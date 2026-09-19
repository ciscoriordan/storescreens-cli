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

    // MARK: - Display-shaped hole (no DMG needed)

    /// Stands in for a PSD: a flat opaque canvas, like the PSD's gray
    /// Screen fill under the bezel, loaded through the same NSImage path.
    private func makeFlatSource(width: Int, height: Int, in dir: URL, name: String) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Exports a flat canvas with the given screen box and returns the
    /// punched PNG, decoded before its temporary directory goes away.
    private func exportFlat(canvas: CGSize, screen: CGRect, key: String) throws -> AlphaReader {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storescreens-bezel-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeFlatSource(width: Int(canvas.width), height: Int(canvas.height), in: dir, name: "source.png")
        let candidate = BezelCandidate(
            sourceURL: source,
            filename: "source.png",
            modelName: "iPhone Test",
            colorway: nil,
            orientation: screen.width > screen.height ? .landscape : .portrait,
            orientationIsExplicit: true,
            productFamily: 1,
            canvasSize: canvas,
            screenBBox: screen,
            canonicalKey: key
        )
        let (pngURL, _) = try BezelExporter.export(candidate: candidate, to: dir.appendingPathComponent("out"))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(pngURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(image.width, Int(canvas.width))
        XCTAssertEqual(image.height, Int(canvas.height))
        return try AlphaReader(image)
    }

    func testExport_duoOuterKeepsCameraOpaqueAndSmallHingeCorners() throws {
        let screen = CGRect(x: 88, y: 80, width: 1398, height: 2034)
        let img = try exportFlat(canvas: CGSize(width: 1574, height: 2194), screen: screen, key: "iPhone_1398x2034_portrait")
        func alpha(_ x: CGFloat, _ y: CGFloat) throws -> Int {
            try img.alpha(x: Int(screen.minX + x), y: Int(screen.minY + y))
        }
        XCTAssertEqual(try alpha(699, 1017), 0, "screen center punched")
        // Camera disc (108 px, centered at 1255, 143.5) stays opaque.
        XCTAssertEqual(try alpha(1255, 143), 255, "camera center kept")
        XCTAssertEqual(try alpha(1255 + 50, 143), 255, "inside the camera rim kept")
        XCTAssertEqual(try alpha(1255 + 58, 143), 0, "just outside the camera punched")
        // Hinge side (left): 18 px corners, so 6 px in from the corner is
        // already display. The old single radius (203 px) left these opaque.
        XCTAssertEqual(try alpha(6, 6), 0)
        XCTAssertEqual(try alpha(6, 2034 - 7), 0)
        // Opposite side: 162 px corners.
        XCTAssertEqual(try alpha(1398 - 7, 6), 255)
        XCTAssertEqual(try alpha(1398 - 7, 2034 - 7), 255)
    }

    func testExport_duoOuterLandscapeHasCameraTopLeft() throws {
        let screen = CGRect(x: 80, y: 88, width: 2034, height: 1398)
        let img = try exportFlat(canvas: CGSize(width: 2194, height: 1574), screen: screen, key: "iPhone_2034x1398_landscape")
        func alpha(_ x: CGFloat, _ y: CGFloat) throws -> Int {
            try img.alpha(x: Int(screen.minX + x), y: Int(screen.minY + y))
        }
        XCTAssertEqual(try alpha(143, 143), 255, "camera kept, top left")
        XCTAssertEqual(try alpha(6, 1398 - 7), 0, "hinge along the bottom: small corners")
        XCTAssertEqual(try alpha(6, 6), 255, "large corner on top")
    }

    func testExport_duoInnerUsesItsOwnCornerRadius() throws {
        let screen = CGRect(x: 120, y: 120, width: 2007, height: 2853)
        let img = try exportFlat(canvas: CGSize(width: 2247, height: 3093), screen: screen, key: "iPhone_2007x2853_portrait")
        func alpha(_ x: CGFloat, _ y: CGFloat) throws -> Int {
            try img.alpha(x: Int(screen.minX + x), y: Int(screen.minY + y))
        }
        // 149 px corners: 50 px in along the diagonal is display. The
        // iPhone rule's 291 px radius left it opaque.
        for (x, y) in [(50, 50), (2007 - 51, 50), (50, 2853 - 51), (2007 - 51, 2853 - 51)] {
            XCTAssertEqual(try alpha(CGFloat(x), CGFloat(y)), 0, "(\(x), \(y))")
        }
        XCTAssertEqual(try alpha(3, 3), 255)
        XCTAssertEqual(try alpha(1003, 1426), 0)
    }

    func testExport_slabIPhoneKeepsTheSingleFamilyRadius() throws {
        let screen = CGRect(x: 60, y: 60, width: 1206, height: 2622)
        let img = try exportFlat(canvas: CGSize(width: 1326, height: 2742), screen: screen, key: "iPhone_1206x2622_portrait")
        func alpha(_ x: CGFloat, _ y: CGFloat) throws -> Int {
            try img.alpha(x: Int(screen.minX + x), y: Int(screen.minY + y))
        }
        // 0.145 x 1206 = 175 px on every corner, no island kept.
        for (x, y) in [(40, 40), (1206 - 41, 40), (40, 2622 - 41), (1206 - 41, 2622 - 41)] {
            XCTAssertEqual(try alpha(CGFloat(x), CGFloat(y)), 255, "(\(x), \(y))")
        }
        for (x, y) in [(60, 60), (1206 - 61, 2622 - 61)] {
            XCTAssertEqual(try alpha(CGFloat(x), CGFloat(y)), 0, "(\(x), \(y))")
        }
        XCTAssertEqual(try alpha(603, 60), 0)
    }

    /// Reads the alpha byte at a given top-left (x, y) coordinate from a CGImage.
    private func readPixelAlpha(image: CGImage, x: Int, y: Int, canvasHeight: Int) throws -> Int {
        try AlphaReader(image).alpha(x: x, y: y)
    }

    /// Decodes an image once into a bitmap context owned by the context
    /// itself (a Swift array passed as `data:` is only guaranteed to stay
    /// put for the initializer call, so later draws may miss it).
    private struct AlphaReader {
        let ctx: CGContext

        init(_ image: CGImage) throws {
            guard let ctx = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 4 * image.width,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw NSError(domain: "test", code: 1)
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            self.ctx = ctx
        }

        /// Row 0 of a bitmap context's memory is the top of the image, so a
        /// top-left (x, y) indexes it directly.
        func alpha(x: Int, y: Int) throws -> Int {
            guard let base = ctx.data else { throw NSError(domain: "test", code: 2) }
            return Int(base.load(fromByteOffset: y * ctx.bytesPerRow + x * 4 + 3, as: UInt8.self))
        }
    }
}
