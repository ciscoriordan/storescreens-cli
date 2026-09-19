import XCTest
import CoreText
import AppKit
@testable import StorescreensCore

/// Captions in Japanese and Chinese use Han characters that are drawn
/// differently in each language. With the `system` caption font (SF Pro,
/// which has no Han glyphs) Core Text substitutes a fallback font, chosen
/// from the text's language attribute. These tests check that the layouter
/// sets that attribute from the slide's locale, so the fallback is Japanese
/// for `ja` and Chinese for `zh-Hans`, whatever language the rendering Mac
/// itself runs in.
final class CaptionLanguageTests: XCTestCase {

    private func fonts(for text: String, language: String?) throws -> [String] {
        let layouter = CaptionLayouter(resolver: FontResolver(baseDirectory: URL(fileURLWithPath: "/tmp")))
        let out = try layouter.layout(
            title: .string(text),
            subtitle: nil,
            titleStyleRaw: CaptionRole(font: .system, weight: .semibold, fontSizePct: 4, color: "#ffffff", align: .center),
            subtitleStyleRaw: nil,
            highlights: [],
            canvasSize: CGSize(width: 1290, height: 2796),
            reservedHeight: 600,
            blockWidth: 1200,
            spacing: 20,
            language: language
        )
        let attributed = try XCTUnwrap(out.drawable.titleFramesetter).attributed
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        return runs.map { run in
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName] as! CTFont
            return CTFontCopyPostScriptName(font) as String
        }
    }

    func testLanguageAttributeIsSet() throws {
        let layouter = CaptionLayouter(resolver: FontResolver(baseDirectory: URL(fileURLWithPath: "/tmp")))
        let out = try layouter.layout(
            title: .string("直"), subtitle: nil,
            titleStyleRaw: CaptionRole(font: .system, weight: .bold, fontSizePct: 4, color: "#ffffff", align: .center),
            subtitleStyleRaw: nil, highlights: [],
            canvasSize: CGSize(width: 1290, height: 2796), reservedHeight: 400, blockWidth: 1200, spacing: 20,
            language: "ja"
        )
        let attributed = try XCTUnwrap(out.drawable.titleFramesetter).attributed
        let value = attributed.attribute(NSAttributedString.Key(kCTLanguageAttributeName as String), at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(value, "ja")
    }

    func testJapaneseAndChineseGetDifferentFallbacks() throws {
        // 直 and 骨 are drawn differently in Japanese and Chinese typefaces.
        let ja = try fonts(for: "直骨", language: "ja")
        let zh = try fonts(for: "直骨", language: "zh-Hans")
        XCTAssertNotEqual(ja, zh, "ja and zh-Hans captions should fall back to different fonts, got \(ja) and \(zh)")
        // System UI variants carry private names (".HiraKakuInterface-W5",
        // ".PingFangUIDisplaySC-Semibold"), so match the family stems.
        XCTAssertTrue(ja.contains { $0.contains("Hira") }, "Japanese fallback was \(ja)")
        XCTAssertTrue(zh.contains { $0.contains("PingFang") && $0.contains("SC") }, "Simplified Chinese fallback was \(zh)")
    }

    func testNoLanguageLeavesTextUntagged() throws {
        let layouter = CaptionLayouter(resolver: FontResolver(baseDirectory: URL(fileURLWithPath: "/tmp")))
        let out = try layouter.layout(
            title: .string("Hello"), subtitle: nil,
            titleStyleRaw: CaptionRole(font: .system, weight: .bold, fontSizePct: 4, color: "#ffffff", align: .center),
            subtitleStyleRaw: nil, highlights: [],
            canvasSize: CGSize(width: 1290, height: 2796), reservedHeight: 400, blockWidth: 1200, spacing: 20
        )
        let attributed = try XCTUnwrap(out.drawable.titleFramesetter).attributed
        XCTAssertNil(attributed.attribute(NSAttributedString.Key(kCTLanguageAttributeName as String), at: 0, effectiveRange: nil))
    }
}

/// `storescreens capture --locale` splits a locale into the -testLanguage
/// and -testRegion xcodebuild flags. A four-letter final subtag is a script,
/// not a region, and has to stay with the language.
final class ParseLocaleTests: XCTestCase {
    func testRegionIsSplitOff() {
        XCTAssertEqual(CaptureOrchestrator.parseLocale("de-DE").language, "de")
        XCTAssertEqual(CaptureOrchestrator.parseLocale("de-DE").region, "DE")
        XCTAssertEqual(CaptureOrchestrator.parseLocale("pt-BR").language, "pt")
        XCTAssertEqual(CaptureOrchestrator.parseLocale("pt-BR").region, "BR")
    }

    func testScriptStaysWithLanguage() {
        XCTAssertEqual(CaptureOrchestrator.parseLocale("zh-Hans").language, "zh-Hans")
        XCTAssertNil(CaptureOrchestrator.parseLocale("zh-Hans").region)
        XCTAssertEqual(CaptureOrchestrator.parseLocale("zh-Hant").language, "zh-Hant")
        XCTAssertEqual(CaptureOrchestrator.parseLocale("sr-Latn").language, "sr-Latn")
    }

    func testBareLanguage() {
        XCTAssertEqual(CaptureOrchestrator.parseLocale("ja").language, "ja")
        XCTAssertNil(CaptureOrchestrator.parseLocale("ja").region)
        XCTAssertNil(CaptureOrchestrator.parseLocale(nil).language)
    }
}
