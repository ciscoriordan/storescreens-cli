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

    /// PATCH the app-info localization's privacy URL. Nil leaves the existing
    /// value untouched.
    @discardableResult
    package func updateAppInfoLocalization(
        id: String, privacyPolicyURL: String?
    ) async throws -> AppInfoLocalization {
        struct AttrsPatch: Encodable { var privacyPolicyUrl: String? }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appInfoLocalizations"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: .init(privacyPolicyUrl: privacyPolicyURL)
        ))
        struct Resp: Decodable { let data: AppInfoLocalization }
        let resp: Resp = try await client.patch(
            path: "appInfoLocalizations/\(id)", body: body, as: Resp.self
        )
        return resp.data
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
    /// Matches the old `submitForReview` signature for callers.
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
