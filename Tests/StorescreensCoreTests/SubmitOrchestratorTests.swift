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

/// Collects `progress` lines from the orchestrator.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
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

    /// Stubs `POST /v1/appScreenshotSets` the way App Store Connect behaves:
    /// a `screenshotDisplayType` outside the OpenAPI enum gets a 409
    /// ENTITY_ERROR.ATTRIBUTE.TYPE, so an invalid value can never pass a
    /// test silently. `setID` names the created set from its display type.
    private func addScreenshotSetCreateStub(setID: @escaping @Sendable (String) -> String = { "SET-\($0)" }) {
        ASCStub.add(method: "POST", suffix: "/v1/appScreenshotSets") { _ in
            let body = ASCStub.requestBodies.last ?? Data()
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let attrs = (parsed?["data"] as? [String: Any])?["attributes"] as? [String: Any]
            let displayType = attrs?["screenshotDisplayType"] as? String ?? ""
            guard ASCOpenAPIScreenshotDisplayTypes.all.contains(displayType) else {
                let error = #"{"errors":[{"status":"409","code":"ENTITY_ERROR.ATTRIBUTE.TYPE","title":"An attribute value has an invalid type.","detail":"'\#(displayType)' is not a valid value for the attribute 'screenshotDisplayType'.","source":{"pointer":"/data/attributes/screenshotDisplayType"}}]}"#
                return (409, Data(error.utf8))
            }
            let json = #"{"data":{"id":"\#(setID(displayType))","type":"appScreenshotSets","attributes":{"screenshotDisplayType":"\#(displayType)"}}}"#
            return (201, Data(json.utf8))
        }
    }

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

        // Write 2 iPhone 6.9 PNGs at 1320x2868 (the 6.9" class, which App
        // Store Connect calls APP_IPHONE_67).
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
        addScreenshotSetCreateStub(setID: { _ in "SET-1" })
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
        // 1320x2868 (iPhone 18 Pro Max / 17 Pro Max) is the 6.9" class,
        // APP_IPHONE_67 in the API.
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

    /// When creating a brand-new `appStoreReviewDetails` record without any
    /// demo-account fields configured, the orchestrator must explicitly send
    /// `demoAccountRequired: false`. Apple's ASC API otherwise defaults the
    /// field to `true` on creation, which leaves "Sign-In Required" checked
    /// in the App Review Information panel for apps that don't need a login.
    func testSubmit_reviewDetail_createsWithDemoAccountRequiredFalseWhenNoCreds() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-review-no-demo-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("English description", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        // Only a single review-side file. No demo account name/password,
        // no review_demo_account_required (which doesn't exist as a file).
        try writeFixture("contact me at the email below", to: metaRoot.appendingPathComponent("en-US/review_notes.txt"))
        try writeFixture("cisco@example.com", to: metaRoot.appendingPathComponent("en-US/review_contact_email.txt"))

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
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
        // Parse the JSON body and inspect attributes.demoAccountRequired so
        // we don't depend on key ordering or whitespace.
        let json = try JSONSerialization.jsonObject(with: createBody!) as? [String: Any]
        let data = json?["data"] as? [String: Any]
        let attrs = data?["attributes"] as? [String: Any]
        XCTAssertEqual(
            attrs?["demoAccountRequired"] as? Bool, false,
            "create body must explicitly send demoAccountRequired: false when no demo creds are configured (raw body: \(bodyStr))"
        )
        // Sanity: demo creds must NOT have appeared in the body since none
        // were configured.
        XCTAssertNil(attrs?["demoAccountName"],
                     "must not send demoAccountName when none configured: \(bodyStr)")
        XCTAssertNil(attrs?["demoAccountPassword"],
                     "must not send demoAccountPassword when none configured: \(bodyStr)")
        XCTAssertTrue(report.reviewDetailUpdated)
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// When demo creds ARE configured (via YAML's review_info), the
    /// `asReviewDetailFields` helper sets `demoAccountRequired: true`. The
    /// orchestrator's no-creds override must NOT clobber that value back
    /// to `false` on the create-side path.
    func testSubmit_reviewDetail_createPreservesDemoAccountRequiredTrueFromYAML() async throws {
        let (client, _) = makeClient()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("submit-review-with-demo-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let metaRoot = tmp.appendingPathComponent("metadata")
        try writeFixture("desc", to: metaRoot.appendingPathComponent("en-US/description.txt"))
        // File-side demo creds — `asReviewDetailFields` would normally
        // promote demoAccountRequired to true via the YAML helper, but the
        // file-side reader only writes the name/password fields. The
        // orchestrator must still leave the create body alone here (since
        // demo fields are non-nil, the no-creds override doesn't kick in).
        try writeFixture("demo@example.com", to: metaRoot.appendingPathComponent("en-US/review_demo_account_name.txt"))
        try writeFixture("hunter2", to: metaRoot.appendingPathComponent("en-US/review_demo_account_password.txt"))

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreReviewDetail") { _ in
            (200, Data(#"{"data":null}"#.utf8))
        }
        var createBody: Data?
        ASCStub.add(method: "POST", suffix: "/v1/appStoreReviewDetails") { _ in
            createBody = ASCStub.requestBodies.last
            return (201, Data(#"{"data":{"id":"RD-1","type":"appStoreReviewDetails","attributes":{}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, Data(#"{"data":[{"id":"LOC-en-US","type":"appStoreVersionLocalizations","attributes":{"locale":"en-US"}}]}"#.utf8))
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

        _ = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: tmp,
            metadataRoot: metaRoot,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: true,
            progress: nil
        )

        let bodyStr = String(data: createBody!, encoding: .utf8) ?? ""
        let json = try JSONSerialization.jsonObject(with: createBody!) as? [String: Any]
        let attrs = (json?["data"] as? [String: Any])?["attributes"] as? [String: Any]
        // The demo creds were supplied, so the no-creds override must not
        // force demoAccountRequired to false. Both demo fields must appear
        // in the body.
        XCTAssertEqual(attrs?["demoAccountName"] as? String, "demo@example.com",
                       "demoAccountName must be sent: \(bodyStr)")
        XCTAssertEqual(attrs?["demoAccountPassword"] as? String, "hunter2",
                       "demoAccountPassword must be sent: \(bodyStr)")
        XCTAssertNotEqual(attrs?["demoAccountRequired"] as? Bool, false,
                          "demoAccountRequired must NOT be forced to false when demo creds are present: \(bodyStr)")
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

    /// `READY_FOR_REVIEW` stale draft that holds a DIFFERENT version
    /// (a sibling submission for some other version that's still
    /// blocking us) gets cancelled and a fresh submission is created
    /// for our version. Same mechanism as UNRESOLVED_ISSUES.
    func testSubmit_submitForReview_cancelsStaleDraftWithDifferentVersion() async throws {
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
        // Items on the stale draft point at a DIFFERENT version, so the
        // orchestrator must cancel-and-recreate rather than adopting.
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-STALE/items") { _ in
            (200, Data(#"{"data":[{"id":"RI-OLD","type":"reviewSubmissionItems","relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"VER-OTHER"}}}}]}"#.utf8))
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

        XCTAssertTrue(staleCanceled, "stale READY_FOR_REVIEW with another version must be canceled")
        XCTAssertEqual(report.canceledReviewSubmissionIDs, ["RSUB-STALE"])
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-NEW")
        XCTAssertNil(report.adoptedReviewSubmissionID,
                     "fresh submission, nothing was adopted")
    }

    /// The bug-report scenario, common case: a prior submit run created
    /// a `reviewSubmission` and POST item failed (e.g. build wasn't VALID
    /// yet), leaving an empty `READY_FOR_REVIEW` draft. The cleanup
    /// must adopt that draft (attach our version + finalize) instead of
    /// trying to cancel it - Apple refuses to cancel an empty submission
    /// AND refuses to cancel a draft once items are attached, so the only
    /// way out is the finalize path.
    func testSubmit_submitForReview_adoptsEmptyReadyForReviewDraft() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[{"id":"RSUB-EMPTY","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}]}"#.utf8))
        }
        // Empty items: this is the orphan-from-prior-failed-run state.
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-EMPTY/items") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        // Attach must hit the adopted draft, NOT a fresh one. Capture
        // the body so we can verify the reviewSubmission relationship.
        var attachBody: Data?
        var attachHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            attachHits += 1
            attachBody = ASCStub.requestBodies.last
            return (201, Data(#"{"data":{"id":"RI-NEW","type":"reviewSubmissionItems"}}"#.utf8))
        }
        // Finalize via PATCH submitted:true on the adopted draft.
        var finalizeBody: Data?
        var finalizeHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-EMPTY") { _ in
            finalizeHits += 1
            finalizeBody = ASCStub.requestBodies.last
            return (200, Data(#"{"data":{"id":"RSUB-EMPTY","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
        }
        // Cancel and POST create must NOT be called.
        var cancelHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            cancelHits += 1
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

        XCTAssertEqual(attachHits, 1, "must attach version to the adopted draft")
        XCTAssertEqual(finalizeHits, 1, "must PATCH submitted:true on the adopted draft")
        XCTAssertEqual(cancelHits, 0, "must NOT POST a fresh reviewSubmission when adopting")
        let attachStr = String(data: attachBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(attachStr.contains("\"id\":\"RSUB-EMPTY\""),
                      "attach must target the adopted draft, got: \(attachStr)")
        let finalizeStr = String(data: finalizeBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(finalizeStr.contains("\"submitted\":true"),
                      "finalize must send submitted:true, got: \(finalizeStr)")
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-EMPTY")
        XCTAssertEqual(report.adoptedReviewSubmissionID, "RSUB-EMPTY")
        XCTAssertEqual(report.reviewSubmissionState, "WAITING_FOR_REVIEW")
        XCTAssertTrue(report.canceledReviewSubmissionIDs.isEmpty,
                      "adoption is not a cancel; canceledReviewSubmissionIDs stays empty")
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// The bug-report scenario, recovery case: a prior aborted submit
    /// already attached the version to the draft (e.g. the user re-ran
    /// once after hitting the bug and the unstick-attach succeeded but
    /// the second cancel failed). Cleanup now sees the draft with our
    /// version attached and just finalizes it - no attach, no cancel.
    func testSubmit_submitForReview_adoptsDraftWithOurVersionAlreadyAttached() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[{"id":"RSUB-ADOPT","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-ADOPT/items") { _ in
            (200, Data(#"{"data":[{"id":"RI-EXIST","type":"reviewSubmissionItems","relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"VER-1"}}}}]}"#.utf8))
        }
        var attachHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            attachHits += 1
            return (201, Data(#"{"data":{"id":"RI-NEW","type":"reviewSubmissionItems"}}"#.utf8))
        }
        var createHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            createHits += 1
            return (201, Data(#"{"data":{"id":"X","type":"reviewSubmissions","attributes":{}}}"#.utf8))
        }
        var finalizeBody: Data?
        var finalizeHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-ADOPT") { _ in
            finalizeHits += 1
            finalizeBody = ASCStub.requestBodies.last
            return (200, Data(#"{"data":{"id":"RSUB-ADOPT","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
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

        XCTAssertEqual(attachHits, 0,
                       "version already attached; must NOT re-POST reviewSubmissionItems")
        XCTAssertEqual(createHits, 0,
                       "must NOT create a fresh reviewSubmission when one already owns our version")
        XCTAssertEqual(finalizeHits, 1, "must PATCH submitted:true on the adopted draft")
        let finalizeStr = String(data: finalizeBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(finalizeStr.contains("\"submitted\":true"),
                      "finalize must send submitted:true, got: \(finalizeStr)")
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-ADOPT")
        XCTAssertEqual(report.adoptedReviewSubmissionID, "RSUB-ADOPT")
        XCTAssertEqual(report.reviewSubmissionState, "WAITING_FOR_REVIEW")
        XCTAssertTrue(report.canceledReviewSubmissionIDs.isEmpty)
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// Eventual-consistency edge case: items list reports empty, so we
    /// pick the adopt-empty branch and POST item, but Apple replies 409
    /// `ENTITY_ERROR.RELATIONSHIP.INVALID.NOT_ALLOWED` "already added to
    /// this reviewSubmission". The orchestrator treats it as success and
    /// proceeds to finalize.
    func testSubmit_submitForReview_adoptsEmptyDraft_attachAlreadyAttachedTreatedAsSuccess() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[{"id":"RSUB-EMPTY","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-EMPTY/items") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        // Attach returns 409 with the "already added to this reviewSubmission"
        // wording. Real wire shape from Apple.
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            let body = #"{"errors":[{"id":"X","status":"409","code":"ENTITY_ERROR.RELATIONSHIP.INVALID.NOT_ALLOWED","title":"The provided entity includes a relationship with an invalid value","detail":"The appStoreVersion VER-1 was already added to this reviewSubmission."}]}"#
            return (409, Data(body.utf8))
        }
        var finalizeHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-EMPTY") { _ in
            finalizeHits += 1
            return (200, Data(#"{"data":{"id":"RSUB-EMPTY","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
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

        XCTAssertEqual(finalizeHits, 1,
                       "must still finalize even when attach reports already-attached")
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-EMPTY")
        XCTAssertEqual(report.adoptedReviewSubmissionID, "RSUB-EMPTY")
        XCTAssertEqual(report.reviewSubmissionState, "WAITING_FOR_REVIEW")
        XCTAssertTrue(report.errors.isEmpty,
                      "already-attached must not be surfaced as an error: \(report.errors)")
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
        // RSUB-A is UNRESOLVED_ISSUES so items are not consulted.
        // RSUB-B is a READY_FOR_REVIEW draft holding a DIFFERENT version,
        // so it routes to must-cancel rather than adoption.
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions/RSUB-B/items") { _ in
            (200, Data(#"{"data":[{"id":"RI-X","type":"reviewSubmissionItems","relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"VER-OTHER"}}}}]}"#.utf8))
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

    // MARK: - Submit for review: wait-for-build

    /// When attach_build and submit_for_review are both true and the
    /// first `latestValidBuild` lookup finds no VALID build yet, the
    /// orchestrator polls. As soon as a VALID build appears the attach
    /// proceeds and the submission goes through normally. Submitting
    /// against a build-less version is exactly what leaves an empty
    /// reviewSubmission orphan behind, so waiting is the cheaper fix.
    func testSubmit_submitForReview_waitsForBuildToProcess() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        // First two /builds calls report no VALID build, the third returns
        // VALID. The orchestrator should poll until VALID appears.
        let buildHits = Counter()
        ASCStub.add(method: "GET", suffix: "/v1/builds") { _ in
            let n = buildHits.increment()
            if n < 3 {
                return (200, Data(#"{"data":[{"id":"BLD-1","type":"builds","attributes":{"version":"1","processingState":"PROCESSING"}}]}"#.utf8))
            }
            return (200, Data(#"{"data":[{"id":"BLD-1","type":"builds","attributes":{"version":"1","processingState":"VALID"}}]}"#.utf8))
        }
        var attachBuildHits = 0
        ASCStub.add(method: "PATCH", suffix: "/v1/appStoreVersions/VER-1") { _ in
            attachBuildHits += 1
            return (200, Data(#"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{}}}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/builds/BLD-1") { _ in
            (200, Data(#"{"data":{"id":"BLD-1","type":"builds","attributes":{}}}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            (201, Data(#"{"data":{"id":"RSUB-1","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            (201, Data(#"{"data":{"id":"RI-1","type":"reviewSubmissionItems"}}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-1") { _ in
            (200, Data(#"{"data":{"id":"RSUB-1","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.0.0",
                submitForReview: true,
                attachBuild: true
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 0,
            buildWaitInterval: 0, buildWaitMaxAttempts: 10
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

        XCTAssertEqual(attachBuildHits, 1,
                       "must attach the build once it finishes processing")
        XCTAssertEqual(report.attachedBuildNumber, "1")
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-1")
        XCTAssertEqual(report.reviewSubmissionState, "WAITING_FOR_REVIEW")
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
    }

    /// When the build never goes VALID within the wait budget, the
    /// orchestrator gives up, surfaces the no-VALID-build error, and
    /// MUST NOT proceed to runSubmitForReview - creating a reviewSubmission
    /// against a build-less version is the exact thing that leaves the
    /// empty draft orphan behind.
    func testSubmit_submitForReview_buildWaitTimeoutSkipsRunSubmitForReview() async throws {
        let (client, _) = makeClient()

        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.0.0","platform":"IOS"}}]}"#.utf8))
        }
        // /builds always returns no VALID build (everything is still
        // PROCESSING). Wait must time out.
        ASCStub.add(method: "GET", suffix: "/v1/builds") { _ in
            (200, Data(#"{"data":[{"id":"BLD-1","type":"builds","attributes":{"version":"1","processingState":"PROCESSING"}}]}"#.utf8))
        }
        var listReviewHits = 0
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            listReviewHits += 1
            return (200, Data(#"{"data":[]}"#.utf8))
        }
        var createReviewHits = 0
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            createReviewHits += 1
            return (201, Data(#"{"data":{"id":"BAD","type":"reviewSubmissions","attributes":{}}}"#.utf8))
        }

        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.0.0",
                submitForReview: true,
                attachBuild: true
            )
        )
        let orchestrator = SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 0,
            buildWaitInterval: 0, buildWaitMaxAttempts: 3
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

        XCTAssertNil(report.attachedBuildNumber)
        XCTAssertNil(report.reviewSubmissionID,
                     "must NOT create a reviewSubmission when no build was attached")
        XCTAssertEqual(listReviewHits, 0,
                       "cleanup phase must not even list submissions when the build timed out")
        XCTAssertEqual(createReviewHits, 0,
                       "creating an empty reviewSubmission is the exact bug we're avoiding")
        XCTAssertTrue(
            report.errors.contains { $0.contains("no VALID build") },
            "expected the no-VALID-build error, got: \(report.errors)"
        )
        XCTAssertTrue(
            report.errors.contains { $0.contains("submit for review: skipped") },
            "expected an explicit submit-for-review-skipped error, got: \(report.errors)"
        )
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

    /// A `pricing:` block with neither `free: true` nor a `base_price` is
    /// invalid — surface a clear error rather than silently skipping.
    func testSubmit_pricing_noDirective_reportsError() async throws {
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

        XCTAssertTrue(report.errors.contains { $0.contains("base_price") },
                      "must point the user at free/base_price, got: \(report.errors)")
        XCTAssertNil(report.pricingStatus)
    }

    /// Paid pricing with a per-territory override: resolve the base price and
    /// each override to the nearest tier, then POST one schedule whose manual
    /// prices cover both territories. The base territory anchors equivalencing
    /// for everything not listed.
    func testSubmit_pricing_paidWithTerritoryOverride_createsSchedule() async throws {
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
        // Territory-specific ladders: branch on the filter[territory] value so
        // USA and GBR resolve to distinct tier IDs.
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appPricePoints") { request in
            let isGBR = request.url?.absoluteString.contains("=GBR") ?? false
            let body = isGBR ? """
            {"data":[
              {"id":"PP-GBR-399","type":"appPricePoints","attributes":{"customerPrice":"3.99","proceeds":"2.79"}},
              {"id":"PP-GBR-499","type":"appPricePoints","attributes":{"customerPrice":"4.99","proceeds":"3.49"}}
            ]}
            """ : """
            {"data":[
              {"id":"PP-USA-399","type":"appPricePoints","attributes":{"customerPrice":"3.99","proceeds":"2.79"}},
              {"id":"PP-USA-499","type":"appPricePoints","attributes":{"customerPrice":"4.99","proceeds":"3.49"}}
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
            pricing: PricingConfig(baseTerritory: "USA", basePrice: "4.99", territoryPrices: ["GBR": "3.99"])
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
        XCTAssertTrue(bodyStr.contains("\"PP-USA-499\""), "base USA tier must be in the POST body: \(bodyStr)")
        XCTAssertTrue(bodyStr.contains("\"PP-GBR-399\""), "GBR override tier must be in the POST body: \(bodyStr)")
        XCTAssertEqual(report.pricingStatus, "paid (base: USA @ 4.99, 1 territory override(s))")
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
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

    // MARK: - Screenshot sets: display types, iPhone Duo, one device per set

    /// Stubs everything a screenshots-only submit touches for an existing
    /// app (APP-1), version (VER-1) and one localization per locale
    /// (LOC-<locale>), with no screenshot sets yet. Sets are created through
    /// `addScreenshotSetCreateStub` (id SET-<displayType>), and up to
    /// `maxUploads` screenshots can go through reserve, chunk upload and
    /// confirm.
    private func stubScreenshotOnlySubmit(locales: [String], maxUploads: Int) {
        ASCStub.add(method: "GET", suffix: "/v1/apps") { _ in
            (200, Data(#"{"data":[{"id":"APP-1","type":"apps","attributes":{"bundleId":"com.example.app"}}]}"#.utf8))
        }
        ASCStub.add(method: "GET", suffix: "/v1/apps/APP-1/appStoreVersions") { _ in
            (200, Data(#"{"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","platform":"IOS"}}]}"#.utf8))
        }
        let localizations = locales
            .map { #"{"id":"LOC-\#($0)","type":"appStoreVersionLocalizations","attributes":{"locale":"\#($0)"}}"# }
            .joined(separator: ",")
        ASCStub.add(method: "GET", suffix: "/v1/appStoreVersions/VER-1/appStoreVersionLocalizations") { _ in
            (200, Data(#"{"data":[\#(localizations)]}"#.utf8))
        }
        for locale in locales {
            ASCStub.add(method: "GET", suffix: "/appStoreVersionLocalizations/LOC-\(locale)/appScreenshotSets") { _ in
                (200, Data(#"{"data":[]}"#.utf8))
            }
        }
        addScreenshotSetCreateStub()
        // Every new set starts empty.
        ASCStub.add(method: "GET", suffix: "/appScreenshots") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        let shotCounter = Counter()
        ASCStub.add(method: "POST", suffix: "/v1/appScreenshots") { _ in
            let n = shotCounter.increment()
            let body = """
            {"data":{"id":"SHOT-\(n)","type":"appScreenshots","attributes":{"fileSize":1,"fileName":"x.png","uploadOperations":[{"method":"PUT","url":"https://upload.example.com/chunk-\(n)","length":0,"offset":0,"requestHeaders":[]}]}}}
            """
            return (201, Data(body.utf8))
        }
        for n in 1...max(maxUploads, 1) {
            ASCStub.add(method: "PUT", suffix: "chunk-\(n)") { _ in (200, Data()) }
            ASCStub.add(method: "PATCH", suffix: "/v1/appScreenshots/SHOT-\(n)") { _ in
                (200, Data(#"{"data":{"id":"SHOT-\#(n)","type":"appScreenshots","attributes":{}}}"#.utf8))
            }
        }
    }

    /// (set id, file name) of every screenshot reservation, in request order.
    private func reservedUploads() -> [(set: String, fileName: String)] {
        zip(ASCStub.requests, ASCStub.requestBodies).compactMap { request, body in
            guard request.httpMethod == "POST",
                  request.url?.path.hasSuffix("/v1/appScreenshots") == true,
                  let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let data = parsed["data"] as? [String: Any],
                  let attrs = data["attributes"] as? [String: Any],
                  let fileName = attrs["fileName"] as? String,
                  let rels = data["relationships"] as? [String: Any],
                  let setRel = rels["appScreenshotSet"] as? [String: Any],
                  let setData = setRel["data"] as? [String: Any],
                  let setID = setData["id"] as? String
            else { return nil }
            return (setID, fileName)
        }
    }

    /// Display types sent to `POST /v1/appScreenshotSets`, in request order.
    private func createdSetDisplayTypes() -> [String] {
        zip(ASCStub.requests, ASCStub.requestBodies).compactMap { request, body in
            guard request.httpMethod == "POST",
                  request.url?.path.hasSuffix("/v1/appScreenshotSets") == true,
                  let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let data = parsed["data"] as? [String: Any],
                  let attrs = data["attributes"] as? [String: Any]
            else { return nil }
            return attrs["screenshotDisplayType"] as? String
        }
    }

    private func makeRenderRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes `png` under `root` at each relative path, creating folders.
    private func writePNGs(_ png: Data, to root: URL, _ paths: [String]) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
        }
    }

    private func device(
        _ deviceType: String, _ simulatorName: String,
        locale: String = "en-US", appearance: String? = nil, files: [String]
    ) -> CaptureManifest.DeviceCapture {
        CaptureManifest.DeviceCapture(
            deviceType: deviceType, simulatorName: simulatorName,
            locale: locale, appearance: appearance,
            screenshots: files.map { .init(name: $0, filename: $0, capturedAt: Date()) }
        )
    }

    private func manifest(_ devices: [CaptureManifest.DeviceCapture]) -> CaptureManifest {
        CaptureManifest(
            version: 2, generatedAt: Date(), generatedBy: "t",
            appName: "App", displayName: nil, scheme: "App", devices: devices
        )
    }

    private func screenshotsOnly(_ client: ASCClient, _ config: AppStoreConnectConfig, manifest: CaptureManifest, renderRoot: URL, progress: ((String) -> Void)? = nil) async throws -> SubmitOrchestrator.Report {
        try await SubmitOrchestrator(client: client, config: config).submit(
            manifest: manifest,
            renderRoot: renderRoot,
            metadataRoot: nil,
            shouldUploadScreenshots: true,
            shouldUploadMetadata: false,
            progress: progress
        )
    }

    /// The stub itself must reject values App Store Connect rejects, or the
    /// tests below prove nothing.
    func testScreenshotSetStub_rejectsValuesOutsideTheEnum() async throws {
        let (client, _) = makeClient()
        addScreenshotSetCreateStub()
        let api = ScreenshotsAPI(client: client)
        do {
            _ = try await api.createScreenshotSet(localizationID: "LOC-en-US", displayType: "APP_IPHONE_63")
            XCTFail("APP_IPHONE_63 is not an App Store Connect value; the stub must answer 409")
        } catch let error as ASCClient.APIError {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.details.first?.code, "ENTITY_ERROR.ATTRIBUTE.TYPE")
        }
        let set = try await api.createScreenshotSet(localizationID: "LOC-en-US", displayType: "APP_IPHONE_61")
        XCTAssertEqual(set.id, "SET-APP_IPHONE_61")
    }

    /// iPhone 18 Pro (1206x2622) is in the 6.3" class, APP_IPHONE_61. The
    /// old table sent APP_IPHONE_63, which App Store Connect rejects.
    func testSubmit_iPhone18Pro_uploadsUnderAPP_IPHONE_61() async throws {
        let (client, config) = makeClient()
        let renderRoot = try makeRenderRoot("submit-18pro")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        try writePNGs(makePNG(w: 1206, h: 2622), to: renderRoot, ["en-US/18pro_01.png", "en-US/18pro_02.png"])
        stubScreenshotOnlySubmit(locales: ["en-US"], maxUploads: 2)

        let report = try await screenshotsOnly(client, config, manifest: manifest([
            device("iPhone 6.3\"", "iPhone 18 Pro", files: ["en-US/18pro_01.png", "en-US/18pro_02.png"]),
        ]), renderRoot: renderRoot)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(createdSetDisplayTypes(), ["APP_IPHONE_61"])
        XCTAssertEqual(report.screenshotUploads.map(\.displayType), ["APP_IPHONE_61"])
        XCTAssertEqual(report.screenshotUploads.first?.count, 2)
        XCTAssertEqual(reservedUploads().map(\.set), ["SET-APP_IPHONE_61", "SET-APP_IPHONE_61"])
        XCTAssertTrue(report.screenshotsSkipped.isEmpty)
    }

    /// iPhone Duo sizes are on Apple's specifications page but the API has
    /// no display type for them yet. They are skipped with one line per
    /// device and locale, the rest of the upload goes ahead, and nothing
    /// lands in `errors` (so the CLI exits 0 and submit-for-review still
    /// runs).
    func testSubmit_iPhoneDuoSkippedWithNotice_69SetStillUploads() async throws {
        let (client, config) = makeClient()
        let renderRoot = try makeRenderRoot("submit-duo")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        let proMax = makePNG(w: 1320, h: 2868)
        let duoInner = makePNG(w: 2007, h: 2853)
        let duoInnerLandscape = makePNG(w: 2853, h: 2007)
        for locale in ["en-US", "ja"] {
            try writePNGs(proMax, to: renderRoot, ["\(locale)/max_01.png", "\(locale)/max_02.png"])
            try writePNGs(duoInner, to: renderRoot, ["\(locale)/duo_01.png", "\(locale)/duo_02.png"])
            try writePNGs(duoInnerLandscape, to: renderRoot, ["\(locale)/duo_03.png"])
        }
        stubScreenshotOnlySubmit(locales: ["en-US", "ja"], maxUploads: 4)

        let lines = LineCollector()
        let report = try await screenshotsOnly(client, config, manifest: manifest([
            device("iPhone 6.9\"", "iPhone 18 Pro Max", files: ["en-US/max_01.png", "en-US/max_02.png"]),
            device("iPhone 2007x2853", "iPhone Duo", files: ["en-US/duo_01.png", "en-US/duo_02.png", "en-US/duo_03.png"]),
            device("iPhone 6.9\"", "iPhone 18 Pro Max", locale: "ja", files: ["ja/max_01.png", "ja/max_02.png"]),
            device("iPhone 2007x2853", "iPhone Duo", locale: "ja", files: ["ja/duo_01.png", "ja/duo_02.png", "ja/duo_03.png"]),
        ]), renderRoot: renderRoot, progress: { lines.append($0) })

        XCTAssertTrue(report.errors.isEmpty, "Duo screenshots must not be errors: \(report.errors)")
        XCTAssertEqual(createdSetDisplayTypes(), ["APP_IPHONE_67", "APP_IPHONE_67"])
        XCTAssertEqual(report.screenshotUploads.map(\.locale), ["en-US", "ja"])
        XCTAssertEqual(report.screenshotUploads.map(\.count), [2, 2])
        XCTAssertFalse(reservedUploads().contains { $0.fileName.hasPrefix("duo_") }, "Duo files must not be uploaded")

        XCTAssertEqual(report.screenshotsSkipped, [
            .init(locale: "en-US", device: "iPhone Duo", count: 3, reason: .awaitingUploadSupport(screens: ["iPhone Duo inner display"])),
            .init(locale: "ja", device: "iPhone Duo", count: 3, reason: .awaitingUploadSupport(screens: ["iPhone Duo inner display"])),
        ])
        // One line per device and locale, not one per file.
        let duoLines = lines.all.filter { $0.contains("iPhone Duo") }
        XCTAssertEqual(duoLines.count, 2, "got: \(duoLines)")
        XCTAssertTrue(duoLines.allSatisfy { $0.contains("does not accept iPhone Duo screenshots yet") && $0.contains("later this year") }, "got: \(duoLines)")
        XCTAssertTrue(duoLines[0].hasPrefix("en-US iPhone Duo:"), "got: \(duoLines[0])")
        XCTAssertTrue(duoLines[1].hasPrefix("ja iPhone Duo:"), "got: \(duoLines[1])")
    }

    /// iPhone 17 Pro and iPhone 18 Pro both land in APP_IPHONE_61, at the
    /// same pixel size (1206x2622). The set is wiped and refilled, so merging
    /// both devices would upload two copies of every screen. With equal
    /// screens the device listed first is uploaded (with all of its
    /// appearances, in manifest order), and one notice names the device left
    /// out and says why.
    func testSubmit_twoSameSizeDevicesInOneSet_uploadsOnlyTheOneListedFirst() async throws {
        let (client, config) = makeClient()
        let renderRoot = try makeRenderRoot("submit-same-slot")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        try writePNGs(makePNG(w: 1206, h: 2622), to: renderRoot, [
            "en-US/light/17pro_01.png", "en-US/light/17pro_02.png", "en-US/dark/17pro_01.png",
            "en-US/light/18pro_01.png", "en-US/light/18pro_02.png",
        ])
        stubScreenshotOnlySubmit(locales: ["en-US"], maxUploads: 5)

        let lines = LineCollector()
        // Order as a sequential capture writes it: every device's light
        // entry, then every device's dark entry.
        let report = try await screenshotsOnly(client, config, manifest: manifest([
            device("iPhone 6.3\"", "iPhone 17 Pro", appearance: "light", files: ["en-US/light/17pro_01.png", "en-US/light/17pro_02.png"]),
            device("iPhone 6.3\"", "iPhone 18 Pro", appearance: "light", files: ["en-US/light/18pro_01.png", "en-US/light/18pro_02.png"]),
            device("iPhone 6.3\"", "iPhone 17 Pro", appearance: "dark", files: ["en-US/dark/17pro_01.png"]),
        ]), renderRoot: renderRoot, progress: { lines.append($0) })

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(createdSetDisplayTypes(), ["APP_IPHONE_61"])
        XCTAssertEqual(reservedUploads().map(\.fileName), ["17pro_01.png", "17pro_02.png", "17pro_01.png"])
        let uploadedPaths = lines.all.filter { $0.hasPrefix("en-US APP_IPHONE_61: uploading ") }
        XCTAssertEqual(uploadedPaths, [
            "en-US APP_IPHONE_61: uploading en-US/light/17pro_01.png",
            "en-US APP_IPHONE_61: uploading en-US/light/17pro_02.png",
            "en-US APP_IPHONE_61: uploading en-US/dark/17pro_01.png",
        ])
        XCTAssertEqual(report.screenshotUploads.first?.count, 3)
        XCTAssertEqual(report.screenshotsSkipped, [
            .init(locale: "en-US", device: "iPhone 18 Pro", count: 2,
                  reason: .sameSizeClass(displayType: "APP_IPHONE_61", uploadedDevice: "iPhone 17 Pro")),
        ])
        let notices = lines.all.filter { $0.contains("left out") }
        XCTAssertEqual(notices.count, 1, "got: \(lines.all)")
        XCTAssertEqual(notices.first, "APP_IPHONE_61 (en-US): uploading iPhone 17 Pro screenshots only (tied for the largest screen in the class, listed first); left out iPhone 18 Pro (same App Store size class, and App Store Connect keeps one screenshot set per size class and locale).")
    }

    /// App Store Connect keeps at most 10 screenshots per set. A group over
    /// the limit is an error before any call touches the set, instead of
    /// wiping the set and failing on the 11th upload.
    func testSubmit_moreThanTenInOneSet_errorsWithoutTouchingTheSet() async throws {
        let (client, config) = makeClient()
        let renderRoot = try makeRenderRoot("submit-too-many")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        let files = (1...11).map { String(format: "en-US/max_%02d.png", $0) }
        try writePNGs(makePNG(w: 1320, h: 2868), to: renderRoot, files)
        stubScreenshotOnlySubmit(locales: ["en-US"], maxUploads: 11)

        let report = try await screenshotsOnly(client, config, manifest: manifest([
            device("iPhone 6.9\"", "iPhone 18 Pro Max", files: files),
        ]), renderRoot: renderRoot)

        XCTAssertEqual(report.errors.count, 1, "got: \(report.errors)")
        XCTAssertTrue(report.errors.first?.contains("11 screenshots from iPhone 18 Pro Max") == true, "got: \(report.errors)")
        XCTAssertTrue(report.screenshotUploads.isEmpty)
        let setCalls = ASCStub.requests.filter { $0.url?.path.contains("appScreenshot") == true }
        XCTAssertTrue(setCalls.isEmpty, "no screenshot set call expected, got \(setCalls.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" })")
    }

    // MARK: - Upload plan

    /// iPhone Air (1260x2736) and iPhone 18 Pro Max (1320x2868) are different
    /// device types in the same 6.9" class. The set takes the Pro Max, which
    /// has the larger screen, in every locale, even though en-US lists the
    /// Air first; the Air is reported, per locale, as left out, in one
    /// folded notice.
    func testPlan_airAnd18ProMax_shareAPP_IPHONE_67_largestScreenWins() throws {
        let renderRoot = try makeRenderRoot("plan-air")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        try writePNGs(makePNG(w: 1260, h: 2736), to: renderRoot, ["en-US/air_01.png", "ja/air_01.png"])
        try writePNGs(makePNG(w: 1320, h: 2868), to: renderRoot, ["en-US/max_01.png", "ja/max_01.png"])

        let plan = SubmitOrchestrator.planScreenshotUploads(manifest: manifest([
            device("iPhone 1260x2736", "iPhone Air", files: ["en-US/air_01.png"]),
            device("iPhone 6.9\"", "iPhone 18 Pro Max", files: ["en-US/max_01.png"]),
            device("iPhone 6.9\"", "iPhone 18 Pro Max", locale: "ja", files: ["ja/max_01.png"]),
            device("iPhone 1260x2736", "iPhone Air", locale: "ja", files: ["ja/air_01.png"]),
        ]), renderRoot: renderRoot)

        XCTAssertTrue(plan.problems.isEmpty, "got: \(plan.problems)")
        XCTAssertEqual(plan.groups.map { "\($0.locale) \($0.displayType) \($0.device)" }, [
            "en-US APP_IPHONE_67 iPhone 18 Pro Max",
            "ja APP_IPHONE_67 iPhone 18 Pro Max",
        ])
        XCTAssertEqual(plan.groups.map(\.choice), [.largestScreen, .largestScreen])
        XCTAssertEqual(plan.groups.map { $0.files.map(\.filename) }, [["en-US/max_01.png"], ["ja/max_01.png"]])
        XCTAssertEqual(plan.skipped, [
            .init(locale: "en-US", device: "iPhone Air", count: 1,
                  reason: .sameSizeClass(displayType: "APP_IPHONE_67", uploadedDevice: "iPhone 18 Pro Max")),
            .init(locale: "ja", device: "iPhone Air", count: 1,
                  reason: .sameSizeClass(displayType: "APP_IPHONE_67", uploadedDevice: "iPhone 18 Pro Max")),
        ])
        XCTAssertEqual(plan.notices, [
            "APP_IPHONE_67 (en-US, ja): uploading iPhone 18 Pro Max screenshots only (largest screen in the class); left out iPhone Air (same App Store size class, and App Store Connect keeps one screenshot set per size class and locale).",
        ])
    }

    /// Unknown sizes stay errors (no ASC display type), unlike Duo sizes.
    func testPlan_unknownSize_isStillAProblem() throws {
        let renderRoot = try makeRenderRoot("plan-unknown")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        try writePNGs(makePNG(w: 828, h: 1792), to: renderRoot, ["en-US/xr_01.png"])

        let plan = SubmitOrchestrator.planScreenshotUploads(manifest: manifest([
            device("iPhone 6.1\"", "iPhone 11", files: ["en-US/xr_01.png", "en-US/missing.png"]),
        ]), renderRoot: renderRoot)

        XCTAssertEqual(plan.problems, [
            .noDisplayType(filename: "en-US/xr_01.png", width: 828, height: 1792),
            .missingFile(filename: "en-US/missing.png", path: renderRoot.appendingPathComponent("en-US/missing.png").path),
        ])
        XCTAssertEqual(plan.problems.map(\.message), [
            "no ASC display type for 828x1792 in en-US/xr_01.png",
            "cannot read dims of en-US/missing.png",
        ])
        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertTrue(plan.notices.isEmpty)
    }

    /// A device over the 10-per-set limit is refused, and the set falls back
    /// to the next device in the ranking that fits. In en-US the Pro Max (11
    /// screenshots) gives way to the 16 Plus (next largest screen), which
    /// leaves out the Air. In ja the Pro Max has 12 (its light and dark
    /// captures count together) and the Air fills the set alone. No notice or
    /// skip row names the refused Pro Max.
    func testPlan_overLimitDevice_fallsBackToTheNextDeviceThatFits() throws {
        let renderRoot = try makeRenderRoot("plan-fallback")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        let maxEnUS = (1...11).map { String(format: "en-US/max_%02d.png", $0) }
        let maxJaLight = (1...6).map { String(format: "ja/light/max_%02d.png", $0) }
        let maxJaDark = (1...6).map { String(format: "ja/dark/max_%02d.png", $0) }
        let plusEnUS = ["en-US/plus_01.png", "en-US/plus_02.png"]
        let airEnUS = ["en-US/air_01.png", "en-US/air_02.png"]
        let airJa = (1...5).map { String(format: "ja/light/air_%02d.png", $0) }
        try writePNGs(makePNG(w: 1320, h: 2868), to: renderRoot, maxEnUS + maxJaLight + maxJaDark)
        try writePNGs(makePNG(w: 1290, h: 2796), to: renderRoot, plusEnUS)
        try writePNGs(makePNG(w: 1260, h: 2736), to: renderRoot, airEnUS + airJa)

        let plan = SubmitOrchestrator.planScreenshotUploads(manifest: manifest([
            device("iPhone 6.9\"", "iPhone 18 Pro Max", files: maxEnUS),
            device("iPhone 1260x2736", "iPhone Air", files: airEnUS),
            device("iPhone 1290x2796", "iPhone 16 Plus", files: plusEnUS),
            device("iPhone 6.9\"", "iPhone 18 Pro Max", locale: "ja", appearance: "light", files: maxJaLight),
            device("iPhone 1260x2736", "iPhone Air", locale: "ja", appearance: "light", files: airJa),
            device("iPhone 6.9\"", "iPhone 18 Pro Max", locale: "ja", appearance: "dark", files: maxJaDark),
        ]), renderRoot: renderRoot)

        XCTAssertEqual(plan.groups.map { "\($0.locale) \($0.displayType) \($0.device) \($0.files.count)" }, [
            "en-US APP_IPHONE_67 iPhone 16 Plus 2",
            "ja APP_IPHONE_67 iPhone Air 5",
        ])
        XCTAssertEqual(plan.groups.map(\.choice), [.largestThatFits, .largestThatFits])
        XCTAssertEqual(plan.problems, [
            .tooManyForOneSet(locale: "en-US", displayType: "APP_IPHONE_67", device: "iPhone 18 Pro Max", count: 11, filledFrom: "iPhone 16 Plus"),
            .tooManyForOneSet(locale: "ja", displayType: "APP_IPHONE_67", device: "iPhone 18 Pro Max", count: 12, filledFrom: "iPhone Air"),
        ])
        XCTAssertEqual(plan.problems.last?.message, "screenshots ja/APP_IPHONE_67: 12 screenshots from iPhone 18 Pro Max, more than the 10 App Store Connect allows in one set; the set is filled from iPhone Air instead (the light and dark captures of one device go into the same set)")
        XCTAssertEqual(plan.skipped, [
            .init(locale: "en-US", device: "iPhone Air", count: 2,
                  reason: .sameSizeClass(displayType: "APP_IPHONE_67", uploadedDevice: "iPhone 16 Plus")),
        ])
        XCTAssertEqual(plan.notices, [
            "APP_IPHONE_67 (en-US): uploading iPhone 16 Plus screenshots only (largest screen in the class with at most 10 screenshots); left out iPhone Air (same App Store size class, and App Store Connect keeps one screenshot set per size class and locale).",
        ])
        XCTAssertFalse(plan.notices.contains { $0.contains("iPhone 18 Pro Max") }, "got: \(plan.notices)")
    }

    /// When every device in the class is over the limit, the set is left
    /// alone: only problems, and no skip row or notice that claims a device
    /// was uploaded to it.
    func testPlan_noDeviceFits_onlyProblems() throws {
        let renderRoot = try makeRenderRoot("plan-none-fit")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        let maxFiles = (1...11).map { String(format: "en-US/max_%02d.png", $0) }
        let airFiles = (1...11).map { String(format: "en-US/air_%02d.png", $0) }
        try writePNGs(makePNG(w: 1320, h: 2868), to: renderRoot, maxFiles)
        try writePNGs(makePNG(w: 1260, h: 2736), to: renderRoot, airFiles)

        let plan = SubmitOrchestrator.planScreenshotUploads(manifest: manifest([
            device("iPhone 1260x2736", "iPhone Air", files: airFiles),
            device("iPhone 6.9\"", "iPhone 18 Pro Max", files: maxFiles),
        ]), renderRoot: renderRoot)

        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertEqual(plan.problems, [
            .tooManyForOneSet(locale: "en-US", displayType: "APP_IPHONE_67", device: "iPhone 18 Pro Max", count: 11, filledFrom: nil),
            .tooManyForOneSet(locale: "en-US", displayType: "APP_IPHONE_67", device: "iPhone Air", count: 11, filledFrom: nil),
        ])
        XCTAssertTrue(plan.problems.allSatisfy { $0.message.contains("nothing is uploaded to this set") }, "got: \(plan.problems.map(\.message))")
        XCTAssertTrue(plan.skipped.isEmpty, "got: \(plan.skipped)")
        XCTAssertTrue(plan.notices.isEmpty, "got: \(plan.notices)")
    }

    /// The device is chosen once per display type, not per locale. An older
    /// parallel capture wrote each locale's devices in the order they
    /// finished, so the locales below list them in different orders. Every
    /// locale still gets the same device: the iPad Pro 11" (1668x2420) over
    /// the iPad Air 11" (1640x2360), and, between the equal iPhone 17 Pro and
    /// iPhone 18 Pro, the one the manifest lists first overall.
    func testPlan_deviceChoiceIsPerDisplayType_sameInEveryLocale() throws {
        let renderRoot = try makeRenderRoot("plan-locales")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        for locale in ["en-US", "ja", "de-DE"] {
            try writePNGs(makePNG(w: 1668, h: 2420), to: renderRoot, ["\(locale)/ipadpro_01.png"])
            try writePNGs(makePNG(w: 1640, h: 2360), to: renderRoot, ["\(locale)/ipadair_01.png"])
            try writePNGs(makePNG(w: 1206, h: 2622), to: renderRoot, ["\(locale)/17pro_01.png", "\(locale)/18pro_01.png"])
        }
        func iPadPro(_ locale: String) -> CaptureManifest.DeviceCapture {
            device("iPad Pro 11\"", "iPad Pro 11-inch (M5)", locale: locale, files: ["\(locale)/ipadpro_01.png"])
        }
        func iPadAir(_ locale: String) -> CaptureManifest.DeviceCapture {
            device("iPad 1640x2360", "iPad Air 11-inch (M4)", locale: locale, files: ["\(locale)/ipadair_01.png"])
        }
        func pro17(_ locale: String) -> CaptureManifest.DeviceCapture {
            device("iPhone 6.3\"", "iPhone 17 Pro", locale: locale, files: ["\(locale)/17pro_01.png"])
        }
        func pro18(_ locale: String) -> CaptureManifest.DeviceCapture {
            device("iPhone 6.3\"", "iPhone 18 Pro", locale: locale, files: ["\(locale)/18pro_01.png"])
        }

        let plan = SubmitOrchestrator.planScreenshotUploads(manifest: manifest([
            pro17("en-US"), iPadAir("en-US"), pro18("en-US"), iPadPro("en-US"),
            pro18("ja"), iPadPro("ja"), pro17("ja"), iPadAir("ja"),
            iPadAir("de-DE"), pro18("de-DE"), iPadPro("de-DE"), pro17("de-DE"),
        ]), renderRoot: renderRoot)

        XCTAssertTrue(plan.problems.isEmpty, "got: \(plan.problems)")
        XCTAssertEqual(plan.groups.map { "\($0.locale) \($0.displayType) \($0.device)" }, [
            "de-DE APP_IPAD_PRO_3GEN_11 iPad Pro 11-inch (M5)",
            "de-DE APP_IPHONE_61 iPhone 17 Pro",
            "en-US APP_IPAD_PRO_3GEN_11 iPad Pro 11-inch (M5)",
            "en-US APP_IPHONE_61 iPhone 17 Pro",
            "ja APP_IPAD_PRO_3GEN_11 iPad Pro 11-inch (M5)",
            "ja APP_IPHONE_61 iPhone 17 Pro",
        ])
        XCTAssertEqual(plan.notices, [
            "APP_IPAD_PRO_3GEN_11 (de-DE, en-US, ja): uploading iPad Pro 11-inch (M5) screenshots only (largest screen in the class); left out iPad Air 11-inch (M4) (same App Store size class, and App Store Connect keeps one screenshot set per size class and locale).",
            "APP_IPHONE_61 (de-DE, en-US, ja): uploading iPhone 17 Pro screenshots only (tied for the largest screen in the class, listed first); left out iPhone 18 Pro (same App Store size class, and App Store Connect keeps one screenshot set per size class and locale).",
        ])
    }

    /// Capture labels iPhone Duo screenshots by the screen they show, so one
    /// simulator can produce an "iPhone Duo outer" and an "iPhone Duo inner"
    /// entry per locale. They fold into one skip row and one notice line per
    /// locale that names both screens, with the counts summed.
    func testPlan_duoBothPoses_oneSkipRowPerLocale() throws {
        let renderRoot = try makeRenderRoot("plan-duo-poses")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        var entries: [CaptureManifest.DeviceCapture] = []
        for locale in ["en-US", "ja"] {
            let outer = ["\(locale)/duo_outer_01.png", "\(locale)/duo_outer_02.png"]
            let inner = ["\(locale)/duo_inner_01.png"]
            try writePNGs(makePNG(w: 1398, h: 2034), to: renderRoot, outer)
            try writePNGs(makePNG(w: 2007, h: 2853), to: renderRoot, inner)
            entries.append(device("iPhone Duo outer", "iPhone Duo", locale: locale, files: outer))
            entries.append(device("iPhone Duo inner", "iPhone Duo", locale: locale, files: inner))
        }

        let plan = SubmitOrchestrator.planScreenshotUploads(manifest: manifest(entries), renderRoot: renderRoot)

        XCTAssertTrue(plan.problems.isEmpty, "got: \(plan.problems)")
        XCTAssertTrue(plan.groups.isEmpty)
        let bothScreens = ["iPhone Duo outer display", "iPhone Duo inner display"]
        XCTAssertEqual(plan.skipped, [
            .init(locale: "en-US", device: "iPhone Duo", count: 3, reason: .awaitingUploadSupport(screens: bothScreens)),
            .init(locale: "ja", device: "iPhone Duo", count: 3, reason: .awaitingUploadSupport(screens: bothScreens)),
        ])
        XCTAssertEqual(plan.notices.count, 2, "got: \(plan.notices)")
        XCTAssertTrue(plan.notices[0].hasPrefix("en-US iPhone Duo: skipped 3 screenshot(s) (iPhone Duo outer display, iPhone Duo inner display). "), "got: \(plan.notices[0])")
        XCTAssertTrue(plan.notices[1].hasPrefix("ja iPhone Duo: skipped 3 screenshot(s) (iPhone Duo outer display, iPhone Duo inner display). "), "got: \(plan.notices[1])")
    }

    /// iPhone Air and iPhone 17 Pro share the label `iPhone 6.3"`, so capture
    /// saves both under the same file names and the files on disk hold one
    /// capture. Submit counts those files once: one upload per file, no
    /// "left out" claim about either device, and one notice per device pair
    /// across all locales that does not say which device the pixels are from.
    func testSubmit_devicesSavedUnderSameFileNames_uploadOnceWithNotice() async throws {
        let (client, config) = makeClient()
        let renderRoot = try makeRenderRoot("submit-shared-files")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        let names = ["iPhone_6.3_Home.png", "iPhone_6.3_Settings.png"]
        for locale in ["en-US", "ja"] {
            try writePNGs(makePNG(w: 1206, h: 2622), to: renderRoot, names.map { "\(locale)/\($0)" })
        }
        stubScreenshotOnlySubmit(locales: ["en-US", "ja"], maxUploads: 4)
        let shotManifest = manifest([
            device("iPhone 6.3\"", "iPhone Air", files: names.map { "en-US/\($0)" }),
            device("iPhone 6.3\"", "iPhone 17 Pro", files: names.map { "en-US/\($0)" }),
            device("iPhone 6.3\"", "iPhone Air", locale: "ja", files: names.map { "ja/\($0)" }),
            device("iPhone 6.3\"", "iPhone 17 Pro", locale: "ja", files: names.map { "ja/\($0)" }),
        ])

        let plan = SubmitOrchestrator.planScreenshotUploads(manifest: shotManifest, renderRoot: renderRoot)
        XCTAssertEqual(plan.sharedFiles, [.init(device: "iPhone Air", otherDevice: "iPhone 17 Pro", label: "iPhone 6.3\"")])

        let lines = LineCollector()
        let report = try await screenshotsOnly(client, config, manifest: shotManifest, renderRoot: renderRoot, progress: { lines.append($0) })

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(createdSetDisplayTypes(), ["APP_IPHONE_61", "APP_IPHONE_61"])
        XCTAssertEqual(reservedUploads().map(\.fileName), names + names)
        XCTAssertEqual(report.screenshotUploads.map(\.count), [2, 2])
        XCTAssertTrue(report.screenshotsSkipped.isEmpty, "got: \(report.screenshotsSkipped)")
        XCTAssertEqual(lines.all.filter { $0.contains("same file names") }, [
            "iPhone Air and iPhone 17 Pro were saved under the same file names (label iPhone 6.3\"), so only one capture is on disk; submit counts it once, not once per device. Capture them in separate runs with different output_dir values to upload both.",
        ])
        XCTAssertFalse(lines.all.contains { $0.contains("left out") || $0.contains("same App Store size class") }, "got: \(lines.all)")
    }

    /// Ownership of a shared file follows the device's first appearance in
    /// the whole manifest, not the entry order inside each locale. Manifests
    /// written in capture completion order flip that order per locale; the
    /// same device must own the files everywhere and the pair gets one notice.
    func testPlan_sharedFiles_ownerFollowsWholeManifestOrder() throws {
        let renderRoot = try makeRenderRoot("plan-shared-order")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        let names = ["iPhone_6.3_Home.png", "iPhone_6.3_Settings.png"]
        for locale in ["en-US", "ja"] {
            try writePNGs(makePNG(w: 1206, h: 2622), to: renderRoot, names.map { "\(locale)/\($0)" })
        }
        let plan = SubmitOrchestrator.planScreenshotUploads(manifest: manifest([
            device("iPhone 6.3\"", "iPhone Air", files: names.map { "en-US/\($0)" }),
            device("iPhone 6.3\"", "iPhone 17 Pro", files: names.map { "en-US/\($0)" }),
            // ja lists the devices the other way round.
            device("iPhone 6.3\"", "iPhone 17 Pro", locale: "ja", files: names.map { "ja/\($0)" }),
            device("iPhone 6.3\"", "iPhone Air", locale: "ja", files: names.map { "ja/\($0)" }),
        ]), renderRoot: renderRoot)

        XCTAssertEqual(plan.sharedFiles, [.init(device: "iPhone Air", otherDevice: "iPhone 17 Pro", label: "iPhone 6.3\"")])
        XCTAssertEqual(plan.groups.map(\.locale), ["en-US", "ja"])
        XCTAssertEqual(plan.groups.map(\.device), ["iPhone Air", "iPhone Air"])
        XCTAssertEqual(plan.groups.map { $0.files.map(\.filename) }, [
            names.map { "en-US/\($0)" }, names.map { "ja/\($0)" },
        ])
        XCTAssertTrue(plan.problems.isEmpty, "got: \(plan.problems)")
    }

    /// A same-size-class row says which device filled the set, so it must
    /// not be reported for a set whose upload failed.
    func testSubmit_failedSetUpload_recordsNoFilledFromRow() async throws {
        let (client, config) = makeClient()
        let renderRoot = try makeRenderRoot("submit-failed-filled-from")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        try writePNGs(makePNG(w: 1260, h: 2736), to: renderRoot, ["en-US/air_01.png"])
        try writePNGs(makePNG(w: 1320, h: 2868), to: renderRoot, ["en-US/max_01.png", "en-US/max_02.png"])
        // Only the first upload is stubbed, so the Pro Max's second file fails.
        stubScreenshotOnlySubmit(locales: ["en-US"], maxUploads: 1)

        let report = try await screenshotsOnly(client, config, manifest: manifest([
            device("iPhone 6.3\"", "iPhone Air", files: ["en-US/air_01.png"]),
            device("iPhone 6.9\"", "iPhone 18 Pro Max", files: ["en-US/max_01.png", "en-US/max_02.png"]),
        ]), renderRoot: renderRoot)

        XCTAssertEqual(report.errors.count, 1, "got: \(report.errors)")
        XCTAssertTrue(report.errors.first?.hasPrefix("screenshots en-US/APP_IPHONE_67: ") == true, "got: \(report.errors)")
        XCTAssertTrue(report.screenshotUploads.isEmpty, "got: \(report.screenshotUploads)")
        XCTAssertTrue(report.screenshotsSkipped.isEmpty, "no 'filled from' row for a failed set, got: \(report.screenshotsSkipped)")
    }

    // MARK: - Submit-for-review after screenshot errors

    /// A clean reviewSubmissions flow: no prior submissions, then create,
    /// attach and finalize to WAITING_FOR_REVIEW.
    private func stubReviewSubmissionFlow() {
        ASCStub.add(method: "GET", suffix: "/v1/reviewSubmissions") { _ in
            (200, Data(#"{"data":[]}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissions") { _ in
            (201, Data(#"{"data":{"id":"RSUB-1","type":"reviewSubmissions","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}}"#.utf8))
        }
        ASCStub.add(method: "POST", suffix: "/v1/reviewSubmissionItems") { _ in
            (201, Data(#"{"data":{"id":"RITEM-1","type":"reviewSubmissionItems"}}"#.utf8))
        }
        ASCStub.add(method: "PATCH", suffix: "/v1/reviewSubmissions/RSUB-1") { _ in
            (200, Data(#"{"data":{"id":"RSUB-1","type":"reviewSubmissions","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#.utf8))
        }
    }

    /// Every review-submission request, as "METHOD path", in request order.
    private func reviewSubmissionRequests() -> [String] {
        ASCStub.requests.compactMap { request in
            guard let path = request.url?.path, path.contains("/reviewSubmission") else { return nil }
            return "\(request.httpMethod ?? "") \(path)"
        }
    }

    /// Screenshots-only submit with `submit_for_review: true`.
    private func screenshotsAndReview(_ client: ASCClient, manifest: CaptureManifest, renderRoot: URL) async throws -> SubmitOrchestrator.Report {
        let config = AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(
                createVersion: "1.2.0",
                screenshots: true,
                metadata: false,
                submitForReview: true,
                attachBuild: false  // test stub doesn't model /v1/builds
            )
        )
        return try await SubmitOrchestrator(
            client: client, config: config,
            settlePollInterval: 0, settlePollMaxAttempts: 0
        ).submit(
            manifest: manifest,
            renderRoot: renderRoot,
            metadataRoot: nil,
            shouldUploadScreenshots: true,
            shouldUploadMetadata: false
        )
    }

    /// A set refused for going over the limit keeps the previous version's
    /// screenshots, so the version must not go to App Review: submit makes
    /// no review-submission call and adds an error saying why. Six screens
    /// in the default light and dark appearances are enough to hit this.
    func testSubmit_refusedSet_skipsSubmitForReview() async throws {
        let (client, _) = makeClient()
        let renderRoot = try makeRenderRoot("submit-refused-review")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        let light = (1...6).map { String(format: "en-US/light/max_%02d.png", $0) }
        let dark = (1...6).map { String(format: "en-US/dark/max_%02d.png", $0) }
        try writePNGs(makePNG(w: 1320, h: 2868), to: renderRoot, light + dark)
        stubScreenshotOnlySubmit(locales: ["en-US"], maxUploads: 12)
        stubReviewSubmissionFlow()

        let report = try await screenshotsAndReview(client, manifest: manifest([
            device("iPhone 6.9\"", "iPhone 18 Pro Max", appearance: "light", files: light),
            device("iPhone 6.9\"", "iPhone 18 Pro Max", appearance: "dark", files: dark),
        ]), renderRoot: renderRoot)

        XCTAssertEqual(report.errors.count, 2, "got: \(report.errors)")
        XCTAssertTrue(report.errors.first?.contains("12 screenshots from iPhone 18 Pro Max") == true, "got: \(report.errors)")
        XCTAssertEqual(report.errors.last, "submit for review: skipped because the screenshot step reported errors (see above); fix them and re-run")
        XCTAssertEqual(reviewSubmissionRequests(), [], "no review submission call expected")
        XCTAssertNil(report.reviewSubmissionID)
        XCTAssertNil(report.reviewSubmissionState)
    }

    /// Same when a set's upload fails partway: the set is left half-filled.
    func testSubmit_failedSetUpload_skipsSubmitForReview() async throws {
        let (client, _) = makeClient()
        let renderRoot = try makeRenderRoot("submit-failed-review")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        let files = ["en-US/max_01.png", "en-US/max_02.png"]
        try writePNGs(makePNG(w: 1320, h: 2868), to: renderRoot, files)
        // Only the first upload is stubbed, so the second one fails.
        stubScreenshotOnlySubmit(locales: ["en-US"], maxUploads: 1)
        stubReviewSubmissionFlow()

        let report = try await screenshotsAndReview(client, manifest: manifest([
            device("iPhone 6.9\"", "iPhone 18 Pro Max", files: files),
        ]), renderRoot: renderRoot)

        XCTAssertEqual(report.errors.count, 2, "got: \(report.errors)")
        XCTAssertTrue(report.errors.first?.hasPrefix("screenshots en-US/APP_IPHONE_67: ") == true, "got: \(report.errors)")
        XCTAssertEqual(report.errors.last, "submit for review: skipped because the screenshot step reported errors (see above); fix them and re-run")
        XCTAssertEqual(reviewSubmissionRequests(), [], "no review submission call expected")
    }

    /// Skipped screenshots are not errors: with only an iPhone Duo skip and a
    /// device left out of a shared set, the review submission still goes
    /// ahead.
    func testSubmit_onlySkippedScreenshots_stillSubmitsForReview() async throws {
        let (client, _) = makeClient()
        let renderRoot = try makeRenderRoot("submit-skips-review")
        defer { try? FileManager.default.removeItem(at: renderRoot) }
        try writePNGs(makePNG(w: 1320, h: 2868), to: renderRoot, ["en-US/max_01.png", "en-US/max_02.png"])
        try writePNGs(makePNG(w: 1260, h: 2736), to: renderRoot, ["en-US/air_01.png", "en-US/air_02.png"])
        try writePNGs(makePNG(w: 2007, h: 2853), to: renderRoot, ["en-US/duo_01.png"])
        stubScreenshotOnlySubmit(locales: ["en-US"], maxUploads: 2)
        stubReviewSubmissionFlow()

        let report = try await screenshotsAndReview(client, manifest: manifest([
            device("iPhone 1260x2736", "iPhone Air", files: ["en-US/air_01.png", "en-US/air_02.png"]),
            device("iPhone 6.9\"", "iPhone 18 Pro Max", files: ["en-US/max_01.png", "en-US/max_02.png"]),
            device("iPhone Duo inner", "iPhone Duo", files: ["en-US/duo_01.png"]),
        ]), renderRoot: renderRoot)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.screenshotUploads.map(\.count), [2])
        XCTAssertEqual(report.screenshotsSkipped, [
            .init(locale: "en-US", device: "iPhone Duo", count: 1, reason: .awaitingUploadSupport(screens: ["iPhone Duo inner display"])),
            .init(locale: "en-US", device: "iPhone Air", count: 2,
                  reason: .sameSizeClass(displayType: "APP_IPHONE_67", uploadedDevice: "iPhone 18 Pro Max")),
        ])
        XCTAssertEqual(reviewSubmissionRequests(), [
            "GET /v1/reviewSubmissions",
            "POST /v1/reviewSubmissions",
            "POST /v1/reviewSubmissionItems",
            "PATCH /v1/reviewSubmissions/RSUB-1",
        ])
        XCTAssertEqual(report.reviewSubmissionID, "RSUB-1")
        XCTAssertEqual(report.reviewSubmissionState, "WAITING_FOR_REVIEW")
    }
}
