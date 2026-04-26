import Foundation

/// Root Codable shape for the `render:` block in `storescreens.yml`. Every
/// field is optional so the same type serves as both the top-level defaults
/// and a per-slide override — resolution walks from slide-level → top-level
/// at render time.
package struct RenderConfig: Codable, Sendable {
    package var enabled: Bool?
    package var outputDir: String?
    /// Named preset that seeds default `background`, `caption`, and `chrome`
    /// values. User-supplied fields in this same block override the template.
    /// Valid names: see `RenderTemplate.builtIn` (e.g. "ascent", "sahara").
    /// Unknown names are ignored with a warning.
    package var template: String?
    package var background: BackgroundConfig?
    package var scrim: ScrimConfig?
    package var logo: LogoConfig?
    /// Image overlays drawn near the caption. Up to two entries; entries past
    /// the second are dropped at render time with a warning. When `images` is
    /// non-empty, a legacy `logo:` block is ignored. When `images` is nil/empty
    /// the legacy `logo:` is treated as a single `above_title` image so old
    /// configs keep working unchanged.
    package var images: [ImageConfig]?
    /// Laurel overlays: left/right laurel SVGs flanking centered text. Up to
    /// two entries; same slot rules as `images`.
    package var laurels: [LaurelConfig]?
    /// Table overlays: a 2D grid of text cells with optional borders. Up to
    /// two entries; same slot rules as `images` and `laurels`.
    package var tables: [TableConfig]?
    package var caption: CaptionConfig?
    package var chrome: ChromeConfig?
    /// Per-slide overrides keyed by screenshot name (exact match, not substring).
    package var slides: [String: SlideOverride]?

    package init(
        enabled: Bool? = nil,
        outputDir: String? = nil,
        template: String? = nil,
        background: BackgroundConfig? = nil,
        scrim: ScrimConfig? = nil,
        logo: LogoConfig? = nil,
        images: [ImageConfig]? = nil,
        laurels: [LaurelConfig]? = nil,
        tables: [TableConfig]? = nil,
        caption: CaptionConfig? = nil,
        chrome: ChromeConfig? = nil,
        slides: [String: SlideOverride]? = nil
    ) {
        self.enabled = enabled
        self.outputDir = outputDir
        self.template = template
        self.background = background
        self.scrim = scrim
        self.logo = logo
        self.images = images
        self.laurels = laurels
        self.tables = tables
        self.caption = caption
        self.chrome = chrome
        self.slides = slides
    }

    package enum CodingKeys: String, CodingKey {
        case enabled
        case outputDir = "output_dir"
        case template
        case background, scrim, logo, images, laurels, tables, caption, chrome, slides
    }
}

/// Per-slide overrides. Any field left nil inherits from `RenderConfig`.
/// Caption supports shorthand forms (string = title only, array = title lines).
package struct SlideOverride: Codable, Sendable {
    package var background: BackgroundConfig?
    package var scrim: ScrimConfig?
    package var logo: LogoConfig?
    /// Per-slide image overlays. When set (even to an empty array) replaces
    /// the top-level `images:` wholesale for this slide; partial-element
    /// merging is intentionally not supported because its semantics are
    /// ambiguous when the user wants to drop slot 0 but keep slot 1.
    package var images: [ImageConfig]?
    package var laurels: [LaurelConfig]?
    package var tables: [TableConfig]?
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
        images: [ImageConfig]? = nil,
        laurels: [LaurelConfig]? = nil,
        tables: [TableConfig]? = nil,
        caption: SlideCaption? = nil,
        chrome: ChromeConfig? = nil,
        captionLocales: [String: CaptionText]? = nil
    ) {
        self.background = background
        self.scrim = scrim
        self.logo = logo
        self.images = images
        self.laurels = laurels
        self.tables = tables
        self.caption = caption
        self.chrome = chrome
        self.captionLocales = captionLocales
    }

    package enum CodingKeys: String, CodingKey {
        case background, scrim, logo, images, laurels, tables, caption, chrome
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
    /// Procedural pattern layer drawn on top of the color/gradient base.
    /// Independent from `image:` — a background can have both a gradient
    /// and a pattern, but if an image is also set the image wins.
    package var pattern: PatternConfig?

    package init(
        image: AppearanceVariant<String>? = nil,
        color: AppearanceVariant<BackgroundColor>? = nil,
        align: BackgroundAlign? = nil,
        fit: BackgroundFit? = nil,
        pattern: PatternConfig? = nil
    ) {
        self.image = image
        self.color = color
        self.align = align
        self.fit = fit
        self.pattern = pattern
    }
}

