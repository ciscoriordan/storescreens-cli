import Foundation

/// Uploads an `.ipa` to App Store Connect via `xcrun altool --upload-app`
/// using an ASC API key.
///
/// altool requires the .p8 file to be named `AuthKey_<KEY_ID>.p8` and live
/// in one of a handful of hard-coded directories. Rather than touching the
/// user's `~/.appstoreconnect/private_keys/`, we write the key to a fresh
/// tmpdir, point altool at it via `API_PRIVATE_KEYS_DIR`, and remove the
/// tmpdir on exit, matching fastlane's `AltoolTransporterExecutor`.
package actor AltoolUploader {
    package let xcode: XcodeInstall

    package init(xcode: XcodeInstall) {
        self.xcode = xcode
    }

    package enum Platform: String, Sendable {
        case iOS = "ios"
        case macOS = "osx"
        case tvOS = "tvos"
        case visionOS = "visionos"
    }

    /// Upload `ipaPath` to App Store Connect.
    /// - Parameter lineHandler: receives stdout and stderr lines live so
    ///   altool's progress shows through to the user.
    package func upload(
        ipaPath: String,
        platform: Platform = .iOS,
        credentials: ASCCredentials,
        lineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let keyDir = try writeKeyToTmpDir(credentials: credentials)
        defer {
            try? FileManager.default.removeItem(atPath: keyDir)
        }

        let args = [
            "altool",
            "--upload-app",
            "-f", ipaPath,
            "-t", platform.rawValue,
            "--apiKey", credentials.keyID,
            "--apiIssuer", credentials.issuerID,
            "-k", "100000",
        ]

        let env = [
            "DEVELOPER_DIR": xcode.developerDir,
            "API_PRIVATE_KEYS_DIR": keyDir,
        ]
        let result = try await ShellRunner().run(
            "/usr/bin/xcrun",
            arguments: args,
            environment: env,
            stdoutLineHandler: lineHandler
        )
        guard result.succeeded else {
            throw CLIError.uploadFailed(
                output: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    /// Validate `ipaPath` against App Store Connect without uploading.
    /// `altool --validate-app` runs the server-side pre-checks Apple would
    /// run at upload time; useful for a dry-run sanity check.
    package func validate(
        ipaPath: String,
        platform: Platform = .iOS,
        credentials: ASCCredentials,
        lineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let keyDir = try writeKeyToTmpDir(credentials: credentials)
        defer {
            try? FileManager.default.removeItem(atPath: keyDir)
        }

        let args = [
            "altool",
            "--validate-app",
            "-f", ipaPath,
            "-t", platform.rawValue,
            "--apiKey", credentials.keyID,
            "--apiIssuer", credentials.issuerID,
        ]

        let env = [
            "DEVELOPER_DIR": xcode.developerDir,
            "API_PRIVATE_KEYS_DIR": keyDir,
        ]
        let result = try await ShellRunner().run(
            "/usr/bin/xcrun",
            arguments: args,
            environment: env,
            stdoutLineHandler: lineHandler
        )
        guard result.succeeded else {
            throw CLIError.uploadFailed(
                output: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    // MARK: - Private

    private func writeKeyToTmpDir(credentials: ASCCredentials) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("storescreens-altool-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let keyFile = dir.appendingPathComponent("AuthKey_\(credentials.keyID).p8")
        try credentials.privateKeyPEM.write(to: keyFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        return dir.path
    }
}
