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
        XCTAssertTrue(LocalizationFields(privacyPolicyURL: "https://example.com/privacy").hasAnyField)
    }

    func testRead_privacyURL_parsed() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try write(tmp.appendingPathComponent("en-US/privacy_url.txt"), "https://example.com/privacy")
        try write(tmp.appendingPathComponent("ja/privacy_url.txt"), "https://example.com/privacy/ja\n")

        let result = try MetadataReader.read(dir: tmp)
        XCTAssertEqual(result["en-US"]?.privacyPolicyURL, "https://example.com/privacy")
        XCTAssertEqual(result["ja"]?.privacyPolicyURL, "https://example.com/privacy/ja")
        XCTAssertTrue(result["en-US"]?.hasAnyField ?? false)
    }

    func testReadAll_reviewFields_parsedFromFirstLocale() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try write(tmp.appendingPathComponent("en-US/description.txt"), "English")
        try write(tmp.appendingPathComponent("en-US/review_notes.txt"), "Notes for reviewer")
        try write(tmp.appendingPathComponent("en-US/review_contact_first_name.txt"), "Cisco")
        try write(tmp.appendingPathComponent("en-US/review_contact_last_name.txt"), "Riordan")
        try write(tmp.appendingPathComponent("en-US/review_contact_email.txt"), "cisco@example.com")
        try write(tmp.appendingPathComponent("en-US/review_contact_phone.txt"), "+15551234567")

        let result = try MetadataReader.readAll(dir: tmp)
        XCTAssertEqual(result.localizations["en-US"]?.description, "English")
        XCTAssertNotNil(result.reviewDetail)
        XCTAssertEqual(result.reviewDetail?.notes, "Notes for reviewer")
        XCTAssertEqual(result.reviewDetail?.contactFirstName, "Cisco")
        XCTAssertEqual(result.reviewDetail?.contactLastName, "Riordan")
        XCTAssertEqual(result.reviewDetail?.contactEmail, "cisco@example.com")
        XCTAssertEqual(result.reviewDetail?.contactPhone, "+15551234567")
    }

    func testReadAll_reviewFieldsInMultipleLocales_warnsAndKeepsFirst() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Both locales have review_notes.txt - the alphabetically first
        // (de-DE) wins; en-US's value is ignored with a warning.
        try write(tmp.appendingPathComponent("de-DE/description.txt"), "Deutsch")
        try write(tmp.appendingPathComponent("de-DE/review_notes.txt"), "from de-DE")
        try write(tmp.appendingPathComponent("en-US/description.txt"), "English")
        try write(tmp.appendingPathComponent("en-US/review_notes.txt"), "from en-US")

        var warnings: [String] = []
        let result = try MetadataReader.readAll(dir: tmp) { warnings.append($0) }
        XCTAssertEqual(result.reviewDetail?.notes, "from de-DE",
                       "first locale (alphabetically) wins")
        XCTAssertTrue(warnings.contains { $0.contains("[en-US]") && $0.contains("review_notes.txt") },
                      "expected a warning about en-US's review_notes.txt being ignored")
    }

    func testReadAll_reviewFieldsAbsent_returnsNilReviewDetail() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(tmp.appendingPathComponent("en-US/description.txt"), "Only the description")

        let result = try MetadataReader.readAll(dir: tmp)
        XCTAssertEqual(result.localizations["en-US"]?.description, "Only the description")
        XCTAssertNil(result.reviewDetail)
    }

    func testReviewDetailFields_hasAnyField() {
        XCTAssertFalse(ReviewDetailFields().hasAnyField)
        XCTAssertTrue(ReviewDetailFields(notes: "x").hasAnyField)
        XCTAssertTrue(ReviewDetailFields(contactEmail: "a@b.c").hasAnyField)
        XCTAssertTrue(ReviewDetailFields(demoAccountRequired: true).hasAnyField)
    }

    // MARK: - Field routing (appInfo vs version localization)

    /// Regression test for the bug where `name.txt` / `subtitle.txt` were
    /// either silently ignored or pushed to the wrong endpoint. These
    /// fields live on `appInfoLocalizations` (per app, not per version);
    /// the four routing helpers below are what the orchestrator uses to
    /// decide which API endpoint to PATCH for each filename it reads. If
    /// any of them regress, name/subtitle on the live App Store will stop
    /// updating after a `submit`.
    func testRouting_nameSubtitlePrivacyURLs_classifiedAsAppInfo() {
        XCTAssertTrue(MetadataReader.appInfoFilenames.contains("name.txt"))
        XCTAssertTrue(MetadataReader.appInfoFilenames.contains("subtitle.txt"))
        XCTAssertTrue(MetadataReader.appInfoFilenames.contains("privacy_url.txt"))
        XCTAssertTrue(MetadataReader.appInfoFilenames.contains("privacy_choices_url.txt"))
    }

    func testRouting_versionLocalizationFiles_notClassifiedAsAppInfo() {
        // Sanity check the inverse: the version-level fields must NOT be
        // in the appInfoFilenames set. If they were, the orchestrator
        // would (silently, wrongly) try to PATCH description/keywords
        // onto appInfoLocalizations.
        for name in [
            "description.txt", "keywords.txt", "promotional_text.txt",
            "release_notes.txt", "support_url.txt", "marketing_url.txt",
        ] {
            XCTAssertFalse(MetadataReader.appInfoFilenames.contains(name),
                           "\(name) should be on appStoreVersionLocalizations, not appInfoLocalizations")
        }
    }

    func testRouting_hasAppInfoFields_partitionsCorrectly() {
        // Only appInfo fields set -> hasAppInfoFields true,
        // hasVersionLocalizationFields false.
        let appInfoOnly = LocalizationFields(
            name: "App Name", subtitle: "Subtitle",
            privacyPolicyURL: "https://example.com/privacy",
            privacyChoicesURL: "https://example.com/choices"
        )
        XCTAssertTrue(MetadataReader.hasAppInfoFields(appInfoOnly))
        XCTAssertFalse(MetadataReader.hasVersionLocalizationFields(appInfoOnly))

        // Only version-localization fields set -> opposite.
        let versionOnly = LocalizationFields(
            description: "d", keywords: "k", promotionalText: "p",
            whatsNew: "w", supportURL: "s", marketingURL: "m"
        )
        XCTAssertFalse(MetadataReader.hasAppInfoFields(versionOnly))
        XCTAssertTrue(MetadataReader.hasVersionLocalizationFields(versionOnly))

        // Mixed -> both true.
        let mixed = LocalizationFields(name: "X", description: "Y")
        XCTAssertTrue(MetadataReader.hasAppInfoFields(mixed))
        XCTAssertTrue(MetadataReader.hasVersionLocalizationFields(mixed))

        // Empty -> both false.
        let empty = LocalizationFields()
        XCTAssertFalse(MetadataReader.hasAppInfoFields(empty))
        XCTAssertFalse(MetadataReader.hasVersionLocalizationFields(empty))
    }

    func testRead_privacyChoicesURL_parsed() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try write(tmp.appendingPathComponent("en-US/privacy_choices_url.txt"),
                  "https://example.com/choices")

        let result = try MetadataReader.read(dir: tmp)
        XCTAssertEqual(result["en-US"]?.privacyChoicesURL, "https://example.com/choices")
        XCTAssertTrue(result["en-US"]?.hasAnyField ?? false)
    }
}
