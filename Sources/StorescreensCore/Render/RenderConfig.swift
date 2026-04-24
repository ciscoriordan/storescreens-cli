import Foundation

/// Root Codable shape for the `render:` block in `storescreens.yml`. Every
/// field is optional so the same type serves as both the top-level defaults
/// and a per-slide override — resolution walks from slide-level → top-level
/// at render time.
package struct RenderConfig: Codable, Sendable {
    package var enabled: Bool?
    package var outputDir: String?
    package var background: BackgroundConfig?
    package var scrim: ScrimConfig?
    package var logo: LogoConfig?
    package var caption: CaptionConfig?
    package var chrome: ChromeConfig?
    /// Per-slide overrides keyed by screenshot name (exact match, not substring).
    package var slides: [String: SlideOverride]?

    package init(
        enabled: Bool? = nil,
        outputDir: String? = nil,
        background: BackgroundConfig? = nil,
        scrim: ScrimConfig? = nil,
        logo: LogoConfig? = nil,
        caption: CaptionConfig? = nil,
        chrome: ChromeConfig? = nil,
        slides: [String: SlideOverride]? = nil
    ) {
        self.enabled = enabled
        self.outputDir = outputDir
        self.background = background
        self.scrim = scrim
        self.logo = logo
        self.caption = caption
        self.chrome = chrome
        self.slides = slides
    }

    package enum CodingKeys: String, CodingKey {
        case enabled
        case outputDir = "output_dir"
        case background, scrim, logo, caption, chrome, slides
    }
}

/// Per-slide overrides. Any field left nil inherits from `RenderConfig`.
/// Caption supports shorthand forms (string = title only, array = title lines).
package struct SlideOverride: Codable, Sendable {
    package var background: BackgroundConfig?
    package var scrim: ScrimConfig?
    package var logo: LogoConfig?
    package var caption: SlideCaption?
    package var chrome: ChromeConfig?

    /// Per-locale title overrides. Keyed by Xcode locale code
    /// (`en-US`, `el`, `ja`, `zh-Hans`, …). When the current render's
    /// locale is in this map its entry wins over the `caption.title`
    /// fallback. Keeping the slide's `caption:` as the default means
    /// unlisted locales still get the shared caption with the same
    /// style, spacing, and highlights.
    ///
    /// Example YAML:
    ///   "spellcheck":
    ///     caption: "Auto-corrections"
    ///     caption_locales:
    ///       el: "Αυτόματες διορθώσεις"
    package var captionLocales: [String: CaptionText]?

    package init(
        background: BackgroundConfig? = nil,
        scrim: ScrimConfig? = nil,
        logo: LogoConfig? = nil,
        caption: SlideCaption? = nil,
        chrome: ChromeConfig? = nil,
        captionLocales: [String: CaptionText]? = nil
    ) {
        self.background = background
        self.scrim = scrim
        self.logo = logo
        self.caption = caption
        self.chrome = chrome
        self.captionLocales = captionLocales
    }

    package enum CodingKeys: String, CodingKey {
        case background, scrim, logo, caption, chrome
        case captionLocales = "caption_locales"
    }
}

// MARK: - Appearance variants

/// A value that can be specified as a single scalar (used for both light and
/// dark appearances) or as a `{ light, dark }` object where either side may
/// be omitted to fall back to the other.
///
/// Example YAML:
///   image: "./bg.png"                               # same for both
///   image: { light: "./bg-l.png", dark: "./bg-d.png" }
package enum AppearanceVariant<T: Codable & Sendable>: Codable, Sendable {
    case shared(T)
    case variant(light: T?, dark: T?)

    package func value(for appearance: String) -> T? {
        switch self {
        case .shared(let v): return v
        case .variant(let light, let dark):
            let isDark = appearance.lowercased() == "dark"
            if isDark { return dark ?? light }
            return light ?? dark
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let scalar = try? container.decode(T.self) {
            self = .shared(scalar)
            return
        }
        let keyed = try decoder.container(keyedBy: VariantKey.self)
        let light = try keyed.decodeIfPresent(T.self, forKey: .light)
        let dark = try keyed.decodeIfPresent(T.self, forKey: .dark)
        self = .variant(light: light, dark: dark)
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .shared(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case .variant(let l, let d):
            var c = encoder.container(keyedBy: VariantKey.self)
            try c.encodeIfPresent(l, forKey: .light)
            try c.encodeIfPresent(d, forKey: .dark)
        }
    }

    private enum VariantKey: String, CodingKey { case light, dark }
}

// MARK: - Background

package struct BackgroundConfig: Codable, Sendable {
    /// Path to background image (may be variant per appearance).
    package var image: AppearanceVariant<String>?
    /// Background fill — a single hex for a solid color, or an array of
    /// hexes for a vertical gradient (top → bottom). Supports appearance
    /// variants via `{ light, dark }`.
    package var color: AppearanceVariant<BackgroundColor>?
    package var align: BackgroundAlign?
    package var fit: BackgroundFit?

    package init(
        image: AppearanceVariant<String>? = nil,
        color: AppearanceVariant<BackgroundColor>? = nil,
        align: BackgroundAlign? = nil,
        fit: BackgroundFit? = nil
    ) {
        self.image = image
        self.color = color
        self.align = align
        self.fit = fit
    }
}

/// Background fill: a single hex color for a solid fill, or an ordered list
/// of hex colors for a vertical (top → bottom) gradient.
///
/// YAML forms:
///   color: "#1a1a2e"                       → .solid
///   color: ["#1a1a2e", "#4a1e5c"]          → .gradient (2+ stops)
package enum BackgroundColor: Codable, Sendable, Equatable {
    case solid(String)
    case gradient([String])

    package var hexes: [String] {
        switch self {
        case .solid(let h): return [h]
        case .gradient(let arr): return arr
        }
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .solid(s); return
        }
        let arr = try c.decode([String].self)
        self = arr.count == 1 ? .solid(arr[0]) : .gradient(arr)
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .solid(let h): try c.encode(h)
        case .gradient(let arr): try c.encode(arr)
        }
    }
}

