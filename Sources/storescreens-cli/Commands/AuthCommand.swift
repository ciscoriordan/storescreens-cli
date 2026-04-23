import ArgumentParser
import Foundation
import StorescreensCore

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage App Store Connect API credentials.",
        discussion: """
            Credentials are resolved in this order: (1) environment variables \
            ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH; (2) the config file at \
            ~/.storescreens/asc-credentials.yml (created by `auth login` or `auth init`).

            Download your API key from https://appstoreconnect.apple.com/access/api \
            and keep the .p8 file safe; Apple only lets you download it once.
            """,
        subcommands: [
            AuthInitCommand.self,
            AuthLoginCommand.self,
            AuthLogoutCommand.self,
            AuthStatusCommand.self,
        ],
        defaultSubcommand: AuthStatusCommand.self
    )
}

// MARK: - init

struct AuthInitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Write a boilerplate credentials file and open it in your editor.",
        discussion: """
            Creates ~/.storescreens/asc-credentials.yml (0600 perms) with \
            commented placeholders. Opens the file in $EDITOR, or your \
            default text editor if $EDITOR is unset. Fill in the three fields \
            and verify with `storescreens auth status`.
            """
    )

    @Flag(name: .shortAndLong, help: "Overwrite the existing credentials file if it exists.")
    var force: Bool = false

    @Flag(name: .long, help: "Skip opening the file in an editor after writing.")
    var noOpen: Bool = false

    func run() async throws {
        let logger = Logger()
        let path = ASCCredentialResolver.defaultFilePath
        let url = URL(fileURLWithPath: path)

        if FileManager.default.fileExists(atPath: path) && !force {
            logger.log("credentials file already exists at \(path)", level: .warning)
            print("  use `--force` to overwrite, or just edit the existing file.")
            if !noOpen { openInEditor(path: path) }
            return
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let template = """
            # App Store Connect API credentials for storescreens.
            #
            # 1. Create an API key at https://appstoreconnect.apple.com/access/api
            #    (Admin or App Manager access works)
            # 2. Download the AuthKey_XXXXXX.p8 file; Apple lets you download it ONCE.
            # 3. Fill in the three fields below and save.
            #
            # Verify with: storescreens auth status
            #
            # Want to keep credentials OUT of a file? Set these env vars instead:
            #   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
            # Env vars take priority over this file.

            # 10-character alphanumeric key ID shown next to your key (e.g. ABCDE12345)
            key_id: REPLACE_ME

            # UUID shown at the top of the API Keys page
            issuer_id: REPLACE_ME

            # Absolute path to your downloaded AuthKey_XXXXXX.p8 file (~ is expanded)
            key_path: ~/AuthKey_KEYID.p8
            """
        try template.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        logger.log("wrote boilerplate to \(path) (perms 0600)", level: .success)
        print("  fill in key_id, issuer_id, key_path, then run `storescreens auth status`")

        if !noOpen { openInEditor(path: path) }
    }

    private func openInEditor(path: String) {
        // Prefer $EDITOR if set, else the default macOS text editor.
        let env = ProcessInfo.processInfo.environment
        let task = Process()
        if let editor = env["EDITOR"], !editor.isEmpty {
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "\(editor) \(path.shellQuoted)"]
        } else {
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-t", path]
        }
        do {
            try task.run()
        } catch {
            print("  (could not open automatically: \(error.localizedDescription); open \(path) yourself)")
        }
    }
}

private extension String {
    var shellQuoted: String {
        "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - login

struct AuthLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Prompt for ASC API key credentials and save them."
    )

    @Option(name: .long, help: "App Store Connect API key ID (10-char alphanumeric).")
    var keyId: String?

    @Option(name: .long, help: "Issuer ID (UUID) from the App Store Connect API keys page.")
    var issuerId: String?

    @Option(name: .long, help: "Path to your AuthKey_XXXXXX.p8 private key file.")
    var keyPath: String?

    func run() async throws {
        let logger = Logger()

        let keyID = keyId ?? prompt("Key ID: ")
        let issuerID = issuerId ?? prompt("Issuer ID: ")
        let rawKeyPath = keyPath ?? prompt("Path to .p8: ")
        let expandedKeyPath = (rawKeyPath as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedKeyPath) else {
            logger.log(".p8 file not found at \(expandedKeyPath)", level: .error)
            throw ExitCode(1)
        }
        // Validate the key parses before writing.
        let pem = try String(contentsOfFile: expandedKeyPath, encoding: .utf8)
        let testCreds = ASCCredentials(
            keyID: keyID, issuerID: issuerID, privateKeyPEM: pem, source: .file
        )
        do {
            _ = try ASCJWTSigner.sign(credentials: testCreds)
        } catch {
            logger.log("key failed to parse: \(error)", level: .error)
            throw ExitCode(1)
        }

        try ASCCredentialResolver.write(
            keyID: keyID,
            issuerID: issuerID,
            keyPath: expandedKeyPath
        )

        logger.log(
            "saved to \(ASCCredentialResolver.defaultFilePath) (perms 0600)",
            level: .success
        )
        print("  run `storescreens auth status` to verify.")
    }

    /// Reads a non-echoed line from stdin. Simple readLine for interactive use.
    private func prompt(_ label: String) -> String {
        print(label, terminator: "")
        return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

// MARK: - logout

struct AuthLogoutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Delete the stored ASC credentials file."
    )

    func run() async throws {
        let logger = Logger()
        let path = ASCCredentialResolver.defaultFilePath
        if FileManager.default.fileExists(atPath: path) {
            try ASCCredentialResolver.deleteStoredFile()
            logger.log("deleted \(path)", level: .success)
        } else {
            logger.log("no stored credentials to delete", level: .info)
        }
        print("  (ASC_* env vars are independent and unaffected.)")
    }
}

// MARK: - status

struct AuthStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report which credential source is active and verify it works."
    )

    func run() async throws {
        let logger = Logger()
        logger.header("App Store Connect credentials")

        if !ASCCredentialResolver.isConfigured() {
            logger.log("no credentials configured", level: .warning)
            print("  fix: run `storescreens auth login`")
            print("  or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
            return
        }

        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            logger.log("credentials broken: \(error)", level: .error)
            throw ExitCode(1)
        }

        print("  source:    \(creds.source.rawValue)")
        print("  key_id:    \(creds.keyID)")
        print("  issuer_id: \(creds.issuerID)")

        // Live smoke test — mint a token and hit /v1/users. If the key is
        // bad or the team has revoked it, this will 401.
        let client = ASCClient(credentials: creds)
        print("")
        print("  testing token against /v1/users ...")
        do {
            let result = try await client.get(path: "users", as: UsersResp.self)
            if let first = result.data.first {
                logger.log(
                    "authenticated as \(first.attributes?.username ?? "(unknown)") (\(result.data.count) user(s) visible)",
                    level: .success
                )
            } else {
                logger.log("authenticated (0 users visible on this key's scope)", level: .success)
            }
        } catch let err as ASCClient.APIError {
            logger.log("auth check failed: HTTP \(err.statusCode)", level: .error)
            for d in err.details {
                print("  [\(d.code)] \(d.title): \(d.detail)")
            }
            throw ExitCode(1)
        } catch {
            logger.log("auth check failed: \(error)", level: .error)
            throw ExitCode(1)
        }
    }

    private struct UsersResp: Decodable {
        struct User: Decodable {
            struct Attrs: Decodable { let username: String? }
            let id: String
            let attributes: Attrs?
        }
        let data: [User]
    }
}
