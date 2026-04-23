import Foundation

/// Reads per-locale App Store metadata from a fastlane-style directory:
///
///     metadata/
///       en-US/
///         name.txt
///         subtitle.txt
///         description.txt
///         keywords.txt
///         promotional_text.txt
///         release_notes.txt
///         support_url.txt
///         marketing_url.txt
///         privacy_url.txt
///       ja/
///         ...
///
/// Missing files are treated as "don't change" (nil) when we PATCH the
/// localization; present files replace the current App Store value.
/// Unknown files in a locale directory are skipped with a warning.
package enum MetadataReader {

    /// Supported filename -> field mapping. The value names match our
    /// `LocalizationFields` property names.
    package static let supportedFields: [String: WritableKeyPath<LocalizationFields, String?>] = [
        "name.txt":              \.name,
        "subtitle.txt":          \.subtitle,
        "description.txt":       \.description,
        "keywords.txt":          \.keywords,
        "promotional_text.txt":  \.promotionalText,
        "release_notes.txt":     \.whatsNew,
        "support_url.txt":       \.supportURL,
        "marketing_url.txt":     \.marketingURL,
    ]

    /// Reads every `<locale>/` subdirectory and returns one LocalizationFields
    /// per locale. Locales with no readable files are dropped.
    package static func read(
        dir: URL,
        onWarning: (String) -> Void = { _ in }
    ) throws -> [String: LocalizationFields] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            throw ReadError.directoryNotFound(path: dir.path)
        }

        let children = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var result: [String: LocalizationFields] = [:]
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            let locale = child.lastPathComponent
            var fields = LocalizationFields()
            var touched = false

            let localeContents = (try? fm.contentsOfDirectory(atPath: child.path)) ?? []
            for fileName in localeContents {
                // Skip dotfiles.
                if fileName.hasPrefix(".") { continue }
                guard let keyPath = supportedFields[fileName] else {
                    onWarning("[\(locale)] unknown metadata file: \(fileName)")
                    continue
                }
                let fileURL = child.appendingPathComponent(fileName)
                let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                // Trim trailing whitespace + newlines; keep leading intact.
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                fields[keyPath: keyPath] = trimmed
                touched = true
            }

            if touched {
                result[locale] = fields
            }
        }

        return result
    }

    package enum ReadError: Error, CustomStringConvertible {
        case directoryNotFound(path: String)

        package var description: String {
            switch self {
            case .directoryNotFound(let p): return "metadata directory not found: \(p)"
            }
        }
    }
}

/// Values for one App Store Connect version localization. Any field left
/// nil means "don't touch" — only non-nil fields are sent in the PATCH.
package struct LocalizationFields: Sendable, Equatable {
    package var name: String?
    package var subtitle: String?
    package var description: String?
    package var keywords: String?
    package var promotionalText: String?
    package var whatsNew: String?
    package var supportURL: String?
    package var marketingURL: String?

    package init(
        name: String? = nil,
        subtitle: String? = nil,
        description: String? = nil,
        keywords: String? = nil,
        promotionalText: String? = nil,
        whatsNew: String? = nil,
        supportURL: String? = nil,
        marketingURL: String? = nil
    ) {
        self.name = name
        self.subtitle = subtitle
        self.description = description
        self.keywords = keywords
        self.promotionalText = promotionalText
        self.whatsNew = whatsNew
        self.supportURL = supportURL
        self.marketingURL = marketingURL
    }

    /// True when at least one field is present.
    package var hasAnyField: Bool {
        [name, subtitle, description, keywords, promotionalText, whatsNew, supportURL, marketingURL]
            .contains(where: { $0 != nil })
    }
}
