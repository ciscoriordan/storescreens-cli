import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import StorescreensCore

final class BezelExporterTests: XCTestCase {

    func testExport_writesPngAndJson_withTransparentScreenRegion() throws {
        // Grab the first available winner candidate from mounted DMGs. Skip if
        // nothing mounted.
        let volumes = VolumeScanner.findAppleDesignResourceVolumes()
        if volumes.isEmpty {
            print("BezelExporterTests: no DMGs mounted — skipping")
            return
        }
        let candidates = BezelImporter.discover(in: volumes)
        let winners = BezelImporter.selectWinners(candidates: candidates)

        // Pick iPhone 17 Pro Max portrait if available, otherwise any winner.
        let chosen = winners["iPhone_1320x2868_portrait"] ?? winners.values.first
        guard let winner = chosen else {
            XCTFail("no winners returned")
            return
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storescreens-bezel-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let (pngURL, jsonURL) = try BezelExporter.export(candidate: winner, to: tmpDir)

        // Files exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: pngURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))

        // JSON round-trips to identical metadata
        let jsonData = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(BezelMetadata.self, from: jsonData)
        XCTAssertEqual(decoded.canonicalKey, winner.canonicalKey)
        XCTAssertEqual(decoded.canvasWidth, Int(winner.canvasSize.width))
        XCTAssertEqual(decoded.canvasHeight, Int(winner.canvasSize.height))
        XCTAssertEqual(decoded.screenWidth, Int(winner.screenBBox.width))
        XCTAssertEqual(decoded.screenHeight, Int(winner.screenBBox.height))

        // PNG is the right canvas size
        guard let src = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            XCTFail("failed to read back PNG")
            return
        }
        XCTAssertEqual(img.width, decoded.canvasWidth)
        XCTAssertEqual(img.height, decoded.canvasHeight)

        // Sample the center of the Screen rect — should be fully transparent.
        // Sample a pixel well outside the screen rect (canvas corner) — should
        // be fully transparent too (that's the background), so sample the
        // bezel area instead: a point just outside the screen rect but inside
        // the device hardware (top edge at the notch area).
        let centerX = decoded.screenX + decoded.screenWidth / 2
        let centerY = decoded.screenY + decoded.screenHeight / 2
        let centerAlpha = try readPixelAlpha(image: img, x: centerX, y: centerY, canvasHeight: decoded.canvasHeight)
        XCTAssertEqual(centerAlpha, 0, "center of Screen rect should be fully transparent, got alpha=\(centerAlpha)")

        // Sample a pixel just above the Screen rect's top edge — this lands
        // inside the hardware bezel for every device (the bezel surrounds the
        // screen). Alpha must be > 0, proving the PSD content rendered AND
        // the transparent punch was localized to the Screen rect only.
        let bezelX = decoded.screenX + decoded.screenWidth / 2
        let bezelY = max(0, decoded.screenY - 5)
        let bezelAlpha = try readPixelAlpha(image: img, x: bezelX, y: bezelY, canvasHeight: decoded.canvasHeight)
        XCTAssertGreaterThan(bezelAlpha, 0, "bezel region above Screen rect should be opaque, got alpha=\(bezelAlpha) at (\(bezelX),\(bezelY))")
    }

    /// Reads the alpha byte at a given top-left (x, y) coordinate from a CGImage.
    /// Converts the top-left input to the image's native bottom-left bitmap
    /// layout, since PNG output may be top-down or bottom-up depending on the
    /// pipeline.
    private func readPixelAlpha(image: CGImage, x: Int, y: Int, canvasHeight: Int) throws -> Int {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * image.width
        var data = [UInt8](repeating: 0, count: image.width * image.height * bytesPerPixel)
        guard let ctx = CGContext(
            data: &data,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // The input (x, y) is in top-left coords relative to the canvas. After
        // drawing into a CGContext (bottom-left origin), reading `data` gives
        // rows top-to-bottom from index 0 because CGContext writes that way
        // when reading back via bitmapInfo flags. Use (y * bytesPerRow + x * 4 + 3).
        let idx = y * bytesPerRow + x * bytesPerPixel + 3
        return Int(data[idx])
    }
}
