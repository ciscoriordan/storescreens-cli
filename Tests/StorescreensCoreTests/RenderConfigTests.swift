import XCTest
import Yams
@testable import StorescreensCore

final class RenderConfigTests: XCTestCase {

    // MARK: - FontSpec disambiguation

    func testFontSpec_systemShorthand() throws {
        XCTAssertEqual(try decodeFont("font: system"), .system)
    }

    func testFontSpec_pathByLeadingSlash() throws {
        XCTAssertEqual(try decodeFont("font: \"./Inter-Bold.otf\""), .path("./Inter-Bold.otf"))
        XCTAssertEqual(try decodeFont("font: \"/usr/local/share/fonts/Inter.ttf\""), .path("/usr/local/share/fonts/Inter.ttf"))
    }

    func testFontSpec_pathByExtension() throws {
        XCTAssertEqual(try decodeFont("font: Inter.otf"), .path("Inter.otf"))
    }

    func testFontSpec_installedFallback() throws {
        XCTAssertEqual(try decodeFont("font: \"Helvetica Neue\""), .installed("Helvetica Neue"))
    }

    func testFontSpec_googleObject() throws {
        let result = try decodeFont("""
            font:
              google: Inter
              version: "3.19"
            """)
        XCTAssertEqual(result, .google(family: "Inter", version: "3.19"))
    }

    func testFontSpec_bundleObject() throws {
        let result = try decodeFont("""
            font:
              regular: ./Inter-Regular.otf
              bold: ./Inter-Bold.otf
            """)
        XCTAssertEqual(result, .bundle(regular: "./Inter-Regular.otf", bold: "./Inter-Bold.otf", italic: nil, boldItalic: nil))
    }

    // MARK: - AppearanceVariant

    func testBackground_imageShared() throws {
        let yaml = """
            background:
              image: ./bg.png
              align: center
            """
        let bg: BackgroundConfig = try decodeNested(yaml, key: "background")
        guard case .shared(let path) = bg.image else { return XCTFail("expected .shared") }
        XCTAssertEqual(path, "./bg.png")
        XCTAssertEqual(bg.align, .center)
    }

    func testBackground_imageVariant() throws {
        let yaml = """
            background:
              image:
                light: ./bg-l.png
                dark: ./bg-d.png
            """
        let bg: BackgroundConfig = try decodeNested(yaml, key: "background")
        guard case .variant(let l, let d) = bg.image else { return XCTFail("expected .variant") }
        XCTAssertEqual(l, "./bg-l.png")
        XCTAssertEqual(d, "./bg-d.png")
        XCTAssertEqual(bg.image?.value(for: "light"), "./bg-l.png")
        XCTAssertEqual(bg.image?.value(for: "dark"), "./bg-d.png")
    }

    func testBackground_imageVariant_onlyOneSide_fallsBack() throws {
        let yaml = """
            background:
              image:
                light: ./only-light.png
            """
        let bg: BackgroundConfig = try decodeNested(yaml, key: "background")
        XCTAssertEqual(bg.image?.value(for: "light"), "./only-light.png")
        XCTAssertEqual(bg.image?.value(for: "dark"), "./only-light.png", "dark should fall back to light when dark absent")
    }

    // MARK: - Pattern background

    func testBackgroundPattern_decodes() throws {
        let yaml = """
            background:
              color: "#F4EFE7"
              pattern:
                pattern: topographic
                color: "#1A1F2E"
                opacity: 0.15
            """
        let bg: BackgroundConfig = try decodeNested(yaml, key: "background")
        XCTAssertEqual(bg.pattern?.pattern, .topographic)
        XCTAssertEqual(bg.pattern?.color, "#1A1F2E")
        XCTAssertEqual(bg.pattern?.opacity, 0.15)
    }

