import XCTest
@testable import StorescreensCore

final class PSDParserTests: XCTestCase {

    /// Absolute path to each DMG sample we want to validate. Tests skip
    /// cleanly if a volume isn't mounted, so the suite passes on CI / fresh
    /// machines without manual DMG setup.
    private struct Sample {
        let path: String
        let expectedCanvas: (w: Int, h: Int)
        let expectedScreenLayerName: String
        let expectedScreenBBox: CGRect
    }

    private let samples: [Sample] = [
        Sample(
            path: "/Volumes/Bezel-iPhone-17/Photoshop/iPhone 17 Pro Max/iPhone 17 Pro Max - Silver - Portrait.psd",
            expectedCanvas: (1470, 3000),
            expectedScreenLayerName: "Screen",
            expectedScreenBBox: CGRect(x: 75, y: 66, width: 1320, height: 2868)
        ),
        Sample(
            path: "/Volumes/Bezel-iPad-Pro-(M5)/Photoshop/iPad Pro (M5) 13\" - Silver - Portrait.psd",
            expectedCanvas: (2300, 3000),
            expectedScreenLayerName: "Screen",
            expectedScreenBBox: CGRect(x: 118, y: 124, width: 2064, height: 2752)
        ),
        Sample(
            path: "/Volumes/Bezel-MacBook-Pro-M5/Photoshop/MacBook Pro M5 16-inch Silver.psd",
            expectedCanvas: (4260, 2840),
            expectedScreenLayerName: "Screen: 3456 x 2234",
            expectedScreenBBox: CGRect(x: 402, y: 303, width: 3456, height: 2234)
        ),
    ]

    func testParsesAllMountedSamples() throws {
        var ran = 0
        for sample in samples {
            guard FileManager.default.fileExists(atPath: sample.path) else {
                print("SKIP (not mounted): \(sample.path)")
                continue
            }
            let url = URL(fileURLWithPath: sample.path)
            let file = try PSDParser.parse(at: url)

            XCTAssertEqual(file.canvasWidth, sample.expectedCanvas.w,
                           "canvas width mismatch for \(sample.path)")
            XCTAssertEqual(file.canvasHeight, sample.expectedCanvas.h,
                           "canvas height mismatch for \(sample.path)")

            let screen = file.layers.first { $0.name == sample.expectedScreenLayerName }
            XCTAssertNotNil(screen, "Screen layer not found in \(sample.path). Available: \(file.layers.map(\.name))")
            if let s = screen {
                XCTAssertEqual(s.bbox, sample.expectedScreenBBox,
                               "Screen bbox mismatch for \(sample.path)")
            }
            ran += 1
        }
        if ran == 0 {
            print("PSDParserTests: no samples mounted — skipping validation")
        }
    }
}
