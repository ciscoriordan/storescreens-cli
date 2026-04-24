import ArgumentParser
import Foundation
import StorescreensCore

struct SubmitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "Upload rendered screenshots and metadata to App Store Connect.",
        discussion: """
            Requires `storescreens auth login` (or ASC_* env vars) and an \
            `app_store_connect:` block in storescreens.yml. Screenshots are \
            sourced from the render output directory; metadata from a \
            fastlane-style metadata/<locale>/*.txt directory.
            """
    )

    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml.")
    var config: String = "storescreens.yml"

    @Option(name: .long, help: "Override the render output directory.")
    var renderDir: String?

    @Option(name: .long, help: "Override the metadata directory (defaults to config.metadata_dir or ./metadata).")
    var metadataDir: String?

    @Option(name: .long, help: "Override app_store_connect.submit.create_version.")
    var versionOverride: String?

    @Flag(name: .long, help: "Validate without uploading. Does find-or-create-safe read-only checks.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Skip screenshot upload (metadata only).")
    var skipScreenshots: Bool = false

    @Flag(name: .long, help: "Skip metadata upload (screenshots only).")
    var skipMetadata: Bool = false

    func run() async throws {
        let logger = Logger()
        let loader = ConfigLoader()
        let captureConfig = try loader.load(from: config)

        guard let ascConfig = captureConfig.appStoreConnect else {
            logger.log("no `app_store_connect:` block in \(config); nothing to do", level: .error)
            throw ExitCode(1)
        }

        // Resolve credentials.
        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            logger.log("credentials not configured: \(error)", level: .error)
            print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
            throw ExitCode(1)
        }
        print("  credentials: \(creds.source.rawValue) (keyID \(creds.keyID))")

        // Apply version override.
        var effectiveConfig = ascConfig
        if let v = versionOverride {
            var submit = effectiveConfig.submit ?? SubmitConfig()
            submit.createVersion = v
            effectiveConfig.submit = submit
        }

        // Load manifest.
        let capturedDir = URL(fileURLWithPath: captureConfig.outputDir)
        let manifestPath = capturedDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            logger.log("no manifest.json at \(manifestPath.path); run `storescreens capture` first", level: .error)
            throw ExitCode(1)
        }
        let manifestData = try Data(contentsOf: manifestPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureManifest.self, from: manifestData)

        // Resolve render + metadata paths relative to the YML.
        let baseDir = URL(fileURLWithPath: config).deletingLastPathComponent().standardized
        let renderRoot: URL = {
            if let override = renderDir { return URL(fileURLWithPath: override) }
            if let configured = captureConfig.render?.outputDir {
                return URL(fileURLWithPath: configured, relativeTo: baseDir).standardized
            }
            return baseDir.appendingPathComponent("storescreens-framed")
        }()
        let metadataURL: URL? = {
            if skipMetadata { return nil }
            let path: String
            if let override = metadataDir { path = override }
            else if let configured = effectiveConfig.metadataDir { path = configured }
            else { path = "metadata" }
            let url = URL(fileURLWithPath: path, relativeTo: baseDir).standardized
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }()

        logger.header(dryRun ? "Dry run" : "Submitting")
        print("  app:       \(effectiveConfig.appID ?? effectiveConfig.bundleID ?? "(unset)")")
        print("  version:   \(effectiveConfig.submit?.createVersion ?? "(unset)")")
        print("  render:    \(renderRoot.path)")
        print("  metadata:  \(metadataURL?.path ?? "(none)")")

        if dryRun {
            try await runDryRun(
                creds: creds,
                config: effectiveConfig,
                manifest: manifest,
                renderRoot: renderRoot,
                metadataRoot: metadataURL,
                logger: logger
            )
            return
        }

        // Live upload.
        let client = ASCClient(credentials: creds)
        let orchestrator = SubmitOrchestrator(client: client, config: effectiveConfig)
        let report = try await orchestrator.submit(
            manifest: manifest,
            renderRoot: renderRoot,
            metadataRoot: metadataURL,
            shouldUploadScreenshots: !skipScreenshots,
            shouldUploadMetadata: !skipMetadata && metadataURL != nil,
            screenshotOrder: captureConfig.screenshots,
            progress: { line in print("  \(line)") }
        )

        print("")
        logger.header("Report")
        print("  app:      \(report.appID)")
        print("  version:  \(report.versionString) (\(report.versionID))")
        if !report.metadataUpdates.isEmpty {
            print("  metadata updates:")
            for m in report.metadataUpdates {
                print("    \(m.locale): \(m.fieldsUpdated.joined(separator: ", "))")
            }
        }
        if !report.screenshotUploads.isEmpty {
            print("  screenshots uploaded:")
            for s in report.screenshotUploads {
                print("    \(s.locale) / \(s.displayType): \(s.count) file(s)")
            }
        }
        if !report.privacyURLUpdates.isEmpty {
            print("  privacy URL updated for: \(report.privacyURLUpdates.joined(separator: ", "))")
        }
        if let submissionID = report.reviewSubmissionID {
            print("  submitted for review: \(submissionID)")
        }
        if !report.errors.isEmpty {
            logger.log("\(report.errors.count) error(s):", level: .error)
            for e in report.errors { print("    \(e)") }
            throw ExitCode(1)
        }
        logger.log("submit complete", level: .success)
    }

    // MARK: - Dry run

    private func runDryRun(
        creds: ASCCredentials,
        config ascConfig: AppStoreConnectConfig,
        manifest: CaptureManifest,
        renderRoot: URL,
        metadataRoot: URL?,
        logger: Logger
    ) async throws {
        var problems: [String] = []

        // 1. Credential smoke test via /v1/users.
        do {
            let client = ASCClient(credentials: creds)
            struct UsersResp: Decodable {
                struct User: Decodable { let id: String }
                let data: [User]
            }
            _ = try await client.get(path: "users", as: UsersResp.self)
            print("  ✓ credentials authenticated")
        } catch {
            problems.append("credentials failed: \(error)")
        }

        // 2. App resolves.
        let client = ASCClient(credentials: creds)
        let apps = AppsAPI(client: client)
        var appOK = false
        do {
            if let id = ascConfig.appID {
                let app = try await apps.lookupApp(id: id)
                print("  ✓ app: \(app.attributes?.name ?? id)")
                appOK = true
            } else if let bundle = ascConfig.bundleID {
                if let app = try await apps.lookupApp(bundleID: bundle) {
                    print("  ✓ app: \(app.attributes?.name ?? bundle) (id \(app.id))")
                    appOK = true
                } else {
                    problems.append("no app matches bundle id \(bundle)")
                }
            } else {
                problems.append("neither app_id nor bundle_id set")
            }
        } catch {
            problems.append("app lookup failed: \(error)")
        }
        _ = appOK

        // 3. Version string present.
        if ascConfig.submit?.createVersion?.isEmpty ?? true {
            problems.append("submit.create_version is empty")
        } else {
            print("  ✓ version: \(ascConfig.submit!.createVersion!)")
        }

        // 4. Metadata locales exist.
        if !skipMetadata {
            if let metadataRoot {
                do {
                    var warnings: [String] = []
                    let byLocale = try MetadataReader.read(dir: metadataRoot) { warnings.append($0) }
                    for w in warnings { print("    warn: \(w)") }
                    print("  ✓ metadata: \(byLocale.count) locale(s): \(byLocale.keys.sorted().joined(separator: ", "))")
                } catch {
                    problems.append("metadata read failed: \(error)")
                }
            } else {
                print("  (metadata: skipped, no directory)")
            }
        }

        // 5. Every rendered PNG maps to a known ASC displayType + file size OK.
        if !skipScreenshots {
            var slotCount = 0
            var sizeProblems = 0
            for device in manifest.devices {
                let pf = RenderPipeline.productFamilyFromDeviceType(device.deviceType)
                for shot in device.screenshots {
                    let url = renderRoot.appendingPathComponent(shot.filename)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        problems.append("missing rendered file: \(url.path)")
                        continue
                    }
                    guard let dims = ImageDims.read(at: url) else {
                        problems.append("can't read dims of \(shot.filename)")
                        continue
                    }
                    guard let dt = ScreenshotDisplayType.resolve(
                        productFamily: pf, width: dims.w, height: dims.h
                    ) else {
                        problems.append("no ASC display type for \(shot.filename) (\(dims.w)x\(dims.h))")
                        continue
                    }
                    // Apple caps screenshots at 8 MB.
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    if fileSize > 8 * 1024 * 1024 {
                        sizeProblems += 1
                        problems.append("\(shot.filename) is \(fileSize / 1024)KB, exceeds Apple's 8MB limit")
                    }
                    slotCount += 1
                    _ = dt
                }
            }
            print("  ✓ screenshots: \(slotCount) PNG(s) map to valid ASC display types" + (sizeProblems > 0 ? " (\(sizeProblems) too large)" : ""))
        }

        print("")
        if problems.isEmpty {
            logger.log("dry run OK", level: .success)
        } else {
            logger.log("dry run found \(problems.count) issue(s):", level: .error)
            for p in problems { print("    ✗ \(p)") }
            throw ExitCode(1)
        }
    }
}

/// Tiny helper to avoid re-importing ImageIO inline across this file.
private enum ImageDims {
    static func read(at url: URL) -> (w: Int, h: Int)? {
        #if canImport(ImageIO)
        return readIO(url: url)
        #else
        return nil
        #endif
    }
}

#if canImport(ImageIO)
import ImageIO

private func readIO(url: URL) -> (w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
}
#endif
