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

    // MARK: - drawSlot positioning

    /// One item with no `align` set must land at the slot's horizontal center
    /// (defaults are: `align: center`, vertically centered in the slot rect).
    func testDrawSlot_singleItem_defaultAlignCentersHorizontally() throws {
        let probe = try probeSingleItemX(align: nil)
        XCTAssertEqual(probe.itemCenterX, probe.canvasW / 2, accuracy: 2,
            "default align should center the item; got centerX=\(probe.itemCenterX) canvasW=\(probe.canvasW)")
    }

    /// One item with `align: left` lands flush to the slot's left edge.
    func testDrawSlot_singleItem_alignLeft_pinsLeft() throws {
        let probe = try probeSingleItemX(align: .left)
        XCTAssertEqual(probe.itemLeftX, 0, accuracy: 2,
            "align: left should pin item at slot.minX; got leftX=\(probe.itemLeftX)")
    }

    /// Two items in the same slot auto-distribute at canvas thirds, regardless
    /// of each item's `align`. Item centers at x = canvasW * 1/3 and 2/3.
    func testDrawSlot_twoItems_distributesAtThirds() throws {
        let probe = try probeTwoItems(aligns: (.left, .right))
        XCTAssertEqual(probe.firstItemCenterX, probe.canvasW / 3, accuracy: 2,
            "first item center should be at canvas/3; got \(probe.firstItemCenterX)")
        XCTAssertEqual(probe.secondItemCenterX, probe.canvasW * 2 / 3, accuracy: 2,
            "second item center should be at canvas*2/3; got \(probe.secondItemCenterX)")
    }

    /// Same auto-distribute even when both items default-align (no align set).
    func testDrawSlot_twoItems_noAlign_distributesAtThirds() throws {
        let probe = try probeTwoItems(aligns: (nil, nil))
        XCTAssertEqual(probe.firstItemCenterX, probe.canvasW / 3, accuracy: 2,
            "first item should distribute to canvas/3 even with no align; got \(probe.firstItemCenterX)")
        XCTAssertEqual(probe.secondItemCenterX, probe.canvasW * 2 / 3, accuracy: 2,
            "second item should distribute to canvas*2/3 even with no align; got \(probe.secondItemCenterX)")
    }

    // MARK: - Laurel inset_pct

    /// inset_pct shifts the left laurel right and the right laurel left by
    /// `inset_pct` percent of the laurel block height. Renders a laurel with
    /// two different inset values, scans for the leftmost laurel pixel near
    /// the top of the block (text doesn't reach there), and confirms the
    /// shift matches.
    func testLaurel_insetPct_shiftsLeftLaurelRight() throws {
        let baseLeft = try probeLaurelLeftEdge(insetPct: 0)
        let insetLeft = try probeLaurelLeftEdge(insetPct: 12)

        let canvasH: CGFloat = 600
        let blockH = canvasH * 0.10  // max_height_pct = 10
        let expectedShift = blockH * 12 / 100  // 12% of 60 = 7.2 px

        let actualShift = CGFloat(insetLeft - baseLeft)
        XCTAssertEqual(actualShift, expectedShift, accuracy: 2,
            "inset_pct: 12 should shift the left laurel right by ~\(expectedShift)px; got \(actualShift)")
    }

    private func probeLaurelLeftEdge(insetPct: Double) throws -> Int {
        let canvasW = 400, canvasH = 600
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("laurel-inset-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let ctx = makeTransparentContext(width: canvasW, height: canvasH)
        let placer = OverlayPlacer(
            baseDirectory: runRoot,
            fontResolver: FontResolver(baseDirectory: runRoot)
        )
        // Use a recognizable color so we can scan for laurel pixels and not
        // accidentally pick up alpha noise from anti-aliasing.
        let laurel = LaurelConfig(
            title: .string("X"),
            color: .shared("#FF00FF"),
            position: .aboveTitle,
            maxHeightPct: 10,
            insetPct: insetPct
        )
        // Slot at the top of the canvas, full width.
        let slotH = CGFloat(canvasH) * 0.10
        let slotRect = CGRect(x: 0, y: CGFloat(canvasH) - slotH,
                              width: CGFloat(canvasW), height: slotH)
        let canvas = CGSize(width: canvasW, height: canvasH)

        _ = placer.drawSlot(
            position: .aboveTitle, images: [], laurels: [laurel],
            appearance: "light", slotRect: slotRect, canvasSize: canvas,
            isFirstInCombo: true, into: ctx
        )

        let cg = ctx.makeImage()!
        // Scan a row near the top of the laurel block (block top is at y=0 in
        // CG, image data is top-down so screen-y=2 is the top edge area).
        return findLeftmostMagentaX(in: cg, scanRowFromTop: 6)
    }

    /// Finds the leftmost x where r>200 && b>200 && g<60 (magenta laurel tint).
    /// Skips alpha-only pixels so anti-aliasing edges don't fool the probe.
    private func findLeftmostMagentaX(in cg: CGImage, scanRowFromTop y: Int) -> Int {
        let data = cg.dataProvider!.data! as Data
        let bpp = 4
        for x in 0..<cg.width {
            let off = y * cg.bytesPerRow + x * bpp
            let r = data[off], g = data[off + 1], b = data[off + 2]
            if r > 200 && g < 60 && b > 200 {
                return x
            }
        }
        return cg.width  // not found, return rightmost
    }

    // MARK: - Probe helpers

    private struct SinglePositionProbe {
        let canvasW: CGFloat
        let itemLeftX: CGFloat
        let itemCenterX: CGFloat
    }

    /// Renders a single-item slot with the given align and returns the bounds
    /// of the rendered image found by scanning for non-transparent pixels.
    private func probeSingleItemX(align: CaptionAlign?) throws -> SinglePositionProbe {
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-probe-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let pngURL = runRoot.appendingPathComponent("a.png")
        try writeSolidColorPNG(width: 10, height: 10, color: .red, to: pngURL)

        let canvasW = 100, canvasH = 200
        let ctx = makeTransparentContext(width: canvasW, height: canvasH)
        let placer = OverlayPlacer(
            baseDirectory: runRoot,
            fontResolver: FontResolver(baseDirectory: runRoot)
        )
        let img = ImageConfig(
            path: .shared(pngURL.path),
            position: .aboveTitle,
            align: align,
            maxHeightPct: 5
        )
        let slotH: CGFloat = 10
        let slotRect = CGRect(x: 0, y: CGFloat(canvasH) - slotH,
                              width: CGFloat(canvasW), height: slotH)
        let canvas = CGSize(width: canvasW, height: canvasH)

        _ = placer.drawSlot(
            position: .aboveTitle, images: [img], laurels: [],
            appearance: "light", slotRect: slotRect, canvasSize: canvas,
            isFirstInCombo: true, into: ctx
        )

        let cg = ctx.makeImage()!
        let bounds = nonTransparentBoundsX(in: cg, scanRowFromTop: 5)
        return SinglePositionProbe(
            canvasW: CGFloat(canvasW),
            itemLeftX: CGFloat(bounds.minX),
            itemCenterX: CGFloat(bounds.minX + bounds.maxX) / 2
        )
    }

    private struct TwoItemsProbe {
        let canvasW: CGFloat
        let firstItemCenterX: CGFloat
        let secondItemCenterX: CGFloat
    }

    /// Renders two items in the same slot with the given aligns and returns
    /// the centers of each rendered image found by scanning for distinct
    /// colors. Two items share a slot, item 1 is red, item 2 is blue.
    private func probeTwoItems(aligns: (CaptionAlign?, CaptionAlign?)) throws -> TwoItemsProbe {
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-probe-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let redURL = runRoot.appendingPathComponent("red.png")
        let blueURL = runRoot.appendingPathComponent("blue.png")
        try writeSolidColorPNG(width: 10, height: 10, color: .red, to: redURL)
        try writeSolidColorPNG(width: 10, height: 10, color: .blue, to: blueURL)

        let canvasW = 120, canvasH = 200
        let ctx = makeTransparentContext(width: canvasW, height: canvasH)
        let placer = OverlayPlacer(
            baseDirectory: runRoot,
            fontResolver: FontResolver(baseDirectory: runRoot)
        )
        let img1 = ImageConfig(
            path: .shared(redURL.path),
            position: .aboveTitle, align: aligns.0, maxHeightPct: 5
        )
        let img2 = ImageConfig(
            path: .shared(blueURL.path),
            position: .aboveTitle, align: aligns.1, maxHeightPct: 5
        )
        let slotH: CGFloat = 10
        let slotRect = CGRect(x: 0, y: CGFloat(canvasH) - slotH,
                              width: CGFloat(canvasW), height: slotH)
        let canvas = CGSize(width: canvasW, height: canvasH)

        _ = placer.drawSlot(
            position: .aboveTitle, images: [img1, img2], laurels: [],
            appearance: "light", slotRect: slotRect, canvasSize: canvas,
            isFirstInCombo: true, into: ctx
        )

        let cg = ctx.makeImage()!
        let redCenter = colorCenterX(in: cg, scanRowFromTop: 5, channel: .red)
        let blueCenter = colorCenterX(in: cg, scanRowFromTop: 5, channel: .blue)
        return TwoItemsProbe(
            canvasW: CGFloat(canvasW),
            firstItemCenterX: CGFloat(redCenter),
            secondItemCenterX: CGFloat(blueCenter)
        )
    }

    private func makeTransparentContext(width: Int, height: Int) -> CGContext {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    /// Scans one row of `cg` (counted from the top) and returns the leftmost
    /// and rightmost columns where alpha > 0.
    private func nonTransparentBoundsX(in cg: CGImage, scanRowFromTop y: Int) -> (minX: Int, maxX: Int) {
        let data = cg.dataProvider!.data! as Data
        let bpp = 4
        var minX = cg.width
        var maxX = -1
        for x in 0..<cg.width {
            let off = y * cg.bytesPerRow + x * bpp
            if data[off + 3] > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }
        return (minX, maxX)
    }

    private enum ColorChannel { case red, blue }

    /// Finds the horizontal center of the run of pixels matching the given
    /// channel (red: r>200,g<60,b<60; blue: b>200,r<60,g<60) on the given row.
    private func colorCenterX(in cg: CGImage, scanRowFromTop y: Int, channel: ColorChannel) -> Int {
        let data = cg.dataProvider!.data! as Data
        let bpp = 4
        var minX = cg.width
        var maxX = -1
        for x in 0..<cg.width {
            let off = y * cg.bytesPerRow + x * bpp
            let r = data[off], g = data[off + 1], b = data[off + 2]
            let match: Bool
            switch channel {
            case .red:  match = r > 200 && g < 60 && b < 60
            case .blue: match = b > 200 && r < 60 && g < 60
            }
            if match {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }
        return (minX + maxX) / 2
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
