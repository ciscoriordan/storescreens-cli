import Foundation
import CoreGraphics

/// Resolves a canonical bezel key (e.g. `iPhone_1320x2868_portrait`) to the
/// PNG + metadata the render pipeline needs. Checks project-local overrides
/// first, then the user-global install directory.
package struct BezelStore {

    /// Directory lookup order. The first match wins. `projectLocal` is
    /// typically `./bezels/` next to the user's project YML; `userGlobal`
    /// is `~/Library/Application Support/storescreens/bezels/`.
    package let searchPaths: [URL]

    package init(projectLocal: URL?, userGlobal: URL? = nil) {
        var paths: [URL] = []
        if let projectLocal { paths.append(projectLocal) }
        paths.append(userGlobal ?? BezelExporter.defaultInstallDirectory())
        self.searchPaths = paths
    }

    package struct Asset: Sendable {
        package let pngURL: URL
        package let metadata: BezelMetadata
    }

    /// Returns the asset for a canonical key, or nil if neither directory has
    /// both the PNG and its JSON sidecar.
    package func lookup(canonicalKey: String) -> Asset? {
        let fm = FileManager.default
        for dir in searchPaths {
            let pngURL = dir.appendingPathComponent("\(canonicalKey).png")
            let jsonURL = dir.appendingPathComponent("\(canonicalKey).json")
            guard fm.fileExists(atPath: pngURL.path),
                  fm.fileExists(atPath: jsonURL.path) else { continue }
            guard let data = try? Data(contentsOf: jsonURL),
                  let metadata = try? JSONDecoder().decode(BezelMetadata.self, from: data) else {
                continue
            }
            return Asset(pngURL: pngURL, metadata: metadata)
        }
        return nil
    }

    /// Lists all canonical keys installed across the search paths. Used by
    /// `storescreens bezels check` to report state.
    package func installedKeys() -> Set<String> {
        let fm = FileManager.default
        var keys: Set<String> = []
        for dir in searchPaths {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension == "png" {
                let key = entry.deletingPathExtension().lastPathComponent
                let jsonURL = dir.appendingPathComponent("\(key).json")
                if fm.fileExists(atPath: jsonURL.path) {
                    keys.insert(key)
                }
            }
        }
        return keys
    }

    /// Canonical key for a screenshot of given pixel dimensions and product
    /// family. Matches the scheme used by `BezelImporter.makeCanonicalKey`.
    package static func canonicalKey(
        productFamily: Int,
        width: Int,
        height: Int,
        orientation: BezelOrientation
    ) -> String {
        let prefix: String
        switch productFamily {
        case 1: prefix = "iPhone"
        case 2: prefix = "iPad"
        case 4: prefix = "Watch"
        case 6: prefix = "MacBook"
        default: prefix = "Device\(productFamily)"
        }
        if orientation == .none {
            return "\(prefix)_\(width)x\(height)"
        }
        return "\(prefix)_\(width)x\(height)_\(orientation.rawValue)"
    }
}
