import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
@testable import StorescreensCore

/// Template-system tests: lookup, merge semantics, and end-to-end render.
///
/// The end-to-end test produces one sample PNG per built-in template under
/// `/tmp/storescreens-render-fixture/templates/<template>/` so you can `open`
/// them to eyeball the visual output.
final class RenderTemplateTests: XCTestCase {

    private let fixtureRoot = URL(fileURLWithPath: "/tmp/storescreens-render-fixture", isDirectory: true)

    // MARK: - Lookup

    func testFind_byId_caseInsensitive() {
        XCTAssertEqual(RenderTemplate.find("ascent")?.id, "ascent")
        XCTAssertEqual(RenderTemplate.find("ASCENT")?.id, "ascent")
        XCTAssertEqual(RenderTemplate.find("Ascent")?.id, "ascent")
    }

    func testFind_ignoresSeparators() {
        // `sunset_blvd` / `sunsetblvd` / `sunset-blvd` all resolve the same.
        XCTAssertEqual(RenderTemplate.find("sunset_blvd")?.id, "sunset_blvd")
        XCTAssertEqual(RenderTemplate.find("sunsetblvd")?.id, "sunset_blvd")
        XCTAssertEqual(RenderTemplate.find("sunset-blvd")?.id, "sunset_blvd")
        XCTAssertEqual(RenderTemplate.find("Sunset Blvd")?.id, "sunset_blvd")
    }

    func testFind_unknownReturnsNil() {
        XCTAssertNil(RenderTemplate.find(""))
        XCTAssertNil(RenderTemplate.find("definitely-not-a-template"))
    }

    // MARK: - Apply / merge semantics

    func testApplyTemplate_seedsDefaultsWhenUserConfigIsEmpty() {
        let config = RenderConfig(enabled: true, template: "ascent")
        let applied = RenderResolver.applyTemplate(config)

        XCTAssertNotNil(applied.background, "template must seed background")
        XCTAssertNotNil(applied.caption, "template must seed caption")
        XCTAssertNotNil(applied.chrome, "template must seed chrome")
        // Template-specific check: Ascent sets a topographic pattern
        XCTAssertEqual(applied.background?.pattern?.pattern, .topographic)
    }

    func testApplyTemplate_userFieldsWinOverTemplate() {
        // User overrides the background color; template-supplied caption + pattern survive.
        let userConfig = RenderConfig(
            enabled: true,
            template: "sahara",
            background: BackgroundConfig(color: .solid("#FFFFFF"))
        )
        let applied = RenderResolver.applyTemplate(userConfig)
        XCTAssertEqual(applied.background?.color?.value(for: "light")?.hexes, ["#FFFFFF"],
                       "user color must override template gradient")
        XCTAssertEqual(applied.background?.pattern?.pattern, .duneLayers,
                       "template pattern survives when user didn't set one")
        XCTAssertNotNil(applied.caption, "template caption still applied")
    }

    func testApplyTemplate_unknownTemplateLeavesConfigUnchanged() {
        let config = RenderConfig(enabled: true, template: "does-not-exist")
        let applied = RenderResolver.applyTemplate(config)
        XCTAssertNil(applied.background)
        XCTAssertNil(applied.caption)
        XCTAssertNil(applied.chrome)
    }

    func testApplyTemplate_nilTemplateIsNoOp() {
        let config = RenderConfig(enabled: true)
        let applied = RenderResolver.applyTemplate(config)
        XCTAssertNil(applied.background)
        XCTAssertNil(applied.template)
    }

    // MARK: - End-to-end render per template

    /// Renders one iPhone 6.9" screenshot through each built-in template and
    /// verifies the framed PNG exists with the expected pixel dimensions.
    /// The outputs are kept on disk for visual inspection.
    ///
    /// Uses `chrome.style = .stroke` per-template so we don't require a
    /// bezel install on the test host; template-specific chrome preferences
    /// (colorway etc.) are irrelevant to stroke rendering but the rest of
    /// the template (background pattern, caption font, colors) is real.
    func testEndToEnd_everyTemplate_rendersSuccessfully() async throws {
        let width = 1320, height = 2868   // iPhone 6.9"

        for template in RenderTemplate.builtIn {
            let runRoot = fixtureRoot
                .appendingPathComponent("templates", isDirectory: true)
                .appendingPathComponent(template.id, isDirectory: true)
            try? FileManager.default.removeItem(at: runRoot)
            try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)

            let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
            try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

            // Single synthetic screenshot
            let filename = "iPhone_6.9_01_Home.png"
            let sourceURL = capturedRoot.appendingPathComponent(filename)
            try writeSyntheticPNG(width: width, height: height, label: template.name, to: sourceURL)

            let manifest = CaptureManifest(
                version: 1,
                generatedAt: Date(),
                generatedBy: "template-test",
                appName: "Template",
                displayName: "Template",
                scheme: "Template",
                devices: [
                    CaptureManifest.DeviceCapture(
                        deviceType: "iPhone 6.9\"",
                        simulatorName: "iPhone 17 Pro Max",
                        locale: "en-US",
                        appearance: nil,
                        screenshots: [CaptureManifest.Screenshot(name: "01_Home", filename: filename, capturedAt: Date())]
                    ),
                ]
            )

            // Apply template, force stroke chrome so bezels aren't required,
            // add caption text so the template's typography is visible.
            var config = RenderConfig(enabled: true, template: template.id)
            config.chrome = ChromeConfig(
                style: .stroke,
                strokeColor: "#ffffff",
                strokeWidth: 3,
                cornerRadius: .auto,
                shadow: true,
                paddingPct: 5
            )
            config.slides = [
                "01_Home": SlideOverride(
                    caption: SlideCaption(
                        title: .string(template.name),
                        subtitle: .string(template.description)
                    )
                ),
            ]

            let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
            let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
            let out = try await pipeline.render(manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot)

            XCTAssertEqual(out.failures.count, 0,
                           "[\(template.id)] expected no failures; got \(out.failures)")
            XCTAssertEqual(out.renderedSlides, 1, "[\(template.id)] 1 slide expected")

            let outURL = renderRoot.appendingPathComponent(filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                          "[\(template.id)] missing output: \(outURL.path)")

            guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                XCTFail("[\(template.id)] can't read rendered PNG")
                continue
            }
            XCTAssertEqual(img.width, width, "[\(template.id)] width mismatch")
            XCTAssertEqual(img.height, height, "[\(template.id)] height mismatch")

            print("[\(template.id)] -> \(outURL.path)")
        }
    }

    // MARK: - Helpers

    /// Synthetic portrait PNG with a simple gradient + label for visual ID.
    private func writeSyntheticPNG(width: Int, height: Int, label: String, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "RenderTemplateTests", code: 1)
        }
        ctx.setFillColor(NSColor(calibratedHue: 0.58, saturation: 0.35, brightness: 0.25, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Simple centered label so the output is identifiable at a glance.
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: CGFloat(width) * 0.06),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let flipped = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        let textRect = CGRect(x: 0, y: CGFloat(height) * 0.45, width: CGFloat(width), height: CGFloat(height) * 0.1)
        attr.draw(in: textRect)
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw NSError(domain: "RenderTemplateTests", code: 2)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "RenderTemplateTests", code: 3)
        }
    }
}
