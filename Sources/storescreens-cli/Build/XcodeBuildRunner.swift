import Foundation

actor XcodeBuildRunner {
    private let shell = ShellRunner()
    let verbose: Bool
    /// Directory where xcodebuild log files are written. Nil means no log files.
    var logDir: String?

    init(verbose: Bool = false, logDir: String? = nil) {
        self.verbose = verbose
        self.logDir = logDir
    }

    func setLogDir(_ dir: String) {
        self.logDir = dir
    }

    /// Build for testing - produces a .xctestrun file.
    /// Returns the path to the .xctestrun file.
    func buildForTesting(
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

        let result = try await shell.xcodebuild(arguments: args)
        if verbose {
            print(result.stdout)
        }
        writeLog(name: "build-for-testing", result: result)
        guard result.succeeded else {
            throw CLIError.buildFailed(output: result.stderr)
        }

        return try findXCTestRun(in: derivedDataPath)
    }

    /// Run tests without building on a specific simulator (or natively for macOS).
    /// Returns the path to the .xcresult bundle.
    ///
    /// When `testSelectors` is non-empty, each entry becomes its own
    /// `-only-testing <selector>` arg, taking precedence over the target/class
    /// collapse. Used by per-device `tests:` config. Selectors must be
    /// pre-resolved to fully-qualified `Target/Class/method` form by the caller.
    func testWithoutBuilding(
        xctestrunPath: String,
        destinationUDID: String,
        resultBundlePath: String,
        testTarget: String? = nil,
        testClass: String? = nil,
        testSelectors: [String]? = nil,
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

        // Test progress is displayed via file-based log tailing in CaptureCommand
        let result = try await shell.xcodebuild(arguments: args)
        if verbose {
            print(result.stdout)
        }
        // Include device UDID in filename to avoid conflicts during parallel runs
        let shortUDID = String(destinationUDID.prefix(8))
        writeLog(name: "test-\(shortUDID)", result: result)

        // Tests may fail assertions but still produce screenshots
        guard FileManager.default.fileExists(atPath: resultBundlePath) else {
            throw CLIError.resultBundleNotFound(path: resultBundlePath)
        }

        return resultBundlePath
    }

    /// Build and test in a single xcodebuild invocation.
    /// Unlike build-for-testing + test-without-building, this lets XCTest clone the
    /// simulator for a clean state (no stale data, no hardware keyboard issues).
    /// Returns the path to the .xcresult bundle.
    func test(
        project: String?,
        workspace: String?,
        scheme: String,
        destinationUDID: String,
        derivedDataPath: String,
        resultBundlePath: String,
        testTarget: String? = nil,
        testClass: String? = nil,
        testLanguage: String? = nil,
        testRegion: String? = nil
    ) async throws -> String {
        var args = ["test"]
        if let workspace {
            args += ["-workspace", workspace]
        } else if let project {
            args += ["-project", project]
        }
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

        let result = try await shell.xcodebuild(arguments: args)
        if verbose {
            print(result.stdout)
        }
        let shortUDID = String(destinationUDID.prefix(8))
        writeLog(name: "test-\(shortUDID)", result: result)

        // Tests may fail assertions but still produce screenshots
        guard FileManager.default.fileExists(atPath: resultBundlePath) else {
            throw CLIError.resultBundleNotFound(path: resultBundlePath)
        }

        return resultBundlePath
    }

    /// Simple build (for simple capture mode).
    /// Returns path to the .app bundle.
    func build(
        project: String?,
        workspace: String?,
        scheme: String,
        destinationUDID: String,
        derivedDataPath: String
    ) async throws -> String {
        var args = ["build"]
        if let workspace {
            args += ["-workspace", workspace]
        } else if let project {
            args += ["-project", project]
        }
        args += [
            "-scheme", scheme,
            "-derivedDataPath", derivedDataPath,
            "-destination", "platform=iOS Simulator,id=\(destinationUDID)",
            "CODE_SIGNING_ALLOWED=NO",
        ]

        let result = try await shell.xcodebuild(arguments: args)
        if verbose {
            print(result.stdout)
        }
        writeLog(name: "build", result: result)
        guard result.succeeded else {
            throw CLIError.buildFailed(output: result.stderr)
        }

        return try findAppBundle(in: derivedDataPath)
    }

    /// List available schemes for a project/workspace.
    func listSchemes(project: String?, workspace: String?) async throws -> [String] {
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

    /// Write xcodebuild stdout+stderr to a log file for debugging.
    private func writeLog(name: String, result: ProcessResult) {
        guard let logDir else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let path = (logDir as NSString).appendingPathComponent("\(name).log")
        var content = ""
        if !result.stdout.isEmpty {
            content += result.stdout
        }
        if !result.stderr.isEmpty {
            if !content.isEmpty { content += "\n\n--- stderr ---\n\n" }
            content += result.stderr
        }
        if !content.isEmpty {
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
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

    func findAppBundle(in derivedDataPath: String) throws -> String {
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
            let app = appBundles.first(where: { !$0.contains("UITests") && !$0.contains("-Runner") })
                    ?? appBundles.first
            if let app {
                return (debugDir as NSString).appendingPathComponent(app)
            }
        }

        throw CLIError.buildFailed(output: "No .app bundle found in build products")
    }
}
