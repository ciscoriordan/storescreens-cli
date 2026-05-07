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

    /// How long to wait between `getReviewSubmission` polls when waiting for
    /// a `cancel` PATCH to settle. Nanoseconds. Default 1s; tests pass 0.
    package let settlePollInterval: UInt64

    /// Max number of poll attempts before giving up on the cancel settling.
    /// Default 30 (~30s with default interval); tests pass 0 to skip
    /// polling entirely.
    package let settlePollMaxAttempts: Int

    package init(
        client: ASCClient,
        config: AppStoreConnectConfig,
        settlePollInterval: UInt64 = 1_000_000_000,  // 1s
        settlePollMaxAttempts: Int = 30
    ) {
        self.client = client
        self.config = config
        self.settlePollInterval = settlePollInterval
        self.settlePollMaxAttempts = settlePollMaxAttempts
    }

    // MARK: - Report

    package struct Report: Sendable {
        package var appID: String
        package var versionID: String
        package var versionString: String
        /// Per-locale field updates against `appStoreVersionLocalizations`.
        /// Covers description, keywords, promotionalText, whatsNew,
        /// supportURL, marketingURL.
        package var metadataUpdates: [MetadataUpdate]
        /// Per-locale field updates against `appInfoLocalizations` (the
        /// app-level resource where name, subtitle, and the privacy URLs
        /// live). Empty when no `name.txt` / `subtitle.txt` /
        /// `privacy_url.txt` / `privacy_choices_url.txt` were present, or
        /// when none of them differed from ASC's current value, or when
        /// no editable AppInfo could be located.
        package var appInfoUpdates: [MetadataUpdate]
        package var screenshotUploads: [ScreenshotUpload]
        /// Locales where the privacy policy URL was successfully PATCHed
        /// onto `appInfoLocalizations`. Kept for backwards-compatibility
        /// with earlier report consumers; same data is also reflected in
        /// `appInfoUpdates` under the `privacyPolicyURL` field.
        package var privacyURLUpdates: [String]
        package var attachedBuildNumber: String?      // ASC build number attached to the version
        package var exportComplianceSet: Bool         // true when we patched usesNonExemptEncryption
        package var reviewSubmissionID: String?
        /// Final state of the new review submission after the submit-for-review
        /// flow. Typically `WAITING_FOR_REVIEW` on success; `READY_FOR_REVIEW`
        /// when `submit_for_review: false` and the orchestrator only created
        /// the draft submission. Nil when submit-for-review was not requested.
        package var reviewSubmissionState: String?
        /// IDs of any prior `reviewSubmissions` we canceled before creating
        /// the new one (UNRESOLVED_ISSUES from a rejection, or stale
        /// READY_FOR_REVIEW from an aborted run). Empty when there was
        /// nothing to clean up.
        package var canceledReviewSubmissionIDs: [String]
        /// True when the version-level review-detail (notes + contact info)
        /// was PATCHed this run. False when no review fields were configured
        /// or all values matched what ASC already had.
        package var reviewDetailUpdated: Bool
        /// Set when pricing was applied this run (e.g. "free", or "unchanged"
        /// when the schedule already existed). Nil when no pricing config was
        /// supplied or when the step was skipped.
        package var pricingStatus: String?
        /// Set when availability was applied this run. Nil when no
        /// availability config was supplied.
        package var availabilityStatus: String?
        /// Set when category assignments were applied this run
        /// ("updated: primary, secondary", "unchanged", or
        /// "skipped: no editable appInfo"). Nil when no `categories:`
        /// block was supplied.
        package var categoriesStatus: String?
        /// Set when age-rating answers were applied this run
        /// ("updated: <fields>", "unchanged", or "skipped: ..."). Nil
        /// when no `age_rating:` block was supplied.
        package var ageRatingStatus: String?
        /// Set when the orchestrator detected appInfo-level fields
        /// (name/subtitle/privacy URLs) but couldn't find an editable
        /// AppInfo to PATCH them onto. Common cause: the live version is
        /// `READY_FOR_SALE` and no new editable version has been created
        /// yet. Surfaced for the CLI report so the operator sees why
        /// name/subtitle weren't applied.
        package var appInfoSkipped: AppInfoSkipReason?
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

        package enum AppInfoSkipReason: Sendable {
            /// `GET /v1/apps/{id}/appInfos` returned no record in any
            /// editable state. Operator must create a new editable version
            /// to unblock name/subtitle updates.
            case noEditableAppInfo
            /// `GET /v1/apps/{id}/appInfos` itself failed (network /
            /// auth / 5xx). Surfaces the underlying message.
            case lookupFailed(message: String)
        }
    }

    package enum Failure: Error, CustomStringConvertible {
        case missingAppIdentifier
        case appNotFound(query: String)
        case missingCreateVersion
        case unsupportedScreenshotDims(file: String, w: Int, h: Int)
        /// A prior `reviewSubmission` is in WAITING_FOR_REVIEW or IN_REVIEW
        /// and we refuse to auto-cancel it. Operator must cancel it via the
        /// ASC web UI before re-running submit-for-review.
        case activeReviewInProgress(submissionID: String, state: String)

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
            case .activeReviewInProgress(let id, let state):
                return "an active review submission (\(id), state \(state)) is in progress; cancel it via the App Store Connect web UI before re-running submit-for-review"
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
            appInfoUpdates: [],
            screenshotUploads: [],
            privacyURLUpdates: [],
            attachedBuildNumber: nil,
            exportComplianceSet: false,
            reviewSubmissionID: nil,
            reviewSubmissionState: nil,
            canceledReviewSubmissionIDs: [],
            reviewDetailUpdated: false,
            pricingStatus: nil,
            availabilityStatus: nil,
            categoriesStatus: nil,
            ageRatingStatus: nil,
            appInfoSkipped: nil,
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

        // 2c. AppInfo-level metadata (categories + age rating). These
        // both live on the editable AppInfo / its auto-created
        // ageRatingDeclaration child. Resolve the editable AppInfo
        // once and reuse it for both calls. Each subsection is gated
        // on its own config block (nil = skip).
        if config.categories != nil || config.ageRating != nil {
            await applyAppInfoMetadata(
                appsAPI: appsAPI,
                appID: app.id,
                report: &report,
                progress: progress
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
        } else if let yamlReview = config.reviewInfo?.asReviewDetailFields,
                  yamlReview.hasAnyField {
            // No metadata dir, but the user supplied `review_info:` in
            // YAML — still apply it. `appStoreReviewDetails` is
            // version-scoped, not locale-scoped, so the metadata dir is
            // irrelevant here.
            await applyReviewDetail(
                appsAPI: appsAPI,
                versionID: version.id,
                desired: yamlReview,
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
        if config.submit?.submitForReview == true {
            await runSubmitForReview(
                appsAPI: appsAPI,
                appID: app.id,
                versionID: version.id,
                versionString: createVersion,
                platform: platform,
                report: &report,
                progress: progress
            )
        }

        return report
    }

    // MARK: - Submit for review (with pre-flight cleanup)

    /// Drives the 3-step `reviewSubmissions` flow with the cleanup phase
    /// that's missing from the bare `appsAPI.submitForReview` convenience:
    ///
    /// 1. List existing reviewSubmissions for the app.
    /// 2. If any are in WAITING_FOR_REVIEW or IN_REVIEW: bail loudly.
    ///    Operator must cancel via the ASC web UI; we won't pull the rug
    ///    out from under an active Apple review.
    /// 3. If any are in READY_FOR_REVIEW (stale draft from an aborted
    ///    submit) or UNRESOLVED_ISSUES (a rejected submission still
    ///    "owning" the version): PATCH `canceled: true`. Poll until the
    ///    state settles to COMPLETE so the next POST sees a freed version.
    /// 4. Create a fresh submission, attach the version (POST item), PATCH
    ///    `submitted: true` to push it into WAITING_FOR_REVIEW.
    ///
    /// Errors at each step land in `report.errors`; the orchestrator never
    /// throws here so the rest of the report is preserved.
    private func runSubmitForReview(
        appsAPI: AppsAPI,
        appID: String,
        versionID: String,
        versionString: String,
        platform: String,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async {
        // Step 1+2+3: cleanup pre-existing submissions that would block us.
        do {
            try await cancelStaleReviewSubmissions(
                appsAPI: appsAPI,
                appID: appID,
                platform: platform,
                report: &report,
                progress: progress
            )
        } catch let e as Failure {
            report.errors.append("submit for review: \(e)")
            return
        } catch {
            report.errors.append("submit for review (cleanup): \(error)")
            return
        }

        // Step 4: create + attach + finalize.
        do {
            let submission = try await appsAPI.createReviewSubmission(appID: appID, platform: platform)
            report.reviewSubmissionID = submission.id
            report.reviewSubmissionState = submission.attributes?.state
            progress?("submit for review: created submission \(submission.id) (state: \(submission.attributes?.state ?? "?"))")

            do {
                _ = try await appsAPI.addVersionToReviewSubmission(
                    reviewSubmissionID: submission.id, versionID: versionID
                )
            } catch let e as ASCClient.APIError {
                // The "version is already attached" path: Apple returns 409
                // ENTITY_STATE_INVALID with "Item is already present in
                // [other-submission]". Cleanup should have handled this -
                // if we still hit it, surface the original error so the
                // operator sees it instead of swallowing.
                report.errors.append("submit for review: failed to attach version \(versionString) to new submission \(submission.id): \(e)")
                return
            }
            progress?("submit for review: attached version \(versionString) to submission")

            let finalized = try await appsAPI.finalizeReviewSubmission(id: submission.id)
            report.reviewSubmissionState = finalized.attributes?.state
            let finalState = finalized.attributes?.state ?? "?"
            if finalState == "WAITING_FOR_REVIEW" {
                progress?("submit for review: submitted (state: \(finalState))")
            } else {
                // Apple sometimes responds 200 with a transient state. Don't
                // treat it as a hard failure - just surface so the operator
                // can poll the ASC web UI.
                progress?("submit for review: PATCH submitted=true returned state \(finalState) (expected WAITING_FOR_REVIEW)")
            }
        } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
            // Hit if the version was somehow already attached + finalized.
            progress?("version \(versionString) is already submitted for review")
        } catch {
            report.errors.append("submit for review: \(error)")
        }
    }

    /// Pre-flight cleanup: cancel any reviewSubmissions for this app that
    /// would block creating a new one. Throws `Failure.activeReviewInProgress`
    /// when an in-flight review is found that we refuse to auto-cancel.
    private func cancelStaleReviewSubmissions(
        appsAPI: AppsAPI,
        appID: String,
        platform: String,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async throws {
        let existing: [AppsAPI.ReviewSubmission]
        do {
            existing = try await appsAPI.listReviewSubmissions(appID: appID, platform: platform)
        } catch {
            // If we can't list submissions we can't reason about cleanup;
            // proceed anyway so a brand-new app (no submissions yet) still
            // works. Surface the read failure as a progress note.
            progress?("submit for review: could not list existing submissions (\(error)); continuing")
            return
        }

        // Bail loudly on active reviews. Refuse to cancel.
        if let active = existing.first(where: {
            let s = $0.attributes?.state ?? ""
            return AppsAPI.activeReviewSubmissionStates.contains(s)
        }) {
            throw Failure.activeReviewInProgress(
                submissionID: active.id,
                state: active.attributes?.state ?? "?"
            )
        }

        let cancellable = existing.filter {
            let s = $0.attributes?.state ?? ""
            return AppsAPI.cancellableReviewSubmissionStates.contains(s)
        }
        guard !cancellable.isEmpty else { return }

        for sub in cancellable {
            let originalState = sub.attributes?.state ?? "?"
            do {
                _ = try await appsAPI.cancelReviewSubmission(id: sub.id)
                progress?("submit for review: canceled prior submission \(sub.id) (was \(originalState))")
                report.canceledReviewSubmissionIDs.append(sub.id)
                // Poll until the cancel settles. Apple typically transitions
                // to COMPLETE within a few seconds; poll up to ~30s with
                // 1-second backoff.
                try await waitForSubmissionToSettle(appsAPI: appsAPI, id: sub.id)
            } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                // Submission already in a non-cancellable end state. Treat
                // as success: nothing more to do.
                progress?("submit for review: prior submission \(sub.id) already finalized")
                report.canceledReviewSubmissionIDs.append(sub.id)
            }
            // Other errors propagate up so submit-for-review aborts; we
            // don't want to charge ahead and POST a new submission while
            // a stale one is still attached to the version.
        }
    }

    /// Polls `getReviewSubmission` until the state leaves the canceling /
    /// active set (i.e. settles to COMPLETE or any other terminal state).
    /// Times out after `settlePollMaxAttempts * settlePollInterval`; doesn't
    /// throw on timeout - the worst case is the next POST will fail loudly
    /// with ENTITY_STATE_INVALID, which the orchestrator surfaces as an
    /// error.
    private func waitForSubmissionToSettle(
        appsAPI: AppsAPI, id: String
    ) async throws {
        // States that mean the submission still "owns" the version. Once
        // we leave this set, the next POST item should succeed.
        let pendingStates: Set<String> = [
            "READY_FOR_REVIEW", "UNRESOLVED_ISSUES", "CANCELING",
            "WAITING_FOR_REVIEW", "IN_REVIEW",
        ]
        for _ in 0..<settlePollMaxAttempts {
            do {
                let cur = try await appsAPI.getReviewSubmission(id: id)
                let state = cur.attributes?.state ?? ""
                if !pendingStates.contains(state) { return }
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                // Submission disappeared - cleanup succeeded.
                return
            }
            try? await Task.sleep(nanoseconds: settlePollInterval)
        }
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
        let fileReviewDetail: ReviewDetailFields?
        do {
            let read = try MetadataReader.readAll(dir: metadataRoot) { readWarnings.append($0) }
            byLocale = read.localizations
            fileReviewDetail = read.reviewDetail
        } catch {
            report.errors.append("metadata read: \(error)")
            return
        }
        for warning in readWarnings { progress?("  warn: \(warning)") }

        // Review detail (notes + contact info) lives at the version level
        // (not per locale) on Apple's side, so we PATCH it once. Fire it
        // before the per-locale loop so contact info is on the version
        // before any reviewer might see it. Merge precedence: YAML
        // `review_info:` wins over per-locale `review_*.txt` files.
        let reviewDetail = mergeReviewDetail(
            yaml: config.reviewInfo?.asReviewDetailFields,
            file: fileReviewDetail
        )
        if let reviewDetail, reviewDetail.hasAnyField {
            await applyReviewDetail(
                appsAPI: appsAPI,
                versionID: versionID,
                desired: reviewDetail,
                report: &report,
                progress: progress
            )
        }

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

        // appInfoLocalizations carry name, subtitle, privacyPolicyUrl, and
        // privacyChoicesUrl — all four live at the app level, not on the
        // version localization. Resolve the editable AppInfo lazily and
        // only when at least one locale has any of those fields set, so
        // submits that only touch description/keywords don't pay the
        // appInfos GET. When no editable AppInfo exists (e.g. the live
        // version is READY_FOR_SALE and no new editable version has been
        // created yet) ASC won't accept these PATCHes — we log a clear
        // skip reason and continue with the version-level fields rather
        // than failing the whole submit.
        var editableAppInfo: AppsAPI.AppInfo?
        let anyAppInfoFieldSet = byLocale.values.contains { fields in
            MetadataReader.hasAppInfoFields(fields)
        }
        if anyAppInfoFieldSet {
            do {
                editableAppInfo = try await appsAPI.findEditableAppInfo(appID: report.appID)
                if let editable = editableAppInfo {
                    let state = editable.attributes?.state
                        ?? editable.attributes?.appStoreState ?? "?"
                    progress?("appInfo: editable record \(editable.id) (state: \(state))")
                } else {
                    let names = appInfoFieldsSummary(byLocale: byLocale)
                    report.appInfoSkipped = .noEditableAppInfo
                    progress?(
                        "Skipped \(names) update — no editable appInfo (create a new editable version first)"
                    )
                }
            } catch {
                report.appInfoSkipped = .lookupFailed(message: "\(error)")
                report.errors.append("appInfo lookup: \(error)")
            }
        }

        for (locale, fields) in byLocale.sorted(by: { $0.key < $1.key }) {
            guard fields.hasAnyField else { continue }

            // Version localization PATCH — covers description / keywords /
            // whatsNew / support / marketing / promotional. Diff against the
            // current ASC values so unchanged fields don't re-PATCH; if
            // nothing differs we skip the PATCH entirely. Skip the
            // find-or-create entirely when the locale only has appInfo
            // fields — no need to reach the version localization endpoint.
            if MetadataReader.hasVersionLocalizationFields(fields) {
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
                        progress?("metadata \(locale) [version]: updated \(names.joined(separator: ", "))")
                    } else {
                        progress?("metadata \(locale) [version]: unchanged")
                    }
                } catch {
                    report.errors.append("metadata \(locale): \(error)")
                }
            }

            // AppInfoLocalization PATCH — covers name, subtitle,
            // privacyPolicyUrl, privacyChoicesUrl. Skip when no editable
            // AppInfo was located (warning already logged above) or when
            // the locale carries no appInfo-level fields.
            guard MetadataReader.hasAppInfoFields(fields), let appInfo = editableAppInfo else {
                continue
            }
            do {
                let ail = try await appsAPI.findOrCreateAppInfoLocalization(
                    appInfoID: appInfo.id, locale: locale
                )
                let diff = changedAppInfoLocalizationFields(
                    desired: fields, current: ail.attributes
                )
                if diff.hasAnyField {
                    _ = try await appsAPI.updateAppInfoLocalization(
                        id: ail.id, fields: diff
                    )
                    let names = appInfoUpdatedFieldNames(diff)
                    report.appInfoUpdates.append(.init(locale: locale, fieldsUpdated: names))
                    if diff.privacyPolicyURL != nil {
                        report.privacyURLUpdates.append(locale)
                    }
                    progress?("metadata \(locale) [appInfo]: updated \(names.joined(separator: ", "))")
                } else {
                    progress?("metadata \(locale) [appInfo]: unchanged")
                }
            } catch {
                report.errors.append("appInfo \(locale): \(error)")
            }
        }
    }

    /// Returns a comma-separated list of appInfo-level fields that were
    /// requested across any locale, for use in the
    /// "Skipped name/subtitle update" log message.
    private func appInfoFieldsSummary(byLocale: [String: LocalizationFields]) -> String {
        var names: Set<String> = []
        for fields in byLocale.values {
            if fields.name != nil { names.insert("name") }
            if fields.subtitle != nil { names.insert("subtitle") }
            if fields.privacyPolicyURL != nil { names.insert("privacyPolicyUrl") }
            if fields.privacyChoicesURL != nil { names.insert("privacyChoicesUrl") }
        }
        // Stable order: name, subtitle, privacy URLs.
        let ordered = ["name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl"]
            .filter { names.contains($0) }
        return ordered.joined(separator: "/")
    }

    /// Diff `desired` (read from `metadata/<locale>/`) against the live
    /// AppInfoLocalization attributes from ASC. Returns only the fields
    /// that actually differ; matches the version-localization diff helper
    /// in spirit.
    private func changedAppInfoLocalizationFields(
        desired: LocalizationFields,
        current: AppsAPI.AppInfoLocalization.Attributes?
    ) -> AppsAPI.AppInfoLocalizationFields {
        func diff(_ new: String?, _ old: String?) -> String? {
            guard let new else { return nil }
            return new == (old ?? "") ? nil : new
        }
        return AppsAPI.AppInfoLocalizationFields(
            name:              diff(desired.name,             current?.name),
            subtitle:          diff(desired.subtitle,         current?.subtitle),
            privacyPolicyURL:  diff(desired.privacyPolicyURL, current?.privacyPolicyUrl),
            privacyChoicesURL: diff(desired.privacyChoicesURL, current?.privacyChoicesUrl)
        )
    }

    private func appInfoUpdatedFieldNames(_ fields: AppsAPI.AppInfoLocalizationFields) -> [String] {
        var names: [String] = []
        if fields.name != nil { names.append("name") }
        if fields.subtitle != nil { names.append("subtitle") }
        if fields.privacyPolicyURL != nil { names.append("privacyPolicyUrl") }
        if fields.privacyChoicesURL != nil { names.append("privacyChoicesUrl") }
        return names
    }

    /// Find-or-create the version's `appStoreReviewDetails` resource and
    /// PATCH any non-nil review fields whose values differ from ASC's
    /// current. When ASC has no review-detail record yet (typical for a
    /// fresh version), POST one in the same call. Errors are non-fatal:
    /// they go to `report.errors` so the rest of submit still runs.
    private func applyReviewDetail(
        appsAPI: AppsAPI,
        versionID: String,
        desired: ReviewDetailFields,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async {
        do {
            let existing = try await appsAPI.getReviewDetail(versionID: versionID)
            if let existing {
                let diff = changedReviewDetailFields(desired: desired, current: existing.attributes)
                if diff.hasAnyField {
                    _ = try await appsAPI.updateReviewDetail(id: existing.id, fields: diff)
                    report.reviewDetailUpdated = true
                    progress?("review detail: updated \(reviewDetailFieldNames(diff).joined(separator: ", "))")
                } else {
                    progress?("review detail: unchanged")
                }
            } else {
                _ = try await appsAPI.createReviewDetail(versionID: versionID, fields: desired)
                report.reviewDetailUpdated = true
                progress?("review detail: created with \(reviewDetailFieldNames(desired).joined(separator: ", "))")
            }
        } catch {
            report.errors.append("review detail: \(error)")
        }
    }

    /// Merges a YAML-side `review_info:` block with the file-side
    /// `review_*.txt` reads. YAML wins on field-by-field precedence: any
    /// non-nil YAML field overrides the file-side value. This way callers
    /// who set notes in YAML but contact info in files (or vice versa)
    /// get the union of both.
    private func mergeReviewDetail(
        yaml: ReviewDetailFields?,
        file: ReviewDetailFields?
    ) -> ReviewDetailFields? {
        switch (yaml, file) {
        case (nil, nil): return nil
        case (let y?, nil): return y
        case (nil, let f?): return f
        case (let y?, let f?):
            return ReviewDetailFields(
                contactFirstName:    y.contactFirstName    ?? f.contactFirstName,
                contactLastName:     y.contactLastName     ?? f.contactLastName,
                contactPhone:        y.contactPhone        ?? f.contactPhone,
                contactEmail:        y.contactEmail        ?? f.contactEmail,
                demoAccountName:     y.demoAccountName     ?? f.demoAccountName,
                demoAccountPassword: y.demoAccountPassword ?? f.demoAccountPassword,
                demoAccountRequired: y.demoAccountRequired ?? f.demoAccountRequired,
                notes:               y.notes               ?? f.notes
            )
        }
    }

    /// Returns a ReviewDetailFields containing only fields that actually
    /// differ from ASC's current. Mirrors `changedVersionLocalizationFields`
    /// for the review-detail resource.
    private func changedReviewDetailFields(
        desired: ReviewDetailFields,
        current: AppsAPI.AppStoreReviewDetail.Attributes?
    ) -> ReviewDetailFields {
        func diff(_ new: String?, _ old: String?) -> String? {
            guard let new else { return nil }
            return new == (old ?? "") ? nil : new
        }
        return ReviewDetailFields(
            contactFirstName:    diff(desired.contactFirstName,    current?.contactFirstName),
            contactLastName:     diff(desired.contactLastName,     current?.contactLastName),
            contactPhone:        diff(desired.contactPhone,        current?.contactPhone),
            contactEmail:        diff(desired.contactEmail,        current?.contactEmail),
            demoAccountName:     diff(desired.demoAccountName,     current?.demoAccountName),
            demoAccountPassword: diff(desired.demoAccountPassword, current?.demoAccountPassword),
            demoAccountRequired: desired.demoAccountRequired == current?.demoAccountRequired ? nil : desired.demoAccountRequired,
            notes:               diff(desired.notes,               current?.notes)
        )
    }

    private func reviewDetailFieldNames(_ fields: ReviewDetailFields) -> [String] {
        var names: [String] = []
        if fields.notes != nil { names.append("notes") }
        if fields.contactFirstName != nil { names.append("contactFirstName") }
        if fields.contactLastName != nil { names.append("contactLastName") }
        if fields.contactPhone != nil { names.append("contactPhone") }
        if fields.contactEmail != nil { names.append("contactEmail") }
        if fields.demoAccountName != nil { names.append("demoAccountName") }
        if fields.demoAccountPassword != nil { names.append("demoAccountPassword") }
        if fields.demoAccountRequired != nil { names.append("demoAccountRequired") }
        return names
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
        // Only lists fields that actually went out in the
        // appStoreVersionLocalizations PATCH. Name, subtitle, and the two
        // privacy URLs live on appInfoLocalizations and are reported via
        // `report.appInfoUpdates` instead.
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

    // MARK: - AppInfo metadata (categories, age rating)

    /// Coordinates the AppInfo-level metadata steps that share an editable
    /// AppInfo lookup: categories and age rating. Each step gates on its
    /// own config block, but they all need the same `findEditableAppInfo`
    /// result, so we resolve it once and pass it through.
    ///
    /// Errors here are non-fatal — they land on `report.errors` and the
    /// submit flow continues. A missing-editable-appInfo case is logged
    /// once with a clear "skip reason" and surfaces in
    /// `report.categoriesStatus` / `report.ageRatingStatus`.
    private func applyAppInfoMetadata(
        appsAPI: AppsAPI,
        appID: String,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async {
        let editable: AppsAPI.AppInfo?
        do {
            editable = try await appsAPI.findEditableAppInfo(appID: appID)
        } catch {
            report.errors.append("appInfo lookup (categories/age rating): \(error)")
            if config.categories != nil {
                report.categoriesStatus = "skipped: appInfo lookup failed"
            }
            if config.ageRating != nil {
                report.ageRatingStatus = "skipped: appInfo lookup failed"
            }
            return
        }
        guard let editable else {
            // Same skip-reason path as the metadata flow uses for
            // name/subtitle when no editable AppInfo exists.
            if config.categories != nil {
                report.categoriesStatus = "skipped: no editable appInfo"
                progress?("categories: skipped — no editable appInfo")
            }
            if config.ageRating != nil {
                report.ageRatingStatus = "skipped: no editable appInfo"
                progress?("age rating: skipped — no editable appInfo")
            }
            return
        }

        if let categoriesConfig = config.categories {
            await applyCategories(
                appInfo: editable,
                config: categoriesConfig,
                report: &report,
                progress: progress
            )
        }

        if let ageRatingConfig = config.ageRating {
            await applyAgeRating(
                appInfo: editable,
                config: ageRatingConfig,
                report: &report,
                progress: progress
            )
        }
    }

    /// Applies the `categories:` block to the editable AppInfo. Diffs
    /// against the current relationship values and only PATCHes when
    /// something differs. Each YAML field maps to one of the six category
    /// slots; the literal string "none" is treated as an explicit clear.
    private func applyCategories(
        appInfo: AppsAPI.AppInfo,
        config categoriesConfig: CategoriesConfig,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async {
        let api = AppCategoriesAPI(client: client)
        do {
            let current = try await api.currentCategories(appInfoID: appInfo.id)
            // Build the per-slot intent. Nil-keep is the most conservative
            // default; only emit an actual update when the desired and
            // current ids differ.
            func intent(
                desired: String?,
                current: String?
            ) -> AppCategoriesAPI.CategoryUpdate? {
                guard let desired else { return nil }
                let trimmed = desired.trimmingCharacters(in: .whitespaces)
                let isClear = trimmed.lowercased() == "none" || trimmed.isEmpty
                if isClear {
                    return current == nil ? nil : .clear
                }
                return current == trimmed ? nil : .set(trimmed)
            }

            let primary = intent(desired: categoriesConfig.primary, current: current.primary)
            let secondary = intent(desired: categoriesConfig.secondary, current: current.secondary)
            let p1 = intent(desired: categoriesConfig.primarySubcategoryOne, current: current.primarySubcategoryOne)
            let p2 = intent(desired: categoriesConfig.primarySubcategoryTwo, current: current.primarySubcategoryTwo)
            let s1 = intent(desired: categoriesConfig.secondarySubcategoryOne, current: current.secondarySubcategoryOne)
            let s2 = intent(desired: categoriesConfig.secondarySubcategoryTwo, current: current.secondarySubcategoryTwo)

            let updates: [(String, AppCategoriesAPI.CategoryUpdate?)] = [
                ("primary", primary),
                ("secondary", secondary),
                ("primarySubcategoryOne", p1),
                ("primarySubcategoryTwo", p2),
                ("secondarySubcategoryOne", s1),
                ("secondarySubcategoryTwo", s2),
            ]
            let dirtyNames = updates.compactMap { (name, u) -> String? in
                u != nil ? name : nil
            }
            guard !dirtyNames.isEmpty else {
                report.categoriesStatus = "unchanged"
                progress?("categories: unchanged")
                return
            }
            do {
                _ = try await api.updateCategories(
                    appInfoID: appInfo.id,
                    primary: primary,
                    secondary: secondary,
                    primarySubcategoryOne: p1,
                    primarySubcategoryTwo: p2,
                    secondarySubcategoryOne: s1,
                    secondarySubcategoryTwo: s2
                )
                report.categoriesStatus = "updated: \(dirtyNames.joined(separator: ", "))"
                progress?("categories: updated \(dirtyNames.joined(separator: ", "))")
            } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                report.categoriesStatus = "unchanged"
                progress?("categories: unchanged (ASC reported already-set)")
            }
        } catch {
            report.errors.append("categories: \(error)")
            report.categoriesStatus = "error"
        }
    }

    /// Applies the `age_rating:` block to the editable AppInfo's auto-
    /// created ageRatingDeclaration. Diffs every supplied field against
    /// the current declaration; only PATCHes when something differs.
    /// Empty diffs are skipped entirely (ASC rejects PATCHes with no
    /// changed attributes).
    private func applyAgeRating(
        appInfo: AppsAPI.AppInfo,
        config ageRatingConfig: AgeRatingConfig,
        report: inout Report,
        progress: ((String) -> Void)?
    ) async {
        let api = AgeRatingDeclarationsAPI(client: client)
        do {
            guard let declaration = try await api.getForAppInfo(appInfoID: appInfo.id) else {
                report.errors.append("age rating: declaration not found for appInfo \(appInfo.id) (ASC has not auto-created one yet?)")
                report.ageRatingStatus = "skipped: no declaration"
                return
            }
            let current = declaration.attributes
            let (diff, dirtyNames) = ageRatingDiff(desired: ageRatingConfig, current: current)
            guard !dirtyNames.isEmpty else {
                report.ageRatingStatus = "unchanged"
                progress?("age rating: unchanged")
                return
            }
            do {
                _ = try await api.update(id: declaration.id, fields: diff)
                report.ageRatingStatus = "updated: \(dirtyNames.joined(separator: ", "))"
                progress?("age rating: updated \(dirtyNames.joined(separator: ", "))")
            } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                report.ageRatingStatus = "unchanged"
                progress?("age rating: unchanged (ASC reported already-set)")
            }
        } catch {
            report.errors.append("age rating: \(error)")
            report.ageRatingStatus = "error"
        }
    }

    /// Returns (attributes-to-PATCH, list-of-dirty-field-names) for the
    /// age-rating diff. The PATCH attributes carry only fields whose
    /// desired value differs from current; everything else is left nil
    /// so the wire body omits them.
    private func ageRatingDiff(
        desired: AgeRatingConfig,
        current: AgeRatingDeclarationsAPI.Declaration.Attributes?
    ) -> (AgeRatingDeclarationsAPI.Declaration.Attributes, [String]) {
        var diff = AgeRatingDeclarationsAPI.Declaration.Attributes()
        var dirty: [String] = []

        func freq(
            _ desired: AgeRatingConfig.Frequency?,
            _ current: AgeRatingConfig.Frequency?,
            _ name: String,
            _ assign: (AgeRatingConfig.Frequency) -> Void
        ) {
            guard let desired else { return }
            let cur = current ?? .none
            if desired != cur {
                assign(desired)
                dirty.append(name)
            }
        }
        func bool(
            _ desired: Bool?,
            _ current: Bool?,
            _ name: String,
            _ assign: (Bool) -> Void
        ) {
            guard let desired else { return }
            let cur = current ?? false
            if desired != cur {
                assign(desired)
                dirty.append(name)
            }
        }

        freq(desired.cartoonOrFantasyViolence, current?.violenceCartoonOrFantasy, "cartoonOrFantasyViolence") {
            diff.violenceCartoonOrFantasy = $0
        }
        freq(desired.realisticViolence, current?.violenceRealistic, "realisticViolence") {
            diff.violenceRealistic = $0
        }
        freq(desired.prolongedGraphicSadisticRealisticViolence, current?.violenceRealisticProlongedGraphicOrSadistic, "prolongedGraphicSadisticRealisticViolence") {
            diff.violenceRealisticProlongedGraphicOrSadistic = $0
        }
        freq(desired.profanityOrCrudeHumor, current?.profanityOrCrudeHumor, "profanityOrCrudeHumor") {
            diff.profanityOrCrudeHumor = $0
        }
        freq(desired.matureOrSuggestiveThemes, current?.matureOrSuggestiveThemes, "matureOrSuggestiveThemes") {
            diff.matureOrSuggestiveThemes = $0
        }
        freq(desired.horrorOrFearThemes, current?.horrorOrFearThemes, "horrorOrFearThemes") {
            diff.horrorOrFearThemes = $0
        }
        freq(desired.medicalOrTreatmentInformation, current?.medicalOrTreatmentInformation, "medicalOrTreatmentInformation") {
            diff.medicalOrTreatmentInformation = $0
        }
        freq(desired.alcoholTobaccoOrDrugUseOrReferences, current?.alcoholTobaccoOrDrugUseOrReferences, "alcoholTobaccoOrDrugUseOrReferences") {
            diff.alcoholTobaccoOrDrugUseOrReferences = $0
        }
        freq(desired.simulatedGambling, current?.gamblingSimulated, "simulatedGambling") {
            diff.gamblingSimulated = $0
        }
        freq(desired.sexualContentOrNudity, current?.sexualContentOrNudity, "sexualContentOrNudity") {
            diff.sexualContentOrNudity = $0
        }
        freq(desired.graphicSexualContentAndNudity, current?.sexualContentGraphicAndNudity, "graphicSexualContentAndNudity") {
            diff.sexualContentGraphicAndNudity = $0
        }
        freq(desired.contests, current?.contests, "contests") {
            diff.contests = $0
        }
        bool(desired.unrestrictedWebAccess, current?.unrestrictedWebAccess, "unrestrictedWebAccess") {
            diff.unrestrictedWebAccess = $0
        }
        bool(desired.gambling, current?.gambling, "gambling") {
            diff.gambling = $0
        }
        if let band = desired.kidsAgeBand {
            let cur = current?.kidsAgeBand ?? .none
            if band != cur {
                diff.kidsAgeBand = band
                dirty.append("kidsAgeBand")
            }
        }
        if let override = desired.ageRatingOverride {
            if override != (current?.ageRatingOverride ?? "") {
                diff.ageRatingOverride = override
                dirty.append("ageRatingOverride")
            }
        }
        return (diff, dirty)
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
