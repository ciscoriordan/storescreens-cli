import MCP
import Foundation
import StorescreensCore

// MARK: - Async Task Store

/// Tracks in-progress and completed capture tasks.
/// `capture` starts a background task and returns the taskId immediately.
/// `get_capture_status` polls this store for live progress.
actor AsyncTaskStore {
    static let shared = AsyncTaskStore()

    enum TaskState {
        case running(startedAt: Date, lastEventAt: Date, totalEventCount: Int, events: [String], logDir: String?)
        case completed(captureId: String, summary: String, isError: Bool)
        case failed(error: String, events: [String])
    }

    private var tasks: [String: TaskState] = [:]

    func start(taskId: String) {
        let now = Date()
        tasks[taskId] = .running(startedAt: now, lastEventAt: now, totalEventCount: 0, events: [], logDir: nil)
    }

    func setLogDir(taskId: String, logDir: String) {
        guard case .running(let start, let lastEvent, let count, let events, _) = tasks[taskId] else { return }
        tasks[taskId] = .running(startedAt: start, lastEventAt: lastEvent, totalEventCount: count, events: events, logDir: logDir)
    }

    func appendEvent(taskId: String, line: String) {
        guard case .running(let start, _, let count, var events, let logDir) = tasks[taskId] else { return }
        events.append(line)
        tasks[taskId] = .running(startedAt: start, lastEventAt: Date(), totalEventCount: count + 1, events: events, logDir: logDir)
    }

    func complete(taskId: String, captureId: String, summary: String, isError: Bool) {
        tasks[taskId] = .completed(captureId: captureId, summary: summary, isError: isError)
    }

    func fail(taskId: String, error: String) {
        let events: [String]
        if case .running(_, _, _, let e, _) = tasks[taskId] { events = e } else { events = [] }
        tasks[taskId] = .failed(error: error, events: events)
    }

    func state(_ taskId: String) -> TaskState? { tasks[taskId] }
}

// MARK: - Result Cache

/// In-memory store for completed capture results (manifests).
/// Lets `get_capture_result` fetch the full manifest on demand.
actor ResultCache {
    static let shared = ResultCache()

    struct Entry {
        let manifest: CaptureManifest
        let outputDir: URL
        let events: [String]
        let capturedAt: Date
    }

    private var captures: [String: Entry] = [:]
    private let maxEntries = 5

    func store(id: String, entry: Entry) {
        captures[id] = entry
        if captures.count > maxEntries {
            let oldest = captures.min { $0.value.capturedAt < $1.value.capturedAt }?.key
            if let key = oldest { captures.removeValue(forKey: key) }
        }
    }

    func get(id: String) -> Entry? { captures[id] }
}

// MARK: - Server

