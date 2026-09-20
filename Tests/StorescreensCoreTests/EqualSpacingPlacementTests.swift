import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
@testable import StorescreensCore

/// Pixel tests for `caption.equal_spacing` and for the above_title band that
/// `images[].top_padding_pct` sizes. Strategy matches `CaptionPlacementTests`:
/// render a real one-slide project through the pipeline, then scan the output
/// PNG for the three things the layout rule talks about. Each is given its own
/// color so one pass over the rows separates them: the wordmark is magenta,
/// the caption text is white, and the screenshot standing in for the device is
/// green.
///
/// The fixture uses `chrome.style: none` with `chrome.fit: height` so the
/// screenshot is drawn to exactly fill the padded chrome rect. Its first green
/// row is then the same device anchor the layout solved against, which lets
/// every assertion compare measured pixels against other measured pixels
/// instead of re-deriving the pipeline's arithmetic.
final class EqualSpacingPlacementTests: XCTestCase {

    // Canvas and overlay percentages shared by the fixtures below. The logo
    // band is `logoMaxHeightPct + logoTopPaddingPct` = 22% of canvas height,
    // which is wide enough that band-centering and equal-spacing land the
    // wordmark in visibly different places (86px vs 114px from the top).
    private let canvasW = 660
    private let canvasH = 1434
    private let logoMaxHeightPct = 10.0
    private let logoTopPaddingPct = 12.0
    private let chromePaddingPct = 5.0

    // MARK: - equal_spacing on a caption-less hero

    /// A hero slide carrying only a wordmark: no caption, so the rule reduces
    /// to two gaps, canvas top -> wordmark and wordmark -> device. Both are
    /// measured between visible edges, so the wordmark reads as centered in
    /// the space above the device.
    func testEqualSpacing_captionlessHero_centersWordmarkAboveDevice() async throws {
        let (ink, warnings) = try await renderSlide(equalSpacing: true, title: nil)
        XCTAssertTrue(warnings.isEmpty, "expected a clean render; got \(warnings)")

        let gapAbove = ink.logoTop
        let gapBelow = ink.deviceTop - ink.logoBottom - 1
        XCTAssertEqual(gapAbove, gapBelow, accuracy: 3,
            "caption-less equal_spacing must leave the same gap above and below the wordmark: above=\(gapAbove)px, below=\(gapBelow)px (wordmark rows \(ink.logoTop)...\(ink.logoBottom), device top \(ink.deviceTop))")
        XCTAssertNil(ink.captionTop,
            "fixture must render no caption text; found white pixels at row \(String(describing: ink.captionTop))")
    }

    /// The same slide with `equal_spacing` off must keep the pre-existing
    /// placement: the wordmark centers inside its own above_title band, which
    /// is anchored to the canvas edge and knows nothing about the chrome inset
    /// below it. That leaves the gap below visibly fatter than the gap above,
    /// which is what the opt-in exists to fix - so this test is what proves
    /// the new branch is genuinely opt-in rather than always-on.
    func testEqualSpacing_off_captionlessHero_keepsBandCentering() async throws {
        let (off, _) = try await renderSlide(equalSpacing: false, title: nil)
        let (on, _) = try await renderSlide(equalSpacing: true, title: nil)

        // Band = (max_height_pct + top_padding_pct)% of canvas, image box =
        // max_height_pct% of canvas, and the box centers in the band.
        let bandH = Double(canvasH) * (logoMaxHeightPct + logoTopPaddingPct) / 100.0
        let boxH = Double(canvasH) * logoMaxHeightPct / 100.0
        let expectedTop = Int(((bandH - boxH) / 2.0).rounded())
        XCTAssertEqual(off.logoTop, expectedTop, accuracy: 3,
            "with equal_spacing off the wordmark must stay centered in its \(Int(bandH))px band: expected top \(expectedTop), got \(off.logoTop)")

        let gapAbove = off.logoTop
        let gapBelow = off.deviceTop - off.logoBottom - 1
        XCTAssertGreaterThan(gapBelow, gapAbove + 30,
            "band-centered placement must still show the lopsided gap it always had: above=\(gapAbove)px, below=\(gapBelow)px")

        XCTAssertNotEqual(off.logoTop, on.logoTop,
            "equal_spacing must actually move the wordmark; both runs put it at row \(off.logoTop)")
        XCTAssertEqual(off.deviceTop, on.deviceTop, accuracy: 1,
            "equal_spacing must not move the device: off=\(off.deviceTop), on=\(on.deviceTop)")
    }

    // MARK: - equal_spacing with a caption (regression guard)

