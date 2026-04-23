import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// Composites the captured screenshot onto the canvas with the configured
/// chrome style. Three dispatched paths:
///   none      — screenshot drawn as-is at padding-inset rect
///   stroke    — screenshot clipped to rounded rect with optional border/shadow
///   bezel  — screenshot placed inside a device bezel PNG from BezelStore
package struct ChromeRenderer {

    package let bezelStore: BezelStore

    package init(bezelStore: BezelStore) {
        self.bezelStore = bezelStore
    }

    package enum RenderError: Error, CustomStringConvertible {
        case missingBezel(canonicalKey: String)
        case screenshotLoadFailed(URL)

        package var description: String {
            switch self {
            case .missingBezel(let k):
                return "bezel chrome requires a bezel for '\(k)' — run `storescreens bezels import` or switch to chrome.style: stroke"
            case .screenshotLoadFailed(let u):
                return "failed to load screenshot: \(u.path)"
            }
        }
    }

    /// Draws the screenshot into a reserved rect at the bottom of `canvasRect`,
    /// applying chrome per `config`. `canvasRect` is the full canvas; this
    /// renderer reserves the area below the caption block.
    ///
    /// `screenshotRegion` is the rect (in bottom-left CG coords) available to
    /// the chrome; the caller computes this from caption reservation + logo +
    /// padding.
    package func drawChrome(
        _ config: ChromeConfig?,
        screenshotURL: URL,
        productFamily: Int,
        orientation: BezelOrientation,
        screenshotPixelSize: CGSize,
        into ctx: CGContext,
        chromeRect: CGRect
    ) throws {
        let style = config?.style ?? .none

        switch style {
        case .none:
            try drawNone(screenshotURL: screenshotURL,
                         config: config, into: ctx, rect: chromeRect)
        case .stroke:
            try drawStroke(screenshotURL: screenshotURL,
                           config: config, into: ctx, rect: chromeRect,
                           productFamily: productFamily)
        case .bezel:
            try drawBezel(screenshotURL: screenshotURL,
                          config: config, into: ctx, rect: chromeRect,
                          productFamily: productFamily,
                          orientation: orientation,
                          screenshotPixelSize: screenshotPixelSize)
        }
    }

    // MARK: - none

    private func drawNone(
        screenshotURL: URL,
        config: ChromeConfig?,
        into ctx: CGContext,
        rect: CGRect
    ) throws {
        let img = try loadImage(screenshotURL)
        let padded = inset(rect, config: config)
        let fit = fitRect(
            imageSize: CGSize(width: img.width, height: img.height),
            in: padded,
            mode: config?.fit ?? .width
        )
        drawImage(img, in: fit, ctx: ctx)
    }

    // MARK: - stroke

    private func drawStroke(
        screenshotURL: URL,
        config: ChromeConfig?,
        into ctx: CGContext,
        rect: CGRect,
        productFamily: Int
    ) throws {
        let img = try loadImage(screenshotURL)
        let padded = inset(rect, config: config)
        let fit = fitRect(
            imageSize: CGSize(width: img.width, height: img.height),
            in: padded,
            mode: config?.fit ?? .width
        )
        let radius = resolveCornerRadius(config: config, rect: fit, productFamily: productFamily)

        ctx.saveGState()

        if config?.shadow ?? true {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -min(fit.width, fit.height) * 0.015),
                blur: min(fit.width, fit.height) * 0.04,
                color: NSColor.black.withAlphaComponent(0.35).cgColor
            )
        }

        // Fill behind the screenshot so the rounded-rect clip produces a
        // sharp alpha edge (important when there's no background image).
        let path = CGPath(roundedRect: fit, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()

        // Clip + draw screenshot
        ctx.addPath(path)
        ctx.clip()
        drawImage(img, in: fit, ctx: ctx)
        ctx.restoreGState()

        // Border (stroke) drawn un-clipped so it sits on top of the edge.
        if let strokeWidth = config?.strokeWidth, strokeWidth > 0 {
            let color = config?.strokeColor.flatMap(RenderColors.parseHex) ?? .white
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(CGFloat(strokeWidth))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - bezel

    private func drawBezel(
        screenshotURL: URL,
        config: ChromeConfig?,
        into ctx: CGContext,
        rect: CGRect,
        productFamily: Int,
        orientation: BezelOrientation,
        screenshotPixelSize: CGSize
    ) throws {
        let screenshotImg = try loadImage(screenshotURL)

        let key = BezelStore.canonicalKey(
            productFamily: productFamily,
            width: Int(screenshotPixelSize.width.rounded()),
            height: Int(screenshotPixelSize.height.rounded()),
            orientation: orientation
        )

        guard let asset = bezelStore.lookup(canonicalKey: key) else {
            throw RenderError.missingBezel(canonicalKey: key)
        }
        guard let bezelSrc = CGImageSourceCreateWithURL(asset.pngURL as CFURL, nil),
              let bezelImg = CGImageSourceCreateImageAtIndex(bezelSrc, 0, nil) else {
            throw RenderError.screenshotLoadFailed(asset.pngURL)
        }

        let metadata = asset.metadata
        let canvasW = CGFloat(metadata.canvasWidth)
        let canvasH = CGFloat(metadata.canvasHeight)
        let padded = inset(rect, config: config)

        // Fit the bezel canvas inside the chrome rect per the configured
        // fit mode. `width` (default) lets the device bleed past the bottom
        // when its aspect is taller than the padded rect — standard App
        // Store style.
        let bezelTargetRect = fitRect(
            imageSize: CGSize(width: canvasW, height: canvasH),
            in: padded,
            mode: config?.fit ?? .width
        )
        let scaleX = bezelTargetRect.width / canvasW
        let scaleY = bezelTargetRect.height / canvasH

        // Screenshot goes inside the scaled Screen rect.
        let screenInBezel = CGRect(
            x: CGFloat(metadata.screenX) * scaleX + bezelTargetRect.minX,
            // Flip Y: metadata.screenY is top-left; bezelTargetRect is bottom-left origin.
            y: bezelTargetRect.maxY - (CGFloat(metadata.screenY) + CGFloat(metadata.screenHeight)) * scaleY,
            width: CGFloat(metadata.screenWidth) * scaleX,
            height: CGFloat(metadata.screenHeight) * scaleY
        )

        // Device-shaped shadow: create a black silhouette matching the
        // bezel's alpha (so rounded phone corners, notch cutouts, etc. all
        // shadow correctly) and draw that with CG shadow enabled. A plain
        // rectangle would leak black corners past the bezel's rounded body.
        if config?.shadow ?? true, let silhouette = makeSilhouette(from: bezelImg) {
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -bezelTargetRect.height * 0.01),
                blur: bezelTargetRect.height * 0.025,
                color: NSColor.black.withAlphaComponent(0.4).cgColor
            )
            ctx.draw(silhouette, in: bezelTargetRect)
            ctx.restoreGState()
        }

        // 1. Draw screenshot inside the Screen rect, clipped to a rounded
        //    rect so its corners don't poke past the bezel's rounded display
        //    cut-out. Radius is device-class-derived in native px.
        let screenCornerRadius = bezelScreenCornerRadius(
            productFamily: productFamily,
            screenRect: screenInBezel
        )
        ctx.saveGState()
        let screenClipPath = CGPath(
            roundedRect: screenInBezel,
            cornerWidth: screenCornerRadius,
            cornerHeight: screenCornerRadius,
            transform: nil
        )
        ctx.addPath(screenClipPath)
        ctx.clip()
        drawImage(screenshotImg, in: screenInBezel, ctx: ctx)
        ctx.restoreGState()

        // 2. Draw bezel PNG on top (its transparent Screen area lets the
        //    screenshot show through)
        drawImage(bezelImg, in: bezelTargetRect, ctx: ctx)
    }

    /// Returns a black silhouette of `bezel` (all opaque pixels → black, all
    /// transparent pixels stay transparent). Used to cast a device-shaped
    /// drop shadow — a rectangle silhouette would leak past the bezel's
    /// rounded device body.
    private func makeSilhouette(from bezel: CGImage) -> CGImage? {
        let w = bezel.width
        let h = bezel.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let tmp = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        tmp.draw(bezel, in: rect)
        // sourceIn blend replaces the RGB of existing pixels while preserving
        // their alpha. After this fill, opaque bezel pixels are solid black,
        // transparent pixels remain transparent.
        tmp.setBlendMode(.sourceIn)
        tmp.setFillColor(NSColor.black.cgColor)
        tmp.fill(rect)
        return tmp.makeImage()
    }

    /// Device-display corner radius in screen-pixel units. Delegates to the
    /// shared table in `BezelExporter` so the screenshot's rounded clip and
    /// the bezel's screen hole line up exactly.
    private func bezelScreenCornerRadius(productFamily: Int, screenRect: CGRect) -> CGFloat {
        BezelExporter.deviceScreenCornerRadius(productFamily: productFamily, screenSize: screenRect.size)
    }

    // MARK: - helpers

    private func inset(_ rect: CGRect, config: ChromeConfig?) -> CGRect {
        let pct = CGFloat(config?.paddingPct ?? 4)
        let dx = rect.width * pct / 100.0
        let dy = rect.height * pct / 100.0
        return rect.insetBy(dx: dx, dy: dy)
    }

    private func fitRect(imageSize: CGSize, in bounds: CGRect, mode: ChromeFit) -> CGRect {
        let scale: CGFloat
        switch mode {
        case .width:
            scale = bounds.width / imageSize.width
        case .height:
            scale = bounds.height / imageSize.height
        case .contain:
            scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        }
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        // Horizontally centered. Vertically anchored to the TOP of the bounds
        // so overflow (when mode=width and device is taller than bounds)
        // bleeds off the bottom — standard marketing-screenshot style.
        let x = bounds.midX - w / 2
        let y: CGFloat
        switch mode {
        case .width where h > bounds.height, .contain:
            y = bounds.minY + (bounds.height - h) / 2   // center
        case .width:
            y = bounds.minY + (bounds.height - h) / 2   // still center when device fits
        case .height:
            y = bounds.minY + (bounds.height - h) / 2
        }
        // `bounds` is in CG bottom-left coords: the chrome occupies [0, canvasH - reservedTop].
        // For fit=width with device taller than bounds, we want the device to
        // extend below y=bounds.minY (off-canvas). Anchoring to bounds.maxY - h
        // achieves that: the TOP of the device sits at the top of the bounds,
        // and any overflow hangs off the BOTTOM of the bounds (which is the
        // BOTTOM of the canvas).
        if mode == .width && h > bounds.height {
            return CGRect(x: x, y: bounds.maxY - h, width: w, height: h)
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        // `CGContext.draw(image:in:)` in a bottom-left context already emits
        // the image right-side-up. No Y flip needed.
        ctx.draw(image, in: rect)
    }

    /// Resolves the stroke-chrome corner radius from config. `auto` derives
    /// a sensible default from the device class.
    private func resolveCornerRadius(
        config: ChromeConfig?,
        rect: CGRect,
        productFamily: Int
    ) -> CGFloat {
        switch config?.cornerRadius ?? .auto {
        case .fixed(let px):
            return CGFloat(px)
        case .auto:
            // iPhone ≈ 55pt corner at native scale; most iPad 18pt; MacBook 8pt
            switch productFamily {
            case 1: return rect.width * 0.055   // iPhone
            case 2: return rect.width * 0.035   // iPad
            case 6: return rect.width * 0.008   // MacBook
            default: return rect.width * 0.03
            }
        }
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw RenderError.screenshotLoadFailed(url)
        }
        return img
    }
}
