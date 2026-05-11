import Foundation

// MARK: - Apple Pay API

/// App Store Connect endpoints for the Apple Pay surface: pass type IDs
/// (the dotted identifiers like `pass.com.example.myapp`), the certificates
/// signed against those pass type IDs, and the merchant domains a team
/// claims for Apple Pay on the Web.
///
/// The Apple Pay endpoints are split across three small JSON:API resources;
/// we wrap each one as a method group on `ApplePayAPI` so callers can use
/// them in sequence (e.g. create a pass type id, then submit a CSR to mint
/// a signed certificate for that pass type id).
///
/// Docs:
///   - https://developer.apple.com/documentation/appstoreconnectapi/pass_type_ids
///   - https://developer.apple.com/documentation/appstoreconnectapi/pass_type_id_certificates
///   - https://developer.apple.com/documentation/appstoreconnectapi/merchant_domains
package struct ApplePayAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Pass Type IDs

    /// One pass type identifier. The `identifier` is the user-visible dotted
    /// string ("pass.com.example.myapp") that Wallet uses to namespace passes;
    /// the `id` is ASC's internal database id for relationships.
    package struct PassTypeID: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let identifier: String?
            package let name: String?
        }
    }

    /// Lists pass type identifiers on the team. Paginated.
    package func listPassTypeIDs(
        limit: Int = 200,
        cursor: String? = nil,
        filterIdentifier: String? = nil
    ) async throws -> (passTypeIDs: [PassTypeID], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        if let filterIdentifier { query["filter[identifier]"] = filterIdentifier }
        struct Resp: Decodable {
            let data: [PassTypeID]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "passTypeIds",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/passTypeIds/{id}`. Returns nil on 404.
    package func getPassTypeID(id: String) async throws -> PassTypeID? {
        struct Resp: Decodable { let data: PassTypeID }
        do {
            let resp: Resp = try await client.get(
                path: "passTypeIds/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Looks up a pass type identifier by its dotted string
    /// ("pass.com.example.myapp"). Returns nil if no match.
    package func findPassTypeID(identifier: String) async throws -> PassTypeID? {
        let (matches, _) = try await listPassTypeIDs(
            limit: 1, filterIdentifier: identifier
        )
        return matches.first
    }

    /// Creates a new pass type identifier. The `identifier` must begin with
    /// "pass." and use reverse-DNS notation (e.g. "pass.com.example.myapp").
    /// `name` is the human-readable label for the developer portal.
    package func createPassTypeID(
        identifier: String,
        name: String
    ) async throws -> PassTypeID {
        struct Attrs: Encodable {
            let identifier: String
            let name: String
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "passTypeIds"
                let attributes: Attrs
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(identifier: identifier, name: name)
        ))
        struct Resp: Decodable { let data: PassTypeID }
        let resp: Resp = try await client.post(
            path: "passTypeIds", body: body, as: Resp.self
        )
        return resp.data
    }

    /// PATCH `/v1/passTypeIds/{id}` to rename the pass type id's display
    /// label. The dotted `identifier` itself is immutable.
    @discardableResult
    package func updatePassTypeID(id: String, name: String) async throws -> PassTypeID {
        struct AttrsPatch: Encodable { let name: String }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "passTypeIds"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: AttrsPatch(name: name)
        ))
        struct Resp: Decodable { let data: PassTypeID }
        let resp: Resp = try await client.patch(
            path: "passTypeIds/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/passTypeIds/{id}`. Apple blocks deletion when any signed
    /// certificates still reference the pass type id; revoke certificates
    /// first.
    package func deletePassTypeID(id: String) async throws {
        try await client.delete(path: "passTypeIds/\(id)")
    }

    // MARK: - Pass Type ID Certificates

    /// A certificate signed against a pass type id. Apple uses these to sign
    /// `.pkpass` bundles; each pass type id can have multiple certificates
    /// (typically one active and one on deck for rotation).
    package struct PassTypeIDCertificate: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let certificateContent: String?
            package let displayName: String?
            package let expirationDate: Date?
            package let name: String?
            package let platform: String?
            package let serialNumber: String?
            package let certificateType: String?
        }
    }

    /// Lists certificates signed against a specific pass type id. Paginated.
    package func listPassTypeIDCertificates(
        passTypeIDDatabaseID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (certificates: [PassTypeIDCertificate], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        struct Resp: Decodable {
            let data: [PassTypeIDCertificate]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "passTypeIds/\(passTypeIDDatabaseID)/certificates",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/passTypeIdCertificates/{id}`. Returns nil on 404. Includes
    /// the base64-encoded `certificateContent` which callers save to a
    /// `.cer` file for importing into Keychain Access.
    package func getPassTypeIDCertificate(id: String) async throws -> PassTypeIDCertificate? {
        struct Resp: Decodable { let data: PassTypeIDCertificate }
        do {
            let resp: Resp = try await client.get(
                path: "passTypeIdCertificates/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Creates a pass type id certificate by submitting a Certificate Signing
    /// Request. The CSR must be PEM, base64-encoded. Apple signs the request
    /// using the pass type id's seed material and returns the certificate
    /// data in `attributes.certificateContent`. Pass that to a `.cer` file to
    /// import into Keychain Access or use directly with `openssl` to sign
    /// `.pkpass` payloads.
    package func createPassTypeIDCertificate(
        passTypeIDDatabaseID: String,
        csrContent: String
    ) async throws -> PassTypeIDCertificate {
        struct Attrs: Encodable {
            let csrContent: String
        }
        struct PassTypeRef: Encodable {
            struct D: Encodable { let type = "passTypeIds"; let id: String }
            let data: D
        }
        struct Rels: Encodable { let passTypeId: PassTypeRef }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "passTypeIdCertificates"
                let attributes: Attrs
                let relationships: Rels
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(csrContent: csrContent),
            relationships: .init(passTypeId: .init(data: .init(id: passTypeIDDatabaseID)))
        ))
        struct Resp: Decodable { let data: PassTypeIDCertificate }
        let resp: Resp = try await client.post(
            path: "passTypeIdCertificates", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/passTypeIdCertificates/{id}`. Revokes the certificate;
    /// passes signed by it stay valid until the binary signature expires on
    /// its own schedule.
    package func revokePassTypeIDCertificate(id: String) async throws {
        try await client.delete(path: "passTypeIdCertificates/\(id)")
    }

    // MARK: - Merchant Domains

    /// One Apple Pay for the Web merchant domain. Apple expects the domain
    /// to host a `.well-known/apple-developer-merchantid-domain-association`
    /// file to prove ownership before validation succeeds.
    package struct MerchantDomain: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let domain: String?
            /// `VERIFIED`, `UNVERIFIED`, `VERIFY_FAILED`, etc.
            package let domainState: String?
        }
    }

    /// Lists Apple Pay merchant domains the team has claimed. Paginated.
    package func listMerchantDomains(
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (merchantDomains: [MerchantDomain], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        struct Resp: Decodable {
            let data: [MerchantDomain]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "merchantDomains",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/merchantDomains/{id}`. Returns nil on 404.
    package func getMerchantDomain(id: String) async throws -> MerchantDomain? {
        struct Resp: Decodable { let data: MerchantDomain }
        do {
            let resp: Resp = try await client.get(
                path: "merchantDomains/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Claims a new merchant domain for Apple Pay on the Web. Apple does NOT
    /// validate the domain at creation time, callers must follow up with
    /// `validateMerchantDomain(id:)` after hosting the well-known association
    /// file at the claimed URL.
    package func createMerchantDomain(domain: String) async throws -> MerchantDomain {
        struct Attrs: Encodable { let domain: String }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "merchantDomains"
                let attributes: Attrs
            }
            let data: Data
        }
        let body = Body(data: .init(attributes: .init(domain: domain)))
        struct Resp: Decodable { let data: MerchantDomain }
        let resp: Resp = try await client.post(
            path: "merchantDomains", body: body, as: Resp.self
        )
        return resp.data
    }

    /// Triggers Apple to fetch the well-known association file at the
    /// claimed domain and verify ownership. PATCH with `verify: true` flips
    /// the merchant domain into `VERIFIED` state on success. On failure the
    /// state moves to `VERIFY_FAILED` and the caller can retry after fixing
    /// the well-known file.
    @discardableResult
    package func validateMerchantDomain(id: String) async throws -> MerchantDomain {
        struct AttrsPatch: Encodable { let verify: Bool }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "merchantDomains"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: AttrsPatch(verify: true)
        ))
        struct Resp: Decodable { let data: MerchantDomain }
        let resp: Resp = try await client.patch(
            path: "merchantDomains/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/merchantDomains/{id}`. Revokes the domain claim; web
    /// payments on that domain will stop working immediately.
    package func deleteMerchantDomain(id: String) async throws {
        try await client.delete(path: "merchantDomains/\(id)")
    }
}

// MARK: - Sandbox Testers API

/// App Store Connect endpoints for sandbox testers (the synthetic user
/// accounts Apple maintains for testing in-app purchases without real
/// charges). Apple does not let you create or delete sandbox testers via
/// the API: they're created through the App Store Connect web UI under
/// "Users and Access > Sandbox > Testers". This wrapper exposes only the
/// read + per-tester action endpoints.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/sandbox_testers
package struct SandboxTestersAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    /// String values Apple uses for `subscriptionRenewalRate`. The renewal
    /// rate is how aggressively Apple simulates renewals in sandbox; the
    /// default `REAL_TIME` matches production timing exactly.
    package enum SubscriptionRenewalRate {
        package static let realTime    = "REAL_TIME"
        package static let oneTime     = "ONE_TIME"
        package static let oneHour     = "ONE_HOUR"
        package static let thirtyMinutes = "THIRTY_MINUTES"
        package static let fifteenMinutes = "FIFTEEN_MINUTES"
        package static let fiveMinutes = "FIVE_MINUTES"

        package static let known: Set<String> = [
            realTime, oneTime, oneHour, thirtyMinutes, fifteenMinutes,
            fiveMinutes,
        ]
    }

    /// One sandbox tester record. Apple intentionally omits the email
    /// address and password from the API response, only the per-tester
    /// id and a small subset of profile fields surface here.
    package struct SandboxTester: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let firstName: String?
            package let lastName: String?
            /// Apple App Store territory the tester is registered against
            /// (e.g. "USA", "GBR"). Determines which storefront pricing and
            /// availability the tester sees.
            package let territory: String?
            /// IETF locale (e.g. "en-US", "fr-CA"). Determines language and
            /// formatting in the tester's sandbox storefront.
            package let locale: String?
            /// "REAL_TIME", "ONE_TIME", "ONE_HOUR", "THIRTY_MINUTES",
            /// "FIFTEEN_MINUTES", "FIVE_MINUTES".
            package let subscriptionRenewalRate: String?
        }
    }

    /// Lists sandbox testers on the team. Paginated. Filter by territory
    /// (e.g. "USA") or by subscription renewal rate.
    package func listSandboxTesters(
        limit: Int = 200,
        cursor: String? = nil,
        filterTerritory: String? = nil,
        filterRenewalRate: String? = nil
    ) async throws -> (testers: [SandboxTester], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        if let filterTerritory { query["filter[territory]"] = filterTerritory }
        if let filterRenewalRate {
            query["filter[subscriptionRenewalRate]"] = filterRenewalRate
        }
        struct Resp: Decodable {
            let data: [SandboxTester]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "sandboxTesters",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/sandboxTesters/{id}`. Returns nil on 404.
    package func getSandboxTester(id: String) async throws -> SandboxTester? {
        struct Resp: Decodable { let data: SandboxTester }
        do {
            let resp: Resp = try await client.get(
                path: "sandboxTesters/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Clears a sandbox tester's accumulated purchase history. Useful when
    /// re-running an IAP flow that gates state on whether the tester has
    /// already bought the product. POST `/v1/sandboxTesters/{id}/clearPurchaseHistoryRequest`
    /// returns a single-record action envelope; we discard the body and
    /// treat the call as a fire-and-forget side effect.
    package func clearPurchaseHistory(testerID: String) async throws {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "sandboxTesterClearPurchaseHistoryRequest"
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct T: Encodable {
                    struct Data: Encodable { let type = "sandboxTesters"; let id: String }
                    let data: Data
                }
                let sandboxTester: T
            }
            let data: Data
        }
        let body = Body(data: .init(
            relationships: .init(sandboxTester: .init(data: .init(id: testerID)))
        ))
        struct Resp: Decodable { struct D: Decodable { let id: String? }; let data: D? }
        _ = try await client.post(
            path: "sandboxTestersClearPurchaseHistoryRequest",
            body: body,
            as: Resp.self
        )
    }

    /// Changes how aggressively Apple simulates subscription renewals for a
    /// sandbox tester. `rate` accepts `REAL_TIME`, `ONE_TIME`, `ONE_HOUR`,
    /// `THIRTY_MINUTES`, `FIFTEEN_MINUTES`, `FIVE_MINUTES`. Useful when you
    /// want to test renewal flows without waiting real-world time. PATCHes
    /// the sandbox tester directly.
    @discardableResult
    package func modifySubscriptionRenewalRate(
        testerID: String,
        rate: String
    ) async throws -> SandboxTester {
        struct AttrsPatch: Encodable { let subscriptionRenewalRate: String }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "sandboxTesters"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: testerID, attributes: AttrsPatch(subscriptionRenewalRate: rate)
        ))
        struct Resp: Decodable { let data: SandboxTester }
        let resp: Resp = try await client.patch(
            path: "sandboxTesters/\(testerID)", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: - Sandbox Tester Apps

    /// Junction record describing one sandbox tester's access to a single
    /// app. Apple uses this to scope which testers can purchase which apps
    /// during sandbox flows (typically all testers see all apps, but the
    /// team can opt into a narrower configuration).
    package struct SandboxTesterApp: Codable, Sendable {
        package let id: String
    }

    /// Lists sandbox-tester / app junction records scoped to a specific
    /// app. Each record identifies a tester that has access to the app.
    package func listSandboxTesterApps(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (testerApps: [SandboxTesterApp], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        struct Resp: Decodable {
            let data: [SandboxTesterApp]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/sandboxTesterApps",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/sandboxTesterApps/{id}`. Returns nil on 404.
    package func getSandboxTesterApp(id: String) async throws -> SandboxTesterApp? {
        struct Resp: Decodable { let data: SandboxTesterApp }
        do {
            let resp: Resp = try await client.get(
                path: "sandboxTesterApps/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }
}

// MARK: - Resource Limits API

/// App Store Connect endpoint for `resourceLimits`: read-only team quota
/// records that report the team's caps on apps, in-app purchases per app,
/// users per team, etc. Useful as a precursor to "can I create another
/// app on this team?" workflows.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/resource_limits
package struct ResourceLimitsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    /// One quota record. The `limitType` is the slot identifier (e.g.
    /// "MAX_APPS_PER_TEAM", "MAX_USERS_PER_TEAM"). `currentValue` is the
    /// team's present usage; `limit` is the max Apple allows.
    package struct ResourceLimit: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Apple's quota key (e.g. "MAX_APPS_PER_TEAM",
            /// "MAX_IN_APP_PURCHASES_PER_APP", "MAX_USERS_PER_TEAM").
            package let limitType: String?
            /// Numeric ceiling Apple enforces.
            package let limit: Int?
            /// Team's current count against the ceiling.
            package let currentValue: Int?
        }
    }

    /// Lists all resource limit records for the team. Apple returns the
    /// full set in one page; pagination args are present for API symmetry.
    package func listResourceLimits(
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (resourceLimits: [ResourceLimit], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        struct Resp: Decodable {
            let data: [ResourceLimit]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "resourceLimits",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/resourceLimits/{id}`. Returns nil on 404.
    package func getResourceLimit(id: String) async throws -> ResourceLimit? {
        struct Resp: Decodable { let data: ResourceLimit }
        do {
            let resp: Resp = try await client.get(
                path: "resourceLimits/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }
}

// MARK: - App Hashes API

/// App Store Connect endpoint for `appHashes`: read-only cryptographic
/// hash records Apple maintains for each app, used during identifier or
/// signing migrations to verify the app binary chain.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/app_hashes
package struct AppHashesAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    package struct AppHash: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Hex-encoded hash value Apple computed.
            package let hash: String?
            /// Hash algorithm Apple used (e.g. "SHA256").
            package let hashAlgorithm: String?
            /// When this hash was generated.
            package let createdDate: Date?
        }
    }

    /// Lists app hashes scoped to a specific app. Paginated. Apple emits
    /// one hash per signing event during migrations; teams typically have
    /// a single record.
    package func listAppHashes(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (appHashes: [AppHash], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        struct Resp: Decodable {
            let data: [AppHash]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/appHashes",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/appHashes/{id}`. Returns nil on 404.
    package func getAppHash(id: String) async throws -> AppHash? {
        struct Resp: Decodable { let data: AppHash }
        do {
            let resp: Resp = try await client.get(
                path: "appHashes/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }
}

// MARK: - Diagnostic Sessions API

/// App Store Connect endpoints for `profileDiagnosticSessions`: per-build
/// app sessions that Xcode Instruments uses for power and performance
/// diagnostics. Each session represents one period during which Apple's
/// device telemetry collects diagnostic samples against a specific build.
///
/// Note: the related `perfPowerMetrics` (per-app + per-build performance
/// snapshots) and `diagnosticSignatures` (crash / hang signature rollups)
/// endpoints already live in `ReportsAPI.MetricsAPI`. This wrapper covers
/// only the session lifecycle: list, get, create, complete.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/profile_diagnostic_sessions
package struct DiagnosticSessionsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    /// String values Apple uses for `profileDiagnosticSessions.state`.
    package enum State {
        /// Apple is actively collecting telemetry against this session.
        package static let inProgress = "IN_PROGRESS"
        /// The session has been marked complete and is no longer accepting
        /// new samples.
        package static let complete = "COMPLETE"

        package static let known: Set<String> = [inProgress, complete]
    }

    /// One diagnostic session record.
    package struct ProfileDiagnosticSession: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Optional human-readable label for the session (e.g.
            /// "After launch", "After image load").
            package let name: String?
            /// Apple's session state, `IN_PROGRESS` or `COMPLETE`.
            package let state: String?
            /// When the session began collecting samples.
            package let createdDate: Date?
            /// When the session was marked complete; nil while in progress.
            package let endedDate: Date?
            /// Apple's device family identifier the session targets (e.g.
            /// "IPHONE", "IPAD"). Determines which device-specific metrics
            /// Apple emits.
            package let deviceFamily: String?
        }
    }

    /// Lists diagnostic sessions for an app. Paginated. Filter by state
    /// ("IN_PROGRESS", "COMPLETE") when triaging which session is still
    /// collecting data.
    package func listProfileDiagnosticSessions(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil,
        filterState: String? = nil
    ) async throws -> (sessions: [ProfileDiagnosticSession], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        if let filterState { query["filter[state]"] = filterState }
        struct Resp: Decodable {
            let data: [ProfileDiagnosticSession]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/profileDiagnosticSessions",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/profileDiagnosticSessions/{id}`. Returns nil on 404.
    package func getProfileDiagnosticSession(
        id: String
    ) async throws -> ProfileDiagnosticSession? {
        struct Resp: Decodable { let data: ProfileDiagnosticSession }
        do {
            let resp: Resp = try await client.get(
                path: "profileDiagnosticSessions/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Creates a new diagnostic session against a specific build. Apple
    /// scopes the session to one build + device-family pair; callers spin
    /// up multiple sessions to compare across device families. Optional
    /// `name` is a free-form label that shows up in Xcode Instruments.
    package func createProfileDiagnosticSession(
        buildID: String,
        deviceFamily: String? = nil,
        name: String? = nil
    ) async throws -> ProfileDiagnosticSession {
        struct AttrsCreate: Encodable {
            var name: String?
            var deviceFamily: String?
        }
        struct BuildRef: Encodable {
            struct D: Encodable { let type = "builds"; let id: String }
            let data: D
        }
        struct Rels: Encodable { let build: BuildRef }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "profileDiagnosticSessions"
                let attributes: AttrsCreate
                let relationships: Rels
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: AttrsCreate(name: name, deviceFamily: deviceFamily),
            relationships: .init(build: .init(data: .init(id: buildID)))
        ))
        struct Resp: Decodable { let data: ProfileDiagnosticSession }
        let resp: Resp = try await client.post(
            path: "profileDiagnosticSessions", body: body, as: Resp.self
        )
        return resp.data
    }

    /// Marks an in-progress session as complete. PATCHes `state: "COMPLETE"`
    /// on the session, stopping further sample collection. Sessions left in
    /// `IN_PROGRESS` indefinitely still time out on Apple's side after a
    /// few hours, but completing them explicitly frees the slot sooner.
    @discardableResult
    package func completeProfileDiagnosticSession(
        id: String
    ) async throws -> ProfileDiagnosticSession {
        struct AttrsPatch: Encodable { let state: String }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "profileDiagnosticSessions"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: AttrsPatch(state: State.complete)
        ))
        struct Resp: Decodable { let data: ProfileDiagnosticSession }
        let resp: Resp = try await client.patch(
            path: "profileDiagnosticSessions/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/profileDiagnosticSessions/{id}`. Removes the session
    /// record; any sampled metrics already collected stay on the
    /// `perfPowerMetrics` resource attached to the build.
    package func deleteProfileDiagnosticSession(id: String) async throws {
        try await client.delete(path: "profileDiagnosticSessions/\(id)")
    }
}
