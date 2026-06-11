import Foundation

/// Sidecar that records what the translator generated, so a later run can tell
/// a stale machine translation (base text moved) from one a human refined
/// (on-disk text no longer matches the recorded machine output). Lives at
/// `metadata/.translations.json`. `MetadataReader` skips non-directory and
/// hidden entries, so it is never mistaken for a locale. Commit it to git so
/// the staleness signal survives across machines and collaborators.
package struct TranslationManifest: Codable, Sendable {

    package var schema: Int
    package var baseLocale: String?
    /// Keyed by "<locale>/<field>", e.g. "de-DE/description".
    package var entries: [String: Entry]

    package struct Entry: Codable, Sendable, Equatable {
        /// SHA-256 of the base-locale source text this translation was made from.
        package var baseSha256: String
        /// SHA-256 of the machine output we wrote. If the on-disk file no longer
        /// hashes to this, a human edited it (the "reviewed" signal).
        package var outputSha256: String
        package var engine: String
        package var sourceLang: String
        package var targetLang: String
        package var translatedAt: String

        package init(
            baseSha256: String,
            outputSha256: String,
            engine: String,
            sourceLang: String,
            targetLang: String,
            translatedAt: String
        ) {
            self.baseSha256 = baseSha256
            self.outputSha256 = outputSha256
            self.engine = engine
            self.sourceLang = sourceLang
            self.targetLang = targetLang
            self.translatedAt = translatedAt
        }

        enum CodingKeys: String, CodingKey {
            case baseSha256 = "base_sha256"
            case outputSha256 = "output_sha256"
            case engine
            case sourceLang = "source_lang"
            case targetLang = "target_lang"
            case translatedAt = "translated_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case baseLocale = "base_locale"
        case entries
    }

    package init(schema: Int = 1, baseLocale: String? = nil, entries: [String: Entry] = [:]) {
        self.schema = schema
        self.baseLocale = baseLocale
        self.entries = entries
    }

    /// Filename at the metadata root.
    package static let filename = ".translations.json"

    package static func key(locale: String, field: String) -> String {
        "\(locale)/\(field)"
    }

    /// Loads the manifest from `dir/.translations.json`, returning an empty
    /// manifest if it is absent or unreadable (a corrupt file should not block
    /// a run; the next save rewrites it).
    package static func load(dir: URL) -> TranslationManifest {
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(TranslationManifest.self, from: data)
        else {
            return TranslationManifest()
        }
        return manifest
    }

    /// Writes the manifest to `dir/.translations.json` with stable, pretty,
    /// sorted-key JSON so it diffs cleanly in pull requests.
    package func save(dir: URL) throws {
        let url = dir.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
