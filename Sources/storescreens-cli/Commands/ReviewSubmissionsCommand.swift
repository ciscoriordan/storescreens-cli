import ArgumentParser
import Foundation
import StorescreensCore

// MARK: - storescreens review-submissions

/// Parent command for direct control over App Review submissions - the
/// `reviewSubmissions` + `reviewSubmissionItems` resources that
/// `storescreens submit --submit-for-review` drives automatically. The
/// headline subcommand is `cancel`: pulling a queued, in-review, or
/// rejected submission back so a fixed build (or metadata) can be
/// resubmitted, without touching the ASC web UI.
struct ReviewSubmissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review-submissions",
        abstract: "Manage App Review submissions: list, inspect, create, submit, and cancel.",
        discussion: """
            Direct control over the reviewSubmissions flow that `storescreens submit \
            --submit-for-review` runs automatically. Typical workflows:
            1) `storescreens review-submissions list` shows submissions + states for the app \
            in ./storescreens.yml (or pass --app-id / --bundle-id).
            2) `storescreens review-submissions cancel <id>` withdraws a queued or rejected \
            submission (WAITING_FOR_REVIEW / UNRESOLVED_ISSUES / READY_FOR_REVIEW draft) so a \
            fixed build can be resubmitted. Find the id via `list` or `storescreens status`.
            3) `create` + `add-item` + `submit` assembles a submission by hand - e.g. sending a \
            Custom Product Page version, app event, or Game Center version to review without \
            a new app version.
            """,
        subcommands: [
            ReviewSubmissionsListCommand.self,
            ReviewSubmissionsGetCommand.self,
            ReviewSubmissionsItemsCommand.self,
            ReviewSubmissionsCreateCommand.self,
            ReviewSubmissionsAddItemCommand.self,
            ReviewSubmissionsSubmitCommand.self,
            ReviewSubmissionsCancelCommand.self,
            ReviewSubmissionsUpdateItemCommand.self,
            ReviewSubmissionsRemoveItemCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// CLI helpers private to the review-submissions command tree. Mirrors the
/// VersionReleaseCLIHelpers shape so user-facing error rendering stays
/// consistent across the CLI.
enum ReviewSubmissionsCLIHelpers {
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

    /// Resolves the numeric ASC app id from, in priority order: an explicit
    /// --app-id, an explicit --bundle-id (looked up), or the
    /// `app_store_connect:` block of the storescreens.yml at `configPath`.
    /// Lets `list` / `create` work with zero flags inside a project dir while
    /// staying usable against arbitrary apps.
    static func resolveAppID(
        appId: String?,
        bundleId: String?,
        configPath: String,
        client: ASCClient,
        logger: Logger
    ) async throws -> String {
        if let appId, !appId.isEmpty { return appId }
        let apps = AppsAPI(client: client)
        if let bundleId, !bundleId.isEmpty {
            guard let app = try await apps.lookupApp(bundleID: bundleId) else {
                logger.log("no app matches bundle id \(bundleId)", level: .error)
                throw ExitCode(1)
            }
            return app.id
        }
        if FileManager.default.fileExists(atPath: configPath),
           let ascConfig = (try? ConfigLoader().load(from: configPath))?.appStoreConnect {
            if let id = ascConfig.appID, !id.isEmpty { return id }
            if let bundle = ascConfig.bundleID, !bundle.isEmpty {
                guard let app = try await apps.lookupApp(bundleID: bundle) else {
                    logger.log("no app matches bundle id \(bundle) (from \(configPath))", level: .error)
                    throw ExitCode(1)
                }
                return app.id
            }
        }
        logger.log("no app specified", level: .error)
        print("  pass --app-id or --bundle-id, or run in a directory whose storescreens.yml has an `app_store_connect:` block")
        throw ExitCode(1)
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

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()

    static func printSubmissionLine(_ s: AppsAPI.ReviewSubmission) {
        let state = s.attributes?.state ?? "(unknown)"
        let date = s.attributes?.submittedDate.map { dateFormatter.string(from: $0) } ?? "(not yet submitted)"
        print("  \(s.id)  \(state)  submitted \(date)")
    }
}

// MARK: - list

struct ReviewSubmissionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List review submissions for an app (GET /reviewSubmissions)."
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String?
    @Option(name: .long, help: "Bundle id to look the app up by.") var bundleId: String?
    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml (used when no --app-id / --bundle-id).")
    var config: String = "storescreens.yml"
    @Option(name: .long, help: "Platform (IOS, MAC_OS, TV_OS, VISION_OS).") var platform: String = "IOS"
    @Option(name: .long, help: "Comma-separated state filter (READY_FOR_REVIEW, WAITING_FOR_REVIEW, IN_REVIEW, UNRESOLVED_ISSUES, CANCELING, COMPLETING, COMPLETE).")
    var state: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let client = try ReviewSubmissionsCLIHelpers.loadClient(logger: logger)
        do {
            let appID = try await ReviewSubmissionsCLIHelpers.resolveAppID(
                appId: appId, bundleId: bundleId, configPath: config, client: client, logger: logger
            )
            let states = state?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let subs = try await AppsAPI(client: client).listReviewSubmissions(
                appID: appID, platform: platform, states: states
            )
            if json { try ReviewSubmissionsCLIHelpers.emitJSON(subs); return }
            logger.header("Review submissions (app \(appID), \(platform))")
            if subs.isEmpty {
                print("  (none)")
                return
            }
            // Newest submittedDate first; drafts (nil date) last.
            let sorted = subs.sorted { l, r in
                switch (l.attributes?.submittedDate, r.attributes?.submittedDate) {
                case let (a?, b?): return a > b
                case (_?, nil):    return true
                case (nil, _?):    return false
                default:           return false
                }
            }
            for s in sorted { ReviewSubmissionsCLIHelpers.printSubmissionLine(s) }
            print("")
            print("  inspect items with `storescreens review-submissions items <id>`")
        } catch let e as ExitCode {
            throw e
        } catch {
            throw ReviewSubmissionsCLIHelpers.failAPI(error, logger: logger, context: "list")
        }
    }
}

