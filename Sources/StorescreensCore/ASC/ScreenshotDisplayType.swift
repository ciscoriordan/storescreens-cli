import Foundation
import CoreGraphics

/// Maps our device class + screen dimensions to App Store Connect's
/// `screenshotDisplayType` enum strings. ASC uses these to slot each
/// screenshot into the correct device bucket on the product page.
///
/// Reference: https://developer.apple.com/documentation/appstoreconnectapi/screenshotdisplaytype
package enum ScreenshotDisplayType {

    /// Resolves a displayType for a screenshot whose native dimensions are
    /// `(width, height)` and whose product family is 1=iPhone, 2=iPad, 6=Mac.
    /// Returns nil when we don't recognize the dimensions (e.g. Apple Watch).
    package static func resolve(
        productFamily: Int,
        width: Int,
        height: Int
    ) -> String? {
        // Normalize to portrait dims for lookup.
        let w = min(width, height)
        let h = max(width, height)

        switch productFamily {
        case 1:   // iPhone
            return resolveIPhone(width: w, height: h)
        case 2:   // iPad
            return resolveIPad(width: w, height: h)
        case 6:   // Mac
            return "APP_DESKTOP"
        default:
            return nil
        }
    }

    private static func resolveIPhone(width w: Int, height h: Int) -> String? {
        // Keyed by portrait dims. Values match ASC's screenshotDisplayType.
        // Sources: ASC API enum + Apple's 2024/2025 screenshot specifications.
        switch (w, h) {
        // Apple's screenshotDisplayType enum does NOT have APP_IPHONE_69 yet
        // as of 2026-04; the 1320x2868 "6.9"" slot in the ASC web UI is
        // still fed from APP_IPHONE_67 uploads (the 6.7" slot), which
        // the gallery then auto-scales up. Uploading under the
        // literal "APP_IPHONE_69" enum fails with a 409
        // ENTITY_ERROR.ATTRIBUTE.TYPE. Route 6.9" screenshots into
        // APP_IPHONE_67 until Apple ships a native 69 enum value.
        case (1320, 2868):  return "APP_IPHONE_67"    // iPhone 17 Pro Max / 16 Pro Max (uploaded under 6.7" slot; ASC auto-fills 6.9")
        case (1290, 2796):  return "APP_IPHONE_67"    // iPhone 14 Pro Max, 15 Plus/Pro Max, 16 Plus
        case (1284, 2778):  return "APP_IPHONE_67"    // iPhone 12/13 Pro Max, 14 Plus
        case (1260, 2736):  return "APP_IPHONE_63"    // iPhone Air
        case (1242, 2688):  return "APP_IPHONE_65"    // iPhone Xs Max, 11 Pro Max
        case (1206, 2622):  return "APP_IPHONE_63"    // iPhone 16/17 Pro, 17
        case (1179, 2556):  return "APP_IPHONE_61"    // iPhone 14 Pro, 15, 15 Pro, 16
        case (1170, 2532):  return "APP_IPHONE_61"    // iPhone 12/13 and non-Pro 14/16
        case (1125, 2436):  return "APP_IPHONE_58"    // iPhone X, Xs, 11 Pro
        case (1080, 2340):  return "APP_IPHONE_54"    // iPhone 12/13 mini
        case (1242, 2208):  return "APP_IPHONE_55"    // iPhone 6s/7/8 Plus
        case (828, 1792):   return "APP_IPHONE_61"    // iPhone Xr, 11
        case (750, 1334):   return "APP_IPHONE_47"    // iPhone 6s-8, SE 2/3
        case (640, 1136):   return "APP_IPHONE_40"    // iPhone SE 1st gen, 5s
        default: return nil
        }
    }

    private static func resolveIPad(width w: Int, height h: Int) -> String? {
        switch (w, h) {
        case (2064, 2752):  return "APP_IPAD_PRO_3GEN_129"  // iPad Pro 13" M4/M5 ("13-inch" slot)
        case (2048, 2732):  return "APP_IPAD_PRO_129"       // iPad Pro 12.9", iPad Air 13"
        case (1668, 2420):  return "APP_IPAD_PRO_3GEN_11"   // iPad Pro 11" M4/M5
        case (1668, 2388):  return "APP_IPAD_PRO"           // iPad Pro 11" older
        case (1668, 2224):  return "APP_IPAD_105"           // iPad Air 3rd gen, iPad Pro 10.5"
        case (1640, 2360):  return "APP_IPAD_109"           // iPad 10th gen, iPad Air 11"
        case (1620, 2160):  return "APP_IPAD_102"           // iPad 7th-9th gen
        case (1536, 2048):  return "APP_IPAD_97"            // iPad Air 2, iPad Pro 9.7", iPad 5th/6th
        case (1488, 2266):  return "APP_IPAD_MINI_83"       // iPad mini 6, iPad mini A17 Pro
        default: return nil
        }
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
}
