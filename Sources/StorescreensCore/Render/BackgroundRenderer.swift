import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// Renders the background layer (solid fill or image) and the scrim overlay
/// for a single slide. Called once per slide at the bottom of the layer
/// stack, before logo / caption / chrome.
package struct BackgroundRenderer {

    package let baseDirectory: URL

    package init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Fills `canvasSize` with the configured background, picking the
    /// appropriate variant for `appearance` ("light" | "dark").
    ///
    /// When `slidesInCombo > 1` and a background IMAGE is set, the image is
    /// treated as a PANORAMA spanning all slides: it's scaled to fit a
    /// virtual canvas of width `canvasSize.width * slidesInCombo`, then the
    /// slice starting at `slideIndex * canvasSize.width` is drawn into this
    /// slide's canvas. Adjacent slides line up into one continuous backdrop
    /// when viewed side-by-side in App Store Connect. Solid and gradient
    /// fills remain per-slide (no slicing).
    package func drawBackground(
        _ config: BackgroundConfig?,
        appearance: String,
        into ctx: CGContext,
        canvasSize: CGSize,
        slideIndex: Int = 0,
        slidesInCombo: Int = 1
    ) {
        let canvas = CGRect(origin: .zero, size: canvasSize)

        // Color fill: single hex = solid; array of hexes = vertical gradient.
        // Variant aware via `color: { light, dark }`. Falls through to solid
        // black when nothing is configured, so the bitmap is never left
        // transparent behind the content.
        if let colorVariant = config?.color,
           let resolved = colorVariant.value(for: appearance) {
            drawColorFill(resolved, into: ctx, rect: canvas)
        } else {
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(canvas)
            ctx.restoreGState()
        }

        // Image layer
        guard let imageVariant = config?.image,
              let path = imageVariant.value(for: appearance),
              let cgImage = loadImage(path: path) else {
            return
        }

        let fit = config?.fit ?? .cover
        let align = config?.align ?? .center

        // Panorama sizing: the bg is laid out across the full combo width,
        // then only THIS slide's horizontal slice is drawn into its canvas.
        // The canvas itself stays at canvasSize — we translate the bg left
        // by (slideIndex * canvasWidth) and clip to the canvas rect.
        let panoramaSize = CGSize(
            width: canvasSize.width * CGFloat(max(1, slidesInCombo)),
            height: canvasSize.height
        )
        let panoramaBounds = CGRect(origin: .zero, size: panoramaSize)
        let panoramaTargetRect = computeRect(
            imageW: cgImage.width, imageH: cgImage.height,
            canvas: panoramaBounds, fit: fit, align: align
        )
        // Shift left by this slide's horizontal offset, then clip to canvas.
        let sliceOffsetX = canvasSize.width * CGFloat(slideIndex)
        let drawRectInPanorama = panoramaTargetRect.offsetBy(dx: -sliceOffsetX, dy: 0)

        ctx.saveGState()
        if fit == .tile {
            drawTiled(cgImage, in: canvas, ctx: ctx)
        } else {
            // Clip to the slide's canvas so the bg doesn't bleed into
            // neighboring rendered pixels (important when the panorama rect
            // extends past the canvas width).
            ctx.clip(to: canvas)
            // Top-left → bottom-left Y flip for CGContext.draw.
            let rect = CGRect(
                x: drawRectInPanorama.origin.x,
                y: canvasSize.height - drawRectInPanorama.origin.y - drawRectInPanorama.height,
                width: drawRectInPanorama.width,
                height: drawRectInPanorama.height
            )
            ctx.draw(cgImage, in: rect)
        }
        ctx.restoreGState()
    }

    /// Draws the scrim overlay on top of the background. Safe to call when
    /// `config` is nil (no-op).
    package func drawScrim(
        _ config: ScrimConfig?,
        into ctx: CGContext,
        canvasSize: CGSize
    ) {
        guard let scrim = config else { return }
        let canvas = CGRect(origin: .zero, size: canvasSize)

        // Gradient scrim wins if present, else solid.
        if let gradient = scrim.gradient {
            drawGradientScrim(gradient, color: scrim.color, into: ctx, canvas: canvas)
            return
        }

        guard let opacity = scrim.opacity, opacity > 0 else { return }
        let baseColor = scrim.color.flatMap(RenderColors.parseHex) ?? .black
        let fill = baseColor.withAlphaComponent(CGFloat(opacity))
        ctx.saveGState()
        ctx.setFillColor(fill.cgColor)
        ctx.fill(canvas)
        ctx.restoreGState()
    }

    // MARK: - Color fill (solid or gradient)

    private func drawColorFill(_ color: BackgroundColor, into ctx: CGContext, rect: CGRect) {
        switch color {
        case .solid(let hex):
            let ns = RenderColors.parseHex(hex) ?? .black
            ctx.saveGState()
            ctx.setFillColor(ns.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()

        case .gradient(let hexes):
            // Fill with the first stop first so transparent gradient stops
            // don't leave the canvas bitmap partially unfilled.
            let first = hexes.first.flatMap(RenderColors.parseHex) ?? .black
            ctx.saveGState()
            ctx.setFillColor(first.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()

            let cgColors = hexes.compactMap { RenderColors.parseHex($0)?.cgColor }
            guard cgColors.count >= 2 else { return }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            // Evenly distribute stops across [0, 1].
            let locations: [CGFloat] = (0..<cgColors.count).map {
                CGFloat($0) / CGFloat(cgColors.count - 1)
            }
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: cgColors as CFArray,
                locations: locations
            ) else { return }

            ctx.saveGState()
            // First hex = top of canvas visually. CGContext is bottom-left
            // origin, so start = top (maxY), end = bottom (minY).
            let start = CGPoint(x: rect.midX, y: rect.maxY)
            let end = CGPoint(x: rect.midX, y: rect.minY)
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
            ctx.restoreGState()
        }
    }

    // MARK: - Scrim internals

    private func drawGradientScrim(
        _ gradient: ScrimGradient,
        color: String?,
        into ctx: CGContext,
        canvas: CGRect
    ) {
        let baseColor = color.flatMap(RenderColors.parseHex) ?? .black
        let topAlpha = CGFloat(gradient.topOpacity ?? 0.6)
        let bottomAlpha = CGFloat(gradient.bottomOpacity ?? 0.0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        baseColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let components: [CGFloat] = [
            r, g, b, topAlpha,
            r, g, b, bottomAlpha,
        ]
        guard let cgGrad = CGGradient(
            colorSpace: colorSpace,
            colorComponents: components,
            locations: [0.0, 1.0],
            count: 2
        ) else { return }

        ctx.saveGState()
        // Top of canvas (visually) is y=canvas.maxY in CGContext coords.
        let start = CGPoint(x: canvas.midX, y: canvas.maxY)
        let end = CGPoint(x: canvas.midX, y: canvas.minY)
        ctx.drawLinearGradient(cgGrad, start: start, end: end, options: [])
        ctx.restoreGState()
    }

    private func drawTiled(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                ctx.draw(image, in: CGRect(x: x, y: y, width: w, height: h))
                x += w
            }
            y += h
        }
    }

    /// Rectangle (in top-left coord space relative to canvas) where an image
    /// should be drawn given fit + vertical align. The background's LEFT edge
    /// is always pinned to the canvas's left edge (x=0) so the same pixel
    /// column shows at x=0 on every slide — important for continuity across
    /// multi-screenshot App Store layouts. Vertical `align` is the only knob:
    /// top / center / bottom.
    private func computeRect(
        imageW: Int, imageH: Int,
        canvas: CGRect,
        fit: BackgroundFit,
        align: BackgroundAlign
    ) -> CGRect {
        let iw = CGFloat(imageW)
        let ih = CGFloat(imageH)
        let cw = canvas.width
        let ch = canvas.height

        let scale: CGFloat
        switch fit {
        case .cover:
            scale = max(cw / iw, ch / ih)
        case .contain:
            scale = min(cw / iw, ch / ih)
        case .tile:
            scale = 1
        }
        let drawW = iw * scale
        let drawH = ih * scale
        let x: CGFloat = 0   // always left-aligned
        let y: CGFloat
        switch align {
        case .top: y = 0
        case .center: y = (ch - drawH) / 2
        case .bottom: y = ch - drawH
        }
        return CGRect(x: x, y: y, width: drawW, height: drawH)
    }

    private func loadImage(path: String) -> CGImage? {
        let url = resolveURL(path)
        // NSImage handles SVG, PDF, PSD, PNG, JPG, TIFF; CGImageSource does not do SVG.
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
}
