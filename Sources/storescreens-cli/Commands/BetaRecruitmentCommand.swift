import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens beta-recruitment` command. Wraps the
/// `betaRecruitmentCriteria` family Apple shipped in OpenAPI spec v3.8
/// (February 2025): automatic rules that decide which testers a public
/// TestFlight link will accept based on device family, OS version, and
/// region.
///
/// Every leaf subcommand accepts `--json` for machine-readable output. The
/// same operations are exposed as MCP tools under the `beta_recruitment_*`
/// namespace.
struct BetaRecruitmentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-recruitment",
        abstract: "Manage TestFlight automatic recruitment criteria.",
        discussion: """
            Wraps the App Store Connect `betaRecruitmentCriteria` API. Each \
            criterion attaches to a beta group and decides which testers will \
            be admitted automatically when they apply via the group's public link.

            The valid catalog of device families, OS versions, and regions \
            evolves on Apple's side; fetch the live options via \
            `criterion-options list` before constructing a create / update call.
            """,
        subcommands: [
            BRCriteriaCommand.self,
            BRCriterionOptionsCommand.self,
        ]
    )
}

// MARK: - Shared helpers

fileprivate func brAPI(logger: Logger) throws -> BetaRecruitmentAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return BetaRecruitmentAPI(client: client)
}

fileprivate func brEmitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

fileprivate struct BRCLIPage<Item: Encodable>: Encodable {
    let items: [Item]
    let nextCursor: String?
}

fileprivate func brSurface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
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

// MARK: - criteria

struct BRCriteriaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "criteria",
        abstract: "Create / update / delete automatic-recruitment criteria.",
        subcommands: [
            BRCriteriaCreateCommand.self,
            BRCriteriaUpdateCommand.self,
            BRCriteriaDeleteCommand.self,
        ]
    )
}

struct BRCriteriaCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new recruitment criterion on a beta group.")
    @Option(name: .long, help: "Beta group id the criterion attaches to.") var betaGroupId: String
    @Option(name: .long, help: "Developer-visible label.") var displayName: String
    @Option(name: .long, parsing: .upToNextOption, help: "Allowed device family codes (space-separated).") var deviceFamilies: [String] = []
    @Option(name: .long, help: "Minimum OS version (e.g. 17.0).") var minimumOsVersion: String?
    @Option(name: .long, help: "Maximum OS version.") var maximumOsVersion: String?
    @Option(name: .long, parsing: .upToNextOption, help: "Allowed ISO 3166-1 alpha-3 codes (space-separated).") var allowedRegions: [String] = []
    @Option(name: .long, help: "Initial active flag.") var isActive: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try brAPI(logger: logger)
        let fields = BetaRecruitmentAPI.CriterionFields(
            deviceFamilies: deviceFamilies.isEmpty ? nil : deviceFamilies,
            minimumOsVersion: minimumOsVersion,
            maximumOsVersion: maximumOsVersion,
            allowedRegions: allowedRegions.isEmpty ? nil : allowedRegions,
            isActive: isActive
        )
        let c = try await brSurface(
            { try await api.createCriterion(
                betaGroupID: betaGroupId, displayName: displayName, fields: fields
            ) },
            logger: logger
        )
        if json { try brEmitJSON(c); return }
        logger.log("created betaRecruitmentCriterion \(c.id) (\(displayName))", level: .success)
    }
}

struct BRCriteriaUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH a recruitment criterion.")
    @Argument(help: "betaRecruitmentCriterion id.") var id: String
    @Option(name: .long) var displayName: String?
    @Option(name: .long, parsing: .upToNextOption) var deviceFamilies: [String] = []
    @Option(name: .long) var minimumOsVersion: String?
    @Option(name: .long) var maximumOsVersion: String?
    @Option(name: .long, parsing: .upToNextOption) var allowedRegions: [String] = []
    @Option(name: .long) var isActive: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try brAPI(logger: logger)
        let fields = BetaRecruitmentAPI.CriterionFields(
            displayName: displayName,
            deviceFamilies: deviceFamilies.isEmpty ? nil : deviceFamilies,
            minimumOsVersion: minimumOsVersion,
            maximumOsVersion: maximumOsVersion,
            allowedRegions: allowedRegions.isEmpty ? nil : allowedRegions,
            isActive: isActive
        )
        let c = try await brSurface(
            { try await api.updateCriterion(id: id, fields: fields) },
            logger: logger
        )
        if json { try brEmitJSON(c); return }
        logger.log("updated betaRecruitmentCriterion \(c.id)", level: .success)
    }
}

struct BRCriteriaDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a recruitment criterion.")
    @Argument(help: "betaRecruitmentCriterion id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try brAPI(logger: logger)
        try await brSurface({ try await api.deleteCriterion(id: id) }, logger: logger)
        logger.log("deleted betaRecruitmentCriterion \(id)", level: .success)
    }
}

// MARK: - criterion-options

struct BRCriterionOptionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "criterion-options",
        abstract: "List Apple's catalog of valid recruitment criterion values.",
        subcommands: [
            BRCriterionOptionsListCommand.self,
        ]
    )
}

struct BRCriterionOptionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the catalog of valid criterion values.")
    @Option(name: .long, help: "Max results per page (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Pagination cursor from a previous page.") var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try brAPI(logger: logger)
        let page = try await brSurface(
            { try await api.listCriterionOptions(limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try brEmitJSON(BRCLIPage(items: page.items, nextCursor: page.nextCursor))
            return
        }
        logger.header("Criterion options (\(page.items.count))")
        for o in page.items {
            let category = o.attributes?.category ?? "?"
            let value = o.attributes?.value ?? "?"
            let display = o.attributes?.displayName ?? ""
            print("  \(o.id)\t[\(category)]\t\(value)\t\(display)")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}
