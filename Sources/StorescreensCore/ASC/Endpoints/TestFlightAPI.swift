import Foundation

/// App Store Connect endpoints covering TestFlight and pre-release
/// distribution. Wraps the JSON:API resources Apple groups under "TestFlight"
/// in the docs:
///
///   - betaGroups + beta tester relationships
///   - betaTesters + invitations
///   - prereleaseVersions (read-only; Apple auto-manages them)
///   - builds (TestFlight slice: list/get + expired flag PATCH)
///   - buildBetaDetails (external testing toggle, auto-notify)
///   - buildBetaNotifications (push "new build available" pings)
///   - betaAppLocalizations (per-locale TF description, feedback email,
///     marketing/privacy URLs, TOS URL)
///   - betaBuildLocalizations (per-locale "what to test" notes per build)
///   - betaAppReviewDetails (review contact info for the TF beta review,
///     separate from App Review's appStoreReviewDetails)
///   - betaAppReviewSubmissions (submit a build for Beta App Review)
///   - betaLicenseAgreements (the TF EULA testers accept)
///   - betaTesterMetrics (per-tester install/launch counts; read-only)
///   - buildBundles + buildIcons (primary build bundle + extensions/clips,
///     per-build app icon images; read-only)
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/testflight
///
/// Pagination convention: every list endpoint accepts an optional `limit`
/// and `cursor` and returns `(data, nextCursor)`. The cursor is Apple's
/// opaque `links.next` continuation token; pass it back unchanged on the
/// next call to get the next page. When `nextCursor` is nil, the caller has
/// reached the end of the list.
package struct TestFlightAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Shared paged response shape

    /// Generic JSON:API page envelope. Apple returns `links.next` as a full
    /// URL with a base64-encoded `cursor=` query parameter; we extract the
    /// cursor value so callers can pass it back on subsequent calls without
    /// having to parse the URL themselves.
    package struct Page<Item: Codable & Sendable>: Sendable {
        package let data: [Item]
        package let nextCursor: String?
    }

    /// Internal helper: decodes a JSON:API list response and pulls out the
    /// `cursor=` parameter from `links.next` if present.
    fileprivate struct PageEnvelope<Item: Codable>: Decodable {
        struct Links: Decodable { let next: String? }
        let data: [Item]
        let links: Links?
    }

    fileprivate static func extractCursor(from link: String?) -> String? {
        guard let link, !link.isEmpty,
              let comps = URLComponents(string: link)
        else { return nil }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }

    /// Standard list query builder used by every paged endpoint here.
    fileprivate static func listQuery(
        limit: Int,
        cursor: String?,
        extras: [String: String] = [:]
    ) -> [String: String] {
        var q = extras
        q["limit"] = String(limit)
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return q
    }

    // MARK: - betaGroups

    package struct BetaGroup: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Human-readable name shown to testers and in the ASC UI.
            package let name: String?
            /// True for the auto-created "App Store Connect Users" group
            /// that mirrors the team. Read-only on Apple's side.
            package let isInternalGroup: Bool?
            /// Public invite link slug. Nil for internal-only groups.
            package let publicLink: String?
            package let publicLinkEnabled: Bool?
            package let publicLinkLimit: Int?
            package let publicLinkLimitEnabled: Bool?
            /// Apple-side timestamps.
            package let createdDate: Date?
            /// Whether new builds are auto-pushed to this group as soon as
            /// they finish processing + beta review.
            package let feedbackEnabled: Bool?
            package let hasAccessToAllBuilds: Bool?
            package let iosBuildsAvailableForAppleSiliconMac: Bool?
        }
    }

    /// Lists beta groups for an app. Use `cursor` to page; pass the
    /// `nextCursor` from the previous response.
    package func listBetaGroups(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page<BetaGroup> {
        let resp: PageEnvelope<BetaGroup> = try await client.get(
            path: "apps/\(appID)/betaGroups",
            query: Self.listQuery(limit: limit, cursor: cursor),
            as: PageEnvelope<BetaGroup>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    /// Fetches a single beta group by ID. Returns nil if Apple returns 404.
    package func getBetaGroup(id: String) async throws -> BetaGroup? {
        struct Resp: Decodable { let data: BetaGroup }
        do {
            let resp: Resp = try await client.get(
                path: "betaGroups/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Fields accepted on betaGroup create/update. Nil fields are omitted
    /// from the wire body so existing values stay untouched on a PATCH.
    package struct BetaGroupFields: Sendable, Equatable {
        package var name: String?
        package var publicLinkEnabled: Bool?
        package var publicLinkLimit: Int?
        package var publicLinkLimitEnabled: Bool?
        package var feedbackEnabled: Bool?
        package var hasAccessToAllBuilds: Bool?
        package var iosBuildsAvailableForAppleSiliconMac: Bool?

        package init(
            name: String? = nil,
            publicLinkEnabled: Bool? = nil,
            publicLinkLimit: Int? = nil,
            publicLinkLimitEnabled: Bool? = nil,
            feedbackEnabled: Bool? = nil,
            hasAccessToAllBuilds: Bool? = nil,
            iosBuildsAvailableForAppleSiliconMac: Bool? = nil
        ) {
            self.name = name
            self.publicLinkEnabled = publicLinkEnabled
            self.publicLinkLimit = publicLinkLimit
            self.publicLinkLimitEnabled = publicLinkLimitEnabled
            self.feedbackEnabled = feedbackEnabled
            self.hasAccessToAllBuilds = hasAccessToAllBuilds
            self.iosBuildsAvailableForAppleSiliconMac = iosBuildsAvailableForAppleSiliconMac
        }
    }

    fileprivate struct BetaGroupAttrsPatch: Encodable {
        var name: String?
        var publicLinkEnabled: Bool?
        var publicLinkLimit: Int?
        var publicLinkLimitEnabled: Bool?
        var feedbackEnabled: Bool?
        var hasAccessToAllBuilds: Bool?
        var iosBuildsAvailableForAppleSiliconMac: Bool?

        init(fields: BetaGroupFields) {
            self.name = fields.name
            self.publicLinkEnabled = fields.publicLinkEnabled
            self.publicLinkLimit = fields.publicLinkLimit
            self.publicLinkLimitEnabled = fields.publicLinkLimitEnabled
            self.feedbackEnabled = fields.feedbackEnabled
            self.hasAccessToAllBuilds = fields.hasAccessToAllBuilds
            self.iosBuildsAvailableForAppleSiliconMac = fields.iosBuildsAvailableForAppleSiliconMac
        }
    }

    /// Creates a new beta group on `appID`. `name` is required; the other
    /// fields default to Apple's documented defaults if nil.
    @discardableResult
    package func createBetaGroup(
        appID: String,
        name: String,
        fields: BetaGroupFields = .init()
    ) async throws -> BetaGroup {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaGroups"
                let attributes: BetaGroupAttrsPatch
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct App: Encodable {
                    struct D: Encodable { let type = "apps"; let id: String }
                    let data: D
                }
                let app: App
            }
            let data: Data
        }
        var merged = fields
        merged.name = name
        let body = Body(data: .init(
            attributes: BetaGroupAttrsPatch(fields: merged),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: BetaGroup }
        let resp: Resp = try await client.post(
            path: "betaGroups", body: body, as: Resp.self
        )
        return resp.data
    }

    /// PATCH a beta group with any non-nil fields. Nil fields are omitted.
    @discardableResult
    package func updateBetaGroup(
        id: String,
        fields: BetaGroupFields
    ) async throws -> BetaGroup {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaGroups"
                let id: String
                let attributes: BetaGroupAttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: BetaGroupAttrsPatch(fields: fields)))
        struct Resp: Decodable { let data: BetaGroup }
        let resp: Resp = try await client.patch(
            path: "betaGroups/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteBetaGroup(id: String) async throws {
        try await client.delete(path: "betaGroups/\(id)")
    }

    // MARK: - betaGroups: builds + testers relationships

    /// Attaches one or more builds to a beta group. After this, Apple
    /// auto-distributes the builds to the group's testers (subject to
    /// beta-review state for external groups).
    package func addBuildsToBetaGroup(
        groupID: String,
        buildIDs: [String]
    ) async throws {
        struct Body: Encodable {
            struct D: Encodable { let type = "builds"; let id: String }
            let data: [D]
        }
        let body = Body(data: buildIDs.map { .init(id: $0) })
        // Relationship POST is fire-and-forget; ASC returns 204.
        _ = try await client.post(
            path: "betaGroups/\(groupID)/relationships/builds",
            body: body,
            as: ASCClient.EmptyBody.self
        )
    }

    /// Removes one or more builds from a beta group. Testers in the group
    /// can no longer install those builds. The build resources themselves
    /// stay intact.
    package func removeBuildsFromBetaGroup(
        groupID: String,
        buildIDs: [String]
    ) async throws {
        struct Body: Encodable {
            struct D: Encodable { let type = "builds"; let id: String }
            let data: [D]
        }
        let body = Body(data: buildIDs.map { .init(id: $0) })
        // DELETE with body. ASCClient surfaces only GET/POST/PATCH typed
        // helpers plus a bodyless DELETE, so we drop down to URLSession
        // directly through `sendRelationshipDelete` to keep the JSON:API
        // body shape Apple expects.
        try await sendRelationshipDelete(
            path: "betaGroups/\(groupID)/relationships/builds",
            body: body
        )
    }

    /// Adds testers to a beta group. Testers must already exist on the app.
    package func addTestersToBetaGroup(
        groupID: String,
        testerIDs: [String]
    ) async throws {
        struct Body: Encodable {
            struct D: Encodable { let type = "betaTesters"; let id: String }
            let data: [D]
        }
        let body = Body(data: testerIDs.map { .init(id: $0) })
        _ = try await client.post(
            path: "betaGroups/\(groupID)/relationships/betaTesters",
            body: body,
            as: ASCClient.EmptyBody.self
        )
    }

    /// Removes testers from a beta group. The betaTester record itself
    /// stays attached to the app.
    package func removeTestersFromBetaGroup(
        groupID: String,
        testerIDs: [String]
    ) async throws {
        struct Body: Encodable {
            struct D: Encodable { let type = "betaTesters"; let id: String }
            let data: [D]
        }
        let body = Body(data: testerIDs.map { .init(id: $0) })
        try await sendRelationshipDelete(
            path: "betaGroups/\(groupID)/relationships/betaTesters",
            body: body
        )
    }

    /// Convenience: create a group and immediately add testers to it.
    /// Common starter workflow for a new external test campaign.
    @discardableResult
    package func createBetaGroupAndInvite(
        appID: String,
        name: String,
        testerIDs: [String],
        fields: BetaGroupFields = .init()
    ) async throws -> BetaGroup {
        let group = try await createBetaGroup(appID: appID, name: name, fields: fields)
        if !testerIDs.isEmpty {
            try await addTestersToBetaGroup(groupID: group.id, testerIDs: testerIDs)
        }
        return group
    }

    // MARK: - betaTesters

    package struct BetaTester: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let firstName: String?
            package let lastName: String?
            package let email: String?
            /// "INSTALLED", "NOT_INSTALLED", "INVITED", "REVOKED", etc.
            package let inviteType: String?
            /// True once Apple has marked the invitation as expired.
            package let state: String?
        }
    }

    /// Lists beta testers for an app. Apple scopes via `filter[apps]`.
    package func listBetaTesters(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page<BetaTester> {
        let resp: PageEnvelope<BetaTester> = try await client.get(
            path: "betaTesters",
            query: Self.listQuery(
                limit: limit,
                cursor: cursor,
                extras: ["filter[apps]": appID]
            ),
            as: PageEnvelope<BetaTester>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    /// Fetches a single beta tester by ID. Returns nil on 404.
    package func getBetaTester(id: String) async throws -> BetaTester? {
        struct Resp: Decodable { let data: BetaTester }
        do {
            let resp: Resp = try await client.get(
                path: "betaTesters/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Creates a beta tester record on `appID`. `email` is required;
    /// firstName/lastName are optional. The tester is attached to any
    /// `betaGroupIDs` you pass in (use this to invite-into-group in one call).
    @discardableResult
    package func createBetaTester(
        appID: String,
        email: String,
        firstName: String? = nil,
        lastName: String? = nil,
        betaGroupIDs: [String] = []
    ) async throws -> BetaTester {
        let body = BetaTesterCreateBody(
            data: .init(
                attributes: .init(email: email, firstName: firstName, lastName: lastName),
                relationships: .init(
                    apps: .init(data: [.init(id: appID)]),
                    betaGroups: betaGroupIDs.isEmpty
                        ? nil
                        : .init(data: betaGroupIDs.map { .init(id: $0) })
                )
            )
        )
        struct Resp: Decodable { let data: BetaTester }
        let resp: Resp = try await client.post(
            path: "betaTesters", body: body, as: Resp.self
        )
        return resp.data
    }

    /// Removes a tester from the entire app. The betaTester record is
    /// deleted across all groups it belongs to.
    package func deleteBetaTester(id: String) async throws {
        try await client.delete(path: "betaTesters/\(id)")
    }

    /// Removes a tester from one specific app (Apple supports a tester
    /// across multiple apps; this DELETE only detaches from the given app
    /// rather than deleting the tester record).
    package func removeBetaTesterFromApp(
        testerID: String, appID: String
    ) async throws {
        struct Body: Encodable {
            struct D: Encodable { let type = "apps"; let id: String }
            let data: [D]
        }
        let body = Body(data: [.init(id: appID)])
        try await sendRelationshipDelete(
            path: "betaTesters/\(testerID)/relationships/apps",
            body: body
        )
    }

    /// Adds an existing tester to one or more beta groups.
    package func assignBetaTesterToGroups(
        testerID: String, groupIDs: [String]
    ) async throws {
        struct Body: Encodable {
            struct D: Encodable { let type = "betaGroups"; let id: String }
            let data: [D]
        }
        let body = Body(data: groupIDs.map { .init(id: $0) })
        _ = try await client.post(
            path: "betaTesters/\(testerID)/relationships/betaGroups",
            body: body,
            as: ASCClient.EmptyBody.self
        )
    }

    /// Removes a tester from specific beta groups (keeps them on the app).
    package func removeBetaTesterFromGroups(
        testerID: String, groupIDs: [String]
    ) async throws {
        struct Body: Encodable {
            struct D: Encodable { let type = "betaGroups"; let id: String }
            let data: [D]
        }
        let body = Body(data: groupIDs.map { .init(id: $0) })
        try await sendRelationshipDelete(
            path: "betaTesters/\(testerID)/relationships/betaGroups",
            body: body
        )
    }

    // Helper body type used by `createBetaTester`. Declared outside the
    // function so the nested relationship and attribute structs share the
    // same generic context (Swift can't always infer `.init(...)` shorthand
    // through a deeply nested anonymous body).
    fileprivate struct BetaTesterCreateBody: Encodable {
        struct Data: Encodable {
            let type = "betaTesters"
            let attributes: Attrs
            let relationships: Rels
        }
        struct Attrs: Encodable {
            let email: String
            var firstName: String?
            var lastName: String?
        }
        struct Rels: Encodable {
            struct AppRel: Encodable {
                struct D: Encodable { let type = "apps"; let id: String }
                let data: [D]
            }
            struct GroupRel: Encodable {
                struct D: Encodable { let type = "betaGroups"; let id: String }
                let data: [D]
            }
            let apps: AppRel
            var betaGroups: GroupRel?
        }
        let data: Data
    }

    // MARK: - betaTesterInvitations

    package struct BetaTesterInvitation: Codable, Sendable {
        package let id: String
    }

    /// Re-sends (or sends for the first time) a TestFlight invitation
    /// email to an existing tester on a given app. Useful when a tester
    /// said they never got their invite. ASC has no GET counterpart; the
    /// resource only exists as a create-effect.
    @discardableResult
    package func createBetaTesterInvitation(
        testerID: String, appID: String
    ) async throws -> BetaTesterInvitation {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaTesterInvitations"
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct AppRel: Encodable {
                    struct D: Encodable { let type = "apps"; let id: String }
                    let data: D
                }
                struct TesterRel: Encodable {
                    struct D: Encodable { let type = "betaTesters"; let id: String }
                    let data: D
                }
                let app: AppRel
                let betaTester: TesterRel
            }
            let data: Data
        }
        let body = Body(data: .init(relationships: .init(
            app: .init(data: .init(id: appID)),
            betaTester: .init(data: .init(id: testerID))
        )))
        struct Resp: Decodable { let data: BetaTesterInvitation }
        let resp: Resp = try await client.post(
            path: "betaTesterInvitations", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: - prereleaseVersions

    package struct PrereleaseVersion: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// The marketing version string (e.g. "1.2.0") that groups
            /// uploaded builds into a "train" in TestFlight.
            package let version: String?
            /// "IOS", "MAC_OS", etc.
            package let platform: String?
        }
    }

    /// Lists pre-release versions (build trains) for an app. ASC creates
    /// these automatically when a build is uploaded; you cannot create
    /// or delete them via the API.
    package func listPrereleaseVersions(
        appID: String,
        platform: String? = nil,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page<PrereleaseVersion> {
        var extras: [String: String] = [:]
        if let platform { extras["filter[platform]"] = platform }
        let resp: PageEnvelope<PrereleaseVersion> = try await client.get(
            path: "apps/\(appID)/preReleaseVersions",
            query: Self.listQuery(limit: limit, cursor: cursor, extras: extras),
            as: PageEnvelope<PrereleaseVersion>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    package func getPrereleaseVersion(id: String) async throws -> PrereleaseVersion? {
        struct Resp: Decodable { let data: PrereleaseVersion }
        do {
            let resp: Resp = try await client.get(
                path: "preReleaseVersions/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    // MARK: - builds (TestFlight slice)

    /// Lists builds across an app, with TestFlight-relevant filters
    /// commonly used by callers iterating beta state: `expired`, `processingState`,
    /// `preReleaseVersion` id. Other filters are exposed via `extraFilters`
    /// for advanced callers.
    package func listBuilds(
        appID: String? = nil,
        expired: Bool? = nil,
        processingState: String? = nil,
        preReleaseVersionID: String? = nil,
        extraFilters: [String: String] = [:],
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page<BuildsAPI.Build> {
        var extras = extraFilters
        if let appID { extras["filter[app]"] = appID }
        if let expired { extras["filter[expired]"] = expired ? "true" : "false" }
        if let processingState {
            extras["filter[processingState]"] = processingState
        }
        if let preReleaseVersionID {
            extras["filter[preReleaseVersion]"] = preReleaseVersionID
        }
        extras["sort"] = extras["sort"] ?? "-uploadedDate"
        let resp: PageEnvelope<BuildsAPI.Build> = try await client.get(
            path: "builds",
            query: Self.listQuery(limit: limit, cursor: cursor, extras: extras),
            as: PageEnvelope<BuildsAPI.Build>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    /// Fetches a single build by ID. Returns nil on 404.
    package func getBuild(id: String) async throws -> BuildsAPI.Build? {
        struct Resp: Decodable { let data: BuildsAPI.Build }
        do {
            let resp: Resp = try await client.get(
                path: "builds/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// PATCH `expired` on a build. Apple keeps builds available for 90 days
    /// by default; flipping `expired: true` makes the build unavailable to
    /// testers immediately. Use this to retire a bad build that you can't
    /// or don't want to delete.
    @discardableResult
    package func setBuildExpired(id: String, expired: Bool) async throws -> BuildsAPI.Build {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "builds"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { let expired: Bool }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: .init(expired: expired)))
        struct Resp: Decodable { let data: BuildsAPI.Build }
        let resp: Resp = try await client.patch(
            path: "builds/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: - buildBetaDetails

    package struct BuildBetaDetail: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// "MISSING_EXPORT_COMPLIANCE", "READY_FOR_BETA_TESTING",
            /// "IN_BETA_TESTING", "EXPIRED", "IN_EXPORT_COMPLIANCE_REVIEW".
            package let internalBuildState: String?
            /// Same lifecycle states but for external (public) testers.
            package let externalBuildState: String?
            /// If true, Apple emails testers automatically when the build
            /// finishes processing. False suppresses the notification so the
            /// developer can curate which build to push.
            package let autoNotifyEnabled: Bool?
        }
    }

    /// Fetches the buildBetaDetails record for a build.  Apple creates one
    /// automatically per build; the record exists as soon as the build is
    /// uploaded so this should normally never 404.
    package func getBuildBetaDetail(buildID: String) async throws -> BuildBetaDetail? {
        struct Resp: Decodable { let data: BuildBetaDetail }
        do {
            let resp: Resp = try await client.get(
                path: "builds/\(buildID)/buildBetaDetail", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// PATCH the buildBetaDetails record. Use this to flip `autoNotifyEnabled`
    /// before a build finishes processing.
    @discardableResult
    package func updateBuildBetaDetail(
        id: String, autoNotifyEnabled: Bool
    ) async throws -> BuildBetaDetail {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "buildBetaDetails"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { let autoNotifyEnabled: Bool }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: .init(autoNotifyEnabled: autoNotifyEnabled)
        ))
        struct Resp: Decodable { let data: BuildBetaDetail }
        let resp: Resp = try await client.patch(
            path: "buildBetaDetails/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: - buildBetaNotifications

    package struct BuildBetaNotification: Codable, Sendable {
        package let id: String
    }

    /// Pushes the "a new build is available to test" email to every tester
    /// in every group attached to this build. The build must already be in
    /// beta-testing state (external review approved for external groups).
    /// One-shot: ASC has no GET counterpart and no list endpoint, the
    /// resource only exists as a create-effect.
    @discardableResult
    package func sendBuildBetaNotification(buildID: String) async throws -> BuildBetaNotification {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "buildBetaNotifications"
                let relationships: Rels
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
        let body = Body(data: .init(relationships: .init(build: .init(data: .init(id: buildID)))))
        struct Resp: Decodable { let data: BuildBetaNotification }
        let resp: Resp = try await client.post(
            path: "buildBetaNotifications", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: - betaAppLocalizations

    /// Per-locale TestFlight "App Information" card: the description shown
    /// in TestFlight on the tester's device, plus a feedback email,
    /// marketing/privacy URLs and TOS URL. Separate from the App Store
    /// version localizations; lives on the app, not the version.
    package struct BetaAppLocalization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let locale: String?
            package let description: String?
            package let feedbackEmail: String?
            package let marketingUrl: String?
            package let privacyPolicyUrl: String?
            package let tvOsPrivacyPolicy: String?
        }
    }

    package struct BetaAppLocalizationFields: Sendable, Equatable {
        package var description: String?
        package var feedbackEmail: String?
        package var marketingURL: String?
        package var privacyPolicyURL: String?
        package var tvOsPrivacyPolicy: String?

        package init(
            description: String? = nil,
            feedbackEmail: String? = nil,
            marketingURL: String? = nil,
            privacyPolicyURL: String? = nil,
            tvOsPrivacyPolicy: String? = nil
        ) {
            self.description = description
            self.feedbackEmail = feedbackEmail
            self.marketingURL = marketingURL
            self.privacyPolicyURL = privacyPolicyURL
            self.tvOsPrivacyPolicy = tvOsPrivacyPolicy
        }
    }

    fileprivate struct BetaAppLocAttrsPatch: Encodable {
        var description: String?
        var feedbackEmail: String?
        var marketingUrl: String?
        var privacyPolicyUrl: String?
        var tvOsPrivacyPolicy: String?

        init(fields: BetaAppLocalizationFields) {
            self.description = fields.description
            self.feedbackEmail = fields.feedbackEmail
            self.marketingUrl = fields.marketingURL
            self.privacyPolicyUrl = fields.privacyPolicyURL
            self.tvOsPrivacyPolicy = fields.tvOsPrivacyPolicy
        }
    }

    package func listBetaAppLocalizations(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page<BetaAppLocalization> {
        let resp: PageEnvelope<BetaAppLocalization> = try await client.get(
            path: "betaAppLocalizations",
            query: Self.listQuery(
                limit: limit, cursor: cursor,
                extras: ["filter[app]": appID]
            ),
            as: PageEnvelope<BetaAppLocalization>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    package func getBetaAppLocalization(id: String) async throws -> BetaAppLocalization? {
        struct Resp: Decodable { let data: BetaAppLocalization }
        do {
            let resp: Resp = try await client.get(
                path: "betaAppLocalizations/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    @discardableResult
    package func createBetaAppLocalization(
        appID: String,
        locale: String,
        fields: BetaAppLocalizationFields = .init()
    ) async throws -> BetaAppLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaAppLocalizations"
                let attributes: AttrsCreate
                let relationships: Rels
            }
            struct AttrsCreate: Encodable {
                let locale: String
                var description: String?
                var feedbackEmail: String?
                var marketingUrl: String?
                var privacyPolicyUrl: String?
                var tvOsPrivacyPolicy: String?
            }
            struct Rels: Encodable {
                struct A: Encodable {
                    struct D: Encodable { let type = "apps"; let id: String }
                    let data: D
                }
                let app: A
            }
            let data: Data
        }
        let attrs = Body.AttrsCreate(
            locale: locale,
            description: fields.description,
            feedbackEmail: fields.feedbackEmail,
            marketingUrl: fields.marketingURL,
            privacyPolicyUrl: fields.privacyPolicyURL,
            tvOsPrivacyPolicy: fields.tvOsPrivacyPolicy
        )
        let body = Body(data: .init(
            attributes: attrs,
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: BetaAppLocalization }
        let resp: Resp = try await client.post(
            path: "betaAppLocalizations", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateBetaAppLocalization(
        id: String, fields: BetaAppLocalizationFields
    ) async throws -> BetaAppLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaAppLocalizations"
                let id: String
                let attributes: BetaAppLocAttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: BetaAppLocAttrsPatch(fields: fields)))
        struct Resp: Decodable { let data: BetaAppLocalization }
        let resp: Resp = try await client.patch(
            path: "betaAppLocalizations/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteBetaAppLocalization(id: String) async throws {
        try await client.delete(path: "betaAppLocalizations/\(id)")
    }

    // MARK: - betaBuildLocalizations

    /// Per-locale "What to Test" notes attached to a single build. Replaces
    /// the per-app description with build-specific release notes for the
    /// TestFlight client.
    package struct BetaBuildLocalization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let locale: String?
            package let whatsNew: String?
        }
    }

    package func listBetaBuildLocalizations(
        buildID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page<BetaBuildLocalization> {
        let resp: PageEnvelope<BetaBuildLocalization> = try await client.get(
            path: "betaBuildLocalizations",
            query: Self.listQuery(
                limit: limit, cursor: cursor,
                extras: ["filter[build]": buildID]
            ),
            as: PageEnvelope<BetaBuildLocalization>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    package func getBetaBuildLocalization(id: String) async throws -> BetaBuildLocalization? {
        struct Resp: Decodable { let data: BetaBuildLocalization }
        do {
            let resp: Resp = try await client.get(
                path: "betaBuildLocalizations/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    @discardableResult
    package func createBetaBuildLocalization(
        buildID: String,
        locale: String,
        whatsNew: String? = nil
    ) async throws -> BetaBuildLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaBuildLocalizations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let locale: String
                var whatsNew: String?
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
            attributes: .init(locale: locale, whatsNew: whatsNew),
            relationships: .init(build: .init(data: .init(id: buildID)))
        ))
        struct Resp: Decodable { let data: BetaBuildLocalization }
        let resp: Resp = try await client.post(
            path: "betaBuildLocalizations", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateBetaBuildLocalization(
        id: String, whatsNew: String?
    ) async throws -> BetaBuildLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaBuildLocalizations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { var whatsNew: String? }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: .init(whatsNew: whatsNew)))
        struct Resp: Decodable { let data: BetaBuildLocalization }
        let resp: Resp = try await client.patch(
            path: "betaBuildLocalizations/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteBetaBuildLocalization(id: String) async throws {
        try await client.delete(path: "betaBuildLocalizations/\(id)")
    }

    // MARK: - betaAppReviewDetails

    /// Per-app TestFlight beta review contact info and demo account fields.
    /// Separate from `appStoreReviewDetails` (which is per-app-store-version
    /// for App Review). Apple uses these only when a build is submitted
    /// for Beta App Review before going external.
    package struct BetaAppReviewDetail: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let contactFirstName: String?
            package let contactLastName: String?
            package let contactPhone: String?
            package let contactEmail: String?
            package let demoAccountName: String?
            package let demoAccountPassword: String?
            package let demoAccountRequired: Bool?
            package let notes: String?
        }
    }

    package struct BetaAppReviewDetailFields: Sendable, Equatable {
        package var contactFirstName: String?
        package var contactLastName: String?
        package var contactPhone: String?
        package var contactEmail: String?
        package var demoAccountName: String?
        package var demoAccountPassword: String?
        package var demoAccountRequired: Bool?
        package var notes: String?

        package init(
            contactFirstName: String? = nil,
            contactLastName: String? = nil,
            contactPhone: String? = nil,
            contactEmail: String? = nil,
            demoAccountName: String? = nil,
            demoAccountPassword: String? = nil,
            demoAccountRequired: Bool? = nil,
            notes: String? = nil
        ) {
            self.contactFirstName = contactFirstName
            self.contactLastName = contactLastName
            self.contactPhone = contactPhone
            self.contactEmail = contactEmail
            self.demoAccountName = demoAccountName
            self.demoAccountPassword = demoAccountPassword
            self.demoAccountRequired = demoAccountRequired
            self.notes = notes
        }
    }

    fileprivate struct BetaReviewDetailAttrsPatch: Encodable {
        var contactFirstName: String?
        var contactLastName: String?
        var contactPhone: String?
        var contactEmail: String?
        var demoAccountName: String?
        var demoAccountPassword: String?
        var demoAccountRequired: Bool?
        var notes: String?

        init(fields: BetaAppReviewDetailFields) {
            self.contactFirstName = fields.contactFirstName
            self.contactLastName = fields.contactLastName
            self.contactPhone = fields.contactPhone
            self.contactEmail = fields.contactEmail
            self.demoAccountName = fields.demoAccountName
            self.demoAccountPassword = fields.demoAccountPassword
            self.demoAccountRequired = fields.demoAccountRequired
            self.notes = fields.notes
        }
    }

    /// Reads the betaAppReviewDetail attached to an app. Returns nil on 404.
    package func getBetaAppReviewDetail(appID: String) async throws -> BetaAppReviewDetail? {
        struct Resp: Decodable { let data: BetaAppReviewDetail }
        do {
            let resp: Resp = try await client.get(
                path: "apps/\(appID)/betaAppReviewDetail", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    @discardableResult
    package func updateBetaAppReviewDetail(
        id: String, fields: BetaAppReviewDetailFields
    ) async throws -> BetaAppReviewDetail {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaAppReviewDetails"
                let id: String
                let attributes: BetaReviewDetailAttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: BetaReviewDetailAttrsPatch(fields: fields)
        ))
        struct Resp: Decodable { let data: BetaAppReviewDetail }
        let resp: Resp = try await client.patch(
            path: "betaAppReviewDetails/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: - betaAppReviewSubmissions

    /// TestFlight Beta App Review submission. Required once per app (or
    /// per "significant" build update) before a build can be made available
    /// to external testers.
    package struct BetaAppReviewSubmission: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// "WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED", "REJECTED".
            package let betaReviewState: String?
            package let submittedDate: Date?
        }
    }

    /// Lists historical and pending beta app review submissions for an app.
    package func listBetaAppReviewSubmissions(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page<BetaAppReviewSubmission> {
        let resp: PageEnvelope<BetaAppReviewSubmission> = try await client.get(
            path: "betaAppReviewSubmissions",
            query: Self.listQuery(
                limit: limit, cursor: cursor,
                extras: ["filter[build.app]": appID]
            ),
            as: PageEnvelope<BetaAppReviewSubmission>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    package func getBetaAppReviewSubmission(id: String) async throws -> BetaAppReviewSubmission? {
        struct Resp: Decodable { let data: BetaAppReviewSubmission }
        do {
            let resp: Resp = try await client.get(
                path: "betaAppReviewSubmissions/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Submits a build for Beta App Review. The build must be in
    /// processingState VALID and have export compliance answered.
    @discardableResult
    package func createBetaAppReviewSubmission(buildID: String) async throws -> BetaAppReviewSubmission {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaAppReviewSubmissions"
                let relationships: Rels
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
        let body = Body(data: .init(relationships: .init(build: .init(data: .init(id: buildID)))))
        struct Resp: Decodable { let data: BetaAppReviewSubmission }
        let resp: Resp = try await client.post(
            path: "betaAppReviewSubmissions", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: - betaLicenseAgreements

    /// The TestFlight EULA testers see and must accept before installing
    /// the app. One per app; ASC seeds it with Apple's default text.
    package struct BetaLicenseAgreement: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let agreementText: String?
        }
    }

    package func getBetaLicenseAgreement(appID: String) async throws -> BetaLicenseAgreement? {
        struct Resp: Decodable { let data: BetaLicenseAgreement }
        do {
            let resp: Resp = try await client.get(
                path: "apps/\(appID)/betaLicenseAgreement", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    @discardableResult
    package func updateBetaLicenseAgreement(
        id: String, agreementText: String
    ) async throws -> BetaLicenseAgreement {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "betaLicenseAgreements"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { let agreementText: String }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: .init(agreementText: agreementText)))
        struct Resp: Decodable { let data: BetaLicenseAgreement }
        let resp: Resp = try await client.patch(
            path: "betaLicenseAgreements/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: - betaTesterMetrics

    /// Per-tester install and launch counts on a given build. Read-only.
    package struct BetaTesterMetric: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// "INSTALLED", "NOT_INSTALLED", "PENDING".
            package let betaTesterState: String?
            package let installedCfBundleShortVersionString: String?
            package let installedCfBundleVersion: String?
            package let lastModifiedDate: Date?
            package let crashCount: Int?
        }
    }

    /// Per-tester install/launch counts scoped to an app. Apple does not
    /// expose a "per build" filter on the metrics endpoint; callers can
    /// pivot client-side using the `installedCfBundleVersion` attribute.
    package func listBetaTesterMetrics(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page<BetaTesterMetric> {
        let resp: PageEnvelope<BetaTesterMetric> = try await client.get(
            path: "apps/\(appID)/betaTesterUsages",
            query: Self.listQuery(limit: limit, cursor: cursor),
            as: PageEnvelope<BetaTesterMetric>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    // MARK: - buildBundles

    /// One bundle from a build: the primary `.app` plus any app extensions,
    /// app clips, watch apps, etc. Read-only; Apple materializes these
    /// from the .ipa.
    package struct BuildBundle: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let bundleId: String?
            package let bundleType: String?
            package let dsymUrl: String?
            package let fileName: String?
            package let hasOnDemandResources: Bool?
            package let hasPrerenderedIcon: Bool?
            package let hasSirikit: Bool?
            package let includesSymbols: Bool?
            package let isIosBuildMacAppStoreCompatible: Bool?
            package let locales: [String]?
            package let platformBuild: String?
            package let sdkBuild: String?
            package let supportedArchitectures: [String]?
            package let usesLocationServices: Bool?
            package let deviceProtocols: [String]?
        }
    }

    package func listBuildBundles(
        buildID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page<BuildBundle> {
        let resp: PageEnvelope<BuildBundle> = try await client.get(
            path: "builds/\(buildID)/buildBundles",
            query: Self.listQuery(limit: limit, cursor: cursor),
            as: PageEnvelope<BuildBundle>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    package func getBuildBundle(id: String) async throws -> BuildBundle? {
        struct Resp: Decodable { let data: BuildBundle }
        do {
            let resp: Resp = try await client.get(
                path: "buildBundles/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    // MARK: - buildIcons

    /// Per-build app icon image(s). Read-only.
    package struct BuildIcon: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// "MARKETING", "TABLE_OF_CONTENTS", "WATCH", etc.
            package let iconAssetType: String?
            /// Image asset object with a URL the caller can dereference.
            package let imageAsset: ImageAsset?

            package struct ImageAsset: Codable, Sendable {
                package let templateUrl: String?
                package let width: Int?
                package let height: Int?
            }
        }
    }

    package func listBuildIcons(
        buildID: String,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> Page<BuildIcon> {
        let resp: PageEnvelope<BuildIcon> = try await client.get(
            path: "builds/\(buildID)/icons",
            query: Self.listQuery(limit: limit, cursor: cursor),
            as: PageEnvelope<BuildIcon>.self
        )
        return .init(data: resp.data, nextCursor: Self.extractCursor(from: resp.links?.next))
    }

    // MARK: - Private: DELETE with body

    /// JSON:API relationship DELETEs (e.g. removing testers from a group)
    /// take a body. ASCClient.delete() is bodyless, so we build the request
    /// directly here using the same auth/retry plumbing via a HEAD-style
    /// fallback: post with a custom method through a one-off URLRequest.
    /// The shared client doesn't expose its retry helper publicly, so this
    /// is a single attempt, which is sufficient for relationship deletes since
    /// idempotent on Apple's side (re-DELETE of an already-removed item
    /// returns 204).
    private func sendRelationshipDelete<Body: Encodable>(
        path: String, body: Body
    ) async throws {
        let url: URL
        // Match ASCClient's `buildURL` behavior: leading slash trimmed,
        // appended to /v1 baseURL.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        url = client.baseURL.appendingPathComponent(trimmed)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try encoder.encode(body)
        let token = try ASCJWTSigner.sign(
            credentials: client.credentials,
            lifetime: client.tokenLifetime
        )
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ASCClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no HTTPURLResponse"]
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(
                ASCClient.ErrorEnvelope.self, from: data
            )
            throw ASCClient.APIError(
                statusCode: http.statusCode,
                details: envelope?.errors ?? [],
                rawBody: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}