/// Convenience constructor: wraps a bare hex as a shared solid color.
package extension AppearanceVariant where T == BackgroundColor {
    static func solid(_ hex: String) -> Self { .shared(.solid(hex)) }
    static func gradient(_ hexes: [String]) -> Self { .shared(.gradient(hexes)) }
}

package enum BackgroundAlign: String, Codable, Sendable {
    case top, center, bottom
}

package enum BackgroundFit: String, Codable, Sendable {
    case cover, contain, tile
}

// MARK: - Scrim

package struct ScrimConfig: Codable, Sendable {
    package var color: String?
    package var opacity: Double?
    package var gradient: ScrimGradient?

    package init(color: String? = nil, opacity: Double? = nil, gradient: ScrimGradient? = nil) {
        self.color = color
        self.opacity = opacity
        self.gradient = gradient
    }
}

package struct ScrimGradient: Codable, Sendable {
    package var topOpacity: Double?
    package var bottomOpacity: Double?

    package init(topOpacity: Double? = nil, bottomOpacity: Double? = nil) {
        self.topOpacity = topOpacity
        self.bottomOpacity = bottomOpacity
    }

    package enum CodingKeys: String, CodingKey {
        case topOpacity = "top_opacity"
        case bottomOpacity = "bottom_opacity"
    }
}

// MARK: - Logo

package struct LogoConfig: Codable, Sendable {
    package var path: AppearanceVariant<String>?
    package var placement: LogoPlacement?
    package var maxHeightPct: Double?
    package var topPaddingPct: Double?

    package init(
        path: AppearanceVariant<String>? = nil,
        placement: LogoPlacement? = nil,
        maxHeightPct: Double? = nil,
        topPaddingPct: Double? = nil
    ) {
        self.path = path
        self.placement = placement
        self.maxHeightPct = maxHeightPct
        self.topPaddingPct = topPaddingPct
    }

    package enum CodingKeys: String, CodingKey {
        case path, placement
        case maxHeightPct = "max_height_pct"
        case topPaddingPct = "top_padding_pct"
    }
}

package enum LogoPlacement: String, Codable, Sendable {
    case firstOnly = "first_only"
    case all
    case none
}

// MARK: - Chrome

package struct ChromeConfig: Codable, Sendable {
    package var style: ChromeStyle?
    package var strokeColor: String?
    package var strokeWidth: Double?
    package var cornerRadius: ChromeCornerRadius?
    package var shadow: Bool?
    package var paddingPct: Double?
    /// How much of the device/screenshot to show. `width` scales so the
    /// content fills the available width (device may extend past the bottom
    /// of the canvas — common App Store style). `height` fits fully
    /// vertically. `contain` fits both dimensions inside the padded rect.
    /// Default: `width`.
    package var fit: ChromeFit?
    /// User-supplied preference order for bezel model (e.g. ["Pro Max", "Pro"]).
    /// Overrides the built-in default when set; applied at `bezels import` time,
    /// not at render time.
    package var modelPreference: [String]?
    package var colorwayPreference: [String]?

    package init(
        style: ChromeStyle? = nil,
        strokeColor: String? = nil,
        strokeWidth: Double? = nil,
        cornerRadius: ChromeCornerRadius? = nil,
        shadow: Bool? = nil,
        paddingPct: Double? = nil,
        fit: ChromeFit? = nil,
        modelPreference: [String]? = nil,
        colorwayPreference: [String]? = nil
    ) {
        self.style = style
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.paddingPct = paddingPct
        self.fit = fit
        self.modelPreference = modelPreference
        self.colorwayPreference = colorwayPreference
    }

    package enum CodingKeys: String, CodingKey {
        case style
        case strokeColor = "stroke_color"
        case strokeWidth = "stroke_width"
        case cornerRadius = "corner_radius"
        case shadow
        case paddingPct = "padding_pct"
        case fit
        case modelPreference = "model_preference"
        case colorwayPreference = "colorway_preference"
    }
}

package enum ChromeStyle: String, Codable, Sendable {
    case none
    case stroke
    case bezel = "bezel"
}

/// How device chrome + screenshot fit inside the available area.
package enum ChromeFit: String, Codable, Sendable {
    /// Scale so the content's width matches the available width. Taller-than-area
    /// devices bleed past the bottom of the canvas (App Store marketing style).
    case width
    /// Scale so the content's height matches the available height. Narrower
    /// visible device but fully on-canvas.
    case height
    /// Scale so both dimensions fit entirely within the padded rect. No bleed.
    case contain
}

/// `corner_radius: auto` picks device-derived radius; integer/double picks
/// a fixed point value. Accepts either "auto" or a number in YAML.
package enum ChromeCornerRadius: Codable, Sendable {
    case auto
    case fixed(Double)

    package init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Try numeric first — YAML scalars can be read as String or Double,
        // so preferring Double avoids mis-routing numbers into the String branch.
        if let n = try? c.decode(Double.self) {
            self = .fixed(n)
            return
        }
        let s = try c.decode(String.self)
        if s == "auto" { self = .auto; return }
        if let n = Double(s) { self = .fixed(n); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "corner_radius must be 'auto' or a number, got '\(s)'"
        )
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .fixed(let n): try c.encode(n)
        }
    }
}
