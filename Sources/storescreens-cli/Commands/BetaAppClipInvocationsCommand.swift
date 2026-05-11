import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens beta-app-clip` command. Wraps
/// `betaAppClipInvocations` and `betaAppClipInvocationLocalizations`, the
/// URL trigger configurations Apple uses when distributing App Clips via
/// TestFlight.
///
/// Sibling of the production `storescreens marketing` app-clip commands
/// (the `app_clip_*` MCP tools); the beta variant is scoped to a single
/// build and lives only for the duration of that build's beta cycle.
///
/// Every leaf subcommand accepts `--json` for machine-readable output. The
/// same operations are exposed as MCP tools under the
/// `beta_app_clip_invocations_*` and `beta_app_clip_invocation_localizations_*`
/// namespaces.
struct BetaAppClipInvocationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-app-clip",
        abstract: "Manage TestFlight App Clip invocations + per-locale titles.",
        discussion: """
            Wraps the App Store Connect betaAppClipInvocations API. Each \
            invocation defines a URL trigger Apple uses to surface the Clip \
            (NFC tag, QR code, Safari banner) for a specific build.

            Use the `invocations` subcommands to CRUD the URL triggers; the \
            `localizations` subcommands attach per-locale title strings.
            """,
        subcommands: [
            BACInvocationsCommand.self,
            BACLocalizationsCommand.self,
        ]
    )
}

// MARK: - Shared helpers

fileprivate func bacAPI(logger: Logger) throws -> BetaAppClipInvocationsAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return BetaAppClipInvocationsAPI(client: client)
}

fileprivate func bacEmitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

fileprivate func bacEmitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value {
        try bacEmitJSON(value)
    } else {
        print("null")
    }
}

fileprivate struct BACCLIPage<Item: Encodable>: Encodable {
    let items: [Item]
    let nextCursor: String?
}

fileprivate func bacSurface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
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

// MARK: - invocations

struct BACInvocationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invocations",
        abstract: "CRUD beta App Clip URL invocations.",
        subcommands: [
            BACInvocationsListCommand.self,
            BACInvocationsCreateCommand.self,
            BACInvocationsGetCommand.self,
            BACInvocationsUpdateCommand.self,
            BACInvocationsDeleteCommand.self,
        ]
    )
}

struct BACInvocationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List invocations on a build.")
    @Option(name: .long) var buildId: String
    @Option(name: .long, help: "Max results per page (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Pagination cursor from a previous page.") var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try bacAPI(logger: logger)
        let page = try await bacSurface(
            { try await api.listInvocations(buildID: buildId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try bacEmitJSON(BACCLIPage(items: page.items, nextCursor: page.nextCursor))
            return
        }
        logger.header("Beta App Clip invocations on build \(buildId) (\(page.items.count))")
        for inv in page.items {
            let url = inv.attributes?.url ?? "(no url)"
            let action = inv.attributes?.action ?? "OPEN"
            print("  \(inv.id)\t[\(action)]\t\(url)")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct BACInvocationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new invocation on a build.")
    @Option(name: .long) var buildId: String
    @Option(name: .long, help: "Trigger URL prefix.") var url: String
    @Option(name: .long, help: "Verb (OPEN | VIEW | PLAY). Defaults to OPEN.") var action: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try bacAPI(logger: logger)
        let inv = try await bacSurface(
            { try await api.createInvocation(buildID: buildId, url: url, action: action) },
            logger: logger
        )
        if json { try bacEmitJSON(inv); return }
        logger.log("created betaAppClipInvocation \(inv.id) (\(url))", level: .success)
    }
}

struct BACInvocationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an invocation by id.")
    @Argument(help: "betaAppClipInvocation id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try bacAPI(logger: logger)
        let inv = try await bacSurface({ try await api.getInvocation(id: id) }, logger: logger)
        if json {
            try bacEmitOptionalJSON(inv)
            return
        }
        guard let inv else {
            logger.log("no betaAppClipInvocation \(id)", level: .warning)
            return
        }
        logger.header("Invocation \(inv.id)")
        print("  url:    \(inv.attributes?.url ?? "(none)")")
        print("  action: \(inv.attributes?.action ?? "OPEN")")
    }
}

struct BACInvocationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH url and/or action on an invocation.")
    @Argument(help: "betaAppClipInvocation id.") var id: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var action: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try bacAPI(logger: logger)
        let inv = try await bacSurface(
            { try await api.updateInvocation(id: id, url: url, action: action) },
            logger: logger
        )
        if json { try bacEmitJSON(inv); return }
        logger.log("updated betaAppClipInvocation \(inv.id)", level: .success)
    }
}

struct BACInvocationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an invocation.")
    @Argument(help: "betaAppClipInvocation id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try bacAPI(logger: logger)
        try await bacSurface({ try await api.deleteInvocation(id: id) }, logger: logger)
        logger.log("deleted betaAppClipInvocation \(id)", level: .success)
    }
}

// MARK: - localizations

struct BACLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localizations",
        abstract: "Per-locale title strings on a beta App Clip invocation.",
        subcommands: [
            BACLocalizationsCreateCommand.self,
            BACLocalizationsUpdateCommand.self,
            BACLocalizationsDeleteCommand.self,
        ]
    )
}

struct BACLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a per-locale title for an invocation.")
    @Option(name: .long) var invocationId: String
    @Option(name: .long, help: "e.g. en-US.") var locale: String
    @Option(name: .long) var title: String
    @Option(name: .long, help: "Optional second-line text.") var subtitle: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try bacAPI(logger: logger)
        let loc = try await bacSurface(
            { try await api.createLocalization(
                invocationID: invocationId, locale: locale, title: title, subtitle: subtitle
            ) },
            logger: logger
        )
        if json { try bacEmitJSON(loc); return }
        logger.log("created betaAppClipInvocationLocalization \(loc.id) (\(locale))", level: .success)
    }
}

struct BACLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH title and/or subtitle on a localization.")
    @Argument(help: "betaAppClipInvocationLocalization id.") var id: String
    @Option(name: .long) var title: String?
    @Option(name: .long) var subtitle: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try bacAPI(logger: logger)
        let loc = try await bacSurface(
            { try await api.updateLocalization(id: id, title: title, subtitle: subtitle) },
            logger: logger
        )
        if json { try bacEmitJSON(loc); return }
        logger.log("updated betaAppClipInvocationLocalization \(loc.id)", level: .success)
    }
}

struct BACLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a localization.")
    @Argument(help: "betaAppClipInvocationLocalization id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try bacAPI(logger: logger)
        try await bacSurface({ try await api.deleteLocalization(id: id) }, logger: logger)
        logger.log("deleted betaAppClipInvocationLocalization \(id)", level: .success)
    }
}
