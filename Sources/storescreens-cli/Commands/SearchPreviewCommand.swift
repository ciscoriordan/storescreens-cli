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

    @Option(name: .long, help: "App Store URL to fetch and preview (e.g. https://apps.apple.com/us/app/id6762309721). Skips local config + metadata; pulls every input from iTunes Lookup.")
    var url: String?

    @Option(name: .long, help: "Numeric App Store app id to fetch and preview (e.g. 6762309721). Same as --url but skipping the URL parsing step.")
    var appID: String?

    @Option(name: .long, help: "Country/region for iTunes Lookup (default: us). Used with --url / --app-id.")
    var country: String = "us"

    func run() async throws {
        // App Store fetch path: --url or --app-id was passed. Builds an
        // in-memory config from iTunes Lookup + the icon/screenshot
        // downloads instead of reading any local YAML.
        if let id = appID ?? AppStoreFetcher.extractAppID(from: url ?? "") {
            try await runFromAppStore(appID: id)
            return
        }
        if url != nil || appID != nil {
            // The user passed --url but it didn't yield a valid id.
            Logger().log(
                "could not extract App Store app id from --url \"\(url ?? "")\"",
                level: .error
            )
            throw ExitCode(1)
        }

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

    // MARK: - App Store fetch path

    /// Renders a search preview for a shipped App Store app, by app id.
    /// Pulls every input from iTunes Lookup + the public App Store web
    /// page; writes the resulting PNGs to `<outputDir>/<appID>/...`.
    private func runFromAppStore(appID: String) async throws {
        let logger = Logger()
        logger.header("Fetching App Store metadata")
        print("  app id:  \(appID)")
        print("  country: \(country)")

        let fetcher = AppStoreFetcher()
        let fetched: AppStoreFetcher.FetchedApp
        do {
            fetched = try await fetcher.fetch(appID: appID, country: country)
        } catch {
            logger.log("App Store fetch failed: \(error)", level: .error)
            throw ExitCode(1)
        }
        logger.log("\(fetched.name) by \(fetched.developer)", level: .success)
        if let subtitle = fetched.subtitle {
            logger.log("subtitle: \(subtitle)", level: .info)
        }
        logger.log("rating: \(String(format: "%.1f", fetched.rating)) (\(fetched.reviewCount) reviews) · age \(fetched.ageRating) · v\(fetched.version)", level: .info)
        logger.log("screenshots: \(fetched.screenshotURLs.count) · devices: \(fetched.supportedDevices.joined(separator: ", "))", level: .info)

        // Resolve output directory + asset cache. Each app id gets its own
        // subdir so multiple URL renders don't clobber each other.
        let outputRoot: URL = {
            if let configured = outputDir { return URL(fileURLWithPath: configured) }
            return URL(fileURLWithPath: "./storescreens-search-preview")
        }()
        let appOutputDir = outputRoot.appendingPathComponent("appstore-\(appID)")
        let assetCacheDir = appOutputDir.appendingPathComponent(".cache")

        logger.header("Downloading assets")
        let (iconLocals, iconWarnings) = try await fetcher.downloadImages(
            [fetched.iconURL], to: assetCacheDir, basename: "icon"
        )
        for w in iconWarnings { logger.log(w, level: .warning) }
        let (screenshotLocals, shotWarnings) = try await fetcher.downloadImages(
            Array(fetched.screenshotURLs.prefix(3)), to: assetCacheDir, basename: "screenshot"
        )
        for w in shotWarnings { logger.log(w, level: .warning) }
        logger.log("\(iconLocals.count) icon + \(screenshotLocals.count) screenshot(s) cached", level: .success)

        // Modes: both by default for fetched apps so users see search-row
        // + detail-page from one invocation.
        let modes: [SearchPreviewMode] = [.searchRow, .detailPage]
        let appearances = appearance.isEmpty ? ["light"] : appearance
        let canvasSize = CGSize(width: 1290, height: 2796)
        let deviceLabel = "iPhone 6.9\""

        let searchTerm = SearchPreviewResolver.defaultSearchTerm(from: fetched.name)
        let reviewsString = Self.formatReviewCount(fetched.reviewCount)
        let releaseAgo = SearchPreviewResolver.relativeAgo(from: fetched.releaseDateISO)

        logger.header("Rendering")
        var inputs: [SearchPreviewInput] = []
        for app in appearances {
            for mode in modes {
                let modeSlug = mode == .searchRow ? "search-row" : "detail-page"
                let outputURL = appOutputDir.appendingPathComponent("\(app)/iPhone_6.9_\(modeSlug).png")
                inputs.append(SearchPreviewInput(
                    locale: nil,
                    appearance: app,
                    mode: mode,
                    canvasSize: canvasSize,
                    deviceLabel: deviceLabel,
                    name: fetched.name,
                    subtitle: fetched.subtitle ?? "",
                    developer: fetched.developer,
                    rating: fetched.rating,
                    reviews: reviewsString,
                    categories: fetched.categories,
                    iconPath: iconLocals.first,
                    screenshotPaths: screenshotLocals,
                    action: .get,
                    priceLabel: nil,
                    hasInAppPurchases: false,
                    searchTerm: searchTerm,
                    bezel: .iphone,
                    version: fetched.version,
                    whatsNew: fetched.releaseNotes,
                    descriptionText: fetched.description,
                    ageRating: fetched.ageRating,
                    releaseAgo: releaseAgo,
                    supportedDevices: fetched.supportedDevices,
                    outputURL: outputURL
                ))
            }
        }

        let renderer = SearchPreviewRenderer()
        let warnings = try renderer.render(inputs)
        for w in warnings { logger.log(w, level: .warning) }
        let written = inputs.map { $0.outputURL }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !written.isEmpty else {
            logger.log("no PNGs were rendered", level: .error)
            throw ExitCode(1)
        }
        logger.log("rendered \(written.count) PNG(s)", level: .success)
        logger.log("output: \(appOutputDir.path)", level: .info)
    }

    /// Compact App Store-style review count: 999 stays as is, 1234 becomes
    /// 1.2K, 12_500_000 becomes 12.5M. Drops trailing `.0` so 5000 reads
    /// as "5K", not "5.0K".
    private static func formatReviewCount(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 {
            let k = Double(count) / 1_000
            return String(format: "%.1fK", k).replacingOccurrences(of: ".0K", with: "K")
        }
        let m = Double(count) / 1_000_000
        return String(format: "%.1fM", m).replacingOccurrences(of: ".0M", with: "M")
    }
}
