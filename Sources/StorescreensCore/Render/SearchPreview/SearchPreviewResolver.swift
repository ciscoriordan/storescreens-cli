import Foundation

/// Fully resolved render input for one `(locale, appearance)` combo of the
/// search-preview pass. Every field is concrete — fallbacks have already
/// been chased through `metadata/<locale>/*.txt`, the captured `AppIcon.png`,
/// the configured ASC categories, etc. The renderer never touches the
/// filesystem to discover inputs; it just draws what it's given.
package struct SearchPreviewInput: Sendable {
    package let locale: String?
    package let appearance: String
    package let name: String
    package let subtitle: String
    package let developer: String
    package let rating: Double
    package let reviews: String
    package let categories: [String]
    package let iconPath: URL?
    package let screenshotPaths: [URL]
    package let action: SearchPreviewAction
    package let priceLabel: String?
    package let searchTerm: String
    package let bezel: SearchPreviewBezel
    package let outputURL: URL

    package init(
        locale: String?,
        appearance: String,
        name: String,
        subtitle: String,
        developer: String,
        rating: Double,
        reviews: String,
        categories: [String],
        iconPath: URL?,
        screenshotPaths: [URL],
        action: SearchPreviewAction,
        priceLabel: String?,
        searchTerm: String,
        bezel: SearchPreviewBezel,
        outputURL: URL
    ) {
        self.locale = locale
        self.appearance = appearance
        self.name = name
        self.subtitle = subtitle
        self.developer = developer
        self.rating = rating
        self.reviews = reviews
        self.categories = categories
        self.iconPath = iconPath
        self.screenshotPaths = screenshotPaths
        self.action = action
        self.priceLabel = priceLabel
        self.searchTerm = searchTerm
        self.bezel = bezel
        self.outputURL = outputURL
    }
}

