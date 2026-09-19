import XCTest
import CoreGraphics
@testable import StorescreensCore

final class DisplayShapeTests: XCTestCase {

    /// Every App Store screenshot size other than the iPhone Duo's, plus
    /// sizes in no App Store class that captures still produce.
    private let iPhoneSizes: [(Int, Int)] = [
        (1260, 2736), (1290, 2796), (1320, 2868), (1284, 2778), (1242, 2688),
        (1179, 2556), (1206, 2622), (1170, 2532), (1125, 2436), (1080, 2340),
        (1242, 2208), (750, 1334), (640, 1136), (640, 1096), (640, 960), (640, 920),
        (828, 1792), (660, 1434),
    ]
    private let iPadSizes: [(Int, Int)] = [
        (2064, 2752), (2048, 2732), (1488, 2266), (1668, 2420), (1668, 2388),
        (1640, 2360), (1668, 2224), (1536, 2048), (1536, 2008), (768, 1024),
        (768, 1004), (1620, 2160),
    ]

    // MARK: - Every display but the Duo's is unchanged

    func testNonDuoSizesKeepTheUniformFamilyRadiusAndNoCutouts() {
        let cases = iPhoneSizes.map { (1, $0) } + iPadSizes.map { (2, $0) } + [(6, (3456, 2234))]
        for (family, (w, h)) in cases {
            for size in [CGSize(width: w, height: h), CGSize(width: h, height: w)] {
                let shape = DisplayShape.forScreen(productFamily: family, size: size)
                let expected = BezelExporter.deviceScreenCornerRadius(productFamily: family, screenSize: size)
                XCTAssertEqual(shape.corners, CornerRadii(uniform: expected), "family \(family) \(size)")
                XCTAssertTrue(shape.cameraCutouts.isEmpty, "family \(family) \(size)")
                XCTAssertNil(DisplayShape.DuoDisplay.match(productFamily: family, size: size), "family \(family) \(size)")

                // Same path the exporter and renderer built before corners
                // could differ, element for element.
                let rect = CGRect(origin: CGPoint(x: 88, y: 80), size: size)
                XCTAssertEqual(
                    shape.openingPath(in: rect, yUp: true),
                    CGPath(roundedRect: rect, cornerWidth: expected, cornerHeight: expected, transform: nil),
                    "family \(family) \(size)"
                )
            }
        }
    }

    // MARK: - iPhone Duo

    func testDuoOuterPortrait_smallCornersOnHingeSide_cameraTopRight() {
        let shape = DisplayShape.forScreen(productFamily: 1, size: CGSize(width: 1398, height: 2034))
        XCTAssertEqual(shape.corners, CornerRadii(topLeft: 18, topRight: 162, bottomLeft: 18, bottomRight: 162))
        XCTAssertEqual(shape.cameraCutouts, [CGRect(x: 1201, y: 89.5, width: 108, height: 108)])
        // Measured on Apple's artwork: 143 px from the right edge, 143.5
        // from the top.
        let camera = shape.cameraCutouts[0]
        XCTAssertEqual(1398 - camera.midX, 143, accuracy: 0.01)
        XCTAssertEqual(camera.midY, 143.5, accuracy: 0.01)
    }

    func testDuoOuterLandscape_isPortraitTurnedCounterclockwise() throws {
        let shape = DisplayShape.forScreen(productFamily: 1, size: CGSize(width: 2034, height: 1398))
        XCTAssertEqual(shape.size, CGSize(width: 2034, height: 1398))
        // Large corners on top, hinge (small corners) along the bottom.
        XCTAssertEqual(shape.corners, CornerRadii(topLeft: 162, topRight: 162, bottomLeft: 18, bottomRight: 18))
        let camera = try XCTUnwrap(shape.cameraCutouts.first)
        XCTAssertEqual(camera.midX, 143.5, accuracy: 0.01)
        XCTAssertEqual(camera.midY, 143, accuracy: 0.01)

        let portrait = DisplayShape.forScreen(productFamily: 1, size: CGSize(width: 1398, height: 2034))
        XCTAssertEqual(shape, portrait.rotatedCounterclockwise())
        XCTAssertEqual(shape.rotatedClockwise(), portrait)
    }

