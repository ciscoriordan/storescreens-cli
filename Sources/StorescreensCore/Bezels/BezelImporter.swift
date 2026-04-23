import Foundation
import CoreGraphics

/// Discovers bezel PSD files across mounted Apple Design Resource DMGs and
/// classifies them by (screen-dimension, orientation) groups, applying user
/// preferences to pick one winner per group.
///
/// This stage produces `BezelCandidate` values only; the transparent-screen
/// PNG export happens in a separate step (BezelExporter).
package enum BezelImporter {

    package enum ImportError: Error, CustomStringConvertible {
        case noVolumesMounted
        case noScreenLayer(source: String, availableLayers: [String])
        case unknownProductFamily(filename: String)

        package var description: String {
            switch self {
            case .noVolumesMounted:
                return "no Apple Design Resource DMGs mounted under /Volumes — mount a DMG first"
            case .noScreenLayer(let src, let layers):
                return "PSD \(src) has no 'Screen' layer (found: \(layers.joined(separator: ", ")))"
            case .unknownProductFamily(let f):
                return "cannot infer product family from filename: \(f)"
            }
        }
    }

    /// Walks the given volumes, parses every `.psd` found, and returns one
    /// candidate per readable PSD. PSDs that can't be parsed or have no
    /// `Screen` layer are skipped with a warning through `onWarning`.
    package static func discover(
        in volumes: [URL],
        onWarning: (String) -> Void = { _ in }
    ) -> [BezelCandidate] {
        var candidates: [BezelCandidate] = []

        for volumeURL in volumes {
            let psdURLs = enumeratePSDs(under: volumeURL)
            for psdURL in psdURLs {
                do {
                    let candidate = try makeCandidate(from: psdURL)
                    candidates.append(candidate)
                } catch {
                    onWarning("skipped \(psdURL.path): \(error)")
                }
            }
        }

        return candidates
    }

    /// Groups candidates by canonicalKey and returns one winner per group,
    /// applying `preferences` (model_order then colorway_order, then
    /// alphabetical fallback on the original filename).
    package static func selectWinners(
        candidates: [BezelCandidate],
        preferences: BezelPreferences = .defaults
    ) -> [String: BezelCandidate] {
        let groups = Dictionary(grouping: candidates, by: \.canonicalKey)
        var winners: [String: BezelCandidate] = [:]
        for (key, group) in groups {
            winners[key] = pickBest(from: group, preferences: preferences)
        }
        return winners
    }

    // MARK: - Candidate construction

    static func makeCandidate(from psdURL: URL) throws -> BezelCandidate {
        let filename = psdURL.lastPathComponent
        let parsedName = try FilenameParser.parse(filename: filename)
        let psd = try PSDParser.parse(at: psdURL)

        guard let screen = findScreenLayer(in: psd.layers) else {
            throw ImportError.noScreenLayer(source: filename, availableLayers: psd.layers.map(\.name))
        }

        let canvasSize = CGSize(width: psd.canvasWidth, height: psd.canvasHeight)
        let orientation = resolveOrientation(parsed: parsedName, canvasSize: canvasSize)
        let canonicalKey = makeCanonicalKey(
            productFamily: parsedName.productFamily,
            screenBBox: screen.bbox,
            orientation: orientation
        )

        return BezelCandidate(
            sourceURL: psdURL,
            filename: filename,
            modelName: parsedName.model,
            colorway: parsedName.colorway,
            orientation: orientation,
            productFamily: parsedName.productFamily,
            canvasSize: canvasSize,
            screenBBox: screen.bbox,
            canonicalKey: canonicalKey
        )
    }

    /// Finds the layer that contains the display area. Apple names it
    /// "Screen" (iPhone/iPad) or "Screen: WxH" (MacBook).
    static func findScreenLayer(in layers: [PSDParser.Layer]) -> PSDParser.Layer? {
        for layer in layers {
            let name = layer.name
            if name == "Screen" { return layer }
            if name.hasPrefix("Screen:") || name.hasPrefix("Screen ") { return layer }
        }
        return nil
    }

    /// Determines orientation. Macs are always `.none`. Others use the
    /// filename's explicit orientation word when present; otherwise fall back
    /// to canvas aspect.
    static func resolveOrientation(parsed: FilenameParser.Parsed, canvasSize: CGSize) -> BezelOrientation {
        if parsed.productFamily == 6 { return .none }
        if let explicit = parsed.orientation { return explicit }
        return canvasSize.width > canvasSize.height ? .landscape : .portrait
    }

    /// Canonical filename key based on the Screen layer's actual pixel
    /// dimensions. Delegates to `BezelStore.canonicalKey` so the import and
    /// lookup paths share one source of truth.
    ///
    /// Examples:
    ///   iPhone_1320x2868_portrait
    ///   iPhone_2868x1320_landscape
    ///   iPad_2064x2752_portrait
    ///   MacBook_3456x2234
    static func makeCanonicalKey(
        productFamily: Int,
        screenBBox: CGRect,
        orientation: BezelOrientation
    ) -> String {
        BezelStore.canonicalKey(
            productFamily: productFamily,
            width: Int(screenBBox.width.rounded()),
            height: Int(screenBBox.height.rounded()),
            orientation: orientation
        )
    }

    // MARK: - Volume walk

    /// Recursive directory walk collecting `.psd` files. Skips dotfiles and
    /// the "PNG" folder (we prefer PSDs; see plan).
    static func enumeratePSDs(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "psd" {
                results.append(url)
            }
        }
        return results
    }

    // MARK: - Preference application

    static func pickBest(
        from group: [BezelCandidate],
        preferences: BezelPreferences
    ) -> BezelCandidate {
        // Stable sort: lower score wins. Score is (modelRank, colorwayRank, filename)
        let ranked = group.map { candidate -> (BezelCandidate, Int, Int, String) in
            let modelRank = rank(value: candidate.modelName, in: preferences.modelOrder)
            let colorwayRank = rank(value: candidate.colorway ?? "", in: preferences.colorwayOrder)
            return (candidate, modelRank, colorwayRank, candidate.filename)
        }
        let best = ranked.min { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            return a.3 < b.3
        }!
        return best.0
    }

    /// Returns the index of the first element in `order` that appears as a
    /// substring of `value`, or `order.count` (worst) if none match. Empty
    /// string "" in the preference list acts as a catchall.
    static func rank(value: String, in order: [String]) -> Int {
        for (idx, pref) in order.enumerated() {
            if pref.isEmpty { return idx }
            if value.contains(pref) { return idx }
        }
        return order.count
    }
}

