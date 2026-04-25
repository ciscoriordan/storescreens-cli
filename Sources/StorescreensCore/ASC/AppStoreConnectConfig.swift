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
    /// Pricing (free vs paid tier). Unset leaves the app's existing schedule
    /// untouched — set it only on first-version submissions or when the
    /// price tier changes.
    package var pricing: PricingConfig?
    /// Territory availability (which countries the app is available in).
    /// Unset leaves current availability untouched.
    package var availability: AvailabilityConfig?

    package init(
        appID: String? = nil,
        bundleID: String? = nil,
        metadataDir: String? = nil,
        submit: SubmitConfig? = nil,
        uploadBuild: UploadBuildConfig? = nil,
        pricing: PricingConfig? = nil,
        availability: AvailabilityConfig? = nil
    ) {
        self.appID = appID
        self.bundleID = bundleID
        self.metadataDir = metadataDir
        self.submit = submit
        self.uploadBuild = uploadBuild
        self.pricing = pricing
        self.availability = availability
    }

    package enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case bundleID = "bundle_id"
        case metadataDir = "metadata_dir"
        case submit
        case uploadBuild = "upload_build"
        case pricing
        case availability
    }
}

/// App-level pricing. Currently supports the "free" case (most common for a
/// first submission). Setting a specific paid tier is doable via the same
/// `createPriceSchedule` path but isn't exposed here yet — add a `price_tier`
/// or `base_price` field when a real paid-app use case comes up.
package struct PricingConfig: Codable, Sendable {
    /// `true` sets the app to free in the base territory; Apple auto-computes
    /// free prices for every other territory. `false` is currently rejected —
    /// paid pricing needs more fields than this config exposes today.
    package var free: Bool?

    /// Territory used as the base for price equivalencing. Defaults to USA
    /// (matches the ASC web UI default). Any ISO 3166-1 alpha-3 code works.
    package var baseTerritory: String?

    package init(free: Bool? = nil, baseTerritory: String? = nil) {
        self.free = free
        self.baseTerritory = baseTerritory
    }

    package enum CodingKeys: String, CodingKey {
        case free
        case baseTerritory = "base_territory"
    }
}

/// Territory availability — which countries the app shows up in on the
/// App Store. For a worldwide launch use `territories: .all`; for a limited
/// rollout use `.list(["USA", "CAN", ...])`.
package struct AvailabilityConfig: Codable, Sendable {
    /// Either `all` for every supported territory, or an explicit list of
    /// ISO 3166-1 alpha-3 codes. When unset, current availability stays as-is.
    package var territories: TerritorySelection?
    /// When Apple adds a new territory to the App Store, should the app auto-
    /// enroll? Defaults to true — matches ASC's own default.
    package var availableInNewTerritories: Bool?

    package init(
        territories: TerritorySelection? = nil,
        availableInNewTerritories: Bool? = nil
    ) {
        self.territories = territories
        self.availableInNewTerritories = availableInNewTerritories
    }

    package enum CodingKeys: String, CodingKey {
        case territories
        case availableInNewTerritories = "available_in_new_territories"
    }
}

