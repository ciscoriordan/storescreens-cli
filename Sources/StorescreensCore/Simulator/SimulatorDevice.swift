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
    /// True when this device targets macOS (tests run natively, not in a simulator).
    package let isMacOS: Bool
    /// Per-device test selection, preserved from the source DeviceConfig. When
    /// non-nil and non-empty, the orchestrator passes each entry (resolved by
    /// `DeviceConfig.resolvedTestSelectors`) as a `-only-testing` arg, taking
    /// precedence over the top-level test_class filter.
    package let tests: [String]?

    package init(
        simulatorName: String,
        udid: String,
        deviceTypeIdentifier: String,
        appStoreSize: AppStoreScreenSize,
        isMacOS: Bool = false,
        tests: [String]? = nil
    ) {
        self.simulatorName = simulatorName
        self.udid = udid
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.appStoreSize = appStoreSize
        self.isMacOS = isMacOS
        self.tests = tests
    }
}
