import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens resource-limits …` parent command: read-only access to
/// the team's quota records. Folds in the small `app-hashes` subcommand
/// since both surfaces are read-only one-shot lookups.
struct ResourceLimitsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resource-limits",
        abstract: "Inspect the team's App Store Connect resource quotas.",
        discussion: """
            Wraps Apple's resourceLimits and appHashes endpoints. Requires \
            ASC credentials.

            Resource limits are the team-level quotas Apple enforces (max \
            apps per team, max in-app purchases per app, max users, etc). \
            Useful as a precursor to "can I create another app on this team?" \
            workflows.

            App hashes are the cryptographic hash records Apple emits during \
            signing migrations; teams typically have a single record per app. \
            See `storescreens resource-limits app-hashes`.
            """,
        subcommands: [
            ResourceLimitsListCommand.self,
            ResourceLimitsGetCommand.self,
            AppHashesCommand.self,
        ],
        defaultSubcommand: ResourceLimitsListCommand.self
    )
}

// MARK: - shared helpers

@discardableResult
private func resolveResourceLimitsAPI(logger: Logger) throws -> ResourceLimitsAPI {
    guard ASCCredentialResolver.isConfigured() else {
        logger.log("no ASC credentials configured", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let creds = try ASCCredentialResolver.resolve()
    let client = ASCClient(credentials: creds)
    return ResourceLimitsAPI(client: client)
}

@discardableResult
private func resolveAppHashesAPI(logger: Logger) throws -> AppHashesAPI {
    guard ASCCredentialResolver.isConfigured() else {
        logger.log("no ASC credentials configured", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let creds = try ASCCredentialResolver.resolve()
    let client = ASCClient(credentials: creds)
    return AppHashesAPI(client: client)
}

private func emitResourceLimitsJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

// MARK: - resource-limits list / get

struct ResourceLimitsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the team's resource limit records."
    )

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveResourceLimitsAPI(logger: logger)
        let result = try await api.listResourceLimits(limit: limit, cursor: cursor)
        if json {
            struct Out: Encodable {
                let resourceLimits: [ResourceLimitsAPI.ResourceLimit]
                let nextCursor: String?
            }
            try emitResourceLimitsJSON(Out(resourceLimits: result.resourceLimits, nextCursor: result.nextCursor))
            return
        }
        logger.header("Resource limits (\(result.resourceLimits.count))")
        if result.resourceLimits.isEmpty {
            print("  (none)")
            return
        }
        for r in result.resourceLimits {
            let limitVal = r.attributes?.limit.map(String.init) ?? "?"
            let currentVal = r.attributes?.currentValue.map(String.init) ?? "?"
            print("  \(r.attributes?.limitType ?? "(unknown)")")
            print("    id:           \(r.id)")
            print("    current:      \(currentVal)")
            print("    limit:        \(limitVal)")
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct ResourceLimitsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one resource limit record by id."
    )

    @Argument(help: "Resource limit id.")
    var limitID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveResourceLimitsAPI(logger: logger)
        guard let r = try await api.getResourceLimit(id: limitID) else {
            logger.log("no resource limit with id \(limitID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitResourceLimitsJSON(r)
            return
        }
        logger.header(r.attributes?.limitType ?? r.id)
        print("  id:           \(r.id)")
        print("  limitType:    \(r.attributes?.limitType ?? "(unset)")")
        print("  current:      \(r.attributes?.currentValue.map(String.init) ?? "(unset)")")
        print("  limit:        \(r.attributes?.limit.map(String.init) ?? "(unset)")")
    }
}

// MARK: - app-hashes

struct AppHashesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-hashes",
        abstract: "Inspect cryptographic app hashes Apple records for identifier or signing migrations.",
        subcommands: [
            AppHashesListCommand.self,
            AppHashesGetCommand.self,
        ],
        defaultSubcommand: AppHashesListCommand.self
    )
}

struct AppHashesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List app hashes for a specific app."
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
        let api = try resolveAppHashesAPI(logger: logger)
        let result = try await api.listAppHashes(appID: appID, limit: limit, cursor: cursor)
        if json {
            struct Out: Encodable {
                let appHashes: [AppHashesAPI.AppHash]
                let nextCursor: String?
            }
            try emitResourceLimitsJSON(Out(appHashes: result.appHashes, nextCursor: result.nextCursor))
            return
        }
        logger.header("App hashes for \(appID) (\(result.appHashes.count))")
        if result.appHashes.isEmpty {
            print("  (none)")
            return
        }
        for h in result.appHashes {
            print("  \(h.id)")
            print("    algorithm: \(h.attributes?.hashAlgorithm ?? "(unset)")")
            if let hash = h.attributes?.hash {
                print("    hash:      \(hash)")
            }
            if let d = h.attributes?.createdDate {
                print("    created:   \(d)")
            }
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct AppHashesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one app hash record by id."
    )

    @Argument(help: "App hash id.")
    var hashID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveAppHashesAPI(logger: logger)
        guard let h = try await api.getAppHash(id: hashID) else {
            logger.log("no app hash with id \(hashID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitResourceLimitsJSON(h)
            return
        }
        logger.header(h.id)
        print("  id:            \(h.id)")
        print("  hashAlgorithm: \(h.attributes?.hashAlgorithm ?? "(unset)")")
        print("  hash:          \(h.attributes?.hash ?? "(unset)")")
        print("  createdDate:   \(h.attributes?.createdDate.map(String.init(describing:)) ?? "(unset)")")
    }
}
