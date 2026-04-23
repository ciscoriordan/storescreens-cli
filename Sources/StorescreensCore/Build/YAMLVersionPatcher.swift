import Foundation

/// Regex-based patcher for a single field in `storescreens.yml`. Used to
/// sync `app_store_connect.submit.create_version` after a version bump so
/// the yml doesn't drift from the Xcode project.
///
/// Why regex instead of a proper YAML roundtrip: `Yams` can parse and
/// re-emit the whole file but would drop comments and reformat the entire
/// document. This file is user-authored and comment-heavy, so the narrow
/// text replacement is worth the tradeoff.
package enum YAMLVersionPatcher {

    /// Rewrites the `create_version: "X"` value in-place. Matches any indent
    /// level. Returns true when a change was written; false if the key was
    /// absent or already had the target value.
    @discardableResult
    package static func syncCreateVersion(
        yamlPath: String,
        to newVersion: String
    ) throws -> Bool {
        let original = try String(contentsOfFile: yamlPath, encoding: .utf8)
        let updated = try rewrite(createVersion: newVersion, in: original)
        guard updated != original else { return false }
        try updated.write(toFile: yamlPath, atomically: true, encoding: .utf8)
        return true
    }

    /// Pure string rewrite. Exposed for testing.
    package static func rewrite(
        createVersion newVersion: String,
        in text: String
    ) throws -> String {
        // Match `create_version:` at any indent, with or without quotes.
        // Group 1: everything up to and including the colon + whitespace +
        // opening quote (if any).
        // Group 2: the value (excluding closing quote).
        // Group 3: closing quote (if any) + rest of line.
        let pattern = #"(^\s*create_version\s*:\s*)("?)([^"\n\r]*?)(\2)(\s*(?:#.*)?)$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        // Template uses $1 for prefix, then quote + new value + quote, then
        // trailing. Pad with quotes regardless so the output is always
        // quoted (more robust against YAML type coercion for versions
        // like "1.10").
        let replacement = "$1\"\(newVersion)\"$5"
        let updated = regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: replacement
        )
        return updated
    }
}
