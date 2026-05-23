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
        let width = Int(Self.canvasWidth)
        let height = Int(Self.canvasHeight)
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
        ctx.translateBy(x: 0, y: Self.canvasHeight)
        ctx.scaleBy(x: 1, y: -1)

        let theme = Theme.resolve(appearance: input.appearance)

        // 1. Canvas background.
        ctx.setFillColor(theme.canvasBackground.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: Self.canvasWidth, height: Self.canvasHeight))

        let canvas = CGRect(x: 0, y: 0, width: Self.canvasWidth, height: Self.canvasHeight)

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
            drawCard(into: ctx, cardRect: cardRect, theme: theme, input: input)
        case .none:
            let padding: CGFloat = canvas.width * 0.04
            let cardRect = CGRect(
                x: padding,
                y: canvas.height * 0.05,
                width: canvas.width - 2 * padding,
                height: canvas.height * 0.55
            )
            drawCard(into: ctx, cardRect: cardRect, theme: theme, input: input)
        }

        try writePNG(ctx: ctx, url: input.outputURL)
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
        theme: Theme,
        input: SearchPreviewInput
    ) {
        let cardW = cardRect.width
        let canvasH = Self.canvasHeight
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
        let actionFont = systemFont(size: iconSize * 0.34, weight: .bold)
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

        // Name + subtitle text band, right of the icon.
        let textLeftX = iconRect.maxX + cardW * 0.035
        let nameBandWidth = actionRect.minX - textLeftX - cardW * 0.02

        let nameFont = systemFont(size: iconSize * 0.40, weight: .semibold)
        let subtitleFont = systemFont(size: iconSize * 0.30, weight: .regular)
        let nameAscent = CGFloat(CTFontGetAscent(nameFont))
        let subtitleAscent = CGFloat(CTFontGetAscent(subtitleFont))
        let nameLineHeight = nameAscent + CGFloat(CTFontGetDescent(nameFont))
        let subtitleLineHeight = subtitleAscent + CGFloat(CTFontGetDescent(subtitleFont))

        let truncatedName = truncateToFit(input.name, font: nameFont, maxWidth: nameBandWidth)
        drawText(
            into: ctx, text: truncatedName,
            font: nameFont, color: theme.primaryText,
            topLeft: CGPoint(x: textLeftX, y: iconRect.minY + iconSize * 0.05),
            maxWidth: nameBandWidth
        )

        let truncatedSubtitle = truncateToFit(input.subtitle, font: subtitleFont, maxWidth: nameBandWidth)
        if !truncatedSubtitle.isEmpty {
            drawText(
                into: ctx, text: truncatedSubtitle,
                font: subtitleFont, color: theme.secondaryText,
                topLeft: CGPoint(
                    x: textLeftX,
                    y: iconRect.minY + iconSize * 0.05 + nameLineHeight * 1.10
                ),
                maxWidth: nameBandWidth
            )
        }

        // Stars + reviews row, directly below the icon.
        let starsTopY = iconRect.maxY + iconSize * 0.18
        drawStarsRow(
            into: ctx,
            leftX: cardRect.minX,
            topY: starsTopY,
            scale: iconSize * 0.30,
            rating: input.rating,
            reviews: input.reviews,
            theme: theme
        )

        // Meta row: categories | developer.
        let starGlyphSize = iconSize * 0.30 * 1.2
        let metaTopY = starsTopY + starGlyphSize + iconSize * 0.10
        let metaScale = iconSize * 0.28
        drawMetaRow(
            into: ctx,
            leftX: cardRect.minX,
            topY: metaTopY,
            cardRect: cardRect,
            categories: input.categories,
            developer: input.developer,
            theme: theme,
            scale: metaScale
        )

        // Screenshot strip: 3-up grid below the meta row.
        let metaLineHeight = metaScale + iconSize * 0.06
        let stripTopY = metaTopY + metaLineHeight + iconSize * 0.20
        drawScreenshotStrip(
            into: ctx,
            cardRect: cardRect,
            stripTopY: stripTopY,
            screenshots: input.screenshotPaths,
            theme: theme
        )

        _ = subtitleLineHeight  // silence unused-let if linter complains
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
        var chunks: [String] = categories.filter { !$0.isEmpty }
        let developerMarker = "\u{F8FF}"   // private-use Unicode as a chunk marker
        if !developer.isEmpty { chunks.append(developerMarker + developer) }
        guard !chunks.isEmpty else { return }

        let font = systemFont(size: scale, weight: .regular)
        var cursorX = leftX
        let pipeColor = theme.secondaryText.withAlphaComponent(0.5)

        for (idx, chunk) in chunks.enumerated() {
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
            if chunk.hasPrefix(developerMarker) {
                let dev = String(chunk.dropFirst())
                drawPersonGlyph(
                    into: ctx,
                    topLeft: CGPoint(x: cursorX, y: topY),
                    scale: scale,
                    color: theme.secondaryText
                )
                cursorX += scale * 1.1
                let devWidth = measureText(dev, font: font)
                if cursorX + devWidth > cardRect.maxX { return }
                drawText(
                    into: ctx, text: dev,
                    font: font, color: theme.secondaryText,
                    topLeft: CGPoint(x: cursorX, y: topY)
                )
                cursorX += devWidth + scale * 0.3
            } else {
                let width = measureText(chunk, font: font)
                if cursorX + width > cardRect.maxX { return }
                drawText(
                    into: ctx, text: chunk,
                    font: font, color: theme.secondaryText,
                    topLeft: CGPoint(x: cursorX, y: topY)
                )
                cursorX += width + scale * 0.3
            }
        }
    }

    /// Tiny "person" silhouette: filled circle head + rounded shoulders.
    private func drawPersonGlyph(
        into ctx: CGContext,
        topLeft: CGPoint,
        scale: CGFloat,
        color: NSColor
    ) {
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        let headRadius = scale * 0.26
        let headRect = CGRect(
            x: topLeft.x + scale * 0.20,
            y: topLeft.y + scale * 0.06,
            width: headRadius * 2,
            height: headRadius * 2
        )
        ctx.fillEllipse(in: headRect)
        let bodyW = scale * 0.95
        let bodyH = scale * 0.42
        let bodyRect = CGRect(
            x: topLeft.x + (scale - bodyW) / 2,
            y: topLeft.y + scale * 0.55,
            width: bodyW,
            height: bodyH
        )
        ctx.addPath(CGPath(
            roundedRect: bodyRect,
            cornerWidth: bodyH * 0.8,
            cornerHeight: bodyH * 0.8,
            transform: nil
        ))
        ctx.fillPath()
        ctx.restoreGState()
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

    private func attributedString(_ text: String, font: CTFont, color: NSColor) -> NSAttributedString {
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: 0.0,
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
    private func drawText(
        into ctx: CGContext,
        text: String,
        font: CTFont,
        color: NSColor,
        topLeft: CGPoint,
        maxWidth: CGFloat? = nil
    ) {
        guard !text.isEmpty else { return }
        let attr = attributedString(text, font: font, color: color)
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
