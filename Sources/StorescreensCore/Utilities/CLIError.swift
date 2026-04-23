import Foundation

package enum CLIError: LocalizedError {
    case xcrunFailed(String)
    case simulatorNotFound(name: String)
    case noMatchingDeviceSize(simulatorName: String)
    case simulatorBootFailed(reason: String)
    case simulatorShutdownFailed(reason: String)
    case screenshotFailed(reason: String)
    case installFailed(reason: String)
    case launchFailed(reason: String)
    case configNotFound(path: String)
    case configInvalid(reason: String)
    case buildFailed(output: String)
    case testFailed(device: String, output: String)
    case xctestrunNotFound(derivedDataPath: String)
    case resultBundleNotFound(path: String)
    case noScreenshotsFound(device: String)
    /// 0 PNGs reached the cache dir AND at least one test failed in the xcresult.
    /// Surfaces the failing test names and messages so the user can fix the root cause
    /// instead of chasing simulator-state red herrings.
    case noScreenshotsTestFailures(
        device: String,
        totalTests: Int,
        failedTests: Int,
        failureSummaries: [String]
    )
    /// 0 PNGs reached the cache dir but all tests passed. This points at the breadcrumb
    /// mechanism rather than a test failure, so the error message says so explicitly.
    case noScreenshotsAllTestsPassed(
        device: String,
        totalTests: Int,
        cacheDir: String
    )
    case screenshotExtractionFailed(reason: String)
    case outputDirectoryNotWritable(path: String)
    case localeSetFailed(reason: String)
    case appearanceSetFailed(reason: String)
    case statusBarFailed(reason: String)
    case noProjectOrWorkspace
    case noDevicesConfigured
    case preflightFailed(errorCount: Int, warningCount: Int)
    case unsupportedDestinations(devices: [String], supportedFamilies: [Int])
    case noBootedSimulator
    case simulatorNotBooted(name: String)
    case xcodeNotFound(reason: String)
    case archiveFailed(output: String)
    case exportFailed(reason: String)
    case uploadFailed(output: String)
    case versionProbeFailed(reason: String)

    private func familyName(_ id: Int) -> String {
        switch id {
        case 1: return "iPhone"
        case 2: return "iPad"
        case 4: return "Apple Watch"
        case 6: return "Mac"
        default: return "family \(id)"
        }
    }

    package var errorDescription: String? {
        switch self {
        case .xcrunFailed(let msg):
            return "xcrun failed: \(msg)"
        case .simulatorNotFound(let name):
            return "Simulator '\(name)' not found. Run 'storescreens list' to see available simulators."
        case .noMatchingDeviceSize(let name):
            return "Could not determine App Store size for '\(name)'. Specify 'size:' explicitly in config."
        case .simulatorBootFailed(let reason):
            return "Failed to boot simulator: \(reason)"
        case .simulatorShutdownFailed(let reason):
            return "Failed to shutdown simulator: \(reason)"
        case .screenshotFailed(let reason):
            return "Screenshot capture failed: \(reason)"
        case .installFailed(let reason):
            return "App install failed: \(reason)"
        case .launchFailed(let reason):
            return "App launch failed: \(reason)"
        case .configNotFound(let path):
            return "Config file not found at '\(path)'. Run 'storescreens init' to generate one."
        case .configInvalid(let reason):
            return "Invalid config: \(reason)"
        case .buildFailed(let output):
            return "Build failed:\n\(String(output.suffix(500)))"
        case .testFailed(let device, let output):
            return "Tests failed on \(device):\n\(String(output.suffix(500)))"
        case .xctestrunNotFound(let path):
            return "No .xctestrun file found in \(path). Check your scheme builds for testing."
        case .resultBundleNotFound(let path):
            return "Result bundle not found at \(path)."
        case .noScreenshotsFound(let device):
            return "No screenshots collected for \(device). Possible causes: simulator in bad state (try 'xcrun simctl shutdown all'), tests not saving screenshots, or test crash. Check logs/ for details."
        case .noScreenshotsTestFailures(let device, let total, let failed, let summaries):
            let failuresBlock = summaries.isEmpty
                ? "(xcresulttool did not return failure details; inspect logs/ for the raw xcodebuild output)"
                : summaries.map { "  - \($0)" }.joined(separator: "\n")
            return """
            No screenshots collected for \(device). \(failed) of \(total) tests failed, which is almost certainly why no PNGs were produced:
            \(failuresBlock)
            Fix the failing test(s) above, then rerun. If the test code looks correct but xcodebuild keeps running stale logic, the compiled test bundle in your persistent DerivedData is stale, see the '⚑ Test sources newer than compiled test bundle' warning earlier in this run.
            """
        case .noScreenshotsAllTestsPassed(let device, let total, let cacheDir):
            return """
            No screenshots collected for \(device). All \(total) test\(total == 1 ? "" : "s") passed but no PNGs reached the screenshot cache directory:
              \(cacheDir)
            The test target likely did not write any screenshots. Check that your test code reads the breadcrumb file at ~/.storescreens-cache-dir and writes PNGs to the path it contains. See logs/ for the raw xcodebuild output.
            """
        case .screenshotExtractionFailed(let reason):
            return "Screenshot extraction failed: \(reason)"
        case .outputDirectoryNotWritable(let path):
            return "Cannot write to output directory: \(path)"
        case .localeSetFailed(let reason):
            return "Failed to set simulator locale: \(reason)"
        case .appearanceSetFailed(let reason):
            return "Failed to set simulator appearance: \(reason)"
        case .statusBarFailed(let reason):
            return "Failed to override status bar: \(reason)"
        case .noProjectOrWorkspace:
            return "No .xcodeproj or .xcworkspace found. Specify 'project:' or 'workspace:' in config."
        case .noDevicesConfigured:
            return "No devices configured. Add devices to your storescreens.yml config."
        case .preflightFailed(let errors, let warnings):
            return "Preflight check found \(errors) error\(errors == 1 ? "" : "s") and \(warnings) warning\(warnings == 1 ? "" : "s"). Fix errors or use --skip-check to bypass."
        case .noBootedSimulator:
            return "No booted simulator found. Boot one with 'xcrun simctl boot <device>' or pass --boot."
        case .simulatorNotBooted(let name):
            return "Simulator '\(name)' is not booted. Pass --boot to boot it automatically."
        case .unsupportedDestinations(let devices, let families):
            let familyNames = families.map { familyName($0) }.joined(separator: "+")
            let deviceList = devices.joined(separator: ", ")
            return "unsupported-destination: \(deviceList) - app only supports \(familyNames). Remove these devices from storescreens.yml, or add the missing device family in Xcode (General -> Supported Destinations)."
        case .xcodeNotFound(let reason):
            return "Could not locate a production Xcode: \(reason). Install a non-beta Xcode in /Applications, or set `app_store_connect.upload_build.xcode_path` / pass --xcode-path."
        case .archiveFailed(let output):
            return "xcodebuild archive failed:\n\(String(output.suffix(800)))"
        case .exportFailed(let reason):
            return "xcodebuild -exportArchive failed: \(reason)"
        case .uploadFailed(let output):
            return "altool upload failed:\n\(String(output.suffix(800)))"
        case .versionProbeFailed(let reason):
            return "Could not read version from Xcode project: \(reason)"
        }
    }
}
