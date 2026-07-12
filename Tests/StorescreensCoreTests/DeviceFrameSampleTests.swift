import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
@testable import StorescreensCore

/// Renders a gallery of `chrome.style: device` samples - one per cutout
/// shape, colorway, and orientation - so the drawn frame can be eyeballed
/// after geometry or palette changes.
///
/// Skipped by default. To render:
///
///     STORESCREENS_WRITE_DEVICE_SAMPLES=1 swift test --filter DeviceFrameSampleTests
///
/// Output goes to `STORESCREENS_DEVICE_SAMPLES_DIR` if set, else a fresh
/// temp directory (path printed at the end).
final class DeviceFrameSampleTests: XCTestCase {

    private struct Sample {
        let name: String
        let width: Int
        let height: Int
        let deviceType: String
        let colorway: DeviceColorway
        let darkUI: Bool
        let background: [String]
        let darkBackground: Bool
        let title: String
    }

    func testRenderDeviceFrameSamples() async throws {
        guard ProcessInfo.processInfo.environment["STORESCREENS_WRITE_DEVICE_SAMPLES"] == "1" else {
            throw XCTSkip("set STORESCREENS_WRITE_DEVICE_SAMPLES=1 to render device frame samples")
        }

        let outDir: URL
        if let dir = ProcessInfo.processInfo.environment["STORESCREENS_DEVICE_SAMPLES_DIR"] {
            outDir = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            outDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("storescreens-device-samples-\(UUID())", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let samples: [Sample] = [
            Sample(name: "island-dark", width: 1206, height: 2622, deviceType: "iPhone 6.9\"",
                   colorway: .dark, darkUI: false, background: ["#1a1d29", "#0b0d14"],
                   darkBackground: true, title: "Dynamic Island, dark band"),
            Sample(name: "island-silver", width: 1206, height: 2622, deviceType: "iPhone 6.9\"",
                   colorway: .silver, darkUI: false, background: ["#f5f1ea"],
                   darkBackground: false, title: "Dynamic Island, silver band"),
            Sample(name: "island-natural", width: 1320, height: 2868, deviceType: "iPhone 6.9\"",
                   colorway: .natural, darkUI: true, background: ["#eee6d8", "#d9cbb4"],
                   darkBackground: false, title: "6.9 inch, natural titanium"),
            Sample(name: "notch-silver", width: 1284, height: 2778, deviceType: "iPhone 6.5\"",
                   colorway: .silver, darkUI: false, background: ["#eef2f5"],
                   darkBackground: false, title: "Notch era, silver band"),
            Sample(name: "se-dark", width: 750, height: 1334, deviceType: "iPhone 4.7\"",
                   colorway: .dark, darkUI: false, background: ["#20242e", "#12141a"],
                   darkBackground: true, title: "16:9 screen, no cutout"),
            Sample(name: "ipad-silver", width: 2064, height: 2752, deviceType: "iPad 13\"",
                   colorway: .silver, darkUI: false, background: ["#e8e4dc"],
                   darkBackground: false, title: "iPad, uniform border"),
            Sample(name: "landscape-dark", width: 2622, height: 1206, deviceType: "iPhone 6.9\"",
                   colorway: .dark, darkUI: true, background: ["#101318", "#1c2028"],
                   darkBackground: true, title: "Landscape island"),
        ]

        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("storescreens-device-samples-work-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        for sample in samples {
            let runRoot = workRoot.appendingPathComponent(sample.name, isDirectory: true)
            let capturedRoot = runRoot.appendingPathComponent("captured", isDirectory: true)
            try FileManager.default.createDirectory(at: capturedRoot, withIntermediateDirectories: true)

            let filename = "\(sample.name).png"
            try writeSyntheticAppScreenshot(
                width: sample.width, height: sample.height, darkUI: sample.darkUI,
                to: capturedRoot.appendingPathComponent(filename)
            )

            let manifest = CaptureManifest(
                version: 1,
                generatedAt: Date(),
                generatedBy: "device-frame-samples",
                appName: "Samples",
                displayName: "Samples",
                scheme: "Samples",
                devices: [
                    CaptureManifest.DeviceCapture(
                        deviceType: sample.deviceType,
                        simulatorName: sample.deviceType,
                        locale: "en-US",
                        appearance: nil,
                        screenshots: [CaptureManifest.Screenshot(name: sample.name, filename: filename, capturedAt: Date())]
                    ),
                ]
            )

            var config = RenderConfig(enabled: true)
            config.background = BackgroundConfig(
                color: sample.background.count > 1 ? .gradient(sample.background) : .solid(sample.background[0])
            )
            config.caption = CaptionConfig(
                title: CaptionRole(color: sample.darkBackground ? "#ffffff" : "#15161a")
            )
            config.chrome = ChromeConfig(
                style: .device,
                shadow: true,
                paddingPct: 5,
                deviceColorway: sample.colorway
            )
            config.slides = [
                sample.name: SlideOverride(caption: SlideCaption(title: .string(sample.title))),
            ]

            let renderRoot = runRoot.appendingPathComponent("framed", isDirectory: true)
            let pipeline = RenderPipeline(config: config, baseDirectory: runRoot)
            let out = try await pipeline.render(manifest: manifest, capturedRoot: capturedRoot, renderRoot: renderRoot)
            XCTAssertEqual(out.failures.count, 0, "[\(sample.name)] render failed: \(out.failures)")
            for w in out.warnings { print("[\(sample.name)] warning: \(w)") }

            let rendered = renderRoot.appendingPathComponent(filename)
            let dest = outDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: rendered, to: dest)
        }

        print("Rendered \(samples.count) device frame samples in \(outDir.path)")
    }

    /// Synthetic app UI - status-bar strip, header card, and list rows -
    /// realistic enough to judge how the drawn frame reads around it.
    private func writeSyntheticAppScreenshot(width: Int, height: Int, darkUI: Bool, to url: URL) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "DeviceFrameSamples", code: 1)
        }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let bg: CGColor = darkUI
            ? CGColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)
            : CGColor(srgbRed: 0.98, green: 0.975, blue: 0.965, alpha: 1)
        let card: CGColor = darkUI
            ? CGColor(srgbRed: 0.15, green: 0.16, blue: 0.20, alpha: 1)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let accent = CGColor(srgbRed: 0.16, green: 0.35, blue: 0.70, alpha: 1)
        let textDark: CGColor = darkUI
            ? CGColor(srgbRed: 0.85, green: 0.86, blue: 0.90, alpha: 1)
            : CGColor(srgbRed: 0.22, green: 0.22, blue: 0.25, alpha: 1)
        let textLight: CGColor = darkUI
            ? CGColor(srgbRed: 0.55, green: 0.56, blue: 0.60, alpha: 1)
            : CGColor(srgbRed: 0.62, green: 0.61, blue: 0.59, alpha: 1)

        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        func rr(_ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
            // Flip to bottom-left CG coords from the top-left sketch coords.
            let flipped = CGRect(x: rect.minX, y: h - rect.minY - rect.height,
                                 width: rect.width, height: rect.height)
            ctx.addPath(CGPath(roundedRect: flipped, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(color)
            ctx.fillPath()
        }

        let unit = min(w, h)
        // Header card below the status-bar area.
        rr(CGRect(x: 0.033 * unit, y: 0.085 * h, width: w - 0.066 * unit, height: 0.07 * h), 0.033 * unit, accent)
        // List rows.
        var y = 0.085 * h + 0.07 * h + 0.03 * h
        let rowH = 0.11 * h
        while y + rowH < h {
            rr(CGRect(x: 0.033 * unit, y: y, width: w - 0.066 * unit, height: rowH - 0.015 * h), 0.03 * unit, card)
            rr(CGRect(x: 0.066 * unit, y: y + 0.014 * h, width: 0.19 * unit, height: rowH - 0.043 * h), 0.02 * unit,
               CGColor(srgbRed: 0.78, green: 0.80, blue: 0.74, alpha: 1))
            rr(CGRect(x: 0.30 * unit, y: y + 0.020 * h, width: 0.52 * w, height: 0.018 * h), 0.009 * h, textDark)
            rr(CGRect(x: 0.30 * unit, y: y + 0.052 * h, width: 0.38 * w, height: 0.014 * h), 0.007 * h, textLight)
            y += rowH
        }

        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw NSError(domain: "DeviceFrameSamples", code: 2)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "DeviceFrameSamples", code: 3)
        }
    }
}
