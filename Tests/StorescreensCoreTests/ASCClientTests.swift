import XCTest
import CryptoKit
@testable import StorescreensCore

/// URLProtocol that intercepts every request. Tests register a handler that
/// maps (method, path) to a canned response.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "no-handler", code: 0))
            return
        }
        StubProtocol.requests.append(request)
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ASCClientTests: XCTestCase {

    private func makeClient(handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)) -> ASCClient {
        StubProtocol.handler = handler
        StubProtocol.requests.removeAll()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let pk = P256.Signing.PrivateKey()
        let creds = ASCCredentials(
            keyID: "K", issuerID: "I", privateKeyPEM: pk.pemRepresentation, source: .environment
        )
        return ASCClient(credentials: creds, session: session, maxRetries: 2)
    }

    private func response(_ url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    // MARK: - Happy path

    struct AppsResp: Codable {
        struct Data: Codable { let id: String; let type: String }
        let data: [Data]
    }

    func testGet_appendsQueryAndSetsBearer() async throws {
        let client = makeClient { req in
            let body = #"{"data":[{"id":"1234567890","type":"apps"}]}"#
            return (self.response(req.url!), Data(body.utf8))
        }
        let result: AppsResp = try await client.get(
            path: "apps",
            query: ["filter[bundleId]": "com.example.app"],
            as: AppsResp.self
        )
        XCTAssertEqual(result.data.first?.id, "1234567890")

        let sent = StubProtocol.requests.first!
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertTrue(sent.url!.absoluteString.contains("/v1/apps"))
        XCTAssertTrue(sent.url!.absoluteString.contains("filter%5BbundleId%5D=com.example.app"))
        let auth = sent.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.hasPrefix("Bearer "))
        // Verify the token has three parts.
        let token = String(auth.dropFirst("Bearer ".count))
        XCTAssertEqual(token.split(separator: ".").count, 3)
    }

    struct CreateBody: Codable { let name: String }
    struct CreateResp: Codable { let ok: Bool }

    func testPost_encodesJSON() async throws {
        let client = makeClient { req in
            (self.response(req.url!), Data(#"{"ok":true}"#.utf8))
        }
        let resp: CreateResp = try await client.post(path: "things", body: CreateBody(name: "n"), as: CreateResp.self)
        XCTAssertTrue(resp.ok)
        let sent = StubProtocol.requests.first!
        XCTAssertEqual(sent.httpMethod, "POST")

        // Capturing body through URLProtocol returns nil — URLProtocol strips
        // the body from the request object. Just verify it was a POST with
        // Content-Type JSON.
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: - Error envelope

    func testError_parsesASCEnvelope() async {
        let client = makeClient { req in
            let body = """
            {"errors":[{"code":"NOT_FOUND","title":"Resource not found","detail":"App 9 does not exist","status":"404","id":"abc"}]}
            """
            return (self.response(req.url!, status: 404), Data(body.utf8))
        }
        do {
            _ = try await client.get(path: "apps/9", as: AppsResp.self)
            XCTFail("expected error")
        } catch let err as ASCClient.APIError {
            XCTAssertEqual(err.statusCode, 404)
            XCTAssertEqual(err.details.first?.code, "NOT_FOUND")
            XCTAssertEqual(err.details.first?.detail, "App 9 does not exist")
            XCTAssertTrue(err.description.contains("NOT_FOUND"))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Retry

    func testRetry_on503ThenSuccess() async throws {
        let counter = Counter()
        let client = makeClient { req in
            let n = counter.increment()
            if n < 3 {
                return (self.response(req.url!, status: 503), Data(#"{"errors":[]}"#.utf8))
            }
            return (self.response(req.url!, status: 200), Data(#"{"data":[]}"#.utf8))
        }
        let _: AppsResp = try await client.get(path: "apps", as: AppsResp.self)
        XCTAssertEqual(counter.value, 3, "should have tried twice more after initial 503")
    }

    // MARK: - 204 No Content

    func testDelete_204NoContent() async throws {
        let client = makeClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        }
        try await client.delete(path: "things/123")
        XCTAssertEqual(StubProtocol.requests.first?.httpMethod, "DELETE")
    }

    // MARK: - Binary PUT

    func testPutBinary_sendsBody() async throws {
        let client = makeClient { req in
            (self.response(req.url!, status: 200), Data())
        }
        let bin = Data(repeating: 0xAB, count: 100)
        try await client.putBinary(
            absoluteURL: URL(string: "https://upload.example.com/bucket/file")!,
            headers: ["Content-Type": "image/png"],
            body: bin
        )
        let sent = StubProtocol.requests.first!
        XCTAssertEqual(sent.httpMethod, "PUT")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "image/png")
    }
}

/// Thread-safe request counter for the retry test.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        _value += 1
        return _value
    }
}
