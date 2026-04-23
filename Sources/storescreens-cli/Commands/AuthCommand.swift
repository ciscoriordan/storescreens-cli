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
            ~/.storescreens/asc-credentials.yml (created by `auth login`).

            Download your API key from https://appstoreconnect.apple.com/access/api \
            and keep the .p8 file safe; Apple only lets you download it once.
            """,
        subcommands: [AuthLoginCommand.self, AuthLogoutCommand.self, AuthStatusCommand.self],
        defaultSubcommand: AuthStatusCommand.self
    )
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
