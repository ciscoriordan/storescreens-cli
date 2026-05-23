import Foundation

/// Root Codable shape for the `search_preview:` block in `storescreens.yml`.
/// Every field is optional; the resolver fills gaps from `metadata/<locale>/*.txt`,
/// the extracted `AppIcon.png`, the configured `app_store_connect.categories`,
/// and `captureConfig.scheme`. Inspired by ezscreenshots' Search Preview tool —
/// renders an iPhone App Store search result row (icon, name, subtitle, stars,
/// 3 screenshots) wrapped in an iPhone bezel + status bar.
package struct SearchPreviewConfig: Codable, Sendable {
    /// Master switch. Defaults to false so existing configs are untouched.
    /// When true, `storescreens capture` runs the search-preview pass after
    /// the regular render pass.
    package var enabled: Bool?

    /// Output directory for the rendered PNGs. Default: `./storescreens-search-preview`.
    /// Relative paths resolve against the directory containing the YML config.
    package var outputDir: String?

    /// Which appearances to render. Default: `[light]`. The "dark" appearance
    /// recreates the App Store's dark mode (black bezel + chrome) — it's not
    /// tied to the app's own light/dark screenshots, so users opt in
    /// independently of the capture-time `appearances:` list.
    package var appearances: [String]?

    /// Which locales to render. Default: every locale in `captureConfig.locales`,
    /// falling back to a single un-localized PNG when no locales are configured.
    package var locales: [String]?

    // MARK: - Text + identity overrides

    /// App name shown in the search row. When unset, falls back to
    /// `metadata/<locale>/name.txt`, then to `captureConfig.scheme`.
    package var name: String?

    /// Subtitle shown beneath the app name. When unset, falls back to
    /// `metadata/<locale>/subtitle.txt`. May be empty.
    package var subtitle: String?

    /// Developer / studio name shown in the meta row. Default: empty
    /// (the meta row drops the developer chunk when both this and
    /// categories are missing).
    package var developer: String?

    /// Star rating (0–5, fractional values rounded to nearest integer for
    /// star fill count). Default: 4.8 (matches ezscreenshots' placeholder).
    package var rating: Double?

    /// Free-form review count text (e.g. "1.2K", "843", "12M"). Default: "1.2K".
    package var reviews: String?

    /// Up to two categories shown in the pipe-separated meta row. When unset,
    /// falls back to `app_store_connect.categories.primary` + `.secondary`
    /// (mapped from Apple's uppercase ids to friendly display strings).
    package var categories: [String]?

    /// Path to the app icon PNG. When unset, falls back to `<captureDir>/AppIcon.png`
    /// (written by `AppIconExtractor` at capture time). Relative paths
    /// resolve against the YML config directory.
    package var icon: String?

    /// Override the source directory for the 3 screenshots shown in the strip.
    /// Default: the rendered framed dir when `render:` is enabled, else the
    /// raw capture dir. Relative paths resolve against the YML config directory.
    package var screenshotsDir: String?

    /// Subset of screenshot names to show in the 3-up strip, in order.
    /// When unset, the first three entries from `captureConfig.screenshots`
    /// (or the manifest, in order) are used. Names without "@deviceType"
    /// match the basename — the resolver picks the iPhone-sized variant
    /// when multiple devices captured the same name.
    package var screenshots: [String]?

    // MARK: - Action button + search bar

    /// Action button at the right of the row. `get` (default), `open`,
    /// `update`, or `price`. When `price`, the `price` field is shown
    /// instead of the standard pill text.
    package var action: SearchPreviewAction?

    /// Price label shown when `action: price` (e.g. "$0.99"). Ignored
    /// for other action types.
    package var price: String?

    /// Search term shown in the fake search bar at the top of the bezel.
    /// Default: lowercased first 20 chars of the resolved name.
    package var searchTerm: String?

    // MARK: - Visual chrome

    /// Bezel preference: `iphone` (default) wraps the row in a iPhone
    /// bezel + status bar + Dynamic Island. `none` renders just the
    /// search-row card on a flat background (smaller, faster, useful for
    /// embedding the card elsewhere).
    package var bezel: SearchPreviewBezel?

    package init(
        enabled: Bool? = nil,
        outputDir: String? = nil,
        appearances: [String]? = nil,
        locales: [String]? = nil,
        name: String? = nil,
        subtitle: String? = nil,
        developer: String? = nil,
        rating: Double? = nil,
        reviews: String? = nil,
        categories: [String]? = nil,
        icon: String? = nil,
        screenshotsDir: String? = nil,
        screenshots: [String]? = nil,
        action: SearchPreviewAction? = nil,
        price: String? = nil,
        searchTerm: String? = nil,
        bezel: SearchPreviewBezel? = nil
    ) {
        self.enabled = enabled
        self.outputDir = outputDir
        self.appearances = appearances
        self.locales = locales
        self.name = name
        self.subtitle = subtitle
        self.developer = developer
        self.rating = rating
        self.reviews = reviews
        self.categories = categories
        self.icon = icon
        self.screenshotsDir = screenshotsDir
        self.screenshots = screenshots
        self.action = action
        self.price = price
        self.searchTerm = searchTerm
        self.bezel = bezel
    }

    package enum CodingKeys: String, CodingKey {
        case enabled
        case outputDir = "output_dir"
        case appearances
        case locales
        case name, subtitle, developer, rating, reviews, categories, icon
        case screenshotsDir = "screenshots_dir"
        case screenshots, action, price
        case searchTerm = "search_term"
        case bezel
    }
}

/// Which call-to-action pill is drawn on the right of the search row.
/// Matches ezscreenshots' set; `cloud` is intentionally dropped from the
/// public API for v1 since it carries no extra information beyond `get`
/// for screenshot-marketing use cases.
package enum SearchPreviewAction: String, Codable, Sendable {
    case get
    case open
    case update
    case price
}

/// Bezel wrapping style around the search-row card.
package enum SearchPreviewBezel: String, Codable, Sendable {
    case iphone
    case none
}
