import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Rasterizes a source PSD (flattened by AppKit's PSD codec), punches a
/// transparent rect where the Screen layer sits, and writes the result to the
/// user-global bezels directory as a PNG plus a `.json` sidecar.
///
/// Called once per winner selected by `BezelImporter.selectWinners`.
package enum BezelExporter {

    package enum ExportError: Error, CustomStringConvertible {
        case cannotLoadPSD(URL)
        case cannotExtractCGImage(URL)
        case cannotCreateBitmapContext
        case cannotWritePNG(URL)
        case cannotCreateInstallDir(URL, Error)

        package var description: String {
            switch self {
            case .cannotLoadPSD(let u): return "NSImage failed to load PSD: \(u.path)"
            case .cannotExtractCGImage(let u): return "failed to extract CGImage from: \(u.path)"
            case .cannotCreateBitmapContext: return "failed to create bitmap CGContext"
            case .cannotWritePNG(let u): return "failed to write PNG to: \(u.path)"
            case .cannotCreateInstallDir(let u, let e): return "failed to create directory \(u.path): \(e)"
            }
        }
    }

    /// Default user-global bezels directory: `~/Library/Application Support/storescreens/bezels/`
    package static func defaultInstallDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("storescreens/bezels", isDirectory: true)
    }

    /// Exports a winner candidate to PNG + JSON. Returns the URLs written.
    @discardableResult
    package static func export(
        candidate: BezelCandidate,
        to installDir: URL
    ) throws -> (pngURL: URL, jsonURL: URL) {
        try ensureDirectoryExists(installDir)

        let pngURL = installDir.appendingPathComponent("\(candidate.canonicalKey).png")
        let jsonURL = installDir.appendingPathComponent("\(candidate.canonicalKey).json")

        let canvasW = Int(candidate.canvasSize.width.rounded())
        let canvasH = Int(candidate.canvasSize.height.rounded())

        // 1. Load PSD via AppKit (the PSD codec is built into Image I/O on macOS).
        guard let nsImage = NSImage(contentsOf: candidate.sourceURL) else {
            throw ExportError.cannotLoadPSD(candidate.sourceURL)
        }
        var proposedRect = NSRect(x: 0, y: 0, width: canvasW, height: canvasH)
        guard let cgImage = nsImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw ExportError.cannotExtractCGImage(candidate.sourceURL)
        }

        // 2. Redraw into a transparent pixel-dimension bitmap, then clear the
        //    Screen rect to punch a hole. CGContext uses bottom-left origin;
        //    the PSD bbox is top-left - flip Y on the clear rect only.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ExportError.cannotCreateBitmapContext
        }

        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        let screen = candidate.screenBBox
        let flippedY = CGFloat(canvasH) - (screen.minY + screen.height)
        let clearRect = CGRect(x: screen.minX, y: flippedY, width: screen.width, height: screen.height)

        // Punch a rounded hole rather than a rectangular one so the Screen
        // opening matches the real device's display corners. Radius is
        // proportional to the screen's short side, per product family.
        let cornerRadius = Self.deviceScreenCornerRadius(
            productFamily: candidate.productFamily,
            screenSize: screen.size
        )
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        let holePath = CGPath(
            roundedRect: clearRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        ctx.addPath(holePath)
        ctx.fillPath()
        ctx.restoreGState()

        guard let outImage = ctx.makeImage() else {
            throw ExportError.cannotCreateBitmapContext
        }

        // 3. Write PNG via Image I/O.
        try writePNG(outImage, to: pngURL)

        // 4. Write JSON sidecar.
        let metadata = BezelMetadata(from: candidate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(metadata)
        try jsonData.write(to: jsonURL, options: .atomic)

        return (pngURL, jsonURL)
    }

    /// Proportional display corner radius (in screen-pixel units) per
    /// product family. Shared with ChromeRenderer so the hole punched at
    /// export time lines up exactly with the rounded clip applied to the
    /// screenshot at render time.
    ///
    /// Values tuned against Apple's shipped bezels - larger than a pure
    /// "display corner radius" reading because the bezel PSDs stylize the
    /// display opening with a slightly rounder arc than the hardware spec.
    package static func deviceScreenCornerRadius(productFamily: Int, screenSize: CGSize) -> CGFloat {
        let shortSide = min(screenSize.width, screenSize.height)
        switch productFamily {
        case 1: return shortSide * 0.145   // iPhone
        case 2: return shortSide * 0.022   // iPad
        case 6: return shortSide * 0.015   // MacBook
        default: return shortSide * 0.05
        }
    }

    // MARK: - Helpers

    private static func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw ExportError.cannotCreateInstallDir(url, error)
            }
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let pngType = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, pngType, 1, nil) else {
            throw ExportError.cannotWritePNG(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.cannotWritePNG(url)
        }
    }
}
