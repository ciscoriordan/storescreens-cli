import Foundation
import AppKit
@preconcurrency import CoreText
import CoreGraphics

/// Lays out a caption (title + optional subtitle) for a single slide. Builds
/// attributed strings via `MarkdownAttributor`, measures via Core Text, and
/// auto-shrinks the font size proportionally until the combined block fits
/// inside `reservedHeight`. Returns a `LaidOutCaption` that knows how to draw
/// itself into a CGContext.
///
/// Behavior:
///   - Array captions are strict (one item per line, never word-wrapped).
///   - String captions wrap normally at the allowed width.
///   - Shrinkage applies the same ratio to title + subtitle so hierarchy is
///     preserved.
///   - If min_font_size_pct is hit and text still overflows, we truncate the
///     title with an ellipsis and log a warning (via the caller).
package struct CaptionLayouter {

    package let resolver: FontResolver

    package init(resolver: FontResolver) {
        self.resolver = resolver
    }

    package struct Warning: Sendable {
        package let message: String
    }

    package struct Output: Sendable {
        /// Full height occupied by the laid-out text block (may be less than
        /// reservedHeight if the text is short and centered).
        package let measuredHeight: CGFloat
        /// True if the shrink loop ran at least once.
        package let wasShrunk: Bool
        /// True if we hit the min font size without fitting and had to
        /// truncate with an ellipsis.
        package let wasTruncated: Bool
        /// Warnings for the caller to surface (e.g. truncation).
        package let warnings: [Warning]
        /// The opaque renderable. Callers invoke `draw(into:topLeft:)` to
        /// paint the caption in their canvas.
        package let drawable: Drawable
    }

    package struct Drawable: Sendable {
        let titleFramesetter: AttributedFramesetter?
        let subtitleFramesetter: AttributedFramesetter?
        let titleAlign: CaptionAlign
        let subtitleAlign: CaptionAlign
        let titleSize: CGSize
        let subtitleSize: CGSize
        let spacing: CGFloat
        let blockWidth: CGFloat
        /// Height of an optional vertical gap reserved between title and
        /// subtitle for image / laurel overlays. Zero means no slot. The
        /// rendered text simply ignores this region; the caller queries
        /// `middleSlotRect(topLeft:)` to draw into it.
        let middleSlotHeight: CGFloat

        /// Draws the caption block with its bottom-left corner at `topLeft`
        /// inside `ctx`. `topLeft.y` is in bottom-left (CG) coords - it's the
        /// y of the caption block's BOTTOM edge; the top of the block is at
        /// `topLeft.y + totalHeight`. Title sits on top, subtitle below it,
        /// with an optional middle slot gap between them.
        ///
        /// Core Text draws glyphs right-side-up in a natural bottom-left
        /// context. We compute rect coordinates in world space rather than
        /// flipping the CTM (which would mirror the glyphs vertically).
        package func draw(into ctx: CGContext, topLeft: CGPoint) {
            let titleH = titleSize.height
            let subH = subtitleSize.height
            // The gap between title baseline and subtitle baseline (or below
            // title when subtitle is absent) absorbs the middle slot plus
            // spacing on either side, so the slot is visually separated from
            // both text rows.
            let titleBottomGap: CGFloat
            if subH > 0 && middleSlotHeight > 0 {
                titleBottomGap = spacing + middleSlotHeight + spacing
            } else if subH > 0 {
                titleBottomGap = spacing
            } else if middleSlotHeight > 0 {
                titleBottomGap = spacing + middleSlotHeight
            } else {
                titleBottomGap = 0
            }
            let totalHeight = titleH + titleBottomGap + subH
            let blockTop = topLeft.y + totalHeight     // world y of the block's top edge

            if let ts = titleFramesetter, titleH > 0 {
                let x = topLeft.x + alignOffset(for: titleAlign, content: titleSize.width, total: blockWidth)
                let y = blockTop - titleH               // title's bottom edge
                ts.draw(in: ctx, rect: CGRect(x: x, y: y, width: titleSize.width, height: titleH))
            }

            if let ss = subtitleFramesetter, subH > 0 {
                let x = topLeft.x + alignOffset(for: subtitleAlign, content: subtitleSize.width, total: blockWidth)
                let y = topLeft.y                       // subtitle's bottom edge = block's bottom edge
                ss.draw(in: ctx, rect: CGRect(x: x, y: y, width: subtitleSize.width, height: subH))
            }
        }

        /// World-space rectangle (bottom-left CG coords) reserved for an
        /// image / laurel overlay between title and subtitle, given the same
        /// `topLeft` passed to `draw()`. Returns `.zero` when no slot was
        /// reserved. The slot is positioned `spacing` below the title's
        /// bottom edge.
        package func middleSlotRect(topLeft: CGPoint) -> CGRect {
            guard middleSlotHeight > 0 else { return .zero }
            let titleH = titleSize.height
            let subH = subtitleSize.height
            let titleBottomGap: CGFloat
            if subH > 0 && middleSlotHeight > 0 {
                titleBottomGap = spacing + middleSlotHeight + spacing
            } else if subH > 0 {
                titleBottomGap = spacing
            } else if middleSlotHeight > 0 {
                titleBottomGap = spacing + middleSlotHeight
            } else {
                titleBottomGap = 0
            }
            let totalHeight = titleH + titleBottomGap + subH
            let blockTop = topLeft.y + totalHeight
            let titleBottom = blockTop - titleH
            let slotTop = titleBottom - spacing
            let slotBottom = slotTop - middleSlotHeight
            return CGRect(x: topLeft.x, y: slotBottom, width: blockWidth, height: middleSlotHeight)
        }

        private func alignOffset(for align: CaptionAlign, content: CGFloat, total: CGFloat) -> CGFloat {
            switch align {
            case .left:   return 0
            case .center: return max(0, (total - content) / 2)
            case .right:  return max(0, total - content)
            }
        }
    }

    /// Main entry point. `reservedHeight` is the pixel height of the reserved
    /// caption region (usually `canvasSize.height * min_height_pct / 100`).
    /// `blockWidth` is the pixel width available for text (usually canvas
    /// width minus left/right padding). `middleSlotHeight` reserves a vertical
    /// gap between title and subtitle for an image / laurel overlay; pass 0
    /// to skip the slot. The slot height is included in fit/shrink decisions
    /// and in the returned `measuredHeight`.
    package func layout(
        title: CaptionText?,
        subtitle: CaptionText?,
        titleStyleRaw: CaptionRole?,
        subtitleStyleRaw: CaptionRole?,
        highlights: [CaptionHighlight],
        canvasSize: CGSize,
        reservedHeight: CGFloat,
        blockWidth: CGFloat,
        spacing: CGFloat,
        middleSlotHeight: CGFloat = 0
    ) throws -> Output {

        // If nothing to render, return empty output.
        if title == nil && subtitle == nil {
            return Output(
                measuredHeight: 0, wasShrunk: false, wasTruncated: false, warnings: [],
                drawable: Drawable(
                    titleFramesetter: nil, subtitleFramesetter: nil,
                    titleAlign: .center, subtitleAlign: .center,
                    titleSize: .zero, subtitleSize: .zero,
                    spacing: 0, blockWidth: blockWidth,
                    middleSlotHeight: middleSlotHeight
                )
            )
        }

        let titleResolved = resolveRoleDefaults(titleStyleRaw, canvasHeight: canvasSize.height, isTitle: true)
        let subtitleResolved = resolveRoleDefaults(subtitleStyleRaw, canvasHeight: canvasSize.height, isTitle: false)

        var ratio: CGFloat = 1.0
        var wasShrunk = false
        var warnings: [Warning] = []

        while true {
            let tRole = scaled(titleResolved, ratio: ratio)
            let sRole = scaled(subtitleResolved, ratio: ratio)

            let titleAttr = try title.map {
                try buildAttr(text: $0, role: tRole, highlights: highlights)
            }
            let subtitleAttr = try subtitle.map {
                try buildAttr(text: $0, role: sRole, highlights: highlights)
            }

            let titleMeasure = titleAttr.map {
                measure(attr: $0, strict: title?.isStrictLines ?? false, width: blockWidth)
            }
            let subtitleMeasure = subtitleAttr.map {
                measure(attr: $0, strict: subtitle?.isStrictLines ?? false, width: blockWidth)
            }

            let tH = titleMeasure?.size.height ?? 0
            let sH = subtitleMeasure?.size.height ?? 0
            let tW = titleMeasure?.size.width ?? 0
            let sW = subtitleMeasure?.size.width ?? 0
            // Mirror the gap math in Drawable.draw: when both rows are
            // present the slot is sandwiched by `spacing` on each side; when
            // only the title is present the slot sits one `spacing` below it.
            let gap: CGFloat
            if sH > 0 && middleSlotHeight > 0 {
                gap = spacing + middleSlotHeight + spacing
            } else if sH > 0 {
                gap = spacing
            } else if middleSlotHeight > 0 {
                gap = spacing + middleSlotHeight
            } else {
                gap = 0
            }
            let totalH = tH + gap + sH
            let maxLineW = max(tW, sW)

            let fits = totalH <= reservedHeight && maxLineW <= blockWidth

            if fits {
                let drawable = Drawable(
                    titleFramesetter: titleMeasure?.framesetter,
                    subtitleFramesetter: subtitleMeasure?.framesetter,
                    titleAlign: tRole.align,
                    subtitleAlign: sRole.align,
                    titleSize: titleMeasure?.size ?? .zero,
                    subtitleSize: subtitleMeasure?.size ?? .zero,
                    spacing: spacing,
                    blockWidth: blockWidth,
                    middleSlotHeight: middleSlotHeight
                )
                return Output(
                    measuredHeight: totalH,
                    wasShrunk: wasShrunk,
                    wasTruncated: false,
                    warnings: warnings,
                    drawable: drawable
                )
            }

            // Hit floor? `scaled()` clamps fontSize at minFontSize, so compare
            // ratio-derived target against the floor — once the pre-clamp value
            // is at/below the floor, we've stopped actually shrinking.
            let titleTargetSize = titleResolved.fontSize * ratio
            let subtitleTargetSize = subtitleResolved.fontSize * ratio
            let titleBelowFloor = titleTargetSize <= titleResolved.minFontSize
            let subtitleBelowFloor = sH == 0 || subtitleTargetSize <= subtitleResolved.minFontSize

            if titleBelowFloor && (subtitle == nil || subtitleBelowFloor) {
                warnings.append(Warning(message: "caption did not fit at min font size; truncated with ellipsis"))
                // Re-layout with a paragraph style that truncates.
                let tAttrClipped = titleAttr.map { applyTruncation($0) }
                let sAttrClipped = subtitleAttr.map { applyTruncation($0) }
                let tMeasure = tAttrClipped.map { measure(attr: $0, strict: false, width: blockWidth) }
                let sMeasure = sAttrClipped.map { measure(attr: $0, strict: false, width: blockWidth) }
                let drawable = Drawable(
                    titleFramesetter: tMeasure?.framesetter,
                    subtitleFramesetter: sMeasure?.framesetter,
                    titleAlign: tRole.align,
                    subtitleAlign: sRole.align,
                    titleSize: tMeasure?.size ?? .zero,
                    subtitleSize: sMeasure?.size ?? .zero,
                    spacing: spacing,
                    blockWidth: blockWidth,
                    middleSlotHeight: middleSlotHeight
                )
                let th = tMeasure?.size.height ?? 0
                let sh = sMeasure?.size.height ?? 0
                let truncatedGap: CGFloat
                if sh > 0 && middleSlotHeight > 0 {
                    truncatedGap = spacing + middleSlotHeight + spacing
                } else if sh > 0 {
                    truncatedGap = spacing
                } else if middleSlotHeight > 0 {
                    truncatedGap = spacing + middleSlotHeight
                } else {
                    truncatedGap = 0
                }
                return Output(
                    measuredHeight: th + truncatedGap + sh,
                    wasShrunk: true, wasTruncated: true,
                    warnings: warnings, drawable: drawable
                )
            }

            ratio *= 0.95
            wasShrunk = true
        }
    }

    // MARK: - Role defaults

    private func resolveRoleDefaults(
        _ raw: CaptionRole?,
        canvasHeight: CGFloat,
        isTitle: Bool
    ) -> ResolvedRole {
        let defaultSizePct = isTitle ? 5.0 : 3.0
        let defaultMinPct = isTitle ? 3.0 : 1.8
        return ResolvedRole(
            font: raw?.font ?? .system,
            weight: raw?.weight ?? (isTitle ? .bold : .regular),
            italic: raw?.italic ?? false,
            fontSize: canvasHeight * (raw?.fontSizePct ?? defaultSizePct) / 100.0,
            minFontSize: canvasHeight * (raw?.minFontSizePct ?? defaultMinPct) / 100.0,
            color: raw?.color.flatMap(RenderColors.parseHex) ?? (isTitle ? .white : .white),
            align: raw?.align ?? .center
        )
    }

    private struct ResolvedRole {
        let font: FontSpec
        let weight: FontWeight
        let italic: Bool
        let fontSize: CGFloat
        let minFontSize: CGFloat
        let color: NSColor
        let align: CaptionAlign
    }

    private func scaled(_ r: ResolvedRole, ratio: CGFloat) -> ResolvedRole {
        ResolvedRole(
            font: r.font, weight: r.weight, italic: r.italic,
            fontSize: max(r.minFontSize, r.fontSize * ratio),
            minFontSize: r.minFontSize,
            color: r.color, align: r.align
        )
    }

    private func minFontSize(_ r: ResolvedRole) -> CGFloat { r.minFontSize }

    private func buildAttr(
        text: CaptionText,
        role: ResolvedRole,
        highlights: [CaptionHighlight]
    ) throws -> NSAttributedString {
        // Join array lines with newlines; framesetter will respect them when
        // we set paragraph style to no-wrap for strict mode.
        let joined = text.lines.joined(separator: "\n")
        let style = ResolvedRoleStyle(
            font: role.font, weight: role.weight, italic: role.italic,
            fontSize: role.fontSize, color: role.color, align: role.align
        )
        let base = try MarkdownAttributor.buildAttributed(
            plainOrMarkdown: joined,
            role: style,
            resolver: resolver
        )
        // Apply paragraph style (alignment + no word-wrap for strict).
        let mutable = NSMutableAttributedString(attributedString: base)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsTextAlignment(from: role.align)
        paragraph.lineBreakMode = text.isStrictLines ? .byClipping : .byWordWrapping
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: mutable.length))

        return try MarkdownAttributor.applyHighlights(mutable, role: style, highlights: highlights, resolver: resolver)
    }

    private func nsTextAlignment(from a: CaptionAlign) -> NSTextAlignment {
        switch a {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    private func applyTruncation(_ attr: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        let paragraph = (attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        m.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: m.length))
        return m
    }

    // MARK: - Measurement

    private struct Measurement {
        let framesetter: AttributedFramesetter
        let size: CGSize
    }

    private func measure(attr: NSAttributedString, strict: Bool, width: CGFloat) -> Measurement {
        // For strict: measure at near-infinite width so CTFramesetter won't
        // wrap a line within an item — we want the natural width. If it
        // exceeds `width`, the caller's shrink loop will reduce size.
        let measureWidth = strict ? CGFloat.greatestFiniteMagnitude : width
        let framesetter = AttributedFramesetter(attributed: attr)
        let size = framesetter.suggestedSize(constrainedTo: CGSize(width: measureWidth, height: .greatestFiniteMagnitude))
        return Measurement(framesetter: framesetter, size: size)
    }
}

// MARK: - CoreText framesetter wrapper

package struct AttributedFramesetter: @unchecked Sendable {
    // CTFramesetter + NSAttributedString aren't declared Sendable, but both
    // are read-only once created; treating them as Sendable is safe for our
    // single-slide-at-a-time render flow.
    let framesetter: CTFramesetter
    let attributed: NSAttributedString

    init(attributed: NSAttributedString) {
        self.attributed = attributed
        self.framesetter = CTFramesetterCreateWithAttributedString(attributed)
    }

    func suggestedSize(constrainedTo bounds: CGSize) -> CGSize {
        let fitRange = CFRange(location: 0, length: attributed.length)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, fitRange, nil, bounds, nil
        )
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    func draw(in ctx: CGContext, rect: CGRect) {
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, ctx)
    }
}
