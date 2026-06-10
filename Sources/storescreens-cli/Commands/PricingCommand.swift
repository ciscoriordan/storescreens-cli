import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens pricing` - manage an app's App Store price schedule:
/// free, a single paid tier, or true per-territory pricing.
///
/// Prices are plain local-currency amounts (no symbol). `4.99` with
/// `--base-territory USA` means US$4.99; `--territory JPN=600` means ¥600.
/// Each amount snaps to the nearest valid App Store price tier for that
/// territory, since Apple's tiers are a fixed ladder rather than free-form.
///
/// Subcommand layout:
///   storescreens pricing get          - show the current schedule
///   storescreens pricing set          - free | single paid tier | per-territory
///   storescreens pricing price-points - list valid tiers for a territory
struct PricingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pricing",
        abstract: "Get or set an app's price schedule (free, paid, or per-territory).",
        discussion: """
            Requires `storescreens auth login` (or ASC_KEY_ID / ASC_ISSUER_ID / \
            ASC_KEY_PATH env vars).

            Prices are local-currency amounts with no symbol: 4.99 in USA means \
            US$4.99, 600 in JPN means ¥600. Every amount snaps to the nearest \
            valid App Store price tier for that territory. `set` replaces the \
            app's entire price schedule; territories you don't list are \
            equivalenced from the base price.
            """,
        subcommands: [
            PricingGetCommand.self,
            PricingSetCommand.self,
            PricingPricePointsCommand.self,
        ]
    )
}

// MARK: - Shared helpers (file-private)

private func makePricingAPI() throws -> PricingAvailabilityAPI {
    let logger = Logger()
    do {
        let creds = try ASCCredentialResolver.resolve()
        return PricingAvailabilityAPI(client: ASCClient(credentials: creds))
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
}

private func printPricingJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "null")
}

private func runPricing(_ body: () async throws -> Void) async throws {
    let logger = Logger()
    do {
        try await body()
    } catch let err as ASCClient.APIError {
        logger.log("App Store Connect error: HTTP \(err.statusCode)", level: .error)
        for d in err.details {
            print("  [\(d.code)] \(d.title): \(d.detail)")
        }
        throw ExitCode(1)
    } catch let exit as ExitCode {
        throw exit
    } catch {
        logger.log("\(error)", level: .error)
        throw ExitCode(1)
    }
}

/// Formats a resolved amount without spurious decimals: 600.0 -> "600",
/// 4.99 -> "4.99". Used only for display.
private func money(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
}

// MARK: - get

struct PricingGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show the app's current price schedule (base territory + per-territory prices)."
    )

    @Option(name: .long, help: "App Store Connect app id (numeric).") var appId: String
    @Flag(name: .long, help: "Emit JSON instead of human-readable text.") var json: Bool = false

    func run() async throws {
        try await runPricing {
            let api = try makePricingAPI()
            guard let details = try await api.getPriceScheduleDetails(appID: appId) else {
                if json { print("null"); return }
                Logger().log("no price schedule on file for app \(appId)", level: .warning)
                print("  set one with `storescreens pricing set --app-id \(appId) ...`")
                return
            }
            if json { try printPricingJSON(details); return }

            Logger().header("Price schedule for app \(appId)")
            print("  schedule id:    \(details.scheduleID)")
            print("  base territory: \(details.baseTerritory ?? "?")")
            if details.manualPrices.isEmpty {
                print("  manual prices:  (none - every territory equivalenced from base)")
            } else {
                print("  manual prices (\(details.manualPrices.count)):")
                for p in details.manualPrices {
                    print("    \(p.territory)  customer=\(p.customerPrice ?? "?")  proceeds=\(p.proceeds ?? "?")")
                }
            }
        }
    }
}

// MARK: - set

struct PricingSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the app's price schedule: free, a single paid tier, or per-territory.",
        discussion: """
            Replaces the app's entire price schedule. Pass either --free or \
            --base-price; add repeated --territory CODE=AMOUNT pairs for \
            per-territory overrides (paid only). Amounts are local-currency \
            and snap to the nearest valid tier.

            Examples:
              storescreens pricing set --app-id 12345 --free
              storescreens pricing set --app-id 12345 --base-price 4.99
              storescreens pricing set --app-id 12345 --base-price 4.99 \\
                --territory GBR=3.99 JPN=600
            """
    )

    @Option(name: .long, help: "App Store Connect app id (numeric).") var appId: String
    @Option(name: .long, help: "Base territory for equivalencing, ISO 3166-1 alpha-3 (default USA).")
    var baseTerritory: String = "USA"
    @Flag(name: .long, help: "Make the app free everywhere.") var free: Bool = false
    @Option(name: .long, help: "Paid base price in the base territory's currency, e.g. 4.99.")
    var basePrice: String?
    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Per-territory overrides as CODE=AMOUNT (repeatable), e.g. --territory GBR=3.99 JPN=600."
    )
    var territory: [String] = []
    @Flag(name: .long, help: "Emit JSON instead of human-readable text.") var json: Bool = false

    func validate() throws {
        if free && basePrice != nil {
            throw ValidationError("pass either --free or --base-price, not both")
        }
        if !free && basePrice == nil {
            throw ValidationError("pass --free or --base-price <amount>")
        }
        if free && !territory.isEmpty {
            throw ValidationError("--territory overrides can't be combined with --free")
        }
    }

    struct SetResult: Encodable {
        let scheduleID: String
        let baseTerritory: String
        let free: Bool
        let resolutions: [PricingAvailabilityAPI.PricingPlan.Resolution]
    }

    func run() async throws {
        try await runPricing {
            let api = try makePricingAPI()

            let baseAmount: Double
            var overrides: [String: Double] = [:]
            if free {
                baseAmount = 0
            } else {
                guard let amount = Double(basePrice ?? "") else {
                    Logger().log("--base-price '\(basePrice ?? "")' is not a number", level: .error)
                    throw ExitCode(1)
                }
                baseAmount = amount
                for entry in territory {
                    let parts = entry.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2, let amt = Double(parts[1]) else {
                        Logger().log("malformed --territory '\(entry)'; expected CODE=AMOUNT (e.g. GBR=3.99)", level: .error)
                        throw ExitCode(1)
                    }
                    overrides[String(parts[0])] = amt
                }
            }

            let plan = try await api.resolvePricing(
                appID: appId,
                baseTerritory: baseTerritory,
                basePrice: baseAmount,
                territoryPrices: overrides
            )
            let result = try await api.createPriceSchedule(
                appID: appId, baseTerritoryID: baseTerritory, manualPrices: plan.manualPrices
            )

            if json {
                try printPricingJSON(SetResult(
                    scheduleID: result.id,
                    baseTerritory: baseTerritory,
                    free: free,
                    resolutions: plan.resolutions
                ))
                return
            }

            let kind = free ? "free" : "paid"
            Logger().log(
                "set price schedule \(result.id): \(kind), base \(baseTerritory), \(plan.manualPrices.count) manual price(s)",
                level: .success
            )
            for r in plan.resolutions {
                let note = r.isExact ? "" : "  (requested \(money(r.requested)), snapped to nearest tier)"
                print("  \(r.territory)  \(money(r.actual))\(note)")
            }
            print("  territories not listed are equivalenced from \(baseTerritory).")
        }
    }
}

// MARK: - price-points

struct PricingPricePointsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "price-points",
        abstract: "List valid price tiers for a territory, or find the nearest tier to an amount."
    )

    @Option(name: .long, help: "App Store Connect app id (numeric).") var appId: String
    @Option(name: .long, help: "Territory id, ISO 3166-1 alpha-3 (e.g. USA).") var territory: String
    @Option(name: .long, help: "Show only the nearest valid tier to this local-currency amount, e.g. 4.99.")
    var around: String?
    @Option(name: .long, help: "Max tiers to list when not using --around (default 50, cheapest first).")
    var limit: Int = 50
    @Flag(name: .long, help: "Emit JSON instead of human-readable text.") var json: Bool = false

    struct NearestResult: Encodable {
        let territory: String
        let requested: Double
        let actual: Double
        let isExact: Bool
        let pricePointID: String
        let proceeds: String?
    }

    func run() async throws {
        try await runPricing {
            let api = try makePricingAPI()

            if let around {
                guard let target = Double(around) else {
                    Logger().log("--around '\(around)' is not a number", level: .error)
                    throw ExitCode(1)
                }
                guard let r = try await api.findPricePoint(
                    appID: appId, territoryID: territory, targetPrice: target
                ) else {
                    Logger().log("no price points available in \(territory)", level: .warning)
                    return
                }
                if json {
                    try printPricingJSON(NearestResult(
                        territory: territory,
                        requested: target,
                        actual: r.actual,
                        isExact: r.isExact,
                        pricePointID: r.point.id,
                        proceeds: r.point.attributes?.proceeds
                    ))
                    return
                }
                Logger().header("Nearest tier in \(territory) to \(around)")
                print("  customer price: \(r.point.attributes?.customerPrice ?? "?")\(r.isExact ? "" : "  (nearest, not exact)")")
                print("  proceeds:       \(r.point.attributes?.proceeds ?? "?")")
                print("  price point id: \(r.point.id)")
                return
            }

            let (points, _) = try await api.listAppPricePoints(
                appID: appId, territoryID: territory, limit: limit
            )
            if json { try printPricingJSON(points); return }
            Logger().header("Price points for app \(appId) in \(territory) (cheapest \(points.count))")
            if points.isEmpty {
                print("  (none)")
            } else {
                for p in points {
                    print("  \(p.id)  customer=\(p.attributes?.customerPrice ?? "?")  proceeds=\(p.attributes?.proceeds ?? "?")")
                }
            }
        }
    }
}