// MARK: - get

struct ReviewSubmissionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch a single review submission by id."
    )
    @Argument(help: "reviewSubmission id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let client = try ReviewSubmissionsCLIHelpers.loadClient(logger: logger)
        do {
            let sub = try await AppsAPI(client: client).getReviewSubmission(id: id)
            if json { try ReviewSubmissionsCLIHelpers.emitJSON(sub); return }
            logger.header("reviewSubmission \(sub.id)")
            print("  state:         \(sub.attributes?.state ?? "?")")
            print("  platform:      \(sub.attributes?.platform ?? "?")")
            if let d = sub.attributes?.submittedDate {
                print("  submittedDate: \(ReviewSubmissionsCLIHelpers.dateFormatter.string(from: d))")
            }
        } catch {
            throw ReviewSubmissionsCLIHelpers.failAPI(error, logger: logger, context: "get")
        }
    }
}

// MARK: - items

struct ReviewSubmissionsItemsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "items",
        abstract: "List the items attached to a review submission (GET /reviewSubmissions/{id}/items)."
    )
    @Argument(help: "reviewSubmission id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let client = try ReviewSubmissionsCLIHelpers.loadClient(logger: logger)
        do {
            let items = try await AppsAPI(client: client).listReviewSubmissionItems(reviewSubmissionID: id)
            if json { try ReviewSubmissionsCLIHelpers.emitJSON(items); return }
            logger.header("Items on reviewSubmission \(id)")
            if items.isEmpty {
                print("  (none - attach one with `storescreens review-submissions add-item`)")
                return
            }
            for item in items {
                let state = item.attributes?.state ?? "(unknown)"
                let version = item.appStoreVersionID.map { "  appStoreVersion \($0)" } ?? ""
                print("  \(item.id)  \(state)\(version)")
            }
        } catch {
            throw ReviewSubmissionsCLIHelpers.failAPI(error, logger: logger, context: "items")
        }
    }
}

// MARK: - create

