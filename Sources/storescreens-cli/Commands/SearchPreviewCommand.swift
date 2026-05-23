import ArgumentParser
import Foundation
import StorescreensCore

struct SearchPreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-preview",
        abstract: "Render an iPhone App Store search-result preview of the app.",
        discussion: """
            Reads `search_preview:` from your storescreens.yml, plus per-locale \
            name/subtitle from `metadata/<locale>/*.txt`, the extracted \
            `AppIcon.png` from the capture dir, and the first three configured \
            screenshots, then composites a faithful iPhone search-row mockup \
            (icon + name + subtitle + stars + 3 screenshots) wrapped in an \
            iPhone bezel + status bar.

            Inspired by ezscreenshots' Search Preview tool - gives you an \
            honest preview of how the app will look when surfaced in App \
            Store search before you ship.

            The command does not need `enabled: true` in the YAML - that flag \
            only governs the auto-trigger during `storescreens capture`. When \
            invoked directly, it always runs.
            """
    )

    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml (default: ./storescreens.yml).")
    var config: String = "storescreens.yml"

    @Option(name: .long, help: "Override the capture output directory (defaults to config.output_dir).")
    var capturedDir: String?

    @Option(name: .long, help: "Override the search-preview output directory (defaults to config.search_preview.output_dir).")
    var outputDir: String?

    @Option(name: .long, help: "Override the appearance(s) to render. Repeatable: --appearance light --appearance dark.")
    var appearance: [String] = []

    @Option(name: .long, help: "Override the locale(s) to render. Repeatable: --locale en-US --locale ja.")
    var locale: [String] = []

    func run() async throws {
        let logger = Logger()

        let configLoader = ConfigLoader()
        var captureConfig = try configLoader.load(from: config)

        // CLI flags override the YAML's search_preview block (or create it
        // if the user hasn't configured one yet).
        var sp = captureConfig.searchPreview ?? SearchPreviewConfig()
        if !appearance.isEmpty { sp.appearances = appearance }
        if !locale.isEmpty { sp.locales = locale }
        if let outputDir { sp.outputDir = outputDir }
        captureConfig.searchPreview = sp

        let baseDirectory = URL(fileURLWithPath: config).deletingLastPathComponent().standardized

        let capturedRoot: URL = {
            if let override = capturedDir { return URL(fileURLWithPath: override) }
            return URL(fileURLWithPath: (captureConfig.outputDir as NSString).expandingTildeInPath)
        }()

        // Best-effort: read the capture manifest if it exists. The renderer
        // works without one (the user can supply screenshots via the YAML),
        // but the manifest lets us pick the iPhone-sized variant of each
        // configured screenshot automatically.
        let manifest = Self.loadManifestIfPresent(at: capturedRoot.appendingPathComponent("manifest.json"))

        // Resolved framed dir, if the user also enabled the render pass.
        let renderedRoot: URL? = {
            guard captureConfig.render?.enabled == true else { return nil }
            if let configured = captureConfig.render?.outputDir {
                return URL(fileURLWithPath: configured)
            }
            return URL(fileURLWithPath: "./storescreens-framed")
        }()

        logger.header("Rendering search preview")
        print("  config:    \(config)")
        print("  captured:  \(capturedRoot.path)")
        if let renderedRoot {
            print("  framed:    \(renderedRoot.path)")
        }

        let result = SearchPreviewRunner().run(
            captureConfig: captureConfig,
            manifest: manifest,
            capturedRoot: capturedRoot,
            renderedRoot: renderedRoot,
            baseDirectory: baseDirectory
        )

        for warning in result.warnings {
            logger.log(warning, level: .warning)
        }

        guard result.renderedCount > 0 else {
            logger.log("no search-preview PNGs were rendered", level: .error)
            throw ExitCode(1)
        }
        logger.log("rendered \(result.renderedCount) search preview(s)", level: .success)
        if let firstParent = result.outputs.first?.deletingLastPathComponent() {
            logger.log("output: \(firstParent.path)", level: .info)
        }
    }

    private static func loadManifestIfPresent(at path: URL) -> CaptureManifest? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return nil }
        guard let data = try? Data(contentsOf: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CaptureManifest.self, from: data)
    }
}
