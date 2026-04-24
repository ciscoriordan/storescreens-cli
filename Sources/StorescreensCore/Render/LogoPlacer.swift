import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// Places a logo image at the top of a slide. Placement rules (from config):
///   first_only — only render on the first slide per (device, locale, appearance) combo
///   all        — render on every slide
///   none       — skip entirely
///
/// Sizing: `max_height_pct` of canvas height, aspect preserved.
/// Position: horizontally centered, `top_padding_pct` from the top.
package struct LogoPlacer {

    package let baseDirectory: URL

    package init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Returns the pixel height the logo will occupy (for layout math),
    /// or 0 if nothing will be drawn. Call before caption layout so caption
    /// reservation can account for the logo when it's present on slide 0.
    package func reservedHeight(
        _ config: LogoConfig?,
        appearance: String,
        canvasSize: CGSize,
        isFirstInCombo: Bool
    ) -> CGFloat {
        guard let config,
              shouldDraw(config: config, isFirstInCombo: isFirstInCombo),
              config.path?.value(for: appearance) != nil else {
            return 0
        }
        let maxPct = config.maxHeightPct ?? 8
        let topPct = config.topPaddingPct ?? 4
        return canvasSize.height * CGFloat(maxPct + topPct) / 100.0
    }

    /// Draws the logo into `ctx`. Safe to call unconditionally — returns
    /// without drawing when config / placement rules say no.
    ///
    /// `verticalCenterY` is the bottom-left-origin Y at which the logo
    /// should be vertically centered. When non-nil the caller has
    /// computed an "equidistant from canvas top and device top" target
    /// Y (accounting for chrome padding below the caption reservation)
    /// and we honor it. When nil we fall back to centering the logo
    /// inside its own reservation band — same behavior as before the
    /// caller-controlled override existed.
    package func drawLogo(
        _ config: LogoConfig?,
        appearance: String,
        isFirstInCombo: Bool,
        into ctx: CGContext,
        canvasSize: CGSize,
        verticalCenterY: CGFloat? = nil
    ) {
        guard let config,
              shouldDraw(config: config, isFirstInCombo: isFirstInCombo),
              let path = config.path?.value(for: appearance),
              let image = loadImage(path: path) else {
            return
        }

        let maxHeightPct = CGFloat(config.maxHeightPct ?? 8)
        let topPaddingPct = CGFloat(config.topPaddingPct ?? 4)
        let maxHeight = canvasSize.height * maxHeightPct / 100.0

        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)
        let scale = min(maxHeight / ih, canvasSize.width / iw)
        let drawW = iw * scale
        let drawH = ih * scale

        // CGContext has bottom-left origin: y = canvasSize.height is
        // the top of the canvas.
        let centerY: CGFloat
        if let verticalCenterY {
            centerY = verticalCenterY
        } else {
            // Center the logo vertically within its reservation band
            // (the top `maxHeightPct + topPaddingPct` percent of the
            // canvas) — default behavior when the caller hasn't
            // computed an equidistant target.
            let reservedHeight = canvasSize.height * (maxHeightPct + topPaddingPct) / 100.0
            centerY = canvasSize.height - reservedHeight / 2
        }
        // Nudge: x positive = right, y positive = up (toward screen top).
        // Expressed as percentages of canvas dimensions so a logo offset
        // scales naturally across iPhone / iPad / Mac sizes.
        let nudgeX = CGFloat(config.nudge?.xPct ?? 0) * canvasSize.width / 100.0
        let nudgeY = CGFloat(config.nudge?.yPct ?? 0) * canvasSize.height / 100.0

        let x = (canvasSize.width - drawW) / 2 + nudgeX
        let yBottom = centerY - drawH / 2 + nudgeY

        ctx.draw(image, in: CGRect(x: x, y: yBottom, width: drawW, height: drawH))
    }

    private func shouldDraw(config: LogoConfig, isFirstInCombo: Bool) -> Bool {
        switch config.placement ?? .firstOnly {
        case .firstOnly: return isFirstInCombo
        case .all: return true
        case .none: return false
        }
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
