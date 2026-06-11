import Foundation

/// What `translate run` decided to do for one (locale, field). The three
/// `willTranslate` cases write a file; the rest are reported and left alone.
package enum TranslationDecision: String, Sendable, Equatable {
    /// No target file yet.
    case translateNew
    /// Target is an untouched machine translation but the base text moved.
    /// This is the core "base changed -> override the stale translation" path.
    case retranslateStaleBase
    /// `--force` overrode a skip and re-translated anyway.
    case forced
    /// Target is an untouched machine translation and the base is unchanged.
    case skipUpToDate
    /// Target was edited by a human/agent and the base is unchanged (reviewed).
    case skipReviewed
    /// Target was edited by a human/agent but the base text has since moved -
    /// the edit may be outdated. Re-translate only with `--force`.
    case skipStaleEdited
    /// Target exists with no manifest entry - assumed hand-authored, never clobbered.
    case skipPreexisting
    /// No base-locale text for this field; nothing to translate from.
    case skipNoBase

    package var willTranslate: Bool {
        switch self {
        case .translateNew, .retranslateStaleBase, .forced: return true
        default: return false
        }
    }
}

/// Pure decision for one (locale, field). Kept separate from I/O so the policy
/// is exhaustively unit-testable.
package func decideTranslation(
    baseSha: String?,
    targetExists: Bool,
    targetSha: String?,
    entry: TranslationManifest.Entry?,
    force: Bool
) -> TranslationDecision {
    // Nothing to translate from.
    if baseSha == nil { return .skipNoBase }
    // Never-translated field.
    if !targetExists { return .translateNew }
    // An explicit --force re-translates any existing target (overwrites edits).
    if force { return .forced }

    guard let entry else {
        // File on disk we did not write: treat as hand-authored, leave alone.
        return .skipPreexisting
    }
    let untouched = (entry.outputSha256 == targetSha)
    if untouched {
        return entry.baseSha256 == baseSha ? .skipUpToDate : .retranslateStaleBase
    } else {
        return entry.baseSha256 == baseSha ? .skipReviewed : .skipStaleEdited
    }
}

package struct PlanItem: Sendable {
    package let locale: String
    package let fieldName: String
    package let filename: String
    package let maxLength: Int?
    package let decision: TranslationDecision
    package let sourceLang: String
    package let targetLang: String
    package let baseText: String?
}

package struct TranslationPlan: Sendable {
    package var baseLocale: String
    package var items: [PlanItem]
    /// Requested targets DeepL cannot translate (skipped with a warning).
    package var unsupportedLocales: [String]
    /// True if the base locale had at least one of the requested fields.
    package var hasBaseContent: Bool
}

package struct WrittenField: Sendable {
    package let locale: String
    package let fieldName: String
    package let decision: TranslationDecision
    package let charCount: Int
    package let maxLength: Int?
    package var overLength: Bool {
        guard let maxLength else { return false }
        return charCount > maxLength
    }
}

package struct SkippedField: Sendable {
    package let locale: String
    package let fieldName: String
    package let decision: TranslationDecision
}

package struct RunSummary: Sendable {
    package var dryRun: Bool
    package var written: [WrittenField]
    package var skipped: [SkippedField]
    package var unsupportedLocales: [String]
}

package enum TranslationOrchestratorError: Error, CustomStringConvertible {
    case unsupportedBaseLocale(String)
    case unknownField(String)

    package var description: String {
        switch self {
        case .unsupportedBaseLocale(let l):
            return "DeepL cannot use `\(l)` as a source language. Pick a base locale DeepL supports."
        case .unknownField(let f):
            return "unknown translatable field `\(f)`. Valid: \(TranslatableFields.defaultNames.joined(separator: ", "))."
        }
    }
}

