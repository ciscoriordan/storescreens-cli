import Foundation
import MCP
import StorescreensCore

/// MCP tool catalog + dispatch for the App Store Connect Background Assets
/// resources (Apple's 200GB-per-app post-install asset download mechanism,
/// shipped in OpenAPI spec v4.0 June 2025 with v4.1 additions in October
/// 2025) and the related App Store Version Release Control surface
/// (phased releases, promo carousel opt-in, manual release triggers,
/// end-of-pre-order action).
///
/// Tools return pretty-printed JSON text content, credentials come from
/// `ASCCredentialResolver.resolve()`, and ASC API errors surface as
/// `isError: true` with a structured human-readable message.
package enum BackgroundAssetsMCPTools {

    // MARK: - Shared helpers

    /// Build a tool with a plain object input schema. Same shape used
    /// across the other MCP tool families so the JSON-schema dialect
    /// stays consistent.
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

    /// Hand-rolled either type so we can return user-facing CallTool.Result
    /// values for credential / parameter errors without throwing. Mirrors
    /// the BuildUploadsMCPTools pattern.
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

    package static let tools: [Tool] = backgroundAssetTools + releaseControlTools

    // MARK: Background Assets catalog

    private static let backgroundAssetTools: [Tool] = [
        // backgroundAssets CRUD
        makeTool(
            name: "bg_assets_list",
            description: "List backgroundAssets for an app (uses GET /backgroundAssets?filter[app]). Apple ships one per app today, but the relationship is one-to-many in the schema.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("limit", "integer", "page size (default 200, max 200)"),
                ("cursor", "string", "opaque cursor from a previous nextCursor"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "bg_assets_list_for_app",
            description: "Convenience: list backgroundAssets via the relationship endpoint `apps/{id}/backgroundAssets`. Same data as bg_assets_list, kept separate so callers can mirror Apple's URL exactly.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("limit", "integer", "page size (default 200, max 200)"),
                ("cursor", "string", "opaque cursor from a previous nextCursor"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "bg_assets_get",
            description: "Fetch a single backgroundAsset by id. Returns attributes.internalBetaState / externalBetaState / appStoreState / lastUpdated plus the app + manifest relationships.",
            properties: [
                ("id", "string", "backgroundAsset id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "bg_assets_create",
            description: "POST /backgroundAssets - create the parent record on an app. Apple permits one per app, so a 409 isAlreadySetConflict means the record already exists.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "bg_assets_update",
            description: "PATCH /backgroundAssets/{id} with any combination of state attributes. Use to stage per-channel state transitions programmatically.",
            properties: [
                ("id", "string", "backgroundAsset id"),
                ("internal_beta_state", "string", "new internal beta delivery state"),
                ("external_beta_state", "string", "new external beta delivery state"),
                ("app_store_state", "string", "new App Store delivery state"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "bg_assets_delete",
            description: "DELETE /backgroundAssets/{id}. Removes the asset record and cascades to every child version + file. Use with care.",
            properties: [
                ("id", "string", "backgroundAsset id"),
            ],
            required: ["id"]
        ),

        // backgroundAssetVersions
        makeTool(
            name: "bg_asset_versions_list",
            description: "List backgroundAssetVersions hanging off a backgroundAsset (paginated).",
            properties: [
                ("background_asset_id", "string", "backgroundAsset id"),
                ("limit", "integer", "page size (default 200, max 200)"),
                ("cursor", "string", "opaque cursor from a previous nextCursor"),
            ],
            required: ["background_asset_id"]
        ),
        makeTool(
            name: "bg_asset_versions_get",
            description: "Fetch a single backgroundAssetVersion by id. Returns per-version delivery state plus the file relationship list.",
            properties: [
                ("id", "string", "backgroundAssetVersion id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "bg_asset_versions_create",
            description: "POST /backgroundAssetVersions - create a new version on an existing backgroundAsset. After creation, register one or more backgroundAssetUploadFiles and chunk-PUT bytes.",
            properties: [
                ("background_asset_id", "string", "parent backgroundAsset id"),
                ("version", "string", "optional free-form version label (independent of the app's marketing version)"),
            ],
            required: ["background_asset_id"]
        ),

        // backgroundAssetUploadFiles
        makeTool(
            name: "bg_asset_files_list",
            description: "List backgroundAssetUploadFiles attached to a backgroundAssetVersion (paginated).",
            properties: [
                ("version_id", "string", "backgroundAssetVersion id"),
                ("limit", "integer", "page size (default 200, max 200)"),
                ("cursor", "string", "opaque cursor from a previous nextCursor"),
            ],
            required: ["version_id"]
        ),
        makeTool(
            name: "bg_asset_files_get",
            description: "Fetch a single backgroundAssetUploadFile. Inspect attributes.uploadOperations (signed chunk PUT URLs + headers + offsets + lengths) for manual chunked-PUT workflows.",
            properties: [
                ("id", "string", "backgroundAssetUploadFile id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "bg_asset_files_create",
            description: "POST /backgroundAssetUploadFiles - reserve a chunked-upload target inside an existing backgroundAssetVersion. Response includes uploadOperations you PUT chunks to. Optionally include a precomputed sourceFileChecksum (hex MD5).",
            properties: [
                ("version_id", "string", "parent backgroundAssetVersion id"),
                ("file_name", "string", "file name (e.g. assets-pack-1.bin)"),
                ("file_size", "integer", "file size in bytes"),
                ("source_file_checksum", "string", "optional hex MD5 over the file bytes"),
            ],
            required: ["version_id", "file_name", "file_size"]
        ),
        makeTool(
            name: "bg_asset_files_commit",
            description: "PATCH /backgroundAssetUploadFiles/{id} with uploaded:true + sourceFileChecksum. Run after every chunk for the file has been PUT successfully. ASC validates the checksum and transitions state to UPLOADED.",
            properties: [
                ("id", "string", "backgroundAssetUploadFile id"),
                ("source_file_checksum", "string", "hex MD5 over the file bytes"),
            ],
            required: ["id", "source_file_checksum"]
        ),

        // High-level convenience
        makeTool(
            name: "bg_asset_files_upload",
            description: "End-to-end chunked upload for a single background-asset file. Reads the file from disk, registers the backgroundAssetUploadFile with ASC, PUTs every chunk to Apple's signed URLs, then commits. Returns the committed file. Streams progress when invoked through a chunk-aware MCP harness.",
            properties: [
                ("version_id", "string", "parent backgroundAssetVersion id"),
                ("file", "string", "absolute path to the asset file on disk"),
            ],
            required: ["version_id", "file"]
        ),

        // Read-only release-state records
        makeTool(
            name: "bg_asset_app_store_release_get",
            description: "Read the App Store delivery release-state record for a backgroundAssetVersion (spec v4.1). Surfaces `state` and `releaseDate`.",
            properties: [
                ("id", "string", "backgroundAssetVersionAppStoreRelease id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "bg_asset_external_beta_release_get",
            description: "Read the External Beta delivery release-state record for a backgroundAssetVersion.",
            properties: [
                ("id", "string", "backgroundAssetVersionExternalBetaRelease id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "bg_asset_internal_beta_release_get",
            description: "Read the Internal Beta delivery release-state record for a backgroundAssetVersion.",
            properties: [
                ("id", "string", "backgroundAssetVersionInternalBetaRelease id"),
            ],
            required: ["id"]
        ),
    ]

    // MARK: Release Control catalog

    private static let releaseControlTools: [Tool] = [
        // phasedReleases
        makeTool(
            name: "phased_release_get_for_version",
            description: "Read the appStoreVersionPhasedRelease record attached to an appStoreVersion (relationship form). Returns phasedReleaseState (INACTIVE/ACTIVE/PAUSED/COMPLETE) + currentDayNumber.",
            properties: [
                ("version_id", "string", "appStoreVersion id"),
            ],
            required: ["version_id"]
        ),
        makeTool(
            name: "phased_release_get",
            description: "Fetch a single appStoreVersionPhasedRelease by id.",
            properties: [
                ("id", "string", "appStoreVersionPhasedRelease id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "phased_release_create",
            description: "POST /appStoreVersionPhasedReleases - start a phased rollout on a version. The 7-day rollout begins once the version goes live; until then the record stays in INACTIVE.",
            properties: [
                ("version_id", "string", "appStoreVersion id"),
                ("phased_release_state", "string", "optional initial state (default Apple-picked)"),
            ],
            required: ["version_id"]
        ),
        makeTool(
            name: "phased_release_update",
            description: "PATCH /appStoreVersionPhasedReleases/{id} - change rollout state. Use PAUSED to pause, ACTIVE to resume, COMPLETE to expedite the rollout to 100% immediately.",
            properties: [
                ("id", "string", "appStoreVersionPhasedRelease id"),
                ("phased_release_state", "string", "new state (PAUSED / ACTIVE / COMPLETE)"),
            ],
            required: ["id", "phased_release_state"]
        ),
        makeTool(
            name: "phased_release_delete",
            description: "DELETE /appStoreVersionPhasedReleases/{id} - revert the version to immediate release (no rollout). Safe before the version actually goes live.",
            properties: [
                ("id", "string", "appStoreVersionPhasedRelease id"),
            ],
            required: ["id"]
        ),

        // promotions, releaseRequests, endPreOrders (create-only)
        makeTool(
            name: "version_promotion_create",
            description: "POST /appStoreVersionPromotions - opt the parent version into App Store editorial promo carousels. One-shot; Apple decides whether the version actually appears.",
            properties: [
                ("version_id", "string", "appStoreVersion id"),
            ],
            required: ["version_id"]
        ),
        makeTool(
            name: "version_release_request_create",
            description: "POST /appStoreVersionReleaseRequests - release a manually-released version now. The version must be in PENDING_DEVELOPER_RELEASE.",
            properties: [
                ("version_id", "string", "appStoreVersion id"),
            ],
            required: ["version_id"]
        ),
        makeTool(
            name: "end_preorder_create",
            description: "POST /endAppAvailabilityPreOrders - end an app's pre-order period early. Transitions customers from pre-order to live install.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
            ],
            required: ["app_id"]
        ),
    ]

    // MARK: - Dispatch

    package static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        switch params.name {
        // backgroundAssets
        case "bg_assets_list":              return await bgAssetsList(params)
        case "bg_assets_list_for_app":      return await bgAssetsListForApp(params)
        case "bg_assets_get":               return await bgAssetsGet(params)
        case "bg_assets_create":            return await bgAssetsCreate(params)
        case "bg_assets_update":            return await bgAssetsUpdate(params)
        case "bg_assets_delete":            return await bgAssetsDelete(params)
        // backgroundAssetVersions
        case "bg_asset_versions_list":      return await bgAssetVersionsList(params)
        case "bg_asset_versions_get":       return await bgAssetVersionsGet(params)
        case "bg_asset_versions_create":    return await bgAssetVersionsCreate(params)
        // backgroundAssetUploadFiles
        case "bg_asset_files_list":         return await bgAssetFilesList(params)
        case "bg_asset_files_get":          return await bgAssetFilesGet(params)
        case "bg_asset_files_create":       return await bgAssetFilesCreate(params)
        case "bg_asset_files_commit":       return await bgAssetFilesCommit(params)
        case "bg_asset_files_upload":       return await bgAssetFilesUpload(params)
        // Read-only release-state records
        case "bg_asset_app_store_release_get":
            return await bgAssetAppStoreReleaseGet(params)
        case "bg_asset_external_beta_release_get":
            return await bgAssetExternalBetaReleaseGet(params)
        case "bg_asset_internal_beta_release_get":
            return await bgAssetInternalBetaReleaseGet(params)
        // Phased releases
        case "phased_release_get_for_version":
            return await phasedReleaseGetForVersion(params)
        case "phased_release_get":          return await phasedReleaseGet(params)
        case "phased_release_create":       return await phasedReleaseCreate(params)
        case "phased_release_update":       return await phasedReleaseUpdate(params)
        case "phased_release_delete":       return await phasedReleaseDelete(params)
        // Version promotions / release requests / end pre-orders
        case "version_promotion_create":    return await versionPromotionCreate(params)
        case "version_release_request_create":
            return await versionReleaseRequestCreate(params)
        case "end_preorder_create":         return await endPreorderCreate(params)
        default:
            return .init(
                content: [.text("Unknown background-assets / release tool: \(params.name)")],
                isError: true
            )
        }
    }

    // MARK: - Handlers: backgroundAssets

    static func bgAssetsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let limit = Int(p.arguments?["limit"]?.intValue ?? 200)
        let cursor = p.arguments?["cursor"]?.stringValue
        do {
            let page = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.list(
                appID: appID, limit: limit, cursor: cursor
            )
            return emitJSON(
                PageDTO(data: page.data, nextCursor: page.nextCursor),
                header: "\(page.data.count) backgroundAsset(s)"
            )
        } catch {
            return emitAPIError(error, context: "bg_assets_list failed")
        }
    }

    static func bgAssetsListForApp(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let limit = Int(p.arguments?["limit"]?.intValue ?? 200)
        let cursor = p.arguments?["cursor"]?.stringValue
        do {
            let page = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.listForApp(
                appID: appID, limit: limit, cursor: cursor
            )
            return emitJSON(
                PageDTO(data: page.data, nextCursor: page.nextCursor),
                header: "\(page.data.count) backgroundAsset(s)"
            )
        } catch {
            return emitAPIError(error, context: "bg_assets_list_for_app failed")
        }
    }

    static func bgAssetsGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            guard let asset = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.get(id: id) else {
                return .init(
                    content: [.text("backgroundAsset \(id) not found")],
                    isError: true
                )
            }
            return emitJSON(asset)
        } catch {
            return emitAPIError(error, context: "bg_assets_get failed")
        }
    }

    static func bgAssetsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        do {
            let asset = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.create(appID: appID)
            return emitJSON(asset, header: "Created backgroundAsset \(asset.id)")
        } catch {
            return emitAPIError(error, context: "bg_assets_create failed")
        }
    }

    static func bgAssetsUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        let fields = BackgroundAssetsAPI.Assets.BackgroundAssetUpdateFields(
            internalBetaState: p.arguments?["internal_beta_state"]?.stringValue,
            externalBetaState: p.arguments?["external_beta_state"]?.stringValue,
            appStoreState: p.arguments?["app_store_state"]?.stringValue
        )
        do {
            let asset = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.update(
                id: id, fields: fields
            )
            return emitJSON(asset, header: "Updated backgroundAsset \(asset.id)")
        } catch {
            return emitAPIError(error, context: "bg_assets_update failed")
        }
    }

    static func bgAssetsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.delete(id: id)
            return .init(content: [.text("Deleted backgroundAsset \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "bg_assets_delete failed")
        }
    }

    // MARK: - Handlers: backgroundAssetVersions

    static func bgAssetVersionsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let ba = requireString(p, "background_asset_id"); guard case .left(let baID) = ba else {
            if case .right(let r) = ba { return r }; return .init(isError: true)
        }
        let limit = Int(p.arguments?["limit"]?.intValue ?? 200)
        let cursor = p.arguments?["cursor"]?.stringValue
        do {
            let page = try await BackgroundAssetsAPI(client: client).assets.versions.list(
                backgroundAssetID: baID, limit: limit, cursor: cursor
            )
            return emitJSON(
                PageDTO(data: page.data, nextCursor: page.nextCursor),
                header: "\(page.data.count) backgroundAssetVersion(s)"
            )
        } catch {
            return emitAPIError(error, context: "bg_asset_versions_list failed")
        }
    }

    static func bgAssetVersionsGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            guard let v = try await BackgroundAssetsAPI(client: client).assets.versions.get(id: id) else {
                return .init(
                    content: [.text("backgroundAssetVersion \(id) not found")],
                    isError: true
                )
            }
            return emitJSON(v)
        } catch {
            return emitAPIError(error, context: "bg_asset_versions_get failed")
        }
    }

    static func bgAssetVersionsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let ba = requireString(p, "background_asset_id"); guard case .left(let baID) = ba else {
            if case .right(let r) = ba { return r }; return .init(isError: true)
        }
        let version = p.arguments?["version"]?.stringValue
        do {
            let v = try await BackgroundAssetsAPI(client: client).assets.versions.create(
                backgroundAssetID: baID, version: version
            )
            return emitJSON(v, header: "Created backgroundAssetVersion \(v.id)")
        } catch {
            return emitAPIError(error, context: "bg_asset_versions_create failed")
        }
    }

    // MARK: - Handlers: backgroundAssetUploadFiles

    static func bgAssetFilesList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let versionID) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        let limit = Int(p.arguments?["limit"]?.intValue ?? 200)
        let cursor = p.arguments?["cursor"]?.stringValue
        do {
            let page = try await BackgroundAssetsAPI(client: client).assets.uploadFiles.list(
                versionID: versionID, limit: limit, cursor: cursor
            )
            return emitJSON(
                PageDTO(data: page.data, nextCursor: page.nextCursor),
                header: "\(page.data.count) backgroundAssetUploadFile(s)"
            )
        } catch {
            return emitAPIError(error, context: "bg_asset_files_list failed")
        }
    }

    static func bgAssetFilesGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            guard let f = try await BackgroundAssetsAPI(client: client).assets.uploadFiles.get(id: id) else {
                return .init(
                    content: [.text("backgroundAssetUploadFile \(id) not found")],
                    isError: true
                )
            }
            return emitJSON(f)
        } catch {
            return emitAPIError(error, context: "bg_asset_files_get failed")
        }
    }

    static func bgAssetFilesCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let versionID) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        let fn = requireString(p, "file_name"); guard case .left(let fileName) = fn else {
            if case .right(let r) = fn { return r }; return .init(isError: true)
        }
        guard let fileSize = p.arguments?["file_size"]?.intValue else {
            return .init(content: [.text("Missing required parameter: file_size")], isError: true)
        }
        let checksum = p.arguments?["source_file_checksum"]?.stringValue
        do {
            let f = try await BackgroundAssetsAPI(client: client).assets.uploadFiles.create(
                versionID: versionID,
                fileName: fileName,
                fileSize: Int64(fileSize),
                sourceFileChecksum: checksum
            )
            return emitJSON(f, header: "Created backgroundAssetUploadFile \(f.id)")
        } catch {
            return emitAPIError(error, context: "bg_asset_files_create failed")
        }
    }

    static func bgAssetFilesCommit(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        let cs = requireString(p, "source_file_checksum"); guard case .left(let checksum) = cs else {
            if case .right(let r) = cs { return r }; return .init(isError: true)
        }
        do {
            let f = try await BackgroundAssetsAPI(client: client).assets.uploadFiles.commit(
                id: id, sourceFileChecksum: checksum
            )
            return emitJSON(f, header: "Committed backgroundAssetUploadFile \(f.id)")
        } catch {
            return emitAPIError(error, context: "bg_asset_files_commit failed")
        }
    }

    static func bgAssetFilesUpload(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let versionID) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        do {
            let result = try await BackgroundAssetsAPI(client: client).uploadBackgroundAssetFile(
                path: URL(fileURLWithPath: file),
                versionID: versionID,
                progress: nil
            )
            return emitJSON(
                BackgroundAssetUploadResultDTO(file: result.file),
                header: "Uploaded \(file)"
            )
        } catch {
            return emitAPIError(error, context: "bg_asset_files_upload failed")
        }
    }

    // MARK: - Handlers: read-only release-state records

    static func bgAssetAppStoreReleaseGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            guard let r = try await BackgroundAssetsAPI(client: client).assets.appStoreReleases.get(id: id) else {
                return .init(
                    content: [.text("backgroundAssetVersionAppStoreRelease \(id) not found")],
                    isError: true
                )
            }
            return emitJSON(r)
        } catch {
            return emitAPIError(error, context: "bg_asset_app_store_release_get failed")
        }
    }

    static func bgAssetExternalBetaReleaseGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            guard let r = try await BackgroundAssetsAPI(client: client).assets.externalBetaReleases.get(id: id) else {
                return .init(
                    content: [.text("backgroundAssetVersionExternalBetaRelease \(id) not found")],
                    isError: true
                )
            }
            return emitJSON(r)
        } catch {
            return emitAPIError(error, context: "bg_asset_external_beta_release_get failed")
        }
    }

    static func bgAssetInternalBetaReleaseGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            guard let r = try await BackgroundAssetsAPI(client: client).assets.internalBetaReleases.get(id: id) else {
                return .init(
                    content: [.text("backgroundAssetVersionInternalBetaRelease \(id) not found")],
                    isError: true
                )
            }
            return emitJSON(r)
        } catch {
            return emitAPIError(error, context: "bg_asset_internal_beta_release_get failed")
        }
    }

    // MARK: - Handlers: phased releases

    static func phasedReleaseGetForVersion(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let versionID) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        do {
            guard let pr = try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.getForVersion(versionID: versionID) else {
                return .init(
                    content: [.text("appStoreVersion \(versionID) has no phased release")],
                    isError: false
                )
            }
            return emitJSON(pr)
        } catch {
            return emitAPIError(error, context: "phased_release_get_for_version failed")
        }
    }

    static func phasedReleaseGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            guard let pr = try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.get(id: id) else {
                return .init(
                    content: [.text("appStoreVersionPhasedRelease \(id) not found")],
                    isError: true
                )
            }
            return emitJSON(pr)
        } catch {
            return emitAPIError(error, context: "phased_release_get failed")
        }
    }

    static func phasedReleaseCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let versionID) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        let state = p.arguments?["phased_release_state"]?.stringValue
        do {
            let pr = try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.create(
                versionID: versionID,
                phasedReleaseState: state
            )
            return emitJSON(pr, header: "Started phased release \(pr.id)")
        } catch {
            return emitAPIError(error, context: "phased_release_create failed")
        }
    }

    static func phasedReleaseUpdate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        let s = requireString(p, "phased_release_state"); guard case .left(let state) = s else {
            if case .right(let r) = s { return r }; return .init(isError: true)
        }
        do {
            let pr = try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.update(
                id: id, phasedReleaseState: state
            )
            return emitJSON(pr, header: "Updated phased release to \(state)")
        } catch {
            return emitAPIError(error, context: "phased_release_update failed")
        }
    }

    static func phasedReleaseDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            try await BackgroundAssetsAPI(client: client).releaseControl.phasedReleases.delete(id: id)
            return .init(
                content: [.text("Deleted appStoreVersionPhasedRelease \(id) (version will release immediately).")],
                isError: false
            )
        } catch {
            return emitAPIError(error, context: "phased_release_delete failed")
        }
    }

    // MARK: - Handlers: version promotions / release requests / end pre-orders

    static func versionPromotionCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let versionID) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        do {
            let promo = try await BackgroundAssetsAPI(client: client).releaseControl.promotions.create(
                versionID: versionID
            )
            return emitJSON(promo, header: "Created appStoreVersionPromotion \(promo.id)")
        } catch {
            return emitAPIError(error, context: "version_promotion_create failed")
        }
    }

    static func versionReleaseRequestCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let v = requireString(p, "version_id"); guard case .left(let versionID) = v else {
            if case .right(let r) = v { return r }; return .init(isError: true)
        }
        do {
            let req = try await BackgroundAssetsAPI(client: client).releaseControl.releaseRequests.create(
                versionID: versionID
            )
            return emitJSON(req, header: "Released version \(versionID) (request \(req.id))")
        } catch {
            return emitAPIError(error, context: "version_release_request_create failed")
        }
    }

    static func endPreorderCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        do {
            let req = try await BackgroundAssetsAPI(client: client).releaseControl.endPreOrders.create(
                appID: appID
            )
            return emitJSON(req, header: "Ended pre-orders for app \(appID) (request \(req.id))")
        } catch {
            return emitAPIError(error, context: "end_preorder_create failed")
        }
    }
}

// MARK: - DTOs

/// Flat-shape page envelope so MCP callers see a stable cursor field
/// independent of the SDK type evolution.
private struct PageDTO<Item: Encodable>: Encodable {
    let data: [Item]
    let nextCursor: String?
}

/// Flat-shape JSON view of a background-asset upload result.
private struct BackgroundAssetUploadResultDTO: Encodable {
    let file: BackgroundAssetsAPI.Assets.BackgroundAssetUploadFile
}
