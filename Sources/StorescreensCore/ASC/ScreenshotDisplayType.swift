import Foundation
import CoreGraphics

/// Maps our device class + screen dimensions to App Store Connect's
/// `screenshotDisplayType` enum strings. ASC uses these to slot each
/// screenshot into the correct device bucket on the product page.
///
/// App Store Connect sorts screenshots into size classes ("6.9-inch
/// display", "6.3-inch display", ...) and keeps one screenshot set per class
/// and localization. When Apple introduced larger phones it did not add new
/// enum values; it kept the old names and re-pointed each one at the current
/// size class. The number in a value's name is therefore historical, not the
/// class it holds today:
///
///     APP_IPHONE_67  6.9"        APP_IPHONE_55  5.5"
///     APP_IPHONE_65  6.5"        APP_IPHONE_47  4.7"
///     APP_IPHONE_61  6.3"        APP_IPHONE_40  4"
///     APP_IPHONE_58  6.1"        APP_IPHONE_35  3.5"
///
///     APP_IPAD_PRO_3GEN_129  13"      APP_IPAD_105  10.5"
///     APP_IPAD_PRO_129       12.9"    APP_IPAD_97   9.7"
///     APP_IPAD_PRO_3GEN_11   11"
///
/// The values come from Apple's App Store Connect OpenAPI spec (4.4.1); the
/// pixel sizes accepted in each class come from the screenshot
/// specifications page. Uploading under a value that is not in the enum
/// (for example a made-up "APP_IPHONE_69" or "APP_IPHONE_63") fails with a
/// 409 ENTITY_ERROR.ATTRIBUTE.TYPE, so every table below may only return
/// values listed in `validValues`.
///
/// References:
///   https://developer.apple.com/documentation/appstoreconnectapi/screenshotdisplaytype
///   https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
package enum ScreenshotDisplayType {

    /// Every `screenshotDisplayType` value the App Store Connect API accepts,
    /// copied in order from the `ScreenshotDisplayType` schema of Apple's
    /// OpenAPI spec 4.4.1. Update it only from a newer copy of that spec.
    package static let validValues: [String] = [
        "APP_IPHONE_67",
        "APP_IPHONE_61",
        "APP_IPHONE_65",
        "APP_IPHONE_58",
        "APP_IPHONE_55",
        "APP_IPHONE_47",
        "APP_IPHONE_40",
        "APP_IPHONE_35",
        "APP_IPAD_PRO_3GEN_129",
        "APP_IPAD_PRO_3GEN_11",
        "APP_IPAD_PRO_129",
        "APP_IPAD_105",
        "APP_IPAD_97",
        "APP_DESKTOP",
        "APP_WATCH_ULTRA",
        "APP_WATCH_SERIES_10",
        "APP_WATCH_SERIES_7",
        "APP_WATCH_SERIES_4",
        "APP_WATCH_SERIES_3",
        "APP_APPLE_TV",
        "APP_APPLE_VISION_PRO",
        "IMESSAGE_APP_IPHONE_67",
        "IMESSAGE_APP_IPHONE_61",
        "IMESSAGE_APP_IPHONE_65",
        "IMESSAGE_APP_IPHONE_58",
        "IMESSAGE_APP_IPHONE_55",
        "IMESSAGE_APP_IPHONE_47",
        "IMESSAGE_APP_IPHONE_40",
        "IMESSAGE_APP_IPAD_PRO_3GEN_129",
        "IMESSAGE_APP_IPAD_PRO_3GEN_11",
        "IMESSAGE_APP_IPAD_PRO_129",
        "IMESSAGE_APP_IPAD_105",
        "IMESSAGE_APP_IPAD_97",
    ]

    /// Resolves a displayType for a screenshot whose native dimensions are
    /// `(width, height)` and whose product family is 1=iPhone, 2=iPad, 6=Mac.
    /// Returns nil when we don't recognize the dimensions (e.g. Apple Watch),
    /// and for sizes that are `awaitingUploadSupport`.
    package static func resolve(
        productFamily: Int,
        width: Int,
        height: Int
    ) -> String? {
        guard case .displayType(let value) = slot(productFamily: productFamily, width: width, height: height) else {
            return nil
        }
        return value
    }

    /// Names the screen (e.g. "iPhone Duo inner display") when Apple's
    /// screenshot specifications list `(width, height)` but App Store Connect
    /// cannot take screenshots of that size through the API yet. Returns nil
    /// for every other size, including ones `resolve` handles. Callers skip
    /// these screenshots instead of treating them as errors.
    package static func awaitingUploadSupport(
        productFamily: Int,
        width: Int,
        height: Int
    ) -> String? {
        guard case .awaitingUploadSupport(let screen) = slot(productFamily: productFamily, width: width, height: height) else {
            return nil
        }
        return screen
    }

    /// Why screenshots that are `awaitingUploadSupport` were not uploaded,
    /// worded for the operator. Lives next to the table rows it describes so
    /// that both change together.
    package static let awaitingUploadSupportReason =
        "App Store Connect does not accept iPhone Duo screenshots yet; Apple says upload support arrives later this year"

    /// Every value `resolve` can return, for checking the tables against
    /// `validValues`.
    package static var resolvableValues: Set<String> {
        var values: Set<String> = [macDisplayType]
        for case .displayType(let value) in iPhoneSlots.values { values.insert(value) }
        for case .displayType(let value) in iPadSlots.values { values.insert(value) }
        return values
    }

    /// Opposite direction: given a known displayType, does this screenshot's
    /// pixel dimensions match (portrait OR landscape)? Useful for `submit`
    /// validation when we need to confirm we're uploading a valid size for
    /// the slot we're writing to.
    package static func dimensionsMatch(
        displayType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        productFamily: Int
    ) -> Bool {
        resolve(productFamily: productFamily, width: pixelWidth, height: pixelHeight) == displayType
    }

    // MARK: - Tables

    /// What App Store Connect does with screenshots of one pixel size.
    private enum Slot: Equatable {
        /// Uploaded under this `screenshotDisplayType` value.
        case displayType(String)
        /// Listed in Apple's screenshot specifications, but the API has no
        /// value for it yet. The string names the screen for messages.
        case awaitingUploadSupport(String)
    }

    /// Portrait pixel size (width <= height), the key of both tables.
    private struct PortraitSize: Hashable {
        let width: Int
        let height: Int
        init(_ width: Int, _ height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// Mac screenshots take any of Apple's 16:10 sizes, all in one class.
    private static let macDisplayType = "APP_DESKTOP"

    private static func slot(productFamily: Int, width: Int, height: Int) -> Slot? {
        // Both orientations of a size belong to the same class, so look up
        // the portrait form.
        let key = PortraitSize(min(width, height), max(width, height))
        switch productFamily {
        case 1:   // iPhone
            return iPhoneSlots[key]
        case 2:   // iPad
            return iPadSlots[key]
        case 6:   // Mac
            return .displayType(macDisplayType)
        default:
            return nil
        }
    }

    /// iPhone rows, keyed by portrait pixel size. The comment on each row
    /// names the devices whose screenshots come out at that size.
    ///
    /// iPhone Duo rows are `awaitingUploadSupport`: Apple published the
    /// sizes (with "Support for uploading assets for this device in App
    /// Store Connect will be available later this year") but the API enum
    /// has no value for them. When Apple adds one, change each Duo row to
    /// `.displayType("<new value>")`, add the value to `validValues`, and
    /// drop `awaitingUploadSupportReason` if nothing else uses it.
    ///
    /// Not listed on purpose: 828x1792 (iPhone 11, iPhone XR). Apple lists
    /// those phones under 6.5" but accepts no screenshot at their native
    /// size, so it resolves to nil and submit reports it.
    private static let iPhoneSlots: [PortraitSize: Slot] = [
        // 6.9"
        PortraitSize(1320, 2868): .displayType("APP_IPHONE_67"),   // iPhone 18 Pro Max, 17 Pro Max, 16 Pro Max
        PortraitSize(1290, 2796): .displayType("APP_IPHONE_67"),   // iPhone 16 Plus, 15 Plus, 15 Pro Max, 14 Pro Max
        PortraitSize(1260, 2736): .displayType("APP_IPHONE_67"),   // iPhone Air
        // 6.5"
        PortraitSize(1284, 2778): .displayType("APP_IPHONE_65"),   // iPhone 14 Plus, 13 Pro Max, 12 Pro Max
        PortraitSize(1242, 2688): .displayType("APP_IPHONE_65"),   // iPhone 11 Pro Max, Xs Max
        // 6.3"
        PortraitSize(1206, 2622): .displayType("APP_IPHONE_61"),   // iPhone 18 Pro, 17 Pro, 17, 16 Pro
        PortraitSize(1179, 2556): .displayType("APP_IPHONE_61"),   // iPhone 16, 15 Pro, 15, 14 Pro
        // 6.1"
        PortraitSize(1170, 2532): .displayType("APP_IPHONE_58"),   // iPhone 17e, 16e, 14, 13 Pro, 13, 12 Pro, 12
        PortraitSize(1125, 2436): .displayType("APP_IPHONE_58"),   // iPhone 11 Pro, Xs, X
        PortraitSize(1080, 2340): .displayType("APP_IPHONE_58"),   // iPhone 13 mini, 12 mini
        // 5.5"
        PortraitSize(1242, 2208): .displayType("APP_IPHONE_55"),   // iPhone 8 Plus, 7 Plus, 6s Plus, 6 Plus
        // 4.7"
        PortraitSize(750, 1334):  .displayType("APP_IPHONE_47"),   // iPhone SE 2nd/3rd gen, 8, 7, 6s, 6
        // 4"
        PortraitSize(640, 1136):  .displayType("APP_IPHONE_40"),   // iPhone SE 1st gen, 5s, 5c, 5
        PortraitSize(640, 1096):  .displayType("APP_IPHONE_40"),   // same phones, status bar cropped off
        // 3.5"
        PortraitSize(640, 960):   .displayType("APP_IPHONE_35"),   // iPhone 4s, 4
        PortraitSize(640, 920):   .displayType("APP_IPHONE_35"),   // same phones, status bar cropped off
        // iPhone Duo (foldable). Not uploadable yet, see above.
        PortraitSize(1398, 2034): .awaitingUploadSupport("iPhone Duo outer display"),
        PortraitSize(2007, 2853): .awaitingUploadSupport("iPhone Duo inner display"),
    ]

    /// iPad rows, keyed by portrait pixel size.
    ///
    /// Not listed on purpose: 1620x2160 (iPad 7th-9th gen, 10.2"). Apple
    /// lists those iPads under 10.5" but accepts no screenshot at their
    /// native size, so it resolves to nil and submit reports it.
    private static let iPadSlots: [PortraitSize: Slot] = [
        // 13"
        PortraitSize(2064, 2752): .displayType("APP_IPAD_PRO_3GEN_129"),  // iPad Pro 13" (M5, M4)
        // 2048x2732 (iPad Pro 12.9" 1st-6th gen, iPad Air 13" M2-M4) is
        // accepted by both the 13" class and the separate 12.9" class,
        // whose only size it is. It stays on APP_IPAD_PRO_129 because apps
        // already have live APP_IPAD_PRO_129 sets filled from it; moving it
        // to APP_IPAD_PRO_3GEN_129 would start a second set next to those
        // and is a separate change.
        PortraitSize(2048, 2732): .displayType("APP_IPAD_PRO_129"),
        // 11"
        PortraitSize(1668, 2420): .displayType("APP_IPAD_PRO_3GEN_11"),   // iPad Pro 11" (M5, M4)
        PortraitSize(1668, 2388): .displayType("APP_IPAD_PRO_3GEN_11"),   // iPad Pro 11" 1st-4th gen
        PortraitSize(1640, 2360): .displayType("APP_IPAD_PRO_3GEN_11"),   // iPad Air 11" (M4, M3, M2), iPad Air 4th/5th gen, iPad (A16), iPad 10th gen
        PortraitSize(1488, 2266): .displayType("APP_IPAD_PRO_3GEN_11"),   // iPad mini (A17 Pro), iPad mini 6th gen
        // 10.5"
        PortraitSize(1668, 2224): .displayType("APP_IPAD_105"),           // iPad Pro 10.5", iPad Air 3rd gen
        // 9.7"
        PortraitSize(1536, 2048): .displayType("APP_IPAD_97"),            // iPad Pro 9.7", iPad Air 2, iPad Air, iPad 3rd-6th gen, iPad mini 2-5
        PortraitSize(1536, 2008): .displayType("APP_IPAD_97"),            // same iPads, status bar cropped off
        PortraitSize(768, 1024):  .displayType("APP_IPAD_97"),            // iPad 2, iPad mini 1st gen
        PortraitSize(768, 1004):  .displayType("APP_IPAD_97"),            // same iPads, status bar cropped off
    ]
}