@main
struct StorescreensMCP {
    static func main() async throws {
        let server = Server(
            name: "storescreens",
            version: storescreensVersion,
            capabilities: Server.Capabilities(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await Self.handle(params, server: server)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    /// All tools exposed by the MCP server: the built-in capture/render/preview
    /// tools defined in this file plus every family of ASC API tools defined
    /// alongside this file in `Tools/`. Each family's tools are appended in a
    /// stable order; the dispatch code further down routes incoming calls to
    /// the matching family handler.
    static let tools: [Tool] = baseTools
        + TestFlightMCPTools.tools
        + InAppPurchasesMCPTools.tools
        + SubscriptionsMCPTools.tools
        + CustomerReviewsMCPTools.tools
        + ReportsMCPTools.tools
        + UsersAndDevPortalMCPTools.tools
        + MarketingMCPTools.tools
        + GameCenterMCPTools.tools
        + XcodeCloudMCPTools.tools
        + AltDistributionMCPTools.tools
        + ApplePayAndMiscMCPTools.tools
        + WebhooksMCPTools.tools
        + BuildUploadsMCPTools.tools
        + AccessibilityDeclarationsMCPTools.tools
        + BackgroundAssetsMCPTools.tools
        + GameCenterActivitiesMCPTools.tools
        + BetaFeedbackAndExtrasMCPTools.tools
        + Wave4ExtrasMCPTools.tools
        + ReviewSubmissionsMCPTools.tools
        + PricingMCPTools.tools
        + TranslateMCPTools.tools

    static let baseTools: [Tool] = [
        Tool(
            name: "capture",
            description: """
            Run App Store screenshot capture. Boots simulators, runs UI tests, and collects screenshots.
            Returns a compact summary with a captureId. Call get_capture_result(captureId) to get the \
            full manifest and per-screenshot paths if needed.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "config_path": .object([
                        "type": .string("string"),
                        "description": .string("Path to storescreens.yml (default: storescreens.yml)"),
                    ]),
                    "directory": .object([
                        "type": .string("string"),
                        "description": .string("Working directory to run capture from (default: current directory)"),
                    ]),
                    "derived_data_path": .object([
                        "type": .string("string"),
                        "description": .string("Persistent DerivedData directory for faster incremental builds. Reused across runs; overrides storescreens.yml."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "get_capture_status",
            description: """
            Poll the status of a running or completed capture. Returns live progress events \
            while running, or the final summary when done. Call repeatedly until status is \
            'completed' or 'failed'. Use the taskId returned by capture.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "task_id": .object([
                        "type": .string("string"),
                        "description": .string("The taskId returned by the capture tool"),
                    ]),
                ]),
                "required": .array([.string("task_id")]),
            ])
        ),
        Tool(
            name: "get_capture_result",
            description: """
            Retrieve the full manifest and event log from a completed capture. \
            Use the captureId from get_capture_status once the capture is done.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "capture_id": .object([
                        "type": .string("string"),
                        "description": .string("The captureId returned by the capture tool"),
                    ]),
                ]),
                "required": .array([.string("capture_id")]),
            ])
        ),
        Tool(
            name: "check",
            description: """
            Scan Swift source files for issues that will cause screenshot capture to fail or produce \
            incorrect results. Returns structured findings grouped by severity (error/warning), with \
            file path and line number. Errors block capture; warnings should be reviewed.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "directory": .object([
                        "type": .string("string"),
                        "description": .string("Directory to scan (default: current directory)"),
                    ]),
                    "config_path": .object([
                        "type": .string("string"),
                        "description": .string("Path to storescreens.yml for device context (default: storescreens.yml)"),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "list_simulators",
            description: """
            List available iOS simulators that can be used for App Store screenshot capture. \
            Grouped by App Store slot. Use these names in the devices section of storescreens.yml.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "list_screenshots",
            description: """
            List screenshots from the last capture run. Returns device, App Store slot, name, and \
            file path for each screenshot. Use get_screenshot to view a specific image.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "output_dir": .object([
                        "type": .string("string"),
                        "description": .string("Output directory (default: storescreens-output)"),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "get_screenshot",
            description: "Load and display a screenshot by file path. Returns the image inline.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute or relative path to the PNG file"),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        Tool(
            name: "take_screenshot",
            description: """
            Capture the current screen of a running iOS simulator and return the image inline. \
            Use this for quick visual checks during UI development - not for full App Store screenshot capture. \
            If no simulator or udid is given, uses the first booted simulator.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object([
                        "type": .string("string"),
                        "description": .string("Simulator name (e.g. \"iPhone 17 Pro\"). Ignored if udid is given."),
                    ]),
                    "udid": .object([
                        "type": .string("string"),
                        "description": .string("Simulator UDID. Use instead of simulator name for precision."),
                    ]),
                    "boot": .object([
                        "type": .string("boolean"),
                        "description": .string("Boot the simulator if not already running. Default: false."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "read_config",
            description: "Read storescreens.yml and return it as a structured JSON object.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "config_path": .object([
                        "type": .string("string"),
                        "description": .string("Path to config file (default: storescreens.yml)"),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "list_templates",
            description: """
            List built-in render templates (curated color + typography + background pattern presets). \
            Apply one by calling set_template(template_id) or by passing --template to the render CLI. \
            User-supplied fields in the config always win over template defaults.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "set_template",
            description: """
            Apply a built-in render template by writing `template: <id>` into storescreens.yml. \
            Creates the `render:` block if missing. Does NOT remove user-supplied fields - those still \
            win over the template defaults. Call list_templates first to see available IDs.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "template_id": .object([
                        "type": .string("string"),
                        "description": .string("Template id from list_templates (e.g. 'sahara', 'midnight'). Pass empty string to clear."),
                    ]),
                    "config_path": .object([
                        "type": .string("string"),
                        "description": .string("Path to config file (default: storescreens.yml)"),
                    ]),
                ]),
                "required": .array([.string("template_id")]),
            ])
        ),
        Tool(
            name: "write_config",
            description: """
            Create or update storescreens.yml. Accepts a JSON object with any subset of config fields. \
            Merges with existing config if the file already exists.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "config_path": .object([
                        "type": .string("string"),
                        "description": .string("Path to config file (default: storescreens.yml)"),
                    ]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name")]),
                    "project": .object(["type": .string("string"), "description": .string(".xcodeproj path")]),
                    "workspace": .object(["type": .string("string"), "description": .string(".xcworkspace path")]),
                    "devices": .object([
                        "type": .string("array"),
                        "description": .string("Array of {simulator: \"Name\"} objects"),
                    ]),
                    "output_dir": .object(["type": .string("string"), "description": .string("Output directory")]),
                    "test_target": .object(["type": .string("string"), "description": .string("UI test target name")]),
                    "test_class": .object(["type": .string("string"), "description": .string("Test class name (default: ScreenshotTests)")]),
                    "appearances": .object(["type": .string("array"), "description": .string("e.g. [\"light\", \"dark\"]")]),
                    "locales": .object(["type": .string("array"), "description": .string("e.g. [\"en-US\", \"ja\"]")]),
                    "derived_data_path": .object(["type": .string("string"), "description": .string("Persistent DerivedData directory for faster incremental builds. Reused across runs.")]),
                    "upload": .object(["type": .string("boolean"), "description": .string("Enable post-capture upload prompt for storescreens.app. Default: false.")]),
                ]),
            ])
        ),
    ]

    // MARK: - Dispatch

