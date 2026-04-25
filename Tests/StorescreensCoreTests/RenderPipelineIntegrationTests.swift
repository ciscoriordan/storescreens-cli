import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
@testable import StorescreensCore

/// End-to-end render test. Fabricates a fixture directory with synthetic
/// screenshots at real App Store pixel dimensions, writes a storescreens.yml
/// exercising every render feature, runs the pipeline, and verifies outputs.
///
/// The fixture is written to a **persistent** location (not a tmp dir that
/// gets cleaned up) so the user can `open` the results in Preview to eyeball
/// them. Location:
///   /tmp/storescreens-render-fixture/
final class RenderPipelineIntegrationTests: XCTestCase {

    private let fixtureRoot = URL(fileURLWithPath: "/tmp/storescreens-render-fixture", isDirectory: true)

    /// Set to true to keep the fixture on disk after the test (default) so
    /// you can inspect it. Set to false locally if you want a clean tmp.
    private let keepOutputForInspection = true

    override func setUpWithError() throws {
        // Each test owns its own subdirectory; clean only that, not the shared root.
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !keepOutputForInspection {
            try? FileManager.default.removeItem(at: fixtureRoot)
        } else {
            print("fixture kept at: \(fixtureRoot.path)")
        }
    }

    /// Per-test fixture subdirectory, wiped fresh each run.
    private func perTestRoot(_ name: String) throws -> URL {
        let url = fixtureRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs the render pipeline against a minimal chrome=stroke configuration
    /// (no bezel download required). Verifies output PNGs exist and have
    /// the expected pixel dimensions.
    func testEndToEnd_strokeChrome_producesOutputs() async throws {
        let devices: [(String, String, Int, Int, Int)] = [
            // (deviceType, simulatorName, width, height, productFamily)
            ("iPhone 6.9\"", "iPhone 17 Pro Max", 1320, 2868, 1),
            ("iPad Pro 13\"", "iPad Pro 13-inch (M5)", 2064, 2752, 2),
            ("Mac 3456x2234", "MacBook Pro 16-inch", 3456, 2234, 6),
        ]

        let runRoot = try perTestRoot("stroke-chrome")
        let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

        // Synthesize one screenshot per device at the right pixel dims.
        var manifestDevices: [CaptureManifest.DeviceCapture] = []
        for (deviceType, simName, w, h, _) in devices {
            let prefix = deviceType
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: " ", with: "_")

            var shots: [CaptureManifest.Screenshot] = []
            for (idx, label) in [
                "01_Home", "02_Search", "03_Detail"
            ].enumerated() {
                let filename = "\(prefix)_\(label).png"
                let url = capturedRoot.appendingPathComponent(filename)
                try writeSyntheticPNG(width: w, height: h, label: label, index: idx, to: url)
                shots.append(CaptureManifest.Screenshot(name: label, filename: filename, capturedAt: Date()))
            }

            manifestDevices.append(CaptureManifest.DeviceCapture(
                deviceType: deviceType,
                simulatorName: simName,
                locale: "en-US",
                appearance: nil,
                screenshots: shots
            ))
        }

        let manifest = CaptureManifest(
            version: 1,
            generatedAt: Date(),
            generatedBy: "fixture-test",
            appName: "FixtureApp",
            displayName: "Fixture",
            scheme: "Fixture",
            devices: manifestDevices
        )

        // Config exercises chrome=stroke so no bezel install is required.
        let config = RenderConfig(
            enabled: true,
            outputDir: runRoot.appendingPathComponent("framed").path,
            background: BackgroundConfig(
                color: .gradient(["#1a1a2e", "#4a1e5c"]),
                align: .center, fit: .cover
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .system,
                    weight: .bold,
                    fontSizePct: 5.5,
                    color: "#ffffff",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .system,
                    weight: .regular,
                    fontSizePct: 2.8,
                    color: "#cccccc",
                    align: .center
                ),
                spacingPct: 1.2,
                minHeightPct: 20,
                paddingPct: 4
            ),
            chrome: ChromeConfig(
                style: .stroke,
                strokeColor: "#ffffff",
                strokeWidth: 4,
                cornerRadius: .auto,
                shadow: true,
                paddingPct: 5
            ),
            slides: [
                "01_Home": SlideOverride(caption: SlideCaption(title: .string("Your **recipes**, organized."))),
                "02_Search": SlideOverride(caption: SlideCaption(
                    title: .array(["Find anything", "in *seconds*."]),
                    highlights: [CaptionHighlight(match: "seconds", color: "#feb909", weight: .heavy)]
                )),
                "03_Detail": SlideOverride(
                    caption: SlideCaption(title: .string("Every detail, at a glance."), subtitle: .string("Powered by AI")),
                    chrome: ChromeConfig(strokeColor: "#feb909")
                ),
            ]
        )

