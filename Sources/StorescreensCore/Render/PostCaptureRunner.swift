import Foundation

/// Shared post-capture pass. Runs the render pipeline (when
/// `captureConfig.render.enabled == true`) and regenerates the
/// capture's `preview.html` so the per-device pages pick up the
/// raw/framed toggle.
///
/// Both the CLI (`storescreens capture`) and the MCP server
/// (`capture` tool) call this after `CaptureOrchestrator.run()`
/// succeeds, so both surfaces produce the same captioned PNGs and
/// the same preview UX. Render failures are surfaced through the
/// `logger` closure but never thrown — a bad render must not
/// destroy a successful capture.
package struct PostCaptureRunner {

    package init() {}

    /// Run render + preview regeneration if the config opts in.
    ///
    /// - Parameters:
    ///   - captureConfig: resolved capture config (for `render`,
    ///     `keepOldPreviews`, `localeFlags`, `screenshots` order).
    ///   - manifest: the manifest written by `CaptureOrchestrator.run`.
    ///   - capturedRoot: directory holding the raw captured PNGs
    ///     (the same dir `preview.html` lives in).
    ///   - baseDirectory: directory used to resolve render asset
    ///     paths — typically the directory containing the YML config.
    ///   - logger: optional sink for user-facing progress/warnings.
    ///     When nil, messages are discarded. MCP callers wire this
    ///     up to the `AsyncTaskStore` so pollers see render progress.
    ///   - skip: short-circuit flag (e.g. `--no-render` on the CLI).
    ///     When true, this call does nothing regardless of config.
    package func runIfEnabled(
        captureConfig: CaptureConfig,
        manifest: CaptureManifest,
        capturedRoot: URL,
        baseDirectory: URL,
        skip: Bool = false,
        logger: ((String) -> Void)? = nil
    ) async {
        guard !skip else { return }
        guard captureConfig.render?.enabled == true, let renderConfig = captureConfig.render else {
            return
        }

        let renderRoot: URL = {
            if let configured = renderConfig.outputDir {
                return URL(fileURLWithPath: configured)
            }
            return URL(fileURLWithPath: "./storescreens-framed")
        }()

        logger?("● Rendering")
        logger?("  output:  \(renderRoot.path)")

        let pipeline = RenderPipeline(config: renderConfig, baseDirectory: baseDirectory)
        do {
            let out = try await pipeline.render(
                manifest: manifest,
                capturedRoot: capturedRoot,
                renderRoot: renderRoot,
                screenshotOrder: captureConfig.screenshots
            )
            for w in out.warnings { logger?("⚠ \(w)") }
            if out.failures.isEmpty {
                logger?("✓ rendered \(out.renderedSlides) slide(s)")
            } else {
                logger?("✗ rendered \(out.renderedSlides) slide(s); \(out.failures.count) failure(s)")
                for (slide, err) in out.failures {
                    logger?("  ✗ \(slide): \(err)")
                }
            }
        } catch {
            logger?("✗ render failed: \(error)")
        }

        // Regenerate preview.html so the per-device pages surface
        // the just-written framed PNGs next to the raw captures.
        // `framedRelative` is a POSIX-style path from the capture
        // dir to the render dir so relative `<img src>`s resolve
        // whether the user opens file:// or serves the output.
        let framedRelative = Self.relativePathString(from: capturedRoot, to: renderRoot.standardized)
        do {
            try HTMLPreviewGenerator(localeFlags: captureConfig.localeFlags)
                .generate(
                    manifest: manifest,
                    outputDir: capturedRoot.path,
                    framedDir: framedRelative,
                    keepOldPreviews: captureConfig.keepOldPreviews ?? false,
                    screenshotOrder: captureConfig.screenshots
                )
        } catch {
            logger?("⚠ preview regeneration failed: \(error)")
        }
    }

    /// POSIX-style relative path from one absolute URL to another.
    /// Returns "." when the URLs resolve to the same directory.
    /// Duplicated from `CaptureCommand` / `RenderCommand` so the
    /// shared helper doesn't depend on either CLI module.
    static func relativePathString(from base: URL, to target: URL) -> String {
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
