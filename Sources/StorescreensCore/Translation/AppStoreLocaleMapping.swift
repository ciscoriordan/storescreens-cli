import Foundation

/// Maps App Store Connect locale codes (en-US, de-DE, zh-Hans, ...) to DeepL
/// language codes. DeepL distinguishes a coarse SOURCE language (EN, PT, ZH)
/// from a finer TARGET language (EN-US, EN-GB, PT-BR, PT-PT, ZH-HANS, ZH-HANT),
/// so each App Store locale carries both: `source` for when it is the base
/// locale we translate FROM, `target` for when it is a locale we translate TO.
///
/// Locales DeepL cannot translate (Hindi, Thai, Vietnamese, Malay, Catalan,
/// Croatian, Hebrew, ...) are absent from the table; `deepL(for:)` returns nil
/// and the orchestrator skips them with a warning rather than failing the run.
package enum AppStoreLocaleMapping {

    package struct Lang: Sendable, Equatable {
        /// DeepL source code (region-less), e.g. "EN", "PT", "ZH".
        package let source: String
        /// DeepL target code (may carry a region), e.g. "EN-US", "PT-BR", "ZH-HANS".
        package let target: String
    }

    /// Lookup keyed by the lowercased App Store locale code. Several App Store
    /// locales with no DeepL regional variant fall back to the nearest target
    /// (e.g. en-AU/en-CA -> EN-GB, fr-CA -> FR, es-MX -> ES); this is a coarse
    /// approximation the user is expected to review.
    private static let table: [String: Lang] = [
        "en-us":   Lang(source: "EN", target: "EN-US"),
        "en-gb":   Lang(source: "EN", target: "EN-GB"),
        "en-au":   Lang(source: "EN", target: "EN-GB"),
        "en-ca":   Lang(source: "EN", target: "EN-GB"),
        "de-de":   Lang(source: "DE", target: "DE"),
        "fr-fr":   Lang(source: "FR", target: "FR"),
        "fr-ca":   Lang(source: "FR", target: "FR"),
        "es-es":   Lang(source: "ES", target: "ES"),
        "es-mx":   Lang(source: "ES", target: "ES"),
        "es-419":  Lang(source: "ES", target: "ES"),
        "it":      Lang(source: "IT", target: "IT"),
        "pt-br":   Lang(source: "PT", target: "PT-BR"),
        "pt-pt":   Lang(source: "PT", target: "PT-PT"),
        "nl-nl":   Lang(source: "NL", target: "NL"),
        "ja":      Lang(source: "JA", target: "JA"),
        "ko":      Lang(source: "KO", target: "KO"),
        "zh-hans": Lang(source: "ZH", target: "ZH-HANS"),
        "zh-hant": Lang(source: "ZH", target: "ZH-HANT"),
        "ru":      Lang(source: "RU", target: "RU"),
        "uk":      Lang(source: "UK", target: "UK"),
        "pl":      Lang(source: "PL", target: "PL"),
        "tr":      Lang(source: "TR", target: "TR"),
        "sv":      Lang(source: "SV", target: "SV"),
        "da":      Lang(source: "DA", target: "DA"),
        "fi":      Lang(source: "FI", target: "FI"),
        "no":      Lang(source: "NB", target: "NB"),
        "nb":      Lang(source: "NB", target: "NB"),
        "el":      Lang(source: "EL", target: "EL"),
        "cs":      Lang(source: "CS", target: "CS"),
        "sk":      Lang(source: "SK", target: "SK"),
        "sl":      Lang(source: "SL", target: "SL"),
        "ro":      Lang(source: "RO", target: "RO"),
        "hu":      Lang(source: "HU", target: "HU"),
        "bg":      Lang(source: "BG", target: "BG"),
        "id":      Lang(source: "ID", target: "ID"),
        "ar":      Lang(source: "AR", target: "AR"),
        "lt":      Lang(source: "LT", target: "LT"),
        "lv":      Lang(source: "LV", target: "LV"),
        "et":      Lang(source: "ET", target: "ET"),
    ]

    /// DeepL language pair for an App Store locale, or nil when DeepL does not
    /// support that language.
    package static func deepL(for ascLocale: String) -> Lang? {
        table[ascLocale.lowercased()]
    }

    /// True when DeepL can translate the given App Store locale.
    package static func isSupported(_ ascLocale: String) -> Bool {
        table[ascLocale.lowercased()] != nil
    }
}
