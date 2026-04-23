import Foundation

/// How a font is specified in the render config. Four tiers, tagged by shape:
///
///   font: system                       → .system
///   font: "Helvetica Neue"             → .installed("Helvetica Neue")
///   font: "./assets/Inter-Bold.otf"    → .path(URL)
///   font:
///     regular: "./Inter-Regular.otf"
///     bold:    "./Inter-Bold.otf"
///     italic:  "./Inter-Italic.otf"
///     bold_italic: "./Inter-BoldItalic.otf"   → .bundle(...)
///   font: { google: "Inter", version: "3.19" }  → .google(...)
///
/// Disambiguation rule for bare strings:
///   1. "system"                               → .system
///   2. starts with ./ ../ / or ~             → .path
///   3. ends with .otf / .ttf / .otc / .ttc   → .path
///   4. anything else                          → .installed
package enum FontSpec: Codable, Sendable, Equatable {
    case system
    case installed(String)
    case path(String)
    case bundle(regular: String, bold: String?, italic: String?, boldItalic: String?)
    case google(family: String, version: String?)

    package init(from decoder: Decoder) throws {
        // Try string form first
        if let single = try? decoder.singleValueContainer(),
           let s = try? single.decode(String.self) {
            self = FontSpec.fromString(s)
            return
        }

        // Object form — inspect keys
        let c = try decoder.container(keyedBy: ObjectKey.self)

        if let family = try c.decodeIfPresent(String.self, forKey: .google) {
            let v = try c.decodeIfPresent(String.self, forKey: .version)
            self = .google(family: family, version: v)
            return
        }

        if let regular = try c.decodeIfPresent(String.self, forKey: .regular) {
            let bold = try c.decodeIfPresent(String.self, forKey: .bold)
            let italic = try c.decodeIfPresent(String.self, forKey: .italic)
            let boldItalic = try c.decodeIfPresent(String.self, forKey: .boldItalic)
            self = .bundle(regular: regular, bold: bold, italic: italic, boldItalic: boldItalic)
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: ObjectKey.google,
            in: c,
            debugDescription: "font must be a string, {regular, bold, italic, bold_italic}, or {google, version}"
        )
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .system:
            var c = encoder.singleValueContainer()
            try c.encode("system")
        case .installed(let name):
            var c = encoder.singleValueContainer()
            try c.encode(name)
        case .path(let p):
            var c = encoder.singleValueContainer()
            try c.encode(p)
        case .bundle(let r, let b, let i, let bi):
            var c = encoder.container(keyedBy: ObjectKey.self)
            try c.encode(r, forKey: .regular)
            try c.encodeIfPresent(b, forKey: .bold)
            try c.encodeIfPresent(i, forKey: .italic)
            try c.encodeIfPresent(bi, forKey: .boldItalic)
        case .google(let fam, let v):
            var c = encoder.container(keyedBy: ObjectKey.self)
            try c.encode(fam, forKey: .google)
            try c.encodeIfPresent(v, forKey: .version)
        }
    }

    static func fromString(_ s: String) -> FontSpec {
        if s == "system" { return .system }
        if s.hasPrefix("./") || s.hasPrefix("../") || s.hasPrefix("/") || s.hasPrefix("~") {
            return .path(s)
        }
        let lower = s.lowercased()
        if lower.hasSuffix(".otf") || lower.hasSuffix(".ttf") ||
           lower.hasSuffix(".otc") || lower.hasSuffix(".ttc") {
            return .path(s)
        }
        return .installed(s)
    }

    private enum ObjectKey: String, CodingKey {
        case google, version
        case regular, bold, italic
        case boldItalic = "bold_italic"
    }
}
