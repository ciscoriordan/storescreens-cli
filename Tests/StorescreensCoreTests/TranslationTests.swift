import XCTest
@testable import StorescreensCore

final class TranslationTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTmp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Deterministic translator: prefixes the target language so output is
    /// distinguishable and changes when the base text changes.
    private struct StubTranslator: Translator {
        let tag: String
        func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
            texts.map { "[\(tag)] \($0)" }
        }
    }

    private let fixedDate: () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

    // MARK: - Decision matrix (pure)

    func testDecide_noBase_skips() {
        XCTAssertEqual(
            decideTranslation(baseSha: nil, targetExists: false, targetSha: nil, entry: nil, force: false),
            .skipNoBase)
        // Even with force, no base means nothing to translate from.
        XCTAssertEqual(
            decideTranslation(baseSha: nil, targetExists: true, targetSha: "x", entry: nil, force: true),
            .skipNoBase)
    }

    func testDecide_noTarget_translatesNew() {
        XCTAssertEqual(
            decideTranslation(baseSha: "b", targetExists: false, targetSha: nil, entry: nil, force: false),
            .translateNew)
    }

    func testDecide_untouchedMachine_baseSame_upToDate() {
        let e = entry(base: "b", output: "o")
        XCTAssertEqual(
            decideTranslation(baseSha: "b", targetExists: true, targetSha: "o", entry: e, force: false),
            .skipUpToDate)
    }

    func testDecide_untouchedMachine_baseChanged_retranslates() {
        let e = entry(base: "OLD", output: "o")
        XCTAssertEqual(
            decideTranslation(baseSha: "NEW", targetExists: true, targetSha: "o", entry: e, force: false),
            .retranslateStaleBase)
    }

    func testDecide_edited_baseSame_reviewed() {
        let e = entry(base: "b", output: "machine")
        XCTAssertEqual(
            decideTranslation(baseSha: "b", targetExists: true, targetSha: "human-edit", entry: e, force: false),
            .skipReviewed)
    }

    func testDecide_edited_baseChanged_staleEdited() {
        let e = entry(base: "OLD", output: "machine")
        XCTAssertEqual(
            decideTranslation(baseSha: "NEW", targetExists: true, targetSha: "human-edit", entry: e, force: false),
            .skipStaleEdited)
    }

    func testDecide_preexisting_noEntry_skips() {
        XCTAssertEqual(
            decideTranslation(baseSha: "b", targetExists: true, targetSha: "hand", entry: nil, force: false),
            .skipPreexisting)
    }

    func testDecide_force_overridesExisting() {
        let reviewed = entry(base: "b", output: "machine")
        XCTAssertEqual(
            decideTranslation(baseSha: "b", targetExists: true, targetSha: "human-edit", entry: reviewed, force: true),
            .forced)
        // Force on a pre-existing hand-authored file also re-translates.
        XCTAssertEqual(
            decideTranslation(baseSha: "b", targetExists: true, targetSha: "hand", entry: nil, force: true),
            .forced)
    }

    private func entry(base: String, output: String) -> TranslationManifest.Entry {
        TranslationManifest.Entry(
            baseSha256: base, outputSha256: output, engine: "deepl",
            sourceLang: "EN", targetLang: "DE", translatedAt: "t")
    }

    // MARK: - Manifest round-trip

    func testManifest_roundTrips() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        var m = TranslationManifest(baseLocale: "en-US")
        m.entries[TranslationManifest.key(locale: "de-DE", field: "description")] =
            entry(base: "aaa", output: "bbb")
        try m.save(dir: tmp)

        // Hidden filename so the metadata reader never treats it as a locale.
        XCTAssertEqual(TranslationManifest.filename, ".translations.json")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent(".translations.json").path))

        let loaded = TranslationManifest.load(dir: tmp)
        XCTAssertEqual(loaded.baseLocale, "en-US")
        XCTAssertEqual(loaded.entries["de-DE/description"], entry(base: "aaa", output: "bbb"))
    }

    func testManifest_missingFile_returnsEmpty() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = TranslationManifest.load(dir: tmp)
        XCTAssertTrue(m.entries.isEmpty)
    }

    // MARK: - End-to-end run

    /// new -> up-to-date -> stale-base -> reviewed -> stale-edited -> force.
    func testRun_fullLifecycle() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let meta = tmp.appendingPathComponent("metadata")
        try write(meta.appendingPathComponent("en-US/description.txt"), "Plan your meals")
        let deDesc = meta.appendingPathComponent("de-DE/description.txt")

        func runOnce(force: Bool = false) async throws -> RunSummary {
            let plan = try TranslationOrchestrator.plan(
                dir: meta, baseLocale: "en-US", targetLocales: ["de-DE"],
                fieldNames: ["description"], force: force)
            return try await TranslationOrchestrator.run(
                plan: plan, translator: StubTranslator(tag: "de"), dir: meta,
                dryRun: false, now: fixedDate)
        }

        // 1. New -> translated.
        var s = try await runOnce()
        XCTAssertEqual(s.written.map(\.decision), [.translateNew])
        XCTAssertEqual(read(deDesc), "[de] Plan your meals")

        // 2. Re-run, base unchanged -> up to date, nothing written.
        s = try await runOnce()
        XCTAssertTrue(s.written.isEmpty)
        XCTAssertEqual(s.skipped.map(\.decision), [.skipUpToDate])

        // 3. Base text changes -> stale machine translation re-generated.
        try write(meta.appendingPathComponent("en-US/description.txt"), "Plan meals fast")
        s = try await runOnce()
        XCTAssertEqual(s.written.map(\.decision), [.retranslateStaleBase])
        XCTAssertEqual(read(deDesc), "[de] Plan meals fast")

        // 4. A human edits the German file -> preserved as reviewed.
        try write(deDesc, "Mahlzeiten schnell planen")
        s = try await runOnce()
        XCTAssertEqual(s.skipped.map(\.decision), [.skipReviewed])
        XCTAssertEqual(read(deDesc), "Mahlzeiten schnell planen")

        // 5. Base changes again while the edit stands -> flagged stale, still preserved.
        try write(meta.appendingPathComponent("en-US/description.txt"), "Plan meals in seconds")
        s = try await runOnce()
        XCTAssertEqual(s.skipped.map(\.decision), [.skipStaleEdited])
        XCTAssertEqual(read(deDesc), "Mahlzeiten schnell planen")

        // 6. --force overwrites the edit with a fresh translation.
        s = try await runOnce(force: true)
        XCTAssertEqual(s.written.map(\.decision), [.forced])
        XCTAssertEqual(read(deDesc), "[de] Plan meals in seconds")
    }

    func testRun_unsupportedLocale_reported() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let meta = tmp.appendingPathComponent("metadata")
        try write(meta.appendingPathComponent("en-US/description.txt"), "Hello")

        let plan = try TranslationOrchestrator.plan(
            dir: meta, baseLocale: "en-US", targetLocales: ["th"],
            fieldNames: ["description"], force: false)
        XCTAssertEqual(plan.unsupportedLocales, ["th"])
        XCTAssertTrue(plan.items.isEmpty)
    }

    func testRun_dryRun_writesNothing() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let meta = tmp.appendingPathComponent("metadata")
        try write(meta.appendingPathComponent("en-US/description.txt"), "Hello")

        let plan = try TranslationOrchestrator.plan(
            dir: meta, baseLocale: "en-US", targetLocales: ["de-DE"],
            fieldNames: ["description"], force: false)
        let s = try await TranslationOrchestrator.run(
            plan: plan, translator: StubTranslator(tag: "de"), dir: meta,
            dryRun: true, now: fixedDate)

        XCTAssertEqual(s.written.map(\.decision), [.translateNew])
        XCTAssertNil(read(meta.appendingPathComponent("de-DE/description.txt")))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: meta.appendingPathComponent(".translations.json").path))
    }

    // MARK: - Locale + field tables

    func testLocaleMapping_knownAndUnknown() {
        XCTAssertEqual(AppStoreLocaleMapping.deepL(for: "en-US")?.target, "EN-US")
        XCTAssertEqual(AppStoreLocaleMapping.deepL(for: "pt-BR")?.target, "PT-BR")
        XCTAssertEqual(AppStoreLocaleMapping.deepL(for: "zh-Hans")?.target, "ZH-HANS")
        XCTAssertEqual(AppStoreLocaleMapping.deepL(for: "EN-US")?.target, "EN-US") // case-insensitive
        XCTAssertNil(AppStoreLocaleMapping.deepL(for: "th"))
        XCTAssertNil(AppStoreLocaleMapping.deepL(for: "hi"))
    }

    func testFields_resolveByNameOrFilename() {
        XCTAssertEqual(TranslatableFields.field(for: "description")?.filename, "description.txt")
        XCTAssertEqual(TranslatableFields.field(for: "release_notes.txt")?.name, "release_notes")
        XCTAssertNil(TranslatableFields.field(for: "support_url")) // URLs not translatable
        XCTAssertEqual(TranslatableFields.defaultNames.count, 6)
    }

    func testFreeTierDetection() {
        XCTAssertTrue(DeepLCredentials(apiKey: "abc:fx", source: .file).isFreeTier)
        XCTAssertFalse(DeepLCredentials(apiKey: "abc", source: .file).isFreeTier)
        XCTAssertEqual(DeepLCredentials(apiKey: "abc:fx", source: .file).apiBaseURL.host, "api-free.deepl.com")
        XCTAssertEqual(DeepLCredentials(apiKey: "abc", source: .file).apiBaseURL.host, "api.deepl.com")
    }
}
