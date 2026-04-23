import Foundation

/// Runs `xcodebuild archive` and `xcodebuild -exportArchive` against a
/// user-pinned `DEVELOPER_DIR` (so a beta-selected xcode-select doesn't
/// leak into the build).
package actor ArchiveRunner {
    package let xcode: XcodeInstall
    package let logLevel: Logger.LogLevel

    package init(xcode: XcodeInstall, logLevel: Logger.LogLevel = .normal) {
        self.xcode = xcode
        self.logLevel = logLevel
    }

    /// Runs `xcodebuild archive`.
    ///
    /// - Parameter destination: defaults to `generic/platform=iOS` (fastlane's default).
    package func archive(
        project: String?,
        workspace: String?,
        scheme: String,
        configuration: String,
        destination: String,
        archivePath: String,
        derivedDataPath: String?,
        allowProvisioningUpdates: Bool,
        lineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws {
        var args: [String] = ["archive"]
        if let workspace {
            args += ["-workspace", workspace]
        } else if let project {
            args += ["-project", project]
        }
        args += ["-scheme", scheme]
        args += ["-configuration", configuration]
        args += ["-destination", destination]
        args += ["-archivePath", archivePath]
        if let derivedDataPath {
            args += ["-derivedDataPath", derivedDataPath]
        }
        if allowProvisioningUpdates {
            // Lets Xcode contact the dev portal to create/download missing
            // profiles and certs at archive time under automatic signing.
            args += ["-allowProvisioningUpdates"]
        }

        let env = ["DEVELOPER_DIR": xcode.developerDir]
        let result = try await ShellRunner().run(
            "/usr/bin/xcodebuild",
            arguments: args,
            environment: env,
            stdoutLineHandler: lineHandler
        )
        if logLevel == .verbose {
            print(result.stdout)
        }
        guard result.succeeded else {
            throw CLIError.archiveFailed(
                output: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    /// Runs `xcodebuild -exportArchive`, then returns the path to the
    /// produced `.ipa` inside `exportPath`.
    package func export(
        archivePath: String,
        exportPath: String,
        exportOptionsPlistPath: String,
        allowProvisioningUpdates: Bool,
        lineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        var args: [String] = [
            "-exportArchive",
            "-archivePath", archivePath,
            "-exportPath", exportPath,
            "-exportOptionsPlist", exportOptionsPlistPath,
        ]
        if allowProvisioningUpdates {
            args += ["-allowProvisioningUpdates"]
        }

        let env = ["DEVELOPER_DIR": xcode.developerDir]
        let result = try await ShellRunner().run(
            "/usr/bin/xcodebuild",
            arguments: args,
            environment: env,
            stdoutLineHandler: lineHandler
        )
        if logLevel == .verbose {
            print(result.stdout)
        }
        guard result.succeeded else {
            throw CLIError.exportFailed(
                reason: result.stderr.isEmpty
                    ? String(result.stdout.suffix(500))
                    : String(result.stderr.suffix(500))
            )
        }

        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: exportPath)) ?? []
        guard let ipa = entries.first(where: { $0.hasSuffix(".ipa") }) else {
            throw CLIError.exportFailed(reason: "no .ipa produced in \(exportPath)")
        }
        return "\(exportPath)/\(ipa)"
    }
}
