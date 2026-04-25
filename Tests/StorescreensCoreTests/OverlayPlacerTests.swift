import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
@testable import StorescreensCore

/// Numeric tests for `OverlayPlacer.reservedHeight` and a smoke test for
/// `drawSlot` that doesn't compare pixels, just confirms a real image lands
/// somewhere non-transparent inside the slot rect.
final class OverlayPlacerTests: XCTestCase {

    // MARK: - reservedHeight

    func testReservedHeight_aboveTitle_oneImage() {
        let placer = makePlacer()
        let canvas = CGSize(width: 100, height: 200)
        let img = ImageConfig(
            path: .shared("/some/path.png"),
            position: .aboveTitle,
            maxHeightPct: 10
        )
        let h = placer.reservedHeight(
            position: .aboveTitle,
            images: [img],
            laurels: [],
            appearance: "light",
            canvasSize: canvas,
            isFirstInCombo: true
        )
        // 200 * 10/100 = 20.
        XCTAssertEqual(h, 20, accuracy: 0.001)
    }

    func testReservedHeight_emptySlot_returnsZero() {
        let placer = makePlacer()
        let canvas = CGSize(width: 100, height: 200)
        let h = placer.reservedHeight(
            position: .belowSubtitle,
            images: [],
            laurels: [],
            appearance: "light",
            canvasSize: canvas,
            isFirstInCombo: true
        )
        XCTAssertEqual(h, 0)
    }

    func testReservedHeight_canonicalSlotAliases() {
        let placer = makePlacer()
        let canvas = CGSize(width: 100, height: 200)

        // Two images: one declared with below_title, one with above_subtitle.
        // Both canonicalize to the same slot, so querying either alias should
        // pick up both items and yield the same reserved height.
        let belowTitle = ImageConfig(
            path: .shared("/a.png"),
            position: .belowTitle,
            maxHeightPct: 6
        )
        let aboveSubtitle = ImageConfig(
            path: .shared("/b.png"),
            position: .aboveSubtitle,
            maxHeightPct: 9
        )

        let viaBelow = placer.reservedHeight(
            position: .belowTitle,
            images: [belowTitle, aboveSubtitle],
            laurels: [],
            appearance: "light",
            canvasSize: canvas,
            isFirstInCombo: true
        )
        let viaAbove = placer.reservedHeight(
            position: .aboveSubtitle,
            images: [belowTitle, aboveSubtitle],
            laurels: [],
            appearance: "light",
            canvasSize: canvas,
            isFirstInCombo: true
        )
        XCTAssertEqual(viaBelow, viaAbove, "below_title and above_subtitle must canonicalize to the same slot")
        // Max of the two heights wins: 200 * 9/100 = 18.
        XCTAssertEqual(viaBelow, 18, accuracy: 0.001)
    }

    func testReservedHeight_capsItemsAtTwo() {
        let placer = makePlacer()
        let canvas = CGSize(width: 100, height: 200)

        // Three images at the same slot, third should be ignored. Reservation
        // is the max of the kept items (first two): max(8, 12) * canvas.height = 24.
        let imgs: [ImageConfig] = [
            ImageConfig(path: .shared("/a.png"), position: .aboveTitle, maxHeightPct: 8),
            ImageConfig(path: .shared("/b.png"), position: .aboveTitle, maxHeightPct: 12),
            ImageConfig(path: .shared("/c.png"), position: .aboveTitle, maxHeightPct: 30),
        ]
        let h = placer.reservedHeight(
            position: .aboveTitle,
            images: imgs,
            laurels: [],
            appearance: "light",
            canvasSize: canvas,
            isFirstInCombo: true
        )
        XCTAssertEqual(h, 24, accuracy: 0.001,
                       "third item must be dropped; reservation is max of first two")
    }

