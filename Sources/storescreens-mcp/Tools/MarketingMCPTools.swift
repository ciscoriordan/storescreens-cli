import Foundation
import MCP
import StorescreensCore

/// MCP tool catalog + dispatch for the App Store Connect marketing /
/// discoverability / extension endpoints wrapped in MarketingAPI.swift.
/// Each sub-family (previews, app clips, custom product pages, app events,
/// experiments, encryption declarations, routing coverage) exposes its
/// CRUD + upload surface as MCP tools so an AI agent can drive these
/// surfaces without constructing raw HTTP.
///
/// All tools return JSON-pretty-printed text content. Credentials are
/// resolved via `ASCCredentialResolver.resolve()` so the same env-or-file
/// flow that powers `storescreens auth login` works here.
package enum MarketingMCPTools {

    // MARK: - Shared helpers

    /// Build a tool with a plain object input schema.
    static func makeTool(
        name: String,
        description: String,
        properties: [(String, String, String)] = [],
        required: [String] = []
    ) -> Tool {
        var props: [String: Value] = [:]
        for (key, type, desc) in properties {
            props[key] = .object([
                "type": .string(type),
                "description": .string(desc),
            ])
        }
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(props),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return Tool(
            name: name,
            description: description,
            inputSchema: .object(schema)
        )
    }

    /// Resolve credentials, returning an ASCClient or a CallTool.Result
    /// representing the user-facing error. The caller pattern is:
    ///
    ///   switch try client() { ... }
    ///
    /// instead of a throw because we want a consistent shape (text content +
    /// isError: true) rather than the SDK's generic Error renderer. Swift's
    /// stdlib `Result` requires `Failure: Error`, so we use a hand-rolled
    /// either enum here.
    enum Either<L, R> {
        case left(L)
        case right(R)
    }

    static func makeClient() -> Either<ASCClient, CallTool.Result> {
        guard ASCCredentialResolver.isConfigured() else {
            return .right(.init(
                content: [.text("App Store Connect credentials not configured. Run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH.")],
                isError: true
            ))
        }
        do {
            let creds = try ASCCredentialResolver.resolve()
            return .left(ASCClient(credentials: creds))
        } catch {
            return .right(.init(
                content: [.text("Credentials broken: \(error.localizedDescription)")],
                isError: true
            ))
        }
    }

    static func emitJSON<T: Encodable>(_ value: T, header: String? = nil) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            let body = header.map { "\($0)\n\n\(json)" } ?? json
            return .init(content: [.text(body)], isError: false)
        } catch {
            return .init(
                content: [.text("Encoding failed: \(error.localizedDescription)")],
                isError: true
            )
        }
    }

    static func emitAPIError(_ error: Error, context: String) -> CallTool.Result {
        if let api = error as? ASCClient.APIError {
            var lines = ["\(context): HTTP \(api.statusCode)"]
            for d in api.details { lines.append("  [\(d.code)] \(d.title): \(d.detail)") }
            return .init(content: [.text(lines.joined(separator: "\n"))], isError: true)
        }
        return .init(
            content: [.text("\(context): \(error.localizedDescription)")],
            isError: true
        )
    }

    static func requireString(
        _ params: CallTool.Parameters, _ key: String
    ) -> Either<String, CallTool.Result> {
        guard let v = params.arguments?[key]?.stringValue, !v.isEmpty else {
            return .right(.init(
                content: [.text("Missing required parameter: \(key)")],
                isError: true
            ))
        }
        return .left(v)
    }

    // MARK: - Catalog

    package static let tools: [Tool] = previewTools
        + appClipTools
        + customProductPageTools
        + eventTools
        + experimentTools
        + encryptionTools
        + routingCoverageTools

    private static let previewTools: [Tool] = [
        makeTool(
            name: "preview_sets_list",
            description: "List app preview sets for an App Store version localization. Each set is one (locale, previewType) bucket, e.g. APP_IPHONE_67.",
            properties: [
                ("localization_id", "string", "appStoreVersionLocalization id"),
            ],
            required: ["localization_id"]
        ),
        makeTool(
            name: "preview_sets_create",
            description: "Create an app preview set for the given (localization, previewType). Find-or-create on the server side, so safe to retry.",
            properties: [
                ("localization_id", "string", "appStoreVersionLocalization id"),
                ("preview_type", "string", "ASC previewType code (e.g. APP_IPHONE_67, APP_IPAD_PRO_3GEN_129)"),
            ],
            required: ["localization_id", "preview_type"]
        ),
        makeTool(
            name: "preview_sets_delete",
            description: "Delete an app preview set (removes every preview video inside).",
            properties: [
                ("id", "string", "appPreviewSet id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "previews_list",
            description: "List preview videos inside an app preview set.",
            properties: [
                ("set_id", "string", "appPreviewSet id"),
            ],
            required: ["set_id"]
        ),
        makeTool(
            name: "previews_upload",
            description: "Upload a preview video to an appPreviewSet. Runs the 3-phase reserve / chunk-upload / confirm flow against ASC.",
            properties: [
                ("set_id", "string", "appPreviewSet id"),
                ("file", "string", "absolute path to the .mp4 / .mov file"),
                ("mime_type", "string", "optional MIME type (default video/mp4)"),
                ("preview_frame_time_code", "string", "optional HH:MM:SS.mmm poster-frame timecode"),
            ],
            required: ["set_id", "file"]
        ),
        makeTool(
            name: "previews_delete",
            description: "Delete a single preview video.",
            properties: [
                ("id", "string", "appPreview id"),
            ],
            required: ["id"]
        ),
    ]

    private static let appClipTools: [Tool] = [
        makeTool(
            name: "app_clips_list",
            description: "List App Clips attached to an app. Apple permits one Clip per app today.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "app_clips_create",
            description: "Create an App Clip resource with a child bundle id (e.g. com.example.app.Clip).",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("bundle_id", "string", "child bundle id for the Clip"),
            ],
            required: ["app_id", "bundle_id"]
        ),
        makeTool(
            name: "app_clip_default_experiences_list",
            description: "List default-experience records on an App Clip (one per Clip in practice).",
            properties: [
                ("app_clip_id", "string", "appClip id"),
            ],
            required: ["app_clip_id"]
        ),
        makeTool(
            name: "app_clip_default_experience_create",
            description: "Create a default-experience record under an App Clip.",
            properties: [
                ("app_clip_id", "string", "appClip id"),
                ("action", "string", "optional action verb (OPEN / VIEW / PLAY)"),
            ],
            required: ["app_clip_id"]
        ),
        makeTool(
            name: "app_clip_default_experience_update",
            description: "Update a default-experience's action verb.",
            properties: [
                ("id", "string", "appClipDefaultExperience id"),
                ("action", "string", "new action verb"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "app_clip_default_experience_delete",
            description: "Delete a default-experience record.",
            properties: [
                ("id", "string", "appClipDefaultExperience id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "app_clip_default_localizations_list",
            description: "List per-locale localizations on a default Clip experience.",
            properties: [
                ("experience_id", "string", "appClipDefaultExperience id"),
            ],
            required: ["experience_id"]
        ),
        makeTool(
            name: "app_clip_default_localizations_create",
            description: "Create a per-locale localization on a default Clip experience.",
            properties: [
                ("experience_id", "string", "appClipDefaultExperience id"),
                ("locale", "string", "BCP-47 locale (e.g. en-US, ja)"),
                ("subtitle", "string", "optional subtitle"),
            ],
            required: ["experience_id", "locale"]
        ),
        makeTool(
            name: "app_clip_default_localizations_update",
            description: "Update the subtitle on a default Clip experience localization.",
            properties: [
                ("id", "string", "appClipDefaultExperienceLocalization id"),
                ("subtitle", "string", "new subtitle"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "app_clip_default_localizations_delete",
            description: "Delete a default Clip experience localization.",
            properties: [
                ("id", "string", "appClipDefaultExperienceLocalization id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "app_clip_advanced_experiences_list",
            description: "List URL-triggered advanced Clip experiences on an App Clip.",
            properties: [
                ("app_clip_id", "string", "appClip id"),
            ],
            required: ["app_clip_id"]
        ),
        makeTool(
            name: "app_clip_advanced_experience_create",
            description: "Create an advanced Clip experience tied to a specific link/URL.",
            properties: [
                ("app_clip_id", "string", "appClip id"),
                ("link", "string", "the URL the Clip experience handles"),
                ("action", "string", "optional action verb"),
                ("is_powered_by", "boolean", "whether to surface the 'Powered by' attribution"),
            ],
            required: ["app_clip_id", "link"]
        ),
        makeTool(
            name: "app_clip_advanced_experience_update",
            description: "Update an advanced Clip experience.",
            properties: [
                ("id", "string", "appClipAdvancedExperience id"),
                ("link", "string", "new link URL"),
                ("action", "string", "new action verb"),
                ("is_powered_by", "boolean", "powered-by attribution toggle"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "app_clip_advanced_experience_delete",
            description: "Delete an advanced Clip experience.",
            properties: [
                ("id", "string", "appClipAdvancedExperience id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "app_clip_advanced_localizations_list",
            description: "List per-locale localizations on an advanced Clip experience.",
            properties: [
                ("experience_id", "string", "appClipAdvancedExperience id"),
            ],
            required: ["experience_id"]
        ),
        makeTool(
            name: "app_clip_advanced_localizations_create",
            description: "Create a per-locale localization on an advanced Clip experience.",
            properties: [
                ("experience_id", "string", "appClipAdvancedExperience id"),
                ("language", "string", "BCP-47 locale"),
                ("title", "string", "optional title"),
                ("subtitle", "string", "optional subtitle"),
            ],
            required: ["experience_id", "language"]
        ),
        makeTool(
            name: "app_clip_advanced_localizations_update",
            description: "Update an advanced Clip experience localization.",
            properties: [
                ("id", "string", "appClipAdvancedExperienceLocalization id"),
                ("title", "string", "new title"),
                ("subtitle", "string", "new subtitle"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "app_clip_advanced_localizations_delete",
            description: "Delete an advanced Clip experience localization.",
            properties: [
                ("id", "string", "appClipAdvancedExperienceLocalization id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "app_clip_review_detail_get",
            description: "Get the App Clip review-detail record (invocation URLs Apple reviewers use).",
            properties: [
                ("experience_id", "string", "appClipDefaultExperience id"),
            ],
            required: ["experience_id"]
        ),
        makeTool(
            name: "app_clip_review_detail_update",
            description: "Update an App Clip review-detail's invocation URLs.",
            properties: [
                ("id", "string", "appClipAppStoreReviewDetail id"),
                ("invocation_urls", "array", "array of invocation URL strings"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "app_clip_headers_list",
            description: "List header images attached to an App Clip default experience localization.",
            properties: [
                ("experience_localization_id", "string", "appClipDefaultExperienceLocalization id"),
            ],
            required: ["experience_localization_id"]
        ),
        makeTool(
            name: "app_clip_headers_upload",
            description: "Upload a header image to an App Clip default experience localization. 3-phase reservation flow.",
            properties: [
                ("experience_localization_id", "string", "appClipDefaultExperienceLocalization id"),
                ("file", "string", "absolute path to the image"),
            ],
            required: ["experience_localization_id", "file"]
        ),
        makeTool(
            name: "app_clip_headers_delete",
            description: "Delete an App Clip header image.",
            properties: [
                ("id", "string", "appClipHeaderImage id"),
            ],
            required: ["id"]
        ),
    ]

    private static let customProductPageTools: [Tool] = [
        makeTool(
            name: "cpp_list",
            description: "List custom product pages for an app (up to 35 per app).",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("cursor", "string", "optional pagination cursor"),
                ("limit", "integer", "page size (default 200)"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "cpp_create",
            description: "Create a new custom product page on an app.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("name", "string", "display name for the variant"),
                ("visible", "boolean", "whether the page is enabled (default true)"),
            ],
            required: ["app_id", "name"]
        ),
        makeTool(
            name: "cpp_update",
            description: "Update a custom product page's name or visibility.",
            properties: [
                ("id", "string", "customProductPage id"),
                ("name", "string", "new name"),
                ("visible", "boolean", "new visibility"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "cpp_delete",
            description: "Delete a custom product page.",
            properties: [
                ("id", "string", "customProductPage id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "cpp_versions_list",
            description: "List versions of a custom product page (each version is a separately editable+reviewable revision).",
            properties: [
                ("page_id", "string", "customProductPage id"),
                ("cursor", "string", "optional pagination cursor"),
                ("limit", "integer", "page size (default 200)"),
            ],
            required: ["page_id"]
        ),
        makeTool(
            name: "cpp_versions_create",
            description: "Create a fresh editable version on a custom product page.",
            properties: [
                ("page_id", "string", "customProductPage id"),
            ],
            required: ["page_id"]
        ),
        makeTool(
            name: "cpp_versions_delete",
            description: "Delete a custom product page version.",
            properties: [
                ("id", "string", "customProductPageVersion id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "cpp_localizations_list",
            description: "List per-locale localizations on a custom product page version.",
            properties: [
                ("version_id", "string", "customProductPageVersion id"),
                ("cursor", "string", "optional pagination cursor"),
                ("limit", "integer", "page size (default 200)"),
            ],
            required: ["version_id"]
        ),
        makeTool(
            name: "cpp_localizations_create",
            description: "Create a per-locale localization on a custom product page version (carries the promotional text override).",
            properties: [
                ("version_id", "string", "customProductPageVersion id"),
                ("locale", "string", "BCP-47 locale"),
                ("promotional_text", "string", "optional promotional text"),
            ],
            required: ["version_id", "locale"]
        ),
        makeTool(
            name: "cpp_localizations_update",
            description: "Update the promotional text on a custom product page localization.",
            properties: [
                ("id", "string", "customProductPageLocalization id"),
                ("promotional_text", "string", "new promotional text"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "cpp_localizations_delete",
            description: "Delete a custom product page localization.",
            properties: [
                ("id", "string", "customProductPageLocalization id"),
            ],
            required: ["id"]
        ),
    ]

    private static let eventTools: [Tool] = [
        makeTool(
            name: "events_list",
            description: "List in-app App Events for an app (tournaments, content drops, premieres).",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("cursor", "string", "optional pagination cursor"),
                ("limit", "integer", "page size (default 200)"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "events_get",
            description: "Fetch a single App Event by id.",
            properties: [
                ("id", "string", "appEvent id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "events_create",
            description: "Create a new App Event on an app. Provide attribute fields via the fields object.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("reference_name", "string", "internal reference name"),
                ("badge", "string", "badge code"),
                ("deep_link", "string", "in-app deep link URL"),
                ("purchase_requirement", "string", "purchase requirement code"),
                ("primary_locale", "string", "primary locale (e.g. en-US)"),
                ("priority", "string", "priority code"),
                ("purpose", "string", "purpose code"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "events_update",
            description: "Update an App Event's attribute fields.",
            properties: [
                ("id", "string", "appEvent id"),
                ("reference_name", "string", "reference name"),
                ("badge", "string", "badge code"),
                ("deep_link", "string", "in-app deep link URL"),
                ("purchase_requirement", "string", "purchase requirement"),
                ("primary_locale", "string", "primary locale"),
                ("priority", "string", "priority"),
                ("purpose", "string", "purpose"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "events_delete",
            description: "Delete an App Event.",
            properties: [
                ("id", "string", "appEvent id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "events_localizations_list",
            description: "List per-locale localizations on an App Event.",
            properties: [
                ("event_id", "string", "appEvent id"),
                ("cursor", "string", "optional pagination cursor"),
                ("limit", "integer", "page size (default 200)"),
            ],
            required: ["event_id"]
        ),
        makeTool(
            name: "events_localizations_create",
            description: "Create a per-locale localization on an App Event (name + short/long descriptions).",
            properties: [
                ("event_id", "string", "appEvent id"),
                ("locale", "string", "BCP-47 locale"),
                ("name", "string", "event display name"),
                ("short_description", "string", "short description"),
                ("long_description", "string", "long description"),
            ],
            required: ["event_id", "locale"]
        ),
        makeTool(
            name: "events_localizations_update",
            description: "Update fields on an App Event localization.",
            properties: [
                ("id", "string", "appEventLocalization id"),
                ("name", "string", "new name"),
                ("short_description", "string", "new short description"),
                ("long_description", "string", "new long description"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "events_localizations_delete",
            description: "Delete an App Event localization.",
            properties: [
                ("id", "string", "appEventLocalization id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "events_screenshots_list",
            description: "List screenshots attached to an App Event localization.",
            properties: [
                ("localization_id", "string", "appEventLocalization id"),
            ],
            required: ["localization_id"]
        ),
        makeTool(
            name: "events_screenshots_upload",
            description: "Upload a screenshot to an App Event localization. 3-phase reservation flow.",
            properties: [
                ("localization_id", "string", "appEventLocalization id"),
                ("file", "string", "absolute path to the PNG file"),
            ],
            required: ["localization_id", "file"]
        ),
        makeTool(
            name: "events_screenshots_delete",
            description: "Delete an App Event screenshot.",
            properties: [
                ("id", "string", "appEventScreenshot id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "events_videos_list",
            description: "List video clips attached to an App Event localization.",
            properties: [
                ("localization_id", "string", "appEventLocalization id"),
            ],
            required: ["localization_id"]
        ),
        makeTool(
            name: "events_videos_upload",
            description: "Upload a video clip to an App Event localization. 3-phase reservation flow.",
            properties: [
                ("localization_id", "string", "appEventLocalization id"),
                ("file", "string", "absolute path to the video"),
                ("preview_frame_time_code", "string", "optional poster-frame timecode"),
            ],
            required: ["localization_id", "file"]
        ),
        makeTool(
            name: "events_videos_delete",
            description: "Delete an App Event video clip.",
            properties: [
                ("id", "string", "appEventVideoClip id"),
            ],
            required: ["id"]
        ),
    ]

    private static let experimentTools: [Tool] = [
        makeTool(
            name: "experiments_list",
            description: "List App Store Version experiments (V2) for a version. Each experiment is an A/B test on screenshots + product page.",
            properties: [
                ("version_id", "string", "appStoreVersion id"),
                ("cursor", "string", "optional pagination cursor"),
                ("limit", "integer", "page size (default 200)"),
            ],
            required: ["version_id"]
        ),
        makeTool(
            name: "experiments_get",
            description: "Fetch a single experiment by id.",
            properties: [
                ("id", "string", "appStoreVersionExperiment id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "experiments_create",
            description: "Create a new A/B experiment on a version.",
            properties: [
                ("version_id", "string", "appStoreVersion id"),
                ("name", "string", "experiment display name"),
                ("traffic_proportion", "integer", "optional traffic share (0-100)"),
            ],
            required: ["version_id", "name"]
        ),
        makeTool(
            name: "experiments_update",
            description: "Update an experiment's name / traffic share, or start it (started: true).",
            properties: [
                ("id", "string", "appStoreVersionExperiment id"),
                ("name", "string", "new name"),
                ("traffic_proportion", "integer", "new traffic share"),
                ("started", "boolean", "flip to true to launch the experiment"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "experiments_delete",
            description: "Delete an experiment.",
            properties: [
                ("id", "string", "appStoreVersionExperiment id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "experiments_treatments_list",
            description: "List treatments (variants) for an experiment.",
            properties: [
                ("experiment_id", "string", "appStoreVersionExperiment id"),
                ("cursor", "string", "optional pagination cursor"),
                ("limit", "integer", "page size (default 200)"),
            ],
            required: ["experiment_id"]
        ),
        makeTool(
            name: "experiments_treatments_create",
            description: "Create a treatment variant on an experiment.",
            properties: [
                ("experiment_id", "string", "appStoreVersionExperiment id"),
                ("name", "string", "treatment display name"),
                ("traffic_proportion", "integer", "optional traffic share for this treatment"),
            ],
            required: ["experiment_id", "name"]
        ),
        makeTool(
            name: "experiments_treatments_update",
            description: "Update a treatment's name or traffic share.",
            properties: [
                ("id", "string", "appStoreVersionExperimentTreatment id"),
                ("name", "string", "new name"),
                ("traffic_proportion", "integer", "new traffic share"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "experiments_treatments_delete",
            description: "Delete a treatment.",
            properties: [
                ("id", "string", "appStoreVersionExperimentTreatment id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "experiments_treatment_localizations_list",
            description: "List per-locale localizations on a treatment.",
            properties: [
                ("treatment_id", "string", "appStoreVersionExperimentTreatment id"),
                ("cursor", "string", "optional pagination cursor"),
                ("limit", "integer", "page size (default 200)"),
            ],
            required: ["treatment_id"]
        ),
        makeTool(
            name: "experiments_treatment_localizations_create",
            description: "Create a per-locale localization on a treatment (promotional text / description / keywords overrides).",
            properties: [
                ("treatment_id", "string", "appStoreVersionExperimentTreatment id"),
                ("locale", "string", "BCP-47 locale"),
                ("promotional_text", "string", "optional promotional text"),
                ("description", "string", "optional description"),
                ("keywords", "string", "optional keywords (comma-separated)"),
            ],
            required: ["treatment_id", "locale"]
        ),
        makeTool(
            name: "experiments_treatment_localizations_update",
            description: "Update fields on a treatment localization.",
            properties: [
                ("id", "string", "appStoreVersionExperimentTreatmentLocalization id"),
                ("promotional_text", "string", "new promotional text"),
                ("description", "string", "new description"),
                ("keywords", "string", "new keywords"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "experiments_treatment_localizations_delete",
            description: "Delete a treatment localization.",
            properties: [
                ("id", "string", "appStoreVersionExperimentTreatmentLocalization id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "experiments_treatment_screenshots_upload",
            description: "Upload a screenshot to a treatment's appScreenshotSet. 3-phase reservation flow.",
            properties: [
                ("set_id", "string", "appScreenshotSet id (owned by a treatment localization)"),
                ("file", "string", "absolute path to the PNG"),
            ],
            required: ["set_id", "file"]
        ),
        makeTool(
            name: "experiments_treatment_previews_upload",
            description: "Upload a preview video to a treatment's appPreviewSet. 3-phase reservation flow.",
            properties: [
                ("set_id", "string", "appPreviewSet id (owned by a treatment localization)"),
                ("file", "string", "absolute path to the video"),
                ("mime_type", "string", "optional MIME type"),
                ("preview_frame_time_code", "string", "optional poster-frame timecode"),
            ],
            required: ["set_id", "file"]
        ),
    ]

    private static let encryptionTools: [Tool] = [
        makeTool(
            name: "encryption_decl_list",
            description: "List app encryption declarations for an app.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("cursor", "string", "optional pagination cursor"),
                ("limit", "integer", "page size (default 200)"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "encryption_decl_get",
            description: "Fetch a single encryption declaration by id.",
            properties: [
                ("id", "string", "appEncryptionDeclaration id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "encryption_decl_create",
            description: "Create a new encryption declaration on an app.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("uses_encryption", "boolean", "true if the app uses any encryption"),
                ("contains_proprietary_cryptography", "boolean", "proprietary crypto flag"),
                ("contains_third_party_cryptography", "boolean", "third-party crypto flag"),
                ("available_on_french_store", "boolean", "French store availability flag"),
                ("platform", "string", "IOS | MAC_OS | TV_OS | VISION_OS"),
                ("exempt", "boolean", "ATS / export compliance exemption flag"),
                ("document_name", "string", "optional document name"),
                ("document_type", "string", "optional document type"),
                ("code_value", "string", "optional ERN / code value"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "encryption_decl_update",
            description: "Update fields on an encryption declaration.",
            properties: [
                ("id", "string", "appEncryptionDeclaration id"),
                ("uses_encryption", "boolean", ""),
                ("contains_proprietary_cryptography", "boolean", ""),
                ("contains_third_party_cryptography", "boolean", ""),
                ("available_on_french_store", "boolean", ""),
                ("platform", "string", ""),
                ("exempt", "boolean", ""),
                ("document_name", "string", ""),
                ("document_type", "string", ""),
                ("code_value", "string", ""),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "encryption_decl_documents_list",
            description: "List supporting documents on an encryption declaration.",
            properties: [
                ("declaration_id", "string", "appEncryptionDeclaration id"),
            ],
            required: ["declaration_id"]
        ),
        makeTool(
            name: "encryption_decl_documents_upload",
            description: "Upload a supporting document to an encryption declaration. 3-phase reservation flow.",
            properties: [
                ("declaration_id", "string", "appEncryptionDeclaration id"),
                ("file", "string", "absolute path to the document"),
            ],
            required: ["declaration_id", "file"]
        ),
        makeTool(
            name: "encryption_decl_documents_delete",
            description: "Delete an encryption declaration document.",
            properties: [
                ("id", "string", "appEncryptionDeclarationDocument id"),
            ],
            required: ["id"]
        ),
    ]

    private static let routingCoverageTools: [Tool] = [
        makeTool(
            name: "routing_coverage_get",
            description: "Fetch the routing-app coverage JSON file attached to an app (used by Driving and Navigation apps).",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "routing_coverage_upload",
            description: "Upload a routing-app coverage JSON file to an app. 3-phase reservation flow.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("file", "string", "absolute path to the .geojson / .json file"),
            ],
            required: ["app_id", "file"]
        ),
        makeTool(
            name: "routing_coverage_delete",
            description: "Delete an app's routing-app coverage record.",
            properties: [
                ("id", "string", "routingAppCoverage id"),
            ],
            required: ["id"]
        ),
    ]

    // MARK: - Dispatch

    package static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        switch params.name {
        // App Previews
        case "preview_sets_list":             return await previewSetsList(params)
        case "preview_sets_create":           return await previewSetsCreate(params)
        case "preview_sets_delete":           return await previewSetsDelete(params)
        case "previews_list":                 return await previewsList(params)
        case "previews_upload":               return await previewsUpload(params)
        case "previews_delete":               return await previewsDelete(params)
        // App Clips
        case "app_clips_list":                return await appClipsList(params)
        case "app_clips_create":              return await appClipsCreate(params)
        case "app_clip_default_experiences_list":
            return await appClipDefaultExperiencesList(params)
        case "app_clip_default_experience_create":
            return await appClipDefaultExperienceCreate(params)
        case "app_clip_default_experience_update":
            return await appClipDefaultExperienceUpdate(params)
        case "app_clip_default_experience_delete":
            return await appClipDefaultExperienceDelete(params)
        case "app_clip_default_localizations_list":
            return await appClipDefaultLocalizationsList(params)
        case "app_clip_default_localizations_create":
            return await appClipDefaultLocalizationsCreate(params)
        case "app_clip_default_localizations_update":
            return await appClipDefaultLocalizationsUpdate(params)
        case "app_clip_default_localizations_delete":
            return await appClipDefaultLocalizationsDelete(params)
        case "app_clip_advanced_experiences_list":
            return await appClipAdvancedExperiencesList(params)
        case "app_clip_advanced_experience_create":
            return await appClipAdvancedExperienceCreate(params)
        case "app_clip_advanced_experience_update":
            return await appClipAdvancedExperienceUpdate(params)
        case "app_clip_advanced_experience_delete":
            return await appClipAdvancedExperienceDelete(params)
        case "app_clip_advanced_localizations_list":
            return await appClipAdvancedLocalizationsList(params)
        case "app_clip_advanced_localizations_create":
            return await appClipAdvancedLocalizationsCreate(params)
        case "app_clip_advanced_localizations_update":
            return await appClipAdvancedLocalizationsUpdate(params)
        case "app_clip_advanced_localizations_delete":
            return await appClipAdvancedLocalizationsDelete(params)
        case "app_clip_review_detail_get":    return await appClipReviewDetailGet(params)
        case "app_clip_review_detail_update": return await appClipReviewDetailUpdate(params)
        case "app_clip_headers_list":         return await appClipHeadersList(params)
        case "app_clip_headers_upload":       return await appClipHeadersUpload(params)
        case "app_clip_headers_delete":       return await appClipHeadersDelete(params)
        // Custom Product Pages
        case "cpp_list":                      return await cppList(params)
        case "cpp_create":                    return await cppCreate(params)
        case "cpp_update":                    return await cppUpdate(params)
        case "cpp_delete":                    return await cppDelete(params)
        case "cpp_versions_list":             return await cppVersionsList(params)
        case "cpp_versions_create":           return await cppVersionsCreate(params)
        case "cpp_versions_delete":           return await cppVersionsDelete(params)
        case "cpp_localizations_list":        return await cppLocalizationsList(params)
        case "cpp_localizations_create":      return await cppLocalizationsCreate(params)
        case "cpp_localizations_update":      return await cppLocalizationsUpdate(params)
        case "cpp_localizations_delete":      return await cppLocalizationsDelete(params)
        // App Events
        case "events_list":                   return await eventsList(params)
        case "events_get":                    return await eventsGet(params)
        case "events_create":                 return await eventsCreate(params)
        case "events_update":                 return await eventsUpdate(params)
        case "events_delete":                 return await eventsDelete(params)
        case "events_localizations_list":     return await eventsLocalizationsList(params)
        case "events_localizations_create":   return await eventsLocalizationsCreate(params)
        case "events_localizations_update":   return await eventsLocalizationsUpdate(params)
        case "events_localizations_delete":   return await eventsLocalizationsDelete(params)
        case "events_screenshots_list":       return await eventsScreenshotsList(params)
        case "events_screenshots_upload":     return await eventsScreenshotsUpload(params)
        case "events_screenshots_delete":     return await eventsScreenshotsDelete(params)
        case "events_videos_list":            return await eventsVideosList(params)
        case "events_videos_upload":          return await eventsVideosUpload(params)
        case "events_videos_delete":          return await eventsVideosDelete(params)
        // Experiments
        case "experiments_list":              return await experimentsList(params)
        case "experiments_get":               return await experimentsGet(params)
        case "experiments_create":            return await experimentsCreate(params)
        case "experiments_update":            return await experimentsUpdate(params)
        case "experiments_delete":            return await experimentsDelete(params)
        case "experiments_treatments_list":   return await experimentsTreatmentsList(params)
        case "experiments_treatments_create": return await experimentsTreatmentsCreate(params)
        case "experiments_treatments_update": return await experimentsTreatmentsUpdate(params)
        case "experiments_treatments_delete": return await experimentsTreatmentsDelete(params)
        case "experiments_treatment_localizations_list":
            return await experimentsTreatmentLocalizationsList(params)
        case "experiments_treatment_localizations_create":
            return await experimentsTreatmentLocalizationsCreate(params)
        case "experiments_treatment_localizations_update":
            return await experimentsTreatmentLocalizationsUpdate(params)
        case "experiments_treatment_localizations_delete":
            return await experimentsTreatmentLocalizationsDelete(params)
        case "experiments_treatment_screenshots_upload":
            return await experimentsTreatmentScreenshotsUpload(params)
        case "experiments_treatment_previews_upload":
            return await experimentsTreatmentPreviewsUpload(params)
        // Encryption declarations
        case "encryption_decl_list":          return await encryptionDeclList(params)
        case "encryption_decl_get":           return await encryptionDeclGet(params)
        case "encryption_decl_create":        return await encryptionDeclCreate(params)
        case "encryption_decl_update":        return await encryptionDeclUpdate(params)
        case "encryption_decl_documents_list":
            return await encryptionDeclDocumentsList(params)
        case "encryption_decl_documents_upload":
            return await encryptionDeclDocumentsUpload(params)
        case "encryption_decl_documents_delete":
            return await encryptionDeclDocumentsDelete(params)
        // Routing coverage
        case "routing_coverage_get":          return await routingCoverageGet(params)
        case "routing_coverage_upload":       return await routingCoverageUpload(params)
        case "routing_coverage_delete":       return await routingCoverageDelete(params)
        default:
            return .init(
                content: [.text("Unknown marketing tool: \(params.name)")],
                isError: true
            )
        }
    }

    // MARK: - Handlers: App Previews

    static func previewSetsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let l = requireString(p, "localization_id"); guard case .left(let locID) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        do {
            let sets = try await AppPreviewsAPI(client: client).listPreviewSets(localizationID: locID)
            return emitJSON(sets, header: "\(sets.count) appPreviewSet(s)")
        } catch {
            return emitAPIError(error, context: "preview_sets_list failed")
        }
    }

    static func previewSetsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let lid = requireString(p, "localization_id"); guard case .left(let locID) = lid else {
            if case .right(let r) = lid { return r }; return .init(isError: true)
        }
        let pt = requireString(p, "preview_type"); guard case .left(let previewType) = pt else {
            if case .right(let r) = pt { return r }; return .init(isError: true)
        }
        do {
            let set = try await AppPreviewsAPI(client: client).findOrCreatePreviewSet(
                localizationID: locID, previewType: previewType
            )
            return emitJSON(set)
        } catch {
            return emitAPIError(error, context: "preview_sets_create failed")
        }
    }

    static func previewSetsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            try await AppPreviewsAPI(client: client).deletePreviewSet(id: id)
            return .init(content: [.text("Deleted appPreviewSet \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "preview_sets_delete failed")
        }
    }

    static func previewsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let s = requireString(p, "set_id"); guard case .left(let setID) = s else {
            if case .right(let r) = s { return r }; return .init(isError: true)
        }
        do {
            let previews = try await AppPreviewsAPI(client: client).listPreviews(setID: setID)
            return emitJSON(previews, header: "\(previews.count) appPreview(s)")
        } catch {
            return emitAPIError(error, context: "previews_list failed")
        }
    }

    static func previewsUpload(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let s = requireString(p, "set_id"); guard case .left(let setID) = s else {
            if case .right(let r) = s { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        let mime = p.arguments?["mime_type"]?.stringValue
        let tc = p.arguments?["preview_frame_time_code"]?.stringValue
        do {
            let preview = try await AppPreviewsAPI(client: client).uploadPreview(
                setID: setID,
                fileURL: URL(fileURLWithPath: file),
                mimeType: mime,
                previewFrameTimeCode: tc
            )
            return emitJSON(preview, header: "Uploaded preview \(preview.id)")
        } catch {
            return emitAPIError(error, context: "previews_upload failed")
        }
    }

    static func previewsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            try await AppPreviewsAPI(client: client).deletePreview(id: id)
            return .init(content: [.text("Deleted appPreview \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "previews_delete failed")
        }
    }

    // MARK: - Handlers: App Clips

    static func appClipsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        do {
            let clips = try await AppClipsAPI(client: client).listAppClips(appID: appID)
            return emitJSON(clips, header: "\(clips.count) appClip(s)")
        } catch {
            return emitAPIError(error, context: "app_clips_list failed")
        }
    }

    static func appClipsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let b = requireString(p, "bundle_id"); guard case .left(let bid) = b else {
            if case .right(let r) = b { return r }; return .init(isError: true)
        }
        do {
            let clip = try await AppClipsAPI(client: client).createAppClip(
                appID: appID, bundleID: bid
            )
            return emitJSON(clip)
        } catch {
            return emitAPIError(error, context: "app_clips_create failed")
        }
    }

    static func appClipDefaultExperiencesList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let c = requireString(p, "app_clip_id"); guard case .left(let cid) = c else {
            if case .right(let r) = c { return r }; return .init(isError: true)
        }
        do {
            let list = try await AppClipsAPI(client: client).listDefaultExperiences(appClipID: cid)
            return emitJSON(list, header: "\(list.count) default experience(s)")
        } catch {
            return emitAPIError(error, context: "app_clip_default_experiences_list failed")
        }
    }

    static func appClipDefaultExperienceCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let c = requireString(p, "app_clip_id"); guard case .left(let cid) = c else {
            if case .right(let r) = c { return r }; return .init(isError: true)
        }
        let action = p.arguments?["action"]?.stringValue
        do {
            let exp = try await AppClipsAPI(client: client).createDefaultExperience(
                appClipID: cid, action: action
            )
            return emitJSON(exp)
        } catch {
            return emitAPIError(error, context: "app_clip_default_experience_create failed")
        }
    }

    static func appClipDefaultExperienceUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let action = p.arguments?["action"]?.stringValue
        do {
            let exp = try await AppClipsAPI(client: client).updateDefaultExperience(
                id: id, action: action
            )
            return emitJSON(exp)
        } catch {
            return emitAPIError(error, context: "app_clip_default_experience_update failed")
        }
    }

    static func appClipDefaultExperienceDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await AppClipsAPI(client: client).deleteDefaultExperience(id: id)
            return .init(content: [.text("Deleted default experience \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "app_clip_default_experience_delete failed")
        }
    }

    static func appClipDefaultLocalizationsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "experience_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        do {
            let list = try await AppClipsAPI(client: client).listDefaultExperienceLocalizations(
                experienceID: eid
            )
            return emitJSON(list, header: "\(list.count) localization(s)")
        } catch {
            return emitAPIError(error, context: "app_clip_default_localizations_list failed")
        }
    }

    static func appClipDefaultLocalizationsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "experience_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        let l = requireString(p, "locale"); guard case .left(let locale) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        let subtitle = p.arguments?["subtitle"]?.stringValue
        do {
            let loc = try await AppClipsAPI(client: client).createDefaultExperienceLocalization(
                experienceID: eid, locale: locale, subtitle: subtitle
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "app_clip_default_localizations_create failed")
        }
    }

    static func appClipDefaultLocalizationsUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let subtitle = p.arguments?["subtitle"]?.stringValue
        do {
            let loc = try await AppClipsAPI(client: client).updateDefaultExperienceLocalization(
                id: id, subtitle: subtitle
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "app_clip_default_localizations_update failed")
        }
    }

    static func appClipDefaultLocalizationsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await AppClipsAPI(client: client).deleteDefaultExperienceLocalization(id: id)
            return .init(content: [.text("Deleted default experience localization \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "app_clip_default_localizations_delete failed")
        }
    }

    static func appClipAdvancedExperiencesList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let c = requireString(p, "app_clip_id"); guard case .left(let cid) = c else {
            if case .right(let r) = c { return r }; return .init(isError: true)
        }
        do {
            let list = try await AppClipsAPI(client: client).listAdvancedExperiences(appClipID: cid)
            return emitJSON(list, header: "\(list.count) advanced experience(s)")
        } catch {
            return emitAPIError(error, context: "app_clip_advanced_experiences_list failed")
        }
    }

    static func appClipAdvancedExperienceCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let c = requireString(p, "app_clip_id"); guard case .left(let cid) = c else {
            if case .right(let r) = c { return r }; return .init(isError: true)
        }
        let l = requireString(p, "link"); guard case .left(let link) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        let action = p.arguments?["action"]?.stringValue
        let pwr = p.arguments?["is_powered_by"]?.boolValue
        do {
            let exp = try await AppClipsAPI(client: client).createAdvancedExperience(
                appClipID: cid, link: link, action: action, isPoweredBy: pwr
            )
            return emitJSON(exp)
        } catch {
            return emitAPIError(error, context: "app_clip_advanced_experience_create failed")
        }
    }

    static func appClipAdvancedExperienceUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let link = p.arguments?["link"]?.stringValue
        let action = p.arguments?["action"]?.stringValue
        let pwr = p.arguments?["is_powered_by"]?.boolValue
        do {
            let exp = try await AppClipsAPI(client: client).updateAdvancedExperience(
                id: id, link: link, action: action, isPoweredBy: pwr
            )
            return emitJSON(exp)
        } catch {
            return emitAPIError(error, context: "app_clip_advanced_experience_update failed")
        }
    }

    static func appClipAdvancedExperienceDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await AppClipsAPI(client: client).deleteAdvancedExperience(id: id)
            return .init(content: [.text("Deleted advanced experience \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "app_clip_advanced_experience_delete failed")
        }
    }

    static func appClipAdvancedLocalizationsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "experience_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        do {
            let list = try await AppClipsAPI(client: client).listAdvancedExperienceLocalizations(
                experienceID: eid
            )
            return emitJSON(list, header: "\(list.count) advanced localization(s)")
        } catch {
            return emitAPIError(error, context: "app_clip_advanced_localizations_list failed")
        }
    }

    static func appClipAdvancedLocalizationsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "experience_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        let lng = requireString(p, "language"); guard case .left(let lang) = lng else {
            if case .right(let r) = lng { return r }; return .init(isError: true)
        }
        let title = p.arguments?["title"]?.stringValue
        let subtitle = p.arguments?["subtitle"]?.stringValue
        do {
            let loc = try await AppClipsAPI(client: client).createAdvancedExperienceLocalization(
                experienceID: eid, language: lang, title: title, subtitle: subtitle
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "app_clip_advanced_localizations_create failed")
        }
    }

    static func appClipAdvancedLocalizationsUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let title = p.arguments?["title"]?.stringValue
        let subtitle = p.arguments?["subtitle"]?.stringValue
        do {
            let loc = try await AppClipsAPI(client: client).updateAdvancedExperienceLocalization(
                id: id, title: title, subtitle: subtitle
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "app_clip_advanced_localizations_update failed")
        }
    }

    static func appClipAdvancedLocalizationsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await AppClipsAPI(client: client).deleteAdvancedExperienceLocalization(id: id)
            return .init(content: [.text("Deleted advanced experience localization \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "app_clip_advanced_localizations_delete failed")
        }
    }

    static func appClipReviewDetailGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "experience_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        do {
            if let detail = try await AppClipsAPI(client: client).getReviewDetail(experienceID: eid) {
                return emitJSON(detail)
            }
            return .init(content: [.text("No review detail attached to default experience \(eid).")], isError: false)
        } catch {
            return emitAPIError(error, context: "app_clip_review_detail_get failed")
        }
    }

    static func appClipReviewDetailUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let urls = p.arguments?["invocation_urls"]?.arrayValue?.compactMap { $0.stringValue }
        do {
            let detail = try await AppClipsAPI(client: client).updateReviewDetail(
                id: id, invocationUrls: urls
            )
            return emitJSON(detail)
        } catch {
            return emitAPIError(error, context: "app_clip_review_detail_update failed")
        }
    }

    static func appClipHeadersList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "experience_localization_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        do {
            let headers = try await AppClipsAPI(client: client).listHeaders(experienceLocalizationID: eid)
            return emitJSON(headers, header: "\(headers.count) header(s)")
        } catch {
            return emitAPIError(error, context: "app_clip_headers_list failed")
        }
    }

    static func appClipHeadersUpload(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "experience_localization_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        do {
            let header = try await AppClipsAPI(client: client).uploadHeader(
                experienceLocalizationID: eid,
                fileURL: URL(fileURLWithPath: file)
            )
            return emitJSON(header, header: "Uploaded header \(header.id)")
        } catch {
            return emitAPIError(error, context: "app_clip_headers_upload failed")
        }
    }

    static func appClipHeadersDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await AppClipsAPI(client: client).deleteHeader(id: id)
            return .init(content: [.text("Deleted header \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "app_clip_headers_delete failed")
        }
    }

    // MARK: - Handlers: Custom Product Pages

    static func cppList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let cursor = p.arguments?["cursor"]?.stringValue
        let limit = p.arguments?["limit"]?.intValue ?? 200
        do {
            let result = try await CustomProductPagesAPI(client: client).listPages(
                appID: appID, limit: limit, cursor: cursor
            )
            struct Out: Encodable {
                let pages: [CustomProductPagesAPI.Page]
                let nextCursor: String?
            }
            return emitJSON(
                Out(pages: result.pages, nextCursor: result.nextCursor),
                header: "\(result.pages.count) page(s)"
            )
        } catch {
            return emitAPIError(error, context: "cpp_list failed")
        }
    }

    static func cppCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let n = requireString(p, "name"); guard case .left(let name) = n else {
            if case .right(let r) = n { return r }; return .init(isError: true)
        }
        let visible = p.arguments?["visible"]?.boolValue ?? true
        do {
            let page = try await CustomProductPagesAPI(client: client).createPage(
                appID: appID, name: name, visible: visible
            )
            return emitJSON(page)
        } catch {
            return emitAPIError(error, context: "cpp_create failed")
        }
    }

    static func cppUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let name = p.arguments?["name"]?.stringValue
        let visible = p.arguments?["visible"]?.boolValue
        do {
            let page = try await CustomProductPagesAPI(client: client).updatePage(
                id: id, name: name, visible: visible
            )
            return emitJSON(page)
        } catch {
            return emitAPIError(error, context: "cpp_update failed")
        }
    }

    static func cppDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await CustomProductPagesAPI(client: client).deletePage(id: id)
            return .init(content: [.text("Deleted custom product page \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "cpp_delete failed")
        }
    }

    static func cppVersionsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let g = requireString(p, "page_id"); guard case .left(let pid) = g else {
            if case .right(let r) = g { return r }; return .init(isError: true)
        }
        let cursor = p.arguments?["cursor"]?.stringValue
        let limit = p.arguments?["limit"]?.intValue ?? 200
        do {
            let result = try await CustomProductPagesAPI(client: client).listVersions(
                pageID: pid, limit: limit, cursor: cursor
            )
            struct Out: Encodable {
                let versions: [CustomProductPagesAPI.Version]
                let nextCursor: String?
            }
            return emitJSON(
                Out(versions: result.versions, nextCursor: result.nextCursor),
                header: "\(result.versions.count) version(s)"
            )
        } catch {
            return emitAPIError(error, context: "cpp_versions_list failed")
        }
    }

    static func cppVersionsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let g = requireString(p, "page_id"); guard case .left(let pid) = g else {
            if case .right(let r) = g { return r }; return .init(isError: true)
        }
        do {
            let v = try await CustomProductPagesAPI(client: client).createVersion(pageID: pid)
            return emitJSON(v)
        } catch {
            return emitAPIError(error, context: "cpp_versions_create failed")
        }
    }

    static func cppVersionsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await CustomProductPagesAPI(client: client).deleteVersion(id: id)
            return .init(content: [.text("Deleted cpp version \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "cpp_versions_delete failed")
        }
    }

    static func cppLocalizationsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let vid) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        let cursor = p.arguments?["cursor"]?.stringValue
        let limit = p.arguments?["limit"]?.intValue ?? 200
        do {
            let result = try await CustomProductPagesAPI(client: client).listLocalizations(
                versionID: vid, limit: limit, cursor: cursor
            )
            struct Out: Encodable {
                let localizations: [CustomProductPagesAPI.Localization]
                let nextCursor: String?
            }
            return emitJSON(
                Out(localizations: result.localizations, nextCursor: result.nextCursor),
                header: "\(result.localizations.count) localization(s)"
            )
        } catch {
            return emitAPIError(error, context: "cpp_localizations_list failed")
        }
    }

    static func cppLocalizationsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let vid) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        let l = requireString(p, "locale"); guard case .left(let locale) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        let promo = p.arguments?["promotional_text"]?.stringValue
        do {
            let loc = try await CustomProductPagesAPI(client: client).createLocalization(
                versionID: vid, locale: locale, promotionalText: promo
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "cpp_localizations_create failed")
        }
    }

    static func cppLocalizationsUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let promo = p.arguments?["promotional_text"]?.stringValue
        do {
            let loc = try await CustomProductPagesAPI(client: client).updateLocalization(
                id: id, promotionalText: promo
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "cpp_localizations_update failed")
        }
    }

    static func cppLocalizationsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await CustomProductPagesAPI(client: client).deleteLocalization(id: id)
            return .init(content: [.text("Deleted cpp localization \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "cpp_localizations_delete failed")
        }
    }

    // MARK: - Handlers: App Events

    static func eventsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let cursor = p.arguments?["cursor"]?.stringValue
        let limit = p.arguments?["limit"]?.intValue ?? 200
        do {
            let result = try await AppEventsAPI(client: client).listAppEvents(
                appID: appID, limit: limit, cursor: cursor
            )
            struct Out: Encodable {
                let events: [AppEventsAPI.AppEvent]
                let nextCursor: String?
            }
            return emitJSON(
                Out(events: result.events, nextCursor: result.nextCursor),
                header: "\(result.events.count) event(s)"
            )
        } catch {
            return emitAPIError(error, context: "events_list failed")
        }
    }

    static func eventsGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            if let event = try await AppEventsAPI(client: client).getAppEvent(id: id) {
                return emitJSON(event)
            }
            return .init(content: [.text("No app event \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "events_get failed")
        }
    }

    static func eventsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let fields = AppEventsAPI.EventFields(
            referenceName: p.arguments?["reference_name"]?.stringValue,
            badge: p.arguments?["badge"]?.stringValue,
            deepLink: p.arguments?["deep_link"]?.stringValue,
            purchaseRequirement: p.arguments?["purchase_requirement"]?.stringValue,
            primaryLocale: p.arguments?["primary_locale"]?.stringValue,
            priority: p.arguments?["priority"]?.stringValue,
            purpose: p.arguments?["purpose"]?.stringValue
        )
        do {
            let event = try await AppEventsAPI(client: client).createAppEvent(
                appID: appID, fields: fields
            )
            return emitJSON(event)
        } catch {
            return emitAPIError(error, context: "events_create failed")
        }
    }

    static func eventsUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let fields = AppEventsAPI.EventFields(
            referenceName: p.arguments?["reference_name"]?.stringValue,
            badge: p.arguments?["badge"]?.stringValue,
            deepLink: p.arguments?["deep_link"]?.stringValue,
            purchaseRequirement: p.arguments?["purchase_requirement"]?.stringValue,
            primaryLocale: p.arguments?["primary_locale"]?.stringValue,
            priority: p.arguments?["priority"]?.stringValue,
            purpose: p.arguments?["purpose"]?.stringValue
        )
        do {
            let event = try await AppEventsAPI(client: client).updateAppEvent(
                id: id, fields: fields
            )
            return emitJSON(event)
        } catch {
            return emitAPIError(error, context: "events_update failed")
        }
    }

    static func eventsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await AppEventsAPI(client: client).deleteAppEvent(id: id)
            return .init(content: [.text("Deleted app event \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "events_delete failed")
        }
    }

    static func eventsLocalizationsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "event_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        let cursor = p.arguments?["cursor"]?.stringValue
        let limit = p.arguments?["limit"]?.intValue ?? 200
        do {
            let result = try await AppEventsAPI(client: client).listLocalizations(
                eventID: eid, limit: limit, cursor: cursor
            )
            struct Out: Encodable {
                let localizations: [AppEventsAPI.EventLocalization]
                let nextCursor: String?
            }
            return emitJSON(
                Out(localizations: result.localizations, nextCursor: result.nextCursor),
                header: "\(result.localizations.count) localization(s)"
            )
        } catch {
            return emitAPIError(error, context: "events_localizations_list failed")
        }
    }

    static func eventsLocalizationsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "event_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        let l = requireString(p, "locale"); guard case .left(let locale) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        let name = p.arguments?["name"]?.stringValue
        let short = p.arguments?["short_description"]?.stringValue
        let long = p.arguments?["long_description"]?.stringValue
        do {
            let loc = try await AppEventsAPI(client: client).createLocalization(
                eventID: eid, locale: locale, name: name,
                shortDescription: short, longDescription: long
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "events_localizations_create failed")
        }
    }

    static func eventsLocalizationsUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let name = p.arguments?["name"]?.stringValue
        let short = p.arguments?["short_description"]?.stringValue
        let long = p.arguments?["long_description"]?.stringValue
        do {
            let loc = try await AppEventsAPI(client: client).updateLocalization(
                id: id, name: name, shortDescription: short, longDescription: long
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "events_localizations_update failed")
        }
    }

    static func eventsLocalizationsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await AppEventsAPI(client: client).deleteLocalization(id: id)
            return .init(content: [.text("Deleted event localization \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "events_localizations_delete failed")
        }
    }

    static func eventsScreenshotsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let l = requireString(p, "localization_id"); guard case .left(let lid) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        do {
            let shots = try await AppEventsAPI(client: client).listScreenshots(localizationID: lid)
            return emitJSON(shots, header: "\(shots.count) screenshot(s)")
        } catch {
            return emitAPIError(error, context: "events_screenshots_list failed")
        }
    }

    static func eventsScreenshotsUpload(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let l = requireString(p, "localization_id"); guard case .left(let lid) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        do {
            let shot = try await AppEventsAPI(client: client).uploadScreenshot(
                localizationID: lid,
                fileURL: URL(fileURLWithPath: file)
            )
            return emitJSON(shot, header: "Uploaded event screenshot \(shot.id)")
        } catch {
            return emitAPIError(error, context: "events_screenshots_upload failed")
        }
    }

    static func eventsScreenshotsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await AppEventsAPI(client: client).deleteScreenshot(id: id)
            return .init(content: [.text("Deleted event screenshot \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "events_screenshots_delete failed")
        }
    }

    static func eventsVideosList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let l = requireString(p, "localization_id"); guard case .left(let lid) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        do {
            let clips = try await AppEventsAPI(client: client).listVideoClips(localizationID: lid)
            return emitJSON(clips, header: "\(clips.count) video clip(s)")
        } catch {
            return emitAPIError(error, context: "events_videos_list failed")
        }
    }

    static func eventsVideosUpload(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let l = requireString(p, "localization_id"); guard case .left(let lid) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        let tc = p.arguments?["preview_frame_time_code"]?.stringValue
        do {
            let clip = try await AppEventsAPI(client: client).uploadVideoClip(
                localizationID: lid,
                fileURL: URL(fileURLWithPath: file),
                previewFrameTimeCode: tc
            )
            return emitJSON(clip, header: "Uploaded event video \(clip.id)")
        } catch {
            return emitAPIError(error, context: "events_videos_upload failed")
        }
    }

    static func eventsVideosDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await AppEventsAPI(client: client).deleteVideoClip(id: id)
            return .init(content: [.text("Deleted event video \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "events_videos_delete failed")
        }
    }

    // MARK: - Handlers: Experiments

    static func experimentsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let vid) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        let cursor = p.arguments?["cursor"]?.stringValue
        let limit = p.arguments?["limit"]?.intValue ?? 200
        do {
            let result = try await ExperimentsAPI(client: client).listExperiments(
                versionID: vid, limit: limit, cursor: cursor
            )
            struct Out: Encodable {
                let experiments: [ExperimentsAPI.Experiment]
                let nextCursor: String?
            }
            return emitJSON(
                Out(experiments: result.experiments, nextCursor: result.nextCursor),
                header: "\(result.experiments.count) experiment(s)"
            )
        } catch {
            return emitAPIError(error, context: "experiments_list failed")
        }
    }

    static func experimentsGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            if let exp = try await ExperimentsAPI(client: client).getExperiment(id: id) {
                return emitJSON(exp)
            }
            return .init(content: [.text("No experiment \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "experiments_get failed")
        }
    }

    static func experimentsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let vid) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        let n = requireString(p, "name"); guard case .left(let name) = n else {
            if case .right(let r) = n { return r }; return .init(isError: true)
        }
        let tp = p.arguments?["traffic_proportion"]?.intValue
        do {
            let exp = try await ExperimentsAPI(client: client).createExperiment(
                versionID: vid, name: name, trafficProportion: tp
            )
            return emitJSON(exp)
        } catch {
            return emitAPIError(error, context: "experiments_create failed")
        }
    }

    static func experimentsUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let name = p.arguments?["name"]?.stringValue
        let tp = p.arguments?["traffic_proportion"]?.intValue
        let started = p.arguments?["started"]?.boolValue
        do {
            let exp = try await ExperimentsAPI(client: client).updateExperiment(
                id: id, name: name, trafficProportion: tp, started: started
            )
            return emitJSON(exp)
        } catch {
            return emitAPIError(error, context: "experiments_update failed")
        }
    }

    static func experimentsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await ExperimentsAPI(client: client).deleteExperiment(id: id)
            return .init(content: [.text("Deleted experiment \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "experiments_delete failed")
        }
    }

    static func experimentsTreatmentsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "experiment_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        let cursor = p.arguments?["cursor"]?.stringValue
        let limit = p.arguments?["limit"]?.intValue ?? 200
        do {
            let result = try await ExperimentsAPI(client: client).listTreatments(
                experimentID: eid, limit: limit, cursor: cursor
            )
            struct Out: Encodable {
                let treatments: [ExperimentsAPI.Treatment]
                let nextCursor: String?
            }
            return emitJSON(
                Out(treatments: result.treatments, nextCursor: result.nextCursor),
                header: "\(result.treatments.count) treatment(s)"
            )
        } catch {
            return emitAPIError(error, context: "experiments_treatments_list failed")
        }
    }

    static func experimentsTreatmentsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let e = requireString(p, "experiment_id"); guard case .left(let eid) = e else {
            if case .right(let r) = e { return r }; return .init(isError: true)
        }
        let n = requireString(p, "name"); guard case .left(let name) = n else {
            if case .right(let r) = n { return r }; return .init(isError: true)
        }
        let tp = p.arguments?["traffic_proportion"]?.intValue
        do {
            let t = try await ExperimentsAPI(client: client).createTreatment(
                experimentID: eid, name: name, trafficProportion: tp
            )
            return emitJSON(t)
        } catch {
            return emitAPIError(error, context: "experiments_treatments_create failed")
        }
    }

    static func experimentsTreatmentsUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let name = p.arguments?["name"]?.stringValue
        let tp = p.arguments?["traffic_proportion"]?.intValue
        do {
            let t = try await ExperimentsAPI(client: client).updateTreatment(
                id: id, name: name, trafficProportion: tp
            )
            return emitJSON(t)
        } catch {
            return emitAPIError(error, context: "experiments_treatments_update failed")
        }
    }

    static func experimentsTreatmentsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await ExperimentsAPI(client: client).deleteTreatment(id: id)
            return .init(content: [.text("Deleted treatment \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "experiments_treatments_delete failed")
        }
    }

    static func experimentsTreatmentLocalizationsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let t = requireString(p, "treatment_id"); guard case .left(let tid) = t else {
            if case .right(let r) = t { return r }; return .init(isError: true)
        }
        let cursor = p.arguments?["cursor"]?.stringValue
        let limit = p.arguments?["limit"]?.intValue ?? 200
        do {
            let result = try await ExperimentsAPI(client: client).listTreatmentLocalizations(
                treatmentID: tid, limit: limit, cursor: cursor
            )
            struct Out: Encodable {
                let localizations: [ExperimentsAPI.TreatmentLocalization]
                let nextCursor: String?
            }
            return emitJSON(
                Out(localizations: result.localizations, nextCursor: result.nextCursor),
                header: "\(result.localizations.count) treatment localization(s)"
            )
        } catch {
            return emitAPIError(error, context: "experiments_treatment_localizations_list failed")
        }
    }

    static func experimentsTreatmentLocalizationsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let t = requireString(p, "treatment_id"); guard case .left(let tid) = t else {
            if case .right(let r) = t { return r }; return .init(isError: true)
        }
        let l = requireString(p, "locale"); guard case .left(let locale) = l else {
            if case .right(let r) = l { return r }; return .init(isError: true)
        }
        let promo = p.arguments?["promotional_text"]?.stringValue
        let desc = p.arguments?["description"]?.stringValue
        let kw = p.arguments?["keywords"]?.stringValue
        do {
            let loc = try await ExperimentsAPI(client: client).createTreatmentLocalization(
                treatmentID: tid, locale: locale,
                promotionalText: promo, description: desc, keywords: kw
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "experiments_treatment_localizations_create failed")
        }
    }

    static func experimentsTreatmentLocalizationsUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let promo = p.arguments?["promotional_text"]?.stringValue
        let desc = p.arguments?["description"]?.stringValue
        let kw = p.arguments?["keywords"]?.stringValue
        do {
            let loc = try await ExperimentsAPI(client: client).updateTreatmentLocalization(
                id: id, promotionalText: promo, description: desc, keywords: kw
            )
            return emitJSON(loc)
        } catch {
            return emitAPIError(error, context: "experiments_treatment_localizations_update failed")
        }
    }

    static func experimentsTreatmentLocalizationsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await ExperimentsAPI(client: client).deleteTreatmentLocalization(id: id)
            return .init(content: [.text("Deleted treatment localization \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "experiments_treatment_localizations_delete failed")
        }
    }

    static func experimentsTreatmentScreenshotsUpload(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let s = requireString(p, "set_id"); guard case .left(let setID) = s else {
            if case .right(let r) = s { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        do {
            let shot = try await ExperimentsAPI(client: client).uploadTreatmentScreenshot(
                setID: setID, fileURL: URL(fileURLWithPath: file)
            )
            return emitJSON(shot, header: "Uploaded treatment screenshot \(shot.id)")
        } catch {
            return emitAPIError(error, context: "experiments_treatment_screenshots_upload failed")
        }
    }

    static func experimentsTreatmentPreviewsUpload(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let s = requireString(p, "set_id"); guard case .left(let setID) = s else {
            if case .right(let r) = s { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        let mime = p.arguments?["mime_type"]?.stringValue
        let tc = p.arguments?["preview_frame_time_code"]?.stringValue
        do {
            let preview = try await ExperimentsAPI(client: client).uploadTreatmentPreview(
                setID: setID,
                fileURL: URL(fileURLWithPath: file),
                mimeType: mime,
                previewFrameTimeCode: tc
            )
            return emitJSON(preview, header: "Uploaded treatment preview \(preview.id)")
        } catch {
            return emitAPIError(error, context: "experiments_treatment_previews_upload failed")
        }
    }

    // MARK: - Handlers: Encryption Declarations

    static func encryptionDeclList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let cursor = p.arguments?["cursor"]?.stringValue
        let limit = p.arguments?["limit"]?.intValue ?? 200
        do {
            let result = try await EncryptionDeclarationsAPI(client: client).listDeclarations(
                appID: appID, limit: limit, cursor: cursor
            )
            struct Out: Encodable {
                let declarations: [EncryptionDeclarationsAPI.Declaration]
                let nextCursor: String?
            }
            return emitJSON(
                Out(declarations: result.declarations, nextCursor: result.nextCursor),
                header: "\(result.declarations.count) declaration(s)"
            )
        } catch {
            return emitAPIError(error, context: "encryption_decl_list failed")
        }
    }

    static func encryptionDeclGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            if let decl = try await EncryptionDeclarationsAPI(client: client).getDeclaration(id: id) {
                return emitJSON(decl)
            }
            return .init(content: [.text("No declaration \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "encryption_decl_get failed")
        }
    }

    static func encryptionDeclCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let fields = EncryptionDeclarationsAPI.DeclarationFields(
            usesEncryption: p.arguments?["uses_encryption"]?.boolValue,
            containsProprietaryCryptography: p.arguments?["contains_proprietary_cryptography"]?.boolValue,
            containsThirdPartyCryptography: p.arguments?["contains_third_party_cryptography"]?.boolValue,
            availableOnFrenchStore: p.arguments?["available_on_french_store"]?.boolValue,
            platform: p.arguments?["platform"]?.stringValue,
            exempt: p.arguments?["exempt"]?.boolValue,
            documentName: p.arguments?["document_name"]?.stringValue,
            documentType: p.arguments?["document_type"]?.stringValue,
            codeValue: p.arguments?["code_value"]?.stringValue
        )
        do {
            let decl = try await EncryptionDeclarationsAPI(client: client).createDeclaration(
                appID: appID, fields: fields
            )
            return emitJSON(decl)
        } catch {
            return emitAPIError(error, context: "encryption_decl_create failed")
        }
    }

    static func encryptionDeclUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        let fields = EncryptionDeclarationsAPI.DeclarationFields(
            usesEncryption: p.arguments?["uses_encryption"]?.boolValue,
            containsProprietaryCryptography: p.arguments?["contains_proprietary_cryptography"]?.boolValue,
            containsThirdPartyCryptography: p.arguments?["contains_third_party_cryptography"]?.boolValue,
            availableOnFrenchStore: p.arguments?["available_on_french_store"]?.boolValue,
            platform: p.arguments?["platform"]?.stringValue,
            exempt: p.arguments?["exempt"]?.boolValue,
            documentName: p.arguments?["document_name"]?.stringValue,
            documentType: p.arguments?["document_type"]?.stringValue,
            codeValue: p.arguments?["code_value"]?.stringValue
        )
        do {
            let decl = try await EncryptionDeclarationsAPI(client: client).updateDeclaration(
                id: id, fields: fields
            )
            return emitJSON(decl)
        } catch {
            return emitAPIError(error, context: "encryption_decl_update failed")
        }
    }

    static func encryptionDeclDocumentsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let d = requireString(p, "declaration_id"); guard case .left(let did) = d else {
            if case .right(let r) = d { return r }; return .init(isError: true)
        }
        do {
            let docs = try await EncryptionDeclarationsAPI(client: client).listDocuments(declarationID: did)
            return emitJSON(docs, header: "\(docs.count) document(s)")
        } catch {
            return emitAPIError(error, context: "encryption_decl_documents_list failed")
        }
    }

    static func encryptionDeclDocumentsUpload(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let d = requireString(p, "declaration_id"); guard case .left(let did) = d else {
            if case .right(let r) = d { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        do {
            let doc = try await EncryptionDeclarationsAPI(client: client).uploadDocument(
                declarationID: did,
                fileURL: URL(fileURLWithPath: file)
            )
            return emitJSON(doc, header: "Uploaded document \(doc.id)")
        } catch {
            return emitAPIError(error, context: "encryption_decl_documents_upload failed")
        }
    }

    static func encryptionDeclDocumentsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await EncryptionDeclarationsAPI(client: client).deleteDocument(id: id)
            return .init(content: [.text("Deleted encryption document \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "encryption_decl_documents_delete failed")
        }
    }

    // MARK: - Handlers: Routing Coverage

    static func routingCoverageGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        do {
            if let coverage = try await RoutingCoverageAPI(client: client).getCoverage(appID: appID) {
                return emitJSON(coverage)
            }
            return .init(content: [.text("No routing coverage attached to app \(appID).")], isError: false)
        } catch {
            return emitAPIError(error, context: "routing_coverage_get failed")
        }
    }

    static func routingCoverageUpload(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        do {
            let coverage = try await RoutingCoverageAPI(client: client).uploadCoverage(
                appID: appID,
                fileURL: URL(fileURLWithPath: file)
            )
            return emitJSON(coverage, header: "Uploaded coverage \(coverage.id)")
        } catch {
            return emitAPIError(error, context: "routing_coverage_upload failed")
        }
    }

    static func routingCoverageDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let i = requireString(p, "id"); guard case .left(let id) = i else {
            if case .right(let r) = i { return r }; return .init(isError: true)
        }
        do {
            try await RoutingCoverageAPI(client: client).deleteCoverage(id: id)
            return .init(content: [.text("Deleted routing coverage \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "routing_coverage_delete failed")
        }
    }
}
