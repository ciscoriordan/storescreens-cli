import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for the grab-bag of small App Store Connect resource
/// families: Apple Pay (pass type IDs + certificates + merchant domains),
/// Sandbox Testers, Resource Limits, App Hashes, and Diagnostic Sessions.
/// Mirrors the methods on `ApplePayAPI`, `SandboxTestersAPI`,
/// `ResourceLimitsAPI`, `AppHashesAPI`, and `DiagnosticSessionsAPI` so an
/// AI agent can drive these niche workflows without crafting raw ASC HTTP
/// requests.
///
/// All tools resolve credentials through `ASCCredentialResolver.resolve()`
/// (env vars first, then `~/.storescreens/asc-credentials.yml`). Tools
/// return pretty-printed JSON in a single `.text` content block, with
/// `isError: true` set on failures.
///
/// Note: This file is loaded into the same MCP target as `Main.swift`.
/// `Main.swift` owns the actual server bootstrap and tool registration;
/// per the task constraints we do not edit `Main.swift` here, so the
/// dispatch glue lives ready for a separate wiring step that will plug
/// `ApplePayAndMiscMCPTools.tools` into the server's tool list and
/// `ApplePayAndMiscMCPTools.handle(_:)` into the dispatch switch.
package enum ApplePayAndMiscMCPTools {

    // MARK: - Tool catalog

    /// Every tool exposed by this namespace. Names use snake_case with
    /// prefixes that group the resource families: `applepay_*`,
    /// `sandbox_*`, `resource_limits_*`, `app_hashes_*`,
    /// `diagnostic_sessions_*`.
    package static let tools: [Tool] = [

        // MARK: Apple Pay: Pass Type IDs

        Tool(
            name: "applepay_pass_type_ids_list",
            description: """
            List Apple Pay pass type identifiers on the team. Pass type IDs \
            are the dotted strings like `pass.com.example.myapp` that Wallet \
            uses to namespace passes. Paginated; pass `cursor` from a prior \
            response to fetch the next page.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "identifier_filter": .object([
                        "type": .string("string"),
                        "description": .string("Filter to one dotted identifier (e.g. pass.com.example.myapp)."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "applepay_pass_type_ids_get",
            description: "Fetch one pass type identifier by its ASC database id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pass_type_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id (from applepay_pass_type_ids_list)."),
                    ]),
                ]),
                "required": .array([.string("pass_type_id")]),
            ])
        ),
        Tool(
            name: "applepay_pass_type_ids_create",
            description: """
            Register a new pass type identifier. `identifier` must begin with \
            "pass." and use reverse-DNS notation (e.g. pass.com.example.myapp). \
            `name` is the human-readable display label for the developer portal.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "identifier": .object([
                        "type": .string("string"),
                        "description": .string("Dotted pass type identifier (e.g. pass.com.example.myapp)."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Display name in the developer portal."),
                    ]),
                ]),
                "required": .array([.string("identifier"), .string("name")]),
            ])
        ),
        Tool(
            name: "applepay_pass_type_ids_update",
            description: """
            Rename a pass type identifier's display label. The dotted \
            `identifier` itself is immutable; only the human-readable name \
            can change.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pass_type_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("New display name."),
                    ]),
                ]),
                "required": .array([.string("pass_type_id"), .string("name")]),
            ])
        ),
        Tool(
            name: "applepay_pass_type_ids_delete",
            description: """
            Delete a pass type identifier. Apple blocks deletion when any \
            signed certificates still reference the pass type id; revoke \
            certificates first via applepay_certificates_delete.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pass_type_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id to delete."),
                    ]),
                ]),
                "required": .array([.string("pass_type_id")]),
            ])
        ),

        // MARK: Apple Pay: Certificates

        Tool(
            name: "applepay_certificates_list",
            description: """
            List certificates signed against a specific pass type identifier. \
            Each pass type id can carry multiple certificates (typically one \
            active and one on deck for rotation). Paginated.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pass_type_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id of the pass type id (from applepay_pass_type_ids_list)."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
                "required": .array([.string("pass_type_id")]),
            ])
        ),
        Tool(
            name: "applepay_certificates_get",
            description: """
            Fetch one pass type id certificate by id. Includes the \
            base64-encoded `certificateContent` which callers save to a .cer \
            file for importing into Keychain Access or using directly with \
            openssl to sign .pkpass payloads.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "certificate_id": .object([
                        "type": .string("string"),
                        "description": .string("Certificate id (from applepay_certificates_list)."),
                    ]),
                ]),
                "required": .array([.string("certificate_id")]),
            ])
        ),
        Tool(
            name: "applepay_certificates_create",
            description: """
            Submit a CSR and receive a certificate signed against the pass \
            type id. The CSR must be PEM, base64-encoded. Apple signs the \
            request using the pass type id's seed material; save the returned \
            `certificateContent` to a .cer file.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pass_type_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id of the pass type id."),
                    ]),
                    "csr_content": .object([
                        "type": .string("string"),
                        "description": .string("Base64-encoded PEM CSR contents (result of `openssl req -new ...` then base64)."),
                    ]),
                ]),
                "required": .array([.string("pass_type_id"), .string("csr_content")]),
            ])
        ),
        Tool(
            name: "applepay_certificates_delete",
            description: """
            Revoke (delete) a pass type id certificate. Passes signed by it \
            stay valid until the binary signature expires on its own \
            schedule. Irreversible.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "certificate_id": .object([
                        "type": .string("string"),
                        "description": .string("Certificate id to revoke."),
                    ]),
                ]),
                "required": .array([.string("certificate_id")]),
            ])
        ),

        // MARK: Apple Pay: Merchant Domains

        Tool(
            name: "applepay_merchant_domains_list",
            description: """
            List Apple Pay on the Web merchant domains the team has claimed. \
            Each domain shows its current `domainState` (VERIFIED, UNVERIFIED, \
            VERIFY_FAILED). Paginated.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "applepay_merchant_domains_get",
            description: "Fetch one merchant domain by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "domain_id": .object([
                        "type": .string("string"),
                        "description": .string("Merchant domain id (from applepay_merchant_domains_list)."),
                    ]),
                ]),
                "required": .array([.string("domain_id")]),
            ])
        ),
        Tool(
            name: "applepay_merchant_domains_create",
            description: """
            Claim a new merchant domain for Apple Pay on the Web. Apple does \
            NOT validate the domain at creation time; follow up with \
            applepay_merchant_domains_validate after hosting the well-known \
            association file at /.well-known/apple-developer-merchantid-domain-association \
            on the claimed domain.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "domain": .object([
                        "type": .string("string"),
                        "description": .string("Fully-qualified domain name to claim (e.g. shop.example.com)."),
                    ]),
                ]),
                "required": .array([.string("domain")]),
            ])
        ),
        Tool(
            name: "applepay_merchant_domains_validate",
            description: """
            Trigger Apple to fetch the well-known association file at the \
            claimed domain and verify ownership. On success the merchant \
            domain transitions to `VERIFIED`; on failure to `VERIFY_FAILED` \
            (retry after fixing the well-known file).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "domain_id": .object([
                        "type": .string("string"),
                        "description": .string("Merchant domain id."),
                    ]),
                ]),
                "required": .array([.string("domain_id")]),
            ])
        ),
        Tool(
            name: "applepay_merchant_domains_delete",
            description: """
            Revoke a merchant domain claim. Web payments on the domain stop \
            working immediately.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "domain_id": .object([
                        "type": .string("string"),
                        "description": .string("Merchant domain id to delete."),
                    ]),
                ]),
                "required": .array([.string("domain_id")]),
            ])
        ),

        // MARK: Sandbox Testers

        Tool(
            name: "sandbox_testers_list",
            description: """
            List sandbox testers on the team. Apple does not surface email \
            or password in the API; only first name, last name, territory, \
            locale, and subscription renewal rate. Paginated; optional \
            filters for territory (e.g. USA) and subscription renewal rate.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "territory_filter": .object([
                        "type": .string("string"),
                        "description": .string("Filter by territory (e.g. USA, GBR, JPN)."),
                    ]),
                    "renewal_rate_filter": .object([
                        "type": .string("string"),
                        "description": .string("Filter by subscription renewal rate (REAL_TIME, ONE_TIME, ONE_HOUR, THIRTY_MINUTES, FIFTEEN_MINUTES, FIVE_MINUTES)."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "sandbox_testers_get",
            description: "Fetch one sandbox tester by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tester_id": .object([
                        "type": .string("string"),
                        "description": .string("Sandbox tester id (from sandbox_testers_list)."),
                    ]),
                ]),
                "required": .array([.string("tester_id")]),
            ])
        ),
        Tool(
            name: "sandbox_testers_clear_history",
            description: """
            Clear a sandbox tester's accumulated purchase history. Useful \
            when re-running an IAP flow that gates state on whether the \
            tester has already bought the product. Apple processes the \
            request asynchronously; the side effect lands within a few \
            seconds.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tester_id": .object([
                        "type": .string("string"),
                        "description": .string("Sandbox tester id."),
                    ]),
                ]),
                "required": .array([.string("tester_id")]),
            ])
        ),
        Tool(
            name: "sandbox_testers_modify_renewal_rate",
            description: """
            Change how aggressively Apple simulates subscription renewals \
            for the sandbox tester. Use the faster rates (FIVE_MINUTES, \
            FIFTEEN_MINUTES) to walk through renewal flows without waiting \
            real-world time; REAL_TIME matches production timing exactly.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tester_id": .object([
                        "type": .string("string"),
                        "description": .string("Sandbox tester id."),
                    ]),
                    "rate": .object([
                        "type": .string("string"),
                        "description": .string("Renewal rate: REAL_TIME, ONE_TIME, ONE_HOUR, THIRTY_MINUTES, FIFTEEN_MINUTES, FIVE_MINUTES."),
                    ]),
                ]),
                "required": .array([.string("tester_id"), .string("rate")]),
            ])
        ),
        Tool(
            name: "sandbox_tester_apps_list",
            description: """
            List sandbox-tester / app junction records scoped to a specific \
            app. Each record identifies a tester that has access to the app \
            for sandbox purchases. Paginated.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC numeric app id."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "sandbox_tester_apps_get",
            description: "Fetch one sandbox-tester-app junction record by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "junction_id": .object([
                        "type": .string("string"),
                        "description": .string("Junction record id (from sandbox_tester_apps_list)."),
                    ]),
                ]),
                "required": .array([.string("junction_id")]),
            ])
        ),

        // MARK: Resource Limits

        Tool(
            name: "resource_limits_list",
            description: """
            List the team's resource limit records. Each record reports one \
            quota (e.g. MAX_APPS_PER_TEAM, MAX_USERS_PER_TEAM, \
            MAX_IN_APP_PURCHASES_PER_APP) with the team's current usage and \
            Apple's ceiling. Read-only.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "resource_limits_get",
            description: "Fetch one resource limit record by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit_id": .object([
                        "type": .string("string"),
                        "description": .string("Resource limit id (from resource_limits_list)."),
                    ]),
                ]),
                "required": .array([.string("limit_id")]),
            ])
        ),

        // MARK: App Hashes

        Tool(
            name: "app_hashes_list",
            description: """
            List app hashes for a specific app. Apple emits one hash per \
            signing event during identifier or signing migrations; teams \
            typically have a single record. Paginated.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC numeric app id."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "app_hashes_get",
            description: "Fetch one app hash record by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "hash_id": .object([
                        "type": .string("string"),
                        "description": .string("App hash id (from app_hashes_list)."),
                    ]),
                ]),
                "required": .array([.string("hash_id")]),
            ])
        ),

        // MARK: Diagnostic Sessions

        Tool(
            name: "diagnostic_sessions_list",
            description: """
            List profile diagnostic sessions for an app. Each session is one \
            period during which Apple's device telemetry collected power and \
            performance samples against a specific build. Paginated; filter \
            by state (IN_PROGRESS, COMPLETE) when triaging which session is \
            still collecting data.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC numeric app id."),
                    ]),
                    "state_filter": .object([
                        "type": .string("string"),
                        "description": .string("Filter by state: IN_PROGRESS or COMPLETE."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "diagnostic_sessions_get",
            description: "Fetch one profile diagnostic session by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "session_id": .object([
                        "type": .string("string"),
                        "description": .string("Session id (from diagnostic_sessions_list)."),
                    ]),
                ]),
                "required": .array([.string("session_id")]),
            ])
        ),
        Tool(
            name: "diagnostic_sessions_create",
            description: """
            Start a new profile diagnostic session against a specific build. \
            Apple scopes the session to one build + device-family pair; spin \
            up multiple sessions to compare across device families. Optional \
            `name` is a free-form label that shows up in Xcode Instruments.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC build id the session targets."),
                    ]),
                    "device_family": .object([
                        "type": .string("string"),
                        "description": .string("Device family identifier (e.g. IPHONE, IPAD). Optional."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Free-form session label shown in Xcode Instruments. Optional."),
                    ]),
                ]),
                "required": .array([.string("build_id")]),
            ])
        ),
        Tool(
            name: "diagnostic_sessions_complete",
            description: """
            Mark an in-progress diagnostic session as COMPLETE, stopping \
            further sample collection. Sessions left in IN_PROGRESS \
            indefinitely still time out on Apple's side after a few hours, \
            but completing them explicitly frees the slot sooner.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "session_id": .object([
                        "type": .string("string"),
                        "description": .string("Session id to complete."),
                    ]),
                ]),
                "required": .array([.string("session_id")]),
            ])
        ),
        Tool(
            name: "diagnostic_sessions_delete",
            description: """
            Delete a diagnostic session record. Sampled metrics already \
            collected stay on the perfPowerMetrics resource attached to the \
            build; only the session metadata is removed.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "session_id": .object([
                        "type": .string("string"),
                        "description": .string("Session id to delete."),
                    ]),
                ]),
                "required": .array([.string("session_id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Routes a `CallTool.Parameters` whose name belongs to this namespace
    /// to the right handler. Returns an error result for unknown names so
    /// `Main.swift` can route through this whole family with a single
    /// `tools.contains(where:)` prefix check rather than maintaining a
    /// duplicate switch.
    package static func handle(
        _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        switch params.name {
        // Apple Pay: Pass Type IDs
        case "applepay_pass_type_ids_list":     return try await handlePassTypeIDsList(params)
        case "applepay_pass_type_ids_get":      return try await handlePassTypeIDsGet(params)
        case "applepay_pass_type_ids_create":   return try await handlePassTypeIDsCreate(params)
        case "applepay_pass_type_ids_update":   return try await handlePassTypeIDsUpdate(params)
        case "applepay_pass_type_ids_delete":   return try await handlePassTypeIDsDelete(params)
        // Apple Pay: Certificates
        case "applepay_certificates_list":      return try await handleCertificatesList(params)
        case "applepay_certificates_get":       return try await handleCertificatesGet(params)
        case "applepay_certificates_create":    return try await handleCertificatesCreate(params)
        case "applepay_certificates_delete":    return try await handleCertificatesDelete(params)
        // Apple Pay: Merchant Domains
        case "applepay_merchant_domains_list":     return try await handleMerchantDomainsList(params)
        case "applepay_merchant_domains_get":      return try await handleMerchantDomainsGet(params)
        case "applepay_merchant_domains_create":   return try await handleMerchantDomainsCreate(params)
        case "applepay_merchant_domains_validate": return try await handleMerchantDomainsValidate(params)
        case "applepay_merchant_domains_delete":   return try await handleMerchantDomainsDelete(params)
        // Sandbox Testers
        case "sandbox_testers_list":                return try await handleSandboxTestersList(params)
        case "sandbox_testers_get":                 return try await handleSandboxTestersGet(params)
        case "sandbox_testers_clear_history":       return try await handleSandboxTestersClearHistory(params)
        case "sandbox_testers_modify_renewal_rate": return try await handleSandboxTestersModifyRenewalRate(params)
        case "sandbox_tester_apps_list":            return try await handleSandboxTesterAppsList(params)
        case "sandbox_tester_apps_get":             return try await handleSandboxTesterAppsGet(params)
        // Resource Limits
        case "resource_limits_list":            return try await handleResourceLimitsList(params)
        case "resource_limits_get":             return try await handleResourceLimitsGet(params)
        // App Hashes
        case "app_hashes_list":                 return try await handleAppHashesList(params)
        case "app_hashes_get":                  return try await handleAppHashesGet(params)
        // Diagnostic Sessions
        case "diagnostic_sessions_list":        return try await handleDiagnosticSessionsList(params)
        case "diagnostic_sessions_get":         return try await handleDiagnosticSessionsGet(params)
        case "diagnostic_sessions_create":      return try await handleDiagnosticSessionsCreate(params)
        case "diagnostic_sessions_complete":    return try await handleDiagnosticSessionsComplete(params)
        case "diagnostic_sessions_delete":      return try await handleDiagnosticSessionsDelete(params)
        default:
            return errorResult("Unknown tool: \(params.name)")
        }
    }

    // MARK: - Pass Type IDs handlers

    static func handlePassTypeIDsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeApplePayAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let identifierFilter = params.arguments?["identifier_filter"]?.stringValue
            let result = try await api.listPassTypeIDs(
                limit: limit, cursor: cursor, filterIdentifier: identifierFilter
            )
            let payload = PassTypeIDsListPayload(
                passTypeIDs: result.passTypeIDs.map(PassTypeIDJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("applepay_pass_type_ids_list failed: \(error)")
        }
    }

    static func handlePassTypeIDsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["pass_type_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: pass_type_id")
        }
        do {
            let api = try makeApplePayAPI()
            guard let p = try await api.getPassTypeID(id: id) else {
                return errorResult("No pass type id with id \(id)")
            }
            return jsonResult(PassTypeIDJSON(p))
        } catch {
            return errorResult("applepay_pass_type_ids_get failed: \(error)")
        }
    }

    static func handlePassTypeIDsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let identifier = params.arguments?["identifier"]?.stringValue, !identifier.isEmpty else {
            return errorResult("Missing required parameter: identifier")
        }
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("Missing required parameter: name")
        }
        do {
            let api = try makeApplePayAPI()
            let p = try await api.createPassTypeID(identifier: identifier, name: name)
            return jsonResult(PassTypeIDJSON(p))
        } catch {
            return errorResult("applepay_pass_type_ids_create failed: \(error)")
        }
    }

    static func handlePassTypeIDsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["pass_type_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: pass_type_id")
        }
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("Missing required parameter: name")
        }
        do {
            let api = try makeApplePayAPI()
            let p = try await api.updatePassTypeID(id: id, name: name)
            return jsonResult(PassTypeIDJSON(p))
        } catch {
            return errorResult("applepay_pass_type_ids_update failed: \(error)")
        }
    }

    static func handlePassTypeIDsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["pass_type_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: pass_type_id")
        }
        do {
            let api = try makeApplePayAPI()
            try await api.deletePassTypeID(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "passTypeId"))
        } catch {
            return errorResult("applepay_pass_type_ids_delete failed: \(error)")
        }
    }

    // MARK: - Certificates handlers

    static func handleCertificatesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["pass_type_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: pass_type_id")
        }
        do {
            let api = try makeApplePayAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let result = try await api.listPassTypeIDCertificates(
                passTypeIDDatabaseID: id, limit: limit, cursor: cursor
            )
            let payload = PassTypeCertsListPayload(
                certificates: result.certificates.map(PassTypeCertJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("applepay_certificates_list failed: \(error)")
        }
    }

    static func handleCertificatesGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["certificate_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: certificate_id")
        }
        do {
            let api = try makeApplePayAPI()
            guard let cert = try await api.getPassTypeIDCertificate(id: id) else {
                return errorResult("No certificate with id \(id)")
            }
            return jsonResult(PassTypeCertJSON(cert))
        } catch {
            return errorResult("applepay_certificates_get failed: \(error)")
        }
    }

    static func handleCertificatesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let passTypeID = params.arguments?["pass_type_id"]?.stringValue, !passTypeID.isEmpty else {
            return errorResult("Missing required parameter: pass_type_id")
        }
        guard let csr = params.arguments?["csr_content"]?.stringValue, !csr.isEmpty else {
            return errorResult("Missing required parameter: csr_content")
        }
        do {
            let api = try makeApplePayAPI()
            let cert = try await api.createPassTypeIDCertificate(
                passTypeIDDatabaseID: passTypeID, csrContent: csr
            )
            return jsonResult(PassTypeCertJSON(cert))
        } catch {
            return errorResult("applepay_certificates_create failed: \(error)")
        }
    }

    static func handleCertificatesDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["certificate_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: certificate_id")
        }
        do {
            let api = try makeApplePayAPI()
            try await api.revokePassTypeIDCertificate(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "passTypeIdCertificate"))
        } catch {
            return errorResult("applepay_certificates_delete failed: \(error)")
        }
    }

    // MARK: - Merchant Domains handlers

    static func handleMerchantDomainsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeApplePayAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let result = try await api.listMerchantDomains(limit: limit, cursor: cursor)
            let payload = MerchantDomainsListPayload(
                merchantDomains: result.merchantDomains.map(MerchantDomainJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("applepay_merchant_domains_list failed: \(error)")
        }
    }

    static func handleMerchantDomainsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["domain_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: domain_id")
        }
        do {
            let api = try makeApplePayAPI()
            guard let d = try await api.getMerchantDomain(id: id) else {
                return errorResult("No merchant domain with id \(id)")
            }
            return jsonResult(MerchantDomainJSON(d))
        } catch {
            return errorResult("applepay_merchant_domains_get failed: \(error)")
        }
    }

    static func handleMerchantDomainsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let domain = params.arguments?["domain"]?.stringValue, !domain.isEmpty else {
            return errorResult("Missing required parameter: domain")
        }
        do {
            let api = try makeApplePayAPI()
            let d = try await api.createMerchantDomain(domain: domain)
            return jsonResult(MerchantDomainJSON(d))
        } catch {
            return errorResult("applepay_merchant_domains_create failed: \(error)")
        }
    }

    static func handleMerchantDomainsValidate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["domain_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: domain_id")
        }
        do {
            let api = try makeApplePayAPI()
            let d = try await api.validateMerchantDomain(id: id)
            return jsonResult(MerchantDomainJSON(d))
        } catch {
            return errorResult("applepay_merchant_domains_validate failed: \(error)")
        }
    }

    static func handleMerchantDomainsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["domain_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: domain_id")
        }
        do {
            let api = try makeApplePayAPI()
            try await api.deleteMerchantDomain(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "merchantDomain"))
        } catch {
            return errorResult("applepay_merchant_domains_delete failed: \(error)")
        }
    }

    // MARK: - Sandbox Testers handlers

    static func handleSandboxTestersList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeSandboxAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let territory = params.arguments?["territory_filter"]?.stringValue
            let rate = params.arguments?["renewal_rate_filter"]?.stringValue
            let result = try await api.listSandboxTesters(
                limit: limit,
                cursor: cursor,
                filterTerritory: territory,
                filterRenewalRate: rate
            )
            let payload = SandboxTestersListPayload(
                testers: result.testers.map(SandboxTesterJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("sandbox_testers_list failed: \(error)")
        }
    }

    static func handleSandboxTestersGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["tester_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: tester_id")
        }
        do {
            let api = try makeSandboxAPI()
            guard let t = try await api.getSandboxTester(id: id) else {
                return errorResult("No sandbox tester with id \(id)")
            }
            return jsonResult(SandboxTesterJSON(t))
        } catch {
            return errorResult("sandbox_testers_get failed: \(error)")
        }
    }

    static func handleSandboxTestersClearHistory(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["tester_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: tester_id")
        }
        do {
            let api = try makeSandboxAPI()
            try await api.clearPurchaseHistory(testerID: id)
            return jsonResult(SandboxAck(testerID: id, action: "clearPurchaseHistory"))
        } catch {
            return errorResult("sandbox_testers_clear_history failed: \(error)")
        }
    }

    static func handleSandboxTestersModifyRenewalRate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["tester_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: tester_id")
        }
        guard let rate = params.arguments?["rate"]?.stringValue, !rate.isEmpty else {
            return errorResult("Missing required parameter: rate")
        }
        do {
            let api = try makeSandboxAPI()
            let t = try await api.modifySubscriptionRenewalRate(testerID: id, rate: rate)
            return jsonResult(SandboxTesterJSON(t))
        } catch {
            return errorResult("sandbox_testers_modify_renewal_rate failed: \(error)")
        }
    }

    static func handleSandboxTesterAppsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        do {
            let api = try makeSandboxAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let result = try await api.listSandboxTesterApps(
                appID: appID, limit: limit, cursor: cursor
            )
            let payload = SandboxTesterAppsListPayload(
                testerApps: result.testerApps.map { .init(id: $0.id) },
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("sandbox_tester_apps_list failed: \(error)")
        }
    }

    static func handleSandboxTesterAppsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["junction_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: junction_id")
        }
        do {
            let api = try makeSandboxAPI()
            guard let app = try await api.getSandboxTesterApp(id: id) else {
                return errorResult("No sandbox tester app junction with id \(id)")
            }
            return jsonResult(SandboxTesterAppJSON(id: app.id))
        } catch {
            return errorResult("sandbox_tester_apps_get failed: \(error)")
        }
    }

    // MARK: - Resource Limits handlers

    static func handleResourceLimitsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeResourceLimitsAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let result = try await api.listResourceLimits(limit: limit, cursor: cursor)
            let payload = ResourceLimitsListPayload(
                resourceLimits: result.resourceLimits.map(ResourceLimitJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("resource_limits_list failed: \(error)")
        }
    }

    static func handleResourceLimitsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["limit_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: limit_id")
        }
        do {
            let api = try makeResourceLimitsAPI()
            guard let limit = try await api.getResourceLimit(id: id) else {
                return errorResult("No resource limit with id \(id)")
            }
            return jsonResult(ResourceLimitJSON(limit))
        } catch {
            return errorResult("resource_limits_get failed: \(error)")
        }
    }

    // MARK: - App Hashes handlers

    static func handleAppHashesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        do {
            let api = try makeAppHashesAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let result = try await api.listAppHashes(
                appID: appID, limit: limit, cursor: cursor
            )
            let payload = AppHashesListPayload(
                appHashes: result.appHashes.map(AppHashJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("app_hashes_list failed: \(error)")
        }
    }

    static func handleAppHashesGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["hash_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: hash_id")
        }
        do {
            let api = try makeAppHashesAPI()
            guard let h = try await api.getAppHash(id: id) else {
                return errorResult("No app hash with id \(id)")
            }
            return jsonResult(AppHashJSON(h))
        } catch {
            return errorResult("app_hashes_get failed: \(error)")
        }
    }

    // MARK: - Diagnostic Sessions handlers

    static func handleDiagnosticSessionsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        do {
            let api = try makeDiagnosticSessionsAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let stateFilter = params.arguments?["state_filter"]?.stringValue
            let result = try await api.listProfileDiagnosticSessions(
                appID: appID,
                limit: limit,
                cursor: cursor,
                filterState: stateFilter
            )
            let payload = DiagnosticSessionsListPayload(
                sessions: result.sessions.map(DiagnosticSessionJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("diagnostic_sessions_list failed: \(error)")
        }
    }

    static func handleDiagnosticSessionsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["session_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: session_id")
        }
        do {
            let api = try makeDiagnosticSessionsAPI()
            guard let s = try await api.getProfileDiagnosticSession(id: id) else {
                return errorResult("No diagnostic session with id \(id)")
            }
            return jsonResult(DiagnosticSessionJSON(s))
        } catch {
            return errorResult("diagnostic_sessions_get failed: \(error)")
        }
    }

    static func handleDiagnosticSessionsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let buildID = params.arguments?["build_id"]?.stringValue, !buildID.isEmpty else {
            return errorResult("Missing required parameter: build_id")
        }
        let deviceFamily = params.arguments?["device_family"]?.stringValue
        let name = params.arguments?["name"]?.stringValue
        do {
            let api = try makeDiagnosticSessionsAPI()
            let s = try await api.createProfileDiagnosticSession(
                buildID: buildID, deviceFamily: deviceFamily, name: name
            )
            return jsonResult(DiagnosticSessionJSON(s))
        } catch {
            return errorResult("diagnostic_sessions_create failed: \(error)")
        }
    }

    static func handleDiagnosticSessionsComplete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["session_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: session_id")
        }
        do {
            let api = try makeDiagnosticSessionsAPI()
            let s = try await api.completeProfileDiagnosticSession(id: id)
            return jsonResult(DiagnosticSessionJSON(s))
        } catch {
            return errorResult("diagnostic_sessions_complete failed: \(error)")
        }
    }

    static func handleDiagnosticSessionsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["session_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: session_id")
        }
        do {
            let api = try makeDiagnosticSessionsAPI()
            try await api.deleteProfileDiagnosticSession(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "profileDiagnosticSession"))
        } catch {
            return errorResult("diagnostic_sessions_delete failed: \(error)")
        }
    }

    // MARK: - JSON shapes (stable wire format)

    struct PassTypeIDsListPayload: Encodable {
        let passTypeIDs: [PassTypeIDJSON]
        let cursor: String?
    }

    struct PassTypeCertsListPayload: Encodable {
        let certificates: [PassTypeCertJSON]
        let cursor: String?
    }

    struct MerchantDomainsListPayload: Encodable {
        let merchantDomains: [MerchantDomainJSON]
        let cursor: String?
    }

    struct SandboxTestersListPayload: Encodable {
        let testers: [SandboxTesterJSON]
        let cursor: String?
    }

    struct SandboxTesterAppsListPayload: Encodable {
        let testerApps: [SandboxTesterAppJSON]
        let cursor: String?
    }

    struct ResourceLimitsListPayload: Encodable {
        let resourceLimits: [ResourceLimitJSON]
        let cursor: String?
    }

    struct AppHashesListPayload: Encodable {
        let appHashes: [AppHashJSON]
        let cursor: String?
    }

    struct DiagnosticSessionsListPayload: Encodable {
        let sessions: [DiagnosticSessionJSON]
        let cursor: String?
    }

    struct PassTypeIDJSON: Encodable {
        let id: String
        let identifier: String?
        let name: String?

        init(_ p: ApplePayAPI.PassTypeID) {
            self.id = p.id
            self.identifier = p.attributes?.identifier
            self.name = p.attributes?.name
        }
    }

    struct PassTypeCertJSON: Encodable {
        let id: String
        let displayName: String?
        let name: String?
        let platform: String?
        let serialNumber: String?
        let certificateType: String?
        let expirationDate: Date?
        let certificateContent: String?

        init(_ c: ApplePayAPI.PassTypeIDCertificate) {
            self.id = c.id
            self.displayName = c.attributes?.displayName
            self.name = c.attributes?.name
            self.platform = c.attributes?.platform
            self.serialNumber = c.attributes?.serialNumber
            self.certificateType = c.attributes?.certificateType
            self.expirationDate = c.attributes?.expirationDate
            self.certificateContent = c.attributes?.certificateContent
        }
    }

    struct MerchantDomainJSON: Encodable {
        let id: String
        let domain: String?
        let domainState: String?

        init(_ d: ApplePayAPI.MerchantDomain) {
            self.id = d.id
            self.domain = d.attributes?.domain
            self.domainState = d.attributes?.domainState
        }
    }

    struct SandboxTesterJSON: Encodable {
        let id: String
        let firstName: String?
        let lastName: String?
        let territory: String?
        let locale: String?
        let subscriptionRenewalRate: String?

        init(_ t: SandboxTestersAPI.SandboxTester) {
            self.id = t.id
            self.firstName = t.attributes?.firstName
            self.lastName = t.attributes?.lastName
            self.territory = t.attributes?.territory
            self.locale = t.attributes?.locale
            self.subscriptionRenewalRate = t.attributes?.subscriptionRenewalRate
        }
    }

    struct SandboxTesterAppJSON: Encodable {
        let id: String
    }

    struct ResourceLimitJSON: Encodable {
        let id: String
        let limitType: String?
        let limit: Int?
        let currentValue: Int?

        init(_ r: ResourceLimitsAPI.ResourceLimit) {
            self.id = r.id
            self.limitType = r.attributes?.limitType
            self.limit = r.attributes?.limit
            self.currentValue = r.attributes?.currentValue
        }
    }

    struct AppHashJSON: Encodable {
        let id: String
        let hash: String?
        let hashAlgorithm: String?
        let createdDate: Date?

        init(_ h: AppHashesAPI.AppHash) {
            self.id = h.id
            self.hash = h.attributes?.hash
            self.hashAlgorithm = h.attributes?.hashAlgorithm
            self.createdDate = h.attributes?.createdDate
        }
    }

    struct DiagnosticSessionJSON: Encodable {
        let id: String
        let name: String?
        let state: String?
        let createdDate: Date?
        let endedDate: Date?
        let deviceFamily: String?

        init(_ s: DiagnosticSessionsAPI.ProfileDiagnosticSession) {
            self.id = s.id
            self.name = s.attributes?.name
            self.state = s.attributes?.state
            self.createdDate = s.attributes?.createdDate
            self.endedDate = s.attributes?.endedDate
            self.deviceFamily = s.attributes?.deviceFamily
        }
    }

    struct DeleteAck: Encodable {
        let deletedID: String
        let kind: String
    }

    struct SandboxAck: Encodable {
        let testerID: String
        let action: String
    }

    // MARK: - Helpers

    static func makeApplePayAPI() throws -> ApplePayAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return ApplePayAPI(client: client)
    }

    static func makeSandboxAPI() throws -> SandboxTestersAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return SandboxTestersAPI(client: client)
    }

    static func makeResourceLimitsAPI() throws -> ResourceLimitsAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return ResourceLimitsAPI(client: client)
    }

    static func makeAppHashesAPI() throws -> AppHashesAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return AppHashesAPI(client: client)
    }

    static func makeDiagnosticSessionsAPI() throws -> DiagnosticSessionsAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return DiagnosticSessionsAPI(client: client)
    }

    static func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text)], isError: false)
        } catch {
            return errorResult("could not encode response JSON: \(error)")
        }
    }

    static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(message)], isError: true)
    }
}
