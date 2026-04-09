import ArgumentParser
import Foundation

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available simulators and their App Store size mappings."
    )

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    @Flag(name: .long, help: "Show all simulators, including non-App Store sizes.")
    var all: Bool = false

    @Flag(name: .long, help: "Include Apple Watch simulators.")
    var includeWatch: Bool = false

    @Flag(name: .long, help: "Show Mac App Store screenshot sizes.")
    var includeMac: Bool = false

    func run() async throws {
        let manager = SimulatorManager()
        let devices = try await manager.listAvailableDevices()
        let logger = Logger()

        // Build size lookup from screen dimensions
        var sizeMap: [String: AppStoreScreenSize] = [:]
        for device in devices {
            sizeMap[device.udid] = try await manager.appStoreSize(for: device)
        }

        if json {
            try printJSON(devices, sizeMap: sizeMap)
            return
        }

        logger.header("Available Simulators")

        var filtered = all
            ? devices
            : devices.filter { sizeMap[$0.udid] != nil }

        if !includeWatch {
            filtered = filtered.filter { device in
                !(sizeMap[device.udid]?.isAppleWatch ?? device.name.contains("Watch"))
            }
        }

        if filtered.isEmpty && !includeMac {
            logger.log("No simulators found.", level: .warning)
            return
        }

        // Calculate column widths
        let nameWidth = max(filtered.map(\.name.count).max() ?? 0, 4)
        let stateWidth = 8

        // Header
        let header = String(format: "  %-\(nameWidth)@  %-\(stateWidth)@  %@", "Name" as NSString, "State" as NSString, "App Store Size" as NSString)
        print(header)
        print("  " + String(repeating: "─", count: nameWidth + stateWidth + 20))

        for device in filtered {
            let size = sizeMap[device.udid]
            let sizeStr = size?.displayName ?? "—"
            let stateStr = device.isBooted ? "Booted" : "Shutdown"
            let line = String(format: "  %-\(nameWidth)@  %-\(stateWidth)@  %@",
                              device.name as NSString, stateStr as NSString, sizeStr as NSString)
            print(line)
        }

        let mapped = filtered.filter { sizeMap[$0.udid] != nil }
        print("\n  \(mapped.count) of \(filtered.count) devices map to App Store sizes.")

        if includeMac {
            print("")
            logger.header("Mac App Store Screenshot Sizes")
            print("  macOS apps don't use simulators. Add these to storescreens.yml with platform: macOS.")
            print("")
            let macSizes = [
                ("Mac 2880x1800", "15\" Retina (MacBook Pro 15\")"),
                ("Mac 2560x1600", "13\" Retina (MacBook Pro 13\", Air M1+)"),
                ("Mac 1440x900",  "Non-Retina"),
                ("Mac 1280x800",  "Minimum required"),
            ]
            print("  \(String(format: "%-20s  %s", "Size", "Description"))")
            print("  " + String(repeating: "─", count: 50))
            for (name, desc) in macSizes {
                print("  \(String(format: "%-20s  %s", name, desc))")
            }
            print("")
            print("  Example storescreens.yml entry:")
            print("    - simulator: \"Mac 2560x1600\"")
            print("      platform: macOS")
        }
    }

    private func printJSON(_ devices: [SimulatorDevice], sizeMap: [String: AppStoreScreenSize]) throws {
        struct DeviceEntry: Encodable {
            let name: String
            let udid: String
            let state: String
            let deviceTypeIdentifier: String
            let appStoreSize: String?
        }

        let entries = devices.map { device in
            DeviceEntry(
                name: device.name,
                udid: device.udid,
                state: device.state,
                deviceTypeIdentifier: device.deviceTypeIdentifier,
                appStoreSize: sizeMap[device.udid]?.displayName
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        print(String(data: data, encoding: .utf8) ?? "[]")
    }
}
