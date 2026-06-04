import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for App Review submissions: the `reviewSubmissions` +
/// `reviewSubmissionItems` resources that the `submit` orchestrator drives
/// automatically, exposed for direct control. The headline tool is
/// `review_submissions_cancel` - withdrawing a queued / in-review / rejected
/// submission so a fixed build can be resubmitted.
///
/// Also exposes `app_store_versions_list` (the appStoreVersions enumeration
/// the CLI shows in `storescreens status`): without it MCP callers had no
/// way to find a version id to attach to a submission.
///
/// All tools resolve credentials through `ASCCredentialResolver.resolve()`
/// (env vars first, then `~/.storescreens/asc-credentials.yml`). Tools
/// return pretty-printed JSON in a single `.text` content block, with
/// `isError: true` set on failures and unknown names.
package enum ReviewSubmissionsMCPTools {

    // MARK: - Tool catalog

    package static let tools: [Tool] = [
        Tool(
            name: "review_submissions_list",
            description: """
            List App Review submissions for an app, with per-submission state \
            (READY_FOR_REVIEW draft, WAITING_FOR_REVIEW queued, IN_REVIEW, \
            UNRESOLVED_ISSUES rejected, CANCELING, COMPLETING, COMPLETE). Use \
            this to find the submission id to cancel or inspect.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("Numeric ASC app id. Pass this or bundle_id."),
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Bundle id to look the app up by (alternative to app_id)."),
                    ]),
                    "platform": .object([
                        "type": .string("string"),
                        "description": .string("IOS (default) | MAC_OS | TV_OS | VISION_OS."),
                    ]),
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("Optional comma-separated state filter (e.g. WAITING_FOR_REVIEW,IN_REVIEW)."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "review_submissions_get",
            description: "Fetch a single review submission by id (state, platform, submittedDate).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("reviewSubmission id.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "review_submissions_items_list",
            description: """
            List the items attached to a review submission, with per-item state \
            (READY_FOR_REVIEW, ACCEPTED, APPROVED, REJECTED, REMOVED) and the \
            attached appStoreVersion id when the item wraps a version.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "submission_id": .object(["type": .string("string"), "description": .string("reviewSubmission id.")]),
                ]),
                "required": .array([.string("submission_id")]),
            ])
        ),
        Tool(
            name: "review_submissions_create",
            description: """
            Create a draft review submission (state READY_FOR_REVIEW) for an app. \
            ASC allows one open submission per app + platform. Attach items with \
            review_submissions_add_item, then send with review_submissions_submit.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("Numeric ASC app id. Pass this or bundle_id."),
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Bundle id to look the app up by (alternative to app_id)."),
                    ]),
                    "platform": .object([
                        "type": .string("string"),
                        "description": .string("IOS (default) | MAC_OS | TV_OS | VISION_OS."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "review_submissions_add_item",
            description: """
            Attach a reviewable resource to a draft review submission. Pass \
            version_id for the common case (an appStoreVersion). Other kinds go \
            through item_type + item_id; valid item types: \
            \(AppsAPI.ReviewSubmissionItemType.allCases.map(\.rawValue).joined(separator: ", ")).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "submission_id": .object([
                        "type": .string("string"),
                        "description": .string("reviewSubmission id (from create or list)."),
                    ]),
                    "version_id": .object([
                        "type": .string("string"),
                        "description": .string("appStoreVersion id - shorthand for item_type appStoreVersion."),
                    ]),
                    "item_type": .object([
                        "type": .string("string"),
                        "description": .string("Relationship kind for non-version items (e.g. appCustomProductPageVersion, appEvent)."),
                    ]),
                    "item_id": .object([
                        "type": .string("string"),
                        "description": .string("Id of the resource named by item_type."),
                    ]),
                ]),
                "required": .array([.string("submission_id")]),
            ])
        ),
        Tool(
            name: "review_submissions_submit",
            description: "Finalize a draft review submission and send it to Apple (PATCH submitted:true). State moves to WAITING_FOR_REVIEW.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("reviewSubmission id.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "review_submissions_cancel",
            description: """
            Cancel an in-flight review submission (PATCH canceled:true) - queued \
            (WAITING_FOR_REVIEW), in review (IN_REVIEW), rejected \
            (UNRESOLVED_ISSUES), or a stale draft (READY_FOR_REVIEW). ASC \
            transitions it through CANCELING to COMPLETE within a few seconds, \
            freeing the attached version for a fresh submission. (Apple 403s \
            DELETE on reviewSubmissions; this PATCH is the supported cancel path.)
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("reviewSubmission id.")]),
                    "wait": .object([
                        "type": .string("boolean"),
                        "description": .string("Poll until the cancellation settles (state COMPLETE) before returning."),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "review_submissions_item_update",
            description: """
            Mark a review submission item removed (pull it out of a \
            not-yet-submitted submission) and/or resolved (a rejected item has \
            been addressed). PATCH /reviewSubmissionItems/{id}.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("reviewSubmissionItem id.")]),
                    "removed": .object(["type": .string("boolean")]),
                    "resolved": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "review_submissions_item_delete",
            description: "Delete an item from a draft review submission (DELETE /reviewSubmissionItems/{id}).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("reviewSubmissionItem id.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "app_store_versions_list",
            description: """
            List appStoreVersions for an app: id, versionString, appStoreState \
            (PREPARE_FOR_SUBMISSION, READY_FOR_SALE, ...), createdDate. Use this \
            to find the version id for review_submissions_add_item or the \
            release-control tools.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("Numeric ASC app id. Pass this or bundle_id."),
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Bundle id to look the app up by (alternative to app_id)."),
                    ]),
                    "platform": .object([
                        "type": .string("string"),
                        "description": .string("Optional platform filter (IOS, MAC_OS, TV_OS, VISION_OS)."),
                    ]),
                ]),
            ])
        ),
    ]

    // MARK: - Dispatch

    package static func handle(
        _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        switch params.name {
        case "review_submissions_list":        return await handleList(params)
        case "review_submissions_get":         return await handleGet(params)
        case "review_submissions_items_list":  return await handleItemsList(params)
        case "review_submissions_create":      return await handleCreate(params)
        case "review_submissions_add_item":    return await handleAddItem(params)
        case "review_submissions_submit":      return await handleSubmit(params)
        case "review_submissions_cancel":      return await handleCancel(params)
        case "review_submissions_item_update": return await handleItemUpdate(params)
        case "review_submissions_item_delete": return await handleItemDelete(params)
        case "app_store_versions_list":        return await handleVersionsList(params)
        default:
            return errorResult("Unknown review submissions tool: \(params.name)")
        }
    }

    // MARK: - Handlers

    static func handleList(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let api = try makeAPI()
            let appID = try await resolveAppID(params, api: api)
            let platform = params.arguments?["platform"]?.stringValue ?? "IOS"
            let states = params.arguments?["state"]?.stringValue?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let subs = try await api.listReviewSubmissions(
                appID: appID, platform: platform, states: states
            )
            return jsonResult(subs)
        } catch {
            return errorResult("review_submissions_list failed: \(error)")
        }
    }

    static func handleGet(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let sub = try await makeAPI().getReviewSubmission(id: id)
            return jsonResult(sub)
        } catch {
            return errorResult("review_submissions_get failed: \(error)")
        }
    }

    static func handleItemsList(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let id = params.arguments?["submission_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: submission_id")
        }
        do {
            let items = try await makeAPI().listReviewSubmissionItems(reviewSubmissionID: id)
            return jsonResult(items)
        } catch {
            return errorResult("review_submissions_items_list failed: \(error)")
        }
    }

    static func handleCreate(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let api = try makeAPI()
            let appID = try await resolveAppID(params, api: api)
            let platform = params.arguments?["platform"]?.stringValue ?? "IOS"
            let sub = try await api.createReviewSubmission(appID: appID, platform: platform)
            return jsonResult(sub)
        } catch {
            return errorResult("review_submissions_create failed: \(error)")
        }
    }

    static func handleAddItem(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let submissionID = params.arguments?["submission_id"]?.stringValue, !submissionID.isEmpty else {
            return errorResult("Missing required parameter: submission_id")
        }
        let versionID = params.arguments?["version_id"]?.stringValue
        let itemTypeRaw = params.arguments?["item_type"]?.stringValue
        let itemID = params.arguments?["item_id"]?.stringValue

        let type: AppsAPI.ReviewSubmissionItemType
        let id: String
        if let versionID, !versionID.isEmpty {
            type = .appStoreVersion
            id = versionID
        } else if let itemTypeRaw, let itemID, !itemID.isEmpty {
            guard let parsed = AppsAPI.ReviewSubmissionItemType(rawValue: itemTypeRaw) else {
                return errorResult(
                    "Unknown item_type \"\(itemTypeRaw)\"; valid: \(AppsAPI.ReviewSubmissionItemType.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            type = parsed
            id = itemID
        } else {
            return errorResult("Pass version_id, or both item_type and item_id")
        }
        do {
            let item = try await makeAPI().addItemToReviewSubmission(
                reviewSubmissionID: submissionID, itemType: type, itemID: id
            )
            return jsonResult(item)
        } catch {
            return errorResult("review_submissions_add_item failed: \(error)")
        }
    }

    static func handleSubmit(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let sub = try await makeAPI().finalizeReviewSubmission(id: id)
            return jsonResult(sub)
        } catch {
            return errorResult("review_submissions_submit failed: \(error)")
        }
    }

    static func handleCancel(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI()
            var sub = try await api.cancelReviewSubmission(id: id)
            if params.arguments?["wait"]?.boolValue == true {
                // CANCELING settles to COMPLETE server-side within a few
                // seconds; 15 x 2s is comfortably past every observed lag.
                var attempts = 0
                while sub.attributes?.state == "CANCELING", attempts < 15 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    sub = try await api.getReviewSubmission(id: id)
                    attempts += 1
                }
            }
            return jsonResult(sub)
        } catch {
            return errorResult("review_submissions_cancel failed: \(error)")
        }
    }

    static func handleItemUpdate(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        let removed = params.arguments?["removed"]?.boolValue
        let resolved = params.arguments?["resolved"]?.boolValue
        guard removed != nil || resolved != nil else {
            return errorResult("Pass removed and/or resolved")
        }
        do {
            let item = try await makeAPI().updateReviewSubmissionItem(
                id: id, removed: removed, resolved: resolved
            )
            return jsonResult(item)
        } catch {
            return errorResult("review_submissions_item_update failed: \(error)")
        }
    }

    static func handleItemDelete(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            try await makeAPI().deleteReviewSubmissionItem(id: id)
            return jsonResult(DeletedAck(deletedID: id, kind: "reviewSubmissionItem"))
        } catch {
            return errorResult("review_submissions_item_delete failed: \(error)")
        }
    }

    static func handleVersionsList(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let api = try makeAPI()
            let appID = try await resolveAppID(params, api: api)
            let platform = params.arguments?["platform"]?.stringValue
            let versions = try await api.listVersions(appID: appID, platform: platform)
            return jsonResult(versions)
        } catch {
            return errorResult("app_store_versions_list failed: \(error)")
        }
    }

    // MARK: - Helpers

    struct DeletedAck: Encodable {
        let deletedID: String
        let kind: String
    }

    /// Thrown by `resolveAppID` so callers surface a actionable message
    /// rather than a generic decoding failure.
    struct ToolInputError: Error, CustomStringConvertible {
        let description: String
    }

    static func makeAPI() throws -> AppsAPI {
        let creds = try ASCCredentialResolver.resolve()
        return AppsAPI(client: ASCClient(credentials: creds))
    }

    /// Resolves the numeric app id from `app_id` or, failing that, a
    /// `bundle_id` lookup. Mirrors the CLI's resolution order (minus the
    /// storescreens.yml fallback, which has no equivalent cwd in MCP).
    static func resolveAppID(_ params: CallTool.Parameters, api: AppsAPI) async throws -> String {
        if let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty {
            return appID
        }
        if let bundleID = params.arguments?["bundle_id"]?.stringValue, !bundleID.isEmpty {
            guard let app = try await api.lookupApp(bundleID: bundleID) else {
                throw ToolInputError(description: "no app matches bundle_id \(bundleID)")
            }
            return app.id
        }
        throw ToolInputError(description: "pass app_id or bundle_id")
    }

    static func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
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

    static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(message)], isError: true)
    }
}
