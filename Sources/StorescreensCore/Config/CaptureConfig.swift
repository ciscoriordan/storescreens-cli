import Foundation

package struct CaptureConfig: Codable {
    package var project: String?
    package var workspace: String?
    package var scheme: String

    package var devices: [DeviceConfig]

    package var locales: [String]?
    package var appearances: [String]?
    package var screenshots: [String]?
    package var outputDir: String
    package var testTarget: String?
    package var testClass: String?
    package var launchArguments: [String]?
    package var keepRuns: Int?

    /// Run the test suite twice per device. The first run is discarded (warmup) and the second captures the real screenshots.
    /// Useful for apps that need one full launch cycle to finish seeding or loading data (e.g. CloudKit, ODR).
    /// Default: false.
    package var warmupRun: Bool?

    /// Override the simulator status bar for clean screenshots.
    /// When true, applies a clean status bar (9:41 AM, full battery/signal).
    /// Default: true. Set to false to disable.
    package var statusBar: Bool?

    /// Custom arguments for `xcrun simctl status_bar override`.
    /// Only used when `statusBar` is true.
    /// Default: "--time 9:41 --dataNetwork lte+ --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 90 --operatorName TELUS"
    package var statusBarArguments: String?

    /// Run preflight source code check before capture.
    /// Default: true. Set to false to disable auto-check.
    package var preflight: Bool?

    /// Dismiss system alerts (e.g. App Store review prompts) during testing.
    /// Default: true. Set to false to allow review prompts and other system alerts.
    package var dismissSystemAlerts: Bool?

    /// Log level: "quiet", "normal", or "verbose".
    /// Default: "normal". Set to "verbose" to see xcodebuild output, or "quiet" for errors/warnings only.
    package var logLevel: String?

    /// Path to a persistent DerivedData directory for faster incremental builds.
    /// When set, DerivedData is reused across runs and not deleted after capture.
    /// When nil, a temporary directory is used and cleaned up after each run.
    package var derivedDataPath: String?

    /// Show the post-capture upload prompt for storescreens.app.
    /// Default: false. Set to true to enable.
    package var upload: Bool?

    /// Custom locale-to-flag mappings for the HTML preview gallery.
    /// Keys are Xcode locale codes (e.g., "en-GB", "es-419"). Values are either:
    ///   - A filename (without .svg) from ciscoriordan/svg-flags/circle/languages/, e.g. "in-en"
    ///   - A full https:// URL, used as-is
    /// Merged with built-in defaults; user values win over built-in on key collisions.
    package var localeFlags: [String: String]?

    package init(scheme: String, devices: [DeviceConfig], outputDir: String) {
        self.scheme = scheme
        self.devices = devices
        self.outputDir = outputDir
    }

    package enum CodingKeys: String, CodingKey {
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
        case localeFlags = "locale_flags"
    }
}

package struct DeviceConfig: Codable, Sendable {
    package var simulator: String
    package var size: String?
    /// Platform for this device: "iOS" (default) or "macOS".
    /// When "macOS", tests run natively on the Mac instead of in a simulator.
    package var platform: String?

    package init(simulator: String, size: String? = nil, platform: String? = nil) {
        self.simulator = simulator
        self.size = size
        self.platform = platform
    }

    package var isMacOS: Bool {
        platform?.lowercased() == "macos"
    }

    package enum CodingKeys: String, CodingKey {
        case simulator, size, platform
    }
}