    /// Regression guard on the behavior that already shipped: a slide with a
    /// caption still gets three equal gaps - canvas top -> wordmark, wordmark
    /// -> caption, caption -> device.
    ///
    /// The caption title carries descenders on purpose. `Drawable.inkExtent`
    /// models the caption's visible bottom as the line box's bottom edge (the
    /// descent line), so a title of capitals alone would stop a dozen pixels
    /// short of it and inflate the measured third gap for reasons that have
    /// nothing to do with the spacing rule.
    func testEqualSpacing_withCaption_keepsThreeEqualGaps() async throws {
        let (ink, _) = try await renderSlide(equalSpacing: true, title: "Typography")

        guard let captionTop = ink.captionTop, let captionBottom = ink.captionBottom else {
            return XCTFail("no caption text found in the rendered PNG")
        }
        let gapTopToLogo = ink.logoTop
        let gapLogoToCaption = captionTop - ink.logoBottom - 1
        let gapCaptionToDevice = ink.deviceTop - captionBottom - 1

        // Tolerance covers the descender slack described above plus the
        // anti-aliased edge row on each measured boundary.
        XCTAssertEqual(gapLogoToCaption, gapTopToLogo, accuracy: 10,
            "gap 2 (wordmark -> caption) must match gap 1 (canvas top -> wordmark): \(gapLogoToCaption)px vs \(gapTopToLogo)px")
        XCTAssertEqual(gapCaptionToDevice, gapTopToLogo, accuracy: 10,
            "gap 3 (caption -> device) must match gap 1 (canvas top -> wordmark): \(gapCaptionToDevice)px vs \(gapTopToLogo)px")
    }

    /// The caption-less branch has its own "not enough room" exit, reachable
    /// when `chrome.top_pct` pins the device above the natural band stack-up
    /// so the wordmark's ink is taller than the space left for it. The layout
    /// must warn and fall back to band-centering rather than place the
    /// wordmark at a negative gap.
    func testEqualSpacing_captionlessHero_warnsAndFallsBackWhenTooTall() async throws {
        let (ink, warnings) = try await renderSlide(
            equalSpacing: true, title: nil, chromeTopPct: 5
        )

        let equalSpacingWarnings = warnings.filter { $0.contains("caption.equal_spacing") }
        XCTAssertEqual(equalSpacingWarnings.count, 1,
            "expected one equal_spacing warning; got \(warnings)")
        let warning = equalSpacingWarnings.first ?? ""
        XCTAssertTrue(warning.contains("not enough room"), warning)
        XCTAssertTrue(warning.contains("falling back to default placement"), warning)
        XCTAssertFalse(warning.contains("caption ink"),
            "a caption-less slide must not report a caption term it does not have: \(warning)")

        // Fallback means the default band centering, exactly as if
        // equal_spacing had been off.
        let bandH = Double(canvasH) * (logoMaxHeightPct + logoTopPaddingPct) / 100.0
        let boxH = Double(canvasH) * logoMaxHeightPct / 100.0
        let expectedTop = Int(((bandH - boxH) / 2.0).rounded())
        XCTAssertEqual(ink.logoTop, expectedTop, accuracy: 3,
            "fallback must band-center the wordmark: expected top \(expectedTop), got \(ink.logoTop)")
    }

    /// A caption-less slide whose `below_subtitle` slot is occupied cannot use
    /// the two-gap rule. That rule hands everything between the logo and the
    /// device to the two gaps, but the lower overlay is drawn into exactly
    /// that space and drawn AFTER the logo, so an equal-spacing logo would be
    /// laid across it and an opaque overlay would paint the wordmark out
    /// entirely. The layout must decline, warn, and keep band centering.
    func testEqualSpacing_captionlessHero_declinesWhenLowerOverlayOccupied() async throws {
        let (ink, warnings) = try await renderSlide(
            equalSpacing: true, title: nil, belowSubtitleImage: true
        )

        let equalSpacingWarnings = warnings.filter { $0.contains("caption.equal_spacing") }
        XCTAssertEqual(equalSpacingWarnings.count, 1,
            "expected one equal_spacing warning; got \(warnings)")
        let warning = equalSpacingWarnings.first ?? ""
        XCTAssertTrue(warning.contains("skipped"), warning)
        XCTAssertTrue(warning.contains("below_subtitle"), warning)

        // Declining means the default band centering, exactly as if
        // equal_spacing had been off.
        let bandH = Double(canvasH) * (logoMaxHeightPct + logoTopPaddingPct) / 100.0
        let boxH = Double(canvasH) * logoMaxHeightPct / 100.0
        let expectedTop = Int(((bandH - boxH) / 2.0).rounded())
        XCTAssertEqual(ink.logoTop, expectedTop, accuracy: 3,
            "declining must band-center the wordmark: expected top \(expectedTop), got \(ink.logoTop)")
        XCTAssertLessThan(ink.logoBottom, Int(bandH),
            "the wordmark must stay inside its own band, clear of the below_subtitle overlay: bottom row \(ink.logoBottom) against a band ending at \(Int(bandH))")
    }

