import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Orchestrates the per-slide render for a whole `CaptureManifest`.
/// Layer stack per slide (bottom → top):
///   1. Background (solid + image, light/dark variant)
///   2. Scrim (solid or gradient)
///   3. Logo (first slide in each device/locale/appearance combo)
///   4. Caption block (reserved height band at the top)
///   5. Chrome + screenshot (beneath caption, with padding)
package struct RenderPipeline {

    package let config: RenderConfig
    package let baseDirectory: URL
    package let bezelStore: BezelStore
    package let fontResolver: FontResolver

    /// Construction. `baseDirectory` is typically the directory containing
    /// the YML config; relative asset paths resolve against it.
    package init(
        config: RenderConfig,
        baseDirectory: URL,
        bezelStore: BezelStore? = nil,
        fontResolver: FontResolver? = nil
    ) {
        self.config = config
        self.baseDirectory = baseDirectory
        self.bezelStore = bezelStore ?? BezelStore(
            projectLocal: baseDirectory.appendingPathComponent("bezels", isDirectory: true)
        )
        self.fontResolver = fontResolver ?? FontResolver(baseDirectory: baseDirectory)
    }

    package struct Output: Sendable {
        package let renderedSlides: Int
        package let failures: [(slide: String, error: String)]
        package let warnings: [String]
    }

    /// Renders every screenshot from `manifest`. `capturedRoot` holds the
    /// raw captured PNGs. `renderRoot` is where framed PNGs are written.
    /// The manifest's screenshot order is authoritative — we render in that
    /// order, no re-sorting.
    package func render(
        manifest: CaptureManifest,
        capturedRoot: URL,
        renderRoot: URL
    ) async throws -> Output {
        let fm = FileManager.default
        try? fm.createDirectory(at: renderRoot, withIntermediateDirectories: true)

        var failures: [(String, String)] = []
        var warnings: [String] = []
        var renderedCount = 0

        for device in manifest.devices {
            let pf = productFamilyFromDeviceType(device.deviceType)
            let slidesInCombo = device.screenshots.count

            for (slideIndex, shot) in device.screenshots.enumerated() {
                do {
                    let sourceURL = capturedRoot.appendingPathComponent(shot.filename)
                    let outputURL = renderRoot.appendingPathComponent(shot.filename)

                    let slideWarnings = try await renderOne(
                        slideName: shot.name,
                        sourceURL: sourceURL,
                        outputURL: outputURL,
                        productFamily: pf,
                        appearance: device.appearance ?? "light",
                        slideIndex: slideIndex,
                        slidesInCombo: slidesInCombo
                    )
                    warnings.append(contentsOf: slideWarnings)
                    renderedCount += 1
                } catch {
                    failures.append((shot.name, "\(error)"))
                }
            }
        }

        return Output(renderedSlides: renderedCount, failures: failures, warnings: warnings)
    }

    /// Renders a single slide. Creates a pixel-dim CGContext, walks the
    /// layer stack, and writes out a PNG.
    package func renderOne(
        slideName: String,
        sourceURL: URL,
        outputURL: URL,
        productFamily: Int,
        appearance: String,
        slideIndex: Int,
        slidesInCombo: Int
    ) async throws -> [String] {
        let isFirstInCombo = slideIndex == 0
        // Read screenshot pixel dimensions + orientation.
        guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw NSError(domain: "RenderPipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot read dimensions of \(sourceURL.path)"])
        }
        let screenshotPixelSize = CGSize(width: w, height: h)
        // Canvas size == screenshot size for now; bezel rendering scales the
        // bezel canvas into this via `fitRect`.
        let canvasSize = screenshotPixelSize

        let orientation: BezelOrientation
        if productFamily == 6 { orientation = .none }
        else { orientation = w > h ? .landscape : .portrait }

        // Create the pixel-dim target context.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "RenderPipeline", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "failed to create render context"])
        }

        var warnings: [String] = []

        // --- Layer 1: background ---
        let bg = BackgroundRenderer(baseDirectory: baseDirectory)
        let bgConfig = RenderResolver.resolvedBackground(config: config, slideName: slideName)
        bg.drawBackground(
            bgConfig,
            appearance: appearance,
            into: ctx,
            canvasSize: canvasSize,
            slideIndex: slideIndex,
            slidesInCombo: slidesInCombo
        )

        // --- Layer 2: scrim ---
        let scrimConfig = RenderResolver.resolvedScrim(config: config, slideName: slideName)
        bg.drawScrim(scrimConfig, into: ctx, canvasSize: canvasSize)

        // --- Layer 3: logo (first-slide only, per combo) ---
        let logoPlacer = LogoPlacer(baseDirectory: baseDirectory)
        let logoConfig = RenderResolver.resolvedLogo(config: config, slideName: slideName)
        let logoReservedH = logoPlacer.reservedHeight(
            logoConfig, appearance: appearance,
            canvasSize: canvasSize, isFirstInCombo: isFirstInCombo
        )
        logoPlacer.drawLogo(
            logoConfig, appearance: appearance,
            isFirstInCombo: isFirstInCombo,
            into: ctx, canvasSize: canvasSize
        )

        // --- Layer 4: caption ---
        let captionResolved = RenderResolver.resolvedCaption(config: config, slideName: slideName)
        let captionReservedH: CGFloat
        if let cr = captionResolved, (cr.title != nil || cr.subtitle != nil) {
            let minHeightPct = CGFloat(cr.minHeightPct ?? 22)
            captionReservedH = canvasSize.height * minHeightPct / 100.0
            let paddingPct = CGFloat(cr.paddingPct ?? 4)
            let spacingPct = CGFloat(cr.spacingPct ?? 1.2)
            let padding = canvasSize.width * paddingPct / 100.0
            let spacing = canvasSize.height * spacingPct / 100.0
            let blockWidth = canvasSize.width - 2 * padding

            let layouter = CaptionLayouter(resolver: fontResolver)
            let out = try layouter.layout(
                title: cr.title,
                subtitle: cr.subtitle,
                titleStyleRaw: cr.titleStyle,
                subtitleStyleRaw: cr.subtitleStyle,
                highlights: cr.highlights,
                canvasSize: canvasSize,
                reservedHeight: captionReservedH,
                blockWidth: blockWidth,
                spacing: spacing
            )
            for w in out.warnings { warnings.append("[\(slideName)] \(w.message)") }

            // Caption sits under the logo reservation, centered vertically in
            // its reserved band. `topLeft` is in bottom-left coord system.
            let captionTopInset = logoReservedH
            let captionBandTop = canvasSize.height - captionTopInset
            let captionBandBottom = canvasSize.height - captionTopInset - captionReservedH
            let textCenteredY = (captionBandTop + captionBandBottom) / 2
            let topLeftY = textCenteredY - out.measuredHeight / 2

            out.drawable.draw(into: ctx, topLeft: CGPoint(x: padding, y: topLeftY))
        } else {
            captionReservedH = 0
        }

        // --- Layer 5: chrome + screenshot ---
        let chromeConfig = RenderResolver.resolvedChrome(config: config, slideName: slideName)
        let chromeRenderer = ChromeRenderer(bezelStore: bezelStore)
        let reservedTop = logoReservedH + captionReservedH
        let chromeRect = CGRect(
            x: 0,
            y: 0,
            width: canvasSize.width,
            height: canvasSize.height - reservedTop
        )
        try chromeRenderer.drawChrome(
            chromeConfig,
            screenshotURL: sourceURL,
            productFamily: productFamily,
            orientation: orientation,
            screenshotPixelSize: screenshotPixelSize,
            into: ctx,
            chromeRect: chromeRect
        )

        // --- Write output PNG ---
        guard let cgOut = ctx.makeImage() else {
            throw NSError(domain: "RenderPipeline", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "context.makeImage failed"])
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "RenderPipeline", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "cannot create PNG writer"])
        }
        CGImageDestinationAddImage(dest, cgOut, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "RenderPipeline", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "PNG finalize failed"])
        }

        return warnings
    }

    // MARK: - Helpers

    /// Maps the manifest's `deviceType` display string back to a product
    /// family int (1=iPhone, 2=iPad, 4=Watch, 6=Mac). Uses prefix sniff since
    /// display strings like "iPhone 6.9\"" are produced by AppStoreScreenSize.
    package static func productFamilyFromDeviceType(_ deviceType: String) -> Int {
        if deviceType.hasPrefix("iPhone") { return 1 }
        if deviceType.hasPrefix("iPad") { return 2 }
        if deviceType.hasPrefix("Apple Watch") || deviceType.hasPrefix("Watch") { return 4 }
        if deviceType.hasPrefix("Mac") { return 6 }
        return 0
    }

    private func productFamilyFromDeviceType(_ deviceType: String) -> Int {
        Self.productFamilyFromDeviceType(deviceType)
    }
}
