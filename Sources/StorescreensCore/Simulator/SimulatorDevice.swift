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

/// Configured devices whose screenshots get the same App Store size label.
///
/// The label (`AppStoreScreenSize.displayName`) becomes the output filename
/// prefix and the manifest's `deviceType`. A UI-test capture names each file
/// `<label>_<testName>.png`, so two devices that share the label write the
/// same files and whichever finishes last overwrites the other. It happens
/// when a config lists two models with the same screen, such as "iPhone 17
/// Pro" and "iPhone 18 Pro" (both "iPhone 6.3\""). Simple mode (no UI tests)
/// is not affected: it names each file after the device's position in the
/// list (`screenshot_001`, `screenshot_002`), so only the UI-test capture
/// paths log `warning`.
package struct SharedDeviceLabel: Sendable, Equatable {
    /// The label the devices share, e.g. `iPhone 6.3"`.
    package let label: String
    /// The simulators that share it, in config order, without repeats.
    package let simulatorNames: [String]
    /// True when App Store Connect puts all of them in the same screenshot
    /// slot: same pixel size, or sizes `ScreenshotDisplayType` resolves to
    /// the same display type. False for devices that only share the label.
    package let sameAppStoreSlot: Bool

    package init(label: String, simulatorNames: [String], sameAppStoreSlot: Bool) {
        self.label = label
        self.simulatorNames = simulatorNames
        self.sameAppStoreSlot = sameAppStoreSlot
    }

    /// One-line warning for the UI-test capture log.
    ///
    /// The shared files hold whichever device's capture wrote them last, so
    /// the warning does not promise which device submit ends up uploading;
    /// it only says that one set of files survives. Within one App Store
    /// size class that is why removing the extra devices loses nothing.
    package var warning: String {
        let names = Self.joinedList(simulatorNames)
        let both = simulatorNames.count == 2 ? "both" : "all"
        let collision = "\(names) are \(both) labeled \"\(label)\", so their UI-test screenshots are saved "
            + "under the same file names and one overwrites the other."
        if sameAppStoreSlot {
            return collision + " Only the capture that finishes last stays on disk, and submit uploads that one; "
                + "they fill the same App Store size class anyway. "
                + "Remove all but one of them from devices: in the config."
        }
        return collision + " App Store Connect takes them in different size classes, but only one device's files "
            + "are left, so submit can fill only one of those classes from this run. "
            + "Capture them in separate runs with different output_dir values, or remove all but one of them from devices: in the config."
    }

    /// "A and B", "A, B, and C".
    private static func joinedList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

extension ResolvedDevice {
    /// Every label shared by two or more differently named devices in
    /// `devices`, in the order the first device of each group appears. Pure,
    /// so the check is testable without a simulator. A simulator listed
    /// twice under the same name is not reported.
    package static func sharedLabels(in devices: [ResolvedDevice]) -> [SharedDeviceLabel] {
        var order: [String] = []
        var groups: [String: [ResolvedDevice]] = [:]
        for device in devices {
            let label = device.appStoreSize.displayName
            if groups[label] == nil { order.append(label) }
            groups[label, default: []].append(device)
        }

        return order.compactMap { label in
            guard let group = groups[label] else { return nil }
            var seen = Set<String>()
            let names = group.map(\.simulatorName).filter { seen.insert($0).inserted }
            guard names.count > 1 else { return nil }

            let portraitSizes = Set(group.map { device -> [Int] in
                let size = device.appStoreSize
                return [min(size.width, size.height), max(size.width, size.height)]
            })
            let displayTypes = group.map(\.appStoreSize.screenshotDisplayType)
            let sameDisplayType = displayTypes.allSatisfy { $0 != nil && $0 == displayTypes.first! }
            return SharedDeviceLabel(
                label: label,
                simulatorNames: names,
                sameAppStoreSlot: portraitSizes.count == 1 || sameDisplayType
            )
        }
    }
}
