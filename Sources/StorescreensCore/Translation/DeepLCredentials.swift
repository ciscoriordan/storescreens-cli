import Foundation
import Yams

/// DeepL API credentials for the bring-your-own-key metadata translator.
/// Resolved from the environment first (`DEEPL_API_KEY`, or `DEEPL_AUTH_KEY`),
/// then from a YAML file at `~/.storescreens/deepl-credentials.yml`. Mirrors
/// `ASCCredentials` / `ASCCredentialResolver` so the two key stores behave the
/// same way.
package struct DeepLCredentials: Sendable {
    package let apiKey: String
    /// Which source the key came from. Useful for `translate auth status`.
    package let source: Source

    package enum Source: String, Sendable {
        case environment
        case file
    }

    package init(apiKey: String, source: Source) {
        self.apiKey = apiKey
        self.source = source
    }

    /// True when this is a DeepL API Free key. Free keys carry the `:fx`
    /// suffix and must hit `api-free.deepl.com`; paid keys hit `api.deepl.com`.
    package var isFreeTier: Bool { apiKey.hasSuffix(":fx") }

    /// Base URL DeepL routes this key to. Free vs paid is chosen by the key
    /// suffix, exactly as DeepL's own client libraries do.
    package var apiBaseURL: URL {
        isFreeTier
            ? URL(string: "https://api-free.deepl.com")!
            : URL(string: "https://api.deepl.com")!
    }
}

package enum DeepLCredentialError: Error, CustomStringConvertible {
    case notConfigured(hint: String)
    case missingField(field: String, source: String)
    case cannotReadFile(path: String, underlying: Error)
    case invalidYAML(path: String, underlying: Error)

    package var description: String {
        switch self {
        case .notConfigured(let hint):
            return "DeepL API key not configured. \(hint)"
        case .missingField(let field, let source):
            return "DeepL credentials missing `\(field)` from \(source)"
        case .cannotReadFile(let path, let underlying):
            return "cannot read DeepL credentials at \(path): \(underlying)"
        case .invalidYAML(let path, let underlying):
            return "invalid YAML at \(path): \(underlying)"
        }
    }
}

/// Resolution strategy. Env (`DEEPL_API_KEY` / `DEEPL_AUTH_KEY`) takes priority
/// over the file at `~/.storescreens/deepl-credentials.yml`.
package enum DeepLCredentialResolver {

    /// Default file location: ~/.storescreens/deepl-credentials.yml
    package static let defaultFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".storescreens/deepl-credentials.yml").path
    }()

    /// Environment variable names checked, in order.
    package static let envVarNames = ["DEEPL_API_KEY", "DEEPL_AUTH_KEY"]

    /// Returns credentials if configured anywhere, else throws.
    package static func resolve(filePath: String? = nil) throws -> DeepLCredentials {
        if let fromEnv = resolveFromEnvironment() {
            return fromEnv
        }
        let path = filePath ?? defaultFilePath
        if FileManager.default.fileExists(atPath: path) {
            return try resolveFromFile(path: path)
        }
        throw DeepLCredentialError.notConfigured(
            hint: "Set DEEPL_API_KEY - or run `storescreens translate auth login`. "
                + "Get a key (free tier available) at https://www.deepl.com/pro-api."
        )
    }

    /// True if ANY source would produce credentials. Used by `auth status` so
    /// it can report cleanly instead of throwing.
    package static func isConfigured(filePath: String? = nil) -> Bool {
        if resolveFromEnvironment() != nil { return true }
        return FileManager.default.fileExists(atPath: filePath ?? defaultFilePath)
    }

    // MARK: - Environment

    private static func resolveFromEnvironment() -> DeepLCredentials? {
        let env = ProcessInfo.processInfo.environment
        for name in envVarNames {
            if let value = env[name], !value.isEmpty {
                return DeepLCredentials(apiKey: value, source: .environment)
            }
        }
        return nil
    }

    // MARK: - File

    private struct StoredFile: Decodable {
        let api_key: String?
    }

    private static func resolveFromFile(path: String) throws -> DeepLCredentials {
        let url = URL(fileURLWithPath: path)
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw DeepLCredentialError.cannotReadFile(path: path, underlying: error)
        }
        let decoded: StoredFile
        do {
            decoded = try YAMLDecoder().decode(StoredFile.self, from: contents)
        } catch {
            throw DeepLCredentialError.invalidYAML(path: path, underlying: error)
        }
        guard let apiKey = decoded.api_key, !apiKey.isEmpty else {
            throw DeepLCredentialError.missingField(field: "api_key", source: path)
        }
        return DeepLCredentials(apiKey: apiKey, source: .file)
    }

    /// Writes the key to the default file path with 0600 permissions.
    package static func write(apiKey: String, to filePath: String? = nil) throws {
        let path = filePath ?? defaultFilePath
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        struct Out: Encodable { let api_key: String }
        let yaml = try YAMLEncoder().encode(Out(api_key: apiKey))
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    package static func deleteStoredFile(filePath: String? = nil) throws {
        let path = filePath ?? defaultFilePath
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}
