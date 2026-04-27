import Foundation

/// App Store Connect endpoints for apps, versions, and localizations. Thin
/// typed wrappers over ASCClient.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/app_store
package struct AppsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Apps

    package struct App: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let name: String?
            package let bundleId: String?
            package let primaryLocale: String?
            package let sku: String?
        }
    }

    /// Looks up an app by its numeric ID. Returns the app or throws on 404.
    package func lookupApp(id: String) async throws -> App {
        struct Resp: Decodable { let data: AppsAPI.App }
        let resp: Resp = try await client.get(path: "apps/\(id)", as: Resp.self)
        return resp.data
    }

    /// Looks up an app by bundle identifier. Returns nil if not found.
    package func lookupApp(bundleID: String) async throws -> App? {
        struct Resp: Decodable { let data: [AppsAPI.App] }
        let resp: Resp = try await client.get(
            path: "apps",
            query: ["filter[bundleId]": bundleID, "limit": "1"],
            as: Resp.self
        )
        return resp.data.first
    }

    // MARK: - App Store Versions

    package struct Version: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let platform: String?
            package let versionString: String?
            package let appStoreState: String?
            package let createdDate: Date?
        }
    }

    /// Lists versions for an app, optionally filtered to a platform
    /// ("IOS" | "MAC_OS" | "TV_OS" | "VISION_OS").
    package func listVersions(appID: String, platform: String? = nil) async throws -> [Version] {
        var query: [String: String] = ["limit": "50"]
        if let platform { query["filter[platform]"] = platform }
        struct Resp: Decodable { let data: [Version] }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/appStoreVersions",
            query: query,
            as: Resp.self
        )
        return resp.data
    }

    /// Finds the editable version matching `versionString` (any app-store
    /// state that allows edits: PREPARE_FOR_SUBMISSION, DEVELOPER_REJECTED,
    /// INVALID_BINARY, REJECTED, METADATA_REJECTED, WAITING_FOR_REVIEW).
    /// Returns nil if no such version exists.
    package func findEditableVersion(
        appID: String,
        versionString: String,
        platform: String = "IOS"
    ) async throws -> Version? {
        let versions = try await listVersions(appID: appID, platform: platform)
        return versions.first { $0.attributes?.versionString == versionString }
    }

    /// Creates a new editable version on the given app + platform.
    package func createVersion(
        appID: String,
        versionString: String,
        platform: String = "IOS"
    ) async throws -> Version {
        // JSON:API shape Apple expects: data.type, data.attributes,
        // data.relationships.app.data.{type,id}.
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersions"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let platform: String
                let versionString: String
            }
            struct Rels: Encodable {
                struct App: Encodable {
                    struct Data: Encodable { let type = "apps"; let id: String }
                    let data: Data
                }
                let app: App
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(platform: platform, versionString: versionString),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: Version }
        let resp: Resp = try await client.post(
            path: "appStoreVersions",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// Find-or-create convenience: returns the editable version, creating
    /// it if missing.
    package func findOrCreateVersion(
        appID: String,
        versionString: String,
        platform: String = "IOS"
    ) async throws -> Version {
        if let existing = try await findEditableVersion(
            appID: appID, versionString: versionString, platform: platform
        ) {
            return existing
        }
        return try await createVersion(appID: appID, versionString: versionString, platform: platform)
    }

    /// App-store states that indicate a version has been (or is about to
    /// be) publicly available to customers. If any version *other than*
    /// the one we're submitting to is in one of these states, the app
    /// has a prior release and ASC will accept `whatsNew` release notes.
    /// If none are in these states, ASC treats the submission as the
    /// app's first version and rejects any whatsNew field.
    package static let publiclyReleasedVersionStates: Set<String> = [
        "READY_FOR_SALE",
        "PENDING_DEVELOPER_RELEASE",
        "PENDING_APPLE_RELEASE",
        "PROCESSING_FOR_APP_STORE",
        "REMOVED_FROM_SALE",
        "REPLACED_WITH_NEW_VERSION",
    ]

    /// True if the app has at least one `appStoreVersion` (other than
    /// `excludingVersionID`) that has reached a released or pending-release
    /// state. Use this to decide whether to send the `whatsNew` attribute on
    /// the version localization PATCH: ASC rejects whatsNew on a brand-new
    /// app's very first version because release notes are semantically "what
    /// changed since the last release."
    package func hasPreviouslyReleasedVersion(
        appID: String,
        excludingVersionID: String,
        platform: String = "IOS"
    ) async throws -> Bool {
        let versions = try await listVersions(appID: appID, platform: platform)
        return versions.contains { v in
            guard v.id != excludingVersionID else { return false }
            let state = v.attributes?.appStoreState ?? ""
            return Self.publiclyReleasedVersionStates.contains(state)
        }
    }

    /// PATCH `/v1/appStoreVersions/{id}` to attach a processed build
    /// to the version. Required for review submission — ASC rejects a
    /// reviewSubmission whose version has no build associated with it.
    /// The build must be in `processingState: "VALID"` (Apple's
    /// binary processing finished without issues) or the PATCH
    /// succeeds but the version still can't be submitted for review.
    package func attachBuild(versionID: String, buildID: String) async throws {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersions"
                let id: String
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct Build: Encodable {
                    struct BuildRef: Encodable { let type = "builds"; let id: String }
                    let data: BuildRef
                }
                let build: Build
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: versionID,
            relationships: .init(build: .init(data: .init(id: buildID)))
        ))
        struct Resp: Decodable { let data: Version }
        _ = try await client.patch(
            path: "appStoreVersions/\(versionID)",
            body: body,
            as: Resp.self
        )
    }

    // MARK: - Version localizations

    package struct Localization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let locale: String?
            package let description: String?
            package let keywords: String?
            package let marketingUrl: String?
            package let promotionalText: String?
            package let supportUrl: String?
            package let whatsNew: String?
        }
    }

    package func listLocalizations(versionID: String) async throws -> [Localization] {
        struct Resp: Decodable { let data: [Localization] }
        let resp: Resp = try await client.get(
            path: "appStoreVersions/\(versionID)/appStoreVersionLocalizations",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    package func findLocalization(versionID: String, locale: String) async throws -> Localization? {
        let all = try await listLocalizations(versionID: versionID)
        return all.first { $0.attributes?.locale == locale }
    }

    package func createLocalization(versionID: String, locale: String) async throws -> Localization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersionLocalizations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable { let locale: String }
            struct Rels: Encodable {
                struct V: Encodable {
                    struct Data: Encodable { let type = "appStoreVersions"; let id: String }
                    let data: Data
                }
                let appStoreVersion: V
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(locale: locale),
            relationships: .init(appStoreVersion: .init(data: .init(id: versionID)))
        ))
        struct Resp: Decodable { let data: Localization }
        let resp: Resp = try await client.post(
            path: "appStoreVersionLocalizations",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    package func findOrCreateLocalization(
        versionID: String,
        locale: String
    ) async throws -> Localization {
        if let existing = try await findLocalization(versionID: versionID, locale: locale) {
            return existing
        }
        return try await createLocalization(versionID: versionID, locale: locale)
    }

    // MARK: - App info + localization (privacy URL lives here)

    /// App-level info record. Has its own localizations that hold privacy
    /// URLs, subtitle, and name for the currently editable app-info version.
    package struct AppInfo: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package struct Attributes: Codable, Sendable {
            package let appStoreState: String?
            package let state: String?
        }
    }

    /// Lists appInfos for a given app. Usually returns one editable + one
    /// live record. The editable one is the target for PATCHing per-locale
    /// privacy URLs.
    package func listAppInfos(appID: String) async throws -> [AppInfo] {
        struct Resp: Decodable { let data: [AppInfo] }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/appInfos",
            query: ["limit": "10"],
            as: Resp.self
        )
        return resp.data
    }

    /// Finds the editable AppInfo for an app. The editable record has state
    /// like "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", etc. Apple also
    /// reports the same status under `appStoreState` on older API versions.
    package func findEditableAppInfo(appID: String) async throws -> AppInfo? {
        let editableStates: Set<String> = [
            "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
            "METADATA_REJECTED", "INVALID_BINARY", "WAITING_FOR_REVIEW",
            "IN_REVIEW",
        ]
        let infos = try await listAppInfos(appID: appID)
        // Prefer entries in an editable state; if nothing matches, fall back
        // to the first entry (Apple still accepts PATCH on some transient
        // states we may not have listed).
        if let editable = infos.first(where: {
            let s = $0.attributes?.state ?? $0.attributes?.appStoreState ?? ""
            return editableStates.contains(s)
        }) {
            return editable
        }
        return infos.first
    }

    package struct AppInfoLocalization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package struct Attributes: Codable, Sendable {
            package let locale: String?
            package let name: String?
            package let subtitle: String?
            package let privacyPolicyUrl: String?
            package let privacyChoicesUrl: String?
        }
    }

    package func listAppInfoLocalizations(appInfoID: String) async throws -> [AppInfoLocalization] {
        struct Resp: Decodable { let data: [AppInfoLocalization] }
        let resp: Resp = try await client.get(
            path: "appInfos/\(appInfoID)/appInfoLocalizations",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    package func findAppInfoLocalization(
        appInfoID: String, locale: String
    ) async throws -> AppInfoLocalization? {
        let all = try await listAppInfoLocalizations(appInfoID: appInfoID)
        return all.first { $0.attributes?.locale == locale }
    }

    package func createAppInfoLocalization(
        appInfoID: String, locale: String
    ) async throws -> AppInfoLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appInfoLocalizations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable { let locale: String }
            struct Rels: Encodable {
                struct I: Encodable {
                    struct Data: Encodable { let type = "appInfos"; let id: String }
                    let data: Data
                }
                let appInfo: I
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(locale: locale),
            relationships: .init(appInfo: .init(data: .init(id: appInfoID)))
        ))
        struct Resp: Decodable { let data: AppInfoLocalization }
        let resp: Resp = try await client.post(
            path: "appInfoLocalizations", body: body, as: Resp.self
        )
        return resp.data
    }

    package func findOrCreateAppInfoLocalization(
        appInfoID: String, locale: String
    ) async throws -> AppInfoLocalization {
        if let existing = try await findAppInfoLocalization(appInfoID: appInfoID, locale: locale) {
            return existing
        }
        return try await createAppInfoLocalization(appInfoID: appInfoID, locale: locale)
    }

    /// Fields that live on `appInfoLocalizations`. PATCHed onto the
    /// editable AppInfo's per-locale record. Nil fields are omitted from
    /// the wire body so they stay untouched on App Store Connect.
    package struct AppInfoLocalizationFields: Sendable, Equatable {
        package var name: String?
        package var subtitle: String?
        package var privacyPolicyURL: String?
        package var privacyChoicesURL: String?

        package init(
            name: String? = nil,
            subtitle: String? = nil,
            privacyPolicyURL: String? = nil,
            privacyChoicesURL: String? = nil
        ) {
            self.name = name
            self.subtitle = subtitle
            self.privacyPolicyURL = privacyPolicyURL
            self.privacyChoicesURL = privacyChoicesURL
        }

        package var hasAnyField: Bool {
            name != nil || subtitle != nil
                || privacyPolicyURL != nil || privacyChoicesURL != nil
        }
    }

    /// PATCH the app-info localization with any non-nil fields (name,
    /// subtitle, privacyPolicyUrl, privacyChoicesUrl). Nil leaves the
    /// existing ASC value untouched.
    @discardableResult
    package func updateAppInfoLocalization(
        id: String, fields: AppInfoLocalizationFields
    ) async throws -> AppInfoLocalization {
        struct AttrsPatch: Encodable {
            var name: String?
            var subtitle: String?
            var privacyPolicyUrl: String?
            var privacyChoicesUrl: String?
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appInfoLocalizations"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: AttrsPatch(
                name: fields.name,
                subtitle: fields.subtitle,
                privacyPolicyUrl: fields.privacyPolicyURL,
                privacyChoicesUrl: fields.privacyChoicesURL
            )
        ))
        struct Resp: Decodable { let data: AppInfoLocalization }
        let resp: Resp = try await client.patch(
            path: "appInfoLocalizations/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// Convenience wrapper kept for the privacy-only call sites still in
    /// the orchestrator. Forwards through `updateAppInfoLocalization(id:fields:)`.
    @discardableResult
    package func updateAppInfoLocalization(
        id: String, privacyPolicyURL: String?
    ) async throws -> AppInfoLocalization {
        try await updateAppInfoLocalization(
            id: id,
            fields: AppInfoLocalizationFields(privacyPolicyURL: privacyPolicyURL)
        )
    }

    // MARK: - Submit for review (reviewSubmissions API)

    package struct ReviewSubmission: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package struct Attributes: Codable, Sendable {
            package let state: String?
            package let platform: String?
            package let submittedDate: Date?
        }
    }

    package struct ReviewSubmissionItem: Codable, Sendable {
        package let id: String
    }

    /// Review-submission states that block creating a new submission for the
    /// same app + platform until they're cleared. ASC enforces "one open
    /// submission per platform"; if any of these are in flight, attaching the
    /// version to a brand-new submission fails with
    /// `STATE_ERROR.ENTITY_STATE_INVALID` ("appStoreVersions ... is not in
    /// valid state. Item is already present in [other-submission]").
    ///
    /// - `READY_FOR_REVIEW`: an open draft (no `submitted: true` PATCH yet).
    ///   Common after a previous `submit` run aborted between item-attach and
    ///   finalize.
    /// - `UNRESOLVED_ISSUES`: Apple rejected the prior submission. The
    ///   associated version stays "stuck inside" the rejected submission until
    ///   it's cancelled, blocking any resubmit of the same version.
    package static let cancellableReviewSubmissionStates: Set<String> = [
        "READY_FOR_REVIEW",
        "UNRESOLVED_ISSUES",
    ]

    /// Review-submission states that mean Apple is already actively reviewing
    /// (or about to review) the submission. We refuse to auto-cancel these
    /// because pulling them out from under Apple wastes a review slot and
    /// surprises the developer. Surface a loud error and let them cancel via
    /// the ASC web UI if they really mean it.
    package static let activeReviewSubmissionStates: Set<String> = [
        "WAITING_FOR_REVIEW",
        "IN_REVIEW",
    ]

    /// Lists `reviewSubmissions` for an app. ASC scopes them per-app via
    /// `filter[app]`. The response is unsorted; callers typically filter by
    /// `attributes.state` (see `cancellableReviewSubmissionStates`).
    package func listReviewSubmissions(
        appID: String,
        platform: String = "IOS"
    ) async throws -> [ReviewSubmission] {
        struct Resp: Decodable { let data: [ReviewSubmission] }
        let resp: Resp = try await client.get(
            path: "reviewSubmissions",
            query: [
                "filter[app]": appID,
                "filter[platform]": platform,
                "limit": "200",
            ],
            as: Resp.self
        )
        return resp.data
    }

    /// PATCH `canceled: true` on an in-flight `reviewSubmission`. Used to
    /// clear out a prior submission whose state is blocking a resubmit
    /// (`UNRESOLVED_ISSUES` after a rejection, or `READY_FOR_REVIEW` left
    /// behind by an aborted submit). ASC accepts the PATCH and transitions
    /// the submission to `CANCELING` then `COMPLETE` within a few seconds.
    ///
    /// Note: `DELETE /v1/reviewSubmissions/{id}` returns 403 from Apple's
    /// side regardless of submission state. The PATCH attribute path is the
    /// only programmatic cancel path that works.
    @discardableResult
    package func cancelReviewSubmission(id: String) async throws -> ReviewSubmission {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "reviewSubmissions"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { let canceled: Bool }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: .init(canceled: true)))
        struct Resp: Decodable { let data: ReviewSubmission }
        let resp: Resp = try await client.patch(
            path: "reviewSubmissions/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// GET `/v1/reviewSubmissions/{id}`: single-record fetch used to poll
    /// the `state` after a `cancel` PATCH (CANCELING then COMPLETE) so the
    /// follow-up create+attach sees a freed version.
    package func getReviewSubmission(id: String) async throws -> ReviewSubmission {
        struct Resp: Decodable { let data: ReviewSubmission }
        let resp: Resp = try await client.get(
            path: "reviewSubmissions/\(id)", as: Resp.self
        )
        return resp.data
    }

    /// Creates a new `reviewSubmission` for an app on a given platform.
    /// Step 1 of the 3-step submit flow.
    package func createReviewSubmission(
        appID: String,
        platform: String = "IOS"
    ) async throws -> ReviewSubmission {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "reviewSubmissions"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable { let platform: String }
            struct Rels: Encodable {
                struct A: Encodable {
                    struct Data: Encodable { let type = "apps"; let id: String }
                    let data: Data
                }
                let app: A
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(platform: platform),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: ReviewSubmission }
        let resp: Resp = try await client.post(
            path: "reviewSubmissions", body: body, as: Resp.self
        )
        return resp.data
    }

    /// Attaches an App Store Version to an in-progress reviewSubmission.
    /// Step 2 of the 3-step submit flow.
    @discardableResult
    package func addVersionToReviewSubmission(
        reviewSubmissionID: String,
        versionID: String
    ) async throws -> ReviewSubmissionItem {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "reviewSubmissionItems"
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct Sub: Encodable {
                    struct Data: Encodable { let type = "reviewSubmissions"; let id: String }
                    let data: Data
                }
                struct Ver: Encodable {
                    struct Data: Encodable { let type = "appStoreVersions"; let id: String }
                    let data: Data
                }
                let reviewSubmission: Sub
                let appStoreVersion: Ver
            }
            let data: Data
        }
        let body = Body(data: .init(
            relationships: .init(
                reviewSubmission: .init(data: .init(id: reviewSubmissionID)),
                appStoreVersion: .init(data: .init(id: versionID))
            )
        ))
        struct Resp: Decodable { let data: ReviewSubmissionItem }
        let resp: Resp = try await client.post(
            path: "reviewSubmissionItems", body: body, as: Resp.self
        )
        return resp.data
    }

    /// PATCH `submitted: true` to finalize a reviewSubmission. Step 3 of the
    /// 3-step submit flow. After this call the submission's state transitions
    /// to WAITING_FOR_REVIEW.
    @discardableResult
    package func finalizeReviewSubmission(id: String) async throws -> ReviewSubmission {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "reviewSubmissions"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { let submitted: Bool }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: .init(submitted: true)))
        struct Resp: Decodable { let data: ReviewSubmission }
        let resp: Resp = try await client.patch(
            path: "reviewSubmissions/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// Convenience: runs all three steps and returns the finalized submission.
    /// Matches the old `submitForReview` signature for callers. Prefer using
    /// the individual `createReviewSubmission` / `addVersionToReviewSubmission`
    /// / `finalizeReviewSubmission` steps when you need fine-grained error
    /// handling. The orchestrator does the latter so it can detect "version
    /// already attached to a stale rejected submission" and recover.
    @discardableResult
    package func submitForReview(
        appID: String,
        versionID: String,
        platform: String = "IOS"
    ) async throws -> ReviewSubmission {
        let submission = try await createReviewSubmission(appID: appID, platform: platform)
        _ = try await addVersionToReviewSubmission(
            reviewSubmissionID: submission.id, versionID: versionID
        )
        return try await finalizeReviewSubmission(id: submission.id)
    }

    // MARK: - App Store Review Detail (review notes + contact info)

    /// `appStoreReviewDetails` resource: per-version field bag for the
    /// "App Review Information" panel in the ASC web UI. Holds the review
    /// notes (the free-form text Apple's reviewers see when triaging) plus
    /// the contact info Apple uses if they need to reach the developer
    /// during review.
    package struct AppStoreReviewDetail: Codable, Sendable {
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

    /// GET the existing review detail record attached to a version. Returns
    /// nil when ASC hasn't materialized one yet (typical for a fresh
    /// version before any review-detail fields have been touched).
    package func getReviewDetail(versionID: String) async throws -> AppStoreReviewDetail? {
        struct Resp: Decodable {
            struct Data: Decodable { let id: String; let attributes: AppStoreReviewDetail.Attributes? }
            let data: Data?
        }
        do {
            let resp: Resp = try await client.get(
                path: "appStoreVersions/\(versionID)/appStoreReviewDetail",
                as: Resp.self
            )
            guard let d = resp.data else { return nil }
            return AppStoreReviewDetail(id: d.id, attributes: d.attributes)
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Creates an `appStoreReviewDetails` record attached to the version.
    /// Used when `getReviewDetail` returned nil.
    @discardableResult
    package func createReviewDetail(
        versionID: String,
        fields: ReviewDetailFields
    ) async throws -> AppStoreReviewDetail {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreReviewDetails"
                let attributes: AttrsPatch
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct V: Encodable {
                    struct Data: Encodable { let type = "appStoreVersions"; let id: String }
                    let data: Data
                }
                let appStoreVersion: V
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: AttrsPatch(fields: fields),
            relationships: .init(appStoreVersion: .init(data: .init(id: versionID)))
        ))
        struct Resp: Decodable { let data: AppStoreReviewDetail }
        let resp: Resp = try await client.post(
            path: "appStoreReviewDetails", body: body, as: Resp.self
        )
        return resp.data
    }

    /// PATCHes an existing review detail with any non-nil fields. Nil fields
    /// stay untouched.
    @discardableResult
    package func updateReviewDetail(
        id: String,
        fields: ReviewDetailFields
    ) async throws -> AppStoreReviewDetail {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreReviewDetails"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
        struct Resp: Decodable { let data: AppStoreReviewDetail }
        let resp: Resp = try await client.patch(
            path: "appStoreReviewDetails/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// Encodable shape used by both create and update bodies. Defined here
    /// (rather than reusing `ReviewDetailFields` directly) so the JSON keys
    /// match Apple's camelCase wire names and nil fields are omitted.
    private struct AttrsPatch: Encodable {
        var contactFirstName: String?
        var contactLastName: String?
        var contactPhone: String?
        var contactEmail: String?
        var demoAccountName: String?
        var demoAccountPassword: String?
        var demoAccountRequired: Bool?
        var notes: String?

        init(fields: ReviewDetailFields) {
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

    // MARK: - Version localization update (original)

    /// PATCH the localization with any non-nil fields. Nil fields are omitted
    /// so existing values stay untouched.
    @discardableResult
    package func updateLocalization(
        id: String,
        fields: LocalizationFields
    ) async throws -> Localization {
        struct AttrsPatch: Encodable {
            var description: String?
            var keywords: String?
            var marketingUrl: String?
            var promotionalText: String?
            var supportUrl: String?
            var whatsNew: String?
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersionLocalizations"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let attrs = AttrsPatch(
            description: fields.description,
            keywords: fields.keywords,
            marketingUrl: fields.marketingURL,
            promotionalText: fields.promotionalText,
            supportUrl: fields.supportURL,
            whatsNew: fields.whatsNew
        )
        let body = Body(data: .init(id: id, attributes: attrs))
        struct Resp: Decodable { let data: Localization }
        let resp: Resp = try await client.patch(
            path: "appStoreVersionLocalizations/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }
}
