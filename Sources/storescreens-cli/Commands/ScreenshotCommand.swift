import StorescreensCore
import ArgumentParser
import Foundation

struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Take a screenshot of a running simulator's current screen."
    )

    @Option(name: .shortAndLong, help: "Simulator name (e.g. \"iPhone 17 Pro\").")
    var simulator: String?

    @Option(name: .long, help: "Simulator UDID (alternative to --simulator).")
    var udid: String?

    @Option(name: .shortAndLong, help: "Output file path (default: ./screenshot.png).")
    var output: String = "screenshot.png"

    @Flag(name: .shortAndLong, help: "Boot the simulator if it is not already running.")
    var boot: Bool = false

    @Flag(name: .long, help: "Show verbose output.")
    var verbose: Bool = false

    func run() async throws {
        let logger = Logger(isVerbose: verbose)
        logger.log("storescreens v\(storescreensVersion) screenshot", level: .info)

        let manager = SimulatorManager()
        let device: SimulatorDevice

        if let udidValue = udid {
            let allDevices = try await manager.listAvailableDevices()
            guard let found = allDevices.first(where: { $0.udid == udidValue }) else {
                throw CLIError.simulatorNotFound(name: udidValue)
            }
            device = found
        } else if let name = simulator {
            device = try await manager.findDevice(named: name)
        } else {
            // Default: find first booted simulator
            let allDevices = try await manager.listAvailableDevices()
            guard let booted = allDevices.first(where: { $0.isBooted }) else {
                throw CLIError.simulatorNotFound(name: "any booted simulator")
            }
            device = booted
            logger.log("Using booted simulator: \(device.name) (\(device.udid))", level: .info)
        }

        if !device.isBooted {
            if boot {
                logger.log("Booting \(device.name)...", level: .info)
                try await manager.boot(device.udid)
            } else {
                throw CLIError.simulatorBootFailed(reason: "Simulator '\(device.name)' is not booted. Pass --boot to boot it automatically.")
            }
        }

        let outputPath = (output as NSString).standardizingPath
        try await manager.takeScreenshot(device.udid, outputPath: outputPath)
        logger.log("Screenshot saved to \(outputPath)", level: .success)
    }
}
