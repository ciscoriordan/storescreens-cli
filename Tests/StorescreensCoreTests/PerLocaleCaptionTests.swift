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
}