    func testReservedHeight_placementFirstOnlyExcludesNonFirst() {
        let placer = makePlacer()
        let canvas = CGSize(width: 100, height: 200)
        let img = ImageConfig(
            path: .shared("/a.png"),
            position: .aboveTitle,
            maxHeightPct: 10,
            placement: .firstOnly
        )
        let h = placer.reservedHeight(
            position: .aboveTitle,
            images: [img],
            laurels: [],
            appearance: "light",
            canvasSize: canvas,
            isFirstInCombo: false
        )
        XCTAssertEqual(h, 0, "first_only placement must skip non-first slides")
    }

    func testReservedHeight_placementAllIncludesNonFirst() {
        let placer = makePlacer()
        let canvas = CGSize(width: 100, height: 200)
        let img = ImageConfig(
            path: .shared("/a.png"),
            position: .aboveTitle,
            maxHeightPct: 10,
            placement: .all
        )
        let h = placer.reservedHeight(
            position: .aboveTitle,
            images: [img],
            laurels: [],
            appearance: "light",
            canvasSize: canvas,
            isFirstInCombo: false
        )
        XCTAssertEqual(h, 20, accuracy: 0.001,
                       "placement: all must keep the item on non-first slides")
    }

    // MARK: - drawSlot smoke test

    func testDrawSlot_drawsIntoContext() throws {
        // Tiny solid-red PNG written to disk; we confirm a pixel inside the
        // slot rect is non-transparent after drawing.
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-placer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let pngURL = runRoot.appendingPathComponent("dot.png")
        try writeSolidColorPNG(width: 16, height: 16, color: .red, to: pngURL)

        let placer = OverlayPlacer(
            baseDirectory: runRoot,
            fontResolver: FontResolver(baseDirectory: runRoot)
        )

        let canvasW = 100, canvasH = 200
        let canvas = CGSize(width: canvasW, height: canvasH)

        // Build a 100x200 transparent context.
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Start fully transparent so we can detect any drawn pixels.
        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        let img = ImageConfig(
            path: .shared(pngURL.path),
            position: .aboveTitle,
            align: .center,
            maxHeightPct: 20  // 200 * 0.20 = 40px tall
        )

        let slotHeight: CGFloat = 40
        let slotRect = CGRect(
            x: 0,
            y: CGFloat(canvasH) - slotHeight,
            width: CGFloat(canvasW),
            height: slotHeight
        )

        let warnings = placer.drawSlot(
            position: .aboveTitle,
            images: [img],
            laurels: [],
            appearance: "light",
            slotRect: slotRect,
            canvasSize: canvas,
            isFirstInCombo: true,
            into: ctx
        )
        XCTAssertTrue(warnings.isEmpty, "expected no warnings; got \(warnings)")

        // Grab the resulting image and inspect a pixel near the center of the
        // slot. It should be opaque (alpha > 0). The 16x16 source is square and
        // scales to ~40x40; centered horizontally at x=50, vertically inside
        // the top 40px of the canvas (CG-y in [160, 200)).
        let cgOut = ctx.makeImage()!
        let data = cgOut.dataProvider!.data! as Data
        let bpp = 4
        // CG image data is laid out top-down, so the top of the canvas (CG-y
        // closest to canvasH) is the first row in the buffer. Sample a row a
        // few pixels in from the top edge, near the horizontal center.
        let probeY = 10
        let probeX = canvasW / 2
        let off = probeY * cgOut.bytesPerRow + probeX * bpp
        let alpha = data[off + 3]
        XCTAssertGreaterThan(alpha, 0,
                             "expected drawn pixel near center of above_title slot; alpha=\(alpha)")
    }

    // MARK: - Helpers

    private func makePlacer() -> OverlayPlacer {
        let baseDir = URL(fileURLWithPath: "/tmp")
        return OverlayPlacer(
            baseDirectory: baseDir,
            fontResolver: FontResolver(baseDirectory: baseDir)
        )
    }

    /// Writes a solid-color PNG of the requested dimensions. Used to create
    /// tiny image fixtures for the drawSlot smoke test without depending on
    /// real assets.
    private func writeSolidColorPNG(width: Int, height: Int, color: NSColor, to url: URL) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "OverlayPlacerTests", code: 1) }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "OverlayPlacerTests", code: 2) }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "OverlayPlacerTests", code: 3)
        }
    }
}
