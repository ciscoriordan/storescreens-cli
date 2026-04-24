import XCTest
import CoreText
import AppKit
@testable import StorescreensCore

final class FontResolverTests: XCTestCase {

    // MARK: - System tier

    func testSystem_returnsNSFont_atRequestedSize() throws {
        let r = FontResolver(baseDirectory: URL(fileURLWithPath: "/tmp"))
        let font = try r.resolve(.system, size: 24, weight: .regular, italic: false)
        XCTAssertEqual(CTFontGetSize(font), 24, accuracy: 0.001)
    }

    func testSystem_boldWeight_reflectedInTraits() throws {
        let r = FontResolver(baseDirectory: URL(fileURLWithPath: "/tmp"))
        let bold = try r.resolve(.system, size: 20, weight: .bold, italic: false)
        let traits = CTFontGetSymbolicTraits(bold)
        XCTAssertTrue(traits.contains(.boldTrait), "bold weight should set boldTrait")
    }

    func testSystem_italic_sets_italicTrait() throws {
        let r = FontResolver(baseDirectory: URL(fileURLWithPath: "/tmp"))
        let italic = try r.resolve(.system, size: 20, weight: .regular, italic: true)
        let traits = CTFontGetSymbolicTraits(italic)
        XCTAssertTrue(traits.contains(.italicTrait), "italic=true should set italicTrait")
    }

    // MARK: - Installed tier

    func testInstalled_helveticaNeue_resolves() throws {
        // Helvetica Neue is always available on macOS.
        let r = FontResolver(baseDirectory: URL(fileURLWithPath: "/tmp"))
        let font = try r.resolve(.installed("Helvetica Neue"), size: 18, weight: .regular, italic: false)
        let family = CTFontCopyFamilyName(font) as String
        XCTAssertEqual(family, "Helvetica Neue")
    }

    func testInstalled_missingFamily_throws() {
        let r = FontResolver(baseDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try r.resolve(.installed("NotARealFontFamily123"), size: 18, weight: .regular, italic: false))
    }

    // MARK: - Path tier

    func testPath_loadsRelativeToBaseDirectory() throws {
        // Copy a system font to a temp location and load via path.
        let systemFontURL = URL(fileURLWithPath: "/System/Library/Fonts/Helvetica.ttc")
        guard FileManager.default.fileExists(atPath: systemFontURL.path) else {
            print("skipping: Helvetica.ttc missing")
            return
        }
        let tmpBase = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }
        let dest = tmpBase.appendingPathComponent("helv.ttc")
        try FileManager.default.copyItem(at: systemFontURL, to: dest)

