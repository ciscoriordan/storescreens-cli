import Foundation

/// Default caption layout: font, sizes, colors, reserved height.
/// Per-slide overrides use `SlideCaption` (below).
package struct CaptionConfig: Codable, Sendable {
    package var title: CaptionRole?
    package var subtitle: CaptionRole?
    package var spacingPct: Double?
    package var minHeightPct: Double?
    package var paddingPct: Double?
    /// Where the caption block sits inside its reserved band.
    /// `top` / `center` (default) / `bottom`. Per-role horizontal alignment
    /// (`title.align`, `subtitle.align`) is independent and still works.
    package var verticalAlign: VerticalAlign?
    /// Fine-grained positional offset applied after vertical-align placement.
    /// See `NudgeConfig` for units and sign conventions.
    package var nudge: NudgeConfig?

    package init(
        title: CaptionRole? = nil,
        subtitle: CaptionRole? = nil,
        spacingPct: Double? = nil,
        minHeightPct: Double? = nil,
        paddingPct: Double? = nil,
        verticalAlign: VerticalAlign? = nil,
        nudge: NudgeConfig? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.spacingPct = spacingPct
        self.minHeightPct = minHeightPct
        self.paddingPct = paddingPct
        self.verticalAlign = verticalAlign
        self.nudge = nudge
    }

    package enum CodingKeys: String, CodingKey {
        case title, subtitle, nudge
        case spacingPct = "spacing_pct"
        case minHeightPct = "min_height_pct"
        case paddingPct = "padding_pct"
        case verticalAlign = "vertical_align"
    }
}

/// Visual style for one caption role (title or subtitle). Everything is
/// optional so slide-level overrides can tweak individual fields.
package struct CaptionRole: Codable, Sendable {
    package var font: FontSpec?
    package var weight: FontWeight?
    package var italic: Bool?
    package var fontSizePct: Double?
    package var minFontSizePct: Double?
    package var color: String?
    package var align: CaptionAlign?
    /// Vertical alignment within the role's container. Currently only
    /// honored by table cells (positioning text within the row's height
    /// when the row auto-grows for multi-line cells); ignored by captions
    /// and laurels, which use their own block-level positioning.
    package var verticalAlign: VerticalAlign?
    /// Per-locale style overrides keyed by Xcode locale code (`en-US`,
    /// `el`, `ja`, `zh-Hans`, …). Each entry is a `CaptionRole` whose
    /// non-nil fields shadow this role's fields when the render's locale
    /// matches. Locales absent from this map use the role unchanged.
    ///
    /// Common case: one font for Latin scripts, a different display face
    /// for Greek or Japanese:
    ///
    ///   caption:
    ///     title:
    ///       font: { google: "Cormorant Garamond" }
    ///       locale_overrides:
    ///         el:
    ///           font: { google: "GFS Didot" }
    ///         ja:
    ///           font: "Hiragino Mincho ProN"
    ///
    /// Field-by-field merge: an override that only sets `font:` keeps
    /// the role's weight, color, alignment, etc. Recursion stops here:
    /// `locale_overrides` inside an override entry is ignored.
    package var localeOverrides: [String: CaptionRole]?

    package init(
        font: FontSpec? = nil,
        weight: FontWeight? = nil,
        italic: Bool? = nil,
        fontSizePct: Double? = nil,
        minFontSizePct: Double? = nil,
        color: String? = nil,
        align: CaptionAlign? = nil,
        verticalAlign: VerticalAlign? = nil,
        localeOverrides: [String: CaptionRole]? = nil
    ) {
        self.font = font
        self.weight = weight
        self.italic = italic
        self.fontSizePct = fontSizePct
        self.minFontSizePct = minFontSizePct
        self.color = color
        self.align = align
        self.verticalAlign = verticalAlign
        self.localeOverrides = localeOverrides
    }

    package enum CodingKeys: String, CodingKey {
        case font, weight, italic, color, align
        case fontSizePct = "font_size_pct"
        case minFontSizePct = "min_font_size_pct"
        case verticalAlign = "vertical_align"
        case localeOverrides = "locale_overrides"
    }

    /// Returns a copy of this role with the per-locale override (if any)
    /// merged in. Override fields shadow this role's; unset override
    /// fields fall through. The returned role's `localeOverrides` is
    /// always nil so downstream code can't loop.
    package func resolved(forLocale locale: String?) -> CaptionRole {
        guard let locale, let override = localeOverrides?[locale] else {
            var copy = self
            copy.localeOverrides = nil
            return copy
        }
        return CaptionRole(
            font: override.font ?? self.font,
            weight: override.weight ?? self.weight,
            italic: override.italic ?? self.italic,
            fontSizePct: override.fontSizePct ?? self.fontSizePct,
            minFontSizePct: override.minFontSizePct ?? self.minFontSizePct,
            color: override.color ?? self.color,
            align: override.align ?? self.align,
            verticalAlign: override.verticalAlign ?? self.verticalAlign,
            localeOverrides: nil
        )
    }
}

