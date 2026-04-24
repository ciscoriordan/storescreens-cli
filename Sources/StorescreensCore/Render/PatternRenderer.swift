import Foundation
import AppKit
import CoreGraphics

/// Procedural background patterns drawn directly into a `CGContext`. Sits in
/// the layer stack between the solid/gradient color fill and the image layer;
/// `BackgroundRenderer` owns the call ordering.
///
/// All patterns are deterministic — given the same canvas size they produce
/// the same pixels, so re-renders diff cleanly. Seeded with
/// `PatternRenderer.seed(slideIndex:slidesInCombo:)` to stay aligned across
/// adjacent slides when used as a panorama.
package struct PatternRenderer {

    package init() {}

    /// Draws the configured pattern across `canvasSize`. Caller is responsible
    /// for having already filled the background color beneath.
    ///
    /// `slideIndex` / `slidesInCombo` let multi-slide captures share a
    /// continuous pattern: the virtual pattern canvas is `slidesInCombo` wide
    /// and this slide's slice starts at `slideIndex * canvasSize.width`.
    package func draw(
        _ config: PatternConfig,
        into ctx: CGContext,
        canvasSize: CGSize,
        slideIndex: Int = 0,
        slidesInCombo: Int = 1
    ) {
        let accent = RenderColors.parseHex(config.color ?? "#000000") ?? .black
        let opacity = CGFloat(max(0, min(1, config.opacity ?? 0.25)))

        // Virtual canvas spanning the combo; slice this slide's portion and draw into `canvasSize`.
        let virtualWidth = canvasSize.width * CGFloat(max(1, slidesInCombo))
        let virtualSize = CGSize(width: virtualWidth, height: canvasSize.height)
        let offsetX = canvasSize.width * CGFloat(slideIndex)

        ctx.saveGState()
        // Clip to this slide's canvas so the virtual-canvas drawing doesn't bleed.
        ctx.clip(to: CGRect(origin: .zero, size: canvasSize))
        // Translate so the virtual canvas origin aligns with this slide's slice.
        ctx.translateBy(x: -offsetX, y: 0)

        switch config.pattern {
        case .topographic:
            drawTopographic(into: ctx, size: virtualSize, accent: accent, opacity: opacity)
        case .blueprintGrid:
            drawBlueprintGrid(into: ctx, size: virtualSize, accent: accent, opacity: opacity)
        case .duneLayers:
            drawDuneLayers(into: ctx, size: virtualSize, accent: accent, opacity: opacity)
        case .softWaves:
            drawSoftWaves(into: ctx, size: virtualSize, accent: accent, opacity: opacity)
        case .gamifiedShapes:
            drawGamifiedShapes(into: ctx, size: virtualSize, accent: accent, opacity: opacity)
        }

        ctx.restoreGState()
    }

    // MARK: - Topographic contour lines

    private func drawTopographic(
        into ctx: CGContext, size: CGSize, accent: NSColor, opacity: CGFloat
    ) {
        let shortEdge = min(size.width, size.height)
        let strokeWidth = max(1.5, shortEdge / 700)
        let spacing = shortEdge / 14
        let color = accent.withAlphaComponent(opacity)

        // Two focal "peaks" produce overlapping contour fields. Positions
        // are proportional to virtualSize so panoramas stay aligned across slides.
        let centers: [CGPoint] = [
            CGPoint(x: size.width * 0.22, y: size.height * 0.68),  // CG coords: bottom-left
            CGPoint(x: size.width * 0.78, y: size.height * 0.32),
        ]

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for (idx, center) in centers.enumerated() {
            let maxDist = max(
                hypot(center.x, center.y),
                hypot(size.width - center.x, center.y),
                hypot(center.x, size.height - center.y),
                hypot(size.width - center.x, size.height - center.y)
            )
            var radius = spacing * 0.5
            var ring = 0
            while radius < maxDist {
                wobblyCircle(
                    into: ctx,
                    center: center,
                    radius: radius,
                    amplitude: spacing * 0.22,
                    frequency: 6 + radius / (spacing * 3),
                    phase: Double(ring) * 0.7 + Double(idx) * 1.3
                )
                ctx.strokePath()
                radius += spacing
                ring += 1
            }
        }
        ctx.restoreGState()
    }

    private func wobblyCircle(
        into ctx: CGContext,
        center: CGPoint, radius: CGFloat,
        amplitude: CGFloat, frequency: Double, phase: Double
    ) {
        let steps = 160
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let theta = t * 2 * .pi
            let wobble = amplitude * CGFloat(sin(theta * frequency + phase))
            let r = radius + wobble
            let x = center.x + r * CGFloat(cos(theta))
            let y = center.y + r * CGFloat(sin(theta))
            if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) }
            else { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
    }

    // MARK: - Blueprint grid

    private func drawBlueprintGrid(
        into ctx: CGContext, size: CGSize, accent: NSColor, opacity: CGFloat
    ) {
        let shortEdge = min(size.width, size.height)
        let minor = shortEdge / 28
        let major = minor * 5
        let color = accent.withAlphaComponent(opacity)
        let minorColor = accent.withAlphaComponent(opacity * 0.45)

        // Minor grid
        ctx.saveGState()
        ctx.setStrokeColor(minorColor.cgColor)
        ctx.setLineWidth(max(0.75, shortEdge / 1600))
        var x: CGFloat = 0
        while x <= size.width {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: size.height))
            x += minor
        }
        var y: CGFloat = 0
        while y <= size.height {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: size.width, y: y))
            y += minor
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Major grid
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(max(1.2, shortEdge / 900))
        x = 0
        while x <= size.width {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: size.height))
            x += major
        }
        y = 0
        while y <= size.height {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: size.width, y: y))
            y += major
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Crosshair ticks at major intersections
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(max(1.2, shortEdge / 800))
        let tickLen = minor * 0.35
        x = 0
        while x <= size.width {
            y = 0
            while y <= size.height {
                ctx.move(to: CGPoint(x: x - tickLen, y: y))
                ctx.addLine(to: CGPoint(x: x + tickLen, y: y))
                ctx.move(to: CGPoint(x: x, y: y - tickLen))
                ctx.addLine(to: CGPoint(x: x, y: y + tickLen))
                y += major
            }
            x += major
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Dune layers

    private func drawDuneLayers(
        into ctx: CGContext, size: CGSize, accent: NSColor, opacity: CGFloat
    ) {
        // Stacked curved bands, each slightly deeper in accent, rising from
        // the bottom of the canvas (in CG coords: y=0 is bottom).
        let layerCount = 5
        ctx.saveGState()
        for i in 0..<layerCount {
            let t = Double(i + 1) / Double(layerCount)
            let alpha = CGFloat(opacity * (0.5 + t * 0.5))
            let fill = accent.withAlphaComponent(alpha)

            // In CG coords, y=0 is bottom. Dune crest Y (in CG) rises with i.
            let crestYCG = size.height * CGFloat(0.62 - 0.13 * Double(i))
            let jitter = pseudoRandom(0...1, seed: i * 37 + 11) * 0.035
            let crestOffset = CGFloat(jitter)

            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: 0, y: crestYCG))
            // Three-hump curve across the width using two cubic Béziers
            ctx.addCurve(
                to: CGPoint(x: size.width * 0.55, y: crestYCG + size.height * 0.03),
                control1: CGPoint(x: size.width * 0.22, y: crestYCG + size.height * (0.055 + crestOffset)),
                control2: CGPoint(x: size.width * 0.42, y: crestYCG - size.height * 0.015)
            )
            ctx.addCurve(
                to: CGPoint(x: size.width, y: crestYCG - size.height * 0.005),
                control1: CGPoint(x: size.width * 0.72, y: crestYCG + size.height * (0.06 + crestOffset * 0.6)),
                control2: CGPoint(x: size.width * 0.90, y: crestYCG - size.height * 0.01)
            )
            ctx.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.closePath()

            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: - Soft waves

    private func drawSoftWaves(
        into ctx: CGContext, size: CGSize, accent: NSColor, opacity: CGFloat
    ) {
        let shortEdge = min(size.width, size.height)
        let strokeWidth = max(1.5, shortEdge / 600)
        let bandCount = 9
        let spacing = size.height / CGFloat(bandCount + 1)

        ctx.saveGState()
        ctx.setLineCap(.round)
        for i in 0..<bandCount {
            let alpha = opacity * (0.55 + 0.05 * CGFloat(i))
            let color = accent.withAlphaComponent(min(1, alpha))
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(strokeWidth)

            let baseY = spacing * CGFloat(i + 1)
            let amplitude = spacing * 0.35
            let wavelength = size.width / 1.6

            var x: CGFloat = 0
            ctx.move(to: CGPoint(x: 0, y: baseY))
            while x <= size.width {
                let t = Double(x) / Double(wavelength)
                let y = baseY + amplitude * CGFloat(sin(t * 2 * .pi + Double(i) * 0.9))
                ctx.addLine(to: CGPoint(x: x, y: y))
                x += 4
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Gamified shapes

    private func drawGamifiedShapes(
        into ctx: CGContext, size: CGSize, accent: NSColor, opacity: CGFloat
    ) {
        let baseSize = min(size.width, size.height) / 8

        // Derive a small palette around the accent. No color parsing needed —
        // operate on HSV traits of the accent itself for a consistent family.
        let palette: [NSColor] = [
            accent,
            blend(accent, with: .white, t: 0.35),
            blend(accent, with: .white, t: 0.65),
            blend(accent, with: NSColor(calibratedHue: 0.08, saturation: 0.75, brightness: 0.95, alpha: 1), t: 0.5),
            blend(accent, with: NSColor(calibratedHue: 0.42, saturation: 0.55, brightness: 0.82, alpha: 1), t: 0.5),
            blend(accent, with: NSColor(calibratedHue: 0.60, saturation: 0.72, brightness: 0.92, alpha: 1), t: 0.5),
        ]

        ctx.saveGState()
        for i in 0..<28 {
            let kind = i % 4
            let x = pseudoRandom(0.04...0.96, seed: i * 11 + 1) * Double(size.width)
            let y = pseudoRandom(0.04...0.96, seed: i * 11 + 2) * Double(size.height)
            let scale = pseudoRandom(0.55...1.4, seed: i * 11 + 3)
            let rotation = pseudoRandom(0...(.pi * 2), seed: i * 11 + 4)
            let colorIdx = Int(pseudoRandom(0...1, seed: i * 11 + 5) * Double(palette.count - 1))
            let color = palette[colorIdx].withAlphaComponent(min(1, opacity * 1.6))
            let s = baseSize * CGFloat(scale)
            let center = CGPoint(x: CGFloat(x), y: CGFloat(y))

            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: CGFloat(rotation))
            ctx.setFillColor(color.cgColor)

            switch kind {
            case 0:
                ctx.fillEllipse(in: CGRect(x: -s/2, y: -s/2, width: s, height: s))
            case 1:
                let rect = CGRect(x: -s * 0.6, y: -s * 0.5, width: s * 1.2, height: s)
                let path = CGPath(roundedRect: rect, cornerWidth: s * 0.25, cornerHeight: s * 0.25, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            case 2:
                let rect = CGRect(x: -s * 0.9, y: -s * 0.3, width: s * 1.8, height: s * 0.6)
                let path = CGPath(roundedRect: rect, cornerWidth: s * 0.3, cornerHeight: s * 0.3, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            default:
                starPath(into: ctx, center: .zero, outerRadius: s * 0.6, innerRadius: s * 0.26, points: 5)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func starPath(
        into ctx: CGContext,
        center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat, points: Int
    ) {
        let steps = points * 2
        for i in 0..<steps {
            let t = Double(i) / Double(steps)
            let theta = -.pi / 2 + t * 2 * .pi
            let r = i.isMultiple(of: 2) ? outerRadius : innerRadius
            let x = center.x + r * CGFloat(cos(theta))
            let y = center.y + r * CGFloat(sin(theta))
            if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) }
            else { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.closePath()
    }

    // MARK: - Utilities

    private func blend(_ a: NSColor, with b: NSColor, t: CGFloat) -> NSColor {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return a }
        let u = max(0, min(1, t))
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * u,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * u,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * u,
            alpha: a.alphaComponent
        )
    }

    // Deterministic pseudo-random so pattern draws are reproducible.
    private func pseudoRandom(_ range: ClosedRange<Double>, seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed &* 2654435761))
        x ^= x &>> 13
        x &*= 0x9E3779B185EBCA87
        x ^= x &>> 17
        let t = Double(x % 1_000_000) / 1_000_000.0
        return range.lowerBound + (range.upperBound - range.lowerBound) * t
    }
}
