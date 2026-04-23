import XCTest
@testable import StorescreensCore

final class ScreenshotDisplayTypeTests: XCTestCase {

    func testIPhone_portraitAndLandscape_sameDisplayType() {
        // Portrait dims for iPhone 17 Pro Max.
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 1, width: 1320, height: 2868),
            "APP_IPHONE_69"
        )
        // Landscape dims (swap w/h) should resolve to the same slot.
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 1, width: 2868, height: 1320),
            "APP_IPHONE_69"
        )
    }

    func testIPhone_ProAndAir_differentSlots() {
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 1, width: 1206, height: 2622),
            "APP_IPHONE_63"
        )
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 1, width: 1260, height: 2736),
            "APP_IPHONE_63"
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

    func testIPadMini() {
        XCTAssertEqual(
            ScreenshotDisplayType.resolve(productFamily: 2, width: 1488, height: 2266),
            "APP_IPAD_MINI_83"
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
            displayType: "APP_IPHONE_69",
            pixelWidth: 1320, pixelHeight: 2868, productFamily: 1
        ))
        XCTAssertFalse(ScreenshotDisplayType.dimensionsMatch(
            displayType: "APP_IPHONE_69",
            pixelWidth: 1170, pixelHeight: 2532, productFamily: 1
        ))
    }
}