// MARK: - Filename parsing

package enum FilenameParser {

    package struct Parsed {
        package let model: String
        package let colorway: String?
        package let orientation: BezelOrientation?
        package let productFamily: Int
    }

    package static func parse(filename: String) throws -> Parsed {
        let stem = (filename as NSString).deletingPathExtension

        let family = try inferProductFamily(from: stem)

        // Pattern A — space-dash-space separated (iPhone / iPad):
        //   "iPhone 17 Pro Max - Silver - Portrait"
        //   "iPad Pro (M5) 13\" - Silver - Landscape"
        if stem.contains(" - ") {
            let parts = stem.components(separatedBy: " - ")
            let model = parts[0]
            let colorway = parts.count >= 2 ? parts[1] : nil
            let orientation: BezelOrientation? = {
                guard parts.count >= 3 else { return nil }
                switch parts[2].lowercased() {
                case "portrait": return .portrait
                case "landscape": return .landscape
                default: return nil
                }
            }()
            return Parsed(model: model, colorway: colorway, orientation: orientation, productFamily: family)
        }

        // Pattern B — MacBook flat naming, no delimiters:
        //   "MacBook Pro M5 14-inch Silver"
        //   "MacBook Pro M5 16-inch Space Black"
        if family == 6 {
            if let sizeRange = stem.range(of: #"\d+-inch"#, options: .regularExpression) {
                let modelEnd = sizeRange.upperBound
                let model = String(stem[..<modelEnd])
                let colorwayRaw = stem[modelEnd...]
                    .trimmingCharacters(in: .whitespaces)
                return Parsed(
                    model: model,
                    colorway: colorwayRaw.isEmpty ? nil : colorwayRaw,
                    orientation: nil,
                    productFamily: family
                )
            }
        }

        // Fallback: whole stem = model, no colorway / orientation.
        return Parsed(model: stem, colorway: nil, orientation: nil, productFamily: family)
    }

    package static func inferProductFamily(from name: String) throws -> Int {
        if name.hasPrefix("iPhone") { return 1 }
        if name.hasPrefix("iPad")   { return 2 }
        if name.hasPrefix("Apple Watch") || name.hasPrefix("Watch") { return 4 }
        if name.hasPrefix("MacBook") || name.hasPrefix("iMac") || name.hasPrefix("Mac Studio") || name.hasPrefix("Mac Pro") {
            return 6
        }
        throw BezelImporter.ImportError.unknownProductFamily(filename: name)
    }
}