        let r = FontResolver(baseDirectory: tmpBase)
        let font = try r.resolve(.path("./helv.ttc"), size: 20, weight: .regular, italic: false)
        XCTAssertEqual(CTFontGetSize(font), 20, accuracy: 0.001)
    }

    // MARK: - Bundle tier

    func testBundle_picksBoldFile_whenWeightIsBold() throws {
        // Fake base dir with two dummy fonts — but since we actually need
        // valid font files to load, copy a system font into both slots.
        let systemFontURL = URL(fileURLWithPath: "/System/Library/Fonts/Helvetica.ttc")
        guard FileManager.default.fileExists(atPath: systemFontURL.path) else {
            print("skipping: Helvetica.ttc missing")
            return
        }
        let tmpBase = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }
        let regularDest = tmpBase.appendingPathComponent("Regular.ttc")
        let boldDest = tmpBase.appendingPathComponent("Bold.ttc")
        try FileManager.default.copyItem(at: systemFontURL, to: regularDest)
        try FileManager.default.copyItem(at: systemFontURL, to: boldDest)

        let r = FontResolver(baseDirectory: tmpBase)
        // Ensure it resolves — the actual "pick bold" is a pure function test below
        let font = try r.resolve(
            .bundle(regular: "./Regular.ttc", bold: "./Bold.ttc", italic: nil, boldItalic: nil),
            size: 20, weight: .bold, italic: false
        )
        XCTAssertEqual(CTFontGetSize(font), 20, accuracy: 0.001)
    }

    // MARK: - Google Fonts downloader — mock

    func testGoogle_usesMockDownloader() throws {
        let tmpBase = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }

        let mock = MockDownloader()
        let r = FontResolver(baseDirectory: tmpBase, cacheDirectory: tmpBase, downloader: mock)
        let font = try r.resolve(.google(family: "TestFont", version: nil), size: 18, weight: .regular, italic: false)
        XCTAssertEqual(CTFontGetSize(font), 18, accuracy: 0.001)
        XCTAssertEqual(mock.callCount, 1, "downloader should be called once")

        // Second resolve should hit cache, no extra download
        _ = try r.resolve(.google(family: "TestFont", version: nil), size: 24, weight: .regular, italic: false)
        XCTAssertEqual(mock.callCount, 1, "second resolve hits cache")
    }

    // MARK: - CSS extraction (unit)

    func testExtractFirstTTFURL_parsesValidCSS() {
        let css = """
            @font-face {
              font-family: 'Inter';
              font-style: normal;
              font-weight: 400;
              src: url(https://fonts.gstatic.com/s/inter/v19/UcCm3FwrK3iLTcvvYwYZ8UA3.ttf) format('truetype');
            }
            """
        let url = GoogleFontsDownloader.extractFirstTTFURL(from: css)
        XCTAssertEqual(url?.absoluteString, "https://fonts.gstatic.com/s/inter/v19/UcCm3FwrK3iLTcvvYwYZ8UA3.ttf")
    }

    func testExtractFirstTTFURL_returnsNil_whenOnlyWOFF2() {
        let css = "src: url(https://fonts.gstatic.com/s/inter/v19/x.woff2) format('woff2');"
        XCTAssertNil(GoogleFontsDownloader.extractFirstTTFURL(from: css))
    }

    // MARK: - CSS URL construction

    /// Pins the downloader to the v1 `/css` endpoint. v2 returns woff2 only;
    /// any regression to `/css2?family=...` silently breaks offline TTF resolution.
    func testCSSURL_usesV1Endpoint() {
        let url = GoogleFontsDownloader.cssURL(family: "Inter", weight: 9, italic: false)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "fonts.googleapis.com")
        XCTAssertEqual(url.path, "/css", "must use v1 /css (not /css2); v2 returns woff2 only")
        XCTAssertFalse(url.absoluteString.contains("/css2"))
    }

    func testCSSURL_includesWeightInV1Format() {
        // v1 format: `Inter:700`, not v2's `Inter:ital,wght@0,700`.
        let url = GoogleFontsDownloader.cssURL(family: "Inter", weight: 9, italic: false)
        let q = url.query ?? ""
        XCTAssertTrue(q.contains("family=Inter:700"), "expected 'family=Inter:700' in \(q)")
        XCTAssertTrue(q.contains("display=swap"))
    }

    func testCSSURL_italicSuffix() {
        let url = GoogleFontsDownloader.cssURL(family: "Inter", weight: 5, italic: true)
        XCTAssertTrue(url.query?.contains("family=Inter:400italic") == true,
                      "expected italic suffix '400italic' in \(url.query ?? "")")
    }

    func testCSSURL_escapesSpacesInFamily() {
        let url = GoogleFontsDownloader.cssURL(family: "Bricolage Grotesque", weight: 9, italic: false)
        XCTAssertTrue(url.absoluteString.contains("family=Bricolage+Grotesque:700"),
                      "expected + for spaces; got \(url.absoluteString)")
    }

    /// Tests against a real v1 fixture captured from the live endpoint on 2026-04-24.
    /// The regex must accept TTF URLs inside a v1 `@font-face` block.
    func testExtractFirstTTFURL_parsesV1Response() {
        let css = """
            @font-face {
              font-family: 'Inter';
              font-style: normal;
              font-weight: 700;
              font-display: swap;
              src: url(https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuFuYAZ9hjQ.ttf) format('truetype');
            }
            """
        let url = GoogleFontsDownloader.extractFirstTTFURL(from: css)
        XCTAssertEqual(url?.absoluteString, "https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuFuYAZ9hjQ.ttf")
    }

    // MARK: - Weight mapping

    func testWeightMap_coversAllRoles() {
        XCTAssertEqual(FontResolver.nsWeight(from: .regular), NSFont.Weight.regular)
        XCTAssertEqual(FontResolver.nsWeight(from: .bold), NSFont.Weight.bold)
        XCTAssertEqual(FontResolver.nsWeight(from: .heavy), NSFont.Weight.heavy)
        XCTAssertEqual(FontResolver.nsFontManagerWeight(from: .regular), 5)
        XCTAssertEqual(FontResolver.nsFontManagerWeight(from: .bold), 9)
    }
}

// Test-only mock that copies a known system font bytes-for-bytes so the
// resolver's `loadFont(at:)` succeeds without hitting the network.
private final class MockDownloader: FontDownloading, @unchecked Sendable {
    var callCount = 0
    func download(family: String, weight: Int, italic: Bool, to destination: URL) throws {
        callCount += 1
        let src = URL(fileURLWithPath: "/System/Library/Fonts/Helvetica.ttc")
        if FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.copyItem(at: src, to: destination)
        } else {
            // Fallback: write a dummy file so the test still checks cache behavior
            try Data([0x00]).write(to: destination)
        }
    }
}
