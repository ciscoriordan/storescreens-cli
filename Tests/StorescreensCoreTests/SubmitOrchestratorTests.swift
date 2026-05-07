import XCTest
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import StorescreensCore

/// URLProtocol-based ASC API stub: lookups a handler per (method, path suffix)
/// and records every request for assertion. Covers both the JSON API (on
/// api.appstoreconnect.apple.com) and the pre-signed upload URLs (arbitrary
/// hostnames) via a single handler.
private final class ASCStub: URLProtocol, @unchecked Sendable {
    struct Route: Sendable, Hashable {
        let method: String
        let path: String
    }

    /// Handlers keyed by (method, path-suffix). First matching suffix wins.
    nonisolated(unsafe) static var handlers: [(method: String, suffix: String, body: @Sendable (URLRequest) -> (Int, Data))] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    /// Separately captured bodies — URLProtocol strips httpBody, so tests
    /// that need the body must use `httpBodyStream` OR our helper hook below.
    nonisolated(unsafe) static var requestBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        ASCStub.requests.append(request)
        // Recover body from httpBodyStream when present.
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
            ASCStub.requestBodies.append(body)
        } else if let body = request.httpBody {
            ASCStub.requestBodies.append(body)
        } else {
            ASCStub.requestBodies.append(Data())
        }

        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let path = url.path
        for handler in ASCStub.handlers {
            if handler.method == method && path.hasSuffix(handler.suffix) {
                let (status, data) = handler.body(request)
                let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
        }
        let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"errors":[{"code":"NO_HANDLER","title":"no stub","detail":"\#(path)"}]}"#.utf8))
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

/// Thread-safe counter shared with stub handlers.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        _value += 1
        return _value
    }
}

final class SubmitOrchestratorTests: XCTestCase {

