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
        tables: [TableConfig] = [],
        appearance: String,
        canvasSize: CGSize,
        isFirstInCombo: Bool
    ) -> CGFloat {
        let items = collectItems(
            position: position,
            images: images,
            laurels: laurels,
            tables: tables,
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
            case .table(let cfg):
                let pct = CGFloat(cfg.maxHeightPct ?? 14)
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
        tables: [TableConfig] = [],
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
            tables: tables,
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
            case .table(let cfg):
                let m = measureTable(cfg: cfg, appearance: appearance, canvasSize: canvasSize)
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
        case table(TableConfig)
    }

    private struct CollectedItems {
        let items: [OverlayItem]
        let warnings: [String]
    }

    /// Filter images + laurels + tables down to the set that belongs in
    /// `position`, after applying default position, default placement, and
    /// the 2-item cap (across all overlay types).
    private func collectItems(
        position: OverlayPosition,
        images: [ImageConfig],
        laurels: [LaurelConfig],
        tables: [TableConfig],
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

        // Tables: default position is .belowSubtitle (sit under the caption,
        // alongside or instead of laurels).
        let tableMatches: [TableConfig] = tables.filter { cfg in
            (cfg.position ?? .belowSubtitle).canonicalSlot == target
        }.filter { cfg in
            shouldDrawTable(cfg, isFirstInCombo: isFirstInCombo)
        }

        // Preserve config order (images, then laurels, then tables) for
        // stable stacking when items share a slot.
        var combined: [OverlayItem] =
            imageMatches.map { .image($0) }
            + laurelMatches.map { .laurel($0) }
            + tableMatches.map { .table($0) }

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

    private func shouldDrawTable(_ cfg: TableConfig, isFirstInCombo: Bool) -> Bool {
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
        case table(TableArtifacts)
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
        case .table(let art):
            drawTable(art, in: rect, into: ctx)
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

    // MARK: - Paragraph alignment helper

    /// Wraps an attributed string with a paragraph style that pins line
    /// alignment, so multi-line text centers line-by-line inside the
    /// framesetter's draw rect rather than falling back to default
    /// (left-flush) layout. `MarkdownAttributor.buildAttributed` doesn't
    /// add paragraph alignment of its own; CaptionLayouter applies it,
    /// and overlay code (laurels, table cells) needs to do the same.
    private static func applyParagraphAlignment(
        _ attr: NSAttributedString, align: CaptionAlign
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attr)
        let paragraph = NSMutableParagraphStyle()
        switch align {
        case .left:   paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right:  paragraph.alignment = .right
        }
        mutable.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: mutable.length)
        )
        return mutable
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

        // Note: MarkdownAttributor doesn't apply paragraph alignment, so for
        // multi-line laurel text we need to add it ourselves. Without this
        // each line's framesetter rect lays out lines flush-left within the
        // measured rect (which is the width of the widest line), so a
        // 2-line subtitle whose lines have different widths comes out with
        // narrower lines visibly off-center vs the laurels' midline.
        let titleAttr = cfg.title.flatMap { text -> NSAttributedString? in
            let joined = text.lines.joined(separator: "\n")
            guard let raw = try? MarkdownAttributor.buildAttributed(
                plainOrMarkdown: joined, role: titleStyle, resolver: fontResolver
            ) else { return nil }
            return Self.applyParagraphAlignment(raw, align: titleStyle.align)
        }
        let subtitleAttr = cfg.subtitle.flatMap { text -> NSAttributedString? in
            let joined = text.lines.joined(separator: "\n")
            guard let raw = try? MarkdownAttributor.buildAttributed(
                plainOrMarkdown: joined, role: subtitleStyle, resolver: fontResolver
            ) else { return nil }
            return Self.applyParagraphAlignment(raw, align: subtitleStyle.align)
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

    // MARK: - Table layout

    private struct TableArtifacts {
        let cells: [[CellArtifact]]      // [row][col]; non-nil framesetter for non-empty cells
        let columnWidths: [CGFloat]      // includes 2 * cellPadding per column
        let rowHeights: [CGFloat]        // includes 2 * cellPadding per row
        let totalWidth: CGFloat          // sum of columns + outer/inner border lines
        let totalHeight: CGFloat
        let borderColor: NSColor
        let borderWidth: CGFloat
        let drawTopOuter: Bool
        let drawBottomOuter: Bool
        let drawLeftOuter: Bool
        let drawRightOuter: Bool
        let drawInner: Bool
        let cellPadding: CGFloat
    }

    private struct CellArtifact {
        let framesetter: AttributedFramesetter?
        let textSize: CGSize
        let align: CaptionAlign
        let verticalAlign: VerticalAlign
    }

    /// Lays out the table into a `MeasuredItem` so the slot-distribution code
    /// can position it the same way as images and laurels. Pads short rows
    /// with empty cells, derives a single auto font size that fits inside
    /// `max_height_pct / rows`, and computes column widths from the longest
    /// cell text in each column.
    private func measureTable(
        cfg: TableConfig,
        appearance: String,
        canvasSize: CGSize
    ) -> MeasuredItem {
        // Resolve grid orientation. `rows` wins when both are set.
        let rawGrid: [[String]] = cfg.rows ?? cfg.columns.map { transposeGrid($0) } ?? [[]]
        let grid = padToRectangular(rawGrid)
        let numRows = grid.count
        let numCols = grid.first?.count ?? 0

        // Empty/degenerate table: return a zero-sized measured item so the
        // pipeline can drop it without crashing.
        if numRows == 0 || numCols == 0 {
            let zeroArt = TableArtifacts(
                cells: [], columnWidths: [], rowHeights: [],
                totalWidth: 0, totalHeight: 0,
                borderColor: .white, borderWidth: 0,
                drawTopOuter: false, drawBottomOuter: false,
                drawLeftOuter: false, drawRightOuter: false, drawInner: false,
                cellPadding: 0
            )
            return MeasuredItem(
                kind: .table(zeroArt),
                align: cfg.align ?? .center,
                nudgeXPct: cfg.nudge?.xPct ?? 0,
                nudgeYPct: cfg.nudge?.yPct ?? 0,
                width: 0, height: 0
            )
        }

        let blockHeight = canvasSize.height * CGFloat(cfg.maxHeightPct ?? 14) / 100.0
        let cellPadding = canvasSize.height * CGFloat(cfg.cellPaddingPct ?? 1) / 100.0

        // Border configuration.
        let border = cfg.border
        let bordersOn = border?.enabled ?? true
        let borderWidth = bordersOn
            ? canvasSize.height * CGFloat(border?.widthPct ?? 0.15) / 100.0
            : 0
        let borderSides = border?.sides ?? [.outer, .inner]
        let drawTop    = bordersOn && (borderSides.contains(.outer) || borderSides.contains(.top))
        let drawBottom = bordersOn && (borderSides.contains(.outer) || borderSides.contains(.bottom))
        let drawLeft   = bordersOn && (borderSides.contains(.outer) || borderSides.contains(.left))
        let drawRight  = bordersOn && (borderSides.contains(.outer) || borderSides.contains(.right))
        let drawInner  = bordersOn && borderSides.contains(.inner)

        // Vertical budget: block height minus outer borders, inner border
        // lines, and the per-row top + bottom padding. The remaining space
        // is divided across all *text lines* in the table (sum across rows
        // of the max line count in that row), so a row containing a 2-line
        // cell gets twice the height of a single-line row.
        let outerVBorder = (drawTop ? borderWidth : 0) + (drawBottom ? borderWidth : 0)
        let innerVBorder = drawInner ? CGFloat(numRows - 1) * borderWidth : 0
        let totalPaddingV = 2 * cellPadding * CGFloat(numRows)
        let lineCounts: [Int] = grid.map { row in
            row.map { $0.components(separatedBy: "\n").count }.max() ?? 1
        }
        let totalLines = max(1, lineCounts.reduce(0, +))
        let textBudget = max(0, blockHeight - outerVBorder - innerVBorder - totalPaddingV)

        // Auto-derive font size so the table's text content (sum of all line
        // boxes across all rows) fits the budget. Line height = font * 1.2.
        // Override via `cell_style.font_size_pct`.
        let autoFontSize = textBudget / CGFloat(totalLines) / 1.2
        let fontSize = cfg.cellStyle?.fontSizePct.map {
            canvasSize.height * CGFloat($0) / 100.0
        } ?? autoFontSize

        // Cell text style.
        let textColorHex = cfg.textColor?.value(for: appearance)
        let textColor: NSColor = (cfg.cellStyle?.color.flatMap(RenderColors.parseHex))
            ?? textColorHex.flatMap(RenderColors.parseHex)
            ?? .white
        let style = ResolvedRoleStyle(
            font: cfg.cellStyle?.font ?? .system,
            weight: cfg.cellStyle?.weight ?? .regular,
            italic: cfg.cellStyle?.italic ?? false,
            fontSize: fontSize,
            color: textColor,
            align: cfg.cellStyle?.align ?? .center
        )

        // Build framesetters per cell. Each cell honors per-column horizontal
        // align (column_aligns[c]) and per-column vertical align
        // (column_valigns[c]); both fall back to cell_style.align /
        // cell_style.vertical_align (default center / center) when the
        // arrays don't cover this column. Measurement runs at near-infinite
        // width so explicit `\n` line breaks produce in-cell line wrapping
        // but lines never wrap mid-text.
        let cellStyleVAlign = cfg.cellStyle?.verticalAlign ?? .center
        var cells: [[CellArtifact]] = []
        var colWidths = Array(repeating: CGFloat(0), count: numCols)
        for r in 0..<numRows {
            var row: [CellArtifact] = []
            for c in 0..<numCols {
                let text = grid[r][c]
                let cellAlign = colAlign(at: c, columnAligns: cfg.columnAligns) ?? style.align
                let cellVAlign = colVAlign(at: c, columnValigns: cfg.columnValigns) ?? cellStyleVAlign
                if text.isEmpty {
                    row.append(CellArtifact(framesetter: nil, textSize: .zero,
                                            align: cellAlign, verticalAlign: cellVAlign))
                    continue
                }
                guard let raw = try? MarkdownAttributor.buildAttributed(
                    plainOrMarkdown: text, role: style, resolver: fontResolver
                ) else {
                    row.append(CellArtifact(framesetter: nil, textSize: .zero,
                                            align: cellAlign, verticalAlign: cellVAlign))
                    continue
                }
                // Apply per-cell horizontal alignment so multi-line cell
                // text centers (or left/right-aligns) line by line within
                // the measured cell rect.
                let attr = Self.applyParagraphAlignment(raw, align: cellAlign)
                let fs = AttributedFramesetter(attributed: attr)
                let size = fs.suggestedSize(constrainedTo: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ))
                if size.width > colWidths[c] { colWidths[c] = size.width }
                row.append(CellArtifact(framesetter: fs, textSize: size,
                                        align: cellAlign, verticalAlign: cellVAlign))
            }
            cells.append(row)
        }

        // Column widths include left + right cell padding.
        let paddedColWidths = colWidths.map { $0 + 2 * cellPadding }
        // Row heights are content-driven: max cell text height in that row
        // plus the cell's top+bottom padding. A row with 2-line cells comes
        // out twice as tall as a single-line row.
        var rowHeights: [CGFloat] = []
        rowHeights.reserveCapacity(numRows)
        for r in 0..<numRows {
            let maxTextH = cells[r].map(\.textSize.height).max() ?? 0
            rowHeights.append(maxTextH + 2 * cellPadding)
        }

        let outerHBorder = (drawLeft ? borderWidth : 0) + (drawRight ? borderWidth : 0)
        let innerHBorder = drawInner ? CGFloat(numCols - 1) * borderWidth : 0
        let totalWidth = paddedColWidths.reduce(0, +) + outerHBorder + innerHBorder
        let totalHeight = rowHeights.reduce(0, +) + outerVBorder + innerVBorder

        let borderColorHex = cfg.borderColor?.value(for: appearance)
        let borderColor: NSColor = borderColorHex.flatMap(RenderColors.parseHex) ?? .white

        let art = TableArtifacts(
            cells: cells,
            columnWidths: paddedColWidths,
            rowHeights: rowHeights,
            totalWidth: totalWidth,
            totalHeight: totalHeight,
            borderColor: borderColor,
            borderWidth: borderWidth,
            drawTopOuter: drawTop,
            drawBottomOuter: drawBottom,
            drawLeftOuter: drawLeft,
            drawRightOuter: drawRight,
            drawInner: drawInner,
            cellPadding: cellPadding
        )

        return MeasuredItem(
            kind: .table(art),
            align: cfg.align ?? .center,
            nudgeXPct: cfg.nudge?.xPct ?? 0,
            nudgeYPct: cfg.nudge?.yPct ?? 0,
            width: totalWidth,
            height: totalHeight
        )
    }

    /// Resolve the alignment for column `c` from a `column_aligns` array.
    /// Returns nil when the array is missing or shorter than `c+1` so the
    /// caller can fall back to the cell-style default.
    private func colAlign(at c: Int, columnAligns: [CaptionAlign]?) -> CaptionAlign? {
        guard let aligns = columnAligns, c < aligns.count else { return nil }
        return aligns[c]
    }

    /// Resolve the vertical alignment for column `c` from `column_valigns`.
    private func colVAlign(at c: Int, columnValigns: [VerticalAlign]?) -> VerticalAlign? {
        guard let aligns = columnValigns, c < aligns.count else { return nil }
        return aligns[c]
    }

    /// Pad each row with empty strings so all rows have the same column count
    /// (matching the longest row). Empty grid is returned unchanged.
    private func padToRectangular(_ grid: [[String]]) -> [[String]] {
        let cols = grid.map(\.count).max() ?? 0
        guard cols > 0 else { return grid }
        return grid.map { row in
            row.count == cols ? row : row + Array(repeating: "", count: cols - row.count)
        }
    }

    /// Transpose a column-major grid (cols x rows) into a row-major grid
    /// (rows x cols). Used when the user supplies `columns:` instead of
    /// `rows:`. Empty input returns empty.
    private func transposeGrid(_ grid: [[String]]) -> [[String]] {
        guard let firstColRows = grid.first?.count, firstColRows > 0 else { return [] }
        let rows = grid.map(\.count).max() ?? 0
        guard rows > 0 else { return [] }
        var out: [[String]] = Array(repeating: Array(repeating: "", count: grid.count), count: rows)
        for (c, col) in grid.enumerated() {
            for r in 0..<rows {
                out[r][c] = r < col.count ? col[r] : ""
            }
        }
        return out
    }

    /// Draws the table at `rect.origin`. The MeasuredItem already sized us at
    /// totalWidth × totalHeight, so `rect` matches our layout and we walk the
    /// grid in CG bottom-left coords (row 0 sits at the TOP of `rect`).
    private func drawTable(_ art: TableArtifacts, in rect: CGRect, into ctx: CGContext) {
        guard !art.cells.isEmpty else { return }

        let numRows = art.cells.count
        let numCols = art.cells[0].count
        let bw = art.borderWidth

        // Compute X edges of each column (left edge of column i, plus the
        // far-right edge after the last column). Walks from rect.minX
        // accounting for left outer border + inner borders.
        var colXEdges: [CGFloat] = []
        var x = rect.minX + (art.drawLeftOuter ? bw : 0)
        colXEdges.append(x)
        for c in 0..<numCols {
            x += art.columnWidths[c]
            colXEdges.append(x)
            if c < numCols - 1, art.drawInner { x += bw }
        }

        // Y edges of each row, top-down (row 0 is at the top of the table).
        // CG y-axis is flipped, so row 0's top in CG coords is rect.maxY.
        var rowYEdges: [CGFloat] = []
        var y = rect.maxY - (art.drawTopOuter ? bw : 0)
        rowYEdges.append(y)
        for r in 0..<numRows {
            y -= art.rowHeights[r]
            rowYEdges.append(y)
            if r < numRows - 1, art.drawInner { y -= bw }
        }

        // Draw borders first so cells render on top.
        if bw > 0 {
            let rgb = (art.borderColor.usingColorSpace(.sRGB) ?? art.borderColor)
            ctx.setFillColor(red: rgb.redComponent, green: rgb.greenComponent,
                             blue: rgb.blueComponent, alpha: rgb.alphaComponent)

            // Outer borders.
            if art.drawTopOuter {
                ctx.fill(CGRect(x: rect.minX, y: rect.maxY - bw,
                                width: rect.width, height: bw))
            }
            if art.drawBottomOuter {
                ctx.fill(CGRect(x: rect.minX, y: rect.minY,
                                width: rect.width, height: bw))
            }
            if art.drawLeftOuter {
                ctx.fill(CGRect(x: rect.minX, y: rect.minY,
                                width: bw, height: rect.height))
            }
            if art.drawRightOuter {
                ctx.fill(CGRect(x: rect.maxX - bw, y: rect.minY,
                                width: bw, height: rect.height))
            }

            // Inner borders.
            if art.drawInner {
                for c in 1..<numCols {
                    let edge = colXEdges[c] - bw
                    ctx.fill(CGRect(x: edge, y: rect.minY,
                                    width: bw, height: rect.height))
                }
                for r in 1..<numRows {
                    let edge = rowYEdges[r] - bw
                    ctx.fill(CGRect(x: rect.minX, y: edge,
                                    width: rect.width, height: bw))
                }
            }
        }

        // Cell text. Each cell's content rect is column[c] x row[r] minus
        // padding. Text is positioned at the cell's align horizontally and
        // vertically centered.
        for r in 0..<numRows {
            for c in 0..<numCols {
                let cell = art.cells[r][c]
                guard let fs = cell.framesetter, cell.textSize.height > 0 else { continue }
                let cellLeft = colXEdges[c] + art.cellPadding
                let cellRight = colXEdges[c + 1] - art.cellPadding
                let cellWidth = max(0, cellRight - cellLeft)
                let cellTop = rowYEdges[r] - art.cellPadding
                let cellBottom = rowYEdges[r + 1] + art.cellPadding
                let cellHeight = max(0, cellTop - cellBottom)

                // Horizontal alignment within the cell.
                let xOffset: CGFloat
                switch cell.align {
                case .left:   xOffset = 0
                case .center: xOffset = max(0, (cellWidth - cell.textSize.width) / 2)
                case .right:  xOffset = max(0, cellWidth - cell.textSize.width)
                }
                let textX = cellLeft + xOffset
                // Vertical alignment within the cell. CG y-axis is bottom-up,
                // so cellBottom is the *low* y-edge and `textY` (= text rect's
                // low edge) increases as text moves UP within the cell.
                let slack = max(0, cellHeight - cell.textSize.height)
                let textY: CGFloat
                switch cell.verticalAlign {
                case .top:    textY = cellBottom + slack       // text rect's bottom hugs the cell's text-area top
                case .center: textY = cellBottom + slack / 2
                case .bottom: textY = cellBottom              // text rect's bottom hugs the cell's text-area bottom
                }
                fs.draw(in: ctx, rect: CGRect(
                    x: textX, y: textY,
                    width: min(cell.textSize.width, cellWidth),
                    height: cell.textSize.height
                ))
            }
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