package enum CaptionAlign: String, Codable, Sendable {
    case left, center, right
}

package enum FontWeight: String, Codable, Sendable {
    case thin, light, regular, medium, semibold, bold, heavy
}

// MARK: - Slide-level caption (supports shorthand)

/// Per-slide caption. Supports three input shapes:
///   1. bare string       → title only, no subtitle
///   2. array of strings  → title with strict line breaks, no subtitle
///   3. full object       → `{ title: ..., subtitle: ..., highlights: [...] }`
///                          with role-style overrides also allowed
package struct SlideCaption: Codable, Sendable {
    package var title: CaptionText?
    package var subtitle: CaptionText?
    package var highlights: [CaptionHighlight]?
    /// Per-slide role style overrides (optional).
    package var titleStyle: CaptionRole?
    package var subtitleStyle: CaptionRole?

    package init(
        title: CaptionText? = nil,
        subtitle: CaptionText? = nil,
        highlights: [CaptionHighlight]? = nil,
        titleStyle: CaptionRole? = nil,
        subtitleStyle: CaptionRole? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.highlights = highlights
        self.titleStyle = titleStyle
        self.subtitleStyle = subtitleStyle
    }

    package init(from decoder: Decoder) throws {
        var decodedTitle: CaptionText? = nil
        var decodedSubtitle: CaptionText? = nil
        var decodedHighlights: [CaptionHighlight]? = nil
        var decodedTitleStyle: CaptionRole? = nil
        var decodedSubtitleStyle: CaptionRole? = nil

        let single = try? decoder.singleValueContainer()
        if let s = try? single?.decode(String.self) {
            decodedTitle = .string(s)
        } else if let arr = try? single?.decode([String].self) {
            decodedTitle = .array(arr)
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            decodedTitle = try c.decodeIfPresent(CaptionText.self, forKey: .title)
            decodedSubtitle = try c.decodeIfPresent(CaptionText.self, forKey: .subtitle)
            decodedHighlights = try c.decodeIfPresent([CaptionHighlight].self, forKey: .highlights)
            decodedTitleStyle = try c.decodeIfPresent(CaptionRole.self, forKey: .titleStyle)
            decodedSubtitleStyle = try c.decodeIfPresent(CaptionRole.self, forKey: .subtitleStyle)
        }

        self.title = decodedTitle
        self.subtitle = decodedSubtitle
        self.highlights = decodedHighlights
        self.titleStyle = decodedTitleStyle
        self.subtitleStyle = decodedSubtitleStyle
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encodeIfPresent(highlights, forKey: .highlights)
        try c.encodeIfPresent(titleStyle, forKey: .titleStyle)
        try c.encodeIfPresent(subtitleStyle, forKey: .subtitleStyle)
    }

    package enum CodingKeys: String, CodingKey {
        case title, subtitle, highlights
        case titleStyle = "title_style"
        case subtitleStyle = "subtitle_style"
    }
}

/// Caption text — single string (word-wraps) or array (one item per line).
package enum CaptionText: Codable, Sendable {
    case string(String)
    case array([String])

    package var lines: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let a): return a
        }
    }

    package var isStrictLines: Bool {
        if case .array = self { return true }
        return false
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .string(s); return
        }
        let a = try c.decode([String].self)
        self = .array(a)
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        }
    }
}

/// Per-word highlight: overrides color/weight/italic for a literal substring
/// match across the caption's plain text (case-sensitive, all occurrences).
/// Applied after markdown parsing.
package struct CaptionHighlight: Codable, Sendable {
    package var match: String
    package var color: String?
    package var weight: FontWeight?
    package var italic: Bool?

    package init(match: String, color: String? = nil, weight: FontWeight? = nil, italic: Bool? = nil) {
        self.match = match
        self.color = color
        self.weight = weight
        self.italic = italic
    }
}
