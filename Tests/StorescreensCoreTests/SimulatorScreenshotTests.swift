import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import StorescreensCore

/// `SimulatorManager.takeScreenshot` picks a display on devices with more
/// than one built-in screen (iPhone Duo). These cover its two pure parts:
/// reading `simctl io enumerate` and telling an off display from content.
final class SimulatorScreenshotTests: XCTestCase {

    /// Trimmed `simctl io enumerate` output from a booted iPhone Duo
    /// simulator (Xcode 27.1 beta, iOS 27.1). Screen 1 is the outer display,
    /// screen 3 the inner one.
    private let duoEnumerate = """
    Connected Screens:
        Screen ID: 4
        Name: Wireless
        Device Name: wireless0
        Screen Type: CarPlay
        Pixel Size: {720, 480}
        UI Orientation: Ambiguous
        Screen ID: 1
        Name: LCD
        Device Name: primary
        Screen Type: Integrated
        Pixel Size: {1398, 2034}
        UI Orientation: Portrait
        Screen ID: 5
        Name: Resizable
        Device Name: resizable
        Screen Type: Scene
        Pixel Size: {7680, 4320}
        UI Orientation: Ambiguous
        Screen ID: 2
        Name: TVOut
        Device Name: external-0
        Screen Type: TVOut
        Pixel Size: {720, 480}
        UI Orientation: Ambiguous
        Screen ID: 3
        Name: LCD-1
        Device Name: primary-1
        Screen Type: Integrated
        Pixel Size: {2007, 2853}
        UI Orientation: Portrait
    """

    func testEnumerate_duoListsBothBuiltInDisplays() {
        XCTAssertEqual(SimulatorManager.integratedScreenIDs(fromEnumerateOutput: duoEnumerate), ["1", "3"])
    }

    func testEnumerate_singleDisplayPhoneListsOne() {
        let output = """
        Connected Screens:
            Screen ID: 3
            Screen Type: CarPlay
            Screen ID: 2
            Screen Type: TVOut
            Screen ID: 1
            Name: LCD
            Screen Type: Integrated
            Pixel Size: {1206, 2622}
        """
        XCTAssertEqual(SimulatorManager.integratedScreenIDs(fromEnumerateOutput: output), ["1"])
    }

    func testEnumerate_emptyOrUnexpectedOutputListsNone() {
        XCTAssertEqual(SimulatorManager.integratedScreenIDs(fromEnumerateOutput: ""), [])
        XCTAssertEqual(SimulatorManager.integratedScreenIDs(fromEnumerateOutput: "No devices are booted."), [])
    }

    func testBlankImage_allBlackIsBlank() throws {
        let path = try writePNG(width: 200, height: 300) { _, _ in (0, 0, 0) }
        XCTAssertTrue(SimulatorManager.isBlankImage(atPath: path))
    }

    /// A dark-mode screen is mostly black but has lit pixels (status bar,
    /// text), so it must not be mistaken for an off display.
    func testBlankImage_darkScreenWithSomeContentIsNotBlank() throws {
        let path = try writePNG(width: 200, height: 300) { x, y in
            (10...40).contains(y) && (20...60).contains(x) ? (230, 230, 230) : (0, 0, 0)
        }
        XCTAssertFalse(SimulatorManager.isBlankImage(atPath: path))
    }

    func testBlankImage_unreadableFileIsBlank() {
        XCTAssertTrue(SimulatorManager.isBlankImage(atPath: "/nonexistent/screenshot.png"))
    }

    private func writePNG(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> String {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let path = NSTemporaryDirectory() + "storescreens-blank-\(UUID().uuidString).png"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return path
    }
}

/// `waitUntilBooted` also waits for SpringBoard's finished-startup state,
/// because `simctl bootstatus` returns early on the iPhone Duo runtime.
final class SpringBoardStartupParsingTests: XCTestCase {
    func testNonZeroStateMeansStarted() {
        XCTAssertTrue(SimulatorManager.springBoardFinishedStartup(notifyutilOutput: "com.apple.springboard.finishedstartup 54038\n"))
    }

    func testZeroStateMeansStillBooting() {
        XCTAssertFalse(SimulatorManager.springBoardFinishedStartup(notifyutilOutput: "com.apple.springboard.finishedstartup 0\n"))
    }

    func testUnexpectedOutputIsNotReady() {
        XCTAssertFalse(SimulatorManager.springBoardFinishedStartup(notifyutilOutput: ""))
        XCTAssertFalse(SimulatorManager.springBoardFinishedStartup(notifyutilOutput: "Unable to lookup in current state: Shutdown"))
    }
}
