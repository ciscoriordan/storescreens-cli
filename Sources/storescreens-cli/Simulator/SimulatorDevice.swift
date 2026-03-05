import Foundation

struct SimulatorDeviceList: Codable {
    let devices: [String: [SimulatorDevice]]
}

struct SimulatorDevice: Codable, Sendable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
    let deviceTypeIdentifier: String
    let lastBootedAt: String?

    var isBooted: Bool { state == "Booted" }
}

struct ResolvedDevice: Sendable {
    let simulatorName: String
    let udid: String
    let deviceTypeIdentifier: String
    let appStoreSize: AppStoreScreenSize
}
