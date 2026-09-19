import XCTest
@testable import StorescreensCore

/// The `ScreenshotDisplayType` schema of Apple's App Store Connect OpenAPI
/// spec 4.4.1, copied independently of the production list so a value added
/// to both `ScreenshotDisplayType.validValues` and a resolve table by mistake
/// still fails here. `SubmitOrchestratorTests` uses it to make its stubbed
/// `POST /v1/appScreenshotSets` reject anything else, as App Store Connect does.
enum ASCOpenAPIScreenshotDisplayTypes {
    static let all: [String] = [
        "APP_IPHONE_67", "APP_IPHONE_61", "APP_IPHONE_65", "APP_IPHONE_58",
        "APP_IPHONE_55", "APP_IPHONE_47", "APP_IPHONE_40", "APP_IPHONE_35",
        "APP_IPAD_PRO_3GEN_129", "APP_IPAD_PRO_3GEN_11", "APP_IPAD_PRO_129",
        "APP_IPAD_105", "APP_IPAD_97",
        "APP_DESKTOP",
        "APP_WATCH_ULTRA", "APP_WATCH_SERIES_10", "APP_WATCH_SERIES_7",
        "APP_WATCH_SERIES_4", "APP_WATCH_SERIES_3",
        "APP_APPLE_TV", "APP_APPLE_VISION_PRO",
        "IMESSAGE_APP_IPHONE_67", "IMESSAGE_APP_IPHONE_61", "IMESSAGE_APP_IPHONE_65",
        "IMESSAGE_APP_IPHONE_58", "IMESSAGE_APP_IPHONE_55", "IMESSAGE_APP_IPHONE_47",
        "IMESSAGE_APP_IPHONE_40",
        "IMESSAGE_APP_IPAD_PRO_3GEN_129", "IMESSAGE_APP_IPAD_PRO_3GEN_11",
        "IMESSAGE_APP_IPAD_PRO_129", "IMESSAGE_APP_IPAD_105", "IMESSAGE_APP_IPAD_97",
    ]
}

final class ScreenshotDisplayTypeTests: XCTestCase {

