import ArgumentParser
import Foundation
import StorescreensCore

struct UploadBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload-build",
        abstract: "Archive, export, and upload an .ipa to App Store Connect.",
        discussion: """
            Runs `xcodebuild archive` -> `-exportArchive` -> `xcrun altool --upload-app` \
            in one step. Configuration lives under `app_store_connect.upload_build:` \
            in storescreens.yml.

            First-time setup: run `storescreens upload-build init` to add a \
            boilerplate `upload_build:` block to your storescreens.yml, then edit \
            the fields you need. Credentials are shared with `submit` (use \
            `storescreens auth init` if you haven't set up ASC API keys yet).
            """,
        subcommands: [UploadBuildRunCommand.self, UploadBuildInitCommand.self],
        defaultSubcommand: UploadBuildRunCommand.self
    )
}

struct UploadBuildRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Archive, export, and upload an .ipa to App Store Connect.",
        discussion: """
            DEVELOPER_DIR is pinned to a production Xcode (auto-detected from \
            /Applications, excluding Xcode-beta) so a beta xcode-select doesn't \
            taint the archive. Override with `xcode_path:` in config or `--xcode-path`.
            """
    )

    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml.")
    var config: String = "storescreens.yml"

    @Option(name: .long, help: "Override scheme.")
    var scheme: String?

    @Option(name: .long, help: "Override configuration (default: Release).")
    var configuration: String?

    @Option(name: .long, help: "Override DEVELOPER_DIR. Accepts the .app bundle or Contents/Developer.")
    var xcodePath: String?

    @Option(name: .long, help: "Override the export output directory (default: ./build).")
    var outputDir: String?

    @Flag(name: .long, help: "Archive and export but do not upload. Leaves the .ipa in output_dir.")
    var skipUpload: Bool = false

    @Flag(name: .long, help: "Plan the run without invoking xcodebuild or altool.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Stream full xcodebuild output instead of filtered progress lines.")
    var verbose: Bool = false

    @Option(name: .long, help: "Force a specific marketing version (e.g. 1.2.0). Still validates build number against App Store Connect.")
    var marketingVersion: String?

    @Option(name: .long, help: "Force a specific build number (e.g. 3).")
    var build: String?

    @Flag(name: .long, help: "Error out instead of auto-bumping the project when ASC state requires a version/build change.")
    var noAutoBump: Bool = false

    func run() async throws {
        var logger = Logger()
        logger.isVerbose = verbose
        let captureConfig = try ConfigLoader().load(from: config)

        guard let asc = captureConfig.appStoreConnect else {
            logger.log("no `app_store_connect:` block in \(config); nothing to do", level: .error)
            throw ExitCode(1)
        }

        // Merge flags over config. Flags win.
        var buildCfg = asc.uploadBuild ?? UploadBuildConfig()
        if let scheme { buildCfg.scheme = scheme }
        if let configuration { buildCfg.configuration = configuration }
        if let xcodePath { buildCfg.xcodePath = xcodePath }
        if let outputDir { buildCfg.outputDir = outputDir }
        if skipUpload { buildCfg.skipUpload = true }
        if let marketingVersion { buildCfg.marketingVersion = marketingVersion }
        if let build { buildCfg.buildNumber = build }
        if noAutoBump { buildCfg.autoBump = false }

        let resolvedScheme = buildCfg.scheme ?? captureConfig.scheme
        let resolvedConfig = buildCfg.configuration ?? "Release"
        let resolvedDestination = buildCfg.destination ?? "generic/platform=iOS"
        let resolvedExportMethod = buildCfg.exportMethod ?? "app-store"
        let shouldAllowProvUpdates = buildCfg.allowProvisioningUpdates ?? true

        let baseDir = URL(fileURLWithPath: config)
            .deletingLastPathComponent()
            .standardized

        // Pick Xcode.
        let xcode: XcodeInstall
        if let path = buildCfg.xcodePath {
            xcode = try XcodeLocator.atPath(path)
        } else {
            xcode = try XcodeLocator.findProduction()
        }

        // Resolve project + workspace (allow workspace-only projects too).
        let project = captureConfig.project.map {
            URL(fileURLWithPath: $0, relativeTo: baseDir).standardized.path
        }
        let workspace = captureConfig.workspace.map {
            URL(fileURLWithPath: $0, relativeTo: baseDir).standardized.path
        }
        guard project != nil || workspace != nil else {
            logger.log("storescreens.yml has no `project:` or `workspace:`", level: .error)
            throw ExitCode(1)
        }

        // Resolve output dir + derived temp paths.
        let outputRoot: URL = {
            let raw = buildCfg.outputDir ?? "build"
            return URL(fileURLWithPath: raw, relativeTo: baseDir).standardized
        }()
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let archivePath = outputRoot.appendingPathComponent("\(resolvedScheme).xcarchive").path
        let exportPath = outputRoot.appendingPathComponent("export").path

        // User-provided plist wins over generated.
        let exportOptionsPath: String
        var generatedPlistURL: URL? = nil
        if let userPlist = buildCfg.exportOptionsPlist {
            exportOptionsPath = URL(fileURLWithPath: userPlist, relativeTo: baseDir)
                .standardized.path
        } else {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("ExportOptions-\(UUID().uuidString).plist")
            try ExportOptionsWriter.write(from: buildCfg, to: tmp)
            generatedPlistURL = tmp
            exportOptionsPath = tmp.path
        }
        defer {
            if let generatedPlistURL {
                try? FileManager.default.removeItem(at: generatedPlistURL)
            }
        }

        // Pre-archive version resolution. When uploading, the build must
        // have a marketing version + build number that don't collide with
        // anything already in App Store Connect. Skipped when there's no
        // Xcode project (workspace-only exotic setups) or when the user
        // opted out of upload.
        var versionState: XcodeVersion.State? = nil
        var resolvedVersion: VersionResolver.Resolution? = nil
        if let project {
            versionState = try? XcodeVersion.read(projectPath: project)
        }

        if buildCfg.skipUpload != true, let xcState = versionState {
            resolvedVersion = try await resolveAndMaybeBumpVersion(
                xcodeState: xcState,
                project: project!,
                yamlPath: config,
                asc: asc,
                buildCfg: buildCfg,
                dryRun: dryRun,
                logger: logger
            )
        }

        logger.header(dryRun ? "Dry run" : "Upload build")
        print("  scheme:        \(resolvedScheme)")
        print("  configuration: \(resolvedConfig)")
        print("  destination:   \(resolvedDestination)")
        print("  export method: \(resolvedExportMethod)")
        print("  xcode:         \(xcode.appPath) (\(xcode.version)\(xcode.isBeta ? ", BETA" : ""))")
        if let v = resolvedVersion {
            print("  version:       \(v.marketingVersion) (\(v.reason))")
            print("  build:         \(v.buildNumber)")
        } else if let s = versionState {
            print("  version:       \(s.marketingVersion)")
            print("  build:         \(s.buildNumber)")
        }
        print("  archive:       \(archivePath)")
        print("  export dir:    \(exportPath)")
        print("  upload:        \(buildCfg.skipUpload == true ? "skipped" : "altool --upload-app")")

        if dryRun {
            logger.log("dry run OK", level: .success)
            return
        }

        let runner = ArchiveRunner(
            xcode: xcode,
            logLevel: verbose ? StorescreensCore.Logger.LogLevel.verbose : .normal
        )

        let progress: @Sendable (String) -> Void = { line in
            if !line.isEmpty { print("  \(line)") }
        }

        // 1. Archive
        logger.header("Archiving")
        try await runner.archive(
            project: project,
            workspace: workspace,
            scheme: resolvedScheme,
            configuration: resolvedConfig,
            destination: resolvedDestination,
            archivePath: archivePath,
            derivedDataPath: captureConfig.derivedDataPath,
            allowProvisioningUpdates: shouldAllowProvUpdates,
            lineHandler: verbose ? progress : nil
        )
        logger.log("archived -> \(archivePath)", level: .success)

        // 2. Export
        logger.header("Exporting")
        try FileManager.default.createDirectory(
            atPath: exportPath, withIntermediateDirectories: true
        )
        // Supply build config defaults into the writer (export method, etc.)
        // already handled - `ExportOptionsWriter.write` reads those fields.
        let ipaPath = try await runner.export(
            archivePath: archivePath,
            exportPath: exportPath,
            exportOptionsPlistPath: exportOptionsPath,
            allowProvisioningUpdates: shouldAllowProvUpdates,
            lineHandler: verbose ? progress : nil
        )
        logger.log("exported -> \(ipaPath)", level: .success)

        if buildCfg.skipUpload == true {
            print("")
            logger.log("upload skipped (--skip-upload). ipa ready at \(ipaPath)", level: .success)
            return
        }

        // 3. Upload via altool
        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            logger.log("credentials not configured: \(error)", level: .error)
            print("  run `storescreens auth init` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
            throw ExitCode(1)
        }
        print("  credentials: \(creds.source.rawValue) (keyID \(creds.keyID))")

        logger.header("Uploading")
        let uploader = AltoolUploader(xcode: xcode)
        try await uploader.upload(
            ipaPath: ipaPath,
            platform: platformFromDestination(resolvedDestination),
            credentials: creds,
            lineHandler: progress
        )
        print("")
        logger.log("upload complete", level: .success)
    }

    private func platformFromDestination(_ destination: String) -> AltoolUploader.Platform {
        let d = destination.lowercased()
        if d.contains("tvos") { return .tvOS }
        if d.contains("macos") || d.contains("mac os") { return .macOS }
        if d.contains("visionos") || d.contains("xros") { return .visionOS }
        return .iOS
    }

    /// Queries App Store Connect for the app's version + build state, computes
    /// the next legal tuple via `VersionResolver`, and either rewrites the
    /// Xcode project + yml (auto-bump on, default) or throws a
    /// `versionBumpNeeded` error (auto-bump off).
    ///
    /// Returns nil when creds are missing (degrade gracefully in dry-run),
    /// but throws in live mode since you can't upload without creds anyway.
    private func resolveAndMaybeBumpVersion(
        xcodeState: XcodeVersion.State,
        project: String,
        yamlPath: String,
        asc: AppStoreConnectConfig,
        buildCfg: UploadBuildConfig,
        dryRun: Bool,
        logger: Logger
    ) async throws -> VersionResolver.Resolution? {
        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            if dryRun {
                logger.log(
                    "skipping version check (credentials not configured)",
                    level: .warning
                )
                return nil
            }
            logger.log("credentials not configured: \(error)", level: .error)
            print("  run `storescreens auth init` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
            throw ExitCode(1)
        }

        // Resolve the ASC app record.
        let client = ASCClient(credentials: creds)
        let appsAPI = AppsAPI(client: client)
        let appID: String
        if let id = asc.appID {
            appID = id
        } else if let bundle = asc.bundleID {
            guard let app = try await appsAPI.lookupApp(bundleID: bundle) else {
                logger.log("no App Store Connect app matches bundle_id \(bundle)", level: .error)
                throw ExitCode(1)
            }
            appID = app.id
        } else {
            logger.log("app_store_connect needs app_id or bundle_id", level: .error)
            throw ExitCode(1)
        }

        let resolver = VersionResolver(
            appsAPI: appsAPI,
            buildsAPI: BuildsAPI(client: client)
        )
        let override = VersionResolver.Override(
            marketingVersion: buildCfg.marketingVersion,
            buildNumber: buildCfg.buildNumber
        )
        let resolution = try await resolver.resolve(
            appID: appID,
            current: xcodeState,
            override: (override.marketingVersion == nil && override.buildNumber == nil) ? nil : override
        )

        // No-op: Xcode project is already on the right tuple.
        guard resolution.changed else {
            return resolution
        }

        // Decide whether to rewrite.
        let autoBump = buildCfg.autoBump ?? true
        if !autoBump {
            let fixCmd: String
            if resolution.marketingVersion != xcodeState.marketingVersion {
                fixCmd = "agvtool new-marketing-version \(resolution.marketingVersion) && agvtool new-version -all \(resolution.buildNumber)"
            } else {
                fixCmd = "agvtool new-version -all \(resolution.buildNumber)"
            }
            logger.log(
                """
                Version/build bump required before archive.
                  Current in Xcode project: \(xcodeState.marketingVersion) (\(xcodeState.buildNumber))
                  Next legal:                \(resolution.marketingVersion) (\(resolution.buildNumber))
                  Reason: \(resolution.reason)
                Fix: drop --no-auto-bump to have storescreens do it, or run:
                  \(fixCmd)
                """,
                level: .error
            )
            throw ExitCode(1)
        }

        // Dry run stops short of actually writing.
        if dryRun {
            print("  (would bump: \(xcodeState.marketingVersion) (\(xcodeState.buildNumber)) -> \(resolution.marketingVersion) (\(resolution.buildNumber)))")
            return resolution
        }

        // Auto-bump: rewrite pbxproj, then yml.
        logger.header("Bumping version")
        print("  \(resolution.reason)")
        let changes = try XcodeVersion.write(
            projectPath: project,
            marketingVersion: resolution.marketingVersion != xcodeState.marketingVersion
                ? resolution.marketingVersion : nil,
            buildNumber: resolution.buildNumber != xcodeState.buildNumber
                ? resolution.buildNumber : nil
        )
        for change in changes {
            print("  \(change.setting): \(change.oldValue) -> \(change.newValue)")
        }
        // Sync submit.create_version in the yml so `storescreens submit`
        // stays aligned without a second manual edit.
        let yamlChanged = (try? YAMLVersionPatcher.syncCreateVersion(
            yamlPath: yamlPath, to: resolution.marketingVersion
        )) ?? false
        if yamlChanged {
            print("  synced submit.create_version in \(yamlPath)")
        }

        return resolution
    }
}