struct ReviewSubmissionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a draft review submission (POST /reviewSubmissions).",
        discussion: """
            ASC allows one open submission per app + platform. The draft starts in \
            READY_FOR_REVIEW; attach items with `add-item`, then send it with `submit`.
            """
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String?
    @Option(name: .long, help: "Bundle id to look the app up by.") var bundleId: String?
    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml (used when no --app-id / --bundle-id).")
    var config: String = "storescreens.yml"
    @Option(name: .long, help: "Platform (IOS, MAC_OS, TV_OS, VISION_OS).") var platform: String = "IOS"
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let client = try ReviewSubmissionsCLIHelpers.loadClient(logger: logger)
        do {
            let appID = try await ReviewSubmissionsCLIHelpers.resolveAppID(
                appId: appId, bundleId: bundleId, configPath: config, client: client, logger: logger
            )
            let sub = try await AppsAPI(client: client).createReviewSubmission(appID: appID, platform: platform)
            if json { try ReviewSubmissionsCLIHelpers.emitJSON(sub); return }
            logger.log("created reviewSubmission \(sub.id) (state \(sub.attributes?.state ?? "?"))", level: .success)
            print("  attach items with `storescreens review-submissions add-item --submission-id \(sub.id) ...`")
        } catch let e as ExitCode {
            throw e
        } catch {
            throw ReviewSubmissionsCLIHelpers.failAPI(error, logger: logger, context: "create")
        }
    }
}

// MARK: - add-item

struct ReviewSubmissionsAddItemCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-item",
        abstract: "Attach a reviewable resource to a draft submission (POST /reviewSubmissionItems).",
        discussion: """
            Use --version-id for the common case (an appStoreVersion). Other reviewable kinds go \
            through --item-type + --item-id; valid item types: \
            \(AppsAPI.ReviewSubmissionItemType.allCases.map(\.rawValue).joined(separator: ", ")).
            """
    )
    @Option(name: .long, help: "reviewSubmission id (from `create` or `list`).") var submissionId: String
    @Option(name: .long, help: "appStoreVersion id - shorthand for --item-type appStoreVersion --item-id <id>.")
    var versionId: String?
    @Option(name: .long, help: "Relationship kind for non-version items (e.g. appCustomProductPageVersion, appEvent).")
    var itemType: String?
    @Option(name: .long, help: "Id of the resource named by --item-type.") var itemId: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func validate() throws {
        if versionId == nil && (itemType == nil || itemId == nil) {
            throw ValidationError("pass --version-id, or both --item-type and --item-id")
        }
        if versionId != nil && (itemType != nil || itemId != nil) {
            throw ValidationError("--version-id and --item-type/--item-id are mutually exclusive")
        }
        if let itemType, AppsAPI.ReviewSubmissionItemType(rawValue: itemType) == nil {
            throw ValidationError(
                "unknown --item-type \"\(itemType)\"; valid: \(AppsAPI.ReviewSubmissionItemType.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
    }

    func run() async throws {
        let logger = Logger()
        let client = try ReviewSubmissionsCLIHelpers.loadClient(logger: logger)
        let type: AppsAPI.ReviewSubmissionItemType
        let id: String
        if let versionId {
            type = .appStoreVersion
            id = versionId
        } else {
            type = AppsAPI.ReviewSubmissionItemType(rawValue: itemType!)!
            id = itemId!
        }
        do {
            let item = try await AppsAPI(client: client).addItemToReviewSubmission(
                reviewSubmissionID: submissionId, itemType: type, itemID: id
            )
            if json { try ReviewSubmissionsCLIHelpers.emitJSON(item); return }
            logger.log("attached \(type.rawValue) \(id) as item \(item.id)", level: .success)
        } catch {
            throw ReviewSubmissionsCLIHelpers.failAPI(error, logger: logger, context: "add-item")
        }
    }
}

// MARK: - submit

struct ReviewSubmissionsSubmitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "Finalize a draft submission and send it to Apple (PATCH submitted:true)."
    )
    @Argument(help: "reviewSubmission id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let client = try ReviewSubmissionsCLIHelpers.loadClient(logger: logger)
        do {
            let sub = try await AppsAPI(client: client).finalizeReviewSubmission(id: id)
            if json { try ReviewSubmissionsCLIHelpers.emitJSON(sub); return }
            logger.log("submitted reviewSubmission \(sub.id) (state \(sub.attributes?.state ?? "?"))", level: .success)
        } catch {
            throw ReviewSubmissionsCLIHelpers.failAPI(error, logger: logger, context: "submit")
        }
    }
}

