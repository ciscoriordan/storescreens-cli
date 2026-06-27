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
