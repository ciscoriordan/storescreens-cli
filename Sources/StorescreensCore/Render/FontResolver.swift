import Foundation
import AppKit
import CoreText
import CoreGraphics

/// Resolves `FontSpec` values to a concrete `CTFont`. Tiered strategy:
///
///   .system                 → NSFont.systemFont + weight/italic traits
///   .installed(family)      → NSFontManager family lookup with traits
///   .path(p)                → CGFont(CGDataProvider(url:))
///   .bundle(r, b, i, bi)    → picks appropriate file based on weight+italic
///   .google(family, version) → downloads from Google Fonts CSS API, caches
///
/// Relative paths in `.path` and `.bundle` resolve against `baseDirectory`.
/// Google Fonts caches to `~/Library/Caches/storescreens/fonts/`.
package final class FontResolver: @unchecked Sendable {

    package let baseDirectory: URL
    private let cacheDirectory: URL
    private let downloader: FontDownloading

    package init(
        baseDirectory: URL,
        cacheDirectory: URL? = nil,
        downloader: FontDownloading = GoogleFontsDownloader()
    ) {
        self.baseDirectory = baseDirectory
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDir()
        self.downloader = downloader
    }

    package static func defaultCacheDir() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("storescreens/fonts", isDirectory: true)
    }

    package enum ResolveError: Error, CustomStringConvertible {
        case familyNotInstalled(String)
        case cannotLoadFontFile(URL)
        case googleFontDownloadFailed(String, underlying: Error?)
        case bundleMissingVariant(weight: FontWeight, italic: Bool)

        package var description: String {
            switch self {
            case .familyNotInstalled(let f): return "installed font family not found: \(f)"
            case .cannotLoadFontFile(let u): return "cannot load font file: \(u.path)"
            case .googleFontDownloadFailed(let f, let e):
                return "Google Fonts download failed for '\(f)': \(e?.localizedDescription ?? "unknown")"
            case .bundleMissingVariant(let w, let i):
                return "font bundle has no variant for weight=\(w.rawValue) italic=\(i)"
            }
        }
    }

    /// Resolve a `FontSpec` to a `CTFont` at a given point size, weight, and italic.
    /// Weight/italic attributes from the config are passed in — markdown-derived
    /// bold/italic overrides the config's weight/italic for that run of text.
    package func resolve(
        _ spec: FontSpec,
        size: CGFloat,
        weight: FontWeight,
        italic: Bool
    ) throws -> CTFont {
        switch spec {
        case .system:
            return systemFont(size: size, weight: weight, italic: italic)

        case .installed(let family):
            return try installedFont(family: family, size: size, weight: weight, italic: italic)

        case .path(let rawPath):
            let url = resolveRelative(rawPath)
            return try loadFont(at: url, size: size)

        case .bundle(let regular, let bold, let italicPath, let boldItalic):
            let picked = pickBundleVariant(
                weight: weight, italic: italic,
                regular: regular, bold: bold, italic: italicPath, boldItalic: boldItalic
            )
            guard let p = picked else {
                throw ResolveError.bundleMissingVariant(weight: weight, italic: italic)
            }
            return try loadFont(at: resolveRelative(p), size: size)

        case .google(let family, let version):
            let url = try cachedOrDownloadGoogle(family: family, version: version, weight: weight, italic: italic)
            return try loadFont(at: url, size: size)
        }
    }

    // MARK: - Tier 1: System

    private func systemFont(size: CGFloat, weight: FontWeight, italic: Bool) -> CTFont {
        let nsWeight = Self.nsWeight(from: weight)
        let base = NSFont.systemFont(ofSize: size, weight: nsWeight)
        if italic {
            if let descriptor = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) {
                return descriptor as CTFont
            }
        }
        return base as CTFont
    }

    // MARK: - Tier 2: Installed

    private func installedFont(family: String, size: CGFloat, weight: FontWeight, italic: Bool) throws -> CTFont {
        let mgr = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if italic { traits.insert(.italicFontMask) }
        let intWeight = Self.nsFontManagerWeight(from: weight)
        if let font = mgr.font(withFamily: family, traits: traits, weight: intWeight, size: size) {
            return font as CTFont
        }
        // Fallback: try without italic if we asked for italic, with warning path
        if italic, let font = mgr.font(withFamily: family, traits: [], weight: intWeight, size: size) {
            return font as CTFont
        }
        throw ResolveError.familyNotInstalled(family)
    }

    // MARK: - Tier 3: Path

    private func loadFont(at url: URL, size: CGFloat) throws -> CTFont {
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else {
            throw ResolveError.cannotLoadFontFile(url)
        }
        return CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
    }

    private func resolveRelative(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") {
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: path, relativeTo: baseDirectory).standardized
    }

    // MARK: - Tier 4 (bundle): pick variant

    private func pickBundleVariant(
        weight: FontWeight,
        italic: Bool,
        regular: String,
        bold: String?,
        italic italicPath: String?,
        boldItalic: String?
    ) -> String? {
        let wantBold = Self.isBoldWeight(weight)
        switch (wantBold, italic) {
        case (true, true):   return boldItalic ?? bold ?? italicPath ?? regular
        case (true, false):  return bold ?? regular
        case (false, true):  return italicPath ?? regular
        case (false, false): return regular
        }
    }

    // MARK: - Tier 4 (google): cache + download

    private func cachedOrDownloadGoogle(
        family: String,
        version: String?,
        weight: FontWeight,
        italic: Bool
    ) throws -> URL {
        let versionKey = version ?? "latest"
        let familyDir = cacheDirectory.appendingPathComponent("\(family.replacingOccurrences(of: " ", with: "_"))__\(versionKey)", isDirectory: true)
        let variantFile = "\(Self.nsFontManagerWeight(from: weight))-\(italic ? "italic" : "regular").ttf"
        let cached = familyDir.appendingPathComponent(variantFile)

        if FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        do {
            try FileManager.default.createDirectory(at: familyDir, withIntermediateDirectories: true)
            try downloader.download(
                family: family,
                weight: Self.nsFontManagerWeight(from: weight),
                italic: italic,
                to: cached
            )
            return cached
        } catch {
            throw ResolveError.googleFontDownloadFailed(family, underlying: error)
        }
    }

    // MARK: - Weight mapping

    package static func nsWeight(from weight: FontWeight) -> NSFont.Weight {
        switch weight {
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    /// NSFontManager weight (1-14, where 5 ≈ regular and 9 ≈ bold).
    package static func nsFontManagerWeight(from weight: FontWeight) -> Int {
        switch weight {
        case .thin:     return 2
        case .light:    return 3
        case .regular:  return 5
        case .medium:   return 6
        case .semibold: return 8
        case .bold:     return 9
        case .heavy:    return 12
        }
    }

    package static func isBoldWeight(_ weight: FontWeight) -> Bool {
        switch weight {
        case .thin, .light, .regular, .medium: return false
        case .semibold, .bold, .heavy: return true
        }
    }
}

// MARK: - Google Fonts downloading

/// Abstracted so tests can inject a mock without hitting the network.
package protocol FontDownloading: Sendable {
    func download(family: String, weight: Int, italic: Bool, to destination: URL) throws
}

/// Downloads a single weight+italic variant from the Google Fonts CSS2 API.
/// Uses an older-browser User-Agent to request TTF instead of woff2, since
/// CoreText can load TTF directly.
package struct GoogleFontsDownloader: FontDownloading {
    package init() {}

    package func download(family: String, weight: Int, italic: Bool, to destination: URL) throws {
        // Map NSFontManager weight (2-12) to Google's 100-900 scale
        let googleWeight = Self.googleWeight(from: weight)
        let ital = italic ? "1" : "0"
        let familyQuery = family.replacingOccurrences(of: " ", with: "+")
        let cssURL = URL(string: "https://fonts.googleapis.com/css2?family=\(familyQuery):ital,wght@\(ital),\(googleWeight)&display=swap")!

        var request = URLRequest(url: cssURL)
        // Old Android UA triggers the TTF codepath (Google serves woff2 to modern browsers)
        request.setValue(
            "Mozilla/5.0 (Linux; Android 5.0; SM-G900P Build/LRX21T) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.113 Mobile Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let css = try sync(request: request)
        guard let cssString = String(data: css, encoding: .utf8) else {
            throw NSError(domain: "GoogleFonts", code: 1, userInfo: [NSLocalizedDescriptionKey: "non-UTF8 CSS response"])
        }

        // Find all `src: url(...)` patterns that end in .ttf
        let ttfURL = Self.extractFirstTTFURL(from: cssString)
        guard let ttfURL else {
            throw NSError(
                domain: "GoogleFonts", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no TTF URL found in CSS response for \(family)"]
            )
        }

        let ttfData = try sync(request: URLRequest(url: ttfURL))
        try ttfData.write(to: destination, options: .atomic)
    }

    static func extractFirstTTFURL(from css: String) -> URL? {
        // Match `url(https://...ttf)` patterns (src property may have multiple).
        guard let regex = try? NSRegularExpression(pattern: #"url\((https://[^)]+?\.ttf)\)"#) else {
            return nil
        }
        let ns = css as NSString
        let match = regex.firstMatch(in: css, range: NSRange(location: 0, length: ns.length))
        guard let m = match, m.numberOfRanges >= 2 else { return nil }
        let urlStr = ns.substring(with: m.range(at: 1))
        return URL(string: urlStr)
    }

    /// NSFontManager weight (2-14) → Google CSS weight (100-900).
    static func googleWeight(from mgrWeight: Int) -> Int {
        // mgrWeight 5 ≈ regular (400), 9 ≈ bold (700)
        switch mgrWeight {
        case ...2:  return 100  // thin
        case 3:     return 300  // light
        case 4...5: return 400  // regular
        case 6:     return 500  // medium
        case 7...8: return 600  // semibold
        case 9:     return 700  // bold
        case 10...11: return 800 // extra bold
        default:    return 900  // heavy
        }
    }

    /// Synchronous URLSession fetch — used in the resolver's sync API.
    /// Acceptable here because font downloads happen once per cache miss and
    /// the CLI is already blocking on render.
    private func sync(request: URLRequest) throws -> Data {
        let sema = DispatchSemaphore(value: 0)
        var outData: Data?
        var outError: Error?
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            outData = data
            outError = error
            sema.signal()
        }
        task.resume()
        sema.wait()
        if let e = outError { throw e }
        guard let d = outData else {
            throw NSError(domain: "GoogleFonts", code: 3, userInfo: [NSLocalizedDescriptionKey: "empty response"])
        }
        return d
    }
}
