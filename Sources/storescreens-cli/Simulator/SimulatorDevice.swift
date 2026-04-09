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
    /// True when this device targets macOS (tests run natively, not in a simulator).
    let isMacOS: Bool

    init(simulatorName: String, udid: String, deviceTypeIdentifier: String, appStoreSize: AppStoreScreenSize, isMacOS: Bool = false) {
        self.simulatorName = simulatorName
        self.udid = udid
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.appStoreSize = appStoreSize
        self.isMacOS = isMacOS
    }
}
