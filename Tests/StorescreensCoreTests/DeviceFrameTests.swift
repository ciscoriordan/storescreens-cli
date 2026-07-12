import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Yams
@testable import StorescreensCore

final class DeviceFrameTests: XCTestCase {

    // MARK: - Config decoding

    func testChromeConfig_deviceStyleDecodes() throws {
        let yaml = """
            style: device
            device_colorway: natural
            bezel_fallback: stroke
            """
        let chrome = try YAMLDecoder().decode(ChromeConfig.self, from: yaml)
        XCTAssertEqual(chrome.style, .device)
        XCTAssertEqual(chrome.deviceColorway, .natural)
        XCTAssertEqual(chrome.bezelFallback, .stroke)
    }

    func testChromeConfig_mergePrefersSlideOverride() {
        let base = ChromeConfig(style: .bezel, deviceColorway: .dark, bezelFallback: .error)
        let override = ChromeConfig(deviceColorway: .silver)
        let merged = RenderResolver.mergeChrome(base: base, override: override)
        XCTAssertEqual(merged?.style, .bezel)
        XCTAssertEqual(merged?.deviceColorway, .silver)
        XCTAssertEqual(merged?.bezelFallback, .error)
    }

    // MARK: - Spec geometry

    func testSpec_islandDevice() throws {
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 1206, height: 2622)))

        // Screen keeps the screenshot's native pixel size, centered in the canvas.
        XCTAssertEqual(spec.screenRect.width, 1206)
        XCTAssertEqual(spec.screenRect.height, 2622)
        XCTAssertEqual(spec.screenRect.minX, spec.canvasWidth - spec.screenRect.maxX, accuracy: 0.5)
        XCTAssertEqual(spec.screenRect.minY, spec.canvasHeight - spec.screenRect.maxY, accuracy: 0.5)

        // Body encloses screen, canvas encloses body (button margin).
        XCTAssertTrue(spec.bodyRect.contains(spec.screenRect))
        XCTAssertGreaterThan(spec.canvasWidth, spec.bodyRect.width)

        // Edge-to-edge screens keep the concentric corner rule.
        XCTAssertEqual(
            spec.bodyCornerRadius,
            spec.screenCornerRadius + (spec.screenRect.minX - spec.bodyRect.minX),
            accuracy: 0.5
        )

        guard case .island(let island) = spec.cutout else {
            return XCTFail("expected island cutout, got \(spec.cutout)")
        }
        XCTAssertEqual(island.midX, spec.screenRect.midX, accuracy: 0.5)
        XCTAssertGreaterThan(island.minY, spec.screenRect.minY)

        // Action + volume up/down + power.
        XCTAssertEqual(spec.buttons.count, 4)
    }

    func testSpec_notchDevice() throws {
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 1284, height: 2778)))
        guard case .notch(let notch) = spec.cutout else {
            return XCTFail("expected notch cutout, got \(spec.cutout)")
        }
        // Notch sits flush against the screen top.
        XCTAssertEqual(notch.minY, spec.screenRect.minY, accuracy: 0.5)
        XCTAssertEqual(notch.midX, spec.screenRect.midX, accuracy: 0.5)
    }

    func testSpec_squatIPhoneHasNoCutoutAndSquareishCorners() throws {
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 750, height: 1334)))
        XCTAssertEqual(spec.cutout, .none)
        // Home-button-era LCD: nearly square display corners inside a
        // rounded body.
        XCTAssertLessThan(spec.screenCornerRadius, 0.03 * 750)
        XCTAssertGreaterThan(spec.bodyCornerRadius, 0.08 * 750)
    }

    func testSpec_modernAspectFallbackGetsIsland() throws {
        // Half-scale synthetic screenshot: no exact resolution match, but a
        // modern tall aspect - should get the current-generation look.
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 660, height: 1434)))
        guard case .island = spec.cutout else {
            return XCTFail("expected island cutout via aspect fallback, got \(spec.cutout)")
        }
    }

    func testSpec_landscapeRotatesCutoutAndButtons() throws {
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 2622, height: 1206)))
        guard case .island(let island) = spec.cutout else {
            return XCTFail("expected island cutout, got \(spec.cutout)")
        }
        // Vertical pill hugging the leading screen edge.
        XCTAssertGreaterThan(island.height, island.width)
        XCTAssertLessThan(island.midX, spec.screenRect.midX)
        XCTAssertEqual(island.midY, spec.screenRect.midY, accuracy: 0.5)
        // Island-left is a counterclockwise rotation from portrait: the
        // action/volume cluster ends up on the bottom edge and the power
        // button on the top edge.
        XCTAssertEqual(spec.buttons.count, 4)
        let bottom = spec.buttons.filter { $0.midY > spec.bodyRect.maxY - 1 }
        let top = spec.buttons.filter { $0.midY < spec.bodyRect.minY + 1 }
        XCTAssertEqual(bottom.count, 3)
        XCTAssertEqual(top.count, 1)
    }

    func testSpec_iPadIsCleanSlab() throws {
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 2, screenshotPixelSize: CGSize(width: 2064, height: 2752)))
        XCTAssertEqual(spec.cutout, .none)
        XCTAssertTrue(spec.buttons.isEmpty)
        // No button margin: body fills the canvas.
        XCTAssertEqual(spec.bodyRect.width, spec.canvasWidth)
    }

    func testSpec_unsupportedFamiliesReturnNil() {
        XCTAssertNil(DeviceFrame.spec(productFamily: 6, screenshotPixelSize: CGSize(width: 2880, height: 1800)))
        XCTAssertNil(DeviceFrame.spec(productFamily: 4, screenshotPixelSize: CGSize(width: 410, height: 502)))
    }

    // MARK: - ChromeRenderer dispatch + fallback

    private func makeEmptyBezelStore() throws -> (BezelStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-frame-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (BezelStore(projectLocal: nil, userGlobal: dir), dir)
    }

    private func writeTinyScreenshot(to url: URL, width: Int = 120, height: Int = 260) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func makeCanvas() throws -> CGContext {
        try XCTUnwrap(CGContext(
            data: nil, width: 300, height: 640,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    func testDrawChrome_bezelFallsBackToDeviceByDefault() throws {
        let (store, dir) = try makeEmptyBezelStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screenshotURL = dir.appendingPathComponent("shot.png")
        try writeTinyScreenshot(to: screenshotURL)

        let ctx = try makeCanvas()
        let warnings = try ChromeRenderer(bezelStore: store).drawChrome(
            ChromeConfig(style: .bezel),
            screenshotURL: screenshotURL,
            productFamily: 1,
            orientation: .portrait,
            screenshotPixelSize: CGSize(width: 120, height: 260),
            into: ctx,
            chromeRect: CGRect(x: 0, y: 0, width: 300, height: 640)
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("drawn device frame"), "unexpected warning: \(warnings[0])")
        XCTAssertTrue(warnings[0].contains("bezels import"), "warning should point at the fix: \(warnings[0])")
    }

    func testDrawChrome_bezelUsesInstalledBezelWithoutWarnings() throws {
        let (store, dir) = try makeEmptyBezelStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screenshotURL = dir.appendingPathComponent("shot.png")
        try writeTinyScreenshot(to: screenshotURL)

        // Install a bezel under the canonical key the renderer will look up.
        let key = BezelStore.canonicalKey(productFamily: 1, width: 120, height: 260, orientation: .portrait)
        try writeTinyScreenshot(to: dir.appendingPathComponent("\(key).png"), width: 140, height: 280)
        let metadata = BezelMetadata(
            canvasWidth: 140, canvasHeight: 280,
            screenX: 10, screenY: 10, screenWidth: 120, screenHeight: 260,
            canonicalKey: key, orientation: .portrait, productFamily: 1,
            sourceFilename: "test.psd"
        )
        try JSONEncoder().encode(metadata).write(to: dir.appendingPathComponent("\(key).json"))

        let ctx = try makeCanvas()
        let warnings = try ChromeRenderer(bezelStore: store).drawChrome(
            ChromeConfig(style: .bezel),
            screenshotURL: screenshotURL,
            productFamily: 1,
            orientation: .portrait,
            screenshotPixelSize: CGSize(width: 120, height: 260),
            into: ctx,
            chromeRect: CGRect(x: 0, y: 0, width: 300, height: 640)
        )
        XCTAssertEqual(warnings, [], "installed bezel must render with no fallback warnings")
    }

    func testDrawChrome_bezelFallbackStrokeRendersStroke() throws {
        let (store, dir) = try makeEmptyBezelStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screenshotURL = dir.appendingPathComponent("shot.png")
        try writeTinyScreenshot(to: screenshotURL)

        let config = ChromeConfig(style: .bezel, bezelFallback: .stroke)
        let renderer = ChromeRenderer(bezelStore: store)

        // The resolver must pick stroke, not the drawn device frame.
        let (effective, resolveWarnings) = renderer.resolveEffectiveChrome(
            config: config,
            productFamily: 1,
            orientation: .portrait,
            screenshotPixelSize: CGSize(width: 120, height: 260)
        )
        guard case .stroke = effective else {
            return XCTFail("expected stroke fallback, got \(effective)")
        }
        XCTAssertEqual(resolveWarnings.count, 1)

        let ctx = try makeCanvas()
        let warnings = try renderer.drawChrome(
            config,
            screenshotURL: screenshotURL,
            productFamily: 1,
            orientation: .portrait,
            screenshotPixelSize: CGSize(width: 120, height: 260),
            into: ctx,
            chromeRect: CGRect(x: 0, y: 0, width: 300, height: 640)
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("stroke chrome instead"), "unexpected warning: \(warnings[0])")
    }

    func testDrawChrome_deviceStyleIPadRendersWithoutWarnings() throws {
        let (store, dir) = try makeEmptyBezelStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screenshotURL = dir.appendingPathComponent("shot.png")
        try writeTinyScreenshot(to: screenshotURL, width: 150, height: 200)

        let ctx = try makeCanvas()
        let warnings = try ChromeRenderer(bezelStore: store).drawChrome(
            ChromeConfig(style: .device, deviceColorway: .silver),
            screenshotURL: screenshotURL,
            productFamily: 2,
            orientation: .portrait,
            screenshotPixelSize: CGSize(width: 150, height: 200),
            into: ctx,
            chromeRect: CGRect(x: 0, y: 0, width: 300, height: 640)
        )
        XCTAssertEqual(warnings, [], "supported family must draw the device frame with no warnings")
    }

    func testDrawChrome_bezelFallbackErrorThrows() throws {
        let (store, dir) = try makeEmptyBezelStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screenshotURL = dir.appendingPathComponent("shot.png")
        try writeTinyScreenshot(to: screenshotURL)

        let ctx = try makeCanvas()
        XCTAssertThrowsError(try ChromeRenderer(bezelStore: store).drawChrome(
            ChromeConfig(style: .bezel, bezelFallback: .error),
            screenshotURL: screenshotURL,
            productFamily: 1,
            orientation: .portrait,
            screenshotPixelSize: CGSize(width: 120, height: 260),
            into: ctx,
            chromeRect: CGRect(x: 0, y: 0, width: 300, height: 640)
        )) { error in
            guard case ChromeRenderer.RenderError.missingBezel = error else {
                return XCTFail("expected missingBezel, got \(error)")
            }
        }
    }

    func testDrawChrome_deviceStyleOnMacFallsBackToStroke() throws {
        let (store, dir) = try makeEmptyBezelStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screenshotURL = dir.appendingPathComponent("shot.png")
        try writeTinyScreenshot(to: screenshotURL, width: 288, height: 180)

        let ctx = try makeCanvas()
        let warnings = try ChromeRenderer(bezelStore: store).drawChrome(
            ChromeConfig(style: .device),
            screenshotURL: screenshotURL,
            productFamily: 6,
            orientation: .none,
            screenshotPixelSize: CGSize(width: 288, height: 180),
            into: ctx,
            chromeRect: CGRect(x: 0, y: 0, width: 300, height: 640)
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("stroke"), "unexpected warning: \(warnings[0])")
    }

    func testScreenContentTopBL_deviceStyleAnchorsToScreenTop() throws {
        let (store, dir) = try makeEmptyBezelStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let renderer = ChromeRenderer(bezelStore: store)
        let chromeRect = CGRect(x: 0, y: 0, width: 300, height: 640)
        let deviceTop = renderer.screenContentTopBL(
            config: ChromeConfig(style: .device),
            productFamily: 1,
            orientation: .portrait,
            screenshotPixelSize: CGSize(width: 1206, height: 2622),
            chromeRect: chromeRect
        )
        let unwrapped = try XCTUnwrap(deviceTop)

        // Replicate the renderer's layout (default 4% padding, fit: width)
        // and require the exact anchor: the fitted canvas's top minus the
        // scaled screen offset. Anything else - e.g. anchoring to the frame
        // top instead of the screen top - must fail here.
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 1206, height: 2622)))
        let padded = chromeRect.insetBy(dx: chromeRect.width * 0.04, dy: chromeRect.height * 0.04)
        let scale = padded.width / spec.canvasWidth
        let fittedHeight = spec.canvasHeight * scale
        let targetMaxY = fittedHeight > padded.height
            ? padded.maxY
            : padded.minY + (padded.height - fittedHeight) / 2 + fittedHeight
        let expected = targetMaxY - spec.screenRect.minY * scale
        XCTAssertEqual(unwrapped, expected, accuracy: 0.5)

        // Frame-less styles keep the nil fallback.
        XCTAssertNil(renderer.screenContentTopBL(
            config: ChromeConfig(style: .stroke),
            productFamily: 1,
            orientation: .portrait,
            screenshotPixelSize: CGSize(width: 1206, height: 2622),
            chromeRect: chromeRect
        ))
    }
}
