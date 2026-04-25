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
        package var attachedBuildNumber: String?      // ASC build number attached to the version
        package var exportComplianceSet: Bool         // true when we patched usesNonExemptEncryption
        package var reviewSubmissionID: String?
        /// Set when pricing was applied this run (e.g. "free", or "unchanged"
        /// when the schedule already existed). Nil when no pricing config was
        /// supplied or when the step was skipped.
        package var pricingStatus: String?
        /// Set when availability was applied this run. Nil when no
        /// availability config was supplied.
        package var availabilityStatus: String?
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
        screenshotOrder: [String]? = nil,
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
            attachedBuildNumber: nil,
            exportComplianceSet: false,
            reviewSubmissionID: nil,
            pricingStatus: nil,
            availabilityStatus: nil,
            errors: []
        )

        // 2b. Pricing & Availability. These live at the app level, not the
        // version level, so they run once per submit and are gated on
        // their own config blocks (nil config = skip). Errors here are
        // non-fatal — append to the report and keep going so the rest of
        // the submit flow still makes progress.
        if config.pricing != nil || config.availability != nil {
            await applyPricingAndAvailability(
                appID: app.id, report: &report, progress: progress
            )
        }

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

        // 4. Screenshots. Apply the top-level `screenshots:` list order
        // before upload so the App Store Connect gallery matches the
        // render + preview gallery. The manifest is still alpha-sorted
        // from the capture step; applyOrder reshuffles to match the
        // config list, with anything unlisted appended at the end.
        if shouldUploadScreenshots {
            let orderedManifest: CaptureManifest = {
                guard let order = screenshotOrder, !order.isEmpty else { return manifest }
                let reorderedDevices = manifest.devices.map { dev in
                    CaptureManifest.DeviceCapture(
                        deviceType: dev.deviceType,
                        simulatorName: dev.simulatorName,
                        locale: dev.locale,
                        appearance: dev.appearance,
                        screenshots: RenderPipeline.applyOrder(dev.screenshots, order: order)
                    )
                }
                return CaptureManifest(
                    version: manifest.version,
                    generatedAt: manifest.generatedAt,
                    generatedBy: manifest.generatedBy,
                    appName: manifest.appName,
                    displayName: manifest.displayName,
                    scheme: manifest.scheme,
                    devices: reorderedDevices
                )
            }()
            try await uploadScreenshots(
                appsAPI: appsAPI,
                versionID: version.id,
                manifest: orderedManifest,
                renderRoot: renderRoot,
                report: &report,
                progress: progress
            )
        }

        // 4b. Attach the latest VALID build to the version, and (if
        // configured) set export compliance on that build. Without
        // these two steps the version shows "Missing Build" and
        // "Missing Compliance" in App Store Connect and can't be
        // submitted for review. Defaults: attach on, export
        // compliance = `.none` (app uses only standard iOS
        // cryptography covered by Apple's exemption).
        let attachBuildEnabled = config.submit?.attachBuild ?? true
        if attachBuildEnabled {
            let buildsAPI = BuildsAPI(client: client)
            do {
                if let build = try await buildsAPI.latestValidBuild(
                    appID: app.id,
                    marketingVersion: createVersion,
                    platform: platform
                ) {
                    // Both PATCHes are idempotent from the user's
                    // perspective: re-running submit after values are
                    // already on the version/build should be a no-op,
                    // not a noisy 409 error. ASC returns a 409 with
                    // "already set" / "already attached" text when the
                    // attribute already matches; `isAlreadySetConflict`
                    // detects that and we swallow it as success.
                    do {
                        try await appsAPI.attachBuild(versionID: version.id, buildID: build.id)
                        progress?("attached build \(build.attributes?.version ?? build.id) to version \(createVersion)")
                    } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                        progress?("build \(build.attributes?.version ?? build.id) already attached to version \(createVersion)")
                    }
                    report.attachedBuildNumber = build.attributes?.version

                    // Set export compliance on the attached build.
                    let complianceSetting = config.submit?.exportCompliance ?? .none
                    if let answer = complianceSetting.usesNonExemptEncryption {
                        do {
                            try await buildsAPI.setExportCompliance(
                                buildID: build.id,
                                usesNonExemptEncryption: answer
                            )
                            progress?("export compliance set: usesNonExemptEncryption=\(answer)")
                        } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                            progress?("export compliance already set for build \(build.attributes?.version ?? build.id)")
                        }
                        report.exportComplianceSet = true
                    }
                } else {
                    report.errors.append("attach build: no VALID build found for \(createVersion) — wait for Apple's processing to finish (usually 10-30 min after upload-build), then re-run submit")
                }
            } catch {
                report.errors.append("attach build: \(error)")
            }
        }

        // 5. Submit for review if requested. Must run after screenshots +
        // metadata so the version is complete when Apple picks it up.
        // Idempotent on the version-already-submitted path: ASC returns
        // 409 STATE_ERROR.ENTITY_STATE_INVALID when the version is no
        // longer editable, which from submit's perspective means "the
        // thing you asked for has already happened" — surface as a
        // progress line, not a failure.
        if config.submit?.submitForReview == true {
            do {
                // 3-step reviewSubmissions flow: create, add version, finalize.
                let submission = try await appsAPI.submitForReview(
                    appID: app.id, versionID: version.id, platform: platform
                )
                report.reviewSubmissionID = submission.id
                progress?("Submitted for review (submission id \(submission.id))")
            } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                progress?("version \(createVersion) is already submitted for review")
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
        var byLocale: [String: LocalizationFields]
        do {
            byLocale = try MetadataReader.read(dir: metadataRoot) { readWarnings.append($0) }
        } catch {
            report.errors.append("metadata read: \(error)")
            return
        }
        for warning in readWarnings { progress?("  warn: \(warning)") }

        // whatsNew (release notes) is only valid on an update — ASC rejects
        // it on the first version of a brand-new app. Detect that case by
        // listing the app's versions and checking whether any *other* version
        // has reached a released or pending-release state. If none has, this
        // is a first-version submission: strip whatsNew from every locale
        // before the PATCH so the metadata step doesn't fail wholesale.
        let platform = config.submit?.platform ?? "IOS"
        let localesWithWhatsNew = byLocale.filter { $0.value.whatsNew != nil }.map(\.key)
        if !localesWithWhatsNew.isEmpty {
            let hasPrior: Bool
            do {
                hasPrior = try await appsAPI.hasPreviouslyReleasedVersion(
                    appID: report.appID,
                    excludingVersionID: versionID,
                    platform: platform
                )
            } catch {
                // If the check itself fails, don't silently drop release
                // notes — let the PATCH go through and surface any ASC
                // rejection through the normal error path.
                progress?("whatsNew prior-version check failed: \(error) — sending release notes as-is")
                hasPrior = true
            }
            if !hasPrior {
                for locale in localesWithWhatsNew {
                    byLocale[locale]?.whatsNew = nil
                }
                progress?("skipping whatsNew (\(localesWithWhatsNew.count) locale(s)): ASC rejects release notes on an app's first version")
            }
        }

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
            // whatsNew / support / marketing / promotional. Diff against the
            // current ASC values so unchanged fields don't re-PATCH; if
            // nothing differs we skip the PATCH entirely.
            do {
                let localization = try await appsAPI.findOrCreateLocalization(
                    versionID: versionID, locale: locale
                )
                let diff = changedVersionLocalizationFields(
                    desired: fields, current: localization.attributes
                )
                if diff.hasAnyField {
                    _ = try await appsAPI.updateLocalization(id: localization.id, fields: diff)
                    let names = updatedFieldNames(diff)
                    report.metadataUpdates.append(.init(locale: locale, fieldsUpdated: names))
                    progress?("metadata \(locale): updated \(names.joined(separator: ", "))")
                } else {
                    progress?("metadata \(locale): unchanged")
                }
            } catch {
                report.errors.append("metadata \(locale): \(error)")
            }

            // AppInfo localization PATCH — privacy URL only. Skip if the
            // current value on ASC already matches.
            if let privacyURL = fields.privacyPolicyURL, let appInfo = editableAppInfo {
                do {
                    let ail = try await appsAPI.findOrCreateAppInfoLocalization(
                        appInfoID: appInfo.id, locale: locale
                    )
                    if ail.attributes?.privacyPolicyUrl == privacyURL {
                        progress?("privacy \(locale): unchanged")
                    } else {
                        _ = try await appsAPI.updateAppInfoLocalization(
                            id: ail.id, privacyPolicyURL: privacyURL
                        )
                        report.privacyURLUpdates.append(locale)
                        progress?("privacy \(locale): updated privacyPolicyUrl")
                    }
                } catch {
                    report.errors.append("privacy URL \(locale): \(error)")
                }
            }
        }
    }

    /// Returns a LocalizationFields carrying only the version-level fields
    /// that actually differ from ASC's current state. Fields that don't
    /// belong on the version localization endpoint (name, subtitle,
    /// privacyPolicyURL) are always nil here — they're handled elsewhere or
    /// not sent at all.
    private func changedVersionLocalizationFields(
        desired: LocalizationFields,
        current: AppsAPI.Localization.Attributes?
    ) -> LocalizationFields {
        func diff(_ new: String?, _ old: String?) -> String? {
            guard let new else { return nil }
            return new == (old ?? "") ? nil : new
        }
        return LocalizationFields(
            description:     diff(desired.description,     current?.description),
            keywords:        diff(desired.keywords,        current?.keywords),
            promotionalText: diff(desired.promotionalText, current?.promotionalText),
            whatsNew:        diff(desired.whatsNew,        current?.whatsNew),
            supportURL:      diff(desired.supportURL,      current?.supportUrl),
            marketingURL:    diff(desired.marketingURL,    current?.marketingUrl)
        )
    }

    private func updatedFieldNames(_ fields: LocalizationFields) -> [String] {
        // Only lists fields that actually went out in the PATCH. Version
        // localization doesn't carry name/subtitle (those live on the
        // appInfoLocalization) and privacyPolicyURL is reported separately
        // via `report.privacyURLUpdates`.
        var names: [String] = []
        if fields.description != nil { names.append("description") }
        if fields.keywords != nil { names.append("keywords") }
        if fields.promotionalText != nil { names.append("promotionalText") }
        if fields.whatsNew != nil { names.append("whatsNew") }
        if fields.supportURL != nil { names.append("supportURL") }
        if fields.marketingURL != nil { names.append("marketingURL") }
        return names
    }

    // MARK: - Pricing & Availability

    /// Runs the Pricing and Availability API calls for the app. Both are
    /// independent of the version localization flow — they sit at the app
    /// level in ASC and are required-before-first-submit. The method reads
    /// `config.pricing` and `config.availability` and applies whichever is
    /// set, leaving a status line on the report for each. Errors are
    /// captured in `report.errors` rather than thrown so the broader submit
    /// flow can still finish.
    private func applyPricingAndAvailability(
        appID: String,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async {
        let api = PricingAvailabilityAPI(client: client)

        if let pricing = config.pricing {
            do {
                try await applyPricing(api: api, appID: appID, pricing: pricing, report: &report, progress: progress)
            } catch {
                report.errors.append("pricing: \(error)")
            }
        }

        if let availability = config.availability {
            do {
                try await applyAvailability(api: api, appID: appID, availability: availability, report: &report, progress: progress)
            } catch {
                report.errors.append("availability: \(error)")
            }
        }
    }

    private func applyPricing(
        api: PricingAvailabilityAPI,
        appID: String,
        pricing: PricingConfig,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async throws {
        let free = pricing.free ?? false
        guard free else {
            // Paid pricing is not yet supported; surface a clear message
            // rather than silently succeeding.
            report.errors.append("pricing: only `free: true` is supported today; paid pricing is not implemented")
            return
        }

        // Idempotent: if the app already has a price schedule, don't
        // replace it — creating a new schedule is destructive to whatever
        // the developer set up in the ASC web UI.
        if try await api.hasExistingPriceSchedule(appID: appID) {
            report.pricingStatus = "unchanged"
            progress?("pricing: schedule already exists, leaving untouched")
            return
        }

        let base = pricing.baseTerritory ?? "USA"
        guard let pricePoint = try await api.findFreePricePoint(appID: appID, territoryID: base) else {
            report.errors.append("pricing: no free price point for base territory \(base)")
            return
        }

        _ = try await api.createPriceSchedule(
            appID: appID, baseTerritoryID: base, pricePointID: pricePoint.id
        )
        report.pricingStatus = "free (base: \(base))"
        progress?("pricing: set to free with base territory \(base)")
    }

    private func applyAvailability(
        api: PricingAvailabilityAPI,
        appID: String,
        availability: AvailabilityConfig,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async throws {
        guard let selection = availability.territories else {
            // No territories = no-op; only availableInNewTerritories would
            // be set, which needs a create call with the full territory
            // list anyway. Skip to avoid accidental "limit to zero
            // territories" API calls.
            return
        }
        let desiredNewTerritories = availability.availableInNewTerritories ?? true

        let desiredTerritoryIDs: Set<String>
        switch selection {
        case .all:
            desiredTerritoryIDs = Set(try await api.listTerritories().map(\.id))
        case .list(let list):
            desiredTerritoryIDs = Set(list)
        }
        guard !desiredTerritoryIDs.isEmpty else {
            report.errors.append("availability: territory list is empty")
            return
        }

        // Diff against current availability when one exists so we don't
        // re-POST for a no-op. A missing availability (new app) always
        // means create.
        if let current = try await api.getCurrentAvailability(appID: appID) {
            let currentTerritories = (try? await api.listAvailableTerritories(availabilityID: current.id)) ?? []
            let sameSet = currentTerritories == desiredTerritoryIDs
            let sameNewFlag = current.attributes?.availableInNewTerritories == desiredNewTerritories
            if sameSet && sameNewFlag {
                report.availabilityStatus = "unchanged"
                progress?("availability: unchanged (\(desiredTerritoryIDs.count) territories)")
                return
            }
        }

        _ = try await api.createAvailability(
            appID: appID,
            territoryIDs: Array(desiredTerritoryIDs),
            availableInNewTerritories: desiredNewTerritories
        )
        report.availabilityStatus = "updated (\(desiredTerritoryIDs.count) territories, new territories: \(desiredNewTerritories))"
        progress?("availability: set \(desiredTerritoryIDs.count) territories, availableInNewTerritories=\(desiredNewTerritories)")
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

                let existing = try await screenshotsAPI.listScreenshots(setID: set.id)

                // Idempotency: if the existing set matches the local render
                // in content + order, skip the whole wipe+reupload. ASC
                // stores MD5 of the file bytes in sourceFileChecksum, the
                // same shape we compute here from the local render PNG.
                let localChecksums = items.map { (fileURL, _, _) -> String in
                    let data = (try? Data(contentsOf: fileURL)) ?? Data()
                    return ScreenshotsAPI.md5Hex(data: data)
                }
                let existingChecksums = existing.map { $0.attributes?.sourceFileChecksum ?? "" }
                let unchanged = !localChecksums.isEmpty
                    && localChecksums == existingChecksums
                    && !localChecksums.contains("")
                    && !existingChecksums.contains("")

                if unchanged {
                    progress?("\(key.locale) \(key.displayType): unchanged (\(items.count) screenshot(s))")
                    report.screenshotUploads.append(.init(
                        locale: key.locale, displayType: key.displayType, count: 0
                    ))
                    continue
                }

                // Wipe existing screenshots in the set so fresh uploads
                // become the source of truth.
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
