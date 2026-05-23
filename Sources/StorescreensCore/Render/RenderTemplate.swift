import Foundation

/// Named preset that seeds a full `RenderConfig` for a specific visual style.
/// User-supplied fields in the YAML's `render:` block overlay on top of the
/// template's defaults at resolve time - see `RenderResolver.applyTemplate`.
///
/// The 8 built-ins are clean-room reproductions of the free ButterKit template
/// palettes and moods (ButterKit's templates are MIT-licensed), expressed in
/// StoreScreens' own config shape. They do not import or embed ButterKit's
/// artwork; patterns are drawn procedurally by `PatternRenderer`, fonts are
/// resolved via Google Fonts, and colors are picked to evoke the same
/// target app categories (fitness, wellness, travel, dev tools, etc.).
package struct RenderTemplate: Sendable {
    package let id: String
    package let name: String
    package let description: String
    package let category: String
    /// Partial render config applied as defaults. Any field may be nil.
    package let config: RenderConfig

    package init(id: String, name: String, description: String, category: String, config: RenderConfig) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.config = config
    }

    /// Case-insensitive lookup by id, spelled either "sunset_blvd" or "sunsetblvd".
    package static func find(_ needle: String) -> RenderTemplate? {
        let n = normalize(needle)
        return builtIn.first { normalize($0.id) == n }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Registry

    package static let builtIn: [RenderTemplate] = [
        ascent,
        allTheWiser,
        ethereal,
        sahara,
        midnight,
        pinecrest,
        blueprint,
        sunsetBlvd,
        jazzAndWine,
    ]

    // MARK: - Templates

    // All templates use Google Fonts (auto-downloaded on first render, cached
    // to ~/Library/Caches/storescreens/fonts/). Download is a one-time cost
    // per font family + weight + italic variant; subsequent renders hit cache.

    /// Bold outdoors / fitness feel with a topographic contour map.
    package static let ascent = RenderTemplate(
        id: "ascent",
        name: "Ascent",
        description: "Cream paper with topographic contours. Outdoor, fitness, health apps.",
        category: "Pattern",
        config: RenderConfig(
            background: BackgroundConfig(
                color: .solid("#F4EFE7"),
                pattern: PatternConfig(pattern: .topographic, color: "#1A1F2E", opacity: 0.15)
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .google(family: "Inter", version: nil),
                    weight: .heavy,
                    fontSizePct: 9.5,
                    color: "#1A1F2E",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .google(family: "Inter", version: nil),
                    weight: .medium,
                    fontSizePct: 4.6,
                    color: "#3E4A5C",
                    align: .center
                ),
                spacingPct: 1.4,
                minHeightPct: 22,
                paddingPct: 5
            ),
            chrome: ChromeConfig(
                style: .bezel,
                shadow: true,
                paddingPct: 5,
                fit: .width,
                colorwayPreference: ["Natural Titanium", "Silver", "Black"]
            )
        )
    )

    /// Playful, kid-friendly energy with soft scattered shapes.
    package static let allTheWiser = RenderTemplate(
        id: "all_the_wiser",
        name: "All The Wiser",
        description: "Warm cream with playful scattered shapes. Education, kids, language apps.",
        category: "Pattern",
        config: RenderConfig(
            background: BackgroundConfig(
                color: .gradient(["#FCEFD6", "#F5DCA8"]),
                pattern: PatternConfig(pattern: .gamifiedShapes, color: "#3D6BFF", opacity: 0.22)
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .google(family: "Nunito", version: nil),
                    weight: .heavy,
                    fontSizePct: 10,
                    color: "#2B1E5B",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .google(family: "Nunito", version: nil),
                    weight: .semibold,
                    fontSizePct: 4.5,
                    color: "#5A4A8E",
                    align: .center
                ),
                spacingPct: 1.4,
                minHeightPct: 23,
                paddingPct: 5
            ),
            chrome: ChromeConfig(
                style: .bezel,
                shadow: true,
                paddingPct: 5,
                fit: .width
            )
        )
    )

    /// Soft, editorial calm. Desaturated taupe and serif typography.
    package static let ethereal = RenderTemplate(
        id: "ethereal",
        name: "Ethereal",
        description: "Warm taupe gradient with a soft serif. Wellness, meditation, lifestyle apps.",
        category: "Minimal",
        config: RenderConfig(
            background: BackgroundConfig(
                color: .gradient(["#E5D9C8", "#C9A689"])
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .google(family: "Fraunces", version: nil),
                    weight: .regular,
                    fontSizePct: 9.5,
                    color: "#3B2E26",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .google(family: "Fraunces", version: nil),
                    weight: .regular,
                    italic: true,
                    fontSizePct: 4.4,
                    color: "#6A5A4E",
                    align: .center
                ),
                spacingPct: 1.4,
                minHeightPct: 22,
                paddingPct: 6
            ),
            chrome: ChromeConfig(
                style: .bezel,
                shadow: true,
                paddingPct: 5,
                fit: .width,
                colorwayPreference: ["Rose Gold", "Desert Titanium", "Natural Titanium", "Silver"]
            )
        )
    )

    /// Warm sand-to-terracotta gradient with stacked dune bands.
    package static let sahara = RenderTemplate(
        id: "sahara",
        name: "Sahara",
        description: "Sand-to-terracotta gradient with dune layers. Travel, outdoors, adventure apps.",
        category: "Pattern",
        config: RenderConfig(
            background: BackgroundConfig(
                color: .gradient(["#E8D0A8", "#B8624A"]),
                pattern: PatternConfig(pattern: .duneLayers, color: "#5A2E1F", opacity: 0.55)
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .google(family: "Bricolage Grotesque", version: nil),
                    weight: .bold,
                    fontSizePct: 10.5,
                    color: "#2C1810",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .google(family: "Bricolage Grotesque", version: nil),
                    weight: .medium,
                    fontSizePct: 4.5,
                    color: "#4C2F22",
                    align: .center
                ),
                spacingPct: 1.4,
                minHeightPct: 22,
                paddingPct: 5
            ),
            chrome: ChromeConfig(
                style: .bezel,
                shadow: true,
                paddingPct: 5,
                fit: .width,
                colorwayPreference: ["Desert Titanium", "Rose Gold", "Natural Titanium"]
            )
        )
    )

    /// Dark, premium restraint. Deep charcoal with champagne accent text.
    package static let midnight = RenderTemplate(
        id: "midnight",
        name: "Midnight",
        description: "Deep charcoal with champagne accent text. Premium, entertainment, nightlife apps.",
        category: "Dark",
        config: RenderConfig(
            background: BackgroundConfig(
                color: .gradient(["#0B0C10", "#1C1F26"])
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .google(family: "Cormorant Garamond", version: nil),
                    weight: .regular,
                    fontSizePct: 10,
                    color: "#E9E6E0",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .google(family: "Inter", version: nil),
                    weight: .regular,
                    fontSizePct: 4.3,
                    color: "#C8A96A",
                    align: .center
                ),
                spacingPct: 1.6,
                minHeightPct: 22,
                paddingPct: 6
            ),
            chrome: ChromeConfig(
                style: .bezel,
                shadow: true,
                paddingPct: 5,
                fit: .width,
                colorwayPreference: ["Black Titanium", "Space Black", "Midnight", "Black"]
            )
        )
    )

    /// Grounded forest earthtones. Less rose, more moss.
    package static let pinecrest = RenderTemplate(
        id: "pinecrest",
        name: "Pinecrest",
        description: "Forest moss gradient with cream type. Games, health, lifestyle apps.",
        category: "Minimal",
        config: RenderConfig(
            background: BackgroundConfig(
                color: .gradient(["#8DA070", "#3E4E3A"])
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .google(family: "DM Sans", version: nil),
                    weight: .medium,
                    fontSizePct: 9.5,
                    color: "#F5EFDC",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .google(family: "DM Sans", version: nil),
                    weight: .regular,
                    fontSizePct: 4.4,
                    color: "#D5CFB8",
                    align: .center
                ),
                spacingPct: 1.4,
                minHeightPct: 22,
                paddingPct: 5
            ),
            chrome: ChromeConfig(
                style: .bezel,
                shadow: true,
                paddingPct: 5,
                fit: .width,
                colorwayPreference: ["Desert Titanium", "Rose Gold", "Natural Titanium", "Silver"]
            )
        )
    )

    /// Drafting-paper look for developer / productivity apps.
    package static let blueprint = RenderTemplate(
        id: "blueprint",
        name: "Blueprint",
        description: "Pale drafting paper with a blueprint grid. Developer tools, productivity, utilities.",
        category: "Pattern",
        config: RenderConfig(
            background: BackgroundConfig(
                color: .solid("#F3F5F8"),
                pattern: PatternConfig(pattern: .blueprintGrid, color: "#7A9ECF", opacity: 0.55)
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .google(family: "JetBrains Mono", version: nil),
                    weight: .bold,
                    fontSizePct: 8.5,
                    color: "#1C2028",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .google(family: "JetBrains Mono", version: nil),
                    weight: .regular,
                    fontSizePct: 4.0,
                    color: "#546078",
                    align: .center
                ),
                spacingPct: 1.5,
                minHeightPct: 22,
                paddingPct: 5
            ),
            chrome: ChromeConfig(
                style: .bezel,
                shadow: true,
                paddingPct: 5,
                fit: .width,
                colorwayPreference: ["Silver", "Natural Titanium", "Space Gray"]
            )
        )
    )

    /// Loud vibrant sunset. Four-stop gradient, display type.
    package static let sunsetBlvd = RenderTemplate(
        id: "sunset_blvd",
        name: "Sunset Blvd",
        description: "Bold sunset gradient with display type. Entertainment, lifestyle, social apps.",
        category: "Vibrant",
        config: RenderConfig(
            background: BackgroundConfig(
                color: .gradient(["#F0457E", "#FF8A3D", "#FFD166", "#E0743A"])
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .google(family: "Bebas Neue", version: nil),
                    weight: .regular,
                    fontSizePct: 12.5,
                    color: "#FFFFFF",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .google(family: "Inter", version: nil),
                    weight: .medium,
                    fontSizePct: 4.4,
                    color: "#FFF5EA",
                    align: .center
                ),
                spacingPct: 1.3,
                minHeightPct: 22,
                paddingPct: 5
            ),
            chrome: ChromeConfig(
                style: .bezel,
                shadow: true,
                paddingPct: 5,
                fit: .width
            )
        )
    )

    /// Dim warm speakeasy: deep bordeaux and mahogany with a cream serif.
    /// Rich, minimalist, intimate. For food, wine, hospitality, creative apps.
    package static let jazzAndWine = RenderTemplate(
        id: "jazz_and_wine",
        name: "Jazz & Wine",
        description: "Deep bordeaux with elegant cream serif. Food, drink, hospitality, creative apps.",
        category: "Minimal",
        config: RenderConfig(
            background: BackgroundConfig(
                color: .gradient(["#3D1A1F", "#6E2E2A"])
            ),
            caption: CaptionConfig(
                title: CaptionRole(
                    font: .google(family: "Playfair Display", version: nil),
                    weight: .semibold,
                    italic: true,
                    fontSizePct: 10.5,
                    color: "#F2E3D1",
                    align: .center
                ),
                subtitle: CaptionRole(
                    font: .google(family: "Playfair Display", version: nil),
                    weight: .regular,
                    fontSizePct: 4.3,
                    color: "#D9A94E",
                    align: .center
                ),
                spacingPct: 1.6,
                minHeightPct: 22,
                paddingPct: 6
            ),
            chrome: ChromeConfig(
                style: .bezel,
                shadow: true,
                paddingPct: 5,
                fit: .width,
                colorwayPreference: ["Rose Gold", "Desert Titanium", "Natural Titanium"]
            )
        )
    )
}
