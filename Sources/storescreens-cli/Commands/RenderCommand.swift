import ArgumentParser
import Foundation
import StorescreensCore

struct RenderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Render captioned screenshots from an existing capture.",
        discussion: """
            Operates on a previously-captured manifest.json without re-running \
            the UI tests. Reads the `render:` block from your storescreens.yml, \
            composites background + scrim + logo + caption + chrome for each \
            slide, and writes framed PNGs to the configured output directory.
            """
    )

    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml (default: ./storescreens.yml).")
    var config: String = "storescreens.yml"

    @Option(name: .long, help: "Override the capture output directory (defaults to config.output_dir).")
    var capturedDir: String?

    @Option(name: .long, help: "Override the render output directory (defaults to config.render.output_dir).")
    var outputDir: String?

    func run() async throws {
        let logger = Logger()

        // 1. Load config
        let loader = ConfigLoader()
        let captureConfig = try loader.load(from: config)

        guard let render = captureConfig.render else {
            logger.log("no `render:` block in \(config); nothing to do", level: .warning)
            return
        }

        // 2. Locate capture manifest
        let capturedRoot: URL = {
            if let override = capturedDir { return URL(fileURLWithPath: override) }
            return URL(fileURLWithPath: captureConfig.outputDir)
        }()
        let manifestPath = capturedRoot.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            logger.log("no manifest.json at \(manifestPath.path); run `storescreens capture` first", level: .error)
            throw ExitCode(1)
        }

        let manifestData = try Data(contentsOf: manifestPath)
        let manifest = try JSONDecoder.manifestDecoder().decode(StorescreensCore.CaptureManifest.self, from: manifestData)

        // 3. Resolve output dir (flag > config > default)
        let renderRoot: URL = {
            if let override = outputDir { return URL(fileURLWithPath: override) }
            if let configured = render.outputDir { return URL(fileURLWithPath: configured) }
            return URL(fileURLWithPath: "./storescreens-framed")
        }()

        // 4. baseDirectory for asset resolution = dir containing the YML file
        let baseDirectory = URL(fileURLWithPath: config).deletingLastPathComponent().standardized

        logger.header("Rendering")
        print("  config:    \(config)")
        print("  captured:  \(capturedRoot.path)")
        print("  rendered:  \(renderRoot.path)")
        print("")

        let pipeline = RenderPipeline(config: render, baseDirectory: baseDirectory)
        let start = Date()
        let out = try await pipeline.render(
            manifest: manifest,
            capturedRoot: capturedRoot,
            renderRoot: renderRoot,
            screenshotOrder: captureConfig.screenshots
        )
        let elapsed = Date().timeIntervalSince(start)

        for warning in out.warnings {
            logger.log(warning, level: .warning)
        }

        if out.failures.isEmpty {
            logger.log("rendered \(out.renderedSlides) slide(s) in \(String(format: "%.1f", elapsed))s", level: .success)
        } else {
            logger.log("rendered \(out.renderedSlides) slide(s); \(out.failures.count) failure(s)", level: .error)
            for (slide, err) in out.failures {
                print("  ✗ \(slide): \(err)")
            }
            throw ExitCode(1)
        }

        // Refresh the capture's preview.html so the per-device pages
        // pick up a raw/framed toggle pointing at the PNGs we just
        // wrote. Non-fatal: a stale preview is still usable for the
        // raw captures.
        let framedRelative = relativePathString(from: capturedRoot, to: renderRoot)
        do {
            try HTMLPreviewGenerator(localeFlags: captureConfig.localeFlags)
                .generate(
                    manifest: manifest,
                    outputDir: capturedRoot.path,
                    framedDir: framedRelative,
                    keepOldPreviews: captureConfig.keepOldPreviews ?? false
                )
        } catch {
            logger.log("preview regeneration failed: \(error)", level: .warning)
        }
    }

    /// POSIX-style relative path from one absolute URL to another. Used
    /// so the preview's framed `<img src>`s resolve whether the user
    /// opened preview.html via file:// or served it. Kept in-file (and
    /// duplicated across commands) because the logic is three lines and
    /// doesn't earn its own module yet.
    private func relativePathString(from base: URL, to target: URL) -> String {
        let b = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let t = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var i = 0
        while i < b.count && i < t.count && b[i] == t[i] { i += 1 }
        let ups = Array(repeating: "..", count: b.count - i)
        let downs = Array(t[i...])
        let parts = ups + downs
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}

private extension JSONDecoder {
    /// Decoder configured to match the capture manifest's date format.
    static func manifestDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
