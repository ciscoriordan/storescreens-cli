import Foundation

/// Wave 2 App Store Connect endpoints covering four newer resource families
/// Apple shipped during 2025:
///
///   1. Modern TestFlight feedback (`BetaFeedbackAPI`)
///      - betaFeedbackCrashSubmissions: crash feedback testers submit through
///        the TestFlight client. This is the modern path; the older
///        `betaTesters/{id}/...crashSubmissions` endpoints were deprecated in
///        the June 2025 spec.
///      - betaFeedbackScreenshotSubmissions: screenshot feedback testers
///        submit through the TestFlight client, including the attached image.
///      - betaCrashLogs: the actual crash log binary referenced by a
///        crash submission. GET returns metadata + a downloadable URL, and
///        `downloadLog` follows the URL to fetch the bytes.
///
///   2. TestFlight automatic recruitment (`BetaRecruitmentAPI`)
///      - betaRecruitmentCriteria: rules that auto-assign new testers to a
///        build based on device family, OS version, region, etc.
///      - betaRecruitmentCriterionOptions: read-only catalog of valid
///        criterion values. Apps fetch this before creating criteria.
///
///   3. Beta App Clip invocations (`BetaAppClipInvocationsAPI`)
///      - betaAppClipInvocations: URL trigger configurations Apple uses for
///        beta-distributed App Clips, including per-locale localizations.
///      - betaAppClipInvocationLocalizations: per-locale title strings.
///
///   4. IAP offer codes (`IAPOfferCodesAPI`)
///      - inAppPurchaseOfferCodes: offer codes scoped to one-time IAPs
///        (consumable / non-consumable / non-renewing), the one-time-IAP
///        analogue of `subscriptionOfferCodes` covered in SubscriptionsAPI.
///      - inAppPurchaseOfferCodeCustomCodes: developer-chosen redemption
///        strings (e.g. "BLACKFRIDAY25_PRO").
///      - inAppPurchaseOfferCodeOneTimeUseCodes: batches of unique
///        single-use redemption codes, with a `values` endpoint for
///        retrieving the generated strings.
///
/// All wrappers follow the existing Wave 1 conventions: `package` access
/// level, JSON:API shaped Codable models, paginated lists accept
/// `limit: Int = 200, cursor: String? = nil` and return a `Page<T>` with the
/// opaque next-page cursor extracted from `links.next`. 404 -> nil where the
/// call shape allows it, and 409 conflicts surface via
/// `ASCClient.APIError.isAlreadySetConflict`.
///
/// Docs:
///   https://developer.apple.com/documentation/appstoreconnectapi/testflight
///   https://developer.apple.com/documentation/appstoreconnectapi/app_store/in-app_purchases

// MARK: - Shared pagination plumbing

/// Pagination envelope shared by the four namespaces in this file. Apple
/// returns `links.next` as a fully formed URL with the opaque cursor token
/// embedded as a `cursor=` query parameter; we hand that token back so
/// callers stay protocol-agnostic.
package struct BetaFeedbackPage<Item: Codable & Sendable>: Sendable {
    package let items: [Item]
    package let nextCursor: String?

    package init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

fileprivate struct BetaFeedbackLinks: Decodable, Sendable {
    let next: String?
}

fileprivate struct BetaFeedbackPagedResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let data: [Item]
    let links: BetaFeedbackLinks?
}

