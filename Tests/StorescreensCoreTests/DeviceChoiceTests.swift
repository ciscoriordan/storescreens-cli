import XCTest
@testable import StorescreensCore

private func simulator(_ name: String, udid: String) -> SimulatorDevice {
    let json = """
    {
      "udid": "\(udid)",
      "name": "\(name)",
      "state": "Shutdown",
      "isAvailable": true,
      "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.test",
      "lastBootedAt": null
    }
    """
    return try! JSONDecoder().decode(SimulatorDevice.self, from: Data(json.utf8))
}

private func iPhone(_ width: Int, _ height: Int) -> AppStoreScreenSize {
    AppStoreScreenSize(width: width, height: height, productFamily: 1)
}

/// Verifies the one device `storescreens init` writes into a new config. It
/// has to be a size App Store Connect takes screenshots for: the widest
/// iPhone on an Xcode 27.1 machine is the iPhone Duo, which has none.
final class DefaultDevicePickerTests: XCTestCase {

    private func pick(_ entries: [(name: String, size: AppStoreScreenSize)]) -> String? {
        let devices = entries.enumerated().map { simulator($0.element.name, udid: "udid-\($0.offset)") }
        var sizes: [String: AppStoreScreenSize] = [:]
        for (index, entry) in entries.enumerated() { sizes["udid-\(index)"] = entry.size }
        return DefaultDevicePicker.iPhone(from: devices, sizes: sizes)?.name
    }

    func testPicksTheNewestModelInTheLargestAppStoreClassOverTheDuo() {
        let entries: [(name: String, size: AppStoreScreenSize)] = [
            ("iPhone 17", iPhone(1206, 2622)),
            ("iPhone 17 Pro Max", iPhone(1320, 2868)),
            ("iPhone 18 Pro Max", iPhone(1320, 2868)),
            ("iPhone Air", iPhone(1260, 2736)),
            ("iPhone Duo", iPhone(2007, 2853)),
            ("iPad Pro 13-inch (M5)", AppStoreScreenSize(width: 2064, height: 2752, productFamily: 2)),
        ]
        XCTAssertEqual(pick(entries), "iPhone 18 Pro Max")
        XCTAssertEqual(pick(entries.reversed()), "iPhone 18 Pro Max")
    }

    func testPicksTheWidestOfTheLargestClass() {
        XCTAssertEqual(pick([
            ("iPhone 16 Plus", iPhone(1290, 2796)),
            ("iPhone 16 Pro", iPhone(1206, 2622)),
            ("iPhone 16 Pro Max", iPhone(1320, 2868)),
        ]), "iPhone 16 Pro Max")
    }

    func testNeverPicksTheDuoWhileAnotherIPhoneHasAnAppStoreSize() {
        XCTAssertEqual(pick([
            ("iPhone Duo", iPhone(1398, 2034)),
            ("iPhone 16e", iPhone(1170, 2532)),
        ]), "iPhone 16e")
    }

    func testFallsBackToTheWidestIPhoneWhenNoneHasAnAppStoreSize() {
        XCTAssertEqual(pick([
            ("iPhone Duo", iPhone(2007, 2853)),
            ("iPhone Concept", iPhone(1000, 2000)),
        ]), "iPhone Duo")
    }

    func testPicksA65InchClassDeviceWhenThereIsNo69InchOne() {
        // A machine with only older runtimes: the 6.5" class is App Store
        // Connect's accepted alternative to 6.9", so it beats the 6.3" class.
        XCTAssertEqual(pick([
            ("iPhone 16 Pro", iPhone(1206, 2622)),
            ("iPhone 13 Pro Max", iPhone(1284, 2778)),
            ("iPhone 16e", iPhone(1170, 2532)),
        ]), "iPhone 13 Pro Max")
    }

    func testNoIPhoneNoPick() {
        XCTAssertNil(pick([("iPad Air 11-inch (M3)", AppStoreScreenSize(width: 1640, height: 2360, productFamily: 2))]))
    }

    func testReadsTheModelNumberFromTheName() {
        XCTAssertEqual(DefaultDevicePicker.modelGeneration("iPhone 18 Pro Max"), 18)
        XCTAssertEqual(DefaultDevicePicker.modelGeneration("iPhone 16e"), 16)
        XCTAssertNil(DefaultDevicePicker.modelGeneration("iPhone Air"))
        XCTAssertNil(DefaultDevicePicker.modelGeneration("iPhone SE (3rd generation)"))
        XCTAssertNil(DefaultDevicePicker.modelGeneration("iPad Pro 13-inch (M5)"))
    }
}

/// Verifies the capture-time warning for devices that share an App Store size
/// label. In a UI-test capture they write the same output files, so without
/// the warning one device's screenshots silently replace the other's.
final class SharedDeviceLabelTests: XCTestCase {

    private func resolved(_ name: String, _ size: AppStoreScreenSize) -> ResolvedDevice {
        ResolvedDevice(simulatorName: name, udid: name, deviceTypeIdentifier: "test", appStoreSize: size)
    }

