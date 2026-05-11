import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens game-center-v2` command. Wraps the App Store
/// Connect Game Center surfaces added in spec v4.0 / v4.2 (Activities,
/// Challenges, V2 versioning, sandbox-only submissions) as nested
/// subcommands. Kept separate from the Wave 2 `storescreens game-center`
/// parent (achievements / leaderboards / matchmaking) so each surface can
/// evolve independently.
///
/// Every leaf subcommand accepts `--json` for machine-readable output;
/// without it, results print as readable text via the shared Logger. The
/// same operations are exposed as MCP tools under the `gc_activities_*`,
/// `gc_challenges_*`, `gc_*_versions_v2_*`, and `gc_*_submissions_*`
/// namespaces.
struct GameCenterActivitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "game-center-v2",
        abstract: "Manage Game Center activities, challenges, V2 versions, and sandbox submissions.",
        discussion: """
            Wraps the Game Center surfaces added in App Store Connect OpenAPI \
            spec v4.0 (June 2025) and v4.2 (December 2025). Requires credentials \
            via `storescreens auth login` or ASC_KEY_ID / ASC_ISSUER_ID / \
            ASC_KEY_PATH env vars.

            Use `--json` on any leaf subcommand to get machine-readable output. \
            The same operations are exposed as MCP tools.
            """,
        subcommands: [
            GCA2ActivitiesCommand.self,
            GCA2ActivityLocalizationsCommand.self,
            GCA2ActivityImagesCommand.self,
            GCA2ActivityVersionsCommand.self,
            GCA2ChallengesCommand.self,
            GCA2ChallengeLocalizationsCommand.self,
            GCA2ChallengeImagesCommand.self,
            GCA2ChallengeVersionsCommand.self,
            GCA2AchievementVersionsV2Command.self,
            GCA2LeaderboardVersionsV2Command.self,
            GCA2LeaderboardSetVersionsV2Command.self,
            GCA2LeaderboardEntrySubmissionsCommand.self,
            GCA2PlayerAchievementSubmissionsCommand.self,
        ]
    )
}

// MARK: - Shared helpers

fileprivate func gca2Client(logger: Logger) throws -> GameCenterActivitiesAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return GameCenterActivitiesAPI(client: client)
}

fileprivate func gca2EmitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

fileprivate func gca2EmitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value {
        try gca2EmitJSON(value)
    } else {
        print("null")
    }
}

/// Page wrapper used so CLI JSON matches the MCP envelope shape.
fileprivate struct GCA2Page<Item: Encodable>: Encodable {
    let data: [Item]
    let nextCursor: String?
}

fileprivate func gca2Surface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
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

/// Parses an ISO-8601 timestamp string. Used by activity event-window
/// CLI flags. Returns nil for nil input.
fileprivate func gca2ParseDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

// MARK: - Activities

struct GCA2ActivitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activities",
        abstract: "Manage gameCenterActivities (live in-game events and tournaments).",
        subcommands: [
            GCA2ActivitiesListCommand.self,
            GCA2ActivitiesGetCommand.self,
            GCA2ActivitiesCreateCommand.self,
            GCA2ActivitiesUpdateCommand.self,
            GCA2ActivitiesArchiveCommand.self,
            GCA2ActivitiesDeleteCommand.self,
        ]
    )
}

struct GCA2ActivitiesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Game Center activities. Supply exactly one of --app-id, --detail-id, or --group-id.")
    @Option(name: .long) var appId: String?
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({ () -> GameCenterActivitiesAPI.Page<GameCenterActivitiesAPI.Activities.Activity> in
            if let appId { return try await api.activities.listForApp(appID: appId, limit: limit, cursor: cursor) }
            if let detailId { return try await api.activities.listForDetail(detailID: detailId, limit: limit, cursor: cursor) }
            if let groupId { return try await api.activities.listForGroup(groupID: groupId, limit: limit, cursor: cursor) }
            logger.log("supply one of --app-id, --detail-id, or --group-id", level: .error)
            throw ExitCode(1)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterActivities (\(page.items.count))")
        for a in page.items {
            let ref = a.attributes?.referenceName ?? "(no reference name)"
            let vendor = a.attributes?.vendorIdentifier ?? "(no vendor id)"
            print("  \(a.id)  \(ref)  [\(vendor)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2ActivitiesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a gameCenterActivity by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.activities.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2ActivitiesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a Game Center activity under a gameCenterDetail or gameCenterGroup.")
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var referenceName: String
    @Option(name: .long) var vendorIdentifier: String
    @Option(name: .long) var activityType: String?
    @Option(name: .long, help: "ISO-8601 timestamp.") var eventStartDate: String?
    @Option(name: .long, help: "ISO-8601 timestamp.") var eventEndDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        guard detailId != nil || groupId != nil else {
            logger.log("supply one of --detail-id or --group-id", level: .error)
            throw ExitCode(1)
        }
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.Activities.Fields(
            referenceName: referenceName,
            vendorIdentifier: vendorIdentifier,
            activityType: activityType,
            eventStartDate: gca2ParseDate(eventStartDate),
            eventEndDate: gca2ParseDate(eventEndDate)
        )
        let result = try await gca2Surface({
            try await api.activities.create(detailID: detailId, groupID: groupId, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("created gameCenterActivity \(result.id)", level: .success)
    }
}

struct GCA2ActivitiesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH a Game Center activity.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var vendorIdentifier: String?
    @Option(name: .long) var activityType: String?
    @Option(name: .long) var eventStartDate: String?
    @Option(name: .long) var eventEndDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.Activities.Fields(
            referenceName: referenceName,
            vendorIdentifier: vendorIdentifier,
            activityType: activityType,
            eventStartDate: gca2ParseDate(eventStartDate),
            eventEndDate: gca2ParseDate(eventEndDate)
        )
        let result = try await gca2Surface({
            try await api.activities.update(id: id, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("updated gameCenterActivity \(result.id)", level: .success)
    }
}

struct GCA2ActivitiesArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive", abstract: "Toggle archived on an activity.")
    @Argument var id: String
    @Option(name: .long) var archived: Bool = true
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.activities.archive(id: id, archived: archived)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("\(archived ? "archived" : "unarchived") gameCenterActivity \(result.id)", level: .success)
    }
}

struct GCA2ActivitiesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a Game Center activity.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        try await gca2Surface({ try await api.activities.delete(id: id) }, logger: logger)
        logger.log("deleted gameCenterActivity \(id)", level: .success)
    }
}

// MARK: - Activity localizations

struct GCA2ActivityLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activity-localizations",
        abstract: "Manage per-locale display copy for Game Center activities.",
        subcommands: [
            GCA2ActivityLocalizationsListCommand.self,
            GCA2ActivityLocalizationsGetCommand.self,
            GCA2ActivityLocalizationsCreateCommand.self,
            GCA2ActivityLocalizationsUpdateCommand.self,
            GCA2ActivityLocalizationsDeleteCommand.self,
        ]
    )
}

struct GCA2ActivityLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List activity localizations.")
    @Option(name: .long) var activityId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({
            try await api.activityLocalizations.list(activityID: activityId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterActivityLocalizations (\(page.items.count))")
        for l in page.items {
            let loc = l.attributes?.locale ?? "(no locale)"
            let name = l.attributes?.name ?? "(no name)"
            print("  \(l.id)  [\(loc)] \(name)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2ActivityLocalizationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an activity localization by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.activityLocalizations.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2ActivityLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create an activity locale entry.")
    @Option(name: .long) var activityId: String
    @Option(name: .long) var locale: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var subtitle: String?
    @Option(name: .long) var activityDescription: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.ActivityLocalizations.Fields(
            name: name, subtitle: subtitle, activityDescription: activityDescription
        )
        let result = try await gca2Surface({
            try await api.activityLocalizations.create(activityID: activityId, locale: locale, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("created gameCenterActivityLocalization \(result.id)", level: .success)
    }
}

struct GCA2ActivityLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an activity locale entry.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var subtitle: String?
    @Option(name: .long) var activityDescription: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.ActivityLocalizations.Fields(
            name: name, subtitle: subtitle, activityDescription: activityDescription
        )
        let result = try await gca2Surface({
            try await api.activityLocalizations.update(id: id, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("updated gameCenterActivityLocalization \(result.id)", level: .success)
    }
}

struct GCA2ActivityLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an activity locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        try await gca2Surface({ try await api.activityLocalizations.delete(id: id) }, logger: logger)
        logger.log("deleted gameCenterActivityLocalization \(id)", level: .success)
    }
}

// MARK: - Activity images

struct GCA2ActivityImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activity-images",
        abstract: "Manage activity images (per-locale 3-phase upload).",
        subcommands: [
            GCA2ActivityImagesListCommand.self,
            GCA2ActivityImagesGetCommand.self,
            GCA2ActivityImagesUploadCommand.self,
            GCA2ActivityImagesUpdateCommand.self,
            GCA2ActivityImagesDeleteCommand.self,
        ]
    )
}

struct GCA2ActivityImagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List activity images for a localization.")
    @Option(name: .long) var localizationId: String
    @Option(name: .long) var limit: Int = 50
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({
            try await api.activityImages.list(localizationID: localizationId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterActivityImages (\(page.items.count))")
        for img in page.items {
            print("  \(img.id)  \(img.attributes?.fileName ?? "(no fileName)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2ActivityImagesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an activity image by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.activityImages.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2ActivityImagesUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload an activity image (3-phase).")
    @Option(name: .long) var localizationId: String
    @Argument(help: "Path to the PNG file.") var filePath: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        let result = try await gca2Surface({
            try await api.activityImages.upload(localizationID: localizationId, fileURL: url) { idx, total in
                logger.log("chunk \(idx)/\(total)", level: .verbose)
            }
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("uploaded gameCenterActivityImage \(result.id)", level: .success)
    }
}

struct GCA2ActivityImagesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an activity image's metadata.")
    @Argument var id: String
    @Option(name: .long) var fileName: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.activityImages.update(id: id, fileName: fileName)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("updated gameCenterActivityImage \(result.id)", level: .success)
    }
}

struct GCA2ActivityImagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an activity image.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        try await gca2Surface({ try await api.activityImages.delete(id: id) }, logger: logger)
        logger.log("deleted gameCenterActivityImage \(id)", level: .success)
    }
}

// MARK: - Activity versions

struct GCA2ActivityVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activity-versions",
        abstract: "Manage per-app-version snapshots of an activity's config (no delete).",
        subcommands: [
            GCA2ActivityVersionsListCommand.self,
            GCA2ActivityVersionsGetCommand.self,
            GCA2ActivityVersionsCreateCommand.self,
            GCA2ActivityVersionsUpdateCommand.self,
        ]
    )
}

struct GCA2ActivityVersionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List activity version snapshots.")
    @Option(name: .long) var activityId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({
            try await api.activityVersions.list(activityID: activityId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterActivityVersions (\(page.items.count))")
        for v in page.items {
            print("  \(v.id)  live=\(v.attributes?.live.map(String.init(describing:)) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2ActivityVersionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an activity version snapshot by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.activityVersions.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2ActivityVersionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create an activity version snapshot.")
    @Option(name: .long) var activityId: String
    @Option(name: .long) var appVersionId: String?
    @Option(name: .long) var live: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.ActivityVersions.Fields(live: live)
        let result = try await gca2Surface({
            try await api.activityVersions.create(activityID: activityId, appVersionID: appVersionId, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("created gameCenterActivityVersion \(result.id)", level: .success)
    }
}

struct GCA2ActivityVersionsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an activity version snapshot.")
    @Argument var id: String
    @Option(name: .long) var live: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.ActivityVersions.Fields(live: live)
        let result = try await gca2Surface({
            try await api.activityVersions.update(id: id, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("updated gameCenterActivityVersion \(result.id)", level: .success)
    }
}

// MARK: - Challenges

struct GCA2ChallengesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "challenges",
        abstract: "Manage gameCenterChallenges (player-vs-player or community challenges).",
        subcommands: [
            GCA2ChallengesListCommand.self,
            GCA2ChallengesGetCommand.self,
            GCA2ChallengesCreateCommand.self,
            GCA2ChallengesUpdateCommand.self,
            GCA2ChallengesArchiveCommand.self,
            GCA2ChallengesDeleteCommand.self,
        ]
    )
}

struct GCA2ChallengesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Game Center challenges. Supply exactly one of --app-id, --detail-id, or --group-id.")
    @Option(name: .long) var appId: String?
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({ () -> GameCenterActivitiesAPI.Page<GameCenterActivitiesAPI.Challenges.Challenge> in
            if let appId { return try await api.challenges.listForApp(appID: appId, limit: limit, cursor: cursor) }
            if let detailId { return try await api.challenges.listForDetail(detailID: detailId, limit: limit, cursor: cursor) }
            if let groupId { return try await api.challenges.listForGroup(groupID: groupId, limit: limit, cursor: cursor) }
            logger.log("supply one of --app-id, --detail-id, or --group-id", level: .error)
            throw ExitCode(1)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterChallenges (\(page.items.count))")
        for c in page.items {
            let ref = c.attributes?.referenceName ?? "(no reference name)"
            let vendor = c.attributes?.vendorIdentifier ?? "(no vendor id)"
            print("  \(c.id)  \(ref)  [\(vendor)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2ChallengesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a gameCenterChallenge by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.challenges.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2ChallengesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a Game Center challenge.")
    @Option(name: .long) var detailId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long, help: "Optional gameCenterLeaderboard to link the challenge to.") var leaderboardId: String?
    @Option(name: .long) var referenceName: String
    @Option(name: .long) var vendorIdentifier: String
    @Option(name: .long) var challengeType: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        guard detailId != nil || groupId != nil else {
            logger.log("supply one of --detail-id or --group-id", level: .error)
            throw ExitCode(1)
        }
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.Challenges.Fields(
            referenceName: referenceName,
            vendorIdentifier: vendorIdentifier,
            challengeType: challengeType
        )
        let result = try await gca2Surface({
            try await api.challenges.create(detailID: detailId, groupID: groupId, leaderboardID: leaderboardId, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("created gameCenterChallenge \(result.id)", level: .success)
    }
}

struct GCA2ChallengesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH a Game Center challenge.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var vendorIdentifier: String?
    @Option(name: .long) var challengeType: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.Challenges.Fields(
            referenceName: referenceName,
            vendorIdentifier: vendorIdentifier,
            challengeType: challengeType
        )
        let result = try await gca2Surface({
            try await api.challenges.update(id: id, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("updated gameCenterChallenge \(result.id)", level: .success)
    }
}

struct GCA2ChallengesArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive", abstract: "Toggle archived on a challenge.")
    @Argument var id: String
    @Option(name: .long) var archived: Bool = true
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.challenges.archive(id: id, archived: archived)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("\(archived ? "archived" : "unarchived") gameCenterChallenge \(result.id)", level: .success)
    }
}

struct GCA2ChallengesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a Game Center challenge.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        try await gca2Surface({ try await api.challenges.delete(id: id) }, logger: logger)
        logger.log("deleted gameCenterChallenge \(id)", level: .success)
    }
}

// MARK: - Challenge localizations

struct GCA2ChallengeLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "challenge-localizations",
        abstract: "Manage per-locale display copy for challenges.",
        subcommands: [
            GCA2ChallengeLocalizationsListCommand.self,
            GCA2ChallengeLocalizationsGetCommand.self,
            GCA2ChallengeLocalizationsCreateCommand.self,
            GCA2ChallengeLocalizationsUpdateCommand.self,
            GCA2ChallengeLocalizationsDeleteCommand.self,
        ]
    )
}

struct GCA2ChallengeLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List challenge localizations.")
    @Option(name: .long) var challengeId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({
            try await api.challengeLocalizations.list(challengeID: challengeId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterChallengeLocalizations (\(page.items.count))")
        for l in page.items {
            let loc = l.attributes?.locale ?? "(no locale)"
            let name = l.attributes?.name ?? "(no name)"
            print("  \(l.id)  [\(loc)] \(name)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2ChallengeLocalizationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a challenge localization by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.challengeLocalizations.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2ChallengeLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a challenge locale entry.")
    @Option(name: .long) var challengeId: String
    @Option(name: .long) var locale: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var subtitle: String?
    @Option(name: .long) var challengeDescription: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.ChallengeLocalizations.Fields(
            name: name, subtitle: subtitle, challengeDescription: challengeDescription
        )
        let result = try await gca2Surface({
            try await api.challengeLocalizations.create(challengeID: challengeId, locale: locale, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("created gameCenterChallengeLocalization \(result.id)", level: .success)
    }
}

struct GCA2ChallengeLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a challenge locale entry.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var subtitle: String?
    @Option(name: .long) var challengeDescription: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let fields = GameCenterActivitiesAPI.ChallengeLocalizations.Fields(
            name: name, subtitle: subtitle, challengeDescription: challengeDescription
        )
        let result = try await gca2Surface({
            try await api.challengeLocalizations.update(id: id, fields: fields)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("updated gameCenterChallengeLocalization \(result.id)", level: .success)
    }
}

struct GCA2ChallengeLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a challenge locale entry.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        try await gca2Surface({ try await api.challengeLocalizations.delete(id: id) }, logger: logger)
        logger.log("deleted gameCenterChallengeLocalization \(id)", level: .success)
    }
}

// MARK: - Challenge images

struct GCA2ChallengeImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "challenge-images",
        abstract: "Manage challenge images (per-locale 3-phase upload).",
        subcommands: [
            GCA2ChallengeImagesListCommand.self,
            GCA2ChallengeImagesGetCommand.self,
            GCA2ChallengeImagesUploadCommand.self,
            GCA2ChallengeImagesUpdateCommand.self,
            GCA2ChallengeImagesDeleteCommand.self,
        ]
    )
}

struct GCA2ChallengeImagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List challenge images for a localization.")
    @Option(name: .long) var localizationId: String
    @Option(name: .long) var limit: Int = 50
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({
            try await api.challengeImages.list(localizationID: localizationId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterChallengeImages (\(page.items.count))")
        for img in page.items {
            print("  \(img.id)  \(img.attributes?.fileName ?? "(no fileName)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2ChallengeImagesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a challenge image by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.challengeImages.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2ChallengeImagesUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload a challenge image (3-phase).")
    @Option(name: .long) var localizationId: String
    @Argument(help: "Path to the PNG file.") var filePath: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        let result = try await gca2Surface({
            try await api.challengeImages.upload(localizationID: localizationId, fileURL: url) { idx, total in
                logger.log("chunk \(idx)/\(total)", level: .verbose)
            }
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("uploaded gameCenterChallengeImage \(result.id)", level: .success)
    }
}

struct GCA2ChallengeImagesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a challenge image's metadata.")
    @Argument var id: String
    @Option(name: .long) var fileName: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.challengeImages.update(id: id, fileName: fileName)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("updated gameCenterChallengeImage \(result.id)", level: .success)
    }
}

struct GCA2ChallengeImagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a challenge image.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        try await gca2Surface({ try await api.challengeImages.delete(id: id) }, logger: logger)
        logger.log("deleted gameCenterChallengeImage \(id)", level: .success)
    }
}

// MARK: - Challenge versions

struct GCA2ChallengeVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "challenge-versions",
        abstract: "Manage per-app-version snapshots of a challenge's config (create + get only).",
        subcommands: [
            GCA2ChallengeVersionsListCommand.self,
            GCA2ChallengeVersionsGetCommand.self,
            GCA2ChallengeVersionsCreateCommand.self,
        ]
    )
}

struct GCA2ChallengeVersionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List challenge version snapshots.")
    @Option(name: .long) var challengeId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({
            try await api.challengeVersions.list(challengeID: challengeId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterChallengeVersions (\(page.items.count))")
        for v in page.items {
            print("  \(v.id)  live=\(v.attributes?.live.map(String.init(describing:)) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2ChallengeVersionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a challenge version snapshot by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.challengeVersions.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2ChallengeVersionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a challenge version snapshot.")
    @Option(name: .long) var challengeId: String
    @Option(name: .long) var appVersionId: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.challengeVersions.create(challengeID: challengeId, appVersionID: appVersionId)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("created gameCenterChallengeVersion \(result.id)", level: .success)
    }
}

// MARK: - V2 versioning: Achievements

struct GCA2AchievementVersionsV2Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "achievement-versions-v2",
        abstract: "V2 per-app-version snapshots of an achievement's config (create + get only).",
        subcommands: [
            GCA2AchievementVersionsV2ListCommand.self,
            GCA2AchievementVersionsV2GetCommand.self,
            GCA2AchievementVersionsV2CreateCommand.self,
        ]
    )
}

struct GCA2AchievementVersionsV2ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List V2 achievement version snapshots.")
    @Option(name: .long) var achievementId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({
            try await api.achievementVersionsV2.list(achievementID: achievementId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterAchievementVersions (V2) (\(page.items.count))")
        for v in page.items {
            print("  \(v.id)  live=\(v.attributes?.live.map(String.init(describing:)) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2AchievementVersionsV2GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a V2 achievement version snapshot by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.achievementVersionsV2.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2AchievementVersionsV2CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a V2 achievement version snapshot.")
    @Option(name: .long) var achievementId: String
    @Option(name: .long) var appVersionId: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.achievementVersionsV2.create(achievementID: achievementId, appVersionID: appVersionId)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("created gameCenterAchievementVersion (V2) \(result.id)", level: .success)
    }
}

// MARK: - V2 versioning: Leaderboards

struct GCA2LeaderboardVersionsV2Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-versions-v2",
        abstract: "V2 per-app-version snapshots of a leaderboard's config (create + get only).",
        subcommands: [
            GCA2LeaderboardVersionsV2ListCommand.self,
            GCA2LeaderboardVersionsV2GetCommand.self,
            GCA2LeaderboardVersionsV2CreateCommand.self,
        ]
    )
}

struct GCA2LeaderboardVersionsV2ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List V2 leaderboard version snapshots.")
    @Option(name: .long) var leaderboardId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({
            try await api.leaderboardVersionsV2.list(leaderboardID: leaderboardId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterLeaderboardVersions (V2) (\(page.items.count))")
        for v in page.items {
            print("  \(v.id)  live=\(v.attributes?.live.map(String.init(describing:)) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2LeaderboardVersionsV2GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a V2 leaderboard version snapshot by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.leaderboardVersionsV2.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2LeaderboardVersionsV2CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a V2 leaderboard version snapshot.")
    @Option(name: .long) var leaderboardId: String
    @Option(name: .long) var appVersionId: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.leaderboardVersionsV2.create(leaderboardID: leaderboardId, appVersionID: appVersionId)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("created gameCenterLeaderboardVersion (V2) \(result.id)", level: .success)
    }
}

// MARK: - V2 versioning: Leaderboard Sets

struct GCA2LeaderboardSetVersionsV2Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-set-versions-v2",
        abstract: "V2 per-app-version snapshots of a leaderboard set's config (create + get only).",
        subcommands: [
            GCA2LeaderboardSetVersionsV2ListCommand.self,
            GCA2LeaderboardSetVersionsV2GetCommand.self,
            GCA2LeaderboardSetVersionsV2CreateCommand.self,
        ]
    )
}

struct GCA2LeaderboardSetVersionsV2ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List V2 leaderboard set version snapshots.")
    @Option(name: .long) var leaderboardSetId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let page = try await gca2Surface({
            try await api.leaderboardSetVersionsV2.list(leaderboardSetID: leaderboardSetId, limit: limit, cursor: cursor)
        }, logger: logger)
        if json { try gca2EmitJSON(GCA2Page(data: page.items, nextCursor: page.nextCursor)); return }
        logger.header("gameCenterLeaderboardSetVersions (V2) (\(page.items.count))")
        for v in page.items {
            print("  \(v.id)  live=\(v.attributes?.live.map(String.init(describing:)) ?? "(unknown)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct GCA2LeaderboardSetVersionsV2GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a V2 leaderboard set version snapshot by id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({ try await api.leaderboardSetVersionsV2.get(id: id) }, logger: logger)
        try gca2EmitOptionalJSON(result)
    }
}

struct GCA2LeaderboardSetVersionsV2CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a V2 leaderboard set version snapshot.")
    @Option(name: .long) var leaderboardSetId: String
    @Option(name: .long) var appVersionId: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.leaderboardSetVersionsV2.create(leaderboardSetID: leaderboardSetId, appVersionID: appVersionId)
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("created gameCenterLeaderboardSetVersion (V2) \(result.id)", level: .success)
    }
}

// MARK: - Sandbox-only leaderboard entry submissions

struct GCA2LeaderboardEntrySubmissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaderboard-entry-submissions",
        abstract: "Sandbox-only test score submissions for leaderboards (create only).",
        subcommands: [
            GCA2LeaderboardEntrySubmissionsCreateCommand.self,
        ]
    )
}

struct GCA2LeaderboardEntrySubmissionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Submit a sandbox test score for a leaderboard.")
    @Option(name: .long) var leaderboardId: String
    @Option(name: .long, help: "gameCenterPlayer id of the sandbox tester.") var playerId: String
    @Option(name: .long, help: "Stringified integer score.") var score: String
    @Option(name: .long) var context: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.leaderboardEntrySubmissions.create(
                leaderboardID: leaderboardId, playerID: playerId, score: score, context: context
            )
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("submitted gameCenterLeaderboardEntrySubmission \(result.id)", level: .success)
    }
}

// MARK: - Sandbox-only player achievement submissions

struct GCA2PlayerAchievementSubmissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "player-achievement-submissions",
        abstract: "Sandbox-only test achievement progress submissions (create only).",
        subcommands: [
            GCA2PlayerAchievementSubmissionsCreateCommand.self,
        ]
    )
}

struct GCA2PlayerAchievementSubmissionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Submit a sandbox test achievement progress event.")
    @Option(name: .long) var achievementId: String
    @Option(name: .long, help: "gameCenterPlayer id of the sandbox tester.") var playerId: String
    @Option(name: .long, help: "0-100; 100 marks the achievement earned.") var percentComplete: Double
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try gca2Client(logger: logger)
        let result = try await gca2Surface({
            try await api.playerAchievementSubmissions.create(
                achievementID: achievementId, playerID: playerId, percentComplete: percentComplete
            )
        }, logger: logger)
        if json { try gca2EmitJSON(result); return }
        logger.log("submitted gameCenterPlayerAchievementSubmission \(result.id)", level: .success)
    }
}
