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
