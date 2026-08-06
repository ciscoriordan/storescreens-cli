import XCTest
import CryptoKit
@testable import StorescreensCore

/// Covers the `submission_info:` (IDFA + content rights) and `release:`
/// (release type + scheduled date) steps of the submit flow.
///
/// The interesting behavior is all in the diffing: App Store Connect 409s a
/// PATCH that sets an attribute to the value it already holds, so the
/// orchestrator has to skip the call entirely when nothing differs, and has
/// to fold three attributes across two resources into at most two requests.
final class SubmissionInfoReleaseTests: XCTestCase {

    // MARK: - Stub plumbing

    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handlers: [(method: String, suffix: String, body: @Sendable (URLRequest) -> (Int, Data))] = []
        nonisolated(unsafe) static var requests: [(method: String, path: String, body: Data)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var body = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                let size = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: size)
                    if read <= 0 { break }
                    body.append(buffer, count: read)
                }
            } else if let raw = request.httpBody {
                body = raw
            }
            let method = request.httpMethod ?? "GET"
            let path = request.url!.path
            Stub.requests.append((method, path, body))

            for handler in Stub.handlers where handler.method == method && path.hasSuffix(handler.suffix) {
                let (status, data) = handler.body(request)
                let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"errors":[{"code":"NO_HANDLER","title":"no stub","detail":"x"}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func reset() {
            handlers.removeAll()
            requests.removeAll()
        }

        static func add(_ method: String, _ suffix: String, _ body: @escaping @Sendable (URLRequest) -> (Int, Data)) {
            handlers.append((method, suffix, body))
        }

        static func json(_ method: String, _ suffix: String, _ payload: String, status: Int = 200) {
            add(method, suffix) { _ in (status, Data(payload.utf8)) }
        }
    }

    private func makeClient() -> ASCClient {
        Stub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let pk = P256.Signing.PrivateKey()
        let creds = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: pk.pemRepresentation, source: .environment)
        return ASCClient(credentials: creds, session: URLSession(configuration: config), maxRetries: 0)
    }

    /// Minimal manifest + empty render dir: these tests exercise the
    /// pre-screenshot steps only, so both uploads are switched off.
    private func runSubmit(config: AppStoreConnectConfig, client: ASCClient) async throws -> SubmitOrchestrator.Report {
        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "test",
            appName: "App", displayName: nil, scheme: "App", devices: []
        )
        let orchestrator = SubmitOrchestrator(client: client, config: config)
        return try await orchestrator.submit(
            manifest: manifest,
            renderRoot: FileManager.default.temporaryDirectory,
            metadataRoot: nil,
            shouldUploadScreenshots: false,
            shouldUploadMetadata: false
        )
    }

    /// App + version lookups every test needs. `contentRights` and the
    /// version attributes are what the diffing reads.
    private func stubLookups(
        contentRights: String?,
        usesIdfa: String = "null",
        releaseType: String = "\"AFTER_APPROVAL\"",
        earliestReleaseDate: String = "null"
    ) {
        let rights = contentRights.map { "\"\($0)\"" } ?? "null"
        Stub.json("GET", "/v1/apps", """
        {"data":[{"id":"99999","type":"apps","attributes":{"name":"App","bundleId":"com.example.app","contentRightsDeclaration":\(rights)}}]}
        """)
        Stub.json("GET", "/v1/apps/99999/appStoreVersions", """
        {"data":[{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}]}
        """)
        Stub.json("GET", "/v1/appStoreVersions/VER-1", """
        {"data":{"id":"VER-1","type":"appStoreVersions","attributes":{"versionString":"1.2.0","usesIdfa":\(usesIdfa),"releaseType":\(releaseType),"earliestReleaseDate":\(earliestReleaseDate)}}}
        """)
    }

    private func baseConfig(
        submissionInfo: SubmissionInfoConfig? = nil,
        release: ReleaseConfig? = nil
    ) -> AppStoreConnectConfig {
        AppStoreConnectConfig(
            bundleID: "com.example.app",
            submit: SubmitConfig(createVersion: "1.2.0", platform: "IOS", attachBuild: false),
            submissionInfo: submissionInfo,
            release: release
        )
    }

    private func patchBody(path suffix: String) throws -> [String: Any]? {
        guard let request = Stub.requests.last(where: { $0.method == "PATCH" && $0.path.hasSuffix(suffix) }) else {
            return nil
        }
        let parsed = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        return (parsed?["data"] as? [String: Any])?["attributes"] as? [String: Any]
    }

    // MARK: - Content rights

    func testContentRights_setsWhenUnanswered() async throws {
        let client = makeClient()
        stubLookups(contentRights: nil)
        Stub.json("PATCH", "/v1/apps/99999", #"{"data":{"id":"99999","type":"apps","attributes":{}}}"#)

        let report = try await runSubmit(
            config: baseConfig(submissionInfo: SubmissionInfoConfig(containsThirdPartyContent: true)),
            client: client
        )

        XCTAssertEqual(report.submissionInfoStatus, "updated: contentRightsDeclaration")
        let attrs = try patchBody(path: "/v1/apps/99999")
        XCTAssertEqual(attrs?["contentRightsDeclaration"] as? String, "USES_THIRD_PARTY_CONTENT")
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
    }

    func testContentRights_skipsPatchWhenAlreadyCorrect() async throws {
        let client = makeClient()
        stubLookups(contentRights: "USES_THIRD_PARTY_CONTENT")

        let report = try await runSubmit(
            config: baseConfig(submissionInfo: SubmissionInfoConfig(containsThirdPartyContent: true)),
            client: client
        )

        XCTAssertEqual(report.submissionInfoStatus, "unchanged")
        XCTAssertFalse(
            Stub.requests.contains { $0.method == "PATCH" },
            "an unchanged value must not produce a PATCH - ASC 409s it"
        )
    }

    func testContentRights_falseSendsDoesNotUse() async throws {
        let client = makeClient()
        stubLookups(contentRights: "USES_THIRD_PARTY_CONTENT")
        Stub.json("PATCH", "/v1/apps/99999", #"{"data":{"id":"99999","type":"apps","attributes":{}}}"#)

        _ = try await runSubmit(
            config: baseConfig(submissionInfo: SubmissionInfoConfig(containsThirdPartyContent: false)),
            client: client
        )

        let attrs = try patchBody(path: "/v1/apps/99999")
        XCTAssertEqual(attrs?["contentRightsDeclaration"] as? String, "DOES_NOT_USE_THIRD_PARTY_CONTENT")
    }

    // MARK: - IDFA

    func testUsesIdfa_patchesVersionWhenUnanswered() async throws {
        let client = makeClient()
        stubLookups(contentRights: nil, usesIdfa: "null")
        Stub.json("PATCH", "/v1/appStoreVersions/VER-1", #"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{}}}"#)

        let report = try await runSubmit(
            config: baseConfig(submissionInfo: SubmissionInfoConfig(usesIdfa: false)),
            client: client
        )

        XCTAssertEqual(report.submissionInfoStatus, "updated: usesIdfa")
        let attrs = try patchBody(path: "/v1/appStoreVersions/VER-1")
        XCTAssertEqual(attrs?["usesIdfa"] as? Bool, false)
        // Release fields weren't configured, so they must not appear in
        // the body at all - sending them would overwrite ASC's values.
        XCTAssertNil(attrs?["releaseType"])
        XCTAssertNil(attrs?["earliestReleaseDate"])
    }

    func testUsesIdfa_unchangedSkipsPatch() async throws {
        let client = makeClient()
        stubLookups(contentRights: nil, usesIdfa: "false")

        let report = try await runSubmit(
            config: baseConfig(submissionInfo: SubmissionInfoConfig(usesIdfa: false)),
            client: client
        )

        XCTAssertEqual(report.submissionInfoStatus, "unchanged")
        XCTAssertFalse(Stub.requests.contains { $0.method == "PATCH" })
    }

    // MARK: - Release scheduling

    func testRelease_manualPatchesReleaseType() async throws {
        let client = makeClient()
        stubLookups(contentRights: nil, releaseType: "\"AFTER_APPROVAL\"")
        Stub.json("PATCH", "/v1/appStoreVersions/VER-1", #"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{}}}"#)

        let report = try await runSubmit(
            config: baseConfig(release: ReleaseConfig(type: .manual)),
            client: client
        )

        XCTAssertEqual(report.releaseStatus, "updated: releaseType")
        let attrs = try patchBody(path: "/v1/appStoreVersions/VER-1")
        XCTAssertEqual(attrs?["releaseType"] as? String, "MANUAL")
    }

    func testRelease_scheduledSendsTypeAndDateTogether() async throws {
        let client = makeClient()
        stubLookups(contentRights: nil)
        Stub.json("PATCH", "/v1/appStoreVersions/VER-1", #"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{}}}"#)

        let report = try await runSubmit(
            config: baseConfig(release: ReleaseConfig(
                type: .scheduled, earliestReleaseDate: "2027-08-10T12:00:00-07:00"
            )),
            client: client
        )

        XCTAssertEqual(report.releaseStatus, "updated: releaseType, earliestReleaseDate")
        let attrs = try patchBody(path: "/v1/appStoreVersions/VER-1")
        XCTAssertEqual(attrs?["releaseType"] as? String, "SCHEDULED")
        XCTAssertEqual(attrs?["earliestReleaseDate"] as? String, "2027-08-10T12:00:00-07:00")
    }

    /// The same instant written two ways is not a change. Without this the
    /// orchestrator would re-PATCH on every run and eat a 409.
    func testRelease_equivalentDateInDifferentZoneIsUnchanged() async throws {
        let client = makeClient()
        stubLookups(
            contentRights: nil,
            releaseType: "\"SCHEDULED\"",
            earliestReleaseDate: "\"2027-08-10T19:00:00Z\""
        )

        let report = try await runSubmit(
            config: baseConfig(release: ReleaseConfig(
                type: .scheduled, earliestReleaseDate: "2027-08-10T12:00:00-07:00"
            )),
            client: client
        )

        XCTAssertEqual(report.releaseStatus, "unchanged")
        XCTAssertFalse(Stub.requests.contains { $0.method == "PATCH" })
    }

    func testRelease_dateWithoutScheduledTypeIsRejectedBeforeThePatch() async throws {
        let client = makeClient()
        stubLookups(contentRights: nil, releaseType: "\"AFTER_APPROVAL\"")

        let report = try await runSubmit(
            config: baseConfig(release: ReleaseConfig(
                type: .afterApproval, earliestReleaseDate: "2027-08-10T12:00:00-07:00"
            )),
            client: client
        )

        XCTAssertEqual(report.releaseStatus, "error")
        XCTAssertTrue(
            report.errors.contains { $0.contains("requires `type: scheduled`") },
            "\(report.errors)"
        )
        XCTAssertFalse(Stub.requests.contains { $0.method == "PATCH" })
    }

    func testRelease_scheduledWithoutAnyDateIsRejected() async throws {
        let client = makeClient()
        stubLookups(contentRights: nil, releaseType: "\"AFTER_APPROVAL\"", earliestReleaseDate: "null")

        let report = try await runSubmit(
            config: baseConfig(release: ReleaseConfig(type: .scheduled)),
            client: client
        )

        XCTAssertEqual(report.releaseStatus, "error")
        XCTAssertTrue(
            report.errors.contains { $0.contains("needs an earliest_release_date") },
            "\(report.errors)"
        )
        XCTAssertFalse(Stub.requests.contains { $0.method == "PATCH" })
    }

    /// Switching an already-SCHEDULED version's date without repeating
    /// `type:` is allowed - the existing release type already satisfies
    /// Apple's constraint.
    func testRelease_dateOnlyUpdateOnAlreadyScheduledVersion() async throws {
        let client = makeClient()
        stubLookups(
            contentRights: nil,
            releaseType: "\"SCHEDULED\"",
            earliestReleaseDate: "\"2027-08-10T12:00:00-07:00\""
        )
        Stub.json("PATCH", "/v1/appStoreVersions/VER-1", #"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{}}}"#)

        let report = try await runSubmit(
            config: baseConfig(release: ReleaseConfig(earliestReleaseDate: "2027-09-01T09:00:00-07:00")),
            client: client
        )

        XCTAssertEqual(report.releaseStatus, "updated: earliestReleaseDate")
        let attrs = try patchBody(path: "/v1/appStoreVersions/VER-1")
        XCTAssertEqual(attrs?["earliestReleaseDate"] as? String, "2027-09-01T09:00:00-07:00")
        XCTAssertNil(attrs?["releaseType"])
    }

    // MARK: - Both blocks together

    /// IDFA and release type live on the same resource, so configuring
    /// both must produce one PATCH, not two.
    func testIdfaAndReleaseShareASinglePatch() async throws {
        let client = makeClient()
        stubLookups(contentRights: "DOES_NOT_USE_THIRD_PARTY_CONTENT", usesIdfa: "null")
        Stub.json("PATCH", "/v1/apps/99999", #"{"data":{"id":"99999","type":"apps","attributes":{}}}"#)
        Stub.json("PATCH", "/v1/appStoreVersions/VER-1", #"{"data":{"id":"VER-1","type":"appStoreVersions","attributes":{}}}"#)

        let report = try await runSubmit(
            config: baseConfig(
                submissionInfo: SubmissionInfoConfig(usesIdfa: true, containsThirdPartyContent: true),
                release: ReleaseConfig(type: .manual)
            ),
            client: client
        )

        let versionPatches = Stub.requests.filter {
            $0.method == "PATCH" && $0.path.hasSuffix("/v1/appStoreVersions/VER-1")
        }
        XCTAssertEqual(versionPatches.count, 1, "usesIdfa and releaseType belong in one body")

        let attrs = try patchBody(path: "/v1/appStoreVersions/VER-1")
        XCTAssertEqual(attrs?["usesIdfa"] as? Bool, true)
        XCTAssertEqual(attrs?["releaseType"] as? String, "MANUAL")

        // Content rights changed too, so the submission-info line covers
        // both of its halves.
        XCTAssertEqual(report.submissionInfoStatus, "updated: contentRightsDeclaration, usesIdfa")
        XCTAssertEqual(report.releaseStatus, "updated: releaseType")
    }

    /// Neither block configured: the whole step is skipped, including the
    /// extra version GET it would otherwise make.
    func testNeitherBlockConfigured_makesNoExtraCalls() async throws {
        let client = makeClient()
        stubLookups(contentRights: nil)

        let report = try await runSubmit(config: baseConfig(), client: client)

        XCTAssertNil(report.submissionInfoStatus)
        XCTAssertNil(report.releaseStatus)
        XCTAssertFalse(
            Stub.requests.contains { $0.path.hasSuffix("/v1/appStoreVersions/VER-1") && $0.method == "GET" },
            "no config means no version re-read"
        )
    }

    // MARK: - Dry-run validation rules

    /// `now` is pinned so these stay deterministic as the real clock moves
    /// past the fixture dates.
    private let now = ISO8601DateFormatter().date(from: "2026-08-05T12:00:00Z")!

    func testValidateRelease_catchesNonHourDate() {
        let problems = ReleaseConfig(
            type: .scheduled, earliestReleaseDate: "2026-08-10T12:30:00-07:00"
        ).validate(now: now)
        XCTAssertTrue(problems.contains { $0.contains("exact hour") }, "\(problems)")
    }

    func testValidateRelease_catchesPastDate() {
        let problems = ReleaseConfig(
            type: .scheduled, earliestReleaseDate: "2020-01-01T12:00:00Z"
        ).validate(now: now)
        XCTAssertTrue(problems.contains { $0.contains("in the past") }, "\(problems)")
    }

    func testValidateRelease_catchesUnparseableDate() {
        let problems = ReleaseConfig(
            type: .scheduled, earliestReleaseDate: "next tuesday"
        ).validate(now: now)
        XCTAssertTrue(problems.contains { $0.contains("not ISO 8601") }, "\(problems)")
    }

    func testValidateRelease_catchesDateOnNonScheduledType() {
        let problems = ReleaseConfig(
            type: .afterApproval, earliestReleaseDate: "2026-08-10T12:00:00-07:00"
        ).validate(now: now)
        XCTAssertTrue(problems.contains { $0.contains("only valid with") }, "\(problems)")
    }

    func testValidateRelease_catchesScheduledWithoutDate() {
        let problems = ReleaseConfig(type: .scheduled).validate(now: now)
        XCTAssertTrue(problems.contains { $0.contains("requires an earliest_release_date") }, "\(problems)")
    }

    func testValidateRelease_acceptsWellFormedFutureDate() {
        XCTAssertTrue(
            ReleaseConfig(type: .scheduled, earliestReleaseDate: "2026-08-10T12:00:00-07:00")
                .validate(now: now)
                .isEmpty
        )
    }

    func testValidateRelease_acceptsTypeOnlyChanges() {
        XCTAssertTrue(ReleaseConfig(type: .manual).validate(now: now).isEmpty)
        XCTAssertTrue(ReleaseConfig(type: .afterApproval).validate(now: now).isEmpty)
    }
}