// MARK: - cancel

struct ReviewSubmissionsCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Cancel an in-flight review submission (PATCH canceled:true).",
        discussion: """
            Withdraws a submission that is queued (WAITING_FOR_REVIEW), being reviewed \
            (IN_REVIEW), rejected (UNRESOLVED_ISSUES), or a stale draft (READY_FOR_REVIEW). \
            ASC transitions it through CANCELING to COMPLETE within a few seconds, freeing the \
            attached version for a fresh submission. Note Apple 403s the DELETE verb on \
            reviewSubmissions; this PATCH is the supported cancel path.
            """
    )
    @Argument(help: "reviewSubmission id (from `list` or `storescreens status`).") var id: String
    @Flag(name: .long, help: "Poll until the cancellation settles (state COMPLETE) before returning.")
    var wait: Bool = false
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let client = try ReviewSubmissionsCLIHelpers.loadClient(logger: logger)
        let apps = AppsAPI(client: client)
        do {
            var sub = try await apps.cancelReviewSubmission(id: id)
            if wait {
                // CANCELING settles to COMPLETE server-side within a few
                // seconds; 15 x 2s is comfortably past every observed lag.
                var attempts = 0
                while sub.attributes?.state == "CANCELING", attempts < 15 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    sub = try await apps.getReviewSubmission(id: id)
                    attempts += 1
                }
            }
            if json { try ReviewSubmissionsCLIHelpers.emitJSON(sub); return }
            logger.log("canceled reviewSubmission \(sub.id) (state \(sub.attributes?.state ?? "?"))", level: .success)
            print("  resubmit with `storescreens submit --submit-for-review` or `review-submissions create`")
        } catch {
            throw ReviewSubmissionsCLIHelpers.failAPI(error, logger: logger, context: "cancel")
        }
    }
}

// MARK: - update-item

struct ReviewSubmissionsUpdateItemCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-item",
        abstract: "Mark a submission item removed or resolved (PATCH /reviewSubmissionItems/{id})."
    )
    @Option(name: .long, help: "reviewSubmissionItem id (from `items`).") var id: String
    @Flag(name: .long, help: "Pull the item out of a not-yet-submitted submission.") var removed: Bool = false
    @Flag(name: .long, help: "Mark a rejected item as addressed.") var resolved: Bool = false
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func validate() throws {
        if !removed && !resolved {
            throw ValidationError("pass --removed and/or --resolved")
        }
    }

    func run() async throws {
        let logger = Logger()
        let client = try ReviewSubmissionsCLIHelpers.loadClient(logger: logger)
        do {
            let item = try await AppsAPI(client: client).updateReviewSubmissionItem(
                id: id, removed: removed ? true : nil, resolved: resolved ? true : nil
            )
            if json { try ReviewSubmissionsCLIHelpers.emitJSON(item); return }
            logger.log("updated item \(item.id) (state \(item.attributes?.state ?? "?"))", level: .success)
        } catch {
            throw ReviewSubmissionsCLIHelpers.failAPI(error, logger: logger, context: "update-item")
        }
    }
}

// MARK: - remove-item

struct ReviewSubmissionsRemoveItemCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-item",
        abstract: "Delete an item from a draft submission (DELETE /reviewSubmissionItems/{id})."
    )
    @Argument(help: "reviewSubmissionItem id (from `items`).") var itemId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let client = try ReviewSubmissionsCLIHelpers.loadClient(logger: logger)
        do {
            try await AppsAPI(client: client).deleteReviewSubmissionItem(id: itemId)
            if json { try ReviewSubmissionsCLIHelpers.emitJSON(["deleted": itemId]); return }
            logger.log("deleted reviewSubmissionItem \(itemId)", level: .success)
        } catch {
            throw ReviewSubmissionsCLIHelpers.failAPI(error, logger: logger, context: "remove-item")
        }
    }
}
