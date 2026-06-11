import Foundation

/// One metadata field the translator is allowed to touch. Maps a metadata
/// filename (`description.txt`) to the `LocalizationFields` property the base
/// text is read from and the App Store Connect length limit used for
/// over-length warnings. URL fields (`support_url.txt`, ...) and the
/// `review_*` contact files are intentionally absent: translating them is
/// never wanted.
package struct TranslatableField {
    /// Filename on disk, e.g. "description.txt".
    package let filename: String
    /// Bare field name used in the manifest key and CLI `--fields`, e.g. "description".
    package let name: String
    /// Where to read the base-locale value from a `LocalizationFields`.
    package let keyPath: KeyPath<LocalizationFields, String?>
    /// ASC max length, for a post-translation length warning (nil = no limit).
    package let maxLength: Int?

    package init(
        filename: String,
        name: String,
        keyPath: KeyPath<LocalizationFields, String?>,
        maxLength: Int?
    ) {
        self.filename = filename
        self.name = name
        self.keyPath = keyPath
        self.maxLength = maxLength
    }
}

package enum TranslatableFields {

    /// Every field the translator can handle, in display order. The default
    /// `translate run` set is all of these. URLs and review/contact fields are
    /// deliberately excluded.
    package static let all: [TranslatableField] = [
        TranslatableField(filename: "name.txt",             name: "name",             keyPath: \.name,            maxLength: 30),
        TranslatableField(filename: "subtitle.txt",         name: "subtitle",         keyPath: \.subtitle,        maxLength: 30),
        TranslatableField(filename: "description.txt",      name: "description",      keyPath: \.description,     maxLength: 4000),
        TranslatableField(filename: "promotional_text.txt", name: "promotional_text", keyPath: \.promotionalText, maxLength: 170),
        TranslatableField(filename: "release_notes.txt",    name: "release_notes",    keyPath: \.whatsNew,        maxLength: 4000),
        TranslatableField(filename: "keywords.txt",         name: "keywords",         keyPath: \.keywords,        maxLength: 100),
    ]

    /// Default set of field names translated when `--fields` is not given.
    package static let defaultNames: [String] = all.map(\.name)

    /// Resolve a user-supplied token to a field. Accepts either the bare name
    /// ("description") or the filename ("description.txt").
    package static func field(for token: String) -> TranslatableField? {
        let t = token.lowercased()
        return all.first { $0.name == t || $0.filename == t }
    }
}
