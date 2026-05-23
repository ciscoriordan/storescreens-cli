import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens game-center` command. Wraps the App Store Connect
/// Game Center API as nested subcommands so AI agents (and humans) can manage
/// achievements, leaderboards, leaderboard sets, releases, and matchmaking
/// without hand-rolling HTTP requests.
///
/// Every leaf subcommand accepts `--json` for machine-readable output; without
/// it, results print as readable text via the shared Logger. The same
/// operations are exposed as MCP tools under the `gc_*` namespace.
struct GameCenterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "game-center",
        abstract: "Manage Game Center achievements, leaderboards, releases, and matchmaking.",
        discussion: """
            Wraps the App Store Connect Game Center API. Requires credentials via \
            `storescreens auth login` or ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH \
            env vars.

            Use `--json` on any leaf subcommand to get machine-readable output. The \
            same operations are exposed as MCP tools under the `gc_*` namespace.
            """,
        subcommands: [
            GCDetailsCommand.self,
            GCAppVersionsCommand.self,
            GCGroupsCommand.self,
            GCGroupLocalizationsCommand.self,
            GCAchievementsCommand.self,
            GCAchievementLocalizationsCommand.self,
            GCAchievementImagesCommand.self,
            GCAchievementReleasesCommand.self,
            GCLeaderboardsCommand.self,
            GCLeaderboardLocalizationsCommand.self,
            GCLeaderboardImagesCommand.self,
            GCLeaderboardReleasesCommand.self,
            GCLeaderboardSetsCommand.self,
            GCLeaderboardSetLocalizationsCommand.self,
            GCLeaderboardSetImagesCommand.self,
            GCLeaderboardSetMembersCommand.self,
            GCLeaderboardSetMemberLocalizationsCommand.self,
            GCLeaderboardSetReleasesCommand.self,
            GCMatchmakingCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// Builds a GameCenterAPI client wrapped over resolved credentials.
fileprivate func gcClient(logger: Logger) throws -> GameCenterAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return GameCenterAPI(client: client)
}

fileprivate func gcEmitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

fileprivate func gcEmitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value {
        try gcEmitJSON(value)
    } else {
        print("null")
    }
}

/// Page wrapper used so CLI JSON matches the MCP envelope shape.
fileprivate struct GCPage<Item: Encodable>: Encodable {
    let data: [Item]
    let nextCursor: String?
}

fileprivate func gcSurface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
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

// MARK: - Details

struct GCDetailsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "details",
        abstract: "Read or update the gameCenterDetail attached to an app.",
        subcommands: [
            GCDetailsGetForAppCommand.self,
            GCDetailsGetCommand.self,
            GCDetailsUpdateCommand.self,
        ]
    )
}

struct GCDetailsGetForAppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-for-app", abstract: "Get the gameCenterDetail attached to an app.")
    @Option(name: .long) var appId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let detail = try await gcSurface({ try await api.details.getForApp(appID: appId) }, logger: logger)
        if json { try gcEmitOptionalJSON(detail); return }
        guard let detail else {
            logger.log("no gameCenterDetail for app \(appId) - Game Center is likely not enabled", level: .warning)
            return
        }
        logger.header("gameCenterDetail \(detail.id)")
        print("  arcadeEnabled:    \(detail.attributes?.arcadeEnabled.map(String.init(describing:)) ?? "(unknown)")")
        print("  challengeEnabled: \(detail.attributes?.challengeEnabled.map(String.init(describing:)) ?? "(unknown)")")
    }
}

struct GCDetailsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a gameCenterDetail by id.")
    @Argument(help: "gameCenterDetail id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let detail = try await gcSurface({ try await api.details.get(id: id) }, logger: logger)
        if json { try gcEmitOptionalJSON(detail); return }
        guard let detail else {
            logger.log("no gameCenterDetail \(id)", level: .warning)
            return
        }
        logger.header("gameCenterDetail \(detail.id)")
        print("  arcadeEnabled:    \(detail.attributes?.arcadeEnabled.map(String.init(describing:)) ?? "(unknown)")")
        print("  challengeEnabled: \(detail.attributes?.challengeEnabled.map(String.init(describing:)) ?? "(unknown)")")
    }
}

struct GCDetailsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH a gameCenterDetail.")
    @Argument(help: "gameCenterDetail id.") var id: String
    @Option(name: .long) var arcadeEnabled: Bool?
    @Option(name: .long) var challengeEnabled: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let detail = try await gcSurface({
            try await api.details.update(id: id, arcadeEnabled: arcadeEnabled, challengeEnabled: challengeEnabled)
        }, logger: logger)
        if json { try gcEmitJSON(detail); return }
        logger.log("updated gameCenterDetail \(detail.id)", level: .success)
    }
}

// MARK: - App Versions

struct GCAppVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-versions",
        abstract: "Manage gameCenterAppVersions (per-version staging records).",
        subcommands: [
            GCAppVersionsListCommand.self,
            GCAppVersionsGetCommand.self,
            GCAppVersionsCreateCommand.self,
            GCAppVersionsUpdateCommand.self,
            GCAppVersionsDeleteCommand.self,
        ]
    )
}

struct GCAppVersionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List app versions under a gameCenterDetail.")
    @Option(name: .long) var detailId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({ try await api.appVersions.list(detailID: detailId, limit: limit, cursor: cursor) }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterAppVersions (\(page.items.count))")
        for v in page.items {
            print("  \(v.id)  live=\(v.attributes?.live.map(String.init(describing:)) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCAppVersionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an app version by id.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let result = try await gcSurface({ try await api.appVersions.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(result)
        _ = json
    }
}

struct GCAppVersionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create an app version under a gameCenterDetail.")
    @Option(name: .long) var detailId: String
    @Option(name: .long) var appStoreVersionId: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let result = try await gcSurface({
            try await api.appVersions.create(detailID: detailId, appStoreVersionID: appStoreVersionId)
        }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("created gameCenterAppVersion \(result.id)", level: .success)
    }
}

struct GCAppVersionsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an app version.")
    @Argument var id: String
    @Option(name: .long) var live: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let result = try await gcSurface({ try await api.appVersions.update(id: id, live: live) }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("updated gameCenterAppVersion \(result.id)", level: .success)
    }
}

struct GCAppVersionsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an app version.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.appVersions.delete(id: id) }, logger: logger)
        logger.log("deleted gameCenterAppVersion \(id)", level: .success)
    }
}

// MARK: - Groups

struct GCGroupsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "Manage cross-app Game Center groups.",
        subcommands: [
            GCGroupsListCommand.self,
            GCGroupsGetCommand.self,
            GCGroupsCreateCommand.self,
            GCGroupsUpdateCommand.self,
            GCGroupsDeleteCommand.self,
            GCGroupsAddDetailsCommand.self,
        ]
    )
}

struct GCGroupsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Game Center groups.")
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({ try await api.groups.list(limit: limit, cursor: cursor) }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterGroups (\(page.items.count))")
        for g in page.items {
            let ref = g.attributes?.referenceName ?? "(no reference name)"
            let gid = g.attributes?.groupId ?? "(no groupId)"
            print("  \(g.id)  \(ref)  [\(gid)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCGroupsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a group by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let group = try await gcSurface({ try await api.groups.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(group)
    }
}

struct GCGroupsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a group.")
    @Option(name: .long) var referenceName: String
    @Option(name: .long) var groupId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let group = try await gcSurface({
            try await api.groups.create(referenceName: referenceName, groupID: groupId)
        }, logger: logger)
        if json { try gcEmitJSON(group); return }
        logger.log("created gameCenterGroup \(group.id)", level: .success)
    }
}

struct GCGroupsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a group.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let group = try await gcSurface({
            try await api.groups.update(id: id, referenceName: referenceName)
        }, logger: logger)
        if json { try gcEmitJSON(group); return }
        logger.log("updated gameCenterGroup \(group.id)", level: .success)
    }
}

struct GCGroupsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a group.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.groups.delete(id: id) }, logger: logger)
        logger.log("deleted gameCenterGroup \(id)", level: .success)
    }
}

struct GCGroupsAddDetailsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-details", abstract: "Attach app gameCenterDetails to a group.")
    @Option(name: .long) var groupId: String
    @Argument(help: "gameCenterDetail ids to attach.") var detailIds: [String]

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({
            try await api.groups.addDetails(groupID: groupId, detailIDs: detailIds)
        }, logger: logger)
        logger.log("added \(detailIds.count) detail(s) to group \(groupId)", level: .success)
    }
}

// MARK: - Group localizations

struct GCGroupLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group-localizations",
        abstract: "Manage per-locale group display names.",
        subcommands: [
            GCGroupLocalizationsListCommand.self,
            GCGroupLocalizationsGetCommand.self,
            GCGroupLocalizationsCreateCommand.self,
            GCGroupLocalizationsUpdateCommand.self,
            GCGroupLocalizationsDeleteCommand.self,
        ]
    )
}

struct GCGroupLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List group locale entries.")
    @Option(name: .long) var groupId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.groupLocalizations.list(groupID: groupId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("groupLocalizations (\(page.items.count))")
        for l in page.items {
            print("  \(l.id)  [\(l.attributes?.locale ?? "?")]  \(l.attributes?.name ?? "(no name)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCGroupLocalizationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a group locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({ try await api.groupLocalizations.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(loc)
    }
}

struct GCGroupLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a group locale entry.")
    @Option(name: .long) var groupId: String
    @Option(name: .long) var locale: String
    @Option(name: .long) var name: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({
            try await api.groupLocalizations.create(groupID: groupId, locale: locale, name: name)
        }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("created groupLocalization \(loc.id)", level: .success)
    }
}

struct GCGroupLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a group locale entry.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({
            try await api.groupLocalizations.update(id: id, name: name)
        }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("updated groupLocalization \(loc.id)", level: .success)
    }
}

struct GCGroupLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a group locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.groupLocalizations.delete(id: id) }, logger: logger)
        logger.log("deleted groupLocalization \(id)", level: .success)
    }
}

// MARK: - Achievements

struct GCAchievementsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "achievements",
        abstract: "Manage Game Center achievements.",
        subcommands: [
            GCAchievementsListCommand.self,
            GCAchievementsGetCommand.self,
            GCAchievementsCreateCommand.self,
            GCAchievementsUpdateCommand.self,
            GCAchievementsArchiveCommand.self,
            GCAchievementsDeleteCommand.self,
        ]
    )
}

struct GCAchievementsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List achievements for an app, gameCenterDetail, or gameCenterGroup."
    )
    @Option(name: .long) var appId: String?
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page: GameCenterAPI.Page<GameCenterAPI.Achievements.Achievement>
        if let appId {
            page = try await gcSurface({ try await api.achievements.listForApp(appID: appId, limit: limit, cursor: cursor) }, logger: logger)
        } else if let detailId {
            page = try await gcSurface({ try await api.achievements.listForDetail(detailID: detailId, limit: limit, cursor: cursor) }, logger: logger)
        } else if let groupId {
            page = try await gcSurface({ try await api.achievements.listForGroup(groupID: groupId, limit: limit, cursor: cursor) }, logger: logger)
        } else {
            logger.log("must supply --app-id, --detail-id, or --group-id", level: .error)
            throw ExitCode(1)
        }
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("achievements (\(page.items.count))")
        for a in page.items {
            let vid = a.attributes?.vendorIdentifier ?? "(no vendorId)"
            let pts = a.attributes?.points.map(String.init) ?? "?"
            let archived = a.attributes?.archived ?? false
            print("  \(a.id)  \(vid)  \(pts) pts\(archived ? "  [archived]" : "")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCAchievementsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an achievement by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let result = try await gcSurface({ try await api.achievements.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(result)
    }
}

struct GCAchievementsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create an achievement.")
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var referenceName: String
    @Option(name: .long) var vendorIdentifier: String
    @Option(name: .long) var points: Int
    @Option(name: .long) var showBeforeEarned: Bool?
    @Option(name: .long) var repeatable: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        guard detailId != nil || groupId != nil else {
            logger.log("must supply --detail-id or --group-id", level: .error)
            throw ExitCode(1)
        }
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.Achievements.Fields(
            referenceName: referenceName,
            vendorIdentifier: vendorIdentifier,
            points: points,
            showBeforeEarned: showBeforeEarned,
            repeatable: repeatable
        )
        let result = try await gcSurface({
            try await api.achievements.create(detailID: detailId, groupID: groupId, fields: fields)
        }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("created achievement \(result.id)", level: .success)
    }
}

struct GCAchievementsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an achievement.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var vendorIdentifier: String?
    @Option(name: .long) var points: Int?
    @Option(name: .long) var showBeforeEarned: Bool?
    @Option(name: .long) var repeatable: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.Achievements.Fields(
            referenceName: referenceName,
            vendorIdentifier: vendorIdentifier,
            points: points,
            showBeforeEarned: showBeforeEarned,
            repeatable: repeatable
        )
        let result = try await gcSurface({ try await api.achievements.update(id: id, fields: fields) }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("updated achievement \(result.id)", level: .success)
    }
}

struct GCAchievementsArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive", abstract: "Toggle the archived flag on an achievement.")
    @Argument var id: String
    @Flag(name: .long, inversion: .prefixedNo, help: "Default: archived. Use --no-archived to unarchive.") var archived: Bool = true
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let result = try await gcSurface({ try await api.achievements.archive(id: id, archived: archived) }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("\(archived ? "archived" : "unarchived") achievement \(result.id)", level: .success)
    }
}

struct GCAchievementsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an achievement.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.achievements.delete(id: id) }, logger: logger)
        logger.log("deleted achievement \(id)", level: .success)
    }
}

// MARK: - Achievement localizations

struct GCAchievementLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "achievement-localizations",
        abstract: "Manage per-locale title + description for an achievement.",
        subcommands: [
            GCAchievementLocalizationsListCommand.self,
            GCAchievementLocalizationsGetCommand.self,
            GCAchievementLocalizationsCreateCommand.self,
            GCAchievementLocalizationsUpdateCommand.self,
            GCAchievementLocalizationsDeleteCommand.self,
        ]
    )
}

struct GCAchievementLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List locale entries on an achievement.")
    @Option(name: .long) var achievementId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.achievementLocalizations.list(achievementID: achievementId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("achievementLocalizations (\(page.items.count))")
        for l in page.items {
            print("  \(l.id)  [\(l.attributes?.locale ?? "?")]  \(l.attributes?.name ?? "(no name)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCAchievementLocalizationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({ try await api.achievementLocalizations.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(loc)
    }
}

struct GCAchievementLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a locale entry on an achievement.")
    @Option(name: .long) var achievementId: String
    @Option(name: .long) var locale: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var beforeEarnedDescription: String?
    @Option(name: .long) var afterEarnedDescription: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.AchievementLocalizations.Fields(
            name: name,
            beforeEarnedDescription: beforeEarnedDescription,
            afterEarnedDescription: afterEarnedDescription
        )
        let loc = try await gcSurface({
            try await api.achievementLocalizations.create(
                achievementID: achievementId, locale: locale, fields: fields
            )
        }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("created achievementLocalization \(loc.id)", level: .success)
    }
}

struct GCAchievementLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a locale entry.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var beforeEarnedDescription: String?
    @Option(name: .long) var afterEarnedDescription: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.AchievementLocalizations.Fields(
            name: name,
            beforeEarnedDescription: beforeEarnedDescription,
            afterEarnedDescription: afterEarnedDescription
        )
        let loc = try await gcSurface({ try await api.achievementLocalizations.update(id: id, fields: fields) }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("updated achievementLocalization \(loc.id)", level: .success)
    }
}

struct GCAchievementLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.achievementLocalizations.delete(id: id) }, logger: logger)
        logger.log("deleted achievementLocalization \(id)", level: .success)
    }
}

// MARK: - Achievement images

struct GCAchievementImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "achievement-images",
        abstract: "Manage achievement icon images (3-phase upload).",
        subcommands: [
            GCAchievementImagesListCommand.self,
            GCAchievementImagesGetCommand.self,
            GCAchievementImagesUploadCommand.self,
            GCAchievementImagesUpdateCommand.self,
            GCAchievementImagesDeleteCommand.self,
        ]
    )
}

struct GCAchievementImagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List achievement images on a localization.")
    @Option(name: .long) var localizationId: String
    @Option(name: .long) var limit: Int = 50
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.achievementImages.list(localizationID: localizationId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("achievementImages (\(page.items.count))")
        for img in page.items {
            print("  \(img.id)  \(img.attributes?.fileName ?? "(no name)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCAchievementImagesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an achievement image.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let image = try await gcSurface({ try await api.achievementImages.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(image)
    }
}

struct GCAchievementImagesUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload an achievement icon (3-phase reservation + chunk PUT + checksum confirm).")
    @Option(name: .long) var localizationId: String
    @Option(name: .long) var file: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let image = try await gcSurface({
            try await api.achievementImages.upload(localizationID: localizationId, fileURL: url)
        }, logger: logger)
        if json { try gcEmitJSON(image); return }
        logger.log("uploaded achievementImage \(image.id)", level: .success)
    }
}

struct GCAchievementImagesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an achievement image's metadata.")
    @Argument var id: String
    @Option(name: .long) var fileName: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let image = try await gcSurface({ try await api.achievementImages.update(id: id, fileName: fileName) }, logger: logger)
        if json { try gcEmitJSON(image); return }
        logger.log("updated achievementImage \(image.id)", level: .success)
    }
}

struct GCAchievementImagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an achievement image.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.achievementImages.delete(id: id) }, logger: logger)
        logger.log("deleted achievementImage \(id)", level: .success)
    }
}

// MARK: - Achievement releases

struct GCAchievementReleasesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "achievement-releases",
        abstract: "Stage achievements per gameCenterAppVersion.",
        subcommands: [
            GCAchievementReleasesListCommand.self,
            GCAchievementReleasesGetCommand.self,
            GCAchievementReleasesCreateCommand.self,
            GCAchievementReleasesUpdateCommand.self,
            GCAchievementReleasesDeleteCommand.self,
        ]
    )
}

struct GCAchievementReleasesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List achievement releases under an app version.")
    @Option(name: .long) var appVersionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.achievementReleases.list(appVersionID: appVersionId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("achievementReleases (\(page.items.count))")
        for r in page.items {
            print("  \(r.id)  live=\(r.attributes?.live.map(String.init(describing:)) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCAchievementReleasesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an achievement release.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({ try await api.achievementReleases.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(r)
    }
}

struct GCAchievementReleasesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Stage an achievement for an app version.")
    @Option(name: .long) var appVersionId: String
    @Option(name: .long) var achievementId: String
    @Option(name: .long) var live: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({
            try await api.achievementReleases.create(
                appVersionID: appVersionId, achievementID: achievementId, live: live
            )
        }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("staged achievement \(achievementId) on version \(appVersionId): \(r.id)", level: .success)
    }
}

struct GCAchievementReleasesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Toggle live on a staged release.")
    @Argument var id: String
    @Option(name: .long) var live: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({ try await api.achievementReleases.update(id: id, live: live) }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("updated achievementRelease \(r.id)", level: .success)
    }
}

struct GCAchievementReleasesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Detach a staged achievement release.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.achievementReleases.delete(id: id) }, logger: logger)
        logger.log("deleted achievementRelease \(id)", level: .success)
    }
}

// MARK: - Leaderboards

struct GCLeaderboardsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboards",
        abstract: "Manage Game Center leaderboards.",
        subcommands: [
            GCLeaderboardsListCommand.self,
            GCLeaderboardsGetCommand.self,
            GCLeaderboardsCreateCommand.self,
            GCLeaderboardsUpdateCommand.self,
            GCLeaderboardsArchiveCommand.self,
            GCLeaderboardsDeleteCommand.self,
        ]
    )
}

struct GCLeaderboardsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List leaderboards for an app, gameCenterDetail, or gameCenterGroup."
    )
    @Option(name: .long) var appId: String?
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page: GameCenterAPI.Page<GameCenterAPI.Leaderboards.Leaderboard>
        if let appId {
            page = try await gcSurface({ try await api.leaderboards.listForApp(appID: appId, limit: limit, cursor: cursor) }, logger: logger)
        } else if let detailId {
            page = try await gcSurface({ try await api.leaderboards.listForDetail(detailID: detailId, limit: limit, cursor: cursor) }, logger: logger)
        } else if let groupId {
            page = try await gcSurface({ try await api.leaderboards.listForGroup(groupID: groupId, limit: limit, cursor: cursor) }, logger: logger)
        } else {
            logger.log("must supply --app-id, --detail-id, or --group-id", level: .error)
            throw ExitCode(1)
        }
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("leaderboards (\(page.items.count))")
        for l in page.items {
            let vid = l.attributes?.vendorIdentifier ?? "(no vendorId)"
            let sort = l.attributes?.scoreSortType ?? ""
            let archived = l.attributes?.archived ?? false
            print("  \(l.id)  \(vid)  [\(sort)]\(archived ? "  [archived]" : "")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a leaderboard.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let result = try await gcSurface({ try await api.leaderboards.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(result)
    }
}

struct GCLeaderboardsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a leaderboard.")
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var referenceName: String
    @Option(name: .long) var vendorIdentifier: String
    @Option(name: .long) var defaultFormatter: String?
    @Option(name: .long) var submissionType: String?
    @Option(name: .long) var scoreSortType: String?
    @Option(name: .long) var scoreRangeStart: String?
    @Option(name: .long) var scoreRangeEnd: String?
    @Option(name: .long) var recurrenceDuration: String?
    @Option(name: .long) var recurrenceRule: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        guard detailId != nil || groupId != nil else {
            logger.log("must supply --detail-id or --group-id", level: .error)
            throw ExitCode(1)
        }
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.Leaderboards.Fields(
            referenceName: referenceName,
            vendorIdentifier: vendorIdentifier,
            defaultFormatter: defaultFormatter,
            submissionType: submissionType,
            scoreSortType: scoreSortType,
            scoreRangeStart: scoreRangeStart,
            scoreRangeEnd: scoreRangeEnd,
            recurrenceDuration: recurrenceDuration,
            recurrenceRule: recurrenceRule
        )
        let result = try await gcSurface({
            try await api.leaderboards.create(detailID: detailId, groupID: groupId, fields: fields)
        }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("created leaderboard \(result.id)", level: .success)
    }
}

struct GCLeaderboardsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a leaderboard.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var vendorIdentifier: String?
    @Option(name: .long) var defaultFormatter: String?
    @Option(name: .long) var submissionType: String?
    @Option(name: .long) var scoreSortType: String?
    @Option(name: .long) var scoreRangeStart: String?
    @Option(name: .long) var scoreRangeEnd: String?
    @Option(name: .long) var recurrenceDuration: String?
    @Option(name: .long) var recurrenceRule: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.Leaderboards.Fields(
            referenceName: referenceName,
            vendorIdentifier: vendorIdentifier,
            defaultFormatter: defaultFormatter,
            submissionType: submissionType,
            scoreSortType: scoreSortType,
            scoreRangeStart: scoreRangeStart,
            scoreRangeEnd: scoreRangeEnd,
            recurrenceDuration: recurrenceDuration,
            recurrenceRule: recurrenceRule
        )
        let result = try await gcSurface({ try await api.leaderboards.update(id: id, fields: fields) }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("updated leaderboard \(result.id)", level: .success)
    }
}

struct GCLeaderboardsArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive", abstract: "Toggle the archived flag on a leaderboard.")
    @Argument var id: String
    @Flag(name: .long, inversion: .prefixedNo, help: "Default: archived. Use --no-archived to unarchive.") var archived: Bool = true
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let result = try await gcSurface({ try await api.leaderboards.archive(id: id, archived: archived) }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("\(archived ? "archived" : "unarchived") leaderboard \(result.id)", level: .success)
    }
}

struct GCLeaderboardsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a leaderboard.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboards.delete(id: id) }, logger: logger)
        logger.log("deleted leaderboard \(id)", level: .success)
    }
}

// MARK: - Leaderboard localizations

struct GCLeaderboardLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-localizations",
        abstract: "Manage per-locale leaderboard records.",
        subcommands: [
            GCLeaderboardLocalizationsListCommand.self,
            GCLeaderboardLocalizationsGetCommand.self,
            GCLeaderboardLocalizationsCreateCommand.self,
            GCLeaderboardLocalizationsUpdateCommand.self,
            GCLeaderboardLocalizationsDeleteCommand.self,
        ]
    )
}

struct GCLeaderboardLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List leaderboard locale entries.")
    @Option(name: .long) var leaderboardId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.leaderboardLocalizations.list(leaderboardID: leaderboardId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("leaderboardLocalizations (\(page.items.count))")
        for l in page.items {
            print("  \(l.id)  [\(l.attributes?.locale ?? "?")]  \(l.attributes?.name ?? "(no name)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardLocalizationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a leaderboard locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({ try await api.leaderboardLocalizations.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(loc)
    }
}

struct GCLeaderboardLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a leaderboard locale entry.")
    @Option(name: .long) var leaderboardId: String
    @Option(name: .long) var locale: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var formatterOverride: String?
    @Option(name: .long) var formatterSuffix: String?
    @Option(name: .long) var formatterSuffixSingular: String?
    @Option(name: .long) var scoreFormat: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.LeaderboardLocalizations.Fields(
            name: name,
            formatterOverride: formatterOverride,
            formatterSuffix: formatterSuffix,
            formatterSuffixSingular: formatterSuffixSingular,
            scoreFormat: scoreFormat
        )
        let loc = try await gcSurface({
            try await api.leaderboardLocalizations.create(
                leaderboardID: leaderboardId, locale: locale, fields: fields
            )
        }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("created leaderboardLocalization \(loc.id)", level: .success)
    }
}

struct GCLeaderboardLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a leaderboard locale entry.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var formatterOverride: String?
    @Option(name: .long) var formatterSuffix: String?
    @Option(name: .long) var formatterSuffixSingular: String?
    @Option(name: .long) var scoreFormat: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.LeaderboardLocalizations.Fields(
            name: name,
            formatterOverride: formatterOverride,
            formatterSuffix: formatterSuffix,
            formatterSuffixSingular: formatterSuffixSingular,
            scoreFormat: scoreFormat
        )
        let loc = try await gcSurface({ try await api.leaderboardLocalizations.update(id: id, fields: fields) }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("updated leaderboardLocalization \(loc.id)", level: .success)
    }
}

struct GCLeaderboardLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a leaderboard locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboardLocalizations.delete(id: id) }, logger: logger)
        logger.log("deleted leaderboardLocalization \(id)", level: .success)
    }
}

// MARK: - Leaderboard images

struct GCLeaderboardImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-images",
        abstract: "Manage leaderboard icon images (3-phase upload).",
        subcommands: [
            GCLeaderboardImagesListCommand.self,
            GCLeaderboardImagesGetCommand.self,
            GCLeaderboardImagesUploadCommand.self,
            GCLeaderboardImagesUpdateCommand.self,
            GCLeaderboardImagesDeleteCommand.self,
        ]
    )
}

struct GCLeaderboardImagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List leaderboard images on a localization.")
    @Option(name: .long) var localizationId: String
    @Option(name: .long) var limit: Int = 50
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.leaderboardImages.list(localizationID: localizationId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("leaderboardImages (\(page.items.count))")
        for img in page.items {
            print("  \(img.id)  \(img.attributes?.fileName ?? "(no name)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardImagesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a leaderboard image.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let image = try await gcSurface({ try await api.leaderboardImages.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(image)
    }
}

struct GCLeaderboardImagesUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload a leaderboard icon.")
    @Option(name: .long) var localizationId: String
    @Option(name: .long) var file: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let image = try await gcSurface({
            try await api.leaderboardImages.upload(localizationID: localizationId, fileURL: url)
        }, logger: logger)
        if json { try gcEmitJSON(image); return }
        logger.log("uploaded leaderboardImage \(image.id)", level: .success)
    }
}

struct GCLeaderboardImagesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a leaderboard image's metadata.")
    @Argument var id: String
    @Option(name: .long) var fileName: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let image = try await gcSurface({ try await api.leaderboardImages.update(id: id, fileName: fileName) }, logger: logger)
        if json { try gcEmitJSON(image); return }
        logger.log("updated leaderboardImage \(image.id)", level: .success)
    }
}

struct GCLeaderboardImagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a leaderboard image.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboardImages.delete(id: id) }, logger: logger)
        logger.log("deleted leaderboardImage \(id)", level: .success)
    }
}

// MARK: - Leaderboard releases

struct GCLeaderboardReleasesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-releases",
        abstract: "Stage leaderboards per gameCenterAppVersion.",
        subcommands: [
            GCLeaderboardReleasesListCommand.self,
            GCLeaderboardReleasesGetCommand.self,
            GCLeaderboardReleasesCreateCommand.self,
            GCLeaderboardReleasesUpdateCommand.self,
            GCLeaderboardReleasesDeleteCommand.self,
        ]
    )
}

struct GCLeaderboardReleasesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List leaderboard releases under an app version.")
    @Option(name: .long) var appVersionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.leaderboardReleases.list(appVersionID: appVersionId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("leaderboardReleases (\(page.items.count))")
        for r in page.items {
            print("  \(r.id)  live=\(r.attributes?.live.map(String.init(describing:)) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardReleasesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a leaderboard release.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({ try await api.leaderboardReleases.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(r)
    }
}

struct GCLeaderboardReleasesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Stage a leaderboard for an app version.")
    @Option(name: .long) var appVersionId: String
    @Option(name: .long) var leaderboardId: String
    @Option(name: .long) var live: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({
            try await api.leaderboardReleases.create(
                appVersionID: appVersionId, leaderboardID: leaderboardId, live: live
            )
        }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("staged leaderboard \(leaderboardId) on version \(appVersionId): \(r.id)", level: .success)
    }
}

struct GCLeaderboardReleasesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Toggle live on a staged leaderboard release.")
    @Argument var id: String
    @Option(name: .long) var live: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({ try await api.leaderboardReleases.update(id: id, live: live) }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("updated leaderboardRelease \(r.id)", level: .success)
    }
}

struct GCLeaderboardReleasesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Detach a staged leaderboard release.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboardReleases.delete(id: id) }, logger: logger)
        logger.log("deleted leaderboardRelease \(id)", level: .success)
    }
}

// MARK: - Leaderboard sets

struct GCLeaderboardSetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-sets",
        abstract: "Manage leaderboard sets (groupings of leaderboards).",
        subcommands: [
            GCLeaderboardSetsListCommand.self,
            GCLeaderboardSetsGetCommand.self,
            GCLeaderboardSetsCreateCommand.self,
            GCLeaderboardSetsUpdateCommand.self,
            GCLeaderboardSetsArchiveCommand.self,
            GCLeaderboardSetsDeleteCommand.self,
        ]
    )
}

struct GCLeaderboardSetsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List leaderboard sets for an app, gameCenterDetail, or gameCenterGroup."
    )
    @Option(name: .long) var appId: String?
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page: GameCenterAPI.Page<GameCenterAPI.LeaderboardSets.LeaderboardSet>
        if let appId {
            page = try await gcSurface({ try await api.leaderboardSets.listForApp(appID: appId, limit: limit, cursor: cursor) }, logger: logger)
        } else if let detailId {
            page = try await gcSurface({ try await api.leaderboardSets.listForDetail(detailID: detailId, limit: limit, cursor: cursor) }, logger: logger)
        } else if let groupId {
            page = try await gcSurface({ try await api.leaderboardSets.listForGroup(groupID: groupId, limit: limit, cursor: cursor) }, logger: logger)
        } else {
            logger.log("must supply --app-id, --detail-id, or --group-id", level: .error)
            throw ExitCode(1)
        }
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("leaderboardSets (\(page.items.count))")
        for s in page.items {
            let vid = s.attributes?.vendorIdentifier ?? "(no vendorId)"
            let archived = s.attributes?.archived ?? false
            print("  \(s.id)  \(vid)\(archived ? "  [archived]" : "")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardSetsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a leaderboard set.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let result = try await gcSurface({ try await api.leaderboardSets.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(result)
    }
}

struct GCLeaderboardSetsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a leaderboard set.")
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var referenceName: String
    @Option(name: .long) var vendorIdentifier: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        guard detailId != nil || groupId != nil else {
            logger.log("must supply --detail-id or --group-id", level: .error)
            throw ExitCode(1)
        }
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.LeaderboardSets.Fields(
            referenceName: referenceName, vendorIdentifier: vendorIdentifier
        )
        let result = try await gcSurface({
            try await api.leaderboardSets.create(detailID: detailId, groupID: groupId, fields: fields)
        }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("created leaderboardSet \(result.id)", level: .success)
    }
}

struct GCLeaderboardSetsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a leaderboard set.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var vendorIdentifier: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.LeaderboardSets.Fields(
            referenceName: referenceName, vendorIdentifier: vendorIdentifier
        )
        let result = try await gcSurface({ try await api.leaderboardSets.update(id: id, fields: fields) }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("updated leaderboardSet \(result.id)", level: .success)
    }
}

struct GCLeaderboardSetsArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive", abstract: "Toggle archived on a leaderboard set.")
    @Argument var id: String
    @Flag(name: .long, inversion: .prefixedNo, help: "Default: archived. Use --no-archived to unarchive.") var archived: Bool = true
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let result = try await gcSurface({ try await api.leaderboardSets.archive(id: id, archived: archived) }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("\(archived ? "archived" : "unarchived") leaderboardSet \(result.id)", level: .success)
    }
}

struct GCLeaderboardSetsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a leaderboard set.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboardSets.delete(id: id) }, logger: logger)
        logger.log("deleted leaderboardSet \(id)", level: .success)
    }
}

// MARK: - Leaderboard set localizations

struct GCLeaderboardSetLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-set-localizations",
        abstract: "Manage per-locale leaderboard set records.",
        subcommands: [
            GCLeaderboardSetLocalizationsListCommand.self,
            GCLeaderboardSetLocalizationsGetCommand.self,
            GCLeaderboardSetLocalizationsCreateCommand.self,
            GCLeaderboardSetLocalizationsUpdateCommand.self,
            GCLeaderboardSetLocalizationsDeleteCommand.self,
        ]
    )
}

struct GCLeaderboardSetLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List leaderboard set locale entries.")
    @Option(name: .long) var setId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.leaderboardSetLocalizations.list(setID: setId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("leaderboardSetLocalizations (\(page.items.count))")
        for l in page.items {
            print("  \(l.id)  [\(l.attributes?.locale ?? "?")]  \(l.attributes?.name ?? "(no name)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardSetLocalizationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a leaderboard set locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({ try await api.leaderboardSetLocalizations.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(loc)
    }
}

struct GCLeaderboardSetLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a leaderboard set locale entry.")
    @Option(name: .long) var setId: String
    @Option(name: .long) var locale: String
    @Option(name: .long) var name: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({
            try await api.leaderboardSetLocalizations.create(setID: setId, locale: locale, name: name)
        }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("created leaderboardSetLocalization \(loc.id)", level: .success)
    }
}

struct GCLeaderboardSetLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a leaderboard set locale entry.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({ try await api.leaderboardSetLocalizations.update(id: id, name: name) }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("updated leaderboardSetLocalization \(loc.id)", level: .success)
    }
}

struct GCLeaderboardSetLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a leaderboard set locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboardSetLocalizations.delete(id: id) }, logger: logger)
        logger.log("deleted leaderboardSetLocalization \(id)", level: .success)
    }
}

// MARK: - Leaderboard set images

struct GCLeaderboardSetImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-set-images",
        abstract: "Manage leaderboard set images (3-phase upload).",
        subcommands: [
            GCLeaderboardSetImagesListCommand.self,
            GCLeaderboardSetImagesGetCommand.self,
            GCLeaderboardSetImagesUploadCommand.self,
            GCLeaderboardSetImagesUpdateCommand.self,
            GCLeaderboardSetImagesDeleteCommand.self,
        ]
    )
}

struct GCLeaderboardSetImagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List leaderboard set images.")
    @Option(name: .long) var localizationId: String
    @Option(name: .long) var limit: Int = 50
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.leaderboardSetImages.list(localizationID: localizationId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("leaderboardSetImages (\(page.items.count))")
        for img in page.items {
            print("  \(img.id)  \(img.attributes?.fileName ?? "(no name)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardSetImagesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a leaderboard set image.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let image = try await gcSurface({ try await api.leaderboardSetImages.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(image)
    }
}

struct GCLeaderboardSetImagesUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload a leaderboard set image.")
    @Option(name: .long) var localizationId: String
    @Option(name: .long) var file: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let image = try await gcSurface({
            try await api.leaderboardSetImages.upload(localizationID: localizationId, fileURL: url)
        }, logger: logger)
        if json { try gcEmitJSON(image); return }
        logger.log("uploaded leaderboardSetImage \(image.id)", level: .success)
    }
}

struct GCLeaderboardSetImagesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update leaderboard set image metadata.")
    @Argument var id: String
    @Option(name: .long) var fileName: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let image = try await gcSurface({ try await api.leaderboardSetImages.update(id: id, fileName: fileName) }, logger: logger)
        if json { try gcEmitJSON(image); return }
        logger.log("updated leaderboardSetImage \(image.id)", level: .success)
    }
}

struct GCLeaderboardSetImagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a leaderboard set image.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboardSetImages.delete(id: id) }, logger: logger)
        logger.log("deleted leaderboardSetImage \(id)", level: .success)
    }
}

// MARK: - Leaderboard set members

struct GCLeaderboardSetMembersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-set-members",
        abstract: "Manage leaderboards inside a leaderboard set.",
        subcommands: [
            GCLeaderboardSetMembersListCommand.self,
            GCLeaderboardSetMembersGetCommand.self,
            GCLeaderboardSetMembersCreateCommand.self,
            GCLeaderboardSetMembersDeleteCommand.self,
            GCLeaderboardSetMembersReorderCommand.self,
        ]
    )
}

struct GCLeaderboardSetMembersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List leaderboards in a set.")
    @Option(name: .long) var setId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.leaderboardSetMembers.list(setID: setId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("leaderboardSetMembers (\(page.items.count))")
        for m in page.items {
            print("  \(m.id)  order=\(m.attributes?.order.map(String.init) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardSetMembersGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a set member by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let m = try await gcSurface({ try await api.leaderboardSetMembers.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(m)
    }
}

struct GCLeaderboardSetMembersCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Add a leaderboard to a set.")
    @Option(name: .long) var setId: String
    @Option(name: .long) var leaderboardId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let m = try await gcSurface({
            try await api.leaderboardSetMembers.create(setID: setId, leaderboardID: leaderboardId)
        }, logger: logger)
        if json { try gcEmitJSON(m); return }
        logger.log("added leaderboard \(leaderboardId) to set \(setId): \(m.id)", level: .success)
    }
}

struct GCLeaderboardSetMembersDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Remove a member from a set.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboardSetMembers.delete(id: id) }, logger: logger)
        logger.log("deleted leaderboardSetMember \(id)", level: .success)
    }
}

struct GCLeaderboardSetMembersReorderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reorder",
        abstract: "Rewrite the order of leaderboards inside a set."
    )
    @Option(name: .long) var setId: String
    @Argument(help: "Leaderboard ids, in the new order from top to bottom.") var leaderboardIds: [String]

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({
            try await api.leaderboardSetMembers.reorderLeaderboards(setID: setId, leaderboardIDs: leaderboardIds)
        }, logger: logger)
        logger.log("reordered \(leaderboardIds.count) leaderboard(s) in set \(setId)", level: .success)
    }
}

// MARK: - Leaderboard set member localizations

struct GCLeaderboardSetMemberLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-set-member-localizations",
        abstract: "Manage per-locale name overrides on set members.",
        subcommands: [
            GCLeaderboardSetMemberLocalizationsListCommand.self,
            GCLeaderboardSetMemberLocalizationsGetCommand.self,
            GCLeaderboardSetMemberLocalizationsCreateCommand.self,
            GCLeaderboardSetMemberLocalizationsUpdateCommand.self,
            GCLeaderboardSetMemberLocalizationsDeleteCommand.self,
        ]
    )
}

struct GCLeaderboardSetMemberLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List name overrides on a set member.")
    @Option(name: .long) var memberId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.leaderboardSetMemberLocalizations.list(memberID: memberId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("setMemberLocalizations (\(page.items.count))")
        for l in page.items {
            print("  \(l.id)  [\(l.attributes?.locale ?? "?")]  \(l.attributes?.name ?? "(no name)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardSetMemberLocalizationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a set member name override entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({ try await api.leaderboardSetMemberLocalizations.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(loc)
    }
}

struct GCLeaderboardSetMemberLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Add a name override to a set member.")
    @Option(name: .long) var memberId: String
    @Option(name: .long) var locale: String
    @Option(name: .long) var name: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({
            try await api.leaderboardSetMemberLocalizations.create(
                memberID: memberId, locale: locale, name: name
            )
        }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("created setMemberLocalization \(loc.id)", level: .success)
    }
}

struct GCLeaderboardSetMemberLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a set member name override.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let loc = try await gcSurface({ try await api.leaderboardSetMemberLocalizations.update(id: id, name: name) }, logger: logger)
        if json { try gcEmitJSON(loc); return }
        logger.log("updated setMemberLocalization \(loc.id)", level: .success)
    }
}

struct GCLeaderboardSetMemberLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a set member name override.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboardSetMemberLocalizations.delete(id: id) }, logger: logger)
        logger.log("deleted setMemberLocalization \(id)", level: .success)
    }
}

// MARK: - Leaderboard set releases

struct GCLeaderboardSetReleasesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-set-releases",
        abstract: "Stage leaderboard sets per gameCenterAppVersion.",
        subcommands: [
            GCLeaderboardSetReleasesListCommand.self,
            GCLeaderboardSetReleasesGetCommand.self,
            GCLeaderboardSetReleasesCreateCommand.self,
            GCLeaderboardSetReleasesUpdateCommand.self,
            GCLeaderboardSetReleasesDeleteCommand.self,
        ]
    )
}

struct GCLeaderboardSetReleasesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List leaderboard set releases.")
    @Option(name: .long) var appVersionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.leaderboardSetReleases.list(appVersionID: appVersionId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("leaderboardSetReleases (\(page.items.count))")
        for r in page.items {
            print("  \(r.id)  live=\(r.attributes?.live.map(String.init(describing:)) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCLeaderboardSetReleasesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a leaderboard set release.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({ try await api.leaderboardSetReleases.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(r)
    }
}

struct GCLeaderboardSetReleasesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Stage a leaderboard set for an app version.")
    @Option(name: .long) var appVersionId: String
    @Option(name: .long) var leaderboardSetId: String
    @Option(name: .long) var live: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({
            try await api.leaderboardSetReleases.create(
                appVersionID: appVersionId, leaderboardSetID: leaderboardSetId, live: live
            )
        }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("staged leaderboardSet \(leaderboardSetId) on version \(appVersionId): \(r.id)", level: .success)
    }
}

struct GCLeaderboardSetReleasesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Toggle live on a leaderboard set release.")
    @Argument var id: String
    @Option(name: .long) var live: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({ try await api.leaderboardSetReleases.update(id: id, live: live) }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("updated leaderboardSetRelease \(r.id)", level: .success)
    }
}

struct GCLeaderboardSetReleasesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Detach a staged leaderboard set release.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.leaderboardSetReleases.delete(id: id) }, logger: logger)
        logger.log("deleted leaderboardSetRelease \(id)", level: .success)
    }
}

// MARK: - Matchmaking (queues, rule sets, rules, team configs)

struct GCMatchmakingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "matchmaking",
        abstract: "Manage Game Center matchmaking queues, rule sets, rules, and team configurations.",
        subcommands: [
            GCMatchmakingQueuesCommand.self,
            GCMatchmakingRuleSetsCommand.self,
            GCMatchmakingRulesCommand.self,
            GCMatchmakingTeamsCommand.self,
        ]
    )
}

// Queues

struct GCMatchmakingQueuesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "queues",
        abstract: "Manage matchmaking queues.",
        subcommands: [
            GCMatchmakingQueuesListCommand.self,
            GCMatchmakingQueuesGetCommand.self,
            GCMatchmakingQueuesCreateCommand.self,
            GCMatchmakingQueuesUpdateCommand.self,
            GCMatchmakingQueuesDeleteCommand.self,
            GCMatchmakingQueuesTestMatchCommand.self,
        ]
    )
}

struct GCMatchmakingQueuesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List matchmaking queues for an app.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.matchmakingQueues.listForApp(appID: appId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("matchmakingQueues (\(page.items.count))")
        for q in page.items {
            print("  \(q.id)  \(q.attributes?.referenceName ?? "(no reference)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCMatchmakingQueuesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a queue by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let q = try await gcSurface({ try await api.matchmakingQueues.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(q)
    }
}

struct GCMatchmakingQueuesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a matchmaking queue.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var referenceName: String
    @Option(name: .long, parsing: .upToNextOption) var classicMatchmakingBundleIds: [String] = []
    @Option(name: .long) var experimentRuleSetId: String?
    @Option(name: .long) var experimentRuleSetTrafficShare: Int?
    @Option(name: .long) var ruleSetId: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.MatchmakingQueues.Fields(
            referenceName: referenceName,
            classicMatchmakingBundleIDs: classicMatchmakingBundleIds.isEmpty ? nil : classicMatchmakingBundleIds,
            experimentRuleSetID: experimentRuleSetId,
            experimentRuleSetTrafficShare: experimentRuleSetTrafficShare,
            ruleSetID: ruleSetId
        )
        let q = try await gcSurface({
            try await api.matchmakingQueues.create(appID: appId, fields: fields)
        }, logger: logger)
        if json { try gcEmitJSON(q); return }
        logger.log("created matchmakingQueue \(q.id)", level: .success)
    }
}

struct GCMatchmakingQueuesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a queue.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long, parsing: .upToNextOption) var classicMatchmakingBundleIds: [String] = []
    @Option(name: .long) var experimentRuleSetId: String?
    @Option(name: .long) var experimentRuleSetTrafficShare: Int?
    @Option(name: .long) var ruleSetId: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.MatchmakingQueues.Fields(
            referenceName: referenceName,
            classicMatchmakingBundleIDs: classicMatchmakingBundleIds.isEmpty ? nil : classicMatchmakingBundleIds,
            experimentRuleSetID: experimentRuleSetId,
            experimentRuleSetTrafficShare: experimentRuleSetTrafficShare,
            ruleSetID: ruleSetId
        )
        let q = try await gcSurface({ try await api.matchmakingQueues.update(id: id, fields: fields) }, logger: logger)
        if json { try gcEmitJSON(q); return }
        logger.log("updated matchmakingQueue \(q.id)", level: .success)
    }
}

struct GCMatchmakingQueuesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a queue.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.matchmakingQueues.delete(id: id) }, logger: logger)
        logger.log("deleted matchmakingQueue \(id)", level: .success)
    }
}

struct GCMatchmakingQueuesTestMatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-match",
        abstract: "Submit a matchmakingRequests JSON payload to the queue test endpoint."
    )
    @Option(name: .long) var queueId: String
    @Option(name: .long, help: "Path to a JSON file containing matchmakingRequests payload.") var fromFile: String?
    @Option(name: .long, help: "Inline matchmakingRequests JSON string.") var payload: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let body: String
        if let payload {
            body = payload
        } else if let fromFile {
            body = try String(
                contentsOf: URL(fileURLWithPath: (fromFile as NSString).expandingTildeInPath),
                encoding: .utf8
            )
        } else {
            logger.log("must supply --payload or --from-file", level: .error)
            throw ExitCode(1)
        }
        let result = try await gcSurface({
            try await api.matchmakingRules.testQueueMatch(queueID: queueId, matchmakingRequests: body)
        }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("test result type \(result.type ?? "(unknown)") id \(result.id ?? "(none)")", level: .success)
    }
}

// Rule sets

struct GCMatchmakingRuleSetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rule-sets",
        abstract: "Manage matchmaking rule sets attached to queues.",
        subcommands: [
            GCMatchmakingRuleSetsListCommand.self,
            GCMatchmakingRuleSetsGetCommand.self,
            GCMatchmakingRuleSetsCreateCommand.self,
            GCMatchmakingRuleSetsUpdateCommand.self,
            GCMatchmakingRuleSetsDeleteCommand.self,
            GCMatchmakingRuleSetsTestMatchCommand.self,
        ]
    )
}

struct GCMatchmakingRuleSetsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List rule sets on a queue.")
    @Option(name: .long) var queueId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.matchmakingRuleSets.listForQueue(queueID: queueId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("matchmakingRuleSets (\(page.items.count))")
        for r in page.items {
            print("  \(r.id)  \(r.attributes?.referenceName ?? "(no reference)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCMatchmakingRuleSetsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a rule set.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({ try await api.matchmakingRuleSets.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(r)
    }
}

struct GCMatchmakingRuleSetsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a rule set.")
    @Option(name: .long) var queueId: String
    @Option(name: .long) var referenceName: String
    @Option(name: .long) var ruleLanguageVersion: Int?
    @Option(name: .long) var minPlayers: Int?
    @Option(name: .long) var maxPlayers: Int?
    @Option(name: .long) var teams: Int?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.MatchmakingRuleSets.Fields(
            referenceName: referenceName,
            ruleLanguageVersion: ruleLanguageVersion,
            minPlayers: minPlayers,
            maxPlayers: maxPlayers,
            teams: teams
        )
        let r = try await gcSurface({
            try await api.matchmakingRuleSets.create(queueID: queueId, fields: fields)
        }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("created matchmakingRuleSet \(r.id)", level: .success)
    }
}

struct GCMatchmakingRuleSetsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a rule set.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var ruleLanguageVersion: Int?
    @Option(name: .long) var minPlayers: Int?
    @Option(name: .long) var maxPlayers: Int?
    @Option(name: .long) var teams: Int?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.MatchmakingRuleSets.Fields(
            referenceName: referenceName,
            ruleLanguageVersion: ruleLanguageVersion,
            minPlayers: minPlayers,
            maxPlayers: maxPlayers,
            teams: teams
        )
        let r = try await gcSurface({ try await api.matchmakingRuleSets.update(id: id, fields: fields) }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("updated matchmakingRuleSet \(r.id)", level: .success)
    }
}

struct GCMatchmakingRuleSetsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a rule set.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.matchmakingRuleSets.delete(id: id) }, logger: logger)
        logger.log("deleted matchmakingRuleSet \(id)", level: .success)
    }
}

struct GCMatchmakingRuleSetsTestMatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-match",
        abstract: "Submit a matchmakingRequests JSON payload to the rule set test endpoint."
    )
    @Option(name: .long) var ruleSetId: String
    @Option(name: .long) var fromFile: String?
    @Option(name: .long) var payload: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let body: String
        if let payload {
            body = payload
        } else if let fromFile {
            body = try String(
                contentsOf: URL(fileURLWithPath: (fromFile as NSString).expandingTildeInPath),
                encoding: .utf8
            )
        } else {
            logger.log("must supply --payload or --from-file", level: .error)
            throw ExitCode(1)
        }
        let result = try await gcSurface({
            try await api.matchmakingRules.testRuleSetMatch(ruleSetID: ruleSetId, matchmakingRequests: body)
        }, logger: logger)
        if json { try gcEmitJSON(result); return }
        logger.log("test result type \(result.type ?? "(unknown)") id \(result.id ?? "(none)")", level: .success)
    }
}

// Rules

struct GCMatchmakingRulesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Manage individual matchmaking rules.",
        subcommands: [
            GCMatchmakingRulesListCommand.self,
            GCMatchmakingRulesGetCommand.self,
            GCMatchmakingRulesCreateCommand.self,
            GCMatchmakingRulesUpdateCommand.self,
            GCMatchmakingRulesDeleteCommand.self,
        ]
    )
}

struct GCMatchmakingRulesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List rules on a rule set.")
    @Option(name: .long) var ruleSetId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.matchmakingRules.listForRuleSet(ruleSetID: ruleSetId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("matchmakingRules (\(page.items.count))")
        for r in page.items {
            let typ = r.attributes?.type ?? "(no type)"
            print("  \(r.id)  [\(typ)]  \(r.attributes?.referenceName ?? "")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCMatchmakingRulesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a rule by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let r = try await gcSurface({ try await api.matchmakingRules.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(r)
    }
}

struct GCMatchmakingRulesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a rule.")
    @Option(name: .long) var ruleSetId: String
    @Option(name: .long) var referenceName: String
    @Option(name: .long) var type: String
    @Option(name: .long, help: "Apple's rule DSL expression. Use --expression-from-file to load from disk.") var expression: String?
    @Option(name: .long) var expressionFromFile: String?
    @Option(name: .long) var description: String?
    @Option(name: .long) var weight: Double?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let expr: String?
        if let expression {
            expr = expression
        } else if let expressionFromFile {
            expr = try String(
                contentsOf: URL(fileURLWithPath: (expressionFromFile as NSString).expandingTildeInPath),
                encoding: .utf8
            )
        } else {
            logger.log("must supply --expression or --expression-from-file", level: .error)
            throw ExitCode(1)
        }
        let fields = GameCenterAPI.MatchmakingRules.Fields(
            referenceName: referenceName,
            description: description,
            type: type,
            expression: expr,
            weight: weight
        )
        let r = try await gcSurface({
            try await api.matchmakingRules.create(ruleSetID: ruleSetId, fields: fields)
        }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("created matchmakingRule \(r.id)", level: .success)
    }
}

struct GCMatchmakingRulesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a rule.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var type: String?
    @Option(name: .long) var expression: String?
    @Option(name: .long) var expressionFromFile: String?
    @Option(name: .long) var description: String?
    @Option(name: .long) var weight: Double?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let expr: String?
        if let expression {
            expr = expression
        } else if let expressionFromFile {
            expr = try String(
                contentsOf: URL(fileURLWithPath: (expressionFromFile as NSString).expandingTildeInPath),
                encoding: .utf8
            )
        } else {
            expr = nil
        }
        let fields = GameCenterAPI.MatchmakingRules.Fields(
            referenceName: referenceName,
            description: description,
            type: type,
            expression: expr,
            weight: weight
        )
        let r = try await gcSurface({ try await api.matchmakingRules.update(id: id, fields: fields) }, logger: logger)
        if json { try gcEmitJSON(r); return }
        logger.log("updated matchmakingRule \(r.id)", level: .success)
    }
}

struct GCMatchmakingRulesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a rule.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.matchmakingRules.delete(id: id) }, logger: logger)
        logger.log("deleted matchmakingRule \(id)", level: .success)
    }
}

// Team configurations

struct GCMatchmakingTeamsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "team-configurations",
        abstract: "Manage matchmaking team configurations attached to rule sets.",
        subcommands: [
            GCMatchmakingTeamsListCommand.self,
            GCMatchmakingTeamsGetCommand.self,
            GCMatchmakingTeamsCreateCommand.self,
            GCMatchmakingTeamsUpdateCommand.self,
            GCMatchmakingTeamsDeleteCommand.self,
        ]
    )
}

struct GCMatchmakingTeamsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List team configurations on a rule set.")
    @Option(name: .long) var ruleSetId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let page = try await gcSurface({
            try await api.matchmakingTeamConfigurations.listForRuleSet(ruleSetID: ruleSetId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gcEmitJSON(GCPage(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("matchmakingTeamConfigurations (\(page.items.count))")
        for t in page.items {
            let mn = t.attributes?.minPlayers.map(String.init) ?? "?"
            let mx = t.attributes?.maxPlayers.map(String.init) ?? "?"
            print("  \(t.id)  \(t.attributes?.referenceName ?? "(no reference)")  [\(mn)-\(mx)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCMatchmakingTeamsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a team configuration.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let t = try await gcSurface({ try await api.matchmakingTeamConfigurations.get(id: id) }, logger: logger)
        try gcEmitOptionalJSON(t)
    }
}

struct GCMatchmakingTeamsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a team configuration.")
    @Option(name: .long) var ruleSetId: String
    @Option(name: .long) var referenceName: String
    @Option(name: .long) var minPlayers: Int?
    @Option(name: .long) var maxPlayers: Int?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.MatchmakingTeamConfigurations.Fields(
            referenceName: referenceName,
            maxPlayers: maxPlayers,
            minPlayers: minPlayers
        )
        let t = try await gcSurface({
            try await api.matchmakingTeamConfigurations.create(ruleSetID: ruleSetId, fields: fields)
        }, logger: logger)
        if json { try gcEmitJSON(t); return }
        logger.log("created matchmakingTeamConfiguration \(t.id)", level: .success)
    }
}

struct GCMatchmakingTeamsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a team configuration.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var minPlayers: Int?
    @Option(name: .long) var maxPlayers: Int?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        let fields = GameCenterAPI.MatchmakingTeamConfigurations.Fields(
            referenceName: referenceName,
            maxPlayers: maxPlayers,
            minPlayers: minPlayers
        )
        let t = try await gcSurface({ try await api.matchmakingTeamConfigurations.update(id: id, fields: fields) }, logger: logger)
        if json { try gcEmitJSON(t); return }
        logger.log("updated matchmakingTeamConfiguration \(t.id)", level: .success)
    }
}

struct GCMatchmakingTeamsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a team configuration.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gcClient(logger: logger)
        try await gcSurface({ try await api.matchmakingTeamConfigurations.delete(id: id) }, logger: logger)
        logger.log("deleted matchmakingTeamConfiguration \(id)", level: .success)
    }
}
