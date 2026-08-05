import XCTest
@testable import StorescreensCore

/// Verifies which simulators `StatusBarKeeper` targets while a UI test runs.
/// This is the fix for captures coming out with the live status bar: xcodebuild
/// runs the tests on `Clone N of <base>`, and the clone does not inherit the
/// base device's `simctl status_bar override` (runtime SpringBoard state, not
/// persisted device data). Get this selection wrong and the override lands on a
/// device no screenshot is ever taken on.
final class StatusBarKeeperTests: XCTestCase {

    private func device(
        _ name: String,
        udid: String,
        state: String = "Booted",
        set: DeviceSet = .xctest
    ) -> LocatedDevice {
        let json = """
        {
          "udid": "\(udid)",
          "name": "\(name)",
          "state": "\(state)",
          "isAvailable": true,
          "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
          "lastBootedAt": null
        }
        """
        let decoded = try! JSONDecoder().decode(SimulatorDevice.self, from: Data(json.utf8))
        return LocatedDevice(device: decoded, set: set)
    }

    private func targets(
        _ devices: [LocatedDevice],
        base: String = "iPhone 17 Pro Max",
        progress: [String: StatusBarKeeper.Progress] = [:],
        applicationsPerDevice: Int = 3,
        failureLimit: Int = 3
    ) -> [String] {
        StatusBarKeeper.devicesNeedingOverride(
            devices: devices,
            baseName: base,
            progress: progress,
            applicationsPerDevice: applicationsPerDevice,
            failureLimit: failureLimit
        ).map(\.device.udid)
    }

    func testTargetsTheBootedCloneTheTestRunsOn() {
        let devices = [
            device("iPhone 17 Pro Max", udid: "base", set: .default),
            device("Clone 1 of iPhone 17 Pro Max", udid: "clone-1"),
        ]
        XCTAssertEqual(targets(devices).sorted(), ["base", "clone-1"])
    }

    func testCloneKeepsTheDeviceSetItWasFoundIn() {
        // The override must be applied with the clone's own `--set`; addressing
        // an XCTestDevices clone through the default set finds nothing.
        let selected = StatusBarKeeper.devicesNeedingOverride(
            devices: [device("Clone 1 of iPhone 17 Pro Max", udid: "clone-1", set: .xctest)],
            baseName: "iPhone 17 Pro Max",
            progress: [:],
            applicationsPerDevice: 3,
            failureLimit: 3
        )
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.set.simctlArguments.first, "--set")
        XCTAssertEqual(
            selected.first?.set.simctlArguments.last,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/XCTestDevices").path
        )
        XCTAssertEqual(DeviceSet.default.simctlArguments, [])
    }

    func testIgnoresCloneOfAnotherDevice() {
        let devices = [
            device("Clone 1 of iPhone 17 Pro Max", udid: "clone-1"),
            device("Clone 1 of iPad Pro 13-inch (M5)", udid: "ipad-clone"),
            device("Clone 2 of iPhone 17 Pro", udid: "prefix-clone"),
        ]
        XCTAssertEqual(targets(devices), ["clone-1"])
    }

    func testIgnoresDevicesThatAreNotBooted() {
        // A clone that is still Creating/Shutdown has no SpringBoard to accept
        // the override; it gets picked up on a later poll once it boots.
        let devices = [
            device("Clone 1 of iPhone 17 Pro Max", udid: "clone-1", state: "Shutdown"),
            device("Clone 2 of iPhone 17 Pro Max", udid: "clone-2", state: "Creating"),
            device("Clone 3 of iPhone 17 Pro Max", udid: "clone-3", state: "Booted"),
        ]
        XCTAssertEqual(targets(devices), ["clone-3"])
    }

    func testStopsAfterTheOverrideHasLandedEnoughTimes() {
        let devices = [device("Clone 1 of iPhone 17 Pro Max", udid: "clone-1")]
        // Re-applied while SpringBoard finishes coming up...
        XCTAssertEqual(
            targets(devices, progress: ["clone-1": .init(successes: 2)]),
            ["clone-1"]
        )
        // ...then left alone, so the poll loop doesn't spawn simctl forever.
        XCTAssertEqual(
            targets(devices, progress: ["clone-1": .init(successes: 3)]),
            []
        )
    }

    func testGivesUpOnADeviceThatKeepsFailing() {
        // A clone being torn down mid-run rejects the override; it must not
        // keep the loop busy for the rest of the test.
        let devices = [device("Clone 1 of iPhone 17 Pro Max", udid: "clone-1")]
        XCTAssertEqual(
            targets(devices, progress: ["clone-1": .init(failures: 2)]),
            ["clone-1"]
        )
        XCTAssertEqual(
            targets(devices, progress: ["clone-1": .init(failures: 3)]),
            []
        )
    }

    func testArgumentsFollowTheConfiguredStatusBarSetting() {
        var config = CaptureConfig(scheme: "App", devices: [], outputDir: "out")
        XCTAssertEqual(StatusBarKeeper.arguments(for: config), StatusBarKeeper.defaultArguments)

        config.statusBar = true
        XCTAssertEqual(StatusBarKeeper.arguments(for: config), StatusBarKeeper.defaultArguments)

        config.statusBarArguments = "--time 9:41 --batteryLevel 100"
        XCTAssertEqual(StatusBarKeeper.arguments(for: config), "--time 9:41 --batteryLevel 100")

        config.statusBar = false
        XCTAssertNil(StatusBarKeeper.arguments(for: config))
    }

    func testTransitionalStatesBlockSettling() {
        XCTAssertTrue(SimulatorManager.isTransitional("Booting"))
        XCTAssertTrue(SimulatorManager.isTransitional("Shutting Down"))
        XCTAssertTrue(SimulatorManager.isTransitional("Creating"))
        XCTAssertFalse(SimulatorManager.isTransitional("Booted"))
        XCTAssertFalse(SimulatorManager.isTransitional("Shutdown"))
    }
}

/// Verifies the classification that decides whether a failed `xcodebuild test`
/// is worth retrying. The busy-simulator failure writes a result bundle just
/// like a failed assertion does, so without matching the message the capture
/// ends with a bare "no screenshots" and loses the whole run.
final class TestRunDiagnosticsTests: XCTestCase {

    func testRecognizesTheBusySimulatorLaunchFailure() {
        let output = """
        2026-08-05 12:00:00.000 xcodebuild[1234:5678] Failed to install or launch the test runner. \
        (Underlying Error: The request was denied by service delegate (SBMainWorkspace) for reason: \
        Busy ("Application failed preflight checks").)
        ** TEST EXECUTE FAILED **
        """
        XCTAssertEqual(
            TestRunDiagnostics.testRunnerLaunchFailure(in: output),
            "Failed to install or launch the test runner"
        )
    }

    func testDoesNotRetryAFailedAssertion() {
        // A test that ran and failed will fail the same way next time; retrying
        // it just burns another run.
        let output = """
        Test Case '-[ScreenshotTests testGenerateAppStoreScreenshots]' started.
        ScreenshotTests.swift:599: error: -[ScreenshotTests testGenerateAppStoreScreenshots] : \
        XCTAssertTrue failed - Home screen did not appear
        ** TEST EXECUTE FAILED **
        """
        XCTAssertNil(TestRunDiagnostics.testRunnerLaunchFailure(in: output))
    }

    func testDoesNotFireOnACleanRun() {
        XCTAssertNil(TestRunDiagnostics.testRunnerLaunchFailure(in: "** TEST EXECUTE SUCCEEDED **"))
    }
}
