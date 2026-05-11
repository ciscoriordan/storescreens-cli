import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens testflight` command. Wraps the App Store
/// Connect TestFlight & pre-release distribution APIs as nested
/// subcommands so AI agents (and humans) can drive TF lifecycle without
/// hand-rolling HTTP requests.
///
/// Every leaf subcommand accepts `--json` for machine-readable output;
/// without it, results print as readable text via the shared Logger.
struct TestFlightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "testflight",
        abstract: "Manage TestFlight beta groups, testers, builds, and review state.",
        discussion: """
            Wraps the App Store Connect TestFlight API. Requires credentials \
            via `storescreens auth login` or ASC_KEY_ID / ASC_ISSUER_ID / \
            ASC_KEY_PATH env vars.

            Use `--json` on any leaf subcommand to get machine-readable output. \
            The same operations are exposed as MCP tools under the \
            `testflight_*` namespace.
            """,
        subcommands: [
            TFBetaGroupsCommand.self,
            TFBetaTestersCommand.self,
            TFBetaTesterInvitationsCommand.self,
            TFPrereleaseVersionsCommand.self,
            TFBuildsCommand.self,
            TFBuildBetaDetailCommand.self,
            TFBuildBetaNotificationsCommand.self,
            TFBetaAppLocalizationsCommand.self,
            TFBetaBuildLocalizationsCommand.self,
            TFBetaAppReviewDetailCommand.self,
            TFBetaAppReviewSubmissionsCommand.self,
            TFBetaLicenseAgreementCommand.self,
            TFBetaTesterMetricsCommand.self,
            TFBuildBundlesCommand.self,
            TFBuildIconsCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// Resolves ASC credentials and builds a TestFlightAPI client. Throws an
/// ExitCode(1) after logging on failure so subcommands stay tiny.
fileprivate func tfClient(logger: Logger) throws -> TestFlightAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return TestFlightAPI(client: client)
}

/// Emits any `Encodable` as pretty-printed JSON on stdout.
fileprivate func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

/// Emit-helper for "single resource or nil" results from getXxx calls.
fileprivate func emitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value {
        try emitJSON(value)
    } else {
        print("null")
    }
}

/// Wraps a paged TestFlightAPI page in the same shape MCP tools emit.
fileprivate struct CLIPage<Item: Encodable>: Encodable {
    let data: [Item]
    let nextCursor: String?
}

/// Maps ASCClient.APIError to a readable, formatted error then throws
/// ExitCode(1). Other errors propagate.
fileprivate func surface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
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

// MARK: - betaGroups

struct TFBetaGroupsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-groups",
        abstract: "Manage TestFlight beta groups.",
        subcommands: [
            TFBetaGroupsListCommand.self,
            TFBetaGroupsGetCommand.self,
            TFBetaGroupsCreateCommand.self,
            TFBetaGroupsUpdateCommand.self,
            TFBetaGroupsDeleteCommand.self,
            TFBetaGroupsAddBuildsCommand.self,
            TFBetaGroupsRemoveBuildsCommand.self,
            TFBetaGroupsAddTestersCommand.self,
            TFBetaGroupsRemoveTestersCommand.self,
            TFBetaGroupsCreateAndInviteCommand.self,
        ]
    )
}

struct TFBetaGroupsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List beta groups for an app.")
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Option(name: .long, help: "Max results per page (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Pagination cursor from a previous page.") var cursor: String?
    @Flag(name: .long, help: "Emit JSON instead of text.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface({ try await api.listBetaGroups(appID: appId, limit: limit, cursor: cursor) }, logger: logger)
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Beta groups (\(page.data.count))")
        for g in page.data {
            let name = g.attributes?.name ?? "(no name)"
            let kind = (g.attributes?.isInternalGroup ?? false) ? "internal" : "external"
            print("  \(g.id)  \(name)  [\(kind)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct TFBetaGroupsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a beta group by id.")
    @Argument(help: "Beta group id.") var id: String
    @Flag(name: .long, help: "Emit JSON instead of text.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let group = try await surface({ try await api.getBetaGroup(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(group)
            return
        }
        guard let group else {
            logger.log("no beta group \(id)", level: .warning)
            return
        }
        logger.header("Beta group \(group.id)")
        print("  name:                   \(group.attributes?.name ?? "(none)")")
        print("  internal:               \(group.attributes?.isInternalGroup.map(String.init(describing:)) ?? "(unknown)")")
        print("  public link:            \(group.attributes?.publicLink ?? "(none)")")
        print("  public link enabled:    \(group.attributes?.publicLinkEnabled.map(String.init(describing:)) ?? "(unknown)")")
        print("  feedback enabled:       \(group.attributes?.feedbackEnabled.map(String.init(describing:)) ?? "(unknown)")")
        print("  has access to builds:   \(group.attributes?.hasAccessToAllBuilds.map(String.init(describing:)) ?? "(unknown)")")
    }
}

struct TFBetaGroupsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a beta group.")
    @Option(name: .long) var appId: String
    @Option(name: .long, help: "Group name shown in ASC and to testers.") var name: String
    @Option(name: .long) var publicLinkEnabled: Bool?
    @Option(name: .long) var publicLinkLimit: Int?
    @Option(name: .long) var publicLinkLimitEnabled: Bool?
    @Option(name: .long) var feedbackEnabled: Bool?
    @Option(name: .long) var hasAccessToAllBuilds: Bool?
    @Option(name: .long) var iosBuildsAvailableForAppleSiliconMac: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let fields = TestFlightAPI.BetaGroupFields(
            publicLinkEnabled: publicLinkEnabled,
            publicLinkLimit: publicLinkLimit,
            publicLinkLimitEnabled: publicLinkLimitEnabled,
            feedbackEnabled: feedbackEnabled,
            hasAccessToAllBuilds: hasAccessToAllBuilds,
            iosBuildsAvailableForAppleSiliconMac: iosBuildsAvailableForAppleSiliconMac
        )
        let group = try await surface(
            { try await api.createBetaGroup(appID: appId, name: name, fields: fields) },
            logger: logger
        )
        if json {
            try emitJSON(group)
            return
        }
        logger.log("created beta group \(group.id) (\(group.attributes?.name ?? name))", level: .success)
    }
}

struct TFBetaGroupsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a beta group.")
    @Argument(help: "Beta group id.") var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var publicLinkEnabled: Bool?
    @Option(name: .long) var publicLinkLimit: Int?
    @Option(name: .long) var publicLinkLimitEnabled: Bool?
    @Option(name: .long) var feedbackEnabled: Bool?
    @Option(name: .long) var hasAccessToAllBuilds: Bool?
    @Option(name: .long) var iosBuildsAvailableForAppleSiliconMac: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let fields = TestFlightAPI.BetaGroupFields(
            name: name,
            publicLinkEnabled: publicLinkEnabled,
            publicLinkLimit: publicLinkLimit,
            publicLinkLimitEnabled: publicLinkLimitEnabled,
            feedbackEnabled: feedbackEnabled,
            hasAccessToAllBuilds: hasAccessToAllBuilds,
            iosBuildsAvailableForAppleSiliconMac: iosBuildsAvailableForAppleSiliconMac
        )
        let group = try await surface(
            { try await api.updateBetaGroup(id: id, fields: fields) },
            logger: logger
        )
        if json {
            try emitJSON(group)
            return
        }
        logger.log("updated beta group \(group.id)", level: .success)
    }
}

struct TFBetaGroupsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a beta group.")
    @Argument(help: "Beta group id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface({ try await api.deleteBetaGroup(id: id) }, logger: logger)
        logger.log("deleted beta group \(id)", level: .success)
    }
}

struct TFBetaGroupsAddBuildsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-builds", abstract: "Attach builds to a beta group.")
    @Option(name: .long) var groupId: String
    @Argument(help: "Build ids to attach.") var buildIds: [String]

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface(
            { try await api.addBuildsToBetaGroup(groupID: groupId, buildIDs: buildIds) },
            logger: logger
        )
        logger.log("added \(buildIds.count) build(s) to group \(groupId)", level: .success)
    }
}

struct TFBetaGroupsRemoveBuildsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove-builds", abstract: "Detach builds from a beta group.")
    @Option(name: .long) var groupId: String
    @Argument(help: "Build ids to detach.") var buildIds: [String]

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface(
            { try await api.removeBuildsFromBetaGroup(groupID: groupId, buildIDs: buildIds) },
            logger: logger
        )
        logger.log("removed \(buildIds.count) build(s) from group \(groupId)", level: .success)
    }
}

struct TFBetaGroupsAddTestersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-testers", abstract: "Add testers to a beta group.")
    @Option(name: .long) var groupId: String
    @Argument(help: "Tester ids to add.") var testerIds: [String]

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface(
            { try await api.addTestersToBetaGroup(groupID: groupId, testerIDs: testerIds) },
            logger: logger
        )
        logger.log("added \(testerIds.count) tester(s) to group \(groupId)", level: .success)
    }
}

struct TFBetaGroupsRemoveTestersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove-testers", abstract: "Remove testers from a beta group.")
    @Option(name: .long) var groupId: String
    @Argument(help: "Tester ids to remove.") var testerIds: [String]

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface(
            { try await api.removeTestersFromBetaGroup(groupID: groupId, testerIDs: testerIds) },
            logger: logger
        )
        logger.log("removed \(testerIds.count) tester(s) from group \(groupId)", level: .success)
    }
}

struct TFBetaGroupsCreateAndInviteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-and-invite",
        abstract: "Create a beta group and immediately add testers to it."
    )
    @Option(name: .long) var appId: String
    @Option(name: .long) var name: String
    @Option(name: .long) var publicLinkEnabled: Bool?
    @Option(name: .long) var feedbackEnabled: Bool?
    @Argument(help: "Existing tester ids to add to the new group.") var testerIds: [String]
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let fields = TestFlightAPI.BetaGroupFields(
            publicLinkEnabled: publicLinkEnabled,
            feedbackEnabled: feedbackEnabled
        )
        let group = try await surface(
            { try await api.createBetaGroupAndInvite(
                appID: appId, name: name, testerIDs: testerIds, fields: fields
            ) },
            logger: logger
        )
        if json {
            try emitJSON(group)
            return
        }
        logger.log(
            "created beta group \(group.id) and added \(testerIds.count) tester(s)",
            level: .success
        )
    }
}

// MARK: - betaTesters

struct TFBetaTestersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-testers",
        abstract: "Manage TestFlight beta testers.",
        subcommands: [
            TFBetaTestersListCommand.self,
            TFBetaTestersGetCommand.self,
            TFBetaTestersCreateCommand.self,
            TFBetaTestersDeleteCommand.self,
            TFBetaTestersRemoveFromAppCommand.self,
            TFBetaTestersAssignToGroupsCommand.self,
            TFBetaTestersRemoveFromGroupsCommand.self,
        ]
    )
}

struct TFBetaTestersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List beta testers for an app.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface(
            { try await api.listBetaTesters(appID: appId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Beta testers (\(page.data.count))")
        for t in page.data {
            let email = t.attributes?.email ?? "(no email)"
            let name = [t.attributes?.firstName, t.attributes?.lastName]
                .compactMap { $0 }
                .joined(separator: " ")
            let state = t.attributes?.state ?? "(unknown)"
            print("  \(t.id)  \(email)  \(name)  [\(state)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct TFBetaTestersGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a beta tester by id.")
    @Argument(help: "Beta tester id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let tester = try await surface({ try await api.getBetaTester(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(tester)
            return
        }
        guard let tester else {
            logger.log("no beta tester \(id)", level: .warning)
            return
        }
        logger.header("Beta tester \(tester.id)")
        print("  email:      \(tester.attributes?.email ?? "(none)")")
        print("  first name: \(tester.attributes?.firstName ?? "(none)")")
        print("  last name:  \(tester.attributes?.lastName ?? "(none)")")
        print("  state:      \(tester.attributes?.state ?? "(none)")")
        print("  invite:     \(tester.attributes?.inviteType ?? "(none)")")
    }
}

struct TFBetaTestersCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a beta tester.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var email: String
    @Option(name: .long) var firstName: String?
    @Option(name: .long) var lastName: String?
    @Option(name: .long, parsing: .upToNextOption, help: "Beta group ids to add tester to.")
    var betaGroupIds: [String] = []
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let tester = try await surface(
            { try await api.createBetaTester(
                appID: appId, email: email,
                firstName: firstName, lastName: lastName,
                betaGroupIDs: betaGroupIds
            ) },
            logger: logger
        )
        if json {
            try emitJSON(tester)
            return
        }
        logger.log("created beta tester \(tester.id) (\(email))", level: .success)
    }
}

struct TFBetaTestersDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a beta tester across all apps.")
    @Argument(help: "Beta tester id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface({ try await api.deleteBetaTester(id: id) }, logger: logger)
        logger.log("deleted beta tester \(id)", level: .success)
    }
}

struct TFBetaTestersRemoveFromAppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-from-app",
        abstract: "Remove a tester from one app while keeping their record elsewhere."
    )
    @Option(name: .long) var testerId: String
    @Option(name: .long) var appId: String

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface(
            { try await api.removeBetaTesterFromApp(testerID: testerId, appID: appId) },
            logger: logger
        )
        logger.log("removed tester \(testerId) from app \(appId)", level: .success)
    }
}

struct TFBetaTestersAssignToGroupsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assign-to-groups",
        abstract: "Assign a tester to beta groups."
    )
    @Option(name: .long) var testerId: String
    @Argument(help: "Beta group ids to assign tester to.") var groupIds: [String]

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface(
            { try await api.assignBetaTesterToGroups(testerID: testerId, groupIDs: groupIds) },
            logger: logger
        )
        logger.log("assigned tester \(testerId) to \(groupIds.count) group(s)", level: .success)
    }
}

struct TFBetaTestersRemoveFromGroupsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-from-groups",
        abstract: "Remove a tester from one or more beta groups (keeps them on the app)."
    )
    @Option(name: .long) var testerId: String
    @Argument(help: "Beta group ids to remove tester from.") var groupIds: [String]

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface(
            { try await api.removeBetaTesterFromGroups(testerID: testerId, groupIDs: groupIds) },
            logger: logger
        )
        logger.log("removed tester \(testerId) from \(groupIds.count) group(s)", level: .success)
    }
}

// MARK: - betaTesterInvitations

struct TFBetaTesterInvitationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-tester-invitations",
        abstract: "Manage TestFlight tester invitations.",
        subcommands: [
            TFBetaTesterInvitationsCreateCommand.self,
        ]
    )
}

struct TFBetaTesterInvitationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Re-send a TestFlight invitation email to an existing tester."
    )
    @Option(name: .long) var testerId: String
    @Option(name: .long) var appId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let invitation = try await surface(
            { try await api.createBetaTesterInvitation(testerID: testerId, appID: appId) },
            logger: logger
        )
        if json {
            try emitJSON(invitation)
            return
        }
        logger.log("sent invitation \(invitation.id) to tester \(testerId)", level: .success)
    }
}

// MARK: - prereleaseVersions

struct TFPrereleaseVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prerelease-versions",
        abstract: "List or fetch pre-release version trains (read-only).",
        subcommands: [
            TFPrereleaseVersionsListCommand.self,
            TFPrereleaseVersionsGetCommand.self,
        ]
    )
}

struct TFPrereleaseVersionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List pre-release versions for an app.")
    @Option(name: .long) var appId: String
    @Option(name: .long, help: "IOS, MAC_OS, TV_OS, VISION_OS.") var platform: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface(
            { try await api.listPrereleaseVersions(
                appID: appId, platform: platform, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Pre-release versions (\(page.data.count))")
        for v in page.data {
            let ver = v.attributes?.version ?? "(unknown)"
            let plat = v.attributes?.platform ?? "(unknown)"
            print("  \(v.id)  \(ver)  [\(plat)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct TFPrereleaseVersionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a pre-release version by id.")
    @Argument(help: "Pre-release version id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let version = try await surface(
            { try await api.getPrereleaseVersion(id: id) },
            logger: logger
        )
        if json {
            try emitOptionalJSON(version)
            return
        }
        guard let version else {
            logger.log("no pre-release version \(id)", level: .warning)
            return
        }
        print("  id:       \(version.id)")
        print("  version:  \(version.attributes?.version ?? "(none)")")
        print("  platform: \(version.attributes?.platform ?? "(none)")")
    }
}

// MARK: - builds

struct TFBuildsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "builds",
        abstract: "List, fetch, or update TestFlight builds.",
        subcommands: [
            TFBuildsListCommand.self,
            TFBuildsGetCommand.self,
            TFBuildsSetExpiredCommand.self,
        ]
    )
}

struct TFBuildsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List builds with TestFlight filters.")
    @Option(name: .long) var appId: String?
    @Option(name: .long) var expired: Bool?
    @Option(name: .long, help: "PROCESSING, FAILED, INVALID, VALID.") var processingState: String?
    @Option(name: .long) var prereleaseVersionId: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface(
            { try await api.listBuilds(
                appID: appId,
                expired: expired,
                processingState: processingState,
                preReleaseVersionID: prereleaseVersionId,
                limit: limit,
                cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Builds (\(page.data.count))")
        for b in page.data {
            let ver = b.attributes?.version ?? "(unknown)"
            let state = b.attributes?.processingState ?? "(unknown)"
            let exp = (b.attributes?.expired ?? false) ? "expired" : "active"
            print("  \(b.id)  build \(ver)  [\(state)]  \(exp)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct TFBuildsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a build by id.")
    @Argument(help: "Build id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let build = try await surface({ try await api.getBuild(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(build)
            return
        }
        guard let build else {
            logger.log("no build \(id)", level: .warning)
            return
        }
        print("  id:               \(build.id)")
        print("  version:          \(build.attributes?.version ?? "(none)")")
        print("  processingState:  \(build.attributes?.processingState ?? "(none)")")
        print("  expired:          \(build.attributes?.expired.map(String.init(describing:)) ?? "(unknown)")")
        if let uploaded = build.attributes?.uploadedDate {
            print("  uploadedDate:     \(uploaded)")
        }
    }
}

struct TFBuildsSetExpiredCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-expired",
        abstract: "Flip the expired flag on a build."
    )
    @Argument(help: "Build id.") var id: String
    @Flag(name: .long, inversion: .prefixedNo, help: "Expire (--expired) or un-expire (--no-expired).")
    var expired: Bool = true
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let build = try await surface(
            { try await api.setBuildExpired(id: id, expired: expired) },
            logger: logger
        )
        if json {
            try emitJSON(build)
            return
        }
        logger.log(
            "set build \(id) expired=\(expired)",
            level: .success
        )
    }
}

// MARK: - buildBetaDetail

struct TFBuildBetaDetailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-beta-detail",
        abstract: "Read or update a build's TestFlight detail record (auto-notify, beta states).",
        subcommands: [
            TFBuildBetaDetailGetCommand.self,
            TFBuildBetaDetailUpdateCommand.self,
        ]
    )
}

struct TFBuildBetaDetailGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read a build's TestFlight detail record.")
    @Option(name: .long) var buildId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let detail = try await surface(
            { try await api.getBuildBetaDetail(buildID: buildId) },
            logger: logger
        )
        if json {
            try emitOptionalJSON(detail)
            return
        }
        guard let detail else {
            logger.log("no buildBetaDetail for build \(buildId)", level: .warning)
            return
        }
        print("  id:                  \(detail.id)")
        print("  internalBuildState:  \(detail.attributes?.internalBuildState ?? "(none)")")
        print("  externalBuildState:  \(detail.attributes?.externalBuildState ?? "(none)")")
        print("  autoNotifyEnabled:   \(detail.attributes?.autoNotifyEnabled.map(String.init(describing:)) ?? "(unknown)")")
    }
}

struct TFBuildBetaDetailUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update autoNotifyEnabled on a build's TestFlight detail record."
    )
    @Argument(help: "buildBetaDetails id (NOT the build id).") var id: String
    @Flag(name: .long, inversion: .prefixedNo, help: "Toggle auto-notify on/off.")
    var autoNotify: Bool = true
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let detail = try await surface(
            { try await api.updateBuildBetaDetail(id: id, autoNotifyEnabled: autoNotify) },
            logger: logger
        )
        if json {
            try emitJSON(detail)
            return
        }
        logger.log("updated buildBetaDetail \(detail.id) autoNotify=\(autoNotify)", level: .success)
    }
}

// MARK: - buildBetaNotifications

struct TFBuildBetaNotificationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-beta-notifications",
        abstract: "Push a 'new build available' email to TestFlight testers.",
        subcommands: [
            TFBuildBetaNotificationsCreateCommand.self,
        ]
    )
}

struct TFBuildBetaNotificationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Send a notification email to every tester in every group attached to this build."
    )
    @Option(name: .long) var buildId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let n = try await surface(
            { try await api.sendBuildBetaNotification(buildID: buildId) },
            logger: logger
        )
        if json {
            try emitJSON(n)
            return
        }
        logger.log("sent beta notification \(n.id) for build \(buildId)", level: .success)
    }
}

// MARK: - betaAppLocalizations

struct TFBetaAppLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-app-localizations",
        abstract: "Manage per-locale TestFlight App Information records.",
        subcommands: [
            TFBetaAppLocsListCommand.self,
            TFBetaAppLocsGetCommand.self,
            TFBetaAppLocsCreateCommand.self,
            TFBetaAppLocsUpdateCommand.self,
            TFBetaAppLocsDeleteCommand.self,
        ]
    )
}

struct TFBetaAppLocsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List beta app localizations.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface(
            { try await api.listBetaAppLocalizations(appID: appId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Beta app localizations (\(page.data.count))")
        for l in page.data {
            print("  \(l.id)  \(l.attributes?.locale ?? "(no locale)")  feedback=\(l.attributes?.feedbackEmail ?? "(none)")")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct TFBetaAppLocsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a beta app localization by id.")
    @Argument(help: "betaAppLocalizations id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let loc = try await surface(
            { try await api.getBetaAppLocalization(id: id) },
            logger: logger
        )
        if json {
            try emitOptionalJSON(loc)
            return
        }
        guard let loc else {
            logger.log("no beta app localization \(id)", level: .warning)
            return
        }
        try emitJSON(loc)
    }
}

struct TFBetaAppLocsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a beta app localization.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var locale: String
    @Option(name: .long) var description: String?
    @Option(name: .long) var feedbackEmail: String?
    @Option(name: .long) var marketingUrl: String?
    @Option(name: .long) var privacyPolicyUrl: String?
    @Option(name: .long) var tvOsPrivacyPolicy: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let fields = TestFlightAPI.BetaAppLocalizationFields(
            description: description,
            feedbackEmail: feedbackEmail,
            marketingURL: marketingUrl,
            privacyPolicyURL: privacyPolicyUrl,
            tvOsPrivacyPolicy: tvOsPrivacyPolicy
        )
        let loc = try await surface(
            { try await api.createBetaAppLocalization(appID: appId, locale: locale, fields: fields) },
            logger: logger
        )
        if json {
            try emitJSON(loc)
            return
        }
        logger.log("created beta app localization \(loc.id) for \(locale)", level: .success)
    }
}

struct TFBetaAppLocsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a beta app localization.")
    @Argument(help: "betaAppLocalizations id.") var id: String
    @Option(name: .long) var description: String?
    @Option(name: .long) var feedbackEmail: String?
    @Option(name: .long) var marketingUrl: String?
    @Option(name: .long) var privacyPolicyUrl: String?
    @Option(name: .long) var tvOsPrivacyPolicy: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let fields = TestFlightAPI.BetaAppLocalizationFields(
            description: description,
            feedbackEmail: feedbackEmail,
            marketingURL: marketingUrl,
            privacyPolicyURL: privacyPolicyUrl,
            tvOsPrivacyPolicy: tvOsPrivacyPolicy
        )
        let loc = try await surface(
            { try await api.updateBetaAppLocalization(id: id, fields: fields) },
            logger: logger
        )
        if json {
            try emitJSON(loc)
            return
        }
        logger.log("updated beta app localization \(loc.id)", level: .success)
    }
}

struct TFBetaAppLocsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a beta app localization.")
    @Argument(help: "betaAppLocalizations id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface({ try await api.deleteBetaAppLocalization(id: id) }, logger: logger)
        logger.log("deleted beta app localization \(id)", level: .success)
    }
}

// MARK: - betaBuildLocalizations

struct TFBetaBuildLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-build-localizations",
        abstract: "Manage per-locale 'What to Test' notes on a build.",
        subcommands: [
            TFBetaBuildLocsListCommand.self,
            TFBetaBuildLocsGetCommand.self,
            TFBetaBuildLocsCreateCommand.self,
            TFBetaBuildLocsUpdateCommand.self,
            TFBetaBuildLocsDeleteCommand.self,
        ]
    )
}

struct TFBetaBuildLocsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List beta build localizations.")
    @Option(name: .long) var buildId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface(
            { try await api.listBetaBuildLocalizations(buildID: buildId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Beta build localizations (\(page.data.count))")
        for l in page.data {
            let preview = (l.attributes?.whatsNew ?? "").prefix(60)
            print("  \(l.id)  \(l.attributes?.locale ?? "(no locale)")  \(preview)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct TFBetaBuildLocsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a beta build localization by id.")
    @Argument(help: "betaBuildLocalizations id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let loc = try await surface({ try await api.getBetaBuildLocalization(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(loc)
            return
        }
        guard let loc else {
            logger.log("no beta build localization \(id)", level: .warning)
            return
        }
        try emitJSON(loc)
    }
}

struct TFBetaBuildLocsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a beta build localization.")
    @Option(name: .long) var buildId: String
    @Option(name: .long) var locale: String
    @Option(name: .long, help: "What to Test text for this locale.") var whatsNew: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let loc = try await surface(
            { try await api.createBetaBuildLocalization(
                buildID: buildId, locale: locale, whatsNew: whatsNew
            ) },
            logger: logger
        )
        if json {
            try emitJSON(loc)
            return
        }
        logger.log("created beta build localization \(loc.id) for \(locale)", level: .success)
    }
}

struct TFBetaBuildLocsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a beta build localization.")
    @Argument(help: "betaBuildLocalizations id.") var id: String
    @Option(name: .long) var whatsNew: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let loc = try await surface(
            { try await api.updateBetaBuildLocalization(id: id, whatsNew: whatsNew) },
            logger: logger
        )
        if json {
            try emitJSON(loc)
            return
        }
        logger.log("updated beta build localization \(loc.id)", level: .success)
    }
}

struct TFBetaBuildLocsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a beta build localization.")
    @Argument(help: "betaBuildLocalizations id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        try await surface({ try await api.deleteBetaBuildLocalization(id: id) }, logger: logger)
        logger.log("deleted beta build localization \(id)", level: .success)
    }
}

// MARK: - betaAppReviewDetail

struct TFBetaAppReviewDetailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-app-review-detail",
        abstract: "Read or update the TestFlight Beta App Review contact info for an app.",
        subcommands: [
            TFBetaAppReviewDetailGetCommand.self,
            TFBetaAppReviewDetailUpdateCommand.self,
        ]
    )
}

struct TFBetaAppReviewDetailGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read the beta app review detail.")
    @Option(name: .long) var appId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let detail = try await surface(
            { try await api.getBetaAppReviewDetail(appID: appId) },
            logger: logger
        )
        if json {
            try emitOptionalJSON(detail)
            return
        }
        guard let detail else {
            logger.log("no beta app review detail for app \(appId)", level: .warning)
            return
        }
        try emitJSON(detail)
    }
}

struct TFBetaAppReviewDetailUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update the beta app review detail.")
    @Argument(help: "betaAppReviewDetails id (NOT the app id).") var id: String
    @Option(name: .long) var contactFirstName: String?
    @Option(name: .long) var contactLastName: String?
    @Option(name: .long) var contactPhone: String?
    @Option(name: .long) var contactEmail: String?
    @Option(name: .long) var demoAccountName: String?
    @Option(name: .long) var demoAccountPassword: String?
    @Option(name: .long) var demoAccountRequired: Bool?
    @Option(name: .long) var notes: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let fields = TestFlightAPI.BetaAppReviewDetailFields(
            contactFirstName: contactFirstName,
            contactLastName: contactLastName,
            contactPhone: contactPhone,
            contactEmail: contactEmail,
            demoAccountName: demoAccountName,
            demoAccountPassword: demoAccountPassword,
            demoAccountRequired: demoAccountRequired,
            notes: notes
        )
        let detail = try await surface(
            { try await api.updateBetaAppReviewDetail(id: id, fields: fields) },
            logger: logger
        )
        if json {
            try emitJSON(detail)
            return
        }
        logger.log("updated beta app review detail \(detail.id)", level: .success)
    }
}

// MARK: - betaAppReviewSubmissions

struct TFBetaAppReviewSubmissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-app-review-submissions",
        abstract: "Manage TestFlight Beta App Review submissions.",
        subcommands: [
            TFBetaAppReviewSubsListCommand.self,
            TFBetaAppReviewSubsGetCommand.self,
            TFBetaAppReviewSubsCreateCommand.self,
        ]
    )
}

struct TFBetaAppReviewSubsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List beta app review submissions.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface(
            { try await api.listBetaAppReviewSubmissions(appID: appId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Beta app review submissions (\(page.data.count))")
        for s in page.data {
            let state = s.attributes?.betaReviewState ?? "(unknown)"
            let date = s.attributes?.submittedDate.map { String(describing: $0) } ?? "(not submitted)"
            print("  \(s.id)  [\(state)]  \(date)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct TFBetaAppReviewSubsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a beta app review submission by id.")
    @Argument(help: "betaAppReviewSubmissions id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let s = try await surface({ try await api.getBetaAppReviewSubmission(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(s)
            return
        }
        guard let s else {
            logger.log("no beta app review submission \(id)", level: .warning)
            return
        }
        try emitJSON(s)
    }
}

struct TFBetaAppReviewSubsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Submit a build for Beta App Review.")
    @Option(name: .long) var buildId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let s = try await surface(
            { try await api.createBetaAppReviewSubmission(buildID: buildId) },
            logger: logger
        )
        if json {
            try emitJSON(s)
            return
        }
        logger.log("submitted build \(buildId) for Beta App Review (submission \(s.id))", level: .success)
    }
}

// MARK: - betaLicenseAgreement

struct TFBetaLicenseAgreementCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-license-agreement",
        abstract: "Read or update the TestFlight EULA testers accept.",
        subcommands: [
            TFBetaLicenseGetCommand.self,
            TFBetaLicenseUpdateCommand.self,
        ]
    )
}

struct TFBetaLicenseGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read the beta license agreement.")
    @Option(name: .long) var appId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let agreement = try await surface(
            { try await api.getBetaLicenseAgreement(appID: appId) },
            logger: logger
        )
        if json {
            try emitOptionalJSON(agreement)
            return
        }
        guard let agreement else {
            logger.log("no beta license agreement for app \(appId)", level: .warning)
            return
        }
        print("  id:   \(agreement.id)")
        let text = agreement.attributes?.agreementText ?? "(none)"
        print("  text: \(text.prefix(120))\(text.count > 120 ? " ..." : "")")
    }
}

struct TFBetaLicenseUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Replace the beta license agreement text.")
    @Argument(help: "betaLicenseAgreements id (NOT the app id).") var id: String
    @Option(name: .long, help: "Path to a UTF-8 text file containing the agreement.")
    var fromFile: String?
    @Option(name: .long, help: "Inline agreement text.") var text: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let agreementText: String
        if let path = fromFile {
            agreementText = try String(contentsOfFile: path, encoding: .utf8)
        } else if let t = text {
            agreementText = t
        } else {
            logger.log("provide --from-file <path> or --text <inline>", level: .error)
            throw ExitCode(1)
        }
        let api = try tfClient(logger: logger)
        let agreement = try await surface(
            { try await api.updateBetaLicenseAgreement(id: id, agreementText: agreementText) },
            logger: logger
        )
        if json {
            try emitJSON(agreement)
            return
        }
        logger.log("updated beta license agreement \(agreement.id)", level: .success)
    }
}

// MARK: - betaTesterMetrics

struct TFBetaTesterMetricsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-tester-metrics",
        abstract: "Per-tester install/launch counts (read-only).",
        subcommands: [
            TFBetaTesterMetricsListCommand.self,
        ]
    )
}

struct TFBetaTesterMetricsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List per-tester metrics for an app.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface(
            { try await api.listBetaTesterMetrics(appID: appId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Beta tester metrics (\(page.data.count))")
        for m in page.data {
            let state = m.attributes?.betaTesterState ?? "(unknown)"
            let ver = m.attributes?.installedCfBundleShortVersionString ?? "?"
            let build = m.attributes?.installedCfBundleVersion ?? "?"
            let crashes = m.attributes?.crashCount.map(String.init) ?? "?"
            print("  \(m.id)  [\(state)]  installed \(ver) (\(build))  crashes=\(crashes)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

// MARK: - buildBundles

struct TFBuildBundlesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-bundles",
        abstract: "List or fetch build bundles (primary .app + extensions/clips, read-only).",
        subcommands: [
            TFBuildBundlesListCommand.self,
            TFBuildBundlesGetCommand.self,
        ]
    )
}

struct TFBuildBundlesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List bundles inside a build.")
    @Option(name: .long) var buildId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface(
            { try await api.listBuildBundles(buildID: buildId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Build bundles (\(page.data.count))")
        for b in page.data {
            let bid = b.attributes?.bundleId ?? "(no id)"
            let typ = b.attributes?.bundleType ?? "(no type)"
            print("  \(b.id)  \(bid)  [\(typ)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct TFBuildBundlesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a build bundle by id.")
    @Argument(help: "buildBundles id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let bundle = try await surface({ try await api.getBuildBundle(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(bundle)
            return
        }
        guard let bundle else {
            logger.log("no build bundle \(id)", level: .warning)
            return
        }
        try emitJSON(bundle)
    }
}

// MARK: - buildIcons

struct TFBuildIconsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-icons",
        abstract: "List icon images attached to a build (read-only).",
        subcommands: [
            TFBuildIconsListCommand.self,
        ]
    )
}

struct TFBuildIconsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List icons for a build.")
    @Option(name: .long) var buildId: String
    @Option(name: .long) var limit: Int = 50
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try tfClient(logger: logger)
        let page = try await surface(
            { try await api.listBuildIcons(buildID: buildId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Build icons (\(page.data.count))")
        for i in page.data {
            let typ = i.attributes?.iconAssetType ?? "(none)"
            let url = i.attributes?.imageAsset?.templateUrl ?? "(no url)"
            print("  \(i.id)  [\(typ)]  \(url)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}
