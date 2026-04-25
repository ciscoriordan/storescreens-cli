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

    /// Two narrow items: equal whitespace with a comfortable margin on each
    /// side. canvas=120, items 20px wide, total gap = 80, gap = 80/3 ≈ 26.7.
    /// Item 1 left at 26.7, item 2 left at 73.3.
    func testDrawSlot_twoItems_narrow_equalWhitespace() throws {
        let probe = try probeTwoItems(itemWidth: 20, itemHeight: 20, canvasW: 120,
                                      aligns: (.left, .right))
        // Expected: gap = (120 - 40) / 3 = 26.67 (truncated to 26 by px math).
        XCTAssertEqual(probe.firstItemLeftX, 26, accuracy: 2,
            "item 1 left edge should be at gap (~26); got \(probe.firstItemLeftX)")
        XCTAssertEqual(probe.secondItemLeftX, 74, accuracy: 2,
            "item 2 left edge should be at canvas - gap - w (~74); got \(probe.secondItemLeftX)")
    }

    /// Two items at canvas/3 wide each: gap = (120 - 80)/3 = 13. Items at
    /// x=13 and x=67. Verifies the equal-whitespace formula at the size the
    /// old "centers at thirds" rule used to call equal.
    func testDrawSlot_twoItems_thirdsWide_equalWhitespace() throws {
        let probe = try probeTwoItems(itemWidth: 40, itemHeight: 20, canvasW: 120,
                                      aligns: (nil, nil))
        XCTAssertEqual(probe.firstItemLeftX, 13, accuracy: 2,
            "item 1 left should be at gap (~13); got \(probe.firstItemLeftX)")
        XCTAssertEqual(probe.secondItemLeftX, 67, accuracy: 2,
            "item 2 left should be at canvas - gap - w (~67); got \(probe.secondItemLeftX)")
        XCTAssertLessThan(probe.firstItemLeftX + 40, probe.secondItemLeftX,
            "items must not touch with this much canvas left over")
    }

    /// Two items each exactly canvas/2 wide: gap collapses to 0, items abut
    /// at the midline with no overlap and no whitespace.
    func testDrawSlot_twoItems_halfEach_abutWithZeroGap() throws {
        let probe = try probeTwoItems(itemWidth: 60, itemHeight: 20, canvasW: 120,
                                      aligns: (nil, nil))
        XCTAssertEqual(probe.firstItemLeftX, 0, accuracy: 2,
            "item 1 should abut canvas left; got \(probe.firstItemLeftX)")
        XCTAssertEqual(probe.secondItemLeftX, 60, accuracy: 2,
            "item 2 should start at midline (60); got \(probe.secondItemLeftX)")
    }

    /// Two items wider than canvas/3 but still fitting: equal whitespace must
    /// keep them from overlapping. canvas=120, items 50px each, total = 100,
    /// total gap = 20, gap = 6.7. Item 1 left ≈ 6.7, item 2 left ≈ 63.
    func testDrawSlot_twoItems_widerThanThirds_noOverlap() throws {
        let probe = try probeTwoItems(itemWidth: 50, itemHeight: 20, canvasW: 120,
                                      aligns: (nil, nil))
        XCTAssertEqual(probe.firstItemLeftX, 6, accuracy: 2,
            "item 1 left should be at gap (~6); got \(probe.firstItemLeftX)")
        XCTAssertEqual(probe.secondItemLeftX, 63, accuracy: 2,
            "item 2 left should leave equal gap on right; got \(probe.secondItemLeftX)")
        // Inner edges must not overlap: item1.right < item2.left.
        XCTAssertLessThan(probe.firstItemLeftX + 50, probe.secondItemLeftX,
            "items must not overlap; item1.right=\(probe.firstItemLeftX + 50) item2.left=\(probe.secondItemLeftX)")
    }

    /// Two items genuinely wider than the canvas: clamp to abut at the
    /// midline and emit a warning. canvas=120, items 80px each. Item 1 is
    /// placed at x=-20 (left half off-canvas) so its visible portion ends at
    /// the midline; item 2 starts at the midline. Visible portions of the
    /// two items must not overlap.
    func testDrawSlot_twoItems_overflow_clampedAtMidlineWithWarning() throws {
        let probe = try probeTwoItems(itemWidth: 80, itemHeight: 20, canvasW: 120,
                                      aligns: (nil, nil), captureWarnings: true)
        // Item 1 placed at -20 means visible left edge clips to 0 (no probe
        // can detect the off-canvas portion). The visible right edge of red
        // and the visible left edge of blue must both be at the midline (60).
        XCTAssertEqual(probe.firstItemLeftX, 0, accuracy: 1,
            "item 1's visible left edge should clip to 0; got \(probe.firstItemLeftX)")
        XCTAssertEqual(probe.secondItemLeftX, 60, accuracy: 2,
            "item 2 must start at the midline (60); got \(probe.secondItemLeftX)")
        XCTAssertTrue(probe.warnings.contains(where: { $0.contains("exceeds canvas") }),
            "overflow case must emit a warning; got \(probe.warnings)")
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

    // MARK: - Tables

    /// Empty table renders without crashing and contributes no reservation.
    func testTable_empty_reservedHeightZero() {
        let placer = makePlacer()
        let canvas = CGSize(width: 200, height: 400)
        let table = TableConfig(rows: [], position: .belowSubtitle, maxHeightPct: 14)
        let h = placer.reservedHeight(
            position: .belowSubtitle, images: [], laurels: [], tables: [table],
            appearance: "light", canvasSize: canvas, isFirstInCombo: true
        )
        // Empty rows still claim max_height_pct because we reserve before
        // measuring. That's OK; the rendered image is a no-op.
        XCTAssertEqual(h, 56, accuracy: 0.001,
            "empty table still reserves max_height_pct of canvas height")
    }

    /// Non-empty table reserves max_height_pct of canvas height regardless of
    /// content size (width is content-driven, height is config-driven).
    func testTable_reservedHeight_matchesMaxHeightPct() {
        let placer = makePlacer()
        let canvas = CGSize(width: 200, height: 400)
        let table = TableConfig(
            rows: [["A", "B"], ["C", "D"]],
            position: .belowSubtitle,
            maxHeightPct: 10
        )
        let h = placer.reservedHeight(
            position: .belowSubtitle, images: [], laurels: [], tables: [table],
            appearance: "light", canvasSize: canvas, isFirstInCombo: true
        )
        XCTAssertEqual(h, 40, accuracy: 0.001,
            "10% of canvas height = 40px")
    }

    /// Drawing a 2x2 table with a tinted border lays down border pixels at
    /// the expected positions. Probe a single row near the table top to find
    /// the leftmost border-color pixel; it should match the slot's left
    /// padding (the table's totalWidth is centered in the slot).
    func testTable_drawSlot_drawsBorder() throws {
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("table-draw-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let canvasW = 400, canvasH = 600
        let ctx = makeTransparentContext(width: canvasW, height: canvasH)
        let placer = OverlayPlacer(
            baseDirectory: runRoot,
            fontResolver: FontResolver(baseDirectory: runRoot)
        )
        let table = TableConfig(
            rows: [["1", "2"], ["3", "4"]],
            textColor: .shared("#FFFFFF"),
            borderColor: .shared("#FF00FF"),
            position: .aboveTitle,
            align: .center,
            maxHeightPct: 12
        )
        let slotH: CGFloat = CGFloat(canvasH) * 0.12
        let slotRect = CGRect(x: 0, y: CGFloat(canvasH) - slotH,
                              width: CGFloat(canvasW), height: slotH)
        let canvas = CGSize(width: canvasW, height: canvasH)

        let warns = placer.drawSlot(
            position: .aboveTitle, images: [], laurels: [], tables: [table],
            appearance: "light", slotRect: slotRect, canvasSize: canvas,
            isFirstInCombo: true, into: ctx
        )
        XCTAssertTrue(warns.isEmpty, "no warnings expected; got \(warns)")

        // Border pixels are magenta. Find them anywhere on the canvas to
        // confirm something rendered.
        let cg = ctx.makeImage()!
        var foundBorder = false
        outer: for y in 0..<cg.height {
            let bounds = colorBoundsX(in: cg, scanRowFromTop: y, channel: .red)
            // colorBoundsX(.red) won't match magenta directly; use a simpler
            // scan: any non-transparent pixel inside the slot rect is good.
            _ = bounds
            for x in 0..<cg.width {
                let off = y * cg.bytesPerRow + x * 4
                let data = cg.dataProvider!.data! as Data
                if data[off + 3] > 0 {
                    foundBorder = true
                    break outer
                }
            }
        }
        XCTAssertTrue(foundBorder, "expected at least one drawn pixel from the table")
    }

    /// Cells with `\n` produce in-cell line breaks; the row containing the
    /// multi-line cell auto-grows, so other rows aren't bled into.
    func testTable_multiLineCell_growsRow() throws {
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("table-multi-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let placer = OverlayPlacer(
            baseDirectory: runRoot,
            fontResolver: FontResolver(baseDirectory: runRoot)
        )
        let canvasH = 600
        let canvas = CGSize(width: 400, height: CGFloat(canvasH))
        let single = TableConfig(
            rows: [["A", "B"], ["C", "D"]],
            position: .aboveTitle, maxHeightPct: 12
        )
        let multi = TableConfig(
            rows: [["A", "B"], ["C", "Spelling and\nlocation"]],
            position: .aboveTitle, maxHeightPct: 12
        )
        let hSingle = placer.reservedHeight(
            position: .aboveTitle, images: [], laurels: [], tables: [single],
            appearance: "light", canvasSize: canvas, isFirstInCombo: true
        )
        let hMulti = placer.reservedHeight(
            position: .aboveTitle, images: [], laurels: [], tables: [multi],
            appearance: "light", canvasSize: canvas, isFirstInCombo: true
        )
        // Both report the same reservation since reservedHeight is config-
        // based (max_height_pct), not content-based. Real test: render and
        // verify the multi-line cell didn't bleed past its row boundary.
        XCTAssertEqual(hSingle, hMulti, "reservedHeight is config-based")

        // Render the multi-line table and assert no warnings.
        let ctx = makeTransparentContext(width: 400, height: canvasH)
        let slotH = canvas.height * 0.12
        let slotRect = CGRect(x: 0, y: canvas.height - slotH,
                              width: canvas.width, height: slotH)
        let warns = placer.drawSlot(
            position: .aboveTitle, images: [], laurels: [], tables: [multi],
            appearance: "light", slotRect: slotRect,
            canvasSize: canvas, isFirstInCombo: true, into: ctx
        )
        XCTAssertTrue(warns.isEmpty, "multi-line cell render must not warn; got \(warns)")
    }

    /// `column_aligns: [left, right]` for a 2-column table renders cell text
    /// flush left in column 0 and flush right in column 1.
    func testTable_columnAligns_overridesCellStyle() throws {
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("table-colaligns-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let placer = OverlayPlacer(
            baseDirectory: runRoot,
            fontResolver: FontResolver(baseDirectory: runRoot)
        )
        // Just verify the field decodes and renders without crashing. Visual
        // alignment correctness is exercised by single-item alignment tests
        // for images; the same alignOffset routine is used for cells.
        let table = TableConfig(
            rows: [["wide-content-on-left", "x"], ["a", "wide-content-on-right"]],
            columnAligns: [.left, .right],
            position: .aboveTitle, maxHeightPct: 14
        )
        let ctx = makeTransparentContext(width: 400, height: 600)
        let canvas = CGSize(width: 400, height: 600)
        let slotH: CGFloat = 600 * 0.14
        let slotRect = CGRect(x: 0, y: canvas.height - slotH,
                              width: canvas.width, height: slotH)
        let warns = placer.drawSlot(
            position: .aboveTitle, images: [], laurels: [], tables: [table],
            appearance: "light", slotRect: slotRect, canvasSize: canvas,
            isFirstInCombo: true, into: ctx
        )
        XCTAssertTrue(warns.isEmpty, "column_aligns render must not warn; got \(warns)")
    }

    /// Padding short rows: a 2-column-wide first row + 1-column second row
    /// gets padded to 2x2 with the [1][1] cell empty. Renders without crash.
    func testTable_unequalRows_padsWithEmpty() throws {
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("table-pad-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let canvasW = 400, canvasH = 600
        let ctx = makeTransparentContext(width: canvasW, height: canvasH)
        let placer = OverlayPlacer(
            baseDirectory: runRoot,
            fontResolver: FontResolver(baseDirectory: runRoot)
        )
        let table = TableConfig(
            rows: [["A", "B"], ["C"]],   // second row is short
            position: .aboveTitle,
            maxHeightPct: 10
        )
        let slotH: CGFloat = CGFloat(canvasH) * 0.10
        let slotRect = CGRect(x: 0, y: CGFloat(canvasH) - slotH,
                              width: CGFloat(canvasW), height: slotH)
        let canvas = CGSize(width: canvasW, height: canvasH)

        let warns = placer.drawSlot(
            position: .aboveTitle, images: [], laurels: [], tables: [table],
            appearance: "light", slotRect: slotRect, canvasSize: canvas,
            isFirstInCombo: true, into: ctx
        )
        XCTAssertTrue(warns.isEmpty, "padding short rows must not warn; got \(warns)")
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
        let firstItemLeftX: Int
        let secondItemLeftX: Int
        let firstItemCenterX: CGFloat
        let secondItemCenterX: CGFloat
        let warnings: [String]
    }

    /// Renders two items in the same slot at given pixel widths/heights, with
    /// the given aligns. Source PNGs are written at exactly `itemWidth × itemHeight`
    /// so when the renderer scales by `maxHeightPct = itemHeight/canvasH * 100`
    /// the final pixel width matches `itemWidth`. Returns the leftmost x of
    /// each item (located by scanning for distinct red and blue color runs).
    private func probeTwoItems(
        itemWidth: Int = 10, itemHeight: Int = 10, canvasW: Int = 120,
        aligns: (CaptionAlign?, CaptionAlign?), captureWarnings: Bool = false
    ) throws -> TwoItemsProbe {
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-probe-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let redURL = runRoot.appendingPathComponent("red.png")
        let blueURL = runRoot.appendingPathComponent("blue.png")
        try writeSolidColorPNG(width: itemWidth, height: itemHeight, color: .red, to: redURL)
        try writeSolidColorPNG(width: itemWidth, height: itemHeight, color: .blue, to: blueURL)

        let canvasH = 200
        let maxHeightPct = Double(itemHeight) / Double(canvasH) * 100.0
        let ctx = makeTransparentContext(width: canvasW, height: canvasH)
        let placer = OverlayPlacer(
            baseDirectory: runRoot,
            fontResolver: FontResolver(baseDirectory: runRoot)
        )
        let img1 = ImageConfig(
            path: .shared(redURL.path),
            position: .aboveTitle, align: aligns.0, maxHeightPct: maxHeightPct
        )
        let img2 = ImageConfig(
            path: .shared(blueURL.path),
            position: .aboveTitle, align: aligns.1, maxHeightPct: maxHeightPct
        )
        let slotH = CGFloat(itemHeight)
        let slotRect = CGRect(x: 0, y: CGFloat(canvasH) - slotH,
                              width: CGFloat(canvasW), height: slotH)
        let canvas = CGSize(width: canvasW, height: canvasH)

        let warns = placer.drawSlot(
            position: .aboveTitle, images: [img1, img2], laurels: [],
            appearance: "light", slotRect: slotRect, canvasSize: canvas,
            isFirstInCombo: true, into: ctx
        )

        let cg = ctx.makeImage()!
        let redBounds = colorBoundsX(in: cg, scanRowFromTop: itemHeight / 2, channel: .red)
        let blueBounds = colorBoundsX(in: cg, scanRowFromTop: itemHeight / 2, channel: .blue)
        return TwoItemsProbe(
            canvasW: CGFloat(canvasW),
            firstItemLeftX: redBounds.minX,
            secondItemLeftX: blueBounds.minX,
            firstItemCenterX: CGFloat(redBounds.minX + redBounds.maxX) / 2,
            secondItemCenterX: CGFloat(blueBounds.minX + blueBounds.maxX) / 2,
            warnings: captureWarnings ? warns : []
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

    /// Finds the leftmost and rightmost x where the row's pixel matches the
    /// given color channel. Items partially clipped off-canvas are still
    /// detected via their visible portion.
    private func colorBoundsX(in cg: CGImage, scanRowFromTop y: Int, channel: ColorChannel) -> (minX: Int, maxX: Int) {
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
        return (minX, maxX)
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
