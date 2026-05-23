import Foundation

/// Glue between the resolver (figures out what to draw) and the renderer
/// (draws it). Used by both the standalone `storescreens search-preview`
/// command and the post-capture pipeline. Render failures are surfaced as
/// warnings so a broken search-preview never destroys a successful capture.
package struct SearchPreviewRunner {

    package init() {}

    /// Returns the number of rendered PNGs plus any warnings collected
    /// along the way. The caller decides how loud to be about warnings —
    /// the CLI prints them, the MCP server stuffs them in the response.
    package struct Result: Sendable {
        package let renderedCount: Int
        package let outputs: [URL]
        package let warnings: [String]
    }

    /// Resolves search-preview inputs from the given config and draws them.
    /// Skip is honored upstream (CLI `--no-search-preview`); this entry
    /// point assumes the caller already decided to run.
    package func run(
        captureConfig: CaptureConfig,
        manifest: CaptureManifest?,
        capturedRoot: URL,
        renderedRoot: URL?,
        baseDirectory: URL
    ) -> Result {
        let resolver = SearchPreviewResolver()
        let resolved = resolver.resolve(
            captureConfig: captureConfig,
            manifest: manifest,
            capturedRoot: capturedRoot,
            renderedRoot: renderedRoot,
            baseDirectory: baseDirectory
        )

        guard !resolved.inputs.isEmpty else {
            var warnings = resolved.warnings
            warnings.append("no search-preview inputs to render (check `search_preview:` block)")
            return Result(renderedCount: 0, outputs: [], warnings: warnings)
        }

        let renderer = SearchPreviewRenderer()
        var warnings = resolved.warnings
        do {
            let renderWarnings = try renderer.render(resolved.inputs)
            warnings.append(contentsOf: renderWarnings)
        } catch {
            warnings.append("search-preview render aborted: \(error)")
            return Result(renderedCount: 0, outputs: [], warnings: warnings)
        }

        // We don't try to detect partial failures per input here — the
        // renderer's per-input failures are already in `warnings`. Treat
        // any output URL that actually exists on disk as a success.
        let outputs = resolved.inputs.map { $0.outputURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return Result(renderedCount: outputs.count, outputs: outputs, warnings: warnings)
    }
}