        let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)

        let out = try await pipeline.render(
            manifest: manifest,
            capturedRoot: capturedRoot,
            renderRoot: renderRoot
        )

        XCTAssertEqual(out.failures.count, 0, "expected no failures; got \(out.failures)")
        XCTAssertEqual(out.renderedSlides, 9, "3 devices × 3 slides = 9 expected")

        // Verify every expected output exists and has the right pixel dimensions.
        for device in manifest.devices {
            for shot in device.screenshots {
                let outURL = renderRoot.appendingPathComponent(shot.filename)
                XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                              "missing output: \(outURL.path)")
                guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    XCTFail("can't read \(outURL.path)")
                    continue
                }
                // Must match the synthetic screenshot's pixel dims.
                let sourceURL = capturedRoot.appendingPathComponent(shot.filename)
                let srcReader = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
                let props = CGImageSourceCopyPropertiesAtIndex(srcReader, 0, nil) as! [CFString: Any]
                XCTAssertEqual(img.width, props[kCGImagePropertyPixelWidth] as? Int)
                XCTAssertEqual(img.height, props[kCGImagePropertyPixelHeight] as? Int)
            }
        }

        print("--- rendered fixture ---")
        print("  inputs:  \(capturedRoot.path)")
        print("  outputs: \(renderRoot.path)")
        for w in out.warnings { print("  warn: \(w)") }
    }

    /// Runs the same pipeline with chrome=bezel. Requires bezels installed
    /// via `storescreens bezels import` — skips if none found.
    func testEndToEnd_bezel_producesOutputs() async throws {
        let store = BezelStore(projectLocal: nil)
        if store.installedKeys().isEmpty {
            print("skipping: no bezels installed (run `storescreens bezels import`)")
            return
        }

        let bezelFixtureRoot = try perTestRoot("bezel-chrome")

        let capturedRoot = bezelFixtureRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

        // Only render devices whose bezel is installed.
        let candidates: [(String, String, Int, Int)] = [
            ("iPhone 6.9\"", "iPhone 17 Pro Max", 1320, 2868),
            ("iPad Pro 13\"", "iPad Pro 13-inch (M5)", 2064, 2752),
            ("Mac 3456x2234", "MacBook 16", 3456, 2234),
        ]

        var manifestDevices: [CaptureManifest.DeviceCapture] = []
        for (deviceType, simName, w, h) in candidates {
            let pf = RenderPipeline.productFamilyFromDeviceType(deviceType)
            let orient: BezelOrientation = (pf == 6) ? .none : (w > h ? .landscape : .portrait)
            let key = BezelStore.canonicalKey(productFamily: pf, width: w, height: h, orientation: orient)
            guard store.lookup(canonicalKey: key) != nil else {
                print("skipping \(deviceType): no bezel for \(key)")
                continue
            }

            let prefix = deviceType
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: " ", with: "_")
            let filename = "\(prefix)_01_Home.png"
            let url = capturedRoot.appendingPathComponent(filename)
            try writeSyntheticPNG(width: w, height: h, label: "Home", index: 0, to: url)

            manifestDevices.append(CaptureManifest.DeviceCapture(
                deviceType: deviceType, simulatorName: simName,
                locale: "en-US", appearance: nil,
                screenshots: [CaptureManifest.Screenshot(name: "01_Home", filename: filename, capturedAt: Date())]
            ))
        }

        guard !manifestDevices.isEmpty else {
            print("skipping: no matching bezels for the fixture's device list")
            return
        }

        let manifest = CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "fixture-test",
            appName: "BezelFixture", displayName: "Bezel Fixture", scheme: "Bezel",
            devices: manifestDevices
        )

        let config = RenderConfig(
            enabled: true,
            outputDir: bezelFixtureRoot.appendingPathComponent("framed").path,
            background: BackgroundConfig(color: .solid("#2a1830")),
            caption: CaptionConfig(
                title: CaptionRole(font: .system, weight: .bold, fontSizePct: 5.5, color: "#ffffff", align: .center),
                minHeightPct: 20, paddingPct: 4
            ),
            chrome: ChromeConfig(style: .bezel, shadow: true, paddingPct: 5),
            slides: [
                "01_Home": SlideOverride(caption: SlideCaption(title: .string("Inside a real bezel"))),
            ]
        )

        let renderRoot = bezelFixtureRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: bezelFixtureRoot)
        let out = try await pipeline.render(
            manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot
        )

        XCTAssertEqual(out.failures.count, 0, "bezel render should succeed; got: \(out.failures)")
        XCTAssertGreaterThan(out.renderedSlides, 0)
        print("--- bezel fixture rendered to \(renderRoot.path) ---")
    }

    // MARK: - Images + laurels

    /// One image at above_title, runs end-to-end with chrome=stroke. Verifies
    /// the output PNG exists and has non-zero size (read in by ImageIO so we
    /// know it decoded as a valid image).
    func testRender_withSingleImageAtAboveTitle_succeeds() async throws {
        let runRoot = try perTestRoot("image-single-above-title")
        let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

        // Synthesize a screenshot + a small image asset.
        let filename = "iPhone_6.9_01_Home.png"
        try writeSyntheticPNG(width: 1320, height: 2868, label: "Home", index: 0,
                              to: capturedRoot.appendingPathComponent(filename))
        let logoURL = runRoot.appendingPathComponent("logo.png")
        try writeSolidColorPNG(width: 96, height: 96, color: .systemBlue, to: logoURL)

        let manifest = singleSlideManifest(filename: filename, deviceType: "iPhone 6.9\"")

        let config = RenderConfig(
            enabled: true,
            background: BackgroundConfig(color: .solid("#1a1a2e")),
            images: [
                ImageConfig(
                    path: .shared(logoURL.path),
                    position: .aboveTitle,
                    align: .center,
                    maxHeightPct: 8
                ),
            ],
            caption: CaptionConfig(
                title: CaptionRole(font: .system, weight: .bold, fontSizePct: 5.5,
                                   color: "#ffffff", align: .center),
                minHeightPct: 22, paddingPct: 4
            ),
            chrome: ChromeConfig(style: .stroke, strokeColor: "#ffffff", strokeWidth: 3,
                                 cornerRadius: .auto, paddingPct: 5),
            slides: [
                "01_Home": SlideOverride(caption: SlideCaption(title: .string("Hello"))),
            ]
        )

        let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
        let out = try await pipeline.render(
            manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot
        )

        XCTAssertEqual(out.failures.count, 0, "render must not fail; got: \(out.failures)")
        XCTAssertEqual(out.renderedSlides, 1)

        try assertOutputIsValidPNG(at: renderRoot.appendingPathComponent(filename))
    }

    /// Two images at the same slot with the same align should stack as a
    /// horizontal group without crashing.
    func testRender_withTwoImagesSameAlign_succeeds() async throws {
        let runRoot = try perTestRoot("image-two-same-align")
        let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

        let filename = "iPhone_6.9_01_Home.png"
        try writeSyntheticPNG(width: 1320, height: 2868, label: "Home", index: 0,
                              to: capturedRoot.appendingPathComponent(filename))

        let imgA = runRoot.appendingPathComponent("a.png")
        let imgB = runRoot.appendingPathComponent("b.png")
        try writeSolidColorPNG(width: 64, height: 64, color: .systemTeal, to: imgA)
        try writeSolidColorPNG(width: 64, height: 64, color: .systemPink, to: imgB)

        let manifest = singleSlideManifest(filename: filename, deviceType: "iPhone 6.9\"")

        let config = RenderConfig(
            enabled: true,
            background: BackgroundConfig(color: .solid("#101820")),
            images: [
                ImageConfig(path: .shared(imgA.path),
                            position: .aboveTitle, align: .center, maxHeightPct: 6),
                ImageConfig(path: .shared(imgB.path),
                            position: .aboveTitle, align: .center, maxHeightPct: 6),
            ],
            caption: CaptionConfig(
                title: CaptionRole(font: .system, weight: .bold, fontSizePct: 5.0,
                                   color: "#ffffff", align: .center),
                minHeightPct: 20, paddingPct: 4
            ),
            chrome: ChromeConfig(style: .stroke, strokeColor: "#ffffff", strokeWidth: 3,
                                 cornerRadius: .auto, paddingPct: 5),
            slides: [
                "01_Home": SlideOverride(caption: SlideCaption(title: .string("Pair"))),
            ]
        )

        let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
        let out = try await pipeline.render(
            manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot
        )

        XCTAssertEqual(out.failures.count, 0, "render must not fail; got: \(out.failures)")
        XCTAssertEqual(out.renderedSlides, 1)
        try assertOutputIsValidPNG(at: renderRoot.appendingPathComponent(filename))
    }

    /// A config that uses only the legacy `logo:` block (no `images:`) must
    /// still render — the resolver synthesizes an above_title image from it.
    func testRender_legacyLogoStillWorks() async throws {
        let runRoot = try perTestRoot("legacy-logo")
        let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

        let filename = "iPhone_6.9_01_Home.png"
        try writeSyntheticPNG(width: 1320, height: 2868, label: "Home", index: 0,
                              to: capturedRoot.appendingPathComponent(filename))

        let logoURL = runRoot.appendingPathComponent("logo.png")
        try writeSolidColorPNG(width: 96, height: 96, color: .systemOrange, to: logoURL)

        let manifest = singleSlideManifest(filename: filename, deviceType: "iPhone 6.9\"")

        let config = RenderConfig(
            enabled: true,
            background: BackgroundConfig(color: .solid("#221122")),
            logo: LogoConfig(
                path: .shared(logoURL.path),
                placement: .firstOnly,
                maxHeightPct: 8
            ),
            caption: CaptionConfig(
                title: CaptionRole(font: .system, weight: .bold, fontSizePct: 5.0,
                                   color: "#ffffff", align: .center),
                minHeightPct: 20, paddingPct: 4
            ),
            chrome: ChromeConfig(style: .stroke, strokeColor: "#ffffff", strokeWidth: 3,
                                 cornerRadius: .auto, paddingPct: 5),
            slides: [
                "01_Home": SlideOverride(caption: SlideCaption(title: .string("Legacy"))),
            ]
        )

        let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
        let out = try await pipeline.render(
            manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot
        )

        XCTAssertEqual(out.failures.count, 0,
                       "legacy logo: block must still render; got: \(out.failures)")
        XCTAssertEqual(out.renderedSlides, 1)
        try assertOutputIsValidPNG(at: renderRoot.appendingPathComponent(filename))
    }

    /// A laurel block under the caption should render without crashing.
    func testRender_withLaurelBelowSubtitle_succeeds() async throws {
        let runRoot = try perTestRoot("laurel-below-subtitle")
        let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

        let filename = "iPhone_6.9_01_Home.png"
        try writeSyntheticPNG(width: 1320, height: 2868, label: "Home", index: 0,
                              to: capturedRoot.appendingPathComponent(filename))

        let manifest = singleSlideManifest(filename: filename, deviceType: "iPhone 6.9\"")

        let config = RenderConfig(
            enabled: true,
            background: BackgroundConfig(color: .solid("#0a0a14")),
            laurels: [
                LaurelConfig(
                    title: .string("Editor's Choice"),
                    subtitle: .string("2026"),
                    color: .shared("#ffffff"),
                    position: .belowSubtitle,
                    align: .center,
                    maxHeightPct: 10
                ),
            ],
            caption: CaptionConfig(
                title: CaptionRole(font: .system, weight: .bold, fontSizePct: 5.0,
                                   color: "#ffffff", align: .center),
                subtitle: CaptionRole(font: .system, weight: .regular, fontSizePct: 2.8,
                                      color: "#cccccc", align: .center),
                minHeightPct: 22, paddingPct: 4
            ),
            chrome: ChromeConfig(style: .stroke, strokeColor: "#ffffff", strokeWidth: 3,
                                 cornerRadius: .auto, paddingPct: 5),
            slides: [
                "01_Home": SlideOverride(caption: SlideCaption(
                    title: .string("Featured"),
                    subtitle: .string("Loved by readers")
                )),
            ]
        )

        let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
        let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
        let out = try await pipeline.render(
            manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot
        )

        XCTAssertEqual(out.failures.count, 0,
                       "laurel render must not fail; got: \(out.failures)")
        XCTAssertEqual(out.renderedSlides, 1)
        try assertOutputIsValidPNG(at: renderRoot.appendingPathComponent(filename))
    }

    // MARK: - Image / manifest helpers

    /// Builds a one-device, one-screenshot manifest for the simpler image+laurel
    /// integration tests. Keeps the test bodies focused on the feature under test.
    private func singleSlideManifest(filename: String, deviceType: String) -> CaptureManifest {
        CaptureManifest(
            version: 1, generatedAt: Date(), generatedBy: "image-laurel-test",
            appName: "Fixture", displayName: "Fixture", scheme: "Fixture",
            devices: [
                CaptureManifest.DeviceCapture(
                    deviceType: deviceType,
                    simulatorName: "iPhone 17 Pro Max",
                    locale: "en-US", appearance: nil,
                    screenshots: [CaptureManifest.Screenshot(
                        name: "01_Home", filename: filename, capturedAt: Date()
                    )]
                ),
            ]
        )
    }

    /// Creates a tiny solid-colored PNG. Used for image-overlay assets in the
    /// images / laurels render tests.
    private func writeSolidColorPNG(width: Int, height: Int, color: NSColor, to url: URL) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "image-fixture", code: 1) }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "image-fixture", code: 2) }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "image-fixture", code: 3)
        }
    }

    /// Confirms that `url` exists, has non-zero file size, and decodes as a
    /// valid PNG via ImageIO. Common assertion across the image + laurel tests.
    private func assertOutputIsValidPNG(at url: URL) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "expected output PNG at \(url.path)")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "output PNG must be non-empty")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let _ = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            XCTFail("output at \(url.path) is not a decodable PNG")
            return
        }
    }

    // MARK: - Synthetic screenshots

    /// Creates a distinctively-colored PNG at the requested pixel size with a
    /// visible label. Used as a stand-in for a real captured screenshot so
    /// we can eyeball the rendered output (background + caption + chrome)
    /// without needing a real build.
    private func writeSyntheticPNG(width: Int, height: Int, label: String, index: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "fixture", code: 1) }

        // Gradient fill — different hue per slide for visual distinction.
        let hue: CGFloat = CGFloat(index) * 0.27
        let top = NSColor(hue: hue, saturation: 0.7, brightness: 0.45, alpha: 1).cgColor
        let bot = NSColor(hue: hue, saturation: 0.5, brightness: 0.2, alpha: 1).cgColor
        let grad = CGGradient(colorsSpace: colorSpace, colors: [top, bot] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: 0, y: 0),
            options: []
        )

        // Draw the label in white at the center.
        let attr = NSAttributedString(string: label, attributes: [
            .font: NSFont.boldSystemFont(ofSize: CGFloat(width) * 0.06),
            .foregroundColor: NSColor.white,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let fitSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: attr.length),
            nil, CGSize(width: CGFloat(width), height: CGFloat(height)), nil
        )
        let textRect = CGRect(
            x: (CGFloat(width) - fitSize.width) / 2,
            y: (CGFloat(height) - fitSize.height) / 2,
            width: fitSize.width, height: fitSize.height
        )
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attr.length), path, nil)
        CTFrameDraw(frame, ctx)

        guard let img = ctx.makeImage() else { throw NSError(domain: "fixture", code: 2) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "fixture", code: 3)
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "fixture", code: 4)
        }
    }
}
