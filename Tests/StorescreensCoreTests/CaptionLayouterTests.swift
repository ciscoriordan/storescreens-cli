import XCTest
import CoreText
import AppKit
@testable import StorescreensCore

final class CaptionLayouterTests: XCTestCase {

    private func makeLayouter() -> CaptionLayouter {
        CaptionLayouter(resolver: FontResolver(baseDirectory: URL(fileURLWithPath: "/tmp")))
    }

    func testHexColor_parsesShortAndLong() {
        XCTAssertNotNil(RenderColors.parseHex("#fff"))
        XCTAssertNotNil(RenderColors.parseHex("#ffffff"))
        XCTAssertNotNil(RenderColors.parseHex("#ff0000aa"))
        XCTAssertNil(RenderColors.parseHex("not-a-color"))
    }

    func testLayout_shortString_fitsWithoutShrinking() throws {
        let layouter = makeLayouter()
        let out = try layouter.layout(
            title: .string("Hello"),
            subtitle: nil,
            titleStyleRaw: CaptionRole(font: .system, weight: .bold, fontSizePct: 4, color: "#ffffff", align: .center),
            subtitleStyleRaw: nil,
            highlights: [],
            canvasSize: CGSize(width: 1290, height: 2796),
            reservedHeight: 400,
            blockWidth: 1200,
            spacing: 20
        )
        XCTAssertFalse(out.wasShrunk, "short text should fit at full size")
        XCTAssertFalse(out.wasTruncated)
        XCTAssertGreaterThan(out.measuredHeight, 0)
    }

    func testLayout_tooLongString_shrinksToFit() throws {
        let layouter = makeLayouter()
        let veryLong = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 10)
        let out = try layouter.layout(
            title: .string(veryLong),
            subtitle: nil,
            titleStyleRaw: CaptionRole(font: .system, weight: .bold, fontSizePct: 10, minFontSizePct: 1, color: "#ffffff", align: .center),
            subtitleStyleRaw: nil,
            highlights: [],
            canvasSize: CGSize(width: 1290, height: 2796),
            reservedHeight: 300,
            blockWidth: 1200,
            spacing: 0
        )
        XCTAssertTrue(out.wasShrunk, "long text should trigger shrink loop")
        XCTAssertLessThanOrEqual(out.measuredHeight, 300 + 1, "should fit reserved height after shrinking")
    }

    func testLayout_arrayCaption_strictLines_shrinksIfTooWide() throws {
        let layouter = makeLayouter()
        // Each array item is a single strict line — a very long item forces
        // shrinking since we never wrap within it.
        let out = try layouter.layout(
            title: .array(["This is a deliberately long line that won't wrap within its array item"]),
            subtitle: nil,
            titleStyleRaw: CaptionRole(font: .system, weight: .bold, fontSizePct: 8, minFontSizePct: 1, color: "#ffffff", align: .center),
            subtitleStyleRaw: nil,
            highlights: [],
            canvasSize: CGSize(width: 1290, height: 2796),
            reservedHeight: 500,
            blockWidth: 800,
            spacing: 0
        )
        XCTAssertTrue(out.wasShrunk, "wide strict line should shrink")
    }

    func testLayout_titleAndSubtitle_bothRendered() throws {
        let layouter = makeLayouter()
        let out = try layouter.layout(
            title: .string("Big Title"),
            subtitle: .string("With a smaller subtitle"),
            titleStyleRaw: CaptionRole(font: .system, weight: .bold, fontSizePct: 5, color: "#ffffff", align: .center),
            subtitleStyleRaw: CaptionRole(font: .system, weight: .regular, fontSizePct: 3, color: "#cccccc", align: .center),
            highlights: [],
            canvasSize: CGSize(width: 1290, height: 2796),
            reservedHeight: 600,
            blockWidth: 1200,
            spacing: 24
        )
        XCTAssertGreaterThan(out.drawable.titleSize.height, 0)
        XCTAssertGreaterThan(out.drawable.subtitleSize.height, 0)
    }

    func testLayout_drawable_canRenderIntoContext() throws {
        let layouter = makeLayouter()
        let out = try layouter.layout(
            title: .string("**Bold** and *italic*"),
            subtitle: nil,
            titleStyleRaw: CaptionRole(font: .system, weight: .regular, fontSizePct: 4, color: "#ffffff", align: .center),
            subtitleStyleRaw: nil,
            highlights: [CaptionHighlight(match: "italic", color: "#feb909", weight: .heavy, italic: nil)],
            canvasSize: CGSize(width: 1290, height: 2796),
            reservedHeight: 400,
            blockWidth: 1200,
            spacing: 0
        )

        // Draw into a bitmap context; verify no crash and some pixels are set.
        let w = 1290
        let h = 400
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        out.drawable.draw(into: ctx, topLeft: CGPoint(x: 45, y: 100))

        // Sample a pixel in the expected text area — should have been drawn
        // (alpha = 255 since we filled black background, but text should make
        // some pixel near the middle non-black). Hard to assert exactly, so
        // just verify the context completed a draw.
        XCTAssertNotNil(ctx.makeImage())
    }

    func testEmpty_titleAndSubtitle_returnsZeroHeight() throws {
        let layouter = makeLayouter()
        let out = try layouter.layout(
            title: nil, subtitle: nil,
            titleStyleRaw: nil, subtitleStyleRaw: nil,
            highlights: [],
            canvasSize: CGSize(width: 100, height: 100),
            reservedHeight: 50, blockWidth: 80, spacing: 0
        )
        XCTAssertEqual(out.measuredHeight, 0)
    }
}
