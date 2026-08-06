import XCTest
@testable import StorescreensCore

/// Rules for the `storescreens precheck` metadata scanner.
///
/// Two things matter roughly equally here: catching what App Review
/// rejects, and not crying wolf. A precheck that flags "meander" for
/// containing "andro" gets muted after the first false positive, so the
/// negative cases below carry as much weight as the positive ones.
final class MetadataPrecheckTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("precheck-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ contents: String, to file: String, locale: String = "en-US") throws -> URL {
        let dir = root.appendingPathComponent(locale, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func scan() -> MetadataPrecheck.Result {
        MetadataPrecheck().scan(dir: root)
    }

    private func findings(rule: String) -> [MetadataPrecheck.Finding] {
        scan().findings.filter { $0.rule == rule }
    }

    // MARK: - Other platforms (guideline 2.3.10)

    func testOtherPlatform_flagsAndroidMention() throws {
        try write("Also available on Android devices.", to: "description.txt")
        let hits = findings(rule: "other-platform")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.severity, .error)
        XCTAssertEqual(hits.first?.file, "description.txt")
        XCTAssertEqual(hits.first?.locale, "en-US")
        XCTAssertTrue(hits.first?.message.contains("Android") == true)
    }

    func testOtherPlatform_flagsGooglePlayAndBlackBerry() throws {
        try write("Get it on Google Play, or on BlackBerry.", to: "description.txt")
        XCTAssertEqual(findings(rule: "other-platform").count, 2)
    }

    /// Word boundaries: substrings inside ordinary words must not match.
    func testOtherPlatform_doesNotMatchSubstrings() throws {
        try write("A meandering walk through androgynous typography.", to: "description.txt")
        XCTAssertTrue(findings(rule: "other-platform").isEmpty)
    }

    /// Japanese runs words together, so a regex `\b` finds no boundary
    /// between "Android" and the character after it. Apple rejects the
    /// mention in ja just as readily as in en-US, so the match has to
    /// survive unspaced scripts.
    func testOtherPlatform_matchesInsideUnspacedScripts() throws {
        try write("Androidにもあります。", to: "description.txt", locale: "ja")
        XCTAssertEqual(findings(rule: "other-platform").count, 1)
    }

    func testOtherPlatform_reportsEachNeedleOnce() throws {
        try write("Android. Android. Android. Really, Android.", to: "description.txt")
        XCTAssertEqual(
            findings(rule: "other-platform").count, 1,
            "a repeated phrase should produce one finding, not one per occurrence"
        )
    }

    /// URL files legitimately contain host names that would trip the prose
    /// rules, so they're excluded from them.
    func testOtherPlatform_ignoresURLFiles() throws {
        try write("https://example.com/android-support", to: "support_url.txt")
        XCTAssertTrue(findings(rule: "other-platform").isEmpty)
    }

    // MARK: - Placeholder text

    func testPlaceholder_flagsLoremAndTodo() throws {
        try write("Lorem ipsum dolor sit amet.", to: "description.txt")
        try write("TODO write a subtitle", to: "subtitle.txt")
        let hits = findings(rule: "placeholder-text")
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.severity == .error })
    }

    func testPlaceholder_doesNotFireOnCleanCopy() throws {
        try write("A careful reader for ancient Greek texts.", to: "description.txt")
        XCTAssertTrue(findings(rule: "placeholder-text").isEmpty)
    }

    // MARK: - Future functionality + pre-release framing

    func testFutureFunctionality_isAWarning() throws {
        try write("Cloud sync coming soon!", to: "description.txt")
        let hits = findings(rule: "future-functionality")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.severity, .warning)
    }

    func testTestWords_flagsBeta() throws {
        try write("Join the beta today.", to: "description.txt")
        XCTAssertEqual(findings(rule: "test-word").first?.severity, .warning)
    }

    // MARK: - Field lengths

    func testFieldLength_flagsOverLongName() throws {
        try write(String(repeating: "a", count: 31), to: "name.txt")
        let hits = findings(rule: "field-length")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.severity, .error)
        XCTAssertTrue(hits.first?.message.contains("30-character") == true)
    }

    func testFieldLength_acceptsExactlyAtLimit() throws {
        try write(String(repeating: "a", count: 30), to: "name.txt")
        try write(String(repeating: "k", count: 100), to: "keywords.txt")
        XCTAssertTrue(findings(rule: "field-length").isEmpty)
    }

    func testFieldLength_countsCharactersNotBytes() throws {
        // 30 multi-byte characters is within a 30-character limit even
        // though it's 90 bytes of UTF-8.
        try write(String(repeating: "あ", count: 30), to: "name.txt", locale: "ja")
        XCTAssertTrue(findings(rule: "field-length").isEmpty)
    }

    func testFieldLength_ignoresTrailingNewline() throws {
        // Editors add these; submit trims them before upload, so the
        // precheck has to trim before counting or it reports phantom
        // overruns on exactly-at-limit fields.
        try write(String(repeating: "a", count: 30) + "\n", to: "name.txt")
        XCTAssertTrue(findings(rule: "field-length").isEmpty)
    }

    // MARK: - Empty files

    func testEmptyFile_warnsBecauseItBlanksTheLiveField() throws {
        try write("   \n", to: "promotional_text.txt")
        let hits = findings(rule: "empty-file")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.severity, .warning)
    }

    /// An empty file has nothing to length-check or scan; it should
    /// produce exactly one finding, not a pile of them.
    func testEmptyFile_producesOnlyTheEmptyFinding() throws {
        try write("", to: "description.txt")
        XCTAssertEqual(scan().findings.count, 1)
    }

    // MARK: - Keywords

    func testKeywords_flagsSpacesAfterCommas() throws {
        try write("greek, lexicon, homer", to: "keywords.txt")
        XCTAssertTrue(findings(rule: "keyword-format").contains { $0.message.contains("spaces after commas") })
    }

    func testKeywords_flagsDuplicates() throws {
        try write("greek,homer,greek", to: "keywords.txt")
        XCTAssertTrue(findings(rule: "keyword-format").contains { $0.message.contains("repeats") })
    }

    func testKeywords_flagsTrailingComma() throws {
        try write("greek,homer,", to: "keywords.txt")
        XCTAssertTrue(findings(rule: "keyword-format").contains { $0.message.contains("empty keyword") })
    }

    func testKeywords_cleanListIsSilent() throws {
        try write("greek,lexicon,homer,iliad", to: "keywords.txt")
        XCTAssertTrue(findings(rule: "keyword-format").isEmpty)
    }

    // MARK: - URLs

    func testURL_flagsMissingScheme() throws {
        try write("example.com/support", to: "support_url.txt")
        let hits = findings(rule: "url-format")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.severity, .error)
    }

    func testURL_flagsNonHTTPScheme() throws {
        try write("ftp://example.com/support", to: "support_url.txt")
        XCTAssertTrue(findings(rule: "url-format").contains { $0.message.contains("ftp://") })
    }

    func testURL_warnsOnPlainHTTP() throws {
        try write("http://example.com/support", to: "support_url.txt")
        XCTAssertEqual(findings(rule: "url-format").first?.severity, .warning)
    }

    func testURL_acceptsHTTPS() throws {
        try write("https://example.com/support", to: "support_url.txt")
        try write("https://example.com/privacy", to: "privacy_url.txt")
        XCTAssertTrue(findings(rule: "url-format").isEmpty)
    }

    // MARK: - Multi-locale behavior

    func testScan_reportsPerLocale() throws {
        try write("Also on Android.", to: "description.txt", locale: "en-US")
        try write("Androidにもあります。", to: "description.txt", locale: "ja")
        let hits = findings(rule: "other-platform")
        XCTAssertEqual(Set(hits.map(\.locale)), ["en-US", "ja"])
    }

    func testScan_countsLocalesWithMetadata() throws {
        try write("Clean copy.", to: "description.txt", locale: "en-US")
        try write("きれいな文章。", to: "description.txt", locale: "ja")
        // A locale directory with no recognized files doesn't count.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("de-DE"), withIntermediateDirectories: true
        )
        XCTAssertEqual(scan().localesScanned, 2)
    }

    func testScan_missingDirectoryIsEmptyNotAThrow() {
        let result = MetadataPrecheck().scan(dir: root.appendingPathComponent("nope"))
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.localesScanned, 0)
    }

    func testScan_ignoresUnknownFiles() throws {
        try write("Android everywhere", to: "notes-to-self.txt")
        XCTAssertTrue(scan().findings.isEmpty, "unrecognized filenames aren't uploaded, so don't scan them")
    }

    // MARK: - Result shape

    func testResult_partitionsErrorsAndWarnings() throws {
        try write("Also on Android.", to: "description.txt")   // error
        try write("Join the beta.", to: "promotional_text.txt")  // warning
        let result = scan()
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.hasErrors)
    }

    func testFinding_carriesLineAndExcerpt() throws {
        try write("First line is fine.\nSecond line mentions Android.", to: "description.txt")
        let hit = findings(rule: "other-platform").first
        XCTAssertEqual(hit?.line, 2)
        XCTAssertTrue(hit?.excerpt?.contains("Android") == true)
    }
}
