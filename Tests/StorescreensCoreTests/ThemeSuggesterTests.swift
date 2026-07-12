import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import StorescreensCore

final class ThemeSuggesterTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-suggester-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Writes a two-color PNG: `background` everywhere except a left band of
    /// `accentFraction` of the width filled with `accent`.
    private func writeImage(
        name: String,
        background: (Int, Int, Int),
        accent: (Int, Int, Int)? = nil,
        accentFraction: CGFloat = 0.2,
        size: Int = 200
    ) throws -> URL {
        let url = workDir.appendingPathComponent("\(name).png")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        func color(_ c: (Int, Int, Int)) -> CGColor {
            CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
        ctx.setFillColor(color(background))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if let accent {
            ctx.setFillColor(color(accent))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(size) * accentFraction, height: CGFloat(size)))
        }
        let img = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func rgb(_ hex: String) -> (Int, Int, Int) {
        let s = hex.dropFirst()
        return (
            Int(s.prefix(2), radix: 16)!,
            Int(s.dropFirst(2).prefix(2), radix: 16)!,
            Int(s.dropFirst(4).prefix(2), radix: 16)!
        )
    }

    func testDarkAppWithVividAccent_yieldsThreeThemes() throws {
        // Dark navy UI with a vivid orange accent band.
        let url = try writeImage(name: "dark", background: (18, 22, 40), accent: (240, 130, 20))
        let themes = try ThemeSuggester.suggest(from: [url])

        XCTAssertEqual(themes.map(\.name), ["App Match", "Brand Gradient", "Soft Tint"])

        // App Match: canvas is the navy nudged toward black, so still dark,
        // with white text and the dark drawn frame. Bounds sit strictly
        // inside the source color (18, 22, 40) so a deleted or reversed
        // nudge fails here; the nudged canvas is (14, 17, 30).
        let appMatch = themes[0]
        XCTAssertEqual(appMatch.background.count, 1)
        XCTAssertEqual(appMatch.textColor, "#ffffff")
        XCTAssertEqual(appMatch.deviceColorway, .dark)
        let canvas = rgb(appMatch.background[0])
        XCTAssertLessThanOrEqual(canvas.0, 16)
        XCTAssertLessThanOrEqual(canvas.2, 34)

        // Brand Gradient: two stops, both orange-dominant (red > blue).
        let gradient = themes[1]
        XCTAssertEqual(gradient.background.count, 2)
        for stop in gradient.background {
            let c = rgb(stop)
            XCTAssertGreaterThan(c.0, c.2, "gradient stop \(stop) should stay warm")
        }
        // Top stop is near the accent, bottom is much darker.
        XCTAssertGreaterThan(rgb(gradient.background[0]).0, rgb(gradient.background[1]).0)

        // Soft Tint: near-white wash, dark text, silver frame.
        let tint = themes[2]
        let tintColor = rgb(tint.background[0])
        XCTAssertGreaterThan(min(tintColor.0, tintColor.1, tintColor.2), 190)
        XCTAssertEqual(tint.textColor, "#111111")
        XCTAssertEqual(tint.deviceColorway, .silver)
    }

    func testLightGrayscaleApp_yieldsOnlyAppMatch() throws {
        // Near-white UI with a mid-gray band: nothing clears the saturation
        // bar, so no accent-derived themes.
        let url = try writeImage(name: "gray", background: (248, 248, 246), accent: (128, 128, 128))
        let themes = try ThemeSuggester.suggest(from: [url])

        XCTAssertEqual(themes.map(\.name), ["App Match"])
        XCTAssertEqual(themes[0].textColor, "#111111")
        XCTAssertEqual(themes[0].deviceColorway, .silver)
        // Canvas nudged toward white from the already-light (248, 248, 246)
        // background: bound sits above the source's min channel so a deleted
        // nudge fails here; the nudged canvas is about (250, 250, 248).
        let canvas = rgb(themes[0].background[0])
        XCTAssertGreaterThanOrEqual(min(canvas.0, canvas.1, canvas.2), 247)
    }

    func testMultipleImages_mergeIntoOneHistogram() throws {
        // Accent lives only in the FIRST image; the combined dominant
        // background comes from the SECOND. Processing only the first image
        // yields a dark App Match; processing only the last loses the accent
        // (fewer themes). Only a true merge passes both assertions. The
        // first image's background is desaturated so the orange band is the
        // sole accent candidate.
        let a = try writeImage(name: "with-accent", background: (32, 34, 38), accent: (240, 130, 20))
        let b = try writeImage(name: "cream", background: (240, 235, 225))
        let themes = try ThemeSuggester.suggest(from: [a, b])

        XCTAssertEqual(themes.map(\.name), ["App Match", "Brand Gradient", "Soft Tint"])
        // Combined counts: the solid cream image outweighs the first image's
        // navy, so App Match must be light.
        XCTAssertEqual(themes[0].textColor, "#111111")
        let canvas = rgb(themes[0].background[0])
        XCTAssertGreaterThan(min(canvas.0, canvas.1, canvas.2), 200)
        // The accent from the first image survives the merge.
        let top = rgb(themes[1].background[0])
        XCTAssertGreaterThan(top.0, top.2, "gradient top \(themes[1].background[0]) should stay warm")
    }

    func testSuggestionsAreDeterministic() throws {
        let a = try writeImage(name: "one", background: (30, 60, 90), accent: (200, 40, 160))
        let b = try writeImage(name: "two", background: (30, 60, 90), accent: (200, 40, 160), accentFraction: 0.3)
        let first = try ThemeSuggester.suggest(from: [a, b])
        let second = try ThemeSuggester.suggest(from: [a, b])
        XCTAssertEqual(first, second)
    }

    func testUnreadableImageThrows() {
        let missing = workDir.appendingPathComponent("nope.png")
        XCTAssertThrowsError(try ThemeSuggester.suggest(from: [missing])) { error in
            guard case ThemeSuggester.SuggestError.unreadableImage = error else {
                return XCTFail("expected unreadableImage, got \(error)")
            }
        }
    }

    func testCapturedScreenshotURLs_picksDeviceWithMostScreenshots() throws {
        // Two devices; the second has more screenshots. Only files that
        // exist on disk are returned.
        let shots = ["a.png", "b.png", "c.png"]
        for name in shots {
            _ = try writeImage(name: String(name.dropLast(4)), background: (10, 10, 10))
        }
        let manifest = CaptureManifest(
            version: 1,
            generatedAt: Date(),
            generatedBy: "test",
            appName: "T", displayName: "T", scheme: "T",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: "iPad 13\"", simulatorName: "iPad", locale: "en-US", appearance: nil,
                    screenshots: [CaptureManifest.Screenshot(name: "a", filename: "a.png", capturedAt: Date())]
                ),
                CaptureManifest.DeviceCapture(
                    deviceType: "iPhone 6.9\"", simulatorName: "iPhone", locale: "en-US", appearance: nil,
                    screenshots: shots.enumerated().map { i, f in
                        CaptureManifest.Screenshot(name: "s\(i)", filename: f, capturedAt: Date())
                    } + [CaptureManifest.Screenshot(name: "gone", filename: "missing.png", capturedAt: Date())]
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: workDir.appendingPathComponent("manifest.json"))

        let urls = try ThemeSuggester.capturedScreenshotURLs(capturedRoot: workDir)
        XCTAssertEqual(urls.map(\.lastPathComponent), shots)
    }

    func testCapturedScreenshotURLs_emptyDevicesReturnsEmpty() throws {
        // Both the CLI and the MCP handler rely on [] (not a throw) to
        // produce their "no screenshots to analyze" error.
        let manifest = CaptureManifest(
            version: 1,
            generatedAt: Date(),
            generatedBy: "test",
            appName: "T", displayName: "T", scheme: "T",
            devices: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: workDir.appendingPathComponent("manifest.json"))

        XCTAssertEqual(try ThemeSuggester.capturedScreenshotURLs(capturedRoot: workDir), [])
    }
}
