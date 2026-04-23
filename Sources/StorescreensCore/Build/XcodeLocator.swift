import Foundation

package struct XcodeInstall: Sendable {
    /// Path to the `.app` bundle, e.g. `/Applications/Xcode.app`.
    package let appPath: String
    /// Path to `Contents/Developer` inside the bundle. This is what goes into
    /// `DEVELOPER_DIR` when spawning xcodebuild / xcrun.
    package let developerDir: String
    /// `CFBundleShortVersionString`, e.g. `"16.2"`.
    package let version: String
    /// Whether this install looks like a beta (by path name or icon).
    package let isBeta: Bool
}

/// Find Xcode installs on disk and pick the one to use.
///
/// The upload-build command intentionally does NOT trust `xcode-select -p`:
/// on machines where a beta Xcode is selected (common for developers), an
/// App Store archive made with a beta toolchain can still upload to App
/// Store Connect but is rejected at review time. Pinning DEVELOPER_DIR to
/// a production Xcode avoids that silent failure.
package enum XcodeLocator {

    /// Highest-version non-beta Xcode found under `/Applications`.
    /// Throws `CLIError.xcodeNotFound` if none exist.
    package static func findProduction() throws -> XcodeInstall {
        let all = scanApplications()
        let production = all.filter { !$0.isBeta }
        guard let best = production.max(by: { compareVersions($0.version, $1.version) == .orderedAscending }) else {
            if all.isEmpty {
                throw CLIError.xcodeNotFound(reason: "no Xcode*.app found in /Applications")
            }
            let names = all.map { "\($0.appPath) (\($0.version)\($0.isBeta ? ", beta" : ""))" }
            throw CLIError.xcodeNotFound(
                reason: "only beta Xcode(s) found: \(names.joined(separator: ", "))"
            )
        }
        return best
    }

    /// Validate a user-provided Xcode path. Accepts either the `.app` bundle
    /// or the `Contents/Developer` directory inside. Beta installs are
    /// allowed here, since the user explicitly asked for this path.
    package static func atPath(_ raw: String) throws -> XcodeInstall {
        let expanded = (raw as NSString).expandingTildeInPath
        let appPath: String
        if expanded.hasSuffix(".app") {
            appPath = expanded
        } else if expanded.hasSuffix("/Contents/Developer") {
            appPath = String(expanded.dropLast("/Contents/Developer".count))
        } else {
            appPath = expanded
        }
        guard let install = readInstall(at: appPath) else {
            throw CLIError.xcodeNotFound(reason: "\(appPath) is not a valid Xcode.app bundle")
        }
        return install
    }

    /// All Xcode installs under `/Applications`, sorted by descending version.
    /// Used by diagnostics / help output.
    package static func listAll() -> [XcodeInstall] {
        scanApplications().sorted {
            compareVersions($0.version, $1.version) == .orderedDescending
        }
    }

    // MARK: - Internals

    private static func scanApplications() -> [XcodeInstall] {
        let fm = FileManager.default
        let apps = "/Applications"
        guard let entries = try? fm.contentsOfDirectory(atPath: apps) else {
            return []
        }
        return entries.compactMap { name -> XcodeInstall? in
            guard name.hasPrefix("Xcode") && name.hasSuffix(".app") else { return nil }
            return readInstall(at: "\(apps)/\(name)")
        }
    }

    private static func readInstall(at appPath: String) -> XcodeInstall? {
        let infoPlistPath = "\(appPath)/Contents/Info.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: infoPlistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        guard let version = plist["CFBundleShortVersionString"] as? String else {
            return nil
        }
        let developerDir = "\(appPath)/Contents/Developer"
        let iconName = (plist["CFBundleIconName"] as? String) ?? (plist["CFBundleIconFile"] as? String) ?? ""
        let isBeta = appPath.lowercased().contains("beta") ||
                     iconName.lowercased().contains("beta")
        return XcodeInstall(
            appPath: appPath,
            developerDir: developerDir,
            version: version,
            isBeta: isBeta
        )
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").compactMap { Int($0) }
        let r = rhs.split(separator: ".").compactMap { Int($0) }
        let n = max(l.count, r.count)
        for i in 0..<n {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }
}
