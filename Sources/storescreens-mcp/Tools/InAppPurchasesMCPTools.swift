import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for App Store Connect In-App Purchases (V2 API).
///
/// Every tool resolves credentials through `ASCCredentialResolver.resolve()`
/// before hitting the API, so callers don't pass key material in the tool
/// arguments. Results come back as pretty-printed JSON text content; errors
/// arrive as `isError: true` results with the message in the text payload.
///
/// Tool names follow the convention `iap_<resource>_<op>`. Wire them up by
/// appending `InAppPurchasesMCPTools.tools` to the server's tool list and
/// routing `iap_*` names through `InAppPurchasesMCPTools.handle(params:)` in
/// the `CallTool` handler.
package enum InAppPurchasesMCPTools {

    // MARK: - Tool declarations

    package static let tools: [Tool] = [
        // Parent IAP resource
        Tool(
            name: "iap_in_app_purchases_list",
            description: "List in-app purchases for an app. Returns a paginated page of IAPs with id, productId, type, and state. Pass `cursor` from the previous response to fetch additional pages.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string"), "description": .string("App Store Connect app id (numeric).")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Page size. Default 200, max 200.")]),
                    "cursor": .object(["type": .string("string"), "description": .string("Opaque pagination cursor from a prior response.")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "iap_in_app_purchases_get",
            description: "Fetch a single in-app purchase by id. Returns null if not found.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string"), "description": .string("inAppPurchases resource id.")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_in_app_purchases_create",
            description: "Create a new IAP under an app. `inAppPurchaseType` must be CONSUMABLE, NON_CONSUMABLE, or NON_RENEWING_SUBSCRIPTION. After create, set localizations + pricing + a review screenshot before submitting.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string"), "description": .string("App Store Connect app id.")]),
                    "name": .object(["type": .string("string"), "description": .string("Internal reference name (not shown to customers).")]),
                    "product_id": .object(["type": .string("string"), "description": .string("Bundle-scoped product id, e.g. 'com.acme.pro_unlock'.")]),
                    "in_app_purchase_type": .object(["type": .string("string"), "description": .string("CONSUMABLE | NON_CONSUMABLE | NON_RENEWING_SUBSCRIPTION")]),
                    "review_note": .object(["type": .string("string"), "description": .string("Optional review notes for Apple.")]),
                    "family_sharable": .object(["type": .string("boolean"), "description": .string("Whether the IAP is shared with the user's family.")]),
                    "available_in_all_territories": .object(["type": .string("boolean"), "description": .string("Whether the IAP is available in every territory.")]),
                ]),
                "required": .array([.string("app_id"), .string("name"), .string("product_id"), .string("in_app_purchase_type")]),
            ])
        ),
        Tool(
            name: "iap_in_app_purchases_update",
            description: "PATCH an IAP. Product id and product type are not editable. Nil fields stay untouched on ASC.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "review_note": .object(["type": .string("string")]),
                    "family_sharable": .object(["type": .string("boolean")]),
                    "available_in_all_territories": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_in_app_purchases_delete",
            description: "Delete an IAP. Apple only permits delete while the IAP is in MISSING_METADATA, READY_TO_SUBMIT, or DEVELOPER_ACTION_NEEDED.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),

        // Localizations
        Tool(
            name: "iap_localizations_list",
            description: "List per-locale name + description records on an IAP.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_localizations_get",
            description: "Fetch a single localization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localization_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("localization_id")]),
            ])
        ),
        Tool(
            name: "iap_localizations_create",
            description: "Create a per-locale display record for an IAP. `name` is required; `description` is optional but recommended.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string"), "description": .string("e.g. en-US, ja, de-DE")]),
                    "name": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id"), .string("locale"), .string("name")]),
            ])
        ),
        Tool(
            name: "iap_localizations_update",
            description: "PATCH a localization's name and/or description. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localization_id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("localization_id")]),
            ])
        ),
        Tool(
            name: "iap_localizations_delete",
            description: "Delete a localization. Apple permits delete only while the IAP is editable.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localization_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("localization_id")]),
            ])
        ),

        // Price points (read-only)
        Tool(
            name: "iap_price_points_list",
            description: "List valid price tiers for an IAP, optionally filtered to a single territory (ISO 3166-1 alpha-3, e.g. 'USA'). Use the resulting id values with iap_price_schedule_set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "territory_id": .object(["type": .string("string"), "description": .string("ISO 3166-1 alpha-3 territory code (e.g. USA)")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_price_points_get",
            description: "Fetch a single price point by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "price_point_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("price_point_id")]),
            ])
        ),

        // Price schedules
        Tool(
            name: "iap_price_schedule_get",
            description: "Return the IAP's current price schedule, or null if none is set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_price_schedule_set",
            description: "Create or replace the IAP's price schedule. `base_territory_id` is used to compute equivalent prices for territories not in the explicit list (usually 'USA'). `prices` is an array of {territory_id, price_point_id, start_date?} entries.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "base_territory_id": .object(["type": .string("string"), "description": .string("Territory whose price Apple uses to derive others (usually 'USA').")]),
                    "prices": .object([
                        "type": .string("array"),
                        "description": .string("Array of {territory_id, price_point_id, start_date?} objects."),
                    ]),
                ]),
                "required": .array([.string("iap_id"), .string("base_territory_id"), .string("prices")]),
            ])
        ),

        // Submissions
        Tool(
            name: "iap_submission_list",
            description: "List review submissions for an IAP.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_submission_get",
            description: "Fetch a single review submission by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "submission_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("submission_id")]),
            ])
        ),
        Tool(
            name: "iap_submission_create",
            description: "Submit an IAP for Apple review. The IAP must be in READY_TO_SUBMIT state with all required metadata (localizations, pricing, review screenshot) already set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),

        // Content hostings
        Tool(
            name: "iap_content_hosting_get",
            description: "Return the IAP's content hosting record, or null if none. Used for non-consumables that deliver downloadable content via Apple's hosting.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_content_hosting_update",
            description: "PATCH the content hosting record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "content_hosting_id": .object(["type": .string("string")]),
                    "file_name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("content_hosting_id")]),
            ])
        ),

        // Images (IAP detail page)
        Tool(
            name: "iap_images_list",
            description: "List promotional images attached to the IAP's detail page.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_images_get",
            description: "Fetch a single image record by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "image_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("image_id")]),
            ])
        ),
        Tool(
            name: "iap_images_upload",
            description: "Upload an image file for the IAP's detail page. Reserves a slot, uploads the bytes, and confirms in one call. Pass an absolute file path.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string"), "description": .string("Absolute path to the image file on disk.")]),
                ]),
                "required": .array([.string("iap_id"), .string("file_path")]),
            ])
        ),
        Tool(
            name: "iap_images_update",
            description: "PATCH the image record's metadata (e.g. rename). Cannot replace bytes; delete and re-upload to swap the image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "image_id": .object(["type": .string("string")]),
                    "file_name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("image_id")]),
            ])
        ),
        Tool(
            name: "iap_images_delete",
            description: "Delete an IAP detail page image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "image_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("image_id")]),
            ])
        ),

        // Review screenshots
        Tool(
            name: "iap_review_screenshot_get",
            description: "Return the IAP's App Store review screenshot, or null if none. Required for every IAP before submission.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_review_screenshot_upload",
            description: "Upload the review screenshot Apple's reviewers will see. Reserves a slot, uploads the bytes, and confirms in one call.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string"), "description": .string("Absolute path to the screenshot file on disk.")]),
                ]),
                "required": .array([.string("iap_id"), .string("file_path")]),
            ])
        ),
        Tool(
            name: "iap_review_screenshot_update",
            description: "PATCH the review screenshot's metadata (e.g. rename).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "review_screenshot_id": .object(["type": .string("string")]),
                    "file_name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("review_screenshot_id")]),
            ])
        ),
        Tool(
            name: "iap_review_screenshot_delete",
            description: "Delete the IAP's review screenshot.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "review_screenshot_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("review_screenshot_id")]),
            ])
        ),

        // Promotional images (featured-slot artwork)
        Tool(
            name: "iap_promotional_images_list",
            description: "List Apple's featured-slot promotional images for an IAP.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "iap_promotional_images_upload",
            description: "Upload a promotional image used in featured slots on the App Store.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id"), .string("file_path")]),
            ])
        ),
        Tool(
            name: "iap_promotional_images_delete",
            description: "Delete a promotional image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "promotional_image_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("promotional_image_id")]),
            ])
        ),

        // Promoted purchases
        Tool(
            name: "iap_promoted_purchases_list",
            description: "List the app's promoted purchases (which IAPs are highlighted in the App Store storefront).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "iap_promoted_purchases_update",
            description: "Toggle whether an IAP is promoted in the storefront, and optionally whether it is currently visible.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "promoted_purchase_id": .object(["type": .string("string")]),
                    "enabled": .object(["type": .string("boolean")]),
                    "visible_for_distribution": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("promoted_purchase_id")]),
            ])
        ),

        // Promoted purchase images
        Tool(
            name: "iap_promoted_purchase_images_list",
            description: "List images attached to a specific promoted purchase.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "promoted_purchase_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("promoted_purchase_id")]),
            ])
        ),
        Tool(
            name: "iap_promoted_purchase_images_upload",
            description: "Upload an image tied to a specific promoted purchase. Reserves a slot, uploads bytes, and confirms in one call.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "promoted_purchase_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("promoted_purchase_id"), .string("file_path")]),
            ])
        ),
        Tool(
            name: "iap_promoted_purchase_images_update",
            description: "PATCH metadata (rename) on a promoted purchase image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "promoted_purchase_image_id": .object(["type": .string("string")]),
                    "file_name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("promoted_purchase_image_id")]),
            ])
        ),
        Tool(
            name: "iap_promoted_purchase_images_delete",
            description: "Delete a promoted purchase image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "promoted_purchase_image_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("promoted_purchase_image_id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Routes any `iap_*` tool call to the appropriate handler. Returns a
    /// `CallTool.Result` with `isError: true` and the message in the text
    /// payload when the call fails for any reason - auth, network, ASC 4xx.
    package static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let client = try makeClient()
            let api = InAppPurchasesAPI(client: client)
            switch params.name {
            // Purchases
            case "iap_in_app_purchases_list":   return try await handleListPurchases(api, params)
            case "iap_in_app_purchases_get":    return try await handleGetPurchase(api, params)
            case "iap_in_app_purchases_create": return try await handleCreatePurchase(api, params)
            case "iap_in_app_purchases_update": return try await handleUpdatePurchase(api, params)
            case "iap_in_app_purchases_delete": return try await handleDeletePurchase(api, params)
            // Localizations
            case "iap_localizations_list":      return try await handleListLocalizations(api, params)
            case "iap_localizations_get":       return try await handleGetLocalization(api, params)
            case "iap_localizations_create":    return try await handleCreateLocalization(api, params)
            case "iap_localizations_update":    return try await handleUpdateLocalization(api, params)
            case "iap_localizations_delete":    return try await handleDeleteLocalization(api, params)
            // Price points
            case "iap_price_points_list":       return try await handleListPricePoints(api, params)
            case "iap_price_points_get":        return try await handleGetPricePoint(api, params)
            // Price schedule
            case "iap_price_schedule_get":      return try await handleGetPriceSchedule(api, params)
            case "iap_price_schedule_set":      return try await handleSetPriceSchedule(api, params)
            // Submissions
            case "iap_submission_list":         return try await handleListSubmissions(api, params)
            case "iap_submission_get":          return try await handleGetSubmission(api, params)
            case "iap_submission_create":      return try await handleCreateSubmission(api, params)
            // Content hosting
            case "iap_content_hosting_get":     return try await handleGetContentHosting(api, params)
            case "iap_content_hosting_update":  return try await handleUpdateContentHosting(api, params)
            // Images
            case "iap_images_list":             return try await handleListImages(api, params)
            case "iap_images_get":              return try await handleGetImage(api, params)
            case "iap_images_upload":           return try await handleUploadImage(api, params)
            case "iap_images_update":           return try await handleUpdateImage(api, params)
            case "iap_images_delete":           return try await handleDeleteImage(api, params)
            // Review screenshots
            case "iap_review_screenshot_get":    return try await handleGetReviewScreenshot(api, params)
            case "iap_review_screenshot_upload": return try await handleUploadReviewScreenshot(api, params)
            case "iap_review_screenshot_update": return try await handleUpdateReviewScreenshot(api, params)
            case "iap_review_screenshot_delete": return try await handleDeleteReviewScreenshot(api, params)
            // Promotional images
            case "iap_promotional_images_list":   return try await handleListPromotionalImages(api, params)
            case "iap_promotional_images_upload": return try await handleUploadPromotionalImage(api, params)
            case "iap_promotional_images_delete": return try await handleDeletePromotionalImage(api, params)
            // Promoted purchases
            case "iap_promoted_purchases_list":   return try await handleListPromotedPurchases(api, params)
            case "iap_promoted_purchases_update": return try await handleUpdatePromotedPurchase(api, params)
            // Promoted purchase images
            case "iap_promoted_purchase_images_list":   return try await handleListPromotedImages(api, params)
            case "iap_promoted_purchase_images_upload": return try await handleUploadPromotedImage(api, params)
            case "iap_promoted_purchase_images_update": return try await handleUpdatePromotedImage(api, params)
            case "iap_promoted_purchase_images_delete": return try await handleDeletePromotedImage(api, params)
            default:
                return errorResult("Unknown IAP tool: \(params.name)")
            }
        } catch let e as ASCClient.APIError {
            var msg = "App Store Connect error \(e.statusCode)"
            if !e.details.isEmpty {
                msg += "\n" + e.details.map { "[\($0.code)] \($0.title): \($0.detail)" }.joined(separator: "\n")
            } else if !e.rawBody.isEmpty {
                msg += "\n" + e.rawBody
            }
            return errorResult(msg)
        } catch {
            return errorResult("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Client construction

    private static func makeClient() throws -> ASCClient {
        let creds = try ASCCredentialResolver.resolve()
        return ASCClient(credentials: creds)
    }

    // MARK: - Purchases handlers

    private static func handleListPurchases(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue else {
            return errorResult("Missing required parameter: app_id")
        }
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue
        let page = try await api.purchases.list(appID: appID, limit: limit, cursor: cursor)
        return pageResult(nextCursor: page.nextCursor, items: page.items)
    }

    private static func handleGetPurchase(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let result = try await api.purchases.get(id: id)
        return jsonResult(result)
    }

    private static func handleCreatePurchase(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue,
              let name = params.arguments?["name"]?.stringValue,
              let productID = params.arguments?["product_id"]?.stringValue,
              let iapType = params.arguments?["in_app_purchase_type"]?.stringValue
        else {
            return errorResult("Missing required parameters: app_id, name, product_id, in_app_purchase_type")
        }
        let fields = InAppPurchasesAPI.Purchases.CreateFields(
            name: name,
            productID: productID,
            inAppPurchaseType: iapType,
            reviewNote: params.arguments?["review_note"]?.stringValue,
            familySharable: params.arguments?["family_sharable"]?.boolValue,
            availableInAllTerritories: params.arguments?["available_in_all_territories"]?.boolValue
        )
        let result = try await api.purchases.create(appID: appID, fields: fields)
        return jsonResult(result)
    }

    private static func handleUpdatePurchase(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let fields = InAppPurchasesAPI.Purchases.UpdateFields(
            name: params.arguments?["name"]?.stringValue,
            reviewNote: params.arguments?["review_note"]?.stringValue,
            familySharable: params.arguments?["family_sharable"]?.boolValue,
            availableInAllTerritories: params.arguments?["available_in_all_territories"]?.boolValue
        )
        let result = try await api.purchases.update(id: id, fields: fields)
        return jsonResult(result)
    }

    private static func handleDeletePurchase(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        try await api.purchases.delete(id: id)
        return jsonResult(["deleted": id])
    }

    // MARK: - Localization handlers

    private static func handleListLocalizations(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue
        let page = try await api.localizations.list(iapID: iapID, limit: limit, cursor: cursor)
        return pageResult(nextCursor: page.nextCursor, items: page.items)
    }

    private static func handleGetLocalization(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["localization_id"]?.stringValue else {
            return errorResult("Missing required parameter: localization_id")
        }
        let result = try await api.localizations.get(id: id)
        return jsonResult(result)
    }

    private static func handleCreateLocalization(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue,
              let locale = params.arguments?["locale"]?.stringValue,
              let name = params.arguments?["name"]?.stringValue
        else {
            return errorResult("Missing required parameters: iap_id, locale, name")
        }
        let description = params.arguments?["description"]?.stringValue
        let result = try await api.localizations.create(
            iapID: iapID, locale: locale, name: name, description: description
        )
        return jsonResult(result)
    }

    private static func handleUpdateLocalization(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["localization_id"]?.stringValue else {
            return errorResult("Missing required parameter: localization_id")
        }
        let fields = InAppPurchasesAPI.Localizations.UpdateFields(
            name: params.arguments?["name"]?.stringValue,
            description: params.arguments?["description"]?.stringValue
        )
        let result = try await api.localizations.update(id: id, fields: fields)
        return jsonResult(result)
    }

    private static func handleDeleteLocalization(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["localization_id"]?.stringValue else {
            return errorResult("Missing required parameter: localization_id")
        }
        try await api.localizations.delete(id: id)
        return jsonResult(["deleted": id])
    }

    // MARK: - Price point handlers

    private static func handleListPricePoints(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let territoryID = params.arguments?["territory_id"]?.stringValue
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue
        let page = try await api.pricePoints.list(
            iapID: iapID, territoryID: territoryID, limit: limit, cursor: cursor
        )
        return pageResult(nextCursor: page.nextCursor, items: page.items)
    }

    private static func handleGetPricePoint(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["price_point_id"]?.stringValue else {
            return errorResult("Missing required parameter: price_point_id")
        }
        let result = try await api.pricePoints.get(id: id)
        return jsonResult(result)
    }

    // MARK: - Price schedule handlers

    private static func handleGetPriceSchedule(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let result = try await api.priceSchedules.get(iapID: iapID)
        return jsonResult(result)
    }

    private static func handleSetPriceSchedule(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue,
              let baseTerritory = params.arguments?["base_territory_id"]?.stringValue,
              let pricesValue = params.arguments?["prices"]?.arrayValue
        else {
            return errorResult("Missing required parameters: iap_id, base_territory_id, prices")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let prices: [InAppPurchasesAPI.PriceSchedules.DesiredPrice] = pricesValue.compactMap { entry in
            guard let obj = entry.objectValue,
                  let ter = obj["territory_id"]?.stringValue,
                  let point = obj["price_point_id"]?.stringValue
            else { return nil }
            var start: Date? = nil
            if let s = obj["start_date"]?.stringValue {
                start = formatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            }
            return InAppPurchasesAPI.PriceSchedules.DesiredPrice(
                territoryID: ter, pricePointID: point, startDate: start
            )
        }
        let result = try await api.priceSchedules.set(
            iapID: iapID, baseTerritoryID: baseTerritory, prices: prices
        )
        return jsonResult(result)
    }

    // MARK: - Submission handlers

    private static func handleListSubmissions(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue
        let page = try await api.submissions.list(iapID: iapID, limit: limit, cursor: cursor)
        return pageResult(nextCursor: page.nextCursor, items: page.items)
    }

    private static func handleGetSubmission(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["submission_id"]?.stringValue else {
            return errorResult("Missing required parameter: submission_id")
        }
        let result = try await api.submissions.get(id: id)
        return jsonResult(result)
    }

    private static func handleCreateSubmission(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let result = try await api.submissions.create(iapID: iapID)
        return jsonResult(result)
    }

    // MARK: - Content hosting handlers

    private static func handleGetContentHosting(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let result = try await api.contentHostings.get(iapID: iapID)
        return jsonResult(result)
    }

    private static func handleUpdateContentHosting(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["content_hosting_id"]?.stringValue else {
            return errorResult("Missing required parameter: content_hosting_id")
        }
        let fields = InAppPurchasesAPI.ContentHostings.UpdateFields(
            fileName: params.arguments?["file_name"]?.stringValue
        )
        let result = try await api.contentHostings.update(id: id, fields: fields)
        return jsonResult(result)
    }

    // MARK: - Image handlers

    private static func handleListImages(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue
        let page = try await api.images.list(iapID: iapID, limit: limit, cursor: cursor)
        return pageResult(nextCursor: page.nextCursor, items: page.items)
    }

    private static func handleGetImage(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["image_id"]?.stringValue else {
            return errorResult("Missing required parameter: image_id")
        }
        let result = try await api.images.get(id: id)
        return jsonResult(result)
    }

    private static func handleUploadImage(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue,
              let path = params.arguments?["file_path"]?.stringValue
        else {
            return errorResult("Missing required parameters: iap_id, file_path")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let result = try await api.images.upload(iapID: iapID, fileURL: url)
        return jsonResult(result)
    }

    private static func handleUpdateImage(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["image_id"]?.stringValue else {
            return errorResult("Missing required parameter: image_id")
        }
        let fileName = params.arguments?["file_name"]?.stringValue
        let result = try await api.images.update(id: id, fileName: fileName)
        return jsonResult(result)
    }

    private static func handleDeleteImage(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["image_id"]?.stringValue else {
            return errorResult("Missing required parameter: image_id")
        }
        try await api.images.delete(id: id)
        return jsonResult(["deleted": id])
    }

    // MARK: - Review screenshot handlers

    private static func handleGetReviewScreenshot(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let result = try await api.reviewScreenshots.get(iapID: iapID)
        return jsonResult(result)
    }

    private static func handleUploadReviewScreenshot(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue,
              let path = params.arguments?["file_path"]?.stringValue
        else {
            return errorResult("Missing required parameters: iap_id, file_path")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let result = try await api.reviewScreenshots.upload(iapID: iapID, fileURL: url)
        return jsonResult(result)
    }

    private static func handleUpdateReviewScreenshot(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["review_screenshot_id"]?.stringValue else {
            return errorResult("Missing required parameter: review_screenshot_id")
        }
        let fileName = params.arguments?["file_name"]?.stringValue
        let result = try await api.reviewScreenshots.update(id: id, fileName: fileName)
        return jsonResult(result)
    }

    private static func handleDeleteReviewScreenshot(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["review_screenshot_id"]?.stringValue else {
            return errorResult("Missing required parameter: review_screenshot_id")
        }
        try await api.reviewScreenshots.delete(id: id)
        return jsonResult(["deleted": id])
    }

    // MARK: - Promotional image handlers

    private static func handleListPromotionalImages(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue else {
            return errorResult("Missing required parameter: iap_id")
        }
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue
        let page = try await api.promotionalImages.list(
            iapID: iapID, limit: limit, cursor: cursor
        )
        return pageResult(nextCursor: page.nextCursor, items: page.items)
    }

    private static func handleUploadPromotionalImage(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue,
              let path = params.arguments?["file_path"]?.stringValue
        else {
            return errorResult("Missing required parameters: iap_id, file_path")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let result = try await api.promotionalImages.upload(iapID: iapID, fileURL: url)
        return jsonResult(result)
    }

    private static func handleDeletePromotionalImage(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["promotional_image_id"]?.stringValue else {
            return errorResult("Missing required parameter: promotional_image_id")
        }
        try await api.promotionalImages.delete(id: id)
        return jsonResult(["deleted": id])
    }

    // MARK: - Promoted purchase handlers

    private static func handleListPromotedPurchases(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue else {
            return errorResult("Missing required parameter: app_id")
        }
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue
        let page = try await api.promotedPurchases.list(
            appID: appID, limit: limit, cursor: cursor
        )
        return pageResult(nextCursor: page.nextCursor, items: page.items)
    }

    private static func handleUpdatePromotedPurchase(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["promoted_purchase_id"]?.stringValue else {
            return errorResult("Missing required parameter: promoted_purchase_id")
        }
        let enabled = params.arguments?["enabled"]?.boolValue
        let visible = params.arguments?["visible_for_distribution"]?.boolValue
        let result = try await api.promotedPurchases.update(
            id: id, enabled: enabled, visibleForDistribution: visible
        )
        return jsonResult(result)
    }

    // MARK: - Promoted purchase image handlers

    private static func handleListPromotedImages(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let ppID = params.arguments?["promoted_purchase_id"]?.stringValue else {
            return errorResult("Missing required parameter: promoted_purchase_id")
        }
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue
        let page = try await api.promotedPurchaseImages.list(
            promotedPurchaseID: ppID, limit: limit, cursor: cursor
        )
        return pageResult(nextCursor: page.nextCursor, items: page.items)
    }

    private static func handleUploadPromotedImage(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let ppID = params.arguments?["promoted_purchase_id"]?.stringValue,
              let path = params.arguments?["file_path"]?.stringValue
        else {
            return errorResult("Missing required parameters: promoted_purchase_id, file_path")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let result = try await api.promotedPurchaseImages.upload(
            promotedPurchaseID: ppID, fileURL: url
        )
        return jsonResult(result)
    }

    private static func handleUpdatePromotedImage(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["promoted_purchase_image_id"]?.stringValue else {
            return errorResult("Missing required parameter: promoted_purchase_image_id")
        }
        let fileName = params.arguments?["file_name"]?.stringValue
        let result = try await api.promotedPurchaseImages.update(id: id, fileName: fileName)
        return jsonResult(result)
    }

    private static func handleDeletePromotedImage(
        _ api: InAppPurchasesAPI, _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        guard let id = params.arguments?["promoted_purchase_image_id"]?.stringValue else {
            return errorResult("Missing required parameter: promoted_purchase_image_id")
        }
        try await api.promotedPurchaseImages.delete(id: id)
        return jsonResult(["deleted": id])
    }

    // MARK: - Output helpers

    /// Encodable wrapper for paginated responses so the dict
    /// `["nextCursor": ..., "items": ...]` doesn't run into Swift's lack of
    /// heterogenous dictionary literals.
    private struct PageOutput<Item: Encodable>: Encodable {
        let nextCursor: String?
        let items: [Item]
    }

    private static func pageResult<Item: Encodable>(
        nextCursor: String?, items: [Item]
    ) -> CallTool.Result {
        jsonResult(PageOutput(nextCursor: nextCursor, items: items))
    }

    /// Encodes the value as pretty-printed JSON inside a single text content
    /// block, with `isError: false`. Nil values render as `null`, matching the
    /// JSON shape Apple returns.
    private static func jsonResult<Value: Encodable>(_ value: Value) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let body: String
        do {
            let data = try encoder.encode(value)
            body = String(data: data, encoding: .utf8) ?? "null"
        } catch {
            body = "\"encoding failed: \(error.localizedDescription)\""
        }
        return .init(content: [.text(body)], isError: false)
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(message)], isError: true)
    }
}
