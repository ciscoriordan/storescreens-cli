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
    /// matching the capture-time filter behavior - a single list is the
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
                        appearance: shot.appearance ?? device.appearance ?? "light",
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
        //
        // The caption is laid out before the chrome anchor is finalized
        // so the band can grow when locked-font configs naturally exceed
        // `min_height_pct`. Earlier versions ellipsized those captions.
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
        let chromeConfig = RenderResolver.resolvedChrome(config: config, slideName: slideName)

        // Caption text band floor. Two paths:
        //   1. `chrome.device_height_pct` is set → device size is canonical.
        //      Caption band absorbs whatever space remains after the
        //      overlay bands take their cut, ignoring `min_height_pct`.
        //      This guarantees uniform device size across slides.
        //   2. Default → `caption.min_height_pct` floors the band; the
        //      actual band may grow if the caption's natural height
        //      exceeds the floor (locked font + long string).
        let initialCaptionTextH: CGFloat = {
            if let dhp = chromeConfig?.deviceHeightPct {
                let availableForBands = canvasSize.height * (100 - CGFloat(dhp)) / 100.0
                let leftover = availableForBands - aboveTitleBandH - middleSlotH - belowSubtitleBandH
                if leftover < 0 {
                    warnings.append("[\(slideName)] chrome.device_height_pct (\(dhp)%) leaves no room for caption - overlay bands (~\(Int((aboveTitleBandH + middleSlotH + belowSubtitleBandH) / canvasSize.height * 100))%) already exceed the available space (~\(Int((100 - dhp)))%)")
                }
                return max(0, leftover)
            }
            guard hasCaption, let cr = captionResolved else { return 0 }
            let minHeightPct = CGFloat(cr.minHeightPct ?? 22)
            return canvasSize.height * minHeightPct / 100.0
        }()
        // When middle-slot items exist without a caption, the slot still
        // gets its own band sized by `middleSlotH`. When the caption is
        // present, the slot lives inside the caption band.
        let initialCaptionBandH = initialCaptionTextH + middleSlotH

        // --- Caption layout (pre-draw measurement) ----------------------------
        //
        // We measure the caption before finalizing the chrome anchor so the
        // band can grow if the natural layout exceeds the floor. When
        // `chrome.device_height_pct` is set the band size is canonical and
        // we never grow it (the user opted into a fixed device size); the
        // CaptionLayouter will still emit a warning if its natural height
        // overflows.
        let captionPaddingPct = CGFloat(captionResolved?.paddingPct ?? 4)
        let captionSpacingPct = CGFloat(captionResolved?.spacingPct ?? 1.2)
        let captionPadding = canvasSize.width * captionPaddingPct / 100.0
        let captionSpacing = canvasSize.height * captionSpacingPct / 100.0
        let captionBlockWidth = canvasSize.width - 2 * captionPadding

        var captionLayout: CaptionLayouter.Output? = nil
        if hasCaption, let cr = captionResolved {
            let layouter = CaptionLayouter(resolver: fontResolver)
            let out = try layouter.layout(
                title: cr.title,
                subtitle: cr.subtitle,
                titleStyleRaw: cr.titleStyle,
                subtitleStyleRaw: cr.subtitleStyle,
                highlights: cr.highlights,
                canvasSize: canvasSize,
                reservedHeight: initialCaptionBandH,
                blockWidth: captionBlockWidth,
                spacing: captionSpacing,
                middleSlotHeight: middleSlotH
            )
            for w in out.warnings { warnings.append("[\(slideName)] \(w.message)") }
            captionLayout = out
        }

        // Grow the band only when the user hasn't opted into a fixed device
        // height. With `device_height_pct` set the device is canonical and
        // any extra caption content stays clipped within the configured
        // band; without it, locked-font captions naturally extend the band
        // and push the device down.
        let captionBandH: CGFloat = {
            guard chromeConfig?.deviceHeightPct == nil else {
                return initialCaptionBandH
            }
            guard let out = captionLayout else { return initialCaptionBandH }
            return max(initialCaptionBandH, out.measuredHeight)
        }()

        let reservedTop = aboveTitleBandH + captionBandH + belowSubtitleBandH
        let chromePaddingPct = CGFloat(chromeConfig?.paddingPct ?? 4)
        // Top of the chrome rect (the band where the bezel + screenshot
        // get drawn). Caption + overlays sit above this y. With
        // `device_height_pct` set this equals canvas * (100 - dhp)/100; with
        // `top_pct` it equals the pinned y; otherwise it's the natural
        // stack-up.
        let chromeRectTopY: CGFloat = {
            if let dhp = chromeConfig?.deviceHeightPct {
                return canvasSize.height * (100 - CGFloat(dhp)) / 100.0
            }
            if let topPct = chromeConfig?.topPct {
                let pinned = canvasSize.height * CGFloat(topPct) / 100.0
                if pinned < reservedTop {
                    warnings.append("[\(slideName)] chrome.top_pct (\(topPct)%) is above the natural top of the bands (~\(Int(reservedTop / canvasSize.height * 100))% of canvas) - overlays/caption may overflow the device anchor")
                }
                return pinned
            }
            return reservedTop
        }()
        // Padding inset shrinks the bezel away from chromeRect's top edge.
        // Use chromeRectTopY (not reservedTop) so that when device_height_pct or
        // top_pct overrides the natural stack-up, the inset and chromeRect height
        // both honour the anchor instead of the bands' natural extent.
        let chromeInsetDy = (canvasSize.height - chromeRectTopY) * chromePaddingPct / 100.0
        // Visual device top: where the bezel is *actually drawn* after the
        // `chrome.padding_pct` inset (default 4%) shrinks the bezel away from
        // the chromeRect top edge. Caption centering must target this y, not
        // the bare chromeRect top - otherwise short captions float above the
        // bezel with a fat gap below them. Cached as `deviceTopY` so the
        // existing layout / centering names keep their meaning.
        let deviceTopY = chromeRectTopY + chromeInsetDy

        // --- Caption block position (still no draws yet) ---------------------
        //
        // We compute `captionTopLeft` and the caption's BL bounds here so
        // the above_title overlay can anchor to the caption block top
        // instead of the canvas top, so image and caption read as a single
        // visual unit instead of the image floating up at the canvas edge.
        let captionBandTopBL = canvasSize.height - aboveTitleBandH
        let captionBandBottomBL = captionBandTopBL - captionBandH

        var captionTopLeft: CGPoint = .zero
        var captionBlockTopBL: CGFloat = captionBandTopBL
        var captionBlockBottomBL: CGFloat = captionBandTopBL
        if let out = captionLayout, let cr = captionResolved {
            let verticalAlign = cr.verticalAlign ?? .center
            let blockBottomY: CGFloat = {
                switch verticalAlign {
                case .top:
                    return captionBandTopBL - out.measuredHeight
                case .center:
                    // Center the block between the top of the caption area
                    // (canvas top, or logo band's bottom edge if an
                    // above_title overlay is present) and the next physical
                    // boundary below the caption - either the top of the
                    // below_subtitle overlay band, or, when no such overlay
                    // exists, the visible top of the device. Including the
                    // chrome inset in the centering range when no overlay
                    // sits between caption and device produces visually
                    // balanced gaps above and below the caption regardless
                    // of how much slack `min_height_pct` reserves.
                    let topAnchorBL = captionBandTopBL
                    let bottomAnchorBL: CGFloat
                    if belowSubtitleBandH > 0 {
                        bottomAnchorBL = captionBandBottomBL
                    } else {
                        bottomAnchorBL = canvasSize.height - deviceTopY
                    }
                    let mid = (topAnchorBL + bottomAnchorBL) / 2
                    return mid - out.measuredHeight / 2
                case .bottom:
                    return captionBandBottomBL
                }
            }()

            // Nudge: x positive = right, y positive = up (toward screen top).
            let nudgeX = CGFloat(cr.nudge?.xPct ?? 0) * canvasSize.width / 100.0
            let nudgeY = CGFloat(cr.nudge?.yPct ?? 0) * canvasSize.height / 100.0
            captionTopLeft = CGPoint(x: captionPadding + nudgeX, y: blockBottomY + nudgeY)
            captionBlockBottomBL = captionTopLeft.y
            captionBlockTopBL = captionBlockBottomBL + out.measuredHeight
        }

        // --- Equal-spacing override ------------------------------------------
        //
        // When `caption.equal_spacing` is on and the slide has both an
        // above_title logo image and a caption, make the three vertical gaps
        // identical: canvas top -> logo, logo -> caption, and caption ->
        // device top. The two default centerings (logo centered in a tall
        // above_title slot, caption centered in its own band) otherwise leave
        // the caption -> device gap visibly fatter than the other two.
        //
        // The device stays exactly where it naturally lands; we solve for one
        // uniform gap S from the leftover space after the logo and caption
        // VISIBLE heights are removed, then place the logo and caption against
        // that grid.
        //
        // GAPS ARE VISUAL, NOT GEOMETRIC. Three boxes-vs-ink mismatches would
        // unbalance naive box math, so each boundary is measured to its
        // visible (bright) edge:
        //   - LOGO: its drawn box (the `max_height_pct` band) is taller than
        //     the wordmark's glyph ink, and `drawSlot` centers the box, so
        //     pinning the box leaves the wordmark floating. We measure the
        //     wordmark's composited bright extent (`aboveTitleImageMetrics`)
        //     and place that, not the box.
        //   - CAPTION: a Core Text line box carries ascent slack above the
        //     cap height and descent slack below the baseline. We measure the
        //     caption's composited bright extent (`Drawable.inkExtent`) and
        //     anchor the gaps to it, shifting the draw position up by the
        //     box-top -> ink-top slack.
        //   - DEVICE: against the dark background the eye reads the device
        //     from its first bright pixel - the SCREEN content, not the
        //     bezel's dark frame top. We anchor the bottom gap to the screen
        //     top (`ChromeRenderer.screenContentTopBL`), falling back to the
        //     frame top (`deviceTopY`) for frame-less chrome (none/stroke).
        //
        // The logo's own `nudge` is NEUTRALIZED for the above_title draw in
        // this mode (equal_spacing fully owns the logo's vertical position; a
        // leftover nudge would re-skew the very gaps we are equalizing).
        // `caption.nudge` still applies on top so users can fine-tune, and the
        // caption x (incl. nudge.x) is left untouched. The device is never
        // moved.
        var equalSpacingAboveRect: CGRect? = nil
        var equalSpacingStripLogoNudge = false
        if captionResolved?.equalSpacing == true,
           hasCaption,
           let out = captionLayout,
           let cr = captionResolved,
           aboveTitleBandH > 0,
           let logoMetrics = overlayPlacer.aboveTitleImageMetrics(
               images: images, laurels: laurels, tables: tables,
               appearance: appearance, canvasSize: canvasSize, isFirstInCombo: isFirstInCombo
           ) {
            // Device bottom anchor: the screen content top (first bright pixel)
            // for bezel/device chrome, else the frame top deviceTopY. chromeRect
            // is the same rect Layer 6 will pass to the renderer.
            let chromeRectForAnchor = CGRect(
                x: 0, y: 0,
                width: canvasSize.width,
                height: canvasSize.height - chromeRectTopY
            )
            let screenTopBL = ChromeRenderer(bezelStore: bezelStore).screenContentTopBL(
                config: chromeConfig,
                productFamily: productFamily,
                orientation: orientation,
                screenshotPixelSize: screenshotPixelSize,
                chromeRect: chromeRectForAnchor
            )
            // deviceTopY is already a top-origin distance; convert the BL
            // screen top to the same top-origin frame.
            let deviceAnchorFromTop = screenTopBL.map { canvasSize.height - $0 } ?? deviceTopY

            // Visible heights: wordmark bright extent, caption bright extent.
            let hLogo = logoMetrics.inkHeight
            let capInk = out.drawable.inkExtent(measuredHeight: out.measuredHeight)
            let capInkTop = capInk?.top ?? 0          // box top -> first bright row
            let hCaption = capInk?.height ?? out.measuredHeight

            // Single uniform gap, top-origin pixels, from the VISIBLE heights.
            let s = (deviceAnchorFromTop - hLogo - hCaption) / 3.0
            if s < 0 {
                warnings.append("[\(slideName)] caption.equal_spacing: not enough room - logo ink (\(Int(hLogo))px) + caption ink (\(Int(hCaption))px) leave no space above the device; falling back to default placement")
            } else {
                // LOGO: size the slot to the box so drawSlot's centering is a
                // no-op (box top == slot top), then place the box so the
                // wordmark's bright top lands at S. The bright glyphs begin
                // `inkTopOffset` below the box top, so the box top sits at
                // S - inkTopOffset (top origin). In BL the slot bottom is
                // canvasTop - boxTopFromTop - box.
                let boxTopFromTop = s - logoMetrics.inkTopOffset
                equalSpacingAboveRect = CGRect(
                    x: 0,
                    y: canvasSize.height - boxTopFromTop - logoMetrics.box,
                    width: canvasSize.width,
                    height: logoMetrics.box
                )
                equalSpacingStripLogoNudge = true
                // CAPTION: put the caption's bright top at 2*S + H_logo from
                // the canvas top. The bright text begins `capInkTop` below the
                // box top, so the box top sits at (2*S + H_logo) - capInkTop.
                // captionTopLeft.y is the BL y of the box's BOTTOM. Re-apply
                // caption.nudge.y so fine-tuning still works.
                let nudgeY = CGFloat(cr.nudge?.yPct ?? 0) * canvasSize.height / 100.0
                let captionBoxTopFromTop = 2.0 * s + hLogo - capInkTop
                captionTopLeft.y = canvasSize.height - captionBoxTopFromTop - out.measuredHeight + nudgeY
                captionBlockBottomBL = captionTopLeft.y
                captionBlockTopBL = captionBlockBottomBL + out.measuredHeight
            }
        }

        // --- Layer 3: above_title overlays ---
        //
        // Slot semantics: when a caption is present, the slot extends from
        // the canvas top down to just above the caption block (separated
        // by `caption.spacing_pct`). The image is centered in this slot,
        // which gives roughly equal "canvas top -> image" and
        // "image -> caption" gaps automatically, so the user does not
        // need an `images[].nudge.y_pct` workaround. When `caption.nudge`
        // shifts the caption, the slot's bottom edge follows, so the
        // image moves with the caption as a single visual unit.
        //
        // When there's no caption text the slot collapses to the legacy
        // canvas-top band (sized to image height) so middle-slot-only
        // configs still behave the same.
        if aboveTitleBandH > 0 {
            let aboveRect: CGRect
            if let tightRect = equalSpacingAboveRect {
                // Equal-spacing: a tight band exactly bounding the logo at the
                // uniform gap S below the canvas top. `drawSlot` centers the
                // logo in this slot, so a slot of height H_logo lands it there.
                aboveRect = tightRect
            } else {
                let slotBottomBL: CGFloat
                let slotHeight: CGFloat
                if hasCaption {
                    let candidate = captionBlockTopBL + captionSpacing
                    let candidateHeight = canvasSize.height - candidate
                    if candidateHeight >= aboveTitleBandH {
                        slotBottomBL = candidate
                        slotHeight = candidateHeight
                    } else {
                        // Caption block already too tall to leave breathing
                        // room above; fall back to legacy canvas-top band so
                        // the image still fits.
                        slotBottomBL = canvasSize.height - aboveTitleBandH
                        slotHeight = aboveTitleBandH
                    }
                } else {
                    slotBottomBL = canvasSize.height - aboveTitleBandH
                    slotHeight = aboveTitleBandH
                }
                aboveRect = CGRect(
                    x: 0,
                    y: slotBottomBL,
                    width: canvasSize.width,
                    height: slotHeight
                )
            }
            // In equal-spacing mode the slot already encodes the wordmark's
            // exact position, so strip any per-image nudge from the
            // above_title images for this draw (a leftover nudge would shift
            // the wordmark off the equal-spacing grid). Other slots' images
            // are untouched.
            let aboveImages: [ImageConfig]
            if equalSpacingStripLogoNudge {
                aboveImages = images.map { cfg in
                    guard (cfg.position ?? .aboveTitle).canonicalSlot == .aboveTitle else { return cfg }
                    var copy = cfg
                    copy.nudge = nil
                    return copy
                }
            } else {
                aboveImages = images
            }
            let warns = overlayPlacer.drawSlot(
                position: .aboveTitle, images: aboveImages, laurels: laurels, tables: tables,
                appearance: appearance, slotRect: aboveRect,
                canvasSize: canvasSize, isFirstInCombo: isFirstInCombo,
                into: ctx
            )
            for w in warns { warnings.append("[\(slideName)] \(w)") }
        }

        // --- Layer 4: caption (with embedded middle-slot gap) ---
        var middleSlotRectBL: CGRect = .zero
        if let out = captionLayout {
            out.drawable.draw(into: ctx, topLeft: captionTopLeft)
            middleSlotRectBL = out.drawable.middleSlotRect(topLeft: captionTopLeft)
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
        //
        // Slot sits flush against the caption band's bottom (no gap).
        // chrome.padding_pct is the gap BEFORE the device, applied below
        // this slot (between slot bottom and device top), not BEFORE every
        // slot. Pre-2.7 we positioned the slot at `deviceTopBL` which let
        // chromeInsetDy slip in between caption and below_subtitle bands,
        // creating an unreachable phantom gap users could not close even
        // with min_height_pct floored and aggressive nudge.
        if belowSubtitleBandH > 0 {
            let slotTopBL = canvasSize.height - aboveTitleBandH - captionBandH
            let belowRect = CGRect(
                x: 0,
                y: slotTopBL - belowSubtitleBandH,
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
            height: canvasSize.height - chromeRectTopY
        )
        let chromeWarnings = try chromeRenderer.drawChrome(
            chromeConfig,
            screenshotURL: sourceURL,
            productFamily: productFamily,
            orientation: orientation,
            screenshotPixelSize: screenshotPixelSize,
            into: ctx,
            chromeRect: chromeRect
        )
        for w in chromeWarnings { warnings.append("[\(slideName)] \(w)") }

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
