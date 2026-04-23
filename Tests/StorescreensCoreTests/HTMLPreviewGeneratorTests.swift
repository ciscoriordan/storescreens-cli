import XCTest
@testable import StorescreensCore

/// Covers the raw/framed toggle the preview gains when `framedDir` is
/// passed in and matching PNGs exist on disk. The legacy raw-only path
/// is also exercised so a capture-without-render run reads identically
/// to before the feature landed.
final class HTMLPreviewGeneratorTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("storescreens-htmlpreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writePlaceholder(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Tiny 1-byte file; FileManager.fileExists only needs presence.
        try Data([0]).write(to: url)
    }

    private func manifest(filename: String) -> CaptureManifest {
        CaptureManifest(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 0),
            generatedBy: "test",
            appName: "MyApp",
            displayName: nil,
            scheme: "MyApp",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: "iPhone 6.9\"",
                    simulatorName: "iPhone 17 Pro Max",
                    locale: "en-US",
                    appearance: "light",
                    screenshots: [
                        CaptureManifest.Screenshot(
                            name: "01_home",
                            filename: filename,
                            capturedAt: Date(timeIntervalSince1970: 0)
                        )
                    ]
                )
            ]
        )
    }

    func testFramedDirNilOmitsToggle() throws {
        let m = manifest(filename: "en-US/iPhone_6.9_01_home.png")
        try writePlaceholder(at: tmp.appendingPathComponent(m.devices[0].screenshots[0].filename))

        try HTMLPreviewGenerator().generate(manifest: m, outputDir: tmp.path)

        let devicePage = try String(
            contentsOf: tmp.appendingPathComponent("preview_iPhone_6.9_light.html"),
            encoding: .utf8
        )
        XCTAssertFalse(devicePage.contains("<div class=\"view-picker\">"),
                       "toggle element should be absent when framedDir is nil")
        XCTAssertFalse(devicePage.contains("class=\"variant-framed\""))
        XCTAssertTrue(devicePage.contains("iPhone_6.9_01_home.png"))
    }

    func testFramedDirWithMatchingFileEmitsToggle() throws {
        // Both raw and framed placeholders live under tmp so test runs
        // are fully isolated (no leak to a shared sibling directory
        // would pollute later tests).
        let filename = "en-US/iPhone_6.9_01_home.png"
        let m = manifest(filename: filename)
        try writePlaceholder(at: tmp.appendingPathComponent(filename))
        try writePlaceholder(at: tmp.appendingPathComponent("framed/\(filename)"))

        try HTMLPreviewGenerator().generate(
            manifest: m,
            outputDir: tmp.path,
            framedDir: "framed"
        )

        let devicePage = try String(
            contentsOf: tmp.appendingPathComponent("preview_iPhone_6.9_light.html"),
            encoding: .utf8
        )
        XCTAssertTrue(devicePage.contains("<div class=\"view-picker\">"))
        XCTAssertTrue(devicePage.contains("class=\"variant-raw\""))
        XCTAssertTrue(devicePage.contains("class=\"variant-framed\""))
        XCTAssertTrue(devicePage.contains("framed/en-US/iPhone_6.9_01_home.png"))
    }

    func testScreenshotOrderReordersGalleryFigures() throws {
        // Two captures with alphabetical manifest order; expect the
        // gallery to emit figures in the config-list order instead.
        let captureAtZero = Date(timeIntervalSince1970: 0)
        let m = CaptureManifest(
            version: 1,
            generatedAt: captureAtZero,
            generatedBy: "test",
            appName: "MyApp",
            displayName: nil,
            scheme: "MyApp",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: "iPhone 6.9\"",
                    simulatorName: "iPhone 17 Pro Max",
                    locale: "en-US",
                    appearance: "light",
                    screenshots: [
                        CaptureManifest.Screenshot(
                            name: "alpha_first",
                            filename: "en-US/iPhone_6.9_alpha_first.png",
                            capturedAt: captureAtZero
                        ),
                        CaptureManifest.Screenshot(
                            name: "hero",
                            filename: "en-US/iPhone_6.9_hero.png",
                            capturedAt: captureAtZero
                        )
                    ]
                )
            ]
        )
        try writePlaceholder(at: tmp.appendingPathComponent("en-US/iPhone_6.9_alpha_first.png"))
        try writePlaceholder(at: tmp.appendingPathComponent("en-US/iPhone_6.9_hero.png"))

        try HTMLPreviewGenerator().generate(
            manifest: m,
            outputDir: tmp.path,
            screenshotOrder: ["hero", "alpha_first"]
        )

        let devicePage = try String(
            contentsOf: tmp.appendingPathComponent("preview_iPhone_6.9_light.html"),
            encoding: .utf8
        )
        let heroRange = devicePage.range(of: "iPhone_6.9_hero.png")
        let alphaRange = devicePage.range(of: "iPhone_6.9_alpha_first.png")
        XCTAssertNotNil(heroRange)
        XCTAssertNotNil(alphaRange)
        // In the gallery order, hero's <img> tag must appear before
        // alpha_first's, even though alpha_first comes first
        // alphabetically.
        XCTAssertLessThan(heroRange!.lowerBound, alphaRange!.lowerBound,
                          "screenshotOrder should place 'hero' ahead of 'alpha_first' in the gallery")
    }

    func testOldPreviewsWipedByDefault() throws {
        // Simulate a prior run having written a preview page for a
        // device/appearance combo that isn't in this manifest.
        let stale = "preview_iPad_13_dark.html"
        let stalePath = tmp.appendingPathComponent(stale)
        try "stale content".write(to: stalePath, atomically: true, encoding: .utf8)

        let m = manifest(filename: "en-US/iPhone_6.9_01_home.png")
        try writePlaceholder(at: tmp.appendingPathComponent(m.devices[0].screenshots[0].filename))

        try HTMLPreviewGenerator().generate(manifest: m, outputDir: tmp.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePath.path),
                       "default keepOldPreviews=false should wipe stale preview files")
        let index = try String(
            contentsOf: tmp.appendingPathComponent("preview.html"),
            encoding: .utf8
        )
        XCTAssertFalse(index.contains("From older runs"),
                       "wiped stale -> no 'From older runs' section on the index")
    }

    func testOldPreviewsKeptWhenOptedIn() throws {
        // Same setup, but now caller asks to keep stale pages.
        let stale = "preview_iPad_13_dark.html"
        let stalePath = tmp.appendingPathComponent(stale)
        try "stale content".write(to: stalePath, atomically: true, encoding: .utf8)

        let m = manifest(filename: "en-US/iPhone_6.9_01_home.png")
        try writePlaceholder(at: tmp.appendingPathComponent(m.devices[0].screenshots[0].filename))

        try HTMLPreviewGenerator().generate(
            manifest: m,
            outputDir: tmp.path,
            keepOldPreviews: true
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: stalePath.path),
                      "keepOldPreviews=true preserves stale preview files")
        let index = try String(
            contentsOf: tmp.appendingPathComponent("preview.html"),
            encoding: .utf8
        )
        XCTAssertTrue(index.contains("From older runs"),
                      "keepOldPreviews=true surfaces a 'From older runs' section")
    }

    func testFramedDirButNoMatchingFileOmitsToggle() throws {
        // framedDir provided, but the render never wrote this slide.
        // Page should degrade gracefully to raw-only (no broken <img>).
        let filename = "en-US/iPhone_6.9_01_home.png"
        let m = manifest(filename: filename)
        try writePlaceholder(at: tmp.appendingPathComponent(filename))
        // Intentionally no tmp/framed/... file.

        try HTMLPreviewGenerator().generate(
            manifest: m,
            outputDir: tmp.path,
            framedDir: "framed"
        )

        let devicePage = try String(
            contentsOf: tmp.appendingPathComponent("preview_iPhone_6.9_light.html"),
            encoding: .utf8
        )
        XCTAssertFalse(devicePage.contains("class=\"variant-framed\""),
                       "no framed PNG on disk -> no framed figure")
        XCTAssertFalse(devicePage.contains("<div class=\"view-picker\">"),
                       "no framed PNG on disk -> no toggle element")
    }
}
