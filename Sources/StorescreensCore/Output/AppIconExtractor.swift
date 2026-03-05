import Foundation

package struct AppIconExtractor {
    /// Extracts the app icon from a built .app bundle and copies it to the output directory.
    /// The compiled .app always has pre-rendered AppIcon PNGs regardless of source format
    /// (.icon, .appiconset, single-size, etc). Picks the largest one.
    ///
    /// Returns the filename of the extracted icon, or nil if none found.
    @discardableResult
    package static func extract(appBundlePath: String, to outputDir: String) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: appBundlePath) else {
            return nil
        }

        let iconFiles = contents
            .filter { $0.hasPrefix("AppIcon") && $0.hasSuffix(".png") }
            .map { (appBundlePath as NSString).appendingPathComponent($0) }
            .sorted { fileSize($0) > fileSize($1) }

        guard let largest = iconFiles.first else { return nil }

        let destPath = (outputDir as NSString).appendingPathComponent("AppIcon.png")
        try? fm.copyItem(atPath: largest, toPath: destPath)
        return "AppIcon.png"
    }

    private static func fileSize(_ path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
    }
}
