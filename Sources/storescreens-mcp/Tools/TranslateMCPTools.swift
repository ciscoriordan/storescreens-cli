import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for the bring-your-own-DeepL metadata translator. Mirrors
/// `storescreens translate run` / `translate status` so an agent can seed and
/// inspect per-locale metadata translations without shelling out.
///
/// The overwrite policy is the same one the CLI uses, tracked in
/// `metadata/.translations.json`: a machine translation is re-generated when
/// the base text changes, but one a human/agent edited is preserved. Tools
/// resolve the DeepL key via `DeepLCredentialResolver.resolve()` (env
/// `DEEPL_API_KEY` or `~/.storescreens/deepl-credentials.yml`) and return
/// pretty JSON, `isError: true` on failure. Names use the `translate_` prefix
/// so `Main.swift` routes them here.
package enum TranslateMCPTools {

    // MARK: - Catalog

    package static let tools: [Tool] = [
        Tool(
            name: "translate_run",
            description: """
            Translate base-locale App Store metadata into target locales with \
            DeepL, writing one .txt per field per locale. Only fields that need \
            it are (re)translated: a never-translated field, or a machine \
            translation whose base text changed. Translations a human or agent \
            edited are preserved (editing a file is the "reviewed" signal) \
            unless force=true. URLs and review/contact fields are never \
            translated. Output is raw machine translation and should get a QA \
            pass before submit. Requires a DeepL key (env DEEPL_API_KEY or the \
            stored credentials file). Use dry_run=true to preview decisions \
            without translating.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "dir": .object([
                        "type": .string("string"),
                        "description": .string("Metadata directory (default: metadata)."),
                    ]),
                    "from": .object([
                        "type": .string("string"),
                        "description": .string("Base locale to translate FROM (default: en-US)."),
                    ]),
                    "to": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Target locales. Default: every locale folder in dir except the base."),
                    ]),
                    "fields": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Fields to translate. Default: name, subtitle, description, promotional_text, release_notes, keywords."),
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("Re-translate every field, overwriting edited/reviewed translations. Default false."),
                    ]),
                    "dry_run": .object([
                        "type": .string("boolean"),
                        "description": .string("Preview decisions without calling DeepL or writing files. Default false."),
                    ]),
                    "formality": .object([
                        "type": .string("string"),
                        "description": .string("DeepL formality: more, less, prefer_more, prefer_less (ignored by unsupported languages)."),
                    ]),
                ]),
                "required": .array([]),
            ])
        ),
        Tool(
            name: "translate_status",
            description: """
            Report per-locale, per-field translation state without translating: \
            which fields are missing, raw machine output (needs review), \
            reviewed (edited), stale (base text moved), hand-authored, or have \
            no base text. Use this to see what still needs a human/agent QA \
            pass before submit.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "dir": .object([
                        "type": .string("string"),
                        "description": .string("Metadata directory (default: metadata)."),
                    ]),
                    "from": .object([
                        "type": .string("string"),
                        "description": .string("Base locale (default: en-US)."),
                    ]),
                    "to": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Target locales. Default: every locale folder in dir except the base."),
                    ]),
                    "fields": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Fields to inspect. Default: the standard translatable set."),
                    ]),
                ]),
                "required": .array([]),
            ])
        ),
    ]

    // MARK: - Dispatch

    package static func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        switch params.name {
        case "translate_run":    return await handleRun(params)
        case "translate_status": return await handleStatus(params)
        default:                 return errorResult("unknown translate tool: \(params.name)")
        }
    }

    // MARK: - run

    private static func handleRun(_ params: CallTool.Parameters) async -> CallTool.Result {
        let dir = params.arguments?["dir"]?.stringValue ?? "metadata"
        let from = params.arguments?["from"]?.stringValue ?? "en-US"
        let to = stringArray(params, "to")
        let fields = stringArray(params, "fields")
        let force = params.arguments?["force"]?.boolValue ?? false
        let dryRun = params.arguments?["dry_run"]?.boolValue ?? false
        let formality = params.arguments?["formality"]?.stringValue

        let dirURL = URL(fileURLWithPath: dir)
        let fieldNames = fields.isEmpty ? TranslatableFields.defaultNames : fields

        // Translator (and therefore credentials) only needed for live runs.
        let translator: Translator
        if dryRun {
            translator = NoopTranslator()
        } else {
            do {
                let creds = try DeepLCredentialResolver.resolve()
                translator = DeepLClient(credentials: creds, formality: formality)
            } catch {
                return errorResult("\(error)")
            }
        }

        do {
            let plan = try TranslationOrchestrator.plan(
                dir: dirURL, baseLocale: from, targetLocales: to.isEmpty ? nil : to,
                fieldNames: fieldNames, force: force
            )
            guard plan.hasBaseContent else {
                return errorResult("no metadata found for base locale '\(from)' in \(dir)/")
            }
            let summary = try await TranslationOrchestrator.run(
                plan: plan, translator: translator, dir: dirURL, dryRun: dryRun
            )
            return jsonResult(RunJSON(summary, baseLocale: from))
        } catch {
            return errorResult("translate_run failed: \(error)")
        }
    }

    // MARK: - status

    private static func handleStatus(_ params: CallTool.Parameters) async -> CallTool.Result {
        let dir = params.arguments?["dir"]?.stringValue ?? "metadata"
        let from = params.arguments?["from"]?.stringValue ?? "en-US"
        let to = stringArray(params, "to")
        let fields = stringArray(params, "fields")
        let fieldNames = fields.isEmpty ? TranslatableFields.defaultNames : fields

        do {
            let plan = try TranslationOrchestrator.plan(
                dir: URL(fileURLWithPath: dir), baseLocale: from,
                targetLocales: to.isEmpty ? nil : to, fieldNames: fieldNames, force: false
            )
            guard plan.hasBaseContent else {
                return errorResult("no metadata found for base locale '\(from)' in \(dir)/")
            }
            return jsonResult(StatusJSON(plan))
        } catch {
            return errorResult("translate_status failed: \(error)")
        }
    }

    // MARK: - JSON shapes

    private struct RunJSON: Encodable {
        let dryRun: Bool
        let baseLocale: String
        let translated: [FieldJSON]
        let skipped: [SkipJSON]
        let unsupportedLocales: [String]
        let note: String

        init(_ s: RunSummary, baseLocale: String) {
            self.dryRun = s.dryRun
            self.baseLocale = baseLocale
            self.translated = s.written.map(FieldJSON.init)
            self.skipped = s.skipped.map(SkipJSON.init)
            self.unsupportedLocales = s.unsupportedLocales
            self.note = s.dryRun
                ? "Dry run - no files written. Remove dry_run to translate."
                : (s.written.isEmpty
                    ? "Nothing translated; every target field was up to date."
                    : "Raw DeepL output written. QA each locale (brand names, tone, ASO keywords, length) before submit; editing a file marks it reviewed.")
        }
    }

    private struct FieldJSON: Encodable {
        let locale: String
        let field: String
        let decision: String
        let chars: Int
        let maxLength: Int?
        let overLength: Bool
        init(_ w: WrittenField) {
            self.locale = w.locale
            self.field = w.fieldName
            self.decision = w.decision.rawValue
            self.chars = w.charCount
            self.maxLength = w.maxLength
            self.overLength = w.overLength
        }
    }

    private struct SkipJSON: Encodable {
        let locale: String
        let field: String
        let reason: String
        init(_ s: SkippedField) {
            self.locale = s.locale
            self.field = s.fieldName
            self.reason = s.decision.rawValue
        }
    }

    private struct StatusJSON: Encodable {
        let baseLocale: String
        let items: [ItemJSON]
        let unsupportedLocales: [String]
        init(_ plan: TranslationPlan) {
            self.baseLocale = plan.baseLocale
            self.items = plan.items.map(ItemJSON.init)
            self.unsupportedLocales = plan.unsupportedLocales
        }
    }

    private struct ItemJSON: Encodable {
        let locale: String
        let field: String
        let state: String
        init(_ item: PlanItem) {
            self.locale = item.locale
            self.field = item.fieldName
            self.state = item.decision.rawValue
        }
    }

    // MARK: - Helpers

    private struct NoopTranslator: Translator {
        func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] { texts }
    }

    private static func stringArray(_ params: CallTool.Parameters, _ key: String) -> [String] {
        guard let arr = params.arguments?[key]?.arrayValue else { return [] }
        return arr.compactMap { $0.stringValue }
    }

    private static func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text)], isError: false)
        } catch {
            return errorResult("could not encode response JSON: \(error)")
        }
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(message)], isError: true)
    }
}
