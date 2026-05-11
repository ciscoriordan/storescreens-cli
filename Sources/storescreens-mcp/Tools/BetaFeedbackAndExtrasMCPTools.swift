import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for the four Wave-2 App Store Connect resource families
/// wrapped in `BetaFeedbackAndExtrasAPI.swift`:
///
///   - Modern TestFlight feedback (`beta_feedback_*`, `beta_crash_logs_*`)
///   - Beta recruitment criteria (`beta_recruitment_*`)
///   - Beta App Clip invocations (`beta_app_clip_invocations_*`,
///     `beta_app_clip_invocation_localizations_*`)
///   - IAP offer codes (`iap_offer_codes_*`, `iap_offer_code_custom_codes_*`,
///     `iap_offer_code_one_time_use_codes_*`)
///
/// Each tool resolves credentials through `ASCCredentialResolver.resolve()`,
/// constructs the matching `BetaFeedbackAndExtrasAPI` wrapper, and returns
/// pretty-printed JSON on success or `isError: true` text on failure.
///
/// All tool names use unique prefixes (`beta_feedback_`, `beta_crash_logs_`,
/// `beta_recruitment_`, `beta_app_clip_invocation*`, `iap_offer_code*`) to
/// avoid colliding with the Wave-1 names registered by
/// `TestFlightMCPTools` (`testflight_*`), `SubscriptionsMCPTools` (`subs_*`),
/// `InAppPurchasesMCPTools`, or `MarketingMCPTools` (`app_clip*`,
/// non-beta variants).
package enum BetaFeedbackAndExtrasMCPTools {

    // MARK: - Public surface

    /// Every tool the MCP server exposes from this module. Ordered roughly
    /// by resource family so the catalog reads top-to-bottom.
    package static let tools: [Tool] = [
        // Beta feedback (modern) - crash submissions
        crashGetTool,
        crashDeleteTool,
        // Beta feedback (modern) - screenshot submissions
        screenshotGetTool,
        screenshotDeleteTool,
        // Beta crash logs
        crashLogsGetTool,
        crashLogsDownloadTool,
        // Beta recruitment criteria
        recruitmentCreateTool,
        recruitmentUpdateTool,
        recruitmentDeleteTool,
        recruitmentOptionsListTool,
        // Beta app clip invocations
        invocationsListTool,
        invocationsCreateTool,
        invocationsGetTool,
        invocationsUpdateTool,
        invocationsDeleteTool,
        invocationLocalizationsCreateTool,
        invocationLocalizationsUpdateTool,
        invocationLocalizationsDeleteTool,
        // IAP offer codes - parent
        iapOfferCodesCreateTool,
        iapOfferCodesGetTool,
        iapOfferCodesUpdateTool,
        // IAP offer codes - custom codes
        iapCustomCodesCreateTool,
        iapCustomCodesGetTool,
        iapCustomCodesUpdateTool,
        // IAP offer codes - one-time-use codes
        iapOneTimeCreateTool,
        iapOneTimeGetTool,
        iapOneTimeUpdateTool,
        iapOneTimeValuesGetTool,
    ]

    /// Dispatch entry point. Unknown names yield `isError: true` so the
    /// parent dispatcher can spot routing mistakes.
    package static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            return errorResult(
                "App Store Connect credentials are not configured. " +
                "Run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / " +
                "ASC_KEY_PATH. (\(error))"
            )
        }
        let client = ASCClient(credentials: creds)

        do {
            switch params.name {
            // Beta feedback - crash
            case "beta_feedback_crash_get":
                return try await handleCrashGet(params, api: BetaFeedbackAPI(client: client))
            case "beta_feedback_crash_delete":
                return try await handleCrashDelete(params, api: BetaFeedbackAPI(client: client))
            // Beta feedback - screenshot
            case "beta_feedback_screenshot_get":
                return try await handleScreenshotGet(params, api: BetaFeedbackAPI(client: client))
            case "beta_feedback_screenshot_delete":
                return try await handleScreenshotDelete(params, api: BetaFeedbackAPI(client: client))
            // Beta crash logs
            case "beta_crash_logs_get":
                return try await handleCrashLogsGet(params, api: BetaFeedbackAPI(client: client))
            case "beta_crash_logs_download":
                return try await handleCrashLogsDownload(params, api: BetaFeedbackAPI(client: client))
            // Beta recruitment criteria
            case "beta_recruitment_criteria_create":
                return try await handleRecruitmentCreate(params, api: BetaRecruitmentAPI(client: client))
            case "beta_recruitment_criteria_update":
                return try await handleRecruitmentUpdate(params, api: BetaRecruitmentAPI(client: client))
            case "beta_recruitment_criteria_delete":
                return try await handleRecruitmentDelete(params, api: BetaRecruitmentAPI(client: client))
            case "beta_recruitment_criterion_options_list":
                return try await handleRecruitmentOptionsList(params, api: BetaRecruitmentAPI(client: client))
            // Beta app clip invocations
            case "beta_app_clip_invocations_list":
                return try await handleInvocationsList(params, api: BetaAppClipInvocationsAPI(client: client))
            case "beta_app_clip_invocations_create":
                return try await handleInvocationsCreate(params, api: BetaAppClipInvocationsAPI(client: client))
            case "beta_app_clip_invocations_get":
                return try await handleInvocationsGet(params, api: BetaAppClipInvocationsAPI(client: client))
            case "beta_app_clip_invocations_update":
                return try await handleInvocationsUpdate(params, api: BetaAppClipInvocationsAPI(client: client))
            case "beta_app_clip_invocations_delete":
                return try await handleInvocationsDelete(params, api: BetaAppClipInvocationsAPI(client: client))
            case "beta_app_clip_invocation_localizations_create":
                return try await handleInvocationLocalizationsCreate(params, api: BetaAppClipInvocationsAPI(client: client))
            case "beta_app_clip_invocation_localizations_update":
                return try await handleInvocationLocalizationsUpdate(params, api: BetaAppClipInvocationsAPI(client: client))
            case "beta_app_clip_invocation_localizations_delete":
                return try await handleInvocationLocalizationsDelete(params, api: BetaAppClipInvocationsAPI(client: client))
            // IAP offer codes
            case "iap_offer_codes_create":
                return try await handleIAPOfferCodesCreate(params, api: IAPOfferCodesAPI(client: client))
            case "iap_offer_codes_get":
                return try await handleIAPOfferCodesGet(params, api: IAPOfferCodesAPI(client: client))
            case "iap_offer_codes_update":
                return try await handleIAPOfferCodesUpdate(params, api: IAPOfferCodesAPI(client: client))
            case "iap_offer_code_custom_codes_create":
                return try await handleIAPCustomCodesCreate(params, api: IAPOfferCodesAPI(client: client))
            case "iap_offer_code_custom_codes_get":
                return try await handleIAPCustomCodesGet(params, api: IAPOfferCodesAPI(client: client))
            case "iap_offer_code_custom_codes_update":
                return try await handleIAPCustomCodesUpdate(params, api: IAPOfferCodesAPI(client: client))
            case "iap_offer_code_one_time_use_codes_create":
                return try await handleIAPOneTimeCreate(params, api: IAPOfferCodesAPI(client: client))
            case "iap_offer_code_one_time_use_codes_get":
                return try await handleIAPOneTimeGet(params, api: IAPOfferCodesAPI(client: client))
            case "iap_offer_code_one_time_use_codes_update":
                return try await handleIAPOneTimeUpdate(params, api: IAPOfferCodesAPI(client: client))
            case "iap_offer_code_one_time_use_code_values_get":
                return try await handleIAPOneTimeValuesGet(params, api: IAPOfferCodesAPI(client: client))
            default:
                return errorResult("Unknown beta-feedback / extras tool: \(params.name)")
            }
        } catch let e as ASCClient.APIError {
            return errorResult(
                "App Store Connect API error (HTTP \(e.statusCode))\n" +
                e.details.map { "  [\($0.code)] \($0.title): \($0.detail)" }
                    .joined(separator: "\n")
            )
        } catch {
            return errorResult("Error: \(error)")
        }
    }

    // MARK: - Shared helpers

    private static func arg(_ params: CallTool.Parameters, _ key: String) -> Value? {
        params.arguments?[key]
    }

    private static func requireString(_ params: CallTool.Parameters, _ key: String) throws -> String {
        guard let s = arg(params, key)?.stringValue, !s.isEmpty else {
            throw MCPArgError("Missing required string argument: \(key)")
        }
        return s
    }

    private static func optionalString(_ params: CallTool.Parameters, _ key: String) -> String? {
        let s = arg(params, key)?.stringValue
        if let s, !s.isEmpty { return s }
        return nil
    }

    private static func optionalInt(_ params: CallTool.Parameters, _ key: String) -> Int? {
        if let v = arg(params, key)?.intValue { return v }
        if let s = arg(params, key)?.stringValue, let i = Int(s) { return i }
        return nil
    }

    private static func requireInt(_ params: CallTool.Parameters, _ key: String) throws -> Int {
        guard let i = optionalInt(params, key) else {
            throw MCPArgError("Missing required integer argument: \(key)")
        }
        return i
    }

    private static func optionalBool(_ params: CallTool.Parameters, _ key: String) -> Bool? {
        arg(params, key)?.boolValue
    }

    private static func optionalStringArray(_ params: CallTool.Parameters, _ key: String) -> [String]? {
        guard let arr = arg(params, key)?.arrayValue else { return nil }
        let strings = arr.compactMap(\.stringValue)
        return strings.isEmpty ? nil : strings
    }

    private static func requireStringArray(_ params: CallTool.Parameters, _ key: String) throws -> [String] {
        guard let arr = arg(params, key)?.arrayValue else {
            throw MCPArgError("Missing required array argument: \(key)")
        }
        let items = arr.compactMap(\.stringValue)
        if items.isEmpty {
            throw MCPArgError("Array argument \(key) is empty or contains non-strings")
        }
        return items
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = iso8601.date(from: s) { return d }
        return iso8601Plain.date(from: s)
    }

    private struct MCPArgError: Error, CustomStringConvertible {
        let description: String
        init(_ m: String) { self.description = m }
    }

    private static func jsonText<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)])
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func ackResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)])
    }

    // MARK: - Page envelope

    /// JSON shape returned for paginated tool calls. Matches the
    /// `BetaFeedbackPage` contract in `BetaFeedbackAndExtrasAPI.swift`.
    private struct PageOut<Item: Encodable>: Encodable {
        let items: [Item]
        let nextCursor: String?
    }

    private static func envelope<Item: Encodable>(_ page: BetaFeedbackPage<Item>) -> PageOut<Item> {
        PageOut(items: page.items, nextCursor: page.nextCursor)
    }

    // MARK: - Tool definitions: beta feedback (crash)

    private static let crashGetTool = Tool(
        name: "beta_feedback_crash_get",
        description: "Get a single TestFlight crash feedback submission by id. Returns null on 404.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string"), "description": .string("betaFeedbackCrashSubmission id")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let crashDeleteTool = Tool(
        name: "beta_feedback_crash_delete",
        description: "Delete a TestFlight crash feedback submission. Apple keeps the associated betaCrashLog reachable briefly after delete.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Tool definitions: beta feedback (screenshot)

    private static let screenshotGetTool = Tool(
        name: "beta_feedback_screenshot_get",
        description: "Get a single TestFlight screenshot feedback submission by id. Returns null on 404.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string"), "description": .string("betaFeedbackScreenshotSubmission id")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let screenshotDeleteTool = Tool(
        name: "beta_feedback_screenshot_delete",
        description: "Delete a TestFlight screenshot feedback submission.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Tool definitions: beta crash logs

    private static let crashLogsGetTool = Tool(
        name: "beta_crash_logs_get",
        description: "Fetch a betaCrashLog by id. Returns the metadata + downloadable URL. Returns null on 404.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string"), "description": .string("betaCrashLog id")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let crashLogsDownloadTool = Tool(
        name: "beta_crash_logs_download",
        description: "Download a betaCrashLog .crash file. The bytes are returned base64-encoded in the response. Optional `output_path` writes the file to disk instead.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string"), "description": .string("betaCrashLog id")]),
                "output_path": .object(["type": .string("string"), "description": .string("Optional absolute path to write the .crash file. If omitted, the bytes are returned base64-encoded.")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Tool definitions: beta recruitment

    private static let recruitmentCreateTool = Tool(
        name: "beta_recruitment_criteria_create",
        description: "Create a new automatic-recruitment criterion on a beta group. Fetch valid values for device_families / regions via beta_recruitment_criterion_options_list.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "beta_group_id": .object(["type": .string("string")]),
                "display_name": .object(["type": .string("string"), "description": .string("Developer-visible label.")]),
                "device_families": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Apple-defined device family codes."),
                ]),
                "minimum_os_version": .object(["type": .string("string"), "description": .string("e.g. \"17.0\". Nil = any.")]),
                "maximum_os_version": .object(["type": .string("string")]),
                "allowed_regions": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("ISO 3166-1 alpha-3 codes. Empty = global."),
                ]),
                "is_active": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("beta_group_id"), .string("display_name")]),
        ])
    )

    private static let recruitmentUpdateTool = Tool(
        name: "beta_recruitment_criteria_update",
        description: "PATCH an automatic-recruitment criterion. Omitted fields stay untouched. Use is_active=false to pause without delete.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "display_name": .object(["type": .string("string")]),
                "device_families": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ]),
                "minimum_os_version": .object(["type": .string("string")]),
                "maximum_os_version": .object(["type": .string("string")]),
                "allowed_regions": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ]),
                "is_active": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let recruitmentDeleteTool = Tool(
        name: "beta_recruitment_criteria_delete",
        description: "Delete an automatic-recruitment criterion.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let recruitmentOptionsListTool = Tool(
        name: "beta_recruitment_criterion_options_list",
        description: "List the read-only catalog of valid values for recruitment criteria (device families, OS versions, regions). Apple updates this catalog over time; always fetch live rather than hard-coding values.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object(["type": .string("integer"), "description": .string("Page size (default 200).")]),
                "cursor": .object(["type": .string("string")]),
            ]),
        ])
    )

    // MARK: - Tool definitions: beta app clip invocations

    private static let invocationsListTool = Tool(
        name: "beta_app_clip_invocations_list",
        description: "List beta App Clip invocations attached to a build.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "build_id": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")]),
                "cursor": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("build_id")]),
        ])
    )

    private static let invocationsCreateTool = Tool(
        name: "beta_app_clip_invocations_create",
        description: "Create a beta App Clip invocation (URL trigger) on a build.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "build_id": .object(["type": .string("string")]),
                "url": .object(["type": .string("string"), "description": .string("Trigger URL prefix.")]),
                "action": .object(["type": .string("string"), "description": .string("Verb shown next to the Clip card. OPEN | VIEW | PLAY. Defaults to OPEN.")]),
            ]),
            "required": .array([.string("build_id"), .string("url")]),
        ])
    )

    private static let invocationsGetTool = Tool(
        name: "beta_app_clip_invocations_get",
        description: "Get a beta App Clip invocation by id. Returns null on 404.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let invocationsUpdateTool = Tool(
        name: "beta_app_clip_invocations_update",
        description: "PATCH url and/or action on a beta App Clip invocation.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "url": .object(["type": .string("string")]),
                "action": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let invocationsDeleteTool = Tool(
        name: "beta_app_clip_invocations_delete",
        description: "Delete a beta App Clip invocation.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let invocationLocalizationsCreateTool = Tool(
        name: "beta_app_clip_invocation_localizations_create",
        description: "Create a per-locale title for a beta App Clip invocation.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "invocation_id": .object(["type": .string("string")]),
                "locale": .object(["type": .string("string"), "description": .string("e.g. en-US")]),
                "title": .object(["type": .string("string")]),
                "subtitle": .object(["type": .string("string"), "description": .string("Optional second line.")]),
            ]),
            "required": .array([.string("invocation_id"), .string("locale"), .string("title")]),
        ])
    )

    private static let invocationLocalizationsUpdateTool = Tool(
        name: "beta_app_clip_invocation_localizations_update",
        description: "PATCH title and/or subtitle on a beta App Clip invocation localization.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
                "subtitle": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let invocationLocalizationsDeleteTool = Tool(
        name: "beta_app_clip_invocation_localizations_delete",
        description: "Delete a beta App Clip invocation localization.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Tool definitions: IAP offer codes (parent)

    private static let iapOfferCodesCreateTool = Tool(
        name: "iap_offer_codes_create",
        description: "Create a new offer-code program against a one-time IAP (consumable, non-consumable, or non-renewing subscription). Subscription offer codes use the separate subs_offer_codes_* tools.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "in_app_purchase_id": .object(["type": .string("string"), "description": .string("IAP V2 resource id.")]),
                "reference_name": .object(["type": .string("string")]),
                "customer_eligibilities": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Subset of NEW, EXISTING, EXPIRED."),
                ]),
                "expiration_date": .object(["type": .string("string"), "description": .string("Optional ISO-8601 expiration.")]),
            ]),
            "required": .array([
                .string("in_app_purchase_id"),
                .string("reference_name"),
                .string("customer_eligibilities"),
            ]),
        ])
    )

    private static let iapOfferCodesGetTool = Tool(
        name: "iap_offer_codes_get",
        description: "Fetch a one-time IAP offer code by id. Returns null on 404.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let iapOfferCodesUpdateTool = Tool(
        name: "iap_offer_codes_update",
        description: "PATCH a one-time IAP offer code. Omitted fields stay untouched. Use is_active to pause without delete.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "reference_name": .object(["type": .string("string")]),
                "is_active": .object(["type": .string("boolean")]),
                "customer_eligibilities": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ]),
                "expiration_date": .object(["type": .string("string"), "description": .string("Optional ISO-8601 expiration.")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Tool definitions: IAP offer codes (custom)

    private static let iapCustomCodesCreateTool = Tool(
        name: "iap_offer_code_custom_codes_create",
        description: "Create a developer-chosen custom-string code (e.g. 'BLACKFRIDAY25_PRO') for a one-time IAP offer code program.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "offer_code_id": .object(["type": .string("string"), "description": .string("Parent inAppPurchaseOfferCode id.")]),
                "custom_code": .object(["type": .string("string"), "description": .string("Code string customers will type.")]),
                "number_of_codes": .object(["type": .string("integer"), "description": .string("Cap on total redemptions.")]),
                "expiration_date": .object(["type": .string("string"), "description": .string("Optional ISO-8601 expiration.")]),
            ]),
            "required": .array([
                .string("offer_code_id"), .string("custom_code"), .string("number_of_codes"),
            ]),
        ])
    )

    private static let iapCustomCodesGetTool = Tool(
        name: "iap_offer_code_custom_codes_get",
        description: "Fetch a one-time IAP custom code by id. Returns null on 404.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let iapCustomCodesUpdateTool = Tool(
        name: "iap_offer_code_custom_codes_update",
        description: "PATCH active state / expiration on a one-time IAP custom code. The string itself cannot be renamed.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "is_active": .object(["type": .string("boolean")]),
                "expiration_date": .object(["type": .string("string"), "description": .string("Optional ISO-8601 expiration.")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Tool definitions: IAP offer codes (one-time-use)

    private static let iapOneTimeCreateTool = Tool(
        name: "iap_offer_code_one_time_use_codes_create",
        description: "Generate a batch of unique single-use redemption codes for a one-time IAP offer code program. Apple processes asynchronously; poll with `_get` until is_active=true, then fetch the actual strings via `_values_get`.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "offer_code_id": .object(["type": .string("string"), "description": .string("Parent inAppPurchaseOfferCode id.")]),
                "number_of_codes": .object(["type": .string("integer"), "description": .string("How many codes to mint.")]),
                "expiration_date": .object(["type": .string("string"), "description": .string("Optional ISO-8601 expiration.")]),
            ]),
            "required": .array([.string("offer_code_id"), .string("number_of_codes")]),
        ])
    )

    private static let iapOneTimeGetTool = Tool(
        name: "iap_offer_code_one_time_use_codes_get",
        description: "Fetch a one-time-use code batch by id. Use this to poll until isActive=true after creating a batch.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let iapOneTimeUpdateTool = Tool(
        name: "iap_offer_code_one_time_use_codes_update",
        description: "PATCH active state / expiration on a one-time-use code batch. The code count cannot be changed post-create.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "is_active": .object(["type": .string("boolean")]),
                "expiration_date": .object(["type": .string("string"), "description": .string("Optional ISO-8601 expiration.")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    private static let iapOneTimeValuesGetTool = Tool(
        name: "iap_offer_code_one_time_use_code_values_get",
        description: "List the generated code strings for a one-time-use batch. Returns an empty page if Apple is still processing the batch (parent is_active=false).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "one_time_use_code_id": .object(["type": .string("string"), "description": .string("Parent inAppPurchaseOfferCodeOneTimeUseCode id.")]),
                "limit": .object(["type": .string("integer")]),
                "cursor": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("one_time_use_code_id")]),
        ])
    )

    // MARK: - Handlers: beta feedback (crash)

    private static func handleCrashGet(
        _ params: CallTool.Parameters, api: BetaFeedbackAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let sub = try await api.getCrashSubmission(id: id)
        return try jsonText(sub)
    }

    private static func handleCrashDelete(
        _ params: CallTool.Parameters, api: BetaFeedbackAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.deleteCrashSubmission(id: id)
        return ackResult("deleted betaFeedbackCrashSubmission \(id)")
    }

    // MARK: - Handlers: beta feedback (screenshot)

    private static func handleScreenshotGet(
        _ params: CallTool.Parameters, api: BetaFeedbackAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let sub = try await api.getScreenshotSubmission(id: id)
        return try jsonText(sub)
    }

    private static func handleScreenshotDelete(
        _ params: CallTool.Parameters, api: BetaFeedbackAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.deleteScreenshotSubmission(id: id)
        return ackResult("deleted betaFeedbackScreenshotSubmission \(id)")
    }

    // MARK: - Handlers: beta crash logs

    private static func handleCrashLogsGet(
        _ params: CallTool.Parameters, api: BetaFeedbackAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let log = try await api.getCrashLog(id: id)
        return try jsonText(log)
    }

    private static func handleCrashLogsDownload(
        _ params: CallTool.Parameters, api: BetaFeedbackAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let bytes = try await api.downloadLog(id: id)
        if let outputPath = optionalString(params, "output_path") {
            let url = URL(fileURLWithPath: outputPath)
            try bytes.write(to: url)
            struct Out: Encodable {
                let id: String
                let outputPath: String
                let bytesWritten: Int
            }
            return try jsonText(Out(id: id, outputPath: outputPath, bytesWritten: bytes.count))
        }
        struct Out: Encodable {
            let id: String
            let base64: String
            let bytesLength: Int
        }
        return try jsonText(Out(
            id: id,
            base64: bytes.base64EncodedString(),
            bytesLength: bytes.count
        ))
    }

    // MARK: - Handlers: beta recruitment

    private static func handleRecruitmentCreate(
        _ params: CallTool.Parameters, api: BetaRecruitmentAPI
    ) async throws -> CallTool.Result {
        let betaGroupID = try requireString(params, "beta_group_id")
        let displayName = try requireString(params, "display_name")
        let fields = BetaRecruitmentAPI.CriterionFields(
            deviceFamilies: optionalStringArray(params, "device_families"),
            minimumOsVersion: optionalString(params, "minimum_os_version"),
            maximumOsVersion: optionalString(params, "maximum_os_version"),
            allowedRegions: optionalStringArray(params, "allowed_regions"),
            isActive: optionalBool(params, "is_active")
        )
        let c = try await api.createCriterion(
            betaGroupID: betaGroupID, displayName: displayName, fields: fields
        )
        return try jsonText(c)
    }

    private static func handleRecruitmentUpdate(
        _ params: CallTool.Parameters, api: BetaRecruitmentAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = BetaRecruitmentAPI.CriterionFields(
            displayName: optionalString(params, "display_name"),
            deviceFamilies: optionalStringArray(params, "device_families"),
            minimumOsVersion: optionalString(params, "minimum_os_version"),
            maximumOsVersion: optionalString(params, "maximum_os_version"),
            allowedRegions: optionalStringArray(params, "allowed_regions"),
            isActive: optionalBool(params, "is_active")
        )
        let c = try await api.updateCriterion(id: id, fields: fields)
        return try jsonText(c)
    }

    private static func handleRecruitmentDelete(
        _ params: CallTool.Parameters, api: BetaRecruitmentAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.deleteCriterion(id: id)
        return ackResult("deleted betaRecruitmentCriterion \(id)")
    }

    private static func handleRecruitmentOptionsList(
        _ params: CallTool.Parameters, api: BetaRecruitmentAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listCriterionOptions(limit: limit, cursor: cursor)
        return try jsonText(envelope(page))
    }

    // MARK: - Handlers: beta app clip invocations

    private static func handleInvocationsList(
        _ params: CallTool.Parameters, api: BetaAppClipInvocationsAPI
    ) async throws -> CallTool.Result {
        let buildID = try requireString(params, "build_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listInvocations(buildID: buildID, limit: limit, cursor: cursor)
        return try jsonText(envelope(page))
    }

    private static func handleInvocationsCreate(
        _ params: CallTool.Parameters, api: BetaAppClipInvocationsAPI
    ) async throws -> CallTool.Result {
        let buildID = try requireString(params, "build_id")
        let url = try requireString(params, "url")
        let action = optionalString(params, "action")
        let inv = try await api.createInvocation(buildID: buildID, url: url, action: action)
        return try jsonText(inv)
    }

    private static func handleInvocationsGet(
        _ params: CallTool.Parameters, api: BetaAppClipInvocationsAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let inv = try await api.getInvocation(id: id)
        return try jsonText(inv)
    }

    private static func handleInvocationsUpdate(
        _ params: CallTool.Parameters, api: BetaAppClipInvocationsAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let url = optionalString(params, "url")
        let action = optionalString(params, "action")
        let inv = try await api.updateInvocation(id: id, url: url, action: action)
        return try jsonText(inv)
    }

    private static func handleInvocationsDelete(
        _ params: CallTool.Parameters, api: BetaAppClipInvocationsAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.deleteInvocation(id: id)
        return ackResult("deleted betaAppClipInvocation \(id)")
    }

    private static func handleInvocationLocalizationsCreate(
        _ params: CallTool.Parameters, api: BetaAppClipInvocationsAPI
    ) async throws -> CallTool.Result {
        let invocationID = try requireString(params, "invocation_id")
        let locale = try requireString(params, "locale")
        let title = try requireString(params, "title")
        let subtitle = optionalString(params, "subtitle")
        let loc = try await api.createLocalization(
            invocationID: invocationID, locale: locale, title: title, subtitle: subtitle
        )
        return try jsonText(loc)
    }

    private static func handleInvocationLocalizationsUpdate(
        _ params: CallTool.Parameters, api: BetaAppClipInvocationsAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let title = optionalString(params, "title")
        let subtitle = optionalString(params, "subtitle")
        let loc = try await api.updateLocalization(id: id, title: title, subtitle: subtitle)
        return try jsonText(loc)
    }

    private static func handleInvocationLocalizationsDelete(
        _ params: CallTool.Parameters, api: BetaAppClipInvocationsAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.deleteLocalization(id: id)
        return ackResult("deleted betaAppClipInvocationLocalization \(id)")
    }

    // MARK: - Handlers: IAP offer codes (parent)

    private static func handleIAPOfferCodesCreate(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let iapID = try requireString(params, "in_app_purchase_id")
        let referenceName = try requireString(params, "reference_name")
        let eligibilities = try requireStringArray(params, "customer_eligibilities")
        let expiration = parseDate(optionalString(params, "expiration_date"))
        let oc = try await api.createOfferCode(
            inAppPurchaseID: iapID,
            referenceName: referenceName,
            customerEligibilities: eligibilities,
            expirationDate: expiration
        )
        return try jsonText(oc)
    }

    private static func handleIAPOfferCodesGet(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let oc = try await api.getOfferCode(id: id)
        return try jsonText(oc)
    }

    private static func handleIAPOfferCodesUpdate(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = IAPOfferCodesAPI.OfferCodeFields(
            referenceName: optionalString(params, "reference_name"),
            isActive: optionalBool(params, "is_active"),
            customerEligibilities: optionalStringArray(params, "customer_eligibilities"),
            expirationDate: parseDate(optionalString(params, "expiration_date"))
        )
        let oc = try await api.updateOfferCode(id: id, fields: fields)
        return try jsonText(oc)
    }

    // MARK: - Handlers: IAP offer codes (custom)

    private static func handleIAPCustomCodesCreate(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let offerCodeID = try requireString(params, "offer_code_id")
        let customCode = try requireString(params, "custom_code")
        let count = try requireInt(params, "number_of_codes")
        let expiration = parseDate(optionalString(params, "expiration_date"))
        let code = try await api.createCustomCode(
            offerCodeID: offerCodeID,
            customCode: customCode,
            numberOfCodes: count,
            expirationDate: expiration
        )
        return try jsonText(code)
    }

    private static func handleIAPCustomCodesGet(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let code = try await api.getCustomCode(id: id)
        return try jsonText(code)
    }

    private static func handleIAPCustomCodesUpdate(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let isActive = optionalBool(params, "is_active")
        let expiration = parseDate(optionalString(params, "expiration_date"))
        let code = try await api.updateCustomCode(
            id: id, isActive: isActive, expirationDate: expiration
        )
        return try jsonText(code)
    }

    // MARK: - Handlers: IAP offer codes (one-time)

    private static func handleIAPOneTimeCreate(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let offerCodeID = try requireString(params, "offer_code_id")
        let count = try requireInt(params, "number_of_codes")
        let expiration = parseDate(optionalString(params, "expiration_date"))
        let batch = try await api.createOneTimeUseCode(
            offerCodeID: offerCodeID, numberOfCodes: count, expirationDate: expiration
        )
        return try jsonText(batch)
    }

    private static func handleIAPOneTimeGet(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let batch = try await api.getOneTimeUseCode(id: id)
        return try jsonText(batch)
    }

    private static func handleIAPOneTimeUpdate(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let isActive = optionalBool(params, "is_active")
        let expiration = parseDate(optionalString(params, "expiration_date"))
        let batch = try await api.updateOneTimeUseCode(
            id: id, isActive: isActive, expirationDate: expiration
        )
        return try jsonText(batch)
    }

    private static func handleIAPOneTimeValuesGet(
        _ params: CallTool.Parameters, api: IAPOfferCodesAPI
    ) async throws -> CallTool.Result {
        let oneTimeID = try requireString(params, "one_time_use_code_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listOneTimeUseCodeValues(
            oneTimeUseCodeID: oneTimeID, limit: limit, cursor: cursor
        )
        return try jsonText(envelope(page))
    }
}
