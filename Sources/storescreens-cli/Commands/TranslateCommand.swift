import ArgumentParser
import Foundation
import StorescreensCore

struct TranslateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "translate",
        abstract: "Translate per-locale metadata with your own DeepL API key.",
        discussion: """
            Seeds non-base metadata locales from your base locale using DeepL. \
            Bring your own key: set DEEPL_API_KEY (free tier works) or run \
            `storescreens translate auth login`.

            Overwrite policy is tracked in metadata/.translations.json: a machine \
            translation is re-generated when the base text changes, but a \
            translation you (or a coding agent) edited is left alone - editing a \
            file is the "reviewed" signal. DeepL output is a starting point, not \
            ship-ready: always do a QA pass before `submit`. `translate status` \
            shows what is still raw machine output.
            """,
        subcommands: [
            TranslateRunCommand.self,
            TranslateStatusCommand.self,
            TranslateAuthCommand.self,
        ],
        defaultSubcommand: TranslateRunCommand.self
    )
}

// MARK: - shared options

/// Options shared by `run` and `status` for locating + scoping the metadata.
struct TranslateScopeOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Metadata directory (default: ./metadata).")
    var dir: String = "metadata"

    @Option(name: [.customLong("from"), .customLong("base")], help: "Base locale to translate FROM (default: en-US).")
    var from: String = "en-US"

    @Option(
        name: [.customShort("t"), .customLong("to")],
        parsing: .upToNextOption,
        help: "Target locales to translate TO. Default: every locale folder in --dir except the base."
    )
    var to: [String] = []

    @Option(
        name: .customLong("fields"),
        parsing: .upToNextOption,
        help: "Fields to translate. Default: \(TranslatableFields.defaultNames.joined(separator: ", ")). URLs and review/contact fields are never translated."
    )
    var fields: [String] = []

    var dirURL: URL { URL(fileURLWithPath: dir) }
    var targetLocales: [String]? { to.isEmpty ? nil : to }
    var fieldNames: [String] { fields.isEmpty ? TranslatableFields.defaultNames : fields }
}

// MARK: - run

struct TranslateRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Translate the base locale into the target locales (re-translating only stale fields)."
    )

    @OptionGroup var scope: TranslateScopeOptions

    @Flag(name: .long, help: "Re-translate every field, overwriting edited/reviewed translations too.")
    var force: Bool = false

    @Flag(name: .long, help: "Show what would be translated without calling DeepL or writing files.")
    var dryRun: Bool = false

    @Option(name: .long, help: "DeepL formality: more, less, prefer_more, prefer_less (ignored by unsupported languages).")
    var formality: String?

    @Option(name: .long, help: "DeepL API key (otherwise DEEPL_API_KEY or the stored credentials file).")
    var apiKey: String?

    func run() async throws {
        let logger = Logger()

        // Resolve credentials (skip for dry runs - they never hit the network).
        var credentials: DeepLCredentials?
        if !dryRun {
            if let apiKey, !apiKey.isEmpty {
                credentials = DeepLCredentials(apiKey: apiKey, source: .environment)
            } else {
                do {
                    credentials = try DeepLCredentialResolver.resolve()
                } catch {
                    logger.log("\(error)", level: .error)
                    throw ExitCode(1)
                }
            }
        }

        logger.header(dryRun ? "DeepL translation (dry run)" : "DeepL translation")

        let plan: TranslationPlan
        do {
            plan = try TranslationOrchestrator.plan(
                dir: scope.dirURL,
                baseLocale: scope.from,
                targetLocales: scope.targetLocales,
                fieldNames: scope.fieldNames,
                force: force,
                onWarning: { logger.log($0, level: .warning) }
            )
        } catch let e as MetadataReader.ReadError {
            logger.log("\(e)", level: .error)
            print("  scaffold metadata with `storescreens metadata init`.")
            throw ExitCode(1)
        } catch {
            logger.log("\(error)", level: .error)
            throw ExitCode(1)
        }

        guard plan.hasBaseContent else {
            logger.log("no metadata found for base locale '\(scope.from)' in \(scope.dir)/", level: .error)
            print("  add .txt files under \(scope.dir)/\(scope.from)/, then re-run.")
            throw ExitCode(1)
        }

        let translator: Translator = dryRun
            ? NoopTranslator()
            : DeepLClient(credentials: credentials!, formality: formality)

        let summary = try await TranslationOrchestrator.run(
            plan: plan, translator: translator, dir: scope.dirURL, dryRun: dryRun
        )

        render(summary: summary, logger: logger, dryRun: dryRun)
    }

    private func render(summary: RunSummary, logger: Logger, dryRun: Bool) {
        if !summary.unsupportedLocales.isEmpty {
            logger.log("DeepL has no language for: \(summary.unsupportedLocales.joined(separator: ", ")) - skipped", level: .warning)
        }

        let writtenByLocale = Dictionary(grouping: summary.written, by: \.locale)
        if writtenByLocale.isEmpty {
            logger.log("nothing to translate - every target field is up to date", level: .info)
        } else {
            for (locale, fields) in writtenByLocale.sorted(by: { $0.key < $1.key }) {
                let names = fields.map(\.fieldName).sorted().joined(separator: ", ")
                logger.log("\(locale): \(dryRun ? "would translate" : "translated") \(names)", level: .success)
            }
        }

        // Length warnings (real runs only - dry-run char counts are source-text estimates).
        if !dryRun {
            for w in summary.written where w.overLength {
                logger.log("\(w.locale)/\(w.fieldName) is \(w.charCount) chars, over the ASC limit of \(w.maxLength ?? 0) - trim before submit", level: .warning)
            }
        }

        // Stale edits the user may want to refresh.
        let staleEdited = summary.skipped.filter { $0.decision == .skipStaleEdited }
        for s in staleEdited {
            logger.log("\(s.locale)/\(s.fieldName): edited locally but the base text changed - may be outdated (--force to overwrite)", level: .warning)
        }

        let upToDate = summary.skipped.filter { $0.decision == .skipUpToDate }.count
        let reviewed = summary.skipped.filter { $0.decision == .skipReviewed }.count
        let preexisting = summary.skipped.filter { $0.decision == .skipPreexisting }.count
        print("")
        print("  \(summary.written.count) \(dryRun ? "to translate" : "translated") · \(upToDate) up-to-date · \(reviewed) reviewed · \(staleEdited.count) stale-edited · \(preexisting) hand-authored")

        if !dryRun && !summary.written.isEmpty {
            print("")
            logger.log("These are raw DeepL translations - have a coding agent QA-pass them before submit.", level: .warning)
            print("  - Check brand names, tone, ASO keywords, and length against each language.")
            print("  - Editing a file marks it reviewed; `storescreens translate status` lists what is still raw.")
            print("  - Re-run `storescreens translate` after changing base copy to refresh only the stale locales.")
        }
    }
}

