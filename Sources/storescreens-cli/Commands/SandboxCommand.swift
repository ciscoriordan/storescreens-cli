import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens sandbox …` parent command: read + per-tester actions on
/// Apple's sandbox tester accounts (the synthetic users used for testing
/// in-app purchases without real charges). Apple does not let you create
/// or delete sandbox testers via the API: they are created through the
/// App Store Connect web UI under "Users and Access > Sandbox > Testers".
struct SandboxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sandbox",
        abstract: "Manage App Store Connect sandbox testers and per-app access.",
        discussion: """
            Wraps Apple's sandboxTesters and sandboxTesterApps endpoints. \
            Requires ASC credentials (App Manager or Admin scope).

            Note that Apple does not surface tester emails / passwords in \
            the API response; only first name, last name, territory, locale, \
            and subscription renewal rate. Create testers via the ASC web UI \
            under Users and Access > Sandbox > Testers.

            Subscription renewal rates: REAL_TIME (matches production), \
            ONE_TIME, ONE_HOUR, THIRTY_MINUTES, FIFTEEN_MINUTES, FIVE_MINUTES.
            """,
        subcommands: [
            SandboxTestersCommand.self,
            SandboxAppsCommand.self,
        ]
    )
}

// MARK: - shared helpers

@discardableResult
private func resolveSandboxAPI(logger: Logger) throws -> SandboxTestersAPI {
    guard ASCCredentialResolver.isConfigured() else {
        logger.log("no ASC credentials configured", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let creds = try ASCCredentialResolver.resolve()
    let client = ASCClient(credentials: creds)
    return SandboxTestersAPI(client: client)
}

private func emitSandboxJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

// MARK: - testers

struct SandboxTestersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "testers",
        abstract: "List, fetch, and act on sandbox testers.",
        subcommands: [
            SandboxTestersListCommand.self,
            SandboxTestersGetCommand.self,
            SandboxTestersClearHistoryCommand.self,
            SandboxTestersModifyRenewalRateCommand.self,
        ],
        defaultSubcommand: SandboxTestersListCommand.self
    )
}

struct SandboxTestersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List sandbox testers on the team."
    )

    @Option(name: .long, help: "Filter by territory (e.g. USA, GBR, JPN).")
    var territory: String?

    @Option(name: .long, help: "Filter by subscription renewal rate (e.g. REAL_TIME).")
    var renewalRate: String?

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveSandboxAPI(logger: logger)
        let result = try await api.listSandboxTesters(
            limit: limit,
            cursor: cursor,
            filterTerritory: territory,
            filterRenewalRate: renewalRate
        )
        if json {
            struct Out: Encodable {
                let testers: [SandboxTestersAPI.SandboxTester]
                let nextCursor: String?
            }
            try emitSandboxJSON(Out(testers: result.testers, nextCursor: result.nextCursor))
            return
        }
        logger.header("Sandbox testers (\(result.testers.count))")
        if result.testers.isEmpty {
            print("  (none)")
            return
        }
        for t in result.testers {
            let name = [t.attributes?.firstName, t.attributes?.lastName]
                .compactMap { $0 }.joined(separator: " ")
            print("  \(name.isEmpty ? "(no name)" : name)")
            print("    id:        \(t.id)")
            print("    territory: \(t.attributes?.territory ?? "(unset)")")
            print("    locale:    \(t.attributes?.locale ?? "(unset)")")
            print("    renewal:   \(t.attributes?.subscriptionRenewalRate ?? "(unset)")")
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct SandboxTestersGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one sandbox tester by id."
    )

    @Argument(help: "Sandbox tester id.")
    var testerID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveSandboxAPI(logger: logger)
        guard let t = try await api.getSandboxTester(id: testerID) else {
            logger.log("no sandbox tester with id \(testerID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitSandboxJSON(t)
            return
        }
        let name = [t.attributes?.firstName, t.attributes?.lastName]
            .compactMap { $0 }.joined(separator: " ")
        logger.header(name.isEmpty ? t.id : name)
        print("  id:                      \(t.id)")
        print("  firstName:               \(t.attributes?.firstName ?? "(unset)")")
        print("  lastName:                \(t.attributes?.lastName ?? "(unset)")")
        print("  territory:               \(t.attributes?.territory ?? "(unset)")")
        print("  locale:                  \(t.attributes?.locale ?? "(unset)")")
        print("  subscriptionRenewalRate: \(t.attributes?.subscriptionRenewalRate ?? "(unset)")")
    }
}

struct SandboxTestersClearHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-history",
        abstract: "Clear a sandbox tester's accumulated purchase history.",
        discussion: """
            Useful when re-running an IAP flow that gates state on whether \
            the tester has already bought the product. Apple processes the \
            request asynchronously; the side effect lands within a few \
            seconds.
            """
    )

    @Argument(help: "Sandbox tester id.")
    var testerID: String

    func run() async throws {
        let logger = Logger()
        let api = try resolveSandboxAPI(logger: logger)
        try await api.clearPurchaseHistory(testerID: testerID)
        logger.log("cleared purchase history for tester \(testerID)", level: .success)
    }
}

struct SandboxTestersModifyRenewalRateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "modify-renewal-rate",
        abstract: "Change a sandbox tester's subscription renewal rate.",
        discussion: """
            Use the faster rates (FIVE_MINUTES, FIFTEEN_MINUTES) to walk \
            through renewal flows without waiting real-world time; REAL_TIME \
            matches production timing exactly. Valid values: REAL_TIME, \
            ONE_TIME, ONE_HOUR, THIRTY_MINUTES, FIFTEEN_MINUTES, FIVE_MINUTES.
            """
    )

    @Argument(help: "Sandbox tester id.")
    var testerID: String

    @Option(name: .long, help: "New renewal rate (e.g. FIVE_MINUTES).")
    var rate: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveSandboxAPI(logger: logger)
        let t = try await api.modifySubscriptionRenewalRate(testerID: testerID, rate: rate)
        if json {
            try emitSandboxJSON(t)
        } else {
            logger.log(
                "tester \(t.id) renewal rate is now \(t.attributes?.subscriptionRenewalRate ?? rate)",
                level: .success
            )
        }
    }
}

// MARK: - apps

struct SandboxAppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "Inspect which sandbox testers have access to a specific app.",
        subcommands: [
            SandboxAppsListCommand.self,
            SandboxAppsGetCommand.self,
        ],
        defaultSubcommand: SandboxAppsListCommand.self
    )
}

struct SandboxAppsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List sandbox-tester / app junction records for one app."
    )

    @Argument(help: "ASC numeric app id.")
    var appID: String

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveSandboxAPI(logger: logger)
        let result = try await api.listSandboxTesterApps(
            appID: appID, limit: limit, cursor: cursor
        )
        if json {
            struct Out: Encodable {
                let testerApps: [SandboxTestersAPI.SandboxTesterApp]
                let nextCursor: String?
            }
            try emitSandboxJSON(Out(testerApps: result.testerApps, nextCursor: result.nextCursor))
            return
        }
        logger.header("Sandbox tester app junctions for \(appID) (\(result.testerApps.count))")
        if result.testerApps.isEmpty {
            print("  (none)")
            return
        }
        for a in result.testerApps {
            print("  \(a.id)")
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct SandboxAppsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one sandbox-tester-app junction record by id."
    )

    @Argument(help: "Junction record id.")
    var junctionID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveSandboxAPI(logger: logger)
        guard let a = try await api.getSandboxTesterApp(id: junctionID) else {
            logger.log("no junction record with id \(junctionID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitSandboxJSON(a)
            return
        }
        logger.header(a.id)
        print("  id: \(a.id)")
    }
}
