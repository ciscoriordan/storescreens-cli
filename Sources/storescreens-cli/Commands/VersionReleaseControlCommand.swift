import ArgumentParser
import Foundation
import StorescreensCore

// MARK: - storescreens version-release

/// Parent command for the App Store Connect Version Release Control surface:
/// the four release-action resources Apple ships under the appStoreVersion
/// umbrella that govern *when and how* an approved version reaches users.
///
///   - phased releases: 7-day rollout management (start / pause / resume /
///     expedite / revert)
///   - version promotions: one-shot opt-in to App Store editorial promo
///     carousels
///   - release requests: the modern "release this manually-released
///     version now" action
///   - end pre-orders: one-shot to end an app's pre-order period early
///
/// Each subcommand maps to a different point in the release timeline; the
/// shared parent (`appStoreVersion`, or `app` for pre-orders) is set by
/// relationship at create time.
struct VersionReleaseControlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version-release",
        abstract: "Manage App Store version release controls: phased rollout, promotions, manual release, end pre-orders.",
        discussion: """
            Release-control actions on App Store Connect appStoreVersion resources. Typical workflows:
            1) `storescreens version-release phased create --version-id <id>` starts a 7-day phased rollout.
            2) `storescreens version-release phased update --id <id> --phased-release-state PAUSED` pauses it.
            3) `storescreens version-release release-request --version-id <id>` releases a manually-released version now.
            4) `storescreens version-release end-preorder --app-id <id>` ends pre-orders early.
            """,
        subcommands: [
            PhasedReleaseCommand.self,
            VersionPromotionCreateCommand.self,
            VersionReleaseRequestCommand.self,
            EndPreOrderCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// CLI helpers private to the version-release command tree. Mirrors the
/// BackgroundAssetsCLIHelpers shape so user-facing error rendering stays
/// consistent across the CLI. Kept private to this file so it doesn't
/// clash with the helpers in BackgroundAssetsCommand.swift.
enum VersionReleaseCLIHelpers {
    static func loadClient(logger: Logger) throws -> ASCClient {
        guard ASCCredentialResolver.isConfigured() else {
            logger.log("no ASC credentials configured", level: .error)
            print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
            throw ExitCode(1)
        }
        do {
            let creds = try ASCCredentialResolver.resolve()
            return ASCClient(credentials: creds)
        } catch {
            logger.log("credentials broken: \(error)", level: .error)
            throw ExitCode(1)
        }
    }

    static func emitJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    static func failAPI(_ error: Error, logger: Logger, context: String) -> ExitCode {
        if let api = error as? ASCClient.APIError {
            logger.log("\(context) failed: HTTP \(api.statusCode)", level: .error)
            for d in api.details { print("  [\(d.code)] \(d.title): \(d.detail)") }
        } else {
            logger.log("\(context) failed: \(error.localizedDescription)", level: .error)
        }
        return ExitCode(1)
    }
}

// MARK: - storescreens version-release phased

struct PhasedReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "phased",
        abstract: "Manage appStoreVersionPhasedReleases (7-day rollout).",
        subcommands: [
            PhasedReleaseGetForVersionCommand.self,
            PhasedReleaseGetCommand.self,
            PhasedReleaseCreateCommand.self,
            PhasedReleaseUpdateCommand.self,
            PhasedReleaseDeleteCommand.self,
        ]
    )
}

struct PhasedReleaseGetForVersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get-for-version",
        abstract: "Read the appStoreVersionPhasedRelease attached to an appStoreVersion."
    )
    @Option(name: .long, help: "appStoreVersion id.") var versionId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try VersionReleaseCLIHelpers.loadClient(logger: logger)
        do {
            guard let pr = try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.getForVersion(
                versionID: versionId
            ) else {
                logger.log("appStoreVersion \(versionId) has no phased release", level: .info)
                return
            }
            if json { try VersionReleaseCLIHelpers.emitJSON(pr); return }
            logger.header("appStoreVersionPhasedRelease \(pr.id)")
            print("  phasedReleaseState: \(pr.attributes?.phasedReleaseState ?? "?")")
            print("  currentDayNumber:   \(pr.attributes?.currentDayNumber.map(String.init) ?? "?")")
            if let d = pr.attributes?.startDate {
                print("  startDate:          \(ISO8601DateFormatter().string(from: d))")
            }
        } catch {
            throw VersionReleaseCLIHelpers.failAPI(error, logger: logger, context: "phased get-for-version")
        }
    }
}

struct PhasedReleaseGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch a single appStoreVersionPhasedRelease by id."
    )
    @Option(name: .long, help: "appStoreVersionPhasedRelease id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try VersionReleaseCLIHelpers.loadClient(logger: logger)
        do {
            guard let pr = try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.get(id: id) else {
                logger.log("appStoreVersionPhasedRelease \(id) not found", level: .error)
                throw ExitCode(1)
            }
            if json { try VersionReleaseCLIHelpers.emitJSON(pr); return }
            logger.header("appStoreVersionPhasedRelease \(pr.id)")
            print("  phasedReleaseState: \(pr.attributes?.phasedReleaseState ?? "?")")
            print("  currentDayNumber:   \(pr.attributes?.currentDayNumber.map(String.init) ?? "?")")
        } catch {
            throw VersionReleaseCLIHelpers.failAPI(error, logger: logger, context: "phased get")
        }
    }
}

