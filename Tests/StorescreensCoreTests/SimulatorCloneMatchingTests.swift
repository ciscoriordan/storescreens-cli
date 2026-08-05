import XCTest
@testable import StorescreensCore

/// Verifies `SimulatorManager.isClone`, which decides whether a simulator listed
/// by `simctl` is an xcodebuild-created clone of a base device. Getting this
/// match wrong silently breaks the multi-locale clone cleanup: leftover clones
/// would never be deleted, and the 2nd-and-later locale would keep failing with
/// "Busy / Application failed preflight checks". xcodebuild names its clones
/// "Clone N of <base>".
final class SimulatorCloneMatchingTests: XCTestCase {

    func testMatchesXcodebuildCloneNaming() {
        XCTAssertTrue(SimulatorManager.isClone("Clone 1 of iPhone 17 Pro Max", of: "iPhone 17 Pro Max"))
        XCTAssertTrue(SimulatorManager.isClone("Clone 42 of iPhone 17 Pro Max", of: "iPhone 17 Pro Max"))
        // Parenthesised device names (iPad) must still match.
        XCTAssertTrue(SimulatorManager.isClone("Clone 3 of iPad Pro 13-inch (M5)", of: "iPad Pro 13-inch (M5)"))
    }

    func testMatchesLegacyExactName() {
        // Older toolchains reused the exact base name for the clone.
        XCTAssertTrue(SimulatorManager.isClone("iPhone 17 Pro Max", of: "iPhone 17 Pro Max"))
    }

    func testDoesNotMatchUnrelatedDevices() {
        XCTAssertFalse(SimulatorManager.isClone("iPhone 17", of: "iPhone 17 Pro Max"))
        XCTAssertFalse(SimulatorManager.isClone("iPad Pro 13-inch (M5)", of: "iPhone 17 Pro Max"))
        XCTAssertFalse(SimulatorManager.isClone("Apple Watch Series 10", of: "iPhone 17 Pro Max"))
    }

    func testDoesNotMatchCloneOfADifferentButPrefixedDevice() {
        // "iPhone 17 Pro" is a distinct device whose name is a prefix of the
        // base. A clone of it must NOT be treated as a clone of the longer base,
        // otherwise cleanup could delete the wrong device's clone.
        XCTAssertFalse(SimulatorManager.isClone("Clone 1 of iPhone 17 Pro", of: "iPhone 17 Pro Max"))
        XCTAssertFalse(SimulatorManager.isClone("Clone 1 of iPhone 17 Pro Max", of: "iPhone 17 Pro"))
    }

    func testDoesNotMatchArbitraryCloneText() {
        // A user-named device that merely contains "Clone" should not match.
        XCTAssertFalse(SimulatorManager.isClone("My Clone Device", of: "iPhone 17 Pro Max"))
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
