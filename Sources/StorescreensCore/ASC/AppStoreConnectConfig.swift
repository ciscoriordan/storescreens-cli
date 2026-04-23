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
    /// Configuration for `storescreens upload-build`: archive + export + upload
    /// a fresh `.ipa` via `xcrun altool`.
    package var uploadBuild: UploadBuildConfig?

    package init(
        appID: String? = nil,
        bundleID: String? = nil,
        metadataDir: String? = nil,
        submit: SubmitConfig? = nil,
        uploadBuild: UploadBuildConfig? = nil
    ) {
        self.appID = appID
        self.bundleID = bundleID
        self.metadataDir = metadataDir
        self.submit = submit
        self.uploadBuild = uploadBuild
    }

    package enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case bundleID = "bundle_id"
        case metadataDir = "metadata_dir"
        case submit
        case uploadBuild = "upload_build"
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

/// Configuration for `storescreens upload-build`. Drives `xcodebuild archive`
/// -> `xcodebuild -exportArchive` -> `xcrun altool --upload-app`.
///
/// Most fields have sensible defaults; the minimum required config is the
/// `app_store_connect:` block itself (for credentials + bundle/app id).
/// Scheme falls back to `CaptureConfig.scheme` when omitted.
package struct UploadBuildConfig: Codable, Sendable {
    /// Scheme to archive. Defaults to top-level `scheme:` if unset.
    package var scheme: String?
    /// Configuration name. Default "Release".
    package var configuration: String?
    /// Export method: "app-store" (default), "ad-hoc", "enterprise", "development".
    package var exportMethod: String?
    /// Apple Developer Team ID, e.g. "ABCDE12345". Auto-detected from the
    /// archive when possible; set explicitly for manual signing.
    package var teamID: String?
    /// "automatic" (default) or "manual".
    package var signingStyle: String?
    /// Bundle-id -> provisioning profile name, for manual signing.
    package var provisioningProfiles: [String: String]?
    /// Upload dSYMs for symbolication. Default true.
    package var includeSymbols: Bool?
    /// Strip Swift symbols from the binary. Default true.
    package var stripSwiftSymbols: Bool?
    /// Override the auto-selected non-beta Xcode. Accepts either the
    /// `.app` bundle path or the `Contents/Developer` dir.
    package var xcodePath: String?
    /// Path to a user-provided ExportOptions.plist. When set, storescreens
    /// skips generating one from the other fields in this block.
    package var exportOptionsPlist: String?
    /// Pass `-allowProvisioningUpdates` at export time. Default true so Xcode
    /// can create/download missing profiles during export.
    package var allowProvisioningUpdates: Bool?
    /// Archive destination. Default "generic/platform=iOS".
    package var destination: String?
    /// Directory to write the exported `.ipa` to. Default "./build".
    /// Relative paths resolve against the YML directory.
    package var outputDir: String?
    /// Archive + export + stop. Skips the altool upload step.
    /// Default false.
    package var skipUpload: Bool?
    /// Auto-bump MARKETING_VERSION / CURRENT_PROJECT_VERSION before archive
    /// when App Store Connect state requires it (marketing version already
    /// shipped, or build number collides with an existing TestFlight build).
    /// Default true; set false to error out instead of rewriting the
    /// pbxproj.
    package var autoBump: Bool?
    /// Force a specific marketing version instead of what's in the Xcode
    /// project. The resolver still validates the build number against ASC.
    package var marketingVersion: String?
    /// Force a specific build number.
    package var buildNumber: String?

    package init(
        scheme: String? = nil,
        configuration: String? = nil,
        exportMethod: String? = nil,
        teamID: String? = nil,
        signingStyle: String? = nil,
        provisioningProfiles: [String: String]? = nil,
        includeSymbols: Bool? = nil,
        stripSwiftSymbols: Bool? = nil,
        xcodePath: String? = nil,
        exportOptionsPlist: String? = nil,
        allowProvisioningUpdates: Bool? = nil,
        destination: String? = nil,
        outputDir: String? = nil,
        skipUpload: Bool? = nil,
        autoBump: Bool? = nil,
        marketingVersion: String? = nil,
        buildNumber: String? = nil
    ) {
        self.scheme = scheme
        self.configuration = configuration
        self.exportMethod = exportMethod
        self.teamID = teamID
        self.signingStyle = signingStyle
        self.provisioningProfiles = provisioningProfiles
        self.includeSymbols = includeSymbols
        self.stripSwiftSymbols = stripSwiftSymbols
        self.xcodePath = xcodePath
        self.exportOptionsPlist = exportOptionsPlist
        self.allowProvisioningUpdates = allowProvisioningUpdates
        self.destination = destination
        self.outputDir = outputDir
        self.skipUpload = skipUpload
        self.autoBump = autoBump
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    package enum CodingKeys: String, CodingKey {
        case scheme
        case configuration
        case exportMethod = "export_method"
        case teamID = "team_id"
        case signingStyle = "signing_style"
        case provisioningProfiles = "provisioning_profiles"
        case includeSymbols = "include_symbols"
        case stripSwiftSymbols = "strip_swift_symbols"
        case xcodePath = "xcode_path"
        case exportOptionsPlist = "export_options_plist"
        case allowProvisioningUpdates = "allow_provisioning_updates"
        case destination
        case outputDir = "output_dir"
        case skipUpload = "skip_upload"
        case autoBump = "auto_bump"
        case marketingVersion = "marketing_version"
        case buildNumber = "build_number"
    }
}