fileprivate enum BetaFeedbackPagination {
    static func extractCursor(from links: BetaFeedbackLinks?) -> String? {
        guard let next = links?.next, let comps = URLComponents(string: next) else {
            return nil
        }
        return comps.queryItems?.first { $0.name == "cursor" }?.value
    }

    static func query(limit: Int, cursor: String?, extras: [String: String] = [:]) -> [String: String] {
        var q = extras
        q["limit"] = String(limit)
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return q
    }

    static func paged<T: Codable & Sendable>(
        client: ASCClient,
        path: String,
        limit: Int,
        cursor: String?,
        extras: [String: String] = [:]
    ) async throws -> BetaFeedbackPage<T> {
        let resp: BetaFeedbackPagedResponse<T> = try await client.get(
            path: path,
            query: query(limit: limit, cursor: cursor, extras: extras),
            as: BetaFeedbackPagedResponse<T>.self
        )
        return BetaFeedbackPage(items: resp.data, nextCursor: extractCursor(from: resp.links))
    }

    /// Single-resource GET with 404 -> nil convention used across the file.
    static func fetchOrNil<T: Decodable & Sendable>(
        client: ASCClient,
        path: String,
        as type: T.Type
    ) async throws -> T? {
        do {
            return try await client.get(path: path, as: type)
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }
}

// MARK: - Modern TestFlight feedback

/// App Store Connect endpoints for the modern TestFlight feedback resources
/// Apple shipped in OpenAPI spec v4.0 (June 2025). These replace the older
/// per-tester crash submission endpoints, which were deprecated in the same
/// release. Crash submissions and screenshot submissions are now first-class
/// app-scoped resources, and `betaCrashLogs` exposes the actual crash log
/// binary referenced by a crash submission.
///
/// Docs:
///   https://developer.apple.com/documentation/appstoreconnectapi/betafeedbackcrashsubmission
///   https://developer.apple.com/documentation/appstoreconnectapi/betafeedbackscreenshotsubmission
///   https://developer.apple.com/documentation/appstoreconnectapi/betacrashlog
package struct BetaFeedbackAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: betaFeedbackCrashSubmissions

    /// A single crash submission from a TestFlight tester. Apple captures
    /// the build the crash happened on, the tester device profile, and the
    /// crash log itself (referenced by `betaCrashLogs`). Comments are the
    /// optional context the tester typed when submitting feedback.
    package struct CrashSubmission: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// When the tester submitted the feedback through TF.
            package let createdDate: Date?
            /// Free-form note the tester optionally attached.
            package let comments: String?
            /// Apple's device profile string (e.g. "iPhone14,2").
            package let deviceModel: String?
            /// OS version the crash was captured on (e.g. "17.5.1").
            package let osVersion: String?
            /// "PORTRAIT" / "LANDSCAPE_LEFT" etc.
            package let deviceOrientation: String?
            /// Region of the language the tester was running in.
            package let locale: String?
            /// Carrier name if device was on cellular.
            package let carrier: String?
            /// Free space at submission time in bytes.
            package let availableDiskBytes: Int64?
            /// Battery percentage in 0...1.
            package let batteryLevel: Double?
            /// Network state ("WIFI", "CELLULAR", "OFFLINE").
            package let connectionType: String?
            /// Application uptime at crash, in seconds.
            package let appUptimeSeconds: Int?
        }
    }

    /// List crash feedback submissions for an app. Apple scopes via
    /// `filter[build.app]`; callers narrow further by passing optional
    /// `buildID` to filter to one build.
    package func listCrashSubmissions(
        appID: String,
        buildID: String? = nil,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> BetaFeedbackPage<CrashSubmission> {
        var extras: [String: String] = ["filter[build.app]": appID]
        if let buildID { extras["filter[build]"] = buildID }
        return try await BetaFeedbackPagination.paged(
            client: client,
            path: "betaFeedbackCrashSubmissions",
            limit: limit,
            cursor: cursor,
            extras: extras
        )
    }

    /// Single-record GET. Returns nil if Apple returns 404 (typical when the
    /// submission has been removed by the tester or the dev team).
    package func getCrashSubmission(id: String) async throws -> CrashSubmission? {
        struct Resp: Decodable, Sendable { let data: CrashSubmission }
        guard let resp = try await BetaFeedbackPagination.fetchOrNil(
            client: client,
            path: "betaFeedbackCrashSubmissions/\(id)",
            as: Resp.self
        ) else { return nil }
        return resp.data
    }

    /// Deletes a crash submission. Apple keeps the associated `betaCrashLog`
    /// reachable for a short grace period after delete, then garbage-collects
    /// it. Use this to clear duplicate reports or to delete reports from
    /// internal testers who submitted unintentionally.
    package func deleteCrashSubmission(id: String) async throws {
        try await client.delete(path: "betaFeedbackCrashSubmissions/\(id)")
    }

    // MARK: betaFeedbackScreenshotSubmissions

    /// A single screenshot feedback submission from a TestFlight tester.
    /// Includes the same device context as a crash submission plus an
    /// attached image asset.
    package struct ScreenshotSubmission: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let createdDate: Date?
            package let comments: String?
            package let deviceModel: String?
            package let osVersion: String?
            package let deviceOrientation: String?
            package let locale: String?
            package let carrier: String?
            package let availableDiskBytes: Int64?
            package let batteryLevel: Double?
            package let connectionType: String?
            /// Tester-attached screenshot. The image lives at the templated
            /// URL; callers dereference + fill the template tokens to fetch
            /// it. `assetToken` and `fileName` are present when the asset
            /// has finished uploading.
            package let screenshot: Screenshot?

            package struct Screenshot: Codable, Sendable {
                package let templateUrl: String?
                package let width: Int?
                package let height: Int?
                package let assetToken: String?
                package let fileName: String?
            }
        }
    }

    /// List screenshot feedback submissions for an app. Optional `buildID`
    /// filters to a single build.
    package func listScreenshotSubmissions(
        appID: String,
        buildID: String? = nil,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> BetaFeedbackPage<ScreenshotSubmission> {
        var extras: [String: String] = ["filter[build.app]": appID]
        if let buildID { extras["filter[build]"] = buildID }
        return try await BetaFeedbackPagination.paged(
            client: client,
            path: "betaFeedbackScreenshotSubmissions",
            limit: limit,
            cursor: cursor,
            extras: extras
        )
    }

    package func getScreenshotSubmission(id: String) async throws -> ScreenshotSubmission? {
        struct Resp: Decodable, Sendable { let data: ScreenshotSubmission }
        guard let resp = try await BetaFeedbackPagination.fetchOrNil(
            client: client,
            path: "betaFeedbackScreenshotSubmissions/\(id)",
            as: Resp.self
        ) else { return nil }
        return resp.data
    }

    package func deleteScreenshotSubmission(id: String) async throws {
        try await client.delete(path: "betaFeedbackScreenshotSubmissions/\(id)")
    }

    // MARK: betaCrashLogs

    /// The actual crash log binary referenced by a `betaFeedbackCrashSubmission`.
    /// Apple delivers crash logs as Apple-hosted `.crash` blobs Apple keeps
    /// behind an expiring presigned URL; the `downloadUrl` on the attributes
    /// is the URL callers follow to fetch the bytes.
    package struct CrashLog: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Apple-hosted, time-limited URL. Callers dereference this to
            /// get the actual `.crash` bytes. May be nil for a brief window
            /// after the submission lands and before Apple has materialized
            /// the log.
            package let downloadUrl: String?
            /// Apple-side timestamps.
            package let expirationDate: Date?
            /// Total bytes when present. Useful for progress reporting on
            /// `downloadLog`.
            package let fileSizeBytes: Int64?
        }
    }

    /// Get a single crash log by id. Returns nil on 404 (Apple has aged the
    /// log out).
    package func getCrashLog(id: String) async throws -> CrashLog? {
        struct Resp: Decodable, Sendable { let data: CrashLog }
        guard let resp = try await BetaFeedbackPagination.fetchOrNil(
            client: client,
            path: "betaCrashLogs/\(id)",
            as: Resp.self
        ) else { return nil }
        return resp.data
    }

    /// Convenience: fetches a `CrashLog`, follows its `downloadUrl`, and
    /// returns the raw bytes. Throws if the log is missing, the download URL
    /// is nil or expired, or the HTTP fetch fails.
    package func downloadLog(id: String) async throws -> Data {
        guard let log = try await getCrashLog(id: id) else {
            throw ASCClient.APIError(
                statusCode: 404,
                details: [],
                rawBody: "betaCrashLog \(id) not found"
            )
        }
        guard let urlString = log.attributes?.downloadUrl,
              let url = URL(string: urlString)
        else {
            throw ASCClient.APIError(
                statusCode: 410,
                details: [],
                rawBody: "betaCrashLog \(id) has no downloadUrl (expired or still materializing)"
            )
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, response) = try await client.session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ASCClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no HTTPURLResponse downloading betaCrashLog \(id)"]
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ASCClient.APIError(
                statusCode: http.statusCode,
                details: [],
                rawBody: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}

// MARK: - Beta recruitment criteria

/// App Store Connect endpoints for `betaRecruitmentCriteria`, the rules that
/// auto-assign new testers to a build when they apply to a public TestFlight
/// link. Shipped in OpenAPI spec v3.8 (February 2025).
///
/// A criterion bundles a set of device family, OS version, and region rules
/// Apple uses to decide which testers an automatic recruitment campaign will
/// accept. The `betaRecruitmentCriterionOptions` endpoint exposes the
/// catalog of valid values to pass to the criteria create/update body.
///
/// Docs:
///   https://developer.apple.com/documentation/appstoreconnectapi/betarecruitmentcriterion
package struct BetaRecruitmentAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: betaRecruitmentCriteria

    /// A single recruitment-criterion rule attached to a beta group. Apple
    /// applies the criterion when an end user applies via the group's public
    /// link; testers who don't match are rejected automatically.
    package struct Criterion: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Developer-visible label.
            package let displayName: String?
            /// Device families this criterion accepts. Apple-defined enum
            /// values; fetch the live catalog via `criterionOptions.list`.
            package let deviceFamilies: [String]?
            /// Minimum OS version (e.g. "17.0"). Nil means "any".
            package let minimumOsVersion: String?
            /// Maximum OS version. Nil means "any".
            package let maximumOsVersion: String?
            /// ISO 3166-1 alpha-3 territory codes accepted. Empty = global.
            package let allowedRegions: [String]?
            /// True if the criterion is active. Pause without delete by
            /// flipping to false.
            package let isActive: Bool?
            /// Apple-side timestamps.
            package let createdDate: Date?
            package let modifiedDate: Date?
        }
    }

    /// Mutable fields accepted on create / update. Nil fields are omitted on
    /// the wire so existing values stay untouched on PATCH.
    package struct CriterionFields: Sendable, Equatable {
        package var displayName: String?
        package var deviceFamilies: [String]?
        package var minimumOsVersion: String?
        package var maximumOsVersion: String?
        package var allowedRegions: [String]?
        package var isActive: Bool?

        package init(
            displayName: String? = nil,
            deviceFamilies: [String]? = nil,
            minimumOsVersion: String? = nil,
            maximumOsVersion: String? = nil,
            allowedRegions: [String]? = nil,
            isActive: Bool? = nil
        ) {
            self.displayName = displayName
            self.deviceFamilies = deviceFamilies
            self.minimumOsVersion = minimumOsVersion
            self.maximumOsVersion = maximumOsVersion
            self.allowedRegions = allowedRegions
            self.isActive = isActive
        }
    }

    fileprivate struct CriterionAttrs: Encodable {
        var displayName: String?
        var deviceFamilies: [String]?
        var minimumOsVersion: String?
        var maximumOsVersion: String?
        var allowedRegions: [String]?
        var isActive: Bool?

        init(fields: CriterionFields) {
            self.displayName = fields.displayName
            self.deviceFamilies = fields.deviceFamilies
            self.minimumOsVersion = fields.minimumOsVersion
            self.maximumOsVersion = fields.maximumOsVersion
            self.allowedRegions = fields.allowedRegions
            self.isActive = fields.isActive
        }
    }

    /// Lists recruitment criteria attached to a beta group.
    package func listCriteria(
        betaGroupID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> BetaFeedbackPage<Criterion> {
        try await BetaFeedbackPagination.paged(
            client: client,
            path: "betaGroups/\(betaGroupID)/betaRecruitmentCriteria",
            limit: limit,
            cursor: cursor
        )
    }

    /// Single-record fetch. Returns nil on 404.
    package func getCriterion(id: String) async throws -> Criterion? {
        struct Resp: Decodable, Sendable { let data: Criterion }
        guard let resp = try await BetaFeedbackPagination.fetchOrNil(
            client: client,
            path: "betaRecruitmentCriteria/\(id)",
            as: Resp.self
        ) else { return nil }
        return resp.data
    }

    /// Creates a new criterion attached to a beta group. `displayName` is
    /// required; everything else defaults to "any" if omitted.
    @discardableResult
    package func createCriterion(
        betaGroupID: String,
        displayName: String,
        fields: CriterionFields = .init()
    ) async throws -> Criterion {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaRecruitmentCriteria"
                let attributes: CriterionAttrs
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct G: Encodable {
                    struct D: Encodable { let type = "betaGroups"; let id: String }
                    let data: D
                }
                let betaGroup: G
            }
            let data: Data
        }
        var merged = fields
        merged.displayName = displayName
        let body = Body(data: .init(
            attributes: CriterionAttrs(fields: merged),
            relationships: .init(betaGroup: .init(data: .init(id: betaGroupID)))
        ))
        struct Resp: Decodable { let data: Criterion }
        let resp: Resp = try await client.post(
            path: "betaRecruitmentCriteria",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// PATCH any subset of mutable fields. Omitted (nil) fields stay
    /// untouched on Apple's side.
    @discardableResult
    package func updateCriterion(
        id: String,
        fields: CriterionFields
    ) async throws -> Criterion {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaRecruitmentCriteria"
                let id: String
                let attributes: CriterionAttrs
            }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: CriterionAttrs(fields: fields)))
        struct Resp: Decodable { let data: Criterion }
        let resp: Resp = try await client.patch(
            path: "betaRecruitmentCriteria/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    package func deleteCriterion(id: String) async throws {
        try await client.delete(path: "betaRecruitmentCriteria/\(id)")
    }

    // MARK: betaRecruitmentCriterionOptions

    /// Read-only catalog of valid values agents can pass for each field of
    /// `betaRecruitmentCriteria`. Apple updates this catalog over time (new
    /// device families, new region codes). Always fetch live rather than
    /// hard-coding values in agent prompts.
    package struct CriterionOption: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Which field this option applies to: "DEVICE_FAMILIES",
            /// "OS_VERSIONS", "REGIONS", etc.
            package let category: String?
            /// Machine-readable value the agent passes back when
            /// creating / updating a criterion.
            package let value: String?
            /// Human-readable label for surfaces that want to show the
            /// catalog to a developer.
            package let displayName: String?
        }
    }

    /// Lists every option in the catalog. Apple keeps the list small, so a
    /// single page is usually enough, but the endpoint paginates the same as
    /// the rest of the ASC API.
    package func listCriterionOptions(
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> BetaFeedbackPage<CriterionOption> {
        try await BetaFeedbackPagination.paged(
            client: client,
            path: "betaRecruitmentCriterionOptions",
            limit: limit,
            cursor: cursor
        )
    }
}

