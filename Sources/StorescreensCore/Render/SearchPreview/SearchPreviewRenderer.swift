import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Pure Core Graphics + Core Text drawing of an iPhone App Store search
/// result row, wrapped in an iPhone bezel + status bar + Dynamic Island.
/// One renderer per call — no shared mutable state.
///
/// Coordinate convention: the context is flipped at the start so (0,0) is
/// the visual top-left and y grows downward. All layout math reads
/// straightforwardly without bottom-left mental gymnastics. Text drawing
/// undoes the flip locally for each glyph run (CG text APIs assume an
/// upward-pointing baseline; without the local re-flip, every glyph
/// would render mirrored).
///
/// The canvas defaults to the iPhone 6.9" Pro Max App Store screenshot
/// size (1290×2796) so renders sit alongside the regular framed PNGs at
/// a recognizable resolution.
package struct SearchPreviewRenderer {

    package static let canvasWidth: CGFloat = 1290
    package static let canvasHeight: CGFloat = 2796

    package init() {}

    package enum RenderError: Error, CustomStringConvertible {
        case contextCreationFailed
        case writeFailed(URL, underlying: String)

        package var description: String {
            switch self {
            case .contextCreationFailed: return "failed to create CGContext for search-preview render"
            case .writeFailed(let url, let underlying):
                return "failed to write \(url.path): \(underlying)"
            }
        }
    }

    /// Draws every input in `inputs` and writes one PNG per output URL.
    /// Per-input failures land in the returned warnings list; a hard CG
    /// failure throws so the caller can decide whether to abort.
    package func render(_ inputs: [SearchPreviewInput]) throws -> [String] {
        var warnings: [String] = []
        for input in inputs {
            let parent = input.outputURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            do {
                try renderOne(input)
            } catch {
                warnings.append("search-preview render failed for \(input.outputURL.lastPathComponent): \(error)")
            }
        }
        return warnings
    }

    func renderOne(_ input: SearchPreviewInput) throws {
        let canvas = CGRect(origin: .zero, size: input.canvasSize)
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.contextCreationFailed
        }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        // Flip to visual-top-down coords. From here on, y=0 is the top.
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)

        let theme = Theme.resolve(appearance: input.appearance)

        // 1. Canvas background.
        ctx.setFillColor(theme.canvasBackground.cgColor)
        ctx.fill(canvas)

        switch input.mode {
        case .searchRow:
            renderSearchRow(into: ctx, canvas: canvas, theme: theme, input: input)
        case .detailPage:
            renderDetailPage(into: ctx, canvas: canvas, theme: theme, input: input)
        case .both:
            // Resolver expands `.both` into [.searchRow, .detailPage] inputs,
            // so individual renderOne calls only ever see one mode at a time.
            renderSearchRow(into: ctx, canvas: canvas, theme: theme, input: input)
        }

        try writePNG(ctx: ctx, url: input.outputURL)
    }

    // MARK: - Detail page mode

    private func renderDetailPage(
        into ctx: CGContext,
        canvas: CGRect,
        theme: Theme,
        input: SearchPreviewInput
    ) {
        drawBezel(into: ctx, canvas: canvas, theme: theme)
        let navBottom = drawDetailNavBar(into: ctx, canvas: canvas, theme: theme)

        let contentPad = canvas.width * 0.05
        let contentRect = CGRect(
            x: contentPad,
            y: navBottom + canvas.height * 0.012,
            width: canvas.width - 2 * contentPad,
            height: canvas.height - navBottom - canvas.height * 0.02
        )

        var cursorY = contentRect.minY
        cursorY = drawDetailHero(
            into: ctx, contentRect: contentRect, canvas: canvas, topY: cursorY,
            theme: theme, input: input
        )
        cursorY = drawDetailStats(
            into: ctx, contentRect: contentRect, canvas: canvas, topY: cursorY,
            theme: theme, input: input
        )
        cursorY = drawDetailWhatsNew(
            into: ctx, contentRect: contentRect, canvas: canvas, topY: cursorY,
            theme: theme, input: input
        )
        cursorY = drawDetailPreview(
            into: ctx, contentRect: contentRect, canvas: canvas, topY: cursorY,
            theme: theme, input: input
        )
        _ = drawDetailAbout(
            into: ctx, contentRect: contentRect, canvas: canvas, topY: cursorY,
            theme: theme, input: input
        )
    }

    private func drawDetailNavBar(
        into ctx: CGContext,
        canvas: CGRect,
        theme: Theme
    ) -> CGFloat {
        // Status bar pieces (time, Dynamic Island, signal cluster).
        let statusTopY: CGFloat = canvas.height * 0.018
        let statusHeight: CGFloat = canvas.height * 0.040

        drawText(
            into: ctx, text: "9:41",
            font: systemFont(size: canvas.height * 0.018, weight: .semibold),
            color: theme.statusBarText,
            topLeft: CGPoint(x: canvas.width * 0.095, y: statusTopY + statusHeight * 0.10)
        )
        let islandWidth = canvas.width * 0.32
        let islandHeight = canvas.height * 0.034
        let islandRect = CGRect(
            x: (canvas.width - islandWidth) / 2,
            y: statusTopY + (statusHeight - islandHeight) / 2,
            width: islandWidth, height: islandHeight
        )
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(
            roundedRect: islandRect,
            cornerWidth: islandHeight / 2, cornerHeight: islandHeight / 2,
            transform: nil
        ))
        ctx.fillPath()
        drawStatusRightCluster(
            into: ctx,
            rightX: canvas.width * 0.905,
            centerY: statusTopY + statusHeight / 2,
            scale: canvas.height * 0.015,
            theme: theme
        )

        // Nav row: back chevron on left, share + ellipsis on right.
        let navTopY = statusTopY + statusHeight + canvas.height * 0.010
        let navHeight = canvas.height * 0.045
        let navMidY = navTopY + navHeight / 2
        let iconSize = canvas.height * 0.030
        drawSymbol(
            "chevron.left", into: ctx,
            rect: CGRect(
                x: canvas.width * 0.060,
                y: navMidY - iconSize / 2,
                width: iconSize, height: iconSize
            ),
            color: theme.actionText,
            weight: .semibold
        )
        // Share + ellipsis cluster on the right (small inactive icons).
        // `ellipsis.circle.fill` renders as a fully-filled blue blob in
        // palette mode; the plain `ellipsis` glyph reads correctly.
        drawSymbol(
            "ellipsis", into: ctx,
            rect: CGRect(
                x: canvas.width * 0.905 - iconSize,
                y: navMidY - iconSize / 2,
                width: iconSize, height: iconSize
            ),
            color: theme.actionText,
            weight: .semibold
        )
        drawSymbol(
            "square.and.arrow.up", into: ctx,
            rect: CGRect(
                x: canvas.width * 0.905 - iconSize * 2.4,
                y: navMidY - iconSize / 2,
                width: iconSize, height: iconSize
            ),
            color: theme.actionText,
            weight: .regular
        )

        return navTopY + navHeight
    }

    private func drawDetailHero(
        into ctx: CGContext,
        contentRect: CGRect,
        canvas: CGRect,
        topY: CGFloat,
        theme: Theme,
        input: SearchPreviewInput
    ) -> CGFloat {
        let iconSize: CGFloat = canvas.height * 0.085
        let iconCorner = iconSize * 0.2237
        let iconRect = CGRect(
            x: contentRect.minX,
            y: topY,
            width: iconSize, height: iconSize
        )
        let iconPath = CGPath(
            roundedRect: iconRect,
            cornerWidth: iconCorner, cornerHeight: iconCorner,
            transform: nil
        )
        ctx.saveGState()
        ctx.addPath(iconPath)
        ctx.setFillColor(theme.iconPlaceholderBackground.cgColor)
        ctx.fillPath()
        if let iconURL = input.iconPath, let image = loadImage(iconURL) {
            ctx.saveGState()
            ctx.addPath(iconPath)
            ctx.clip()
            ctx.saveGState()
            ctx.translateBy(x: iconRect.minX, y: iconRect.minY + iconRect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: iconRect.width, height: iconRect.height))
            ctx.restoreGState()
            ctx.restoreGState()
        }
        ctx.setStrokeColor(theme.iconStroke.cgColor)
        ctx.setLineWidth(iconSize * 0.005)
        ctx.addPath(iconPath)
        ctx.strokePath()
        ctx.restoreGState()

        // Right of icon: name + subtitle + developer line.
        let textLeftX = iconRect.maxX + contentRect.width * 0.035
        let textWidth = contentRect.maxX - textLeftX
        let nameFont = systemFont(size: iconSize * 0.30, weight: .semibold)
        let subFont = systemFont(size: iconSize * 0.20, weight: .regular)
        let devFont = systemFont(size: iconSize * 0.19, weight: .regular)
        let nameLine = CGFloat(CTFontGetAscent(nameFont)) + CGFloat(CTFontGetDescent(nameFont))
        let subLine = CGFloat(CTFontGetAscent(subFont)) + CGFloat(CTFontGetDescent(subFont))
        let nameTopY = topY + iconSize * 0.05
        let subTopY = nameTopY + nameLine + iconSize * 0.04
        let devTopY = subTopY + subLine + iconSize * 0.04

        drawText(
            into: ctx, text: truncateToFit(input.name, font: nameFont, maxWidth: textWidth),
            font: nameFont, color: theme.primaryText,
            topLeft: CGPoint(x: textLeftX, y: nameTopY),
            maxWidth: textWidth,
            tracking: -CGFloat(CTFontGetSize(nameFont)) * 0.018
        )
        if !input.subtitle.isEmpty {
            drawText(
                into: ctx, text: truncateToFit(input.subtitle, font: subFont, maxWidth: textWidth),
                font: subFont, color: theme.secondaryText,
                topLeft: CGPoint(x: textLeftX, y: subTopY),
                maxWidth: textWidth
            )
        }
        if !input.developer.isEmpty {
            let symW = subLine
            drawSymbol(
                "person.crop.square", into: ctx,
                rect: CGRect(x: textLeftX, y: devTopY, width: symW, height: symW),
                color: theme.actionText, weight: .regular
            )
            drawText(
                into: ctx, text: input.developer,
                font: devFont, color: theme.actionText,
                topLeft: CGPoint(x: textLeftX + symW + iconSize * 0.04, y: devTopY)
            )
        }

        // Action row beneath the icon: GET pill on the left + share buttons.
        let actionTopY = iconRect.maxY + iconSize * 0.18
        let actionLabel = Self.actionLabel(input.action, price: input.priceLabel)
        let actionFont = systemFont(size: iconSize * 0.22, weight: .semibold)
        let actionTextWidth = measureText(actionLabel, font: actionFont)
        let actionPadX = iconSize * 0.45
        let actionWidth = max(iconSize * 1.8, actionTextWidth + 2 * actionPadX)
        let actionHeight = iconSize * 0.42
        let actionRect = CGRect(
            x: contentRect.minX, y: actionTopY,
            width: actionWidth, height: actionHeight
        )
        ctx.saveGState()
        ctx.setFillColor(theme.actionBackground.cgColor)
        ctx.addPath(CGPath(
            roundedRect: actionRect,
            cornerWidth: actionHeight / 2, cornerHeight: actionHeight / 2,
            transform: nil
        ))
        ctx.fillPath()
        drawTextCentered(
            into: ctx, text: actionLabel,
            font: actionFont, color: theme.actionText,
            center: CGPoint(x: actionRect.midX, y: actionRect.midY)
        )
        ctx.restoreGState()
        // Share button on the right.
        let shareSize = actionHeight * 0.85
        drawSymbol(
            "square.and.arrow.up", into: ctx,
            rect: CGRect(
                x: contentRect.maxX - shareSize,
                y: actionTopY + (actionHeight - shareSize) / 2,
                width: shareSize, height: shareSize
            ),
            color: theme.actionText, weight: .regular
        )

        return actionTopY + actionHeight + iconSize * 0.20
    }

    private func drawDetailStats(
        into ctx: CGContext,
        contentRect: CGRect,
        canvas: CGRect,
        topY: CGFloat,
        theme: Theme,
        input: SearchPreviewInput
    ) -> CGFloat {
        // Horizontal divider line above the stats strip.
        ctx.saveGState()
        ctx.setStrokeColor(theme.iconStroke.cgColor)
        ctx.setLineWidth(canvas.height * 0.0008)
        ctx.move(to: CGPoint(x: contentRect.minX, y: topY))
        ctx.addLine(to: CGPoint(x: contentRect.maxX, y: topY))
        ctx.strokePath()
        ctx.restoreGState()

        let stripHeight = canvas.height * 0.080
        let stripTopY = topY + canvas.height * 0.010
        let cellWidth = contentRect.width / 4

        struct StatCell {
            let topLabel: String
            let bigLabel: String?
            let bigSymbol: String?
            let bottomLabel: String?
        }
        var cells: [StatCell] = []
        cells.append(StatCell(
            topLabel: "\(input.reviews) RATINGS",
            bigLabel: String(format: "%.1f", input.rating),
            bigSymbol: nil,
            bottomLabel: "★★★★★"
        ))
        if let age = input.ageRating, !age.isEmpty {
            cells.append(StatCell(
                topLabel: "AGE",
                bigLabel: age,
                bigSymbol: nil,
                bottomLabel: "Years Old"
            ))
        }
        if let firstCategory = input.categories.first {
            cells.append(StatCell(
                topLabel: "CATEGORY",
                bigLabel: nil,
                bigSymbol: Self.categorySymbol[firstCategory] ?? "tag.fill",
                bottomLabel: firstCategory
            ))
        }
        if !input.developer.isEmpty {
            cells.append(StatCell(
                topLabel: "DEVELOPER",
                bigLabel: nil,
                bigSymbol: "person.crop.square",
                bottomLabel: input.developer
            ))
        }

        let labelFont = systemFont(size: canvas.height * 0.011, weight: .semibold)
        let bigFont = systemFont(size: canvas.height * 0.024, weight: .semibold)
        let bottomFont = systemFont(size: canvas.height * 0.011, weight: .regular)
        let visible = min(cells.count, 4)
        for i in 0..<visible {
            let cell = cells[i]
            let cellX = contentRect.minX + CGFloat(i) * cellWidth
            let cellCenterX = cellX + cellWidth / 2
            // Top label (uppercase)
            drawTextCentered(
                into: ctx, text: cell.topLabel,
                font: labelFont, color: theme.secondaryText,
                center: CGPoint(x: cellCenterX, y: stripTopY + canvas.height * 0.008)
            )
            // Big content (label or symbol)
            if let big = cell.bigLabel {
                drawTextCentered(
                    into: ctx, text: big,
                    font: bigFont, color: theme.primaryText,
                    center: CGPoint(x: cellCenterX, y: stripTopY + stripHeight * 0.45)
                )
            } else if let sym = cell.bigSymbol {
                let size = canvas.height * 0.030
                drawSymbol(
                    sym, into: ctx,
                    rect: CGRect(
                        x: cellCenterX - size / 2,
                        y: stripTopY + stripHeight * 0.30,
                        width: size, height: size
                    ),
                    color: theme.secondaryText, weight: .regular
                )
            }
            // Bottom label
            if let bottom = cell.bottomLabel {
                drawTextCentered(
                    into: ctx, text: bottom,
                    font: bottomFont, color: theme.secondaryText,
                    center: CGPoint(x: cellCenterX, y: stripTopY + stripHeight * 0.85)
                )
            }
            // Right divider line (except for last cell)
            if i < visible - 1 {
                ctx.saveGState()
                ctx.setStrokeColor(theme.iconStroke.cgColor)
                ctx.setLineWidth(canvas.height * 0.0006)
                let dx = cellX + cellWidth
                ctx.move(to: CGPoint(x: dx, y: stripTopY + stripHeight * 0.20))
                ctx.addLine(to: CGPoint(x: dx, y: stripTopY + stripHeight * 0.80))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }

        // Bottom divider.
        let stripBottomY = stripTopY + stripHeight + canvas.height * 0.010
        ctx.saveGState()
        ctx.setStrokeColor(theme.iconStroke.cgColor)
        ctx.setLineWidth(canvas.height * 0.0008)
        ctx.move(to: CGPoint(x: contentRect.minX, y: stripBottomY))
        ctx.addLine(to: CGPoint(x: contentRect.maxX, y: stripBottomY))
        ctx.strokePath()
        ctx.restoreGState()

        return stripBottomY + canvas.height * 0.015
    }

    private func drawDetailWhatsNew(
        into ctx: CGContext,
        contentRect: CGRect,
        canvas: CGRect,
        topY: CGFloat,
        theme: Theme,
        input: SearchPreviewInput
    ) -> CGFloat {
        guard let whatsNew = input.whatsNew, !whatsNew.isEmpty else { return topY }

        let headerFont = systemFont(size: canvas.height * 0.020, weight: .bold)
        let metaFont = systemFont(size: canvas.height * 0.013, weight: .regular)
        let bodyFont = systemFont(size: canvas.height * 0.0155, weight: .regular)
        let linkFont = bodyFont

        drawText(
            into: ctx, text: "What's New",
            font: headerFont, color: theme.primaryText,
            topLeft: CGPoint(x: contentRect.minX, y: topY)
        )
        let versionHistoryWidth = measureText("Version History", font: metaFont)
        drawText(
            into: ctx, text: "Version History",
            font: metaFont, color: theme.actionText,
            topLeft: CGPoint(x: contentRect.maxX - versionHistoryWidth, y: topY + canvas.height * 0.005)
        )
        let headerLine = CGFloat(CTFontGetAscent(headerFont)) + CGFloat(CTFontGetDescent(headerFont))

        // Version row (left) — "Version X.Y.Z"
        if let version = input.version, !version.isEmpty {
            drawText(
                into: ctx, text: "Version \(version)",
                font: metaFont, color: theme.secondaryText,
                topLeft: CGPoint(x: contentRect.minX, y: topY + headerLine + canvas.height * 0.005)
            )
        }

        let bodyTopY = topY + headerLine + canvas.height * 0.025
        let bottomY = drawTruncatedParagraph(
            into: ctx,
            text: whatsNew,
            font: bodyFont,
            textColor: theme.primaryText,
            linkColor: theme.actionText,
            linkFont: linkFont,
            moreLabel: "more",
            topLeft: CGPoint(x: contentRect.minX, y: bodyTopY),
            width: contentRect.width,
            maxLines: 3
        )

        return bottomY + canvas.height * 0.025
    }

    private func drawDetailPreview(
        into ctx: CGContext,
        contentRect: CGRect,
        canvas: CGRect,
        topY: CGFloat,
        theme: Theme,
        input: SearchPreviewInput
    ) -> CGFloat {
        let headerFont = systemFont(size: canvas.height * 0.020, weight: .bold)
        drawText(
            into: ctx, text: "Preview",
            font: headerFont, color: theme.primaryText,
            topLeft: CGPoint(x: contentRect.minX, y: topY)
        )
        let headerLine = CGFloat(CTFontGetAscent(headerFont)) + CGFloat(CTFontGetDescent(headerFont))
        let stripTopY = topY + headerLine + canvas.height * 0.015

        let count = 3
        let gap = contentRect.width * 0.020
        let tileWidth = (contentRect.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let tileHeight = tileWidth * (19.5 / 9.0)
        for i in 0..<count {
            let tileX = contentRect.minX + CGFloat(i) * (tileWidth + gap)
            let tileRect = CGRect(x: tileX, y: stripTopY, width: tileWidth, height: tileHeight)
            let cornerRadius = tileWidth * 0.05
            let tilePath = CGPath(
                roundedRect: tileRect,
                cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil
            )
            ctx.saveGState()
            ctx.addPath(tilePath)
            ctx.setFillColor(theme.screenshotPlaceholder.cgColor)
            ctx.fillPath()
            if i < input.screenshotPaths.count,
               let img = loadImage(input.screenshotPaths[i]) {
                ctx.saveGState()
                ctx.addPath(tilePath)
                ctx.clip()
                let fit = aspectFill(
                    imageSize: CGSize(width: img.width, height: img.height),
                    in: tileRect
                )
                ctx.saveGState()
                ctx.translateBy(x: fit.minX, y: fit.minY + fit.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: fit.width, height: fit.height))
                ctx.restoreGState()
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
        return stripTopY + tileHeight + canvas.height * 0.025
    }

    private func drawDetailAbout(
        into ctx: CGContext,
        contentRect: CGRect,
        canvas: CGRect,
        topY: CGFloat,
        theme: Theme,
        input: SearchPreviewInput
    ) -> CGFloat {
        guard let body = input.descriptionText, !body.isEmpty else { return topY }
        let headerFont = systemFont(size: canvas.height * 0.020, weight: .bold)
        drawText(
            into: ctx, text: "About This App",
            font: headerFont, color: theme.primaryText,
            topLeft: CGPoint(x: contentRect.minX, y: topY)
        )
        let headerLine = CGFloat(CTFontGetAscent(headerFont)) + CGFloat(CTFontGetDescent(headerFont))
        let bodyFont = systemFont(size: canvas.height * 0.0155, weight: .regular)
        let bodyTopY = topY + headerLine + canvas.height * 0.012
        return drawTruncatedParagraph(
            into: ctx,
            text: body,
            font: bodyFont,
            textColor: theme.primaryText,
            linkColor: theme.actionText,
            linkFont: bodyFont,
            moreLabel: "more",
            topLeft: CGPoint(x: contentRect.minX, y: bodyTopY),
            width: contentRect.width,
            maxLines: 3
        )
    }

    /// Lays out `text` as wrapped lines at `width`. Up to `maxLines` are
    /// drawn. If the text overflows, the last visible line is truncated to
    /// make room for "…more" (with the literal `moreLabel` in `linkColor`).
    /// Returns the visual bottom y of the rendered block.
    private func drawTruncatedParagraph(
        into ctx: CGContext,
        text: String,
        font: CTFont,
        textColor: NSColor,
        linkColor: NSColor,
        linkFont: CTFont,
        moreLabel: String,
        topLeft: CGPoint,
        width: CGFloat,
        maxLines: Int,
        lineSpacing: CGFloat = 0
    ) -> CGFloat {
        let attr = attributedString(text, font: font, color: textColor)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: width, height: 100_000),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        let ctLines = CTFrameGetLines(frame) as! [CTLine]

        let ascent = CGFloat(CTFontGetAscent(font))
        let descent = CGFloat(CTFontGetDescent(font))
        let leading = CGFloat(CTFontGetLeading(font))
        let lineHeight = ascent + descent + leading + lineSpacing
        let ellipsisAndMore = "…\u{00A0}\(moreLabel)"
        let moreWidth = measureText(ellipsisAndMore, font: linkFont)

        // Helper to draw one line of plain text at the given visual y.
        func draw(line: CTLine, font: CTFont, color: NSColor, atTopLeft tl: CGPoint) {
            ctx.saveGState()
            ctx.translateBy(x: tl.x, y: tl.y + ascent)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        if ctLines.count <= maxLines {
            for (i, line) in ctLines.enumerated() {
                let lineColored = CTLineCreateWithAttributedString(
                    attributedString(
                        substring(of: text, range: CTLineGetStringRange(line)),
                        font: font, color: textColor
                    )
                )
                draw(
                    line: lineColored,
                    font: font, color: textColor,
                    atTopLeft: CGPoint(
                        x: topLeft.x,
                        y: topLeft.y + CGFloat(i) * lineHeight
                    )
                )
            }
            return topLeft.y + CGFloat(ctLines.count) * lineHeight
        }

        // Overflow: draw first maxLines-1 verbatim, then truncate the last
        // visible line so "…more" fits at the right edge.
        for i in 0..<(maxLines - 1) {
            let line = ctLines[i]
            let lineColored = CTLineCreateWithAttributedString(
                attributedString(
                    substring(of: text, range: CTLineGetStringRange(line)),
                    font: font, color: textColor
                )
            )
            draw(
                line: lineColored,
                font: font, color: textColor,
                atTopLeft: CGPoint(x: topLeft.x, y: topLeft.y + CGFloat(i) * lineHeight)
            )
        }

        // Last visible line: take everything that landed on line `maxLines-1`
        // (the line that would overflow), then trim from the end until
        // `(trimmed) + "…\u{00A0}more"` fits.
        let lastLineRange = CTLineGetStringRange(ctLines[maxLines - 1])
        let lastLineEnd = lastLineRange.location + lastLineRange.length
        var truncatedText = substring(of: text, range: CFRange(location: 0, length: lastLineEnd))
        // Strip trailing whitespace/newline so the ellipsis hugs the text.
        truncatedText = truncatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        while !truncatedText.isEmpty {
            let lineCandidate = CTLineCreateWithAttributedString(
                attributedString(truncatedText, font: font, color: textColor)
            )
            let candidateWidth = CGFloat(CTLineGetTypographicBounds(lineCandidate, nil, nil, nil))
            if candidateWidth + moreWidth <= width { break }
            // Drop the last character (word would be cleaner; this is the
            // safe minimum).
            truncatedText = String(truncatedText.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Trim back to a word boundary so the "…" doesn't sit mid-word.
        if let lastSpace = truncatedText.lastIndex(where: { $0 == " " || $0 == "\n" }) {
            truncatedText = String(truncatedText[..<lastSpace])
                .trimmingCharacters(in: .whitespaces)
        }

        let truncatedY = topLeft.y + CGFloat(maxLines - 1) * lineHeight
        let truncatedLine = CTLineCreateWithAttributedString(
            attributedString(truncatedText, font: font, color: textColor)
        )
        draw(
            line: truncatedLine,
            font: font, color: textColor,
            atTopLeft: CGPoint(x: topLeft.x, y: truncatedY)
        )
        let truncatedDrawnWidth = CGFloat(CTLineGetTypographicBounds(truncatedLine, nil, nil, nil))

        // Append "…" in textColor and " more" in linkColor.
        let ellipsisLine = CTLineCreateWithAttributedString(
            attributedString("…\u{00A0}", font: font, color: textColor)
        )
        draw(
            line: ellipsisLine,
            font: font, color: textColor,
            atTopLeft: CGPoint(x: topLeft.x + truncatedDrawnWidth, y: truncatedY)
        )
        let ellipsisWidth = CGFloat(CTLineGetTypographicBounds(ellipsisLine, nil, nil, nil))
        let moreLine = CTLineCreateWithAttributedString(
            attributedString(moreLabel, font: linkFont, color: linkColor)
        )
        draw(
            line: moreLine,
            font: linkFont, color: linkColor,
            atTopLeft: CGPoint(x: topLeft.x + truncatedDrawnWidth + ellipsisWidth, y: truncatedY)
        )

        return topLeft.y + CGFloat(maxLines) * lineHeight
    }

    /// Extract a substring from `text` given a CFRange of UTF-16 offsets.
    /// Used to pull the visible text of each CTLine for re-drawing.
    private func substring(of text: String, range: CFRange) -> String {
        let utf16 = Array(text.utf16)
        guard range.location >= 0, range.location + range.length <= utf16.count else { return "" }
        let slice = utf16[range.location..<(range.location + range.length)]
        return String(utf16CodeUnits: Array(slice), count: Int(range.length))
    }

    // MARK: - Search row mode

    private func renderSearchRow(
        into ctx: CGContext,
        canvas: CGRect,
        theme: Theme,
        input: SearchPreviewInput
    ) {
        switch input.bezel {
        case .iphone:
            drawBezel(into: ctx, canvas: canvas, theme: theme)
            let searchBottom = drawStatusBarAndSearch(
                into: ctx, canvas: canvas, theme: theme,
                searchTerm: input.searchTerm
            )
            // Card sits below the search bar, padded inwards from the
            // bezel sides. The bottom is the bezel's bottom curve.
            let bezelPad = canvas.width * 0.03
            let cardPad = canvas.width * 0.06
            let cardRect = CGRect(
                x: cardPad,
                y: searchBottom + canvas.height * 0.025,
                width: canvas.width - 2 * cardPad,
                height: canvas.height - bezelPad - (searchBottom + canvas.height * 0.025)
            )
            drawCard(into: ctx, cardRect: cardRect, canvas: canvas, theme: theme, input: input)
        case .none:
            let padding: CGFloat = canvas.width * 0.04
            let cardRect = CGRect(
                x: padding,
                y: canvas.height * 0.05,
                width: canvas.width - 2 * padding,
                height: canvas.height * 0.55
            )
            drawCard(into: ctx, cardRect: cardRect, canvas: canvas, theme: theme, input: input)
        }
    }

    // MARK: - PNG write

    private func writePNG(ctx: CGContext, url: URL) throws {
        guard let image = ctx.makeImage() else {
            throw RenderError.writeFailed(url, underlying: "CGContext.makeImage returned nil")
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw RenderError.writeFailed(url, underlying: "CGImageDestinationCreateWithURL returned nil")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw RenderError.writeFailed(url, underlying: "CGImageDestinationFinalize failed")
        }
    }

    // MARK: - Bezel

    private func drawBezel(into ctx: CGContext, canvas: CGRect, theme: Theme) {
        // The bezel is the iPhone screen background — a rounded rect with
        // an iPhone-like corner radius. We let the bezel bleed past the
        // bottom of the canvas to match ezscreenshots' fade-out look
        // (the phone "continues off-screen").
        let inset: CGFloat = canvas.width * 0.03
        let radius: CGFloat = canvas.width * 0.18
        let bezelRect = CGRect(
            x: inset,
            y: 0,
            width: canvas.width - 2 * inset,
            height: canvas.height + radius
        )

        let path = CGPath(roundedRect: bezelRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: canvas.height * 0.005),
            blur: canvas.height * 0.012,
            color: NSColor.black.withAlphaComponent(0.25).cgColor
        )
        ctx.setFillColor(theme.bezelBackground.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - Status bar + search bar

    /// Draws the status bar (clock + Dynamic Island + battery cluster) and
    /// the fake search bar. Returns the visual-y of the search bar's
    /// bottom edge so the caller can place the card directly below it.
    private func drawStatusBarAndSearch(
        into ctx: CGContext,
        canvas: CGRect,
        theme: Theme,
        searchTerm: String
    ) -> CGFloat {
        let statusTopY: CGFloat = canvas.height * 0.018
        let statusHeight: CGFloat = canvas.height * 0.040

        // Time (9:41) — left side of the status bar.
        drawText(
            into: ctx,
            text: "9:41",
            font: systemFont(size: canvas.height * 0.018, weight: .semibold),
            color: theme.statusBarText,
            topLeft: CGPoint(x: canvas.width * 0.095, y: statusTopY + statusHeight * 0.10)
        )

        // Dynamic Island — centered pill, always black.
        let islandWidth = canvas.width * 0.32
        let islandHeight = canvas.height * 0.034
        let islandRect = CGRect(
            x: (canvas.width - islandWidth) / 2,
            y: statusTopY + (statusHeight - islandHeight) / 2,
            width: islandWidth, height: islandHeight
        )
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(
            roundedRect: islandRect,
            cornerWidth: islandHeight / 2, cornerHeight: islandHeight / 2,
            transform: nil
        ))
        ctx.fillPath()

        // Right cluster: signal / wifi / battery.
        drawStatusRightCluster(
            into: ctx,
            rightX: canvas.width * 0.905,
            centerY: statusTopY + statusHeight / 2,
            scale: canvas.height * 0.015,
            theme: theme
        )

        // Search bar — pill just below the status bar.
        let searchTopY = statusTopY + statusHeight + canvas.height * 0.015
        let searchHeight = canvas.height * 0.046
        let searchRect = CGRect(
            x: canvas.width * 0.080,
            y: searchTopY,
            width: canvas.width - 2 * canvas.width * 0.080,
            height: searchHeight
        )
        ctx.setFillColor(theme.searchBarBackground.cgColor)
        ctx.addPath(CGPath(
            roundedRect: searchRect,
            cornerWidth: searchHeight * 0.32, cornerHeight: searchHeight * 0.32,
            transform: nil
        ))
        ctx.fillPath()

        // Magnifying glass icon on the left side of the pill.
        drawMagnifyingGlass(
            into: ctx,
            center: CGPoint(x: searchRect.minX + searchHeight * 0.70, y: searchRect.midY),
            radius: searchHeight * 0.20,
            color: theme.searchBarPlaceholder
        )

        if !searchTerm.isEmpty {
            drawText(
                into: ctx,
                text: searchTerm,
                font: systemFont(size: searchHeight * 0.46, weight: .regular),
                color: theme.searchBarText,
                topLeft: CGPoint(
                    x: searchRect.minX + searchHeight * 1.35,
                    y: searchRect.midY - searchHeight * 0.22
                )
            )
        }

        return searchRect.maxY
    }

    private func drawStatusRightCluster(
        into ctx: CGContext,
        rightX: CGFloat,
        centerY: CGFloat,
        scale: CGFloat,
        theme: Theme
    ) {
        let tint = theme.statusBarIcon.cgColor

        // Battery (right-most): rounded outline + interior fill + stub.
        let batteryWidth = scale * 2.0
        let batteryHeight = scale * 1.0
        let batteryRect = CGRect(
            x: rightX - batteryWidth,
            y: centerY - batteryHeight / 2,
            width: batteryWidth,
            height: batteryHeight
        )
        ctx.saveGState()
        ctx.setStrokeColor(tint)
        ctx.setFillColor(tint)
        ctx.setLineWidth(scale * 0.10)
        ctx.addPath(CGPath(
            roundedRect: batteryRect,
            cornerWidth: scale * 0.20, cornerHeight: scale * 0.20,
            transform: nil
        ))
        ctx.strokePath()
        let fillInset = scale * 0.20
        let fillRect = batteryRect.insetBy(dx: fillInset, dy: fillInset)
        ctx.addPath(CGPath(
            roundedRect: fillRect,
            cornerWidth: scale * 0.12, cornerHeight: scale * 0.12,
            transform: nil
        ))
        ctx.fillPath()
        // Battery stub on the right.
        let stubRect = CGRect(
            x: batteryRect.maxX,
            y: centerY - batteryHeight * 0.22,
            width: scale * 0.14,
            height: batteryHeight * 0.44
        )
        ctx.fill(stubRect)
        ctx.restoreGState()

        // Wifi: three nested arcs facing up.
        let wifiCenter = CGPoint(x: batteryRect.minX - scale * 1.2, y: centerY + scale * 0.05)
        ctx.saveGState()
        ctx.setStrokeColor(tint)
        ctx.setFillColor(tint)
        ctx.setLineWidth(scale * 0.16)
        for i in 0..<3 {
            let r = scale * (0.40 + Double(i) * 0.22)
            let path = CGMutablePath()
            // Upward-facing arc (in our flipped coordinate space, "up" = smaller y).
            // 5π/4 → 7π/4 traces a half-circle facing upward.
            path.addArc(
                center: wifiCenter,
                radius: r,
                startAngle: -CGFloat.pi * 5 / 4,
                endAngle: -CGFloat.pi * 7 / 4,
                clockwise: true
            )
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.fillEllipse(in: CGRect(
            x: wifiCenter.x - scale * 0.12,
            y: wifiCenter.y - scale * 0.12,
            width: scale * 0.24,
            height: scale * 0.24
        ))
        ctx.restoreGState()

        // Signal bars: four ascending bars to the left of wifi.
        let signalRight = wifiCenter.x - scale * 1.3
        let barWidth = scale * 0.22
        let gap = scale * 0.10
        ctx.saveGState()
        ctx.setFillColor(tint)
        for i in 0..<4 {
            let h = scale * (0.30 + Double(i) * 0.22)
            let x = signalRight - CGFloat(4 - 1 - i) * (barWidth + gap) - barWidth
            let bar = CGRect(x: x, y: centerY + scale * 0.55 - h, width: barWidth, height: h)
            ctx.fill(bar)
        }
        ctx.restoreGState()
    }

    private func drawMagnifyingGlass(
        into ctx: CGContext,
        center: CGPoint,
        radius: CGFloat,
        color: NSColor
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(radius * 0.22)
        ctx.setLineCap(.round)
        ctx.strokeEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
        // Handle: 45° toward bottom-right (visually).
        let handleStart = CGPoint(
            x: center.x + radius * 0.707,
            y: center.y + radius * 0.707
        )
        let handleEnd = CGPoint(
            x: handleStart.x + radius * 0.7,
            y: handleStart.y + radius * 0.7
        )
        ctx.move(to: handleStart)
        ctx.addLine(to: handleEnd)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Search result card

    private func drawCard(
        into ctx: CGContext,
        cardRect: CGRect,
        canvas: CGRect,
        theme: Theme,
        input: SearchPreviewInput
    ) {
        let cardW = cardRect.width
        let canvasH = canvas.height
        let iconSize: CGFloat = canvasH * 0.062
        let iconCornerRadius = iconSize * 0.2237   // Apple squircle approximation

        let iconRect = CGRect(
            x: cardRect.minX, y: cardRect.minY,
            width: iconSize, height: iconSize
        )

        // Icon — placeholder fill, then optional image clipped to the squircle.
        let iconPath = CGPath(
            roundedRect: iconRect,
            cornerWidth: iconCornerRadius, cornerHeight: iconCornerRadius,
            transform: nil
        )
        ctx.saveGState()
        ctx.addPath(iconPath)
        ctx.setFillColor(theme.iconPlaceholderBackground.cgColor)
        ctx.fillPath()
        if let iconURL = input.iconPath, let image = loadImage(iconURL) {
            ctx.saveGState()
            ctx.addPath(iconPath)
            ctx.clip()
            // Image is loaded with its native top-up orientation. Our
            // context is flipped, so draw it via a temporary un-flip
            // around the icon rect so it lands right-side-up.
            ctx.saveGState()
            ctx.translateBy(x: iconRect.minX, y: iconRect.minY + iconRect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: iconRect.width, height: iconRect.height))
            ctx.restoreGState()
            ctx.restoreGState()
        }
        // Subtle stroke around the squircle.
        ctx.setStrokeColor(theme.iconStroke.cgColor)
        ctx.setLineWidth(iconSize * 0.005)
        ctx.addPath(iconPath)
        ctx.strokePath()
        ctx.restoreGState()

        // Action button (right side, vertically centered against the icon).
        let actionLabel = Self.actionLabel(input.action, price: input.priceLabel)
        // App Store action pill ("GET") uses SF Pro Semibold, not Bold.
        let actionFont = systemFont(size: iconSize * 0.34, weight: .semibold)
        let actionTextWidth = measureText(actionLabel, font: actionFont)
        let actionPaddingX = iconSize * 0.32
        let actionWidth = max(iconSize * 1.4, actionTextWidth + 2 * actionPaddingX)
        let actionHeight = iconSize * 0.50
        let actionRect = CGRect(
            x: cardRect.maxX - actionWidth,
            y: iconRect.midY - actionHeight / 2,
            width: actionWidth, height: actionHeight
        )
        ctx.saveGState()
        ctx.setFillColor(theme.actionBackground.cgColor)
        ctx.addPath(CGPath(
            roundedRect: actionRect,
            cornerWidth: actionHeight / 2, cornerHeight: actionHeight / 2,
            transform: nil
        ))
        ctx.fillPath()
        drawTextCentered(
            into: ctx, text: actionLabel,
            font: actionFont, color: theme.actionText,
            center: CGPoint(x: actionRect.midX, y: actionRect.midY)
        )
        ctx.restoreGState()

        // Right of icon: three-line stack matching the actual App Store
        // search row.
        //   line 1: name (semibold)
        //   line 2: subtitle (regular, secondary)
        //   line 3: stars + review count (regular, secondary)
        // The lines are vertically distributed within the icon's height so
        // the stack baseline-aligns with the squircle.
        let textLeftX = iconRect.maxX + cardW * 0.035
        let nameBandWidth = actionRect.minX - textLeftX - cardW * 0.02

        let nameFont = systemFont(size: iconSize * 0.36, weight: .semibold)
        let subtitleFont = systemFont(size: iconSize * 0.28, weight: .regular)
        let starsScale = iconSize * 0.24

        let nameAscent = CGFloat(CTFontGetAscent(nameFont))
        let subtitleAscent = CGFloat(CTFontGetAscent(subtitleFont))
        let nameLineHeight = nameAscent + CGFloat(CTFontGetDescent(nameFont))
        let subtitleLineHeight = subtitleAscent + CGFloat(CTFontGetDescent(subtitleFont))
        // Stars row height is dominated by the star glyph, drawn at ~1.4× scale.
        let starsLineHeight = starsScale * 1.45

        // Slight top inset so the three lines visually nest inside the
        // icon's vertical extent.
        let stackTopY = iconRect.minY + iconSize * 0.03
        // iOS App Store row uses roughly ~30% of the title font size as the
        // gap between title baseline and subtitle ascent. Our drawText
        // helper draws from `topLeft` (the ascender top), so we add
        // descent + gap from the previous line's bottom.
        let titleSubtitleGap = iconSize * 0.10
        let subtitleStarsGap = iconSize * 0.06

        let nameTopY = stackTopY
        let subtitleTopY = nameTopY + nameLineHeight + titleSubtitleGap
        let starsTopY = subtitleTopY + subtitleLineHeight + subtitleStarsGap

        let nameTracking = -CGFloat(CTFontGetSize(nameFont)) * 0.018
        let subtitleTracking = -CGFloat(CTFontGetSize(subtitleFont)) * 0.012

        let truncatedName = truncateToFit(input.name, font: nameFont, maxWidth: nameBandWidth)
        drawText(
            into: ctx, text: truncatedName,
            font: nameFont, color: theme.primaryText,
            topLeft: CGPoint(x: textLeftX, y: nameTopY),
            maxWidth: nameBandWidth,
            tracking: nameTracking
        )

        let truncatedSubtitle = truncateToFit(input.subtitle, font: subtitleFont, maxWidth: nameBandWidth)
        if !truncatedSubtitle.isEmpty {
            drawText(
                into: ctx, text: truncatedSubtitle,
                font: subtitleFont, color: theme.secondaryText,
                topLeft: CGPoint(x: textLeftX, y: subtitleTopY),
                maxWidth: nameBandWidth,
                tracking: subtitleTracking
            )
        }

        drawStarsRow(
            into: ctx,
            leftX: textLeftX,
            topY: starsTopY,
            scale: starsScale,
            rating: input.rating,
            reviews: input.reviews,
            theme: theme
        )

        // Meta row: categories | developer. Lives BELOW the icon, spanning
        // the full card width.
        let belowIconY = max(iconRect.maxY, starsTopY + starsLineHeight) + iconSize * 0.20
        let metaScale = iconSize * 0.26
        drawMetaRow(
            into: ctx,
            leftX: cardRect.minX,
            topY: belowIconY,
            cardRect: cardRect,
            categories: input.categories,
            developer: input.developer,
            theme: theme,
            scale: metaScale
        )

        // Screenshot strip: 3-up grid below the meta row.
        let metaLineHeight = metaScale + iconSize * 0.06
        let stripTopY = belowIconY + metaLineHeight + iconSize * 0.20
        drawScreenshotStrip(
            into: ctx,
            cardRect: cardRect,
            stripTopY: stripTopY,
            screenshots: input.screenshotPaths,
            theme: theme
        )
    }

    private static func actionLabel(_ action: SearchPreviewAction, price: String?) -> String {
        switch action {
        case .get:    return "GET"
        case .open:   return "OPEN"
        case .update: return "UPDATE"
        case .price:  return price?.isEmpty == false ? price! : "$0.99"
        }
    }

    // MARK: - Stars + reviews

    private func drawStarsRow(
        into ctx: CGContext,
        leftX: CGFloat,
        topY: CGFloat,
        scale: CGFloat,
        rating: Double,
        reviews: String,
        theme: Theme
    ) {
        let filledCount = Int(rating.rounded().clamped(to: 0...5))
        let starFont = systemFont(size: scale * 1.4, weight: .regular)
        let starWidth = scale * 1.4
        let starGap = scale * 0.10
        var cursorX = leftX
        let centerY = topY + starWidth / 2
        for i in 0..<5 {
            let glyph = i < filledCount ? "★" : "☆"
            drawTextCentered(
                into: ctx, text: glyph,
                font: starFont, color: theme.secondaryText,
                center: CGPoint(x: cursorX + starWidth / 2, y: centerY)
            )
            cursorX += starWidth + starGap
        }
        if !reviews.isEmpty {
            cursorX += scale * 0.5
            drawText(
                into: ctx,
                text: reviews,
                font: systemFont(size: scale * 1.05, weight: .regular),
                color: theme.secondaryText,
                topLeft: CGPoint(x: cursorX, y: topY + scale * 0.20)
            )
        }
    }

    // MARK: - Meta row

    /// Draws the search-row meta line, App Store style:
    ///   `[icon] Cat1 | [icon] Cat2   [person.crop.square] Developer`
    ///
    /// Pipes separate consecutive categories only — the developer chunk is
    /// preceded by whitespace and a `person.crop.square` glyph, never a pipe.
    /// Category SF Symbols come from `SearchPreviewRenderer.categorySymbol`;
    /// categories without an icon mapping render with text only.
    private func drawMetaRow(
        into ctx: CGContext,
        leftX: CGFloat,
        topY: CGFloat,
        cardRect: CGRect,
        categories: [String],
        developer: String,
        theme: Theme,
        scale: CGFloat
    ) {
        let cats = categories.filter { !$0.isEmpty }
        guard !cats.isEmpty || !developer.isEmpty else { return }

        let font = systemFont(size: scale, weight: .regular)
        var cursorX = leftX
        let pipeColor = theme.secondaryText.withAlphaComponent(0.5)
        let iconSize = scale * 1.0
        let iconGap = scale * 0.18

        // Categories with optional leading SF Symbol icon, pipe-separated.
        for (idx, cat) in cats.enumerated() {
            if idx > 0 {
                let pipeWidth = measureText("|", font: font)
                let gap = scale * 0.4
                drawText(
                    into: ctx, text: "|",
                    font: font, color: pipeColor,
                    topLeft: CGPoint(x: cursorX + gap / 2, y: topY)
                )
                cursorX += pipeWidth + gap
            }
            if let symbolName = Self.categorySymbol[cat] {
                drawSymbol(
                    symbolName, into: ctx,
                    rect: CGRect(
                        x: cursorX,
                        y: topY,
                        width: iconSize, height: iconSize
                    ),
                    color: theme.secondaryText,
                    weight: .regular
                )
                cursorX += iconSize + iconGap
            }
            let width = measureText(cat, font: font)
            if cursorX + width > cardRect.maxX { return }
            drawText(
                into: ctx, text: cat,
                font: font, color: theme.secondaryText,
                topLeft: CGPoint(x: cursorX, y: topY)
            )
            cursorX += width + scale * 0.3
        }

        // Developer chunk: whitespace separator (no pipe), then person.crop.square + name.
        guard !developer.isEmpty else { return }
        if !cats.isEmpty {
            cursorX += scale * 0.5
        }
        drawSymbol(
            "person.crop.square", into: ctx,
            rect: CGRect(
                x: cursorX,
                y: topY,
                width: iconSize, height: iconSize
            ),
            color: theme.secondaryText,
            weight: .regular
        )
        cursorX += iconSize + iconGap
        let devWidth = measureText(developer, font: font)
        if cursorX + devWidth > cardRect.maxX { return }
        drawText(
            into: ctx, text: developer,
            font: font, color: theme.secondaryText,
            topLeft: CGPoint(x: cursorX, y: topY)
        )
    }

    // MARK: - Screenshot strip

    private func drawScreenshotStrip(
        into ctx: CGContext,
        cardRect: CGRect,
        stripTopY: CGFloat,
        screenshots: [URL],
        theme: Theme
    ) {
        let count = 3
        let gap = cardRect.width * 0.020
        let tileWidth = (cardRect.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let tileHeight = tileWidth * (19.5 / 9.0)

        for i in 0..<count {
            let tileX = cardRect.minX + CGFloat(i) * (tileWidth + gap)
            let tileRect = CGRect(
                x: tileX, y: stripTopY,
                width: tileWidth, height: tileHeight
            )
            let cornerRadius = tileWidth * 0.05
            let tilePath = CGPath(
                roundedRect: tileRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )

            ctx.saveGState()
            ctx.addPath(tilePath)
            ctx.setFillColor(theme.screenshotPlaceholder.cgColor)
            ctx.fillPath()

            if i < screenshots.count, let img = loadImage(screenshots[i]) {
                ctx.saveGState()
                ctx.addPath(tilePath)
                ctx.clip()
                // Un-flip locally so the image lands right-side-up.
                let fit = aspectFill(
                    imageSize: CGSize(width: img.width, height: img.height),
                    in: tileRect
                )
                ctx.saveGState()
                ctx.translateBy(x: fit.minX, y: fit.minY + fit.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: fit.width, height: fit.height))
                ctx.restoreGState()
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
    }

    private func aspectFill(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: - Text helpers

    private func systemFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        return NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    }

    private func attributedString(
        _ text: String,
        font: CTFont,
        color: NSColor,
        tracking: CGFloat = 0
    ) -> NSAttributedString {
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: tracking,
            ]
        )
    }

    private func measureText(_ text: String, font: CTFont) -> CGFloat {
        let attr = attributedString(text, font: font, color: .black)
        let line = CTLineCreateWithAttributedString(attr)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func truncateToFit(_ text: String, font: CTFont, maxWidth: CGFloat) -> String {
        guard maxWidth > 0, !text.isEmpty else { return text }
        if measureText(text, font: font) <= maxWidth { return text }
        let ellipsis = "…"
        var chars = Array(text)
        while !chars.isEmpty {
            let candidate = String(chars) + ellipsis
            if measureText(candidate, font: font) <= maxWidth { return candidate }
            chars.removeLast()
        }
        return ellipsis
    }

    /// Draw text with its top-left at `topLeft` (visual y, growing down).
    /// The context is assumed to be flipped (translateBy + scaleBy(1,-1));
    /// we wrap each draw call in a local un-flip so glyphs land right-side-
    /// up regardless of the outer transform.
    ///
    /// `tracking` adjusts inter-glyph spacing. iOS App Store rows use a slight
    /// negative tracking on the name + subtitle (display-style optical
    /// adjustment). Default 0 leaves the system kerning unchanged.
    private func drawText(
        into ctx: CGContext,
        text: String,
        font: CTFont,
        color: NSColor,
        topLeft: CGPoint,
        maxWidth: CGFloat? = nil,
        tracking: CGFloat = 0
    ) {
        guard !text.isEmpty else { return }
        let attr = attributedString(text, font: font, color: color, tracking: tracking)
        let line = CTLineCreateWithAttributedString(attr)
        let ascent = CGFloat(CTFontGetAscent(font))

        ctx.saveGState()
        if let maxWidth {
            ctx.clip(to: CGRect(
                x: topLeft.x,
                y: topLeft.y,
                width: maxWidth,
                height: ascent + CGFloat(CTFontGetDescent(font)) + CGFloat(CTFontGetLeading(font))
            ))
        }
        // Un-flip locally so CT text renders right-side-up.
        ctx.translateBy(x: topLeft.x, y: topLeft.y + ascent)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Draw text centered horizontally and vertically on `center`.
    private func drawTextCentered(
        into ctx: CGContext,
        text: String,
        font: CTFont,
        color: NSColor,
        center: CGPoint
    ) {
        guard !text.isEmpty else { return }
        let attr = attributedString(text, font: font, color: color)
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ascent + descent

        ctx.saveGState()
        ctx.translateBy(x: center.x - width / 2, y: center.y + textHeight / 2 - descent)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - SF Symbol drawing

    /// Render the named SF Symbol into the flipped CGContext at `rect`,
    /// tinted to `color`. Falls back to a no-op if the symbol is unavailable
    /// on the current macOS (e.g. running against an older SDK).
    ///
    /// The symbol's intrinsic bounding box is centered inside `rect`, scaled
    /// so the larger of (width, height) matches the corresponding side of
    /// the target rect — i.e. fit-into-rect, never crop.
    func drawSymbol(
        _ name: String,
        into ctx: CGContext,
        rect: CGRect,
        color: NSColor,
        weight: NSFont.Weight = .regular
    ) {
        let pointSize = max(rect.height, rect.width)
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if #available(macOS 13, *) {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        var nsRect = NSRect(origin: .zero, size: symbol.size)
        guard let cgImg = symbol.cgImage(forProposedRect: &nsRect, context: nil, hints: nil) else { return }

        // Fit the symbol's natural bbox inside `rect` preserving aspect ratio.
        let symW = CGFloat(cgImg.width)
        let symH = CGFloat(cgImg.height)
        guard symW > 0, symH > 0 else { return }
        let scale = min(rect.width / symW, rect.height / symH)
        let drawW = symW * scale
        let drawH = symH * scale
        let drawRect = CGRect(
            x: rect.midX - drawW / 2,
            y: rect.midY - drawH / 2,
            width: drawW, height: drawH
        )

        ctx.saveGState()
        // The outer context is flipped (translate + scale -1). Un-flip the
        // symbol locally so it lands right-side-up.
        ctx.translateBy(x: drawRect.minX, y: drawRect.minY + drawRect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: drawRect.width, height: drawRect.height))
        ctx.restoreGState()
    }
}

// MARK: - Category icons

extension SearchPreviewRenderer {
    /// SF Symbol mapping for App Store categories. Keys are the friendly
    /// display strings produced by `SearchPreviewResolver.friendlyCategory(_:)`;
    /// values are SF Symbol names that ship with macOS 14. Categories that
    /// aren't in this map render with no leading icon (legacy behavior).
    static let categorySymbol: [String: String] = [
        "Books":                  "book",
        "Business":               "briefcase",
        "Developer Tools":        "hammer",
        "Education":              "graduationcap",
        "Entertainment":          "tv",
        "Finance":                "dollarsign.circle",
        "Food & Drink":           "fork.knife",
        "Games":                  "gamecontroller",
        "Graphics & Design":      "paintbrush.pointed",
        "Health & Fitness":       "heart",
        "Lifestyle":              "figure.stand",
        "Magazines & Newspapers": "newspaper",
        "Medical":                "stethoscope",
        "Music":                  "music.note",
        "Navigation":             "location.circle",
        "News":                   "newspaper",
        "Photo & Video":          "camera",
        "Productivity":           "square.and.pencil",
        "Reference":              "text.book.closed",
        "Shopping":               "cart",
        "Social Networking":      "bubble.left.and.bubble.right",
        "Sports":                 "sportscourt",
        "Travel":                 "airplane",
        "Utilities":              "wrench.and.screwdriver",
        "Weather":                "cloud.sun",
    ]
}

// MARK: - Theme

extension SearchPreviewRenderer {
    struct Theme {
        let canvasBackground: NSColor
        let bezelBackground: NSColor
        let statusBarText: NSColor
        let statusBarIcon: NSColor
        let searchBarBackground: NSColor
        let searchBarText: NSColor
        let searchBarPlaceholder: NSColor
        let primaryText: NSColor
        let secondaryText: NSColor
        let iconPlaceholderBackground: NSColor
        let iconPlaceholderText: NSColor
        let iconStroke: NSColor
        let screenshotPlaceholder: NSColor
        let actionBackground: NSColor
        let actionText: NSColor

        static func resolve(appearance: String) -> Theme {
            switch appearance.lowercased() {
            case "dark":
                return Theme(
                    canvasBackground:           NSColor(hex: 0x000000),
                    bezelBackground:            NSColor(hex: 0x000000),
                    statusBarText:              NSColor.white,
                    statusBarIcon:              NSColor.white,
                    searchBarBackground:        NSColor(hex: 0x1C1C1E),
                    searchBarText:              NSColor.white,
                    searchBarPlaceholder:       NSColor(hex: 0x8E8E93),
                    primaryText:                NSColor.white,
                    secondaryText:              NSColor(hex: 0x8E8E93),
                    iconPlaceholderBackground:  NSColor(hex: 0x2C2C2E),
                    iconPlaceholderText:        NSColor(hex: 0x636366),
                    iconStroke:                 NSColor.white.withAlphaComponent(0.08),
                    screenshotPlaceholder:      NSColor(hex: 0x1C1C1E),
                    actionBackground:           NSColor(hex: 0x1C3A5C),
                    actionText:                 NSColor(hex: 0x0A84FF)
                )
            default:
                return Theme(
                    canvasBackground:           NSColor(hex: 0xF2F2F7),
                    bezelBackground:            NSColor.white,
                    statusBarText:              NSColor.black,
                    statusBarIcon:              NSColor.black,
                    searchBarBackground:        NSColor(hex: 0xE3E3E8),
                    searchBarText:              NSColor.black,
                    searchBarPlaceholder:       NSColor(hex: 0x8E8E93),
                    primaryText:                NSColor.black,
                    secondaryText:              NSColor(hex: 0x636366),
                    iconPlaceholderBackground:  NSColor(hex: 0xF2F2F7),
                    iconPlaceholderText:        NSColor(hex: 0x8E8E93),
                    iconStroke:                 NSColor.black.withAlphaComponent(0.08),
                    screenshotPlaceholder:      NSColor(hex: 0xF2F2F7),
                    actionBackground:           NSColor(red: 0, green: 122/255, blue: 1, alpha: 0.12),
                    actionText:                 NSColor(red: 0, green: 122/255, blue: 1, alpha: 1)
                )
            }
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}
