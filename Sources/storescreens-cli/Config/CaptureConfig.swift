import Foundation

struct CaptureConfig: Codable {
    var project: String?
    var workspace: String?
    var scheme: String

    var devices: [DeviceConfig]

    var locales: [String]?
    var appearances: [String]?
    var screenshots: [String]?
    var outputDir: String
    var testTarget: String?
    var testClass: String?
    var launchArguments: [String]?
    var keepRuns: Int?

    /// Run the test suite twice per device. The first run is discarded (warmup) and the second captures the real screenshots.
    /// Useful for apps that need one full launch cycle to finish seeding or loading data (e.g. CloudKit, ODR).
    /// Default: false.
    var warmupRun: Bool?

    /// Override the simulator status bar for clean screenshots.
    /// When true, applies a clean status bar (9:41 AM, full battery/signal).
    /// Default: true. Set to false to disable.
    var statusBar: Bool?

    /// Custom arguments for `xcrun simctl status_bar override`.
    /// Only used when `statusBar` is true.
    /// Default: "--time 9:41 --dataNetwork lte+ --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 90 --operatorName TELUS"
    var statusBarArguments: String?

    /// Run preflight source code check before capture.
    /// Default: true. Set to false to disable auto-check.
    var preflight: Bool?

    /// Dismiss system alerts (e.g. App Store review prompts) during testing.
    /// Default: true. Set to false to allow review prompts and other system alerts.
    var dismissSystemAlerts: Bool?

    /// Log level: "quiet", "normal", or "verbose".
    /// Default: "normal". Set to "verbose" to see xcodebuild output, or "quiet" for errors/warnings only.
    var logLevel: String?

    /// Path to a persistent DerivedData directory for faster incremental builds.
    /// When set, DerivedData is reused across runs and not deleted after capture.
    /// When nil, a temporary directory is used and cleaned up after each run.
    var derivedDataPath: String?

    /// Show the post-capture upload prompt for storescreens.app.
    /// Default: false. Set to true to enable.
    var upload: Bool?

    enum CodingKeys: String, CodingKey {
        case project, workspace, scheme, devices, locales, appearances, screenshots
        case outputDir = "output_dir"
        case testTarget = "test_target"
        case testClass = "test_class"
        case launchArguments = "launch_arguments"
        case keepRuns = "keep_runs"
        case warmupRun = "warmup_run"
        case statusBar = "status_bar"
        case statusBarArguments = "status_bar_arguments"
        case preflight
        case dismissSystemAlerts = "dismiss_system_alerts"
        case logLevel = "log_level"
        case derivedDataPath = "derived_data_path"
        case upload
    }
}

struct DeviceConfig: Codable, Sendable {
    var simulator: String
    var size: String?
    /// Platform for this device: "iOS" (default) or "macOS".
    /// When "macOS", tests run natively on the Mac instead of in a simulator.
    var platform: String?

    var isMacOS: Bool {
        platform?.lowercased() == "macos"
    }

    enum CodingKeys: String, CodingKey {
        case simulator, size, platform
    }
}
