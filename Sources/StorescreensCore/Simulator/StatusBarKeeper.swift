import Foundation

/// Keeps `simctl status_bar override` applied to the simulator the UI tests are
/// actually running on.
///
/// `xcodebuild test` decides for itself whether to run on the destination or on
/// a clone of it, and Xcode 26 still clones even with `-parallel-testing-enabled
/// NO` and an explicit `-destination id=<udid>`. When it does, the tests - and
/// every screenshot they take - run on `Clone N of <base>`. The status-bar
/// override is runtime SpringBoard state, not something stored in the device's
/// data container, so a fresh clone does not inherit it: an override applied to
/// the base device lands on a simulator no screenshot is ever taken on, and the
/// captures keep the live status bar (real clock, wifi icon, real battery).
/// Appearance survives the same trip because `simctl ui appearance` writes
/// persisted device data that the clone copies, which is why the status bar is
/// the one setting that silently goes missing.
///
/// So rather than configuring the base device and hoping, this polls `simctl`
/// while the tests run and applies the override to every booted clone as it
/// appears - plus the base itself, for toolchains that skip cloning. The clones
/// live in their own device set (see `DeviceSet.xctest`), which is why they are
/// invisible to a plain `simctl list devices`. Devices that merely share the
/// base's name (the same model on another runtime) can be caught by the name
/// match; applying a status bar override to an idle simulator is harmless.
///
/// Everything here is best-effort: a failed override warns, it never aborts the
/// capture.
package struct StatusBarKeeper: Sendable {

    /// Marketing status bar: 9:41, LTE, full bars, charging.
    package static let defaultArguments = "--time 9:41 --dataNetwork lte --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 90 --operatorName TELUS"

    /// The override arguments a capture should apply, or nil when
    /// `status_bar: false` turns the feature off. Single source of truth for the
    /// documented default so every capture path stays in sync.
    package static func arguments(for config: CaptureConfig) -> String? {
        guard config.statusBar != false else { return nil }
        return config.statusBarArguments ?? defaultArguments
    }

    /// How each device is doing so far. A device is done once the override has
    /// landed `applicationsPerDevice` times, or given up on after `failureLimit`
    /// failures.
    package struct Progress: Sendable, Equatable {
        package var successes: Int
        package var failures: Int

        package init(successes: Int = 0, failures: Int = 0) {
            self.successes = successes
            self.failures = failures
        }
    }

    /// How often to look for newly booted clones.
    package let pollInterval: Duration

    /// How many times the override is applied to each device. SpringBoard can
    /// finish coming up after the device already reports Booted and drop the
    /// first override, so re-applying across a few polls is what makes it stick.
    package let applicationsPerDevice: Int

    /// Stop trying a device after this many failures, so a clone that is being
    /// torn down can't keep the loop busy.
    package let failureLimit: Int

    package init(
        pollInterval: Duration = .milliseconds(500),
        applicationsPerDevice: Int = 3,
        failureLimit: Int = 3
    ) {
        self.pollInterval = pollInterval
        self.applicationsPerDevice = applicationsPerDevice
        self.failureLimit = failureLimit
    }

    /// Devices that should get the override on this poll: booted, named like the
    /// base device or one of its xcodebuild clones, and neither finished nor
    /// given up on. Pure, so the selection is testable without a simulator.
    package static func devicesNeedingOverride(
        devices: [LocatedDevice],
        baseName: String,
        progress: [String: Progress],
        applicationsPerDevice: Int,
        failureLimit: Int
    ) -> [LocatedDevice] {
        devices.filter { located in
            let device = located.device
            guard device.isBooted, SimulatorManager.isClone(device.name, of: baseName) else {
                return false
            }
            let state = progress[device.udid] ?? Progress()
            return state.successes < applicationsPerDevice && state.failures < failureLimit
        }
    }

    /// Poll until cancelled, applying `arguments` to every booted clone of
    /// `baseName` as it appears.
    package func run(
        baseName: String,
        arguments: String,
        manager: SimulatorManager,
        log: @escaping @Sendable (String) async -> Void
    ) async {
        var progress: [String: Progress] = [:]
        while !Task.isCancelled {
            let targets = Self.devicesNeedingOverride(
                devices: await manager.locatedDevices(),
                baseName: baseName,
                progress: progress,
                applicationsPerDevice: applicationsPerDevice,
                failureLimit: failureLimit
            )
            for located in targets {
                let device = located.device
                var state = progress[device.udid] ?? Progress()
                do {
                    try await manager.overrideStatusBar(device.udid, arguments: arguments, in: located.set)
                    state.successes += 1
                    if state.successes == 1 {
                        await log("Status bar override applied to \(device.name)")
                    }
                } catch {
                    state.failures += 1
                    if state.failures == failureLimit {
                        await log("⚠ Status bar override failed on \(device.name) - screenshots there will show the live status bar")
                    }
                }
                progress[device.udid] = state
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Runs `body` with a background keeper that applies the override to the
    /// test's clone as it boots. Pass `arguments: nil` (i.e. `status_bar: false`
    /// or a macOS target) to run `body` untouched.
    package func maintaining<T>(
        baseName: String,
        arguments: String?,
        manager: SimulatorManager,
        log: @escaping @Sendable (String) async -> Void,
        during body: () async throws -> T
    ) async rethrows -> T {
        guard let arguments else { return try await body() }
        let keeper = Task {
            await run(baseName: baseName, arguments: arguments, manager: manager, log: log)
        }
        defer { keeper.cancel() }
        return try await body()
    }
}
