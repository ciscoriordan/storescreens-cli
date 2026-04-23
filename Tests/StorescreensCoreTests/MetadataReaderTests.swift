import XCTest
@testable import StorescreensCore

final class MetadataReaderTests: XCTestCase {

    private func makeTmp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-reader-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testRead_fullLocale_allFields() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let en = tmp.appendingPathComponent("en-US")
        try write(en.appendingPathComponent("name.txt"), "Recipes")
        try write(en.appendingPathComponent("subtitle.txt"), "Cook smarter")
        try write(en.appendingPathComponent("description.txt"), "Full description\nacross lines")
        try write(en.appendingPathComponent("keywords.txt"), "cook,recipe,meal")
        try write(en.appendingPathComponent("promotional_text.txt"), "New! AI planner")
        try write(en.appendingPathComponent("release_notes.txt"), "1.2.0 release notes\nBug fixes\n\n")
        try write(en.appendingPathComponent("support_url.txt"), "https://example.com/support")
        try write(en.appendingPathComponent("marketing_url.txt"), "https://example.com")

        let result = try MetadataReader.read(dir: tmp)
        XCTAssertEqual(result.keys.sorted(), ["en-US"])
        let en_US = result["en-US"]!
        XCTAssertEqual(en_US.name, "Recipes")
        XCTAssertEqual(en_US.subtitle, "Cook smarter")
        XCTAssertEqual(en_US.description, "Full description\nacross lines")
        XCTAssertEqual(en_US.keywords, "cook,recipe,meal")
        XCTAssertEqual(en_US.promotionalText, "New! AI planner")
        XCTAssertEqual(en_US.whatsNew, "1.2.0 release notes\nBug fixes")  // trailing \n\n trimmed
        XCTAssertEqual(en_US.supportURL, "https://example.com/support")
        XCTAssertEqual(en_US.marketingURL, "https://example.com")
    }

    func testRead_multipleLocales_withPartialFields() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try write(tmp.appendingPathComponent("en-US/description.txt"), "English")
        try write(tmp.appendingPathComponent("ja/description.txt"), "日本語")
        try write(tmp.appendingPathComponent("de-DE/release_notes.txt"), "Deutsch notes")

        let result = try MetadataReader.read(dir: tmp)
        XCTAssertEqual(result.keys.sorted(), ["de-DE", "en-US", "ja"])
        XCTAssertEqual(result["en-US"]?.description, "English")
        XCTAssertEqual(result["ja"]?.description, "日本語")
        XCTAssertEqual(result["de-DE"]?.whatsNew, "Deutsch notes")
        // Unset fields stay nil.
        XCTAssertNil(result["en-US"]?.keywords)
        XCTAssertNil(result["de-DE"]?.description)
    }

    func testRead_unknownFile_warnsSkipped() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try write(tmp.appendingPathComponent("en-US/description.txt"), "ok")
        try write(tmp.appendingPathComponent("en-US/categories.txt"), "unsupported")

        var warnings: [String] = []
        let result = try MetadataReader.read(dir: tmp) { warnings.append($0) }
        XCTAssertEqual(result["en-US"]?.description, "ok")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.contains("categories.txt") ?? false)
    }

    func testRead_emptyLocaleDirectory_dropped() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("fr"),
            withIntermediateDirectories: true
        )
        try write(tmp.appendingPathComponent("en-US/description.txt"), "only en")

        let result = try MetadataReader.read(dir: tmp)
        XCTAssertEqual(result.keys.sorted(), ["en-US"])
    }

    func testRead_nonexistentDir_throws() {
        XCTAssertThrowsError(try MetadataReader.read(dir: URL(fileURLWithPath: "/nonexistent/metadata"))) { err in
            if case MetadataReader.ReadError.directoryNotFound = err { return }
            XCTFail("wrong error: \(err)")
        }
    }

    func testHasAnyField_reflectsPresence() {
        XCTAssertFalse(LocalizationFields().hasAnyField)
        XCTAssertTrue(LocalizationFields(description: "x").hasAnyField)
    }
}
