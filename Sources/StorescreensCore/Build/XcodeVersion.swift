import Foundation

/// Reads and writes `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in a
/// `project.pbxproj`. Writes bump every occurrence across all configs and
/// targets, mirroring `agvtool new-marketing-version` / `new-version -all`.
///
/// Why text manipulation rather than `agvtool`: many real-world Xcode
/// projects don't have `VERSIONING_SYSTEM = apple-generic` configured on
/// every target, in which case agvtool either silently ignores them or fails
/// with cryptic errors (e.g. trying to open a path named "YES"). Direct
/// pbxproj edit is more reliable and preserves the project's existing
/// formatting.
package enum XcodeVersion {
    package struct State: Sendable {
        /// Marketing version string (e.g. `"1.2.0"`). Taken from the first
        /// `MARKETING_VERSION = X.Y.Z;` line. All targets normally match.
        package let marketingVersion: String
        /// Build number (e.g. `"42"`). Taken from the first
        /// `CURRENT_PROJECT_VERSION = N;` line.
        package let buildNumber: String
    }

    package struct Change: Sendable {
        package let setting: String
        package let oldValue: String
        package let newValue: String
    }

    /// Reads the current marketing version + build number from a `.xcodeproj`
    /// directory or a `project.pbxproj` file path. Takes the first occurrence
    /// of each setting (they match across targets in well-formed projects).
    package static func read(projectPath: String) throws -> State {
        let pbxproj = try resolvePbxproj(path: projectPath)
        let text = try String(contentsOfFile: pbxproj, encoding: .utf8)

        guard let marketing = firstValue(of: "MARKETING_VERSION", in: text) else {
            throw CLIError.versionProbeFailed(
                reason: "MARKETING_VERSION not found in \(pbxproj). Set it in Xcode (General -> Identity -> Version)."
            )
        }
        guard let build = firstValue(of: "CURRENT_PROJECT_VERSION", in: text) else {
            throw CLIError.versionProbeFailed(
                reason: "CURRENT_PROJECT_VERSION not found in \(pbxproj). Set it in Xcode (General -> Identity -> Build)."
            )
        }
        return State(marketingVersion: marketing, buildNumber: build)
    }

    /// Rewrites `MARKETING_VERSION` and/or `CURRENT_PROJECT_VERSION` across
    /// every config of every target. Returns the list of changes made. A
    /// parameter left nil leaves that setting untouched.
    @discardableResult
    package static func write(
        projectPath: String,
        marketingVersion: String?,
        buildNumber: String?
    ) throws -> [Change] {
        let pbxproj = try resolvePbxproj(path: projectPath)
        var text = try String(contentsOfFile: pbxproj, encoding: .utf8)
        var changes: [Change] = []

        if let newMarketing = marketingVersion {
            let (updated, applied) = try replaceSetting(
                name: "MARKETING_VERSION",
                newValue: newMarketing,
                in: text
            )
            text = updated
            changes.append(contentsOf: applied)
        }
        if let newBuild = buildNumber {
            let (updated, applied) = try replaceSetting(
                name: "CURRENT_PROJECT_VERSION",
                newValue: newBuild,
                in: text
            )
            text = updated
            changes.append(contentsOf: applied)
        }

        if !changes.isEmpty {
            try text.write(toFile: pbxproj, atomically: true, encoding: .utf8)
        }
        return changes
    }

    // MARK: - Internals

    /// Given either `.xcodeproj` dir or a pbxproj path, returns the pbxproj path.
    private static func resolvePbxproj(path: String) throws -> String {
        let fm = FileManager.default
        if path.hasSuffix(".pbxproj") {
            guard fm.fileExists(atPath: path) else {
                throw CLIError.versionProbeFailed(reason: "\(path) does not exist")
            }
            return path
        }
        let candidate = "\(path)/project.pbxproj"
        guard fm.fileExists(atPath: candidate) else {
            throw CLIError.versionProbeFailed(
                reason: "no project.pbxproj inside \(path)"
            )
        }
        return candidate
    }

    /// Matches lines like `	MARKETING_VERSION = 1.2.0;` or with extra
    /// indentation. Captures the exact value between `= ` and `;`.
    private static func firstValue(of setting: String, in text: String) -> String? {
        let pattern = #"\#(setting)\s*=\s*([^;\n]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    /// Replaces every `<name> = <old>;` occurrence with `<name> = <new>;`.
    /// Returns the updated text and the list of distinct old-value -> new-value
    /// transitions observed. If no occurrences match, throws.
    private static func replaceSetting(
        name: String,
        newValue: String,
        in text: String
    ) throws -> (String, [Change]) {
        let pattern = #"(\#(name)\s*=\s*)([^;\n]+)(;)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsText = text as NSString
        let matches = regex.matches(
            in: text, options: [],
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else {
            throw CLIError.versionProbeFailed(
                reason: "\(name) not found in pbxproj; cannot bump."
            )
        }

        // Collect old values (unique), then rebuild the string.
        var seenOld: Set<String> = []
        var result = ""
        var cursor = 0
        for m in matches {
            let prefix = nsText.substring(with: m.range(at: 1))
            let old = nsText.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let suffix = nsText.substring(with: m.range(at: 3))
            // Append text before the match
            let preLen = m.range.location - cursor
            if preLen > 0 {
                result += nsText.substring(with: NSRange(location: cursor, length: preLen))
            }
            // Only rewrite when the value differs (keeps mtimes stable when
            // called in idempotent configurations).
            if old == newValue {
                result += nsText.substring(with: m.range)
            } else {
                result += prefix + newValue + suffix
                seenOld.insert(old)
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < nsText.length {
            result += nsText.substring(from: cursor)
        }

        let changes = seenOld
            .sorted()
            .map { Change(setting: name, oldValue: $0, newValue: newValue) }
        return (result, changes)
    }
}
