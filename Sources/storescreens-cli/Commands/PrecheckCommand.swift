import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens precheck` - scans `metadata/<locale>/*.txt` for the
/// things App Review rejects listings over, before the upload instead of
/// after. The fastlane analogue is `precheck`; the rules are the same
/// family (other platforms, placeholder text, profanity, dead links) plus
/// the hard ASC field limits, which are cheaper to catch here than as a
/// 422 mid-submit.
///
/// Nothing here touches App Store Connect, so it needs no credentials.
/// `--check-urls` is the one exception to "offline": it requests each
/// support/marketing/privacy URL to confirm it answers.
struct PrecheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "precheck",
        abstract: "Scan metadata for App Review guideline problems before submitting.",
        discussion: """
            Reads the same metadata/<locale>/*.txt files `storescreens submit` uploads and \
            reports what App Review is likely to reject: references to other platforms, \
            placeholder text, profanity, pre-release framing, over-length fields, and \
            malformed URLs. Runs offline and needs no App Store Connect credentials.

            `submit --dry-run` runs these same rules automatically. Use this command when \
            you want the detail, or `--check-urls` to also confirm every support and \
            marketing link still resolves.

            Errors exit non-zero; warnings don't. Use --strict to fail on warnings too.
            """
    )

    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml.")
    var config: String = "storescreens.yml"

    @Option(name: .long, help: "Override the metadata directory (defaults to config.metadata_dir or ./metadata).")
    var metadataDir: String?

    @Flag(name: .long, help: "Also request every support/marketing/privacy URL to confirm it resolves.")
    var checkUrls: Bool = false

    @Flag(name: .long, help: "Exit non-zero on warnings as well as errors.")
    var strict: Bool = false

    @Flag(name: .long, help: "Emit findings as JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()

        // The YAML is optional here: precheck is useful on a metadata
        // directory alone, and requiring a config would make it useless
        // for anyone who keeps metadata outside a storescreens project.
        let captureConfig = try? ConfigLoader().load(from: config)
        let baseDir = URL(fileURLWithPath: config).deletingLastPathComponent().standardized
        let root: URL = {
            if let metadataDir { return URL(fileURLWithPath: metadataDir) }
            if let configured = captureConfig?.appStoreConnect?.metadataDir {
                return URL(fileURLWithPath: configured, relativeTo: baseDir).standardized
            }
            return baseDir.appendingPathComponent("metadata")
        }()

        guard FileManager.default.fileExists(atPath: root.path) else {
            logger.log("no metadata directory at \(root.path)", level: .error)
            print("  run `storescreens metadata init` to scaffold one, or pass --metadata-dir")
            throw ExitCode(1)
        }

        let scanner = MetadataPrecheck()
        let offline = scanner.scan(dir: root)
        var findings = offline.findings
        if checkUrls {
            findings.append(contentsOf: await scanner.checkURLs(dir: root))
        }
        let result = MetadataPrecheck.Result(findings: findings, localesScanned: offline.localesScanned)

        if json {
            try emitJSON(result)
        } else {
            report(result, root: root, logger: logger)
        }

        if result.hasErrors || (strict && !result.warnings.isEmpty) {
            throw ExitCode(1)
        }
    }

    private func report(_ result: MetadataPrecheck.Result, root: URL, logger: Logger) {
        logger.header("Precheck")
        print("  metadata: \(root.path)")
        print("  locales:  \(result.localesScanned)")
        if result.localesScanned == 0 {
            logger.log("no locale directories with metadata files found", level: .warning)
            return
        }
        print("")

        // Group by locale so a multi-locale listing reads as one block per
        // language rather than an interleaved stream.
        let byLocale = Dictionary(grouping: result.findings, by: \.locale)
        for locale in byLocale.keys.sorted() {
            let findings = byLocale[locale] ?? []
            print("  \(locale)")
            for finding in findings.sorted(by: { ($0.file, $0.rule) < ($1.file, $1.rule) }) {
                let where_ = finding.line.map { "\(finding.file):\($0)" } ?? finding.file
                logger.log(
                    "\(where_)  [\(finding.rule)]",
                    level: finding.severity == .error ? .error : .warning
                )
                print("      \(finding.message)")
                if let excerpt = finding.excerpt {
                    print("      > \(excerpt)")
                }
            }
            print("")
        }

        if result.findings.isEmpty {
            logger.log("no issues found across \(result.localesScanned) locale(s)", level: .success)
            if !checkUrls {
                print("  tip: --check-urls also confirms every support and marketing link resolves")
            }
            return
        }

        let summary = "\(result.errors.count) error(s), \(result.warnings.count) warning(s)"
        if result.hasErrors {
            logger.log(summary, level: .error)
        } else {
            logger.log(summary, level: .warning)
            if !strict { print("  warnings don't block; --strict makes them exit non-zero") }
        }
    }

    private func emitJSON(_ result: MetadataPrecheck.Result) throws {
        struct Out: Encodable {
            struct Finding: Encodable {
                let severity: String
                let rule: String
                let locale: String
                let file: String
                let line: Int?
                let message: String
                let excerpt: String?
            }
            let localesScanned: Int
            let errorCount: Int
            let warningCount: Int
            let findings: [Finding]
        }
        let out = Out(
            localesScanned: result.localesScanned,
            errorCount: result.errors.count,
            warningCount: result.warnings.count,
            findings: result.findings.map {
                .init(
                    severity: $0.severity.rawValue,
                    rule: $0.rule,
                    locale: $0.locale,
                    file: $0.file,
                    line: $0.line,
                    message: $0.message,
                    excerpt: $0.excerpt
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(out), encoding: .utf8) ?? "{}")
    }
}
