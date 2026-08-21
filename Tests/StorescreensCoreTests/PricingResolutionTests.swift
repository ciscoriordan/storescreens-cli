import XCTest
import CryptoKit
@testable import StorescreensCore

/// URLProtocol that captures the outgoing request and replays a canned body,
/// so the price-points query can be asserted without hitting Apple.
private final class PricePointStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = "{}"
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        PricePointStub.requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(PricePointStub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Unit tests for the pure price-resolution logic that powers per-territory
/// pricing: snapping a requested local-currency amount to Apple's nearest
/// valid price point. The network-paging wrapper (`findPricePoint`) is not
/// exercised here; only the pure `nearestPricePoint` selection it delegates to.
final class PricingResolutionTests: XCTestCase {

    /// Builds price points from a compact [id: customerPrice] map via the
    /// real Codable path, so the test doesn't depend on init access levels.
    private func points(_ prices: [(id: String, customer: String)]) throws -> [PricingAvailabilityAPI.PricePoint] {
        let objects = prices.map { ["id": $0.id, "attributes": ["customerPrice": $0.customer, "proceeds": $0.customer]] }
        let data = try JSONSerialization.data(withJSONObject: objects)
        return try JSONDecoder().decode([PricingAvailabilityAPI.PricePoint].self, from: data)
    }

    func testExactMatchWins() throws {
        let ladder = try points([("a", "0.99"), ("b", "4.99"), ("c", "9.99")])
        let result = PricingAvailabilityAPI.nearestPricePoint(ladder, to: 4.99)
        XCTAssertEqual(result?.point.id, "b")
        XCTAssertEqual(result?.value, 4.99)
    }

    func testSnapsToNearestTierWhenNoExactMatch() throws {
        let ladder = try points([("a", "0.99"), ("b", "4.99"), ("c", "9.99")])
        // 5.50 is closer to 4.99 than to 9.99.
        let result = PricingAvailabilityAPI.nearestPricePoint(ladder, to: 5.50)
        XCTAssertEqual(result?.point.id, "b")
        // 8.00 is closer to 9.99 than to 4.99.
        let higher = PricingAvailabilityAPI.nearestPricePoint(ladder, to: 8.00)
        XCTAssertEqual(higher?.point.id, "c")
    }

    func testTieGoesToLowerPrice() throws {
        // 5.00 is equidistant from 4.00 and 6.00; the earlier (lower) wins
        // because the ladder is ascending and ties keep the first seen.
        let ladder = try points([("low", "4.00"), ("high", "6.00")])
        let result = PricingAvailabilityAPI.nearestPricePoint(ladder, to: 5.00)
        XCTAssertEqual(result?.point.id, "low")
    }

    func testFreeResolvesToZeroTier() throws {
        let ladder = try points([("free", "0"), ("a", "0.99"), ("b", "4.99")])
        let result = PricingAvailabilityAPI.nearestPricePoint(ladder, to: 0)
        XCTAssertEqual(result?.point.id, "free")
        XCTAssertEqual(result?.value, 0)
    }

    func testZeroDecimalCurrencyAmounts() throws {
        // JPY-style integer amounts (no minor unit).
        let ladder = try points([("a", "250"), ("b", "600"), ("c", "1200")])
        let result = PricingAvailabilityAPI.nearestPricePoint(ladder, to: 600)
        XCTAssertEqual(result?.point.id, "b")
    }

    func testEmptyLadderReturnsNil() throws {
        XCTAssertNil(PricingAvailabilityAPI.nearestPricePoint([], to: 4.99))
    }

    func testResolvedPriceIsExactFlag() throws {
        let exact = PricingAvailabilityAPI.ResolvedPrice(
            point: try points([("b", "4.99")])[0], requested: 4.99, actual: 4.99
        )
        XCTAssertTrue(exact.isExact)
        let snapped = PricingAvailabilityAPI.ResolvedPrice(
            point: try points([("b", "4.99")])[0], requested: 5.49, actual: 4.99
        )
        XCTAssertFalse(snapped.isExact)
    }

    // MARK: - Request shape

    private func makeAPI() throws -> PricingAvailabilityAPI {
        PricePointStub.requests.removeAll()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PricePointStub.self]
        let pk = P256.Signing.PrivateKey()
        let creds = ASCCredentials(
            keyID: "K", issuerID: "I", privateKeyPEM: pk.pemRepresentation, source: .environment
        )
        return PricingAvailabilityAPI(
            client: ASCClient(
                credentials: creds,
                session: URLSession(configuration: config),
                maxRetries: 1
            )
        )
    }

    /// Regression: `sort` is illegal on `/v1/apps/{id}/appPricePoints` and
    /// Apple answers the whole request with a 400, so the query must carry
    /// only the territory filter, the limit, and any cursor.
    func testListAppPricePointsSendsNoSortParameter() async throws {
        PricePointStub.body = #"{"data":[],"links":{}}"#
        let api = try makeAPI()
        _ = try await api.listAppPricePoints(appID: "6762309721", territoryID: "USA", limit: 4)

        let url = try XCTUnwrap(PricePointStub.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("/v1/apps/6762309721/appPricePoints"))
        XCTAssertFalse(url.contains("sort"), "sort is rejected by this endpoint: \(url)")
        XCTAssertTrue(url.contains("filter%5Bterritory%5D=USA"))
        XCTAssertTrue(url.contains("limit=4"))
    }

    /// The listing is documented as "cheapest first", and now that Apple
    /// cannot sort it for us the ordering has to survive an out-of-order page.
    func testListAppPricePointsOrdersCheapestFirst() async throws {
        PricePointStub.body = """
        {"data":[
          {"id":"c","attributes":{"customerPrice":"4.99","proceeds":"3.49"}},
          {"id":"a","attributes":{"customerPrice":"0.0","proceeds":"0.0"}},
          {"id":"b","attributes":{"customerPrice":"0.29","proceeds":"0.25"}}
        ],"links":{}}
        """
        let api = try makeAPI()
        let (points, _) = try await api.listAppPricePoints(appID: "1", territoryID: "USA", limit: 3)
        XCTAssertEqual(points.map(\.id), ["a", "b", "c"])
    }

    /// "0.0" is what Apple actually returns for the free tier, so numeric
    /// ordering has to place it below "0.29" instead of comparing strings.
    func testSortedByPriceIsNumericNotLexicographic() throws {
        let ladder = try points([("ten", "10.0"), ("nine", "9.99"), ("free", "0.0")])
        XCTAssertEqual(PricingAvailabilityAPI.sortedByPrice(ladder).map(\.id), ["free", "nine", "ten"])
    }

    /// A tier with an unparseable price is kept, not silently dropped.
    func testSortedByPriceKeepsUnparseableTiersLast() throws {
        let ladder = try points([("junk", "n/a"), ("cheap", "0.99")])
        XCTAssertEqual(PricingAvailabilityAPI.sortedByPrice(ladder).map(\.id), ["cheap", "junk"])
    }
}
