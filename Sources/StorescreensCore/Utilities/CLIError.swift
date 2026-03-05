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
            let familyNames = families.map { $0 == 2 ? "iPad" : ($0 == 1 ? "iPhone" : "family \($0)") }.joined(separator: "+")
            let deviceList = devices.joined(separator: ", ")
            return "unsupported-destination: \(deviceList) — app only supports \(familyNames). Remove these devices from storescreens.yml, or add the missing device family in Xcode (General → Supported Destinations)."
        }
    }
}
