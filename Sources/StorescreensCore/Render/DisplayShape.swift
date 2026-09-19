import Foundation
import CoreGraphics

/// Radii of the four corners of a rounded rectangle, in pixels. Top and
/// bottom refer to the picture as seen, whichever way the coordinate
/// system's y axis points.
package struct CornerRadii: Sendable, Equatable {
    package var topLeft: CGFloat
    package var topRight: CGFloat
    package var bottomLeft: CGFloat
    package var bottomRight: CGFloat

    package init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    package init(uniform radius: CGFloat) {
        self.init(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
    }

    package var isUniform: Bool {
        topLeft == topRight && topLeft == bottomLeft && topLeft == bottomRight
    }

    package var maximum: CGFloat {
        max(topLeft, topRight, bottomLeft, bottomRight)
    }

    /// Radii of the concentric outline `amount` pixels further out
    /// (negative: further in), floored at a square corner.
    package func expanded(by amount: CGFloat) -> CornerRadii {
        CornerRadii(
            topLeft: max(0, topLeft + amount),
            topRight: max(0, topRight + amount),
            bottomLeft: max(0, bottomLeft + amount),
            bottomRight: max(0, bottomRight + amount)
        )
    }

    package func scaled(by factor: CGFloat) -> CornerRadii {
        CornerRadii(
            topLeft: topLeft * factor,
            topRight: topRight * factor,
            bottomLeft: bottomLeft * factor,
            bottomRight: bottomRight * factor
        )
    }

    /// Where each corner ends up when the picture turns a quarter turn
    /// counterclockwise: the old top-right corner becomes the top-left one.
    package func rotatedCounterclockwise() -> CornerRadii {
        CornerRadii(topLeft: topRight, topRight: bottomRight, bottomLeft: topLeft, bottomRight: bottomLeft)
    }

    /// Where each corner ends up when the picture turns a quarter turn
    /// clockwise: the old bottom-left corner becomes the top-left one.
    package func rotatedClockwise() -> CornerRadii {
        CornerRadii(topLeft: bottomLeft, topRight: topLeft, bottomLeft: bottomRight, bottomRight: topRight)
    }

    /// Rounded-rect outline of `rect`. `yUp` false means a top-left origin
    /// (`rect.minY` is the top edge, as in bezel metadata and
    /// `DeviceFrame.Spec`); true means CoreGraphics' bottom-left origin
    /// (`rect.maxY` is the top edge).
    ///
    /// Equal radii go through `CGPath(roundedRect:)`, the call every
    /// renderer used before corners could differ, so those outlines
    /// rasterize to exactly the same pixels as before.
    package func path(in rect: CGRect, yUp: Bool) -> CGPath {
        if isUniform {
            return CGPath(roundedRect: rect, cornerWidth: topLeft, cornerHeight: topLeft, transform: nil)
        }
        let path = CGMutablePath()
        addRoundedRect(rect, yUp: yUp, to: path)
        return path
    }

    /// Appends the outline of `rect` with these corners as a closed subpath.
    /// Radii larger than half the shorter side are clamped.
    package func addRoundedRect(_ rect: CGRect, yUp: Bool, to path: CGMutablePath) {
        let limit = min(rect.width, rect.height) / 2
        func r(_ value: CGFloat) -> CGFloat { min(max(0, value), limit) }
        // Corners in path order around the rect, named for the picture.
        let minYRadiusLeft = r(yUp ? bottomLeft : topLeft)
        let minYRadiusRight = r(yUp ? bottomRight : topRight)
        let maxYRadiusRight = r(yUp ? topRight : bottomRight)
        let maxYRadiusLeft = r(yUp ? topLeft : bottomLeft)

        path.move(to: CGPoint(x: rect.minX + minYRadiusLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - minYRadiusRight, y: rect.minY))
        if minYRadiusRight > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
                        radius: minYRadiusRight)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - maxYRadiusRight))
        if maxYRadiusRight > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
                        radius: maxYRadiusRight)
        }
        path.addLine(to: CGPoint(x: rect.minX + maxYRadiusLeft, y: rect.maxY))
        if maxYRadiusLeft > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX, y: rect.minY),
                        radius: maxYRadiusLeft)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + minYRadiusLeft))
        if minYRadiusLeft > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
                        radius: minYRadiusLeft)
        }
        path.closeSubpath()
    }
}

