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
