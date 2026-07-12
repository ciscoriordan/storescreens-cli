import ArgumentParser
import Foundation
import StorescreensCore

struct ThemesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "themes",
        abstract: "Suggest render themes derived from the app's own colors.",
        discussion: """
            Analyzes captured screenshots for their dominant background and \
            most vivid accent color, then proposes ready-to-paste `render:` \
            theme values (background color or gradient, caption text color, \
            drawn-frame colorway) with legible contrast built in.
            """,
        subcommands: [ThemesSuggestCommand.self],
        defaultSubcommand: ThemesSuggestCommand.self
    )
}

struct ThemesSuggestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggest",
        abstract: "Derive theme suggestions from captured screenshots."
    )

    @Argument(help: "Screenshot paths to analyze. Default: the last capture's screenshots (from manifest.json).")
    var paths: [String] = []

    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml (default: ./storescreens.yml).")
    var config: String = "storescreens.yml"

    @Option(name: .long, help: "Override the capture output directory (defaults to config.output_dir).")
    var capturedDir: String?

    @Flag(name: .long, help: "Print suggestions as JSON instead of YAML snippets.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()

        let urls: [URL]
        if !paths.isEmpty {
            urls = paths.map { URL(fileURLWithPath: $0) }
        } else {
            let capturedRoot: URL
            if let override = capturedDir {
                capturedRoot = URL(fileURLWithPath: override)
            } else {
                let captureConfig = try ConfigLoader().load(from: config)
                capturedRoot = URL(fileURLWithPath: captureConfig.outputDir)
            }
            guard FileManager.default.fileExists(atPath: capturedRoot.appendingPathComponent("manifest.json").path) else {
                logger.log("no manifest.json in \(capturedRoot.path); run `storescreens capture` first or pass screenshot paths", level: .error)
                throw ExitCode(1)
            }
            urls = try ThemeSuggester.capturedScreenshotURLs(capturedRoot: capturedRoot)
        }

        guard !urls.isEmpty else {
            logger.log("no screenshots to analyze", level: .error)
            throw ExitCode(1)
        }

        let themes = try ThemeSuggester.suggest(from: urls)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try encoder.encode(themes), encoding: .utf8) ?? "[]")
            return
        }

        logger.header("Theme suggestions")
        print("  analyzed \(urls.count) screenshot\(urls.count == 1 ? "" : "s")")
        for theme in themes {
            print("")
            print("  \(theme.name) - \(theme.why)")
            let color = theme.background.count == 1
                ? "\"\(theme.background[0])\""
                : "[\"\(theme.background.joined(separator: "\", \""))\"]"
            print("""
                    render:
                      background:
                        color: \(color)
                      caption:
                        title:
                          color: "\(theme.textColor)"
                      chrome:
                        style: bezel        # real bezels if installed, drawn device frame otherwise
                        device_colorway: \(theme.deviceColorway.rawValue)
                """)
        }
        print("")
        print("  paste one into storescreens.yml, then run `storescreens render`")
    }
}
