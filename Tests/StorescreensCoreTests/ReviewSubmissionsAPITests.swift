import XCTest
import CryptoKit
@testable import StorescreensCore

/// Unit tests for the user-facing reviewSubmissions surface added alongside
/// the `review-submissions` CLI family: the generic item attach (all
/// reviewable kinds, not just appStoreVersions), item PATCH / DELETE, the
/// server-side state filter, and item state decoding. The orchestrator's
/// own submit flow is covered separately in SubmitOrchestratorTests.
private final class ReviewSubmissionsStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [(method: String, suffix: String, body: @Sendable (URLRequest) -> (Int, Data))] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        ReviewSubmissionsStub.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            ReviewSubmissionsStub.requestBodies.append(body)
        } else {
            ReviewSubmissionsStub.requestBodies.append(request.httpBody ?? Data())
        }

        let url = request.url!
        let method = request.httpMethod ?? "GET"
        for handler in ReviewSubmissionsStub.handlers
        where handler.method == method && url.path.hasSuffix(handler.suffix) {
            let (status, data) = handler.body(request)
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"errors":[{"code":"NO_HANDLER","title":"no stub","detail":"\#(url.path)"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() {
        handlers.removeAll()
        requests.removeAll()
        requestBodies.removeAll()
    }

    static func add(method: String, suffix: String, body: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        handlers.append((method, suffix, body))
    }
}

final class ReviewSubmissionsAPITests: XCTestCase {

    private func makeAPI() -> AppsAPI {
        ReviewSubmissionsStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewSubmissionsStub.self]
        let session = URLSession(configuration: config)
        let pk = P256.Signing.PrivateKey()
        let creds = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: pk.pemRepresentation, source: .environment)
        return AppsAPI(client: ASCClient(credentials: creds, session: session, maxRetries: 0))
    }

    private func lastBodyJSON() throws -> [String: Any] {
        let body = try XCTUnwrap(ReviewSubmissionsStub.requestBodies.last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static let itemResponse = Data("""
        {"data": {"type": "reviewSubmissionItems", "id": "RSI1",
                  "attributes": {"state": "READY_FOR_REVIEW"}}}
        """.utf8)

    // MARK: - addItemToReviewSubmission

    func testAddVersion_postsAppStoreVersionRelationship() async throws {
        let api = makeAPI()
        ReviewSubmissionsStub.add(method: "POST", suffix: "/reviewSubmissionItems") { _ in
            (201, Self.itemResponse)
        }
        let item = try await api.addVersionToReviewSubmission(reviewSubmissionID: "SUB1", versionID: "VER1")
        XCTAssertEqual(item.id, "RSI1")

        let json = try lastBodyJSON()
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["type"] as? String, "reviewSubmissionItems")
        let rels = try XCTUnwrap(data["relationships"] as? [String: Any])
        let sub = try XCTUnwrap((rels["reviewSubmission"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(sub["type"] as? String, "reviewSubmissions")
        XCTAssertEqual(sub["id"] as? String, "SUB1")
        let ver = try XCTUnwrap((rels["appStoreVersion"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(ver["type"] as? String, "appStoreVersions")
        XCTAssertEqual(ver["id"] as? String, "VER1")
    }

    func testAddItem_customProductPageVersion_usesSingularKeyPluralType() async throws {
        let api = makeAPI()
        ReviewSubmissionsStub.add(method: "POST", suffix: "/reviewSubmissionItems") { _ in
            (201, Self.itemResponse)
        }
        _ = try await api.addItemToReviewSubmission(
            reviewSubmissionID: "SUB1", itemType: .appCustomProductPageVersion, itemID: "CPP1"
        )
        let rels = try XCTUnwrap((lastBodyJSON()["data"] as? [String: Any])?["relationships"] as? [String: Any])
        let cpp = try XCTUnwrap((rels["appCustomProductPageVersion"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(cpp["type"] as? String, "appCustomProductPageVersions")
        XCTAssertEqual(cpp["id"] as? String, "CPP1")
        XCTAssertNil(rels["appStoreVersion"], "only the requested item kind should be attached")
    }

    func testAddItem_experimentV2_sharesExperimentsResourceType() async throws {
        let api = makeAPI()
        ReviewSubmissionsStub.add(method: "POST", suffix: "/reviewSubmissionItems") { _ in
            (201, Self.itemResponse)
        }
        _ = try await api.addItemToReviewSubmission(
            reviewSubmissionID: "SUB1", itemType: .appStoreVersionExperimentV2, itemID: "EXP1"
        )
        let rels = try XCTUnwrap((lastBodyJSON()["data"] as? [String: Any])?["relationships"] as? [String: Any])
        // Spec quirk: the V2 relationship KEY differs but the resource TYPE
        // is the same `appStoreVersionExperiments` as V1.
        let exp = try XCTUnwrap((rels["appStoreVersionExperimentV2"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(exp["type"] as? String, "appStoreVersionExperiments")
    }

    // MARK: - updateReviewSubmissionItem / deleteReviewSubmissionItem

    func testUpdateItem_removedOnly_omitsResolved() async throws {
        let api = makeAPI()
        ReviewSubmissionsStub.add(method: "PATCH", suffix: "/reviewSubmissionItems/RSI1") { _ in
            (200, Data("""
                {"data": {"type": "reviewSubmissionItems", "id": "RSI1",
                          "attributes": {"state": "REMOVED"}}}
                """.utf8))
        }
        let item = try await api.updateReviewSubmissionItem(id: "RSI1", removed: true)
        XCTAssertEqual(item.attributes?.state, "REMOVED")

        let json = try lastBodyJSON()
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["id"] as? String, "RSI1")
        let attrs = try XCTUnwrap(data["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["removed"] as? Bool, true)
        XCTAssertNil(attrs["resolved"], "unset flags must not be sent (Apple PATCHes are sparse)")
    }

    func testDeleteItem_issuesDELETE() async throws {
        let api = makeAPI()
        ReviewSubmissionsStub.add(method: "DELETE", suffix: "/reviewSubmissionItems/RSI1") { _ in
            (204, Data())
        }
        try await api.deleteReviewSubmissionItem(id: "RSI1")
        let req = try XCTUnwrap(ReviewSubmissionsStub.requests.last)
        XCTAssertEqual(req.httpMethod, "DELETE")
        XCTAssertTrue(req.url!.path.hasSuffix("/reviewSubmissionItems/RSI1"))
    }

    // MARK: - listReviewSubmissions state filter

    func testListReviewSubmissions_statesPushedServerSide() async throws {
        let api = makeAPI()
        ReviewSubmissionsStub.add(method: "GET", suffix: "/reviewSubmissions") { _ in
            (200, Data(#"{"data": []}"#.utf8))
        }
        _ = try await api.listReviewSubmissions(
            appID: "APP1", states: ["WAITING_FOR_REVIEW", "IN_REVIEW"]
        )
        let url = try XCTUnwrap(ReviewSubmissionsStub.requests.last?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(
            items.first(where: { $0.name == "filter[state]" })?.value,
            "WAITING_FOR_REVIEW,IN_REVIEW"
        )
        XCTAssertEqual(items.first(where: { $0.name == "filter[app]" })?.value, "APP1")
    }

    func testListReviewSubmissions_noStates_omitsFilter() async throws {
        let api = makeAPI()
        ReviewSubmissionsStub.add(method: "GET", suffix: "/reviewSubmissions") { _ in
            (200, Data(#"{"data": []}"#.utf8))
        }
        _ = try await api.listReviewSubmissions(appID: "APP1")
        let url = try XCTUnwrap(ReviewSubmissionsStub.requests.last?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(items.first(where: { $0.name == "filter[state]" }))
    }

    // MARK: - item state decoding

    func testListItems_decodesPerItemState() async throws {
        let api = makeAPI()
        ReviewSubmissionsStub.add(method: "GET", suffix: "/reviewSubmissions/SUB1/items") { _ in
            (200, Data("""
                {"data": [
                  {"type": "reviewSubmissionItems", "id": "RSI1",
                   "attributes": {"state": "REJECTED"},
                   "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": "VER1"}}}},
                  {"type": "reviewSubmissionItems", "id": "RSI2",
                   "attributes": {"state": "ACCEPTED"}}
                ]}
                """.utf8))
        }
        let items = try await api.listReviewSubmissionItems(reviewSubmissionID: "SUB1")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].attributes?.state, "REJECTED")
        XCTAssertEqual(items[0].appStoreVersionID, "VER1")
        XCTAssertEqual(items[1].attributes?.state, "ACCEPTED")
        XCTAssertNil(items[1].appStoreVersionID)
    }

    // MARK: - cancel (the headline path)

    func testCancel_patchesCanceledTrue() async throws {
        let api = makeAPI()
        ReviewSubmissionsStub.add(method: "PATCH", suffix: "/reviewSubmissions/SUB1") { _ in
            (200, Data("""
                {"data": {"type": "reviewSubmissions", "id": "SUB1",
                          "attributes": {"state": "CANCELING", "platform": "IOS"}}}
                """.utf8))
        }
        let sub = try await api.cancelReviewSubmission(id: "SUB1")
        XCTAssertEqual(sub.attributes?.state, "CANCELING")

        let json = try lastBodyJSON()
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["id"] as? String, "SUB1")
        let attrs = try XCTUnwrap(data["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["canceled"] as? Bool, true)
    }
}