    func testBackgroundPattern_allCases_decode() throws {
        // Each enum case must be reachable from YAML by its lower_snake_case name.
        // Guards against silently renaming a case and breaking user configs.
        let pairs: [(String, BackgroundPattern)] = [
            ("topographic", .topographic),
            ("blueprint_grid", .blueprintGrid),
            ("dune_layers", .duneLayers),
            ("soft_waves", .softWaves),
            ("gamified_shapes", .gamifiedShapes),
        ]
        for (yamlName, expected) in pairs {
            let yaml = """
                background:
                  pattern:
                    pattern: \(yamlName)
                """
            let bg: BackgroundConfig = try decodeNested(yaml, key: "background")
            XCTAssertEqual(bg.pattern?.pattern, expected, "'\(yamlName)' must decode to .\(expected)")
        }
    }

    func testBackgroundPattern_omittedOptionalsDefaultNil() throws {
        let yaml = """
            background:
              pattern:
                pattern: blueprint_grid
            """
        let bg: BackgroundConfig = try decodeNested(yaml, key: "background")
        XCTAssertEqual(bg.pattern?.pattern, .blueprintGrid)
        XCTAssertNil(bg.pattern?.color, "omitted color must stay nil so renderer uses its default")
        XCTAssertNil(bg.pattern?.opacity)
    }

    // MARK: - Template field

    func testRenderConfig_templateField_decodes() throws {
        let yaml = """
            render:
              enabled: true
              template: sahara
            """
        let render: RenderConfig = try decodeNested(yaml, key: "render")
        XCTAssertEqual(render.template, "sahara")
        XCTAssertEqual(render.enabled, true)
    }

    func testRenderConfig_templateField_roundTrips() throws {
        let original = RenderConfig(
            enabled: true,
            template: "midnight",
            background: BackgroundConfig(color: .solid("#111111"))
        )
        let yaml = try YAMLEncoder().encode(original)
        let decoded = try YAMLDecoder().decode(RenderConfig.self, from: yaml)
        XCTAssertEqual(decoded.template, "midnight")
        XCTAssertEqual(decoded.enabled, true)
    }

    // MARK: - Caption vertical_align + nudge

    func testCaption_verticalAlign_decodesAllCases() throws {
        let pairs: [(String, VerticalAlign)] = [
            ("top", .top), ("center", .center), ("bottom", .bottom),
        ]
        for (yamlName, expected) in pairs {
            let yaml = """
                caption:
                  vertical_align: \(yamlName)
                """
            let c: CaptionConfig = try decodeNested(yaml, key: "caption")
            XCTAssertEqual(c.verticalAlign, expected, "'\(yamlName)' must decode to .\(expected)")
        }
    }

    func testCaption_nudge_decodes() throws {
        let yaml = """
            caption:
              nudge:
                x_pct: 1.5
                y_pct: -3
            """
        let c: CaptionConfig = try decodeNested(yaml, key: "caption")
        XCTAssertEqual(c.nudge?.xPct, 1.5)
        XCTAssertEqual(c.nudge?.yPct, -3)
    }

    func testCaption_nudge_partialFields() throws {
        let yaml = """
            caption:
              nudge:
                y_pct: 2
            """
        let c: CaptionConfig = try decodeNested(yaml, key: "caption")
        XCTAssertNil(c.nudge?.xPct, "unset x_pct must stay nil so renderer treats it as zero")
        XCTAssertEqual(c.nudge?.yPct, 2)
    }

    // MARK: - Logo nudge

    func testLogo_nudge_decodes() throws {
        let yaml = """
            logo:
              path: ./logo.png
              nudge:
                x_pct: -1
                y_pct: 4
            """
        let l: LogoConfig = try decodeNested(yaml, key: "logo")
        XCTAssertEqual(l.nudge?.xPct, -1)
        XCTAssertEqual(l.nudge?.yPct, 4)
    }

    // MARK: - Images decoding

