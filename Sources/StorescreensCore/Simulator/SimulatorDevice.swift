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

    /// Tolerant of the fields simctl omits for a device whose runtime or device
    /// type is no longer installed. Those are exactly the orphans clone cleanup
    /// exists to remove, and a strict decode would throw the whole listing away
    /// over one of them.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        udid = try container.decode(String.self, forKey: .udid)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(String.self, forKey: .state)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        deviceTypeIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceTypeIdentifier) ?? ""
        lastBootedAt = try container.decodeIfPresent(String.self, forKey: .lastBootedAt)
    }
}

/// A CoreSimulator device set. `xcodebuild test` does not clone into the set
/// Simulator.app shows: it creates `Clone N of <base>` in a private set under
/// `~/Library/Developer/XCTestDevices`, and a simctl call only reaches a device
/// there when it is passed `--set <path>`. Anything that tracks clones (status
/// bar overrides, leftover-clone cleanup) has to cover both sets, or it silently
/// operates on a device the tests never touch.
package enum DeviceSet: Sendable, CaseIterable {
    /// The set Simulator.app and a bare `simctl` use.
    case `default`
    /// Where `xcodebuild test` creates its test clones.
    case xctest

    /// Filesystem path of the set; nil for the default one.
    package var path: String? {
        switch self {
        case .default:
            return nil
        case .xctest:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/XCTestDevices").path
        }
    }

    /// The `--set <path>` prefix for simctl; empty for the default set.
    package var simctlArguments: [String] {
        guard let path else { return [] }
        return ["--set", path]
    }

    /// False when the set has never been created on this machine. Listing a
    /// missing set would have simctl create the directory as a side effect.
    package var exists: Bool {
        guard let path else { return true }
        return FileManager.default.fileExists(atPath: path)
    }
}

/// A device plus the set it lives in, so callers can address it correctly.
package struct LocatedDevice: Sendable {
    package let device: SimulatorDevice
    package let set: DeviceSet

    package init(device: SimulatorDevice, set: DeviceSet) {
        self.device = device
        self.set = set
    }
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
