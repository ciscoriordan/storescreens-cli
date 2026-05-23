import Foundation
import Yams

/// App Store Connect API key credentials. Resolved from environment
/// variables first, then from a YAML file at `~/.storescreens/asc-credentials.yml`.
/// The .p8 private key is loaded from disk into `privateKeyPEM` at resolution
/// time so callers don't have to deal with the file system.
package struct ASCCredentials: Sendable {
    package let keyID: String
    package let issuerID: String
    package let privateKeyPEM: String
    /// Which source these credentials came from. Useful for `auth status`.
    package let source: Source

    package enum Source: String, Sendable {
        case environment
        case file
    }

    package init(keyID: String, issuerID: String, privateKeyPEM: String, source: Source) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyPEM = privateKeyPEM
        self.source = source
    }
}

package enum ASCCredentialError: Error, CustomStringConvertible {
    case notConfigured(hint: String)
    case missingField(field: String, source: String)
    case cannotReadKeyFile(path: String, underlying: Error)
    case invalidYAML(path: String, underlying: Error)

    package var description: String {
        switch self {
        case .notConfigured(let hint):
            return "App Store Connect credentials not configured. \(hint)"
        case .missingField(let field, let source):
            return "App Store Connect credentials missing `\(field)` from \(source)"
        case .cannotReadKeyFile(let path, let underlying):
            return "cannot read ASC .p8 key at \(path): \(underlying)"
        case .invalidYAML(let path, let underlying):
            return "invalid YAML at \(path): \(underlying)"
        }
    }
}

/// Resolution strategy. Callers use `ASCCredentialResolver.resolve()` to pick
/// up credentials from whichever source is present, with env taking priority
/// over file.
package enum ASCCredentialResolver {

    /// Default file location: ~/.storescreens/asc-credentials.yml
    package static let defaultFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".storescreens/asc-credentials.yml").path
    }()

    /// Returns credentials if configured anywhere, else throws.
    package static func resolve(filePath: String? = nil) throws -> ASCCredentials {
        if let fromEnv = try resolveFromEnvironment() {
            return fromEnv
        }
        let path = filePath ?? defaultFilePath
        if FileManager.default.fileExists(atPath: path) {
            return try resolveFromFile(path: path)
        }
        throw ASCCredentialError.notConfigured(
            hint: "Set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH - or run `storescreens auth login`."
        )
    }

    /// True if ANY source would produce credentials. Used by `auth status`
    /// to avoid throwing.
    package static func isConfigured(filePath: String? = nil) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["ASC_KEY_ID"] != nil && env["ASC_ISSUER_ID"] != nil && env["ASC_KEY_PATH"] != nil {
            return true
        }
        return FileManager.default.fileExists(atPath: filePath ?? defaultFilePath)
    }

    // MARK: - Environment

    private static func resolveFromEnvironment() throws -> ASCCredentials? {
        let env = ProcessInfo.processInfo.environment
        let keyID = env["ASC_KEY_ID"]
        let issuerID = env["ASC_ISSUER_ID"]
        let keyPath = env["ASC_KEY_PATH"]

        // If none set, fall through to file path.
        if keyID == nil && issuerID == nil && keyPath == nil {
            return nil
        }
        guard let keyID, !keyID.isEmpty else {
            throw ASCCredentialError.missingField(field: "ASC_KEY_ID", source: "environment")
        }
        guard let issuerID, !issuerID.isEmpty else {
            throw ASCCredentialError.missingField(field: "ASC_ISSUER_ID", source: "environment")
        }
        guard let keyPath, !keyPath.isEmpty else {
            throw ASCCredentialError.missingField(field: "ASC_KEY_PATH", source: "environment")
        }
        let pem = try readKeyFile(at: expandTilde(keyPath))
        return ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyPEM: pem, source: .environment)
    }

    // MARK: - File

    private struct StoredFile: Decodable {
        let key_id: String?
        let issuer_id: String?
        let key_path: String?
    }

    private static func resolveFromFile(path: String) throws -> ASCCredentials {
        let url = URL(fileURLWithPath: path)
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ASCCredentialError.cannotReadKeyFile(path: path, underlying: error)
        }
        let decoded: StoredFile
        do {
            decoded = try YAMLDecoder().decode(StoredFile.self, from: contents)
        } catch {
            throw ASCCredentialError.invalidYAML(path: path, underlying: error)
        }
        guard let keyID = decoded.key_id, !keyID.isEmpty else {
            throw ASCCredentialError.missingField(field: "key_id", source: path)
        }
        guard let issuerID = decoded.issuer_id, !issuerID.isEmpty else {
            throw ASCCredentialError.missingField(field: "issuer_id", source: path)
        }
        guard let keyPath = decoded.key_path, !keyPath.isEmpty else {
            throw ASCCredentialError.missingField(field: "key_path", source: path)
        }
        let pem = try readKeyFile(at: expandTilde(keyPath))
        return ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyPEM: pem, source: .file)
    }

    /// Writes credentials to the default file path with 0600 permissions.
    /// `keyPath` is stored verbatim so the .p8 can move independently.
    package static func write(
        keyID: String,
        issuerID: String,
        keyPath: String,
        to filePath: String? = nil
    ) throws {
        let path = filePath ?? defaultFilePath
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = YAMLEncoder()
        struct Out: Encodable {
            let key_id: String
            let issuer_id: String
            let key_path: String
        }
        let yaml = try encoder.encode(Out(key_id: keyID, issuer_id: issuerID, key_path: keyPath))
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    package static func deleteStoredFile(filePath: String? = nil) throws {
        let path = filePath ?? defaultFilePath
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Helpers

    private static func readKeyFile(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ASCCredentialError.cannotReadKeyFile(path: path, underlying: error)
        }
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