    func testImages_decode_full() throws {
        let yaml = """
            images:
              - path: ./logo.png
                position: above_title
                align: center
                max_height_pct: 9
                placement: first_only
                nudge:
                  x_pct: 1
                  y_pct: -2
              - path: ./badge.png
                position: below_subtitle
                align: right
                max_height_pct: 12
                placement: all
                nudge:
                  x_pct: -3
            """
        let imgs: [ImageConfig] = try decodeNested(yaml, key: "images")
        XCTAssertEqual(imgs.count, 2)

        XCTAssertEqual(imgs[0].path?.value(for: "light"), "./logo.png")
        XCTAssertEqual(imgs[0].position, .aboveTitle)
        XCTAssertEqual(imgs[0].align, .center)
        XCTAssertEqual(imgs[0].maxHeightPct, 9)
        XCTAssertEqual(imgs[0].placement, .firstOnly)
        XCTAssertEqual(imgs[0].nudge?.xPct, 1)
        XCTAssertEqual(imgs[0].nudge?.yPct, -2)

        XCTAssertEqual(imgs[1].path?.value(for: "light"), "./badge.png")
        XCTAssertEqual(imgs[1].position, .belowSubtitle)
        XCTAssertEqual(imgs[1].align, .right)
        XCTAssertEqual(imgs[1].maxHeightPct, 12)
        XCTAssertEqual(imgs[1].placement, .all)
        XCTAssertEqual(imgs[1].nudge?.xPct, -3)
        XCTAssertNil(imgs[1].nudge?.yPct, "unset y_pct must remain nil")
    }

    func testImages_decode_minimal() throws {
        let yaml = """
            images:
              - path: ./logo.png
            """
        let imgs: [ImageConfig] = try decodeNested(yaml, key: "images")
        XCTAssertEqual(imgs.count, 1)
        XCTAssertEqual(imgs[0].path?.value(for: "light"), "./logo.png")
        XCTAssertNil(imgs[0].position, "position must remain nil so resolver fills default")
        XCTAssertNil(imgs[0].align, "align must remain nil so resolver fills default")
        XCTAssertNil(imgs[0].maxHeightPct)
        XCTAssertNil(imgs[0].placement)
        XCTAssertNil(imgs[0].nudge)
    }

    func testLaurels_decode_full() throws {
        let yaml = """
            laurels:
              - title: Editor's Choice
                subtitle: 2026
                title_style:
                  color: "#feb909"
                subtitle_style:
                  color: "#cccccc"
                color: "#ffffff"
                position: below_subtitle
                align: center
                max_height_pct: 11
                placement: all
                nudge:
                  x_pct: 0.5
                  y_pct: 1
            """
        let laurels: [LaurelConfig] = try decodeNested(yaml, key: "laurels")
        XCTAssertEqual(laurels.count, 1)

        let l = laurels[0]
        XCTAssertEqual(l.title?.lines, ["Editor's Choice"])
        XCTAssertEqual(l.subtitle?.lines, ["2026"])
        XCTAssertEqual(l.titleStyle?.color, "#feb909")
        XCTAssertEqual(l.subtitleStyle?.color, "#cccccc")
        XCTAssertEqual(l.color?.value(for: "light"), "#ffffff")
        XCTAssertEqual(l.position, .belowSubtitle)
        XCTAssertEqual(l.align, .center)
        XCTAssertEqual(l.maxHeightPct, 11)
        XCTAssertEqual(l.placement, .all)
        XCTAssertEqual(l.nudge?.xPct, 0.5)
        XCTAssertEqual(l.nudge?.yPct, 1)
    }

    // MARK: - Resolved images / laurels

    func testResolveImages_slideOverrideReplacesArray() {
        let a = ImageConfig(path: .shared("./a.png"), position: .aboveTitle)
        let b = ImageConfig(path: .shared("./b.png"), position: .belowSubtitle)
        let c = ImageConfig(path: .shared("./c.png"), position: .belowTitle)

        let config = RenderConfig(
            images: [a, b],
            slides: [
                "01_Home": SlideOverride(images: [c]),
            ]
        )

        let resolvedHome = RenderResolver.resolvedImages(config: config, slideName: "01_Home")
        XCTAssertEqual(resolvedHome.count, 1, "slide override replaces the array wholesale")
        XCTAssertEqual(resolvedHome[0].path?.value(for: "light"), "./c.png")

        let resolvedOther = RenderResolver.resolvedImages(config: config, slideName: "02_Unknown")
        XCTAssertEqual(resolvedOther.count, 2, "unknown slide inherits top-level images")
        XCTAssertEqual(resolvedOther[0].path?.value(for: "light"), "./a.png")
        XCTAssertEqual(resolvedOther[1].path?.value(for: "light"), "./b.png")
    }

