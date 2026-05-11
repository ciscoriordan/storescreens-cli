import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens iap-offer-codes` command. Wraps the
/// `inAppPurchaseOfferCodes` family shipped in App Store Connect OpenAPI
/// spec v4.2 (December 2025): the offer-code analogue of
/// `subscriptionOfferCodes`, scoped to one-time IAPs (consumable,
/// non-consumable, non-renewing subscription).
///
/// Sibling of `storescreens subscriptions offer-codes` (Wave 1 covers
/// subscriptions); kept separate so the two distinct Apple resource
/// families don't share help text.
///
/// Every leaf subcommand accepts `--json` for machine-readable output. The
/// same operations are exposed as MCP tools under the `iap_offer_codes_*`,
/// `iap_offer_code_custom_codes_*`, and `iap_offer_code_one_time_use_codes_*`
/// namespaces.
struct IAPOfferCodesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iap-offer-codes",
        abstract: "Offer codes for one-time IAPs (consumable / non-consumable / non-renewing).",
        discussion: """
            Wraps the App Store Connect inAppPurchaseOfferCodes API. The parent \
            offer-code resource owns the program; the code material itself \
            lives in either the one-time-use or custom-codes child resource.

            Use `custom-codes` for developer-chosen redemption strings \
            (e.g. 'BLACKFRIDAY25_PRO'). Use `one-time-use-codes` for batches of \
            unique single-use codes Apple generates; the `values` subcommand \
            fetches the actual generated strings after Apple processes the batch.

            For auto-renewable subscription offer codes, use \
            `storescreens subscriptions offer-codes` instead.
            """,
        subcommands: [
            IAPOCCreateCommand.self,
            IAPOCGetCommand.self,
            IAPOCUpdateCommand.self,
            IAPOCCustomCodesCommand.self,
            IAPOCOneTimeUseCodesCommand.self,
        ]
    )
}

// MARK: - Shared helpers

fileprivate func iapocAPI(logger: Logger) throws -> IAPOfferCodesAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return IAPOfferCodesAPI(client: client)
}

fileprivate func iapocEmitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

fileprivate func iapocEmitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value {
        try iapocEmitJSON(value)
    } else {
        print("null")
    }
}

fileprivate struct IAPOCCLIPage<Item: Encodable>: Encodable {
    let items: [Item]
    let nextCursor: String?
}

fileprivate func iapocSurface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
    do {
        return try await block()
    } catch let e as ASCClient.APIError {
        logger.log("App Store Connect API error: HTTP \(e.statusCode)", level: .error)
        for d in e.details {
            print("  [\(d.code)] \(d.title): \(d.detail)")
        }
        throw ExitCode(1)
    }
}

fileprivate let iapocISO8601Parser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

fileprivate func iapocParseDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    if let d = iapocISO8601Parser.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
}

// MARK: - parent (offer code)

struct IAPOCCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new offer-code program against a one-time IAP.")
    @Option(name: .long, help: "IAP V2 resource id.") var inAppPurchaseId: String
    @Option(name: .long) var referenceName: String
    @Option(name: .long, parsing: .upToNextOption, help: "Subset of NEW, EXISTING, EXPIRED. Pass space-separated.") var customerEligibilities: [String]
    @Option(name: .long, help: "Optional ISO-8601 expiration.") var expirationDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let oc = try await iapocSurface(
            { try await api.createOfferCode(
                inAppPurchaseID: inAppPurchaseId,
                referenceName: referenceName,
                customerEligibilities: customerEligibilities,
                expirationDate: iapocParseDate(expirationDate)
            ) },
            logger: logger
        )
        if json { try iapocEmitJSON(oc); return }
        logger.log("created inAppPurchaseOfferCode \(oc.id) (\(referenceName))", level: .success)
    }
}

struct IAPOCGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a one-time IAP offer code by id.")
    @Argument(help: "inAppPurchaseOfferCode id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let oc = try await iapocSurface({ try await api.getOfferCode(id: id) }, logger: logger)
        if json { try iapocEmitOptionalJSON(oc); return }
        guard let oc else {
            logger.log("no inAppPurchaseOfferCode \(id)", level: .warning)
            return
        }
        logger.header("Offer code \(oc.id)")
        print("  referenceName:                \(oc.attributes?.referenceName ?? "(none)")")
        print("  isActive:                     \(oc.attributes?.isActive.map(String.init) ?? "(unknown)")")
        print("  totalNumberOfCodes:           \(oc.attributes?.totalNumberOfCodes.map(String.init) ?? "(unknown)")")
        print("  totalNumberOfRedeemedCodes:   \(oc.attributes?.totalNumberOfRedeemedCodes.map(String.init) ?? "(unknown)")")
        print("  customerEligibilities:        \(oc.attributes?.customerEligibilities?.joined(separator: ",") ?? "(none)")")
        print("  expirationDate:               \(oc.attributes?.expirationDate.map(String.init(describing:)) ?? "(none)")")
    }
}

struct IAPOCUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH a one-time IAP offer code.")
    @Argument(help: "inAppPurchaseOfferCode id.") var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var isActive: Bool?
    @Option(name: .long, parsing: .upToNextOption) var customerEligibilities: [String] = []
    @Option(name: .long, help: "Optional ISO-8601 expiration.") var expirationDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let fields = IAPOfferCodesAPI.OfferCodeFields(
            referenceName: referenceName,
            isActive: isActive,
            customerEligibilities: customerEligibilities.isEmpty ? nil : customerEligibilities,
            expirationDate: iapocParseDate(expirationDate)
        )
        let oc = try await iapocSurface(
            { try await api.updateOfferCode(id: id, fields: fields) },
            logger: logger
        )
        if json { try iapocEmitJSON(oc); return }
        logger.log("updated inAppPurchaseOfferCode \(oc.id)", level: .success)
    }
}

// MARK: - custom codes

struct IAPOCCustomCodesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "custom-codes",
        abstract: "Developer-chosen custom-string redemption codes.",
        subcommands: [
            IAPOCCustomCodesCreateCommand.self,
            IAPOCCustomCodesGetCommand.self,
            IAPOCCustomCodesUpdateCommand.self,
        ]
    )
}

struct IAPOCCustomCodesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a custom-string redemption code.")
    @Option(name: .long) var offerCodeId: String
    @Option(name: .long, help: "Code string customers type (e.g. BLACKFRIDAY25_PRO).") var customCode: String
    @Option(name: .long, help: "Cap on total redemptions.") var count: Int
    @Option(name: .long, help: "Optional ISO-8601 expiration.") var expirationDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let code = try await iapocSurface(
            { try await api.createCustomCode(
                offerCodeID: offerCodeId,
                customCode: customCode,
                numberOfCodes: count,
                expirationDate: iapocParseDate(expirationDate)
            ) },
            logger: logger
        )
        if json { try iapocEmitJSON(code); return }
        logger.log("created inAppPurchaseOfferCodeCustomCode \(code.id) (\(customCode))", level: .success)
    }
}

struct IAPOCCustomCodesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a custom-string code by id.")
    @Argument(help: "inAppPurchaseOfferCodeCustomCode id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let code = try await iapocSurface({ try await api.getCustomCode(id: id) }, logger: logger)
        if json { try iapocEmitOptionalJSON(code); return }
        guard let code else {
            logger.log("no inAppPurchaseOfferCodeCustomCode \(id)", level: .warning)
            return
        }
        logger.header("Custom code \(code.id)")
        print("  customCode:     \(code.attributes?.customCode ?? "(none)")")
        print("  numberOfCodes:  \(code.attributes?.numberOfCodes.map(String.init) ?? "(unknown)")")
        print("  isActive:       \(code.attributes?.isActive.map(String.init) ?? "(unknown)")")
        print("  expirationDate: \(code.attributes?.expirationDate.map(String.init(describing:)) ?? "(none)")")
    }
}

struct IAPOCCustomCodesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH active state / expiration on a custom code.")
    @Argument(help: "inAppPurchaseOfferCodeCustomCode id.") var id: String
    @Option(name: .long) var isActive: Bool?
    @Option(name: .long, help: "Optional ISO-8601 expiration.") var expirationDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let code = try await iapocSurface(
            { try await api.updateCustomCode(
                id: id, isActive: isActive, expirationDate: iapocParseDate(expirationDate)
            ) },
            logger: logger
        )
        if json { try iapocEmitJSON(code); return }
        logger.log("updated inAppPurchaseOfferCodeCustomCode \(code.id)", level: .success)
    }
}

// MARK: - one-time-use codes

struct IAPOCOneTimeUseCodesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "one-time-use-codes",
        abstract: "Single-use redemption code batches.",
        subcommands: [
            IAPOCOneTimeCreateCommand.self,
            IAPOCOneTimeGetCommand.self,
            IAPOCOneTimeUpdateCommand.self,
            IAPOCOneTimeValuesCommand.self,
        ]
    )
}

struct IAPOCOneTimeCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Generate a batch of unique single-use codes.")
    @Option(name: .long) var offerCodeId: String
    @Option(name: .long, help: "How many codes to mint.") var count: Int
    @Option(name: .long, help: "Optional ISO-8601 expiration.") var expirationDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let batch = try await iapocSurface(
            { try await api.createOneTimeUseCode(
                offerCodeID: offerCodeId,
                numberOfCodes: count,
                expirationDate: iapocParseDate(expirationDate)
            ) },
            logger: logger
        )
        if json { try iapocEmitJSON(batch); return }
        logger.log("created inAppPurchaseOfferCodeOneTimeUseCode batch \(batch.id) (\(count) codes)", level: .success)
        print("  Apple processes asynchronously; poll `get \(batch.id)` until isActive=true, then `values \(batch.id)` to fetch strings.")
    }
}

struct IAPOCOneTimeGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a one-time-use code batch by id.")
    @Argument(help: "inAppPurchaseOfferCodeOneTimeUseCode id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let batch = try await iapocSurface({ try await api.getOneTimeUseCode(id: id) }, logger: logger)
        if json { try iapocEmitOptionalJSON(batch); return }
        guard let batch else {
            logger.log("no inAppPurchaseOfferCodeOneTimeUseCode \(id)", level: .warning)
            return
        }
        logger.header("One-time-use code batch \(batch.id)")
        print("  numberOfCodes:  \(batch.attributes?.numberOfCodes.map(String.init) ?? "(unknown)")")
        print("  isActive:       \(batch.attributes?.isActive.map(String.init) ?? "(unknown)")")
        print("  expirationDate: \(batch.attributes?.expirationDate.map(String.init(describing:)) ?? "(none)")")
    }
}

struct IAPOCOneTimeUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "PATCH active state / expiration on a one-time-use batch.")
    @Argument(help: "inAppPurchaseOfferCodeOneTimeUseCode id.") var id: String
    @Option(name: .long) var isActive: Bool?
    @Option(name: .long, help: "Optional ISO-8601 expiration.") var expirationDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let batch = try await iapocSurface(
            { try await api.updateOneTimeUseCode(
                id: id, isActive: isActive, expirationDate: iapocParseDate(expirationDate)
            ) },
            logger: logger
        )
        if json { try iapocEmitJSON(batch); return }
        logger.log("updated inAppPurchaseOfferCodeOneTimeUseCode \(batch.id)", level: .success)
    }
}

struct IAPOCOneTimeValuesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "values", abstract: "List the generated code strings for a one-time-use batch.")
    @Argument(help: "inAppPurchaseOfferCodeOneTimeUseCode id.") var id: String
    @Option(name: .long, help: "Max results per page (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Pagination cursor from a previous page.") var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try iapocAPI(logger: logger)
        let page = try await iapocSurface(
            { try await api.listOneTimeUseCodeValues(
                oneTimeUseCodeID: id, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try iapocEmitJSON(IAPOCCLIPage(items: page.items, nextCursor: page.nextCursor))
            return
        }
        logger.header("Generated code values (\(page.items.count))")
        for v in page.items {
            let value = v.attributes?.value ?? "(no value yet)"
            let redeemed = v.attributes?.redeemed.map { $0 ? "redeemed" : "unredeemed" } ?? "?"
            print("  \(v.id)\t\(value)\t[\(redeemed)]")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}
