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
        let availableNames = Set(sizeMap.values.map(\.displayName))

        let hasLargeIPhone = availableNames.contains("iPhone 6.9\"") ||
                             availableNames.contains("iPhone 6.7\"")
        if !hasLargeIPhone {
            logger.log(
                "No compatible simulator for iPhone 6.7\"/6.9\" — required by App Store Connect. " +
                "Install a simulator runtime that includes iPhone 15 Pro Max, 16 Pro Max, or 17 Pro Max.",
                level: .error
            )
        }

        let hasStandardIPhone = availableNames.contains("iPhone 6.1\"") ||
                                availableNames.contains("iPhone 6.3\"")
        if !hasStandardIPhone && hasLargeIPhone {
            logger.log(
                "No compatible simulator for iPhone 6.1\"/6.3\". " +
                "Consider installing a runtime with iPhone 16 or 17 Pro for a second size class.",
                level: .warning
            )
        }

        let hasAnyIPad = availableNames.contains(where: { $0.hasPrefix("iPad") })
        if hasAnyIPad {
            let hasLargeIPad = availableNames.contains("iPad Pro 13\"") ||
                               availableNames.contains("iPad Pro 12.9\"")
            if !hasLargeIPad {
                logger.log(
                    "No compatible simulator for iPad Pro 12.9\"/13\" — required by App Store Connect for iPad apps. " +
                    "Install a simulator runtime that includes iPad Pro 13-inch.",
                    level: .error
                )
            }
        }
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
