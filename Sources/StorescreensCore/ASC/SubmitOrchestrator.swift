import Foundation

/// Coordinates everything needed to push a `storescreens capture` +
/// `storescreens render` run to App Store Connect:
///
///   1. Resolve the app by ID or bundle ID
///   2. Find-or-create the target App Store Version
///   3. For every locale in `metadata/` — find-or-create localization and
///      PATCH any fields present
///   4. For every (locale, device) in the manifest — find-or-create a
///      screenshot set, wipe its existing screenshots, upload fresh PNGs
///      in manifest order, confirm each with MD5
package struct SubmitOrchestrator {

    package let client: ASCClient
    package let config: AppStoreConnectConfig

    package init(client: ASCClient, config: AppStoreConnectConfig) {
        self.client = client
        self.config = config
    }

    // MARK: - Report

    package struct Report: Sendable {
        package var appID: String
        package var versionID: String
        package var versionString: String
        package var metadataUpdates: [MetadataUpdate]
        package var screenshotUploads: [ScreenshotUpload]
        package var privacyURLUpdates: [String]       // locales where privacy URL was set
        package var reviewSubmissionID: String?
        package var errors: [String]

        package struct MetadataUpdate: Sendable {
            package let locale: String
            package let fieldsUpdated: [String]
        }

        package struct ScreenshotUpload: Sendable {
            package let locale: String
            package let displayType: String
            package let count: Int
        }
    }

    package enum Failure: Error, CustomStringConvertible {
        case missingAppIdentifier
        case appNotFound(query: String)
        case missingCreateVersion
        case unsupportedScreenshotDims(file: String, w: Int, h: Int)

        package var description: String {
            switch self {
            case .missingAppIdentifier:
                return "app_store_connect.app_id or bundle_id must be set"
            case .appNotFound(let q):
                return "no App Store Connect app matched: \(q)"
            case .missingCreateVersion:
                return "app_store_connect.submit.create_version is required"
            case .unsupportedScreenshotDims(let f, let w, let h):
                return "screenshot \(f) has unsupported dimensions \(w)x\(h); no ASC display type matches"
            }
        }
    }

    // MARK: - Run

    /// Executes the submit flow. `renderRoot` is the directory holding
    /// rendered/framed PNGs (usually `storescreens-framed/`). `metadataRoot`
    /// is the `metadata/<locale>/` directory. `capturedManifest` gives us
    /// the (device, locale, screenshots-in-order) structure — we re-use the
    /// same manifest from the capture step so ordering is preserved.
    package func submit(
        manifest: CaptureManifest,
        renderRoot: URL,
        metadataRoot: URL?,
        shouldUploadScreenshots: Bool,
        shouldUploadMetadata: Bool,
        progress: ((String) -> Void)? = nil
    ) async throws -> Report {
        guard let createVersion = config.submit?.createVersion, !createVersion.isEmpty else {
            throw Failure.missingCreateVersion
        }
        let platform = config.submit?.platform ?? "IOS"

        // 1. Resolve app.
        let appsAPI = AppsAPI(client: client)
        let app = try await resolveApp(appsAPI: appsAPI)
        progress?("Resolved app: \(app.attributes?.name ?? app.id)")

        // 2. Find-or-create version.
        let version = try await appsAPI.findOrCreateVersion(
            appID: app.id, versionString: createVersion, platform: platform
        )
        progress?("Using version \(createVersion) (id: \(version.id))")

        var report = Report(
            appID: app.id,
            versionID: version.id,
            versionString: createVersion,
            metadataUpdates: [],
            screenshotUploads: [],
            privacyURLUpdates: [],
            reviewSubmissionID: nil,
            errors: []
        )

        // 3. Metadata.
        if shouldUploadMetadata, let metadataRoot {
            try await uploadMetadata(
                appsAPI: appsAPI,
                versionID: version.id,
                metadataRoot: metadataRoot,
                report: &report,
                progress: progress
            )
        }

        // 4. Screenshots.
        if shouldUploadScreenshots {
            try await uploadScreenshots(
                appsAPI: appsAPI,
                versionID: version.id,
                manifest: manifest,
                renderRoot: renderRoot,
                report: &report,
                progress: progress
            )
        }

        // 5. Submit for review if requested. Must run after screenshots +
        // metadata so the version is complete when Apple picks it up.
        if config.submit?.submitForReview == true {
            do {
                let submission = try await appsAPI.submitForReview(versionID: version.id)
                report.reviewSubmissionID = submission.id
                progress?("Submitted for review (submission id \(submission.id))")
            } catch {
                report.errors.append("submit for review: \(error)")
            }
        }

        return report
    }

    // MARK: - App resolution

    private func resolveApp(appsAPI: AppsAPI) async throws -> AppsAPI.App {
        if let appID = config.appID, !appID.isEmpty {
            return try await appsAPI.lookupApp(id: appID)
        }
        if let bundleID = config.bundleID, !bundleID.isEmpty {
            guard let app = try await appsAPI.lookupApp(bundleID: bundleID) else {
                throw Failure.appNotFound(query: bundleID)
            }
            return app
        }
        throw Failure.missingAppIdentifier
    }

    // MARK: - Metadata

    private func uploadMetadata(
        appsAPI: AppsAPI,
        versionID: String,
        metadataRoot: URL,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async throws {
        var readWarnings: [String] = []
        let byLocale: [String: LocalizationFields]
        do {
            byLocale = try MetadataReader.read(dir: metadataRoot) { readWarnings.append($0) }
        } catch {
            report.errors.append("metadata read: \(error)")
            return
        }
        for warning in readWarnings { progress?("  warn: \(warning)") }

        // Privacy URL lives on App Info, not the version. Resolve the
        // editable AppInfo lazily — only when at least one locale has a
        // privacy URL set.
        var editableAppInfo: AppsAPI.AppInfo?
        let anyPrivacyURLSet = byLocale.values.contains { $0.privacyPolicyURL != nil }
        if anyPrivacyURLSet {
            do {
                editableAppInfo = try await appsAPI.findEditableAppInfo(appID: report.appID)
                if editableAppInfo == nil {
                    report.errors.append("privacy URL: no editable appInfo for app \(report.appID)")
                }
            } catch {
                report.errors.append("privacy URL: failed to list appInfos: \(error)")
            }
        }

        for (locale, fields) in byLocale.sorted(by: { $0.key < $1.key }) {
            guard fields.hasAnyField else { continue }

            // Version localization PATCH — covers description / keywords /
            // whatsNew / support / marketing / promotional / subtitle / name.
            do {
                let localization = try await appsAPI.findOrCreateLocalization(
                    versionID: versionID, locale: locale
                )
                _ = try await appsAPI.updateLocalization(id: localization.id, fields: fields)
                let names = updatedFieldNames(fields)
                if !names.isEmpty {
                    report.metadataUpdates.append(.init(locale: locale, fieldsUpdated: names))
                    progress?("metadata \(locale): updated \(names.joined(separator: ", "))")
                }
            } catch {
                report.errors.append("metadata \(locale): \(error)")
            }

            // AppInfo localization PATCH — privacy URL only.
            if let privacyURL = fields.privacyPolicyURL, let appInfo = editableAppInfo {
                do {
                    let ail = try await appsAPI.findOrCreateAppInfoLocalization(
                        appInfoID: appInfo.id, locale: locale
                    )
                    _ = try await appsAPI.updateAppInfoLocalization(
                        id: ail.id, privacyPolicyURL: privacyURL
                    )
                    report.privacyURLUpdates.append(locale)
                    progress?("privacy \(locale): updated privacyPolicyUrl")
                } catch {
                    report.errors.append("privacy URL \(locale): \(error)")
                }
            }
        }
    }

    private func updatedFieldNames(_ fields: LocalizationFields) -> [String] {
        // Privacy URL is deliberately excluded — it's patched on the
        // appInfoLocalization, not the version localization, and reported
        // separately via `report.privacyURLUpdates`.
        var names: [String] = []
        if fields.name != nil { names.append("name") }
        if fields.subtitle != nil { names.append("subtitle") }
        if fields.description != nil { names.append("description") }
        if fields.keywords != nil { names.append("keywords") }
        if fields.promotionalText != nil { names.append("promotionalText") }
        if fields.whatsNew != nil { names.append("whatsNew") }
        if fields.supportURL != nil { names.append("supportURL") }
        if fields.marketingURL != nil { names.append("marketingURL") }
        return names
    }

    // MARK: - Screenshots

    private func uploadScreenshots(
        appsAPI: AppsAPI,
        versionID: String,
        manifest: CaptureManifest,
        renderRoot: URL,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async throws {
        let screenshotsAPI = ScreenshotsAPI(client: client)

        // Group manifest entries by (locale, device) so we can open one
        // screenshot set per pair.
        struct Key: Hashable { let locale: String; let displayType: String }
        var byKey: [Key: [(URL, String, Int)]] = [:]

        for device in manifest.devices {
            let pf = productFamilyFromDeviceType(device.deviceType)
            // Each device/locale combo: resolve displayType using the FIRST
            // screenshot's pixel dims (all screenshots in the same device
            // are assumed to share dimensions).
            for shot in device.screenshots {
                let fileURL = renderRoot.appendingPathComponent(shot.filename)
                guard let (w, h) = readPixelDims(at: fileURL) else {
                    report.errors.append("cannot read dims of \(shot.filename)")
                    continue
                }
                guard let displayType = ScreenshotDisplayType.resolve(
                    productFamily: pf, width: w, height: h
                ) else {
                    report.errors.append("no ASC display type for \(w)x\(h) in \(shot.filename)")
                    continue
                }
                let locale = device.locale ?? "en-US"
                byKey[Key(locale: locale, displayType: displayType), default: []]
                    .append((fileURL, shot.filename, manifest.devices.firstIndex(where: { $0.deviceType == device.deviceType }) ?? 0))
            }
        }

        // Upload per (locale, displayType) group. Reuse existing localization
        // if present, else create it.
        for (key, items) in byKey.sorted(by: { ($0.key.locale, $0.key.displayType) < ($1.key.locale, $1.key.displayType) }) {
            do {
                let localization = try await appsAPI.findOrCreateLocalization(
                    versionID: versionID, locale: key.locale
                )
                let set = try await screenshotsAPI.findOrCreateSet(
                    localizationID: localization.id,
                    displayType: key.displayType
                )

                // Wipe existing screenshots in the set so fresh uploads
                // become the source of truth.
                let existing = try await screenshotsAPI.listScreenshots(setID: set.id)
                for e in existing { try await screenshotsAPI.deleteScreenshot(id: e.id) }

                // Upload in manifest order (key.items were appended in
                // manifest order earlier).
                var count = 0
                for (fileURL, filename, _) in items {
                    progress?("\(key.locale) \(key.displayType): uploading \(filename)")
                    _ = try await screenshotsAPI.uploadScreenshot(setID: set.id, fileURL: fileURL)
                    count += 1
                }
                report.screenshotUploads.append(.init(
                    locale: key.locale, displayType: key.displayType, count: count
                ))
            } catch {
                report.errors.append("screenshots \(key.locale)/\(key.displayType): \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func productFamilyFromDeviceType(_ deviceType: String) -> Int {
        RenderPipeline.productFamilyFromDeviceType(deviceType)
    }

    /// Reads the pixel dimensions of a PNG without fully decoding it.
    private func readPixelDims(at url: URL) -> (Int, Int)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Image I/O is the cheapest way to get dims without a full decode.
        #if canImport(ImageIO)
        let sourceClass = NSClassFromString("CGImageSource") as AnyObject?
        _ = sourceClass
        #endif
        return readPixelDimsImageIO(url: url)
    }
}

#if canImport(ImageIO)
import ImageIO

private func readPixelDimsImageIO(url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
}
#else
private func readPixelDimsImageIO(url: URL) -> (Int, Int)? { nil }
#endif
