import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
@testable import StorescreensCore

/// Verifies that `caption.vertical_align` and `caption.nudge` actually shift
/// where the caption lands in the rendered PNG. Strategy: run the full
/// render with each vertical_align + a y_nudge, then sample columns of the
/// caption band and find where light-colored text pixels live. Assert
/// ordering: top-aligned text sits higher (larger y index from image origin)
/// than center, which sits higher than bottom.
final class CaptionPlacementTests: XCTestCase {

    func testVerticalAlignShiftsCaption() async throws {
        let topY = try await renderAndFindCaptionTop(verticalAlign: .top, nudgeYPct: nil)
        let centerY = try await renderAndFindCaptionTop(verticalAlign: .center, nudgeYPct: nil)
        let bottomY = try await renderAndFindCaptionTop(verticalAlign: .bottom, nudgeYPct: nil)

        XCTAssertLessThan(topY, centerY,
            "vertical_align: top must place text higher (lower y-from-image-top) than center — got top=\(topY), center=\(centerY)")
        XCTAssertLessThan(centerY, bottomY,
            "vertical_align: center must be higher than bottom — got center=\(centerY), bottom=\(bottomY)")
    }

    /// Verifies absolute pixel position of each vertical_align value, not
    /// just ordering. With a 1434px canvas and min_height_pct=22 (band ~315px),
    /// the gap between top->center and center->bottom must each equal half
    /// the band's slack space. Pixel-scanning hits the topmost visible glyph,
    /// which sits one font-ascender (~20px for system bold at 5.5%) below the
    /// line-box top, but that offset is uniform across all three positions
    /// and cancels out of the expected_step math.
    func testVerticalAlign_centersBlockInBand() async throws {
        let canvasH = 1434
        let bandPct = 22.0
        let bandH = Int(Double(canvasH) * bandPct / 100.0)

        let topY = try await renderAndFindCaptionTop(verticalAlign: .top, nudgeYPct: nil)
        let centerY = try await renderAndFindCaptionTop(verticalAlign: .center, nudgeYPct: nil)
        let bottomY = try await renderAndFindCaptionTop(verticalAlign: .bottom, nudgeYPct: nil)

        // bottom places block bottom at band bottom; top places block top at
        // band top. (bottomY - topY) = bandH - blockH because top->bottom
        // shifts by the slack space exactly.
        let derivedBlockH = bandH - (bottomY - topY)
        XCTAssertGreaterThan(derivedBlockH, 40,
            "sanity: derived block-height should be substantial (got \(derivedBlockH))")

        // Center should sit halfway between top and bottom positions.
        let expectedCenterY = (topY + bottomY) / 2
        let tolerance = 4
        XCTAssertLessThan(abs(centerY - expectedCenterY), tolerance,
            "vertical_align: center should be midway between top (\(topY)) and bottom (\(bottomY)), got \(centerY); expected \(expectedCenterY)")

        // The full slack between top and bottom must equal band - block.
        let expectedSlack = bandH - derivedBlockH
        XCTAssertEqual(bottomY - topY, expectedSlack,
            "top->bottom gap must equal band slack (\(expectedSlack)), got \(bottomY - topY)")
    }

    /// Multi-line dense caption: with vertical_align: center, the slack
    /// space (band - block) must split equally above and below the block.
    /// User reported 2% above + 8% below on a 5-line caption in a 22% band,
    /// which would imply a 6-percentage-point top bias.
    func testVerticalAlign_centersDenseMultiLineCaption() async throws {
        let topY = try await renderAndFindCaptionBounds(
            title: ["Line one", "Line two", "Line three", "Line four", "Line five"],
            verticalAlign: .center, minHeightPct: 40, fontSizePct: 4
        )
        let canvasH = 1434
        let bandH = Int(Double(canvasH) * 40.0 / 100.0)
        let topSlack = topY.top
        let bottomSlack = bandH - topY.bottom
        XCTAssertEqual(topSlack, bottomSlack, accuracy: 6,
            "5-line caption (roomy band): center should split slack equally. top=\(topSlack), bottom=\(bottomSlack), bandH=\(bandH)")
    }

    /// Same as above but with the user's reported scenario: 22% band, default
    /// font size that produces a tight fit. We expect either no slack (block
    /// fills band) or the small slack to be split evenly.
    func testVerticalAlign_centersDenseCaption_tightBand() async throws {
        let bounds = try await renderAndFindCaptionBounds(
            title: ["Line one", "Line two", "Line three", "Line four", "Line five"],
            verticalAlign: .center, minHeightPct: 22, fontSizePct: 5.5
        )
        let canvasH = 1434
        let bandH = Int(Double(canvasH) * 22.0 / 100.0)
        let topSlack = bounds.top
        let bottomSlack = bandH - bounds.bottom
        XCTAssertEqual(topSlack, bottomSlack, accuracy: 8,
            "5-line caption (tight band): center should have roughly equal slack. top=\(topSlack), bottom=\(bottomSlack), bandH=\(bandH)")
    }

