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

    /// Custom locale-to-flag mappings for the HTML preview gallery.
    /// Keys are Xcode locale codes (e.g., "en-GB", "es-419"). Values are either:
    ///   - A filename (without .svg) from ciscoriordan/svg-flags/circle/languages/, e.g. "in-en"
    ///   - A full https:// URL, used as-is
    /// Merged with built-in defaults; user values win over built-in on key collisions.
    var localeFlags: [String: String]?

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
        case localeFlags = "locale_flags"
    }
}

struct DeviceConfig: Codable, Sendable {
    var simulator: String
    var size: String?
    /// Platform for this device: "iOS" (default) or "macOS".
    /// When "macOS", tests run natively on the Mac instead of in a simulator.
    var platform: String?
    /// Per-device test selection. When non-nil, xcodebuild runs only these
    /// tests on this device, overriding the top-level `test_class` filter.
    ///
    /// Each entry is interpreted relative to the top-level `test_target`:
    ///   - "testFoo"         -> `test_target/test_class/testFoo`
    ///   - "ClassName/test"  -> `test_target/ClassName/test`
    ///   - "ClassName"       -> `test_target/ClassName`
    ///   - "Target/Cls/test" -> passed through verbatim
    ///
    /// Use this to restrict iPad-only or iPhone-only test methods to their
    /// platform, so a test that only renders meaningfully on one form factor
    /// doesn't run on the other and produce a degraded screenshot. When nil,
    /// the device inherits the top-level test_target/test_class behavior.
    var tests: [String]?

    var isMacOS: Bool {
        platform?.lowercased() == "macos"
    }

    enum CodingKeys: String, CodingKey {
        case simulator, size, platform, tests
    }
}

/// Turn a per-device `tests:` list into fully-qualified xcodebuild
/// `-only-testing` selectors, using the top-level test_target/test_class as
/// defaults for short-form entries. Matches the StorescreensCore resolver so
/// both capture paths behave identically.
func resolvedTestSelectors(
    entries: [String]?,
    testTarget: String?,
    testClass: String?
) -> [String]? {
    guard let entries, !entries.isEmpty else { return nil }
    return entries.map { entry in
        let slashCount = entry.filter { $0 == "/" }.count
        switch slashCount {
        case 0:
            if let target = testTarget, let cls = testClass {
                return "\(target)/\(cls)/\(entry)"
            } else if let target = testTarget {
                return "\(target)/\(entry)"
            }
            return entry
        case 1:
            if let target = testTarget {
                return "\(target)/\(entry)"
            }
            return entry
        default:
            return entry
        }
    }
}