/// Two-case discriminator for availability: either worldwide or a specific
/// list of territory codes. Decodes from either the string "all" or an
/// array of strings in YAML/JSON.
package enum TerritorySelection: Codable, Sendable, Equatable {
    case all
    case list([String])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            guard s == "all" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "availability.territories must be \"all\" or a list of ISO alpha-3 codes; got \"\(s)\""
                )
            }
            self = .all
            return
        }
        if let arr = try? container.decode([String].self) {
            self = .list(arr)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "availability.territories must be \"all\" or a list of ISO alpha-3 codes"
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all: try container.encode("all")
        case .list(let a): try container.encode(a)
        }
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

    /// Attach the newest VALID build (from the `createVersion` train)
    /// to the App Store version after screenshots and metadata upload.
    /// A version without a build can't be submitted for review and
    /// shows "Missing Build" in the ASC web UI. Default true so a
    /// standard submit flow produces a review-ready version in one
    /// command; set false when manually managing build attachment.
    package var attachBuild: Bool?

    /// Answer to Apple's export compliance question on the attached
    /// build (`usesNonExemptEncryption` in the Build Beta Detail /
    /// App Store build attributes). The question must be answered
    /// before a build can be submitted for review or made available
    /// to external testers on TestFlight.
    ///
    /// - `none` (default): app uses only standard iOS cryptography
    ///   covered by Apple's exemption (HTTPS, keychain, signing,
    ///   etc.). Sent as `usesNonExemptEncryption: false`. This is
    ///   correct for the vast majority of apps.
    /// - `exempt_algorithms`: app ships its own cryptographic
    ///   algorithms, but they all qualify for one of Apple's specific
    ///   exemptions (authentication, DRM, copy protection, etc.). Sent
    ///   as `usesNonExemptEncryption: false` plus an explanatory
    ///   `exemptEncryptionExplanation` string.
    /// - `non_exempt`: app uses non-exempt encryption and an
    ///   ERN / export compliance review applies. Sent as
    ///   `usesNonExemptEncryption: true`. Submitters are responsible
    ///   for having the necessary paperwork filed with the Bureau of
    ///   Industry and Security separately.
    ///
    /// Set to `skip` to leave the question untouched (the build will
    /// still show "Missing Compliance" until answered manually).
    package var exportCompliance: ExportCompliance?

    package init(
        createVersion: String? = nil,
        screenshots: Bool? = nil,
        metadata: Bool? = nil,
        submitForReview: Bool? = nil,
        platform: String? = nil,
        attachBuild: Bool? = nil,
        exportCompliance: ExportCompliance? = nil
    ) {
        self.createVersion = createVersion
        self.screenshots = screenshots
        self.metadata = metadata
        self.submitForReview = submitForReview
        self.platform = platform
        self.attachBuild = attachBuild
        self.exportCompliance = exportCompliance
    }

    package enum CodingKeys: String, CodingKey {
        case createVersion = "create_version"
        case screenshots
        case metadata
        case submitForReview = "submit_for_review"
        case platform
        case attachBuild = "attach_build"
        case exportCompliance = "export_compliance"
    }
}

/// Answer to App Store Connect's export compliance question.
package enum ExportCompliance: String, Codable, Sendable {
    /// App uses only standard iOS cryptography (HTTPS, keychain,
    /// signing). The common case. Sent as `usesNonExemptEncryption:
    /// false`.
    case none

    /// App ships its own cryptographic algorithms but all qualify for
    /// an Apple exemption (authentication, DRM, copy protection, IP
    /// rights management). Sent as `usesNonExemptEncryption: false`.
    case exemptAlgorithms = "exempt_algorithms"

    /// App uses non-exempt encryption and the submitter has the
    /// required BIS export paperwork. Sent as
    /// `usesNonExemptEncryption: true`.
    case nonExempt = "non_exempt"

    /// Don't touch the usesNonExemptEncryption attribute. The build
    /// shows "Missing Compliance" in ASC until answered manually.
    case skip

    /// Mapping to the boolean `usesNonExemptEncryption` attribute on
    /// the build. Nil means "skip — don't PATCH the build".
    package var usesNonExemptEncryption: Bool? {
        switch self {
        case .none, .exemptAlgorithms: return false
        case .nonExempt:                return true
        case .skip:                     return nil
        }
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

    /// Export compliance answer baked into the Info.plist at archive time
    /// via `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`. Avoids the
    /// "Missing Compliance" state in TestFlight + App Store after upload,
    /// without needing a follow-up ASC API patch via `storescreens submit`.
    ///
    /// - `none` (default): app uses only standard iOS cryptography (HTTPS,
    ///   keychain, signing). Sets the Info.plist key to NO.
    /// - `exempt_algorithms`: app ships its own crypto but it qualifies for
    ///   an Apple exemption. Sets the Info.plist key to NO. (To also set
    ///   `ITSEncryptionExportComplianceCode` for an issued ERN, supply it
    ///   in your Info.plist directly; this field doesn't manage that.)
    /// - `non_exempt`: app uses non-exempt encryption. Sets the key to YES.
    ///   Requires the appropriate BIS export paperwork; see Apple's docs.
    /// - `skip`: don't set the Info.plist key. The build will show "Missing
    ///   Compliance" until answered manually or via `storescreens submit`.
    ///
    /// Note: this build setting only takes effect for projects that opt
    /// into Xcode's auto-generated Info.plist (`GENERATE_INFOPLIST_FILE = YES`,
    /// the default in Xcode 13+ projects). For legacy projects with a
    /// hand-written Info.plist, set the key in the file directly.
    package var exportCompliance: ExportCompliance?

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
        buildNumber: String? = nil,
        exportCompliance: ExportCompliance? = nil
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
        self.exportCompliance = exportCompliance
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
        case exportCompliance = "export_compliance"
    }
}
