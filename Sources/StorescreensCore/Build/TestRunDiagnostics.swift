import Foundation

/// Classifies xcodebuild test output. Some failures are environmental and a
/// retry on a settled simulator clears them; a failed assertion is not, and
/// retrying it just burns another test run.
package enum TestRunDiagnostics {

    /// Signatures of the test runner never getting off the ground because
    /// CoreSimulator was still busy with a previous run's clone, so SpringBoard
    /// rejected the launch. xcodebuild still writes a result bundle in this
    /// case, so without matching the message nothing distinguishes it from a
    /// test that ran and captured nothing - the run just ends with "no
    /// screenshots" and the whole capture is lost.
    package static let launchFailureSignatures = [
        "Failed to install or launch the test runner",
        "Application failed preflight checks",
        "The request was denied by service delegate (SBMainWorkspace)",
    ]

    /// The matched signature when `output` shows the test runner failing to
    /// launch, else nil. Pure, so the classification is testable without a
    /// simulator.
    package static func testRunnerLaunchFailure(in output: String) -> String? {
        launchFailureSignatures.first { output.contains($0) }
    }
}