/// Walks the capture config + metadata files + capture dir to produce one
/// `SearchPreviewInput` per `(locale, appearance)` combo. Designed to run
/// after the regular render pass — `screenshotsSourceDir` should already
/// point at the dir holding the PNGs the user actually plans to upload
/// (framed or raw).
package struct SearchPreviewResolver {

    package init() {}

    /// Resolution result: the list of inputs plus any warnings the caller
    /// should surface. Resolver errors are fatal (e.g. nothing to do); soft
    /// problems (missing icon, missing screenshot) become warnings on the
    /// individual input rather than aborting the whole pass.
    package struct Resolved: Sendable {
        package let inputs: [SearchPreviewInput]
        package let warnings: [String]
    }

    /// - Parameters:
    ///   - captureConfig: full parsed config (we read `searchPreview`,
    ///     `appStoreConnect.metadataDir`, `appStoreConnect.categories`,
    ///     `locales`, `screenshots`, `scheme`).
    ///   - manifest: capture manifest. Used as the screenshot source-of-truth
    ///     when `screenshots:` is empty. When nil, the resolver falls back to
    ///     `captureConfig.screenshots` only.
    ///   - capturedRoot: directory holding the raw captured PNGs +
    ///     extracted `AppIcon.png`. Used as the screenshots dir fallback
    ///     when `render:` isn't enabled.
    ///   - renderedRoot: directory holding the framed PNGs from the
    ///     regular render pass. Preferred over `capturedRoot` when present
    ///     so the search-preview shows the same images the user uploads.
    ///   - baseDirectory: directory containing the YML config. Relative
    ///     paths in `searchPreview.icon` / `searchPreview.screenshots_dir`
    ///     resolve here.
    package func resolve(
        captureConfig: CaptureConfig,
        manifest: CaptureManifest?,
        capturedRoot: URL,
        renderedRoot: URL?,
        baseDirectory: URL
    ) -> Resolved {
        var warnings: [String] = []
        let sp = captureConfig.searchPreview ?? SearchPreviewConfig()
        let outputRoot = resolveOutputDir(sp.outputDir, baseDirectory: baseDirectory)

        let metadataDir = captureConfig.appStoreConnect?.metadataDir.map { resolvePath($0, base: baseDirectory) }
        let metadata: [String: LocalizationFields] = {
            guard let dir = metadataDir else { return [:] }
            do {
                return try MetadataReader.read(dir: dir, onWarning: { warnings.append($0) })
            } catch {
                warnings.append("could not read metadata directory \(dir.path): \(error)")
                return [:]
            }
        }()

        let configuredLocales: [String?] = {
            if let explicit = sp.locales, !explicit.isEmpty { return explicit.map { $0 as String? } }
            if let captureLocales = captureConfig.locales, !captureLocales.isEmpty {
                return captureLocales.map { $0 as String? }
            }
            return [nil]
        }()

        let appearances: [String] = {
            if let explicit = sp.appearances, !explicit.isEmpty { return explicit }
            return ["light"]
        }()

        let screenshotsDir: URL = {
            if let configured = sp.screenshotsDir {
                return resolvePath(configured, base: baseDirectory)
            }
            if let renderedRoot, captureConfig.render?.enabled == true {
                return renderedRoot
            }
            return capturedRoot
        }()

        let iconURL: URL? = {
            if let configured = sp.icon {
                let candidate = resolvePath(configured, base: baseDirectory)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                warnings.append("search_preview.icon not found at \(candidate.path); falling back to AppIcon.png")
            }
            let extracted = capturedRoot.appendingPathComponent("AppIcon.png")
            if FileManager.default.fileExists(atPath: extracted.path) { return extracted }
            return nil
        }()

        let configuredCategories = sp.categories?.filter { !$0.isEmpty }
            ?? Self.friendlyCategories(from: captureConfig.appStoreConnect?.categories)

        let resolvedDeveloper = sp.developer ?? ""
        let resolvedRating = sp.rating ?? 4.8
        let resolvedReviews = sp.reviews ?? "1.2K"
        let resolvedAction = sp.action ?? .get
        let bezel = sp.bezel ?? .iphone

        var inputs: [SearchPreviewInput] = []
        for locale in configuredLocales {
            let localized = locale.flatMap { metadata[$0] }
            let name = sp.name
                ?? localized?.name
                ?? manifest?.displayName
                ?? captureConfig.scheme
            let subtitle = sp.subtitle ?? localized?.subtitle ?? ""

            let screenshotURLs = resolveScreenshotPaths(
                explicit: sp.screenshots,
                fallback: captureConfig.screenshots,
                manifest: manifest,
                locale: locale,
                screenshotsDir: screenshotsDir,
                warnings: &warnings
            )

            let searchTerm = sp.searchTerm ?? Self.defaultSearchTerm(from: name)

            for appearance in appearances {
                let filename = Self.outputFilename(locale: locale, appearance: appearance)
                let outputURL = outputRoot.appendingPathComponent(filename)
                inputs.append(SearchPreviewInput(
                    locale: locale,
                    appearance: appearance,
                    name: name,
                    subtitle: subtitle,
                    developer: resolvedDeveloper,
                    rating: resolvedRating,
                    reviews: resolvedReviews,
                    categories: configuredCategories,
                    iconPath: iconURL,
                    screenshotPaths: screenshotURLs,
                    action: resolvedAction,
                    priceLabel: sp.price,
                    searchTerm: searchTerm,
                    bezel: bezel,
                    outputURL: outputURL
                ))
            }
        }

        return Resolved(inputs: inputs, warnings: warnings)
    }

    // MARK: - Helpers

    /// Default search term: lowercased first 20 chars of the name, with
    /// trailing whitespace trimmed (matches ezscreenshots' default).
    package static func defaultSearchTerm(from name: String) -> String {
        let lower = name.lowercased()
        let truncated = lower.count > 20 ? String(lower.prefix(20)) : lower
        return truncated.trimmingCharacters(in: .whitespaces)
    }

    /// `EDUCATION` → `Education`. `PHOTO_AND_VIDEO` → `Photo & Video`.
    /// `HEALTH_AND_FITNESS` → `Health & Fitness`. Anything we don't
    /// recognize falls through to a generic title-case + underscore→space
    /// rewrite, so future categories Apple adds keep working without
    /// hard-coding.
    package static func friendlyCategory(_ id: String) -> String {
        let normalized = id.uppercased().replacingOccurrences(of: " ", with: "_")
        if let mapped = friendlyCategoryMap[normalized] { return mapped }
        return normalized
            .split(separator: "_")
            .map { part -> String in
                if part == "AND" { return "&" }
                return part.prefix(1).uppercased() + part.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// Extract the (primary, secondary) categories from the configured ASC
    /// block, dropping anything set to "none". Returns at most two strings.
    static func friendlyCategories(from config: CategoriesConfig?) -> [String] {
        guard let config else { return [] }
        var out: [String] = []
        if let primary = config.primary, !primary.isEmpty, primary.lowercased() != "none" {
            out.append(friendlyCategory(primary))
        }
        if let secondary = config.secondary, !secondary.isEmpty, secondary.lowercased() != "none" {
            out.append(friendlyCategory(secondary))
        }
        return out
    }

    /// `search-preview-<locale>-<appearance>.png` — keeps everything in a
    /// flat dir so users can find every variant at a glance. Drops the
    /// locale segment when no locale is configured.
    static func outputFilename(locale: String?, appearance: String) -> String {
        if let locale {
            return "search-preview-\(locale)-\(appearance).png"
        }
        return "search-preview-\(appearance).png"
    }

    private func resolveOutputDir(_ raw: String?, baseDirectory: URL) -> URL {
        guard let raw, !raw.isEmpty else {
            return URL(fileURLWithPath: "./storescreens-search-preview")
        }
        return resolvePath(raw, base: baseDirectory)
    }

    private func resolvePath(_ raw: String, base: URL) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        let trimmed = expanded.hasPrefix("./") ? String(expanded.dropFirst(2)) : expanded
        return base.appendingPathComponent(trimmed).standardizedFileURL
    }

    /// Build the list of screenshot URLs. Priority:
    ///   1. `searchPreview.screenshots` (explicit override) — must exist as files.
    ///   2. First 3 entries of `captureConfig.screenshots` matched against the
    ///      preferred iPhone capture in the manifest.
    ///   3. First 3 screenshots from the preferred iPhone capture in the manifest.
    /// All results are limited to 3. Missing files are dropped with a warning.
    private func resolveScreenshotPaths(
        explicit: [String]?,
        fallback: [String]?,
        manifest: CaptureManifest?,
        locale: String?,
        screenshotsDir: URL,
        warnings: inout [String]
    ) -> [URL] {
        let iphoneCapture = Self.preferredIPhoneCapture(manifest: manifest, locale: locale)

        let namesToTry: [String]
        if let explicit, !explicit.isEmpty {
            namesToTry = explicit
        } else if let fallback, !fallback.isEmpty {
            namesToTry = fallback
        } else if let iphoneCapture {
            namesToTry = iphoneCapture.screenshots.map { $0.name }
        } else {
            return []
        }

        let manifestByName: [String: CaptureManifest.Screenshot] = Dictionary(
            uniqueKeysWithValues: (iphoneCapture?.screenshots ?? [])
                .map { ($0.name, $0) }
        )

        var found: [URL] = []
        for name in namesToTry where found.count < 3 {
            let candidate: URL = {
                if let shot = manifestByName[name] {
                    return screenshotsDir.appendingPathComponent(shot.filename)
                }
                return screenshotsDir.appendingPathComponent("\(name).png")
            }()
            if FileManager.default.fileExists(atPath: candidate.path) {
                found.append(candidate)
            } else {
                warnings.append("search-preview screenshot '\(name)' not found at \(candidate.path)")
            }
        }
        return found
    }

    /// Pick the manifest's iPhone capture closest to the App Store hero
    /// (preferring 6.9" / Pro Max, then 6.7", then any iPhone). Locale
    /// filter is applied first when present.
    static func preferredIPhoneCapture(
        manifest: CaptureManifest?,
        locale: String?
    ) -> CaptureManifest.DeviceCapture? {
        guard let manifest else { return nil }
        let pool: [CaptureManifest.DeviceCapture] = manifest.devices.filter { dev in
            if let locale, let captureLocale = dev.locale, captureLocale != locale { return false }
            let lower = dev.deviceType.lowercased()
            return lower.contains("iphone") || lower.contains("phone")
        }
        if pool.isEmpty { return manifest.devices.first }

        let priorities: [(String) -> Bool] = [
            { $0.lowercased().contains("6.9") || $0.lowercased().contains("pro max") },
            { $0.lowercased().contains("6.7") },
            { $0.lowercased().contains("6.5") },
            { $0.lowercased().contains("6.1") },
            { _ in true },
        ]
        for matcher in priorities {
            if let match = pool.first(where: { matcher($0.simulatorName) || matcher($0.deviceType) }) {
                return match
            }
        }
        return pool.first
    }

    /// Hand-curated mapping for the well-known App Store categories so the
    /// rendered meta row reads "Photo & Video" instead of "PHOTO_AND_VIDEO".
    /// Unknown ids fall through to the generic title-case rewrite in
    /// `friendlyCategory(_:)`.
    private static let friendlyCategoryMap: [String: String] = [
        "BUSINESS":                   "Business",
        "DEVELOPER_TOOLS":            "Developer Tools",
        "EDUCATION":                  "Education",
        "ENTERTAINMENT":              "Entertainment",
        "FINANCE":                    "Finance",
        "FOOD_AND_DRINK":             "Food & Drink",
        "GAMES":                      "Games",
        "GRAPHICS_AND_DESIGN":        "Graphics & Design",
        "HEALTH_AND_FITNESS":         "Health & Fitness",
        "LIFESTYLE":                  "Lifestyle",
        "MAGAZINES_AND_NEWSPAPERS":   "Magazines & Newspapers",
        "MEDICAL":                    "Medical",
        "MUSIC":                      "Music",
        "NAVIGATION":                 "Navigation",
        "NEWS":                       "News",
        "PHOTO_AND_VIDEO":            "Photo & Video",
        "PRODUCTIVITY":               "Productivity",
        "REFERENCE":                  "Reference",
        "SHOPPING":                   "Shopping",
        "SOCIAL_NETWORKING":          "Social Networking",
        "SPORTS":                     "Sports",
        "TRAVEL":                     "Travel",
        "UTILITIES":                  "Utilities",
        "WEATHER":                    "Weather",
        "BOOKS":                      "Books",
        "CATALOGS":                   "Catalogs",
        "STICKERS":                   "Stickers",
    ]
}
