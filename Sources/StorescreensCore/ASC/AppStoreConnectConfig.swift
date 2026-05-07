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
    /// App Store category assignment (primary, secondary, optional
    /// subcategories). Unset leaves the existing categories untouched.
    /// Lives on the editable AppInfo via JSON:API relationships, so
    /// requires the same editable-state guard as name/subtitle PATCHes.
    package var categories: CategoriesConfig?
    /// Age-rating questionnaire answers. Unset leaves the existing
    /// declaration untouched. ASC computes the final rating (4+, 9+, etc.)
    /// from these per-question answers automatically.
    package var ageRating: AgeRatingConfig?
    /// App Review Information panel: notes, contact info, demo account.
    /// An alternative to the per-locale `review_*.txt` files; either flow
    /// is fine. When both are set, this YAML block wins (it's more
    /// scoped). Unset leaves the existing review-detail untouched.
    package var reviewInfo: ReviewInfoConfig?

    package init(
        appID: String? = nil,
        bundleID: String? = nil,
        metadataDir: String? = nil,
        submit: SubmitConfig? = nil,
        uploadBuild: UploadBuildConfig? = nil,
        pricing: PricingConfig? = nil,
        availability: AvailabilityConfig? = nil,
        categories: CategoriesConfig? = nil,
        ageRating: AgeRatingConfig? = nil,
        reviewInfo: ReviewInfoConfig? = nil
    ) {
        self.appID = appID
        self.bundleID = bundleID
        self.metadataDir = metadataDir
        self.submit = submit
        self.uploadBuild = uploadBuild
        self.pricing = pricing
        self.availability = availability
        self.categories = categories
        self.ageRating = ageRating
        self.reviewInfo = reviewInfo
    }

    package enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case bundleID = "bundle_id"
        case metadataDir = "metadata_dir"
        case submit
        case uploadBuild = "upload_build"
        case pricing
        case availability
        case categories
        case ageRating = "age_rating"
        case reviewInfo = "review_info"
    }
}

/// App Store category assignment. All fields are optional; only those that
/// are set get PATCHed onto the editable AppInfo's relationships block.
/// Category and subcategory IDs are Apple's canonical uppercase strings
/// (e.g. "EDUCATION", "PHOTO_AND_VIDEO"). The full list is fetched from
/// `GET /v1/appCategories` and validated during `submit --dry-run`.
///
/// `secondary` and the four subcategory slots all accept the literal
/// string "none" as a request to clear that slot back to unset (this is
/// distinct from leaving the field omitted, which keeps the existing
/// value).
package struct CategoriesConfig: Codable, Sendable {
    /// Primary category id, e.g. "EDUCATION". Required when the
    /// categories block is present and the app currently has no primary
    /// category set; optional otherwise.
    package var primary: String?
    /// Secondary category id. Pass "none" to explicitly clear. Optional.
    package var secondary: String?
    package var primarySubcategoryOne: String?
    package var primarySubcategoryTwo: String?
    package var secondarySubcategoryOne: String?
    package var secondarySubcategoryTwo: String?

    package init(
        primary: String? = nil,
        secondary: String? = nil,
        primarySubcategoryOne: String? = nil,
        primarySubcategoryTwo: String? = nil,
        secondarySubcategoryOne: String? = nil,
        secondarySubcategoryTwo: String? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.primarySubcategoryOne = primarySubcategoryOne
        self.primarySubcategoryTwo = primarySubcategoryTwo
        self.secondarySubcategoryOne = secondarySubcategoryOne
        self.secondarySubcategoryTwo = secondarySubcategoryTwo
    }

    package enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case primarySubcategoryOne = "primary_subcategory_one"
        case primarySubcategoryTwo = "primary_subcategory_two"
        case secondarySubcategoryOne = "secondary_subcategory_one"
        case secondarySubcategoryTwo = "secondary_subcategory_two"
    }
}

