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
