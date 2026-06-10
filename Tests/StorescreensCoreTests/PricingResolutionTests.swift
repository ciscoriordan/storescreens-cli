import XCTest
@testable import StorescreensCore

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
}
