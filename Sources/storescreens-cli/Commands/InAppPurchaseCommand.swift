import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens iap` — manages App Store Connect In-App Purchases (V2).
///
/// Wraps the IAP V2 API surface so callers can manage IAPs without
/// constructing raw HTTP requests. Each subcommand maps to one operation
/// on one resource family; `--json` on every subcommand emits the raw JSON
/// response instead of the human-readable summary.
///
/// Subcommand layout:
///   storescreens iap purchases  list | get | create | update | delete
///   storescreens iap localizations list | get | create | update | delete
///   storescreens iap price-points list | get
///   storescreens iap pricing  get | set
///   storescreens iap submission list | get | create
///   storescreens iap content-hosting get | update
///   storescreens iap images list | get | upload | update | delete
///   storescreens iap review-screenshot get | upload | update | delete
///   storescreens iap promotional-images list | upload | delete
///   storescreens iap promoted-purchases list | update
///   storescreens iap promoted-images list | upload | update | delete
struct InAppPurchaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iap",
        abstract: "Manage App Store Connect in-app purchases (V2 API).",
        discussion: """
            Requires `storescreens auth login` (or ASC_KEY_ID / ASC_ISSUER_ID / \
            ASC_KEY_PATH env vars).

            Covers one-time IAPs: consumable, non-consumable, non-renewing \
            subscription. Auto-renewing subscriptions live under a different \
            resource family and are NOT handled here.
            """,
        subcommands: [
            IAPPurchasesCommand.self,
            IAPLocalizationsCommand.self,
            IAPPricePointsCommand.self,
            IAPPricingCommand.self,
            IAPSubmissionCommand.self,
            IAPContentHostingCommand.self,
            IAPImagesCommand.self,
            IAPReviewScreenshotCommand.self,
            IAPPromotionalImagesCommand.self,
            IAPPromotedPurchasesCommand.self,
            IAPPromotedImagesCommand.self,
        ]
    )
}

// MARK: - Shared utility helpers

/// Resolve ASC credentials and return a configured client. Throws ExitCode(1)
/// with a friendly message if credentials are missing or unusable.
private func makeIAPClient() throws -> ASCClient {
    let logger = Logger()
    do {
        let creds = try ASCCredentialResolver.resolve()
        return ASCClient(credentials: creds)
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
}

/// Pretty-prints any Encodable value as JSON. Used when `--json` is passed.
private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "null")
}

/// Wraps an ASCClient call so errors get printed nicely rather than dumping
/// the raw APIError description through ArgumentParser's catch-all.
private func runWithErrorHandling(_ body: () async throws -> Void) async throws {
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

// MARK: - Purchases

struct IAPPurchasesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purchases",
        abstract: "Manage the parent IAP resources on an app.",
        subcommands: [
            IAPPurchasesListCommand.self,
            IAPPurchasesGetCommand.self,
            IAPPurchasesCreateCommand.self,
            IAPPurchasesUpdateCommand.self,
            IAPPurchasesDeleteCommand.self,
        ]
    )
}

struct IAPPurchasesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List IAPs on an app.")

    @Option(name: .long, help: "App Store Connect app id (numeric).")
    var appID: String

    @Option(name: .long, help: "Page size (default 200).")
    var limit: Int = 200

    @Option(name: .long, help: "Opaque pagination cursor from a prior response.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let page = try await api.purchases.list(appID: appID, limit: limit, cursor: cursor)
            if json {
                try printJSON(MCPPageOutput(nextCursor: page.nextCursor, items: page.items))
                return
            }
            Logger().header("IAPs for app \(appID)")
            if page.items.isEmpty {
                print("  (none)")
            } else {
                for p in page.items {
                    let pid = p.attributes?.productId ?? "(no product id)"
                    let type = p.attributes?.inAppPurchaseType ?? "?"
                    let state = p.attributes?.state ?? "?"
                    print("  \(p.id)  \(pid)  \(type)  \(state)")
                }
                if let next = page.nextCursor {
                    print("\n  next cursor: \(next)")
                }
            }
        }
    }
}

struct IAPPurchasesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a single IAP.")

    @Option(name: .long, help: "inAppPurchases resource id.")
    var iapID: String

    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.purchases.get(id: iapID)
            if json { try printJSON(result); return }
            if let p = result {
                Logger().header("IAP \(p.id)")
                print("  name:       \(p.attributes?.name ?? "(none)")")
                print("  product id: \(p.attributes?.productId ?? "(none)")")
                print("  type:       \(p.attributes?.inAppPurchaseType ?? "?")")
                print("  state:      \(p.attributes?.state ?? "?")")
            } else {
                Logger().log("not found", level: .warning)
            }
        }
    }
}

struct IAPPurchasesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new IAP under an app.")

    @Option(name: .long, help: "App Store Connect app id.")
    var appID: String

    @Option(name: .long, help: "Internal reference name (not customer-facing).")
    var name: String

    @Option(name: .long, help: "Bundle-scoped product id, e.g. com.acme.pro_unlock.")
    var productID: String

    @Option(name: .long, help: "CONSUMABLE | NON_CONSUMABLE | NON_RENEWING_SUBSCRIPTION.")
    var inAppPurchaseType: String

    @Option(name: .long, help: "Optional review notes for Apple.")
    var reviewNote: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Whether the IAP is shared with the user's family.")
    var familySharable: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Whether available in every territory.")
    var availableInAllTerritories: Bool?

    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let fields = InAppPurchasesAPI.Purchases.CreateFields(
                name: name,
                productID: productID,
                inAppPurchaseType: inAppPurchaseType,
                reviewNote: reviewNote,
                familySharable: familySharable,
                availableInAllTerritories: availableInAllTerritories
            )
            let result = try await api.purchases.create(appID: appID, fields: fields)
            if json { try printJSON(result); return }
            Logger().log("created IAP \(result.id) (\(result.attributes?.productId ?? "?"))", level: .success)
        }
    }
}

struct IAPPurchasesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH an IAP.")

    @Option(name: .long, help: "IAP resource id.")
    var iapID: String

    @Option(name: .long, help: "New internal name.") var name: String?
    @Option(name: .long, help: "New review note.") var reviewNote: String?

    @Flag(name: .long, inversion: .prefixedNo) var familySharable: Bool?
    @Flag(name: .long, inversion: .prefixedNo) var availableInAllTerritories: Bool?

    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let fields = InAppPurchasesAPI.Purchases.UpdateFields(
                name: name,
                reviewNote: reviewNote,
                familySharable: familySharable,
                availableInAllTerritories: availableInAllTerritories
            )
            let result = try await api.purchases.update(id: iapID, fields: fields)
            if json { try printJSON(result); return }
            Logger().log("updated IAP \(result.id)", level: .success)
        }
    }
}

struct IAPPurchasesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an IAP.")

    @Option(name: .long, help: "IAP resource id.")
    var iapID: String

    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            try await api.purchases.delete(id: iapID)
            if json { print("{\"deleted\":\"\(iapID)\"}"); return }
            Logger().log("deleted IAP \(iapID)", level: .success)
        }
    }
}

// MARK: - Localizations

struct IAPLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localizations",
        abstract: "Manage per-locale display fields on an IAP.",
        subcommands: [
            IAPLocalizationsListCommand.self,
            IAPLocalizationsGetCommand.self,
            IAPLocalizationsCreateCommand.self,
            IAPLocalizationsUpdateCommand.self,
            IAPLocalizationsDeleteCommand.self,
        ]
    )
}

struct IAPLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List localizations on an IAP.")

    @Option(name: .long) var iapID: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let page = try await api.localizations.list(iapID: iapID, limit: limit, cursor: cursor)
            if json {
                try printJSON(MCPPageOutput(nextCursor: page.nextCursor, items: page.items))
                return
            }
            Logger().header("Localizations for IAP \(iapID)")
            if page.items.isEmpty {
                print("  (none)")
            } else {
                for loc in page.items {
                    let locale = loc.attributes?.locale ?? "?"
                    let name = loc.attributes?.name ?? "(no name)"
                    print("  \(loc.id)  \(locale)  \(name)")
                }
            }
        }
    }
}

struct IAPLocalizationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a single localization.")

    @Option(name: .long) var localizationID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.localizations.get(id: localizationID)
            if json { try printJSON(result); return }
            if let loc = result {
                Logger().header("Localization \(loc.id)")
                print("  locale:      \(loc.attributes?.locale ?? "?")")
                print("  name:        \(loc.attributes?.name ?? "(none)")")
                print("  description: \(loc.attributes?.description ?? "(none)")")
            } else {
                Logger().log("not found", level: .warning)
            }
        }
    }
}

struct IAPLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a localization for an IAP.")

    @Option(name: .long) var iapID: String
    @Option(name: .long, help: "e.g. en-US, ja, de-DE.") var locale: String
    @Option(name: .long, help: "Customer-facing name in this locale.") var name: String
    @Option(name: .long, help: "Customer-facing description.") var description: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.localizations.create(
                iapID: iapID, locale: locale, name: name, description: description
            )
            if json { try printJSON(result); return }
            Logger().log("created localization \(result.id) (\(locale))", level: .success)
        }
    }
}

struct IAPLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH a localization.")

    @Option(name: .long) var localizationID: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var description: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let fields = InAppPurchasesAPI.Localizations.UpdateFields(
                name: name, description: description
            )
            let result = try await api.localizations.update(id: localizationID, fields: fields)
            if json { try printJSON(result); return }
            Logger().log("updated localization \(result.id)", level: .success)
        }
    }
}

struct IAPLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a localization.")

    @Option(name: .long) var localizationID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            try await api.localizations.delete(id: localizationID)
            if json { print("{\"deleted\":\"\(localizationID)\"}"); return }
            Logger().log("deleted localization \(localizationID)", level: .success)
        }
    }
}

// MARK: - Price points

struct IAPPricePointsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "price-points",
        abstract: "Read-only catalog of valid price tiers per territory.",
        subcommands: [
            IAPPricePointsListCommand.self,
            IAPPricePointsGetCommand.self,
        ]
    )
}

struct IAPPricePointsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List price tiers for an IAP.")

    @Option(name: .long) var iapID: String
    @Option(name: .long, help: "Filter by territory id, ISO 3166-1 alpha-3 (e.g. USA).") var territoryID: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let page = try await api.pricePoints.list(
                iapID: iapID, territoryID: territoryID, limit: limit, cursor: cursor
            )
            if json {
                try printJSON(MCPPageOutput(nextCursor: page.nextCursor, items: page.items))
                return
            }
            Logger().header("Price points for IAP \(iapID)\(territoryID.map { " in \($0)" } ?? "")")
            if page.items.isEmpty {
                print("  (none)")
            } else {
                for pp in page.items {
                    let cp = pp.attributes?.customerPrice ?? "?"
                    let proc = pp.attributes?.proceeds ?? "?"
                    print("  \(pp.id)  customer=\(cp)  proceeds=\(proc)")
                }
            }
        }
    }
}

struct IAPPricePointsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a single price point.")

    @Option(name: .long) var pricePointID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.pricePoints.get(id: pricePointID)
            if json { try printJSON(result); return }
            if let pp = result {
                Logger().header("Price point \(pp.id)")
                print("  customer price: \(pp.attributes?.customerPrice ?? "?")")
                print("  proceeds:       \(pp.attributes?.proceeds ?? "?")")
            } else {
                Logger().log("not found", level: .warning)
            }
        }
    }
}

// MARK: - Pricing (price schedules)

struct IAPPricingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pricing",
        abstract: "Get or set the IAP's price schedule.",
        subcommands: [
            IAPPricingGetCommand.self,
            IAPPricingSetCommand.self,
        ]
    )
}

struct IAPPricingGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Show the current price schedule.")

    @Option(name: .long) var iapID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.priceSchedules.get(iapID: iapID)
            if json { try printJSON(result); return }
            if let s = result {
                Logger().header("Price schedule for IAP \(iapID)")
                print("  schedule id: \(s.id)")
            } else {
                Logger().log("no price schedule on file", level: .warning)
            }
        }
    }
}

struct IAPPricingSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the IAP's price schedule.",
        discussion: """
            Pricing entries are passed as `--price territory_id:price_point_id` \
            and may be repeated for each territory.

            Example:
              storescreens iap pricing set --iap-id 12345 \\
                --base-territory-id USA \\
                --price USA:eyJzIjoiVVNBIiwidCI6IjAxIn0 \\
                --price CAN:eyJzIjoiQ0FOIiwidCI6IjAxIn0
            """
    )

    @Option(name: .long) var iapID: String
    @Option(name: .long, help: "Base territory id (usually USA) used to derive prices for unlisted territories.")
    var baseTerritoryID: String

    @Option(name: .long, parsing: .upToNextOption, help: "One or more territory_id:price_point_id pairs (optionally :iso8601-start-date).")
    var price: [String]

    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let parsed = try parsePrices(price)
            let result = try await api.priceSchedules.set(
                iapID: iapID, baseTerritoryID: baseTerritoryID, prices: parsed
            )
            if json { try printJSON(result); return }
            Logger().log("set price schedule \(result.id) with \(parsed.count) territory entries", level: .success)
        }
    }

    /// Parse `territory:price_point[:iso8601_start]` strings into typed
    /// DesiredPrice values. Rejects malformed input loudly.
    private func parsePrices(_ raw: [String]) throws -> [InAppPurchasesAPI.PriceSchedules.DesiredPrice] {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()

        return try raw.map { entry in
            let parts = entry.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else {
                Logger().log("malformed --price '\(entry)'; expected territory:price_point[:start_iso8601]", level: .error)
                throw ExitCode(1)
            }
            let territory = String(parts[0])
            let pricePoint = String(parts[1])
            var start: Date? = nil
            if parts.count == 3 {
                let raw = String(parts[2])
                start = isoFractional.date(from: raw) ?? iso.date(from: raw)
                if start == nil {
                    Logger().log("could not parse start date '\(raw)' as ISO 8601", level: .error)
                    throw ExitCode(1)
                }
            }
            return InAppPurchasesAPI.PriceSchedules.DesiredPrice(
                territoryID: territory, pricePointID: pricePoint, startDate: start
            )
        }
    }
}

// MARK: - Submissions

struct IAPSubmissionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submission",
        abstract: "List, fetch, or create IAP review submissions.",
        subcommands: [
            IAPSubmissionListCommand.self,
            IAPSubmissionGetCommand.self,
            IAPSubmissionCreateCommand.self,
        ]
    )
}

struct IAPSubmissionListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List submissions for an IAP.")

    @Option(name: .long) var iapID: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let page = try await api.submissions.list(iapID: iapID, limit: limit, cursor: cursor)
            if json {
                try printJSON(MCPPageOutput(nextCursor: page.nextCursor, items: page.items))
                return
            }
            Logger().header("Submissions for IAP \(iapID)")
            if page.items.isEmpty {
                print("  (none)")
            } else {
                for s in page.items {
                    print("  \(s.id)  state=\(s.attributes?.state ?? "?")")
                }
            }
        }
    }
}

struct IAPSubmissionGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a submission.")

    @Option(name: .long) var submissionID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.submissions.get(id: submissionID)
            if json { try printJSON(result); return }
            if let s = result {
                Logger().header("Submission \(s.id)")
                print("  state: \(s.attributes?.state ?? "?")")
            } else {
                Logger().log("not found", level: .warning)
            }
        }
    }
}

struct IAPSubmissionCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Submit an IAP for review.")

    @Option(name: .long) var iapID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.submissions.create(iapID: iapID)
            if json { try printJSON(result); return }
            Logger().log("submitted IAP \(iapID); submission id \(result.id), state \(result.attributes?.state ?? "?")", level: .success)
        }
    }
}

// MARK: - Content hosting

struct IAPContentHostingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "content-hosting",
        abstract: "Apple-hosted content for non-consumable IAPs.",
        subcommands: [
            IAPContentHostingGetCommand.self,
            IAPContentHostingUpdateCommand.self,
        ]
    )
}

struct IAPContentHostingGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Show the IAP's content hosting record.")

    @Option(name: .long) var iapID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.contentHostings.get(iapID: iapID)
            if json { try printJSON(result); return }
            if let h = result {
                Logger().header("Content hosting for IAP \(iapID)")
                print("  id:         \(h.id)")
                print("  file name:  \(h.attributes?.fileName ?? "(none)")")
                print("  state:      \(h.attributes?.contentHostingState ?? "?")")
            } else {
                Logger().log("no content hosting configured", level: .warning)
            }
        }
    }
}

struct IAPContentHostingUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH the content hosting record.")

    @Option(name: .long) var contentHostingID: String
    @Option(name: .long) var fileName: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let fields = InAppPurchasesAPI.ContentHostings.UpdateFields(fileName: fileName)
            let result = try await api.contentHostings.update(id: contentHostingID, fields: fields)
            if json { try printJSON(result); return }
            Logger().log("updated content hosting \(result.id)", level: .success)
        }
    }
}

// MARK: - Images (IAP detail page)

struct IAPImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "images",
        abstract: "Manage IAP detail-page images.",
        subcommands: [
            IAPImagesListCommand.self,
            IAPImagesGetCommand.self,
            IAPImagesUploadCommand.self,
            IAPImagesUpdateCommand.self,
            IAPImagesDeleteCommand.self,
        ]
    )
}

struct IAPImagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List images for an IAP.")

    @Option(name: .long) var iapID: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let page = try await api.images.list(iapID: iapID, limit: limit, cursor: cursor)
            if json {
                try printJSON(MCPPageOutput(nextCursor: page.nextCursor, items: page.items))
                return
            }
            Logger().header("Images for IAP \(iapID)")
            if page.items.isEmpty {
                print("  (none)")
            } else {
                for img in page.items {
                    let n = img.attributes?.fileName ?? "(no name)"
                    let s = img.attributes?.assetDeliveryState?.state ?? "?"
                    print("  \(img.id)  \(n)  state=\(s)")
                }
            }
        }
    }
}

struct IAPImagesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a single image record.")

    @Option(name: .long) var imageID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.images.get(id: imageID)
            if json { try printJSON(result); return }
            if let img = result {
                Logger().header("Image \(img.id)")
                print("  file name: \(img.attributes?.fileName ?? "(none)")")
                print("  state:     \(img.attributes?.assetDeliveryState?.state ?? "?")")
            } else {
                Logger().log("not found", level: .warning)
            }
        }
    }
}

struct IAPImagesUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload an image to the IAP's detail page (reserve + bytes + confirm)."
    )

    @Option(name: .long) var iapID: String
    @Option(name: .long, help: "Path to the image file.") var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let result = try await api.images.upload(iapID: iapID, fileURL: url)
            if json { try printJSON(result); return }
            Logger().log("uploaded image \(result.id) (\(result.attributes?.fileName ?? "?"))", level: .success)
        }
    }
}

struct IAPImagesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH an image's metadata.")

    @Option(name: .long) var imageID: String
    @Option(name: .long) var fileName: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.images.update(id: imageID, fileName: fileName)
            if json { try printJSON(result); return }
            Logger().log("updated image \(result.id)", level: .success)
        }
    }
}

struct IAPImagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an image.")

    @Option(name: .long) var imageID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            try await api.images.delete(id: imageID)
            if json { print("{\"deleted\":\"\(imageID)\"}"); return }
            Logger().log("deleted image \(imageID)", level: .success)
        }
    }
}

// MARK: - Review screenshot

struct IAPReviewScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review-screenshot",
        abstract: "Manage the screenshot Apple reviewers see for an IAP.",
        subcommands: [
            IAPReviewScreenshotGetCommand.self,
            IAPReviewScreenshotUploadCommand.self,
            IAPReviewScreenshotUpdateCommand.self,
            IAPReviewScreenshotDeleteCommand.self,
        ]
    )
}

struct IAPReviewScreenshotGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Show the current review screenshot.")

    @Option(name: .long) var iapID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.reviewScreenshots.get(iapID: iapID)
            if json { try printJSON(result); return }
            if let r = result {
                Logger().header("Review screenshot for IAP \(iapID)")
                print("  id:        \(r.id)")
                print("  file name: \(r.attributes?.fileName ?? "(none)")")
                print("  state:     \(r.attributes?.assetDeliveryState?.state ?? "?")")
            } else {
                Logger().log("no review screenshot uploaded", level: .warning)
            }
        }
    }
}

struct IAPReviewScreenshotUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload the review screenshot.")

    @Option(name: .long) var iapID: String
    @Option(name: .long) var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let result = try await api.reviewScreenshots.upload(iapID: iapID, fileURL: url)
            if json { try printJSON(result); return }
            Logger().log("uploaded review screenshot \(result.id)", level: .success)
        }
    }
}

struct IAPReviewScreenshotUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH review screenshot metadata.")

    @Option(name: .long) var reviewScreenshotID: String
    @Option(name: .long) var fileName: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.reviewScreenshots.update(id: reviewScreenshotID, fileName: fileName)
            if json { try printJSON(result); return }
            Logger().log("updated review screenshot \(result.id)", level: .success)
        }
    }
}

struct IAPReviewScreenshotDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete the review screenshot.")

    @Option(name: .long) var reviewScreenshotID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            try await api.reviewScreenshots.delete(id: reviewScreenshotID)
            if json { print("{\"deleted\":\"\(reviewScreenshotID)\"}"); return }
            Logger().log("deleted review screenshot \(reviewScreenshotID)", level: .success)
        }
    }
}

// MARK: - Promotional images (featured slots)

struct IAPPromotionalImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "promotional-images",
        abstract: "Apple's featured-slot promotional artwork for an IAP.",
        subcommands: [
            IAPPromotionalImagesListCommand.self,
            IAPPromotionalImagesUploadCommand.self,
            IAPPromotionalImagesDeleteCommand.self,
        ]
    )
}

struct IAPPromotionalImagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List promotional images.")

    @Option(name: .long) var iapID: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let page = try await api.promotionalImages.list(
                iapID: iapID, limit: limit, cursor: cursor
            )
            if json {
                try printJSON(MCPPageOutput(nextCursor: page.nextCursor, items: page.items))
                return
            }
            Logger().header("Promotional images for IAP \(iapID)")
            if page.items.isEmpty {
                print("  (none)")
            } else {
                for img in page.items {
                    print("  \(img.id)  \(img.attributes?.fileName ?? "(no name)")")
                }
            }
        }
    }
}

struct IAPPromotionalImagesUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload a promotional image.")

    @Option(name: .long) var iapID: String
    @Option(name: .long) var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let result = try await api.promotionalImages.upload(iapID: iapID, fileURL: url)
            if json { try printJSON(result); return }
            Logger().log("uploaded promotional image \(result.id)", level: .success)
        }
    }
}

struct IAPPromotionalImagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a promotional image.")

    @Option(name: .long) var promotionalImageID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            try await api.promotionalImages.delete(id: promotionalImageID)
            if json { print("{\"deleted\":\"\(promotionalImageID)\"}"); return }
            Logger().log("deleted promotional image \(promotionalImageID)", level: .success)
        }
    }
}

// MARK: - Promoted purchases

struct IAPPromotedPurchasesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "promoted-purchases",
        abstract: "Which IAPs are promoted in the App Store storefront.",
        subcommands: [
            IAPPromotedPurchasesListCommand.self,
            IAPPromotedPurchasesUpdateCommand.self,
        ]
    )
}

struct IAPPromotedPurchasesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List promoted purchases on an app.")

    @Option(name: .long) var appID: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let page = try await api.promotedPurchases.list(
                appID: appID, limit: limit, cursor: cursor
            )
            if json {
                try printJSON(MCPPageOutput(nextCursor: page.nextCursor, items: page.items))
                return
            }
            Logger().header("Promoted purchases on app \(appID)")
            if page.items.isEmpty {
                print("  (none)")
            } else {
                for pp in page.items {
                    let enabled = pp.attributes?.enabled.map(String.init(describing:)) ?? "?"
                    let state = pp.attributes?.state ?? "?"
                    print("  \(pp.id)  enabled=\(enabled)  state=\(state)")
                }
            }
        }
    }
}

struct IAPPromotedPurchasesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Toggle a promoted purchase.")

    @Option(name: .long) var promotedPurchaseID: String

    @Flag(name: .long, inversion: .prefixedNo, help: "Whether the promotion is enabled.")
    var enabled: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Whether the promotion is currently visible.")
    var visibleForDistribution: Bool?

    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.promotedPurchases.update(
                id: promotedPurchaseID,
                enabled: enabled,
                visibleForDistribution: visibleForDistribution
            )
            if json { try printJSON(result); return }
            Logger().log("updated promoted purchase \(result.id)", level: .success)
        }
    }
}

// MARK: - Promoted purchase images

struct IAPPromotedImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "promoted-images",
        abstract: "Artwork attached to a promoted purchase entry.",
        subcommands: [
            IAPPromotedImagesListCommand.self,
            IAPPromotedImagesUploadCommand.self,
            IAPPromotedImagesUpdateCommand.self,
            IAPPromotedImagesDeleteCommand.self,
        ]
    )
}

struct IAPPromotedImagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List images on a promoted purchase.")

    @Option(name: .long) var promotedPurchaseID: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let page = try await api.promotedPurchaseImages.list(
                promotedPurchaseID: promotedPurchaseID, limit: limit, cursor: cursor
            )
            if json {
                try printJSON(MCPPageOutput(nextCursor: page.nextCursor, items: page.items))
                return
            }
            Logger().header("Images for promoted purchase \(promotedPurchaseID)")
            if page.items.isEmpty {
                print("  (none)")
            } else {
                for img in page.items {
                    let n = img.attributes?.fileName ?? "(no name)"
                    let s = img.attributes?.assetDeliveryState?.state ?? "?"
                    print("  \(img.id)  \(n)  state=\(s)")
                }
            }
        }
    }
}

struct IAPPromotedImagesUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload a promoted purchase image.")

    @Option(name: .long) var promotedPurchaseID: String
    @Option(name: .long) var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let result = try await api.promotedPurchaseImages.upload(
                promotedPurchaseID: promotedPurchaseID, fileURL: url
            )
            if json { try printJSON(result); return }
            Logger().log("uploaded promoted purchase image \(result.id)", level: .success)
        }
    }
}

struct IAPPromotedImagesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH a promoted purchase image.")

    @Option(name: .long) var promotedPurchaseImageID: String
    @Option(name: .long) var fileName: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            let result = try await api.promotedPurchaseImages.update(
                id: promotedPurchaseImageID, fileName: fileName
            )
            if json { try printJSON(result); return }
            Logger().log("updated promoted purchase image \(result.id)", level: .success)
        }
    }
}

struct IAPPromotedImagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a promoted purchase image.")

    @Option(name: .long) var promotedPurchaseImageID: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false

    func run() async throws {
        try await runWithErrorHandling {
            let api = InAppPurchasesAPI(client: try makeIAPClient())
            try await api.promotedPurchaseImages.delete(id: promotedPurchaseImageID)
            if json { print("{\"deleted\":\"\(promotedPurchaseImageID)\"}"); return }
            Logger().log("deleted promoted purchase image \(promotedPurchaseImageID)", level: .success)
        }
    }
}

// MARK: - Paginated JSON output

/// Used by every `--json` list subcommand. Matches the shape the MCP tools
/// return so callers can plumb the same payload through either surface.
private struct MCPPageOutput<Item: Encodable>: Encodable {
    let nextCursor: String?
    let items: [Item]
}
