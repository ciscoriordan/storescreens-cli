import Foundation

/// Configuration for uploading rendered screenshots and per-locale metadata
/// to App Store Connect. Attached to `CaptureConfig.appStoreConnect`.
///
/// One of `appID` or `bundleID` is required. `appID` is the numeric ID Apple
/// assigns each app (visible in App Store Connect URLs as `/apps/<id>/`).
/// `bundleID` is resolved via `GET /v1/apps?filter[bundleId]=...` at submit
/// time — more convenient when the app already exists in App Store Connect.
package struct AppStoreConnectConfig: Codable, Sendable {
    package var appID: String?
    package var bundleID: String?
    /// Directory containing `<locale>/*.txt` metadata files. Relative paths
    /// resolve against the directory containing the project YML.
    package var metadataDir: String?
    package var submit: SubmitConfig?

    package init(
        appID: String? = nil,
        bundleID: String? = nil,
        metadataDir: String? = nil,
        submit: SubmitConfig? = nil
    ) {
        self.appID = appID
        self.bundleID = bundleID
        self.metadataDir = metadataDir
        self.submit = submit
    }

    package enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case bundleID = "bundle_id"
        case metadataDir = "metadata_dir"
        case submit
    }
}

/// What to upload during a `storescreens submit` run.
package struct SubmitConfig: Codable, Sendable {
    /// Target version string (e.g. "1.2.0"). If the version doesn't exist
    /// in App Store Connect yet, it's created. Required.
    package var createVersion: String?
    package var screenshots: Bool?
    package var metadata: Bool?
    /// Submit the version for App Review after uploading. Hard default false
    /// since this is irreversible without reviewer intervention.
    package var submitForReview: Bool?
    /// Platform for the version: "IOS" | "MAC_OS" | "TV_OS" | "VISION_OS".
    /// Defaults to "IOS". Rarely needs override.
    package var platform: String?

    package init(
        createVersion: String? = nil,
        screenshots: Bool? = nil,
        metadata: Bool? = nil,
        submitForReview: Bool? = nil,
        platform: String? = nil
    ) {
        self.createVersion = createVersion
        self.screenshots = screenshots
        self.metadata = metadata
        self.submitForReview = submitForReview
        self.platform = platform
    }

    package enum CodingKeys: String, CodingKey {
        case createVersion = "create_version"
        case screenshots
        case metadata
        case submitForReview = "submit_for_review"
        case platform
    }
}
