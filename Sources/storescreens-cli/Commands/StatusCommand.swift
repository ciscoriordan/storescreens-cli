import ArgumentParser
import Foundation
import StorescreensCore

/// Hits App Store Connect and prints the current state of the app
/// (versions + their states, in-flight review submissions). Read-only:
/// makes no changes. Falls back gracefully when the project has no
/// `storescreens.yml` or no `app_store_connect:` block, so it's safe to
/// run in any directory.
struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show App Store Connect status for this app (versions, review submissions).",
        discussion: """
            Reads app_id / bundle_id from `storescreens.yml`, resolves ASC \
            credentials (env vars or `~/.storescreens/asc-credentials.yml`), \
            and queries App Store Connect for current app state. Use this to \
            see whether a review submission has been accepted, rejected, or is \
            still queued without having to load the ASC web UI.
            """
    )

    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml.")
    var config: String = "storescreens.yml"

    @Option(name: .long, help: "Platform to query (IOS, MAC_OS, TV_OS, VISION_OS).")
    var platform: String = "IOS"

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()

        // 1. Config
        guard FileManager.default.fileExists(atPath: config) else {
            if json {
                try emitJSON(StatusReport(error: "no_config", message: "no storescreens.yml at \(config)"))
            } else {
                logger.header("App Store Connect status")
                logger.log("no storescreens.yml at \(config)", level: .warning)
                print("  run `storescreens init` to scaffold one")
            }
            return
        }
        let captureConfig: CaptureConfig
        do {
            captureConfig = try ConfigLoader().load(from: config)
        } catch {
            logger.log("could not read \(config): \(error)", level: .error)
            throw ExitCode(1)
        }

        guard let ascConfig = captureConfig.appStoreConnect else {
            if json {
                try emitJSON(StatusReport(error: "no_asc_block", message: "no app_store_connect: block in \(config)"))
            } else {
                logger.header("App Store Connect status")
                logger.log("no `app_store_connect:` block in \(config)", level: .warning)
                print("  add `app_store_connect:` with app_id or bundle_id to enable status checks")
            }
            return
        }

        // 2. Credentials
        guard ASCCredentialResolver.isConfigured() else {
            if json {
                try emitJSON(StatusReport(error: "no_credentials", message: "no ASC credentials"))
            } else {
                logger.header("App Store Connect status")
                logger.log("no ASC credentials configured", level: .warning)
                print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
            }
            return
        }
        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            logger.log("credentials broken: \(error)", level: .error)
            throw ExitCode(1)
        }

        // 3. Hit ASC.
        let client = ASCClient(credentials: creds)
        let apps = AppsAPI(client: client)

        let app: AppsAPI.App
        do {
            if let id = ascConfig.appID {
                app = try await apps.lookupApp(id: id)
            } else if let bundle = ascConfig.bundleID {
                guard let found = try await apps.lookupApp(bundleID: bundle) else {
                    logger.log("no app matches bundle id \(bundle)", level: .error)
                    throw ExitCode(1)
                }
                app = found
            } else {
                logger.log("neither app_id nor bundle_id set in \(config)", level: .error)
                throw ExitCode(1)
            }
        } catch let e as ASCClient.APIError {
            logger.log("app lookup failed: HTTP \(e.statusCode)", level: .error)
            for d in e.details { print("  [\(d.code)] \(d.title): \(d.detail)") }
            throw ExitCode(1)
        }

        let versions = (try? await apps.listVersions(appID: app.id, platform: platform)) ?? []
        let submissions = (try? await apps.listReviewSubmissions(appID: app.id, platform: platform)) ?? []

        // 4. Emit
        let report = StatusReport(
            app: .init(
                id: app.id,
                name: app.attributes?.name,
                bundleID: app.attributes?.bundleId,
                primaryLocale: app.attributes?.primaryLocale
            ),
            platform: platform,
            versions: versions.map { v in
                .init(
                    id: v.id,
                    versionString: v.attributes?.versionString,
                    state: v.attributes?.appStoreState,
                    createdDate: v.attributes?.createdDate
                )
            },
            reviewSubmissions: submissions.map { s in
                .init(
                    id: s.id,
                    state: s.attributes?.state,
                    submittedDate: s.attributes?.submittedDate
                )
            }
        )

        if json {
            try emitJSON(report)
            return
        }
        printHuman(report, logger: logger)
    }

    // MARK: - Output

    private func printHuman(_ report: StatusReport, logger: Logger) {
        logger.header("App Store Connect status")
        if let app = report.app {
            print("  app:        \(app.name ?? "(no name)") (\(app.id))")
            if let bundle = app.bundleID { print("  bundle id:  \(bundle)") }
            if let locale = app.primaryLocale { print("  locale:     \(locale)") }
        }
        print("  platform:   \(report.platform ?? "IOS")")

        // Versions (newest first by createdDate; nils last).
        let sortedVersions = report.versions.sorted { l, r in
            switch (l.createdDate, r.createdDate) {
            case let (a?, b?): return a > b
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return false
            }
        }
        print("")
        if sortedVersions.isEmpty {
            print("  Versions: (none)")
        } else {
            print("  Versions:")
            for v in sortedVersions.prefix(8) {
                let ver = v.versionString ?? "(unknown)"
                let state = v.state ?? "(unknown state)"
                let dateStr = v.createdDate.map { Self.dateFormatter.string(from: $0) } ?? ""
                let pad = String(repeating: " ", count: max(1, 10 - ver.count))
                print("    \(ver)\(pad)\(stateColored(state))    \(dateStr)")
            }
            if sortedVersions.count > 8 {
                print("    … \(sortedVersions.count - 8) more")
            }
        }

        // Review submissions (newest submittedDate first; nils last).
        let sortedSubs = report.reviewSubmissions.sorted { l, r in
            switch (l.submittedDate, r.submittedDate) {
            case let (a?, b?): return a > b
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return false
            }
        }
        print("")
        let openStates: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW", "UNRESOLVED_ISSUES"]
        let openSubs = sortedSubs.filter { ($0.state.map(openStates.contains) ?? false) }
        if !openSubs.isEmpty {
            print("  Open review submissions:")
            for s in openSubs {
                let state = s.state ?? "(unknown)"
                let dateStr = s.submittedDate.map { Self.dateFormatter.string(from: $0) } ?? "(not yet submitted)"
                print("    \(stateColored(state))    \(s.id)    submitted \(dateStr)")
            }
        } else if !sortedSubs.isEmpty {
            print("  Open review submissions: (none — last submission was \(sortedSubs.first?.state ?? "(unknown)"))")
        } else {
            print("  Open review submissions: (none)")
        }

        // Quick hint about the next action.
        print("")
        if let hint = nextActionHint(report) {
            print("  \(hint)")
        }
    }

    /// Picks the most useful hint to show under the status table — answers
    /// "what's happening with this app right now and what can I do about it".
    /// Returns nil when nothing actionable jumps out.
    private func nextActionHint(_ report: StatusReport) -> String? {
        let openStates: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW", "UNRESOLVED_ISSUES"]
        if let open = report.reviewSubmissions.first(where: { ($0.state.map(openStates.contains) ?? false) }) {
            switch open.state {
            case "IN_REVIEW":           return "Apple is reviewing the submission."
            case "WAITING_FOR_REVIEW":  return "Submission is queued; Apple has not started reviewing yet."
            case "READY_FOR_REVIEW":    return "Draft submission exists but has not been finalized. Run `storescreens submit --submit-for-review` to send it."
            case "UNRESOLVED_ISSUES":   return "Apple rejected the submission. Resolve issues and resubmit."
            default: return nil
            }
        }
        for v in report.versions {
            switch v.state {
            case "PENDING_DEVELOPER_RELEASE":
                return "\(v.versionString ?? "?") approved and pending your manual release."
            case "PENDING_APPLE_RELEASE":
                return "\(v.versionString ?? "?") approved, scheduled for Apple to release."
            case "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY":
                return "\(v.versionString ?? "?") needs attention (state: \(v.state ?? "?"))."
            default: continue
            }
        }
        if let live = report.versions.first(where: { $0.state == "READY_FOR_SALE" }) {
            return "Live on the App Store: \(live.versionString ?? "?")"
        }
        return nil
    }

    /// Apply a subtle terminal color so red/yellow/green states stand out.
    /// No-op for unknown states.
    private func stateColored(_ state: String) -> String {
        let color: String
        switch state {
        case "READY_FOR_SALE", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE":
            color = "\u{001B}[32m"  // green
        case "IN_REVIEW", "WAITING_FOR_REVIEW", "PROCESSING_FOR_APP_STORE":
            color = "\u{001B}[33m"  // yellow
        case "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
             "INVALID_BINARY", "UNRESOLVED_ISSUES":
            color = "\u{001B}[31m"  // red
        default:
            return state
        }
        return "\(color)\(state)\u{001B}[0m"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()

    private func emitJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    // MARK: - JSON report shape

    private struct StatusReport: Encodable {
        var error: String?
        var message: String?
        var app: AppInfo?
        var platform: String?
        var versions: [VersionInfo] = []
        var reviewSubmissions: [SubmissionInfo] = []

        init(error: String? = nil, message: String? = nil) {
            self.error = error
            self.message = message
        }

        init(
            app: AppInfo,
            platform: String,
            versions: [VersionInfo],
            reviewSubmissions: [SubmissionInfo]
        ) {
            self.app = app
            self.platform = platform
            self.versions = versions
            self.reviewSubmissions = reviewSubmissions
        }
    }

    private struct AppInfo: Encodable {
        var id: String
        var name: String?
        var bundleID: String?
        var primaryLocale: String?
    }

    private struct VersionInfo: Encodable {
        var id: String
        var versionString: String?
        var state: String?
        var createdDate: Date?
    }

    private struct SubmissionInfo: Encodable {
        var id: String
        var state: String?
        var submittedDate: Date?
    }
}