// MARK: - Beta App Clip invocations

/// App Store Connect endpoints for `betaAppClipInvocations`, the URL trigger
/// configurations Apple uses when distributing App Clips via TestFlight.
/// Sibling of the production `appClips` API (see MarketingAPI.AppClipsAPI);
/// the beta variant is scoped to a specific build and lives only for the
/// duration of that build's beta cycle.
///
/// Docs:
///   https://developer.apple.com/documentation/appstoreconnectapi/betaappclipinvocation
package struct BetaAppClipInvocationsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: Invocations

    /// A single beta App Clip invocation. Apple uses `url` as the trigger
    /// (NFC tag, QR code, Safari banner) and the localizations to show the
    /// tester the right invocation title in their locale.
    package struct Invocation: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Trigger URL ("https://example.com/promo"). Apple matches
            /// prefixes; multiple invocations can target sub-paths.
            package let url: String?
            /// "OPEN", "VIEW", "PLAY", etc. Empty / nil means the default
            /// "OPEN" verb.
            package let action: String?
        }
    }

    /// List invocations attached to a build. Apple does not currently
    /// expose an app-scoped list endpoint for the beta variant; callers go
    /// build-by-build.
    package func listInvocations(
        buildID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> BetaFeedbackPage<Invocation> {
        try await BetaFeedbackPagination.paged(
            client: client,
            path: "builds/\(buildID)/betaAppClipInvocations",
            limit: limit,
            cursor: cursor
        )
    }

    /// Single-record fetch. Returns nil on 404.
    package func getInvocation(id: String) async throws -> Invocation? {
        struct Resp: Decodable, Sendable { let data: Invocation }
        guard let resp = try await BetaFeedbackPagination.fetchOrNil(
            client: client,
            path: "betaAppClipInvocations/\(id)",
            as: Resp.self
        ) else { return nil }
        return resp.data
    }

    /// Creates a new invocation on a build. `url` is required; `action`
    /// defaults to Apple's "OPEN" when nil.
    @discardableResult
    package func createInvocation(
        buildID: String,
        url: String,
        action: String? = nil
    ) async throws -> Invocation {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaAppClipInvocations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let url: String
                var action: String?
            }
            struct Rels: Encodable {
                struct B: Encodable {
                    struct D: Encodable { let type = "builds"; let id: String }
                    let data: D
                }
                let build: B
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(url: url, action: action),
            relationships: .init(build: .init(data: .init(id: buildID)))
        ))
        struct Resp: Decodable { let data: Invocation }
        let resp: Resp = try await client.post(
            path: "betaAppClipInvocations",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// PATCH `url` and/or `action` on an existing invocation. Nil fields
    /// stay untouched.
    @discardableResult
    package func updateInvocation(
        id: String,
        url: String? = nil,
        action: String? = nil
    ) async throws -> Invocation {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaAppClipInvocations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                var url: String?
                var action: String?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(url: url, action: action)
        ))
        struct Resp: Decodable { let data: Invocation }
        let resp: Resp = try await client.patch(
            path: "betaAppClipInvocations/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    package func deleteInvocation(id: String) async throws {
        try await client.delete(path: "betaAppClipInvocations/\(id)")
    }

    // MARK: Invocation localizations

    /// Per-locale title string shown to the tester when Apple surfaces the
    /// App Clip invocation. One record per locale per invocation.
    package struct Localization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// e.g. "en-US".
            package let locale: String?
            /// Title shown next to the App Clip card.
            package let title: String?
            /// Subtitle (optional second-line text).
            package let subtitle: String?
        }
    }

    /// Creates a per-locale title for an invocation.
    @discardableResult
    package func createLocalization(
        invocationID: String,
        locale: String,
        title: String,
        subtitle: String? = nil
    ) async throws -> Localization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaAppClipInvocationLocalizations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let locale: String
                let title: String
                var subtitle: String?
            }
            struct Rels: Encodable {
                struct I: Encodable {
                    struct D: Encodable { let type = "betaAppClipInvocations"; let id: String }
                    let data: D
                }
                let betaAppClipInvocation: I
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(locale: locale, title: title, subtitle: subtitle),
            relationships: .init(betaAppClipInvocation: .init(data: .init(id: invocationID)))
        ))
        struct Resp: Decodable { let data: Localization }
        let resp: Resp = try await client.post(
            path: "betaAppClipInvocationLocalizations",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// PATCH title and/or subtitle. Nil fields stay untouched.
    @discardableResult
    package func updateLocalization(
        id: String,
        title: String? = nil,
        subtitle: String? = nil
    ) async throws -> Localization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaAppClipInvocationLocalizations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                var title: String?
                var subtitle: String?
            }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: .init(title: title, subtitle: subtitle)))
        struct Resp: Decodable { let data: Localization }
        let resp: Resp = try await client.patch(
            path: "betaAppClipInvocationLocalizations/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    package func deleteLocalization(id: String) async throws {
        try await client.delete(path: "betaAppClipInvocationLocalizations/\(id)")
    }
}

