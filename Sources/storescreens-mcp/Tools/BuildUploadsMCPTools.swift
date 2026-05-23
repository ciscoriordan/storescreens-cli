import Foundation
import MCP
import StorescreensCore

/// MCP tool catalog + dispatch for the App Store Connect Build Uploads API
/// (the API-native chunked .ipa upload path Apple shipped in OpenAPI spec
/// v4.1, October 2025). Mirrors the marketing / preview / event-screenshot
/// shape: tools return pretty-printed JSON text content, credentials come
/// from `ASCCredentialResolver.resolve()`, and ASC API errors are surfaced
/// as `isError: true` with a structured human-readable message.
///
/// This is the API-native alternative to the existing altool path exposed
/// via `storescreens upload-build`. The altool path is still recommended
/// for production; these tools exist for early adopters and for future
/// CI environments where Xcode is unavailable.
package enum BuildUploadsMCPTools {

    // MARK: - Shared helpers

    /// Build a tool with a plain object input schema. Same shape used
    /// across the other MCP tool families so the JSON-schema dialect
    /// remains consistent.
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
    /// values for credential / parameter errors without throwing. Same
    /// pattern the marketing family uses.
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

    package static let tools: [Tool] = [
        // /buildUploads CRUD + list + listForApp
        makeTool(
            name: "build_uploads_list",
            description: "List buildUploads filtered by app. Includes in-flight reservations (PENDING / UPLOADED) that have not yet materialized as Build resources.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("limit", "integer", "page size (default 50, max 200)"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "build_uploads_list_for_app",
            description: "Convenience: list buildUploads via the relationship endpoint `apps/{id}/buildUploads`. Same data as build_uploads_list with `filter[app]`, kept separate so callers can mirror the spec URL exactly.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("limit", "integer", "page size (default 50, max 200)"),
            ],
            required: ["app_id"]
        ),
        makeTool(
            name: "build_uploads_get",
            description: "Fetch a single buildUpload by id. Used to poll `attributes.state` (PENDING -> UPLOADED -> PROCESSING -> VALID/INVALID/FAILED) and inspect `errorMessages`.",
            properties: [
                ("id", "string", "buildUpload id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "build_uploads_create",
            description: "POST /buildUploads - reserve a new chunked upload for an app. Returns the buildUpload with state=PENDING. Pair with build_uploads_files_create + the chunk PUTs + build_uploads_files_commit to push bytes. For one-shot use, prefer build_uploads_upload_ipa.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("file_name", "string", ".ipa file name (e.g. MyApp.ipa)"),
                ("file_size", "integer", ".ipa file size in bytes"),
            ],
            required: ["app_id", "file_name", "file_size"]
        ),
        makeTool(
            name: "build_uploads_delete",
            description: "DELETE a buildUpload. Discards an in-progress reservation so it doesn't linger on the account.",
            properties: [
                ("id", "string", "buildUpload id"),
            ],
            required: ["id"]
        ),

        // /buildUploadFiles CRUD
        makeTool(
            name: "build_uploads_files_list",
            description: "List buildUploadFiles attached to a buildUpload. Typically returns a single file (the .ipa) but the relationship is one-to-many.",
            properties: [
                ("build_upload_id", "string", "buildUpload id"),
                ("limit", "integer", "page size (default 50, max 200)"),
            ],
            required: ["build_upload_id"]
        ),
        makeTool(
            name: "build_uploads_files_get",
            description: "Fetch a single buildUploadFile by id. Surface `attributes.uploadOperations` (signed chunk PUT URLs + headers + offsets + lengths) for manual chunked-PUT workflows.",
            properties: [
                ("id", "string", "buildUploadFile id"),
            ],
            required: ["id"]
        ),
        makeTool(
            name: "build_uploads_files_create",
            description: "POST /buildUploadFiles - reserve a chunked-upload target inside an existing buildUpload. Response includes `uploadOperations` you PUT chunks to. Optionally include a precomputed sourceFileChecksum (hex MD5 of the file) so ASC validates against the expected value.",
            properties: [
                ("build_upload_id", "string", "parent buildUpload id"),
                ("file_name", "string", "file name (e.g. MyApp.ipa)"),
                ("file_size", "integer", "file size in bytes"),
                ("source_file_checksum", "string", "optional hex MD5 over the file bytes"),
            ],
            required: ["build_upload_id", "file_name", "file_size"]
        ),
        makeTool(
            name: "build_uploads_files_commit",
            description: "PATCH /buildUploadFiles/{id} with uploaded:true + sourceFileChecksum. Run this after every chunk for the file has been PUT successfully. ASC will validate the checksum and transition state to UPLOADED (or expose errorMessages on rejection).",
            properties: [
                ("id", "string", "buildUploadFile id"),
                ("source_file_checksum", "string", "hex MD5 over the file bytes"),
            ],
            required: ["id", "source_file_checksum"]
        ),

        // High-level convenience
        makeTool(
            name: "build_uploads_upload_ipa",
            description: "Full create -> chunk-PUT -> commit -> poll workflow for a single .ipa file. Reads the file from disk, registers the buildUpload + buildUploadFile with ASC, PUTs every chunk to Apple's signed URLs, commits, and polls until ASC processing completes (default 15min timeout). Returns the processed Build resource when available, or the in-flight buildUpload otherwise. Streams progress lines if invoked through a chunk-aware MCP harness.",
            properties: [
                ("app_id", "string", "numeric ASC app id"),
                ("file", "string", "absolute path to the .ipa on disk"),
                ("processing_timeout_seconds", "integer", "max seconds to wait for ASC processing (default 900)"),
                ("processing_poll_interval_seconds", "integer", "seconds between polls (default 10)"),
            ],
            required: ["app_id", "file"]
        ),
    ]

    // MARK: - Dispatch

    package static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        switch params.name {
        // buildUploads
        case "build_uploads_list":          return await buildUploadsList(params)
        case "build_uploads_list_for_app":  return await buildUploadsListForApp(params)
        case "build_uploads_get":           return await buildUploadsGet(params)
        case "build_uploads_create":        return await buildUploadsCreate(params)
        case "build_uploads_delete":        return await buildUploadsDelete(params)
        // buildUploadFiles
        case "build_uploads_files_list":    return await buildUploadsFilesList(params)
        case "build_uploads_files_get":     return await buildUploadsFilesGet(params)
        case "build_uploads_files_create":  return await buildUploadsFilesCreate(params)
        case "build_uploads_files_commit":  return await buildUploadsFilesCommit(params)
        // high-level
        case "build_uploads_upload_ipa":    return await buildUploadsUploadIpa(params)
        default:
            return .init(
                content: [.text("Unknown build-uploads tool: \(params.name)")],
                isError: true
            )
        }
    }

    // MARK: - Handlers: buildUploads

    static func buildUploadsList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let limit = Int(p.arguments?["limit"]?.intValue ?? 50)
        do {
            let list = try await BuildUploadsAPI(client: client).uploads.list(
                appID: appID, limit: limit
            )
            return emitJSON(list, header: "\(list.count) buildUpload(s)")
        } catch {
            return emitAPIError(error, context: "build_uploads_list failed")
        }
    }

    static func buildUploadsListForApp(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let limit = Int(p.arguments?["limit"]?.intValue ?? 50)
        do {
            let list = try await BuildUploadsAPI(client: client).listBuildUploads(
                appID: appID, limit: limit
            )
            return emitJSON(list, header: "\(list.count) buildUpload(s)")
        } catch {
            return emitAPIError(error, context: "build_uploads_list_for_app failed")
        }
    }

    static func buildUploadsGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            guard let upload = try await BuildUploadsAPI(client: client).uploads.get(id: id) else {
                return .init(
                    content: [.text("buildUpload \(id) not found")],
                    isError: true
                )
            }
            return emitJSON(upload)
        } catch {
            return emitAPIError(error, context: "build_uploads_get failed")
        }
    }

    static func buildUploadsCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let fn = requireString(p, "file_name"); guard case .left(let fileName) = fn else {
            if case .right(let r) = fn { return r }; return .init(isError: true)
        }
        guard let fileSize = p.arguments?["file_size"]?.intValue else {
            return .init(content: [.text("Missing required parameter: file_size")], isError: true)
        }
        do {
            let upload = try await BuildUploadsAPI(client: client).uploads.create(
                appID: appID,
                fileName: fileName,
                fileSize: Int64(fileSize)
            )
            return emitJSON(upload, header: "Created buildUpload \(upload.id)")
        } catch {
            return emitAPIError(error, context: "build_uploads_create failed")
        }
    }

    static func buildUploadsDelete(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            try await BuildUploadsAPI(client: client).uploads.delete(id: id)
            return .init(content: [.text("Deleted buildUpload \(id).")], isError: false)
        } catch {
            return emitAPIError(error, context: "build_uploads_delete failed")
        }
    }

    // MARK: - Handlers: buildUploadFiles

    static func buildUploadsFilesList(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let bu = requireString(p, "build_upload_id"); guard case .left(let buID) = bu else {
            if case .right(let r) = bu { return r }; return .init(isError: true)
        }
        let limit = Int(p.arguments?["limit"]?.intValue ?? 50)
        do {
            let files = try await BuildUploadsAPI(client: client).files.list(
                buildUploadID: buID, limit: limit
            )
            return emitJSON(files, header: "\(files.count) buildUploadFile(s)")
        } catch {
            return emitAPIError(error, context: "build_uploads_files_list failed")
        }
    }

    static func buildUploadsFilesGet(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let idR = requireString(p, "id"); guard case .left(let id) = idR else {
            if case .right(let r) = idR { return r }; return .init(isError: true)
        }
        do {
            guard let file = try await BuildUploadsAPI(client: client).files.get(id: id) else {
                return .init(
                    content: [.text("buildUploadFile \(id) not found")],
                    isError: true
                )
            }
            return emitJSON(file)
        } catch {
            return emitAPIError(error, context: "build_uploads_files_get failed")
        }
    }

    static func buildUploadsFilesCreate(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let bu = requireString(p, "build_upload_id"); guard case .left(let buID) = bu else {
            if case .right(let r) = bu { return r }; return .init(isError: true)
        }
        let fn = requireString(p, "file_name"); guard case .left(let fileName) = fn else {
            if case .right(let r) = fn { return r }; return .init(isError: true)
        }
        guard let fileSize = p.arguments?["file_size"]?.intValue else {
            return .init(content: [.text("Missing required parameter: file_size")], isError: true)
        }
        let checksum = p.arguments?["source_file_checksum"]?.stringValue
        do {
            let file = try await BuildUploadsAPI(client: client).files.create(
                buildUploadID: buID,
                fileName: fileName,
                fileSize: Int64(fileSize),
                sourceFileChecksum: checksum
            )
            return emitJSON(file, header: "Created buildUploadFile \(file.id)")
        } catch {
            return emitAPIError(error, context: "build_uploads_files_create failed")
        }
    }

    static func buildUploadsFilesCommit(_ p: CallTool.Parameters) async -> CallTool.Result {
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
            let file = try await BuildUploadsAPI(client: client).files.commit(
                id: id, sourceFileChecksum: checksum
            )
            return emitJSON(file, header: "Committed buildUploadFile \(file.id)")
        } catch {
            return emitAPIError(error, context: "build_uploads_files_commit failed")
        }
    }

    // MARK: - Handlers: high-level upload_ipa

    static func buildUploadsUploadIpa(_ p: CallTool.Parameters) async -> CallTool.Result {
        let creds = makeClient(); guard case .left(let client) = creds else {
            if case .right(let r) = creds { return r }; return .init(isError: true)
        }
        let a = requireString(p, "app_id"); guard case .left(let appID) = a else {
            if case .right(let r) = a { return r }; return .init(isError: true)
        }
        let f = requireString(p, "file"); guard case .left(let file) = f else {
            if case .right(let r) = f { return r }; return .init(isError: true)
        }
        let timeout = TimeInterval(p.arguments?["processing_timeout_seconds"]?.intValue
            ?? Int(BuildUploadsAPI.defaultProcessingTimeout))
        let pollInterval = TimeInterval(p.arguments?["processing_poll_interval_seconds"]?.intValue
            ?? Int(BuildUploadsAPI.defaultProcessingPollInterval))
        do {
            let result = try await BuildUploadsAPI(client: client).uploadIpaDetailed(
                path: URL(fileURLWithPath: file),
                appID: appID,
                progress: nil,
                processingTimeout: timeout,
                processingPollInterval: pollInterval
            )
            // Always return the detailed result so MCP callers can see
            // the buildUpload state and any errorMessages even when
            // processing has not yet produced a Build resource.
            return emitJSON(BuildUploadsResultDTO(result: result), header: "Uploaded \(file)")
        } catch {
            return emitAPIError(error, context: "build_uploads_upload_ipa failed")
        }
    }
}

// MARK: - JSON DTO for upload_ipa

/// Flat-shape JSON view of `BuildUploadsAPI.UploadIpaResult` so MCP
/// callers see a stable schema. We don't expose the SDK type directly
/// because it's a Sendable struct whose Codable conformance would be
/// brittle to ASC spec evolution.
private struct BuildUploadsResultDTO: Encodable {
    let buildUpload: BuildUploadsAPI.Uploads.BuildUpload
    let files: [BuildUploadsAPI.Files.BuildUploadFile]
    let build: BuildUploadsAPI.Build?

    init(result: BuildUploadsAPI.UploadIpaResult) {
        self.buildUpload = result.upload
        self.files = result.files
        self.build = result.build
    }
}
