import XCTest
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import StorescreensCore

/// Verifies how capture labels a device's screenshots when their pixel size
/// differs from the device's profile. The iPhone Duo has two displays but its
/// profile lists one; its screenshots are 1398x2034 folded and 2007x2853 open,
/// depending on a pose storescreens cannot set. Labeling them by the profile
/// would file inner-display screenshots under the outer display's name.
final class OutputOrganizerLabelTests: XCTestCase {

    private let duoOuter = AppStoreScreenSize(width: 1398, height: 2034, productFamily: 1)
    private let proMax = AppStoreScreenSize(width: 1320, height: 2868, productFamily: 1)

    private func label(_ profile: AppStoreScreenSize, _ width: Int, _ height: Int) -> AppStoreScreenSize {
        OutputOrganizer.labelSize(profile: profile, capturedWidth: width, capturedHeight: height)
    }

    // MARK: - labelSize (pure)

    func testLabelsTheDisplayTheScreenshotActuallyShows() {
        let inner = label(duoOuter, 2007, 2853)
        XCTAssertEqual(inner, AppStoreScreenSize(width: 2007, height: 2853, productFamily: 1))
        XCTAssertEqual(inner.displayName, "iPhone Duo inner")
        // A landscape capture of the inner display is labeled in portrait,
        // the way profiles describe screens.
        XCTAssertEqual(label(duoOuter, 2853, 2007), inner)
    }

    func testKeepsTheProfileWhenOnlyOrientationDiffers() {
        XCTAssertEqual(label(duoOuter, 2034, 1398), duoOuter)
        XCTAssertEqual(label(proMax, 2868, 1320), proMax)
        XCTAssertEqual(label(proMax, 1320, 2868), proMax)
    }

    func testKeepsTheProfileForSizesWithoutAName() {
        // An element screenshot, or a panel size App Store Connect doesn't use.
        XCTAssertEqual(label(proMax, 600, 400), proMax)
        XCTAssertEqual(label(duoOuter, 1878, 2670), duoOuter)
    }

    func testRelabelsFromAProfileSizeWithoutAName() {
        // If the Duo's profile lists the raw inner panel, the App Store sized
        // screenshots still get the inner display's name.
        let panel = AppStoreScreenSize(width: 1878, height: 2670, productFamily: 1)
        XCTAssertEqual(label(panel, 2007, 2853).displayName, "iPhone Duo inner")
    }

    func testNeverRelabelsAMac() {
        // A Mac's size comes from the config name, not a device profile.
        let mac = AppStoreScreenSize(width: 2560, height: 1600, productFamily: 6)
        XCTAssertEqual(label(mac, 2880, 1800), mac)
    }

    func testRelabelNoteOnlyForRelabeledGroups() throws {
        let device = ResolvedDevice(
            simulatorName: "iPhone Duo", udid: "duo",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            appStoreSize: duoOuter
        )
        XCTAssertNil(OutputOrganizer.relabelNote(for: LabeledScreenshots(size: duoOuter), device: device))
        let note = try XCTUnwrap(OutputOrganizer.relabelNote(
            for: LabeledScreenshots(size: AppStoreScreenSize(width: 2007, height: 2853, productFamily: 1)),
            device: device
        ))
        XCTAssertTrue(note.hasPrefix("iPhone Duo "))
        XCTAssertTrue(note.contains("2007x2853"))
        XCTAssertTrue(note.contains("1398x2034"))
        XCTAssertTrue(note.contains("\"iPhone Duo inner\""))
    }

    // MARK: - organizeFromFilesystem

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("label-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testGroupsAMixedCaptureByTheDisplayEachScreenshotShows() async throws {
        let source = tmp.appendingPathComponent("cache")
        let output = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try writePNG(width: 1398, height: 2034, to: source.appendingPathComponent("Home.png"))
        try writePNG(width: 2007, height: 2853, to: source.appendingPathComponent("Library.png"))

        let device = ResolvedDevice(
            simulatorName: "iPhone Duo", udid: "duo",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            appStoreSize: duoOuter
        )
        let groups = try await OutputOrganizer().organizeFromFilesystem(
            screenshotsDir: source.path,
            simulatorName: device.simulatorName,
            outputDir: output.path,
            device: device,
            screenshotFilter: nil
        )

        XCTAssertEqual(groups.map(\.size.displayName), ["iPhone Duo outer", "iPhone Duo inner"])
        XCTAssertEqual(groups.map { $0.screenshots.map(\.filename) }, [
            ["iPhone_Duo_outer_Home.png"],
            ["iPhone_Duo_inner_Library.png"],
        ])
        XCTAssertEqual(groups.screenshotCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("iPhone_Duo_inner_Library.png").path))
    }

    func testAnOrdinaryCaptureStaysOneGroupUnderTheDeviceLabel() async throws {
        let source = tmp.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try writePNG(width: 1320, height: 2868, to: source.appendingPathComponent("Home.png"))
        try writePNG(width: 2868, height: 1320, to: source.appendingPathComponent("Map.png"))

        let device = ResolvedDevice(
            simulatorName: "iPhone 18 Pro Max", udid: "pro-max",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max",
            appStoreSize: proMax
        )
        let groups = try await OutputOrganizer().organizeFromFilesystem(
            screenshotsDir: source.path,
            simulatorName: device.simulatorName,
            outputDir: tmp.appendingPathComponent("out").path,
            device: device,
            screenshotFilter: nil
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.size, proMax)
        XCTAssertEqual(groups.first?.screenshots.map(\.filename), ["iPhone_6.9_Home.png", "iPhone_6.9_Map.png"])
    }
}
