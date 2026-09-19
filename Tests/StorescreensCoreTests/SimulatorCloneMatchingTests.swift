import XCTest
@testable import StorescreensCore

/// Verifies `SimulatorManager.isClone`, which decides whether a simulator listed
/// by `simctl` is an xcodebuild-created clone of a base device. Getting this
/// match wrong silently breaks the multi-locale clone cleanup: leftover clones
/// would never be deleted, and the 2nd-and-later locale would keep failing with
/// "Busy / Application failed preflight checks". xcodebuild names its clones
/// "Clone N of <base>". Matching too much is worse: cleanup deletes whatever
/// matches, so a match on one of the user's own simulators deletes it.
final class SimulatorCloneMatchingTests: XCTestCase {

    func testMatchesXcodebuildCloneNaming() {
        for set in DeviceSet.allCases {
            XCTAssertTrue(SimulatorManager.isClone("Clone 1 of iPhone 17 Pro Max", of: "iPhone 17 Pro Max", in: set))
            XCTAssertTrue(SimulatorManager.isClone("Clone 42 of iPhone 17 Pro Max", of: "iPhone 17 Pro Max", in: set))
            // Parenthesized device names (iPad) must still match.
            XCTAssertTrue(SimulatorManager.isClone("Clone 3 of iPad Pro 13-inch (M5)", of: "iPad Pro 13-inch (M5)", in: set))
        }
    }

    func testMatchesLegacyExactNameOnlyInTheTestSet() {
        // Older toolchains reused the exact base name for the clone, but only
        // ever inside xcodebuild's own set (XCTestDevices).
        XCTAssertTrue(SimulatorManager.isClone("iPhone 17 Pro Max", of: "iPhone 17 Pro Max", in: .xctest))
        // In the default set the same name is the user's own simulator: Xcode
        // creates one per installed runtime ("iPhone 17" on iOS 26.5 and 27.0).
        XCTAssertFalse(SimulatorManager.isClone("iPhone 17 Pro Max", of: "iPhone 17 Pro Max", in: .default))
    }

    func testDoesNotMatchUnrelatedDevices() {
        for set in DeviceSet.allCases {
            XCTAssertFalse(SimulatorManager.isClone("iPhone 17", of: "iPhone 17 Pro Max", in: set))
            XCTAssertFalse(SimulatorManager.isClone("iPad Pro 13-inch (M5)", of: "iPhone 17 Pro Max", in: set))
            XCTAssertFalse(SimulatorManager.isClone("Apple Watch Series 10", of: "iPhone 17 Pro Max", in: set))
        }
    }

    func testDoesNotMatchCloneOfADifferentButPrefixedDevice() {
        // "iPhone 17 Pro" is a distinct device whose name is a prefix of the
        // base. A clone of it must NOT be treated as a clone of the longer base,
        // otherwise cleanup could delete the wrong device's clone.
        XCTAssertFalse(SimulatorManager.isClone("Clone 1 of iPhone 17 Pro", of: "iPhone 17 Pro Max", in: .xctest))
        XCTAssertFalse(SimulatorManager.isClone("Clone 1 of iPhone 17 Pro Max", of: "iPhone 17 Pro", in: .xctest))
    }

    func testDoesNotMatchArbitraryCloneText() {
        // A user-named device that merely contains "Clone" should not match.
        XCTAssertFalse(SimulatorManager.isClone("My Clone Device", of: "iPhone 17 Pro Max", in: .default))
    }
}

/// Verifies which devices `deleteClonesOf` / `settleClones` delete before each
/// `xcodebuild test`. The capture resolves one simulator by name (the one on
/// the newest runtime); the user's other simulators with that name, on other
/// runtimes, are theirs and must survive.
final class CloneCleanupSelectionTests: XCTestCase {

    private func located(
        _ name: String,
        udid: String,
        set: DeviceSet,
        isAvailable: Bool = true
    ) -> LocatedDevice {
        let json = """
        {
          "udid": "\(udid)",
          "name": "\(name)",
          "state": "Shutdown",
          "isAvailable": \(isAvailable),
          "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
          "lastBootedAt": null
        }
        """
        let device = try! JSONDecoder().decode(SimulatorDevice.self, from: Data(json.utf8))
        return LocatedDevice(device: device, set: set)
    }

    private func selected(_ devices: [LocatedDevice], base: String = "iPhone 17", keep: String = "base") -> [String] {
        SimulatorManager.clones(of: base, keeping: keep, in: devices).map(\.device.udid).sorted()
    }

    func testSparesASameNamedSimulatorOnAnotherRuntime() {
        // "iPhone 17" exists on both the iOS 26.5 and the iOS 27.0 runtime.
        // Capturing on the iOS 27.0 one used to delete the iOS 26.5 one.
        let devices = [
            located("iPhone 17", udid: "base", set: .default),
            located("iPhone 17", udid: "ios-26-5", set: .default),
        ]
        XCTAssertEqual(selected(devices), [])
    }