    private func makeClient() -> (ASCClient, AppStoreConnectConfig) {
        ASCStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ASCStub.self]
        let session = URLSession(configuration: config)
        let pk = P256.Signing.PrivateKey()
        let creds = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: pk.pemRepresentation, source: .environment)
        let client = ASCClient(credentials: creds, session: session, maxRetries: 0)
        let ascConfig = AppStoreConnectConfig(
            bundleID: "com.example.app",
            metadataDir: nil,
            submit: SubmitConfig(
                createVersion: "1.2.0",
                screenshots: true,
                metadata: true,
                submitForReview: false,
                platform: "IOS",
                // Tests stub only the endpoints they exercise; the
                // attach-build step reaches into `/v1/builds` which
                // nothing here sets up. Real-world submit runs with
                // attach_build: true (the default).
                attachBuild: false
            )
        )
        return (client, ascConfig)
    }

    private func makePNG(w: Int, h: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        let output = NSMutableData()
        let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return output as Data
    }

    // MARK: - Fixture helpers

    private func writeFixture(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - End-to-end: screenshots + metadata

    func testSubmit_fullRoundTrip() async throws {
        let (client, baseConfig) = makeClient()

        // Build a fixture with 2 devices × 2 screenshots each, 2 locales worth of metadata.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-e2e-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let renderRoot = tmp.appendingPathComponent("render")
        try FileManager.default.createDirectory(at: renderRoot, withIntermediateDirectories: true)

        // Write 2 iPhone 6.9 PNGs at 1320x2868 (matches APP_IPHONE_69).
        let iPhonePNG = makePNG(w: 1320, h: 2868)
        try iPhonePNG.write(to: renderRoot.appendingPathComponent("iPhone_6.9_01.png"))
        try iPhonePNG.write(to: renderRoot.appendingPathComponent("iPhone_6.9_02.png"))

        // Metadata dir with en-US + ja.
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        try writeFixture("1.2.0 release notes", to: metaRoot.appendingPathComponent("en-US/release_notes.txt"))
        try writeFixture("日本語の説明", to: metaRoot.appendingPathComponent("ja/description.txt"))

        // Build manifest.
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "test",
            appName: "App", displayName: nil, scheme: "App",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: "iPhone 6.9\"", simulatorName: "iPhone 17 Pro Max",
                    locale: "en-US", appearance: nil,
                    screenshots: [
                        .init(name: "01", filename: "iPhone_6.9_01.png", capturedAt: Date()),
                        .init(name: "02", filename: "iPhone_6.9_02.png", capturedAt: Date()),
                    ]
                )
            ]
        )

        // Wire up all required endpoints.
        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"99999","type":"apps","attributes":{"name":"My App","bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/99999/appStoreVersions") { _ in
            (200, Data(#"{"data":[]}"#.utf8))  // nothing yet; triggers create
        }
        ASCStub.add(method: "POST", suffix: "/v1/appStoreVersions") { _ in
            (201, Data(#"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","platform":"IOS"}}}"#.utf8))
        }
        // Localizations — first call returns empty, subsequent calls return what's been created.
        let localizationsByVersion = NSMutableArray()
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            let data: [[String: Any]] = localizationsByVersion as? [[String: Any]] ?? []
            let json = try! JSONSerialization.data(withJSONObject: ["data": data])
            return (200, json)
        }
        ASCStub.add(method: "POST", suffix: "/v1/appStoreVersionLocalizations") { req in
            let body = ASCStub.requestBodies.last ?? Data()
            let parsed = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            let data = parsed["data"] as! [String: Any]
            let attrs = data["attributes"] as! [String: Any]
            let locale = attrs["locale"] as! String
            let newID = "LOC-\(locale)"
            let entry: [String: Any] = [
                "id": newID,
                "type": "appStoreVersionLocalizations",
                "attributes": ["locale": locale],
            ]
            localizationsByVersion.add(entry)
            let out: [String: Any] = ["data": entry]
            return (201, try! JSONSerialization.data(withJSONObject: out))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-en-US") { _ in
            (200, Data(#"{"data":{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-ja") { _ in
            (200, Data(#"{"data":{"id":"LOC-ja","type":"appStoreVersionLocalizations","attributes":{"locale":"ja"}}}"#.utf8))
        }
        // Screenshot sets: empty list then create.
        ASCStub.add(method: "GET", suffix: "/appStoreVersionLocalizations/LOC-en-US/appScreenshotSets") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/appScreenshotSets") { _ in
            (201, Data(#"{"data":{"id":"SET-1","type":"appScreenshotSets","attributes":{"screenshotDisplayType":"APP_IPHONE_69"}}}"#.utf8))
        }
        // Existing screenshots in the set: empty, so no deletes.
        ASCStub.add(method: "GET", suffix: "/appScreenshotSets/SET-1/appScreenshots") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        // Reserve screenshot: return upload operations pointing at a stub upload URL.
        // Use a counter so each call gets a unique (but deterministic) SHOT id.
        let shotCounter = Counter()
        ASCStub.add(method: "POST", suffix: "/v1/appScreenshots") { _ in
            let n = shotCounter.increment()
            let uploadURL = "https://upload.example.com/chunk-\(n)"
            let body = """
            {"data":{"id":"SHOT-\(n)","type":"appScreenshots","attributes":{"fileSize":1,"fileName":"x.png","uploadOperations":[{"method":"PUT","url":"\(uploadURL)","length":0,"offset":0,"requestHeaders":[]}]}}}
            """
            return (201, Data(body.utf8))
        }
        // The upload-chunk target (matches /chunk-N for any N).
        ASCStub.add(method: "PUT", suffix: "chunk-1") { _ in (200, Data()) }
        ASCStub.add(method: "PUT", suffix: "chunk-2") { _ in (200, Data()) }
        // Confirm uploads.
        ASCStub.add(method: "PATCH", suffix: "/v1/appScreenshots/SHOT-1") { _ in
            (200, Data(#"{"data":{"id":"SHOT-1","type":"appScreenshots","attributes":{}}}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/appScreenshots/SHOT-2") { _ in
            (200, Data(#"{"data":{"id":"SHOT-2","type":"appScreenshots","attributes":{}}}"#.utf8))
        }

        let orchestrator = SubmitOrchestrator(client: client, config: baseConfig)
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: renderRoot,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: true,
            shouldUploadMetadata: true,
            progress: nil
        )

        XCTAssertEqual(report.appID, "99999")
        XCTAssertEqual(report.versionID, "VER-1")
        XCTAssertEqual(report.versionString, "1.2.0")
        XCTAssertEqual(report.metadataUpdates.count, 2, "expected en-US + ja metadata updates, got \(report.metadataUpdates)")
        // 1320x2868 iPhone 17 Pro Max routes to APP_IPHONE_67 until
        // Apple ships a native APP_IPHONE_69 enum value.
        XCTAssertTrue(report.screenshotUploads.contains { $0.locale == "en-US" && $0.displayType == "APP_IPHONE_67" && $0.count == 2 })
        XCTAssertTrue(report.errors.isEmpty, "expected no errors, got: \(report.errors)")

        // Verify each screenshot upload was a full reserve→chunks→confirm sequence.
        let reserveCalls = ASCStub.requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/v1/appScreenshots") == true }
        XCTAssertEqual(reserveCalls.count, 2, "expected 2 reserve calls, got \(reserveCalls.count)")
        let chunkPuts = ASCStub.requests.filter { $0.httpMethod == "PUT" && $0.url?.host == "upload.example.com" }
        XCTAssertEqual(chunkPuts.count, 2, "expected 2 chunk uploads, got \(chunkPuts.count)")
    }

    // MARK: - Failure modes

    func testSubmit_missingCreateVersion_throws() async throws {
        let (client, _) = makeClient()
        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: nil)
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(version: 1, generatedAt: Date(), generatedBy: "t",
                                       appName: "a", displayName: nil, scheme: "s", devices: [])
        do {
            _ = try await orchestrator.submit(
                manifest: manifest,
                renderRoot: URL(fileURLWithPath: "/tmp"),
                metadataRoot: nil,
                shouldUploadScreenshots: false,
                shouldUploadMetadata: false
            )
            XCTFail("expected missingCreateVersion")
        } catch SubmitOrchestrator.Failure.missingCreateVersion {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSubmit_missingAppIdentifier_throws() async throws {
        let (client, _) = makeClient()
        let config = AppStoreConnectConfig(
            submit: SubmitConfig(createVersion: "1.0.0")
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(version: 1, generatedAt: Date(), generatedBy: "t",
                                       appName: "a", displayName: nil, scheme: "s", devices: [])
        do {
            _ = try await orchestrator.submit(
                manifest: manifest,
                renderRoot: URL(fileURLWithPath: "/tmp"),
                metadataRoot: nil,
                shouldUploadScreenshots: false,
                shouldUploadMetadata: false
            )
            XCTFail("expected missingAppIdentifier")
        } catch SubmitOrchestrator.Failure.missingAppIdentifier {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Privacy URL + submit-for-review

    func testSubmit_privacyURL_patchesAppInfoLocalization() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-priv-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        try writeFixture("https://example.com/privacy", to: metaRoot.appendingPathComponent("en-US/privacy_url.txt"))

        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "test",
            appName: "App", displayName: nil, scheme: "App", devices: []
        )

        // App lookup + version flow.
        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"name":"A","bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/appStoreVersions") { _ in
            (201, Data(#"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{}}}"#.utf8))
        }
        // Version localization flow.
        let localizations = NSMutableArray()
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            let json = try! JSONSerialization.data(withJSONObject: ["data": localizations])
            return (200, json)
        }
        ASCStub.add(method: "POST", suffix: "/v1/appStoreVersionLocalizations") { _ in
            let entry: [String: Any] = [
                "id": "LOC-en-US", "type": "appStoreVersionLocalizations",
                "attributes": ["locale": "en-US"],
            ]
            localizations.add(entry)
            return (201, try! JSONSerialization.data(withJSONObject: ["data": entry]))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-en-US") { _ in
            (200, Data(#"{"data":{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}}"#.utf8))
        }
        // App info + app info localization flow — the new privacy URL path.
        var listAppInfosHitCount = 0
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appInfos") { _ in
            listAppInfosHitCount += 1
            let body = """
            {"data":[{"id":"AI-1","type":"appInfos","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}]}
            """
            return (200, Data(body.utf8))
        }
        let appInfoLocalizations = NSMutableArray()
        ASCStub.add(method: "GET", suffix: "/v1/appInfos/AI-1/appInfoLocalizations") { _ in
            let json = try! JSONSerialization.data(withJSONObject: ["data": appInfoLocalizations])
            return (200, json)
        }
        ASCStub.add(method: "POST", suffix: "/v1/appInfoLocalizations") { _ in
            let entry: [String: Any] = [
                "id": "AIL-en-US", "type": "appInfoLocalizations",
                "attributes": ["locale": "en-US"],
            ]
            appInfoLocalizations.add(entry)
            return (201, try! JSONSerialization.data(withJSONObject: ["data": entry]))
        }
        var appInfoPatchHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/appInfoLocalizations/AIL-en-US") { req in
            appInfoPatchHits += 1
            return (200, Data(#"{"data":{"id":"AIL-en-US","type":"appInfoLocalizations","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.2.0",
                metadata: true,
                attachBuild: false  // test stub doesn't model /v1/builds
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true,
            progress: nil
        )

        XCTAssertEqual(listAppInfosHitCount, 1, "should have fetched appInfos once for the editable record")
        XCTAssertEqual(appInfoPatchHits, 1, "should have PATCHed the app info localization with privacyPolicyUrl")
        XCTAssertEqual(report.privacyURLUpdates, ["en-US"])
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// `metadata/<locale>/review_notes.txt` triggers a PATCH on
    /// `appStoreReviewDetails` for the version. When ASC has no
    /// review-detail record yet, the orchestrator POSTs one.
    func testSubmit_reviewNotes_createsReviewDetailWhenNotPresent() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-review-notes-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        try writeFixture("notes for the reviewer", to: metaRoot.appendingPathComponent("en-US/review_notes.txt"))
        try writeFixture("Cisco", to: metaRoot.appendingPathComponent("en-US/review_contact_first_name.txt"))
        try writeFixture("Riordan", to: metaRoot.appendingPathComponent("en-US/review_contact_last_name.txt"))
        try writeFixture("cisco@example.com", to: metaRoot.appendingPathComponent("en-US/review_contact_email.txt"))
        try writeFixture("+15551234567", to: metaRoot.appendingPathComponent("en-US/review_contact_phone.txt"))

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        // No review-detail yet: orchestrator must POST to create.
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreReviewDetail") { _ in
            (200, Data(#"{"data":null}"#.utf8))
        }
        var createBody: Data?
        var createHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/appStoreReviewDetails") { _ in
            createHits += 1
            createBody = ASCStub.requestBodies.last
            return (201, Data(#"{"data":{"id":"RD-1","type":"appStoreReviewDetails","attributes":{}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, Data(#"{"data":[{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}]}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-en-US") { _ in
            (200, Data(#"{"data":{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", metadata: true, attachBuild: false)
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true,
            progress: nil
        )

        XCTAssertEqual(createHits, 1, "expected one POST to /v1/appStoreReviewDetails")
        XCTAssertNotNil(createBody)
        let bodyStr = String(data: createBody!, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("notes for the reviewer"), "notes must be in the POST body: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("Cisco"), "contactFirstName must be sent: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("Riordan"), "contactLastName must be sent: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("cisco@example.com"), "contactEmail must be sent: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("+15551234567"), "contactPhone must be sent: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"appStoreVersion\""), "must reference the parent appStoreVersion: \(bodyStr)")
        XCTAssertTrue(report.reviewDetailUpdated, "report must reflect that review detail was updated")
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// When the version already has a review-detail and the configured
    /// fields differ, PATCH only the differing ones.
    func testSubmit_reviewNotes_patchesExistingReviewDetailWithDiff() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-review-patch-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        try writeFixture("UPDATED notes", to: metaRoot.appendingPathComponent("en-US/review_notes.txt"))
        // contactEmail unchanged from server-side state -> should not appear in PATCH body.
        try writeFixture("cisco@example.com", to: metaRoot.appendingPathComponent("en-US/review_contact_email.txt"))

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        // Existing review-detail: notes are stale, contactEmail matches.
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreReviewDetail") { _ in
            (200, Data(#"{"data":{"id":"RD-1","type":"appStoreReviewDetails","attributes":{"notes":"old notes","contactEmail":"cisco@example.com"}}}"#.utf8))
        }
        var patchBody: Data?
        var patchHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreReviewDetails/RD-1") { _ in
            patchHits += 1
            patchBody = ASCStub.requestBodies.last
            return (200, Data(#"{"data":{"id":"RD-1","type":"appStoreReviewDetails","attributes":{"notes":"UPDATED notes"}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, Data(#"{"data":[{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US","description":"English description"}}]}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-en-US") { _ in
            (200, Data(#"{"data":{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", metadata: true, attachBuild: false)
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true
        )

        XCTAssertEqual(patchHits, 1, "expected one PATCH on appStoreReviewDetails")
        let bodyStr = String(data: patchBody!, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("UPDATED notes"), "diff PATCH must include changed notes: \(bodyStr)")
        XCTAssertFalse(bodyStr.contains("contactEmail"),
                       "unchanged contactEmail must be diffed out: \(bodyStr)")
        XCTAssertTrue(report.reviewDetailUpdated)
    }

    /// When all configured review fields already match what ASC has, no
    /// PATCH should fire (idempotent re-run).
    func testSubmit_reviewNotes_unchangedSkipsPatch() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-review-noop-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("desc", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        try writeFixture("same notes", to: metaRoot.appendingPathComponent("en-US/review_notes.txt"))

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreReviewDetail") { _ in
            (200, Data(#"{"data":{"id":"RD-1","type":"appStoreReviewDetails","attributes":{"notes":"same notes"}}}"#.utf8))
        }
        var patchHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreReviewDetails/RD-1") { _ in
            patchHits += 1
            return (200, Data(#"{"data":{"id":"RD-1","type":"appStoreReviewDetails","attributes":{}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, Data(#"{"data":[{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US","description":"desc"}}]}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", metadata: true, attachBuild: false)
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true
        )

        XCTAssertEqual(patchHits, 0, "matching review-detail must skip the PATCH")
        XCTAssertFalse(report.reviewDetailUpdated)
    }

    func testSubmit_submitForReview_reviewSubmissionsFlow() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"name":"A","bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","platform":"IOS"}}]}"#.utf8))
        }
        // Pre-flight cleanup: orchestrator lists existing submissions; nothing
        // here since this is a clean first-time submit.
        var listHits = 0
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            listHits += 1
            return (200, Data(#"{"data":[]}"#.utf8))
        }
        // 3-step reviewSubmissions flow: POST create, POST item, PATCH finalize.
        var createHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            createHits += 1
            return (201, Data(#"{"data":{"id":"RSUB-1","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}}"#.utf8))
        }
        var itemHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            itemHits += 1
            return (201, Data(#"{"data":{"id":"RITEM-1","type":"reviewSubmissionItems"}}"#.utf8))
        }
        var finalizeHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-1") { _ in
            finalizeHits += 1
            return (200, Data(#"{"data":{"id":"RSUB-1","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.2.0",
                screenshots: false,
                metadata: false,
                submitForReview: true,
                attachBuild: false  // test stub doesn't model /v1/builds
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 0
        )
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(listHits, 1, "GET /reviewSubmissions once for pre-flight cleanup")
        XCTAssertEqual(createHits, 1, "POST /reviewSubmissions once")
        XCTAssertEqual(itemHits, 1, "POST /reviewSubmissionItems once to attach version")
        XCTAssertEqual(finalizeHits, 1, "PATCH /reviewSubmissions/{id} once to set submitted:true")
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-1")
        XCTAssertEqual(report.reviewSubmissionState, "WAITING_FOR_REVIEW",
                       "final state must be WAITING_FOR_REVIEW after submitted:true PATCH")
        XCTAssertTrue(report.canceledReviewSubmissionIDs.isEmpty,
                      "no cleanup needed on a clean app")
        XCTAssertTrue(report.errors.isEmpty)
    }

    /// When the app has a prior `UNRESOLVED_ISSUES` submission (Apple
    /// rejected an earlier build, version is still "stuck" inside that
    /// submission), `submit` must PATCH `canceled: true` on it before
    /// creating the new submission. Otherwise POST item fails with the
    /// "Item is already present in" 409.
    func testSubmit_submitForReview_cancelsUnresolvedIssuesBeforeRecreating() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"name":"A","bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","platform":"IOS"}}]}"#.utf8))
        }
        // Pre-flight list returns a UNRESOLVED_ISSUES submission that owns
        // the version (this is what blocks a fresh submit after a reject).
        var listHits = 0
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            listHits += 1
            return (200, Data(#"{"data":[{"id":"RSUB-OLD","type":"reviewSubmissions","attributes":{"state":"UNRESOLVED_ISSUES","platform":"IOS"}}]}"#.utf8))
        }
        // Cancel PATCH on the old submission: returns 200 with state
        // CANCELING, then GET polls until state COMPLETE.
        var cancelPatchBody: Data?
        var cancelPatchHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-OLD") { _ in
            cancelPatchHits += 1
            cancelPatchBody = ASCStub.requestBodies.last
            return (200, Data(#"{"data":{"id":"RSUB-OLD","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        // Get poll: orchestrator may call this 0+ times; whenever it does,
        // return COMPLETE so the poll exits immediately.
        var getOldHits = 0
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-OLD") { _ in
            getOldHits += 1
            return (200, Data(#"{"data":{"id":"RSUB-OLD","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        // 3-step flow on the new submission.
        var createHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            createHits += 1
            return (201, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}}"#.utf8))
        }
        var itemHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            itemHits += 1
            return (201, Data(#"{"data":{"id":"RITEM-NEW","type":"reviewSubmissionItems"}}"#.utf8))
        }
        var finalizeHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-NEW") { _ in
            finalizeHits += 1
            return (200, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.2.0",
                screenshots: false,
                metadata: false,
                submitForReview: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 5
        )
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(listHits, 1, "GET /reviewSubmissions once for pre-flight")
        XCTAssertEqual(cancelPatchHits, 1, "PATCH /reviewSubmissions/RSUB-OLD once to cancel")
        XCTAssertNotNil(cancelPatchBody, "cancel PATCH should have a body")
        let cancelStr = String(data: cancelPatchBody!, encoding: .utf8) ?? ""
        XCTAssertTrue(cancelStr.contains("\"canceled\":true"),
                      "cancel PATCH must send canceled: true, got \(cancelStr)")
        XCTAssertFalse(cancelStr.contains("\"submitted\""),
                       "cancel PATCH must not include submitted attribute")
        XCTAssertGreaterThanOrEqual(getOldHits, 1, "should poll until cancel settles")
        XCTAssertEqual(createHits, 1, "exactly one new submission created after cleanup")
        XCTAssertEqual(itemHits, 1, "version attached to new submission")
        XCTAssertEqual(finalizeHits, 1, "submitted:true PATCH on new submission")
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-NEW")
        XCTAssertEqual(report.reviewSubmissionState, "WAITING_FOR_REVIEW")
        XCTAssertEqual(report.canceledReviewSubmissionIDs, ["RSUB-OLD"])
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// `READY_FOR_REVIEW` (an aborted prior submit's draft submission) is
    /// also cancellable. Same mechanism as UNRESOLVED_ISSUES.
    func testSubmit_submitForReview_cancelsStaleReadyForReviewDraft() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[{"id":"RSUB-STALE","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}]}"#.utf8))
        }
        var staleCanceled = false
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-STALE") { _ in
            staleCanceled = true
            return (200, Data(#"{"data":{"id":"RSUB-STALE","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-STALE") { _ in
            (200, Data(#"{"data":{"id":"RSUB-STALE","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            (201, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            (201, Data(#"{"data":{"id":"RI-NEW","type":"reviewSubmissionItems"}}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-NEW") { _ in
            (200, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.0.0",
                submitForReview: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 1
        )
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertTrue(staleCanceled, "stale READY_FOR_REVIEW must be canceled")
        XCTAssertEqual(report.canceledReviewSubmissionIDs, ["RSUB-STALE"])
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-NEW")
    }

    /// `IN_REVIEW` and `WAITING_FOR_REVIEW` are off-limits for auto-cancel:
    /// Apple is actively reviewing or about to. Surface a clear error and
    /// do NOT issue a cancel PATCH.
    func testSubmit_submitForReview_inReviewBailsLoudly() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[{"id":"RSUB-LIVE","type":"reviewSubmissions","attributes":{"state":"IN_REVIEW","platform":"IOS"}}]}"#.utf8))
        }
        var cancelHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-LIVE") { _ in
            cancelHits += 1
            return (200, Data(#"{"data":{"id":"RSUB-LIVE","type":"reviewSubmissions","attributes":{}}}"#.utf8))
        }
        var createHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            createHits += 1
            return (201, Data(#"{"data":{"id":"X","type":"reviewSubmissions","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.0.0",
                submitForReview: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 0
        )
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(cancelHits, 0, "must not auto-cancel an IN_REVIEW submission")
        XCTAssertEqual(createHits, 0, "must not create a new submission while one is in review")
        XCTAssertTrue(report.canceledReviewSubmissionIDs.isEmpty)
        XCTAssertNil(report.reviewSubmissionID)
        XCTAssertTrue(report.errors.contains { $0.contains("active review") || $0.contains("IN_REVIEW") },
                      "expected an active-review error, got: \(report.errors)")
    }

    /// `WAITING_FOR_REVIEW` is also off-limits: Apple has it queued and
    /// the developer probably doesn't want it pulled out from under them.
    func testSubmit_submitForReview_waitingForReviewBailsLoudly() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[{"id":"RSUB-WAIT","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW","platform":"IOS"}}]}"#.utf8))
        }
        var createHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            createHits += 1
            return (201, Data(#"{"data":{"id":"X","type":"reviewSubmissions","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.0.0",
                submitForReview: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 0
        )
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(createHits, 0, "must not create a new submission while one is queued for review")
        XCTAssertTrue(report.errors.contains { $0.contains("WAITING_FOR_REVIEW") || $0.contains("active review") },
                      "expected a waiting-for-review error, got: \(report.errors)")
    }

    /// Multiple stuck submissions all get canceled in one pass.
    func testSubmit_submitForReview_cancelsAllStaleSubmissions() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            let body = """
            {"data":[
              {"id":"RSUB-A","type":"reviewSubmissions","attributes":{"state":"UNRESOLVED_ISSUES","platform":"IOS"}},
              {"id":"RSUB-B","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}
            ]}
            """
            return (200, Data(body.utf8))
        }
        var cancelAHits = 0, cancelBHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-A") { _ in
            cancelAHits += 1
            return (200, Data(#"{"data":{"id":"RSUB-A","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-B") { _ in
            cancelBHits += 1
            return (200, Data(#"{"data":{"id":"RSUB-B","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-A") { _ in
            (200, Data(#"{"data":{"id":"RSUB-A","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-B") { _ in
            (200, Data(#"{"data":{"id":"RSUB-B","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            (201, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            (201, Data(#"{"data":{"id":"RI","type":"reviewSubmissionItems"}}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-NEW") { _ in
            (200, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.0.0",
                submitForReview: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 1
        )
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(cancelAHits, 1)
        XCTAssertEqual(cancelBHits, 1)
        XCTAssertEqual(Set(report.canceledReviewSubmissionIDs), Set(["RSUB-A", "RSUB-B"]))
        XCTAssertTrue(report.errors.isEmpty, "errors: \(report.errors)")
    }

    /// Edge case: cleanup phase succeeded (or there was nothing to clean
    /// up) but POST item still fails with the "Item is already present
    /// in" 409 - because Apple's state propagation lagged. Surface as a
    /// real error in `report.errors` rather than swallowing it as
    /// "already submitted". The user must see this so they can re-run.
    func testSubmit_submitForReview_addItem409SurfacesAsError() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        // Pre-flight returns nothing - clean app from the orchestrator's POV.
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            (201, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}}"#.utf8))
        }
        // POST item: simulate Apple's exact rejection text from the original
        // problem report. With the old "isAlreadySetConflict" path this
        // would have been swallowed; the new orchestrator surfaces it.
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            let body = """
            {"errors":[{"id":"x","status":"409","code":"STATE_ERROR.ENTITY_STATE_INVALID","title":"State error","detail":"appStoreVersions with id '12345' is not in valid state. Item is already present in [other-submission]."}]}
            """
            return (409, Data(body.utf8))
        }
        var finalizeHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-NEW") { _ in
            finalizeHits += 1
            return (200, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.0.0",
                submitForReview: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 0
        )
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(finalizeHits, 0,
                       "must NOT call PATCH submitted=true after addItem failed")
        XCTAssertFalse(report.errors.isEmpty,
                       "POST item 409 must surface as an error, not be swallowed")
        XCTAssertTrue(report.errors.contains { $0.contains("attach version") },
                      "expected an attach-version error, got: \(report.errors)")
    }

    /// Verify the orchestrator never issues a DELETE on a reviewSubmission.
    /// Apple returns 403 on DELETE regardless of state; the only working
    /// programmatic cancel is the canceled:true PATCH.
    func testSubmit_submitForReview_neverIssuesDelete() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[{"id":"RSUB-OLD","type":"reviewSubmissions","attributes":{"state":"UNRESOLVED_ISSUES","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-OLD") { _ in
            (200, Data(#"{"data":{"id":"RSUB-OLD","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-OLD") { _ in
            (200, Data(#"{"data":{"id":"RSUB-OLD","type":"reviewSubmissions","attributes":{"state":"COMPLETE"}}}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            (201, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            (201, Data(#"{"data":{"id":"RI","type":"reviewSubmissionItems"}}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-NEW") { _ in
            (200, Data(#"{"data":{"id":"RSUB-NEW","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.0.0",
                submitForReview: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 1
        )
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )
        _ = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        let deleteCalls = ASCStub.requests.filter {
            $0.httpMethod == "DELETE" && $0.url?.path.contains("/reviewSubmissions/") == true
        }
        XCTAssertEqual(deleteCalls.count, 0, "must never DELETE a reviewSubmission - the API returns 403")
    }

    func testSubmit_submitForReview_defaultsFalse_noPost() async throws {
        let (client, _) = makeClient()
        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","platform":"IOS"}}]}"#.utf8))
        }
        var createHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            createHits += 1
            return (201, Data(#"{"data":{"id":"X","type":"reviewSubmissions","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.2.0")   // submitForReview default nil = false
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(createHits, 0, "submit-for-review must not fire when the flag is unset")
        XCTAssertNil(report.reviewSubmissionID)
    }

    // MARK: - Pricing & Availability

    /// Availability set to a specific territory list: POST to
    /// /v2/appAvailabilities with exactly those territory IDs, no territory
    /// list lookup needed.
    func testSubmit_availability_explicitList_posts() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        // New app: no current availability.
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appAvailabilityV2") { _ in
            (404, Data(#"{"errors":[{"code":"NOT_FOUND","title":"not found","detail":"no availability"}]}"#.utf8))
        }
        let postBodies = NSMutableArray()
        ASCStub.add(method: "POST", suffix: "/v2/appAvailabilities") { _ in
            postBodies.add(ASCStub.requestBodies.last ?? Data())
            return (201, Data(#"{"data":{"id":"AV-1","type":"appAvailabilities","attributes":{"availableInNewTerritories":true}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", attachBuild: false),
            availability: AvailabilityConfig(
                territories: .list(["USA", "CAN", "GBR"]),
                availableInNewTerritories: true
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false,
            progress: nil
        )

        XCTAssertEqual(postBodies.count, 1, "expected one POST to /v2/appAvailabilities")
        let bodyStr = String(data: postBodies[0] as! Data, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("\"USA\""), "USA must be in territory list: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"CAN\""), "CAN must be in territory list: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"GBR\""), "GBR must be in territory list: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"availableInNewTerritories\":true"), "availableInNewTerritories flag must be set: \(bodyStr)")
        XCTAssertEqual(report.availabilityStatus, "updated (3 territories, new territories: true)")
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// Availability set to `.all` resolves to the full territory list first,
    /// then POSTs.
    func testSubmit_availability_all_expandsTerritoryList() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/territories") { _ in
            (200, Data(#"{"data":[{"id":"USA","type":"territories"},{"id":"CAN","type":"territories"},{"id":"GBR","type":"territories"},{"id":"DEU","type":"territories"}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appAvailabilityV2") { _ in
            (404, Data(#"{"errors":[{"code":"NOT_FOUND","title":"not found","detail":"no availability"}]}"#.utf8))
        }
        let postBodies = NSMutableArray()
        ASCStub.add(method: "POST", suffix: "/v2/appAvailabilities") { _ in
            postBodies.add(ASCStub.requestBodies.last ?? Data())
            return (201, Data(#"{"data":{"id":"AV-1","type":"appAvailabilities","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", attachBuild: false),
            availability: AvailabilityConfig(territories: .all)
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(postBodies.count, 1)
        let bodyStr = String(data: postBodies[0] as! Data, encoding: .utf8) ?? ""
        for id in ["USA", "CAN", "GBR", "DEU"] {
            XCTAssertTrue(bodyStr.contains("\"\(id)\""), "\(id) must be in the expanded territory list: \(bodyStr)")
        }
        XCTAssertEqual(report.availabilityStatus, "updated (4 territories, new territories: true)")
    }

    /// When current availability already matches desired, skip the POST and
    /// report `unchanged` so idempotent re-runs aren't destructive.
    func testSubmit_availability_unchanged_skipsPost() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appAvailabilityV2") { _ in
            (200, Data(#"{"data":{"id":"AV-CURRENT","type":"appAvailabilities","attributes":{"availableInNewTerritories":true}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appAvailabilities/AV-CURRENT/availableTerritories") { _ in
            (200, Data(#"{"data":[{"id":"USA","type":"territories"},{"id":"CAN","type":"territories"}]}"#.utf8))
        }
        var postHits = 0
        ASCStub.add(method: "POST", suffix: "/v2/appAvailabilities") { _ in
            postHits += 1
            return (201, Data(#"{"data":{"id":"AV-2","type":"appAvailabilities","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", attachBuild: false),
            availability: AvailabilityConfig(
                territories: .list(["USA", "CAN"]),
                availableInNewTerritories: true
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(postHits, 0, "matching current availability must not re-POST")
        XCTAssertEqual(report.availabilityStatus, "unchanged")
    }

    /// Pricing `free: true` on a new app: look up the free price point for
    /// the base territory, then POST a new appPriceSchedule referencing it.
    func testSubmit_pricing_freeOnNewApp_createsSchedule() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        // No existing price schedule → 404.
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appPriceSchedule") { _ in
            (404, Data(#"{"errors":[{"code":"NOT_FOUND","title":"not found","detail":"no schedule"}]}"#.utf8))
        }
        // Free USA price point lookup returns tier 0 first.
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appPricePoints") { _ in
            let body = """
            {"data":[
              {"id":"PP-FREE","type":"appPricePoints","attributes":{"customerPrice":"0","proceeds":"0"}},
              {"id":"PP-099","type":"appPricePoints","attributes":{"customerPrice":"0.99","proceeds":"0.70"}}
            ]}
            """
            return (200, Data(body.utf8))
        }
        let postBodies = NSMutableArray()
        ASCStub.add(method: "POST", suffix: "/v1/appPriceSchedules") { _ in
            postBodies.add(ASCStub.requestBodies.last ?? Data())
            return (201, Data(#"{"data":{"id":"PS-1","type":"appPriceSchedules"}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", attachBuild: false),
            pricing: PricingConfig(free: true, baseTerritory: "USA")
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(postBodies.count, 1, "expected one POST to /v1/appPriceSchedules")
        let bodyStr = String(data: postBodies[0] as! Data, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("\"PP-FREE\""), "free price point ID must be in the schedule POST body: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"USA\""), "base territory must be set: \(bodyStr)")
        XCTAssertEqual(report.pricingStatus, "free (base: USA)")
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// Pricing is idempotent: if a schedule already exists, leave it alone.
    /// Blindly POSTing a new schedule would overwrite whatever the dev set
    /// up by hand in the ASC web UI.
    func testSubmit_pricing_existingSchedule_leavesUntouched() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appPriceSchedule") { _ in
            (200, Data(#"{"data":{"id":"PS-EXISTING","type":"appPriceSchedules"}}"#.utf8))
        }
        var postHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/appPriceSchedules") { _ in
            postHits += 1
            return (201, Data(#"{"data":{"id":"PS-NEW","type":"appPriceSchedules"}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", attachBuild: false),
            pricing: PricingConfig(free: true)
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(postHits, 0, "existing schedule must not be replaced")
        XCTAssertEqual(report.pricingStatus, "unchanged")
    }

    /// Paid pricing is not yet implemented — surface a clear error rather
    /// than silently skipping.
    func testSubmit_pricing_paidNotSupported_reportsError() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", attachBuild: false),
            pricing: PricingConfig(free: false)
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertTrue(report.errors.contains { $0.contains("only `free: true`") },
                      "paid pricing must surface a clear error, got: \(report.errors)")
        XCTAssertNil(report.pricingStatus)
    }

    // MARK: - First-version whatsNew skip

    /// When the app has no prior released version, `whatsNew` must be
    /// stripped before the PATCH goes out — ASC rejects release notes on
    /// a brand-new app's first version.
    func testSubmit_firstVersion_stripsWhatsNewFromPatch() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-first-version-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        try writeFixture("initial release", to: metaRoot.appendingPathComponent("en-US/release_notes.txt"))

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        // Only a PREPARE_FOR_SUBMISSION version exists — no prior released
        // state anywhere, so this is the app's very first submission.
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, Data(#"{"data":[{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}]}"#.utf8))
        }
        let patchBodies = NSMutableArray()
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-en-US") { _ in
            let body = ASCStub.requestBodies.last ?? Data()
            patchBodies.add(body)
            return (200, Data(#"{"data":{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0.0", metadata: true, attachBuild: false)
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        var progressLines: [String] = []
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true,
            progress: { progressLines.append($0) }
        )

        // PATCH went out (description needs updating) but whatsNew must
        // not appear in the body.
        XCTAssertEqual(patchBodies.count, 1, "expected one PATCH on the localization")
        let bodyStr = String(data: patchBodies[0] as! Data, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyStr.contains("whatsNew"), "whatsNew must be absent on first-version PATCH: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("English description"), "description must still be sent: \(bodyStr)")
        XCTAssertTrue(progressLines.contains { $0.contains("skipping whatsNew") },
                      "expected a progress line noting the skip, got: \(progressLines)")
        // Report still reflects that a metadata update happened (description),
        // just without whatsNew in the field list.
        XCTAssertEqual(report.metadataUpdates.count, 1)
        XCTAssertEqual(report.metadataUpdates.first?.fieldsUpdated, ["description"])
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// When a prior version is in a released state, whatsNew must go
    /// through normally — the skip only applies on the app's first version.
    func testSubmit_subsequentVersion_sendsWhatsNew() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-update-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        try writeFixture("1.1 release notes", to: metaRoot.appendingPathComponent("en-US/release_notes.txt"))

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        // Two versions: the current editable 1.1 + a prior 1.0 that's
        // already READY_FOR_SALE, so whatsNew is legal on 1.1.
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            let body = """
            {"data":[
              {"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.1.0","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}},
              {"id":"VER-0","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS","appStoreState":"READY_FOR_SALE"}}
            ]}
            """
            return (200, Data(body.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, Data(#"{"data":[{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}]}"#.utf8))
        }
        let patchBodies = NSMutableArray()
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-en-US") { _ in
            let body = ASCStub.requestBodies.last ?? Data()
            patchBodies.add(body)
            return (200, Data(#"{"data":{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.1.0", metadata: true, attachBuild: false)
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true,
            progress: nil
        )

        XCTAssertEqual(patchBodies.count, 1, "expected one PATCH on the localization")
        let bodyStr = String(data: patchBodies[0] as! Data, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("whatsNew"), "whatsNew must be present when a prior version is released: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("1.1 release notes"), "whatsNew value must be the fixture content: \(bodyStr)")
        XCTAssertEqual(report.metadataUpdates.first?.fieldsUpdated.sorted(), ["description", "whatsNew"])
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    // MARK: - Idempotency: skip unchanged fields and screenshots

    /// When every metadata field already matches ASC's current values, the
    /// PATCH calls are skipped and the report shows no metadataUpdates.
    func testSubmit_unchangedMetadata_skipsPatch() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-meta-noop-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        try writeFixture("1.2.0 release notes", to: metaRoot.appendingPathComponent("en-US/release_notes.txt"))

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","platform":"IOS"}}]}"#.utf8))
        }
        // Current localization already carries the exact same description
        // + whatsNew we'll read from the fixture files, so the diff should
        // come back empty.
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, Data(#"{"data":[{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US","description":"English description","whatsNew":"1.2.0 release notes"}}]}"#.utf8))
        }
        let patchCounter = Counter()
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-en-US") { _ in
            _ = patchCounter.increment()
            return (200, Data(#"{"data":{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.2.0",
                metadata: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )

        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true,
            progress: nil
        )

        let patchCalls = ASCStub.requests.filter {
            $0.httpMethod == "PATCH" && $0.url?.path.hasSuffix("/v1/appStoreVersionLocalizations/LOC-en-US") == true
        }
        XCTAssertEqual(patchCalls.count, 0, "unchanged metadata must not PATCH the localization")
        XCTAssertTrue(report.metadataUpdates.isEmpty, "unchanged metadata should not be listed in the report")
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// When the existing screenshot set's sourceFileChecksum values match
    /// the local renders in the same order, the submit run skips the
    /// DELETE loop and the upload chain entirely.
    func testSubmit_unchangedScreenshots_skipsUploadAndDelete() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-shot-noop-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let renderRoot = tmp.appendingPathComponent("render")
        try FileManager.default.createDirectory(at: renderRoot, withIntermediateDirectories: true)

        // Write 2 iPhone PNGs and record their MD5s so ASC's "current set"
        // can claim matching sourceFileChecksums.
        let png1 = makePNG(w: 1320, h: 2868)
        let png2 = makePNG(w: 1320, h: 2868)
        try png1.write(to: renderRoot.appendingPathComponent("iPhone_6.9_01.png"))
        try png2.write(to: renderRoot.appendingPathComponent("iPhone_6.9_02.png"))
        let md5_1 = Insecure.MD5.hash(data: png1).map { String(format: "%02x", $0) }.joined()
        let md5_2 = Insecure.MD5.hash(data: png2).map { String(format: "%02x", $0) }.joined()

        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "App", displayName: nil, scheme: "App",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: "iPhone 6.9\"", simulatorName: "iPhone 17 Pro Max",
                    locale: "en-US", appearance: nil,
                    screenshots: [
                        .init(name: "01", filename: "iPhone_6.9_01.png", capturedAt: Date()),
                        .init(name: "02", filename: "iPhone_6.9_02.png", capturedAt: Date()),
                    ]
                )
            ]
        )

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, Data(#"{"data":[{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/appStoreVersionLocalizations/LOC-en-US/appScreenshotSets") { _ in
            (200, Data(#"{"data":[{"id":"SET-1","type":"appScreenshotSets","attributes":{"screenshotDisplayType":"APP_IPHONE_67"}}]}"#.utf8))
        }
        // Existing screenshots' checksums match the local renders.
        let existingJSON = """
        {"data":[
          {"id":"EXIST-1","type":"appScreenshots","attributes":{"fileName":"iPhone_6.9_01.png","sourceFileChecksum":"\(md5_1)"}},
          {"id":"EXIST-2","type":"appScreenshots","attributes":{"fileName":"iPhone_6.9_02.png","sourceFileChecksum":"\(md5_2)"}}
        ]}
        """
        ASCStub.add(method: "GET", suffix: "/appScreenshotSets/SET-1/appScreenshots") { _ in
            (200, Data(existingJSON.utf8))
        }
        // Guards: if any of these ever fire, the idempotency check broke.
        let deleteCounter = Counter()
        ASCStub.add(method: "DELETE", suffix: "/v1/appScreenshots/EXIST-1") { _ in
            _ = deleteCounter.increment(); return (204, Data())
        }
        ASCStub.add(method: "DELETE", suffix: "/v1/appScreenshots/EXIST-2") { _ in
            _ = deleteCounter.increment(); return (204, Data())
        }
        let reserveCounter = Counter()
        ASCStub.add(method: "POST", suffix: "/v1/appScreenshots") { _ in
            _ = reserveCounter.increment()
            return (201, Data(#"{"data":{"id":"SHOT-X","type":"appScreenshots","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.2.0",
                screenshots: true,
                metadata: false,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: renderRoot,
            metadataRoot: nil,
            shouldUploadScreenshots: true,
            shouldUploadMetadata: false,
            progress: nil
        )

        let deleteCalls = ASCStub.requests.filter {
            $0.httpMethod == "DELETE" && $0.url?.path.contains("/v1/appScreenshots/EXIST-") == true
        }
        let reserveCalls = ASCStub.requests.filter {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/v1/appScreenshots") == true
        }
        XCTAssertEqual(deleteCalls.count, 0, "unchanged screenshots must not DELETE existing entries")
        XCTAssertEqual(reserveCalls.count, 0, "unchanged screenshots must not reserve new uploads")
        // The group is still reported, but with count=0 to signal the skip.
        XCTAssertTrue(report.screenshotUploads.contains {
            $0.locale == "en-US" && $0.displayType == "APP_IPHONE_67" && $0.count == 0
        }, "expected a count=0 skip entry, got \(report.screenshotUploads)")
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    func testSubmit_bundleIDNotFound_throws() async throws {
        let (client, baseConfig) = makeClient()
        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        let orchestrator = SubmitOrchestrator(client: client, config: baseConfig)
        let manifest = CaptureManifest(version: 1, generatedAt: Date(), generatedBy: "t",
                                       appName: "a", displayName: nil, scheme: "s", devices: [])
        do {
            _ = try await orchestrator.submit(
                manifest: manifest,
                renderRoot: URL(fileURLWithPath: "/tmp"),
                metadataRoot: nil,
                shouldUploadScreenshots: false,
                shouldUploadMetadata: false
            )
            XCTFail("expected appNotFound")
        } catch SubmitOrchestrator.Failure.appNotFound {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - appInfo field routing (name / subtitle / privacy URLs)

    /// Regression test for the bug where `name.txt` and `subtitle.txt`
    /// were silently dropped (or pushed to `appStoreVersionLocalizations`,
    /// which has no name/subtitle). They must land on
    /// `appInfoLocalizations` for the editable AppInfo. This test also
    /// verifies that `privacy_choices_url.txt` is routed to the same
    /// resource and that the version-localization PATCH does NOT include
    /// any of the appInfo fields.
    func testSubmit_nameSubtitlePrivacyChoices_routedToAppInfoLocalization() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("submit-appinfo-routing-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("My App", to: metaRoot.appendingPathComponent("en-US/name.txt"))
        try writeFixture("Cook smarter", to: metaRoot.appendingPathComponent("en-US/subtitle.txt"))
        try writeFixture("https://example.com/privacy", to: metaRoot.appendingPathComponent("en-US/privacy_url.txt"))
        try writeFixture("https://example.com/choices", to: metaRoot.appendingPathComponent("en-US/privacy_choices_url.txt"))
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))

        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "test",
            appName: "App", displayName: nil, scheme: "App", devices: []
        )

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"name":"A","bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/appStoreVersions") { _ in
            (201, Data(#"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{}}}"#.utf8))
        }
        // Version localization: empty list, then create.
        let localizations = NSMutableArray()
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, try! JSONSerialization.data(withJSONObject: ["data": localizations]))
        }
        ASCStub.add(method: "POST", suffix: "/v1/appStoreVersionLocalizations") { _ in
            let entry: [String: Any] = [
                "id": "LOC-en-US", "type": "appStoreVersionLocalizations",
                "attributes": ["locale": "en-US"],
            ]
            localizations.add(entry)
            return (201, try! JSONSerialization.data(withJSONObject: ["data": entry]))
        }
        // Capture every PATCH body so we can assert the field routing.
        let versionPatchBodies = NSMutableArray()
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-en-US") { _ in
            if let body = ASCStub.requestBodies.last {
                versionPatchBodies.add(body)
            }
            return (200, Data(#"{"data":{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}}"#.utf8))
        }
        // appInfo + appInfoLocalization flow.
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appInfos") { _ in
            (200, Data(#"{"data":[{"id":"AI-1","type":"appInfos","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        let appInfoLocalizations = NSMutableArray()
        ASCStub.add(method: "GET", suffix: "/v1/appInfos/AI-1/appInfoLocalizations") { _ in
            (200, try! JSONSerialization.data(withJSONObject: ["data": appInfoLocalizations]))
        }
        ASCStub.add(method: "POST", suffix: "/v1/appInfoLocalizations") { _ in
            let entry: [String: Any] = [
                "id": "AIL-en-US", "type": "appInfoLocalizations",
                "attributes": ["locale": "en-US"],
            ]
            appInfoLocalizations.add(entry)
            return (201, try! JSONSerialization.data(withJSONObject: ["data": entry]))
        }
        let appInfoPatchBodies = NSMutableArray()
        ASCStub.add(method: "PATCH", suffix: "/v1/appInfoLocalizations/AIL-en-US") { _ in
            if let body = ASCStub.requestBodies.last {
                appInfoPatchBodies.add(body)
            }
            return (200, Data(#"{"data":{"id":"AIL-en-US","type":"appInfoLocalizations","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.2.0",
                metadata: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true,
            progress: nil
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")

        // The version-localization PATCH should carry the description but
        // NOT name, subtitle, privacyPolicyUrl, or privacyChoicesUrl.
        XCTAssertEqual(versionPatchBodies.count, 1, "expected exactly one version-loc PATCH")
        let versionBody = versionPatchBodies[0] as! Data
        let versionJSON = try JSONSerialization.jsonObject(with: versionBody) as! [String: Any]
        let versionAttrs = ((versionJSON["data"] as! [String: Any])["attributes"] as! [String: Any])
        XCTAssertEqual(versionAttrs["description"] as? String, "English description")
        XCTAssertNil(versionAttrs["name"], "version localization must NOT carry name")
        XCTAssertNil(versionAttrs["subtitle"], "version localization must NOT carry subtitle")
        XCTAssertNil(versionAttrs["privacyPolicyUrl"], "version localization must NOT carry privacyPolicyUrl")
        XCTAssertNil(versionAttrs["privacyChoicesUrl"], "version localization must NOT carry privacyChoicesUrl")

        // The appInfo-localization PATCH must carry name + subtitle +
        // both privacy URLs, and NOT description / keywords / etc.
        XCTAssertEqual(appInfoPatchBodies.count, 1, "expected exactly one appInfo-loc PATCH")
        let appInfoBody = appInfoPatchBodies[0] as! Data
        let appInfoJSON = try JSONSerialization.jsonObject(with: appInfoBody) as! [String: Any]
        let appInfoAttrs = ((appInfoJSON["data"] as! [String: Any])["attributes"] as! [String: Any])
        XCTAssertEqual(appInfoAttrs["name"] as? String, "My App")
        XCTAssertEqual(appInfoAttrs["subtitle"] as? String, "Cook smarter")
        XCTAssertEqual(appInfoAttrs["privacyPolicyUrl"] as? String, "https://example.com/privacy")
        XCTAssertEqual(appInfoAttrs["privacyChoicesUrl"] as? String, "https://example.com/choices")
        XCTAssertNil(appInfoAttrs["description"], "appInfo localization must NOT carry description")
        XCTAssertNil(appInfoAttrs["keywords"], "appInfo localization must NOT carry keywords")

        // Report exposes both buckets.
        XCTAssertEqual(report.metadataUpdates.first?.locale, "en-US")
        XCTAssertEqual(report.metadataUpdates.first?.fieldsUpdated, ["description"])
        XCTAssertEqual(report.appInfoUpdates.first?.locale, "en-US")
        XCTAssertEqual(report.appInfoUpdates.first?.fieldsUpdated,
                       ["name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl"])
        // Privacy URL backwards-compat list still populated for old consumers.
        XCTAssertEqual(report.privacyURLUpdates, ["en-US"])
        XCTAssertNil(report.appInfoSkipped)
    }

    /// When ASC has no editable AppInfo (e.g. live version is
    /// READY_FOR_SALE and no new editable version has been created),
    /// `submit` should skip the appInfoLocalizations PATCH with a clear
    /// reason rather than failing the whole submit. The version-level
    /// fields (description etc.) must still be applied.
    func testSubmit_noEditableAppInfo_skipsAppInfoFields_logsReason() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("submit-appinfo-skip-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("My App", to: metaRoot.appendingPathComponent("en-US/name.txt"))
        try writeFixture("Cook smarter", to: metaRoot.appendingPathComponent("en-US/subtitle.txt"))
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))

        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "test",
            appName: "App", displayName: nil, scheme: "App", devices: []
        )

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"name":"A","bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/appStoreVersions") { _ in
            (201, Data(#"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{}}}"#.utf8))
        }
        let localizations = NSMutableArray()
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, try! JSONSerialization.data(withJSONObject: ["data": localizations]))
        }
        ASCStub.add(method: "POST", suffix: "/v1/appStoreVersionLocalizations") { _ in
            let entry: [String: Any] = [
                "id": "LOC-en-US", "type": "appStoreVersionLocalizations",
                "attributes": ["locale": "en-US"],
            ]
            localizations.add(entry)
            return (201, try! JSONSerialization.data(withJSONObject: ["data": entry]))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersionLocalizations/LOC-en-US") { _ in
            (200, Data(#"{"data":{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}}"#.utf8))
        }
        // appInfos: only READY_FOR_SALE (not editable) -> orchestrator
        // should set `appInfoSkipped = .noEditableAppInfo` and skip the
        // PATCH. With the current `findEditableAppInfo` implementation
        // that returns the first record as a fallback, return an empty
        // list to truly express "no editable record".
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appInfos") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        // If something tries to PATCH appInfoLocalizations anyway, fail
        // loudly so the test catches it.
        ASCStub.add(method: "GET", suffix: "/v1/appInfos/AI-1/appInfoLocalizations") { _ in
            XCTFail("must not list appInfoLocalizations when no editable AppInfo exists")
            return (500, Data())
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/appInfoLocalizations/AIL-en-US") { _ in
            XCTFail("must not PATCH appInfoLocalizations when no editable AppInfo exists")
            return (500, Data())
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.2.0",
                metadata: true,
                attachBuild: false
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)

        var progressLines: [String] = []
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true,
            progress: { progressLines.append($0) }
        )

        // Submit didn't fail — version-level description still applied.
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.metadataUpdates.first?.fieldsUpdated, ["description"])
        XCTAssertTrue(report.appInfoUpdates.isEmpty)
        XCTAssertNotNil(report.appInfoSkipped)
        if case .noEditableAppInfo = report.appInfoSkipped {
            // expected
        } else {
            XCTFail("expected .noEditableAppInfo, got \(String(describing: report.appInfoSkipped))")
        }
        XCTAssertTrue(
            progressLines.contains { $0.contains("Skipped") && $0.contains("no editable appInfo") },
            "expected a 'Skipped … no editable appInfo' progress line, got: \(progressLines)"
        )
    }

    // MARK: - Categories

    /// Setting `categories.primary` and `categories.secondary` on an app with
    /// no current category assignments PATCHes /v1/appInfos/{id} once with
    /// both relationship slots in a single body.
    func testSubmit_categories_setBoth_patchesOnce() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appInfos") { _ in
            (200, Data(#"{"data":[{"id":"AI-1","type":"appInfos","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        // Current categories: nothing set.
        ASCStub.add(method: "GET", suffix: "/v1/appInfos/AI-1") { _ in
            (200, Data(#"{"data":{"id":"AI-1","type":"appInfos","relationships":{"primaryCategory":{"data":null},"secondaryCategory":{"data":null}}}}"#.utf8))
        }
        let patchBodies = NSMutableArray()
        ASCStub.add(method: "PATCH", suffix: "/v1/appInfos/AI-1") { _ in
            patchBodies.add(ASCStub.requestBodies.last ?? Data())
            return (200, Data(#"{"data":{"id":"AI-1","type":"appInfos","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0", attachBuild: false),
            categories: CategoriesConfig(primary: "EDUCATION", secondary: "REFERENCE")
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(patchBodies.count, 1, "expected exactly one PATCH on /v1/appInfos/{id}")
        let bodyStr = String(data: patchBodies[0] as! Data, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("\"primaryCategory\""), "primaryCategory must be in body: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"EDUCATION\""), "EDUCATION id must be in body: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"secondaryCategory\""), "secondaryCategory must be in body: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"REFERENCE\""), "REFERENCE id must be in body: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"appCategories\""), "category type must be appCategories: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"relationships\""), "PATCH must use relationships block, not attributes: \(bodyStr)")
        XCTAssertNotNil(report.categoriesStatus)
        XCTAssertTrue(report.categoriesStatus?.contains("primary") == true)
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// When current categories already match desired, skip the PATCH and
    /// report `unchanged` so idempotent re-runs are silent.
    func testSubmit_categories_unchanged_skipsPatch() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appInfos") { _ in
            (200, Data(#"{"data":[{"id":"AI-1","type":"appInfos","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        // Current categories already match desired.
        ASCStub.add(method: "GET", suffix: "/v1/appInfos/AI-1") { _ in
            (200, Data(#"{"data":{"id":"AI-1","type":"appInfos","relationships":{"primaryCategory":{"data":{"id":"EDUCATION","type":"appCategories"}},"secondaryCategory":{"data":{"id":"REFERENCE","type":"appCategories"}}}}}"#.utf8))
        }
        var patchHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/appInfos/AI-1") { _ in
            patchHits += 1
            return (200, Data(#"{"data":{"id":"AI-1","type":"appInfos"}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0", attachBuild: false),
            categories: CategoriesConfig(primary: "EDUCATION", secondary: "REFERENCE")
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(patchHits, 0, "matching categories must not re-PATCH")
        XCTAssertEqual(report.categoriesStatus, "unchanged")
    }

    /// `secondary: none` clears the slot via JSON:API `data: null`. Useful
    /// for downgrading a 2-category app to a single primary.
    func testSubmit_categories_clearSecondary_emitsNullData() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appInfos") { _ in
            (200, Data(#"{"data":[{"id":"AI-1","type":"appInfos","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        // Currently has both primary + secondary; we'll keep primary, clear
        // secondary.
        ASCStub.add(method: "GET", suffix: "/v1/appInfos/AI-1") { _ in
            (200, Data(#"{"data":{"id":"AI-1","type":"appInfos","relationships":{"primaryCategory":{"data":{"id":"EDUCATION","type":"appCategories"}},"secondaryCategory":{"data":{"id":"REFERENCE","type":"appCategories"}}}}}"#.utf8))
        }
        let patchBodies = NSMutableArray()
        ASCStub.add(method: "PATCH", suffix: "/v1/appInfos/AI-1") { _ in
            patchBodies.add(ASCStub.requestBodies.last ?? Data())
            return (200, Data(#"{"data":{"id":"AI-1","type":"appInfos"}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0", attachBuild: false),
            categories: CategoriesConfig(primary: "EDUCATION", secondary: "none")
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )
        _ = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(patchBodies.count, 1)
        let bodyStr = String(data: patchBodies[0] as! Data, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyStr.contains("\"primaryCategory\""), "primaryCategory unchanged → must be omitted: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"secondaryCategory\""), "secondaryCategory must be in body: \(bodyStr)")
        // The clear emits `data: null` (no quotes around null), not the
        // string "null".
        XCTAssertTrue(bodyStr.contains("\"secondaryCategory\":{\"data\":null}"),
                      "clear must emit data:null: \(bodyStr)")
    }

    // MARK: - Age rating

    /// Setting one frequency and a boolean: PATCH /v1/ageRatingDeclarations/{id}
    /// with only the changed attributes.
    func testSubmit_ageRating_partialUpdate() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appInfos") { _ in
            (200, Data(#"{"data":[{"id":"AI-1","type":"appInfos","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appInfos/AI-1/ageRatingDeclaration") { _ in
            (200, Data(#"{"data":{"id":"AR-1","type":"ageRatingDeclarations","attributes":{"violenceCartoonOrFantasy":"NONE","gambling":false}}}"#.utf8))
        }
        let patchBodies = NSMutableArray()
        ASCStub.add(method: "PATCH", suffix: "/v1/ageRatingDeclarations/AR-1") { _ in
            patchBodies.add(ASCStub.requestBodies.last ?? Data())
            return (200, Data(#"{"data":{"id":"AR-1","type":"ageRatingDeclarations","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0", attachBuild: false),
            ageRating: AgeRatingConfig(
                cartoonOrFantasyViolence: .infrequentOrMild,
                profanityOrCrudeHumor: .none, // no diff against current default
                gambling: false                // no diff
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(patchBodies.count, 1, "expected one PATCH for the changed field")
        let bodyStr = String(data: patchBodies[0] as! Data, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("\"violenceCartoonOrFantasy\""), "changed field must be sent: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"INFREQUENT_OR_MILD\""), "frequency must be the API enum value: \(bodyStr)")
        // Fields whose desired matches current must not appear in the PATCH.
        XCTAssertFalse(bodyStr.contains("\"profanityOrCrudeHumor\""), "unchanged field must be omitted: \(bodyStr)")
        XCTAssertFalse(bodyStr.contains("\"gambling\""), "unchanged boolean must be omitted: \(bodyStr)")
        XCTAssertNotNil(report.ageRatingStatus)
        XCTAssertTrue(report.ageRatingStatus?.contains("cartoonOrFantasyViolence") == true,
                      "status should mention the changed field, got: \(report.ageRatingStatus ?? "nil")")
    }

    /// All age-rating fields match the current declaration: skip the PATCH
    /// entirely and report `unchanged`.
    func testSubmit_ageRating_unchanged_skipsPatch() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appInfos") { _ in
            (200, Data(#"{"data":[{"id":"AI-1","type":"appInfos","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appInfos/AI-1/ageRatingDeclaration") { _ in
            (200, Data(#"{"data":{"id":"AR-1","type":"ageRatingDeclarations","attributes":{"violenceCartoonOrFantasy":"NONE","gambling":false}}}"#.utf8))
        }
        var patchHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/ageRatingDeclarations/AR-1") { _ in
            patchHits += 1
            return (200, Data(#"{"data":{"id":"AR-1","type":"ageRatingDeclarations"}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0", attachBuild: false),
            ageRating: AgeRatingConfig(
                cartoonOrFantasyViolence: .none,
                gambling: false
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(patchHits, 0, "no diff → no PATCH")
        XCTAssertEqual(report.ageRatingStatus, "unchanged")
    }

    // MARK: - Review info via YAML

    /// `review_info:` YAML block applied with no metadata directory: still
    /// hits `appStoreReviewDetails` (or creates one), driven entirely by
    /// the YAML.
    func testSubmit_reviewInfo_yaml_appliedWithoutMetadataDir() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        // No existing review-detail; we expect a POST to create one.
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreReviewDetail") { _ in
            (404, Data(#"{"errors":[{"code":"NOT_FOUND","title":"not found","detail":"no review detail"}]}"#.utf8))
        }
        let postBodies = NSMutableArray()
        ASCStub.add(method: "POST", suffix: "/v1/appStoreReviewDetails") { _ in
            postBodies.add(ASCStub.requestBodies.last ?? Data())
            return (201, Data(#"{"data":{"id":"RD-1","type":"appStoreReviewDetails"}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.0", attachBuild: false),
            reviewInfo: ReviewInfoConfig(
                firstName: "Jane",
                lastName: "Doe",
                phoneNumber: "+1 555 123 4567",
                emailAddress: "jane@example.com",
                notes: "Hi reviewer."
            )
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "t",
            appName: "a", displayName: nil, scheme: "s", devices: []
        )
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: URL(fileURLWithPath: "/tmp"),
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )

        XCTAssertEqual(postBodies.count, 1, "expected one POST creating the review-detail record")
        let bodyStr = String(data: postBodies[0] as! Data, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("\"contactFirstName\":\"Jane\""))
        XCTAssertTrue(bodyStr.contains("\"contactLastName\":\"Doe\""))
        XCTAssertTrue(bodyStr.contains("\"contactEmail\":\"jane@example.com\""))
        XCTAssertTrue(bodyStr.contains("\"notes\":\"Hi reviewer.\""))
        XCTAssertTrue(report.reviewDetailUpdated)
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }
}
