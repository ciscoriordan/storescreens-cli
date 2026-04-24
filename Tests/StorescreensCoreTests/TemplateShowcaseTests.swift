import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
@testable import StorescreensCore

/// Generates one PNG per built-in template into `assets/templates/<id>.png`
/// so the README gallery stays in sync with the actual renders.
///
/// By default this is a no-op (skipped) so `swift test` doesn't touch
/// committed files. To (re)generate, set `STORESCREENS_WRITE_SHOWCASE=1`:
///
///     STORESCREENS_WRITE_SHOWCASE=1 swift test --filter TemplateShowcaseTests
///
/// Output is iPhone 6.9" portrait (1320x2868), matching the App Store
/// standard size so the assets double as a real render sample.
final class TemplateShowcaseTests: XCTestCase {

    func testRegenerateShowcaseAssets() async throws {
        guard ProcessInfo.processInfo.environment["STORESCREENS_WRITE_SHOWCASE"] == "1" else {
            throw XCTSkip("set STORESCREENS_WRITE_SHOWCASE=1 to regenerate assets/templates/*.png")
        }

        // Walk up from the test file's source path to the repo root — we
        // can't rely on CWD because `swift test` invokes from the package
        // root, and the repo is the same directory. Still, be defensive.
        let repoRoot = try findRepoRoot()
        let assetsDir = repoRoot
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("templates", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        // Half the iPhone 6.9" App Store size. Keeps PNGs small enough to
        // commit (~500 KB each) while staying retina-sharp in the README gallery.
        let width = 660, height = 1434

        // Use a tmp work dir per render. Not the assets dir — the framed
        // PNG is what we copy over at the end.
        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("storescreens-showcase-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        for template in RenderTemplate.builtIn {
            let runRoot = workRoot.appendingPathComponent(template.id, isDirectory: true)
            let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
            try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

            let filename = "iPhone_6.9_01_Home.png"
            let sourceURL = capturedRoot.appendingPathComponent(filename)
            try writeSyntheticScreenshot(width: width, height: height, label: template.name, to: sourceURL)

            let manifest = CaptureManifest(
                version: 1,
                generatedAt: Date(),
                generatedBy: "showcase",
                appName: "Showcase",
                displayName: "Showcase",
                scheme: "Showcase",
                devices: [
                    CaptureManifest.DeviceCapture(
                        deviceType: "iPhone 6.9\"",
                        simulatorName: "iPhone 17 Pro Max",
                        locale: "en-US",
                        appearance: nil,
                        screenshots: [CaptureManifest.Screenshot(name: "01_Home", filename: filename, capturedAt: Date())]
                    ),
                ]
            )

            var config = RenderConfig(enabled: true, template: template.id)
            // Force stroke chrome so the host doesn't need Apple bezel PSDs
            // installed — the showcase is about backgrounds + typography.
            config.chrome = ChromeConfig(
                style: .stroke,
                strokeColor: "#ffffff",
                strokeWidth: 3,
                cornerRadius: .auto,
                shadow: true,
                paddingPct: 5
            )
            config.slides = [
                "01_Home": SlideOverride(
                    caption: SlideCaption(
                        title: .string(template.name),
                        subtitle: .string(template.description)
                    )
                ),
            ]

            let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
            let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
            let out = try await pipeline.render(manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot)
            XCTAssertEqual(out.failures.count, 0, "[\(template.id)] render failed: \(out.failures)")

            let renderedPNG = renderRoot.appendingPathComponent(filename)
            let destPNG = assetsDir.appendingPathComponent("\(template.id).png")
            if FileManager.default.fileExists(atPath: destPNG.path) {
                try FileManager.default.removeItem(at: destPNG)
            }
            try FileManager.default.copyItem(at: renderedPNG, to: destPNG)
            print("[\(template.id)] -> \(destPNG.path)")
        }

        print("")
        print("Regenerated \(RenderTemplate.builtIn.count) template screenshots in \(assetsDir.path)")
    }

    // MARK: - Helpers

    /// Finds the repo root by walking up from `#filePath` until we see a
    /// `Package.swift`. Falls back to CWD if the walk fails.
    private func findRepoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            return cwd
        }
        throw NSError(domain: "TemplateShowcaseTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not locate repo root (Package.swift)"])
    }

    /// Synthetic app screenshot — a soft vertical gradient and one centered
    /// label — so the device frame in the render has something readable
    /// inside it. Not meant to look like a real app.
    private func writeSyntheticScreenshot(width: Int, height: Int, label: String, to url: URL) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Showcase", code: 1)
        }

        // Gentle vertical gradient
        let colors = [
            NSColor(srgbRed: 0.12, green: 0.14, blue: 0.20, alpha: 1).cgColor,
            NSColor(srgbRed: 0.18, green: 0.22, blue: 0.30, alpha: 1).cgColor,
        ]
        let gradient = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height)),
            end: CGPoint(x: CGFloat(width) / 2, y: 0),
            options: []
        )

        // Label centered vertically
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: CGFloat(width) * 0.06),
            .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85),
            .paragraphStyle: para,
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let rect = CGRect(x: 0, y: CGFloat(height) * 0.46, width: CGFloat(width), height: CGFloat(height) * 0.1)
        attr.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw NSError(domain: "Showcase", code: 2)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Showcase", code: 3)
        }
    }
}