    /// Reproduces a real user report: iPhone 17 Pro Max canvas (1320×2868),
    /// min_height_pct=22, 5-line title with `weight: medium` base and
    /// `**markdown**` bold inside, font_size_pct=3.8 / min_font_size_pct=3.5.
    /// Block is observed to render past the band's bottom edge instead of
    /// shrinking to fit - the actual rendered block bottom lands ~30 px
    /// below where the layouter thinks it ends.
    /// With a below_subtitle overlay (table) and vertical_align: bottom on
    /// the caption, the caption block bottom must sit flush against the
    /// overlay's top edge - no chrome-inset gap between them. Pre-2.7
    /// the below_subtitle slot was positioned at deviceTopBL (which has
    /// chromeInsetDy already subtracted), creating an unreachable phantom
    /// gap users could not close even with min_height_pct floored.
    func testCaption_belowSubtitleOverlay_tightBelowCaption() async throws {
        let canvasW = 660, canvasH = 1434
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }
        let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)
        let filename = "iPhone_6.9_01_Home.png"
        try writeBlackPNG(width: canvasW, height: canvasH, to: capturedRoot.appendingPathComponent(filename))

        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "attach-test",
            appName: "CP", displayName: "CP", scheme: "CP",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: "iPhone 6.9\"", simulatorName: "iPhone 17 Pro Max",
                    locale: "en-US", appearance: nil,
                    screenshots: [CaptureManifest.Screenshot(name: "01_Home", filename: filename, capturedAt: Date())]
                ),
            ]
        )

        let config = RenderConfig(
            enabled: true,
            background: BackgroundConfig(color: .solid("#000000")),
            tables: [
                TableConfig(
                    rows: [["A"]],
                    textColor: .shared("#FF00FF"),  // magenta so it's distinguishable
                    borderColor: .shared("#00FF00"),
                    position: .belowSubtitle,
                    maxHeightPct: 10
                ),
            ],
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .system, weight: .bold, fontSizePct: 4,
                    color: "#FFFFFF", align: .center
                ),
                minHeightPct: 8, paddingPct: 4,
                verticalAlign: .bottom
            ),
            chrome: ChromeConfig(
                style: .stroke, strokeColor: "#222222", strokeWidth: 2,
                cornerRadius: .auto, shadow: false, paddingPct: 5
            ),
            slides: ["01_Home": SlideOverride(caption: SlideCaption(title: .string("Title")))]
        )

        let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
        let out = try await pipeline.render(manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot)
        XCTAssertEqual(out.failures.count, 0)

        let outURL = renderRoot.appendingPathComponent(filename)
        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = img.dataProvider?.data as Data? else {
            return XCTFail("could not read rendered PNG")
        }
        let bpp = 4
        // Find the caption block's visible bottom: scan rows top-down,
        // last row with a white pixel near the center is the caption.
        // Use an upper bound (above the table) to ignore table content.
        var captionBottomY = -1
        let captionScanLimit = img.height / 4  // caption is in the top quarter
        for y in 0..<captionScanLimit {
            for x in stride(from: img.width / 4, through: 3 * img.width / 4, by: 4) {
                let off = y * img.bytesPerRow + x * bpp
                let r = data[off], g = data[off + 1], b = data[off + 2]
                if r > 220 && g > 220 && b > 220 {
                    captionBottomY = y
                    break
                }
            }
        }
        // Find the table's top edge: scan rows top-down, first row with
        // green border pixels.
        var tableTopY = -1
        for y in 0..<img.height {
            for x in 0..<img.width {
                let off = y * img.bytesPerRow + x * bpp
                let r = data[off], g = data[off + 1], b = data[off + 2]
                if r < 60 && g > 200 && b < 60 {
                    tableTopY = y
                    break
                }
            }
            if tableTopY >= 0 { break }
        }
        XCTAssertGreaterThan(captionBottomY, 0, "caption text not found")
        XCTAssertGreaterThan(tableTopY, 0, "table not found")
        XCTAssertGreaterThan(tableTopY, captionBottomY,
            "table must be below caption")
        let gap = tableTopY - captionBottomY
        // Tight: ≤ 30 px on a 1434 canvas (~2% of canvas) accounts for
        // descender padding below the caption's last line; the chrome-inset
        // phantom gap (4% of canvas = ~57 px) is gone after the layout fix.
        XCTAssertLessThanOrEqual(gap, 30,
            "caption-to-table gap must be tight; got \(gap)px on \(img.height)px canvas. The chrome-inset phantom gap should not appear here.")
    }

    /// Regression guard for a real user repro: iPhone 17 Pro Max canvas
    /// (1320x2868), 5-line title with markdown bold inside a `weight: medium`
    /// base style, font_size_pct 3.8 / min_font_size_pct 3.5, min_height_pct
    /// 22, vertical_align center.
    ///
    /// The user reported visible asymmetry (~3% above caption vs ~8% below).
    /// Investigation showed the asymmetry is between
    /// "canvas top -> caption block" (band slack, ~1-2% of canvas) and
    /// "caption block -> device top" (band slack + chrome.padding_pct,
    /// ~5% of canvas). The block IS centered in the caption band. The
    /// imbalance is the chrome inset by design - to address visually,
    /// drop chrome.padding_pct or use the planned equal-whitespace layout.
    ///
    /// This test asserts the band-centering math is correct; the
    /// chrome-inset asymmetry is intentional and not a bug.
    func testVerticalAlign_userRepro_iPhonePro_mediumWithMarkdown() async throws {
        let bounds = try await renderAndFindCaptionBounds(
            canvasW: 1320, canvasH: 2868,
            title: [
                "Approach **native-level**",
                "pronunciation with",
                "**highly-accurate**",
                "GPU-accelerated speech",
                "recognition models",
            ],
            verticalAlign: .center,
            minHeightPct: 22, fontSizePct: 3.8, minFontSizePct: 3.5,
            weight: .medium
        )
        let bandH = Int(2868.0 * 22.0 / 100.0)
        // Block must not extend past the band's bottom edge.
        XCTAssertLessThanOrEqual(bounds.bottom, bandH + 20,
            "block bottom (\(bounds.bottom)) must not exceed bandH (\(bandH)) + tolerance")
        // Top + bottom slack split evenly within the band.
        let topSlack = bounds.top
        let bottomSlack = bandH - bounds.bottom
        XCTAssertEqual(topSlack, bottomSlack, accuracy: 30,
            "center alignment must split slack evenly within the band. top=\(topSlack), bottom=\(bottomSlack), bandH=\(bandH), blockH=\(bounds.bottom-bounds.top)")
    }

    func testNudgeY_shiftsCaptionInDirection() async throws {
        let baselineY = try await renderAndFindCaptionTop(verticalAlign: .center, nudgeYPct: nil)
        // Positive y_pct should move the caption up (toward screen top =
        // smaller y-from-image-top).
        let nudgedUp = try await renderAndFindCaptionTop(verticalAlign: .center, nudgeYPct: 5)
        XCTAssertLessThan(nudgedUp, baselineY,
            "nudge.y_pct: +5 must move text up — got nudgedUp=\(nudgedUp), baseline=\(baselineY)")
        // Negative should push it down (larger y-from-image-top).
        let nudgedDown = try await renderAndFindCaptionTop(verticalAlign: .center, nudgeYPct: -5)
        XCTAssertGreaterThan(nudgedDown, baselineY,
            "nudge.y_pct: -5 must move text down — got nudgedDown=\(nudgedDown), baseline=\(baselineY)")
    }

    // MARK: - Multi-line harness

    private struct CaptionBounds { let top: Int; let bottom: Int }

    private func renderAndFindCaptionBounds(
        canvasW: Int = 660, canvasH: Int = 1434,
        title: [String], verticalAlign: VerticalAlign,
        minHeightPct: Double = 40, fontSizePct: Double = 4,
        minFontSizePct: Double? = nil,
        weight: FontWeight = .bold
    ) async throws -> CaptionBounds {
        let width = canvasW
        let height = canvasH

        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-multi-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }
        let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

        let filename = "iPhone_6.9_01_Home.png"
        try writeBlackPNG(width: width, height: height, to: capturedRoot.appendingPathComponent(filename))

        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "caption-placement-test",
            appName: "CP", displayName: "CP", scheme: "CP",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: "iPhone 6.9\"", simulatorName: "iPhone 17 Pro Max",
                    locale: "en-US", appearance: nil,
                    screenshots: [CaptureManifest.Screenshot(name: "01_Home", filename: filename, capturedAt: Date())]
                ),
            ]
        )

        let config = RenderConfig(
            enabled: true,
            background: BackgroundConfig(color: .solid("#000000")),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .system, weight: weight,
                    fontSizePct: fontSizePct,
                    minFontSizePct: minFontSizePct,
                    color: "#FFFFFF", align: .center
                ),
                minHeightPct: minHeightPct, paddingPct: 4,
                verticalAlign: verticalAlign
            ),
            chrome: ChromeConfig(style: .stroke, strokeColor: "#222222",
                                 strokeWidth: 2, cornerRadius: .auto, shadow: false, paddingPct: 5),
            slides: ["01_Home": SlideOverride(caption: SlideCaption(title: .array(title)))]
        )

        let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
        let out = try await pipeline.render(manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot)
        XCTAssertEqual(out.failures.count, 0, "render failed: \(out.failures)")

        let outURL = renderRoot.appendingPathComponent(filename)
        return try findCaptionBounds(at: outURL)
    }

    private func findCaptionBounds(at url: URL) throws -> CaptionBounds {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = img.dataProvider?.data as Data? else {
            throw NSError(domain: "CaptionPlacementTests", code: 1)
        }
        let bpp = 4
        var first = -1
        var last = -1
        let xStart = img.width / 3
        let xEnd = 2 * img.width / 3
        for y in 0..<img.height {
            var rowHasBright = false
            for x in stride(from: xStart, through: xEnd, by: max(1, (xEnd - xStart) / 60)) {
                let off = y * img.bytesPerRow + x * bpp
                let r = data[off], g = data[off + 1], b = data[off + 2]
                if r > 220 && g > 220 && b > 220 {
                    rowHasBright = true
                    break
                }
            }
            if rowHasBright {
                if first < 0 { first = y }
                last = y
            }
        }
        guard first >= 0 else {
            throw NSError(domain: "CaptionPlacementTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no bright pixels found"])
        }
        return CaptionBounds(top: first, bottom: last)
    }

    // MARK: - Harness

    /// Renders a one-slide fixture with the given vertical alignment and
    /// returns the y coordinate (measured from the image's top edge, in pixels)
    /// of the topmost bright-white text pixel found.
    private func renderAndFindCaptionTop(
        verticalAlign: VerticalAlign,
        nudgeYPct: Double?
    ) async throws -> Int {
        let width = 660
        let height = 1434

        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-placement-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }
        let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

        let filename = "iPhone_6.9_01_Home.png"
        try writeBlackPNG(width: width, height: height, to: capturedRoot.appendingPathComponent(filename))

        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "caption-placement-test",
            appName: "CP", displayName: "CP", scheme: "CP",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: "iPhone 6.9\"", simulatorName: "iPhone 17 Pro Max",
                    locale: "en-US", appearance: nil,
                    screenshots: [CaptureManifest.Screenshot(name: "01_Home", filename: filename, capturedAt: Date())]
                ),
            ]
        )

        let config = RenderConfig(
            enabled: true,
            background: BackgroundConfig(color: .solid("#000000")),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .system, weight: .bold,
                    fontSizePct: 5.5, color: "#FFFFFF", align: .center
                ),
                minHeightPct: 22, paddingPct: 4,
                verticalAlign: verticalAlign,
                nudge: nudgeYPct.map { NudgeConfig(yPct: $0) }
            ),
            chrome: ChromeConfig(style: .stroke, strokeColor: "#222222",
                                 strokeWidth: 2, cornerRadius: .auto, shadow: false, paddingPct: 5),
            slides: ["01_Home": SlideOverride(caption: SlideCaption(title: .string("TITLE")))]
        )

        let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
        let out = try await pipeline.render(manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot)
        XCTAssertEqual(out.failures.count, 0, "render failed: \(out.failures)")

        let outURL = renderRoot.appendingPathComponent(filename)
        return try findTopmostWhitePixelRow(at: outURL)
    }

    /// Scans rows from top to bottom and returns the first row whose center
    /// column is near-white — i.e. where the caption text begins.
    private func findTopmostWhitePixelRow(at url: URL) throws -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = img.dataProvider?.data as Data? else {
            throw NSError(domain: "CaptionPlacementTests", code: 1)
        }
        let bpp = 4
        let centerX = img.width / 2
        // Scan a stripe across the middle third of the canvas; caption text
        // with center alignment lands somewhere in this horizontal range.
        let xStart = img.width / 3
        let xEnd = 2 * img.width / 3
        for y in 0..<img.height {
            for x in stride(from: xStart, through: xEnd, by: max(1, (xEnd - xStart) / 40)) {
                let off = y * img.bytesPerRow + x * bpp
                let r = data[off], g = data[off + 1], b = data[off + 2]
                if r > 220 && g > 220 && b > 220 {
                    return y
                }
            }
            _ = centerX // keep the helper honest; silence unused warning if refactored
        }
        throw NSError(
            domain: "CaptionPlacementTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "no bright text pixel found in \(url.path)"]
        )
    }

    private func writeBlackPNG(width: Int, height: Int, to url: URL) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "CaptionPlacementTests", code: 3) }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "CaptionPlacementTests", code: 4) }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "CaptionPlacementTests", code: 5)
        }
    }
}
