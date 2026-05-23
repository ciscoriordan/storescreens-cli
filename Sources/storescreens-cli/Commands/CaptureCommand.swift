import StorescreensCore
import ArgumentParser
import Foundation

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Capture screenshots from iOS simulators and macOS."
    )

    @Option(name: .shortAndLong, help: "Capture mode: 'xctest' (default) or 'simple'.")
    var mode: CaptureMode = .xctest

    @Option(name: .shortAndLong, help: "Path to storescreens.yml config file.")
    var config: String = "storescreens.yml"

    @Option(name: .shortAndLong, help: "Output directory for screenshots.")
    var output: String?

    @Option(name: .long, help: "Xcode project path (overrides config).")
    var project: String?

    @Option(name: .long, help: "Xcode workspace path (overrides config).")
    var workspace: String?

    @Option(name: .long, help: "Xcode scheme (overrides config).")
    var scheme: String?

    @Option(name: .shortAndLong, help: "Locales to capture (overrides config). Can be repeated: --locale en-US --locale ja")
    var locale: [String] = []

    @Option(name: .shortAndLong, help: "Appearances to capture (overrides config). Can be repeated: --appearance light --appearance dark")
    var appearance: [String] = []

    @Option(name: .long, help: "Number of retries on test failure per device (default: 0).")
    var retries: Int = 0

    @Flag(name: .long, help: "Keep simulators running after capture.")
    var keepAlive: Bool = false

    @Flag(name: .long, help: "Run devices sequentially instead of in parallel (one device at a time).")
    var noParallel: Bool = false

    @Flag(name: .long, help: "Skip preflight source code check.")
    var skipCheck: Bool = false

    @Flag(name: .long, help: "Extract screenshots from the .xcresult bundle instead of the filesystem.")
    var xcresult: Bool = false

    @Flag(name: .long, help: "Show verbose xcodebuild output.")
    var verbose: Bool = false

    @Option(name: .long, help: "Only capture screenshots matching these prefixes (comma-separated). Example: --only 14,18")
    var only: String?

    @Flag(name: .long, help: "Skip the post-capture upload prompt.")
    var noUpload: Bool = false

    @Flag(name: .long, help: "Skip the post-capture render pass.")
    var noRender: Bool = false

    @Flag(name: .long, help: "Skip the post-capture App Store search preview render.")
    var noSearchPreview: Bool = false

    @Option(name: .long, help: "Persistent DerivedData directory for faster incremental builds. Reused across runs; created on first use.")
    var derivedDataPath: String?

    struct CaptureResult {
        let manifest: CaptureManifest
        let outputDir: URL
    }

    func run() async throws {
        let logger = Logger(isVerbose: verbose)

        let binaryPath = ProcessInfo.processInfo.arguments.first ?? "unknown"
        logger.log("storescreens v\(storescreensVersion) (\(binaryPath))", level: .info)

        // Load config
        let configLoader = ConfigLoader()
        var captureConfig = try configLoader.load(from: config)

        // CLI flags override config
        if let project { captureConfig.project = project }
        if let workspace { captureConfig.workspace = workspace }
        if let scheme { captureConfig.scheme = scheme }
        if let output { captureConfig.outputDir = output }
        if !locale.isEmpty { captureConfig.locales = locale }
        if !appearance.isEmpty { captureConfig.appearances = appearance }
        if let derivedDataPath { captureConfig.derivedDataPath = derivedDataPath }

        guard captureConfig.project != nil || captureConfig.workspace != nil else {
            throw CLIError.noProjectOrWorkspace
        }

        // Preflight source code check
        if !skipCheck && captureConfig.preflight != false {
            let deviceContext = CheckCommand.deviceContext(from: captureConfig)

            let projectDir: String
            if let proj = captureConfig.project {
                projectDir = (proj as NSString).deletingLastPathComponent
            } else if let ws = captureConfig.workspace {
                projectDir = (ws as NSString).deletingLastPathComponent
            } else {
                projectDir = "."
            }
            let scanDir = projectDir.isEmpty ? "." : projectDir

            logger.header("Preflight Check")
            let scanner = PreflightScanner()
            let result = scanner.scan(directory: scanDir, deviceContext: deviceContext)
            PreflightScanner.printFindings(result, logger: logger, projectDir: scanDir)

            if result.hasErrors {
                throw CLIError.preflightFailed(
                    errorCount: result.errors.count,
                    warningCount: result.warnings.count
                )
            }
            if result.findings.isEmpty {
                logger.log("No issues found", level: .success)
            }
        }

        // Write screenshot filter file if --only was passed, or clean it up if not
        let filterFile = Self.screenshotFilterFile
        if let only {
            let prefixes = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let filterDir = (filterFile as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: filterDir, withIntermediateDirectories: true)
            try prefixes.joined(separator: "\n").write(toFile: filterFile, atomically: true, encoding: .utf8)
            logger.log("Screenshot filter: only capturing names matching \(prefixes.joined(separator: ", "))", level: .info)
        } else {
            try? FileManager.default.removeItem(atPath: filterFile)
        }
        defer { try? FileManager.default.removeItem(atPath: filterFile) }

        let result: CaptureResult
        switch mode {
        case .xctest:
            result = try await captureXCTest(config: captureConfig, logger: logger)
        case .simple:
            result = try await captureSimple(config: captureConfig, logger: logger)
        }

        // Render pass — composites captioned screenshots when enabled.
        // Runs after capture succeeds; render failures don't destroy the raw captures.
        // Shared with the MCP server so both entry points produce
        // identical framed PNGs + raw/framed preview toggle.
        let baseDirectory = URL(fileURLWithPath: self.config).deletingLastPathComponent().standardized
        await PostCaptureRunner().runIfEnabled(
            captureConfig: captureConfig,
            manifest: result.manifest,
            capturedRoot: result.outputDir,
            baseDirectory: baseDirectory,
            skip: noRender,
            skipSearchPreview: noSearchPreview,
            logger: { msg in
                // Map the runner's prefix convention back onto the
                // CLI's Logger levels so the console output matches
                // the pre-refactor behavior.
                if msg.hasPrefix("● ") {
                    logger.header(String(msg.dropFirst(2)))
                } else if msg.hasPrefix("✓ ") {
                    logger.log(String(msg.dropFirst(2)), level: .success)
                } else if msg.hasPrefix("✗ ") {
                    logger.log(String(msg.dropFirst(2)), level: .error)
                } else if msg.hasPrefix("⚠ ") {
                    logger.log(String(msg.dropFirst(2)), level: .warning)
                } else {
                    print(msg)
                }
            }
        )

        // Offer to upload to storescreens.app (opt-in via config, override with --no-upload)
        if !noUpload && captureConfig.upload == true {
            let prompt = UploadPrompt(
                manifest: result.manifest,
                outputDir: result.outputDir,
                logger: logger
            )
            await prompt.run()
        }
    }

    /// Project-local cache directory for screenshots and named pipes.
    /// Test code discovers this path via the breadcrumb at ~/.storescreens-cache-dir.
    private static let screenshotsCacheDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".storescreens-cache")

    /// Breadcrumb file so simulator-hosted test code can find the cache dir on the host.
    /// Must match the path read by ScreenshotTests.swift.template (~/.storescreens-cache-dir).
    private static let breadcrumbFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".storescreens-cache-dir")

    /// Filter file for --only flag. Contains one prefix per line.
    /// Test code reads this via SIMULATOR_HOST_HOME to skip non-matching screenshots.
    private static let screenshotFilterFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".storescreens-cache")
        .appendingPathComponent("screenshot-filter.txt")
        .path

    /// Per-iteration locale hint, written by storescreens-cli before each
    /// capture iteration and read by the test bundle's setUpWithError so it
    /// can forward `-AppleLanguages` / `-AppleLocale` to the AUT via
    /// XCUIApplication.launchArguments. Empty file means "no locale" (the
    /// test should not override).
    private static let currentLocaleFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".storescreens-cache")
        .appendingPathComponent("current-locale.txt")
        .path

    /// Writes the active locale (or empties the file) so the test bundle
    /// can pick it up via the breadcrumb chain in setUpWithError.
    private static func writeCurrentLocaleHint(_ locale: String?) {
        let dir = (currentLocaleFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (locale ?? "").write(toFile: currentLocaleFile, atomically: true, encoding: .utf8)
    }

    /// ANSI color codes cycled per device for distinguishing log output.
    private static let deviceColors = [36, 35, 33, 32] // cyan, magenta, yellow, green

    // MARK: - XCTest Mode

    @discardableResult
    private func captureXCTest(config: CaptureConfig, logger: Logger) async throws -> CaptureResult {
        let simulatorManager = SimulatorManager()
        let buildRunner = XcodeBuildRunner(verbose: verbose)
        let outputOrganizer = OutputOrganizer()

        // If a persistent DerivedData path is configured, use it directly and skip cleanup.
        // Otherwise, create a temp directory and clean it up after the run.
        let tempDir: URL
        let derivedData: String
        let tempDirToCleanup: URL?
        if let persistentPath = config.derivedDataPath {
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("storescreens-\(UUID().uuidString.prefix(8))")
            derivedData = (persistentPath as NSString).expandingTildeInPath
            tempDirToCleanup = tempDir  // still clean up the temp dir (for xcresult bundles), but NOT derivedData
            try FileManager.default.createDirectory(atPath: derivedData, withIntermediateDirectories: true)
        } else {
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("storescreens-\(UUID().uuidString.prefix(8))")
            derivedData = tempDir.appendingPathComponent("DerivedData").path
            tempDirToCleanup = tempDir
        }

        defer {
            if let dir = tempDirToCleanup {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        // 0. Check for stale DerivedData (persistent path only).
        // Surface a diagnostic so the user can act on it, but do NOT auto-clean: deleting
        // build products without confirmation is destructive. If tests behave strangely
        // the user can remove <DerivedData>/Build/Products manually and rerun.
        if config.derivedDataPath != nil {
            if CaptureOrchestrator.isDerivedDataStale(
                derivedDataPath: derivedData,
                testTarget: config.testTarget,
                project: config.project,
                workspace: config.workspace
            ) {
                let productsDir = (derivedData as NSString).appendingPathComponent("Build/Products")
                logger.log(
                    "⚑ Test sources newer than compiled test bundle; xcodebuild may produce a stale binary. Consider deleting \(productsDir) if tests behave strangely.",
                    level: .warning
                )
            }
        }

        // 1. Resolve devices
        logger.header("Resolving devices...")
        let resolvedDevices = try await simulatorManager.resolveDevices(config.devices)
        for device in resolvedDevices {
            logger.log("\(device.simulatorName) -> \(device.appStoreSize.displayName)", level: .success)
        }

        let outputDir = (config.outputDir as NSString).expandingTildeInPath
        let historyManager = RunHistoryManager(
            outputDir: outputDir, keepRuns: config.keepRuns ?? 1, logger: logger
        )
        let destination = try historyManager.prepareCaptureDirectory()
        let effectiveOutputDir = destination.writeDir

        // Set up xcodebuild log directory inside output (clean slate)
        let logDir = (effectiveOutputDir as NSString).appendingPathComponent("logs")
        if FileManager.default.fileExists(atPath: logDir) {
            try? FileManager.default.removeItem(atPath: logDir)
        }
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        await buildRunner.setLogDir(logDir)

        // Determine locales to iterate (nil = no locale directories)
        let locales: [String?] = (config.locales?.isEmpty ?? true)
            ? [nil]
            : config.locales!.map { $0 as String? }

        // Determine appearances to iterate (default: both light and dark).
        let topLevelAppearances = config.appearances ?? ["light", "dark"]

        // Per-slide appearance overrides. When ANY slide has an override, we
        // switch to "per-slide mode": each slide is captured exactly once in
        // its effective appearance (override or top-level), output goes to a
        // flat folder (no `<appearance>/` subdir), and each manifest entry
        // carries its own `appearance`. Without overrides, the legacy
        // multiplier behavior is preserved (cross-product captures + the
        // `<locale>/<appearance>/` subfolder layout).
        let perSlideAppearances: [String: String] =
            (config.render?.slides ?? [:]).compactMapValues { $0.appearance }
        let perSlideMode = !perSlideAppearances.isEmpty

        // Distinct appearances we actually need to capture in. In legacy
        // mode this is just `topLevelAppearances`. In per-slide mode it's
        // the union of top-level appearances plus any override values not
        // already in top-level.
        let configuredAppearances: [String] = {
            guard perSlideMode else { return topLevelAppearances }
            var out: [String] = []
            var seen = Set<String>()
            for a in topLevelAppearances + Array(perSlideAppearances.values) {
                if !seen.contains(a) { out.append(a); seen.insert(a) }
            }
            return out
        }()
        let multipleAppearances = !perSlideMode && configuredAppearances.count > 1

        var manifestDevices: [CaptureManifest.DeviceCapture] = []

        // Clear leftovers from any prior (possibly failed) run before we write
        // a fresh cache. Without this, stale device subdirs, pipes, and old
        // PNGs accumulate in `<cwd>/.storescreens-cache` and `~/.storescreens-cache`
        // over time.
        CaptureOrchestrator.cleanScreenshotCache()

        // Ensure top-level screenshots cache dir exists (for pipes and screenshots)
        try FileManager.default.createDirectory(at: Self.screenshotsCacheDir, withIntermediateDirectories: true)

        // Write breadcrumb so test code running on the simulator can find the cache dir
        try Self.screenshotsCacheDir.path.write(to: Self.breadcrumbFile, atomically: true, encoding: .utf8)

        // Build once before running tests on any device.
        // This ensures source changes are compiled exactly once and all devices
        // use the same build products (avoids race conditions with parallel xcodebuild test).
        let hasMacDevices = resolvedDevices.contains { $0.isMacOS }
        let hasIOSDevices = resolvedDevices.contains { !$0.isMacOS }

        var xctestrunPath = ""
        if hasIOSDevices {
            logger.header("Building for testing (iOS)...")
            xctestrunPath = try await buildRunner.buildForTesting(
                project: config.project,
                workspace: config.workspace,
                scheme: config.scheme,
                derivedDataPath: derivedData,
                isMacOS: false
            )
            logger.log("iOS build complete", level: .success)
        }
        if hasMacDevices {
            logger.header("Building for testing (macOS)...")
            let macXctestrunPath = try await buildRunner.buildForTesting(
                project: config.project,
                workspace: config.workspace,
                scheme: config.scheme,
                derivedDataPath: derivedData,
                isMacOS: true
            )
            if xctestrunPath.isEmpty { xctestrunPath = macXctestrunPath }
            logger.log("macOS build complete", level: .success)
        }

        do {
            for currentLocale in locales {
                if let loc = currentLocale {
                    logger.header("Locale: \(loc)")
                }

                let (testLanguage, testRegion) = parseLocale(currentLocale)

                if noParallel {
                    // Sequential: one device at a time, outer appearance loop
                    for currentAppearance in configuredAppearances {
                        if multipleAppearances {
                            logger.header("Appearance: \(currentAppearance)")
                        }
                        let effectiveAppearance: String? = perSlideMode
                            ? nil
                            : (multipleAppearances ? currentAppearance : nil)
                        let filterForRun = filteredScreenshots(
                            for: currentAppearance, all: config.screenshots,
                            perSlideAppearances: perSlideAppearances,
                            topLevelAppearances: topLevelAppearances,
                            perSlideMode: perSlideMode
                        )

                        for (index, device) in resolvedDevices.enumerated() {
                            let colorCode = Self.deviceColors[index % Self.deviceColors.count]
                            let devName = device.simulatorName
                            let logLine: @Sendable (String) -> Void = { msg in
                                print("  \u{001B}[\(colorCode)m▸\u{001B}[0m [\(devName)] \(msg)")
                                fflush(stdout)
                            }
                            let captures = try await runDeviceAppearance(
                                device: device, logLine: logLine,
                                appearance: currentAppearance, effectiveAppearance: effectiveAppearance,
                                perSlideAppearance: perSlideMode ? currentAppearance : nil,
                                locale: currentLocale, testLanguage: testLanguage, testRegion: testRegion,
                                tempDir: tempDir, config: config, derivedDataPath: derivedData,
                                xctestrunPath: xctestrunPath,
                                testTarget: config.testTarget, testClass: config.testClass,
                                outputOrganizer: outputOrganizer, outputDir: effectiveOutputDir,
                                screenshotFilter: filterForRun,
                                logDir: logDir
                            )
                            manifestDevices.append(contentsOf: captures)
                        }
                    }
                } else {
                    // Parallel (default): each device runs all its appearances concurrently.
                    let usePanel = isatty(STDOUT_FILENO) != 0
                    if resolvedDevices.count > 1 {
                        logger.header("Running \(resolvedDevices.count) devices in parallel...")
                    }
                    let panelDevices = resolvedDevices.enumerated().map { (index, device) in
                        (name: device.simulatorName, colorCode: Self.deviceColors[index % Self.deviceColors.count])
                    }
                    let panel: ParallelStatusPanel? = usePanel
                        ? ParallelStatusPanel(devices: panelDevices, logDir: Self.screenshotsCacheDir.path)
                        : nil
                    panel?.start()
                    let allCaptures = try await withThrowingTaskGroup(
                        of: [CaptureManifest.DeviceCapture].self
                    ) { group in
                        for (index, device) in resolvedDevices.enumerated() {
                            group.addTask {
                                let colorCode = Self.deviceColors[index % Self.deviceColors.count]
                                let devName = device.simulatorName
                                let logLine: @Sendable (String) -> Void
                                if let panel {
                                    logLine = { msg in panel.update(deviceIndex: index, message: msg) }
                                } else {
                                    // Non-TTY: simple line-by-line output (works in piped/CI environments)
                                    logLine = { msg in
                                        print("  \u{001B}[\(colorCode)m▸\u{001B}[0m [\(devName)] \(msg)")
                                        fflush(stdout)
                                    }
                                }
                                var deviceCaptures: [CaptureManifest.DeviceCapture] = []
                                for currentAppearance in configuredAppearances {
                                    let effectiveAppearance: String? = perSlideMode
                                        ? nil
                                        : (multipleAppearances ? currentAppearance : nil)
                                    let filterForRun = self.filteredScreenshots(
                                        for: currentAppearance, all: config.screenshots,
                                        perSlideAppearances: perSlideAppearances,
                                        topLevelAppearances: topLevelAppearances,
                                        perSlideMode: perSlideMode
                                    )
                                    if perSlideMode, filterForRun?.isEmpty == true {
                                        // No slides resolve to this appearance; skip the run.
                                        continue
                                    }
                                    let captures = try await self.runDeviceAppearance(
                                        device: device,
                                        logLine: logLine,
                                        appearance: currentAppearance, effectiveAppearance: effectiveAppearance,
                                        perSlideAppearance: perSlideMode ? currentAppearance : nil,
                                        locale: currentLocale, testLanguage: testLanguage, testRegion: testRegion,
                                        tempDir: tempDir, config: config, derivedDataPath: derivedData,
                                        xctestrunPath: xctestrunPath,
                                        testTarget: config.testTarget, testClass: config.testClass,
                                        outputOrganizer: outputOrganizer, outputDir: effectiveOutputDir,
                                        screenshotFilter: filterForRun,
                                        logDir: logDir
                                    )
                                    deviceCaptures.append(contentsOf: captures)
                                }
                                return deviceCaptures
                            }
                        }
                        var all: [CaptureManifest.DeviceCapture] = []
                        for try await captures in group { all.append(contentsOf: captures) }
                        return all
                    }
                    panel?.finalize()
                    manifestDevices.append(contentsOf: allCaptures)
                }
            }

            // Find app bundle for icon + display name
            let builtAppPath = try? await buildRunner.findAppBundle(in: derivedData)
            let displayName = builtAppPath.flatMap { detectDisplayName(appPath: $0) }

            // Write manifest
            let hasLocales = config.locales?.isEmpty == false
            let manifest = CaptureManifest(
                version: hasLocales || multipleAppearances ? 2 : 1,
                generatedAt: Date(),
                generatedBy: "storescreens-cli \(storescreensVersion)",
                appName: config.scheme,
                displayName: displayName,
                scheme: config.scheme,
                devices: manifestDevices
            )
            try outputOrganizer.writeManifest(manifest, to: effectiveOutputDir)
            try HTMLPreviewGenerator(localeFlags: config.localeFlags).generate(manifest: manifest, outputDir: effectiveOutputDir, keepOldPreviews: config.keepOldPreviews ?? false, screenshotOrder: config.screenshots)

            // Extract app icon from the built .app bundle
            if let appPath = builtAppPath {
                if AppIconExtractor.extract(appBundlePath: appPath, to: effectiveOutputDir) != nil {
                    logger.log("Extracted app icon", level: .success)
                }
            }

            try historyManager.finalizeCapture(destination)

            // Clean up the screenshot cache and breadcrumb on success.
            // (On failure we deliberately leave them for debugging; the next
            // run starts by clearing leftovers.)
            CaptureOrchestrator.cleanScreenshotCache()
        } catch {
            historyManager.handleFailure(destination)
            throw error
        }

        let totalScreenshots = manifestDevices.reduce(0) { $0 + $1.screenshots.count }
        logger.header("Done! \(totalScreenshots) screenshots saved to \(config.outputDir)")
        let previewPath = (effectiveOutputDir as NSString).appendingPathComponent("preview.html")
        logger.log("Preview: \(previewPath)", level: .info)
        openInBrowser(path: previewPath)

        let builtAppPathFinal = try? await buildRunner.findAppBundle(in: derivedData)
        let displayNameFinal = builtAppPathFinal.flatMap { detectDisplayName(appPath: $0) }

        let finalManifest = CaptureManifest(
            version: (config.locales?.isEmpty == false) || multipleAppearances ? 2 : 1,
            generatedAt: Date(),
            generatedBy: "storescreens-cli \(storescreensVersion)",
            appName: config.scheme,
            displayName: displayNameFinal,
            scheme: config.scheme,
            devices: manifestDevices
        )
        let outputDirURL = URL(fileURLWithPath: (config.outputDir as NSString).expandingTildeInPath)
        return CaptureResult(manifest: finalManifest, outputDir: outputDirURL)
    }

    // MARK: - Per-slide appearance helpers

    /// Returns the screenshot list filtered to the slides that should be
    /// captured in the given appearance. In legacy mode (no per-slide
    /// overrides), the full list applies to every appearance. In per-slide
    /// mode, a slide is included if its override matches the appearance,
    /// or it has no override and the appearance is in the top-level list.
    fileprivate func filteredScreenshots(
        for appearance: String,
        all: [String]?,
        perSlideAppearances: [String: String],
        topLevelAppearances: [String],
        perSlideMode: Bool
    ) -> [String]? {
        guard perSlideMode else { return all }
        guard let all else { return nil }
        return all.filter { name in
            if let override = perSlideAppearances[name] {
                return override == appearance
            }
            return topLevelAppearances.contains(appearance)
        }
    }

    // MARK: - Per-Device Appearance Capture

    /// Runs tests for one device × one appearance and returns the captured screenshots.
    /// Uses `xcodebuild test-without-building` with a pre-built xctestrun file.
    /// Building is done once upfront in captureXCTest to ensure source changes are always compiled.
    private func runDeviceAppearance(
        device: ResolvedDevice,
        logLine: @escaping @Sendable (String) -> Void,
        appearance: String,
        effectiveAppearance: String?,
        perSlideAppearance: String?,
        locale: String?,
        testLanguage: String?,
        testRegion: String?,
        tempDir: URL,
        config: CaptureConfig,
        derivedDataPath: String,
        xctestrunPath: String,
        testTarget: String?,
        testClass: String?,
        outputOrganizer: OutputOrganizer,
        outputDir: String,
        screenshotFilter: [String]?,
        logDir: String?
    ) async throws -> [CaptureManifest.DeviceCapture] {
        // Each call gets its own actor instances so concurrent calls don't serialize on a shared actor
        let buildRunner = XcodeBuildRunner(verbose: verbose, logDir: logDir)

        // Write the active locale to a cache file the test bundle reads on
        // setUp. Adopts fastlane snapshot's pattern: rather than mutating
        // the simulator's GlobalPreferences (which only takes effect after
        // a reboot and rapidly destabilises iPad clones), we let the test
        // forward `-AppleLanguages` / `-AppleLocale` directly to the AUT
        // via XCUIApplication.launchArguments. The AUT's NSLocale picks up
        // the override on launch and renders in the right locale, no
        // simulator state changes needed.
        Self.writeCurrentLocaleHint(locale)

        // Note: appearance/status bar are not pre-configured because xcodebuild test
        // boots its own clone simulator. To set appearance, use test launch arguments
        // or UITraitCollection overrides in test code.

        // Device-specific screenshot subdir avoids conflicts during parallel runs
        let deviceScreenshotsDir = Self.screenshotsCacheDir.appendingPathComponent(device.simulatorName)
        try? FileManager.default.removeItem(at: deviceScreenshotsDir)
        try FileManager.default.createDirectory(at: deviceScreenshotsDir, withIntermediateDirectories: true)

        // Named pipe for real-time log output (lives in top-level cache dir)
        let pipePath = Self.screenshotsCacheDir
            .appendingPathComponent("storescreens-\(device.simulatorName).pipe").path
        unlink(pipePath)
        mkfifo(pipePath, 0o644)
        let fd = open(pipePath, O_RDWR | O_NONBLOCK)
        var pipeHandle: FileHandle?
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            pipeHandle = handle
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                if let str = String(data: data, encoding: .utf8) {
                    for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
                        logLine(String(line))
                    }
                }
            }
        }

        let localeSuffix = locale.map { "-\($0)" } ?? ""
        let resultPath = tempDir
            .appendingPathComponent("\(device.udid)\(localeSuffix)-\(appearance).xcresult").path

        // Per-device tests filter overrides the top-level target/class collapse
        // when set. The shared resolver turns bare method names into fully
        // qualified Target/Class/method selectors.
        let testSelectors = resolvedTestSelectors(
            entries: device.tests,
            testTarget: testTarget,
            testClass: testClass
        )

        // If warmupRun is enabled, run the test once as a warmup (discard screenshots),
        // then run again for real captures.
        if config.warmupRun == true {
            logLine("Warmup run starting...")
            try? FileManager.default.removeItem(atPath: resultPath)
            _ = try? await buildRunner.testWithoutBuilding(
                xctestrunPath: xctestrunPath,
                destinationUDID: device.udid,
                resultBundlePath: resultPath,
                testTarget: testTarget,
                testClass: testClass,
                testSelectors: testSelectors,
                testLanguage: testLanguage,
                testRegion: testRegion,
                isMacOS: device.isMacOS
            )
            // Discard warmup screenshots so the real run starts with a clean slate
            try? FileManager.default.removeItem(at: deviceScreenshotsDir)
            try? FileManager.default.createDirectory(at: deviceScreenshotsDir, withIntermediateDirectories: true)
            logLine("Warmup run complete - starting real capture...")
        }

        try await withRetries(retries, label: device.simulatorName, logLine: logLine) {
            try? FileManager.default.removeItem(atPath: resultPath)
            _ = try await buildRunner.testWithoutBuilding(
                xctestrunPath: xctestrunPath,
                destinationUDID: device.udid,
                resultBundlePath: resultPath,
                testTarget: testTarget,
                testClass: testClass,
                testSelectors: testSelectors,
                testLanguage: testLanguage,
                testRegion: testRegion,
                isMacOS: device.isMacOS
            )
        }
        // Parse the xcresult for real pass/fail counts before we tell the user "done".
        // xcodebuild exits non-zero on assertion failures but still writes the xcresult,
        // and the failure messages (including file:line) only live there, not in stdout.
        let xcresultParser = XCResultParser()
        var testSummary: XCTestSummaryCLI?
        var legacyFailureSummaries: [String] = []
        if FileManager.default.fileExists(atPath: resultPath) {
            testSummary = await xcresultParser.extractTestSummary(resultBundlePath: resultPath)
            legacyFailureSummaries = await xcresultParser.extractFailureSummaries(resultBundlePath: resultPath)
            for failure in legacyFailureSummaries {
                logLine("⚠️  Test failure: \(failure)")
            }
        }

        // Stop async handler, then drain any remaining buffered data synchronously.
        // (O_NONBLOCK: read() returns EAGAIN immediately when the buffer is empty.)
        pipeHandle?.readabilityHandler = nil
        if let fd = pipeHandle?.fileDescriptor, fd >= 0 {
            var drained = Data()
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { ptr in
                    Darwin.read(fd, ptr.baseAddress!, ptr.count)
                }
                guard n > 0 else { break }
                drained.append(contentsOf: buf[..<n])
            }
            if !drained.isEmpty, let str = String(data: drained, encoding: .utf8) {
                for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
                    logLine(String(line))
                }
            }
        }

        // Emit a status line reflecting actual test outcomes, not just "xcodebuild exited".
        if let summary = testSummary {
            if summary.hasFailures {
                logLine("✗ Tests failed [\(appearance)]: \(summary.failedTests) of \(summary.totalTests)")
                for failure in summary.failures {
                    let firstLine = failure.failureText
                        .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                        .first.map(String.init) ?? failure.failureText
                    logLine("  ✗ \(failure.testName): \(firstLine)")
                }
            } else if summary.totalTests > 0 {
                logLine("✓ Tests passed [\(appearance)]: \(summary.passedTests) of \(summary.totalTests)")
            } else {
                logLine("✓ Tests completed [\(appearance)] (0 tests reported in xcresult)")
            }
        } else {
            logLine("✓ Tests completed [\(appearance)]")
        }

        try? pipeHandle?.close()
        unlink(pipePath)

        logLine("Extracting screenshots [\(appearance)]...")
        logLine("  xcresult path: \(resultPath)")
        logLine("  xcresult exists: \(FileManager.default.fileExists(atPath: resultPath))")

        // Extract screenshots - filesystem (default) or xcresult (--xcresult flag)
        var screenshots: [CaptureManifest.Screenshot] = []
        if xcresult && FileManager.default.fileExists(atPath: resultPath) {
            // xcresult mode: extract named attachments from the .xcresult bundle
            logLine("  Extracting from xcresult...")
            let rawExportDir = (tempDir.path as NSString)
                .appendingPathComponent("xcresult-export-\(device.udid)-\(appearance)")
            do {
                let attachments = try await xcresultParser.exportAttachments(
                    resultBundlePath: resultPath,
                    outputPath: rawExportDir
                )
                logLine("  xcresult attachments: \(attachments.count) test details")
                for detail in attachments {
                    logLine("    test: \(detail.testIdentifier) - \(detail.attachments.count) attachments")
                    for att in detail.attachments {
                        logLine("      → \(att.suggestedHumanReadableName) [\(att.exportedFileName)]")
                    }
                }
                screenshots = try outputOrganizer.organize(
                    attachments: attachments,
                    rawExportDir: rawExportDir,
                    outputDir: outputDir,
                    device: device,
                    locale: locale,
                    appearance: effectiveAppearance,
                    screenshotFilter: screenshotFilter
                )
            } catch {
                logLine("  xcresult extraction failed: \(error)")
            }
        } else {
            // Filesystem mode (default): collect PNGs written directly by the test
            screenshots = try outputOrganizer.organizeFromFilesystem(
                screenshotsDir: deviceScreenshotsDir.path,
                simulatorName: device.simulatorName,
                outputDir: outputDir,
                device: device,
                locale: locale,
                appearance: effectiveAppearance,
                screenshotFilter: screenshotFilter
            )
            logLine("  Found \(screenshots.count) screenshots via filesystem")
        }
        // Fail loudly if no screenshots were captured, and make the message match reality:
        // if the xcresult shows test failures, name them; if all tests passed, point at
        // the breadcrumb mechanism; otherwise fall back to the generic simulator-state hint.
        if screenshots.isEmpty {
            if let summary = testSummary, summary.hasFailures {
                let detailed = legacyFailureSummaries.isEmpty
                    ? summary.failures.map { failure -> String in
                        let firstLine = failure.failureText
                            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                            .first.map(String.init) ?? failure.failureText
                        return "\(failure.testName): \(firstLine)"
                    }
                    : legacyFailureSummaries
                throw CLIError.noScreenshotsTestFailures(
                    device: device.simulatorName,
                    totalTests: summary.totalTests,
                    failedTests: summary.failedTests,
                    failureSummaries: detailed
                )
            }
            if let summary = testSummary, summary.totalTests > 0, summary.failedTests == 0 {
                throw CLIError.noScreenshotsAllTestsPassed(
                    device: device.simulatorName,
                    totalTests: summary.totalTests,
                    cacheDir: deviceScreenshotsDir.path
                )
            }
            throw CLIError.noScreenshotsFound(device: device.simulatorName)
        }
        logLine("✓ \(screenshots.count) screenshots")

        // In per-slide mode each shot carries its own appearance so the
        // renderer + submit can pick the right `{ light:, dark: }` variant
        // even though the DeviceCapture's appearance field is nil (flat
        // output layout).
        let stampedScreenshots: [CaptureManifest.Screenshot] = perSlideAppearance.map { app in
            screenshots.map {
                CaptureManifest.Screenshot(name: $0.name, filename: $0.filename, capturedAt: $0.capturedAt, appearance: app)
            }
        } ?? screenshots
        return [CaptureManifest.DeviceCapture(
            deviceType: device.appStoreSize.deviceTypeRawValue,
            simulatorName: device.simulatorName,
            locale: locale,
            appearance: effectiveAppearance,
            screenshots: stampedScreenshots
        )]
    }

    // MARK: - Simple Mode

    @discardableResult
    private func captureSimple(config: CaptureConfig, logger: Logger) async throws -> CaptureResult {
        let simulatorManager = SimulatorManager()
        let buildRunner = XcodeBuildRunner(verbose: verbose)
        let outputOrganizer = OutputOrganizer()

        // If a persistent DerivedData path is configured, use it directly and skip cleanup.
        // Otherwise, create a temp directory and clean it up after the run.
        let tempDir: URL
        let derivedData: String
        let tempDirToCleanup: URL?
        if let persistentPath = config.derivedDataPath {
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("storescreens-\(UUID().uuidString.prefix(8))")
            derivedData = (persistentPath as NSString).expandingTildeInPath
            tempDirToCleanup = tempDir
            try FileManager.default.createDirectory(atPath: derivedData, withIntermediateDirectories: true)
        } else {
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("storescreens-\(UUID().uuidString.prefix(8))")
            derivedData = tempDir.appendingPathComponent("DerivedData").path
            tempDirToCleanup = tempDir
        }

        defer {
            if let dir = tempDirToCleanup {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        // 0. Check for stale DerivedData (persistent path only). Warn only, no auto-clean.
        if config.derivedDataPath != nil {
            if CaptureOrchestrator.isDerivedDataStale(
                derivedDataPath: derivedData,
                testTarget: config.testTarget,
                project: config.project,
                workspace: config.workspace
            ) {
                let productsDir = (derivedData as NSString).appendingPathComponent("Build/Products")
                logger.log(
                    "⚑ Test sources newer than compiled test bundle; xcodebuild may produce a stale binary. Consider deleting \(productsDir) if tests behave strangely.",
                    level: .warning
                )
            }
        }

        // 1. Resolve devices
        logger.header("Resolving devices...")
        let resolvedDevices = try await simulatorManager.resolveDevices(config.devices)
        for device in resolvedDevices {
            logger.log("\(device.simulatorName) -> \(device.appStoreSize.displayName)", level: .success)
        }

        let outputDir = (config.outputDir as NSString).expandingTildeInPath
        let historyManager = RunHistoryManager(
            outputDir: outputDir, keepRuns: config.keepRuns ?? 1, logger: logger
        )
        let destination = try historyManager.prepareCaptureDirectory()
        let effectiveOutputDir = destination.writeDir

        // Set up xcodebuild log directory inside output
        let logDir = (effectiveOutputDir as NSString).appendingPathComponent("logs")
        await buildRunner.setLogDir(logDir)

        // Simple mode does not support macOS devices (no simulator to install/launch into)
        let macDevices = resolvedDevices.filter { $0.isMacOS }
        if !macDevices.isEmpty {
            logger.log("Simple mode does not support macOS devices. Use xctest mode instead: storescreens capture --mode xctest", level: .error)
            logger.log("macOS devices skipped: \(macDevices.map(\.simulatorName).joined(separator: ", "))", level: .info)
        }
        let simulatorDevices = resolvedDevices.filter { !$0.isMacOS }
        guard let firstDevice = simulatorDevices.first else {
            throw CLIError.noDevicesConfigured
        }

        // 2. Build
        logger.header("Building...")
        let appPath = try await buildRunner.build(
            project: config.project,
            workspace: config.workspace,
            scheme: config.scheme,
            destinationUDID: firstDevice.udid,
            derivedDataPath: derivedData
        )
        logger.log("Build succeeded", level: .success)

        // Detect bundle ID from Info.plist
        let bundleId = detectBundleId(appPath: appPath) ?? config.scheme

        let locales: [String?] = (config.locales?.isEmpty ?? true)
            ? [nil]
            : config.locales!.map { $0 as String? }

        let configuredAppearances = config.appearances ?? ["light", "dark"]
        let multipleAppearances = configuredAppearances.count > 1

        var manifestDevices: [CaptureManifest.DeviceCapture] = []

        do {
            // 3. For each locale × appearance, capture on each device
            for currentLocale in locales {
                if let loc = currentLocale {
                    logger.header("Locale: \(loc)")
                }

                for currentAppearance in configuredAppearances {
                    if multipleAppearances {
                        logger.header("Appearance: \(currentAppearance)")
                    }

                    let effectiveAppearance: String? = multipleAppearances ? currentAppearance : nil

                    for (index, device) in simulatorDevices.enumerated() {
                        let localeLabel = currentLocale.map { " [\($0)]" } ?? ""
                        let appearanceLabel = multipleAppearances ? " [\(currentAppearance)]" : ""
                        logger.header("Capturing on \(device.simulatorName)\(localeLabel)\(appearanceLabel) [\(index + 1)/\(simulatorDevices.count)]...")

                        let devName = device.simulatorName
                        let retryLogLine: @Sendable (String) -> Void = { msg in
                            print("  ! [\(devName)] \(msg)")
                        }
                        try await withRetries(retries, label: device.simulatorName, logLine: retryLogLine) {
                            try await simulatorManager.boot(device.udid)
                            logger.log("Booted", level: .success)

                            // Set locale if needed (reboots the simulator)
                            if let loc = currentLocale {
                                try await simulatorManager.setLocale(loc, udid: device.udid)
                                logger.log("Set locale to \(loc)", level: .success)
                            }

                            // Set appearance (no reboot needed)
                            try await simulatorManager.setAppearance(currentAppearance, udid: device.udid)

                            // Override status bar if configured
                            if config.statusBar != false {
                                let defaultArgs = "--time 9:41 --dataNetwork lte --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 90 --operatorName TELUS"
                                let statusBarArgs = config.statusBarArguments ?? defaultArgs
                                try await simulatorManager.overrideStatusBar(device.udid, arguments: statusBarArgs)
                            }

                            try await simulatorManager.install(device.udid, appPath: appPath)
                            logger.log("Installed app", level: .success)

                            let launchArgs = config.launchArguments ?? ["--uitesting"]
                            try await simulatorManager.launch(device.udid, bundleId: bundleId, arguments: launchArgs)
                            logger.log("Launched app", level: .success)

                            // Wait for app to render
                            try await Task.sleep(for: .seconds(3))

                            let screenshotName = "screenshot_\(String(format: "%03d", index + 1))"
                            let tempScreenshot = tempDir.appendingPathComponent("\(screenshotName).png").path

                            try await simulatorManager.takeScreenshot(device.udid, outputPath: tempScreenshot)

                            let screenshot = try outputOrganizer.organizeSimpleScreenshot(
                                sourcePath: tempScreenshot,
                                name: screenshotName,
                                outputDir: effectiveOutputDir,
                                device: device,
                                locale: currentLocale,
                                appearance: effectiveAppearance
                            )

                            manifestDevices.append(CaptureManifest.DeviceCapture(
                                deviceType: device.appStoreSize.deviceTypeRawValue,
                                simulatorName: device.simulatorName,
                                locale: currentLocale,
                                appearance: effectiveAppearance,
                                screenshots: [screenshot]
                            ))
                            logger.log("Screenshot captured", level: .success)
                        }

                        if !keepAlive {
                            try? await simulatorManager.shutdown(device.udid)
                        }
                    }
                }
            }

            let simpleDisplayName = detectDisplayName(appPath: appPath)

            // Write manifest
            let hasLocales = config.locales?.isEmpty == false
            let manifest = CaptureManifest(
                version: hasLocales || multipleAppearances ? 2 : 1,
                generatedAt: Date(),
                generatedBy: "storescreens-cli \(storescreensVersion)",
                appName: config.scheme,
                displayName: simpleDisplayName,
                scheme: config.scheme,
                devices: manifestDevices
            )
            try outputOrganizer.writeManifest(manifest, to: effectiveOutputDir)
            try HTMLPreviewGenerator(localeFlags: config.localeFlags).generate(manifest: manifest, outputDir: effectiveOutputDir, keepOldPreviews: config.keepOldPreviews ?? false, screenshotOrder: config.screenshots)

            // Extract app icon from the built .app bundle
            if AppIconExtractor.extract(appBundlePath: appPath, to: effectiveOutputDir) != nil {
                logger.log("Extracted app icon", level: .success)
            }

            // Finalize: swap staging into place or update symlink
            try historyManager.finalizeCapture(destination)
        } catch {
            historyManager.handleFailure(destination)
            throw error
        }

        let totalScreenshots = manifestDevices.reduce(0) { $0 + $1.screenshots.count }
        logger.header("Done! \(totalScreenshots) screenshots saved to \(config.outputDir)")
        let previewPath = (effectiveOutputDir as NSString).appendingPathComponent("preview.html")
        logger.log("Preview: \(previewPath)", level: .info)
        openInBrowser(path: previewPath)

        let finalManifest = CaptureManifest(
            version: (config.locales?.isEmpty == false) || multipleAppearances ? 2 : 1,
            generatedAt: Date(),
            generatedBy: "storescreens-cli \(storescreensVersion)",
            appName: config.scheme,
            displayName: detectDisplayName(appPath: appPath),
            scheme: config.scheme,
            devices: manifestDevices
        )
        let outputDirURL = URL(fileURLWithPath: (config.outputDir as NSString).expandingTildeInPath)
        return CaptureResult(manifest: finalManifest, outputDir: outputDirURL)
    }

    // MARK: - Helpers

    private func detectBundleId(appPath: String) -> String? {
        let plistPath = (appPath as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String else {
            return nil
        }
        return bundleId
    }

    private func detectDisplayName(appPath: String) -> String? {
        let plistPath = (appPath as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        // CFBundleDisplayName takes priority, then CFBundleName
        return (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
    }

    /// Parse a locale string into (language, region).
    /// "en-US" → ("en", "US"), "ja" → ("ja", nil), "zh-Hans-CN" → ("zh-Hans", "CN")
    private func parseLocale(_ locale: String?) -> (language: String?, region: String?) {
        guard let locale else { return (nil, nil) }
        let parts = locale.split(separator: "-")
        if parts.count >= 2 {
            // Handle script subtags like "zh-Hans-CN" → language="zh-Hans", region="CN"
            let region = String(parts.last!)
            let language = parts.dropLast().joined(separator: "-")
            return (language, region)
        }
        return (String(parts[0]), nil)
    }

    /// Retry an async operation up to `count` additional times on failure.
    private func withRetries(
        _ count: Int,
        label: String,
        logLine: @escaping @Sendable (String) -> Void,
        operation: () async throws -> Void
    ) async throws {
        var lastError: Error?
        for attempt in 0...count {
            do {
                try await operation()
                return
            } catch {
                lastError = error
                if attempt < count {
                    logLine("⚠ Attempt \(attempt + 1) failed on \(label), retrying... (\(error.localizedDescription))")
                }
            }
        }
        throw lastError!
    }

    private func openInBrowser(path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        try? process.run()
    }
}

// MARK: - Parallel Status Panel

/// Shows a rolling tail of the last `tailLines` log lines per device during parallel runs,
/// then prints each device's full log history when finalized. Also writes each device's
/// complete log to a file in `logDir` (if provided) for `tail -f` monitoring.
///
/// Screen layout during run (tailLines=20, N=2 devices):
///
///   (blank line)
///   ── [iPhone 17 Pro] ────────────────────────
///   ▸ [iPhone 17 Pro] [3/11] Statistics
///   ▸ [iPhone 17 Pro] Switched to Settings tab
///   ... (up to 20 lines, older lines scroll off)
///   ── [iPad Pro 13-inch (M5)] ────────────────
///   ▸ [iPad Pro 13-inch (M5)] [2/11] CountryPicker
///   ... (up to 20 lines)
///   ^cursor
///
/// ANSI cursor math (tailLines=T, N devices):
///   - start() reserves 1 + N*(1+T) lines: blank + N*(header + T tail lines)
///   - update(idx): linesUp = (N-idx)*(1+T)-1  to reach idx's tail block start
///                  linesDown = (N-idx-1)*(1+T)+1  to return cursor to bottom
///   - finalize(): moves up 1+N*(1+T) lines, clears to end, prints full histories
private final class ParallelStatusPanel: @unchecked Sendable {
    private let tailLines = 20
    private let devices: [(name: String, colorCode: Int)]
    private var buffers: [[String]]
    private var logHandles: [FileHandle?]
    private let lock = NSLock()

    init(devices: [(name: String, colorCode: Int)], logDir: String? = nil) {
        self.devices = devices
        self.buffers = Array(repeating: [], count: devices.count)
        if let logDir {
            self.logHandles = devices.map { d in
                let path = (logDir as NSString).appendingPathComponent("\(d.name).log")
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }
        } else {
            self.logHandles = Array(repeating: nil, count: devices.count)
        }
    }

    /// Prints a blank line + section header + tailLines empty rows per device.
    /// Cursor ends up below the last device's tail block.
    func start() {
        print("")
        for d in devices {
            let div = String(repeating: "─", count: 28)
            print("  \u{001B}[\(d.colorCode)m\(div) [\(d.name)] \(div)\u{001B}[0m")
            for _ in 0..<tailLines { print("") }
        }
        fflush(stdout)
    }

    /// Buffers the message, writes it to the log file, and redraws the device's
    /// tail block in place. Thread-safe: called concurrently from multiple tasks.
    func update(deviceIndex idx: Int, message: String) {
        lock.lock(); defer { lock.unlock() }
        buffers[idx].append(message)
        if let handle = logHandles[idx], let data = (message + "\n").data(using: .utf8) {
            handle.write(data)
        }
        let d = devices[idx]
        let n = devices.count
        // Move up to the start of this device's tail block
        let linesUp = (n - idx) * (1 + tailLines) - 1
        // Tail: pad with empty lines at top, messages fill from bottom
        let recent = Array(buffers[idx].suffix(tailLines))
        let padding = tailLines - recent.count
        var out = "\u{001B}[\(linesUp)A"
        for i in 0..<tailLines {
            out += "\u{001B}[2K\r"
            if i >= padding {
                out += "  \u{001B}[\(d.colorCode)m▸\u{001B}[0m [\(d.name)] \(recent[i - padding])"
            }
            if i < tailLines - 1 { out += "\n" }
        }
        // Move cursor back to the bottom of the reserved area
        let linesDown = (n - idx - 1) * (1 + tailLines) + 1
        out += "\u{001B}[\(linesDown)B\r"
        print(out, terminator: "")
        fflush(stdout)
    }

    /// Closes log files, then replaces the tail area with each device's full
    /// log history in a clean sectioned layout.
    func finalize() {
        lock.lock(); defer { lock.unlock() }
        for handle in logHandles.compactMap({ $0 }) { try? handle.close() }
        let n = devices.count
        // Move up past all reserved lines (blank + N*(header+tail)) and clear to end of screen
        let totalLinesUp = 1 + n * (1 + tailLines)
        print("\u{001B}[\(totalLinesUp)A\u{001B}[0J", terminator: "")
        for (i, d) in devices.enumerated() {
            let div = String(repeating: "─", count: 28)
            print("")
            print("  \u{001B}[\(d.colorCode)m\(div) [\(d.name)] \(div)\u{001B}[0m")
            for msg in buffers[i] {
                print("  \u{001B}[\(d.colorCode)m▸\u{001B}[0m [\(d.name)] \(msg)")
            }
        }
        fflush(stdout)
    }
}

enum CaptureMode: String, ExpressibleByArgument, Sendable {
    case xctest
    case simple
}
