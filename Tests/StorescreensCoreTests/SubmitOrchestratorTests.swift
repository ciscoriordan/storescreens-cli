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

    func testSubmit_submitForReview_reviewSubmissionsFlow() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"name":"A","bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","platform":"IOS"}}]}"#.utf8))
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

        XCTAssertEqual(createHits, 1, "POST /reviewSubmissions once")
        XCTAssertEqual(itemHits, 1, "POST /reviewSubmissionItems once to attach version")
        XCTAssertEqual(finalizeHits, 1, "PATCH /reviewSubmissions/{id} once to set submitted:true")
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-1")
        XCTAssertTrue(report.errors.isEmpty)
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
}
