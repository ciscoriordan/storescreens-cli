import MCP
import Foundation
import StorescreensCore

/// MCP tool surface for App Store Connect's general-purpose Webhooks
/// API. Webhooks let AI agents (and any other automation) subscribe
/// an HTTPS endpoint to live ASC events (build status, review state,
/// app availability, etc.) so they can drive reactive workflows
/// without polling.
///
/// Every tool is a thin wrapper around a `WebhooksAPI` method. Inputs
/// arrive as JSON arguments, outputs are pretty-printed JSON text
/// content so AI agents get a stable, machine-readable response shape
/// without having to construct raw HTTP requests against Apple's API.
///
/// Tool naming convention: `webhooks_<resource>_<op>` or
/// `webhooks_<op>` snake_case. This surface is distinct from
/// `altdist_marketplace_webhooks_*` which wraps the EU-only
/// `marketplaceWebhooks` resource for Alternative Distribution.
enum WebhooksMCPTools {

    // MARK: - Tool definitions

    static let tools: [Tool] = [

        // webhooks --------------------------------------------------

        Tool(
            name: "webhooks_list",
            description: """
            List webhook subscriptions on the account. Each webhook \
            holds an HTTPS endpoint URL, a list of subscribed App \
            Store Connect event types, an HMAC signing secret, and \
            an active flag. Supports cursor-based pagination via the \
            `cursor` argument.
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
            name: "webhooks_list_for_app",
            description: """
            List webhook subscriptions scoped to a single app. Wraps \
            the apps/{id}/webhooks relationship endpoint. Use this \
            when the agent already knows the app id and only wants \
            its subscriptions.
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
            name: "webhooks_get",
            description: "Get a single webhook subscription by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Webhook id")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "webhooks_create",
            description: """
            Create a webhook subscription. Apple will POST JSON \
            payloads to `url` every time one of the events in \
            `event_types` fires for the given app. The HMAC `secret` \
            is returned once on the create response; capture it then \
            to verify signatures on incoming payloads (Apple typically \
            redacts the secret on subsequent reads). The `event_types` \
            list is passed through verbatim to Apple; consult Apple's \
            docs for the current event-type catalog.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string"), "description": .string("Numeric ASC app id this subscription is scoped to")]),
                    "url": .object(["type": .string("string"), "description": .string("HTTPS endpoint Apple will POST payloads to")]),
                    "name": .object(["type": .string("string"), "description": .string("Human-friendly label shown in the ASC web UI")]),
                    "event_types": .object([
                        "type": .string("array"),
                        "description": .string("List of ASC event-type identifiers to subscribe to (e.g. buildState, appStoreVersionState). Apple ships new event types every quarter; pass through verbatim."),
                    ]),
                    "secret": .object(["type": .string("string"), "description": .string("HMAC shared secret Apple signs each payload with (optional; Apple can generate one)")]),
                    "active": .object(["type": .string("boolean"), "description": .string("Whether the subscription is active (default: true server-side)")]),
                ]),
                "required": .array([.string("app_id"), .string("url"), .string("name"), .string("event_types")]),
            ])
        ),

        Tool(
            name: "webhooks_update",
            description: """
            PATCH a webhook subscription. Only the fields you pass are \
            changed; omitted fields stay as-is on Apple's side. Use \
            `active: false` to soft-disable the subscription without \
            deleting it. The owning app cannot be reassigned.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "url": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "event_types": .object([
                        "type": .string("array"),
                        "description": .string("Replace the subscribed event-type list. Pass the full desired set."),
                    ]),
                    "secret": .object(["type": .string("string")]),
                    "active": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "webhooks_delete",
            description: """
            Delete a webhook subscription. Apple stops dispatching \
            deliveries to the URL and drops the historical delivery \
            records associated with it.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // webhookDeliveries ----------------------------------------

        Tool(
            name: "webhooks_deliveries_list",
            description: """
            List delivery records for a single webhook. Each record \
            captures one attempt to POST an event payload to the \
            webhook's URL, including the HTTP status the endpoint \
            returned. Use `cursor` to page; deliveries can pile up \
            quickly for chatty event types.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "webhook_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("webhook_id")]),
            ])
        ),

        Tool(
            name: "webhooks_deliveries_get",
            description: "Get a single webhook delivery record by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "webhooks_deliveries_resend",
            description: """
            Retrigger a past delivery. Apple POSTs the same payload \
            to the webhook's URL again and records the new attempt's \
            outcome. Useful for replaying a failed delivery after \
            fixing the receiving endpoint.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("webhookDeliveries id to resend")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // webhookPings ---------------------------------------------

        Tool(
            name: "webhooks_pings_create",
            description: """
            Dispatch a synthetic ping payload to a webhook's URL to \
            verify the endpoint is alive, reachable, and properly \
            verifying signatures. Apple's response carries the HTTP \
            status and body the endpoint returned in one round-trip, \
            so the caller doesn't have to wait for a real event.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "webhook_id": .object(["type": .string("string"), "description": .string("Webhook id to ping")]),
                ]),
                "required": .array([.string("webhook_id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Tool names handled by this module. Used by the MCP main
    /// dispatcher to route a CallTool request to `handle` when the
    /// name starts with `webhooks_`.
    static let toolNames: Set<String> = Set(tools.map(\.name))

    /// Master entry point. Resolves credentials, constructs the API
    /// wrapper, and dispatches to the matching handler by tool name.
    /// All handlers return JSON text content; errors surface as
    /// `isError: true` results so the agent can react cleanly.
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
        let api = WebhooksAPI(client: client)

        do {
            switch params.name {

            case "webhooks_list":          return try await handleList(params, api: api)
            case "webhooks_list_for_app":  return try await handleListForApp(params, api: api)
            case "webhooks_get":           return try await handleGet(params, api: api)
            case "webhooks_create":        return try await handleCreate(params, api: api)
            case "webhooks_update":        return try await handleUpdate(params, api: api)
            case "webhooks_delete":        return try await handleDelete(params, api: api)

            case "webhooks_deliveries_list":   return try await handleDeliveriesList(params, api: api)
            case "webhooks_deliveries_get":    return try await handleDeliveriesGet(params, api: api)
            case "webhooks_deliveries_resend": return try await handleDeliveriesResend(params, api: api)

            case "webhooks_pings_create": return try await handlePingsCreate(params, api: api)

            default:
                return errorResult("Unknown Webhooks tool: \(params.name)")
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

    private static func optionalBool(_ params: CallTool.Parameters, _ key: String) -> Bool? {
        arg(params, key)?.boolValue
    }

    /// Reads a JSON array of strings from the named argument. Falls
    /// back to a comma-separated string if the agent passed a CSV
    /// instead of an array (some clients are inconsistent about
    /// how they render list-typed parameters).
    private static func optionalStringArray(_ params: CallTool.Parameters, _ key: String) -> [String]? {
        if let arr = arg(params, key)?.arrayValue {
            return arr.compactMap { $0.stringValue }
        }
        if let csv = arg(params, key)?.stringValue {
            let parts = csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.filter { !$0.isEmpty }
        }
        return nil
    }

    private static func requireStringArray(_ params: CallTool.Parameters, _ key: String) throws -> [String] {
        guard let arr = optionalStringArray(params, key), !arr.isEmpty else {
            throw MCPArgError("Missing required array-of-string argument: \(key)")
        }
        return arr
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

    // MARK: - Handlers: webhooks

    private static func handleList(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.webhooks.list(limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleListForApp(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.webhooks.listForApp(
            appID: appID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleGet(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let w = try await api.webhooks.get(id: id)
        return try jsonText(w)
    }

    private static func handleCreate(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let url = try requireString(params, "url")
        let name = try requireString(params, "name")
        let eventTypes = try requireStringArray(params, "event_types")
        let secret = optionalString(params, "secret")
        let active = optionalBool(params, "active")
        let w = try await api.webhooks.create(
            appID: appID,
            url: url,
            name: name,
            eventTypes: eventTypes,
            secret: secret,
            active: active
        )
        return try jsonText(w)
    }

    private static func handleUpdate(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = WebhooksAPI.WebhookUpdateFields(
            url: optionalString(params, "url"),
            name: optionalString(params, "name"),
            eventTypes: optionalStringArray(params, "event_types"),
            secret: optionalString(params, "secret"),
            active: optionalBool(params, "active")
        )
        let w = try await api.webhooks.update(id: id, fields: fields)
        return try jsonText(w)
    }

    private static func handleDelete(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.webhooks.delete(id: id)
        return ackResult("Deleted webhook \(id)")
    }

    // MARK: - Handlers: deliveries

    private static func handleDeliveriesList(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let webhookID = try requireString(params, "webhook_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.deliveries.list(
            webhookID: webhookID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleDeliveriesGet(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let d = try await api.deliveries.get(id: id)
        return try jsonText(d)
    }

    private static func handleDeliveriesResend(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let d = try await api.deliveries.resend(id: id)
        return try jsonText(d)
    }

    // MARK: - Handlers: pings

    private static func handlePingsCreate(
        _ params: CallTool.Parameters, api: WebhooksAPI
    ) async throws -> CallTool.Result {
        let webhookID = try requireString(params, "webhook_id")
        let p = try await api.pings.create(webhookID: webhookID)
        return try jsonText(p)
    }
}
