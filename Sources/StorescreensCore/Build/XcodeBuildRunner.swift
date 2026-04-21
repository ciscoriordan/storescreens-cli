import Foundation

package actor XcodeBuildRunner {
    private let shell = ShellRunner()
    package let logLevel: Logger.LogLevel
    /// Directory where xcodebuild log files are written. Nil means no log files.
    package var logDir: String?

    package init(logLevel: Logger.LogLevel = .normal, logDir: String? = nil) {
        self.logLevel = logLevel
        self.logDir = logDir
    }

    package func setLogDir(_ dir: String) {
        self.logDir = dir
    }

    /// Build for testing - produces a .xctestrun file.
    /// Returns the path to the .xctestrun file.
    package func buildForTesting(
        project: String?,
        workspace: String?,
        scheme: String,
        derivedDataPath: String,
        isMacOS: Bool = false
    ) async throws -> String {
        var args = ["build-for-testing"]
        if let workspace {
            args += ["-workspace", workspace]
        } else if let project {
            args += ["-project", project]
        }
        if isMacOS {
            args += [
                "-scheme", scheme,
                "-derivedDataPath", derivedDataPath,
                "-destination", "platform=macOS,arch=arm64",
            ]
        } else {
            args += [
                "-scheme", scheme,
                "-derivedDataPath", derivedDataPath,
                "-destination", "generic/platform=iOS Simulator",
                "CODE_SIGNING_ALLOWED=NO",
                "ONLY_ACTIVE_ARCH=YES",
                "EXCLUDED_ARCHS=x86_64",
            ]
        }

        let log = openStreamingLog(name: "build-for-testing")
        let result = try await shell.xcodebuild(
            arguments: args,
            stdoutLineHandler: log.map { makeLogLineHandler(handle: $0.0) }
        )
        if let (handle, _) = log { finalizeLog(handle: handle, stderr: result.stderr) }
        if logLevel == .verbose {
            print(result.stdout)
        }
        guard result.succeeded else {
            throw CLIError.buildFailed(output: result.stderr)
        }

        return try findXCTestRun(in: derivedDataPath)
    }

    /// Run tests without building on a specific simulator.
    /// Returns the path to the .xcresult bundle.
    package func testWithoutBuilding(
        xctestrunPath: String,
        destinationUDID: String,
        resultBundlePath: String,
        testTarget: String? = nil,
        testClass: String? = nil,
        testLanguage: String? = nil,
        testRegion: String? = nil,
        isMacOS: Bool = false
    ) async throws -> String {
        let destination = isMacOS
            ? "platform=macOS,arch=arm64"
            : "platform=iOS Simulator,id=\(destinationUDID)"
        var args = [
            "test-without-building",
            "-xctestrun", xctestrunPath,
            "-destination", destination,
            "-resultBundlePath", resultBundlePath,
            "-parallel-testing-enabled", "NO",
        ]

        if let target = testTarget, let cls = testClass {
            args += ["-only-testing", "\(target)/\(cls)"]
        } else if let target = testTarget {
            args += ["-only-testing", target]
        }

        if let testLanguage {
            args += ["-testLanguage", testLanguage]
        }
        if let testRegion {
            args += ["-testRegion", testRegion]
        }

        // Include device UDID in filename to avoid conflicts during parallel runs
        let shortUDID = String(destinationUDID.prefix(8))
        let log = openStreamingLog(name: "test-\(shortUDID)")
        let result = try await shell.xcodebuild(
            arguments: args,
            stdoutLineHandler: log.map { makeLogLineHandler(handle: $0.0) }
        )
        if let (handle, _) = log { finalizeLog(handle: handle, stderr: result.stderr) }
        if logLevel == .verbose {
            print(result.stdout)
        }

        // Tests may fail assertions but still produce screenshots
        guard FileManager.default.fileExists(atPath: resultBundlePath) else {
            throw CLIError.resultBundleNotFound(path: resultBundlePath)
        }

        return resultBundlePath
    }

    /// Build and test in a single xcodebuild invocation.
    /// Unlike build-for-testing + test-without-building, this lets XCTest clone the
    /// simulator for a clean state (no stale data, no hardware keyboard issues).
    /// For macOS, tests run natively on the host Mac (no simulator needed).
    /// Returns the path to the .xcresult bundle.
    ///
    /// When `testSelectors` is non-empty, each entry becomes its own
    /// `-only-testing <selector>` pair, replacing the target/class collapse. Used
    /// by per-device `tests:` config so e.g. an iPad-only landscape test doesn't
    /// run on the iPhone simulator. Selectors are pre-resolved to fully
    /// qualified `Target/Class/method` strings by the orchestrator.
    package func test(
        project: String?,
        workspace: String?,
        scheme: String,
        destinationUDID: String,
        derivedDataPath: String,
        resultBundlePath: String,
        testTarget: String? = nil,
        testClass: String? = nil,
        testSelectors: [String]? = nil,
        testLanguage: String? = nil,
        testRegion: String? = nil,
        isMacOS: Bool = false,
        liveLineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        var args = ["test"]
        if let workspace {
            args += ["-workspace", workspace]
        } else if let project {
            args += ["-project", project]
        }
        if isMacOS {
            args += [
                "-scheme", scheme,
                "-derivedDataPath", derivedDataPath,
                "-destination", "platform=macOS,arch=arm64",
                "-resultBundlePath", resultBundlePath,
                "-parallel-testing-enabled", "NO",
            ]
        } else {
            args += [
                "-scheme", scheme,
                "-derivedDataPath", derivedDataPath,
                "-destination", "platform=iOS Simulator,id=\(destinationUDID)",
                "-resultBundlePath", resultBundlePath,
                "-parallel-testing-enabled", "NO",
                "CODE_SIGNING_ALLOWED=NO",
                "ONLY_ACTIVE_ARCH=YES",
                "EXCLUDED_ARCHS=x86_64",
            ]
        }

        if let selectors = testSelectors, !selectors.isEmpty {
            for selector in selectors {
                args += ["-only-testing", selector]
            }
        } else if let target = testTarget, let cls = testClass {
            args += ["-only-testing", "\(target)/\(cls)"]
        } else if let target = testTarget {
            args += ["-only-testing", target]
        }

        if let testLanguage {
            args += ["-testLanguage", testLanguage]
        }
        if let testRegion {
            args += ["-testRegion", testRegion]
        }

        let shortUDID = String(destinationUDID.prefix(8))
        let log = openStreamingLog(name: "test-\(shortUDID)")
        let result = try await shell.xcodebuild(
            arguments: args,
            stdoutLineHandler: log.map { makeLogLineHandler(handle: $0.0, liveLineHandler: liveLineHandler) }
        )
        if let (handle, _) = log { finalizeLog(handle: handle, stderr: result.stderr) }
        if logLevel == .verbose {
            print(result.stdout)
        }

        // Detect hard build failures (package resolution, compile errors) that prevent any
        // screenshots from being captured. These must be distinguished from test assertion
        // failures, which also set a non-zero exit code but DO produce screenshots.
        // Check for known fatal patterns in stderr.
        if !result.succeeded {
            let hardFailurePatterns = [
                "Could not resolve package dependencies",
                "** BUILD FAILED **",
                "Couldn't update repository",
                "error: build had compilation errors",
            ]
            if hardFailurePatterns.contains(where: { result.stderr.contains($0) }) {
                throw CLIError.buildFailed(output: result.stderr)
            }
        }

        // Tests may fail assertions but still produce screenshots
        guard FileManager.default.fileExists(atPath: resultBundlePath) else {
            throw CLIError.resultBundleNotFound(path: resultBundlePath)
        }

        return resultBundlePath
    }

    /// Simple build (for simple capture mode).
    /// Returns path to the .app bundle.
    package func build(
        project: String?,
        workspace: String?,
        scheme: String,
        destinationUDID: String,
        derivedDataPath: String,
        isMacOS: Bool = false
    ) async throws -> String {
        var args = ["build"]
        if let workspace {
            args += ["-workspace", workspace]
        } else if let project {
            args += ["-project", project]
        }
        if isMacOS {
            args += [
                "-scheme", scheme,
                "-derivedDataPath", derivedDataPath,
                "-destination", "platform=macOS,arch=arm64",
            ]
        } else {
            args += [
                "-scheme", scheme,
                "-derivedDataPath", derivedDataPath,
                "-destination", "platform=iOS Simulator,id=\(destinationUDID)",
                "CODE_SIGNING_ALLOWED=NO",
            ]
        }

        let log = openStreamingLog(name: "build")
        let result = try await shell.xcodebuild(
            arguments: args,
            stdoutLineHandler: log.map { makeLogLineHandler(handle: $0.0) }
        )
        if let (handle, _) = log { finalizeLog(handle: handle, stderr: result.stderr) }
        if logLevel == .verbose {
            print(result.stdout)
        }
        guard result.succeeded else {
            throw CLIError.buildFailed(output: result.stderr)
        }

        return try findAppBundle(in: derivedDataPath)
    }

    /// List available schemes for a project/workspace.
    package func listSchemes(project: String?, workspace: String?) async throws -> [String] {
        var args = ["-list", "-json"]
        if let workspace {
            args += ["-workspace", workspace]
        } else if let project {
            args += ["-project", project]
        }

        let result = try await shell.xcodebuild(arguments: args)
        guard result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let ws = obj["workspace"] as? [String: Any],
           let schemes = ws["schemes"] as? [String] {
            return schemes
        }
        if let proj = obj["project"] as? [String: Any],
           let schemes = proj["schemes"] as? [String] {
            return schemes
        }
        return []
    }

    // MARK: - Private

    /// Create a streaming log file and return the handle + path.
    /// Lines are appended in real-time so `tail -f` works during the build.
    private func openStreamingLog(name: String) -> (FileHandle, String)? {
        guard let logDir else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let path = (logDir as NSString).appendingPathComponent("\(name).log")
        fm.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        return (handle, path)
    }

    /// Build a line handler that appends each line to the given file handle,
    /// and optionally forwards all lines to a live handler (e.g. for non-TTY CLI output).
    private func makeLogLineHandler(
        handle: FileHandle,
        liveLineHandler: (@Sendable (String) -> Void)? = nil
    ) -> @Sendable (String) -> Void {
        let h = handle
        return { line in
            if let data = (line + "\n").data(using: .utf8) {
                h.write(data)
            }
            liveLineHandler?(line)
        }
    }

    /// Append stderr to an already-open log file, then close it.
    private func finalizeLog(handle: FileHandle, stderr: String) {
        if !stderr.isEmpty {
            if let data = ("\n\n--- stderr ---\n\n" + stderr).data(using: .utf8) {
                handle.write(data)
            }
        }
        try? handle.close()
    }

    private func findXCTestRun(in derivedDataPath: String) throws -> String {
        let productsDir = (derivedDataPath as NSString)
            .appendingPathComponent("Build/Products")
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: productsDir) else {
            throw CLIError.xctestrunNotFound(derivedDataPath: derivedDataPath)
        }

        guard let xctestrun = contents.first(where: { $0.hasSuffix(".xctestrun") }) else {
            throw CLIError.xctestrunNotFound(derivedDataPath: derivedDataPath)
        }

        return (productsDir as NSString).appendingPathComponent(xctestrun)
    }

    package func findAppBundle(in derivedDataPath: String) throws -> String {
        let fm = FileManager.default
        // Check iOS simulator products first, then macOS
        let searchDirs = [
            (derivedDataPath as NSString).appendingPathComponent("Build/Products/Debug-iphonesimulator"),
            (derivedDataPath as NSString).appendingPathComponent("Build/Products/Debug"),
        ]

        for debugDir in searchDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: debugDir) else {
                continue
            }

            let appBundles = contents.filter { $0.hasSuffix(".app") }
            // Prefer bundles that aren't UITest runners (e.g. skip CCWCalcUITests-Runner.app)
            let app = appBundles.first(where: { !$0.contains("UITests") && !$0.contains("-Runner") })
                    ?? appBundles.first
            if let app {
                return (debugDir as NSString).appendingPathComponent(app)
            }
        }

        throw CLIError.buildFailed(output: "No .app bundle found in build products")
    }
}
