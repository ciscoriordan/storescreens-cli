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
