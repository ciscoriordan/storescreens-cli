import MCP
import Foundation
import StorescreensCore

/// MCP tool surface for the App Store Connect auto-renewable subscriptions
/// API. Each Apple resource (subscriptionGroups, subscriptions,
/// subscriptionLocalizations, etc.) gets a small family of tools named
/// `subs_<resource>_<op>` so agents can issue ASC subscription workflows
/// without constructing raw HTTP.
///
/// Every tool here:
///   - resolves credentials via ASCCredentialResolver.resolve()
///   - returns pretty-printed JSON in the text content on success
///   - returns isError: true with a human-readable message on failure
///
/// Wire this into Main.swift by appending `SubscriptionsMCPTools.tools` to
/// the static tool list and forwarding any tool whose name starts with
/// `subs_` to `SubscriptionsMCPTools.handle`.
package enum SubscriptionsMCPTools {

    // MARK: - Public surface

    /// Every subscription tool the MCP server exposes. Order is mostly
    /// alphabetical by resource so editors can find related tools quickly.
    package static let tools: [Tool] = [
        // Groups
        groupsListTool,
        groupsGetTool,
        groupsCreateTool,
        groupsUpdateTool,
        groupsDeleteTool,
        // Group localizations
        groupLocalizationsListTool,
        groupLocalizationsCreateTool,
        groupLocalizationsUpdateTool,
        groupLocalizationsDeleteTool,
        // Subscriptions
        subscriptionsListTool,
        subscriptionsGetTool,
        subscriptionsCreateTool,
        subscriptionsUpdateTool,
        subscriptionsDeleteTool,
        // Localizations
        localizationsListTool,
        localizationsCreateTool,
        localizationsUpdateTool,
        localizationsDeleteTool,
        // Prices
        pricesListTool,
        pricesCreateTool,
        pricesDeleteTool,
        // Price points
        pricePointsListTool,
        // Offer codes
        offerCodesListTool,
        offerCodesGetTool,
        offerCodesCreateTool,
        offerCodesUpdateTool,
        offerCodesDeleteTool,
        // One-time-use codes
        offerCodesOneTimeListTool,
        offerCodesOneTimeCreateTool,
        // Custom codes
        offerCodesCustomListTool,
        offerCodesCustomCreateTool,
        offerCodesCustomDeleteTool,
        // Offer code prices
        offerCodePricesListTool,
        offerCodePricesCreateTool,
        // Promotional offers
        promotionalOffersListTool,
        promotionalOffersGetTool,
        promotionalOffersCreateTool,
        promotionalOffersUpdateTool,
        promotionalOffersDeleteTool,
        // Promotional offer prices
        promotionalOfferPricesListTool,
        promotionalOfferPricesCreateTool,
        // Availability
        availabilityGetTool,
        availabilityUpdateTool,
        // Submissions
        submissionsListTool,
        submissionsGetTool,
        submissionsCreateTool,
        // Review screenshots
        reviewScreenshotsListTool,
        reviewScreenshotsGetTool,
        reviewScreenshotsCreateTool,
        reviewScreenshotsConfirmTool,
        reviewScreenshotsDeleteTool,
        // Images
        imagesListTool,
        imagesCreateTool,
        imagesDeleteTool,
    ]

    /// Dispatch handler. Pass any tool name returned by `tools.map(\.name)`.
    /// Unknown names return isError so callers can detect routing mistakes.
    package static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            switch params.name {
            // Groups
            case "subs_groups_list":              return try await handleGroupsList(params)
            case "subs_groups_get":               return try await handleGroupsGet(params)
            case "subs_groups_create":            return try await handleGroupsCreate(params)
            case "subs_groups_update":            return try await handleGroupsUpdate(params)
            case "subs_groups_delete":            return try await handleGroupsDelete(params)
            // Group localizations
            case "subs_group_localizations_list":   return try await handleGroupLocalizationsList(params)
            case "subs_group_localizations_create": return try await handleGroupLocalizationsCreate(params)
            case "subs_group_localizations_update": return try await handleGroupLocalizationsUpdate(params)
            case "subs_group_localizations_delete": return try await handleGroupLocalizationsDelete(params)
            // Subscriptions
            case "subs_subscriptions_list":   return try await handleSubscriptionsList(params)
            case "subs_subscriptions_get":    return try await handleSubscriptionsGet(params)
            case "subs_subscriptions_create": return try await handleSubscriptionsCreate(params)
            case "subs_subscriptions_update": return try await handleSubscriptionsUpdate(params)
            case "subs_subscriptions_delete": return try await handleSubscriptionsDelete(params)
            // Localizations
            case "subs_localizations_list":   return try await handleLocalizationsList(params)
            case "subs_localizations_create": return try await handleLocalizationsCreate(params)
            case "subs_localizations_update": return try await handleLocalizationsUpdate(params)
            case "subs_localizations_delete": return try await handleLocalizationsDelete(params)
            // Prices
            case "subs_prices_list":          return try await handlePricesList(params)
            case "subs_prices_create":        return try await handlePricesCreate(params)
            case "subs_prices_delete":        return try await handlePricesDelete(params)
            // Price points
            case "subs_price_points_list":    return try await handlePricePointsList(params)
            // Offer codes
            case "subs_offer_codes_list":   return try await handleOfferCodesList(params)
            case "subs_offer_codes_get":    return try await handleOfferCodesGet(params)
            case "subs_offer_codes_create": return try await handleOfferCodesCreate(params)
            case "subs_offer_codes_update": return try await handleOfferCodesUpdate(params)
            case "subs_offer_codes_delete": return try await handleOfferCodesDelete(params)
            // One-time-use codes
            case "subs_offer_codes_one_time_list":   return try await handleOfferCodesOneTimeList(params)
            case "subs_offer_codes_one_time_create": return try await handleOfferCodesOneTimeCreate(params)
            // Custom codes
            case "subs_offer_codes_custom_list":   return try await handleOfferCodesCustomList(params)
            case "subs_offer_codes_custom_create": return try await handleOfferCodesCustomCreate(params)
            case "subs_offer_codes_custom_delete": return try await handleOfferCodesCustomDelete(params)
            // Offer code prices
            case "subs_offer_code_prices_list":   return try await handleOfferCodePricesList(params)
            case "subs_offer_code_prices_create": return try await handleOfferCodePricesCreate(params)
            // Promotional offers
            case "subs_promotional_offers_list":   return try await handlePromotionalOffersList(params)
            case "subs_promotional_offers_get":    return try await handlePromotionalOffersGet(params)
            case "subs_promotional_offers_create": return try await handlePromotionalOffersCreate(params)
            case "subs_promotional_offers_update": return try await handlePromotionalOffersUpdate(params)
            case "subs_promotional_offers_delete": return try await handlePromotionalOffersDelete(params)
            // Promotional offer prices
            case "subs_promotional_offer_prices_list":   return try await handlePromotionalOfferPricesList(params)
            case "subs_promotional_offer_prices_create": return try await handlePromotionalOfferPricesCreate(params)
            // Availability
            case "subs_availability_get":    return try await handleAvailabilityGet(params)
            case "subs_availability_update": return try await handleAvailabilityUpdate(params)
            // Submissions
            case "subs_submissions_list":   return try await handleSubmissionsList(params)
            case "subs_submissions_get":    return try await handleSubmissionsGet(params)
            case "subs_submissions_create": return try await handleSubmissionsCreate(params)
            // Review screenshots
            case "subs_review_screenshots_list":    return try await handleReviewScreenshotsList(params)
            case "subs_review_screenshots_get":     return try await handleReviewScreenshotsGet(params)
            case "subs_review_screenshots_create":  return try await handleReviewScreenshotsCreate(params)
            case "subs_review_screenshots_confirm": return try await handleReviewScreenshotsConfirm(params)
            case "subs_review_screenshots_delete":  return try await handleReviewScreenshotsDelete(params)
            // Images
            case "subs_images_list":   return try await handleImagesList(params)
            case "subs_images_create": return try await handleImagesCreate(params)
            case "subs_images_delete": return try await handleImagesDelete(params)
            default:
                return .init(content: [.text("Unknown subscriptions tool: \(params.name)")], isError: true)
            }
        } catch let e as ASCClient.APIError {
            return .init(content: [.text("ASC error \(e.statusCode):\n\(e.description)")], isError: true)
        } catch {
            return .init(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

    // MARK: - Shared helpers

    /// Resolves ASC credentials and returns a ready-to-use SubscriptionsAPI.
    /// Surfaces a clean error tool result if credentials are missing.
    private static func makeAPI() throws -> SubscriptionsAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return SubscriptionsAPI(client: client)
    }

    /// Pretty-prints any Encodable as JSON text in a CallTool.Result.
    private static func ok<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let str = String(data: data, encoding: .utf8) ?? "{}"
        return .init(content: [.text(str)], isError: false)
    }

    /// Reusable: builds the standard input schema for a list tool. Always
    /// allows `limit` (int) and `cursor` (string); merges in any
    /// resource-specific required ids.
    private static func listSchema(
        requiredKeys: [String] = [],
        extraProperties: [String: Value] = [:]
    ) -> Value {
        var props: [String: Value] = [
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Page size (default: 200, max: 200)."),
            ]),
            "cursor": .object([
                "type": .string("string"),
                "description": .string("Pagination cursor from a previous response's nextCursor."),
            ]),
        ]
        for (k, v) in extraProperties { props[k] = v }
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(props),
        ]
        if !requiredKeys.isEmpty {
            schema["required"] = .array(requiredKeys.map { .string($0) })
        }
        return .object(schema)
    }

    /// Pulls a required string arg or throws a clear error.
    private static func required(_ params: CallTool.Parameters, _ key: String) throws -> String {
        guard let v = params.arguments?[key]?.stringValue else {
            throw RequiredArgMissing(key: key)
        }
        return v
    }

    private static func optionalString(_ params: CallTool.Parameters, _ key: String) -> String? {
        params.arguments?[key]?.stringValue
    }

    private static func optionalInt(_ params: CallTool.Parameters, _ key: String) -> Int? {
        if let i = params.arguments?[key]?.intValue { return i }
        if let s = params.arguments?[key]?.stringValue { return Int(s) }
        return nil
    }

    private static func optionalBool(_ params: CallTool.Parameters, _ key: String) -> Bool? {
        params.arguments?[key]?.boolValue
    }

    private static func stringArray(_ params: CallTool.Parameters, _ key: String) -> [String] {
        guard let arr = params.arguments?[key]?.arrayValue else { return [] }
        return arr.compactMap { $0.stringValue }
    }

    private struct RequiredArgMissing: Error, CustomStringConvertible {
        let key: String
        var description: String { "missing required argument: \(key)" }
    }

    // MARK: - Tool definitions: Groups

    private static let groupsListTool = Tool(
        name: "subs_groups_list",
        description: "List subscription groups under an app. Paginated.",
        inputSchema: listSchema(requiredKeys: ["app_id"], extraProperties: [
            "app_id": .object(["type": .string("string"), "description": .string("Numeric ASC app id.")]),
        ])
    )
    private static let groupsGetTool = Tool(
        name: "subs_groups_get",
        description: "Fetch a single subscription group by id. Returns null if not found.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string"), "description": .string("subscriptionGroup id")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let groupsCreateTool = Tool(
        name: "subs_groups_create",
        description: "Create a new subscription group under an app. Returns the new group.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "app_id": .object(["type": .string("string")]),
                "reference_name": .object(["type": .string("string"), "description": .string("Internal name shown only in ASC.")]),
            ]),
            "required": .array([.string("app_id"), .string("reference_name")]),
        ])
    )
    private static let groupsUpdateTool = Tool(
        name: "subs_groups_update",
        description: "Update the reference name on a subscription group.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "reference_name": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id"), .string("reference_name")]),
        ])
    )
    private static let groupsDeleteTool = Tool(
        name: "subs_groups_delete",
        description: "Delete a subscription group. Fails if subscriptions still exist in the group.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Group localizations tool defs

    private static let groupLocalizationsListTool = Tool(
        name: "subs_group_localizations_list",
        description: "List per-locale group localizations for a subscription group.",
        inputSchema: listSchema(requiredKeys: ["group_id"], extraProperties: [
            "group_id": .object(["type": .string("string")]),
        ])
    )
    private static let groupLocalizationsCreateTool = Tool(
        name: "subs_group_localizations_create",
        description: "Add a new per-locale group localization (display name on the subscription-management screen).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "group_id": .object(["type": .string("string")]),
                "locale": .object(["type": .string("string"), "description": .string("e.g. en-US")]),
                "name": .object(["type": .string("string")]),
                "custom_app_name": .object(["type": .string("string"), "description": .string("Optional override of the app name in this locale.")]),
            ]),
            "required": .array([.string("group_id"), .string("locale"), .string("name")]),
        ])
    )
    private static let groupLocalizationsUpdateTool = Tool(
        name: "subs_group_localizations_update",
        description: "Update display name + optional custom app name on a group localization.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "custom_app_name": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let groupLocalizationsDeleteTool = Tool(
        name: "subs_group_localizations_delete",
        description: "Delete a group localization.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Subscriptions tool defs

    private static let subscriptionsListTool = Tool(
        name: "subs_subscriptions_list",
        description: "List subscriptions in a group. Paginated.",
        inputSchema: listSchema(requiredKeys: ["group_id"], extraProperties: [
            "group_id": .object(["type": .string("string")]),
        ])
    )
    private static let subscriptionsGetTool = Tool(
        name: "subs_subscriptions_get",
        description: "Fetch a single subscription. Returns null if not found.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let subscriptionsCreateTool = Tool(
        name: "subs_subscriptions_create",
        description: "Create a subscription inside a group. Returns the new subscription.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "group_id": .object(["type": .string("string")]),
                "product_id": .object(["type": .string("string"), "description": .string("Reverse-DNS StoreKit identifier.")]),
                "name": .object(["type": .string("string"), "description": .string("Developer label shown in ASC.")]),
                "subscription_period": .object(["type": .string("string"), "description": .string("ONE_WEEK, ONE_MONTH, TWO_MONTHS, THREE_MONTHS, SIX_MONTHS, ONE_YEAR.")]),
                "group_level": .object(["type": .string("integer"), "description": .string("Position within the group; lower numbers shown first.")]),
                "review_note": .object(["type": .string("string"), "description": .string("Optional note to App Review.")]),
            ]),
            "required": .array([
                .string("group_id"), .string("product_id"), .string("name"),
                .string("subscription_period"), .string("group_level"),
            ]),
        ])
    )
    private static let subscriptionsUpdateTool = Tool(
        name: "subs_subscriptions_update",
        description: "Update mutable fields on a subscription (name, group_level, review_note).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "group_level": .object(["type": .string("integer")]),
                "review_note": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let subscriptionsDeleteTool = Tool(
        name: "subs_subscriptions_delete",
        description: "Delete a subscription. Only allowed before it's been published to the App Store.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Localizations tool defs

    private static let localizationsListTool = Tool(
        name: "subs_localizations_list",
        description: "List per-locale localizations for a subscription.",
        inputSchema: listSchema(requiredKeys: ["subscription_id"], extraProperties: [
            "subscription_id": .object(["type": .string("string")]),
        ])
    )
    private static let localizationsCreateTool = Tool(
        name: "subs_localizations_create",
        description: "Create a per-locale name + description for a subscription.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subscription_id": .object(["type": .string("string")]),
                "locale": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "description": .object(["type": .string("string"), "description": .string("Optional.")]),
            ]),
            "required": .array([.string("subscription_id"), .string("locale"), .string("name")]),
        ])
    )
    private static let localizationsUpdateTool = Tool(
        name: "subs_localizations_update",
        description: "Update a subscription localization. Nil fields stay untouched.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "description": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let localizationsDeleteTool = Tool(
        name: "subs_localizations_delete",
        description: "Delete a subscription localization.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Prices tool defs

    private static let pricesListTool = Tool(
        name: "subs_prices_list",
        description: "List per-territory prices for a subscription.",
        inputSchema: listSchema(requiredKeys: ["subscription_id"], extraProperties: [
            "subscription_id": .object(["type": .string("string")]),
            "territory_id": .object(["type": .string("string"), "description": .string("Optional ISO 3166-1 alpha-3 filter (e.g. USA).")]),
        ])
    )
    private static let pricesCreateTool = Tool(
        name: "subs_prices_create",
        description: "Create a per-territory price for a subscription. Prices are immutable once set, so a 'price change' is create-new + delete-old.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subscription_id": .object(["type": .string("string")]),
                "price_point_id": .object(["type": .string("string"), "description": .string("From subs_price_points_list")]),
                "territory_id": .object(["type": .string("string"), "description": .string("ISO 3166-1 alpha-3, e.g. USA.")]),
                "start_date": .object(["type": .string("string"), "description": .string("Optional ISO-8601 effective date.")]),
                "preserve_current_price": .object(["type": .string("boolean"), "description": .string("True to grandfather existing subscribers onto the old price.")]),
            ]),
            "required": .array([.string("subscription_id"), .string("price_point_id"), .string("territory_id")]),
        ])
    )
    private static let pricesDeleteTool = Tool(
        name: "subs_prices_delete",
        description: "Delete a per-territory price record.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Price points tool defs

    private static let pricePointsListTool = Tool(
        name: "subs_price_points_list",
        description: "List Apple's valid price points for a subscription in a single territory. Read-only catalog.",
        inputSchema: listSchema(requiredKeys: ["subscription_id", "territory_id"], extraProperties: [
            "subscription_id": .object(["type": .string("string")]),
            "territory_id": .object(["type": .string("string")]),
        ])
    )

    // MARK: - Offer codes tool defs

    private static let offerCodesListTool = Tool(
        name: "subs_offer_codes_list",
        description: "List offer-code programs for a subscription.",
        inputSchema: listSchema(requiredKeys: ["subscription_id"], extraProperties: [
            "subscription_id": .object(["type": .string("string")]),
        ])
    )
    private static let offerCodesGetTool = Tool(
        name: "subs_offer_codes_get",
        description: "Fetch a single offer code by id.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let offerCodesCreateTool = Tool(
        name: "subs_offer_codes_create",
        description: "Create a new offer-code program against a subscription.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subscription_id": .object(["type": .string("string")]),
                "reference_name": .object(["type": .string("string")]),
                "offer_type": .object(["type": .string("string"), "description": .string("FREE_TRIAL | PAY_AS_YOU_GO | PAY_UP_FRONT")]),
                "duration": .object(["type": .string("string"), "description": .string("e.g. ONE_MONTH")]),
                "number_of_periods": .object(["type": .string("integer"), "description": .string("Required for PAY_AS_YOU_GO.")]),
                "customer_eligibilities": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Subset of NEW, EXISTING, EXPIRED."),
                ]),
                "total_number_of_codes": .object(["type": .string("integer"), "description": .string("Optional cap on total redemptions.")]),
            ]),
            "required": .array([
                .string("subscription_id"), .string("reference_name"), .string("offer_type"),
                .string("duration"), .string("customer_eligibilities"),
            ]),
        ])
    )
    private static let offerCodesUpdateTool = Tool(
        name: "subs_offer_codes_update",
        description: "Update reference_name or is_active on an offer code.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "reference_name": .object(["type": .string("string")]),
                "is_active": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let offerCodesDeleteTool = Tool(
        name: "subs_offer_codes_delete",
        description: "Delete an offer code (only allowed before redemption).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - One-time-use codes tool defs

    private static let offerCodesOneTimeListTool = Tool(
        name: "subs_offer_codes_one_time_list",
        description: "List batches of one-time-use codes for an offer code program.",
        inputSchema: listSchema(requiredKeys: ["offer_code_id"], extraProperties: [
            "offer_code_id": .object(["type": .string("string")]),
        ])
    )
    private static let offerCodesOneTimeCreateTool = Tool(
        name: "subs_offer_codes_one_time_create",
        description: "Generate a batch of unique single-use codes. Apple processes asynchronously.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "offer_code_id": .object(["type": .string("string")]),
                "number_of_codes": .object(["type": .string("integer")]),
                "expiration_date": .object(["type": .string("string"), "description": .string("Optional ISO-8601 expiration.")]),
            ]),
            "required": .array([.string("offer_code_id"), .string("number_of_codes")]),
        ])
    )

    // MARK: - Custom codes tool defs

    private static let offerCodesCustomListTool = Tool(
        name: "subs_offer_codes_custom_list",
        description: "List custom-string codes for an offer code program.",
        inputSchema: listSchema(requiredKeys: ["offer_code_id"], extraProperties: [
            "offer_code_id": .object(["type": .string("string")]),
        ])
    )
    private static let offerCodesCustomCreateTool = Tool(
        name: "subs_offer_codes_custom_create",
        description: "Create a custom-string redemption code (e.g. 'BLACKFRIDAY2025').",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "offer_code_id": .object(["type": .string("string")]),
                "custom_code": .object(["type": .string("string"), "description": .string("Code string customers will type.")]),
                "number_of_codes": .object(["type": .string("integer"), "description": .string("Cap on total redemptions for this string.")]),
                "expiration_date": .object(["type": .string("string"), "description": .string("Optional ISO-8601 expiration.")]),
            ]),
            "required": .array([.string("offer_code_id"), .string("custom_code"), .string("number_of_codes")]),
        ])
    )
    private static let offerCodesCustomDeleteTool = Tool(
        name: "subs_offer_codes_custom_delete",
        description: "Delete a custom code.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Offer code prices tool defs

    private static let offerCodePricesListTool = Tool(
        name: "subs_offer_code_prices_list",
        description: "List per-territory pricing for an offer code.",
        inputSchema: listSchema(requiredKeys: ["offer_code_id"], extraProperties: [
            "offer_code_id": .object(["type": .string("string")]),
        ])
    )
    private static let offerCodePricesCreateTool = Tool(
        name: "subs_offer_code_prices_create",
        description: "Attach a per-territory price to an offer code.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "offer_code_id": .object(["type": .string("string")]),
                "price_point_id": .object(["type": .string("string")]),
                "territory_id": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("offer_code_id"), .string("price_point_id"), .string("territory_id"),
            ]),
        ])
    )

    // MARK: - Promotional offers tool defs

    private static let promotionalOffersListTool = Tool(
        name: "subs_promotional_offers_list",
        description: "List promotional offers (intro pricing) for a subscription.",
        inputSchema: listSchema(requiredKeys: ["subscription_id"], extraProperties: [
            "subscription_id": .object(["type": .string("string")]),
        ])
    )
    private static let promotionalOffersGetTool = Tool(
        name: "subs_promotional_offers_get",
        description: "Fetch a single promotional offer.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let promotionalOffersCreateTool = Tool(
        name: "subs_promotional_offers_create",
        description: "Create a promotional intro offer (e.g. 'first month free') for a subscription.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subscription_id": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "offer_code": .object(["type": .string("string"), "description": .string("Reverse-DNS id StoreKit uses to target this offer.")]),
                "offer_type": .object(["type": .string("string"), "description": .string("FREE_TRIAL | PAY_AS_YOU_GO | PAY_UP_FRONT")]),
                "duration": .object(["type": .string("string")]),
                "number_of_periods": .object(["type": .string("integer")]),
            ]),
            "required": .array([
                .string("subscription_id"), .string("name"), .string("offer_code"),
                .string("offer_type"), .string("duration"),
            ]),
        ])
    )
    private static let promotionalOffersUpdateTool = Tool(
        name: "subs_promotional_offers_update",
        description: "Update the display name of a promotional offer.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let promotionalOffersDeleteTool = Tool(
        name: "subs_promotional_offers_delete",
        description: "Delete a promotional offer (only allowed before publication).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Promotional offer prices tool defs

    private static let promotionalOfferPricesListTool = Tool(
        name: "subs_promotional_offer_prices_list",
        description: "List per-territory prices on a promotional offer.",
        inputSchema: listSchema(requiredKeys: ["promotional_offer_id"], extraProperties: [
            "promotional_offer_id": .object(["type": .string("string")]),
        ])
    )
    private static let promotionalOfferPricesCreateTool = Tool(
        name: "subs_promotional_offer_prices_create",
        description: "Attach a per-territory price to a promotional offer.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "promotional_offer_id": .object(["type": .string("string")]),
                "price_point_id": .object(["type": .string("string")]),
                "territory_id": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("promotional_offer_id"), .string("price_point_id"), .string("territory_id"),
            ]),
        ])
    )

    // MARK: - Availability tool defs

    private static let availabilityGetTool = Tool(
        name: "subs_availability_get",
        description: "Fetch the current territory availability for a subscription.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subscription_id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("subscription_id")]),
        ])
    )
    private static let availabilityUpdateTool = Tool(
        name: "subs_availability_update",
        description: "Replace the subscription's territory list. ASC interprets the list as exhaustive.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subscription_id": .object(["type": .string("string")]),
                "territory_ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Full list of ISO 3166-1 alpha-3 territory codes to make available."),
                ]),
                "available_in_new_territories": .object([
                    "type": .string("boolean"),
                    "description": .string("Auto-enroll into new Apple territories?"),
                ]),
            ]),
            "required": .array([
                .string("subscription_id"), .string("territory_ids"), .string("available_in_new_territories"),
            ]),
        ])
    )

    // MARK: - Submissions tool defs

    private static let submissionsListTool = Tool(
        name: "subs_submissions_list",
        description: "List subscription submissions (App Review history) for a subscription.",
        inputSchema: listSchema(requiredKeys: ["subscription_id"], extraProperties: [
            "subscription_id": .object(["type": .string("string")]),
        ])
    )
    private static let submissionsGetTool = Tool(
        name: "subs_submissions_get",
        description: "Fetch a single subscription submission.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let submissionsCreateTool = Tool(
        name: "subs_submissions_create",
        description: "Submit pending subscription metadata edits for App Review.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subscription_id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("subscription_id")]),
        ])
    )

    // MARK: - Review screenshots tool defs

    private static let reviewScreenshotsListTool = Tool(
        name: "subs_review_screenshots_list",
        description: "List review-only screenshots attached to a subscription.",
        inputSchema: listSchema(requiredKeys: ["subscription_id"], extraProperties: [
            "subscription_id": .object(["type": .string("string")]),
        ])
    )
    private static let reviewScreenshotsGetTool = Tool(
        name: "subs_review_screenshots_get",
        description: "Fetch a single review screenshot (includes uploadOperations until uploaded).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )
    private static let reviewScreenshotsCreateTool = Tool(
        name: "subs_review_screenshots_create",
        description: "Reserve a slot for a new review screenshot. The returned record has uploadOperations the caller PUTs the chunks to.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subscription_id": .object(["type": .string("string")]),
                "file_name": .object(["type": .string("string")]),
                "file_size": .object(["type": .string("integer")]),
            ]),
            "required": .array([
                .string("subscription_id"), .string("file_name"), .string("file_size"),
            ]),
        ])
    )
    private static let reviewScreenshotsConfirmTool = Tool(
        name: "subs_review_screenshots_confirm",
        description: "Mark a review screenshot uploaded after PUTting its chunks. checksum is MD5 of the file bytes.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "checksum": .object(["type": .string("string"), "description": .string("Hex MD5 of the uploaded file bytes.")]),
            ]),
            "required": .array([.string("id"), .string("checksum")]),
        ])
    )
    private static let reviewScreenshotsDeleteTool = Tool(
        name: "subs_review_screenshots_delete",
        description: "Delete a review screenshot.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Images tool defs

    private static let imagesListTool = Tool(
        name: "subs_images_list",
        description: "List promotional images attached to a subscription.",
        inputSchema: listSchema(requiredKeys: ["subscription_id"], extraProperties: [
            "subscription_id": .object(["type": .string("string")]),
        ])
    )
    private static let imagesCreateTool = Tool(
        name: "subs_images_create",
        description: "Reserve a slot for a new promotional image. uploadOperations returned for the binary PUT step.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subscription_id": .object(["type": .string("string")]),
                "file_name": .object(["type": .string("string")]),
                "file_size": .object(["type": .string("integer")]),
            ]),
            "required": .array([
                .string("subscription_id"), .string("file_name"), .string("file_size"),
            ]),
        ])
    )
    private static let imagesDeleteTool = Tool(
        name: "subs_images_delete",
        description: "Delete a promotional image.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Page envelope (encodable)

    /// JSON shape returned for paginated tool calls. Matches the
    /// SubscriptionsAPI.Page contract: an `items` array plus an optional
    /// `next_cursor` string callers feed back into the next call.
    private struct PageEnvelope<Item: Encodable>: Encodable {
        let items: [Item]
        let next_cursor: String?
    }

    private static func envelope<Item: Encodable>(_ page: SubscriptionsAPI.Page<Item>) -> PageEnvelope<Item> {
        PageEnvelope(items: page.items, next_cursor: page.nextCursor)
    }

    // MARK: - Handlers: Groups

    private static func handleGroupsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let appID = try required(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.groups.list(appID: appID, limit: limit, cursor: cursor)
        return try ok(envelope(page))
    }
    private static func handleGroupsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        let group = try await api.groups.get(id: id)
        return try ok(group)
    }
    private static func handleGroupsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let appID = try required(params, "app_id")
        let referenceName = try required(params, "reference_name")
        let api = try makeAPI()
        let group = try await api.groups.create(appID: appID, referenceName: referenceName)
        return try ok(group)
    }
    private static func handleGroupsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let referenceName = try required(params, "reference_name")
        let api = try makeAPI()
        let group = try await api.groups.update(id: id, referenceName: referenceName)
        return try ok(group)
    }
    private static func handleGroupsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.groups.delete(id: id)
        return .init(content: [.text("deleted subscriptionGroup \(id)")], isError: false)
    }

    // MARK: - Handlers: Group localizations

    private static func handleGroupLocalizationsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let groupID = try required(params, "group_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.groups.listLocalizations(groupID: groupID, limit: limit, cursor: cursor)
        return try ok(envelope(page))
    }
    private static func handleGroupLocalizationsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let groupID = try required(params, "group_id")
        let locale = try required(params, "locale")
        let name = try required(params, "name")
        let customAppName = optionalString(params, "custom_app_name")
        let api = try makeAPI()
        let loc = try await api.groupLocalizations.create(
            groupID: groupID, locale: locale, name: name, customAppName: customAppName
        )
        return try ok(loc)
    }
    private static func handleGroupLocalizationsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let name = optionalString(params, "name")
        let customAppName = optionalString(params, "custom_app_name")
        let api = try makeAPI()
        let loc = try await api.groupLocalizations.update(id: id, name: name, customAppName: customAppName)
        return try ok(loc)
    }
    private static func handleGroupLocalizationsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.groupLocalizations.delete(id: id)
        return .init(content: [.text("deleted subscriptionGroupLocalization \(id)")], isError: false)
    }

    // MARK: - Handlers: Subscriptions

    private static func handleSubscriptionsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let groupID = try required(params, "group_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.groups.listSubscriptions(groupID: groupID, limit: limit, cursor: cursor)
        return try ok(envelope(page))
    }
    private static func handleSubscriptionsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        let sub = try await api.subscriptions.get(id: id)
        return try ok(sub)
    }
    private static func handleSubscriptionsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let groupID = try required(params, "group_id")
        let productId = try required(params, "product_id")
        let name = try required(params, "name")
        let period = try required(params, "subscription_period")
        guard let groupLevel = optionalInt(params, "group_level") else {
            throw RequiredArgMissing(key: "group_level")
        }
        let reviewNote = optionalString(params, "review_note")
        let api = try makeAPI()
        let sub = try await api.subscriptions.create(
            groupID: groupID,
            productId: productId,
            name: name,
            subscriptionPeriod: period,
            groupLevel: groupLevel,
            reviewNote: reviewNote
        )
        return try ok(sub)
    }
    private static func handleSubscriptionsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let name = optionalString(params, "name")
        let groupLevel = optionalInt(params, "group_level")
        let reviewNote = optionalString(params, "review_note")
        let api = try makeAPI()
        let sub = try await api.subscriptions.update(
            id: id, name: name, groupLevel: groupLevel, reviewNote: reviewNote
        )
        return try ok(sub)
    }
    private static func handleSubscriptionsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.subscriptions.delete(id: id)
        return .init(content: [.text("deleted subscription \(id)")], isError: false)
    }

    // MARK: - Handlers: Localizations

    private static func handleLocalizationsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.subscriptions.listLocalizations(
            subscriptionID: subscriptionID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handleLocalizationsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let locale = try required(params, "locale")
        let name = try required(params, "name")
        let description = optionalString(params, "description")
        let api = try makeAPI()
        let loc = try await api.localizations.create(
            subscriptionID: subscriptionID, locale: locale, name: name, description: description
        )
        return try ok(loc)
    }
    private static func handleLocalizationsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let name = optionalString(params, "name")
        let description = optionalString(params, "description")
        let api = try makeAPI()
        let loc = try await api.localizations.update(id: id, name: name, description: description)
        return try ok(loc)
    }
    private static func handleLocalizationsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.localizations.delete(id: id)
        return .init(content: [.text("deleted subscriptionLocalization \(id)")], isError: false)
    }

    // MARK: - Handlers: Prices

    private static func handlePricesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let territory = optionalString(params, "territory_id")
        let api = try makeAPI()
        let page = try await api.prices.list(
            subscriptionID: subscriptionID, limit: limit, cursor: cursor, filterTerritory: territory
        )
        return try ok(envelope(page))
    }
    private static func handlePricesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let pricePointID = try required(params, "price_point_id")
        let territoryID = try required(params, "territory_id")
        let startDate: Date? = optionalString(params, "start_date").flatMap { Self.iso8601.date(from: $0) }
        let preserve = optionalBool(params, "preserve_current_price")
        let api = try makeAPI()
        let price = try await api.prices.create(
            subscriptionID: subscriptionID,
            pricePointID: pricePointID,
            territoryID: territoryID,
            startDate: startDate,
            preserveCurrentPrice: preserve
        )
        return try ok(price)
    }
    private static func handlePricesDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.prices.delete(id: id)
        return .init(content: [.text("deleted subscriptionPrice \(id)")], isError: false)
    }

    // MARK: - Handlers: Price points

    private static func handlePricePointsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let territoryID = try required(params, "territory_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.pricePoints.list(
            subscriptionID: subscriptionID, territoryID: territoryID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }

    // MARK: - Handlers: Offer codes

    private static func handleOfferCodesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.offerCodes.list(
            subscriptionID: subscriptionID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handleOfferCodesGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        return try ok(try await api.offerCodes.get(id: id))
    }
    private static func handleOfferCodesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let referenceName = try required(params, "reference_name")
        let offerType = try required(params, "offer_type")
        let duration = try required(params, "duration")
        let numberOfPeriods = optionalInt(params, "number_of_periods")
        let eligibilities = stringArray(params, "customer_eligibilities")
        if eligibilities.isEmpty {
            throw RequiredArgMissing(key: "customer_eligibilities")
        }
        let total = optionalInt(params, "total_number_of_codes")
        let api = try makeAPI()
        let offer = try await api.offerCodes.create(
            subscriptionID: subscriptionID,
            referenceName: referenceName,
            offerType: offerType,
            duration: duration,
            numberOfPeriods: numberOfPeriods,
            customerEligibilities: eligibilities,
            totalNumberOfCodes: total
        )
        return try ok(offer)
    }
    private static func handleOfferCodesUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let referenceName = optionalString(params, "reference_name")
        let isActive = optionalBool(params, "is_active")
        let api = try makeAPI()
        let offer = try await api.offerCodes.update(id: id, referenceName: referenceName, isActive: isActive)
        return try ok(offer)
    }
    private static func handleOfferCodesDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.offerCodes.delete(id: id)
        return .init(content: [.text("deleted subscriptionOfferCode \(id)")], isError: false)
    }

    // MARK: - Handlers: One-time-use codes

    private static func handleOfferCodesOneTimeList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let offerCodeID = try required(params, "offer_code_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.offerCodeOneTimeUseCodes.list(
            offerCodeID: offerCodeID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handleOfferCodesOneTimeCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let offerCodeID = try required(params, "offer_code_id")
        guard let count = optionalInt(params, "number_of_codes") else {
            throw RequiredArgMissing(key: "number_of_codes")
        }
        let expiration: Date? = optionalString(params, "expiration_date").flatMap { Self.iso8601.date(from: $0) }
        let api = try makeAPI()
        let batch = try await api.offerCodeOneTimeUseCodes.create(
            offerCodeID: offerCodeID, numberOfCodes: count, expirationDate: expiration
        )
        return try ok(batch)
    }

    // MARK: - Handlers: Custom codes

    private static func handleOfferCodesCustomList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let offerCodeID = try required(params, "offer_code_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.offerCodeCustomCodes.list(
            offerCodeID: offerCodeID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handleOfferCodesCustomCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let offerCodeID = try required(params, "offer_code_id")
        let customCode = try required(params, "custom_code")
        guard let count = optionalInt(params, "number_of_codes") else {
            throw RequiredArgMissing(key: "number_of_codes")
        }
        let expiration: Date? = optionalString(params, "expiration_date").flatMap { Self.iso8601.date(from: $0) }
        let api = try makeAPI()
        let code = try await api.offerCodeCustomCodes.create(
            offerCodeID: offerCodeID,
            customCode: customCode,
            numberOfCodes: count,
            expirationDate: expiration
        )
        return try ok(code)
    }
    private static func handleOfferCodesCustomDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.offerCodeCustomCodes.delete(id: id)
        return .init(content: [.text("deleted subscriptionOfferCodeCustomCode \(id)")], isError: false)
    }

    // MARK: - Handlers: Offer code prices

    private static func handleOfferCodePricesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let offerCodeID = try required(params, "offer_code_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.offerCodePrices.list(
            offerCodeID: offerCodeID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handleOfferCodePricesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let offerCodeID = try required(params, "offer_code_id")
        let pricePointID = try required(params, "price_point_id")
        let territoryID = try required(params, "territory_id")
        let api = try makeAPI()
        let p = try await api.offerCodePrices.create(
            offerCodeID: offerCodeID, pricePointID: pricePointID, territoryID: territoryID
        )
        return try ok(p)
    }

    // MARK: - Handlers: Promotional offers

    private static func handlePromotionalOffersList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.promotionalOffers.list(
            subscriptionID: subscriptionID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handlePromotionalOffersGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        return try ok(try await api.promotionalOffers.get(id: id))
    }
    private static func handlePromotionalOffersCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let name = try required(params, "name")
        let offerCode = try required(params, "offer_code")
        let offerType = try required(params, "offer_type")
        let duration = try required(params, "duration")
        let numberOfPeriods = optionalInt(params, "number_of_periods")
        let api = try makeAPI()
        let offer = try await api.promotionalOffers.create(
            subscriptionID: subscriptionID,
            name: name,
            offerCode: offerCode,
            offerType: offerType,
            duration: duration,
            numberOfPeriods: numberOfPeriods
        )
        return try ok(offer)
    }
    private static func handlePromotionalOffersUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let name = optionalString(params, "name")
        let api = try makeAPI()
        let offer = try await api.promotionalOffers.update(id: id, name: name)
        return try ok(offer)
    }
    private static func handlePromotionalOffersDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.promotionalOffers.delete(id: id)
        return .init(content: [.text("deleted subscriptionPromotionalOffer \(id)")], isError: false)
    }

    // MARK: - Handlers: Promotional offer prices

    private static func handlePromotionalOfferPricesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let promoID = try required(params, "promotional_offer_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.promotionalOfferPrices.list(
            promotionalOfferID: promoID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handlePromotionalOfferPricesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let promoID = try required(params, "promotional_offer_id")
        let pricePointID = try required(params, "price_point_id")
        let territoryID = try required(params, "territory_id")
        let api = try makeAPI()
        let p = try await api.promotionalOfferPrices.create(
            promotionalOfferID: promoID, pricePointID: pricePointID, territoryID: territoryID
        )
        return try ok(p)
    }

    // MARK: - Handlers: Availability

    private static func handleAvailabilityGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let api = try makeAPI()
        return try ok(try await api.availabilities.get(subscriptionID: subscriptionID))
    }
    private static func handleAvailabilityUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let territoryIDs = stringArray(params, "territory_ids")
        if territoryIDs.isEmpty {
            throw RequiredArgMissing(key: "territory_ids")
        }
        guard let available = optionalBool(params, "available_in_new_territories") else {
            throw RequiredArgMissing(key: "available_in_new_territories")
        }
        let api = try makeAPI()
        let result = try await api.availabilities.update(
            subscriptionID: subscriptionID,
            territoryIDs: territoryIDs,
            availableInNewTerritories: available
        )
        return try ok(result)
    }

    // MARK: - Handlers: Submissions

    private static func handleSubmissionsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.submissions.list(
            subscriptionID: subscriptionID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handleSubmissionsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        return try ok(try await api.submissions.get(id: id))
    }
    private static func handleSubmissionsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let api = try makeAPI()
        let sub = try await api.submissions.create(subscriptionID: subscriptionID)
        return try ok(sub)
    }

    // MARK: - Handlers: Review screenshots

    private static func handleReviewScreenshotsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.reviewScreenshots.list(
            subscriptionID: subscriptionID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handleReviewScreenshotsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        return try ok(try await api.reviewScreenshots.get(id: id))
    }
    private static func handleReviewScreenshotsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let fileName = try required(params, "file_name")
        guard let fileSize = optionalInt(params, "file_size") else {
            throw RequiredArgMissing(key: "file_size")
        }
        let api = try makeAPI()
        let shot = try await api.reviewScreenshots.create(
            subscriptionID: subscriptionID, fileName: fileName, fileSize: fileSize
        )
        return try ok(shot)
    }
    private static func handleReviewScreenshotsConfirm(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let checksum = try required(params, "checksum")
        let api = try makeAPI()
        let shot = try await api.reviewScreenshots.confirmUpload(id: id, checksum: checksum)
        return try ok(shot)
    }
    private static func handleReviewScreenshotsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.reviewScreenshots.delete(id: id)
        return .init(content: [.text("deleted subscriptionAppStoreReviewScreenshot \(id)")], isError: false)
    }

    // MARK: - Handlers: Images

    private static func handleImagesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let api = try makeAPI()
        let page = try await api.images.list(
            subscriptionID: subscriptionID, limit: limit, cursor: cursor
        )
        return try ok(envelope(page))
    }
    private static func handleImagesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let subscriptionID = try required(params, "subscription_id")
        let fileName = try required(params, "file_name")
        guard let fileSize = optionalInt(params, "file_size") else {
            throw RequiredArgMissing(key: "file_size")
        }
        let api = try makeAPI()
        let img = try await api.images.create(
            subscriptionID: subscriptionID, fileName: fileName, fileSize: fileSize
        )
        return try ok(img)
    }
    private static func handleImagesDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let id = try required(params, "id")
        let api = try makeAPI()
        try await api.images.delete(id: id)
        return .init(content: [.text("deleted subscriptionImage \(id)")], isError: false)
    }

    // MARK: - Date plumbing

    /// Permissive ISO-8601 parser. ASC commonly emits dates with fractional
    /// seconds (e.g. "2026-04-25T12:34:56.123Z"), so we use the parser that
    /// accepts both.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