/// Stand-in translator used for dry runs; never called because `run` short-
/// circuits the network path when `dryRun` is set.
private struct NoopTranslator: Translator {
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] { texts }
}

// MARK: - status

struct TranslateStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show per-locale, per-field translation state (what is missing, raw, reviewed, or stale)."
    )

    @OptionGroup var scope: TranslateScopeOptions

    func run() async throws {
        let logger = Logger()
        logger.header("Translation status (base \(scope.from))")

        let plan: TranslationPlan
        do {
            plan = try TranslationOrchestrator.plan(
                dir: scope.dirURL,
                baseLocale: scope.from,
                targetLocales: scope.targetLocales,
                fieldNames: scope.fieldNames,
                force: false,
                onWarning: { logger.log($0, level: .warning) }
            )
        } catch let e as MetadataReader.ReadError {
            logger.log("\(e)", level: .error)
            throw ExitCode(1)
        } catch {
            logger.log("\(error)", level: .error)
            throw ExitCode(1)
        }

        guard plan.hasBaseContent else {
            logger.log("no metadata found for base locale '\(scope.from)' in \(scope.dir)/", level: .error)
            throw ExitCode(1)
        }

        if !plan.unsupportedLocales.isEmpty {
            logger.log("unsupported by DeepL (skipped): \(plan.unsupportedLocales.joined(separator: ", "))", level: .warning)
        }

        let byLocale = Dictionary(grouping: plan.items, by: \.locale)
        if byLocale.isEmpty {
            logger.log("no target locales found in \(scope.dir)/ (besides the base)", level: .info)
            return
        }

        let pad = (plan.items.map { $0.fieldName.count }.max() ?? 0) + 2
        for (locale, items) in byLocale.sorted(by: { $0.key < $1.key }) {
            print("\n  \(locale)")
            for item in items.sorted(by: { $0.fieldName < $1.fieldName }) {
                let name = item.fieldName.padding(toLength: pad, withPad: " ", startingAt: 0)
                print("    \(name)\(stateLabel(item.decision))")
            }
        }

        // Footer: what still needs an agent pass.
        let needsReview = plan.items.filter { $0.decision == .skipUpToDate }.count
        let missing = plan.items.filter { $0.decision == .translateNew }.count
        let stale = plan.items.filter { $0.decision == .retranslateStaleBase || $0.decision == .skipStaleEdited }.count
        let reviewed = plan.items.filter { $0.decision == .skipReviewed }.count
        print("")
        print("  \(missing) missing · \(stale) stale · \(needsReview) raw (needs review) · \(reviewed) reviewed")
        if needsReview > 0 || stale > 0 || missing > 0 {
            print("  run `storescreens translate` to fill missing + refresh stale, then QA the raw ones.")
        }
    }

    private func stateLabel(_ d: TranslationDecision) -> String {
        switch d {
        case .translateNew:          return "missing"
        case .retranslateStaleBase:  return "stale (base changed)"
        case .skipUpToDate:          return "raw machine (needs review)"
        case .skipReviewed:          return "reviewed"
        case .skipStaleEdited:       return "edited, base changed (stale)"
        case .skipPreexisting:       return "hand-authored"
        case .skipNoBase:            return "no base text"
        case .forced:                return "forced"
        }
    }
}

