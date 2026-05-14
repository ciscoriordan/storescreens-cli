import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Progress Events

package enum CaptureEvent: Sendable {
    case phase(String)
    case deviceLog(device: String, message: String)
    case screenshotCaptured(device: String, appStoreSlot: String, name: String, path: String)
    case deviceCompleted(device: String, count: Int)
    case deviceFailed(device: String, error: String)
    /// A preflight check finding detected before any build starts.
    /// `device` is nil for project-wide findings.
    case preflightFinding(rule: String, device: String?, message: String)
}

package typealias CaptureEventHandler = @Sendable (CaptureEvent) async -> Void

package enum CaptureMode: String, Sendable {
    case xctest
    case simple
}

// MARK: - Result

package struct CaptureResult: Sendable {
    package let manifest: CaptureManifest
    package let outputDir: URL

    package init(manifest: CaptureManifest, outputDir: URL) {
        self.manifest = manifest
        self.outputDir = outputDir
    }
}

// MARK: - Orchestrator

package struct CaptureOrchestrator: Sendable {
    package init() {}

    /// Filter file for --only flag. Contains one prefix per line.
    /// Test code reads this via SIMULATOR_HOST_HOME to skip non-matching screenshots.
    package static let screenshotFilterFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".storescreens-cache")
        .appendingPathComponent("screenshot-filter.txt")
        .path

    package func run(
        config: CaptureConfig,
        mode: CaptureMode = .xctest,
        xcresult: Bool = false,
        noParallel: Bool = false,
        retries: Int = 0,
        keepAlive: Bool = false,
        only: String? = nil,
        eventHandler: @escaping CaptureEventHandler
    ) async throws -> CaptureResult {
        // Write screenshot filter file if --only was passed, or clean it up if not
        let filterFile = Self.screenshotFilterFile
        if let only {
            let prefixes = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let filterDir = (filterFile as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: filterDir, withIntermediateDirectories: true)
            try? prefixes.joined(separator: "\n").write(toFile: filterFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: filterFile)
        }
        defer { try? FileManager.default.removeItem(atPath: filterFile) }

        switch mode {
        case .xctest:
            return try await captureXCTest(
                config: config,
                xcresult: xcresult,
                noParallel: noParallel,
                retries: retries,
                eventHandler: eventHandler
            )
        case .simple:
            return try await captureSimple(
                config: config,
                keepAlive: keepAlive,
                retries: retries,
                eventHandler: eventHandler
            )
        }
    }

    // MARK: - Static helpers

    package static let screenshotsCacheDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".storescreens-cache")

    package static let breadcrumbFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".storescreens-cache-dir")

    /// Parent directory of `screenshotFilterFile`. Lives under HOME (not cwd)
    /// because simulator-side test code reads it via `SIMULATOR_HOST_HOME`.
    /// Cleaning it up keeps `~/.storescreens-cache` from accumulating across runs.
    package static let homeFilterCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".storescreens-cache")

    package static let deviceColors = [36, 35, 33, 32] // cyan, magenta, yellow, green

    /// Removes the screenshot cache directories and breadcrumb file. Safe to
    /// call before a run starts (clears leftovers from prior failed runs) and
    /// after a successful run completes. Path arguments default to the
    /// production locations; pass explicit URLs for tests.
    package static func cleanScreenshotCache(
        cacheDir: URL? = nil,
        homeFilterDir: URL? = nil,
        breadcrumb: URL? = nil
    ) {
        let cwdCache = cacheDir ?? screenshotsCacheDir
        let homeCache = homeFilterDir ?? homeFilterCacheDir
        let crumb = breadcrumb ?? breadcrumbFile
        try? FileManager.default.removeItem(at: cwdCache)
        try? FileManager.default.removeItem(at: homeCache)
        try? FileManager.default.removeItem(at: crumb)
    }

    /// Human-readable name for a product family ID.
    package static func familyDisplayName(_ family: Int) -> String {
        switch family {
        case 1: return "iPhone"
        case 2: return "iPad"
        case 4: return "Apple Watch"
        case 6: return "Mac"
        default: return "family \(family)"
        }
    }

    // MARK: - XCTest Mode

    private func captureXCTest(
        config: CaptureConfig,
        xcresult: Bool,
        noParallel: Bool,
        retries: Int,
        eventHandler: @escaping CaptureEventHandler
    ) async throws -> CaptureResult {
        let simulatorManager = SimulatorManager()
        let buildRunner = XcodeBuildRunner(logLevel: config.logLevel.flatMap { Logger.LogLevel(rawValue: $0) } ?? .normal)
        let outputOrganizer = OutputOrganizer()

        // If a persistent DerivedData path is configured, use it directly and skip cleanup.
        // Otherwise, create a temp directory and clean it up after the run.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storescreens-\(UUID().uuidString.prefix(8))")
        let derivedData: String
        let tempDirToCleanup: URL?
        if let persistentPath = config.derivedDataPath {
            derivedData = (persistentPath as NSString).expandingTildeInPath
            tempDirToCleanup = tempDir  // still clean up temp dir (xcresult bundles), but NOT derivedData
            try FileManager.default.createDirectory(atPath: derivedData, withIntermediateDirectories: true)
        } else {
            derivedData = tempDir.appendingPathComponent("DerivedData").path
            tempDirToCleanup = tempDir
        }

        defer {
            if let dir = tempDirToCleanup {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        // 0. Check for stale DerivedData (persistent path only).
        // Surface a diagnostic so the user can act on it, but do NOT auto-clean:
        // storescreens-managed or not, deleting build products without confirmation
        // is a destructive action. If tests behave strangely the user can remove
        // <DerivedData>/Build/Products manually, or rerun after a touch.
        if config.derivedDataPath != nil {
            if Self.isDerivedDataStale(
                derivedDataPath: derivedData,
                testTarget: config.testTarget,
                project: config.project,
                workspace: config.workspace
            ) {
                let productsDir = (derivedData as NSString).appendingPathComponent("Build/Products")
                await eventHandler(.preflightFinding(
                    rule: "stale-test-bundle",
                    device: nil,
                    message: "Test sources newer than compiled test bundle; xcodebuild may produce a stale binary. Consider deleting \(productsDir) if tests behave strangely."
                ))
            }
        }

        // 1. Resolve devices
        await eventHandler(.phase("Resolving devices..."))
        let resolvedDevices = try await simulatorManager.resolveDevices(config.devices)
        for device in resolvedDevices {
            await eventHandler(.deviceLog(device: device.simulatorName, message: "\(device.simulatorName) -> \(device.appStoreSize.displayName)"))
        }

        // 1b. Check that the app's Supported Destinations match the configured devices.
        // xcodebuild silently uses an iPhone clone when the app doesn't support iPad,
        // producing 0 screenshots. Detect this early and surface it to the caller.
        // Skip this check for macOS devices (TARGETED_DEVICE_FAMILY doesn't apply).
        let nonMacDevices = resolvedDevices.filter { !$0.isMacOS }
        let detector = ProjectDetector()
        if !nonMacDevices.isEmpty,
           let supportedFamilies = await detector.detectTargetedDeviceFamilies(
            project: config.project, workspace: config.workspace, scheme: config.scheme
        ) {
            var unsupportedDevices: [String] = []
            for device in nonMacDevices {
                let family = device.appStoreSize.productFamily
                if !supportedFamilies.contains(family) {
                    let familyName = Self.familyDisplayName(family)
                    let supportedNames = supportedFamilies
                        .map { Self.familyDisplayName($0) }
                        .joined(separator: "+")
                    let message = "\(device.simulatorName): app only supports \(supportedNames) " +
                        "(TARGETED_DEVICE_FAMILY=\(supportedFamilies.map(String.init).joined(separator: ","))). " +
                        "xcodebuild will use an iPhone clone and capture 0 screenshots for this \(familyName)."
                    await eventHandler(.preflightFinding(
                        rule: "unsupported-destination",
                        device: device.simulatorName,
                        message: message
                    ))
                    unsupportedDevices.append(device.simulatorName)
                }
            }
            if !unsupportedDevices.isEmpty {
                throw CLIError.unsupportedDestinations(
                    devices: unsupportedDevices,
                    supportedFamilies: supportedFamilies
                )
            }
        }

        // Clean up stale xcodebuild simulator clones from previous runs (iOS/iPadOS only)
        for device in resolvedDevices where !device.isMacOS {
            try? await simulatorManager.deleteClonesOf(name: device.simulatorName, keepUDID: device.udid)
        }

        let outputDir = (config.outputDir as NSString).expandingTildeInPath
        let historyManager = RunHistoryManager(
            outputDir: outputDir,
            keepRuns: config.keepRuns ?? 1,
            logger: Logger()
        )
        let destination = try historyManager.prepareCaptureDirectory()
        let effectiveOutputDir = destination.writeDir

        // Set up xcodebuild log directory inside output
        let logDir = (effectiveOutputDir as NSString).appendingPathComponent("logs")
        if FileManager.default.fileExists(atPath: logDir) {
            try? FileManager.default.removeItem(atPath: logDir)
        }
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        await buildRunner.setLogDir(logDir)
        await eventHandler(.phase("logDir:\(logDir)"))

        // Determine locales to iterate (nil = no locale directories)
        let locales: [String?] = (config.locales?.isEmpty ?? true)
            ? [nil]
            : config.locales!.map { $0 as String? }

        // Determine appearances to iterate (default: both light and dark)
        let configuredAppearances = config.appearances ?? ["light", "dark"]

        var manifestDevices: [CaptureManifest.DeviceCapture] = []

        // Clear leftovers from any prior (possibly failed) run before we write
        // a fresh cache. Without this, stale device subdirs, pipes, and old
        // PNGs accumulate over time.
        Self.cleanScreenshotCache()

        // Ensure cache dir exists (for pipes and screenshots)
        try FileManager.default.createDirectory(at: Self.screenshotsCacheDir, withIntermediateDirectories: true)

        // Write breadcrumb so test code on the simulator can find the cache dir
        try Self.screenshotsCacheDir.path.write(to: Self.breadcrumbFile, atomically: true, encoding: .utf8)

        do {
            for currentLocale in locales {
                if let loc = currentLocale {
                    await eventHandler(.phase("Locale: \(loc)"))
                }

                let (testLanguage, testRegion) = parseLocale(currentLocale)

                if noParallel {
                    // Sequential: one device at a time, outer appearance loop
                    for currentAppearance in configuredAppearances {
                        await eventHandler(.phase("Appearance: \(currentAppearance)"))

                        for (index, device) in resolvedDevices.enumerated() {
                            let devName = device.simulatorName
                            let logLine: @Sendable (String) async -> Void = { msg in
                                await eventHandler(.deviceLog(device: devName, message: msg))
                            }
                            let captures = try await runDeviceAppearance(
                                device: device, logLine: logLine,
                                appearance: currentAppearance, effectiveAppearance: currentAppearance,
                                locale: currentLocale, testLanguage: testLanguage, testRegion: testRegion,
                                tempDir: tempDir, config: config, derivedDataPath: derivedData,
                                testTarget: config.testTarget, testClass: config.testClass,
                                outputOrganizer: outputOrganizer, outputDir: effectiveOutputDir,
                                screenshotFilter: config.screenshots,
                                logDir: logDir,
                                xcresult: xcresult,
                                retries: retries,
                                eventHandler: eventHandler
                            )
                            manifestDevices.append(contentsOf: captures)
                            let count = captures.reduce(0) { $0 + $1.screenshots.count }
                            await eventHandler(.deviceCompleted(device: devName, count: count))
                            _ = index
                        }
                    }
                } else {
                    // Parallel (default): each device runs all its appearances concurrently.
                    await eventHandler(.phase("Running \(resolvedDevices.count) devices in parallel..."))

                    let allCaptures = try await withThrowingTaskGroup(
                        of: [CaptureManifest.DeviceCapture].self
                    ) { group in
                        for (index, device) in resolvedDevices.enumerated() {
                            // Each device gets its own DerivedData subdirectory to prevent
                            // git submodule race conditions during parallel package resolution.
                            let baseDerivedDataURL = config.derivedDataPath != nil
                                ? URL(fileURLWithPath: derivedData)
                                : tempDir
                            let deviceDerivedData = baseDerivedDataURL
                                .appendingPathComponent("DerivedData-\(device.udid)").path
                            group.addTask {
                                let devName = device.simulatorName
                                let logLine: @Sendable (String) async -> Void = { msg in
                                    await eventHandler(.deviceLog(device: devName, message: msg))
                                }
                                var deviceCaptures: [CaptureManifest.DeviceCapture] = []
                                for currentAppearance in configuredAppearances {
                                    let captures = try await self.runDeviceAppearance(
                                        device: device,
                                        logLine: logLine,
                                        appearance: currentAppearance, effectiveAppearance: currentAppearance,
                                        locale: currentLocale, testLanguage: testLanguage, testRegion: testRegion,
                                        tempDir: tempDir, config: config, derivedDataPath: deviceDerivedData,
                                        testTarget: config.testTarget, testClass: config.testClass,
                                        outputOrganizer: outputOrganizer, outputDir: effectiveOutputDir,
                                        screenshotFilter: config.screenshots,
                                        logDir: logDir,
                                        xcresult: xcresult,
                                        retries: retries,
                                        eventHandler: eventHandler
                                    )
                                    deviceCaptures.append(contentsOf: captures)
                                }
                                let count = deviceCaptures.reduce(0) { $0 + $1.screenshots.count }
                                await eventHandler(.deviceCompleted(device: devName, count: count))
                                return deviceCaptures
                            }
                            _ = index
                        }
                        var all: [CaptureManifest.DeviceCapture] = []
                        for try await captures in group { all.append(contentsOf: captures) }
                        return all
                    }
                    manifestDevices.append(contentsOf: allCaptures)
                }
            }

            // Find app bundle for icon + display name.
            // Use first device's DerivedData (parallel mode creates per-device dirs).
            let baseDerivedDataURL = config.derivedDataPath != nil
                ? URL(fileURLWithPath: derivedData)
                : tempDir
            let firstDeviceDerivedData = resolvedDevices.first.map {
                baseDerivedDataURL.appendingPathComponent("DerivedData-\($0.udid)").path
            } ?? derivedData
            let builtAppPath = try? await buildRunner.findAppBundle(in: firstDeviceDerivedData)
            let displayName = builtAppPath.flatMap { detectDisplayName(appPath: $0) }

            // Write manifest
            let manifest = CaptureManifest(
                version: 2,
                generatedAt: Date(),
                generatedBy: "storescreens-cli \(storescreensVersion)",
                appName: config.scheme,
                displayName: displayName,
                scheme: config.scheme,
                devices: manifestDevices
            )
            try outputOrganizer.writeManifest(manifest, to: effectiveOutputDir)
            outputOrganizer.stampMtimes(
                manifest: manifest,
                outputDir: effectiveOutputDir,
                order: config.screenshots
            )
            try HTMLPreviewGenerator(localeFlags: config.localeFlags).generate(
                manifest: manifest,
                outputDir: effectiveOutputDir,
                keepOldPreviews: config.keepOldPreviews ?? false,
                screenshotOrder: config.screenshots
            )

            // Extract app icon from the built .app bundle
            if let appPath = builtAppPath {
                AppIconExtractor.extract(appBundlePath: appPath, to: effectiveOutputDir)
            }

            try historyManager.finalizeCapture(destination)

            // Clean up cache and breadcrumb
            Self.cleanScreenshotCache()

            let finalManifest = CaptureManifest(
                version: 2,
                generatedAt: Date(),
                generatedBy: "storescreens-cli \(storescreensVersion)",
                appName: config.scheme,
                displayName: displayName,
                scheme: config.scheme,
                devices: manifestDevices
            )
            let outputDirURL = URL(fileURLWithPath: (config.outputDir as NSString).expandingTildeInPath)
            return CaptureResult(manifest: finalManifest, outputDir: outputDirURL)
        } catch {
            historyManager.handleFailure(destination)
            throw error
        }
    }

    // MARK: - Per-Device Appearance Capture

    private func runDeviceAppearance(
        device: ResolvedDevice,
        logLine: @escaping @Sendable (String) async -> Void,
        appearance: String,
        effectiveAppearance: String?,
        locale: String?,
        testLanguage: String?,
        testRegion: String?,
        tempDir: URL,
        config: CaptureConfig,
        derivedDataPath: String,
        testTarget: String?,
        testClass: String?,
        outputOrganizer: OutputOrganizer,
        outputDir: String,
        screenshotFilter: [String]?,
        logDir: String?,
        xcresult: Bool,
        retries: Int,
        eventHandler: @escaping CaptureEventHandler
    ) async throws -> [CaptureManifest.DeviceCapture] {
        let buildRunner = XcodeBuildRunner(
            logLevel: config.logLevel.flatMap { Logger.LogLevel(rawValue: $0) } ?? .normal,
            logDir: logDir
        )
        let simulatorManager = SimulatorManager()

        // macOS tests run natively - skip all simulator setup
        if !device.isMacOS {
            await logLine("Booting simulator for configuration...")
            try await simulatorManager.boot(device.udid)

            if let loc = locale {
                // xcodebuild's -testLanguage / -testRegion alone aren't enough
                // to flip the AUT's locale - the AUT inherits its preferred
                // languages from the simulator's .GlobalPreferences.plist,
                // which only setLocale (plist edit + reboot) updates. Without
                // this, every per-locale iteration ends up launching the AUT
                // in whatever locale the simulator last got set to (typically
                // en-US), and screenshots all show English app UI.
                try await simulatorManager.setLocale(loc, udid: device.udid)
                await logLine("Set locale: \(loc)")
            }

            try await simulatorManager.setAppearance(appearance, udid: device.udid)
            await logLine("Set appearance: \(appearance)")

            if config.statusBar != false {
                let defaultArgs = "--time 9:41 --dataNetwork lte --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 90 --operatorName TELUS"
                let statusBarArgs = config.statusBarArguments ?? defaultArgs
                try await simulatorManager.overrideStatusBar(device.udid, arguments: statusBarArgs)
                await logLine("Status bar configured")
            }
        } else {
            await logLine("macOS target - running tests natively...")
        }

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

        let shortUDID = String(device.udid.prefix(8))
        let pipeLogPath = logDir.map { ($0 as NSString).appendingPathComponent("test-debug-\(shortUDID).log") }
        if let path = pipeLogPath {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let pipeLogHandle: FileHandle? = pipeLogPath.flatMap { FileHandle(forWritingAtPath: $0) }

        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            pipeHandle = handle
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                if let str = String(data: data, encoding: .utf8) {
                    for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
                        let msg = String(line)
                        // Write to pipe log
                        if let logData = ("[test] \(msg)\n").data(using: .utf8) {
                            pipeLogHandle?.write(logData)
                        }
                    }
                }
            }
        }

        let localeSuffix = locale.map { "-\($0)" } ?? ""
        let resultPath = tempDir
            .appendingPathComponent("\(device.udid)\(localeSuffix)-\(appearance).xcresult").path

        let liveHandler: (@Sendable (String) -> Void)?
        if isatty(STDOUT_FILENO) == 0 {
            liveHandler = { [device] line in
                Task<Void, Never> { await eventHandler(.deviceLog(device: device.simulatorName, message: line)) }
            }
        } else {
            liveHandler = nil
        }

        // Live screenshot watcher - polls deviceScreenshotsDir for new PNGs while the test runs
        // and emits screenshotCaptured events in real time. Only active in non-TTY mode (MCP/pipe
        // context) so CLI terminal output is unchanged.
        let simulatorName = device.simulatorName
        let appStoreSlot = device.appStoreSize.displayName
        let watchDir = deviceScreenshotsDir
        let liveWatcher: Task<Void, Never>? = isatty(STDOUT_FILENO) == 0 ? Task {
            actor Tracker { var seen = Set<String>(); func tryInsert(_ f: String) -> Bool { seen.insert(f).inserted } }
            let tracker = Tracker()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                let files = (try? FileManager.default.contentsOfDirectory(atPath: watchDir.path)) ?? []
                for filename in files.filter({ $0.hasSuffix(".png") }).sorted() {
                    guard await tracker.tryInsert(filename) else { continue }
                    let name = (filename as NSString).deletingPathExtension
                    await eventHandler(.screenshotCaptured(
                        device: simulatorName,
                        appStoreSlot: appStoreSlot,
                        name: name,
                        path: watchDir.appendingPathComponent(filename).path
                    ))
                }
            }
        } : nil

        // Per-device test filter overrides the top-level target/class collapse
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
            await logLine("Warmup run starting...")
            try? FileManager.default.removeItem(atPath: resultPath)
            _ = try? await buildRunner.test(
                project: config.project,
                workspace: config.workspace,
                scheme: config.scheme,
                destinationUDID: device.udid,
                derivedDataPath: derivedDataPath,
                resultBundlePath: resultPath,
                testTarget: testTarget,
                testClass: testClass,
                testSelectors: testSelectors,
                testLanguage: testLanguage,
                testRegion: testRegion,
                isMacOS: device.isMacOS,
                liveLineHandler: liveHandler
            )
            // Discard warmup screenshots so the real run starts with a clean slate
            try? FileManager.default.removeItem(at: deviceScreenshotsDir)
            try? FileManager.default.createDirectory(at: deviceScreenshotsDir, withIntermediateDirectories: true)
            await logLine("Warmup run complete - starting real capture...")
        }

        try await withRetries(retries, label: device.simulatorName, logLine: logLine) {
            try? FileManager.default.removeItem(atPath: resultPath)
            _ = try await buildRunner.test(
                project: config.project,
                workspace: config.workspace,
                scheme: config.scheme,
                destinationUDID: device.udid,
                derivedDataPath: derivedDataPath,
                resultBundlePath: resultPath,
                testTarget: testTarget,
                testClass: testClass,
                testSelectors: testSelectors,
                testLanguage: testLanguage,
                testRegion: testRegion,
                isMacOS: device.isMacOS,
                liveLineHandler: liveHandler
            )
        }

        // Parse the xcresult for real pass/fail counts. xcodebuild exits non-zero on
        // assertion failures but still writes the xcresult, and the failure messages
        // (including file:line) only live there, not in stdout. Extract them now so
        // the status surface reflects actual test outcomes instead of "xcodebuild exited".
        var testSummary: XCTestSummary?
        var legacyFailureSummaries: [String] = []
        if FileManager.default.fileExists(atPath: resultPath) {
            let xcresultParser = XCResultParser()
            testSummary = await xcresultParser.extractTestSummary(resultBundlePath: resultPath)
            // Fallback: the legacy object graph gives file:line for each assertion,
            // which the modern summary JSON does not. Capture it as a secondary detail
            // source so we can surface it even if the new schema parse fails.
            legacyFailureSummaries = await xcresultParser.extractFailureSummaries(resultBundlePath: resultPath)
            for failure in legacyFailureSummaries {
                await logLine("⚠️  Test failure: \(failure)")
            }
        }

        // Stop async handler, then drain any remaining buffered data synchronously.
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
                    await logLine(String(line))
                }
            }
        }
        liveWatcher?.cancel()

        // Emit a status line that reflects what actually happened, not just
        // "xcodebuild exited". If the summary parse succeeded, we report real
        // pass/fail counts; otherwise we fall back to the old neutral message.
        if let summary = testSummary {
            if summary.hasFailures {
                await logLine("✗ Tests failed [\(appearance)]: \(summary.failedTests) of \(summary.totalTests)")
                for failure in summary.failures {
                    let firstLine = failure.failureText
                        .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                        .first.map(String.init) ?? failure.failureText
                    await logLine("  ✗ \(failure.testName): \(firstLine)")
                }
            } else if summary.totalTests > 0 {
                await logLine("✓ Tests passed [\(appearance)]: \(summary.passedTests) of \(summary.totalTests)")
            } else {
                await logLine("✓ Tests completed [\(appearance)] (0 tests reported in xcresult)")
            }
        } else {
            await logLine("✓ Tests completed [\(appearance)]")
        }

        try? pipeHandle?.close()
        try? pipeLogHandle?.close()
        unlink(pipePath)

        await logLine("Extracting screenshots [\(appearance)]...")
        await logLine("  xcresult path: \(resultPath)")
        await logLine("  xcresult exists: \(FileManager.default.fileExists(atPath: resultPath))")

        var screenshots: [CaptureManifest.Screenshot] = []
        if xcresult && FileManager.default.fileExists(atPath: resultPath) {
            await logLine("  Extracting from xcresult...")
            let xcresultParser = XCResultParser()
            let rawExportDir = (tempDir.path as NSString)
                .appendingPathComponent("xcresult-export-\(device.udid)-\(appearance)")
            do {
                let attachments = try await xcresultParser.exportAttachments(
                    resultBundlePath: resultPath,
                    outputPath: rawExportDir
                )
                await logLine("  xcresult attachments: \(attachments.count) test details")
                screenshots = try await outputOrganizer.organize(
                    attachments: attachments,
                    rawExportDir: rawExportDir,
                    outputDir: outputDir,
                    device: device,
                    locale: locale,
                    appearance: effectiveAppearance,
                    screenshotFilter: screenshotFilter,
                    onScreenshotSaved: { name, _ in
                        await eventHandler(.screenshotCaptured(
                            device: device.simulatorName,
                            appStoreSlot: device.appStoreSize.displayName,
                            name: name,
                            path: ""
                        ))
                    }
                )
            } catch {
                await logLine("  xcresult extraction failed: \(error)")
            }
        } else {
            // Filesystem mode (default)
            // In non-TTY mode the live watcher already emitted screenshotCaptured events
            // for each PNG as it appeared during the test run - suppress duplicates here.
            let onSaved: @Sendable (String, String) async -> Void = isatty(STDOUT_FILENO) == 0
                ? { @Sendable _, _ in }
                : { @Sendable name, _ in
                    await eventHandler(.screenshotCaptured(
                        device: device.simulatorName,
                        appStoreSlot: device.appStoreSize.displayName,
                        name: name,
                        path: ""
                    ))
                }
            screenshots = try await outputOrganizer.organizeFromFilesystem(
                screenshotsDir: deviceScreenshotsDir.path,
                simulatorName: device.simulatorName,
                outputDir: outputDir,
                device: device,
                locale: locale,
                appearance: effectiveAppearance,
                screenshotFilter: screenshotFilter,
                onScreenshotSaved: onSaved
            )
            await logLine("  Found \(screenshots.count) screenshots via filesystem")
        }
        await logLine("✓ \(screenshots.count) screenshots")

        // Fail loudly if no screenshots were collected. Pick the error variant that
        // actually matches what we observed in the xcresult so the message points at
        // the right root cause, not a generic "simulator in bad state" red herring.
        if screenshots.isEmpty {
            if let summary = testSummary, summary.hasFailures {
                // Prefer the legacy assertion summaries (they include file:line); fall
                // back to the modern summary's failureText if the legacy parse was empty.
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

        return [CaptureManifest.DeviceCapture(
            deviceType: device.appStoreSize.deviceTypeRawValue,
            simulatorName: device.simulatorName,
            locale: locale,
            appearance: effectiveAppearance,
            screenshots: screenshots
        )]
    }

    // MARK: - Simple Mode

    private func captureSimple(
        config: CaptureConfig,
        keepAlive: Bool,
        retries: Int,
        eventHandler: @escaping CaptureEventHandler
    ) async throws -> CaptureResult {
        let simulatorManager = SimulatorManager()
        let buildRunner = XcodeBuildRunner(logLevel: config.logLevel.flatMap { Logger.LogLevel(rawValue: $0) } ?? .normal)
        let outputOrganizer = OutputOrganizer()

        // If a persistent DerivedData path is configured, use it directly and skip cleanup.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storescreens-\(UUID().uuidString.prefix(8))")
        let derivedData: String
        let tempDirToCleanup: URL?
        if let persistentPath = config.derivedDataPath {
            derivedData = (persistentPath as NSString).expandingTildeInPath
            tempDirToCleanup = tempDir
            try FileManager.default.createDirectory(atPath: derivedData, withIntermediateDirectories: true)
        } else {
            derivedData = tempDir.appendingPathComponent("DerivedData").path
            tempDirToCleanup = tempDir
        }

        defer {
            if let dir = tempDirToCleanup {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        // 1. Resolve devices
        await eventHandler(.phase("Resolving devices..."))
        let resolvedDevices = try await simulatorManager.resolveDevices(config.devices)
        for device in resolvedDevices {
            await eventHandler(.deviceLog(device: device.simulatorName, message: "\(device.simulatorName) -> \(device.appStoreSize.displayName)"))
        }

        guard let firstDevice = resolvedDevices.first else {
            throw CLIError.noDevicesConfigured
        }

        let outputDir = (config.outputDir as NSString).expandingTildeInPath
        let historyManager = RunHistoryManager(
            outputDir: outputDir,
            keepRuns: config.keepRuns ?? 1,
            logger: Logger()
        )
        let destination = try historyManager.prepareCaptureDirectory()
        let effectiveOutputDir = destination.writeDir

        let logDir = (effectiveOutputDir as NSString).appendingPathComponent("logs")
        if FileManager.default.fileExists(atPath: logDir) {
            try? FileManager.default.removeItem(atPath: logDir)
        }
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        await buildRunner.setLogDir(logDir)

        // 2. Build
        await eventHandler(.phase("Building..."))
        let appPath = try await buildRunner.build(
            project: config.project,
            workspace: config.workspace,
            scheme: config.scheme,
            destinationUDID: firstDevice.udid,
            derivedDataPath: derivedData
        )
        await eventHandler(.phase("Build succeeded"))

        // Detect bundle ID from Info.plist
        let bundleId = detectBundleId(appPath: appPath) ?? config.scheme

        let locales: [String?] = (config.locales?.isEmpty ?? true)
            ? [nil]
            : config.locales!.map { $0 as String? }

        let configuredAppearances = config.appearances ?? ["light", "dark"]

        var manifestDevices: [CaptureManifest.DeviceCapture] = []

        do {
            for currentLocale in locales {
                if let loc = currentLocale {
                    await eventHandler(.phase("Locale: \(loc)"))
                }

                for currentAppearance in configuredAppearances {
                    await eventHandler(.phase("Appearance: \(currentAppearance)"))

                    for (index, device) in resolvedDevices.enumerated() {
                        let devName = device.simulatorName
                        await eventHandler(.phase("Capturing on \(devName) [\(index + 1)/\(resolvedDevices.count)]..."))

                        let retryLogLine: @Sendable (String) async -> Void = { msg in
                            await eventHandler(.deviceLog(device: devName, message: msg))
                        }

                        try await withRetries(retries, label: devName, logLine: retryLogLine) {
                            try await simulatorManager.boot(device.udid)

                            if let loc = currentLocale {
                                try await simulatorManager.setLocale(loc, udid: device.udid)
                            }

                            try await simulatorManager.setAppearance(currentAppearance, udid: device.udid)

                            if config.statusBar != false {
                                let defaultArgs = "--time 9:41 --dataNetwork lte --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 90 --operatorName TELUS"
                                let statusBarArgs = config.statusBarArguments ?? defaultArgs
                                try await simulatorManager.overrideStatusBar(device.udid, arguments: statusBarArgs)
                            }

                            try await simulatorManager.install(device.udid, appPath: appPath)

                            let launchArgs = config.launchArguments ?? ["--uitesting"]
                            try await simulatorManager.launch(device.udid, bundleId: bundleId, arguments: launchArgs)

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
                                appearance: currentAppearance
                            )

                            manifestDevices.append(CaptureManifest.DeviceCapture(
                                deviceType: device.appStoreSize.deviceTypeRawValue,
                                simulatorName: device.simulatorName,
                                locale: currentLocale,
                                appearance: currentAppearance,
                                screenshots: [screenshot]
                            ))

                            await eventHandler(.screenshotCaptured(
                                device: devName,
                                appStoreSlot: device.appStoreSize.displayName,
                                name: screenshotName,
                                path: screenshot.filename
                            ))
                        }

                        if !keepAlive {
                            try? await simulatorManager.shutdown(device.udid)
                        }
                    }
                }
            }

            let simpleDisplayName = detectDisplayName(appPath: appPath)

            let manifest = CaptureManifest(
                version: 2,
                generatedAt: Date(),
                generatedBy: "storescreens-cli \(storescreensVersion)",
                appName: config.scheme,
                displayName: simpleDisplayName,
                scheme: config.scheme,
                devices: manifestDevices
            )
            try outputOrganizer.writeManifest(manifest, to: effectiveOutputDir)
            outputOrganizer.stampMtimes(
                manifest: manifest,
                outputDir: effectiveOutputDir,
                order: config.screenshots
            )
            try HTMLPreviewGenerator(localeFlags: config.localeFlags).generate(
                manifest: manifest,
                outputDir: effectiveOutputDir,
                keepOldPreviews: config.keepOldPreviews ?? false,
                screenshotOrder: config.screenshots
            )

            AppIconExtractor.extract(appBundlePath: appPath, to: effectiveOutputDir)

            try historyManager.finalizeCapture(destination)
        } catch {
            historyManager.handleFailure(destination)
            throw error
        }

        Self.cleanScreenshotCache()

        let totalScreenshots = manifestDevices.reduce(0) { $0 + $1.screenshots.count }
        await eventHandler(.phase("Done! \(totalScreenshots) screenshots saved to \(config.outputDir)"))

        let finalManifest = CaptureManifest(
            version: 2,
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

    // MARK: - Stale DerivedData Detection

    /// Check if persistent DerivedData has stale test binaries (compiled from older source).
    /// When test source files are newer than the compiled test runner, xcodebuild may use
    /// the stale binary and run wrong/deleted test methods. Returns true if stale.
    ///
    /// - Parameters:
    ///   - derivedDataPath: Expanded path to the persistent DerivedData directory
    ///   - testTarget: Name of the UI test target (e.g. "MyAppUITests")
    ///   - project: Xcode project path (optional)
    ///   - workspace: Xcode workspace path (optional)
    package static func isDerivedDataStale(
        derivedDataPath: String,
        testTarget: String?,
        project: String? = nil,
        workspace: String? = nil
    ) -> Bool {
        guard let testTarget else { return false }

        // Find the compiled test runner binary
        let fm = FileManager.default
        let productsDir = (derivedDataPath as NSString).appendingPathComponent("Build/Products")
        guard fm.fileExists(atPath: productsDir) else { return false }

        // Look for the test runner .app in Debug-iphonesimulator or Debug (macOS)
        let runnerName = "\(testTarget)-Runner.app"
        let searchDirs = [
            (productsDir as NSString).appendingPathComponent("Debug-iphonesimulator"),
            (productsDir as NSString).appendingPathComponent("Debug"),
        ]
        let runnerPath = searchDirs
            .map { ($0 as NSString).appendingPathComponent(runnerName) }
            .first { fm.fileExists(atPath: $0) }

        guard let runnerPath, fm.fileExists(atPath: runnerPath) else { return false }

        // Find the newest file in the runner bundle
        guard let runnerMtime = newestFileDate(inDirectory: runnerPath) else { return false }

        // Find test source files
        let projectDir: String
        if let proj = project {
            projectDir = (proj as NSString).deletingLastPathComponent
        } else if let ws = workspace {
            projectDir = (ws as NSString).deletingLastPathComponent
        } else {
            projectDir = fm.currentDirectoryPath
        }

        let testDir = (projectDir as NSString).appendingPathComponent(testTarget)
        guard fm.fileExists(atPath: testDir) else { return false }

        // Check if any .swift file in the test target is newer than the compiled runner
        guard let sourceFiles = try? fm.contentsOfDirectory(atPath: testDir) else { return false }
        for file in sourceFiles where file.hasSuffix(".swift") {
            let filePath = (testDir as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: filePath),
               let mtime = attrs[.modificationDate] as? Date,
               mtime > runnerMtime {
                return true
            }
        }

        return false
    }

    /// Returns the newest modification date of any file inside a directory (recursive).
    private static func newestFileDate(inDirectory path: String) -> Date? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return nil }
        var newest: Date?
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let mtime = attrs[.modificationDate] as? Date {
                if newest == nil || mtime > newest! {
                    newest = mtime
                }
            }
        }
        return newest
    }

    /// Clean DerivedData Build/Products directory to force a fresh build.
    package static func cleanDerivedData(at path: String) {
        let productsDir = (path as NSString).appendingPathComponent("Build/Products")
        try? FileManager.default.removeItem(atPath: productsDir)
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
        return (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
    }

    /// Parse a locale string into (language, region).
    /// "en-US" → ("en", "US"), "ja" → ("ja", nil), "zh-Hans-CN" → ("zh-Hans", "CN")
    private func parseLocale(_ locale: String?) -> (language: String?, region: String?) {
        guard let locale else { return (nil, nil) }
        let parts = locale.split(separator: "-")
        if parts.count >= 2 {
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
        logLine: @escaping @Sendable (String) async -> Void,
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
                    await logLine("⚠ Attempt \(attempt + 1) failed on \(label), retrying... (\(error.localizedDescription))")
                }
            }
        }
        throw lastError!
    }
}

// storescreensVersion is generated from the VERSION file by the GenerateVersion build plugin.
