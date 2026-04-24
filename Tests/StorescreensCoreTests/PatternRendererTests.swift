import XCTest
import CoreGraphics
import AppKit
@testable import StorescreensCore

/// Unit tests for `PatternRenderer`. Each pattern is exercised at least once —
/// the built-in templates cover topographic/gamified/dune/blueprint, but
/// `soft_waves` has no template user, so without these tests its codepath
/// would be unreached.
final class PatternRendererTests: XCTestCase {

    // MARK: - All patterns draw something

    func testEveryPattern_modifiesPixels() throws {
        // Render each pattern on top of a known base color, then sample a few
        // points to confirm at least one pixel in the canvas is different
        // from the base. This is a smoke test: patterns must actually draw.
        let base = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let accent = "#FF0000"
        let size = CGSize(width: 400, height: 800)

        for pattern in BackgroundPattern.allCases {
            let ctx = makeContext(size: size)
            ctx.setFillColor(base.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))

            PatternRenderer().draw(
                PatternConfig(pattern: pattern, color: accent, opacity: 0.6),
                into: ctx,
                canvasSize: size
            )

            guard let image = ctx.makeImage() else {
                XCTFail("[\(pattern.rawValue)] makeImage failed")
                continue
            }

            // Sample a grid of points and look for any pixel whose red
            // channel is notably above the gray base — the accent is pure red.
            let samples = pixelGrid(image: image, samplesPerAxis: 12)
            let maxRed = samples.map(\.r).max() ?? 0
            XCTAssertGreaterThan(maxRed, 160,
                "[\(pattern.rawValue)] expected at least one red-shifted pixel above 160, saw max \(maxRed)")
        }
    }

    // MARK: - Soft waves specifically

    /// Soft waves has no template user; without this test the codepath is
    /// dead code. Render explicitly and assert band-shape coverage: there
    /// should be horizontal bands of accent pixels separated by base-color gaps.
    func testSoftWaves_drawsMultipleBands() throws {
        let size = CGSize(width: 400, height: 800)
        let ctx = makeContext(size: size)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        PatternRenderer().draw(
            PatternConfig(pattern: .softWaves, color: "#000000", opacity: 1.0),
            into: ctx,
            canvasSize: size
        )

        let image = try XCTUnwrap(ctx.makeImage())
        // Scan a single column down the middle, count transitions from
        // "mostly white" → "dark" → "mostly white". Should be ≥ 3 bands
        // (soft_waves draws 9 bands).
        let column = 200
        let bytesPerPixel = 4
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        var transitions = 0
        var inBand = false
        for y in 0..<image.height {
            let offset = (y * image.bytesPerRow) + (column * bytesPerPixel)
            let r = data[offset]
            let g = data[offset + 1]
            let b = data[offset + 2]
            let isDark = r < 200 && g < 200 && b < 200
            if isDark && !inBand {
                transitions += 1
                inBand = true
            } else if !isDark {
                inBand = false
            }
        }
        XCTAssertGreaterThanOrEqual(transitions, 3,
            "expected at least 3 soft-wave bands in middle column, found \(transitions)")
    }

    // MARK: - Panorama slicing

    /// When a pattern is drawn with slidesInCombo > 1, rendering the same
    /// slideIndex twice must produce identical output — determinism is required
    /// for reproducible App Store renders.
    func testPatternIsDeterministicAcrossRuns() throws {
        let size = CGSize(width: 300, height: 600)
        func render() throws -> CGImage {
            let ctx = makeContext(size: size)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            PatternRenderer().draw(
                PatternConfig(pattern: .gamifiedShapes, color: "#00AAFF", opacity: 0.5),
                into: ctx,
                canvasSize: size,
                slideIndex: 1,
                slidesInCombo: 3
            )
            return try XCTUnwrap(ctx.makeImage())
        }
        let a = try render()
        let b = try render()
        XCTAssertEqual(pixelHash(a), pixelHash(b),
            "same (pattern, slideIndex, slidesInCombo) must produce identical pixels")
    }

    // MARK: - Helpers

    private func makeContext(size: CGSize) -> CGContext {
        let cs = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    private struct Pixel { let r: UInt8; let g: UInt8; let b: UInt8 }

    private func pixelGrid(image: CGImage, samplesPerAxis: Int) -> [Pixel] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        var out: [Pixel] = []
        for iy in 0..<samplesPerAxis {
            for ix in 0..<samplesPerAxis {
                let x = image.width * ix / samplesPerAxis
                let y = image.height * iy / samplesPerAxis
                let off = y * image.bytesPerRow + x * 4
                out.append(Pixel(r: data[off], g: data[off + 1], b: data[off + 2]))
            }
        }
        return out
    }

    private func pixelHash(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        // FNV-1a on the raw pixel buffer; cheap and good enough for equality.
        var h: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            h ^= UInt64(byte)
            h &*= 1_099_511_628_211
        }
        return Int(truncatingIfNeeded: h)
    }
}