    func testDuoInner_uniformCornersNoCamera_bothOrientations() {
        for size in [CGSize(width: 2007, height: 2853), CGSize(width: 2853, height: 2007)] {
            let shape = DisplayShape.forScreen(productFamily: 1, size: size)
            XCTAssertEqual(shape.corners, CornerRadii(uniform: 149), "\(size)")
            XCTAssertTrue(shape.cameraCutouts.isEmpty, "\(size)")
            XCTAssertEqual(shape.size, size)
        }
    }

    func testDuoMatch_nativeAndScaledSizes() {
        typealias Duo = DisplayShape.DuoDisplay
        XCTAssertEqual(Duo.match(productFamily: 1, size: CGSize(width: 1398, height: 2034)), Duo(panel: .outer, landscape: false))
        XCTAssertEqual(Duo.match(productFamily: 1, size: CGSize(width: 2034, height: 1398)), Duo(panel: .outer, landscape: true))
        XCTAssertEqual(Duo.match(productFamily: 1, size: CGSize(width: 2007, height: 2853)), Duo(panel: .inner, landscape: false))
        XCTAssertEqual(Duo.match(productFamily: 1, size: CGSize(width: 2853, height: 2007)), Duo(panel: .inner, landscape: true))
        // Half-scale captures keep the aspect ratio.
        XCTAssertEqual(Duo.match(productFamily: 1, size: CGSize(width: 699, height: 1017)), Duo(panel: .outer, landscape: false))
        XCTAssertEqual(Duo.match(productFamily: 1, size: CGSize(width: 1427, height: 1004)), Duo(panel: .inner, landscape: true))
        // Only iPhone family: an iPad of similar aspect is not a Duo.
        XCTAssertNil(Duo.match(productFamily: 2, size: CGSize(width: 1398, height: 2034)))
    }

    func testDuoMatch_wholeNumberReductionsWithinOnePixel() {
        typealias Duo = DisplayShape.DuoDisplay
        let outer: [(CGFloat, CGFloat)] = [
            (1398, 2034), (1397, 2035), // native, 1 px off each side
            (699, 1017), (466, 678),    // half and third scale
            (349, 508), (350, 509),     // quarter scale, 349.5 x 508.5 rounded either way
        ]
        let inner: [(CGFloat, CGFloat)] = [
            (2007, 2853),
            (1003, 1426), (1004, 1427), // half scale, 1003.5 x 1426.5 rounded either way
            (669, 951),                 // third scale
            (502, 713), (501, 714),     // quarter scale, 501.75 x 713.25
        ]
        for (panel, sizes) in [(Duo.Panel.outer, outer), (.inner, inner)] {
            for (short, long) in sizes {
                XCTAssertEqual(Duo.match(productFamily: 1, size: CGSize(width: short, height: long)),
                               Duo(panel: panel, landscape: false), "\(short)x\(long)")
                XCTAssertEqual(Duo.match(productFamily: 1, size: CGSize(width: long, height: short)),
                               Duo(panel: panel, landscape: true), "\(long)x\(short)")
            }
        }
        // More than 1 px off a whole-number reduction, or a reduction by a
        // fraction (three quarters: 1048.5 x 1525.5), is not a Duo.
        for (w, h) in [(1400, 2034), (1398, 2031), (701, 1017), (1006, 1427), (1049, 1526), (1048, 1525)] {
            XCTAssertNil(Duo.match(productFamily: 1, size: CGSize(width: w, height: h)), "\(w)x\(h)")
        }
    }

    /// Element and cropped iPhone screenshots keep their device's label,
    /// so a crop whose aspect ratio happens to be near a Duo display's
    /// must still get the uniform iPhone shape: no hinge-side corners and
    /// no camera hole over the content.
    func testIPhoneCropsWithADuoLikeAspectKeepTheUniformFamilyRadius() {
        // 1206 x 1755 is within 0.02% of the outer display's ratio,
        // 1206 x 1714 within 0.02% of the inner one's.
        for (w, h) in [(1206, 1755), (1755, 1206), (1206, 1714), (1714, 1206), (1320, 1920), (1179, 1716)] {
            let size = CGSize(width: w, height: h)
            XCTAssertNil(DisplayShape.DuoDisplay.match(productFamily: 1, size: size), "\(size)")

            let shape = DisplayShape.forScreen(productFamily: 1, size: size)
            let expected = BezelExporter.deviceScreenCornerRadius(productFamily: 1, screenSize: size)
            XCTAssertEqual(shape.corners, CornerRadii(uniform: expected), "\(size)")
            XCTAssertTrue(shape.cameraCutouts.isEmpty, "\(size)")
            let rect = CGRect(origin: CGPoint(x: 88, y: 80), size: size)
            XCTAssertEqual(
                shape.openingPath(in: rect, yUp: true),
                CGPath(roundedRect: rect, cornerWidth: expected, cornerHeight: expected, transform: nil),
                "\(size)"
            )
        }
    }

