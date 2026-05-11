import Foundation

/// App Store Connect endpoints covering Alternative Distribution (the
/// EU DMA mandate that lets developers ship iOS apps outside the App
/// Store via approved marketplaces or developer-direct distribution).
///
/// This surface is only relevant for developers who have registered
/// with Apple for the EU Alternative Distribution program. Standard
/// App Store flows are untouched by these endpoints.
///
/// Resources wrapped here, with the JSON:API types Apple documents:
///
///   - alternativeDistributionKeys: the public-key signing material
///     Apple uses to verify packages the developer uploads. List/get/
///     create/update/delete.
///   - alternativeDistributionPackages: a per-app package container
///     that points at a notarized binary. List per app + CRUD.
///   - alternativeDistributionPackageVersions: each version of the
///     package, with a state machine (CREATED -> COMPLETED -> ENABLED
///     /DISABLED + REPLACED on supersede). Submission state changes
///     happen via PATCH state.
///   - alternativeDistributionPackageDeltas: read-only binary diffs
///     between two package versions, used for incremental downloads.
///   - alternativeDistributionPackageVariants: read-only per-
///     architecture/variant slices of a single package version.
///   - alternativeDistributionDomains: the developer's verified
///     distribution domain(s). Apple uses these to scope where
///     download links can live. CRUD.
///   - marketplaceSearchDetails: the marketplace-side metadata that
///     appears when the app is searched in a marketplace's catalog
///     (subtitle, support / privacy / marketing URLs, seller name).
///     Get + update per app.
///   - marketplaceWebhooks: webhook URLs Apple POSTs distribution
///     events to (install/uninstall/etc). CRUD.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi
/// (Alternative Distribution section)
///
/// Pagination convention: every list endpoint accepts an optional
/// `limit` and `cursor` and returns `(data, nextCursor)`. The cursor
/// is Apple's opaque `links.next` continuation token; pass it back
/// unchanged on the next call. When `nextCursor` is nil, the caller
/// has reached the end of the list.
///
/// Master struct + nested namespaces pattern (mirrors TestFlightAPI's
/// shape from the Wave 1 surface):
///
///   let api = AltDistributionAPI(client: client)
///   try await api.keys.list(limit: 50)
///   try await api.packages.list(appID: "123")
///   try await api.packageVersions.activate(id: "v-1")
///
package struct AltDistributionAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Nested namespaces

    /// Signing keys Apple uses to verify packages.
    package var keys: Keys { Keys(client: client) }
    /// Per-app distribution package container.
    package var packages: Packages { Packages(client: client) }
    /// Versions of a package, with submission lifecycle.
    package var packageVersions: PackageVersions { PackageVersions(client: client) }
    /// Read-only binary diffs between two versions.
    package var packageDeltas: PackageDeltas { PackageDeltas(client: client) }
    /// Read-only per-architecture/variant slices.
    package var packageVariants: PackageVariants { PackageVariants(client: client) }
    /// Verified developer distribution domains.
    package var domains: Domains { Domains(client: client) }
    /// Marketplace search-catalog metadata per app.
    package var marketplaceSearch: MarketplaceSearch { MarketplaceSearch(client: client) }
    /// Marketplace webhook subscriptions.
    package var marketplaceWebhooks: MarketplaceWebhooks { MarketplaceWebhooks(client: client) }

    // MARK: - Shared paged response shape

    /// Generic JSON:API page envelope. Apple returns `links.next` as a
    /// full URL with a base64-encoded `cursor=` query parameter; we
    /// extract the cursor value so callers can pass it back on
    /// subsequent calls without parsing the URL themselves.
    package struct Page<Item: Codable & Sendable>: Sendable {
        package let data: [Item]
        package let nextCursor: String?
    }

    /// Internal helper: decodes a JSON:API list response and pulls
    /// out the `cursor=` parameter from `links.next` if present.
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

    // MARK: - alternativeDistributionKeys

    /// A public signing key the developer has registered with Apple
    /// for verifying distribution packages. Apple stores only the
    /// public side; the developer keeps the private key locally.
    package struct Key: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// PEM-encoded public key (the developer's half of the
            /// keypair Apple uses to verify package signatures).
            package let publicKey: String?
            /// SHA-256 fingerprint of the public key, hex-encoded.
            /// Useful when verifying which key Apple has on file.
            package let sha256Fingerprint: String?
        }
    }

    /// Top-level namespace for alternativeDistributionKeys endpoints.
    package struct Keys {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        /// Lists keys registered on the team. Use `cursor` to page.
        package func list(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Key> {
            let resp: PageEnvelope<Key> = try await client.get(
                path: "alternativeDistributionKeys",
                query: AltDistributionAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Key>.self
            )
            return .init(data: resp.data, nextCursor: AltDistributionAPI.extractCursor(from: resp.links?.next))
        }

        /// Fetches a single key by id. Returns nil on 404.
        package func get(id: String) async throws -> Key? {
            struct Resp: Decodable { let data: Key }
            do {
                let resp: Resp = try await client.get(
                    path: "alternativeDistributionKeys/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Registers a new public key with Apple. `publicKey` is the
        /// PEM-encoded public-key block the developer extracted from
        /// their signing keypair.
        @discardableResult
        package func create(publicKey: String) async throws -> Key {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "alternativeDistributionKeys"
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let publicKey: String
                }
                let data: Data
            }
            let body = Body(data: .init(attributes: .init(publicKey: publicKey)))
            struct Resp: Decodable { let data: Key }
            let resp: Resp = try await client.post(
                path: "alternativeDistributionKeys",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        /// PATCH a key's public-key material (key rotation).
        @discardableResult
        package func update(id: String, publicKey: String) async throws -> Key {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "alternativeDistributionKeys"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let publicKey: String
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(publicKey: publicKey)))
            struct Resp: Decodable { let data: Key }
            let resp: Resp = try await client.patch(
                path: "alternativeDistributionKeys/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "alternativeDistributionKeys/\(id)")
        }
    }

    // MARK: - alternativeDistributionPackages

    /// A per-app container that hangs a sequence of distribution
    /// package versions off a given app. There is at most one package
    /// per app at any time.
    package struct Package: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// The marketing version string the package describes
            /// (e.g. "1.2.0"). Mirrors the App Store's `versionString`
            /// for the same train.
            package let versionString: String?
            /// URL the developer hosts the notarized binary at.
            /// Apple does not host the binary itself for alternative
            /// distribution; the developer is responsible for hosting.
            package let url: String?
        }
    }

    package struct Packages {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        /// Lists packages for an app. There is typically only one,
        /// but the endpoint is plural so we expose it as a page.
        package func list(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Package> {
            let resp: PageEnvelope<Package> = try await client.get(
                path: "apps/\(appID)/alternativeDistributionPackages",
                query: AltDistributionAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Package>.self
            )
            return .init(data: resp.data, nextCursor: AltDistributionAPI.extractCursor(from: resp.links?.next))
        }

        package func get(id: String) async throws -> Package? {
            struct Resp: Decodable { let data: Package }
            do {
                let resp: Resp = try await client.get(
                    path: "alternativeDistributionPackages/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Creates a package for `appID`. The package itself is the
        /// container; individual version slices and their state
        /// machine live on alternativeDistributionPackageVersions.
        @discardableResult
        package func create(appID: String) async throws -> Package {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "alternativeDistributionPackages"
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
            let body = Body(data: .init(
                relationships: .init(app: .init(data: .init(id: appID)))
            ))
            struct Resp: Decodable { let data: Package }
            let resp: Resp = try await client.post(
                path: "alternativeDistributionPackages",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "alternativeDistributionPackages/\(id)")
        }
    }

    // MARK: - alternativeDistributionPackageVersions

    /// One version of a distribution package. Apple maintains a
    /// state machine here:
    ///   - CREATED: the version record exists, Apple hasn't
    ///     finished ingesting / notarizing the binary yet
    ///   - REPLACED: superseded by a newer version of the same
    ///     package; older binaries get archived to this state
    ///   - COMPLETED: ingest done, ready to activate
    ///   - ENABLED: live for end users
    ///   - DISABLED: explicitly taken offline
    ///
    /// State changes happen via PATCH state on the version record.
    /// Apple may also auto-transition between states (e.g. a new
    /// upload moves prior versions to REPLACED on its own).
    package struct PackageVersion: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Developer-hosted URL of the notarized package binary.
            package let url: String?
            /// SHA-256 file checksum Apple computed at ingest time.
            /// Used to confirm the binary the developer hosts is
            /// what Apple verified.
            package let fileChecksum: String?
            /// "CREATED", "REPLACED", "COMPLETED", "ENABLED", "DISABLED".
            package let state: String?
            /// Marketing version string for this package version
            /// (e.g. "1.2.0").
            package let version: String?
        }
    }

    /// Documented state values for an alternativeDistributionPackageVersion.
    /// Exposed as a Swift enum so callers can use type-safe comparisons
    /// without re-typing raw strings.
    package enum PackageVersionState: String, Sendable, Codable {
        case created = "CREATED"
        case replaced = "REPLACED"
        case completed = "COMPLETED"
        case enabled = "ENABLED"
        case disabled = "DISABLED"
    }

    package struct PackageVersions {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        /// Lists versions for a given package. Use `state` to filter.
        package func list(
            packageID: String,
            state: PackageVersionState? = nil,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PackageVersion> {
            var extras: [String: String] = [:]
            if let state {
                extras["filter[state]"] = state.rawValue
            }
            let resp: PageEnvelope<PackageVersion> = try await client.get(
                path: "alternativeDistributionPackages/\(packageID)/alternativeDistributionPackageVersions",
                query: AltDistributionAPI.listQuery(limit: limit, cursor: cursor, extras: extras),
                as: PageEnvelope<PackageVersion>.self
            )
            return .init(data: resp.data, nextCursor: AltDistributionAPI.extractCursor(from: resp.links?.next))
        }

        package func get(id: String) async throws -> PackageVersion? {
            struct Resp: Decodable { let data: PackageVersion }
            do {
                let resp: Resp = try await client.get(
                    path: "alternativeDistributionPackageVersions/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Creates a new package version pointing at `url`. Apple will
        /// pull the binary from `url`, notarize it, and transition the
        /// resource through CREATED -> COMPLETED. The version is not
        /// live yet until the caller activates it (PATCH state =
        /// ENABLED, or call `activate`).
        @discardableResult
        package func create(
            packageID: String,
            url: String,
            version: String? = nil
        ) async throws -> PackageVersion {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "alternativeDistributionPackageVersions"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let url: String
                    var version: String?
                }
                struct Rels: Encodable {
                    struct Pkg: Encodable {
                        struct D: Encodable {
                            let type = "alternativeDistributionPackages"
                            let id: String
                        }
                        let data: D
                    }
                    let alternativeDistributionPackage: Pkg
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(url: url, version: version),
                relationships: .init(
                    alternativeDistributionPackage: .init(data: .init(id: packageID))
                )
            ))
            struct Resp: Decodable { let data: PackageVersion }
            let resp: Resp = try await client.post(
                path: "alternativeDistributionPackageVersions",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        /// PATCH a version's state. Use this for any state transition
        /// Apple allows from the current state (typically COMPLETED ->
        /// ENABLED or ENABLED <-> DISABLED). For the common shortcuts,
        /// prefer `activate` / `disable` / `validate`.
        @discardableResult
        package func updateState(
            id: String,
            state: PackageVersionState
        ) async throws -> PackageVersion {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "alternativeDistributionPackageVersions"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { let state: String }
                let data: Data
            }
            let body = Body(data: .init(
                id: id, attributes: .init(state: state.rawValue)
            ))
            struct Resp: Decodable { let data: PackageVersion }
            let resp: Resp = try await client.patch(
                path: "alternativeDistributionPackageVersions/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        /// PATCH-update arbitrary mutable attributes on a version
        /// record (currently only `url` and `state` are mutable; nil
        /// fields are omitted from the wire body).
        @discardableResult
        package func update(
            id: String,
            url: String? = nil,
            state: PackageVersionState? = nil
        ) async throws -> PackageVersion {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "alternativeDistributionPackageVersions"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    var url: String?
                    var state: String?
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(url: url, state: state?.rawValue)
            ))
            struct Resp: Decodable { let data: PackageVersion }
            let resp: Resp = try await client.patch(
                path: "alternativeDistributionPackageVersions/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "alternativeDistributionPackageVersions/\(id)")
        }

        // MARK: - State transition shortcuts

        /// Activates a completed package version (state -> ENABLED).
        /// Call once Apple has finished notarizing and the version is
        /// in COMPLETED state. Re-calling on an already-enabled
        /// version surfaces a 409, which is mapped through the
        /// shared `isAlreadySetConflict` check on the resulting
        /// APIError.
        @discardableResult
        package func activate(id: String) async throws -> PackageVersion {
            try await updateState(id: id, state: .enabled)
        }

        /// Disables a live package version (state -> DISABLED).
        /// Useful for an emergency takedown without deleting the
        /// version record itself.
        @discardableResult
        package func disable(id: String) async throws -> PackageVersion {
            try await updateState(id: id, state: .disabled)
        }

        /// "Validates" a version by fetching its current state from
        /// Apple. This is a thin wrapper around `get` for callers
        /// that want to poll a version through Apple's processing
        /// pipeline (CREATED -> COMPLETED) before activating.
        package func validate(id: String) async throws -> PackageVersion? {
            try await get(id: id)
        }
    }

    // MARK: - alternativeDistributionPackageDeltas

    /// A binary diff between two package versions, used so end users
    /// don't have to redownload the full binary on every update.
    /// Read-only; Apple computes deltas automatically as versions
    /// land.
    package struct PackageDelta: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// SHA-256 checksum of the delta payload.
            package let fileChecksum: String?
            /// Developer-facing URL of the delta payload. Apple uses
            /// this to ferry the diff to end-user devices.
            package let url: String?
            /// SHA-256 checksum of the source-side package version.
            package let sourceFileChecksum: String?
            /// When the signed `url` ceases to be valid. Refresh by
            /// re-reading the delta resource.
            package let urlExpirationDate: Date?
        }
    }

    package struct PackageDeltas {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        /// Lists deltas hung off a single package version.
        package func list(
            versionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PackageDelta> {
            let resp: PageEnvelope<PackageDelta> = try await client.get(
                path: "alternativeDistributionPackageVersions/\(versionID)/alternativeDistributionPackageDeltas",
                query: AltDistributionAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<PackageDelta>.self
            )
            return .init(data: resp.data, nextCursor: AltDistributionAPI.extractCursor(from: resp.links?.next))
        }

        package func get(id: String) async throws -> PackageDelta? {
            struct Resp: Decodable { let data: PackageDelta }
            do {
                let resp: Resp = try await client.get(
                    path: "alternativeDistributionPackageDeltas/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - alternativeDistributionPackageVariants

    /// Per-architecture/variant slice of a single package version
    /// (e.g. one variant per supported device family or arch). Read-
    /// only; Apple derives these from the uploaded binary.
    package struct PackageVariant: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Developer-facing URL of the variant payload.
            package let url: String?
            /// When the signed `url` ceases to be valid.
            package let urlExpirationDate: Date?
            /// SHA-256 checksum of the variant payload.
            package let fileChecksum: String?
            /// Default localization Apple should serve for this
            /// variant (e.g. "en-US").
            package let defaultLanguage: String?
        }
    }

    package struct PackageVariants {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package func list(
            versionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PackageVariant> {
            let resp: PageEnvelope<PackageVariant> = try await client.get(
                path: "alternativeDistributionPackageVersions/\(versionID)/alternativeDistributionPackageVariants",
                query: AltDistributionAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<PackageVariant>.self
            )
            return .init(data: resp.data, nextCursor: AltDistributionAPI.extractCursor(from: resp.links?.next))
        }

        package func get(id: String) async throws -> PackageVariant? {
            struct Resp: Decodable { let data: PackageVariant }
            do {
                let resp: Resp = try await client.get(
                    path: "alternativeDistributionPackageVariants/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - alternativeDistributionDomains

    /// A domain the developer has registered with Apple as a valid
    /// distribution host. Apple verifies ownership before accepting
    /// download URLs that point at this domain.
    package struct Domain: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// The fully-qualified domain name (e.g. "downloads.example.com").
            package let domain: String?
            /// The HTTP referrer Apple expects on download requests
            /// to this domain. Used as an anti-abuse measure.
            package let referrer: String?
        }
    }

    package struct Domains {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package func list(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Domain> {
            let resp: PageEnvelope<Domain> = try await client.get(
                path: "alternativeDistributionDomains",
                query: AltDistributionAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Domain>.self
            )
            return .init(data: resp.data, nextCursor: AltDistributionAPI.extractCursor(from: resp.links?.next))
        }

        package func get(id: String) async throws -> Domain? {
            struct Resp: Decodable { let data: Domain }
            do {
                let resp: Resp = try await client.get(
                    path: "alternativeDistributionDomains/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Registers a domain. Apple will trigger an out-of-band
        /// verification flow before the domain can host packages.
        @discardableResult
        package func create(
            domain: String,
            referrer: String? = nil
        ) async throws -> Domain {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "alternativeDistributionDomains"
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let domain: String
                    var referrer: String?
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(domain: domain, referrer: referrer)
            ))
            struct Resp: Decodable { let data: Domain }
            let resp: Resp = try await client.post(
                path: "alternativeDistributionDomains",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            domain: String? = nil,
            referrer: String? = nil
        ) async throws -> Domain {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "alternativeDistributionDomains"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    var domain: String?
                    var referrer: String?
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(domain: domain, referrer: referrer)
            ))
            struct Resp: Decodable { let data: Domain }
            let resp: Resp = try await client.patch(
                path: "alternativeDistributionDomains/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "alternativeDistributionDomains/\(id)")
        }
    }

    // MARK: - marketplaceSearchDetails

    /// Per-app marketplace catalog metadata. When the app appears in
    /// a marketplace's search results, the marketplace pulls these
    /// fields to populate its listing.
    package struct MarketplaceSearchDetail: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let subtitle: String?
            package let privacyPolicyUrl: String?
            package let customerSupportUrl: String?
            package let marketingUrl: String?
            package let sellerName: String?
            /// Optional age-band bounds for the listing. Apple uses
            /// these to filter the app from age-restricted catalogs.
            package let ageBandRangeMin: Int?
            package let ageBandRangeMax: Int?
        }
    }

    /// Fields accepted on a marketplaceSearchDetail PATCH. Nil
    /// fields are omitted from the wire body so existing values
    /// stay untouched.
    package struct MarketplaceSearchDetailFields: Sendable, Equatable {
        package var subtitle: String?
        package var privacyPolicyURL: String?
        package var customerSupportURL: String?
        package var marketingURL: String?
        package var sellerName: String?
        package var ageBandRangeMin: Int?
        package var ageBandRangeMax: Int?

        package init(
            subtitle: String? = nil,
            privacyPolicyURL: String? = nil,
            customerSupportURL: String? = nil,
            marketingURL: String? = nil,
            sellerName: String? = nil,
            ageBandRangeMin: Int? = nil,
            ageBandRangeMax: Int? = nil
        ) {
            self.subtitle = subtitle
            self.privacyPolicyURL = privacyPolicyURL
            self.customerSupportURL = customerSupportURL
            self.marketingURL = marketingURL
            self.sellerName = sellerName
            self.ageBandRangeMin = ageBandRangeMin
            self.ageBandRangeMax = ageBandRangeMax
        }
    }

    fileprivate struct MarketplaceSearchAttrsPatch: Encodable {
        var subtitle: String?
        var privacyPolicyUrl: String?
        var customerSupportUrl: String?
        var marketingUrl: String?
        var sellerName: String?
        var ageBandRangeMin: Int?
        var ageBandRangeMax: Int?

        init(fields: MarketplaceSearchDetailFields) {
            self.subtitle = fields.subtitle
            self.privacyPolicyUrl = fields.privacyPolicyURL
            self.customerSupportUrl = fields.customerSupportURL
            self.marketingUrl = fields.marketingURL
            self.sellerName = fields.sellerName
            self.ageBandRangeMin = fields.ageBandRangeMin
            self.ageBandRangeMax = fields.ageBandRangeMax
        }
    }

    package struct MarketplaceSearch {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        /// Reads the marketplace search detail attached to an app.
        /// Returns nil on 404 (which happens when the app has not
        /// yet been published into any marketplace).
        package func get(appID: String) async throws -> MarketplaceSearchDetail? {
            struct Resp: Decodable { let data: MarketplaceSearchDetail }
            do {
                let resp: Resp = try await client.get(
                    path: "apps/\(appID)/marketplaceSearchDetail",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// PATCH the marketplace search detail by record id. Use
        /// `get` first to discover the id, then pass it here along
        /// with whichever fields you want to change.
        @discardableResult
        package func update(
            id: String,
            fields: MarketplaceSearchDetailFields
        ) async throws -> MarketplaceSearchDetail {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "marketplaceSearchDetails"
                    let id: String
                    let attributes: MarketplaceSearchAttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: MarketplaceSearchAttrsPatch(fields: fields)
            ))
            struct Resp: Decodable { let data: MarketplaceSearchDetail }
            let resp: Resp = try await client.patch(
                path: "marketplaceSearchDetails/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - marketplaceWebhooks

    /// A webhook subscription. Apple POSTs distribution events
    /// (install / uninstall / package version state changes) to
    /// `url`. `secret` is an HMAC shared secret Apple signs each
    /// payload with so the developer can verify authenticity.
    package struct MarketplaceWebhook: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let url: String?
            /// Apple typically write-only redacts the stored secret
            /// on reads, so this often comes back nil. Treat as
            /// "set" if it round-trips a real value once on create.
            package let secret: String?
        }
    }

    package struct MarketplaceWebhooks {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package func list(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<MarketplaceWebhook> {
            let resp: PageEnvelope<MarketplaceWebhook> = try await client.get(
                path: "marketplaceWebhooks",
                query: AltDistributionAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<MarketplaceWebhook>.self
            )
            return .init(data: resp.data, nextCursor: AltDistributionAPI.extractCursor(from: resp.links?.next))
        }

        package func get(id: String) async throws -> MarketplaceWebhook? {
            struct Resp: Decodable { let data: MarketplaceWebhook }
            do {
                let resp: Resp = try await client.get(
                    path: "marketplaceWebhooks/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            url: String,
            secret: String? = nil
        ) async throws -> MarketplaceWebhook {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "marketplaceWebhooks"
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let url: String
                    var secret: String?
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(url: url, secret: secret)
            ))
            struct Resp: Decodable { let data: MarketplaceWebhook }
            let resp: Resp = try await client.post(
                path: "marketplaceWebhooks",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            url: String? = nil,
            secret: String? = nil
        ) async throws -> MarketplaceWebhook {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "marketplaceWebhooks"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    var url: String?
                    var secret: String?
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(url: url, secret: secret)
            ))
            struct Resp: Decodable { let data: MarketplaceWebhook }
            let resp: Resp = try await client.patch(
                path: "marketplaceWebhooks/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "marketplaceWebhooks/\(id)")
        }
    }
}
