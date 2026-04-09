import Foundation

/// Represents an App Store screenshot size, derived from actual screen dimensions.
/// New devices are automatically supported — no code changes needed.
package struct AppStoreScreenSize: Codable, Hashable, Sendable {
    package let width: Int
    package let height: Int
    package let productFamily: Int

    package init(width: Int, height: Int, productFamily: Int) {
        self.width = width
        self.height = height
        self.productFamily = productFamily
    }

    /// Human-readable display name.
    /// Known resolutions get friendly names like "iPhone 6.7\"".
    /// Unknown resolutions get auto-generated names like "iPhone 1320x2868".
    package var displayName: String {
        let key = "\(productFamily)-\(width)x\(height)"
        if let friendly = Self.friendlyNames[key] {
            return friendly
        }
        return "\(familyPrefix) \(width)x\(height)"
    }

    /// Value written to manifest.json deviceType field.
    package var deviceTypeRawValue: String { displayName }

    /// Filesystem-safe name used as a prefix in output filenames.
    package var filenamePrefix: String {
        displayName
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: " ", with: "_")
    }

    package var isIPhone: Bool { productFamily == 1 }
    package var isIPad: Bool { productFamily == 2 }
    package var isAppleWatch: Bool { productFamily == 4 }
    package var isMac: Bool { productFamily == 6 }

    private var familyPrefix: String {
        switch productFamily {
        case 1: return "iPhone"
        case 2: return "iPad"
        case 4: return "Apple Watch"
        case 6: return "Mac"
        default: return "Device"
        }
    }

    // MARK: - Friendly names for known resolutions

    /// Maps "family-widthxheight" to a human-readable App Store display name.
    /// This table is purely cosmetic — the CLI works without it.
    /// When Apple adds a new resolution, it auto-generates a name until this table is updated.
    private static let friendlyNames: [String: String] = [
        // iPhone
        "1-1320x2868": "iPhone 6.9\"",    // iPhone 16/17 Pro Max
        "1-1290x2796": "iPhone 6.7\"",    // iPhone 14 Pro Max, 15 Plus/Pro Max, 16 Plus
        "1-1284x2778": "iPhone 6.7\"",    // iPhone 12/13 Pro Max, 14 Plus
        "1-1260x2736": "iPhone 6.3\"",    // iPhone Air
        "1-1242x2688": "iPhone 6.5\"",    // iPhone Xs Max, 11 Pro Max
        "1-1206x2622": "iPhone 6.3\"",    // iPhone 16/17 Pro, 17
        "1-1179x2556": "iPhone 6.1\"",    // iPhone 14 Pro, 15, 15 Pro, 16
        "1-1170x2532": "iPhone 6.1\"",    // iPhone 12, 12 Pro, 13, 13 Pro, 14, 16e
        "1-1125x2436": "iPhone 5.8\"",    // iPhone X, Xs, 11 Pro
        "1-1080x2340": "iPhone 5.4\"",    // iPhone 12 mini, 13 mini
        "1-1242x2208": "iPhone 5.5\"",    // iPhone 6s/7/8 Plus
        "1-828x1792":  "iPhone 6.1\"",    // iPhone Xr, 11
        "1-750x1334":  "iPhone 4.7\"",    // iPhone 6s, 7, 8, SE 2/3
        "1-640x1136":  "iPhone 4\"",      // iPhone SE 1st gen, 5s
        // iPad
        "2-2064x2752": "iPad Pro 13\"",   // iPad Pro 13-inch M4/M5
        "2-2048x2732": "iPad Pro 12.9\"", // iPad Pro 12.9", iPad Air 13"
        "2-1668x2420": "iPad Pro 11\"",   // iPad Pro 11" M4/M5
        "2-1668x2388": "iPad Pro 11\"",   // iPad Pro 11" 1st-4th gen
        "2-1668x2224": "iPad 10.5\"",     // iPad Air 3rd gen, iPad Pro 10.5"
        "2-1640x2360": "iPad 10.9\"",     // iPad 10th gen, iPad Air 11"
        "2-1620x2160": "iPad 10.2\"",     // iPad 7th-9th gen
        "2-1536x2048": "iPad 9.7\"",      // iPad Air 2, iPad Pro 9.7", iPad 5th/6th
        "2-1488x2266": "iPad mini 8.3\"", // iPad mini 6th gen, iPad mini A17 Pro
        // Apple Watch
        "4-422x514":  "Apple Watch Ultra 49mm",   // Ultra 3
        "4-410x502":  "Apple Watch Ultra 49mm",   // Ultra, Ultra 2
        "4-416x496":  "Apple Watch 46mm",          // Series 10, 11
        "4-396x484":  "Apple Watch 45mm",          // Series 7, 8, 9
        "4-374x446":  "Apple Watch 42mm",          // Series 10, 11 (small)
        "4-368x448":  "Apple Watch 44mm",          // Series 4-6, SE
        "4-352x430":  "Apple Watch 41mm",          // Series 7, 8, 9 (small)
        "4-324x394":  "Apple Watch 40mm",          // Series 4-6, SE (small)
        "4-312x390":  "Apple Watch 42mm (S3)",     // Series 2, 3
        "4-272x340":  "Apple Watch 38mm",          // Series 2, 3 (small)
        // Mac (App Store Connect screenshot sizes)
        "6-2880x1800": "Mac 2880x1800",            // 15" Retina (MacBook Pro 15")
        "6-2560x1600": "Mac 2560x1600",            // Retina (MacBook Pro 13", Air 13" M1+)
        "6-1440x900":  "Mac 1440x900",             // Non-Retina
        "6-1280x800":  "Mac 1280x800",             // Minimum required
    ]
}

package struct DeviceMapping {

    /// Read screen dimensions from a device type's CoreSimulator profile.plist.
    /// Returns (width, height, productFamily) or nil if the profile can't be read.
    package static func readProfile(bundlePath: String) -> (width: Int, height: Int, productFamily: Int)? {
        let profilePath = (bundlePath as NSString)
            .appendingPathComponent("Contents/Resources/profile.plist")

        guard let data = FileManager.default.contents(atPath: profilePath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        // mainScreenWidth/Height can be Int or Double in the plist
        let width: Int
        let height: Int
        if let w = plist["mainScreenWidth"] as? Int {
            width = w
        } else if let w = plist["mainScreenWidth"] as? Double {
            width = Int(w)
        } else {
            return nil
        }
        if let h = plist["mainScreenHeight"] as? Int {
            height = h
        } else if let h = plist["mainScreenHeight"] as? Double {
            height = Int(h)
        } else {
            return nil
        }

        // supportedProductFamilyIDs: 1=iPhone, 2=iPad, 3=Apple TV, 4=Watch, 7=Vision
        let family: Int
        if let families = plist["supportedProductFamilyIDs"] as? [Int], let first = families.first {
            family = first
        } else {
            return nil
        }

        return (width, height, family)
    }
}
