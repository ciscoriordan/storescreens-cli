import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import StorescreensCore

final class SearchPreviewTests: XCTestCase {

    // MARK: - Helpers

    private func makeTmp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-preview-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a small solid-color PNG at `url` so the renderer has something
    /// real to load. We don't need any specific dimensions — the renderer
    /// aspect-fills into its tiles regardless of input size.
    private func writeSolidPNG(_ url: URL, color: NSColor, size: CGSize) throws {
        let width = Int(size.width)
        let height = Int(size.height)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "SearchPreviewTests", code: 1)
        }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let img = ctx.makeImage() else {
            throw NSError(domain: "SearchPreviewTests", code: 2)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "SearchPreviewTests", code: 3)
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "SearchPreviewTests", code: 4)
        }
    }

    private func writeText(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Resolver

    func testResolver_pullsNameAndSubtitleFromMetadataFiles() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let metadataDir = tmp.appendingPathComponent("metadata")
        try writeText(metadataDir.appendingPathComponent("en-US/name.txt"), "My Test App")
        try writeText(metadataDir.appendingPathComponent("en-US/subtitle.txt"), "A nifty tagline")

        let capturedRoot = tmp.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)
        try writeSolidPNG(
            capturedRoot.appendingPathComponent("AppIcon.png"),
            color: .systemRed, size: CGSize(width: 256, height: 256)
        )

        var config = CaptureConfig(
            scheme: "FallbackScheme",
            devices: [],
            outputDir: capturedRoot.path
        )
        config.locales = ["en-US"]
        config.appStoreConnect = AppStoreConnectConfig(metadataDir: metadataDir.path)
        config.searchPreview = SearchPreviewConfig(
            enabled: true,
            outputDir: tmp.appendingPathComponent("preview").path
        )

        let resolved = SearchPreviewResolver().resolve(
            captureConfig: config,
            manifest: nil,
            capturedRoot: capturedRoot,
            renderedRoot: nil,
            baseDirectory: tmp
        )
        XCTAssertEqual(resolved.inputs.count, 1)
        let input = resolved.inputs.first!
        XCTAssertEqual(input.locale, "en-US")
        XCTAssertEqual(input.appearance, "light")
        XCTAssertEqual(input.name, "My Test App")
        XCTAssertEqual(input.subtitle, "A nifty tagline")
        XCTAssertEqual(input.iconPath?.lastPathComponent, "AppIcon.png")
        XCTAssertEqual(input.searchTerm, "my test app")
    }

    func testResolver_explicitOverrides_winOverMetadata() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let metadataDir = tmp.appendingPathComponent("metadata")
        try writeText(metadataDir.appendingPathComponent("en-US/name.txt"), "Metadata Name")
        try writeText(metadataDir.appendingPathComponent("en-US/subtitle.txt"), "Metadata Subtitle")

        var config = CaptureConfig(scheme: "X", devices: [], outputDir: tmp.path)
        config.locales = ["en-US"]
        config.appStoreConnect = AppStoreConnectConfig(metadataDir: metadataDir.path)
        config.searchPreview = SearchPreviewConfig(
            enabled: true,
            name: "Explicit Name",
            subtitle: "Explicit Subtitle",
            developer: "Test Studio",
            rating: 4.5,
            reviews: "327"
        )

        let resolved = SearchPreviewResolver().resolve(
            captureConfig: config,
            manifest: nil,
            capturedRoot: tmp,
            renderedRoot: nil,
            baseDirectory: tmp
        )
        let input = resolved.inputs.first!
        XCTAssertEqual(input.name, "Explicit Name")
        XCTAssertEqual(input.subtitle, "Explicit Subtitle")
        XCTAssertEqual(input.developer, "Test Studio")
        XCTAssertEqual(input.rating, 4.5)
        XCTAssertEqual(input.reviews, "327")
    }

    func testResolver_categories_fromAppStoreConnectConfig() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        var config = CaptureConfig(scheme: "X", devices: [], outputDir: tmp.path)
        config.appStoreConnect = AppStoreConnectConfig(
            categories: CategoriesConfig(primary: "HEALTH_AND_FITNESS", secondary: "FOOD_AND_DRINK")
        )
        config.searchPreview = SearchPreviewConfig(enabled: true)

        let resolved = SearchPreviewResolver().resolve(
            captureConfig: config,
            manifest: nil,
            capturedRoot: tmp,
            renderedRoot: nil,
            baseDirectory: tmp
        )
        XCTAssertEqual(resolved.inputs.first?.categories, ["Health & Fitness", "Food & Drink"])
    }

    func testResolver_appearances_iteratesLightAndDark() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        var config = CaptureConfig(scheme: "X", devices: [], outputDir: tmp.path)
        config.searchPreview = SearchPreviewConfig(
            enabled: true,
            appearances: ["light", "dark"]
        )

        let resolved = SearchPreviewResolver().resolve(
            captureConfig: config,
            manifest: nil,
            capturedRoot: tmp,
            renderedRoot: nil,
            baseDirectory: tmp
        )
        XCTAssertEqual(resolved.inputs.count, 2)
        XCTAssertEqual(resolved.inputs.map { $0.appearance }, ["light", "dark"])
    }

    func testFriendlyCategory_knownAndFallback() {
        XCTAssertEqual(SearchPreviewResolver.friendlyCategory("HEALTH_AND_FITNESS"), "Health & Fitness")
        XCTAssertEqual(SearchPreviewResolver.friendlyCategory("PHOTO_AND_VIDEO"), "Photo & Video")
        XCTAssertEqual(SearchPreviewResolver.friendlyCategory("EDUCATION"), "Education")
        // Unknown id falls through to generic title-case + underscore→space rewrite.
        XCTAssertEqual(SearchPreviewResolver.friendlyCategory("FUTURE_NEW_CATEGORY"), "Future New Category")
    }

    func testDefaultSearchTerm_truncatesAndLowercases() {
        XCTAssertEqual(
            SearchPreviewResolver.defaultSearchTerm(from: "My Super Cool App For All Of Us"),
            "my super cool app fo"
        )
        XCTAssertEqual(SearchPreviewResolver.defaultSearchTerm(from: "Short"), "short")
    }

    // MARK: - Renderer

    func testRenderer_writesPNG_atExpectedDimensions() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let iconURL = tmp.appendingPathComponent("AppIcon.png")
        try writeSolidPNG(iconURL, color: .systemBlue, size: CGSize(width: 256, height: 256))

        let shotURL = tmp.appendingPathComponent("hero.png")
        try writeSolidPNG(shotURL, color: .systemGreen, size: CGSize(width: 540, height: 1170))

        let outputURL = tmp.appendingPathComponent("preview.png")
        let input = SearchPreviewInput(
            locale: "en-US",
            appearance: "light",
            name: "Test App",
            subtitle: "A great tagline",
            developer: "Acme Co",
            rating: 4.8,
            reviews: "1.2K",
            categories: ["Health & Fitness", "Food & Drink"],
            iconPath: iconURL,
            screenshotPaths: [shotURL, shotURL, shotURL],
            action: .get,
            priceLabel: nil,
            searchTerm: "test app",
            bezel: .iphone,
            outputURL: outputURL
        )

        let warnings = try SearchPreviewRenderer().render([input])
        XCTAssertTrue(warnings.isEmpty, "renderer warnings: \(warnings)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attrs[.size] as? UInt64 ?? 0
        XCTAssertGreaterThan(size, 1024, "PNG output should be more than a kilobyte")

        // Verify dimensions match the configured canvas size.
        guard let src = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return XCTFail("could not read PNG metadata")
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int
        let height = props[kCGImagePropertyPixelHeight] as? Int
        XCTAssertEqual(width, Int(SearchPreviewRenderer.canvasWidth))
        XCTAssertEqual(height, Int(SearchPreviewRenderer.canvasHeight))
    }

    func testRenderer_darkModeWritesDistinctPNG() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let iconURL = tmp.appendingPathComponent("AppIcon.png")
        try writeSolidPNG(iconURL, color: .systemPurple, size: CGSize(width: 128, height: 128))

        let baseInput: (String, URL) -> SearchPreviewInput = { appearance, outputURL in
            SearchPreviewInput(
                locale: nil,
                appearance: appearance,
                name: "App",
                subtitle: "Sub",
                developer: "",
                rating: 5,
                reviews: "42",
                categories: ["Utilities"],
                iconPath: iconURL,
                screenshotPaths: [],
                action: .open,
                priceLabel: nil,
                searchTerm: "app",
                bezel: .iphone,
                outputURL: outputURL
            )
        }

        let lightURL = tmp.appendingPathComponent("light.png")
        let darkURL = tmp.appendingPathComponent("dark.png")
        _ = try SearchPreviewRenderer().render([
            baseInput("light", lightURL),
            baseInput("dark", darkURL),
        ])

        let lightSize = (try FileManager.default.attributesOfItem(atPath: lightURL.path)[.size] as? UInt64) ?? 0
        let darkSize  = (try FileManager.default.attributesOfItem(atPath: darkURL.path)[.size]  as? UInt64) ?? 0
        XCTAssertGreaterThan(lightSize, 1024)
        XCTAssertGreaterThan(darkSize, 1024)
        // Light/dark themes have different background fills, so the PNGs
        // must differ at least byte-wise. (This is a very loose sanity
        // check, not a pixel-perfect comparison.)
        let lightData = try Data(contentsOf: lightURL)
        let darkData = try Data(contentsOf: darkURL)
        XCTAssertNotEqual(lightData, darkData)
    }

    // MARK: - Runner integration

    func testRunner_endToEnd_writesPNGsForEachLocaleAppearance() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let metadataDir = tmp.appendingPathComponent("metadata")
        try writeText(metadataDir.appendingPathComponent("en-US/name.txt"), "English Name")
        try writeText(metadataDir.appendingPathComponent("en-US/subtitle.txt"), "English Subtitle")
        try writeText(metadataDir.appendingPathComponent("ja/name.txt"), "日本語アプリ")
        try writeText(metadataDir.appendingPathComponent("ja/subtitle.txt"), "サブタイトル")

        let capturedRoot = tmp.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)
        try writeSolidPNG(
            capturedRoot.appendingPathComponent("AppIcon.png"),
            color: .systemOrange, size: CGSize(width: 512, height: 512)
        )

        let outputDir = tmp.appendingPathComponent("preview")
        var config = CaptureConfig(scheme: "X", devices: [], outputDir: capturedRoot.path)
        config.locales = ["en-US", "ja"]
        config.appStoreConnect = AppStoreConnectConfig(metadataDir: metadataDir.path)
        config.searchPreview = SearchPreviewConfig(
            enabled: true,
            outputDir: outputDir.path,
            appearances: ["light", "dark"]
        )

        let result = SearchPreviewRunner().run(
            captureConfig: config,
            manifest: nil,
            capturedRoot: capturedRoot,
            renderedRoot: nil,
            baseDirectory: tmp
        )
        // 2 locales × 2 appearances = 4 PNGs
        XCTAssertEqual(result.renderedCount, 4)
        for url in result.outputs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
