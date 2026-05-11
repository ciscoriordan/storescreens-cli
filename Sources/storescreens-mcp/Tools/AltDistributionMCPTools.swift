import MCP
import Foundation
import StorescreensCore

/// MCP tool surface for App Store Connect Alternative Distribution
/// (the EU DMA mandate that lets developers ship iOS apps outside
/// the App Store via approved marketplaces or developer-direct
/// distribution).
///
/// Every tool is a thin wrapper around an `AltDistributionAPI`
/// method. Inputs arrive as JSON arguments, outputs are pretty-
/// printed JSON text content so AI agents get a stable, machine-
/// readable response shape without having to construct raw HTTP
/// requests against Apple's API.
///
/// Tool naming convention: `altdist_<resource>_<op>` (snake_case).
///
/// This surface is only relevant for developers participating in
/// Apple's EU Alternative Distribution program. Standard App
/// Store flows are untouched.
enum AltDistributionMCPTools {

    // MARK: - Tool definitions

    static let tools: [Tool] = [

        // alternativeDistributionKeys ------------------------------

        Tool(
            name: "altdist_keys_list",
            description: """
            List alternative distribution keys registered on the team. \
            Each key holds the developer's public-key material Apple \
            uses to verify distribution packages. Supports cursor-based \
            pagination via the `cursor` argument.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer"), "description": .string("Max results per page (default 200)")]),
                    "cursor": .object(["type": .string("string"), "description": .string("Opaque pagination cursor from a prior page's nextCursor")]),
                ]),
            ])
        ),

        Tool(
            name: "altdist_keys_get",
            description: "Get a single alternative distribution key by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Alternative distribution key id")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_keys_create",
            description: """
            Register a new public signing key with Apple. `public_key` is the \
            PEM-encoded public-key block the developer extracted from their \
            signing keypair. Apple stores only the public side.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "public_key": .object(["type": .string("string"), "description": .string("PEM-encoded public key")]),
                ]),
                "required": .array([.string("public_key")]),
            ])
        ),

        Tool(
            name: "altdist_keys_update",
            description: "Rotate the public key on an existing alternative distribution key record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "public_key": .object(["type": .string("string"), "description": .string("New PEM-encoded public key")]),
                ]),
                "required": .array([.string("id"), .string("public_key")]),
            ])
        ),

        Tool(
            name: "altdist_keys_delete",
            description: "Delete an alternative distribution key. Apple will no longer accept packages signed with this key.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // alternativeDistributionPackages --------------------------

        Tool(
            name: "altdist_packages_list",
            description: """
            List alternative distribution packages for an app. A package is \
            the per-app container that hangs version slices off the app. \
            There is typically only one package per app, but the endpoint is \
            paged for symmetry.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string"), "description": .string("Numeric ASC app id")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "altdist_packages_get",
            description: "Get a single alternative distribution package by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_packages_create",
            description: """
            Create a new alternative distribution package for an app. The \
            package is just a container; individual binary versions and \
            their state machine live on alternativeDistributionPackageVersions.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "altdist_packages_delete",
            description: "Delete an alternative distribution package and all its versions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // alternativeDistributionPackageVersions -------------------

        Tool(
            name: "altdist_package_versions_list",
            description: """
            List versions for a single alternative distribution package. \
            Filter by `state`: CREATED, REPLACED, COMPLETED, ENABLED, DISABLED.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "package_id": .object(["type": .string("string")]),
                    "state": .object(["type": .string("string"), "description": .string("CREATED, REPLACED, COMPLETED, ENABLED, or DISABLED")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("package_id")]),
            ])
        ),

        Tool(
            name: "altdist_package_versions_get",
            description: "Get a single alternative distribution package version by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_package_versions_create",
            description: """
            Create a new package version pointing at a developer-hosted URL. \
            Apple will fetch and notarize the binary, transitioning the \
            version through CREATED -> COMPLETED. The version is not live \
            until you call altdist_package_versions_activate.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "package_id": .object(["type": .string("string")]),
                    "url": .object(["type": .string("string"), "description": .string("Developer-hosted URL of the notarized binary")]),
                    "version": .object(["type": .string("string"), "description": .string("Marketing version string, e.g. \"1.2.0\"")]),
                ]),
                "required": .array([.string("package_id"), .string("url")]),
            ])
        ),

        Tool(
            name: "altdist_package_versions_update",
            description: """
            PATCH a package version's mutable attributes. `url` swaps the \
            hosted binary location; `state` triggers a state transition \
            (CREATED, REPLACED, COMPLETED, ENABLED, DISABLED). Pass only \
            the fields you want to change.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "url": .object(["type": .string("string")]),
                    "state": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_package_versions_delete",
            description: "Delete an alternative distribution package version.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_package_versions_activate",
            description: """
            Activate a completed package version (transitions state to \
            ENABLED). Call once Apple has finished notarizing and the \
            version is in COMPLETED state. Convenience wrapper around \
            altdist_package_versions_update with state=ENABLED.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_package_versions_disable",
            description: """
            Disable a live package version (transitions state to DISABLED). \
            Useful for an emergency takedown without deleting the version \
            record. Convenience wrapper around altdist_package_versions_update \
            with state=DISABLED.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_package_versions_validate",
            description: """
            Validate (read current state of) a package version by fetching \
            it from Apple. Useful for polling a version through Apple's \
            processing pipeline (CREATED -> COMPLETED) before activating. \
            Returns the same shape as altdist_package_versions_get.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // alternativeDistributionPackageDeltas ---------------------

        Tool(
            name: "altdist_package_deltas_list",
            description: """
            List binary deltas hung off a single package version. Read-only; \
            Apple computes deltas automatically as new versions land so end \
            users don't redownload the full binary on every update.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "version_id": .object(["type": .string("string"), "description": .string("alternativeDistributionPackageVersions id")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("version_id")]),
            ])
        ),

        Tool(
            name: "altdist_package_deltas_get",
            description: "Get a single alternative distribution package delta by id. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // alternativeDistributionPackageVariants -------------------

        Tool(
            name: "altdist_package_variants_list",
            description: """
            List per-architecture/variant slices of a single package version. \
            Read-only; Apple derives these from the uploaded binary.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "version_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("version_id")]),
            ])
        ),

        Tool(
            name: "altdist_package_variants_get",
            description: "Get a single alternative distribution package variant by id. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // alternativeDistributionDomains ---------------------------

        Tool(
            name: "altdist_domains_list",
            description: "List the developer's verified alternative distribution domains.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),

        Tool(
            name: "altdist_domains_get",
            description: "Get a single alternative distribution domain by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_domains_create",
            description: """
            Register a domain as a valid alternative distribution host. \
            Apple triggers an out-of-band verification flow before the \
            domain can host packages.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "domain": .object(["type": .string("string"), "description": .string("Fully-qualified domain, e.g. downloads.example.com")]),
                    "referrer": .object(["type": .string("string"), "description": .string("HTTP referrer Apple expects on download requests (anti-abuse)")]),
                ]),
                "required": .array([.string("domain")]),
            ])
        ),

        Tool(
            name: "altdist_domains_update",
            description: "Update an alternative distribution domain. Only the fields you pass are changed.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "domain": .object(["type": .string("string")]),
                    "referrer": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_domains_delete",
            description: "Delete an alternative distribution domain.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // marketplaceSearchDetails ---------------------------------

        Tool(
            name: "altdist_marketplace_search_get",
            description: """
            Read the marketplace search-catalog metadata for an app. These \
            fields appear when the app shows up in a marketplace's search \
            results. Returns null if the app has not yet been published into \
            any marketplace.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "altdist_marketplace_search_update",
            description: """
            PATCH the marketplace search-catalog metadata for an app. Nil/ \
            omitted fields stay as-is. Use altdist_marketplace_search_get \
            first to discover the record `id`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("marketplaceSearchDetails id, NOT the app id")]),
                    "subtitle": .object(["type": .string("string")]),
                    "privacy_policy_url": .object(["type": .string("string")]),
                    "customer_support_url": .object(["type": .string("string")]),
                    "marketing_url": .object(["type": .string("string")]),
                    "seller_name": .object(["type": .string("string")]),
                    "age_band_range_min": .object(["type": .string("integer")]),
                    "age_band_range_max": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // marketplaceWebhooks --------------------------------------

        Tool(
            name: "altdist_marketplace_webhooks_list",
            description: """
            List marketplace webhook subscriptions. Apple POSTs distribution \
            events (install / uninstall / package version state changes) to \
            these webhook URLs.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),

        Tool(
            name: "altdist_marketplace_webhooks_get",
            description: "Get a single marketplace webhook by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_marketplace_webhooks_create",
            description: """
            Create a new marketplace webhook. Apple will POST distribution \
            events to `url`. `secret` is an HMAC shared secret Apple signs \
            each payload with so the developer can verify authenticity.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string"), "description": .string("HTTPS endpoint that will receive POSTs")]),
                    "secret": .object(["type": .string("string"), "description": .string("HMAC shared secret for payload signing")]),
                ]),
                "required": .array([.string("url")]),
            ])
        ),

        Tool(
            name: "altdist_marketplace_webhooks_update",
            description: "Update a marketplace webhook's url or shared secret.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "url": .object(["type": .string("string")]),
                    "secret": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "altdist_marketplace_webhooks_delete",
            description: "Delete a marketplace webhook subscription.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Tool names handled by this module. Used by the MCP main dispatcher
    /// to route a CallTool request to `handle` when the name starts with
    /// `altdist_`.
    static let toolNames: Set<String> = Set(tools.map(\.name))

    /// Master entry point. Resolves credentials, constructs the API
    /// wrapper, and dispatches to the matching handler by tool name. All
    /// handlers return JSON text content; errors surface as `isError: true`
    /// results so the agent can react cleanly.
    static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            return errorResult(
                "App Store Connect credentials are not configured. " +
                "Run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / " +
                "ASC_KEY_PATH. (\(error))"
            )
        }
        let client = ASCClient(credentials: creds)
        let api = AltDistributionAPI(client: client)

        do {
            switch params.name {

            // keys
            case "altdist_keys_list":          return try await handleKeysList(params, api: api)
            case "altdist_keys_get":           return try await handleKeysGet(params, api: api)
            case "altdist_keys_create":        return try await handleKeysCreate(params, api: api)
            case "altdist_keys_update":        return try await handleKeysUpdate(params, api: api)
            case "altdist_keys_delete":        return try await handleKeysDelete(params, api: api)

            // packages
            case "altdist_packages_list":      return try await handlePackagesList(params, api: api)
            case "altdist_packages_get":       return try await handlePackagesGet(params, api: api)
            case "altdist_packages_create":    return try await handlePackagesCreate(params, api: api)
            case "altdist_packages_delete":    return try await handlePackagesDelete(params, api: api)

            // package versions
            case "altdist_package_versions_list":     return try await handlePackageVersionsList(params, api: api)
            case "altdist_package_versions_get":      return try await handlePackageVersionsGet(params, api: api)
            case "altdist_package_versions_create":   return try await handlePackageVersionsCreate(params, api: api)
            case "altdist_package_versions_update":   return try await handlePackageVersionsUpdate(params, api: api)
            case "altdist_package_versions_delete":   return try await handlePackageVersionsDelete(params, api: api)
            case "altdist_package_versions_activate": return try await handlePackageVersionsActivate(params, api: api)
            case "altdist_package_versions_disable":  return try await handlePackageVersionsDisable(params, api: api)
            case "altdist_package_versions_validate": return try await handlePackageVersionsValidate(params, api: api)

            // deltas
            case "altdist_package_deltas_list": return try await handlePackageDeltasList(params, api: api)
            case "altdist_package_deltas_get":  return try await handlePackageDeltasGet(params, api: api)

            // variants
            case "altdist_package_variants_list": return try await handlePackageVariantsList(params, api: api)
            case "altdist_package_variants_get":  return try await handlePackageVariantsGet(params, api: api)

            // domains
            case "altdist_domains_list":   return try await handleDomainsList(params, api: api)
            case "altdist_domains_get":    return try await handleDomainsGet(params, api: api)
            case "altdist_domains_create": return try await handleDomainsCreate(params, api: api)
            case "altdist_domains_update": return try await handleDomainsUpdate(params, api: api)
            case "altdist_domains_delete": return try await handleDomainsDelete(params, api: api)

            // marketplace search
            case "altdist_marketplace_search_get":    return try await handleMarketplaceSearchGet(params, api: api)
            case "altdist_marketplace_search_update": return try await handleMarketplaceSearchUpdate(params, api: api)

            // marketplace webhooks
            case "altdist_marketplace_webhooks_list":   return try await handleMarketplaceWebhooksList(params, api: api)
            case "altdist_marketplace_webhooks_get":    return try await handleMarketplaceWebhooksGet(params, api: api)
            case "altdist_marketplace_webhooks_create": return try await handleMarketplaceWebhooksCreate(params, api: api)
            case "altdist_marketplace_webhooks_update": return try await handleMarketplaceWebhooksUpdate(params, api: api)
            case "altdist_marketplace_webhooks_delete": return try await handleMarketplaceWebhooksDelete(params, api: api)

            default:
                return errorResult("Unknown Alternative Distribution tool: \(params.name)")
            }
        } catch let e as ASCClient.APIError {
            return errorResult(
                "App Store Connect API error (HTTP \(e.statusCode))\n" +
                e.details.map { "  [\($0.code)] \($0.title): \($0.detail)" }
                    .joined(separator: "\n")
            )
        } catch {
            return errorResult("Error: \(error)")
        }
    }

    // MARK: - Argument helpers

    private static func arg(_ params: CallTool.Parameters, _ key: String) -> Value? {
        params.arguments?[key]
    }

    private static func requireString(_ params: CallTool.Parameters, _ key: String) throws -> String {
        guard let s = arg(params, key)?.stringValue else {
            throw MCPArgError("Missing required string argument: \(key)")
        }
        return s
    }

    private static func optionalString(_ params: CallTool.Parameters, _ key: String) -> String? {
        arg(params, key)?.stringValue
    }

    private static func optionalInt(_ params: CallTool.Parameters, _ key: String) -> Int? {
        if let v = arg(params, key)?.intValue { return v }
        if let s = arg(params, key)?.stringValue, let i = Int(s) { return i }
        return nil
    }

    private struct MCPArgError: Error, CustomStringConvertible {
        let description: String
        init(_ m: String) { self.description = m }
    }

    // MARK: - JSON output

    private static func jsonText<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)])
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func ackResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)])
    }

    // MARK: - Page wrapper for JSON output

    private struct PageOut<Item: Encodable>: Encodable {
        let data: [Item]
        let nextCursor: String?
    }

    // MARK: - Handlers: keys

    private static func handleKeysList(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.keys.list(limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleKeysGet(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let key = try await api.keys.get(id: id)
        return try jsonText(key)
    }

    private static func handleKeysCreate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let pub = try requireString(params, "public_key")
        let key = try await api.keys.create(publicKey: pub)
        return try jsonText(key)
    }

    private static func handleKeysUpdate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let pub = try requireString(params, "public_key")
        let key = try await api.keys.update(id: id, publicKey: pub)
        return try jsonText(key)
    }

    private static func handleKeysDelete(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.keys.delete(id: id)
        return ackResult("Deleted alternative distribution key \(id)")
    }

    // MARK: - Handlers: packages

    private static func handlePackagesList(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.packages.list(appID: appID, limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handlePackagesGet(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let pkg = try await api.packages.get(id: id)
        return try jsonText(pkg)
    }

    private static func handlePackagesCreate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let pkg = try await api.packages.create(appID: appID)
        return try jsonText(pkg)
    }

    private static func handlePackagesDelete(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.packages.delete(id: id)
        return ackResult("Deleted alternative distribution package \(id)")
    }

    // MARK: - Handlers: package versions

    private static func handlePackageVersionsList(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let packageID = try requireString(params, "package_id")
        let stateStr = optionalString(params, "state")
        let state = stateStr.flatMap { AltDistributionAPI.PackageVersionState(rawValue: $0) }
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.packageVersions.list(
            packageID: packageID, state: state, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handlePackageVersionsGet(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let v = try await api.packageVersions.get(id: id)
        return try jsonText(v)
    }

    private static func handlePackageVersionsCreate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let packageID = try requireString(params, "package_id")
        let url = try requireString(params, "url")
        let version = optionalString(params, "version")
        let v = try await api.packageVersions.create(
            packageID: packageID, url: url, version: version
        )
        return try jsonText(v)
    }

    private static func handlePackageVersionsUpdate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let url = optionalString(params, "url")
        let stateStr = optionalString(params, "state")
        let state = stateStr.flatMap { AltDistributionAPI.PackageVersionState(rawValue: $0) }
        if url == nil && stateStr != nil && state == nil {
            // User passed an unrecognised state value. Surface a clear error
            // rather than silently dropping the field.
            return errorResult("Unknown state value: \(stateStr ?? "") (expected CREATED, REPLACED, COMPLETED, ENABLED, or DISABLED)")
        }
        let v = try await api.packageVersions.update(id: id, url: url, state: state)
        return try jsonText(v)
    }

    private static func handlePackageVersionsDelete(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.packageVersions.delete(id: id)
        return ackResult("Deleted alternative distribution package version \(id)")
    }

    private static func handlePackageVersionsActivate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let v = try await api.packageVersions.activate(id: id)
        return try jsonText(v)
    }

    private static func handlePackageVersionsDisable(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let v = try await api.packageVersions.disable(id: id)
        return try jsonText(v)
    }

    private static func handlePackageVersionsValidate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let v = try await api.packageVersions.validate(id: id)
        return try jsonText(v)
    }

    // MARK: - Handlers: package deltas

    private static func handlePackageDeltasList(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let versionID = try requireString(params, "version_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.packageDeltas.list(
            versionID: versionID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handlePackageDeltasGet(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let d = try await api.packageDeltas.get(id: id)
        return try jsonText(d)
    }

    // MARK: - Handlers: package variants

    private static func handlePackageVariantsList(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let versionID = try requireString(params, "version_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.packageVariants.list(
            versionID: versionID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handlePackageVariantsGet(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let v = try await api.packageVariants.get(id: id)
        return try jsonText(v)
    }

    // MARK: - Handlers: domains

    private static func handleDomainsList(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.domains.list(limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleDomainsGet(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let d = try await api.domains.get(id: id)
        return try jsonText(d)
    }

    private static func handleDomainsCreate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let domain = try requireString(params, "domain")
        let referrer = optionalString(params, "referrer")
        let d = try await api.domains.create(domain: domain, referrer: referrer)
        return try jsonText(d)
    }

    private static func handleDomainsUpdate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let domain = optionalString(params, "domain")
        let referrer = optionalString(params, "referrer")
        let d = try await api.domains.update(id: id, domain: domain, referrer: referrer)
        return try jsonText(d)
    }

    private static func handleDomainsDelete(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.domains.delete(id: id)
        return ackResult("Deleted alternative distribution domain \(id)")
    }

    // MARK: - Handlers: marketplace search

    private static func handleMarketplaceSearchGet(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let detail = try await api.marketplaceSearch.get(appID: appID)
        return try jsonText(detail)
    }

    private static func handleMarketplaceSearchUpdate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = AltDistributionAPI.MarketplaceSearchDetailFields(
            subtitle: optionalString(params, "subtitle"),
            privacyPolicyURL: optionalString(params, "privacy_policy_url"),
            customerSupportURL: optionalString(params, "customer_support_url"),
            marketingURL: optionalString(params, "marketing_url"),
            sellerName: optionalString(params, "seller_name"),
            ageBandRangeMin: optionalInt(params, "age_band_range_min"),
            ageBandRangeMax: optionalInt(params, "age_band_range_max")
        )
        let detail = try await api.marketplaceSearch.update(id: id, fields: fields)
        return try jsonText(detail)
    }

    // MARK: - Handlers: marketplace webhooks

    private static func handleMarketplaceWebhooksList(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.marketplaceWebhooks.list(limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleMarketplaceWebhooksGet(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let w = try await api.marketplaceWebhooks.get(id: id)
        return try jsonText(w)
    }

    private static func handleMarketplaceWebhooksCreate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let url = try requireString(params, "url")
        let secret = optionalString(params, "secret")
        let w = try await api.marketplaceWebhooks.create(url: url, secret: secret)
        return try jsonText(w)
    }

    private static func handleMarketplaceWebhooksUpdate(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let url = optionalString(params, "url")
        let secret = optionalString(params, "secret")
        let w = try await api.marketplaceWebhooks.update(id: id, url: url, secret: secret)
        return try jsonText(w)
    }

    private static func handleMarketplaceWebhooksDelete(
        _ params: CallTool.Parameters, api: AltDistributionAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.marketplaceWebhooks.delete(id: id)
        return ackResult("Deleted marketplace webhook \(id)")
    }
}
