import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import StorescreensCore

/// Exports every bezel winner from the mounted Apple Design Resource DMGs
/// into a scratch directory and composites a solid-color screenshot under
/// each one through `ChromeRenderer`, at the bezel's native scale. The
/// composites show whether the punched screen opening lines up with Apple's
/// artwork: PSD screen fill left around the corners, a missing camera disc,
/// or a hole cut into the metal band are all visible (and measurable) there.
///
/// Skipped by default, and never writes to the user-global bezels
/// directory. To run:
///
///     STORESCREENS_BEZEL_CHECK_DIR=/tmp/bezel-check swift test --filter BezelExportCheckTests
///
/// Writes `<dir>/bezels/<key>.png|json` and `<dir>/composites/<key>.png`.
final class BezelExportCheckTests: XCTestCase {

    func testExportAndCompositeMountedBezels() throws {
        guard let dir = ProcessInfo.processInfo.environment["STORESCREENS_BEZEL_CHECK_DIR"] else {
            throw XCTSkip("set STORESCREENS_BEZEL_CHECK_DIR to export and composite the mounted bezels")
        }
        let volumes = VolumeScanner.findAppleDesignResourceVolumes()
        if volumes.isEmpty {
            throw XCTSkip("no Apple Design Resource DMGs mounted")
        }

        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let bezelDir = root.appendingPathComponent("bezels", isDirectory: true)
        let compositeDir = root.appendingPathComponent("composites", isDirectory: true)
        try FileManager.default.createDirectory(at: compositeDir, withIntermediateDirectories: true)

        let candidates = BezelImporter.discover(in: volumes) { print("  warn: \($0)") }
        let winners = BezelImporter.selectWinners(candidates: candidates)
        let store = BezelStore(projectLocal: nil, userGlobal: bezelDir)
        let renderer = ChromeRenderer(bezelStore: store)

        for key in winners.keys.sorted() {
            let winner = try XCTUnwrap(winners[key])
            print("  \(key) <- \(winner.filename)")
            try BezelExporter.export(candidate: winner, to: bezelDir)

            let asset = try XCTUnwrap(store.lookup(canonicalKey: key))
            let meta = asset.metadata
            let screenshotURL = root.appendingPathComponent("screen-\(meta.screenWidth)x\(meta.screenHeight).png")
            try writeSolid(width: meta.screenWidth, height: meta.screenHeight, to: screenshotURL)

            let ctx = try XCTUnwrap(CGContext(
                data: nil, width: meta.canvasWidth, height: meta.canvasHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // No padding and fit: width put the bezel canvas 1:1 on the
            // output, so composite pixels line up with Apple's PNG artwork.
            let warnings = try renderer.drawChrome(
                ChromeConfig(style: .bezel, shadow: false, paddingPct: 0, bezelFallback: .error),
                screenshotURL: screenshotURL,
                productFamily: meta.productFamily,
                orientation: meta.orientation,
                screenshotPixelSize: CGSize(width: meta.screenWidth, height: meta.screenHeight),
                into: ctx,
                chromeRect: CGRect(x: 0, y: 0, width: meta.canvasWidth, height: meta.canvasHeight)
            )
            XCTAssertEqual(warnings, [], "[\(key)] unexpected chrome warnings")
            try writePNG(try XCTUnwrap(ctx.makeImage()), to: compositeDir.appendingPathComponent("\(key).png"))
        }
        print("Exported \(winners.count) bezels to \(bezelDir.path)")
    }

    /// Pure red, a color that never occurs in Apple's bezel artwork, so any
    /// non-red pixel inside the opening is bezel content.
    private func writeSolid(width: Int, height: Int, to url: URL) throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try writePNG(try XCTUnwrap(ctx.makeImage()), to: url)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
