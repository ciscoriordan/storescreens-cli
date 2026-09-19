import Foundation

/// Represents an App Store screenshot size, derived from actual screen dimensions.
///
/// The pixel size comes from the simulator's CoreSimulator device type, so a
/// device Apple adds later is captured without code changes. What needs a
/// code change is the human-readable label (see `friendlyNames`): until a
/// size is listed there, its screenshots are labeled "iPhone WxH".
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
    /// The lookup ignores orientation (a landscape capture of a known size
    /// gets the same name as the portrait one); the auto-generated name keeps
    /// the width and height as given.
    package var displayName: String {
        if let friendly = Self.friendlyNamesByPortraitSize[portraitKey] {
            return friendly
        }
        return "\(familyPrefix) \(width)x\(height)"
    }

    /// True when `friendlyNames` lists this size (in either orientation),
    /// i.e. it is a screen size storescreens knows by name.
    package var hasFriendlyName: Bool {
        Self.friendlyNamesByPortraitSize[portraitKey] != nil
    }

    /// App Store Connect's `screenshotDisplayType` for this size, or nil when
    /// App Store Connect has no screenshot slot for it (the iPhone Duo, Apple
    /// Watch, or a size storescreens does not know). `ScreenshotDisplayType`
    /// is the source of truth for which App Store size class a pixel size
    /// belongs to; the label in `displayName` is not.
    package var screenshotDisplayType: String? {
        ScreenshotDisplayType.resolve(productFamily: productFamily, width: width, height: height)
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

    /// `friendlyNames` keyed by the portrait form of each size, which is what
    /// `displayName` looks up. The table itself lists each size the way Apple
    /// quotes it (Mac sizes are landscape).
    private static let friendlyNamesByPortraitSize: [String: String] = Dictionary(
        friendlyNames.map { key, name in (portraitKey(forTableKey: key), name) },
        uniquingKeysWith: { first, _ in first }
    )

    private var portraitKey: String {
        "\(productFamily)-\(min(width, height))x\(max(width, height))"
    }

    private static func portraitKey(forTableKey key: String) -> String {
        let parts = key.split(separator: "-", maxSplits: 1)
        let dims = parts.count == 2 ? parts[1].split(separator: "x").compactMap { Int($0) } : []
        guard dims.count == 2 else { return key }
        return "\(parts[0])-\(min(dims[0], dims[1]))x\(max(dims[0], dims[1]))"
    }

    /// Maps "family-widthxheight" to a human-readable App Store display name.
    ///
    /// The name is more than cosmetic. It is written to manifest.json as the
    /// device's `deviceType`, it becomes the output filename prefix
    /// ("iPhone 6.9\"" -> "iPhone_6.9_Home.png"), and it keys the HTML
    /// preview pages. Render and submit read the product family from its
    /// "iPhone" / "iPad" prefix. Two sizes that share a name therefore share
    /// output files, so a UI-test capture that includes both overwrites one
    /// with the other (capture warns, see `ResolvedDevice.sharedLabels`;
    /// simple mode names files by device position instead), and renaming
    /// an existing entry renames every file captured for that size. The App
    /// Store size class used for upload is not taken from this name: submit
    /// decides it from each PNG's pixel size through `ScreenshotDisplayType`.
    ///
    /// A size missing from this table still captures, under an auto-generated
    /// "iPhone WxH" name, until the table is updated.
    private static let friendlyNames: [String: String] = [
        // iPhone
        "1-1320x2868": "iPhone 6.9\"",    // iPhone 16/17/18 Pro Max
        "1-1290x2796": "iPhone 6.7\"",    // iPhone 14 Pro Max, 15 Plus/Pro Max, 16 Plus
        "1-1284x2778": "iPhone 6.7\"",    // iPhone 12/13 Pro Max, 14 Plus
        "1-1260x2736": "iPhone 6.3\"",    // iPhone Air
        "1-1242x2688": "iPhone 6.5\"",    // iPhone Xs Max, 11 Pro Max
        "1-1206x2622": "iPhone 6.3\"",    // iPhone 16/17/18 Pro, 17
        "1-1179x2556": "iPhone 6.1\"",    // iPhone 14 Pro, 15, 15 Pro, 16
        "1-1170x2532": "iPhone 6.1\"",    // iPhone 12, 12 Pro, 13, 13 Pro, 14, 16e
        "1-1125x2436": "iPhone 5.8\"",    // iPhone X, Xs, 11 Pro
        "1-1080x2340": "iPhone 5.4\"",    // iPhone 12 mini, 13 mini
        "1-1242x2208": "iPhone 5.5\"",    // iPhone 6s/7/8 Plus
        "1-828x1792":  "iPhone 6.1\"",    // iPhone Xr, 11
        "1-750x1334":  "iPhone 4.7\"",    // iPhone 6s, 7, 8, SE 2/3
        "1-640x1136":  "iPhone 4\"",      // iPhone SE 1st gen, 5s
        // iPhone Duo (foldable). Each display gets its own name because the
        // simulator produces screenshots of whichever display the device's
        // pose (folded or open) has active. App Store Connect lists both
        // sizes but has no upload slot for them yet.
        "1-1398x2034": "iPhone Duo outer", // iPhone Duo outer display (folded)
        "1-2007x2853": "iPhone Duo inner", // iPhone Duo inner display (open)
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

    /// Read screen dimensions from a device type's CoreSimulator bundle.
    /// Returns (width, height, productFamily) or nil if the bundle can't be read.
    ///
    /// Older CoreSimulator releases put the main screen's pixel size in
    /// profile.plist as `mainScreenWidth` / `mainScreenHeight`. The release
    /// that shipped alongside Xcode 27 (September 2026) removed both keys from
    /// every device type and describes the screens in capabilities.plist
    /// instead, under `capabilities.displays`, one entry per screen. Reading
    /// only the old keys made every device unresolvable ("Could not determine
    /// App Store size"), so both layouts are read.
    package static func readProfile(bundlePath: String) -> (width: Int, height: Int, productFamily: Int)? {
        let resources = (bundlePath as NSString).appendingPathComponent("Contents/Resources")
        guard let plist = readPlist(atPath: (resources as NSString).appendingPathComponent("profile.plist")) else {
            return nil
        }

        // supportedProductFamilyIDs: 1=iPhone, 2=iPad, 3=Apple TV, 4=Watch, 7=Vision
        guard let families = plist["supportedProductFamilyIDs"] as? [Int], let family = families.first else {
            return nil
        }

        if let width = intValue(plist["mainScreenWidth"]), let height = intValue(plist["mainScreenHeight"]) {
            return (width, height, family)
        }

        guard let capabilities = readPlist(atPath: (resources as NSString).appendingPathComponent("capabilities.plist")),
              let screen = mainDisplay(in: capabilities) else {
            return nil
        }
        return (screen.width, screen.height, family)
    }

    /// The device's own screen from capabilities.plist: screenID 1, which is
    /// the built-in touch display. The other entries are external displays
    /// (CarPlay at 720x480, an 8K monitor), and taking the first or the
    /// largest would pick one of those on some devices.
    ///
    /// A device with two built-in displays (the iPhone Duo: outer display
    /// when folded, inner when open) still gets one size here, and which
    /// display a screenshot shows depends on a pose storescreens cannot set.
    /// Capture therefore labels each screenshot by its own pixel size when it
    /// differs from this one (`OutputOrganizer.labelSize`).
    static func mainDisplay(in capabilities: [String: Any]) -> (width: Int, height: Int)? {
        guard let inner = capabilities["capabilities"] as? [String: Any],
              let displays = inner["displays"] as? [[String: Any]] else {
            return nil
        }
        let main = displays.first { intValue($0["screenID"]) == 1 }
            ?? displays.first { ($0["hasDigitizer"] as? Bool) == true }
        guard let main, let width = intValue(main["width"]), let height = intValue(main["height"]) else {
            return nil
        }
        return (width, height)
    }

    private static func readPlist(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Plist numbers can decode as Int or Double.
    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}
