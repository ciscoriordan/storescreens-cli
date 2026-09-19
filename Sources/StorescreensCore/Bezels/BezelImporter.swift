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
                return "no Apple Design Resource DMGs mounted under /Volumes - mount a DMG first"
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

    /// Groups candidates by canonicalKey and returns one winner per group.
    /// See `pickBest` for the ranking.
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
        let orientation = resolveOrientation(parsed: parsedName, screenBBox: screen.bbox)
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
            orientationIsExplicit: parsedName.orientation != nil,
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
    /// filename's orientation word when present; otherwise the Screen
    /// layer's box. The canvas is no guide: Apple's "iPhone Duo - Night Sky -
    /// Outer Open" artwork is the open phone seen from the back, a landscape
    /// canvas around a portrait outer display.
    static func resolveOrientation(parsed: FilenameParser.Parsed, screenBBox: CGRect) -> BezelOrientation {
        if parsed.productFamily == 6 { return .none }
        if let explicit = parsed.orientation { return explicit }
        return screenBBox.width > screenBBox.height ? .landscape : .portrait
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

    /// Picks one candidate from a group sharing a canonical key. In order:
    ///   1. A filename that states the orientation beats one that does not:
    ///      the Duo's "Outer Closed Portrait" is the intended portrait
    ///      artwork, "Outer Open" only lands in the same group because its
    ///      outer display has the same size.
    ///   2. `preferences.modelOrder`.
    ///   3. The newer generation of the model line, so the iPhone 18 Pro
    ///      Max artwork wins over the iPhone 17 Pro Max one when both DMGs
    ///      are mounted. Ahead of colorway because each generation ships
    ///      its own set of finishes.
    ///   4. `preferences.colorwayOrder`.
    ///   5. Filename, alphabetically, so the result never depends on the
    ///      order the volume walk returned files in.
    static func pickBest(
        from group: [BezelCandidate],
        preferences: BezelPreferences
    ) -> BezelCandidate {
        struct Score: Comparable {
            let orientationRank: Int
            let modelRank: Int
            let generationRank: Int
            let colorwayRank: Int
            let filename: String

            static func < (a: Score, b: Score) -> Bool {
                (a.orientationRank, a.modelRank, a.generationRank, a.colorwayRank, a.filename)
                    < (b.orientationRank, b.modelRank, b.generationRank, b.colorwayRank, b.filename)
            }
        }
        let scored = group.map { candidate in
            (candidate, Score(
                orientationRank: candidate.orientationIsExplicit ? 0 : 1,
                modelRank: rank(value: candidate.modelName, in: preferences.modelOrder),
                generationRank: -(generation(of: candidate.modelName) ?? 0),
                colorwayRank: rank(value: candidate.colorway ?? "", in: preferences.colorwayOrder),
                filename: candidate.filename
            ))
        }
        return scored.min { $0.1 < $1.1 }!.0
    }

    /// Generation number in an iPhone model name: "iPhone 18 Pro Max" is
    /// 18, "iPhone 16e" is 16. Nil for names without one ("iPhone Air",
    /// "iPhone Duo") and for other families, whose names carry screen
    /// sizes and chip names rather than generations ("iPad Pro (M5) 13\"").
    static func generation(of modelName: String) -> Int? {
        guard let range = modelName.range(of: #"^iPhone\s+\d+"#, options: .regularExpression) else { return nil }
        return Int(modelName[range].drop(while: { !$0.isNumber }))
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

        // Pattern A - space-dash-space separated (iPhone / iPad):
        //   "iPhone 17 Pro Max - Silver - Portrait"
        //   "iPad Pro (M5) 13\" - Silver - Landscape"
        //   "iPhone Duo - Night Sky - Outer Closed Portrait"
        if stem.contains(" - ") {
            let parts = stem.components(separatedBy: " - ")
            let model = parts[0]
            let colorway = parts.count >= 2 ? parts[1] : nil
            let orientation = parts.count >= 3 ? orientation(inPose: parts[2]) : nil
            return Parsed(model: model, colorway: colorway, orientation: orientation, productFamily: family)
        }

        // Pattern B - MacBook flat naming, no delimiters:
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

    /// Orientation named in the third filename field. Foldables describe a
    /// pose there ("Inner Open Landscape", "Outer Closed Portrait"), so the
    /// word is looked for anywhere in the field, case-insensitively. Nil
    /// when the field names neither orientation ("Outer Open") or both.
    static func orientation(inPose field: String) -> BezelOrientation? {
        let words = Set(field.lowercased().split(whereSeparator: { !$0.isLetter }))
        switch (words.contains("portrait"), words.contains("landscape")) {
        case (true, false): return .portrait
        case (false, true): return .landscape
        default: return nil
        }
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
