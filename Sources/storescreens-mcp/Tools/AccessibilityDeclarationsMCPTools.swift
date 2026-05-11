import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for App Store Connect Accessibility Declarations
/// (Apple's "Accessibility Nutrition Label" resource, shipped in API
/// v4.0, June 2025). Mirrors `AccessibilityDeclarationsAPI` so an AI
/// agent can list / read / create / update / delete a declaration
/// without crafting raw ASC HTTP requests.
///
/// Tool naming convention: `accessibility_declarations_<op>` (snake_case).
/// All tools return pretty-printed JSON in a single `.text` content
/// block, with `isError: true` set on failures so the agent can react
/// cleanly.
///
/// Credentials resolve via `ASCCredentialResolver.resolve()` (env vars
/// first, falling back to `~/.storescreens/asc-credentials.yml`).
///
/// Note: This file is loaded into the same MCP target as `Main.swift`.
/// `Main.swift` owns the actual server bootstrap and tool registration;
/// per the task constraints we do not edit `Main.swift` here, so the
/// dispatch glue lives unused until a separate wiring step plugs
/// `AccessibilityDeclarationsMCPTools.tools` into
/// `StorescreensMCP.tools` and `AccessibilityDeclarationsMCPTools.handle(_:)`
/// into the dispatch table.
package enum AccessibilityDeclarationsMCPTools {

    // MARK: - Tool catalog

    package static let tools: [Tool] = [

        Tool(
            name: "accessibility_declarations_list",
            description: """
            List every accessibility declaration attached to an app, optionally \
            filtered by deviceFamily and/or state. Returns a JSON envelope with \
            `data` (the declarations on this page) and `nextCursor` for \
            paginating further pages. In practice an app carries at most a \
            handful of declarations (one PUBLISHED + one DRAFT per device \
            family, plus REPLACED history), so the default limit is rarely \
            exercised.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id (numeric string)."),
                    ]),
                    "device_family": .object([
                        "type": .string("string"),
                        "description": .string("Filter: IPHONE, IPAD, APPLE_TV, APPLE_WATCH, MAC, VISION."),
                    ]),
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("Filter: DRAFT, PUBLISHED, REPLACED."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size (default 200)."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Pagination cursor from a previous page's nextCursor."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "accessibility_declarations_get",
            description: """
            Get a single accessibility declaration by id. Returns the full \
            attribute set (deviceFamily, state, every supports-* boolean) so \
            the caller can diff before PATCHing. Returns null if the id does \
            not exist or is not visible to this team.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("accessibilityDeclarations id."),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "accessibility_declarations_list_for_app",
            description: """
            Convenience wrapper: list all accessibility declarations attached to \
            a single app via the relationship endpoint \
            `/v1/apps/{id}/accessibilityDeclarations`. Identical to \
            accessibility_declarations_list; provided as a separate name for \
            agents that prefer the per-resource scope phrasing.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id (numeric string)."),
                    ]),
                    "device_family": .object([
                        "type": .string("string"),
                        "description": .string("Filter: IPHONE, IPAD, APPLE_TV, APPLE_WATCH, MAC, VISION."),
                    ]),
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("Filter: DRAFT, PUBLISHED, REPLACED."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size (default 200)."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Pagination cursor from a previous page's nextCursor."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "accessibility_declarations_create",
            description: """
            Create a new DRAFT accessibility declaration for an (app, \
            deviceFamily). `device_family` is required; every supports-* \
            boolean is optional. The returned record is always in DRAFT state; \
            call accessibility_declarations_update with `publish: true` to \
            transition it to PUBLISHED so it appears on the App Store product \
            page. Use exact Apple attribute names (camelCase).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id (numeric string)."),
                    ]),
                    "device_family": .object([
                        "type": .string("string"),
                        "description": .string("Required: IPHONE, IPAD, APPLE_TV, APPLE_WATCH, MAC, VISION."),
                    ]),
                    "supportsVoiceover": .object([
                        "type": .string("boolean"),
                        "description": .string("Every interactive element has a meaningful VoiceOver label and is reachable."),
                    ]),
                    "supportsVoiceControl": .object([
                        "type": .string("boolean"),
                        "description": .string("Every interactive element can be operated via Voice Control commands."),
                    ]),
                    "supportsLargerText": .object([
                        "type": .string("boolean"),
                        "description": .string("UI reflows correctly under Dynamic Type / Larger Text."),
                    ]),
                    "supportsCaptions": .object([
                        "type": .string("boolean"),
                        "description": .string("Audio content has accompanying captions / subtitles."),
                    ]),
                    "supportsAudioDescriptions": .object([
                        "type": .string("boolean"),
                        "description": .string("Video content has a narrated audio-description track."),
                    ]),
                    "supportsSufficientContrast": .object([
                        "type": .string("boolean"),
                        "description": .string("All text and meaningful UI meets WCAG-style contrast ratios."),
                    ]),
                    "supportsDifferentiateWithoutColorAlone": .object([
                        "type": .string("boolean"),
                        "description": .string("Information is conveyed by more than color alone (shape / text / icons)."),
                    ]),
                    "supportsReducedMotion": .object([
                        "type": .string("boolean"),
                        "description": .string("App respects Reduce Motion (disables / dampens motion-heavy animations)."),
                    ]),
                    "supportsDarkInterface": .object([
                        "type": .string("boolean"),
                        "description": .string("App respects the system Dark Appearance setting."),
                    ]),
                ]),
                "required": .array([.string("app_id"), .string("device_family")]),
            ])
        ),

        Tool(
            name: "accessibility_declarations_update",
            description: """
            PATCH an existing declaration. Omitted fields are not sent so they \
            stay untouched on Apple's side. Pass `publish: true` to transition \
            a DRAFT record to PUBLISHED; Apple will automatically move the \
            previous PUBLISHED record (if any) for the same (app, deviceFamily) \
            to REPLACED. The deviceFamily attribute is immutable after \
            creation; passing it on update is silently ignored. Apple rejects \
            an empty PATCH body, so at least one field must be set.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("accessibilityDeclarations id to update."),
                    ]),
                    "publish": .object([
                        "type": .string("boolean"),
                        "description": .string("True transitions a DRAFT record to PUBLISHED."),
                    ]),
                    "supportsVoiceover": .object(["type": .string("boolean")]),
                    "supportsVoiceControl": .object(["type": .string("boolean")]),
                    "supportsLargerText": .object(["type": .string("boolean")]),
                    "supportsCaptions": .object(["type": .string("boolean")]),
                    "supportsAudioDescriptions": .object(["type": .string("boolean")]),
                    "supportsSufficientContrast": .object(["type": .string("boolean")]),
                    "supportsDifferentiateWithoutColorAlone": .object(["type": .string("boolean")]),
                    "supportsReducedMotion": .object(["type": .string("boolean")]),
                    "supportsDarkInterface": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "accessibility_declarations_delete",
            description: """
            Delete an accessibility declaration by id. Usually only meaningful \
            for a DRAFT record; PUBLISHED records are normally superseded via \
            the publish flow rather than deleted.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("accessibilityDeclarations id to delete."),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Routes a `CallTool.Parameters` whose name belongs to this
    /// namespace to the matching handler. Returns a result with
    /// `isError: true` for unknown names so the caller sees a clear
    /// failure rather than a silent fall-through.
    package static func handle(
        _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        switch params.name {
        case "accessibility_declarations_list":
            return try await handleList(params)
        case "accessibility_declarations_get":
            return try await handleGet(params)
        case "accessibility_declarations_list_for_app":
            return try await handleListForApp(params)
        case "accessibility_declarations_create":
            return try await handleCreate(params)
        case "accessibility_declarations_update":
            return try await handleUpdate(params)
        case "accessibility_declarations_delete":
            return try await handleDelete(params)
        default:
            return .init(
                content: [.text("Unknown Accessibility Declarations tool: \(params.name)")],
                isError: true
            )
        }
    }

    // MARK: - Handlers

    static func handleList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        return await listImpl(params, appID: appID)
    }

    static func handleListForApp(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        return await listImpl(params, appID: appID)
    }

    /// Shared list body for both list tools (filter shape is identical).
    private static func listImpl(
        _ params: CallTool.Parameters,
        appID: String
    ) async -> CallTool.Result {
        let dfRaw = params.arguments?["device_family"]?.stringValue
        let stateRaw = params.arguments?["state"]?.stringValue
        let deviceFamily = dfRaw.flatMap {
            AccessibilityDeclarationsAPI.DeviceFamily(rawValue: $0)
        }
        let state = stateRaw.flatMap {
            AccessibilityDeclarationsAPI.State(rawValue: $0)
        }
        if let r = dfRaw, deviceFamily == nil {
            return errorResult(
                "Unknown device_family '\(r)'. Expected one of: " +
                AccessibilityDeclarationsAPI.DeviceFamily.allCases
                    .map(\.rawValue).joined(separator: ", ")
            )
        }
        if let r = stateRaw, state == nil {
            return errorResult(
                "Unknown state '\(r)'. Expected one of: " +
                AccessibilityDeclarationsAPI.State.allCases
                    .map(\.rawValue).joined(separator: ", ")
            )
        }
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue

        do {
            let api = try makeAPI()
            let page = try await api.list(
                appID: appID,
                deviceFamily: deviceFamily,
                state: state,
                limit: limit,
                cursor: cursor
            )
            let payload = PageOut(
                data: page.data.map(DeclarationJSON.init),
                nextCursor: page.nextCursor
            )
            return jsonResult(payload)
        } catch let e as ASCClient.APIError {
            return apiErrorResult(e)
        } catch {
            return errorResult("accessibility_declarations_list failed: \(error)")
        }
    }

    static func handleGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI()
            let decl = try await api.get(id: id)
            return jsonResult(decl.map(DeclarationJSON.init))
        } catch let e as ASCClient.APIError {
            return apiErrorResult(e)
        } catch {
            return errorResult("accessibility_declarations_get failed: \(error)")
        }
    }

    static func handleCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        guard let dfRaw = params.arguments?["device_family"]?.stringValue,
              !dfRaw.isEmpty,
              let deviceFamily = AccessibilityDeclarationsAPI.DeviceFamily(rawValue: dfRaw)
        else {
            return errorResult(
                "Missing or unknown device_family. Expected one of: " +
                AccessibilityDeclarationsAPI.DeviceFamily.allCases
                    .map(\.rawValue).joined(separator: ", ")
            )
        }
        let fields = readFields(from: params, deviceFamily: deviceFamily)
        do {
            let api = try makeAPI()
            let decl = try await api.create(appID: appID, fields: fields)
            return jsonResult(DeclarationJSON(decl))
        } catch let e as ASCClient.APIError {
            return apiErrorResult(e)
        } catch {
            return errorResult("accessibility_declarations_create failed: \(error)")
        }
    }

    static func handleUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        // deviceFamily is ignored on update; the helper still reads it
        // but we strip it before sending.
        var fields = readFields(from: params, deviceFamily: nil)
        fields.publish = params.arguments?["publish"]?.boolValue
        if fields.isEmpty {
            return errorResult(
                "update requires at least one field to PATCH " +
                "(publish or any supports-* boolean)"
            )
        }
        do {
            let api = try makeAPI()
            let decl = try await api.update(id: id, fields: fields)
            return jsonResult(DeclarationJSON(decl))
        } catch let e as ASCClient.APIError {
            return apiErrorResult(e)
        } catch {
            return errorResult("accessibility_declarations_update failed: \(error)")
        }
    }

    static func handleDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI()
            try await api.delete(id: id)
            return .init(
                content: [.text("Deleted accessibility declaration \(id)")],
                isError: false
            )
        } catch let e as ASCClient.APIError {
            return apiErrorResult(e)
        } catch {
            return errorResult("accessibility_declarations_delete failed: \(error)")
        }
    }

    // MARK: - JSON payloads

    /// Page envelope returned by both list tools.
    struct PageOut: Encodable {
        let data: [DeclarationJSON]
        let nextCursor: String?
    }

    /// Wire-friendly view of an `AccessibilityDeclarationsAPI.Declaration`.
    /// Keeps the exact Apple attribute names so an agent can round-trip
    /// the values verbatim through update calls.
    struct DeclarationJSON: Encodable {
        let id: String
        let deviceFamily: String?
        let state: String?
        let supportsAudioDescriptions: Bool?
        let supportsCaptions: Bool?
        let supportsDarkInterface: Bool?
        let supportsDifferentiateWithoutColorAlone: Bool?
        let supportsLargerText: Bool?
        let supportsReducedMotion: Bool?
        let supportsSufficientContrast: Bool?
        let supportsVoiceControl: Bool?
        let supportsVoiceover: Bool?

        init(_ d: AccessibilityDeclarationsAPI.Declaration) {
            self.id = d.id
            self.deviceFamily = d.attributes?.deviceFamily?.rawValue
            self.state = d.attributes?.state?.rawValue
            self.supportsAudioDescriptions = d.attributes?.supportsAudioDescriptions
            self.supportsCaptions = d.attributes?.supportsCaptions
            self.supportsDarkInterface = d.attributes?.supportsDarkInterface
            self.supportsDifferentiateWithoutColorAlone =
                d.attributes?.supportsDifferentiateWithoutColorAlone
            self.supportsLargerText = d.attributes?.supportsLargerText
            self.supportsReducedMotion = d.attributes?.supportsReducedMotion
            self.supportsSufficientContrast = d.attributes?.supportsSufficientContrast
            self.supportsVoiceControl = d.attributes?.supportsVoiceControl
            self.supportsVoiceover = d.attributes?.supportsVoiceover
        }
    }

    // MARK: - Argument helpers

    /// Reads the supports-* booleans (and optional deviceFamily) off
    /// the call params into a `Fields` value. Used by both create and
    /// update handlers.
    private static func readFields(
        from params: CallTool.Parameters,
        deviceFamily: AccessibilityDeclarationsAPI.DeviceFamily?
    ) -> AccessibilityDeclarationsAPI.Fields {
        let a = params.arguments
        return AccessibilityDeclarationsAPI.Fields(
            deviceFamily: deviceFamily,
            publish: nil,
            supportsAudioDescriptions: a?["supportsAudioDescriptions"]?.boolValue,
            supportsCaptions: a?["supportsCaptions"]?.boolValue,
            supportsDarkInterface: a?["supportsDarkInterface"]?.boolValue,
            supportsDifferentiateWithoutColorAlone:
                a?["supportsDifferentiateWithoutColorAlone"]?.boolValue,
            supportsLargerText: a?["supportsLargerText"]?.boolValue,
            supportsReducedMotion: a?["supportsReducedMotion"]?.boolValue,
            supportsSufficientContrast: a?["supportsSufficientContrast"]?.boolValue,
            supportsVoiceControl: a?["supportsVoiceControl"]?.boolValue,
            supportsVoiceover: a?["supportsVoiceover"]?.boolValue
        )
    }

    private static func makeAPI() throws -> AccessibilityDeclarationsAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return AccessibilityDeclarationsAPI(client: client)
    }

    private static func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text)], isError: false)
        } catch {
            return errorResult("could not encode response JSON: \(error)")
        }
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(message)], isError: true)
    }

    private static func apiErrorResult(_ e: ASCClient.APIError) -> CallTool.Result {
        let lines = e.details.map { "  [\($0.code)] \($0.title): \($0.detail)" }
        let body = lines.isEmpty
            ? "App Store Connect API error (HTTP \(e.statusCode)): \(e.rawBody)"
            : "App Store Connect API error (HTTP \(e.statusCode))\n" + lines.joined(separator: "\n")
        return .init(content: [.text(body)], isError: true)
    }
}