// MARK: - auth

struct TranslateAuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage the DeepL API key.",
        discussion: """
            Resolved env-first: DEEPL_API_KEY (or DEEPL_AUTH_KEY), then the file \
            at ~/.storescreens/deepl-credentials.yml. Free-tier keys carry a \
            `:fx` suffix and route to api-free.deepl.com automatically.
            """,
        subcommands: [
            TranslateAuthLoginCommand.self,
            TranslateAuthLogoutCommand.self,
            TranslateAuthStatusCommand.self,
        ],
        defaultSubcommand: TranslateAuthStatusCommand.self
    )
}

struct TranslateAuthLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Prompt for a DeepL API key, verify it, and save it."
    )

    @Option(name: .long, help: "DeepL API key (otherwise prompted).")
    var apiKey: String?

    func run() async throws {
        let logger = Logger()
        let key = (apiKey ?? prompt("DeepL API key: ")).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            logger.log("no key provided", level: .error)
            throw ExitCode(1)
        }

        // Verify against /v2/usage before persisting.
        let creds = DeepLCredentials(apiKey: key, source: .file)
        do {
            let usage = try await DeepLClient(credentials: creds).usage()
            logger.log("key valid (\(creds.isFreeTier ? "free" : "pro") tier, \(usage.characterCount)/\(usage.characterLimit) chars used)", level: .success)
        } catch {
            logger.log("key check failed: \(error)", level: .error)
            throw ExitCode(1)
        }

        try DeepLCredentialResolver.write(apiKey: key)
        logger.log("saved to \(DeepLCredentialResolver.defaultFilePath) (perms 0600)", level: .success)
    }

    private func prompt(_ label: String) -> String {
        print(label, terminator: "")
        return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

struct TranslateAuthLogoutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Delete the stored DeepL credentials file."
    )

    func run() async throws {
        let logger = Logger()
        let path = DeepLCredentialResolver.defaultFilePath
        if FileManager.default.fileExists(atPath: path) {
            try DeepLCredentialResolver.deleteStoredFile()
            logger.log("deleted \(path)", level: .success)
        } else {
            logger.log("no stored DeepL credentials to delete", level: .info)
        }
        print("  (DEEPL_API_KEY / DEEPL_AUTH_KEY env vars are independent and unaffected.)")
    }
}

struct TranslateAuthStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether a DeepL key is configured and verify it."
    )

    func run() async throws {
        let logger = Logger()
        logger.header("DeepL credentials")

        if !DeepLCredentialResolver.isConfigured() {
            logger.log("no DeepL key configured", level: .warning)
            print("  fix: run `storescreens translate auth login`")
            print("  or set DEEPL_API_KEY (free tier available at https://www.deepl.com/pro-api)")
            return
        }

        let creds: DeepLCredentials
        do {
            creds = try DeepLCredentialResolver.resolve()
        } catch {
            logger.log("credentials broken: \(error)", level: .error)
            throw ExitCode(1)
        }

        print("  source: \(creds.source.rawValue)")
        print("  tier:   \(creds.isFreeTier ? "free" : "pro")")
        print("  key:    \(maskKey(creds.apiKey))")

        print("")
        print("  testing key against /v2/usage ...")
        do {
            let usage = try await DeepLClient(credentials: creds).usage()
            logger.log("authenticated (\(usage.characterCount)/\(usage.characterLimit) characters used this period)", level: .success)
        } catch {
            logger.log("auth check failed: \(error)", level: .error)
            throw ExitCode(1)
        }
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 8 else { return "****" }
        return String(key.prefix(6)) + "…" + String(key.suffix(3))
    }
}