    func testSelectsXcodebuildClonesInEitherSet() {
        let devices = [
            located("iPhone 17", udid: "base", set: .default),
            located("iPhone 17", udid: "ios-26-5", set: .default),
            located("Clone 1 of iPhone 17", udid: "test-set-clone", set: .xctest),
            located("Clone 2 of iPhone 17", udid: "default-set-clone", set: .default),
            located("iPhone 17", udid: "legacy-clone", set: .xctest),
            located("Clone 1 of iPhone 17 Pro", udid: "other-device-clone", set: .xctest),
        ]
        XCTAssertEqual(selected(devices), ["default-set-clone", "legacy-clone", "test-set-clone"])
    }

    func testNeverSelectsTheBaseOrAnUnavailableDevice() {
        let devices = [
            located("iPhone 17", udid: "base", set: .xctest),
            located("Clone 1 of iPhone 17", udid: "unavailable", set: .xctest, isAvailable: false),
        ]
        XCTAssertEqual(selected(devices), [])
    }
}

/// Verifies which devices the XCTestDevices sweep is willing to delete. The
/// sweep is name-agnostic on purpose: any `xcodebuild test` on the machine
/// leaves clones there, and once a couple of dozen pile up CoreSimulator stops
/// creating new ones. Being too eager is the dangerous direction - deleting a
/// clone another test run is using kills that run.
final class TestCloneSweepTests: XCTestCase {

    private func device(
        _ name: String,
        udid: String,
        state: String = "Shutdown",
        isAvailable: Bool = true
    ) -> SimulatorDevice {
        let json = """
        {
          "udid": "\(udid)",
          "name": "\(name)",
          "state": "\(state)",
          "isAvailable": \(isAvailable),
          "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
          "lastBootedAt": null
        }
        """
        return try! JSONDecoder().decode(SimulatorDevice.self, from: Data(json.utf8))
    }

    private func swept(_ devices: [SimulatorDevice], sparing: Set<String> = []) -> [String] {
        SimulatorManager.sweepableTestClones(devices, sparing: sparing).map(\.udid).sorted()
    }

    func testSweepsIdleClonesOfAnyDevice() {
        // The leftovers are usually clones of devices this capture never
        // touches, which is exactly what the name-scoped cleanup misses.
        let devices = [
            device("Clone 1 of iPhone 17 Pro Max", udid: "a"),
            device("Clone 7 of iPad Pro 13-inch (M5)", udid: "b"),
            device("Clone 2 of iPhone 16", udid: "c"),
        ]
        XCTAssertEqual(swept(devices), ["a", "b", "c"])
    }

    func testSparesDevicesInUse() {
        // A booted or mid-transition clone belongs to a test run happening right
        // now, possibly in another terminal.
        let devices = [
            device("Clone 1 of iPhone 17 Pro Max", udid: "booted", state: "Booted"),
            device("Clone 2 of iPhone 17 Pro Max", udid: "booting", state: "Booting"),
            device("Clone 3 of iPhone 17 Pro Max", udid: "creating", state: "Creating"),
            device("Clone 4 of iPhone 17 Pro Max", udid: "shutting-down", state: "Shutting Down"),
            device("Clone 5 of iPhone 17 Pro Max", udid: "idle"),
        ]
        XCTAssertEqual(swept(devices), ["idle"])
    }

    func testSparesExplicitlyBusyDevices() {
        // Covers both the devices this capture is using and the ones the manager
        // finds were touched within the grace window.
        let devices = [
            device("Clone 1 of iPhone 17 Pro Max", udid: "ours"),
            device("Clone 1 of iPhone 16", udid: "just-created"),
            device("Clone 9 of iPhone 16", udid: "stale"),
        ]
        XCTAssertEqual(swept(devices, sparing: ["ours", "just-created"]), ["stale"])
    }

    func testDecodesAListingEntryWithFieldsMissing() throws {
        // simctl drops fields for a device whose runtime or device type is gone.
        // A strict decode would throw away the whole listing over one orphan,
        // silently turning the sweep into a no-op on the machines that need it.
        let json = """
        {"udid": "orphan", "name": "Clone 1 of iPhone 15", "state": "Shutdown"}
        """
        let decoded = try JSONDecoder().decode(SimulatorDevice.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.udid, "orphan")
        XCTAssertEqual(decoded.deviceTypeIdentifier, "")
        XCTAssertEqual(swept([decoded]), ["orphan"])
    }

    func testSweepsClonesWhoseRuntimeIsGone() {
        // An orphaned clone of an uninstalled runtime still occupies the set, so
        // the sweep has to list unavailable devices and delete them too.
        let devices = [device("Clone 1 of iPhone 15", udid: "orphan", isAvailable: false)]
        XCTAssertEqual(swept(devices), ["orphan"])
    }
}
