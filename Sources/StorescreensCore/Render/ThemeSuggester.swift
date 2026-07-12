import Foundation
import CoreGraphics
import ImageIO

/// Derives render theme suggestions from the app's own screenshots, so the
/// first `render:` block starts from the app's actual colors instead of a
/// guess. Ported from the palette heuristics in appstore-mockup-mcp, adapted
/// to this pipeline's config shape (background color/gradient, caption text
/// color, drawn-frame colorway).
///
/// The analysis is deterministic: same screenshots, same suggestions.
package enum ThemeSuggester {

    package enum SuggestError: Error, CustomStringConvertible, LocalizedError {
        case unreadableImage(URL)
        case noPixels

        package var description: String {
            switch self {
            case .unreadableImage(let url): return "cannot read image: \(url.path)"
            case .noPixels: return "no opaque pixels in the provided screenshots"
            }
        }

        // LocalizedError, so callers formatting via `localizedDescription`
        // (e.g. the MCP dispatch catch-all) show the real message instead of
        // a generic NSError one.
        package var errorDescription: String? { description }
    }

    /// One suggested theme, ready to translate into a `render:` block.
    package struct ThemeSuggestion: Codable, Sendable, Equatable {
        package let name: String
        /// One hex for a solid background, two for a vertical top-to-bottom
        /// gradient - the same shape `background.color` accepts.
        package let background: [String]
        /// Caption text color with guaranteed contrast against `background`.
        package let textColor: String
        /// Drawn-frame body color for `chrome.device_colorway` (also a
        /// sensible hint for `colorway_preference` with real bezels).
        package let deviceColorway: DeviceColorway
        package let why: String

        package enum CodingKeys: String, CodingKey {
            case name, background, why
            case textColor = "text_color"
            case deviceColorway = "device_colorway"
        }
    }

    // MARK: - Palette extraction

    struct PaletteEntry {
        let red: Int      // 0-255, averaged over the bucket
        let green: Int
        let blue: Int
        let count: Int    // pixels in the bucket across all screenshots
    }

    /// Dominant colors across one or more screenshots. Each image is
    /// thumbnailed to <=96px and histogrammed into 16-levels-per-channel
    /// buckets; bucket colors are the average of their member pixels, so a
    /// solid app background comes back as its exact color.
    static func extractPalette(from urls: [URL]) throws -> [PaletteEntry] {
        var sumR = [Int](repeating: 0, count: 4096)
        var sumG = [Int](repeating: 0, count: 4096)
        var sumB = [Int](repeating: 0, count: 4096)
        var counts = [Int](repeating: 0, count: 4096)

        for url in urls {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                throw SuggestError.unreadableImage(url)
            }

            let w = thumb.width
            let h = thumb.height
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw SuggestError.unreadableImage(url)
            }
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { throw SuggestError.unreadableImage(url) }

            let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            for i in 0..<(w * h) {
                // Skip mostly-transparent pixels (transparent padding in
                // user-supplied PNGs would otherwise vote as opaque black)
                // and un-premultiply the survivors so partial alpha doesn't
                // darken their color.
                let a = Int(pixels[i * 4 + 3])
                guard a >= 128 else { continue }
                let r = min(255, Int(pixels[i * 4]) * 255 / a)
                let g = min(255, Int(pixels[i * 4 + 1]) * 255 / a)
                let b = min(255, Int(pixels[i * 4 + 2]) * 255 / a)
                let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
                sumR[key] += r
                sumG[key] += g
                sumB[key] += b
                counts[key] += 1
            }
        }

        var entries: [PaletteEntry] = []
        for key in 0..<4096 where counts[key] > 0 {
            let n = counts[key]
            entries.append(PaletteEntry(red: sumR[key] / n, green: sumG[key] / n, blue: sumB[key] / n, count: n))
        }
        return entries
    }

    // MARK: - Suggestion

    /// Suggests up to three themes ordered by recommendation strength:
    /// App Match (canvas nudged off the app's dominant background), then,
    /// when the app has a vivid accent color, Brand Gradient and Soft Tint
    /// built from it. Apps with no saturated accent (grayscale UIs) get only
    /// App Match.
    package static func suggest(from urls: [URL]) throws -> [ThemeSuggestion] {
        let palette = try extractPalette(from: urls)
        guard let bg = palette.max(by: { $0.count < $1.count }) else {
            throw SuggestError.noPixels
        }

        // Accent: frequent AND vivid, not just frequent, and visibly
        // different from the background. Two extra guards keep it honest:
        // a coverage floor (0.5% of pixels) so a sub-pixel tinted glyph in
        // an otherwise grayscale UI can't become a phantom brand color, and
        // a hue guard so antialiased blends of a vivid background (bg mixed
        // with white text) don't count as a second brand color.
        let totalPixels = palette.reduce(0) { $0 + $1.count }
        let bgSaturated = saturation(bg) >= 0.25
        var accent: PaletteEntry?
        var bestScore = 0.0
        for entry in palette {
            let sat = saturation(entry)
            guard sat >= 0.25,
                  distance(entry, bg) >= 0.10,
                  Double(entry.count) >= 0.005 * Double(totalPixels) else { continue }
            if bgSaturated, hueDistance(entry, bg) < 20 { continue }
            let score = Double(entry.count) * sat * sat
            if score > bestScore {
                bestScore = score
                accent = entry
            }
        }

        // Nudge the canvas away from the app background so the device
        // doesn't melt into it.
        let darkBG = luminance(bg) < 0.35
        let canvas = mix(bg, toward: darkBG ? (0, 0, 0) : (255, 255, 255), 0.25)
        let canvasDark = luminance(canvas) < 0.35
        var themes = [ThemeSuggestion(
            name: "App Match",
            background: [hex(canvas)],
            textColor: textColor(over: canvas),
            deviceColorway: canvasDark ? .dark : .silver,
            why: "matches the app's own background"
        )]

        if let accent {
            // Captions render at the top of the canvas, so text contrast is
            // computed against the TOP gradient stop.
            let top = mix(accent, toward: (255, 255, 255), 0.10)
            themes.append(ThemeSuggestion(
                name: "Brand Gradient",
                background: [hex(top), hex(mix(accent, toward: (0, 0, 0), 0.75))],
                textColor: textColor(over: top),
                deviceColorway: .dark,
                why: "bold light-to-dark gradient built from the app's accent color"
            ))
            let tint = mix(accent, toward: (255, 255, 255), 0.88)
            themes.append(ThemeSuggestion(
                name: "Soft Tint",
                background: [hex(tint)],
                textColor: textColor(over: tint),
                deviceColorway: .silver,
                why: "clean, minimal wash of the app's accent color"
            ))
        }
        return themes
    }

    /// White or near-black, whichever has the higher WCAG contrast ratio
    /// against `background`. A plain luminance threshold picks white too
    /// eagerly on bright accents (white on orange at nearly 2:1); comparing
    /// actual ratios keeps every suggestion legible.
    private static func textColor(over background: PaletteEntry) -> String {
        let bgL = luminance(background)
        let white = 1.05 / (bgL + 0.05)
        let darkL = 0.0056  // #111111
        let dark = (bgL + 0.05) / (darkL + 0.05)
        return white >= dark ? "#ffffff" : "#111111"
    }

    /// Screenshot URLs for the default (no explicit paths) flow: the device
    /// with the most screenshots in the capture manifest. Palette barely
    /// varies across device sizes, so one device is enough.
    package static func capturedScreenshotURLs(capturedRoot: URL) throws -> [URL] {
        let manifestURL = capturedRoot.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureManifest.self, from: data)
        guard let device = manifest.devices.max(by: { $0.screenshots.count < $1.screenshots.count }) else {
            return []
        }
        return device.screenshots
            .map { capturedRoot.appendingPathComponent($0.filename) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Color math

    private static func saturation(_ e: PaletteEntry) -> Double {
        let mx = Double(max(e.red, e.green, e.blue))
        let mn = Double(min(e.red, e.green, e.blue))
        return mx == 0 ? 0 : (mx - mn) / mx
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    private static func luminance(_ e: PaletteEntry) -> Double {
        func lin(_ c: Int) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(e.red) + 0.7152 * lin(e.green) + 0.0722 * lin(e.blue)
    }

    /// Hue angle difference in degrees, 0 to 180. Only meaningful when both
    /// colors carry some saturation; callers gate on that.
    private static func hueDistance(_ a: PaletteEntry, _ b: PaletteEntry) -> Double {
        let d = abs(hue(a) - hue(b))
        return min(d, 360 - d)
    }

    private static func hue(_ e: PaletteEntry) -> Double {
        let r = Double(e.red) / 255
        let g = Double(e.green) / 255
        let b = Double(e.blue) / 255
        let mx = max(r, g, b)
        let mn = min(r, g, b)
        let delta = mx - mn
        guard delta > 0 else { return 0 }
        let h: Double
        if mx == r {
            h = (g - b) / delta
        } else if mx == g {
            h = 2 + (b - r) / delta
        } else {
            h = 4 + (r - g) / delta
        }
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Euclidean distance in unit RGB space, 0 to sqrt(3).
    private static func distance(_ a: PaletteEntry, _ b: PaletteEntry) -> Double {
        let dr = Double(a.red - b.red) / 255
        let dg = Double(a.green - b.green) / 255
        let db = Double(a.blue - b.blue) / 255
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private static func mix(_ e: PaletteEntry, toward target: (Int, Int, Int), _ t: Double) -> PaletteEntry {
        func m(_ a: Int, _ b: Int) -> Int { Int((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return PaletteEntry(
            red: m(e.red, target.0),
            green: m(e.green, target.1),
            blue: m(e.blue, target.2),
            count: e.count
        )
    }

    private static func hex(_ e: PaletteEntry) -> String {
        String(format: "#%02x%02x%02x", e.red, e.green, e.blue)
    }
}
