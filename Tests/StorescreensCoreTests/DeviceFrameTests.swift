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

    // MARK: - iPhone Duo

    private func edgeButtons(_ spec: DeviceFrame.Spec) -> (top: [CGRect], bottom: [CGRect], left: [CGRect], right: [CGRect]) {
        let b = spec.bodyRect
        return (
            spec.buttons.filter { abs($0.midY - b.minY) < 1 },
            spec.buttons.filter { abs($0.midY - b.maxY) < 1 },
            spec.buttons.filter { abs($0.midX - b.minX) < 1 },
            spec.buttons.filter { abs($0.midX - b.maxX) < 1 }
        )
    }

    func testSpec_duoOuterPortrait() throws {
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 1398, height: 2034)))
        XCTAssertEqual(spec.screenRect.size, CGSize(width: 1398, height: 2034))

        // Display corners from the shared display shape: small on the
        // hinge (left) side, large on the other side.
        XCTAssertEqual(spec.screenCorners, CornerRadii(topLeft: 18, topRight: 162, bottomLeft: 18, bottomRight: 162))
        // Body concentric with the display, corner by corner.
        let inset = spec.screenRect.minX - spec.bodyRect.minX
        XCTAssertEqual(spec.bodyCorners, spec.screenCorners.expanded(by: inset))
        XCTAssertEqual(spec.screenRect.minY - spec.bodyRect.minY, inset)

        // Screen centered horizontally even with the hinge strip on one side.
        XCTAssertEqual(spec.screenRect.minX, spec.canvasWidth - spec.screenRect.maxX, accuracy: 0.5)

        // Camera hole top right, where Apple's artwork puts it.
        guard case .hole(let camera) = spec.cutout else {
            return XCTFail("expected camera hole, got \(spec.cutout)")
        }
        XCTAssertEqual(camera.midX - spec.screenRect.minX, 1255, accuracy: 0.5)
        XCTAssertEqual(camera.midY - spec.screenRect.minY, 143.5, accuracy: 0.5)
        XCTAssertEqual(camera.width, 108, accuracy: 0.5)
        XCTAssertTrue(spec.screenRect.contains(camera))

        // The other half of the closed phone shows past the hinge edge.
        let hinge = try XCTUnwrap(spec.hinge)
        let spine = try XCTUnwrap(hinge.spine)
        XCTAssertLessThan(spine.minX, spec.bodyRect.minX)
        XCTAssertGreaterThanOrEqual(spine.minX, 0)
        XCTAssertGreaterThan(spine.minY, spec.bodyRect.minY)
        XCTAssertLessThan(spine.maxY, spec.bodyRect.maxY)
        XCTAssertTrue(hinge.foldSeams.isEmpty)

        // Volume buttons on the top edge, power on the edge opposite the hinge.
        let edges = edgeButtons(spec)
        XCTAssertEqual(edges.top.count, 2)
        XCTAssertEqual(edges.right.count, 1)
        XCTAssertEqual(spec.buttons.count, 3)
    }

    func testSpec_duoOuterLandscapeIsPortraitTurnedCounterclockwise() throws {
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 2034, height: 1398)))
        let portrait = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 1398, height: 2034)))
        XCTAssertEqual(spec.canvasWidth, portrait.canvasHeight)
        XCTAssertEqual(spec.canvasHeight, portrait.canvasWidth)
        XCTAssertEqual(spec.screenRect.size, CGSize(width: 2034, height: 1398))

        // Apple's landscape artwork: large corners on top, hinge along the
        // bottom, camera top left.
        XCTAssertEqual(spec.screenCorners, CornerRadii(topLeft: 162, topRight: 162, bottomLeft: 18, bottomRight: 18))
        XCTAssertEqual(
            spec.screenCorners,
            DisplayShape.forScreen(productFamily: 1, size: CGSize(width: 2034, height: 1398)).corners
        )
        guard case .hole(let camera) = spec.cutout else {
            return XCTFail("expected camera hole, got \(spec.cutout)")
        }
        XCTAssertEqual(camera.midX - spec.screenRect.minX, 143.5, accuracy: 0.5)
        XCTAssertEqual(camera.midY - spec.screenRect.minY, 143, accuracy: 0.5)

        let spine = try XCTUnwrap(spec.hinge?.spine)
        XCTAssertGreaterThan(spine.maxY, spec.bodyRect.maxY)
        XCTAssertLessThanOrEqual(spine.maxY, spec.canvasHeight)

        let edges = edgeButtons(spec)
        XCTAssertEqual(edges.top.count, 1)
        XCTAssertEqual(edges.left.count, 2)
    }

    func testSpec_duoInnerPortrait() throws {
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 2007, height: 2853)))
        XCTAssertEqual(spec.screenCorners, CornerRadii(uniform: 149))
        XCTAssertEqual(spec.cutout, .none)
        XCTAssertEqual(
            spec.bodyCornerRadius,
            spec.screenCornerRadius + (spec.screenRect.minX - spec.bodyRect.minX),
            accuracy: 0.5
        )

        // Fold marks on both long edges at mid-height, none over the screen.
        let hinge = try XCTUnwrap(spec.hinge)
        XCTAssertNil(hinge.spine)
        XCTAssertEqual(hinge.foldSeams.count, 2)
        XCTAssertEqual(hinge.foldHousings.count, 2)
        for mark in hinge.foldSeams + hinge.foldHousings {
            XCTAssertEqual(mark.midY, spec.screenRect.midY, accuracy: 0.5)
            XCTAssertFalse(mark.intersects(spec.screenRect), "\(mark) crosses the screen")
        }
        XCTAssertLessThan(hinge.foldSeams[0].midX, spec.screenRect.minX)
        XCTAssertGreaterThan(hinge.foldSeams[1].midX, spec.screenRect.maxX)

        let edges = edgeButtons(spec)
        XCTAssertEqual(edges.left.count, 2)
        XCTAssertEqual(edges.top.count, 1)
    }

    func testSpec_duoInnerLandscapeIsPortraitTurnedClockwise() throws {
        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 2853, height: 2007)))
        XCTAssertEqual(spec.screenCorners, CornerRadii(uniform: 149))

        // Fold now runs vertically at mid-width: marks on top and bottom.
        let hinge = try XCTUnwrap(spec.hinge)
        for mark in hinge.foldSeams + hinge.foldHousings {
            XCTAssertEqual(mark.midX, spec.screenRect.midX, accuracy: 0.5)
            XCTAssertFalse(mark.intersects(spec.screenRect))
        }

        // Apple's Inner Open Landscape: volume on the top edge, power on the right.
        let edges = edgeButtons(spec)
        XCTAssertEqual(edges.top.count, 2)
        XCTAssertEqual(edges.right.count, 1)
        XCTAssertTrue(edges.top.allSatisfy { $0.midX > spec.bodyRect.midX })
    }

    func testSpec_duoIsNotTreatedAsHomeButtonIPhone() throws {
        // Both Duo displays are squat (aspect below 2); the home-button
        // rule would give them nearly square corners and no hinge.
        let sizes = [
            CGSize(width: 1398, height: 2034), CGSize(width: 2007, height: 2853),
            CGSize(width: 699, height: 1017), CGSize(width: 1004, height: 1427), CGSize(width: 669, height: 951),
        ]
        for size in sizes {
            let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: size))
            XCTAssertNotNil(spec.hinge, "\(size)")
            XCTAssertGreaterThan(spec.screenCornerRadius, 0.05 * size.width, "\(size)")
        }
    }

    func testSpec_iPhoneCropsWithADuoLikeAspectKeepTheHomeButtonFrame() throws {
        // Element and cropped screenshots keep their device's iPhone
        // label. 1206 x 1755 is within 0.02% of the Duo outer display's
        // aspect ratio and 1206 x 1714 of the inner one's, but neither is
        // a Duo size: both keep the home-button frame they got before Duo
        // support, with no hinge and no camera hole over the content.
        // Expected geometry is what that frame produced for these sizes.
        struct Expected {
            let size: CGSize
            let canvas: CGSize
            let body: CGRect
            let buttons: [CGRect]
        }
        let cases = [
            Expected(
                size: CGSize(width: 1206, height: 1755),
                canvas: CGSize(width: 1322, height: 1871),
                body: CGRect(x: 11, y: 11, width: 1300, height: 1849),
                buttons: [
                    CGRect(x: 0, y: 297.595, width: 22, height: 83.205),
                    CGRect(x: 0, y: 445.515, width: 22, height: 138.675),
                    CGRect(x: 0, y: 611.925, width: 22, height: 138.675),
                    CGRect(x: 1300, y: 491.74, width: 22, height: 203.39),
                ]
            ),
            Expected(
                size: CGSize(width: 1755, height: 1206),
                canvas: CGSize(width: 1871, height: 1322),
                body: CGRect(x: 11, y: 11, width: 1849, height: 1300),
                buttons: [
                    CGRect(x: 297.595, y: 1300, width: 83.205, height: 22),
                    CGRect(x: 445.515, y: 1300, width: 138.675, height: 22),
                    CGRect(x: 611.925, y: 1300, width: 138.675, height: 22),
                    CGRect(x: 491.74, y: 0, width: 203.39, height: 22),
                ]
            ),
            Expected(
                size: CGSize(width: 1206, height: 1714),
                canvas: CGSize(width: 1322, height: 1830),
                body: CGRect(x: 11, y: 11, width: 1300, height: 1808),
                buttons: [
                    CGRect(x: 0, y: 291.24, width: 22, height: 81.36),
                    CGRect(x: 0, y: 435.88, width: 22, height: 135.6),
                    CGRect(x: 0, y: 598.6, width: 22, height: 135.6),
                    CGRect(x: 1300, y: 481.08, width: 22, height: 198.88),
                ]
            ),
        ]
        for c in cases {
            let label = "\(c.size)"
            let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: c.size), label)
            XCTAssertNil(spec.hinge, label)
            XCTAssertEqual(spec.cutout, .none, label)
            // Home-button rule: nearly square display corners inside a
            // rounded body, the same on all four corners.
            XCTAssertEqual(spec.screenCorners, CornerRadii(uniform: 0.02 * 1206), label)
            XCTAssertEqual(spec.bodyCorners, CornerRadii(uniform: 0.115 * 1206), label)
            XCTAssertEqual(spec.bandWidth, 29, label)
            XCTAssertEqual(spec.canvasWidth, c.canvas.width, label)
            XCTAssertEqual(spec.canvasHeight, c.canvas.height, label)
            XCTAssertEqual(spec.bodyRect, c.body, label)
            XCTAssertEqual(spec.screenRect, CGRect(origin: CGPoint(x: 58, y: 58), size: c.size), label)
            XCTAssertEqual(spec.buttons.count, c.buttons.count, label)
            for (button, expected) in zip(spec.buttons, c.buttons) {
                XCTAssertEqual(button.minX, expected.minX, accuracy: 0.001, label)
                XCTAssertEqual(button.minY, expected.minY, accuracy: 0.001, label)
                XCTAssertEqual(button.width, expected.width, accuracy: 0.001, label)
                XCTAssertEqual(button.height, expected.height, accuracy: 0.001, label)
            }
        }
    }

    func testSpec_nonFoldingDevicesHaveUniformCornersAndNoHinge() throws {
        for size in [CGSize(width: 1206, height: 2622), CGSize(width: 2622, height: 1206), CGSize(width: 750, height: 1334)] {
            let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: size))
            XCTAssertNil(spec.hinge)
            XCTAssertTrue(spec.bodyCorners.isUniform)
            XCTAssertTrue(spec.screenCorners.isUniform)
        }
    }

    func testDrawChrome_deviceStyleDuoDrawsCameraOverScreenshot() throws {
        let (store, dir) = try makeEmptyBezelStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screenshotURL = dir.appendingPathComponent("shot.png")
        try writeTinyScreenshot(to: screenshotURL, width: 1398, height: 2034)

        let spec = try XCTUnwrap(DeviceFrame.spec(productFamily: 1, screenshotPixelSize: CGSize(width: 1398, height: 2034)))
        let width = Int(spec.canvasWidth)
        let height = Int(spec.canvasHeight)
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let warnings = try ChromeRenderer(bezelStore: store).drawChrome(
            ChromeConfig(style: .device, shadow: false, paddingPct: 0),
            screenshotURL: screenshotURL,
            productFamily: 1,
            orientation: .portrait,
            screenshotPixelSize: CGSize(width: 1398, height: 2034),
            into: ctx,
            chromeRect: CGRect(x: 0, y: 0, width: width, height: height)
        )
        XCTAssertEqual(warnings, [])

        // Rows of the context's buffer run top to bottom, matching the
        // spec's top-left coordinates at this 1:1 scale.
        let pixels = try XCTUnwrap(ctx.data)
        func red(_ p: CGPoint) -> UInt8 {
            pixels.load(fromByteOffset: Int(p.y) * ctx.bytesPerRow + Int(p.x) * 4, as: UInt8.self)
        }
        guard case .hole(let camera) = spec.cutout else { return XCTFail("expected camera hole") }
        XCTAssertLessThan(red(CGPoint(x: camera.midX, y: camera.midY)), 40, "camera disc drawn over the white screenshot")
        XCTAssertEqual(red(CGPoint(x: spec.screenRect.midX, y: spec.screenRect.midY)), 255, "screenshot visible")
        // Hinge-side corner is nearly square: 6 px in from the corner is
        // screenshot. At the large corner opposite the hinge it is not.
        XCTAssertEqual(red(CGPoint(x: spec.screenRect.minX + 6, y: spec.screenRect.minY + 6)), 255)
        XCTAssertLessThan(red(CGPoint(x: spec.screenRect.maxX - 6, y: spec.screenRect.minY + 6)), 40)
    }
}