    static func handle(_ params: CallTool.Parameters, server: Server) async -> CallTool.Result {
        do {
            // ASC API families. Two routing strategies coexist here:
            //   1. tools.contains(...) checks - most specific, used for any
            //      family that shares a prefix with another (Wave 4 GC
            //      Activities reuses `gc_*`; Wave 4 IAP Offer Codes reuses
            //      `iap_*`; etc.). These must come BEFORE the prefix checks
            //      so the more-specific family wins.
            //   2. hasPrefix(...) - fallback for namespaces with a single
            //      owner (`testflight_*`, `subs_*`, `reports_*`, …).
            //   3. Result? - a couple of early Wave 1 families returned
            //      nil for unknown names; left as-is.
            if let r = try await CustomerReviewsMCPTools.handle(params) { return r }
            if let r = try await UsersAndDevPortalMCPTools.handle(params) { return r }
            // Wave 4 family-specific catalogs (most-specific first).
            if GameCenterActivitiesMCPTools.tools.contains(where: { $0.name == params.name }) {
                return try await GameCenterActivitiesMCPTools.handle(params)
            }
            if BackgroundAssetsMCPTools.tools.contains(where: { $0.name == params.name }) {
                return try await BackgroundAssetsMCPTools.handle(params)
            }
            if BetaFeedbackAndExtrasMCPTools.tools.contains(where: { $0.name == params.name }) {
                return try await BetaFeedbackAndExtrasMCPTools.handle(params)
            }
            if Wave4ExtrasMCPTools.tools.contains(where: { $0.name == params.name }) {
                return try await Wave4ExtrasMCPTools.handle(params)
            }
            if ReviewSubmissionsMCPTools.tools.contains(where: { $0.name == params.name }) {
                return try await ReviewSubmissionsMCPTools.handle(params)
            }
            // Marketing + Apple Pay grab-bag use tools.contains too.
            if MarketingMCPTools.tools.contains(where: { $0.name == params.name }) {
                return try await MarketingMCPTools.handle(params)
            }
            if ApplePayAndMiscMCPTools.tools.contains(where: { $0.name == params.name }) {
                return try await ApplePayAndMiscMCPTools.handle(params)
            }
            // Prefix-based fallback routing for single-owner namespaces.
            if params.name.hasPrefix("testflight_") {
                return try await TestFlightMCPTools.handle(params)
            }
            if params.name.hasPrefix("iap_") {
                return try await InAppPurchasesMCPTools.handle(params)
            }
            if params.name.hasPrefix("pricing_") {
                return try await PricingMCPTools.handle(params)
            }
            if params.name.hasPrefix("translate_") {
                return try await TranslateMCPTools.handle(params)
            }
            if params.name.hasPrefix("subs_") {
                return try await SubscriptionsMCPTools.handle(params)
            }
            if params.name.hasPrefix("reports_") {
                return try await ReportsMCPTools.handle(params)
            }
            if params.name.hasPrefix("gc_") {
                return try await GameCenterMCPTools.handle(params)
            }
            if params.name.hasPrefix("xcc_") {
                return try await XcodeCloudMCPTools.handle(params)
            }
            if params.name.hasPrefix("altdist_") {
                return try await AltDistributionMCPTools.handle(params)
            }
            if params.name.hasPrefix("webhooks_") {
                return try await WebhooksMCPTools.handle(params)
            }
            if params.name.hasPrefix("build_uploads_") {
                return try await BuildUploadsMCPTools.handle(params)
            }
            if params.name.hasPrefix("accessibility_declarations_") {
                return try await AccessibilityDeclarationsMCPTools.handle(params)
            }

            // Built-in capture / render / preview tools.
            switch params.name {
            case "capture":             return try await handleCapture(params)
            case "get_capture_status":  return await handleGetCaptureStatus(params)
            case "get_capture_result":  return try await handleGetCaptureResult(params)
            case "check":             return try await handleCheck(params)
            case "list_simulators":   return try await handleListSimulators()
            case "list_screenshots":  return try handleListScreenshots(params)
            case "get_screenshot":    return try handleGetScreenshot(params)
            case "take_screenshot":   return try await handleTakeScreenshot(params)
            case "read_config":       return try handleReadConfig(params)
            case "write_config":      return try handleWriteConfig(params)
            case "list_templates":    return try handleListTemplates()
            case "set_template":      return try handleSetTemplate(params)
            default:
                return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        } catch {
            return .init(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

    // MARK: - capture (non-blocking)

    static func handleCapture(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let configPath = params.arguments?["config_path"]?.stringValue ?? "storescreens.yml"
        if let dir = params.arguments?["directory"]?.stringValue {
            FileManager.default.changeCurrentDirectoryPath(dir)
        }

        var captureConfig = try ConfigLoader().load(from: configPath)
        if let ddp = params.arguments?["derived_data_path"]?.stringValue {
            captureConfig.derivedDataPath = (ddp as NSString).expandingTildeInPath
        }
        guard captureConfig.project != nil || captureConfig.workspace != nil else {
            return .init(content: [.text("No project or workspace in \(configPath). Run write_config or check storescreens.yml.")], isError: true)
        }

        let taskId = String(UUID().uuidString.prefix(8).lowercased())
        await AsyncTaskStore.shared.start(taskId: taskId)

        // Run capture in background - returns taskId immediately so Claude can poll.
        Task {
            actor EventCollector {
                private(set) var events: [String] = []
                func append(_ line: String) { events.append(line) }
            }
            let collector = EventCollector()
            let orchestrator = CaptureOrchestrator()

            do {
                let result = try await orchestrator.run(config: captureConfig) { event in
                    switch event {
                    case .phase(let msg):
                        // Internal log dir signal - store for status polling, don't surface as an event
                        if msg.hasPrefix("logDir:") {
                            let logDir = String(msg.dropFirst("logDir:".count))
                            await AsyncTaskStore.shared.setLogDir(taskId: taskId, logDir: logDir)
                            return
                        }
                        let line = "● \(msg)"
                        await collector.append(line)
                        await AsyncTaskStore.shared.appendEvent(taskId: taskId, line: line)
                    case .deviceLog(_, let msg):
                        let line = "  \(msg)"
                        await collector.append(line)
                        await AsyncTaskStore.shared.appendEvent(taskId: taskId, line: line)
                    case .screenshotCaptured(let device, let slot, let name, _):
                        let line = "  ✓ \(device) [\(slot)] \(name)"
                        await collector.append(line)
                        await AsyncTaskStore.shared.appendEvent(taskId: taskId, line: line)
                    case .deviceCompleted(let device, let count):
                        let line = "✓ \(device): \(count) screenshot\(count == 1 ? "" : "s")"
                        await collector.append(line)
                        await AsyncTaskStore.shared.appendEvent(taskId: taskId, line: line)
                    case .deviceFailed(let device, let error):
                        let line = "✗ \(device) failed: \(error)"
                        await collector.append(line)
                        await AsyncTaskStore.shared.appendEvent(taskId: taskId, line: line)
                    case .preflightFinding(let rule, _, let message):
                        let line = "⚑ check:\(rule) - \(message)"
                        await collector.append(line)
                        await AsyncTaskStore.shared.appendEvent(taskId: taskId, line: line)
                    }
                }

                // Post-capture render + preview regeneration.
                // Shared with the CLI entry point so MCP users get the
                // same framed PNGs + raw/framed preview toggle. Render
                // progress lines flow through the logger closure into
                // AsyncTaskStore so callers polling `get_capture_status`
                // see them alongside capture events. Failures inside
                // the runner are already non-fatal - nothing throws here.
                let baseDirectory = URL(fileURLWithPath: configPath)
                    .deletingLastPathComponent()
                    .standardized
                await PostCaptureRunner().runIfEnabled(
                    captureConfig: captureConfig,
                    manifest: result.manifest,
                    capturedRoot: result.outputDir,
                    baseDirectory: baseDirectory,
                    logger: { msg in
                        Task {
                            await collector.append(msg)
                            await AsyncTaskStore.shared.appendEvent(taskId: taskId, line: msg)
                        }
                    }
                )

                let events = await collector.events

                // Store full result for on-demand retrieval
                let captureId = String(UUID().uuidString.prefix(8).lowercased())
                await ResultCache.shared.store(id: captureId, entry: .init(
                    manifest: result.manifest,
                    outputDir: result.outputDir,
                    events: events,
                    capturedAt: Date()
                ))

                let totalScreenshots = result.manifest.devices.reduce(0) { $0 + $1.screenshots.count }
                var seenLines = Set<String>()
                let deviceLines = result.manifest.devices.compactMap { device -> String? in
                    let line = "  \(device.simulatorName) [\(device.deviceType)]: \(device.screenshots.count) screenshot\(device.screenshots.count == 1 ? "" : "s")"
                    return seenLines.insert(line).inserted ? line : nil
                }
                let didFail = totalScreenshots == 0
                let summary = """
                \(didFail ? "⚠️  0 screenshots collected." : "Capture complete.") captureId: \(captureId)

                \(deviceLines.joined(separator: "\n"))

                Total: \(totalScreenshots) screenshot\(totalScreenshots == 1 ? "" : "s")
                Output: \(result.outputDir.path)
                \(didFail ? "Log: \(result.outputDir.appendingPathComponent("logs").path)" : "Preview: \(result.outputDir.appendingPathComponent("preview.html").path)")

                \(events.filter { isMeaningfulEvent($0) }.joined(separator: "\n"))
                """
                await AsyncTaskStore.shared.complete(taskId: taskId, captureId: captureId, summary: summary, isError: didFail)

                // Open preview in default browser on success
                if !didFail {
                    let previewPath = result.outputDir.appendingPathComponent("preview.html").path
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = [previewPath]
                    try? process.run()
                }
            } catch {
                await AsyncTaskStore.shared.fail(taskId: taskId, error: error.localizedDescription)
            }
        }

        return .init(content: [.text("""
        Capture started. taskId: \(taskId)

        Poll for progress with get_capture_status(task_id: "\(taskId)")
        Poll every 30 seconds during the build phase. Once get_capture_status reports "Wait 5 seconds", switch to 5-second polls until status is 'completed' or 'failed'.
        """)], isError: false)
    }

    // MARK: - Event filtering

    /// Returns true for structured storescreens events (●, ✓, ✗) and meaningful xcodebuild
    /// transitions. Filters out raw xcodebuild noise: `cd /path`, `builtin-copy`, `SwiftCompile`,
    /// `ScanDependencies`, `MkDir`, `Touch`, etc.
    static func isMeaningfulEvent(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        // Always keep structured storescreens lines (⚠️ = test failure with message+location)
        if t.hasPrefix("●") || t.hasPrefix("✓") || t.hasPrefix("✗") || t.hasPrefix("⚑") || t.hasPrefix("⚠️") { return true }
        // Keep meaningful xcodebuild transitions
        let keepPrefixes = ["Testing started", "Test case ", "Test suite ", "** TEST", "** BUILD"]
        if keepPrefixes.contains(where: { t.hasPrefix($0) }) { return true }
        // Keep xcodebuild errors, fatal failures, and screenshot progress markers
        let keepContains = ["xcodebuild: error:", "Could not resolve package dependencies",
                            "Couldn't update repository", "fatalError", "[📸]"]
        if keepContains.contains(where: { t.contains($0) }) { return true }
        // Drop everything else (cd, builtin-*, SwiftCompile, ScanDependencies, MkDir, Copy, Touch, etc.)
        return false
    }

    // MARK: - Device log scanning

    /// Error patterns that indicate a device capture has failed hard.
    /// Applied to individual lines in the per-device xcodebuild log files.
    static let deviceLogErrorPatterns: [String] = [
        "xcodebuild: error:",
        "** BUILD FAILED **",
        "** TEST FAILED **",
        "Could not resolve package dependencies",
        "fatalError",
        "error: Could not resolve",
        "Couldn't update repository",
    ]

    /// Scan per-device log files in `logDir` for known failure patterns.
    /// Returns an array of (deviceLabel, errorSnippet) for each failed device found.
    /// When a `** TEST FAILED **` line is found, also collects any `⚠️  Test failure:` lines
    /// that follow it (emitted by xcresult parsing) to include the specific assertion message.
    static func scanDeviceLogs(logDir: String) -> [(device: String, error: String)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logDir) else { return [] }
        let logFiles = files.filter { $0.hasPrefix("test-") && $0.hasSuffix(".log") && !$0.hasPrefix("test-debug-") }

        var results: [(device: String, error: String)] = []
        for filename in logFiles {
            let path = (logDir as NSString).appendingPathComponent(filename)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            let udidPrefix = filename
                .replacingOccurrences(of: "test-", with: "")
                .replacingOccurrences(of: ".log", with: "")

            let lines = content.components(separatedBy: "\n")

            // Find the first hard-failure line
            guard let failIdx = lines.firstIndex(where: { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return deviceLogErrorPatterns.contains(where: { t.contains($0) })
            }) else { continue }

            let failLine = lines[failIdx].trimmingCharacters(in: .whitespaces)

            // Collect any xcresult-derived assertion details that follow the failure line
            let detailLines = lines[(failIdx + 1)...].prefix(10)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("⚠️") }

            let errorSnippet = detailLines.isEmpty
                ? failLine
                : failLine + "\n" + detailLines.joined(separator: "\n")

            results.append((device: udidPrefix, error: errorSnippet))
        }
        return results
    }

    // MARK: - Staging log tail

    /// Returns the last `maxLines` lines of each per-device log file in `logDir`.
    /// Used to surface "build finished, tests running" context when xcodebuild goes silent.
    static func tailDeviceLogs(logDir: String, maxLines: Int = 5) -> String {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logDir) else { return "" }
        let logFiles = files
            .filter { $0.hasPrefix("test-") && $0.hasSuffix(".log") && !$0.hasPrefix("test-debug-") }
            .sorted()

        var sections: [String] = []
        for filename in logFiles {
            let path = (logDir as NSString).appendingPathComponent(filename)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let tail = lines.suffix(maxLines).joined(separator: "\n")
            if !tail.isEmpty {
                let device = filename
                    .replacingOccurrences(of: "test-", with: "")
                    .replacingOccurrences(of: ".log", with: "")
                sections.append("--- \(device) build log tail ---\n\(tail)")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - get_capture_status

    static func handleGetCaptureStatus(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let taskId = params.arguments?["task_id"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: task_id")], isError: true)
        }
        guard let state = await AsyncTaskStore.shared.state(taskId) else {
            return .init(content: [.text("No task found with id: \(taskId)")], isError: true)
        }
        switch state {
        case .running(let startedAt, let lastEventAt, let totalEventCount, let events, let logDir):
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            let lastEventSec = Int(Date().timeIntervalSince(lastEventAt))
            let meaningful = events.filter { isMeaningfulEvent($0) }
            let recent = meaningful.suffix(20).joined(separator: "\n")
            let activityLine = totalEventCount > 0
                ? "(\(totalEventCount) lines processed, last activity \(lastEventSec)s ago)"
                : "(starting up)"

            // Collect all error events from the full event history (not just recent 20).
            // Device errors can be pushed off the suffix(20) window by a long parallel build.
            let allErrors = meaningful.filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("✗") || deviceLogErrorPatterns.contains(where: { t.contains($0) })
            }

            // Scan log files for device failures - catches errors that xcodebuild writes to
            // stderr (appended by finalizeLog) which may not have appeared as events yet.
            var deviceFailureLines: [String] = allErrors
            if let logDir {
                let failures = scanDeviceLogs(logDir: logDir)
                for (device, error) in failures {
                    let line = "  ✗ Device \(device): \(error)"
                    if !deviceFailureLines.contains(line) {
                        deviceFailureLines.append(line)
                    }
                }
            }
            let failureSection = deviceFailureLines.isEmpty ? "" :
                "\n\nDevice failures detected:\n" + deviceFailureLines.joined(separator: "\n") +
                "\n\nIf a device has failed, ask the user whether to abort the run or wait for remaining devices."

            // When activity has gone silent (>60s), include the build log tail so Claude
            // can confirm the build ended and tests are executing, rather than seeing silence.
            let logTailSection: String
            if lastEventSec > 60, let logDir {
                let tail = tailDeviceLogs(logDir: logDir)
                logTailSection = tail.isEmpty ? "" : "\n\nBuild phase ended. Last lines from build log (tests are now executing):\n\(tail)"
            } else {
                logTailSection = ""
            }

            let inTestPhase = !logTailSection.isEmpty || recent.contains("✓")
            let pollAdvice = inTestPhase
                ? "Still running. Wait 5 seconds, then call get_capture_status(task_id: \"\(taskId)\") again."
                : "Still running. Wait 30 seconds, then call get_capture_status(task_id: \"\(taskId)\") again. Do not poll continuously."

            return .init(content: [.text("""
            status: running (\(elapsed)s elapsed)

            \(recent.isEmpty ? "" : recent + "\n\n")\(activityLine)\(logTailSection)\(failureSection)

            \(pollAdvice)
            """)], isError: !deviceFailureLines.isEmpty)
        case .completed(let captureId, let summary, let isError):
            return .init(content: [.text("""
            status: completed

            \(summary)

            Call get_capture_result(capture_id: "\(captureId)") for the full manifest.
            Call list_screenshots to browse captured images.
            """)], isError: isError)
        case .failed(let error, let events):
            let recent = events.suffix(10).joined(separator: "\n")
            // Surface preflight findings (⚑ lines) separately so the skill can act on them
            let findings = events.filter { $0.hasPrefix("⚑") }.joined(separator: "\n")
            let isDestinationError = error.hasPrefix("unsupported-destination:")
            let actionHint = isDestinationError
                ? """

                  To skip the unsupported device(s): remove them from storescreens.yml and re-run capture.
                  To add iPad/iPhone support: open Xcode → target → General → Supported Destinations.
                  """
                : "\n  Check the log files in the output directory for full xcodebuild output."
            return .init(content: [.text("""
            status: failed

            Error: \(error)
            \(findings.isEmpty ? "" : "\nPreflight findings:\n\(findings)\n")\(actionHint)

            Last events:
            \(recent)
            """)], isError: true)
        }
    }

    // MARK: - get_capture_result

    static func handleGetCaptureResult(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["capture_id"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: capture_id")], isError: true)
        }
        guard let entry = await ResultCache.shared.get(id: id) else {
            return .init(content: [.text("No capture result found for id '\(id)'. Results are kept for the 5 most recent captures per server session.")], isError: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestJSON = String(data: try encoder.encode(entry.manifest), encoding: .utf8) ?? "{}"

        let filteredEvents = entry.events.filter { isMeaningfulEvent($0) }
        let output = """
        captureId: \(id)
        Output: \(entry.outputDir.path)

        --- Events ---
        \(filteredEvents.joined(separator: "\n"))

        --- Manifest ---
        \(manifestJSON)
        """
        return .init(content: [.text(output)], isError: false)
    }

    // MARK: - check

    static func handleCheck(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let configPath = params.arguments?["config_path"]?.stringValue ?? "storescreens.yml"
        let directory = params.arguments?["directory"]?.stringValue ?? "."
        let captureConfig = try? ConfigLoader().load(from: configPath)

        let deviceContext: PreflightScanner.DeviceContext
        if let cfg = captureConfig {
            let hasIPad = cfg.devices.contains { $0.simulator.lowercased().contains("ipad") }
            let hasIPhone = cfg.devices.contains {
                !$0.simulator.lowercased().contains("ipad") && !$0.simulator.lowercased().contains("watch")
            }
            let hasMultipleLocales = (cfg.locales?.count ?? 0) > 1
            deviceContext = PreflightScanner.DeviceContext(hasIPad: hasIPad, hasIPhone: hasIPhone, hasMultipleLocales: hasMultipleLocales)
        } else {
            deviceContext = PreflightScanner.DeviceContext(hasIPad: true, hasIPhone: true)
        }

        let scanResult = PreflightScanner().scan(directory: directory, deviceContext: deviceContext)

        struct FindingOutput: Encodable {
            let severity: String
            let rule: String
            let file: String
            let line: Int
            let message: String
            let lineContent: String
        }
        var findings = scanResult.findings.map {
            FindingOutput(
                severity: $0.severity.rawValue, rule: $0.rule,
                file: $0.filePath, line: $0.lineNumber,
                message: $0.message, lineContent: $0.lineContent
            )
        }
        // Check for stale DerivedData
        if let cfg = captureConfig, let persistentPath = cfg.derivedDataPath {
            let expandedPath = (persistentPath as NSString).expandingTildeInPath
            if CaptureOrchestrator.isDerivedDataStale(
                derivedDataPath: expandedPath,
                testTarget: cfg.testTarget,
                project: cfg.project,
                workspace: cfg.workspace
            ) {
                let staleFinding = FindingOutput(
                    severity: "warning", rule: "stale-derived-data",
                    file: expandedPath, line: 0,
                    message: "Test source files are newer than the compiled test binary in DerivedData. " +
                        "xcodebuild may produce a stale test binary. To force a clean rebuild, run: rm -rf \"\(expandedPath)/Build/Products\"",
                    lineContent: ""
                )
                findings.append(staleFinding)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(data: try encoder.encode(findings), encoding: .utf8) ?? "[]"
        let summary = "\(scanResult.errors.count) error(s), \(scanResult.warnings.count + (findings.count - scanResult.findings.count)) warning(s)\n\n\(json)"
        return .init(content: [.text(summary)], isError: scanResult.hasErrors)
    }

    // MARK: - list_simulators

    static func handleListSimulators() async throws -> CallTool.Result {
        let manager = SimulatorManager()
        let devices = try await manager.listAvailableDevices()

        struct DeviceOutput: Encodable {
            let name: String
            let appStoreSize: String
            let udid: String
        }

        // Group by App Store size, keep only available iPhone/iPad devices
        var bySize: [String: [DeviceOutput]] = [:]
        for device in devices where device.isAvailable {
            guard let size = try? await manager.appStoreSize(for: device),
                  size.isIPhone || size.isIPad else { continue }
            let entry = DeviceOutput(name: device.name, appStoreSize: size.displayName, udid: device.udid)
            bySize[size.displayName, default: []].append(entry)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(data: try encoder.encode(bySize), encoding: .utf8) ?? "{}"
        let count = bySize.values.reduce(0) { $0 + $1.count }
        return .init(content: [.text("\(count) available simulators grouped by App Store slot:\n\n\(json)")], isError: false)
    }

    // MARK: - list_screenshots

    static func handleListScreenshots(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let outputDir = params.arguments?["output_dir"]?.stringValue ?? "storescreens-output"
        let manifestPath = (outputDir as NSString).appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: manifestPath) else {
            return .init(content: [.text("No manifest.json at \(manifestPath). Run capture first.")], isError: true)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureManifest.self, from: data)

        struct ScreenshotOutput: Encodable {
            let device: String
            let appStoreSlot: String
            let name: String
            let path: String
        }
        var screenshots: [ScreenshotOutput] = []
        for device in manifest.devices {
            for shot in device.screenshots {
                let fullPath = (outputDir as NSString).appendingPathComponent(shot.filename)
                screenshots.append(ScreenshotOutput(
                    device: device.simulatorName,
                    appStoreSlot: device.deviceType,
                    name: shot.name,
                    path: fullPath
                ))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(data: try encoder.encode(screenshots), encoding: .utf8) ?? "[]"
        return .init(content: [.text("\(screenshots.count) screenshot(s):\n\n\(json)")], isError: false)
    }

    // MARK: - get_screenshot

    static func handleGetScreenshot(_ params: CallTool.Parameters) throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: path")], isError: true)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .init(content: [.text("File not found: \(path)")], isError: true)
        }
        let base64 = data.base64EncodedString()
        return .init(content: [.image(data: base64, mimeType: "image/png", metadata: nil)], isError: false)
    }

    // MARK: - take_screenshot

    static func handleTakeScreenshot(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let manager = SimulatorManager()
        let device: SimulatorDevice

        if let udidValue = params.arguments?["udid"]?.stringValue {
            let allDevices = try await manager.listAvailableDevices()
            guard let found = allDevices.first(where: { $0.udid == udidValue }) else {
                return .init(content: [.text("Simulator with UDID '\(udidValue)' not found.")], isError: true)
            }
            device = found
        } else if let name = params.arguments?["simulator"]?.stringValue {
            device = try await manager.findDevice(named: name)
        } else {
            let allDevices = try await manager.listAvailableDevices()
            guard let booted = allDevices.first(where: { $0.isBooted }) else {
                return .init(content: [.text("No booted simulator found. Pass a simulator name or udid, or boot one first.")], isError: true)
            }
            device = booted
        }

        let shouldBoot = params.arguments?["boot"]?.boolValue ?? false

        if !device.isBooted {
            if shouldBoot {
                try await manager.boot(device.udid)
                // Brief pause for the simulator to finish booting
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } else {
                return .init(content: [.text("Simulator '\(device.name)' is not booted. Pass boot: true to boot it automatically, or use list_simulators to find a booted simulator.")], isError: true)
            }
        }

        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png").path
        try await manager.takeScreenshot(device.udid, outputPath: tempPath)

        guard let data = FileManager.default.contents(atPath: tempPath) else {
            return .init(content: [.text("Screenshot was taken but file could not be read.")], isError: true)
        }
        let base64 = data.base64EncodedString()
        try? FileManager.default.removeItem(atPath: tempPath)

        return .init(content: [.image(data: base64, mimeType: "image/png", metadata: nil)], isError: false)
    }

    // MARK: - read_config

    static func handleReadConfig(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let configPath = params.arguments?["config_path"]?.stringValue ?? "storescreens.yml"
        let config = try ConfigLoader().load(from: configPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(data: try encoder.encode(config), encoding: .utf8) ?? "{}"
        return .init(content: [.text(json)], isError: false)
    }

    // MARK: - list_templates

    static func handleListTemplates() throws -> CallTool.Result {
        struct Out: Encodable {
            let id: String
            let name: String
            let category: String
            let description: String
        }
        let templates = RenderTemplate.builtIn.map {
            Out(id: $0.id, name: $0.name, category: $0.category, description: $0.description)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(data: try encoder.encode(templates), encoding: .utf8) ?? "[]"
        return .init(content: [.text("""
        \(templates.count) built-in templates:

        \(json)

        Apply one with set_template(template_id: "<id>") or `storescreens render --template <id>`.
        """)], isError: false)
    }

    // MARK: - set_template

    static func handleSetTemplate(_ params: CallTool.Parameters) throws -> CallTool.Result {
        guard let templateId = params.arguments?["template_id"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: template_id")], isError: true)
        }
        let configPath = params.arguments?["config_path"]?.stringValue ?? "storescreens.yml"

        // Reject unknown template ids up-front so the user doesn't write a
        // value that the render pipeline will then warn about. Empty string
        // is the documented way to clear the template, so let that through.
        if !templateId.isEmpty, RenderTemplate.find(templateId) == nil {
            let known = RenderTemplate.builtIn.map(\.id).joined(separator: ", ")
            return .init(content: [.text("Unknown template '\(templateId)'. Known: \(known).")], isError: true)
        }

        guard FileManager.default.fileExists(atPath: configPath) else {
            return .init(content: [.text("No config at \(configPath). Run `storescreens init` or pass config_path.")], isError: true)
        }

        var config = try ConfigLoader().load(from: configPath)
        var render = config.render ?? RenderConfig(enabled: true)
        if render.enabled == nil { render.enabled = true }
        render.template = templateId.isEmpty ? nil : templateId
        config.render = render

        try ConfigLoader().write(config, to: configPath)

        let msg = templateId.isEmpty
            ? "Cleared template from \(configPath)."
            : "Applied template '\(templateId)' to \(configPath). Run `storescreens render` to re-render with the new defaults."
        return .init(content: [.text(msg)], isError: false)
    }

    // MARK: - write_config

    static func handleWriteConfig(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let configPath = params.arguments?["config_path"]?.stringValue ?? "storescreens.yml"
        let args = params.arguments ?? [:]

        // Load existing config to merge into, or build a minimal one
        var config: CaptureConfig
        if FileManager.default.fileExists(atPath: configPath) {
            config = try ConfigLoader().load(from: configPath)
        } else {
            // Minimal valid config - scheme and at least one device required to capture
            let scheme = args["scheme"]?.stringValue ?? "MyApp"
            config = CaptureConfig(scheme: scheme, devices: [], outputDir: "storescreens-output")
        }

        // Apply any provided fields
        if let v = args["scheme"]?.stringValue       { config.scheme = v }
        if let v = args["project"]?.stringValue      { config.project = v }
        if let v = args["workspace"]?.stringValue    { config.workspace = v }
        if let v = args["output_dir"]?.stringValue   { config.outputDir = v }
        if let v = args["test_target"]?.stringValue  { config.testTarget = v }
        if let v = args["test_class"]?.stringValue   { config.testClass = v }
        if let v = args["derived_data_path"]?.stringValue { config.derivedDataPath = (v as NSString).expandingTildeInPath }
        if let v = args["upload"]?.boolValue             { config.upload = v }

        if let devArray = args["devices"]?.arrayValue {
            config.devices = devArray.compactMap { item -> DeviceConfig? in
                guard let name = item.objectValue?["simulator"]?.stringValue else { return nil }
                return DeviceConfig(simulator: name)
            }
        }
        if let appArray = args["appearances"]?.arrayValue {
            config.appearances = appArray.compactMap { $0.stringValue }
        }
        if let locArray = args["locales"]?.arrayValue {
            config.locales = locArray.compactMap { $0.stringValue }
        }

        try ConfigLoader().write(config, to: configPath)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(data: try encoder.encode(config), encoding: .utf8) ?? "{}"
        return .init(content: [.text("Wrote \(configPath):\n\n\(json)")], isError: false)
    }
}