    // MARK: - top_padding_pct through the legacy logo block

    /// `logo.top_padding_pct` reaches the placer through the above_title image
    /// the resolver synthesizes from the legacy `logo:` block, so raising it
    /// grows the reserved band and pushes the device down. Before the fix the
    /// field was dropped during that conversion and the device did not move at
    /// all, which is how a hero slide ended up with its device far higher than
    /// every caption slide in the same set.
    ///
    /// The band grows by `top_padding_pct`% of canvas height; the device top
    /// moves by slightly less because the chrome inset is a percentage of the
    /// shrinking space left below the band.
    func testLogoTopPaddingPct_pushesDeviceDown() async throws {
        let (withoutPadding, _) = try await renderSlide(
            equalSpacing: false, title: nil,
            logoTopPaddingPct: 0, useLegacyLogoBlock: true
        )
        let (withPadding, _) = try await renderSlide(
            equalSpacing: false, title: nil,
            logoTopPaddingPct: logoTopPaddingPct, useLegacyLogoBlock: true
        )

        let bandGrowth = Double(canvasH) * logoTopPaddingPct / 100.0
        let expectedShift = Int((bandGrowth * (1.0 - chromePaddingPct / 100.0)).rounded())
        let actualShift = withPadding.deviceTop - withoutPadding.deviceTop
        XCTAssertEqual(actualShift, expectedShift, accuracy: 3,
            "logo.top_padding_pct \(logoTopPaddingPct)% must push the device down ~\(expectedShift)px; device top went from \(withoutPadding.deviceTop) to \(withPadding.deviceTop) (\(actualShift)px)")
    }

    // MARK: - Harness

    /// The rows the layout rule is about, measured from the image's top edge.
    private struct SlideInk {
        let logoTop: Int
        let logoBottom: Int
        let captionTop: Int?
        let captionBottom: Int?
        let deviceTop: Int
    }