/// Age-rating questionnaire YAML config. Each `Frequency` field defaults
/// to `.none` when omitted; specify only what's actually present in the
/// app's content. ASC computes the final age rating from the answers.
///
/// Field names use snake_case in YAML (matching the rest of this config
/// block); `CodingKeys` translates to camelCase for the API attributes.
package struct AgeRatingConfig: Codable, Sendable {
    package typealias Frequency = AgeRatingDeclarationsAPI.Frequency
    package typealias KidsAgeBand = AgeRatingDeclarationsAPI.KidsAgeBand

    // Frequencies
    package var cartoonOrFantasyViolence: Frequency?
    package var realisticViolence: Frequency?
    package var prolongedGraphicSadisticRealisticViolence: Frequency?
    package var profanityOrCrudeHumor: Frequency?
    package var matureOrSuggestiveThemes: Frequency?
    package var horrorOrFearThemes: Frequency?
    package var medicalOrTreatmentInformation: Frequency?
    package var alcoholTobaccoOrDrugUseOrReferences: Frequency?
    package var simulatedGambling: Frequency?
    package var sexualContentOrNudity: Frequency?
    package var graphicSexualContentAndNudity: Frequency?
    package var contests: Frequency?

    // Booleans
    package var unrestrictedWebAccess: Bool?
    package var gambling: Bool?

    // Other
    package var kidsAgeBand: KidsAgeBand?
    package var ageRatingOverride: String?

    package init(
        cartoonOrFantasyViolence: Frequency? = nil,
        realisticViolence: Frequency? = nil,
        prolongedGraphicSadisticRealisticViolence: Frequency? = nil,
        profanityOrCrudeHumor: Frequency? = nil,
        matureOrSuggestiveThemes: Frequency? = nil,
        horrorOrFearThemes: Frequency? = nil,
        medicalOrTreatmentInformation: Frequency? = nil,
        alcoholTobaccoOrDrugUseOrReferences: Frequency? = nil,
        simulatedGambling: Frequency? = nil,
        sexualContentOrNudity: Frequency? = nil,
        graphicSexualContentAndNudity: Frequency? = nil,
        contests: Frequency? = nil,
        unrestrictedWebAccess: Bool? = nil,
        gambling: Bool? = nil,
        kidsAgeBand: KidsAgeBand? = nil,
        ageRatingOverride: String? = nil
    ) {
        self.cartoonOrFantasyViolence = cartoonOrFantasyViolence
        self.realisticViolence = realisticViolence
        self.prolongedGraphicSadisticRealisticViolence = prolongedGraphicSadisticRealisticViolence
        self.profanityOrCrudeHumor = profanityOrCrudeHumor
        self.matureOrSuggestiveThemes = matureOrSuggestiveThemes
        self.horrorOrFearThemes = horrorOrFearThemes
        self.medicalOrTreatmentInformation = medicalOrTreatmentInformation
        self.alcoholTobaccoOrDrugUseOrReferences = alcoholTobaccoOrDrugUseOrReferences
        self.simulatedGambling = simulatedGambling
        self.sexualContentOrNudity = sexualContentOrNudity
        self.graphicSexualContentAndNudity = graphicSexualContentAndNudity
        self.contests = contests
        self.unrestrictedWebAccess = unrestrictedWebAccess
        self.gambling = gambling
        self.kidsAgeBand = kidsAgeBand
        self.ageRatingOverride = ageRatingOverride
    }

    package enum CodingKeys: String, CodingKey {
        case cartoonOrFantasyViolence = "cartoon_or_fantasy_violence"
        case realisticViolence = "realistic_violence"
        case prolongedGraphicSadisticRealisticViolence = "prolonged_graphic_sadistic_realistic_violence"
        case profanityOrCrudeHumor = "profanity_or_crude_humor"
        case matureOrSuggestiveThemes = "mature_or_suggestive_themes"
        case horrorOrFearThemes = "horror_or_fear_themes"
        case medicalOrTreatmentInformation = "medical_or_treatment_information"
        case alcoholTobaccoOrDrugUseOrReferences = "alcohol_tobacco_or_drug_use_or_references"
        case simulatedGambling = "simulated_gambling"
        case sexualContentOrNudity = "sexual_content_or_nudity"
        case graphicSexualContentAndNudity = "graphic_sexual_content_and_nudity"
        case contests
        case unrestrictedWebAccess = "unrestricted_web_access"
        case gambling
        case kidsAgeBand = "kids_age_band"
        case ageRatingOverride = "age_rating_override"
    }
}

/// App Review Information panel YAML config. An alternative to the
/// per-locale `review_*.txt` files; either flow ends up at the same
/// `appStoreReviewDetails` resource. Useful for one-shot YAML-only
/// setups where the user doesn't need to maintain a `metadata/<locale>/`
/// directory.
package struct ReviewInfoConfig: Codable, Sendable {
    package var firstName: String?
    package var lastName: String?
    package var phoneNumber: String?
    package var emailAddress: String?
    /// Whether Apple needs a demo login. When unset and demo account
    /// fields are present, defaults to true. When demo fields are absent,
    /// defaults to false.
    package var demoAccountRequired: Bool?
    package var demoAccountName: String?
    package var demoAccountPassword: String?
    /// Free-form review notes. Multi-line YAML strings work fine here
    /// (`notes: |`).
    package var notes: String?

    package init(
        firstName: String? = nil,
        lastName: String? = nil,
        phoneNumber: String? = nil,
        emailAddress: String? = nil,
        demoAccountRequired: Bool? = nil,
        demoAccountName: String? = nil,
        demoAccountPassword: String? = nil,
        notes: String? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.phoneNumber = phoneNumber
        self.emailAddress = emailAddress
        self.demoAccountRequired = demoAccountRequired
        self.demoAccountName = demoAccountName
        self.demoAccountPassword = demoAccountPassword
        self.notes = notes
    }

    /// Converts this YAML-side config into the wire-side `ReviewDetailFields`
    /// shape consumed by `AppsAPI`. Splits/normalizes nothing - one-to-one
    /// pass-through with field renames.
    package var asReviewDetailFields: ReviewDetailFields {
        var fields = ReviewDetailFields(
            contactFirstName: firstName,
            contactLastName: lastName,
            contactPhone: phoneNumber,
            contactEmail: emailAddress,
            demoAccountName: demoAccountName,
            demoAccountPassword: demoAccountPassword,
            demoAccountRequired: demoAccountRequired,
            notes: notes
        )
        // If the user supplied demo account fields without explicitly
        // saying demo_account_required, default it to true. If neither the
        // demo fields nor the flag are set, leave it nil so it stays
        // untouched on ASC.
        if fields.demoAccountRequired == nil {
            if fields.demoAccountName != nil || fields.demoAccountPassword != nil {
                fields.demoAccountRequired = true
            }
        }
        return fields
    }

    package enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case phoneNumber = "phone_number"
        case emailAddress = "email_address"
        case demoAccountRequired = "demo_account_required"
        case demoAccountName = "demo_account_name"
        case demoAccountPassword = "demo_account_password"
        case notes
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
