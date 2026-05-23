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
///         privacy_choices_url.txt
///         review_notes.txt
///         review_contact_first_name.txt
///         review_contact_last_name.txt
///         review_contact_phone.txt
///         review_contact_email.txt
///         review_demo_account_name.txt
///         review_demo_account_password.txt
///       ja/
///         ...
///
/// Missing files are treated as "don't change" (nil) when we PATCH the
/// localization; present files replace the current App Store value.
/// Unknown files in a locale directory are skipped with a warning.
///
/// Routing note: `name.txt`, `subtitle.txt`, `privacy_url.txt`, and
/// `privacy_choices_url.txt` live on the `appInfoLocalizations` resource
/// (one per app, not per version). Everything else lives on
/// `appStoreVersionLocalizations` (per version × locale). The orchestrator
/// is responsible for routing each field to the correct endpoint.
///
/// Review-specific files (`review_*.txt`) live under one chosen locale (any
/// locale - they're not actually per-locale on Apple's side) and feed the
/// version-level `appStoreReviewDetails` resource. The first locale that
/// contains any `review_*.txt` file wins; subsequent locales' review files
/// produce a warning.
package enum MetadataReader {

    /// Supported filename -> field mapping. The value names match our
    /// `LocalizationFields` property names.
    package static let supportedFields: [String: WritableKeyPath<LocalizationFields, String?>] = [
        "name.txt":                 \.name,
        "subtitle.txt":             \.subtitle,
        "description.txt":          \.description,
        "keywords.txt":             \.keywords,
        "promotional_text.txt":     \.promotionalText,
        "release_notes.txt":        \.whatsNew,
        "support_url.txt":          \.supportURL,
        "marketing_url.txt":        \.marketingURL,
        "privacy_url.txt":          \.privacyPolicyURL,
        "privacy_choices_url.txt":  \.privacyChoicesURL,
    ]

    /// Filenames that map to `appInfoLocalizations` (app-level, one per app)
    /// rather than `appStoreVersionLocalizations` (per version). The
    /// orchestrator uses this to decide which API endpoint to PATCH.
    package static let appInfoFilenames: Set<String> = [
        "name.txt", "subtitle.txt", "privacy_url.txt", "privacy_choices_url.txt",
    ]

    /// True when `LocalizationFields` carries any field that lives on the
    /// `appInfoLocalizations` resource (name, subtitle, privacyPolicyURL,
    /// privacyChoicesURL). The orchestrator gates editable-appInfo lookup
    /// on this so we don't list appInfos unnecessarily.
    package static func hasAppInfoFields(_ f: LocalizationFields) -> Bool {
        f.name != nil || f.subtitle != nil
            || f.privacyPolicyURL != nil || f.privacyChoicesURL != nil
    }

    /// True when `LocalizationFields` carries any field that lives on the
    /// `appStoreVersionLocalizations` resource (description, keywords,
    /// promotional text, what's new, support URL, marketing URL).
    package static func hasVersionLocalizationFields(_ f: LocalizationFields) -> Bool {
        f.description != nil || f.keywords != nil || f.promotionalText != nil
            || f.whatsNew != nil || f.supportURL != nil || f.marketingURL != nil
    }

    /// Filename -> ReviewDetailFields key path. These feed the version-level
    /// `appStoreReviewDetails` resource (notes Apple's reviewers see plus
    /// developer contact info). They aren't really per-locale on Apple's
    /// side, so the reader collapses them to a single per-version record:
    /// the first locale containing any of these files wins.
    package static let supportedReviewFields: [String: WritableKeyPath<ReviewDetailFields, String?>] = [
        "review_notes.txt":                  \.notes,
        "review_contact_first_name.txt":     \.contactFirstName,
        "review_contact_last_name.txt":      \.contactLastName,
        "review_contact_phone.txt":          \.contactPhone,
        "review_contact_email.txt":          \.contactEmail,
        "review_demo_account_name.txt":      \.demoAccountName,
        "review_demo_account_password.txt":  \.demoAccountPassword,
    ]

    /// Reads every `<locale>/` subdirectory and returns one LocalizationFields
    /// per locale. Locales with no readable files are dropped. Use
    /// `readAll` instead when you also need version-level review-detail
    /// fields (`review_notes.txt` etc.).
    package static func read(
        dir: URL,
        onWarning: (String) -> Void = { _ in }
    ) throws -> [String: LocalizationFields] {
        try readAll(dir: dir, onWarning: onWarning).localizations
    }

    /// Combined return type from `readAll`: per-locale localization fields
    /// plus the (optional) version-level review detail fields. The review
    /// detail is collapsed across locales because Apple's
    /// `appStoreReviewDetails` resource isn't per-locale.
    package struct Read: Sendable {
        package var localizations: [String: LocalizationFields]
        package var reviewDetail: ReviewDetailFields?
        package init(localizations: [String: LocalizationFields], reviewDetail: ReviewDetailFields?) {
            self.localizations = localizations
            self.reviewDetail = reviewDetail
        }
    }

    /// Reads every `<locale>/` subdirectory plus version-level review files.
    /// `review_*.txt` files may live in any locale; the first locale that
    /// contains any of them wins, and subsequent locales' review files emit
    /// a warning.
    package static func readAll(
        dir: URL,
        onWarning: (String) -> Void = { _ in }
    ) throws -> Read {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            throw ReadError.directoryNotFound(path: dir.path)
        }

        let children = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        // Sort locales alphabetically so review-detail "first locale wins"
        // is deterministic across runs.
        let sortedChildren = children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        var result: [String: LocalizationFields] = [:]
        var reviewDetail: ReviewDetailFields?
        var reviewSourceLocale: String?

        for child in sortedChildren {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            let locale = child.lastPathComponent
            var fields = LocalizationFields()
            var touched = false

            let localeContents = (try? fm.contentsOfDirectory(atPath: child.path)) ?? []
            for fileName in localeContents {
                // Skip dotfiles.
                if fileName.hasPrefix(".") { continue }
                if let keyPath = supportedFields[fileName] {
                    let fileURL = child.appendingPathComponent(fileName)
                    let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                    // Trim trailing whitespace + newlines; keep leading intact.
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    fields[keyPath: keyPath] = trimmed
                    touched = true
                } else if let reviewKeyPath = supportedReviewFields[fileName] {
                    if let already = reviewSourceLocale, already != locale {
                        onWarning("[\(locale)] ignoring \(fileName) - review fields already taken from [\(already)]/. Move all review_*.txt files into one locale to silence this warning.")
                        continue
                    }
                    let fileURL = child.appendingPathComponent(fileName)
                    let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if reviewDetail == nil { reviewDetail = ReviewDetailFields() }
                    reviewDetail?[keyPath: reviewKeyPath] = trimmed
                    reviewSourceLocale = locale
                } else {
                    onWarning("[\(locale)] unknown metadata file: \(fileName)")
                }
            }

            if touched {
                result[locale] = fields
            }
        }

        return Read(localizations: result, reviewDetail: reviewDetail)
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

/// Values pulled from a `metadata/<locale>/` directory for one locale.
/// These are split between two App Store Connect resources at PATCH time:
///
/// - `appStoreVersionLocalizations` (per version × locale):
///   description, keywords, promotionalText, whatsNew, supportURL,
///   marketingURL.
/// - `appInfoLocalizations` (per app × locale):
///   name, subtitle, privacyPolicyURL, privacyChoicesURL.
///
/// Any field left nil means "don't touch" - only non-nil fields are sent in
/// the PATCH that owns that field.
package struct LocalizationFields: Sendable, Equatable {
    /// App name. Lives on `appInfoLocalizations.name`. Read from `name.txt`.
    package var name: String?
    /// Subtitle. Lives on `appInfoLocalizations.subtitle`. Read from
    /// `subtitle.txt`.
    package var subtitle: String?
    package var description: String?
    package var keywords: String?
    package var promotionalText: String?
    package var whatsNew: String?
    package var supportURL: String?
    package var marketingURL: String?
    /// Privacy policy URL. Lives on
    /// `appInfoLocalizations.privacyPolicyUrl` (not the version
    /// localization). Read from `privacy_url.txt`.
    package var privacyPolicyURL: String?
    /// Privacy choices URL (CCPA "do not sell my data" landing page). Lives
    /// on `appInfoLocalizations.privacyChoicesUrl`. Read from
    /// `privacy_choices_url.txt`.
    package var privacyChoicesURL: String?

    package init(
        name: String? = nil,
        subtitle: String? = nil,
        description: String? = nil,
        keywords: String? = nil,
        promotionalText: String? = nil,
        whatsNew: String? = nil,
        supportURL: String? = nil,
        marketingURL: String? = nil,
        privacyPolicyURL: String? = nil,
        privacyChoicesURL: String? = nil
    ) {
        self.name = name
        self.subtitle = subtitle
        self.description = description
        self.keywords = keywords
        self.promotionalText = promotionalText
        self.whatsNew = whatsNew
        self.supportURL = supportURL
        self.marketingURL = marketingURL
        self.privacyPolicyURL = privacyPolicyURL
        self.privacyChoicesURL = privacyChoicesURL
    }

    /// True when at least one field is present.
    package var hasAnyField: Bool {
        [name, subtitle, description, keywords, promotionalText, whatsNew,
         supportURL, marketingURL, privacyPolicyURL, privacyChoicesURL]
            .contains(where: { $0 != nil })
    }
}

/// Values for one App Store Connect `appStoreReviewDetails` resource. The
/// resource is per-version, not per-locale - it carries the free-form
/// review notes Apple's reviewers see plus the contact info and demo
/// account. Any field left nil means "don't touch" - only non-nil fields
/// are sent in the PATCH.
package struct ReviewDetailFields: Sendable, Equatable {
    package var contactFirstName: String?
    package var contactLastName: String?
    package var contactPhone: String?
    package var contactEmail: String?
    package var demoAccountName: String?
    package var demoAccountPassword: String?
    /// Whether Apple needs a demo login. Defaults to nil (untouched). When a
    /// demo account name + password are provided we set this to true via the
    /// orchestrator; explicit yml support is not exposed yet.
    package var demoAccountRequired: Bool?
    package var notes: String?

    package init(
        contactFirstName: String? = nil,
        contactLastName: String? = nil,
        contactPhone: String? = nil,
        contactEmail: String? = nil,
        demoAccountName: String? = nil,
        demoAccountPassword: String? = nil,
        demoAccountRequired: Bool? = nil,
        notes: String? = nil
    ) {
        self.contactFirstName = contactFirstName
        self.contactLastName = contactLastName
        self.contactPhone = contactPhone
        self.contactEmail = contactEmail
        self.demoAccountName = demoAccountName
        self.demoAccountPassword = demoAccountPassword
        self.demoAccountRequired = demoAccountRequired
        self.notes = notes
    }

    package var hasAnyField: Bool {
        contactFirstName != nil || contactLastName != nil
            || contactPhone != nil || contactEmail != nil
            || demoAccountName != nil || demoAccountPassword != nil
            || demoAccountRequired != nil || notes != nil
    }
}
