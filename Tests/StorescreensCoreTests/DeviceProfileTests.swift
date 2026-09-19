import XCTest
@testable import StorescreensCore

/// Verifies `DeviceMapping.readProfile` against both layouts of a
/// CoreSimulator device type bundle. The screen size used to live in
/// profile.plist; the CoreSimulator release that came with Xcode 27 moved it
/// to capabilities.plist, and reading only the old keys left every device
/// unresolvable, so `storescreens capture` failed before booting anything.
final class DeviceProfileTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceProfileTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundle(profile: [String: Any], capabilities: [String: Any]? = nil) throws -> String {
        let bundle = root.appendingPathComponent("Device.simdevicetype")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            .write(to: resources.appendingPathComponent("profile.plist"))
        if let capabilities {
            try PropertyListSerialization.data(fromPropertyList: capabilities, format: .xml, options: 0)
                .write(to: resources.appendingPathComponent("capabilities.plist"))
        }
        return bundle.path
    }

    func testReadsLegacyProfileKeys() throws {
        let path = try makeBundle(profile: [
            "mainScreenWidth": 1320, "mainScreenHeight": 2868, "supportedProductFamilyIDs": [1],
        ])
        let profile = try XCTUnwrap(DeviceMapping.readProfile(bundlePath: path))
        XCTAssertEqual(profile.width, 1320)
        XCTAssertEqual(profile.height, 2868)
        XCTAssertEqual(profile.productFamily, 1)
    }

    func testFallsBackToCapabilitiesDisplays() throws {
        // Shape of iPhone 17 Pro Max under the Xcode 27 CoreSimulator: no
        // mainScreen keys, and the built-in screen listed alongside CarPlay
        // and external-monitor displays.
        let path = try makeBundle(
            profile: ["supportedProductFamilyIDs": [1], "modelIdentifier": "iPhone18,2"],
            capabilities: ["capabilities": ["displays": [
                ["screenID": 1, "width": 1320, "height": 2868, "scale": 3.0, "hasDigitizer": true],
                ["screenID": 2, "width": 720, "height": 480, "scale": 1.0, "hasDigitizer": false],
                ["screenID": 4, "width": 7680, "height": 4320, "scale": 3.0, "hasDigitizer": true],
            ]]]
        )
        let profile = try XCTUnwrap(DeviceMapping.readProfile(bundlePath: path))
        XCTAssertEqual(profile.width, 1320)
        XCTAssertEqual(profile.height, 2868)
        XCTAssertEqual(profile.productFamily, 1)
    }

    func testTakesTheFirstFamilyForAniPad() throws {
        // iPad device types list [2, 1]: an iPad that can also run iPhone apps.
        let path = try makeBundle(
            profile: ["supportedProductFamilyIDs": [2, 1]],
            capabilities: ["capabilities": ["displays": [
                ["screenID": 1, "width": 2064, "height": 2752, "hasDigitizer": true],
            ]]]
        )
        let profile = try XCTUnwrap(DeviceMapping.readProfile(bundlePath: path))
        XCTAssertEqual(profile.productFamily, 2)
        XCTAssertEqual(profile.width, 2064)
    }

    func testNilWhenNeitherLayoutHasASize() throws {
        let path = try makeBundle(profile: ["supportedProductFamilyIDs": [1]])
        XCTAssertNil(DeviceMapping.readProfile(bundlePath: path))
    }
}

/// Verifies the App Store size labels. The label is the manifest's
/// `deviceType` and the output filename prefix, so a wrong or missing one
/// renames every file a capture writes.
final class AppStoreScreenSizeLabelTests: XCTestCase {

    private func size(_ width: Int, _ height: Int, family: Int = 1) -> AppStoreScreenSize {
        AppStoreScreenSize(width: width, height: height, productFamily: family)
    }

    func testNamesBothIPhoneDuoDisplays() {
        XCTAssertEqual(size(1398, 2034).displayName, "iPhone Duo outer")
        XCTAssertEqual(size(1398, 2034).filenamePrefix, "iPhone_Duo_outer")
        XCTAssertEqual(size(2007, 2853).displayName, "iPhone Duo inner")
        XCTAssertEqual(size(2007, 2853).filenamePrefix, "iPhone_Duo_inner")
        XCTAssertTrue(size(2007, 2853).hasFriendlyName)
    }

    func testLookupIgnoresOrientationButKeepsTheGivenSize() {
        let landscape = size(2868, 1320)
        XCTAssertEqual(landscape.displayName, "iPhone 6.9\"")
        XCTAssertEqual(landscape.width, 2868)
        XCTAssertEqual(landscape.height, 1320)
        XCTAssertEqual(size(2853, 2007).displayName, "iPhone Duo inner")
        // Mac sizes are listed in landscape; both orientations still resolve.
        XCTAssertEqual(size(2880, 1800, family: 6).displayName, "Mac 2880x1800")
        XCTAssertEqual(size(1800, 2880, family: 6).displayName, "Mac 2880x1800")
    }

    func testUnknownSizeGetsAnAutoGeneratedNameInItsOwnOrientation() {
        XCTAssertEqual(size(1000, 2000).displayName, "iPhone 1000x2000")
        XCTAssertEqual(size(2000, 1000).displayName, "iPhone 2000x1000")
        XCTAssertFalse(size(1000, 2000).hasFriendlyName)
    }

    func testExistingLabelsAreUnchanged() {
        // The iPhone 18 Pro and Pro Max have the 17 Pro / Pro Max screens.
        XCTAssertEqual(size(1320, 2868).displayName, "iPhone 6.9\"")
        XCTAssertEqual(size(1206, 2622).displayName, "iPhone 6.3\"")
        // iPhone Air keeps its label; its App Store class is decided from
        // the pixel size at submit time, not from this name.
        XCTAssertEqual(size(1260, 2736).displayName, "iPhone 6.3\"")
        XCTAssertEqual(size(2064, 2752, family: 2).displayName, "iPad Pro 13\"")
        XCTAssertEqual(size(422, 514, family: 4).displayName, "Apple Watch Ultra 49mm")
    }

    func testDisplayTypeComesFromScreenshotDisplayType() {
        for candidate in [size(1320, 2868), size(1206, 2622), size(1260, 2736), size(2007, 2853), size(2064, 2752, family: 2)] {
            XCTAssertEqual(
                candidate.screenshotDisplayType,
                ScreenshotDisplayType.resolve(productFamily: candidate.productFamily, width: candidate.width, height: candidate.height)
            )
        }
        XCTAssertEqual(size(1320, 2868).screenshotDisplayType, "APP_IPHONE_67")
    }
}
