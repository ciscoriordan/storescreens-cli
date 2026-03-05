import Foundation

package struct SimulatorDeviceList: Codable {
    package let devices: [String: [SimulatorDevice]]
}

package struct SimulatorDevice: Codable, Sendable {
    package let udid: String
    package let name: String
    package let state: String
    package let isAvailable: Bool
    package let deviceTypeIdentifier: String
    package let lastBootedAt: String?

    package var isBooted: Bool { state == "Booted" }
}

package struct ResolvedDevice: Sendable {
    package let simulatorName: String
    package let udid: String
    package let deviceTypeIdentifier: String
    package let appStoreSize: AppStoreScreenSize

    package init(simulatorName: String, udid: String, deviceTypeIdentifier: String, appStoreSize: AppStoreScreenSize) {
        self.simulatorName = simulatorName
        self.udid = udid
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.appStoreSize = appStoreSize
    }
}
