import Foundation
import CoreGraphics

/// Screen orientation of a bezel. Laptops (`.none`) have no rotated variant.
package enum BezelOrientation: String, Codable, Sendable {
    case portrait
    case landscape
    case none
}

/// A candidate bezel file discovered while scanning mounted DMGs.
/// Produced by `BezelImporter.discover`; consumed by `BezelImporter.selectWinners`
/// and the transparent-screen export step.
package struct BezelCandidate: Sendable {
    package let sourceURL: URL
    package let filename: String          // "iPhone 17 Pro Max - Silver - Portrait.psd"
    package let modelName: String         // "iPhone 17 Pro Max"
    package let colorway: String?         // "Silver" - nil for MacBook (no separator)
    package let orientation: BezelOrientation
    /// True when the filename names the orientation; false when it was
    /// derived from the Screen layer's box. A stated orientation wins over
    /// a derived one inside a key group.
    package let orientationIsExplicit: Bool
    package let productFamily: Int        // 1=iPhone, 2=iPad, 6=Mac
    package let canvasSize: CGSize        // PSD canvas in pixels
    package let screenBBox: CGRect        // pixel coords inside canvas
    package let canonicalKey: String      // "iPhone_1320x2868_portrait" (no extension)
}

/// User-overridable preference for which model + colorway wins inside a group
/// of candidates that share the same `canonicalKey`.
package struct BezelPreferences: Sendable {
    package let modelOrder: [String]
    package let colorwayOrder: [String]

    package init(modelOrder: [String], colorwayOrder: [String]) {
        self.modelOrder = modelOrder
        self.colorwayOrder = colorwayOrder
    }

    /// Default preferences. Higher-priority entries appear earlier.
    /// Empty-string "" in modelOrder acts as a catchall (matches any model).
    ///
    /// Colorways favor the dark finish of each line, then the neutral ones.
    /// Entries match as substrings, so "Black" covers the iPhone 18 Pro's
    /// "Black" (over its "Silver", "Glacier" and "Burgundy"). "Night Sky" is
    /// the iPhone Duo's dark finish, listed so it wins over "Star White" by
    /// preference rather than by the alphabetical fallback.
    package static let defaults = BezelPreferences(
        modelOrder: ["Pro Max", "Pro", "Air", "mini", ""],
        colorwayOrder: [
            "Space Black", "Black",
            "Night Sky",
            "Natural Titanium",
            "Silver",
            "Space Gray",
            "Deep Blue",
        ]
    )
}