    func testResolveImages_legacyLogoSynthesized() {
        let config = RenderConfig(
            logo: LogoConfig(
                path: .shared("./logo.png"),
                placement: .firstOnly,
                maxHeightPct: 7,
                nudge: NudgeConfig(yPct: 2)
            )
        )

        let resolved = RenderResolver.resolvedImages(config: config, slideName: "01_Home")
        XCTAssertEqual(resolved.count, 1, "legacy logo block must synthesize a single image")

        let img = resolved[0]
        XCTAssertEqual(img.path?.value(for: "light"), "./logo.png")
        XCTAssertEqual(img.position, .aboveTitle, "legacy logo always lands at above_title")
        XCTAssertEqual(img.maxHeightPct, 7)
        XCTAssertEqual(img.placement, .firstOnly)
        XCTAssertEqual(img.nudge?.yPct, 2)
    }

    func testResolveImages_imagesArrayOverridesLogo() {
        let img = ImageConfig(path: .shared("./img.png"), position: .belowSubtitle)
        let config = RenderConfig(
            logo: LogoConfig(path: .shared("./logo.png")),
            images: [img]
        )

        let resolved = RenderResolver.resolvedImages(config: config, slideName: "01_Home")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].path?.value(for: "light"), "./img.png",
                       "explicit images: must win over legacy logo:")
    }

    func testResolveImages_emptyImagesArrayDoesNotFallBackToLogo() {
        let config = RenderConfig(
            logo: LogoConfig(path: .shared("./logo.png")),
            images: []
        )

        let resolved = RenderResolver.resolvedImages(config: config, slideName: "01_Home")
        XCTAssertEqual(resolved.count, 0, "explicit empty images: suppresses legacy logo fallback")
    }

    func testResolveImages_capsAtTwo() {
        let imgs: [ImageConfig] = (0..<4).map {
            ImageConfig(path: .shared("./img\($0).png"))
        }
        let config = RenderConfig(images: imgs)

        let resolved = RenderResolver.resolvedImages(config: config, slideName: "01_Home")
        XCTAssertEqual(resolved.count, 2, "more than 2 entries must be truncated")
        XCTAssertEqual(resolved[0].path?.value(for: "light"), "./img0.png")
        XCTAssertEqual(resolved[1].path?.value(for: "light"), "./img1.png")
    }

    func testResolveLaurels_capsAtTwo() {
        let laurels: [LaurelConfig] = (0..<4).map {
            LaurelConfig(title: .string("L\($0)"))
        }
        let config = RenderConfig(laurels: laurels)

        let resolved = RenderResolver.resolvedLaurels(config: config, slideName: "01_Home")
        XCTAssertEqual(resolved.count, 2, "more than 2 entries must be truncated")
        XCTAssertEqual(resolved[0].title?.lines, ["L0"])
        XCTAssertEqual(resolved[1].title?.lines, ["L1"])
    }

    // MARK: - Merge behavior for nudge

    func testMergeLogo_slideNudge_wins() {
        let base = LogoConfig(nudge: NudgeConfig(xPct: 0, yPct: 0))
        let override = LogoConfig(nudge: NudgeConfig(xPct: 2, yPct: -1))
        let merged = RenderResolver.mergeLogo(base: base, override: override)
        XCTAssertEqual(merged?.nudge?.xPct, 2)
        XCTAssertEqual(merged?.nudge?.yPct, -1)
    }

    func testMergeCaption_verticalAlignAndNudge_slideWins() {
        let base = CaptionConfig(verticalAlign: .center, nudge: NudgeConfig(xPct: 0, yPct: 0))
        let override = CaptionConfig(verticalAlign: .bottom, nudge: NudgeConfig(yPct: 5))
        let merged = RenderResolver.mergeCaption(base: base, override: override)
        XCTAssertEqual(merged?.verticalAlign, .bottom)
        XCTAssertEqual(merged?.nudge?.yPct, 5)
        XCTAssertEqual(merged?.nudge?.xPct, 0, "unset fields in override fall through to base")
    }

    // MARK: - ChromeCornerRadius union

    func testChromeCornerRadius_auto() throws {
        let c: ChromeConfig = try decodeNested("chrome:\n  corner_radius: auto\n", key: "chrome")
        guard case .auto = c.cornerRadius else { return XCTFail("expected .auto") }
    }

    func testChromeCornerRadius_fixed() throws {
        let c: ChromeConfig = try decodeNested("chrome:\n  corner_radius: 24\n", key: "chrome")
        guard case .fixed(let n) = c.cornerRadius else { return XCTFail("expected .fixed") }
        XCTAssertEqual(n, 24)
    }

    // MARK: - SlideCaption shorthand

    func testSlideCaption_stringShorthand() throws {
        let sc: SlideCaption = try decodeNested("caption: \"Just a title\"", key: "caption")
        XCTAssertEqual(sc.title?.lines, ["Just a title"])
        XCTAssertNil(sc.subtitle)
    }

    func testSlideCaption_arrayShorthand() throws {
        let sc: SlideCaption = try decodeNested("""
            caption:
              - Line one
              - Line two
            """, key: "caption")
        XCTAssertEqual(sc.title?.lines, ["Line one", "Line two"])
        XCTAssertEqual(sc.title?.isStrictLines, true)
    }

    func testSlideCaption_fullObject() throws {
        let sc: SlideCaption = try decodeNested("""
            caption:
              title: Your **recipes**
              subtitle: Organized
              highlights:
                - match: recipes
                  color: "#feb909"
                  weight: heavy
            """, key: "caption")
        XCTAssertEqual(sc.title?.lines, ["Your **recipes**"])
        XCTAssertEqual(sc.subtitle?.lines, ["Organized"])
        XCTAssertEqual(sc.highlights?.count, 1)
        XCTAssertEqual(sc.highlights?.first?.match, "recipes")
        XCTAssertEqual(sc.highlights?.first?.color, "#feb909")
        XCTAssertEqual(sc.highlights?.first?.weight, .heavy)
    }

    // MARK: - Resolver merge

    func testResolver_slideOverridesDefault_chrome_strokeOnly() throws {
        let config = RenderConfig(
            chrome: ChromeConfig(style: .stroke, strokeColor: "#ffffff", strokeWidth: 3),
            slides: [
                "01_Home": SlideOverride(
                    chrome: ChromeConfig(strokeColor: "#feb909")
                )
            ]
        )

        let resolved = RenderResolver.resolvedChrome(config: config, slideName: "01_Home")
        XCTAssertEqual(resolved?.style, .stroke, "style should inherit from defaults")
        XCTAssertEqual(resolved?.strokeColor, "#feb909", "slide override should win")
        XCTAssertEqual(resolved?.strokeWidth, 3, "untouched field should inherit")

        let other = RenderResolver.resolvedChrome(config: config, slideName: "02_Other")
        XCTAssertEqual(other?.strokeColor, "#ffffff", "unknown slide should inherit defaults")
    }

    func testResolver_resolvedCaption_mergesStyles() throws {
        let config = RenderConfig(
            caption: CaptionConfig(
                title: CaptionRole(font: .system, weight: .bold, fontSizePct: 5.0, color: "#ffffff"),
                subtitle: CaptionRole(font: .system, weight: .regular, fontSizePct: 3.0, color: "#dddddd")
            ),
            slides: [
                "01_Home": SlideOverride(
                    caption: SlideCaption(
                        title: .string("Home"),
                        titleStyle: CaptionRole(color: "#feb909")
                    )
                )
            ]
        )

        let rc = RenderResolver.resolvedCaption(config: config, slideName: "01_Home")
        XCTAssertEqual(rc?.title?.lines, ["Home"])
        XCTAssertEqual(rc?.titleStyle?.color, "#feb909", "slide overrides color")
        XCTAssertEqual(rc?.titleStyle?.weight, .bold, "other fields inherit")
        XCTAssertEqual(rc?.titleStyle?.fontSizePct, 5.0)
        XCTAssertEqual(rc?.subtitleStyle?.color, "#dddddd", "subtitle keeps defaults when slide doesn't touch it")
    }

    // MARK: - Full-shape integration (all features in one YAML)

    func testFullShape_decodesCleanly() throws {
        let yaml = """
            enabled: true
            output_dir: ./storescreens-framed
            background:
              image:
                light: ./bg-l.png
                dark: ./bg-d.png
              color: "#1a1a2e"
              align: center
              fit: cover
            scrim:
              color: "#000000"
              opacity: 0.35
              gradient:
                top_opacity: 0.6
                bottom_opacity: 0.0
            logo:
              path: ./logo.png
              placement: first_only
              max_height_pct: 8
              top_padding_pct: 4
            caption:
              title:
                font: system
                weight: bold
                font_size_pct: 5.5
                min_font_size_pct: 3.0
                color: "#ffffff"
                align: center
              subtitle:
                font:
                  google: Inter
                weight: regular
                font_size_pct: 3.0
                color: "#d0d0d0"
              spacing_pct: 1.2
              min_height_pct: 22
              padding_pct: 4
            chrome:
              style: bezel
              stroke_color: "#ffffff"
              stroke_width: 3
              corner_radius: auto
              shadow: true
              padding_pct: 6
              model_preference:
                - Pro Max
                - Pro
              colorway_preference:
                - Space Black
                - Black
            slides:
              "01_Home":
                caption: "Your **recipes**, organized."
              "02_Search":
                caption:
                  title:
                    - Find anything
                    - "in *seconds*."
                  highlights:
                    - match: seconds
                      color: "#feb909"
                      weight: heavy
              "03_Detail":
                chrome:
                  stroke_color: "#feb909"
            """
        let config = try YAMLDecoder().decode(RenderConfig.self, from: yaml)

        XCTAssertEqual(config.enabled, true)
        XCTAssertEqual(config.outputDir, "./storescreens-framed")
        XCTAssertEqual(config.background?.fit, .cover)
        XCTAssertEqual(config.scrim?.opacity, 0.35)
        XCTAssertEqual(config.scrim?.gradient?.topOpacity, 0.6)
        XCTAssertEqual(config.logo?.placement, .firstOnly)
        XCTAssertEqual(config.caption?.title?.weight, .bold)
        if case .google(let f, _) = config.caption?.subtitle?.font {
            XCTAssertEqual(f, "Inter")
        } else {
            XCTFail("subtitle font should be .google(Inter)")
        }
        XCTAssertEqual(config.chrome?.style, .bezel)
        if case .auto = config.chrome?.cornerRadius {
        } else {
            XCTFail("corner_radius should decode as .auto")
        }
        XCTAssertEqual(config.slides?.count, 3)
        XCTAssertEqual(config.slides?["01_Home"]?.caption?.title?.lines, ["Your **recipes**, organized."])
        XCTAssertEqual(config.slides?["02_Search"]?.caption?.title?.isStrictLines, true)
        XCTAssertEqual(config.slides?["02_Search"]?.caption?.highlights?.first?.match, "seconds")
        XCTAssertEqual(config.slides?["03_Detail"]?.chrome?.strokeColor, "#feb909")

        // Verify resolution: 03_Detail should inherit everything except the one field
        let resolvedChrome = RenderResolver.resolvedChrome(config: config, slideName: "03_Detail")
        XCTAssertEqual(resolvedChrome?.style, .bezel, "inherited")
        XCTAssertEqual(resolvedChrome?.strokeColor, "#feb909", "overridden")
        XCTAssertEqual(resolvedChrome?.strokeWidth, 3, "inherited")
    }

    // MARK: - Helpers

    private func decodeFont(_ yaml: String) throws -> FontSpec {
        struct W: Codable { let font: FontSpec }
        return try YAMLDecoder().decode(W.self, from: yaml).font
    }

    /// Decodes a single-key YAML wrapper like "key: ..." into the value type
    /// T. Navigates the YAML via `Yams.Node` so we don't need per-test
    /// wrapper structs.
    private func decodeNested<T: Decodable>(_ yaml: String, key: String) throws -> T {
        guard let root = try Yams.compose(yaml: yaml),
              case .mapping(let map) = root,
              let child = map[Node(key)] else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "key '\(key)' not found"])
        }
        let subYaml = try Yams.serialize(node: child)
        return try YAMLDecoder().decode(T.self, from: subYaml)
    }
}
