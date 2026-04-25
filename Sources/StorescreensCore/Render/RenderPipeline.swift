import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Orchestrates the per-slide render for a whole `CaptureManifest`.
/// Layer stack per slide (bottom -> top):
///   1. Background (solid + image, light/dark variant)
///   2. Scrim (solid or gradient)
///   3. above_title overlay band (images / laurels at the top of the canvas)
///   4. Caption block (title + optional middle-slot overlays + subtitle)
///   5. below_subtitle overlay band (between caption and device)
///   6. Chrome + screenshot
package struct RenderPipeline {

    package let config: RenderConfig
    package let baseDirectory: URL
    package let bezelStore: BezelStore
    package let fontResolver: FontResolver

    /// Construction. `baseDirectory` is typically the directory containing
    /// the YML config; relative asset paths resolve against it.
    ///
    /// If `config.template` names a built-in template, its defaults are
    /// applied here once so every downstream resolve sees a fully-baked
    /// `RenderConfig`. Unknown template names are silently ignored
    /// (resolved warnings come back via `Output.warnings`).
    package init(
        config: RenderConfig,
        baseDirectory: URL,
        bezelStore: BezelStore? = nil,
        fontResolver: FontResolver? = nil
    ) {
        self.config = RenderResolver.applyTemplate(config)
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
    ///
    /// If `screenshotOrder` is non-nil, each device's screenshots are
    /// reordered so entries whose `name` appears in the list come first
    /// in list order; any extras not in the list keep their original
    /// manifest position at the end. This lets the top-level
    /// `screenshots:` config key drive render order (hero slide first,
    /// panoramic background left-edge pinned to the first entry,
    /// `logo.placement: first_only` landing where the user expects),
    /// matching the capture-time filter behavior — a single list is the
    /// canonical source for slide order across the whole pipeline.
    /// When nil, manifest order is preserved as before.
    package func render(
        manifest: CaptureManifest,
        capturedRoot: URL,
        renderRoot: URL,
        screenshotOrder: [String]? = nil
    ) async throws -> Output {
        let fm = FileManager.default
        try? fm.createDirectory(at: renderRoot, withIntermediateDirectories: true)

        var failures: [(String, String)] = []
        var warnings: [String] = []
        var renderedCount = 0

        for device in manifest.devices {
            let pf = productFamilyFromDeviceType(device.deviceType)
            let orderedScreenshots = Self.applyOrder(device.screenshots, order: screenshotOrder)
            let slidesInCombo = orderedScreenshots.count

            for (slideIndex, shot) in orderedScreenshots.enumerated() {
                do {
                    let sourceURL = capturedRoot.appendingPathComponent(shot.filename)
                    let outputURL = renderRoot.appendingPathComponent(shot.filename)

                    let slideWarnings = try await renderOne(
                        slideName: shot.name,
                        sourceURL: sourceURL,
                        outputURL: outputURL,
                        productFamily: pf,
                        appearance: device.appearance ?? "light",
                        locale: device.locale,
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

        // Stamp mtimes on the rendered PNGs so `ls -t` / Finder Date sort
        // matches the configured `screenshots:` order, the same way
        // OutputOrganizer does for the raw captured dir.
        OutputOrganizer().stampMtimes(
            manifest: manifest,
            outputDir: renderRoot.path,
            order: screenshotOrder
        )

        return Output(renderedSlides: renderedCount, failures: failures, warnings: warnings)
    }

    /// Reorder `shots` so entries whose `name` is in `order` come first,
    /// in the order specified; any shots not in the list keep their
    /// relative manifest order after the ordered prefix. When `order`
    /// is nil or empty the input is returned unchanged.
    ///
    /// Exposed for tests; not expected to be called directly by normal
    /// render clients (the public `render` method dispatches through it).
    package static func applyOrder(
        _ shots: [CaptureManifest.Screenshot],
        order: [String]?
    ) -> [CaptureManifest.Screenshot] {
        guard let order, !order.isEmpty else { return shots }
        var byName: [String: CaptureManifest.Screenshot] = [:]
        for s in shots { byName[s.name] = s }
        var ordered: [CaptureManifest.Screenshot] = []
        ordered.reserveCapacity(shots.count)
        var taken = Set<String>()
        for name in order where !taken.contains(name) {
            if let s = byName[name] {
                ordered.append(s)
                taken.insert(name)
            }
        }
        for s in shots where !taken.contains(s.name) {
            ordered.append(s)
        }
        return ordered
    }

    /// Renders a single slide. Creates a pixel-dim CGContext, walks the
    /// layer stack, and writes out a PNG.
    package func renderOne(
        slideName: String,
        sourceURL: URL,
        outputURL: URL,
        productFamily: Int,
        appearance: String,
        locale: String? = nil,
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

        // --- Pre-compute the layout spine -----------------------------------
        //
        // Three overlay bands wrap the caption: above_title at the top
        // of the canvas, a middle slot embedded in the caption block
        // (between title and subtitle), and below_subtitle between the
        // caption and the device. The caption's `min_height_pct` floor
        // grows by the middle-slot height so adding a slot does not
        // squeeze the text. Chrome inset is taken from the remaining
        // space so device top moves down predictably as the user adds
        // overlays.
        let overlayPlacer = OverlayPlacer(baseDirectory: baseDirectory, fontResolver: fontResolver)
        let images = RenderResolver.resolvedImages(config: config, slideName: slideName)
        let laurels = RenderResolver.resolvedLaurels(config: config, slideName: slideName)
        let tables = RenderResolver.resolvedTables(config: config, slideName: slideName)

        let aboveTitleBandH = overlayPlacer.reservedHeight(
            position: .aboveTitle, images: images, laurels: laurels, tables: tables,
            appearance: appearance, canvasSize: canvasSize, isFirstInCombo: isFirstInCombo
        )
        let middleSlotH = overlayPlacer.reservedHeight(
            position: .belowTitle, images: images, laurels: laurels, tables: tables,
            appearance: appearance, canvasSize: canvasSize, isFirstInCombo: isFirstInCombo
        )
        let belowSubtitleBandH = overlayPlacer.reservedHeight(
            position: .belowSubtitle, images: images, laurels: laurels, tables: tables,
            appearance: appearance, canvasSize: canvasSize, isFirstInCombo: isFirstInCombo
        )

        let captionResolved = RenderResolver.resolvedCaption(
            config: config, slideName: slideName, locale: locale
        )
        let hasCaption: Bool = {
            guard let cr = captionResolved else { return false }
            return cr.title != nil || cr.subtitle != nil
        }()
        let captionTextH: CGFloat = {
            guard hasCaption, let cr = captionResolved else { return 0 }
            let minHeightPct = CGFloat(cr.minHeightPct ?? 22)
            return canvasSize.height * minHeightPct / 100.0
        }()
        // When middle-slot items exist without a caption, the slot still
        // gets its own band sized by `middleSlotH`. When the caption is
        // present, the slot lives inside the caption band.
        let captionBandH = captionTextH + middleSlotH

        let reservedTop = aboveTitleBandH + captionBandH + belowSubtitleBandH
        let chromeConfig = RenderResolver.resolvedChrome(config: config, slideName: slideName)
        let chromePaddingPct = CGFloat(chromeConfig?.paddingPct ?? 4)
        let chromeInsetDy = (canvasSize.height - reservedTop) * chromePaddingPct / 100.0
        // Top of the visible device in screen coordinates (distance
        // from canvas top). In bottom-left CG coords this is
        // `canvasSize.height - deviceTopY`.
        let deviceTopY = reservedTop + chromeInsetDy
        let deviceTopBL = canvasSize.height - deviceTopY

        // --- Layer 3: above_title overlays ---
        if aboveTitleBandH > 0 {
            let aboveRect = CGRect(
                x: 0,
                y: canvasSize.height - aboveTitleBandH,
                width: canvasSize.width,
                height: aboveTitleBandH
            )
            let warns = overlayPlacer.drawSlot(
                position: .aboveTitle, images: images, laurels: laurels, tables: tables,
                appearance: appearance, slotRect: aboveRect,
                canvasSize: canvasSize, isFirstInCombo: isFirstInCombo,
                into: ctx
            )
            for w in warns { warnings.append("[\(slideName)] \(w)") }
        }

        // --- Layer 4: caption (with embedded middle-slot gap) ---
        var middleSlotRectBL: CGRect = .zero
        if hasCaption, let cr = captionResolved {
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
                reservedHeight: captionBandH,
                blockWidth: blockWidth,
                spacing: spacing,
                middleSlotHeight: middleSlotH
            )
            for w in out.warnings { warnings.append("[\(slideName)] \(w.message)") }

            // Band = [captionBandBottomBL, captionBandTopBL] in BL coords.
            // verticalAlign picks top / center (default) / bottom; nudge
            // shifts after that.
            let captionBandTopBL = canvasSize.height - aboveTitleBandH
            let captionBandBottomBL = captionBandTopBL - captionBandH

            let verticalAlign = cr.verticalAlign ?? .center
            let blockBottomY: CGFloat = {
                switch verticalAlign {
                case .top:
                    return captionBandTopBL - out.measuredHeight
                case .center:
                    let mid = (captionBandTopBL + captionBandBottomBL) / 2
                    return mid - out.measuredHeight / 2
                case .bottom:
                    return captionBandBottomBL
                }
            }()

            // Nudge: x positive = right, y positive = up (toward screen top).
            let nudgeX = CGFloat(cr.nudge?.xPct ?? 0) * canvasSize.width / 100.0
            let nudgeY = CGFloat(cr.nudge?.yPct ?? 0) * canvasSize.height / 100.0
            let topLeft = CGPoint(x: padding + nudgeX, y: blockBottomY + nudgeY)

            out.drawable.draw(into: ctx, topLeft: topLeft)
            middleSlotRectBL = out.drawable.middleSlotRect(topLeft: topLeft)
        } else if middleSlotH > 0 {
            // No caption text: the middle slot occupies its own band
            // between the above_title and below_subtitle bands.
            middleSlotRectBL = CGRect(
                x: 0,
                y: canvasSize.height - aboveTitleBandH - captionBandH,
                width: canvasSize.width,
                height: captionBandH
            )
        }

        // --- Layer 5: middle-slot overlays (between title and subtitle) ---
        if middleSlotRectBL.height > 0 {
            let warns = overlayPlacer.drawSlot(
                position: .belowTitle, images: images, laurels: laurels, tables: tables,
                appearance: appearance, slotRect: middleSlotRectBL,
                canvasSize: canvasSize, isFirstInCombo: isFirstInCombo,
                into: ctx
            )
            for w in warns { warnings.append("[\(slideName)] \(w)") }
        }

        // --- Layer 6: below_subtitle overlays ---
        if belowSubtitleBandH > 0 {
            let belowRect = CGRect(
                x: 0,
                y: deviceTopBL,
                width: canvasSize.width,
                height: belowSubtitleBandH
            )
            let warns = overlayPlacer.drawSlot(
                position: .belowSubtitle, images: images, laurels: laurels, tables: tables,
                appearance: appearance, slotRect: belowRect,
                canvasSize: canvasSize, isFirstInCombo: isFirstInCombo,
                into: ctx
            )
            for w in warns { warnings.append("[\(slideName)] \(w)") }
        }

        // --- Layer 5: chrome + screenshot ---
        let chromeRenderer = ChromeRenderer(bezelStore: bezelStore)
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