    /// Renders a single slide and returns its measured ink rows alongside the
    /// render's warnings, so a test can assert on the fallback message.
    ///
    /// `useLegacyLogoBlock` picks how the wordmark reaches the renderer: as an
    /// explicit `images:` entry, or through the pre-2.4 `logo:` block that
    /// `RenderResolver.resolvedImages` converts into an above_title image.
    /// `title` nil leaves the slide caption-less while the shared `caption:`
    /// block (and its `equal_spacing`) still applies, which is the hero case.
    private func renderSlide(
        equalSpacing: Bool,
        title: String?,
        logoTopPaddingPct: Double? = nil,
        chromeTopPct: Double? = nil,
        useLegacyLogoBlock: Bool = false,
        belowSubtitleImage: Bool = false
    ) async throws -> (ink: SlideInk, warnings: [String]) {
        let topPaddingPct = logoTopPaddingPct ?? self.logoTopPaddingPct

        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("equal-spacing-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }
        let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

        // Green "screen" so the device's top edge is findable by color, and a
        // magenta wordmark so it never collides with the white caption text.
        let filename = "iPhone_6.9_01_Home.png"
        try writeSolidPNG(width: canvasW, height: canvasH, red: 0, green: 1, blue: 0,
                          to: capturedRoot.appendingPathComponent(filename))
        let logoURL = runRoot.appendingPathComponent("logo.png")
        try writeSolidPNG(width: 64, height: 64, red: 1, green: 0, blue: 1, to: logoURL)

        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "equal-spacing-test",
            appName: "ES", displayName: "ES", scheme: "ES",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: "iPhone 6.9\"", simulatorName: "iPhone 17 Pro Max",
                    locale: "en-US", appearance: nil,
                    screenshots: [CaptureManifest.Screenshot(name: "01_Home", filename: filename, capturedAt: Date())]
                ),
            ]
        )

        let logoBlock: LogoConfig? = useLegacyLogoBlock
            ? LogoConfig(
                path: .shared(logoURL.path),
                placement: .all,
                maxHeightPct: logoMaxHeightPct,
                topPaddingPct: topPaddingPct
              )
            : nil
        // A solid blue overlay for the below_subtitle slot: a color no other
        // measured band uses, and opaque, so a wordmark placed across it would
        // be painted out rather than merely crossed.
        let lowerURL = runRoot.appendingPathComponent("lower.png")
        if belowSubtitleImage {
            try writeSolidPNG(width: 64, height: 64, red: 0, green: 0, blue: 1, to: lowerURL)
        }
        var imageEntries: [ImageConfig] = useLegacyLogoBlock
            ? []
            : [ImageConfig(
                path: .shared(logoURL.path),
                position: .aboveTitle,
                align: .center,
                maxHeightPct: logoMaxHeightPct,
                topPaddingPct: topPaddingPct,
                placement: .all
              )]
        if belowSubtitleImage {
            imageEntries.append(ImageConfig(
                path: .shared(lowerURL.path),
                position: .belowSubtitle,
                align: .center,
                maxHeightPct: logoMaxHeightPct,
                placement: .all
            ))
        }
        let imageBlock: [ImageConfig]? = imageEntries.isEmpty ? nil : imageEntries

        let config = RenderConfig(
            enabled: true,
            background: BackgroundConfig(color: .solid("#000000")),
            logo: logoBlock,
            images: imageBlock,
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .system, weight: .bold,
                    fontSizePct: 5.5, color: "#FFFFFF", align: .center
                ),
                minHeightPct: 22, paddingPct: 4,
                verticalAlign: .center,
                equalSpacing: equalSpacing
            ),
            // `fit: height` makes the screenshot fill the padded chrome rect
            // exactly, so its top row is the device anchor the layout used.
            chrome: ChromeConfig(
                style: ChromeStyle.none, cornerRadius: .auto, shadow: false,
                paddingPct: chromePaddingPct, fit: .height, topPct: chromeTopPct
            ),
            slides: title.map { ["01_Home": SlideOverride(caption: SlideCaption(title: .string($0)))] }
        )

        let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
        let out = try await pipeline.render(manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot)
        XCTAssertEqual(out.failures.count, 0, "render failed: \(out.failures)")

        let ink = try measureInk(at: renderRoot.appendingPathComponent(filename))
        return (ink, out.warnings)
    }

    /// One top-down pass over the rows, classifying each sampled pixel as
    /// wordmark (magenta), caption text (white) or device (green).
    private func measureInk(at url: URL) throws -> SlideInk {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = img.dataProvider?.data as Data? else {
            throw NSError(domain: "EqualSpacingPlacementTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not read \(url.path)"])
        }
        let bpp = 4
        // Sample the middle half of each row: the wordmark, the centered
        // caption and the device all cross it, and the row-by-row cost stays
        // small on a 1434-row canvas.
        let xStart = img.width / 4
        let xEnd = 3 * img.width / 4
        let xStep = max(1, (xEnd - xStart) / 80)

        var logoTop = -1, logoBottom = -1
        var captionTop = -1, captionBottom = -1
        var deviceTop = -1
        for y in 0..<img.height {
            var hasMagenta = false, hasWhite = false, hasGreen = false
            for x in stride(from: xStart, through: xEnd, by: xStep) {
                let off = y * img.bytesPerRow + x * bpp
                let r = Int(data[off]), g = Int(data[off + 1]), b = Int(data[off + 2])
                if r > 200 && g < 80 && b > 200 {
                    hasMagenta = true
                } else if r > 220 && g > 220 && b > 220 {
                    hasWhite = true
                } else if r < 80 && g > 200 && b < 80 {
                    hasGreen = true
                }
            }
            if hasMagenta {
                if logoTop < 0 { logoTop = y }
                logoBottom = y
            }
            if hasWhite {
                if captionTop < 0 { captionTop = y }
                captionBottom = y
            }
            if hasGreen && deviceTop < 0 { deviceTop = y }
        }

        guard logoTop >= 0 else {
            throw NSError(domain: "EqualSpacingPlacementTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no wordmark (magenta) pixels found in \(url.path)"])
        }
        guard deviceTop >= 0 else {
            throw NSError(domain: "EqualSpacingPlacementTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "no device (green) pixels found in \(url.path)"])
        }
        return SlideInk(
            logoTop: logoTop,
            logoBottom: logoBottom,
            captionTop: captionTop >= 0 ? captionTop : nil,
            captionBottom: captionBottom >= 0 ? captionBottom : nil,
            deviceTop: deviceTop
        )
    }

    private func writeSolidPNG(
        width: Int, height: Int,
        red: CGFloat, green: CGFloat, blue: CGFloat,
        to url: URL
    ) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "EqualSpacingPlacementTests", code: 4) }
        ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "EqualSpacingPlacementTests", code: 5) }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "EqualSpacingPlacementTests", code: 6)
        }
    }
}