    func testDuoHalfScale_scalesGeometryByShortSide() throws {
        let shape = DisplayShape.forScreen(productFamily: 1, size: CGSize(width: 699, height: 1017))
        XCTAssertEqual(shape.corners, CornerRadii(topLeft: 9, topRight: 81, bottomLeft: 9, bottomRight: 81))
        let camera = try XCTUnwrap(shape.cameraCutouts.first)
        XCTAssertEqual(camera.width, 54, accuracy: 0.01)
        XCTAssertEqual(699 - camera.midX, 71.5, accuracy: 0.01)
    }

    // MARK: - Paths

    func testOpeningPath_evenOddLeavesCameraOut() {
        let shape = DisplayShape.forScreen(productFamily: 1, size: CGSize(width: 1398, height: 2034))
        let rect = CGRect(x: 88, y: 80, width: 1398, height: 2034)
        let opening = shape.openingPath(in: rect, yUp: false)
        let cameraCenter = CGPoint(x: 88 + 1255, y: 80 + 143.5)
        XCTAssertFalse(opening.contains(cameraCenter, using: .evenOdd))
        XCTAssertTrue(opening.contains(CGPoint(x: rect.midX, y: rect.midY), using: .evenOdd))
        // The outline alone covers the camera (the render clip).
        XCTAssertTrue(shape.outlinePath(in: rect, yUp: false).contains(cameraCenter))
    }

    func testCornerPath_topAndBottomFollowTheCoordinateSystem() {
        let corners = CornerRadii(topLeft: 0, topRight: 40, bottomLeft: 40, bottomRight: 40)
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

        // Top-left origin: y = 1 is the top edge.
        let topDown = corners.path(in: rect, yUp: false)
        XCTAssertTrue(topDown.contains(CGPoint(x: 1, y: 1)))
        XCTAssertFalse(topDown.contains(CGPoint(x: 99, y: 1)))
        XCTAssertFalse(topDown.contains(CGPoint(x: 1, y: 99)))

        // Bottom-left origin: y = 99 is the top edge.
        let bottomUp = corners.path(in: rect, yUp: true)
        XCTAssertTrue(bottomUp.contains(CGPoint(x: 1, y: 99)))
        XCTAssertFalse(bottomUp.contains(CGPoint(x: 99, y: 99)))
        XCTAssertFalse(bottomUp.contains(CGPoint(x: 1, y: 1)))
    }

    func testOutlinePath_scalesOntoTheTargetRect() {
        let shape = DisplayShape.forScreen(productFamily: 1, size: CGSize(width: 1398, height: 2034))
        // Half size: the hinge-side arc (18 px native) becomes 9 px.
        let rect = CGRect(x: 0, y: 0, width: 699, height: 1017)
        let path = shape.outlinePath(in: rect, yUp: false)
        XCTAssertTrue(path.contains(CGPoint(x: 3, y: 3)))
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)))
        // 81 px arc top right: a point 20 px in from the corner is outside.
        XCTAssertFalse(path.contains(CGPoint(x: 679, y: 20)))
    }

    func testCornerRotations_roundTrip() {
        let c = CornerRadii(topLeft: 1, topRight: 2, bottomLeft: 3, bottomRight: 4)
        XCTAssertEqual(c.rotatedClockwise().rotatedCounterclockwise(), c)
        // A quarter turn counterclockwise brings the top-right corner to the top-left.
        XCTAssertEqual(c.rotatedCounterclockwise(), CornerRadii(topLeft: 2, topRight: 4, bottomLeft: 1, bottomRight: 3))
        XCTAssertEqual(c.rotatedClockwise(), CornerRadii(topLeft: 3, topRight: 1, bottomLeft: 4, bottomRight: 2))
    }
}
