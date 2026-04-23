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