// MARK: - init

struct UploadBuildInitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Add a boilerplate `upload_build:` block to storescreens.yml and open it in your editor.",
        discussion: """
            Appends an `upload_build:` block (inside `app_store_connect:`) with \
            commented placeholders for every supported field. Opens the file in \
            $EDITOR (or your default text editor) so you can fill it in.

            Credentials (ASC API key) are separate: run `storescreens auth init` \
            if you haven't configured those yet.
            """
    )

    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml.")
    var config: String = "storescreens.yml"

    @Flag(name: .shortAndLong, help: "Replace an existing upload_build: block.")
    var force: Bool = false

    @Flag(name: .long, help: "Skip opening the file in an editor after writing.")
    var noOpen: Bool = false

    func run() async throws {
        let logger = Logger()
        let fm = FileManager.default

        guard fm.fileExists(atPath: config) else {
            logger.log("no \(config) in this directory", level: .error)
            print("  run `storescreens init` first to generate a storescreens.yml.")
            throw ExitCode(1)
        }

        let original = try String(contentsOfFile: config, encoding: .utf8)
        var lines = original.components(separatedBy: "\n")

        // Detect existing upload_build: (any indent level greater than zero).
        let existingIndex = lines.firstIndex { line in
            guard line.first == " " || line.first == "\t" else { return false }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return trimmed.hasPrefix("upload_build:")
        }

        if existingIndex != nil && !force {
            logger.log("`upload_build:` already in \(config)", level: .warning)
            print("  use `--force` to replace, or just edit the existing block.")
            if !noOpen { openInEditor(path: config) }
            return
        }

        // If --force, strip any existing upload_build block first (to a sane
        // approximation; user-edited blocks with weird indentation may need
        // manual cleanup, which is fine since they're already editing).
        if force, let start = existingIndex {
            let startIndent = leadingSpaces(lines[start])
            var end = lines.count
            for j in (start + 1)..<lines.count {
                let line = lines[j]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let ind = leadingSpaces(line)
                if ind <= startIndent {
                    end = j
                    break
                }
            }
            lines.removeSubrange(start..<end)
        }

        // Find top-level `app_store_connect:` line.
        let ascStart = lines.firstIndex(where: { $0.hasPrefix("app_store_connect:") })

        if let ascStart {
            // Find end of the app_store_connect: block.
            var ascEnd = lines.count
            for j in (ascStart + 1)..<lines.count {
                let line = lines[j]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let ind = leadingSpaces(line)
                if ind == 0 {
                    ascEnd = j
                    break
                }
            }
            // Insert right before the end. Prefix a blank line for readability.
            var inserted = [""] + boilerplateBlock.components(separatedBy: "\n")
            // Drop any trailing empty string produced by the final newline so we
            // don't leave two blank lines in the file.
            if inserted.last?.isEmpty == true { inserted.removeLast() }
            lines.insert(contentsOf: inserted, at: ascEnd)
        } else {
            // No app_store_connect block: append a minimal one with the
            // boilerplate nested inside.
            var appended = [
                "",
                "app_store_connect:",
                "  # REQUIRED: either bundle_id or app_id.",
                "  bundle_id: REPLACE_ME_com.your.bundle.id",
                "",
            ]
            appended += boilerplateBlock.components(separatedBy: "\n")
            if appended.last?.isEmpty == true { appended.removeLast() }
            lines.append(contentsOf: appended)
        }

        let updated = lines.joined(separator: "\n")
        try updated.write(toFile: config, atomically: true, encoding: .utf8)

        logger.log(
            force
                ? "replaced upload_build: block in \(config)"
                : "added upload_build: block to \(config)",
            level: .success
        )
        print("  edit the placeholders, then: storescreens upload-build --dry-run")
        if !ASCCredentialResolver.isConfigured() {
            print("  note: ASC credentials not configured. run `storescreens auth init`.")
        }

        if !noOpen { openInEditor(path: config) }
    }

    // MARK: - helpers

    private func leadingSpaces(_ s: String) -> Int {
        var n = 0
        for c in s {
            if c == " " { n += 1 } else { break }
        }
        return n
    }

    private var boilerplateBlock: String {
        """
          # === upload-build: archive + export + altool upload ===
          # Scaffolded by `storescreens upload-build init`.
          # All fields are optional and have sensible defaults; uncomment the
          # ones you need. A minimal valid block is just `upload_build: {}`.
          upload_build:
            # Scheme to archive. Falls back to top-level `scheme:` if omitted.
            # scheme: MyApp

            # Build configuration. Default: Release.
            # configuration: Release

            # "app-store" (default) | "ad-hoc" | "enterprise" | "development"
            # export_method: app-store

            # Apple Developer Team ID (10 chars). Usually only needed for manual
            # signing; automatic signing resolves the team from the archive.
            # team_id: ABCDE12345

            # "automatic" (default) or "manual".
            # signing_style: automatic

            # Manual signing only - bundle_id to provisioning profile name.
            # provisioning_profiles:
            #   com.example.app: "My App Distribution Profile"

            # Override the auto-selected non-beta Xcode. Accepts the .app path
            # or Contents/Developer. If omitted, storescreens picks the
            # highest-version non-beta Xcode under /Applications.
            # xcode_path: /Applications/Xcode.app

            # Upload dSYMs for symbolication. Default true.
            # include_symbols: true

            # Strip Swift symbols from the binary. Default true.
            # strip_swift_symbols: true

            # Path to a hand-crafted ExportOptions.plist. Overrides the
            # auto-generated one.
            # export_options_plist: ./ExportOptions.plist

            # Pass -allowProvisioningUpdates at archive + export time.
            # Default true so Xcode can create/download missing profiles.
            # allow_provisioning_updates: true

            # Archive destination. Default: generic/platform=iOS
            # destination: generic/platform=iOS

            # Where to write .xcarchive + .ipa. Default: ./build
            # output_dir: ./build

            # Archive + export + stop (skip altool upload). Default false.
            # skip_upload: false

            # Before archiving, storescreens queries ASC to check whether the
            # MARKETING_VERSION in the Xcode project is already shipped and
            # whether the build number collides with an existing TestFlight
            # build. If so, it auto-bumps the pbxproj (and syncs
            # submit.create_version). Set to false to error out instead.
            # auto_bump: true

            # Force a specific marketing version (overrides Xcode project).
            # Still validates build number against ASC TestFlight history.
            # marketing_version: "1.2.0"

            # Force a specific build number.
            # build_number: "3"
        """
    }

    private func openInEditor(path: String) {
        let env = ProcessInfo.processInfo.environment
        let task = Process()
        if let editor = env["EDITOR"], !editor.isEmpty {
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "\(editor) \(path.shellQuoted)"]
        } else {
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-t", path]
        }
        do {
            try task.run()
        } catch {
            print("  (could not open automatically: \(error.localizedDescription); open \(path) yourself)")
        }
    }
}

private extension String {
    var shellQuoted: String {
        "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