struct PhasedReleaseCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Start a phased release on a version (POST /appStoreVersionPhasedReleases)."
    )
    @Option(name: .long, help: "appStoreVersion id.") var versionId: String
    @Option(name: .long, help: "Optional initial state (default: Apple-picked).") var phasedReleaseState: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try VersionReleaseCLIHelpers.loadClient(logger: logger)
        do {
            let pr = try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.create(
                versionID: versionId,
                phasedReleaseState: phasedReleaseState
            )
            if json { try VersionReleaseCLIHelpers.emitJSON(pr); return }
            logger.log("started phased release \(pr.id) (state \(pr.attributes?.phasedReleaseState ?? "?"))", level: .success)
        } catch {
            throw VersionReleaseCLIHelpers.failAPI(error, logger: logger, context: "phased create")
        }
    }
}

struct PhasedReleaseUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Change rollout state (PAUSED to pause, ACTIVE to resume, COMPLETE to expedite)."
    )
    @Option(name: .long, help: "appStoreVersionPhasedRelease id.") var id: String
    @Option(name: .long, help: "New state (PAUSED / ACTIVE / COMPLETE).") var phasedReleaseState: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try VersionReleaseCLIHelpers.loadClient(logger: logger)
        do {
            let pr = try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.update(
                id: id, phasedReleaseState: phasedReleaseState
            )
            if json { try VersionReleaseCLIHelpers.emitJSON(pr); return }
            logger.log("updated phased release \(pr.id) -> \(phasedReleaseState)", level: .success)
        } catch {
            throw VersionReleaseCLIHelpers.failAPI(error, logger: logger, context: "phased update")
        }
    }
}

struct PhasedReleaseDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Revert the version to immediate release (no rollout)."
    )
    @Argument(help: "appStoreVersionPhasedRelease id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try VersionReleaseCLIHelpers.loadClient(logger: logger)
        do {
            try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.delete(id: id)
            if json { try VersionReleaseCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted appStoreVersionPhasedRelease \(id)", level: .success)
        } catch {
            throw VersionReleaseCLIHelpers.failAPI(error, logger: logger, context: "phased delete")
        }
    }
}

// MARK: - storescreens version-release promote

struct VersionPromotionCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "promote",
        abstract: "Opt the parent version into App Store editorial promo carousels (POST /appStoreVersionPromotions)."
    )
    @Option(name: .long, help: "appStoreVersion id.") var versionId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try VersionReleaseCLIHelpers.loadClient(logger: logger)
        do {
            let promo = try await BackgroundAssetsAPI(client: client).releaseControl.promotions.create(
                versionID: versionId
            )
            if json { try VersionReleaseCLIHelpers.emitJSON(promo); return }
            logger.log("created appStoreVersionPromotion \(promo.id)", level: .success)
        } catch {
            throw VersionReleaseCLIHelpers.failAPI(error, logger: logger, context: "promote")
        }
    }
}

// MARK: - storescreens version-release release-request

struct VersionReleaseRequestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release-request",
        abstract: "Release a manually-released version now (POST /appStoreVersionReleaseRequests).",
        discussion: """
            Triggers the release of a version currently in PENDING_DEVELOPER_RELEASE. Apple approved \
            the version on the developer's behalf and is waiting on the developer to publish it; \
            this is the modern API equivalent of clicking "Release This Version" in App Store Connect.
            """
    )
    @Option(name: .long, help: "appStoreVersion id.") var versionId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try VersionReleaseCLIHelpers.loadClient(logger: logger)
        do {
            let req = try await BackgroundAssetsAPI(client: client).releaseControl.releaseRequests.create(
                versionID: versionId
            )
            if json { try VersionReleaseCLIHelpers.emitJSON(req); return }
            logger.log("released version \(versionId) (request \(req.id))", level: .success)
        } catch {
            throw VersionReleaseCLIHelpers.failAPI(error, logger: logger, context: "release-request")
        }
    }
}

// MARK: - storescreens version-release end-preorder

struct EndPreOrderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "end-preorder",
        abstract: "End an app's pre-order period early (POST /endAppAvailabilityPreOrders).",
        discussion: """
            Transitions customers from pre-order to live install state immediately. The app must \
            currently be in a pre-order availability state; if not, ASC rejects with a 409.
            """
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try VersionReleaseCLIHelpers.loadClient(logger: logger)
        do {
            let req = try await BackgroundAssetsAPI(client: client).releaseControl.endPreOrders.create(
                appID: appId
            )
            if json { try VersionReleaseCLIHelpers.emitJSON(req); return }
            logger.log("ended pre-orders for app \(appId) (request \(req.id))", level: .success)
        } catch {
            throw VersionReleaseCLIHelpers.failAPI(error, logger: logger, context: "end-preorder")
        }
    }
}
