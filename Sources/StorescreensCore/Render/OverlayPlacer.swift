import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// Places `ImageConfig` and `LaurelConfig` overlays into one of three caption
/// slots: `above_title`, `below_title` (alias `above_subtitle`), and
/// `below_subtitle`. The pipeline calls `reservedHeight` once per slot to
/// build its layout spine, then `drawSlot` once per slot to render.
///
/// Per slot, items are filtered by canonical position, capped at 2, and
/// stacked horizontally inside the slot rect:
///   - same `align` for both items: stacked as a group, then aligned together
///   - different `align`: each placed independently (may overlap if too wide)
/// Vertical placement centers each item inside `slotRect`. Nudges are applied
/// in canvas-percent units, x positive = right, y positive = up.
package struct OverlayPlacer: @unchecked Sendable {

    package let baseDirectory: URL
    package let fontResolver: FontResolver

    package init(baseDirectory: URL, fontResolver: FontResolver) {
        self.baseDirectory = baseDirectory
        self.fontResolver = fontResolver
    }

    // MARK: - Public API

    /// Pixel height the slot at `position` will reserve for its tallest item.
    /// Returns 0 when nothing is drawn (no items, all skipped, etc.).
    package func reservedHeight(
        position: OverlayPosition,
        images: [ImageConfig],
        laurels: [LaurelConfig],
        appearance: String,
        canvasSize: CGSize,
        isFirstInCombo: Bool
    ) -> CGFloat {
        let items = collectItems(
            position: position,
            images: images,
            laurels: laurels,
            isFirstInCombo: isFirstInCombo
        ).items

        var maxH: CGFloat = 0
        for item in items {
            switch item {
            case .image(let cfg):
                guard cfg.path?.value(for: appearance) != nil else { continue }
                let pct = CGFloat(cfg.maxHeightPct ?? 8)
                maxH = max(maxH, canvasSize.height * pct / 100.0)
            case .laurel(let cfg):
                let pct = CGFloat(cfg.maxHeightPct ?? 10)
                maxH = max(maxH, canvasSize.height * pct / 100.0)
            }
        }
        return maxH
    }

    /// Renders all items belonging to `position` into `slotRect`. `slotRect`
    /// is in bottom-left CG coordinates. Returns warnings for the caller.
    package func drawSlot(
        position: OverlayPosition,
        images: [ImageConfig],
        laurels: [LaurelConfig],
        appearance: String,
        slotRect: CGRect,
        canvasSize: CGSize,
        isFirstInCombo: Bool,
        into ctx: CGContext
    ) -> [String] {
        let collected = collectItems(
            position: position,
            images: images,
            laurels: laurels,
            isFirstInCombo: isFirstInCombo
        )
        var warnings = collected.warnings
        if collected.items.isEmpty { return warnings }

        // Measure each item once so we know its on-canvas size.
        var measured: [MeasuredItem] = []
        for item in collected.items {
            switch item {
            case .image(let cfg):
                guard let path = cfg.path?.value(for: appearance),
                      let cg = loadImage(path: path) else {
                    warnings.append("image overlay path missing or unloadable; skipping")
                    continue
                }
                let h = canvasSize.height * CGFloat(cfg.maxHeightPct ?? 8) / 100.0
                let aspect = CGFloat(cg.width) / CGFloat(cg.height)
                let w = min(h * aspect, canvasSize.width)
                measured.append(MeasuredItem(
                    kind: .image(cg),
                    align: cfg.align ?? .center,
                    nudgeXPct: cfg.nudge?.xPct ?? 0,
                    nudgeYPct: cfg.nudge?.yPct ?? 0,
                    width: w,
                    height: h
                ))
            case .laurel(let cfg):
                guard let m = measureLaurel(cfg: cfg, appearance: appearance, canvasSize: canvasSize) else {
                    warnings.append("laurel SVGs missing from bundle; skipping laurel overlay")
                    continue
                }
                measured.append(m)
            }
        }
        if measured.isEmpty { return warnings }

        // Two-item slots auto-distribute with equal whitespace: the gaps
        // canvas_left -> item1, between item1 and item2, and item2 ->
        // canvas_right are all the same. With identical-sized items their
        // centers land symmetrically; with different sizes the larger item's
        // center sits closer to its outer edge.
        //
        // Earlier versions placed item centers at canvas * 1/3 and 2/3, which
        // collapsed to overlap once each item's width approached canvas / 3
        // (typical for wide laurels). Equal-whitespace placement guarantees
        // items never overlap as long as they fit on the canvas.
        //
        // When items are wider than the canvas, abut them at the midline and
        // warn so the user knows to drop max_height_pct.
        if measured.count == 2 {
            let item1 = measured[0]
            let item2 = measured[1]
            let totalItemWidth = item1.width + item2.width
            let totalGap = canvasSize.width - totalItemWidth
            let gap = totalGap / 3.0

            let item1XBase: CGFloat
            let item2XBase: CGFloat
            if gap < 0 {
                warnings.append(
                    "two-item slot: combined width (\(Int(totalItemWidth))px) exceeds canvas (\(Int(canvasSize.width))px); clamping items to abut at the midline. Lower max_height_pct to fix."
                )
                let mid = canvasSize.width / 2
                item1XBase = mid - item1.width
                item2XBase = mid
            } else {
                item1XBase = gap
                item2XBase = canvasSize.width - gap - item2.width
            }

            let nudgeX1 = CGFloat(item1.nudgeXPct) * canvasSize.width / 100.0
            let nudgeY1 = CGFloat(item1.nudgeYPct) * canvasSize.height / 100.0
            let nudgeX2 = CGFloat(item2.nudgeXPct) * canvasSize.width / 100.0
            let nudgeY2 = CGFloat(item2.nudgeYPct) * canvasSize.height / 100.0
            let yBottom1 = slotRect.minY + (slotRect.height - item1.height) / 2 + nudgeY1
            let yBottom2 = slotRect.minY + (slotRect.height - item2.height) / 2 + nudgeY2

            drawItem(item1, in: CGRect(x: item1XBase + nudgeX1, y: yBottom1,
                                       width: item1.width, height: item1.height), into: ctx)
            drawItem(item2, in: CGRect(x: item2XBase + nudgeX2, y: yBottom2,
                                       width: item2.width, height: item2.height), into: ctx)
            return warnings
        }

        // Single item: place at its `align` (or center by default), centered
        // vertically in slotRect, with nudge applied last.
        let item = measured[0]
        let nudgeX = CGFloat(item.nudgeXPct) * canvasSize.width / 100.0
        let nudgeY = CGFloat(item.nudgeYPct) * canvasSize.height / 100.0
        let xLeft: CGFloat
        switch item.align {
        case .left:   xLeft = slotRect.minX + nudgeX
        case .center: xLeft = slotRect.minX + (slotRect.width - item.width) / 2 + nudgeX
        case .right:  xLeft = slotRect.maxX - item.width + nudgeX
        }
        let yBottom = slotRect.minY + (slotRect.height - item.height) / 2 + nudgeY
        let drawRect = CGRect(x: xLeft, y: yBottom, width: item.width, height: item.height)
        drawItem(item, in: drawRect, into: ctx)

        return warnings
    }

    // MARK: - Item collection

    private enum OverlayItem {
        case image(ImageConfig)
        case laurel(LaurelConfig)
    }

    private struct CollectedItems {
        let items: [OverlayItem]
        let warnings: [String]
    }

    /// Filter images + laurels down to the set that belongs in `position`,
    /// after applying default position, default placement, and the 2-item cap.
    private func collectItems(
        position: OverlayPosition,
        images: [ImageConfig],
        laurels: [LaurelConfig],
        isFirstInCombo: Bool
    ) -> CollectedItems {
        let target = position.canonicalSlot
        var warnings: [String] = []

        // Images: default position is .aboveTitle.
        let imageMatches: [ImageConfig] = images.filter { cfg in
            (cfg.position ?? .aboveTitle).canonicalSlot == target
        }.filter { cfg in
            shouldDrawImage(cfg, isFirstInCombo: isFirstInCombo)
        }

        // Laurels: default position is .belowSubtitle.
        let laurelMatches: [LaurelConfig] = laurels.filter { cfg in
            (cfg.position ?? .belowSubtitle).canonicalSlot == target
        }.filter { cfg in
            shouldDrawLaurel(cfg, isFirstInCombo: isFirstInCombo)
        }

        // Preserve config order (images first, then laurels) for stable stacking.
        var combined: [OverlayItem] = imageMatches.map { .image($0) } + laurelMatches.map { .laurel($0) }

        if combined.count > 2 {
            warnings.append("more than 2 overlays at \(target.rawValue); dropping extras")
            combined = Array(combined.prefix(2))
        }

        return CollectedItems(items: combined, warnings: warnings)
    }

    private func shouldDrawImage(_ cfg: ImageConfig, isFirstInCombo: Bool) -> Bool {
        let defaultPlacement: OverlayPlacement =
            (cfg.position ?? .aboveTitle).canonicalSlot == .aboveTitle ? .firstOnly : .all
        switch cfg.placement ?? defaultPlacement {
        case .firstOnly: return isFirstInCombo
        case .all:       return true
        case .none:      return false
        }
    }

    private func shouldDrawLaurel(_ cfg: LaurelConfig, isFirstInCombo: Bool) -> Bool {
        switch cfg.placement ?? .all {
        case .firstOnly: return isFirstInCombo
        case .all:       return true
        case .none:      return false
        }
    }

    // MARK: - Measured item model

    private enum MeasuredKind {
        case image(CGImage)
        case laurel(LaurelArtifacts)
    }

    private struct LaurelArtifacts {
        let leftCG: CGImage
        let rightCG: CGImage
        let titleFramesetter: AttributedFramesetter?
        let subtitleFramesetter: AttributedFramesetter?
        let titleSize: CGSize
        let subtitleSize: CGSize
        let textRegionWidth: CGFloat
        let laurelWidth: CGFloat
        let horizontalPad: CGFloat
        let textSpacing: CGFloat
        let tintColor: NSColor
        /// How far each half nudges toward (positive) or away from (negative)
        /// the text, in pixels. The text region stays anchored at the un-inset
        /// position so the laurels can encroach on text edges as the user
        /// dials this up.
        let inset: CGFloat
    }

    private struct MeasuredItem {
        let kind: MeasuredKind
        let align: CaptionAlign
        let nudgeXPct: Double
        let nudgeYPct: Double
        let width: CGFloat
        let height: CGFloat
    }

    // MARK: - Drawing dispatch

    private func drawItem(_ item: MeasuredItem, in rect: CGRect, into ctx: CGContext) {
        switch item.kind {
        case .image(let cg):
            ctx.draw(cg, in: rect)
        case .laurel(let art):
            drawLaurel(art, in: rect, into: ctx)
        }
    }

    // MARK: - Image loading (mirrors LogoPlacer)

    private func loadImage(path: String) -> CGImage? {
        let url = resolveURL(path)
        if let ns = NSImage(contentsOf: url) {
            var rect = NSRect(x: 0, y: 0, width: ns.size.width, height: ns.size.height)
            if let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return cg
            }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        return img
    }

    private func resolveURL(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: path, relativeTo: baseDirectory).standardized
    }

    // MARK: - Laurel measurement

    /// SVG aspect: width 420, height 802, so each laurel renders at
    /// `blockHeight * (420/802)` wide.
    private static let laurelAspect: CGFloat = 420.0 / 802.0

    private func measureLaurel(
        cfg: LaurelConfig,
        appearance: String,
        canvasSize: CGSize
    ) -> MeasuredItem? {
        let blockHeight = canvasSize.height * CGFloat(cfg.maxHeightPct ?? 10) / 100.0
        let laurelW = blockHeight * Self.laurelAspect
        let horizontalPad = blockHeight * 0.05
        let textSpacing = blockHeight * 0.04

        // Tint color (default white).
        let tintHex = cfg.color?.value(for: appearance)
        let tint: NSColor = tintHex.flatMap(RenderColors.parseHex) ?? .white

        // Build attributed strings for title + subtitle. By default, title and
        // subtitle share a single auto-derived font size so two-line laurels
        // read as balanced typography rather than headline + footnote. The
        // weight defaults still differ (title bold, subtitle regular) to
        // preserve visual hierarchy. Explicit `font_size_pct` overrides on
        // either side are treated as percent of canvas height (matches the
        // CaptionRole convention everywhere else) and break the link.
        let titleColor = cfg.titleStyle?.color.flatMap(RenderColors.parseHex) ?? tint
        let subtitleColor = cfg.subtitleStyle?.color.flatMap(RenderColors.parseHex) ?? tint

        // 0.27 of block height gives two lines plus spacing room for ~31%
        // breathing space inside the block, scaling cleanly with max_height_pct.
        let autoPt = blockHeight * 0.27
        let titlePt: CGFloat = cfg.titleStyle?.fontSizePct.map {
            canvasSize.height * CGFloat($0) / 100.0
        } ?? autoPt
        let subtitlePt: CGFloat = cfg.subtitleStyle?.fontSizePct.map {
            canvasSize.height * CGFloat($0) / 100.0
        } ?? autoPt

        let titleStyle = ResolvedRoleStyle(
            font: cfg.titleStyle?.font ?? .system,
            weight: cfg.titleStyle?.weight ?? .bold,
            italic: cfg.titleStyle?.italic ?? false,
            fontSize: titlePt,
            color: titleColor,
            align: cfg.titleStyle?.align ?? .center
        )
        let subtitleStyle = ResolvedRoleStyle(
            font: cfg.subtitleStyle?.font ?? .system,
            weight: cfg.subtitleStyle?.weight ?? .regular,
            italic: cfg.subtitleStyle?.italic ?? false,
            fontSize: subtitlePt,
            color: subtitleColor,
            align: cfg.subtitleStyle?.align ?? .center
        )

        let titleAttr = cfg.title.flatMap { text -> NSAttributedString? in
            let joined = text.lines.joined(separator: "\n")
            return try? MarkdownAttributor.buildAttributed(
                plainOrMarkdown: joined, role: titleStyle, resolver: fontResolver
            )
        }
        let subtitleAttr = cfg.subtitle.flatMap { text -> NSAttributedString? in
            let joined = text.lines.joined(separator: "\n")
            return try? MarkdownAttributor.buildAttributed(
                plainOrMarkdown: joined, role: subtitleStyle, resolver: fontResolver
            )
        }

        // Measure at near-infinite width; the text region grows to fit content.
        let bigBox = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let titleFS = titleAttr.map { AttributedFramesetter(attributed: $0) }
        let subtitleFS = subtitleAttr.map { AttributedFramesetter(attributed: $0) }
        let titleSize = titleFS?.suggestedSize(constrainedTo: bigBox) ?? .zero
        let subtitleSize = subtitleFS?.suggestedSize(constrainedTo: bigBox) ?? .zero

        let textRegionWidth = max(titleSize.width, subtitleSize.width)
        let totalWidth = laurelW + horizontalPad + textRegionWidth + horizontalPad + laurelW

        // Load laurel SVGs from the bundle, rendered at `blockHeight` tall.
        guard let leftCG = loadLaurelImage("laurel-left", height: blockHeight),
              let rightCG = loadLaurelImage("laurel-right", height: blockHeight) else {
            return nil
        }

        // Default inset of 4% of block height gives a slightly tighter badge
        // without bleeding into the text at typical max_height_pct values.
        // Users can dial up (overlap) or down (extra breathing room).
        let inset = blockHeight * CGFloat(cfg.insetPct ?? 4) / 100.0

        let art = LaurelArtifacts(
            leftCG: leftCG,
            rightCG: rightCG,
            titleFramesetter: titleFS,
            subtitleFramesetter: subtitleFS,
            titleSize: titleSize,
            subtitleSize: subtitleSize,
            textRegionWidth: textRegionWidth,
            laurelWidth: laurelW,
            horizontalPad: horizontalPad,
            textSpacing: textSpacing,
            tintColor: tint,
            inset: inset
        )

        return MeasuredItem(
            kind: .laurel(art),
            align: cfg.align ?? .center,
            nudgeXPct: cfg.nudge?.xPct ?? 0,
            nudgeYPct: cfg.nudge?.yPct ?? 0,
            width: totalWidth,
            height: blockHeight
        )
    }

    // MARK: - Laurel drawing

    private func drawLaurel(_ art: LaurelArtifacts, in rect: CGRect, into ctx: CGContext) {
        // The laurel halves are nudged toward (positive inset) or away from
        // (negative inset) the text. The text region is computed from the
        // un-inset positions so it stays put when the user dials inset; the
        // laurels then encroach on its edges (or pull away) without forcing a
        // re-layout. The bow shape leaves enough open space between leaves
        // that modest overlap usually reads cleanly.
        let leftRect = CGRect(x: rect.minX + art.inset, y: rect.minY,
                              width: art.laurelWidth, height: rect.height)
        let rightRect = CGRect(x: rect.maxX - art.laurelWidth - art.inset, y: rect.minY,
                               width: art.laurelWidth, height: rect.height)

        tintMask(art.leftCG, in: leftRect, color: art.tintColor, into: ctx)
        tintMask(art.rightCG, in: rightRect, color: art.tintColor, into: ctx)

        // Text region: between the original (un-inset) laurel inner edges.
        let textLeft = rect.minX + art.laurelWidth + art.horizontalPad
        let textRight = rect.maxX - art.laurelWidth - art.horizontalPad
        let textRegionRect = CGRect(
            x: textLeft, y: rect.minY,
            width: max(0, textRight - textLeft),
            height: rect.height
        )

        let titleH = art.titleSize.height
        let subtitleH = art.subtitleSize.height
        let gap = subtitleH > 0 ? art.textSpacing : 0
        let stackH = titleH + gap + subtitleH

        // Vertically center the title+subtitle stack inside the text region.
        let stackBottom = textRegionRect.minY + (textRegionRect.height - stackH) / 2

        if let fs = art.titleFramesetter, titleH > 0 {
            let w = min(art.titleSize.width, textRegionRect.width)
            let x = textRegionRect.minX + (textRegionRect.width - w) / 2
            let y = stackBottom + subtitleH + gap
            fs.draw(in: ctx, rect: CGRect(x: x, y: y, width: w, height: titleH))
        }

        if let fs = art.subtitleFramesetter, subtitleH > 0 {
            let w = min(art.subtitleSize.width, textRegionRect.width)
            let x = textRegionRect.minX + (textRegionRect.width - w) / 2
            let y = stackBottom
            fs.draw(in: ctx, rect: CGRect(x: x, y: y, width: w, height: subtitleH))
        }
    }

    /// Clip the context to the alpha mask of `mask` over `rect`, then fill
    /// `rect` with `color`. Result: the SVG silhouette tinted to `color`.
    private func tintMask(_ mask: CGImage, in rect: CGRect, color: NSColor, into ctx: CGContext) {
        ctx.saveGState()
        // CG's clip(to:mask:) treats darker mask values as opaque, lighter as
        // transparent, but for an alpha-channel image the alpha is already
        // what we want, so we pass the image directly.
        ctx.clip(to: rect, mask: mask)
        let rgb = color.usingColorSpace(.sRGB) ?? color
        ctx.setFillColor(red: rgb.redComponent,
                         green: rgb.greenComponent,
                         blue: rgb.blueComponent,
                         alpha: rgb.alphaComponent)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    /// Rasterizes one of the bundled laurel SVGs (now embedded as a string
    /// constant in `LaurelAssets`) to a transparent CGImage of the given
    /// height. Width preserves the SVG's 420:802 aspect.
    ///
    /// The SVG was previously read from `Bundle.module`. Homebrew installs
    /// did not symlink the resource bundle directory next to the binary,
    /// which crashed laurel rendering at runtime, so the bytes now live
    /// inside the binary itself.
    private func loadLaurelImage(_ name: String, height: CGFloat) -> CGImage? {
        let width = height * Self.laurelAspect
        let svgString: String
        switch name {
        case "laurel-left":  svgString = LaurelAssets.leftSVG
        case "laurel-right": svgString = LaurelAssets.rightSVG
        default: return nil
        }
        guard let data = svgString.data(using: .utf8),
              let ns = NSImage(data: data) else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bmp = CGContext(
            data: nil,
            width: Int(ceil(width)),
            height: Int(ceil(height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bmp, flipped: false)
        ns.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero, operation: .copy, fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return bmp.makeImage()
    }
}