// MARK: - IAP offer codes

/// App Store Connect endpoints for `inAppPurchaseOfferCodes`, the offer-code
/// equivalent of `subscriptionOfferCodes` but scoped to one-time IAPs
/// (consumable, non-consumable, non-renewing). Shipped in OpenAPI spec v4.2
/// (December 2025).
///
/// The shape mirrors the subscription side closely: the parent
/// `inAppPurchaseOfferCodes` resource owns the program, and the code
/// material itself lives in either the one-time-use or custom-codes child
/// resource. The `one_time_use_codes/{id}/values` endpoint is the way to
/// retrieve the actual generated code strings after Apple processes the
/// batch.
///
/// Docs:
///   https://developer.apple.com/documentation/appstoreconnectapi/inapppurchaseoffercode
package struct IAPOfferCodesAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: Offer codes (parent)

    /// A single offer-code program scoped to one IAP product.
    package struct OfferCode: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Developer-visible label.
            package let referenceName: String?
            /// True if the program is currently redeemable.
            package let isActive: Bool?
            /// Total codes Apple has minted across one-time + custom.
            package let totalNumberOfCodes: Int?
            /// Of those, how many have been redeemed by customers.
            package let totalNumberOfRedeemedCodes: Int?
            /// Eligibility flags. Subset of "NEW", "EXISTING", "EXPIRED".
            /// Apple's catalog evolves; pass whatever Apple lists in its
            /// docs for the current API revision.
            package let customerEligibilities: [String]?
            /// Apple-side timestamps.
            package let createdDate: Date?
            package let expirationDate: Date?
        }
    }

    /// Mutable fields accepted on create / update. Nil fields are omitted.
    package struct OfferCodeFields: Sendable, Equatable {
        package var referenceName: String?
        package var isActive: Bool?
        package var customerEligibilities: [String]?
        package var expirationDate: Date?

        package init(
            referenceName: String? = nil,
            isActive: Bool? = nil,
            customerEligibilities: [String]? = nil,
            expirationDate: Date? = nil
        ) {
            self.referenceName = referenceName
            self.isActive = isActive
            self.customerEligibilities = customerEligibilities
            self.expirationDate = expirationDate
        }
    }

    fileprivate struct OfferCodeAttrs: Encodable {
        var referenceName: String?
        var active: Bool?
        var customerEligibilities: [String]?
        var expirationDate: Date?

        init(fields: OfferCodeFields) {
            self.referenceName = fields.referenceName
            self.active = fields.isActive
            self.customerEligibilities = fields.customerEligibilities
            self.expirationDate = fields.expirationDate
        }
    }

    /// Creates a new offer-code program against a one-time IAP. Apple
    /// requires `referenceName` and `customerEligibilities`; other fields
    /// default to "active, no expiration."
    @discardableResult
    package func createOfferCode(
        inAppPurchaseID: String,
        referenceName: String,
        customerEligibilities: [String],
        expirationDate: Date? = nil
    ) async throws -> OfferCode {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "inAppPurchaseOfferCodes"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let referenceName: String
                let customerEligibilities: [String]
                var expirationDate: Date?
            }
            struct Rels: Encodable {
                struct P: Encodable {
                    struct D: Encodable { let type = "inAppPurchases"; let id: String }
                    let data: D
                }
                let inAppPurchaseV2: P
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(
                referenceName: referenceName,
                customerEligibilities: customerEligibilities,
                expirationDate: expirationDate
            ),
            relationships: .init(
                inAppPurchaseV2: .init(data: .init(id: inAppPurchaseID))
            )
        ))
        struct Resp: Decodable { let data: OfferCode }
        let resp: Resp = try await client.post(
            path: "inAppPurchaseOfferCodes",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// Single-record fetch. Returns nil on 404.
    package func getOfferCode(id: String) async throws -> OfferCode? {
        struct Resp: Decodable, Sendable { let data: OfferCode }
        guard let resp = try await BetaFeedbackPagination.fetchOrNil(
            client: client,
            path: "inAppPurchaseOfferCodes/\(id)",
            as: Resp.self
        ) else { return nil }
        return resp.data
    }

    /// PATCH any subset of mutable fields. Nil fields stay untouched.
    @discardableResult
    package func updateOfferCode(
        id: String,
        fields: OfferCodeFields
    ) async throws -> OfferCode {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "inAppPurchaseOfferCodes"
                let id: String
                let attributes: OfferCodeAttrs
            }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: OfferCodeAttrs(fields: fields)))
        struct Resp: Decodable { let data: OfferCode }
        let resp: Resp = try await client.patch(
            path: "inAppPurchaseOfferCodes/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    // MARK: Custom codes

    /// A developer-chosen redemption string (e.g. "BLACKFRIDAY2025_PRO").
    /// Apple still mints a finite batch behind the readable string.
    package struct CustomCode: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// The code string customers type.
            package let customCode: String?
            /// How many redemptions Apple minted for this code.
            package let numberOfCodes: Int?
            /// True once Apple has fully provisioned the batch.
            package let isActive: Bool?
            package let createdDate: Date?
            package let expirationDate: Date?
        }
    }

    /// Creates a custom-string code batch. `customCode` is the string
    /// customers type; `numberOfCodes` caps redemptions.
    @discardableResult
    package func createCustomCode(
        offerCodeID: String,
        customCode: String,
        numberOfCodes: Int,
        expirationDate: Date? = nil
    ) async throws -> CustomCode {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "inAppPurchaseOfferCodeCustomCodes"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let customCode: String
                let numberOfCodes: Int
                var expirationDate: Date?
            }
            struct Rels: Encodable {
                struct O: Encodable {
                    struct D: Encodable { let type = "inAppPurchaseOfferCodes"; let id: String }
                    let data: D
                }
                let inAppPurchaseOfferCode: O
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(
                customCode: customCode,
                numberOfCodes: numberOfCodes,
                expirationDate: expirationDate
            ),
            relationships: .init(
                inAppPurchaseOfferCode: .init(data: .init(id: offerCodeID))
            )
        ))
        struct Resp: Decodable { let data: CustomCode }
        let resp: Resp = try await client.post(
            path: "inAppPurchaseOfferCodeCustomCodes",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// Single-record fetch. Returns nil on 404.
    package func getCustomCode(id: String) async throws -> CustomCode? {
        struct Resp: Decodable, Sendable { let data: CustomCode }
        guard let resp = try await BetaFeedbackPagination.fetchOrNil(
            client: client,
            path: "inAppPurchaseOfferCodeCustomCodes/\(id)",
            as: Resp.self
        ) else { return nil }
        return resp.data
    }

    /// PATCH active state / expiration. Apple does not let you rename a
    /// custom code post-create (the string is the code).
    @discardableResult
    package func updateCustomCode(
        id: String,
        isActive: Bool? = nil,
        expirationDate: Date? = nil
    ) async throws -> CustomCode {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "inAppPurchaseOfferCodeCustomCodes"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                var active: Bool?
                var expirationDate: Date?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(active: isActive, expirationDate: expirationDate)
        ))
        struct Resp: Decodable { let data: CustomCode }
        let resp: Resp = try await client.patch(
            path: "inAppPurchaseOfferCodeCustomCodes/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    // MARK: One-time-use codes

    /// A batch of Apple-generated single-use redemption codes. Each batch
    /// has a fixed count; once redeemed, that specific code can't be reused.
    package struct OneTimeUseCode: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// How many codes Apple minted in this batch.
            package let numberOfCodes: Int?
            /// True once Apple has fully generated the batch and the
            /// `values` endpoint will return strings.
            package let isActive: Bool?
            package let createdDate: Date?
            package let expirationDate: Date?
        }
    }

    /// Creates a one-time-use code batch. Apple processes asynchronously;
    /// poll `getOneTimeUseCode` or the `values` endpoint until `isActive`
    /// flips to true.
    @discardableResult
    package func createOneTimeUseCode(
        offerCodeID: String,
        numberOfCodes: Int,
        expirationDate: Date? = nil
    ) async throws -> OneTimeUseCode {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "inAppPurchaseOfferCodeOneTimeUseCodes"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let numberOfCodes: Int
                var expirationDate: Date?
            }
            struct Rels: Encodable {
                struct O: Encodable {
                    struct D: Encodable { let type = "inAppPurchaseOfferCodes"; let id: String }
                    let data: D
                }
                let inAppPurchaseOfferCode: O
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(numberOfCodes: numberOfCodes, expirationDate: expirationDate),
            relationships: .init(
                inAppPurchaseOfferCode: .init(data: .init(id: offerCodeID))
            )
        ))
        struct Resp: Decodable { let data: OneTimeUseCode }
        let resp: Resp = try await client.post(
            path: "inAppPurchaseOfferCodeOneTimeUseCodes",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// Single-record fetch. Returns nil on 404.
    package func getOneTimeUseCode(id: String) async throws -> OneTimeUseCode? {
        struct Resp: Decodable, Sendable { let data: OneTimeUseCode }
        guard let resp = try await BetaFeedbackPagination.fetchOrNil(
            client: client,
            path: "inAppPurchaseOfferCodeOneTimeUseCodes/\(id)",
            as: Resp.self
        ) else { return nil }
        return resp.data
    }

    /// PATCH expiration on an existing batch. Apple does not let you
    /// change the code count post-create.
    @discardableResult
    package func updateOneTimeUseCode(
        id: String,
        isActive: Bool? = nil,
        expirationDate: Date? = nil
    ) async throws -> OneTimeUseCode {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "inAppPurchaseOfferCodeOneTimeUseCodes"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                var active: Bool?
                var expirationDate: Date?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(active: isActive, expirationDate: expirationDate)
        ))
        struct Resp: Decodable { let data: OneTimeUseCode }
        let resp: Resp = try await client.patch(
            path: "inAppPurchaseOfferCodeOneTimeUseCodes/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    // MARK: One-time-use code values

    /// One generated code string from a one-time-use batch. Apple uses a
    /// nested `values` endpoint so the listing returns just the strings
    /// without echoing the whole batch metadata.
    package struct OneTimeUseCodeValue: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// The actual code customers redeem.
            package let value: String?
            /// True once the customer has used it.
            package let redeemed: Bool?
        }
    }

    /// Lists the generated code strings for a one-time-use batch. Returns
    /// an empty page if Apple hasn't finished processing the batch yet
    /// (`isActive: false` on the parent).
    package func listOneTimeUseCodeValues(
        oneTimeUseCodeID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> BetaFeedbackPage<OneTimeUseCodeValue> {
        try await BetaFeedbackPagination.paged(
            client: client,
            path: "inAppPurchaseOfferCodeOneTimeUseCodes/\(oneTimeUseCodeID)/values",
            limit: limit,
            cursor: cursor
        )
    }
}