    func testWarnsWhenTwoModelsShareAScreen() throws {
        let shared = ResolvedDevice.sharedLabels(in: [
            resolved("iPhone 17 Pro", iPhone(1206, 2622)),
            resolved("iPhone 18 Pro Max", iPhone(1320, 2868)),
            resolved("iPhone 18 Pro", iPhone(1206, 2622)),
        ])
        XCTAssertEqual(shared.count, 1)
        let entry = try XCTUnwrap(shared.first)
        XCTAssertEqual(entry.label, "iPhone 6.3\"")
        XCTAssertEqual(entry.simulatorNames, ["iPhone 17 Pro", "iPhone 18 Pro"])
        XCTAssertTrue(entry.sameAppStoreSlot)
        XCTAssertTrue(entry.warning.contains("iPhone 17 Pro and iPhone 18 Pro"))
        XCTAssertTrue(entry.warning.contains("\"iPhone 6.3\"\""))
        XCTAssertTrue(entry.warning.contains("UI-test screenshots"))
        XCTAssertTrue(entry.warning.contains("same App Store size class"))
        // The shared files hold whichever capture wrote them last, so the
        // warning names no device.
        XCTAssertTrue(entry.warning.contains("Only the capture that finishes last stays on disk, and submit uploads that one"))
        XCTAssertTrue(entry.warning.contains("Remove"))
    }

    func testSameLabelDifferentSizesReportsWhetherTheSlotMatches() throws {
        // iPhone Air and iPhone 17 Pro share the "iPhone 6.3\"" label but not
        // the pixel size; whether App Store Connect puts them in one slot is
        // ScreenshotDisplayType's call.
        let shared = ResolvedDevice.sharedLabels(in: [
            resolved("iPhone Air", iPhone(1260, 2736)),
            resolved("iPhone 17 Pro", iPhone(1206, 2622)),
        ])
        let entry = try XCTUnwrap(shared.first)
        XCTAssertEqual(entry.simulatorNames, ["iPhone Air", "iPhone 17 Pro"])
        XCTAssertEqual(
            entry.sameAppStoreSlot,
            ScreenshotDisplayType.resolve(productFamily: 1, width: 1260, height: 2736)
                == ScreenshotDisplayType.resolve(productFamily: 1, width: 1206, height: 2622)
        )
        XCTAssertTrue(entry.warning.contains("overwrites"))
    }

    func testDifferentSizeClassesSayOnlyOneClassGetsFilled() throws {
        // iPhone 16 Plus (1290x2796, 6.9" class) and iPhone 13 Pro Max
        // (1284x2778, 6.5" class) are both labeled "iPhone 6.7\"".
        let shared = ResolvedDevice.sharedLabels(in: [
            resolved("iPhone 16 Plus", iPhone(1290, 2796)),
            resolved("iPhone 13 Pro Max", iPhone(1284, 2778)),
        ])
        let entry = try XCTUnwrap(shared.first)
        XCTAssertFalse(entry.sameAppStoreSlot)
        XCTAssertTrue(entry.warning.contains("different size classes"))
        XCTAssertTrue(entry.warning.contains("fill only one of those classes"))
        XCTAssertTrue(entry.warning.contains("separate runs with different output_dir values"))
        XCTAssertFalse(entry.warning.contains("largest screen"))
    }

    func testNamesEveryDeviceInTheGroup() throws {
        let shared = ResolvedDevice.sharedLabels(in: [
            resolved("iPhone 16 Pro", iPhone(1206, 2622)),
            resolved("iPhone 17 Pro", iPhone(1206, 2622)),
            resolved("iPhone 18 Pro", iPhone(1206, 2622)),
        ])
        let entry = try XCTUnwrap(shared.first)
        XCTAssertTrue(entry.warning.hasPrefix("iPhone 16 Pro, iPhone 17 Pro, and iPhone 18 Pro are all labeled"))
    }

    func testDistinctLabelsAndRepeatedEntriesAreFine() {
        XCTAssertEqual(ResolvedDevice.sharedLabels(in: [
            resolved("iPhone 18 Pro Max", iPhone(1320, 2868)),
            resolved("iPhone 18 Pro", iPhone(1206, 2622)),
            resolved("iPad Pro 13-inch (M5)", AppStoreScreenSize(width: 2064, height: 2752, productFamily: 2)),
        ]), [])
        // The same simulator listed twice is a different mistake.
        XCTAssertEqual(ResolvedDevice.sharedLabels(in: [
            resolved("iPhone 18 Pro", iPhone(1206, 2622)),
            resolved("iPhone 18 Pro", iPhone(1206, 2622)),
        ]), [])
    }
}

/// Verifies the simulator coverage check `storescreens init` and `setup` run.
/// App Store Connect requires an iPhone set in the 6.9" class, or in the 6.5"
/// class when there is no 6.9" set, so a 6.5"-only machine gets a warning, not
/// an error.
final class SizeCoverageGapTests: XCTestCase {

