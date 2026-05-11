import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens beta-feedback` command. Wraps the modern
/// TestFlight feedback API (`betaFeedbackCrashSubmissions`,
/// `betaFeedbackScreenshotSubmissions`, `betaCrashLogs`) shipped in App
/// Store Connect OpenAPI spec v4.0 (June 2025), which superseded the older
/// per-tester crash submission endpoints.
///
/// Sibling of `storescreens testflight` (Wave 1); kept as a separate
/// top-level so the resource family stays self-describing in command help.
///
/// Every leaf subcommand accepts `--json` for machine-readable output. The
/// same operations are exposed as MCP tools under the `beta_feedback_*` and
/// `beta_crash_logs_*` namespaces.
struct BetaFeedbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-feedback",
        abstract: "Manage modern TestFlight feedback (crash + screenshot submissions, crash logs).",
        discussion: """
            Wraps the modern App Store Connect TestFlight feedback API. \
            Requires credentials via `storescreens auth login` or ASC_KEY_ID / \
            ASC_ISSUER_ID / ASC_KEY_PATH env vars.

            Use `--json` on any leaf subcommand to get machine-readable output. \
            The same operations are exposed as MCP tools under the \
            `beta_feedback_*` and `beta_crash_logs_*` namespaces.
            """,
        subcommands: [
            BFCrashCommand.self,
            BFScreenshotCommand.self,
            BFCrashLogsCommand.self,
        ]
    )
}

// MARK: - Shared helpers

fileprivate func bfFeedbackAPI(logger: Logger) throws -> BetaFeedbackAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return BetaFeedbackAPI(client: client)
}

fileprivate func bfEmitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

fileprivate func bfEmitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value {
        try bfEmitJSON(value)
    } else {
        print("null")
    }
}

fileprivate func bfSurface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
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

// MARK: - crash

struct BFCrashCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crash",
        abstract: "TestFlight crash feedback submissions (modern API).",
        subcommands: [
            BFCrashGetCommand.self,
            BFCrashDeleteCommand.self,
        ]
    )
}

struct BFCrashGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a single crash feedback submission.")
    @Argument(help: "betaFeedbackCrashSubmission id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try bfFeedbackAPI(logger: logger)
        let sub = try await bfSurface({ try await api.getCrashSubmission(id: id) }, logger: logger)
        if json {
            try bfEmitOptionalJSON(sub)
            return
        }
        guard let sub else {
            logger.log("no betaFeedbackCrashSubmission \(id)", level: .warning)
            return
        }
        logger.header("Crash submission \(sub.id)")
        print("  createdDate:        \(sub.attributes?.createdDate.map(String.init(describing:)) ?? "(unknown)")")
        print("  comments:           \(sub.attributes?.comments ?? "(none)")")
        print("  deviceModel:        \(sub.attributes?.deviceModel ?? "(unknown)")")
        print("  osVersion:          \(sub.attributes?.osVersion ?? "(unknown)")")
        print("  locale:             \(sub.attributes?.locale ?? "(unknown)")")
        print("  connectionType:     \(sub.attributes?.connectionType ?? "(unknown)")")
    }
}

struct BFCrashDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a crash feedback submission.")
    @Argument(help: "betaFeedbackCrashSubmission id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try bfFeedbackAPI(logger: logger)
        try await bfSurface({ try await api.deleteCrashSubmission(id: id) }, logger: logger)
        logger.log("deleted betaFeedbackCrashSubmission \(id)", level: .success)
    }
}

// MARK: - screenshot

struct BFScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "TestFlight screenshot feedback submissions (modern API).",
        subcommands: [
            BFScreenshotGetCommand.self,
            BFScreenshotDeleteCommand.self,
        ]
    )
}

struct BFScreenshotGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a single screenshot feedback submission.")
    @Argument(help: "betaFeedbackScreenshotSubmission id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try bfFeedbackAPI(logger: logger)
        let sub = try await bfSurface({ try await api.getScreenshotSubmission(id: id) }, logger: logger)
        if json {
            try bfEmitOptionalJSON(sub)
            return
        }
        guard let sub else {
            logger.log("no betaFeedbackScreenshotSubmission \(id)", level: .warning)
            return
        }
        logger.header("Screenshot submission \(sub.id)")
        print("  createdDate:        \(sub.attributes?.createdDate.map(String.init(describing:)) ?? "(unknown)")")
        print("  comments:           \(sub.attributes?.comments ?? "(none)")")
        print("  deviceModel:        \(sub.attributes?.deviceModel ?? "(unknown)")")
        print("  osVersion:          \(sub.attributes?.osVersion ?? "(unknown)")")
        if let s = sub.attributes?.screenshot {
            print("  screenshot:")
            print("    templateUrl:    \(s.templateUrl ?? "(none)")")
            print("    width x height: \(s.width.map(String.init) ?? "?") x \(s.height.map(String.init) ?? "?")")
            print("    fileName:       \(s.fileName ?? "(none)")")
        }
    }
}

struct BFScreenshotDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a screenshot feedback submission.")
    @Argument(help: "betaFeedbackScreenshotSubmission id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try bfFeedbackAPI(logger: logger)
        try await bfSurface({ try await api.deleteScreenshotSubmission(id: id) }, logger: logger)
        logger.log("deleted betaFeedbackScreenshotSubmission \(id)", level: .success)
    }
}

// MARK: - crash-logs

struct BFCrashLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crash-logs",
        abstract: "TestFlight crash log artifacts referenced by crash submissions.",
        subcommands: [
            BFCrashLogsGetCommand.self,
            BFCrashLogsDownloadCommand.self,
        ]
    )
}

struct BFCrashLogsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get betaCrashLog metadata + download URL.")
    @Argument(help: "betaCrashLog id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try bfFeedbackAPI(logger: logger)
        let log = try await bfSurface({ try await api.getCrashLog(id: id) }, logger: logger)
        if json {
            try bfEmitOptionalJSON(log)
            return
        }
        guard let log else {
            logger.log("no betaCrashLog \(id)", level: .warning)
            return
        }
        logger.header("Crash log \(log.id)")
        print("  downloadUrl:        \(log.attributes?.downloadUrl ?? "(none yet)")")
        print("  expirationDate:     \(log.attributes?.expirationDate.map(String.init(describing:)) ?? "(none)")")
        print("  fileSizeBytes:      \(log.attributes?.fileSizeBytes.map(String.init) ?? "(unknown)")")
    }
}

struct BFCrashLogsDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "download", abstract: "Download a betaCrashLog .crash file.")
    @Argument(help: "betaCrashLog id.") var id: String
    @Option(name: .long, help: "Output path for the .crash file. If omitted, writes to <id>.crash in the current directory.") var output: String?

    func run() async throws {
        let logger = Logger()
        let api = try bfFeedbackAPI(logger: logger)
        let bytes = try await bfSurface({ try await api.downloadLog(id: id) }, logger: logger)
        let outputPath = output ?? "\(id).crash"
        try bytes.write(to: URL(fileURLWithPath: outputPath))
        logger.log("wrote \(bytes.count) bytes to \(outputPath)", level: .success)
    }
}
