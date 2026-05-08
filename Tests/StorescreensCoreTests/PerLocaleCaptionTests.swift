import XCTest
import Yams
@testable import StorescreensCore

/// Covers the `caption_locales:` map on a `SlideOverride`: a slide
/// carries one baseline `caption:` plus per-locale title overrides,
/// and `RenderResolver.resolvedCaption(config:, slideName:, locale:)`
/// returns the localized title when the render's locale is in the map.
final class PerLocaleCaptionTests: XCTestCase {

    private let baseYAML = """
    slides:
      spellcheck:
        caption: "Auto-corrections"
        caption_locales:
          el: "Αυτόματες διορθώσεις"
          ja: "自動修正"
    """

    private func loadConfig(_ yaml: String) throws -> RenderConfig {
        try YAMLDecoder().decode(RenderConfig.self, from: yaml)
    }

    func testResolvedCaption_perLocaleOverride_wins() throws {
        let config = try loadConfig(baseYAML)
        let el = RenderResolver.resolvedCaption(
            config: config, slideName: "spellcheck", locale: "el"
        )
        XCTAssertEqual(el?.title?.lines, ["Αυτόματες διορθώσεις"])

        let ja = RenderResolver.resolvedCaption(
            config: config, slideName: "spellcheck", locale: "ja"
        )
        XCTAssertEqual(ja?.title?.lines, ["自動修正"])
    }

    func testResolvedCaption_localeAbsentFromMap_fallsBackToBaseCaption() throws {
        let config = try loadConfig(baseYAML)
        let en = RenderResolver.resolvedCaption(
            config: config, slideName: "spellcheck", locale: "en-US"
        )
        XCTAssertEqual(en?.title?.lines, ["Auto-corrections"],
                       "en-US isn't in caption_locales, so the baseline 'caption:' wins")
    }

    func testResolvedCaption_nilLocale_usesBaseCaption() throws {
        // Callers that don't know the locale (legacy call sites) still
        // get the baseline caption, never a random locale's variant.
        let config = try loadConfig(baseYAML)
        let resolved = RenderResolver.resolvedCaption(
            config: config, slideName: "spellcheck"
        )
        XCTAssertEqual(resolved?.title?.lines, ["Auto-corrections"])
    }

    func testResolvedCaption_onlyCaptionLocales_noBaseCaption() throws {
        // `caption:` is optional when `caption_locales:` covers the
        // locales you care about. Unknown locales then return nil
        // rather than a phantom title.
        let yaml = """
        slides:
          trackpad:
            caption_locales:
              el: "Trackpad διαστήματος"
        """
        let config = try loadConfig(yaml)
        let el = RenderResolver.resolvedCaption(
            config: config, slideName: "trackpad", locale: "el"
        )
        XCTAssertEqual(el?.title?.lines, ["Trackpad διαστήματος"])

        let en = RenderResolver.resolvedCaption(
            config: config, slideName: "trackpad", locale: "en-US"
        )
        XCTAssertNil(en?.title, "en-US has no baseline caption and no per-locale entry")
    }

    // MARK: - Per-locale font / style overrides on caption roles

    func testCaptionRole_localeOverrides_fontWins() throws {
        // Top-level `caption.title.locale_overrides.<locale>.font` wins
        // over the role's default font when the render's locale matches.
        let yaml = """
        caption:
          title:
            font: { google: "Cormorant Garamond" }
            weight: bold
            color: "#ffffff"
            locale_overrides:
              el:
                font: { google: "GFS Didot" }
        slides:
          weather:
            caption: "Two scales. Always."
        """
        let config = try loadConfig(yaml)

        let el = RenderResolver.resolvedCaption(
            config: config, slideName: "weather", locale: "el"
        )
        guard case .google(let elFamily, _) = el?.titleStyle?.font else {
            return XCTFail("expected el title to use a google font, got \(String(describing: el?.titleStyle?.font))")
        }
        XCTAssertEqual(elFamily, "GFS Didot",
                       "el locale must use GFS Didot from locale_overrides")
        XCTAssertEqual(el?.titleStyle?.weight, .bold,
                       "fields not set in the locale override fall through to the role default")
        XCTAssertEqual(el?.titleStyle?.color, "#ffffff")

        let en = RenderResolver.resolvedCaption(
            config: config, slideName: "weather", locale: "en-US"
        )
        guard case .google(let enFamily, _) = en?.titleStyle?.font else {
            return XCTFail("expected en title to use a google font, got \(String(describing: en?.titleStyle?.font))")
        }
        XCTAssertEqual(enFamily, "Cormorant Garamond",
                       "en-US is not in locale_overrides; default font wins")
    }

    func testCaptionRole_localeOverrides_subtitleAlsoSupported() throws {
        let yaml = """
        caption:
          title:
            font: system
            locale_overrides:
              el: { font: { google: "GFS Didot" } }
          subtitle:
            font: system
            color: "#dddddd"
            locale_overrides:
              el:
                font: { google: "GFS Didot" }
                color: "#bbbbbb"
        slides:
          weather:
            caption:
              title: "Two scales."
              subtitle: "Always."
        """
        let config = try loadConfig(yaml)

        let el = RenderResolver.resolvedCaption(
            config: config, slideName: "weather", locale: "el"
        )
        guard case .google(let titleFamily, _) = el?.titleStyle?.font else {
            return XCTFail("expected el title font to be google")
        }
        XCTAssertEqual(titleFamily, "GFS Didot")
        guard case .google(let subFamily, _) = el?.subtitleStyle?.font else {
            return XCTFail("expected el subtitle font to be google")
        }
        XCTAssertEqual(subFamily, "GFS Didot")
        XCTAssertEqual(el?.subtitleStyle?.color, "#bbbbbb",
                       "subtitle locale override applies to color too")
    }

    func testCaptionRole_localeOverrides_nilLocaleUsesDefaults() throws {
        // A nil locale (legacy callers without locale awareness) skips
        // the per-locale overrides and just gets the role defaults.
        let yaml = """
        caption:
          title:
            font: system
            locale_overrides:
              el: { font: { google: "GFS Didot" } }
        slides:
          weather:
            caption: "Two scales."
        """
        let config = try loadConfig(yaml)
        let resolved = RenderResolver.resolvedCaption(
            config: config, slideName: "weather"
        )
        XCTAssertEqual(resolved?.titleStyle?.font, .system)
    }

    func testCaptionRole_localeOverrides_slideOverrideStillWorks() throws {
        // A slide-level title_style override merges field-by-field with
        // the top-level role; the merged role's locale_overrides then
        // re-shadow individual fields for the matching locale.
        let yaml = """
        caption:
          title:
            font: system
            color: "#ffffff"
            locale_overrides:
              el: { font: { google: "GFS Didot" } }
        slides:
          weather:
            caption:
              title: "Two scales."
              title_style:
                color: "#feb909"
        """
        let config = try loadConfig(yaml)

        let el = RenderResolver.resolvedCaption(
            config: config, slideName: "weather", locale: "el"
        )
        // Slide override changed color; locale override changed font.
        XCTAssertEqual(el?.titleStyle?.color, "#feb909",
                       "slide-level title_style still wins for color")
        guard case .google(let family, _) = el?.titleStyle?.font else {
            return XCTFail("expected el font to be google")
        }
        XCTAssertEqual(family, "GFS Didot",
                       "locale override on the merged role still applies font")
    }
}
