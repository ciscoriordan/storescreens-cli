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
/// The iPhone Duo (a foldable) gets its own frames, one per display: the
/// outer display shows the closed phone (hinge-side corners nearly square,
/// the other half of the phone showing past the hinge edge, a camera hole
/// in the display), the inner display the open phone (fold marks where the
/// hinge meets the two long edges).
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
        /// Outer body corner radii. Ring and screen radii are concentric
        /// (inner radius = outer radius - inset) so the band reads as a
        /// uniform-width rail around the corners. All four are equal on
        /// every device but the iPhone Duo.
        package let bodyCorners: CornerRadii
        package let screenCorners: CornerRadii
        /// Metal band thickness (body edge to the dark ring).
        package let bandWidth: CGFloat
        package let cutout: Cutout
        /// Button rects, top-left origin. Drawn under the body so only the
        /// outer sliver protrudes past the band.
        package let buttons: [CGRect]
        /// Foldable details (iPhone Duo); nil for every other device.
        package let hinge: Hinge?

        /// Largest body corner radius (the only one, except on the Duo).
        package var bodyCornerRadius: CGFloat { bodyCorners.maximum }
        /// Largest screen corner radius (the only one, except on the Duo).
        package var screenCornerRadius: CGFloat { screenCorners.maximum }

        package enum Cutout: Equatable, Sendable {
            case none
            /// Dynamic Island pill, inset below the screen's top edge.
            case island(CGRect)
            /// Notch flush against the screen's top (or leading, in
            /// landscape) edge. Drawn with the flush corners square.
            case notch(CGRect)
            /// Round camera hole through the display (the Duo's outer
            /// display): the disc's bounding rect.
            case hole(CGRect)
        }

        /// Top-left origin, like the rest of the spec.
        package struct Hinge: Equatable, Sendable {
            /// Closed phone: the other half of the phone, visible past the
            /// hinge edge as a strip behind the body.
            package let spine: CGRect?
            package let spineCornerRadius: CGFloat
            /// Open phone: where the fold meets each long edge, a short
            /// gap across the metal band and the hinge housing showing in
            /// the dark ring. Neither crosses the screen.
            package let foldSeams: [CGRect]
            package let foldHousings: [CGRect]
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

        // The Duo's displays are squat (aspect below 2), so the
        // home-button rule below would otherwise claim them.
        if let duo = DisplayShape.DuoDisplay.match(productFamily: productFamily, size: CGSize(width: sw, height: sh)) {
            return duoSpec(duo, screenSize: CGSize(width: sw, height: sh))
        }

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
            bodyCorners: CornerRadii(uniform: bodyR),
            screenCorners: CornerRadii(uniform: screenR),
            bandWidth: band,
            cutout: cutout(productFamily: productFamily, screenRect: screenRect, landscape: landscape),
            buttons: buttons,
            hinge: nil
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

    // MARK: - iPhone Duo

    /// Builds the portrait frame, then turns it the way Apple's landscape
    /// artwork turns: the outer display counterclockwise (hinge along the
    /// bottom, camera top-left), the inner display clockwise (the power
    /// button ends up on the right edge, volume on the top).
    ///
    /// Proportions come from Apple's iPhone Duo bezel artwork, relative to
    /// the display's short side; button positions are fractions of the body
    /// measured on the "Outer Closed Portrait" and "Inner Open Portrait"
    /// PNGs.
    private static func duoSpec(_ duo: DisplayShape.DuoDisplay, screenSize: CGSize) -> Spec {
        let sw = min(screenSize.width, screenSize.height)
        let sh = max(screenSize.width, screenSize.height)
        let shape = DisplayShape.forScreen(productFamily: 1, size: CGSize(width: sw, height: sh))

        let portrait: Spec
        switch duo.panel {
        case .outer: portrait = duoOuterPortrait(shape: shape, screenWidth: sw, screenHeight: sh)
        case .inner: portrait = duoInnerPortrait(shape: shape, screenWidth: sw, screenHeight: sh)
        }
        guard duo.landscape else { return portrait }
        return duo.panel == .outer ? rotated(portrait, clockwise: false) : rotated(portrait, clockwise: true)
    }

    /// Closed phone, hinge on the left. The body's corners follow the
    /// display's (small on the hinge side), the other half of the phone
    /// shows as a strip past the hinge edge, and the canvas keeps equal
    /// margins left and right so the screen stays centered, as in Apple's
    /// artwork.
    private static func duoOuterPortrait(shape: DisplayShape, screenWidth sw: CGFloat, screenHeight sh: CGFloat) -> Spec {
        let band = (0.016 * sw).rounded()
        let ring = (0.019 * sw).rounded()
        let buttonOut = (0.009 * sw).rounded()
        let spineOut = (0.026 * sw).rounded()
        let spineInsetY = (0.018 * sw).rounded()

        let inset = band + ring
        let sideMargin = max(spineOut, buttonOut)
        let bodyRect = CGRect(x: sideMargin, y: buttonOut, width: sw + 2 * inset, height: sh + 2 * inset)
        let screenRect = CGRect(x: sideMargin + inset, y: buttonOut + inset, width: sw, height: sh)
        let bodyCorners = shape.corners.expanded(by: inset)

        // Reaches under the body past the rounded hinge-side corners so no
        // gap opens between the strip and the body.
        let spine = CGRect(
            x: bodyRect.minX - spineOut,
            y: bodyRect.minY + spineInsetY,
            width: spineOut + max(bodyCorners.topLeft, bodyCorners.bottomLeft),
            height: bodyRect.height - 2 * spineInsetY
        )

        // Two volume buttons on the top edge, the power button on the edge
        // opposite the hinge.
        var buttons: [CGRect] = []
        for offset in [0.451, 0.613] {
            buttons.append(CGRect(
                x: bodyRect.minX + CGFloat(offset) * bodyRect.width,
                y: bodyRect.minY - buttonOut,
                width: 0.132 * bodyRect.width,
                height: 2 * buttonOut
            ))
        }
        buttons.append(CGRect(
            x: bodyRect.maxX - buttonOut,
            y: bodyRect.minY + 0.285 * bodyRect.height,
            width: 2 * buttonOut,
            height: 0.159 * bodyRect.height
        ))

        let camera = shape.cameraCutouts.first.map {
            $0.offsetBy(dx: screenRect.minX, dy: screenRect.minY)
        }
        return Spec(
            canvasWidth: bodyRect.width + 2 * sideMargin,
            canvasHeight: bodyRect.height + 2 * buttonOut,
            bodyRect: bodyRect,
            screenRect: screenRect,
            bodyCorners: bodyCorners,
            screenCorners: shape.corners,
            bandWidth: band,
            cutout: camera.map { .hole($0) } ?? .none,
            buttons: buttons,
            hinge: Spec.Hinge(
                spine: spine,
                spineCornerRadius: (0.55 * spineOut).rounded(),
                foldSeams: [],
                foldHousings: []
            )
        )
    }

    /// Open phone, portrait: the fold runs across the middle of the
    /// display. Marks sit on both long edges at the fold, outside the
    /// screen, so nothing is drawn over the screenshot.
    private static func duoInnerPortrait(shape: DisplayShape, screenWidth sw: CGFloat, screenHeight sh: CGFloat) -> Spec {
        let band = (0.011 * sw).rounded()
        let ring = (0.021 * sw).rounded()
        let buttonOut = (0.0065 * sw).rounded()

        let inset = band + ring
        let bodyRect = CGRect(x: buttonOut, y: buttonOut, width: sw + 2 * inset, height: sh + 2 * inset)
        let screenRect = CGRect(x: buttonOut + inset, y: buttonOut + inset, width: sw, height: sh)

        // Two volume buttons on the left edge, the power button on the top.
        var buttons: [CGRect] = []
        for offset in [0.127, 0.208] {
            buttons.append(CGRect(
                x: bodyRect.minX - buttonOut,
                y: bodyRect.minY + CGFloat(offset) * bodyRect.height,
                width: 2 * buttonOut,
                height: 0.066 * bodyRect.height
            ))
        }
        buttons.append(CGRect(
            x: bodyRect.minX + 0.285 * bodyRect.width,
            y: bodyRect.minY - buttonOut,
            width: 0.159 * bodyRect.width,
            height: 2 * buttonOut
        ))

        let foldY = screenRect.midY
        let seamHeight = max(2, (0.004 * sw).rounded())
        let housingHeight = (0.095 * sw).rounded()
        let housingInset = (0.1 * ring).rounded()
        let housingWidth = (0.6 * ring).rounded()
        // Seams start one pixel outside the body so no sliver of band is
        // left at the outer edge; drawing clips them to the body.
        let seams = [
            CGRect(x: bodyRect.minX - 1, y: foldY - seamHeight / 2, width: band + 1, height: seamHeight),
            CGRect(x: bodyRect.maxX - band, y: foldY - seamHeight / 2, width: band + 1, height: seamHeight),
        ]
        let housings = [
            CGRect(x: bodyRect.minX + band + housingInset, y: foldY - housingHeight / 2,
                   width: housingWidth, height: housingHeight),
            CGRect(x: bodyRect.maxX - band - housingInset - housingWidth, y: foldY - housingHeight / 2,
                   width: housingWidth, height: housingHeight),
        ]

        return Spec(
            canvasWidth: bodyRect.width + 2 * buttonOut,
            canvasHeight: bodyRect.height + 2 * buttonOut,
            bodyRect: bodyRect,
            screenRect: screenRect,
            bodyCorners: shape.corners.expanded(by: inset),
            screenCorners: shape.corners,
            bandWidth: band,
            cutout: .none,
            buttons: buttons,
            hinge: Spec.Hinge(spine: nil, spineCornerRadius: 0, foldSeams: seams, foldHousings: housings)
        )
    }

    /// Turns a whole spec a quarter turn, canvas included.
    private static func rotated(_ spec: Spec, clockwise: Bool) -> Spec {
        let cw = spec.canvasWidth
        let ch = spec.canvasHeight
        func turn(_ r: CGRect) -> CGRect {
            clockwise
                ? CGRect(x: ch - r.maxY, y: r.minX, width: r.height, height: r.width)
                : CGRect(x: r.minY, y: cw - r.maxX, width: r.height, height: r.width)
        }
        func turn(_ c: CornerRadii) -> CornerRadii {
            clockwise ? c.rotatedClockwise() : c.rotatedCounterclockwise()
        }
        let cutout: Spec.Cutout
        switch spec.cutout {
        case .none: cutout = .none
        case .island(let r): cutout = .island(turn(r))
        case .notch(let r): cutout = .notch(turn(r))
        case .hole(let r): cutout = .hole(turn(r))
        }
        return Spec(
            canvasWidth: ch,
            canvasHeight: cw,
            bodyRect: turn(spec.bodyRect),
            screenRect: turn(spec.screenRect),
            bodyCorners: turn(spec.bodyCorners),
            screenCorners: turn(spec.screenCorners),
            bandWidth: spec.bandWidth,
            cutout: cutout,
            buttons: spec.buttons.map(turn),
            hinge: spec.hinge.map { h in
                Spec.Hinge(
                    spine: h.spine.map(turn),
                    spineCornerRadius: h.spineCornerRadius,
                    foldSeams: h.foldSeams.map(turn),
                    foldHousings: h.foldHousings.map(turn)
                )
            }
        )
    }

    // MARK: - Colorways

    package struct Palette: Sendable {
        package let bandTop: CGColor
        package let bandBottom: CGColor
        package let edge: CGColor
        package let button: CGColor
        package let ring: CGColor
        /// The Duo's other half, showing past the hinge of the closed
        /// phone: a flat tone a step off the band's gradient, so it reads
        /// as a separate part.
        package let spine: CGColor
        /// Hinge housing in the dark ring of the open Duo: just lighter
        /// than the ring.
        package let hingeHousing: CGColor

        package init(_ colorway: DeviceColorway) {
            self.ring = Self.srgb(8, 8, 10)
            self.hingeHousing = Self.srgb(36, 36, 40)
            switch colorway {
            case .dark:
                bandTop = Self.srgb(82, 82, 87)
                bandBottom = Self.srgb(50, 50, 54)
                edge = Self.srgb(118, 118, 124)
                button = Self.srgb(66, 66, 70)
                spine = Self.srgb(58, 58, 63)
            case .silver:
                bandTop = Self.srgb(236, 234, 231)
                bandBottom = Self.srgb(206, 204, 200)
                edge = Self.srgb(166, 164, 160)
                button = Self.srgb(198, 196, 192)
                spine = Self.srgb(212, 210, 206)
            case .natural:
                bandTop = Self.srgb(158, 152, 142)
                bandBottom = Self.srgb(126, 121, 112)
                edge = Self.srgb(176, 171, 160)
                button = Self.srgb(122, 117, 108)
                spine = Self.srgb(134, 129, 120)
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
        let bodyPath = spec.bodyCorners.scaled(by: rScale).path(in: bodyBL, yUp: true)
        let spinePath: CGPath? = spec.hinge.flatMap { hinge in
            hinge.spine.map { rect in
                let radius = hinge.spineCornerRadius * rScale
                return CGPath(roundedRect: place(rect), cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
        }

        // 1. Device-shaped drop shadow (same offsets as the bezel style).
        if shadow {
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -targetRect.height * 0.01),
                blur: targetRect.height * 0.025,
                color: NSColor.black.withAlphaComponent(0.4).cgColor
            )
            ctx.addPath(bodyPath)
            if let spinePath { ctx.addPath(spinePath) }
            ctx.setFillColor(palette.bandBottom)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 1b. Closed Duo: the other half of the phone, behind the body so
        //     only the strip past the hinge edge shows.
        if let spinePath {
            ctx.addPath(spinePath)
            ctx.setFillColor(palette.spine)
            ctx.fillPath()
            ctx.saveGState()
            ctx.addPath(spinePath)
            ctx.setStrokeColor(palette.edge)
            ctx.setLineWidth(max(1, spec.bandWidth * 0.08 * rScale))
            ctx.strokePath()
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

        // 3b. Open Duo: the gap where the two halves of the band meet at
        //     the fold, clipped to the body.
        if let seams = spec.hinge?.foldSeams, !seams.isEmpty {
            ctx.saveGState()
            ctx.addPath(bodyPath)
            ctx.clip()
            ctx.setFillColor(palette.ring)
            for seam in seams {
                ctx.fill(place(seam))
            }
            ctx.restoreGState()
        }

        // 4. Dark ring between band and screen.
        let ringBL = bodyBL.insetBy(dx: spec.bandWidth * scaleX, dy: spec.bandWidth * scaleY)
        let ringCorners = spec.bodyCorners.expanded(by: -spec.bandWidth).scaled(by: rScale)
        ctx.addPath(ringCorners.path(in: ringBL, yUp: true))
        ctx.setFillColor(palette.ring)
        ctx.fillPath()

        // 4b. Open Duo: hinge housings in the ring at the fold.
        for housing in spec.hinge?.foldHousings ?? [] {
            let r = place(housing)
            let radius = 0.3 * min(r.width, r.height)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(palette.hingeHousing)
            ctx.fillPath()
        }

        // 5. Screenshot, clipped to the display's rounded corners.
        let screenBL = place(spec.screenRect)
        let screenPath = spec.screenCorners.scaled(by: rScale).path(in: screenBL, yUp: true)
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
        case .hole(let rect):
            ctx.saveGState()
            ctx.addPath(screenPath)
            ctx.clip()
            ctx.addEllipse(in: place(rect))
            ctx.setFillColor(palette.ring)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}
