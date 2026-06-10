import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for App Store Connect app-level pricing (the "Pricing"
/// half of the Pricing and Availability screen). Mirrors the pricing methods
/// on `PricingAvailabilityAPI` so an agent can read and set an app's price
/// schedule - free, a single paid tier, or true per-territory pricing -
/// without crafting raw ASC requests.
///
/// Prices are local-currency amounts (no symbol). 4.99 in USA means US$4.99;
/// 600 in JPN means ¥600. Each amount snaps to the nearest valid App Store
/// price tier for that territory. Tools resolve credentials via
/// `ASCCredentialResolver.resolve()` and return pretty-printed JSON in one
/// `.text` block, with `isError: true` on failure. Names use the `pricing_`
/// prefix so `Main.swift` routes them here.
package enum PricingMCPTools {

    // MARK: - Tool catalog

    package static let tools: [Tool] = [
        Tool(
            name: "pricing_get",
            description: """
            Show an app's current App Store price schedule: the base territory \
            and every manually set per-territory price (territory code, \
            customer price, proceeds). Territories not listed are \
            equivalenced from the base price. Returns null when the app has \
            no price schedule yet.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id (numeric string)."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "pricing_set",
            description: """
            Set (replace) an app's price schedule. Provide EITHER free=true \
            for a free app, OR base_price for a paid app. base_price is the \
            price in the base territory's local currency (no symbol), e.g. \
            "4.99". Add territory_prices for per-territory overrides: an \
            object mapping ISO 3166-1 alpha-3 codes to local-currency amounts, \
            e.g. {"GBR": "3.99", "JPN": "600"}. Every amount snaps to the \
            nearest valid App Store tier; the response reports what each \
            request resolved to. Territories absent from territory_prices are \
            equivalenced from the base price.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id (numeric string)."),
                    ]),
                    "free": .object([
                        "type": .string("boolean"),
                        "description": .string("True to make the app free everywhere. Mutually exclusive with base_price."),
                    ]),
                    "base_price": .object([
                        "type": .string("string"),
                        "description": .string("Paid base price in the base territory's local currency, e.g. \"4.99\". Mutually exclusive with free."),
                    ]),
                    "base_territory": .object([
                        "type": .string("string"),
                        "description": .string("Base territory for equivalencing, ISO 3166-1 alpha-3. Default USA."),
                    ]),
                    "territory_prices": .object([
                        "type": .string("object"),
                        "description": .string("Per-territory overrides: object of ISO alpha-3 code -> local-currency amount string, e.g. {\"GBR\":\"3.99\",\"JPN\":\"600\"}. Paid apps only."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "pricing_price_points_list",
            description: """
            List an app's valid price tiers for one territory (cheapest \
            first), or - with `around` set - return just the single tier \
            nearest a given amount. Use this to discover what prices are \
            valid before calling pricing_set, since App Store prices are a \
            fixed ladder rather than free-form.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id (numeric string)."),
                    ]),
                    "territory": .object([
                        "type": .string("string"),
                        "description": .string("Territory id, ISO 3166-1 alpha-3 (e.g. \"USA\", \"GBR\", \"JPN\")."),
                    ]),
                    "around": .object([
                        "type": .string("string"),
                        "description": .string("Optional local-currency amount, e.g. \"4.99\". When set, returns only the nearest valid tier."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Max tiers to list when `around` is not set. Default 50."),
                    ]),
                ]),
                "required": .array([.string("app_id"), .string("territory")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    package static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        switch params.name {
        case "pricing_get":                 return await handleGet(params)
        case "pricing_set":                 return await handleSet(params)
        case "pricing_price_points_list":   return await handlePricePoints(params)
        default:
            return errorResult("Unknown pricing tool: \(params.name)")
        }
    }

    // MARK: - Handlers

    static func handleGet(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        do {
            let api = try makeAPI()
            guard let details = try await api.getPriceScheduleDetails(appID: appID) else {
                return jsonResult(NoSchedule(appId: appID))
            }
            return jsonResult(details)
        } catch {
            return errorResult("pricing_get failed: \(error)")
        }
    }

    static func handleSet(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        let free = params.arguments?["free"]?.boolValue ?? false
        let basePriceRaw = params.arguments?["base_price"]?.stringValue
            ?? params.arguments?["base_price"]?.doubleValue.map { String($0) }
        let baseTerritory = params.arguments?["base_territory"]?.stringValue ?? "USA"

        if free && basePriceRaw != nil {
            return errorResult("Provide either free=true or base_price, not both")
        }
        if !free && basePriceRaw == nil {
            return errorResult("Provide free=true or a base_price (e.g. \"4.99\")")
        }

        // Resolve the base amount and any per-territory overrides.
        let baseAmount: Double
        var overrides: [String: Double] = [:]
        if free {
            baseAmount = 0
            if params.arguments?["territory_prices"]?.objectValue?.isEmpty == false {
                return errorResult("territory_prices can't be combined with free=true")
            }
        } else {
            guard let amount = basePriceRaw.flatMap(Double.init) else {
                return errorResult("base_price \"\(basePriceRaw ?? "")\" is not a number")
            }
            baseAmount = amount
            if let map = params.arguments?["territory_prices"]?.objectValue {
                for (code, value) in map {
                    let amt = value.doubleValue ?? value.stringValue.flatMap(Double.init)
                    guard let amt else {
                        return errorResult("territory_prices[\(code)] is not a number")
                    }
                    overrides[code] = amt
                }
            }
        }

        do {
            let api = try makeAPI()
            let plan = try await api.resolvePricing(
                appID: appID, baseTerritory: baseTerritory, basePrice: baseAmount, territoryPrices: overrides
            )
            let result = try await api.createPriceSchedule(
                appID: appID, baseTerritoryID: baseTerritory, manualPrices: plan.manualPrices
            )
            return jsonResult(SetResult(
                scheduleID: result.id,
                baseTerritory: baseTerritory,
                free: free,
                resolutions: plan.resolutions
            ))
        } catch {
            return errorResult("pricing_set failed: \(error)")
        }
    }

    static func handlePricePoints(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        guard let territory = params.arguments?["territory"]?.stringValue, !territory.isEmpty else {
            return errorResult("Missing required parameter: territory")
        }
        let aroundRaw = params.arguments?["around"]?.stringValue
            ?? params.arguments?["around"]?.doubleValue.map { String($0) }
        let limit = params.arguments?["limit"]?.intValue ?? 50

        do {
            let api = try makeAPI()
            if let aroundRaw {
                guard let target = Double(aroundRaw) else {
                    return errorResult("around \"\(aroundRaw)\" is not a number")
                }
                guard let r = try await api.findPricePoint(
                    appID: appID, territoryID: territory, targetPrice: target
                ) else {
                    return errorResult("no price points available in \(territory)")
                }
                return jsonResult(NearestResult(
                    territory: territory,
                    requested: target,
                    actual: r.actual,
                    isExact: r.isExact,
                    pricePointID: r.point.id,
                    customerPrice: r.point.attributes?.customerPrice,
                    proceeds: r.point.attributes?.proceeds
                ))
            }
            let (points, nextCursor) = try await api.listAppPricePoints(
                appID: appID, territoryID: territory, limit: limit
            )
            return jsonResult(PointsResult(
                territory: territory,
                points: points.map(PointJSON.init),
                nextCursor: nextCursor
            ))
        } catch {
            return errorResult("pricing_price_points_list failed: \(error)")
        }
    }

    // MARK: - JSON shapes

    struct NoSchedule: Encodable {
        let appId: String
        let hasSchedule = false
    }

    struct SetResult: Encodable {
        let scheduleID: String
        let baseTerritory: String
        let free: Bool
        let resolutions: [PricingAvailabilityAPI.PricingPlan.Resolution]
    }

    struct NearestResult: Encodable {
        let territory: String
        let requested: Double
        let actual: Double
        let isExact: Bool
        let pricePointID: String
        let customerPrice: String?
        let proceeds: String?
    }

    struct PointsResult: Encodable {
        let territory: String
        let points: [PointJSON]
        let nextCursor: String?
    }

    struct PointJSON: Encodable {
        let id: String
        let customerPrice: String?
        let proceeds: String?

        init(_ p: PricingAvailabilityAPI.PricePoint) {
            self.id = p.id
            self.customerPrice = p.attributes?.customerPrice
            self.proceeds = p.attributes?.proceeds
        }
    }

    // MARK: - Helpers

    static func makeAPI() throws -> PricingAvailabilityAPI {
        let creds = try ASCCredentialResolver.resolve()
        return PricingAvailabilityAPI(client: ASCClient(credentials: creds))
    }

    static func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