package enum TranslationOrchestrator {

    // MARK: - Plan (no network)

    /// Computes the per-(locale, field) decision matrix without translating.
    /// Powers both `translate status` and `translate run --dry-run`.
    package static func plan(
        dir: URL,
        baseLocale: String,
        targetLocales: [String]?,
        fieldNames: [String],
        force: Bool,
        onWarning: (String) -> Void = { _ in }
    ) throws -> TranslationPlan {
        guard let baseMapping = AppStoreLocaleMapping.deepL(for: baseLocale) else {
            throw TranslationOrchestratorError.unsupportedBaseLocale(baseLocale)
        }

        // Resolve requested fields up front so a typo fails fast.
        let fields = try fieldNames.map { name -> TranslatableField in
            guard let f = TranslatableFields.field(for: name) else {
                throw TranslationOrchestratorError.unknownField(name)
            }
            return f
        }

        let read = try MetadataReader.read(dir: dir, onWarning: onWarning)
        let baseFields = read[baseLocale]
        let manifest = TranslationManifest.load(dir: dir)

        let targets = (targetLocales ?? inferTargetLocales(dir: dir, excluding: baseLocale)).sorted()

        var items: [PlanItem] = []
        var unsupported: [String] = []

        for locale in targets {
            guard let mapping = AppStoreLocaleMapping.deepL(for: locale) else {
                unsupported.append(locale)
                continue
            }
            for field in fields {
                let rawBase = baseFields?[keyPath: field.keyPath]
                let baseText = (rawBase?.isEmpty == false) ? rawBase : nil
                let baseSha = baseText?.sha256Hex

                let targetURL = dir.appendingPathComponent(locale).appendingPathComponent(field.filename)
                let targetContent = readTrimmed(targetURL)
                let targetSha = targetContent?.sha256Hex

                let entry = manifest.entries[TranslationManifest.key(locale: locale, field: field.name)]
                let decision = decideTranslation(
                    baseSha: baseSha,
                    targetExists: targetContent != nil,
                    targetSha: targetSha,
                    entry: entry,
                    force: force
                )
                items.append(PlanItem(
                    locale: locale,
                    fieldName: field.name,
                    filename: field.filename,
                    maxLength: field.maxLength,
                    decision: decision,
                    sourceLang: baseMapping.source,
                    targetLang: mapping.target,
                    baseText: baseText
                ))
            }
        }

        return TranslationPlan(
            baseLocale: baseLocale,
            items: items,
            unsupportedLocales: unsupported,
            hasBaseContent: baseFields != nil
        )
    }

    // MARK: - Run

    /// Executes a plan: translates the fields that need it, writes the `.txt`
    /// files, and upserts + saves the manifest. With `dryRun` it makes no
    /// network calls and writes nothing.
    package static func run(
        plan: TranslationPlan,
        translator: Translator,
        dir: URL,
        dryRun: Bool,
        now: @escaping () -> Date = { Date() }
    ) async throws -> RunSummary {
        var written: [WrittenField] = []
        var skipped: [SkippedField] = []

        if dryRun {
            for item in plan.items {
                if item.decision.willTranslate {
                    written.append(WrittenField(
                        locale: item.locale,
                        fieldName: item.fieldName,
                        decision: item.decision,
                        charCount: item.baseText?.count ?? 0,
                        maxLength: item.maxLength
                    ))
                } else {
                    skipped.append(SkippedField(locale: item.locale, fieldName: item.fieldName, decision: item.decision))
                }
            }
            return RunSummary(dryRun: true, written: written, skipped: skipped, unsupportedLocales: plan.unsupportedLocales)
        }

        var manifest = TranslationManifest.load(dir: dir)
        manifest.baseLocale = plan.baseLocale

        let iso = ISO8601DateFormatter()
        let timestamp = iso.string(from: now())

        // Group translate-able items by locale so each locale is one DeepL call.
        let byLocale = Dictionary(grouping: plan.items.filter { $0.decision.willTranslate }, by: \.locale)

        for (locale, localeItems) in byLocale.sorted(by: { $0.key < $1.key }) {
            let toTranslate = localeItems.filter { $0.baseText != nil }
            guard !toTranslate.isEmpty else { continue }
            let texts = toTranslate.map { $0.baseText! }
            let source = toTranslate[0].sourceLang
            let target = toTranslate[0].targetLang

            let outputs = try await translator.translate(texts, from: source, to: target)

            let localeDir = dir.appendingPathComponent(locale)
            try FileManager.default.createDirectory(at: localeDir, withIntermediateDirectories: true)

            for (item, raw) in zip(toTranslate, outputs) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let fileURL = localeDir.appendingPathComponent(item.filename)
                try (trimmed + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

                manifest.entries[TranslationManifest.key(locale: locale, field: item.fieldName)] =
                    TranslationManifest.Entry(
                        baseSha256: item.baseText!.sha256Hex,
                        outputSha256: trimmed.sha256Hex,
                        engine: "deepl",
                        sourceLang: source,
                        targetLang: target,
                        translatedAt: timestamp
                    )

                written.append(WrittenField(
                    locale: locale,
                    fieldName: item.fieldName,
                    decision: item.decision,
                    charCount: trimmed.count,
                    maxLength: item.maxLength
                ))
            }
        }

        for item in plan.items where !item.decision.willTranslate {
            skipped.append(SkippedField(locale: item.locale, fieldName: item.fieldName, decision: item.decision))
        }

        try manifest.save(dir: dir)

        return RunSummary(dryRun: false, written: written, skipped: skipped, unsupportedLocales: plan.unsupportedLocales)
    }

    // MARK: - Helpers

    /// Subdirectories of `dir` (locale folders), minus the base locale and
    /// hidden entries. The manifest file (`.translations.json`) is hidden, so
    /// it is excluded automatically.
    package static func inferTargetLocales(dir: URL, excluding base: String) -> [String] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { url -> String? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }
            let name = url.lastPathComponent
            return name == base ? nil : name
        }
    }

    /// Reads a file as UTF-8 and trims surrounding whitespace/newlines, matching
    /// `MetadataReader` so the hash of what we read here equals the hash we store.
    /// Returns nil when the file does not exist.
    private static func readTrimmed(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