    private func gaps(_ sizes: [AppStoreScreenSize]) -> [ProjectDetector.SizeCoverageGap] {
        ProjectDetector.sizeCoverageGaps(in: sizes)
    }

    private func iPad(_ width: Int, _ height: Int) -> AppStoreScreenSize {
        AppStoreScreenSize(width: width, height: height, productFamily: 2)
    }

    func test69And63InchClassesCoverTheIPhone() {
        XCTAssertEqual(gaps([iPhone(1320, 2868), iPhone(1206, 2622)]), [])
    }

    func testOnlyA65InchClassIPhoneIsAWarningRecommendingA69InchSimulator() throws {
        for size in [iPhone(1284, 2778), iPhone(1242, 2688)] {
            let found = gaps([size, iPhone(1206, 2622)])
            XCTAssertEqual(found.count, 1, "\(size.width)x\(size.height)")
            let gap = try XCTUnwrap(found.first)
            XCTAssertEqual(gap.severity, .warning)
            XCTAssertTrue(gap.message.contains("6.5\" class"))
            XCTAssertTrue(gap.message.contains("iOS 27 runtimes create iPhone 18 Pro Max"))
            XCTAssertTrue(gap.message.contains("iOS 26 runtimes iPhone 17 Pro Max"))
        }
    }

    func testThe63InchHintCountsA65InchClassIPhoneAsTheLargeOne() {
        let found = gaps([iPhone(1284, 2778)])
        XCTAssertEqual(found.map(\.severity), [.warning, .warning])
        XCTAssertTrue(found[1].message.hasPrefix("No compatible simulator in the iPhone 6.3\" class"))
    }

    func testNeither69Nor65InchClassIsAnError() throws {
        // A 6.3" class iPhone and the Duo (no App Store Connect slot yet)
        // cover neither required class. The 6.3" hint is skipped: the error
        // already asks for a larger iPhone.
        let found = gaps([iPhone(1206, 2622), iPhone(2007, 2853)])
        XCTAssertEqual(found.count, 1)
        let gap = try XCTUnwrap(found.first)
        XCTAssertEqual(gap.severity, .error)
        XCTAssertTrue(gap.message.contains("6.9\" or 6.5\" class"))
    }

    func testIPhoneAirCoversThe69InchClassButNotThe63InchOne() throws {
        // Labeled "iPhone 6.3\"", but App Store Connect files it under 6.9".
        let found = gaps([iPhone(1260, 2736)])
        XCTAssertEqual(found.count, 1)
        let gap = try XCTUnwrap(found.first)
        XCTAssertEqual(gap.severity, .warning)
        XCTAssertTrue(gap.message.hasPrefix("No compatible simulator in the iPhone 6.3\" class"))
    }

    func testIPadsNeedA13InchOr129InchSimulator() {
        let iPhones = [iPhone(1320, 2868), iPhone(1206, 2622)]
        XCTAssertEqual(gaps(iPhones + [iPad(2064, 2752), iPad(1668, 2420)]), [])
        XCTAssertEqual(gaps(iPhones + [iPad(2048, 2732)]), [])
        XCTAssertEqual(gaps(iPhones + [iPad(1668, 2420)]).map(\.severity), [.error])
    }
}

/// Verifies the device-lookup errors point at the actual cause for the
/// models whose absence is not self-explanatory.
final class SimulatorLookupErrorTests: XCTestCase {

    func testIPhoneDuoNotFoundNamesTheXcodeItNeeds() throws {
        let message = try XCTUnwrap(CLIError.simulatorNotFound(name: "iPhone Duo").errorDescription)
        XCTAssertTrue(message.contains("Xcode 27.1"))
        XCTAssertTrue(message.contains("DEVELOPER_DIR"))
    }

    func testProModelsNotFoundNameTheRuntimeThatCreatesThem() throws {
        let seventeen = try XCTUnwrap(CLIError.simulatorNotFound(name: "iPhone 17 Pro Max").errorDescription)
        XCTAssertTrue(seventeen.contains("iOS 26"))
        XCTAssertTrue(seventeen.contains("iPhone 18 Pro"))
        let eighteen = try XCTUnwrap(CLIError.simulatorNotFound(name: "iPhone 18 Pro").errorDescription)
        XCTAssertTrue(eighteen.contains("iOS 27"))
    }

    func testOtherNamesKeepThePlainMessage() {
        XCTAssertEqual(
            CLIError.simulatorNotFound(name: "iPhone 17").errorDescription,
            "Simulator 'iPhone 17' not found. Run 'storescreens list' to see available simulators."
        )
    }

    func testUnknownSizeErrorNoLongerPointsAtTheUnusedSizeField() throws {
        let message = try XCTUnwrap(CLIError.noMatchingDeviceSize(simulatorName: "Apple TV").errorDescription)
        XCTAssertFalse(message.contains("size:"))
        XCTAssertTrue(message.contains("simctl list devicetypes"))
    }
}
