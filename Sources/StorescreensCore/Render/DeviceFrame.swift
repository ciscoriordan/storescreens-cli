import Foundation
import AppKit
import CoreGraphics

/// Geometry + drawing for the `device` chrome style: a generic modern device
/// frame drawn procedurally with CoreGraphics. No Apple Design Resources
/// needed, so `render` works before (or without) `storescreens bezels import`.
///
/// The frame is built AROUND the screenshot at its native aspect ratio -
/// metal band, dark bezel ring, side buttons, and a Dynamic Island / notch
/// cutout chosen from the screenshot's pixel dimensions. This is the inverse
/// of tools that hard-code one device's proportions and crop the screenshot
/// to fit; here the screenshot is never cropped or stretched.
///
/// `DeviceFrameSpec` lives in "canvas pixel" space with a top-left origin,
/// mirroring `BezelMetadata` for real bezels, so `ChromeRenderer` lays out
/// both styles with the same fit/scale math.
package enum DeviceFrame {

    /// Supported product families. MacBook (6) is intentionally absent - a
    /// laptop body (lid, hinge, base) is a different drawing problem and the
    /// `stroke`/`bezel` styles cover it.
    package static func supports(productFamily: Int) -> Bool {
        productFamily == 1 || productFamily == 2
    }

    // MARK: - Spec

    package struct Spec: Sendable, Equatable {
        package let canvasWidth: CGFloat
        package let canvasHeight: CGFloat
        /// Outer body rect (the metal band's outline), top-left origin.
        package let bodyRect: CGRect
        /// Screen rect (screenshot at native pixel size), top-left origin.
        package let screenRect: CGRect
        /// Outer body corner radius. Ring and screen radii are concentric
        /// (inner radius = outer radius - inset) so the band reads as a
        /// uniform-width rail around the corners.
        package let bodyCornerRadius: CGFloat
        package let screenCornerRadius: CGFloat
        /// Metal band thickness (body edge to the dark ring).
        package let bandWidth: CGFloat
        package let cutout: Cutout
        /// Button rects, top-left origin. Drawn under the body so only the
        /// outer sliver protrudes past the band.
        package let buttons: [CGRect]

        package enum Cutout: Equatable, Sendable {
            case none
            /// Dynamic Island pill, inset below the screen's top edge.
            case island(CGRect)
            /// Notch flush against the screen's top (or leading, in
            /// landscape) edge. Drawn with the flush corners square.
            case notch(CGRect)
        }
    }

    /// Builds the frame geometry for a screenshot, or nil when the product
    /// family has no drawn-frame support (MacBook, Watch).
    package static func spec(productFamily: Int, screenshotPixelSize size: CGSize) -> Spec? {
        guard supports(productFamily: productFamily), size.width > 0, size.height > 0 else { return nil }

        let sw = size.width.rounded()
        let sh = size.height.rounded()
        let shortSide = min(sw, sh)
        let landscape = sw > sh

        // Band proportions relative to the display's short side, tuned
        // against Apple's product bezels: iPhone has a visible metal rail
        // and thin ring; iPad is nearly all ring (thin aluminum edge,
        // wide uniform black border).
        let band: CGFloat
        let ring: CGFloat
        let buttonOut: CGFloat
        switch productFamily {
        case 1:
            band = (0.024 * shortSide).rounded()
            ring = (0.015 * shortSide).rounded()
            buttonOut = (0.009 * shortSide).rounded()
        default: // iPad
            band = (0.007 * shortSide).rounded()
            ring = (0.034 * shortSide).rounded()
            buttonOut = 0
        }

        let inset = band + ring
        let bodyRect = CGRect(x: buttonOut, y: buttonOut, width: sw + 2 * inset, height: sh + 2 * inset)
        let screenRect = CGRect(x: buttonOut + inset, y: buttonOut + inset, width: sw, height: sh)
        let canvasW = bodyRect.width + 2 * buttonOut
        let canvasH = bodyRect.height + 2 * buttonOut

        // 16:9-era iPhone displays (home button generation) had square
        // corners inside a rounded body; the concentric-radius rule only
        // holds for edge-to-edge screens.
        let squatIPhone = productFamily == 1 && max(sw, sh) / shortSide < 2.0
        let screenR: CGFloat
        let bodyR: CGFloat
        if squatIPhone {
            screenR = 0.02 * shortSide
            bodyR = 0.115 * shortSide
        } else {
            screenR = BezelExporter.deviceScreenCornerRadius(
                productFamily: productFamily,
                screenSize: CGSize(width: sw, height: sh)
            )
            bodyR = screenR + inset
        }

        var buttons: [CGRect] = []
        if productFamily == 1 {
            let bodyW = bodyRect.width
            let bodyH = bodyRect.height
            if landscape {
                // Island-left landscape is portrait rotated counterclockwise:
                // the portrait left-edge cluster (action + volumes) lands on
                // the BOTTOM edge measured from the leading side, and the
                // power button lands on the TOP edge.
                for (offset, length) in [(0.155, 0.045), (0.235, 0.075), (0.325, 0.075)] {
                    buttons.append(CGRect(
                        x: bodyRect.minX + CGFloat(offset) * bodyW,
                        y: bodyRect.maxY - buttonOut,
                        width: CGFloat(length) * bodyW,
                        height: 2 * buttonOut
                    ))
                }
                buttons.append(CGRect(
                    x: bodyRect.minX + 0.26 * bodyW,
                    y: bodyRect.minY - buttonOut,
                    width: 0.11 * bodyW,
                    height: 2 * buttonOut
                ))
            } else {
                // Left edge: action, volume up, volume down. Right: power.
                for (offset, length) in [(0.155, 0.045), (0.235, 0.075), (0.325, 0.075)] {
                    buttons.append(CGRect(
                        x: bodyRect.minX - buttonOut,
                        y: bodyRect.minY + CGFloat(offset) * bodyH,
                        width: 2 * buttonOut,
                        height: CGFloat(length) * bodyH
                    ))
                }
                buttons.append(CGRect(
                    x: bodyRect.maxX - buttonOut,
                    y: bodyRect.minY + 0.26 * bodyH,
                    width: 2 * buttonOut,
                    height: 0.11 * bodyH
                ))
            }
        }

        return Spec(
            canvasWidth: canvasW,
            canvasHeight: canvasH,
            bodyRect: bodyRect,
            screenRect: screenRect,
            bodyCornerRadius: bodyR,
            screenCornerRadius: screenR,
            bandWidth: band,
            cutout: cutout(productFamily: productFamily, screenRect: screenRect, landscape: landscape),
            buttons: buttons
        )
    }

    // MARK: - Cutout selection

    /// Portrait pixel sizes of Dynamic Island devices (14 Pro through the
    /// current generation, including iPhone Air).
    private static let islandSizes: Set<[Int]> = [
        [1179, 2556], [1206, 2622], [1260, 2736], [1290, 2796], [1320, 2868],
    ]

    /// Portrait pixel sizes of notch devices (X through 16e).
    private static let notchSizes: Set<[Int]> = [
        [828, 1792], [1080, 2340], [1125, 2436], [1170, 2532], [1242, 2688], [1284, 2778],
    ]

    private static func cutout(productFamily: Int, screenRect: CGRect, landscape: Bool) -> Spec.Cutout {
        guard productFamily == 1 else { return .none }
        let pw = Int(min(screenRect.width, screenRect.height))
        let ph = Int(max(screenRect.width, screenRect.height))
        let shortSide = CGFloat(pw)

        let kind: CutoutKind
        if islandSizes.contains([pw, ph]) {
            kind = .island
        } else if notchSizes.contains([pw, ph]) {
            kind = .notch
        } else if (2.0...2.3).contains(CGFloat(ph) / shortSide) {
            // Non-native sizes with a modern tall aspect (e.g. half-scale
            // synthetic screenshots) get the current-generation look.
            kind = .island
        } else {
            // 16:9-era screens (home button) and squat aspects: no cutout.
            return .none
        }

        switch kind {
        case .island:
            let w = 0.30 * shortSide
            let h = 0.088 * shortSide
            let inset = 0.028 * shortSide
            if landscape {
                return .island(CGRect(
                    x: screenRect.minX + inset,
                    y: screenRect.midY - w / 2,
                    width: h, height: w
                ))
            }
            return .island(CGRect(
                x: screenRect.midX - w / 2,
                y: screenRect.minY + inset,
                width: w, height: h
            ))
        case .notch:
            let w = 0.48 * shortSide
            let h = 0.078 * shortSide
            if landscape {
                return .notch(CGRect(
                    x: screenRect.minX,
                    y: screenRect.midY - w / 2,
                    width: h, height: w
                ))
            }
            return .notch(CGRect(
                x: screenRect.midX - w / 2,
                y: screenRect.minY,
                width: w, height: h
            ))
        }
    }

    private enum CutoutKind { case island, notch }

    // MARK: - Colorways

    package struct Palette: Sendable {
        package let bandTop: CGColor
        package let bandBottom: CGColor
        package let edge: CGColor
        package let button: CGColor
        package let ring: CGColor

        package init(_ colorway: DeviceColorway) {
            self.ring = Self.srgb(8, 8, 10)
            switch colorway {
            case .dark:
                bandTop = Self.srgb(82, 82, 87)
                bandBottom = Self.srgb(50, 50, 54)
                edge = Self.srgb(118, 118, 124)
                button = Self.srgb(66, 66, 70)
            case .silver:
                bandTop = Self.srgb(236, 234, 231)
                bandBottom = Self.srgb(206, 204, 200)
                edge = Self.srgb(166, 164, 160)
                button = Self.srgb(198, 196, 192)
            case .natural:
                bandTop = Self.srgb(158, 152, 142)
                bandBottom = Self.srgb(126, 121, 112)
                edge = Self.srgb(176, 171, 160)
                button = Self.srgb(122, 117, 108)
            }
        }

        private static func srgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
            CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    // MARK: - Drawing

    /// Draws the frame + screenshot into `targetRect` (bottom-left CG
    /// coords), scaling the spec's canvas to fill it. `targetRect` should be
    /// aspect-fit to the spec canvas (same math as bezel PNGs); radii use
    /// the horizontal scale.
    package static func draw(
        spec: Spec,
        colorway: DeviceColorway,
        screenshot: CGImage,
        shadow: Bool,
        into ctx: CGContext,
        targetRect: CGRect
    ) {
        let palette = Palette(colorway)
        let scaleX = targetRect.width / spec.canvasWidth
        let scaleY = targetRect.height / spec.canvasHeight
        let rScale = min(scaleX, scaleY)

        // Spec (top-left origin) -> context (bottom-left origin).
        func place(_ r: CGRect) -> CGRect {
            CGRect(
                x: targetRect.minX + r.minX * scaleX,
                y: targetRect.maxY - (r.minY + r.height) * scaleY,
                width: r.width * scaleX,
                height: r.height * scaleY
            )
        }

        let bodyBL = place(spec.bodyRect)
        let bodyR = spec.bodyCornerRadius * rScale
        let bodyPath = CGPath(roundedRect: bodyBL, cornerWidth: bodyR, cornerHeight: bodyR, transform: nil)

        // 1. Device-shaped drop shadow (same offsets as the bezel style).
        if shadow {
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -targetRect.height * 0.01),
                blur: targetRect.height * 0.025,
                color: NSColor.black.withAlphaComponent(0.4).cgColor
            )
            ctx.addPath(bodyPath)
            ctx.setFillColor(palette.bandBottom)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 2. Buttons, drawn first so the body overlaps their inner half and
        //    only the outer sliver shows.
        for button in spec.buttons {
            let r = place(button)
            let radius = min(r.width, r.height) / 2
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(palette.button)
            ctx.fillPath()
        }

        // 3. Metal band: vertical gradient clipped to the body, plus a
        //    hairline edge so the rail reads against busy backgrounds.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [palette.bandTop, palette.bandBottom] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: bodyBL.midX, y: bodyBL.maxY),
                end: CGPoint(x: bodyBL.midX, y: bodyBL.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.setStrokeColor(palette.edge)
        ctx.setLineWidth(max(1, spec.bandWidth * 0.08 * rScale))
        ctx.strokePath()
        ctx.restoreGState()

        // 4. Dark ring between band and screen.
        let ringBL = bodyBL.insetBy(dx: spec.bandWidth * scaleX, dy: spec.bandWidth * scaleY)
        let ringR = max(0, (spec.bodyCornerRadius - spec.bandWidth) * rScale)
        ctx.addPath(CGPath(roundedRect: ringBL, cornerWidth: ringR, cornerHeight: ringR, transform: nil))
        ctx.setFillColor(palette.ring)
        ctx.fillPath()

        // 5. Screenshot, clipped to the display's rounded corners.
        let screenBL = place(spec.screenRect)
        let screenR = spec.screenCornerRadius * rScale
        let screenPath = CGPath(roundedRect: screenBL, cornerWidth: screenR, cornerHeight: screenR, transform: nil)
        ctx.saveGState()
        ctx.addPath(screenPath)
        ctx.clip()
        ctx.draw(screenshot, in: screenBL)
        ctx.restoreGState()

        // 6. Cutout on top of the screenshot. Simulator captures render app
        //    content where the hardware sensor housing sits; painting the
        //    housing back on matches what the display physically shows.
        switch spec.cutout {
        case .none:
            break
        case .island(let rect):
            let r = place(rect)
            let radius = min(r.width, r.height) / 2
            ctx.saveGState()
            ctx.addPath(screenPath)
            ctx.clip()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(palette.ring)
            ctx.fillPath()
            ctx.restoreGState()
        case .notch(let rect):
            // Rounded rect extended past the flush screen edge, then clipped
            // to the screen path: flush corners come out square, the inner
            // corners rounded.
            let radius = 0.35 * min(rect.width, rect.height)
            var extended = rect
            if rect.width >= rect.height {
                extended.origin.y -= radius
                extended.size.height += radius
            } else {
                extended.origin.x -= radius
                extended.size.width += radius
            }
            let r = place(extended)
            ctx.saveGState()
            ctx.addPath(screenPath)
            ctx.clip()
            ctx.addPath(CGPath(
                roundedRect: r,
                cornerWidth: radius * rScale,
                cornerHeight: radius * rScale,
                transform: nil
            ))
            ctx.setFillColor(palette.ring)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}
