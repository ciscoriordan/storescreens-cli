import Foundation
import CoreGraphics

/// Sidecar metadata for an exported bezel PNG. Written to a `.json` file with
/// the same basename as the PNG, so the render pipeline can look up the
/// screen rect without re-parsing the source PSD.
package struct BezelMetadata: Codable, Sendable {
    package let canvasWidth: Int
    package let canvasHeight: Int
    /// Screen rect in top-left pixel coordinates inside the canvas.
    /// Stored as four ints to avoid CGFloat precision drift across Codable.
    package let screenX: Int
    package let screenY: Int
    package let screenWidth: Int
    package let screenHeight: Int
    package let canonicalKey: String
    package let orientation: BezelOrientation
    package let productFamily: Int
    package let sourceFilename: String

    package var screenRect: CGRect {
        CGRect(x: screenX, y: screenY, width: screenWidth, height: screenHeight)
    }

    package init(
        canvasWidth: Int,
        canvasHeight: Int,
        screenX: Int,
        screenY: Int,
        screenWidth: Int,
        screenHeight: Int,
        canonicalKey: String,
        orientation: BezelOrientation,
        productFamily: Int,
        sourceFilename: String
    ) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.screenX = screenX
        self.screenY = screenY
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.canonicalKey = canonicalKey
        self.orientation = orientation
        self.productFamily = productFamily
        self.sourceFilename = sourceFilename
    }

    package init(from candidate: BezelCandidate) {
        self.canvasWidth = Int(candidate.canvasSize.width.rounded())
        self.canvasHeight = Int(candidate.canvasSize.height.rounded())
        self.screenX = Int(candidate.screenBBox.minX.rounded())
        self.screenY = Int(candidate.screenBBox.minY.rounded())
        self.screenWidth = Int(candidate.screenBBox.width.rounded())
        self.screenHeight = Int(candidate.screenBBox.height.rounded())
        self.canonicalKey = candidate.canonicalKey
        self.orientation = candidate.orientation
        self.productFamily = candidate.productFamily
        self.sourceFilename = candidate.filename
    }
}
