import Foundation

package actor SimulatorManager {
    private let shell = ShellRunner()

    /// Cache of device type identifier → screen info, loaded from CoreSimulator profiles.
    private var profileCache: [String: DeviceScreenInfo]?

    package struct DeviceScreenInfo: Sendable {
        package let width: Int
        package let height: Int
        package let productFamily: Int
    }

    package init() {}

    /// Load device type profiles from CoreSimulator.
    /// Reads bundle paths from `simctl list devicetypes`, then parses each profile.plist
    /// to get screen dimensions. This is how we avoid hardcoding device names.
    package func loadDeviceTypeProfiles() async throws -> [String: DeviceScreenInfo] {
        if let cached = profileCache {
            return cached
        }

        let result = try await shell.xcrun("simctl", arguments: ["list", "devicetypes", "--json"])
        guard result.succeeded else {
            throw CLIError.xcrunFailed(result.stderr)
        }

        let data = Data(result.stdout.utf8)
        let decoded = try JSONDecoder().decode(DeviceTypeListResponse.self, from: data)

        var cache: [String: DeviceScreenInfo] = [:]
        for deviceType in decoded.devicetypes {
            if let profile = DeviceMapping.readProfile(bundlePath: deviceType.bundlePath) {
                cache[deviceType.identifier] = DeviceScreenInfo(
                    width: profile.width,
                    height: profile.height,
                    productFamily: profile.productFamily
                )
            }
        }

        profileCache = cache
        return cache
    }

    /// Look up the App Store size for a device using its screen dimensions from the profile.
    /// Returns nil only if the profile can't be read (no Xcode, etc.).
    package func appStoreSize(for device: SimulatorDevice) async throws -> AppStoreScreenSize? {
        let profiles = try await loadDeviceTypeProfiles()
        guard let info = profiles[device.deviceTypeIdentifier] else {
            return nil
        }
        // Support iPhone (1), iPad (2), Watch (4), and Mac (6) for App Store screenshots
        guard info.productFamily == 1 || info.productFamily == 2 || info.productFamily == 4 || info.productFamily == 6 else {
            return nil
        }
        return AppStoreScreenSize(
            width: info.width,
            height: info.height,
            productFamily: info.productFamily
        )
    }

    package func listAvailableDevices(minimumRuntime: String? = nil) async throws -> [SimulatorDevice] {
        let result = try await shell.xcrun("simctl", arguments: ["list", "devices", "available", "--json"])
        guard result.succeeded else {
            throw CLIError.xcrunFailed(result.stderr)
        }

        let data = Data(result.stdout.utf8)
        let decoded = try JSONDecoder().decode(SimulatorDeviceList.self, from: data)

        // Filter runtimes to only those >= the project's deployment target
        let filteredRuntimes: [String: [SimulatorDevice]]
        if let minimum = minimumRuntime, let minVersion = parseRuntimeVersion(minimum) {
            filteredRuntimes = decoded.devices.filter { key, _ in
                guard let version = parseRuntimeVersion(fromIdentifier: key) else { return false }
                return version >= minVersion
            }
        } else {
            filteredRuntimes = decoded.devices
        }

        let allDevices = filteredRuntimes
            .sorted { $0.key > $1.key } // latest runtimes first
            .flatMap(\.value)
            .filter(\.isAvailable)

        // Deduplicate: keep the first (latest runtime) for each device name
        var seen = Set<String>()
        var unique: [SimulatorDevice] = []
        for device in allDevices {
            if seen.insert(device.name).inserted {
                unique.append(device)
            }
        }

        return unique.sorted { $0.name < $1.name }
    }

    /// Parse a version string like "18.0" or "26" into a comparable tuple.
    private func parseRuntimeVersion(_ version: String) -> (Int, Int)? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        let minor = parts.count > 1 ? parts[1] : 0
        return (major, minor)
    }

    /// Extract the iOS version from a runtime identifier like
    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-0" → (18, 0)
    private func parseRuntimeVersion(fromIdentifier identifier: String) -> (Int, Int)? {
        // Match "iOS-XX-Y" at the end of the identifier
        guard let range = identifier.range(of: #"iOS-(\d+)-(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(identifier[range])
        let parts = matched.replacingOccurrences(of: "iOS-", with: "").split(separator: "-")
        guard let major = Int(parts[0]) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return (major, minor)
    }

    package func findDevice(named name: String) async throws -> SimulatorDevice {
        let devices = try await listAvailableDevices()
        guard let device = devices.first(where: { $0.name == name }) else {
            throw CLIError.simulatorNotFound(name: name)
        }
        return device
    }

    package func resolveDevices(_ configs: [DeviceConfig]) async throws -> [ResolvedDevice] {
        // Separate macOS devices (native) from simulator devices
        let simulatorConfigs = configs.filter { !$0.isMacOS }
        let macConfigs = configs.filter { $0.isMacOS }

        var resolved: [ResolvedDevice] = []

        // Resolve simulator-based devices (iOS, iPadOS, watchOS)
        if !simulatorConfigs.isEmpty {
            let allDevices = try await listAvailableDevices()
            let profiles = try await loadDeviceTypeProfiles()

            for config in simulatorConfigs {
                guard let device = allDevices.first(where: { $0.name == config.simulator }) else {
                    throw CLIError.simulatorNotFound(name: config.simulator)
                }

                let size: AppStoreScreenSize
                if let info = profiles[device.deviceTypeIdentifier],
                   (info.productFamily == 1 || info.productFamily == 2 || info.productFamily == 4) {
                    size = AppStoreScreenSize(
                        width: info.width,
                        height: info.height,
                        productFamily: info.productFamily
                    )
                } else {
                    throw CLIError.noMatchingDeviceSize(simulatorName: config.simulator)
                }

                resolved.append(ResolvedDevice(
                    simulatorName: device.name,
                    udid: device.udid,
                    deviceTypeIdentifier: device.deviceTypeIdentifier,
                    appStoreSize: size,
                    isMacOS: false,
                    tests: config.tests
                ))
            }
        }

        // Resolve macOS devices (native, no simulator)
        for config in macConfigs {
            let size = Self.macScreenSize(named: config.simulator)
            resolved.append(ResolvedDevice(
                simulatorName: config.simulator,
                udid: "mac-native",
                deviceTypeIdentifier: "com.apple.platform.macosx",
                appStoreSize: size,
                isMacOS: true,
                tests: config.tests
            ))
        }

        return resolved
    }

    /// Map a macOS device config name to its App Store screenshot size.
    /// Mac App Store requires specific pixel dimensions for screenshots.
    private static func macScreenSize(named name: String) -> AppStoreScreenSize {
        // Parse explicit dimensions from the name, e.g. "Mac 2560x1600"
        let lowered = name.lowercased()
        if lowered.contains("2880x1800") || lowered.contains("2880") {
            return AppStoreScreenSize(width: 2880, height: 1800, productFamily: 6)
        } else if lowered.contains("2560x1600") || lowered.contains("2560") {
            return AppStoreScreenSize(width: 2560, height: 1600, productFamily: 6)
        } else if lowered.contains("1440x900") || lowered.contains("1440") {
            return AppStoreScreenSize(width: 1440, height: 900, productFamily: 6)
        } else if lowered.contains("1280x800") || lowered.contains("1280") {
            return AppStoreScreenSize(width: 1280, height: 800, productFamily: 6)
        }
        // Default to Retina 13" (most common Mac App Store size)
        return AppStoreScreenSize(width: 2560, height: 1600, productFamily: 6)
    }

    /// Erase the simulator to restore a clean state.
    /// Must be called while the simulator is shut down.
    package func erase(_ udid: String) async throws {
        // Ensure simulator is shut down first
        try? await shutdown(udid)
        let result = try await shell.xcrun("simctl", arguments: ["erase", udid])
        if !result.succeeded {
            throw CLIError.simulatorBootFailed(reason: "erase failed: \(result.stderr)")
        }
    }

    /// Delete all simulator clones that share `name` but have a different UDID.
    /// xcodebuild test clones the target simulator on every run; this cleans up leftovers.
    package func deleteClonesOf(name: String, keepUDID: String) async throws {
        let result = try await shell.xcrun("simctl", arguments: ["list", "devices", "available", "--json"])
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SimulatorDeviceList.self, from: data)
        else { return }

        let clones = decoded.devices.values
            .flatMap { $0 }
            .filter { $0.name == name && $0.udid != keepUDID && $0.isAvailable }

        for clone in clones {
            try? await shutdown(clone.udid)
            _ = try? await shell.xcrun("simctl", arguments: ["delete", clone.udid])
        }
    }

    package func boot(_ udid: String) async throws {
        let result = try await shell.xcrun("simctl", arguments: ["boot", udid])
        if !result.succeeded && !result.stderr.contains("current state: Booted") {
            throw CLIError.simulatorBootFailed(reason: result.stderr)
        }
    }

    package func shutdown(_ udid: String) async throws {
        let result = try await shell.xcrun("simctl", arguments: ["shutdown", udid])
        if !result.succeeded && !result.stderr.contains("current state: Shutdown") {
            throw CLIError.simulatorShutdownFailed(reason: result.stderr)
        }
    }

    package func takeScreenshot(_ udid: String, outputPath: String) async throws {
        let result = try await shell.xcrun("simctl", arguments: ["io", udid, "screenshot", outputPath])
        guard result.succeeded else {
            throw CLIError.screenshotFailed(reason: result.stderr)
        }
    }

    package func install(_ udid: String, appPath: String) async throws {
        let result = try await shell.xcrun("simctl", arguments: ["install", udid, appPath])
        guard result.succeeded else {
            throw CLIError.installFailed(reason: result.stderr)
        }
    }

    package func launch(_ udid: String, bundleId: String, arguments: [String] = []) async throws {
        let args = ["launch", udid, bundleId] + arguments
        let result = try await shell.xcrun("simctl", arguments: args)
        guard result.succeeded else {
            throw CLIError.launchFailed(reason: result.stderr)
        }
    }

    package func terminate(_ udid: String, bundleId: String) async throws {
        let result = try await shell.xcrun("simctl", arguments: ["terminate", udid, bundleId])
        // Ignore errors - app may have already exited
        _ = result
    }

    /// Set the simulator's appearance (light or dark mode).
    /// Does not require a reboot - takes effect immediately.
    package func setAppearance(_ appearance: String, udid: String) async throws {
        let style = appearance.lowercased() == "dark" ? "dark" : "light"
        let result = try await shell.xcrun("simctl", arguments: ["ui", udid, "appearance", style])
        if !result.succeeded {
            throw CLIError.appearanceSetFailed(reason: result.stderr)
        }
    }

    /// Override the simulator status bar for clean screenshots.
    /// Uses `xcrun simctl status_bar <udid> override` with the given arguments.
    package func overrideStatusBar(_ udid: String, arguments: String) async throws {
        let args = ["status_bar", udid, "override"] + arguments.split(separator: " ").map(String.init)
        let result = try await shell.xcrun("simctl", arguments: args)
        if !result.succeeded {
            throw CLIError.statusBarFailed(reason: result.stderr)
        }
    }

    /// Clear the status bar override, restoring the default status bar.
    package func clearStatusBar(_ udid: String) async throws {
        let result = try await shell.xcrun("simctl", arguments: ["status_bar", udid, "clear"])
        // Ignore errors - may not have been overridden
        _ = result
    }

    /// Disable the hardware keyboard in the simulator so software keyboard appears.
    /// This is critical for UI tests that use typeText() - without this, XCUITest
    /// fails with "Neither element nor any descendant has keyboard focus".
    package func disableHardwareKeyboard(_ udid: String) async throws {
        let prefsPath = NSHomeDirectory()
            .appending("/Library/Developer/CoreSimulator/Devices/\(udid)/data/Library/Preferences/com.apple.Preferences.plist")
        // Create the plist if it doesn't exist
        if !FileManager.default.fileExists(atPath: prefsPath) {
            _ = try await shell.run("/usr/bin/plutil", arguments: [
                "-create", "binary1", prefsPath
            ])
        }
        _ = try await shell.run("/usr/bin/plutil", arguments: [
            "-replace", "KeyboardConnectHardwareKeyboard", "-bool", "NO", prefsPath
        ])
    }

    /// Set the simulator's language and locale by modifying its .GlobalPreferences.plist.
    /// Requires a reboot for changes to take effect.
    package func setLocale(_ locale: String, udid: String) async throws {
        let prefsPath = NSHomeDirectory()
            .appending("/Library/Developer/CoreSimulator/Devices/\(udid)/data/Library/Preferences/.GlobalPreferences.plist")

        // Parse locale: "en-US" → language="en", locale="en_US"
        // "ja" → language="ja", locale="ja"
        let parts = locale.split(separator: "-", maxSplits: 1)
        let language = String(parts[0])
        let appleLocale = locale.replacingOccurrences(of: "-", with: "_")

        // Set AppleLocale
        let localeResult = try await shell.run("/usr/bin/plutil", arguments: [
            "-replace", "AppleLocale", "-string", appleLocale, prefsPath
        ])
        if !localeResult.succeeded {
            throw CLIError.localeSetFailed(reason: localeResult.stderr)
        }

        // Set AppleLanguages
        let langResult = try await shell.run("/usr/bin/plutil", arguments: [
            "-replace", "AppleLanguages", "-json", "[\"\(language)\"]", prefsPath
        ])
        if !langResult.succeeded {
            throw CLIError.localeSetFailed(reason: langResult.stderr)
        }

        // Reboot for changes to take effect
        try? await shutdown(udid)
        try await boot(udid)
    }
}

// MARK: - simctl devicetypes JSON model

private struct DeviceTypeListResponse: Codable {
    let devicetypes: [DeviceTypeEntry]

    struct DeviceTypeEntry: Codable {
        let name: String
        let bundlePath: String
        let identifier: String
    }
}
