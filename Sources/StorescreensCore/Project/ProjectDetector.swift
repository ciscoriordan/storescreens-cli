import Foundation

package struct ProjectDetector {
    private let shell = ShellRunner()

    package init() {}

    /// Find .xcodeproj and .xcworkspace in the current directory.
    package func detectProjectFile() -> (project: String?, workspace: String?) {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: ".")) ?? []

        let workspace = contents.first { $0.hasSuffix(".xcworkspace") }
        let project = contents.first { $0.hasSuffix(".xcodeproj") }

        return (project, workspace)
    }

    /// Detect the first scheme from the project or workspace.
    /// If a workspace is present but has no schemes, falls back to the project.
    package func detectScheme(project: String?, workspace: String?) async -> String? {
        // Try workspace first
        if let ws = workspace {
            let args = ["-list", "-json", "-workspace", ws]
            if let result = try? await shell.xcodebuild(arguments: args),
               result.succeeded,
               let scheme = parseFirstScheme(from: result.stdout) {
                return scheme
            }
        }
        // Fall back to project (or use project directly when no workspace)
        if let proj = project {
            let args = ["-list", "-json", "-project", proj]
            if let result = try? await shell.xcodebuild(arguments: args),
               result.succeeded,
               let scheme = parseFirstScheme(from: result.stdout) {
                return scheme
            }
        }
        return nil
    }

    /// Query xcodebuild for the project's IPHONEOS_DEPLOYMENT_TARGET.
    package func detectDeploymentTarget(
        project: String?, workspace: String?, scheme: String
    ) async -> String? {
        var args = ["-showBuildSettings", "-scheme", scheme, "-json"]
        if let ws = workspace {
            args += ["-workspace", ws]
        } else if let proj = project {
            args += ["-project", proj]
        } else {
            return nil
        }

        guard let result = try? await shell.xcodebuild(arguments: args),
              result.succeeded else {
            return nil
        }

        // Parse JSON array of build settings
        guard let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return parseDeploymentTargetFromText(result.stdout)
        }

        for entry in array {
            if let settings = entry["buildSettings"] as? [String: Any],
               let target = settings["IPHONEOS_DEPLOYMENT_TARGET"] as? String {
                return target
            }
        }
        return nil
    }

    /// List targets from the project/workspace. Useful for finding UI test targets.
    package func listTargets(project: String?, workspace: String?) async -> [String] {
        var args = ["-list", "-json"]
        if let ws = workspace {
            args += ["-workspace", ws]
        } else if let proj = project {
            args += ["-project", proj]
        } else {
            return []
        }

        guard let result = try? await shell.xcodebuild(arguments: args),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let project = obj["project"] as? [String: Any],
           let targets = project["targets"] as? [String] {
            return targets
        }

        // Workspaces don't list targets directly; fall back to filesystem scan
        return []
    }

    /// Find UI test targets by name convention (ending in "UITests").
    package func findUITestTargets(project: String?, workspace: String?) async -> [String] {
        // Try xcodebuild first
        let targets = await listTargets(project: project, workspace: workspace)
        let uiTestTargets = targets.filter { $0.hasSuffix("UITests") }
        if !uiTestTargets.isEmpty {
            return uiTestTargets
        }

        // Fallback: scan filesystem for *UITests directories
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: ".")) ?? []
        return contents.filter { name in
            name.hasSuffix("UITests") && {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: name, isDirectory: &isDir) && isDir.boolValue
            }()
        }
    }

    /// List installed iOS simulator runtimes.
    package func listInstalledRuntimes() async -> [InstalledRuntime] {
        guard let result = try? await shell.xcrun("simctl", arguments: ["list", "runtimes", "--json"]),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = obj["runtimes"] as? [[String: Any]] else {
            return []
        }

        return runtimes.compactMap { runtime in
            guard let version = runtime["version"] as? String,
                  let identifier = runtime["identifier"] as? String,
                  let isAvailable = runtime["isAvailable"] as? Bool,
                  identifier.contains("iOS") else {
                return nil
            }
            return InstalledRuntime(version: version, identifier: identifier, isAvailable: isAvailable)
        }
    }

    /// Check that compatible simulators cover all required App Store screenshot sizes.
    package func warnMissingRequiredSizes(
        sizeMap: [String: AppStoreScreenSize],
        logger: Logger
    ) {
        for gap in Self.sizeCoverageGaps(in: Array(sizeMap.values)) {
            logger.log(gap.message, level: gap.severity == .error ? .error : .warning)
        }
    }

    /// A screenshot size class the available simulators do not cover.
    package struct SizeCoverageGap: Sendable, Equatable {
        package enum Severity: Sendable { case error, warning }
        /// `.error` when App Store Connect cannot take the app's screenshots
        /// without it, `.warning` for a recommended class.
        package let severity: Severity
        package let message: String
    }

    /// The gaps `warnMissingRequiredSizes` logs for simulators with `sizes`,
    /// in log order. Pure, so the check is testable without a simulator; the
    /// CLI's copy of `ProjectDetector` calls it too.
    package static func sizeCoverageGaps(in sizes: [AppStoreScreenSize]) -> [SizeCoverageGap] {
        var gaps: [SizeCoverageGap] = []
        let availableNames = Set(sizes.map(\.displayName))

        // The iPhone checks go by App Store Connect display type, not by
        // label. ScreenshotDisplayType is the source of truth for which slot
        // a pixel size fills; the labels do not line up with those slots
        // (iPhone Air is labeled 6.3" but App Store Connect files it in the
        // 6.9" class), so checking labels let an Air hide a missing 6.3".
        let iPhoneDisplayTypes = Set(sizes.filter(\.isIPhone).compactMap(\.screenshotDisplayType))

        // App Store Connect requires one iPhone set: 6.9" (APP_IPHONE_67),
        // or 6.5" (APP_IPHONE_65) when there is no 6.9" set. A machine whose
        // largest iPhone is a 12/13 Pro Max or 14 Plus (1284x2778) only has
        // the 6.5" class, which is accepted but not the recommended one.
        //
        // Xcode creates each model's simulator only for some runtimes: the
        // iPhone 17 Pro and 17 Pro Max for iOS 26, the 18 Pro and 18 Pro Max
        // for iOS 27. Which one a machine has depends on its runtimes.
        let has69 = iPhoneDisplayTypes.contains("APP_IPHONE_67")
        let has65 = iPhoneDisplayTypes.contains("APP_IPHONE_65")
        if !has69 && !has65 {
            gaps.append(SizeCoverageGap(
                severity: .error,
                message: "No compatible simulator in the iPhone 6.9\" or 6.5\" class - App Store Connect requires " +
                    "screenshots in one of them. Install a simulator runtime that creates a 6.9\" iPhone: " +
                    "iOS 27 runtimes create iPhone 18 Pro Max, iOS 26 runtimes iPhone 17 Pro Max, " +
                    "older runtimes iPhone 15 or 16 Pro Max."
            ))
        } else if !has69 {
            gaps.append(SizeCoverageGap(
                severity: .warning,
                message: "The largest compatible iPhone simulator is in the 6.5\" class. App Store Connect accepts " +
                    "6.5\" screenshots when there are no 6.9\" ones, but a 6.9\" simulator is recommended: " +
                    "iOS 27 runtimes create iPhone 18 Pro Max, iOS 26 runtimes iPhone 17 Pro Max."
            ))
        }

        let hasStandardIPhone = iPhoneDisplayTypes.contains("APP_IPHONE_61")
        if !hasStandardIPhone && (has69 || has65) {
            gaps.append(SizeCoverageGap(
                severity: .warning,
                message: "No compatible simulator in the iPhone 6.3\" class. " +
                    "For a second size class, install a runtime that creates one: iOS 27 runtimes create " +
                    "iPhone 18 Pro, iOS 26 runtimes iPhone 17 Pro."
            ))
        }

        let hasAnyIPad = availableNames.contains(where: { $0.hasPrefix("iPad") })
        if hasAnyIPad {
            let hasLargeIPad = availableNames.contains("iPad Pro 13\"") ||
                               availableNames.contains("iPad Pro 12.9\"")
            if !hasLargeIPad {
                gaps.append(SizeCoverageGap(
                    severity: .error,
                    message: "No compatible simulator for iPad Pro 12.9\"/13\" - required by App Store Connect for iPad apps. " +
                        "Install a simulator runtime that includes iPad Pro 13-inch."
                ))
            }
        }
        return gaps
    }

    /// Query xcodebuild for TARGETED_DEVICE_FAMILY and return the supported product family IDs.
    /// Returns [1] for iPhone-only, [2] for iPad-only, [1,2] for universal, nil if unavailable.
    package func detectTargetedDeviceFamilies(
        project: String?, workspace: String?, scheme: String
    ) async -> [Int]? {
        var args = ["-showBuildSettings", "-scheme", scheme, "-json"]
        if let ws = workspace {
            args += ["-workspace", ws]
        } else if let proj = project {
            args += ["-project", proj]
        } else {
            return nil
        }

        guard let result = try? await shell.xcodebuild(arguments: args),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        for entry in array {
            if let settings = entry["buildSettings"] as? [String: Any],
               let raw = settings["TARGETED_DEVICE_FAMILY"] as? String {
                let families = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                return families.isEmpty ? nil : families
            }
        }
        return nil
    }

    /// Detect supported platforms from build settings (e.g. ["iphoneos", "iphonesimulator"]).
    package func detectSupportedPlatforms(
        project: String?, workspace: String?, scheme: String
    ) async -> [String] {
        var args = ["-showBuildSettings", "-scheme", scheme, "-json"]
        if let ws = workspace {
            args += ["-workspace", ws]
        } else if let proj = project {
            args += ["-project", proj]
        } else {
            return []
        }

        guard let result = try? await shell.xcodebuild(arguments: args),
              result.succeeded else {
            return []
        }

        guard let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        for entry in array {
            if let settings = entry["buildSettings"] as? [String: Any],
               let platforms = settings["SUPPORTED_PLATFORMS"] as? String {
                return platforms.split(separator: " ").map { String($0) }
            }
        }
        return []
    }

    // MARK: - Private

    private func parseFirstScheme(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let workspace = obj["workspace"] as? [String: Any],
           let schemes = workspace["schemes"] as? [String],
           let first = schemes.first {
            return first
        }

        if let project = obj["project"] as? [String: Any],
           let schemes = project["schemes"] as? [String],
           let first = schemes.first {
            return first
        }

        return nil
    }

    private func parseDeploymentTargetFromText(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("IPHONEOS_DEPLOYMENT_TARGET = ") {
                return String(trimmed.dropFirst("IPHONEOS_DEPLOYMENT_TARGET = ".count))
            }
        }
        return nil
    }
}

package struct InstalledRuntime {
    package let version: String
    package let identifier: String
    package let isAvailable: Bool

    package init(version: String, identifier: String, isAvailable: Bool) {
        self.version = version
        self.identifier = identifier
        self.isAvailable = isAvailable
    }
}
