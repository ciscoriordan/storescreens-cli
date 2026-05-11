import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens webhooks` command. Wraps App Store Connect's
/// general-purpose Webhooks API as nested subcommands so AI agents (and
/// humans) can subscribe HTTPS endpoints to ASC event streams (build
/// status, review state, app availability, etc.) without hand-rolling
/// HTTP requests.
///
/// This is distinct from `storescreens alt-dist marketplace webhooks`
/// which wraps the EU-only `marketplaceWebhooks` resource for
/// Alternative Distribution. Use this surface for everything that is
/// not marketplace-distribution-specific.
///
/// Every leaf subcommand accepts `--json` for machine-readable output;
/// without it, results print as readable text via the shared Logger.
struct WebhooksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webhooks",
        abstract: "Manage App Store Connect webhook subscriptions: create, list, inspect deliveries, ping endpoints.",
        discussion: """
            Wraps the App Store Connect Webhooks API so a reactive AI \
            agent (or any other automation) can subscribe to live ASC \
            events (build status changes, review state transitions, \
            app availability changes, TestFlight events, etc.) without \
            polling. Requires credentials via `storescreens auth login` \
            or ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH env vars.

            Use `--json` on any leaf subcommand for machine-readable \
            output. The same operations are exposed as MCP tools under \
            the `webhooks_*` namespace.

            Note: this is the general-purpose webhooks resource. For \
            EU DMA Alternative Distribution webhooks, see \
            `storescreens alt-dist marketplace webhooks`.
            """,
        subcommands: [
            WHListCommand.self,
            WHListForAppCommand.self,
            WHGetCommand.self,
            WHCreateCommand.self,
            WHUpdateCommand.self,
            WHDeleteCommand.self,
            WHDeliveriesCommand.self,
            WHPingCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// Resolves ASC credentials and builds a WebhooksAPI client. Throws
/// ExitCode(1) after logging on failure so subcommands stay tiny.
fileprivate func whClient(logger: Logger) throws -> WebhooksAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return WebhooksAPI(client: client)
}

/// Emits any `Encodable` as pretty-printed JSON on stdout.
fileprivate func whEmitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

/// Emit-helper for "single resource or nil" results.
fileprivate func whEmitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value {
        try whEmitJSON(value)
    } else {
        print("null")
    }
}

/// Wraps a paged WebhooksAPI page in the same shape MCP tools emit.
fileprivate struct WHCLIPage<Item: Encodable>: Encodable {
    let data: [Item]
    let nextCursor: String?
}

/// Maps ASCClient.APIError to a readable, formatted error then throws
/// ExitCode(1). Other errors propagate.
fileprivate func whSurface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
    do {
        return try await block()
    } catch let e as ASCClient.APIError {
        logger.log("App Store Connect API error: HTTP \(e.statusCode)", level: .error)
        for d in e.details {
            print("  [\(d.code)] \(d.title): \(d.detail)")
        }
        throw ExitCode(1)
    }
}

/// Parse a comma-separated CLI flag value into an array of trimmed,
/// non-empty event-type strings. Used by `create` and `update`.
fileprivate func whParseEvents(_ raw: String?) -> [String]? {
    guard let raw, !raw.isEmpty else { return nil }
    let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let filtered = parts.filter { !$0.isEmpty }
    return filtered.isEmpty ? nil : filtered
}

// MARK: - list

struct WHListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List webhook subscriptions on the account."
    )

    @Option(name: .long, help: "Max results per page (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Pagination cursor from a previous page.") var cursor: String?
    @Flag(name: .long, help: "Emit JSON instead of text.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try whClient(logger: logger)
        let page = try await whSurface(
            { try await api.webhooks.list(limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try whEmitJSON(WHCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Webhooks (\(page.data.count))")
        for w in page.data {
            let name = w.attributes?.name ?? "(no name)"
            let url = w.attributes?.url ?? "(no url)"
            let active = w.attributes?.active.map { $0 ? "active" : "inactive" } ?? "(no state)"
            print("  \(w.id)  \(name)  [\(active)]  \(url)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

// MARK: - list --app-id (apps/{id}/webhooks)

struct WHListForAppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-for-app",
        abstract: "List webhook subscriptions scoped to a single app."
    )

    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try whClient(logger: logger)
        let page = try await whSurface(
            { try await api.webhooks.listForApp(appID: appId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try whEmitJSON(WHCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Webhooks for app \(appId) (\(page.data.count))")
        for w in page.data {
            let name = w.attributes?.name ?? "(no name)"
            let url = w.attributes?.url ?? "(no url)"
            let active = w.attributes?.active.map { $0 ? "active" : "inactive" } ?? "(no state)"
            print("  \(w.id)  \(name)  [\(active)]  \(url)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

// MARK: - get

struct WHGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a webhook subscription by id."
    )

    @Argument(help: "Webhook id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try whClient(logger: logger)
        let w = try await whSurface({ try await api.webhooks.get(id: id) }, logger: logger)
        if json {
            try whEmitOptionalJSON(w)
            return
        }
        guard let w else {
            logger.log("no webhook \(id)", level: .warning)
            return
        }
        logger.header("Webhook \(w.id)")
        print("  name:   \(w.attributes?.name ?? "(none)")")
        print("  url:    \(w.attributes?.url ?? "(none)")")
        print("  active: \(w.attributes?.active.map(String.init(describing:)) ?? "(none)")")
        let events = w.attributes?.eventTypes ?? []
        print("  events: \(events.isEmpty ? "(none)" : events.joined(separator: ", "))")
        if let app = w.relationships?.app?.data?.id {
            print("  app:    \(app)")
        }
    }
}

// MARK: - create

struct WHCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new webhook subscription."
    )

    @Option(name: .long, help: "Numeric ASC app id this subscription is scoped to.")
    var appId: String

    @Option(name: .long, help: "HTTPS endpoint Apple will POST event payloads to.")
    var url: String

    @Option(name: .long, help: "Human-friendly label shown in the ASC web UI.")
    var name: String

    @Option(
        name: .long,
        help: "Comma-separated list of ASC event-type identifiers to subscribe to (e.g. buildState,appStoreVersionState). Apple ships new event types every quarter."
    )
    var events: String

    @Option(name: .long, help: "HMAC shared secret Apple signs each payload with (optional).")
    var secret: String?

    @Flag(name: .long, help: "Create the subscription inactive (default: active).")
    var inactive: Bool = false

    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        guard let eventTypes = whParseEvents(events) else {
            logger.log("--events must be a non-empty comma-separated list", level: .error)
            throw ExitCode(1)
        }
        let api = try whClient(logger: logger)
        let active: Bool? = inactive ? false : nil
        let w = try await whSurface(
            { try await api.webhooks.create(
                appID: appId,
                url: url,
                name: name,
                eventTypes: eventTypes,
                secret: secret,
                active: active
            ) },
            logger: logger
        )
        if json {
            try whEmitJSON(w)
            return
        }
        logger.log("created webhook \(w.id) -> \(url)", level: .success)
        if let s = w.attributes?.secret {
            logger.log("apple returned a generated secret; store it now (subsequent reads will redact it):", level: .warning)
            print("  secret: \(s)")
        }
    }
}

// MARK: - update

struct WHUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a webhook subscription. Only the fields you pass are changed."
    )

    @Argument(help: "Webhook id.") var id: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var name: String?
    @Option(name: .long, help: "Replace the subscribed event-type list (comma-separated).")
    var events: String?
    @Option(name: .long) var secret: String?
    @Option(name: .long, help: "Set active flag (true|false).") var active: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try whClient(logger: logger)
        let eventTypes = whParseEvents(events)
        let fields = WebhooksAPI.WebhookUpdateFields(
            url: url,
            name: name,
            eventTypes: eventTypes,
            secret: secret,
            active: active
        )
        let w = try await whSurface(
            { try await api.webhooks.update(id: id, fields: fields) },
            logger: logger
        )
        if json {
            try whEmitJSON(w)
            return
        }
        logger.log("updated webhook \(w.id)", level: .success)
    }
}

// MARK: - delete

struct WHDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a webhook subscription."
    )

    @Argument(help: "Webhook id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try whClient(logger: logger)
        try await whSurface({ try await api.webhooks.delete(id: id) }, logger: logger)
        logger.log("deleted webhook \(id)", level: .success)
    }
}

// MARK: - deliveries (nested subcommand group)

struct WHDeliveriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deliveries",
        abstract: "Inspect or resend webhook delivery records.",
        subcommands: [
            WHDeliveriesListCommand.self,
            WHDeliveriesGetCommand.self,
            WHDeliveriesResendCommand.self,
        ]
    )
}

struct WHDeliveriesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List delivery records for a single webhook."
    )

    @Option(name: .long, help: "Webhook id whose deliveries to list.") var webhookId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try whClient(logger: logger)
        let page = try await whSurface(
            { try await api.deliveries.list(webhookID: webhookId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try whEmitJSON(WHCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Deliveries for webhook \(webhookId) (\(page.data.count))")
        for d in page.data {
            let event = d.attributes?.eventType ?? "(no event)"
            let state = d.attributes?.state ?? "(no state)"
            let code = d.attributes?.responseCode.map(String.init) ?? "-"
            let attempts = d.attributes?.attemptCount.map(String.init) ?? "-"
            print("  \(d.id)  [\(state)]  \(event)  http=\(code)  attempts=\(attempts)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct WHDeliveriesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a webhook delivery record by id."
    )

    @Argument(help: "Delivery id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try whClient(logger: logger)
        let d = try await whSurface({ try await api.deliveries.get(id: id) }, logger: logger)
        if json {
            try whEmitOptionalJSON(d)
            return
        }
        guard let d else {
            logger.log("no delivery \(id)", level: .warning)
            return
        }
        try whEmitJSON(d)
    }
}

struct WHDeliveriesResendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resend",
        abstract: "Retrigger a past delivery."
    )

    @Option(name: .long, help: "Delivery id to resend.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try whClient(logger: logger)
        let d = try await whSurface(
            { try await api.deliveries.resend(id: id) },
            logger: logger
        )
        if json {
            try whEmitJSON(d)
            return
        }
        logger.log("resent delivery \(d.id)", level: .success)
        print("  state:        \(d.attributes?.state ?? "(none)")")
        print("  responseCode: \(d.attributes?.responseCode.map(String.init) ?? "(none)")")
    }
}

// MARK: - ping

struct WHPingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Dispatch a synthetic ping payload to a webhook's URL to verify the endpoint is alive."
    )

    @Option(name: .long, help: "Webhook id to ping.") var webhookId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try whClient(logger: logger)
        let p = try await whSurface(
            { try await api.pings.create(webhookID: webhookId) },
            logger: logger
        )
        if json {
            try whEmitJSON(p)
            return
        }
        logger.log("dispatched ping for webhook \(webhookId)", level: .success)
        print("  ping id:      \(p.id)")
        print("  state:        \(p.attributes?.state ?? "(none)")")
        print("  responseCode: \(p.attributes?.responseCode.map(String.init) ?? "(none)")")
    }
}
