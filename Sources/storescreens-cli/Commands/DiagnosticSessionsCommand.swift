import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens diagnostic-sessions …` parent command: manages
/// `profileDiagnosticSessions`, the per-build sessions Xcode Instruments
/// uses for power and performance diagnostics. Each session represents
/// one period during which Apple's device telemetry collects samples
/// against a specific build.
///
/// Related `perfPowerMetrics` (per-app + per-build performance snapshots)
/// and `diagnosticSignatures` (crash / hang signature rollups) live under
/// the existing `storescreens reports` subcommand surface, see
/// `storescreens reports diagnostic-signatures` and
/// `storescreens reports perf-power-metrics`.
struct DiagnosticSessionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostic-sessions",
        abstract: "Manage Xcode Instruments diagnostic sessions per build.",
        discussion: """
            Wraps Apple's profileDiagnosticSessions endpoint. Requires ASC \
            credentials with App Manager or Admin scope.

            Each session is scoped to one build + device-family pair; spin \
            up multiple sessions to compare across iPhone / iPad / etc. \
            Sessions left in IN_PROGRESS time out automatically on Apple's \
            side after a few hours, but completing them explicitly frees \
            the slot sooner.

            Related metrics: `storescreens reports diagnostic-signatures` \
            and `storescreens reports perf-power-metrics`.
            """,
        subcommands: [
            DiagnosticSessionsListCommand.self,
            DiagnosticSessionsGetCommand.self,
            DiagnosticSessionsCreateCommand.self,
            DiagnosticSessionsCompleteCommand.self,
            DiagnosticSessionsDeleteCommand.self,
        ],
        defaultSubcommand: DiagnosticSessionsListCommand.self
    )
}

// MARK: - shared helpers

@discardableResult
private func resolveDiagnosticSessionsAPI(logger: Logger) throws -> DiagnosticSessionsAPI {
    guard ASCCredentialResolver.isConfigured() else {
        logger.log("no ASC credentials configured", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let creds = try ASCCredentialResolver.resolve()
    let client = ASCClient(credentials: creds)
    return DiagnosticSessionsAPI(client: client)
}

private func emitDiagnosticSessionsJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

// MARK: - list

struct DiagnosticSessionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List profile diagnostic sessions for an app."
    )

    @Argument(help: "ASC numeric app id.")
    var appID: String

    @Option(name: .long, help: "Filter by state (IN_PROGRESS or COMPLETE).")
    var state: String?

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDiagnosticSessionsAPI(logger: logger)
        let result = try await api.listProfileDiagnosticSessions(
            appID: appID, limit: limit, cursor: cursor, filterState: state
        )
        if json {
            struct Out: Encodable {
                let sessions: [DiagnosticSessionsAPI.ProfileDiagnosticSession]
                let nextCursor: String?
            }
            try emitDiagnosticSessionsJSON(Out(sessions: result.sessions, nextCursor: result.nextCursor))
            return
        }
        logger.header("Diagnostic sessions for \(appID) (\(result.sessions.count))")
        if result.sessions.isEmpty {
            print("  (none)")
            return
        }
        for s in result.sessions {
            print("  \(s.attributes?.name ?? "(no name)")")
            print("    id:           \(s.id)")
            print("    state:        \(s.attributes?.state ?? "(unset)")")
            if let f = s.attributes?.deviceFamily {
                print("    deviceFamily: \(f)")
            }
            if let d = s.attributes?.createdDate {
                print("    created:      \(d)")
            }
            if let d = s.attributes?.endedDate {
                print("    ended:        \(d)")
            }
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

// MARK: - get

struct DiagnosticSessionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one profile diagnostic session by id."
    )

    @Argument(help: "Session id.")
    var sessionID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDiagnosticSessionsAPI(logger: logger)
        guard let s = try await api.getProfileDiagnosticSession(id: sessionID) else {
            logger.log("no session with id \(sessionID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitDiagnosticSessionsJSON(s)
            return
        }
        logger.header(s.attributes?.name ?? s.id)
        print("  id:           \(s.id)")
        print("  name:         \(s.attributes?.name ?? "(unset)")")
        print("  state:        \(s.attributes?.state ?? "(unset)")")
        print("  deviceFamily: \(s.attributes?.deviceFamily ?? "(unset)")")
        print("  createdDate:  \(s.attributes?.createdDate.map(String.init(describing:)) ?? "(unset)")")
        print("  endedDate:    \(s.attributes?.endedDate.map(String.init(describing:)) ?? "(unset)")")
    }
}

// MARK: - create

struct DiagnosticSessionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Start a new profile diagnostic session for a build.",
        discussion: """
            Apple scopes the session to one build + device-family pair. \
            Sessions are typically used by Xcode Instruments, but the API \
            surface is here for programmatic test harnesses.
            """
    )

    @Option(name: .long, help: "ASC build id the session targets.")
    var buildID: String

    @Option(name: .long, help: "Device family identifier (e.g. IPHONE, IPAD).")
    var deviceFamily: String?

    @Option(name: .long, help: "Free-form session label shown in Xcode Instruments.")
    var name: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDiagnosticSessionsAPI(logger: logger)
        let s = try await api.createProfileDiagnosticSession(
            buildID: buildID, deviceFamily: deviceFamily, name: name
        )
        if json {
            try emitDiagnosticSessionsJSON(s)
        } else {
            logger.log("created diagnostic session \(s.id)", level: .success)
            if let st = s.attributes?.state {
                print("  state: \(st)")
            }
        }
    }
}

// MARK: - complete

struct DiagnosticSessionsCompleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "complete",
        abstract: "Mark an in-progress diagnostic session as COMPLETE."
    )

    @Argument(help: "Session id.")
    var sessionID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDiagnosticSessionsAPI(logger: logger)
        let s = try await api.completeProfileDiagnosticSession(id: sessionID)
        if json {
            try emitDiagnosticSessionsJSON(s)
        } else {
            logger.log("completed session \(s.id)", level: .success)
            if let st = s.attributes?.state {
                print("  state: \(st)")
            }
        }
    }
}

// MARK: - delete

struct DiagnosticSessionsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a diagnostic session record."
    )

    @Argument(help: "Session id.")
    var sessionID: String

    @Flag(name: [.short, .long], help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let logger = Logger()
        if !yes {
            print("About to delete diagnostic session \(sessionID). Continue? [y/N] ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                logger.log("aborted", level: .info)
                return
            }
        }
        let api = try resolveDiagnosticSessionsAPI(logger: logger)
        try await api.deleteProfileDiagnosticSession(id: sessionID)
        logger.log("deleted session \(sessionID)", level: .success)
    }
}