/// Procedural pattern drawn on top of a solid/gradient background.
/// Used by templates like "ascent" (topographic), "blueprint" (grid),
/// "sahara" (dune layers). Colors are hex strings.
///
/// YAML:
///   pattern:
///     pattern: topographic
///     color: "#1A1F2E"
///     opacity: 0.15
package struct PatternConfig: Codable, Sendable {
    package var pattern: BackgroundPattern
    /// Accent / line color. Hex string. Defaults to black if omitted.
    package var color: String?
    /// 0..1. Multiplier on the pattern's internal drawing alpha. Default 0.25.
    package var opacity: Double?

    package init(pattern: BackgroundPattern, color: String? = nil, opacity: Double? = nil) {
        self.pattern = pattern
        self.color = color
        self.opacity = opacity
    }
}

/// Built-in procedural patterns. Extend carefully — the set is stable and
/// templates reference them by lower_snake_case name in YAML.
package enum BackgroundPattern: String, Codable, Sendable, CaseIterable {
    case topographic
    case blueprintGrid = "blueprint_grid"
    case duneLayers = "dune_layers"
    case softWaves = "soft_waves"
    case gamifiedShapes = "gamified_shapes"
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

// MARK: - Shared alignment + nudge

/// Vertical alignment of a block inside its reservation band.
/// Applies to the caption block; the logo keeps its own simple top-padding
/// model because it's always at the top of the canvas.
package enum VerticalAlign: String, Codable, Sendable {
    case top, center, bottom
}

/// Fine-grained positional offset relative to a block's normal layout
/// position. Units are percentages of the canvas dimensions, so a nudge
/// stays the same relative size across iPhone 6.9" and iPad 13" renders.
///
/// Coordinate conventions (matches human expectation, not CG origin):
///   - `x_pct`: positive = right, negative = left
///   - `y_pct`: positive = up (toward the top of the screen), negative = down
///
/// YAML:
///   nudge:
///     x_pct: 0
///     y_pct: -2       # move the block 2% of canvas height downward
package struct NudgeConfig: Codable, Sendable, Equatable {
    package var xPct: Double?
    package var yPct: Double?

    package init(xPct: Double? = nil, yPct: Double? = nil) {
        self.xPct = xPct
        self.yPct = yPct
    }

    package enum CodingKeys: String, CodingKey {
        case xPct = "x_pct"
        case yPct = "y_pct"
    }
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
    /// Fine-tune the logo's position. Applied after the normal center-top
    /// placement, in canvas-percent units. See `NudgeConfig` for semantics.
    package var nudge: NudgeConfig?

    package init(
        path: AppearanceVariant<String>? = nil,
        placement: LogoPlacement? = nil,
        maxHeightPct: Double? = nil,
        topPaddingPct: Double? = nil,
        nudge: NudgeConfig? = nil
    ) {
        self.path = path
        self.placement = placement
        self.maxHeightPct = maxHeightPct
        self.topPaddingPct = topPaddingPct
        self.nudge = nudge
    }

    package enum CodingKeys: String, CodingKey {
        case path, placement, nudge
        case maxHeightPct = "max_height_pct"
        case topPaddingPct = "top_padding_pct"
    }
}

package enum LogoPlacement: String, Codable, Sendable {
    case firstOnly = "first_only"
    case all
    case none
}

// MARK: - Overlays (images + laurels)

/// Where an overlay (image or laurel) sits relative to the caption block.
/// `belowTitle` and `aboveSubtitle` are aliases for the same slot, the
/// gap between the title and subtitle text. When the slide has no subtitle,
/// `aboveSubtitle` and `belowSubtitle` collapse to "directly under the title"
/// (i.e. the band between the title baseline and the device top).
package enum OverlayPosition: String, Codable, Sendable {
    case aboveTitle = "above_title"
    case belowTitle = "below_title"
    case aboveSubtitle = "above_subtitle"
    case belowSubtitle = "below_subtitle"

    /// `belowTitle` and `aboveSubtitle` collapse to the same physical slot.
    package var canonicalSlot: OverlayPosition {
        switch self {
        case .belowTitle, .aboveSubtitle: return .belowTitle
        default: return self
        }
    }
}

/// First-only / all / none. Controls per-slide visibility for an overlay.
/// Same semantics as `LogoPlacement` (kept separate so the legacy logo type
/// can stay frozen for backwards compatibility).
package enum OverlayPlacement: String, Codable, Sendable {
    case firstOnly = "first_only"
    case all
    case none
}

/// Image overlay drawn near the caption. Up to two entries may share a slot;
/// stacking + alignment is handled by `OverlayPlacer`.
package struct ImageConfig: Codable, Sendable {
    /// File path to the image (relative to the config dir, absolute, or `~/`).
    /// May be a `{ light, dark }` variant, same as `background.image`.
    package var path: AppearanceVariant<String>?
    /// Slot the image lands in. Default: `above_title` (matches legacy logo
    /// placement so a single image with no `position:` reads naturally).
    package var position: OverlayPosition?
    /// Horizontal alignment within the slot. Default: `center`.
    package var align: CaptionAlign?
    /// Image height as a percentage of canvas height. Default: 8.
    package var maxHeightPct: Double?
    /// Per-slide visibility. Default: `first_only` for `above_title`, `all`
    /// for every other position. (Re-applied at render time; the field stays
    /// a flat optional here so the merge logic is simple.)
    package var placement: OverlayPlacement?
    /// Fine-tune position. See `NudgeConfig` for units.
    package var nudge: NudgeConfig?

    package init(
        path: AppearanceVariant<String>? = nil,
        position: OverlayPosition? = nil,
        align: CaptionAlign? = nil,
        maxHeightPct: Double? = nil,
        placement: OverlayPlacement? = nil,
        nudge: NudgeConfig? = nil
    ) {
        self.path = path
        self.position = position
        self.align = align
        self.maxHeightPct = maxHeightPct
        self.placement = placement
        self.nudge = nudge
    }

    package enum CodingKeys: String, CodingKey {
        case path, position, align, placement, nudge
        case maxHeightPct = "max_height_pct"
    }
}

/// Laurel overlay: left + right laurel SVGs flanking centered title/subtitle
/// text. Up to two entries per slide; same slot rules as `ImageConfig`. The
/// laurel SVGs are bundled with `StorescreensCore` and tinted via `color`
/// (alpha-mask + fill, so any solid color works).
package struct LaurelConfig: Codable, Sendable {
    /// Title text rendered between the laurels (top line, bold by default).
    package var title: CaptionText?
    /// Subtitle text rendered below the title (regular by default).
    package var subtitle: CaptionText?
    /// Title style overrides. Defaults: bold, `color` from `LaurelConfig.color`.
    package var titleStyle: CaptionRole?
    /// Subtitle style overrides. Defaults: regular, `color` from `LaurelConfig.color`.
    package var subtitleStyle: CaptionRole?
    /// Laurel tint color (single hex or `{ light, dark }`). Defaults to white.
    package var color: AppearanceVariant<String>?
    /// Slot the laurel block sits in. Default: `below_subtitle` (the natural
    /// "award badge" position under the caption).
    package var position: OverlayPosition?
    /// Horizontal alignment of the laurel block within its slot. Default: center.
    package var align: CaptionAlign?
    /// Block height (laurel + text) as a percentage of canvas height. Default: 10.
    package var maxHeightPct: Double?
    /// Per-slide visibility. Default: `all` (laurels usually want to repeat).
    package var placement: OverlayPlacement?
    /// Fine-tune position.
    package var nudge: NudgeConfig?
    /// How far each laurel half nudges toward (or away from) the text, as a
    /// percentage of laurel block height. Positive shifts the left laurel
    /// right and the right laurel left, tightening the badge or letting the
    /// laurel branches overlap the text edges (usually safe given the laurel's
    /// open bow shape). Negative pushes both halves outward. The text region
    /// stays put; only the laurels move. Default: 4.
    package var insetPct: Double?

    package init(
        title: CaptionText? = nil,
        subtitle: CaptionText? = nil,
        titleStyle: CaptionRole? = nil,
        subtitleStyle: CaptionRole? = nil,
        color: AppearanceVariant<String>? = nil,
        position: OverlayPosition? = nil,
        align: CaptionAlign? = nil,
        maxHeightPct: Double? = nil,
        placement: OverlayPlacement? = nil,
        nudge: NudgeConfig? = nil,
        insetPct: Double? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleStyle = titleStyle
        self.subtitleStyle = subtitleStyle
        self.color = color
        self.position = position
        self.align = align
        self.maxHeightPct = maxHeightPct
        self.placement = placement
        self.nudge = nudge
        self.insetPct = insetPct
    }

    package enum CodingKeys: String, CodingKey {
        case title, subtitle, color, position, align, placement, nudge
        case titleStyle = "title_style"
        case subtitleStyle = "subtitle_style"
        case maxHeightPct = "max_height_pct"
        case insetPct = "inset_pct"
    }
}

/// Table overlay: a 2D grid of text cells with optional borders. Same slot
/// semantics as `images` and `laurels`; up to two per slot, auto-distributed
/// at equal whitespace when paired.
package struct TableConfig: Codable, Sendable {
    /// Row-major content. Each row is an array of cell strings; rows that
    /// have fewer columns than the widest row are padded with empty cells
    /// at the end so the rendered grid is always rectangular. Wins over
    /// `columns` when both are set.
    package var rows: [[String]]?
    /// Column-major content. Same padding rule as `rows` but along columns.
    /// Used only when `rows` is nil.
    package var columns: [[String]]?
    /// Cell text color (default white). Independent from `border_color` so
    /// you can keep crisp white text on a tinted border.
    package var textColor: AppearanceVariant<String>?
    /// Border color (default white).
    package var borderColor: AppearanceVariant<String>?
    /// Cell text style. When `font_size_pct` is omitted, the renderer picks
    /// a single auto-derived size that fits inside `max_height_pct` divided
    /// across the row line totals, applied uniformly to every cell.
    package var cellStyle: CaptionRole?
    /// Per-column horizontal alignment override. Index 0 is the leftmost
    /// column. Cells without an entry (or columns past the array length)
    /// inherit `cell_style.align` (default center).
    package var columnAligns: [CaptionAlign]?
    /// Per-column vertical alignment override. Mirrors `column_aligns` but
    /// for the y axis. Cells without an entry inherit
    /// `cell_style.vertical_align` (default center). Useful when one row
    /// auto-grows for a multi-line cell and you want its single-line
    /// neighbors to top-align with that cell's first line.
    package var columnValigns: [VerticalAlign]?
    /// Border configuration. Default: enabled, all outer + inner sides,
    /// `width_pct: 0.15` (% of canvas height).
    package var border: TableBorderConfig?
    /// Cell interior padding as percent of canvas height. Default: 1.
    package var cellPaddingPct: Double?
    /// Slot the table sits in. Default: `below_subtitle` (matches laurels).
    package var position: OverlayPosition?
    /// Horizontal alignment of the whole table within its slot. Default: center.
    package var align: CaptionAlign?
    /// Block height (the table's max height) as a percentage of canvas height.
    /// Default: 14. Width is content-driven.
    package var maxHeightPct: Double?
    /// Per-slide visibility. Default: `all`.
    package var placement: OverlayPlacement?
    /// Fine-tune position.
    package var nudge: NudgeConfig?

    package init(
        rows: [[String]]? = nil,
        columns: [[String]]? = nil,
        textColor: AppearanceVariant<String>? = nil,
        borderColor: AppearanceVariant<String>? = nil,
        cellStyle: CaptionRole? = nil,
        columnAligns: [CaptionAlign]? = nil,
        columnValigns: [VerticalAlign]? = nil,
        border: TableBorderConfig? = nil,
        cellPaddingPct: Double? = nil,
        position: OverlayPosition? = nil,
        align: CaptionAlign? = nil,
        maxHeightPct: Double? = nil,
        placement: OverlayPlacement? = nil,
        nudge: NudgeConfig? = nil
    ) {
        self.rows = rows
        self.columns = columns
        self.textColor = textColor
        self.borderColor = borderColor
        self.cellStyle = cellStyle
        self.columnAligns = columnAligns
        self.columnValigns = columnValigns
        self.border = border
        self.cellPaddingPct = cellPaddingPct
        self.position = position
        self.align = align
        self.maxHeightPct = maxHeightPct
        self.placement = placement
        self.nudge = nudge
    }

    package enum CodingKeys: String, CodingKey {
        case rows, columns, border, position, align, placement, nudge
        case textColor = "text_color"
        case borderColor = "border_color"
        case cellStyle = "cell_style"
        case columnAligns = "column_aligns"
        case columnValigns = "column_valigns"
        case cellPaddingPct = "cell_padding_pct"
        case maxHeightPct = "max_height_pct"
    }
}

/// Border configuration for a `TableConfig`. Defaults render outer + inner
/// borders; pass `sides: [outer]` to drop grid lines, `sides: [inner]` for
/// only grid lines, or per-side values like `[top, bottom]`.
package struct TableBorderConfig: Codable, Sendable {
    package var enabled: Bool?
    /// Border thickness as a percentage of canvas height. Default: 0.15.
    package var widthPct: Double?
    /// Which sides to draw. Default: `[outer, inner]` (full grid). `outer`
    /// expands to the four outside edges; `inner` to the lines between
    /// cells. Individual sides override expansion of `outer`.
    package var sides: [BorderSide]?

    package init(
        enabled: Bool? = nil,
        widthPct: Double? = nil,
        sides: [BorderSide]? = nil
    ) {
        self.enabled = enabled
        self.widthPct = widthPct
        self.sides = sides
    }

    package enum CodingKeys: String, CodingKey {
        case enabled, sides
        case widthPct = "width_pct"
    }
}

package enum BorderSide: String, Codable, Sendable {
    case outer
    case inner
    case top, bottom, left, right
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