/// Outline of a device display's visible opening: per-corner radii plus
/// any opaque camera cutouts inside it, in screen pixels. One description
/// shared by the bezel export (the transparent hole punched into Apple's
/// artwork), the bezel render (the clip applied to the screenshot) and the
/// drawn device frame, so all three agree on the display's shape.
///
/// Every display except the iPhone Duo's is a rounded rect with one radius
/// from `BezelExporter.deviceScreenCornerRadius` and no cutouts.
package struct DisplayShape: Sendable, Equatable {
    /// Screen size the geometry below is expressed in, pixels.
    package let size: CGSize
    package let corners: CornerRadii
    /// Camera holes through the display, each the bounding rect of a disc
    /// in screen-local pixels with a top-left origin. The hardware sits in
    /// front of the panel, so the opening keeps these opaque.
    package let cameraCutouts: [CGRect]

    package init(size: CGSize, corners: CornerRadii, cameraCutouts: [CGRect] = []) {
        self.size = size
        self.corners = corners
        self.cameraCutouts = cameraCutouts
    }

    /// Shape of a display of `size` pixels in `productFamily`.
    package static func forScreen(productFamily: Int, size: CGSize) -> DisplayShape {
        if let duo = DuoDisplay.match(productFamily: productFamily, size: size) {
            return duoShape(duo, size: size)
        }
        return DisplayShape(
            size: size,
            corners: CornerRadii(uniform: BezelExporter.deviceScreenCornerRadius(
                productFamily: productFamily,
                screenSize: size
            ))
        )
    }

    // MARK: - Paths

    /// Outline of the opening mapped onto `rect` (the shape's `size`
    /// stretched to the rect; radii follow the smaller of the two scales).
    /// See `CornerRadii.path(in:yUp:)` for `yUp`.
    package func outlinePath(in rect: CGRect, yUp: Bool) -> CGPath {
        corners.scaled(by: scale(to: rect)).path(in: rect, yUp: yUp)
    }

    /// Outline plus every camera disc as extra subpaths. Fill with the
    /// even-odd rule to cover the opening minus the cameras.
    package func openingPath(in rect: CGRect, yUp: Bool) -> CGPath {
        let outline = outlinePath(in: rect, yUp: yUp)
        if cameraCutouts.isEmpty { return outline }
        let path = CGMutablePath()
        path.addPath(outline)
        for camera in cameraRects(in: rect, yUp: yUp) {
            path.addEllipse(in: camera)
        }
        return path
    }

    /// Camera disc bounds mapped onto `rect`, in that rect's coordinate
    /// system.
    package func cameraRects(in rect: CGRect, yUp: Bool) -> [CGRect] {
        let sx = rect.width / size.width
        let sy = rect.height / size.height
        return cameraCutouts.map { c in
            CGRect(
                x: rect.minX + c.minX * sx,
                y: yUp ? rect.maxY - c.maxY * sy : rect.minY + c.minY * sy,
                width: c.width * sx,
                height: c.height * sy
            )
        }
    }

    private func scale(to rect: CGRect) -> CGFloat {
        min(rect.width / size.width, rect.height / size.height)
    }

    // MARK: - iPhone Duo

    /// Which iPhone Duo display a screen size belongs to. The Duo is a
    /// foldable with two displays: the outer one, usable with the phone
    /// closed, and the inner one that the phone opens to.
    package struct DuoDisplay: Sendable, Equatable {
        package enum Panel: Sendable, Equatable {
            case outer
            case inner
        }

        package let panel: Panel
        package let landscape: Bool

        package init(panel: Panel, landscape: Bool) {
            self.panel = panel
            self.landscape = landscape
        }

        /// Native portrait pixel sizes: the outer display and the inner
        /// display's App Store screenshot size.
        static let outerNative = CGSize(width: 1398, height: 2034)
        static let innerNative = CGSize(width: 2007, height: 2853)

        /// Whole-number reductions of the native sizes that still count
        /// as Duo captures: full, half, third and quarter scale.
        static let scaleDivisors: [CGFloat] = [1, 2, 3, 4]

        /// Matches the two native sizes and their half, third and quarter
        /// scales, in either orientation, allowing 1 px of rounding on
        /// each side (the inner display at half scale is 1003.5 x 1426.5,
        /// saved as 1003 or 1004 by 1426 or 1427).
        ///
        /// The aspect ratio alone is not enough. Element and cropped
        /// screenshots keep their device's iPhone label, and a 1206 x 1755
        /// crop of a 1206 x 2622 screenshot is within 0.02% of the outer
        /// display's ratio. Sizes like that keep the plain iPhone frame
        /// instead of getting a hinge and a camera hole over the content.
        package static func match(productFamily: Int, size: CGSize) -> DuoDisplay? {
            guard productFamily == 1, size.width > 0, size.height > 0 else { return nil }
            let w = size.width.rounded()
            let h = size.height.rounded()
            let short = min(w, h)
            let long = max(w, h)
            let landscape = w > h
            for (native, panel) in [(outerNative, Panel.outer), (innerNative, Panel.inner)] {
                for divisor in scaleDivisors
                where abs(short - native.width / divisor) <= 1 && abs(long - native.height / divisor) <= 1 {
                    return DuoDisplay(panel: panel, landscape: landscape)
                }
            }
            return nil
        }

        var nativeShortSide: CGFloat {
            panel == .outer ? Self.outerNative.width : Self.innerNative.width
        }
    }

    /// Duo display geometry, measured on Apple's iPhone Duo bezel artwork
    /// at native size and scaled by the short side for other sizes.
    ///
    /// Apple draws display corners as continuous-curvature curves; the
    /// radii here are the circular arcs that stand in for them, using the
    /// same ratio the iPhone rule has to Apple's iPhone 17/18 Pro artwork
    /// (0.145 x 1206 = 175 px arc for a 203 px curve, 0.862). Against
    /// Apple's opening masks those arcs leave no opening pixel uncovered
    /// and reach at most 3 px (hinge corners) to 6 px (others) into the
    /// black border, the same margin the iPhone 18 Pro bezel has.
    ///
    /// Outer display, portrait, hinge on the left: 20.5 px curves on the
    /// hinge side (18 px arcs), 188 px on the other side (162 px arcs),
    /// and a 108 px camera disc centered 143 px from the right edge and
    /// 143.5 px from the top. Inner display: 172.5 px curves on all four
    /// corners (149 px arcs), no camera.
    private static func duoShape(_ duo: DuoDisplay, size: CGSize) -> DisplayShape {
        let short = min(size.width, size.height)
        let s = short / duo.nativeShortSide
        let portraitSize = CGSize(width: short, height: max(size.width, size.height))

        switch duo.panel {
        case .inner:
            // Uniform corners, so turning it for landscape changes nothing.
            return DisplayShape(size: size, corners: CornerRadii(uniform: 149 * s))
        case .outer:
            let small = 18 * s
            let large = 162 * s
            let diameter = 108 * s
            let camera = CGRect(
                x: portraitSize.width - 143 * s - diameter / 2,
                y: 143.5 * s - diameter / 2,
                width: diameter,
                height: diameter
            )
            let portrait = DisplayShape(
                size: portraitSize,
                corners: CornerRadii(topLeft: small, topRight: large, bottomLeft: small, bottomRight: large),
                cameraCutouts: [camera]
            )
            // Apple's landscape artwork is the portrait phone turned
            // counterclockwise: hinge along the bottom, camera top-left.
            return duo.landscape ? portrait.rotatedCounterclockwise() : portrait
        }
    }

    /// The same display turned a quarter turn counterclockwise.
    package func rotatedCounterclockwise() -> DisplayShape {
        DisplayShape(
            size: CGSize(width: size.height, height: size.width),
            corners: corners.rotatedCounterclockwise(),
            cameraCutouts: cameraCutouts.map { c in
                CGRect(x: c.minY, y: size.width - c.maxX, width: c.height, height: c.width)
            }
        )
    }

    /// The same display turned a quarter turn clockwise.
    package func rotatedClockwise() -> DisplayShape {
        DisplayShape(
            size: CGSize(width: size.height, height: size.width),
            corners: corners.rotatedClockwise(),
            cameraCutouts: cameraCutouts.map { c in
                CGRect(x: size.height - c.maxY, y: c.minX, width: c.height, height: c.width)
            }
        )
    }
}
