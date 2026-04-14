import StorescreensCore
import ArgumentParser
import Foundation

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Scan Swift source files for iPad-unsafe patterns and device assumptions."
    )

    @Option(name: .shortAndLong, help: "Path to storescreens.yml config file.")
    var config: String = "storescreens.yml"

    @Option(name: .shortAndLong, help: "Directory to scan (default: current directory).")
    var directory: String = "."

    @Flag(name: .long, help: "Show verbose output.")
    var verbose: Bool = false

    func run() async throws {
        let logger = Logger(isVerbose: verbose)
        logger.log("storescreens v\(storescreensVersion) check", level: .info)

        // Try to load config for device context; fall back to "assume both" if no config
        let deviceContext: PreflightScanner.DeviceContext
        if let captureConfig = try? ConfigLoader().load(from: config) {
            deviceContext = Self.deviceContext(from: captureConfig)
        } else {
            deviceContext = PreflightScanner.DeviceContext(hasIPad: true, hasIPhone: true)
        }

        logger.header("Preflight Check")
        if deviceContext.hasIPad {
            logger.log("iPad detected in config - running iPad-specific checks", level: .info)
        }

        let scanner = PreflightScanner()
        let result = scanner.scan(directory: directory, deviceContext: deviceContext)

        PreflightScanner.printFindings(result, logger: logger, projectDir: directory)

        if result.hasErrors {
            throw CLIError.preflightFailed(
                errorCount: result.errors.count,
                warningCount: result.warnings.count
            )
        }

        if result.findings.isEmpty {
            logger.log("No issues found", level: .success)
        }

        // Check for stale DerivedData
        if let captureConfig = try? ConfigLoader().load(from: config),
           let persistentPath = captureConfig.derivedDataPath {
            let expandedPath = (persistentPath as NSString).expandingTildeInPath
            if CaptureOrchestrator.isDerivedDataStale(
                derivedDataPath: expandedPath,
                testTarget: captureConfig.testTarget,
                project: captureConfig.project,
                workspace: captureConfig.workspace
            ) {
                logger.log(
                    "\(expandedPath)  [stale-derived-data]\n    Test source files are newer than the compiled test binary. " +
                    "Next capture will clean and rebuild automatically, or run: rm -rf \"\(expandedPath)/Build/Products\"",
                    level: .warning
                )
            }
        }
    }

    static func deviceContext(from config: CaptureConfig) -> PreflightScanner.DeviceContext {
        let hasIPad = config.devices.contains {
            $0.simulator.lowercased().contains("ipad")
        }
        let hasIPhone = config.devices.contains {
            let name = $0.simulator.lowercased()
            return !name.contains("ipad") && !name.contains("watch") && !$0.isMacOS
        }
        let hasMultipleLocales = (config.locales?.count ?? 0) > 1
        return PreflightScanner.DeviceContext(hasIPad: hasIPad, hasIPhone: hasIPhone, hasMultipleLocales: hasMultipleLocales)
    }
}
