import Foundation

/// Finds mounted Apple Design Resource DMGs under /Volumes.
///
/// Detection rules (either signals a candidate):
///   1. Volume name starts with "Bezel-" (recent Apple DMG naming)
///   2. Volume contains "Apple Design Resources License.rtf" at its root
///
/// Returns absolute URLs to each matching volume root. Skips the boot volume,
/// data volume, and anything we can't stat.
package enum VolumeScanner {

    private static let licenseFilename = "Apple Design Resources License.rtf"

    package static func findAppleDesignResourceVolumes() -> [URL] {
        let fm = FileManager.default
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        guard let entries = try? fm.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.filter { isAppleDesignResourceVolume($0) }
    }

    package static func isAppleDesignResourceVolume(_ volumeURL: URL) -> Bool {
        let name = volumeURL.lastPathComponent
        if name.hasPrefix("Bezel-") { return true }

        let licensePath = volumeURL.appendingPathComponent(licenseFilename).path
        return FileManager.default.fileExists(atPath: licensePath)
    }
}