    func testIPhone_portraitAndLandscape_sameDisplayType() {
        // iPhone 18 Pro Max / 17 Pro Max 1320x2868 is the 6.9" class, which
        // App Store Connect still calls APP_IPHONE_67.
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 1, width: 1320, height: 2868),
            "APP_IPHONE_67"
        )
        // Landscape dims (swap w/h) should resolve to the same slot.
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 1, width: 2868, height: 1320),
            "APP_IPHONE_67"
        )
    }

    /// Replaces the old test that expected APP_IPHONE_63 for both sizes.
    /// APP_IPHONE_63 is not an App Store Connect value (every upload under
    /// it failed with a 409); the 6.3" class is APP_IPHONE_61, and iPhone
    /// Air is in the 6.9" class.
    func testIPhone_18ProIn63Class_AirIn69Class() {
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 1, width: 1206, height: 2622),
            "APP_IPHONE_61"
        )
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 1, width: 1260, height: 2736),
            "APP_IPHONE_67"
        )
    }

    func testIPad_M5_Pro13_and_Pro11() {
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 2, width: 2064, height: 2752),
            "APP_IPAD_PRO_3GEN_129"
        )
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 2, width: 1668, height: 2420),
            "APP_IPAD_PRO_3GEN_11"
        )
    }

    /// Was APP_IPAD_MINI_83, which is not an App Store Connect value. Apple
    /// lists the iPad mini size under the 11" class.
    func testIPadMini_in11InchClass() {
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 2, width: 1488, height: 2266),
            "APP_IPAD_PRO_3GEN_11"
        )
    }

    func testMac_anyDims() {
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 6, width: 2880, height: 1800),
            "APP_DESKTOP"
        )
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 6, width: 1280, height: 800),
            "APP_DESKTOP"
        )
    }

    func testUnknownDimensions_returnsNil() {
        XCTAssertNil(ScreenshotDisplayType.resolve(productFamily: 1, width: 999, height: 1999))
        XCTAssertNil(ScreenshotDisplayType.resolve(productFamily: 99, width: 100, height: 200))
    }

    func testDimensionsMatch_true_and_false() {
        XCTAssertTrue(ScreenshotDisplayType.dimensionsMatch(
            displayType: "APP_IPHONE_67",
            pixelWidth: 1320, pixelHeight: 2868, productFamily: 1
        ))
        XCTAssertFalse(ScreenshotDisplayType.dimensionsMatch(
            displayType: "APP_IPHONE_67",
            pixelWidth: 1170, pixelHeight: 2532, productFamily: 1
        ))
    }

    // MARK: - Every size on Apple's screenshot specifications page

    /// (product family, portrait width, portrait height, expected value), one
    /// row per portrait size Apple lists for iPhone and iPad.
    private let specSizes: [(family: Int, width: Int, height: Int, expected: String)] = [
        // iPhone 6.9"
        (1, 1260, 2736, "APP_IPHONE_67"),
        (1, 1290, 2796, "APP_IPHONE_67"),
        (1, 1320, 2868, "APP_IPHONE_67"),
        // iPhone 6.5"
        (1, 1284, 2778, "APP_IPHONE_65"),
        (1, 1242, 2688, "APP_IPHONE_65"),
        // iPhone 6.3"
        (1, 1179, 2556, "APP_IPHONE_61"),
        (1, 1206, 2622, "APP_IPHONE_61"),
        // iPhone 6.1"
        (1, 1170, 2532, "APP_IPHONE_58"),
        (1, 1125, 2436, "APP_IPHONE_58"),
        (1, 1080, 2340, "APP_IPHONE_58"),
        // iPhone 5.5"
        (1, 1242, 2208, "APP_IPHONE_55"),
        // iPhone 4.7"
        (1, 750, 1334, "APP_IPHONE_47"),
        // iPhone 4"
        (1, 640, 1136, "APP_IPHONE_40"),
        (1, 640, 1096, "APP_IPHONE_40"),
        // iPhone 3.5"
        (1, 640, 960, "APP_IPHONE_35"),
        (1, 640, 920, "APP_IPHONE_35"),
        // iPad 13"
        (2, 2064, 2752, "APP_IPAD_PRO_3GEN_129"),
        // iPad 12.9" (also an accepted 13" size; kept on APP_IPAD_PRO_129)
        (2, 2048, 2732, "APP_IPAD_PRO_129"),
        // iPad 11"
        (2, 1488, 2266, "APP_IPAD_PRO_3GEN_11"),
        (2, 1668, 2420, "APP_IPAD_PRO_3GEN_11"),
        (2, 1668, 2388, "APP_IPAD_PRO_3GEN_11"),
        (2, 1640, 2360, "APP_IPAD_PRO_3GEN_11"),
        // iPad 10.5"
        (2, 1668, 2224, "APP_IPAD_105"),
        // iPad 9.7"
        (2, 1536, 2048, "APP_IPAD_97"),
        (2, 1536, 2008, "APP_IPAD_97"),
        (2, 768, 1024, "APP_IPAD_97"),
        (2, 768, 1004, "APP_IPAD_97"),
    ]

    func testEverySpecSize_portraitAndLandscape() {
        for row in specSizes {
            XCTAssertEqual(
                ScreenshotDisplayType.resolve(productFamily: row.family, width: row.width, height: row.height),
                row.expected,
                "\(row.width)x\(row.height) portrait"
            )
            XCTAssertEqual(
                ScreenshotDisplayType.resolve(productFamily: row.family, width: row.height, height: row.width),
                row.expected,
                "\(row.height)x\(row.width) landscape"
            )
            XCTAssertNil(
                ScreenshotDisplayType.awaitingUploadSupport(productFamily: row.family, width: row.width, height: row.height),
                "\(row.width)x\(row.height) is uploadable, not awaiting support"
            )
        }
    }

    /// iPhone 11 / XR (828x1792) and iPad 7th-9th gen (1620x2160) are listed
    /// with a class on Apple's page, but no class accepts their native size.
    func testSizesInNoClass_returnNil() {
        for (family, w, h) in [(1, 828, 1792), (2, 1620, 2160)] {
            XCTAssertNil(ScreenshotDisplayType.resolve(productFamily: family, width: w, height: h))
            XCTAssertNil(ScreenshotDisplayType.resolve(productFamily: family, width: h, height: w))
            XCTAssertNil(ScreenshotDisplayType.awaitingUploadSupport(productFamily: family, width: w, height: h))
        }
    }

    // MARK: - Only real enum values

    func testValidValues_matchOpenAPI_4_4_1() {
        XCTAssertEqual(ScreenshotDisplayType.validValues, ASCOpenAPIScreenshotDisplayTypes.all)
    }

    func testEveryResolvableValue_isAValidEnumValue() {
        let valid = Set(ASCOpenAPIScreenshotDisplayTypes.all)
        let resolvable = ScreenshotDisplayType.resolvableValues
        XCTAssertFalse(resolvable.isEmpty)
        XCTAssertEqual(
            resolvable.subtracting(valid), [],
            "tables return values App Store Connect rejects with 409 ENTITY_ERROR.ATTRIBUTE.TYPE"
        )
        // The table rows cover the spec sizes above; make sure the check
        // really saw them.
        XCTAssertTrue(resolvable.isSuperset(of: Set(specSizes.map(\.expected))))
    }

    // MARK: - iPhone Duo

    func testIPhoneDuo_awaitingUploadSupport_bothOrientations() {
        let cases: [(w: Int, h: Int, screen: String)] = [
            (1398, 2034, "iPhone Duo outer display"),
            (2007, 2853, "iPhone Duo inner display"),
        ]
        for c in cases {
            XCTAssertEqual(ScreenshotDisplayType.awaitingUploadSupport(productFamily: 1, width: c.w, height: c.h), c.screen)
            XCTAssertEqual(ScreenshotDisplayType.awaitingUploadSupport(productFamily: 1, width: c.h, height: c.w), c.screen)
            // No API value yet, so nothing to upload under.
            XCTAssertNil(ScreenshotDisplayType.resolve(productFamily: 1, width: c.w, height: c.h))
            XCTAssertNil(ScreenshotDisplayType.resolve(productFamily: 1, width: c.h, height: c.w))
            // The sizes are iPhone sizes only.
            XCTAssertNil(ScreenshotDisplayType.awaitingUploadSupport(productFamily: 2, width: c.w, height: c.h))
        }
    }

    func testAwaitingUploadSupport_nilForUnknownSizes() {
        XCTAssertNil(ScreenshotDisplayType.awaitingUploadSupport(productFamily: 1, width: 999, height: 1999))
        XCTAssertNil(ScreenshotDisplayType.awaitingUploadSupport(productFamily: 6, width: 1398, height: 2034))
    }
}
