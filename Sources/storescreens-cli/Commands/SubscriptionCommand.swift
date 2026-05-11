import ArgumentParser
import Foundation
import StorescreensCore

/// Parent command for App Store Connect auto-renewable subscriptions.
///
/// All subcommands resolve credentials through `ASCCredentialResolver.resolve()`
/// and emit either a human-readable summary or pretty-printed JSON
/// (with `--json`). Mirrors the resource graph: groups → subscriptions →
/// localizations / prices / offers / availability / submissions /
/// review-screenshots / images.
///
/// This file does not register itself in Main.swift; the parent agent
/// wires it in when integrating.
struct SubscriptionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subscriptions",
        abstract: "Manage App Store Connect auto-renewable subscriptions.",
        discussion: """
            Wraps the App Store Connect Subscriptions API. Requires ASC \
            credentials (run `storescreens auth login`, or set ASC_KEY_ID / \
            ASC_ISSUER_ID / ASC_KEY_PATH).

            Use `groups`, `products`, `localizations`, `prices`, `price-points`, \
            `offer-codes`, `promotional-offers`, `availability`, `submission`, \
            `review-screenshots`, or `images` to drill into each resource.
            """,
        subcommands: [
            SubsGroupsCommand.self,
            SubsGroupLocalizationsCommand.self,
            SubsSubscriptionsCommand.self,
            SubsLocalizationsCommand.self,
            SubsPricesCommand.self,
            SubsPricePointsCommand.self,
            SubsOfferCodesCommand.self,
            SubsPromotionalOffersCommand.self,
            SubsAvailabilityCommand.self,
            SubsSubmissionCommand.self,
            SubsReviewScreenshotsCommand.self,
            SubsImagesCommand.self,
        ]
    )
}

// MARK: - Shared output plumbing

/// Tiny helper to render either pretty-printed JSON or a plain summary.
/// Hands the encoded JSON back to the caller as a String so the caller
/// can layer on a human-readable header before printing.
private enum SubsJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Resolves credentials and returns a ready-to-use SubscriptionsAPI.
/// Mirrors the pattern used by `submit` and `status`; throws ExitCode(1)
/// after printing a friendly message when credentials aren't configured.
private func resolveSubsAPI(logger: Logger) async throws -> SubscriptionsAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return SubscriptionsAPI(client: client)
}

/// Parses a permissive ISO-8601 date (with or without fractional seconds).
private let subsISO8601Parser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func parseDate(_ str: String?) -> Date? {
    guard let str else { return nil }
    if let d = subsISO8601Parser.date(from: str) { return d }
    // Fall back to a parser without fractional seconds for short forms.
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: str)
}

// MARK: - Groups

struct SubsGroupsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "Manage subscription groups (apps contain groups; groups contain subscriptions).",
        subcommands: [
            SubsGroupsListCommand.self,
            SubsGroupsGetCommand.self,
            SubsGroupsCreateCommand.self,
            SubsGroupsUpdateCommand.self,
            SubsGroupsDeleteCommand.self,
        ]
    )
}

struct SubsGroupsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List subscription groups for an app."
    )

    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Option(name: .long, help: "Page size.") var limit: Int = 200
    @Option(name: .long, help: "Pagination cursor from a previous response.") var cursor: String?
    @Flag(name: .long, help: "Emit JSON instead of human-readable text.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.groups.list(appID: appId, limit: limit, cursor: cursor)
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Subscription groups (\(page.items.count))")
        for g in page.items {
            print("  \(g.id)\t\(g.attributes?.referenceName ?? "")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsGroupsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch a single subscription group by id."
    )
    @Argument(help: "subscriptionGroup id") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let group = try await api.groups.get(id: id)
        if json {
            print(try SubsJSON.encode(group))
            return
        }
        if let g = group {
            logger.header("Subscription group")
            print("  id:             \(g.id)")
            print("  referenceName:  \(g.attributes?.referenceName ?? "(none)")")
        } else {
            logger.log("not found", level: .warning)
        }
    }
}

struct SubsGroupsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new subscription group under an app."
    )
    @Option(name: .long) var appId: String
    @Option(name: .long, help: "Internal name shown only in ASC.") var referenceName: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let group = try await api.groups.create(appID: appId, referenceName: referenceName)
        if json {
            print(try SubsJSON.encode(group))
        } else {
            logger.log("created group \(group.id) (\(group.attributes?.referenceName ?? referenceName))", level: .success)
        }
    }
}

struct SubsGroupsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a subscription group's reference name."
    )
    @Argument(help: "subscriptionGroup id") var id: String
    @Option(name: .long) var referenceName: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let group = try await api.groups.update(id: id, referenceName: referenceName)
        if json {
            print(try SubsJSON.encode(group))
        } else {
            logger.log("updated group \(group.id)", level: .success)
        }
    }
}

struct SubsGroupsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an empty subscription group."
    )
    @Argument(help: "subscriptionGroup id") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.groups.delete(id: id)
        logger.log("deleted group \(id)", level: .success)
    }
}

// MARK: - Group Localizations

struct SubsGroupLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group-localizations",
        abstract: "Per-locale display name + custom app name on a subscription group.",
        subcommands: [
            SubsGroupLocalizationsListCommand.self,
            SubsGroupLocalizationsCreateCommand.self,
            SubsGroupLocalizationsUpdateCommand.self,
            SubsGroupLocalizationsDeleteCommand.self,
        ]
    )
}

struct SubsGroupLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List group localizations.")
    @Option(name: .long) var groupId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.groups.listLocalizations(groupID: groupId, limit: limit, cursor: cursor)
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Group localizations (\(page.items.count))")
        for l in page.items {
            let locale = l.attributes?.locale ?? "?"
            print("  \(l.id)\t\(locale)\t\(l.attributes?.name ?? "")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsGroupLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a group localization.")
    @Option(name: .long) var groupId: String
    @Option(name: .long, help: "e.g. en-US") var locale: String
    @Option(name: .long) var name: String
    @Option(name: .long, help: "Optional override of the app name in this locale.") var customAppName: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let loc = try await api.groupLocalizations.create(
            groupID: groupId, locale: locale, name: name, customAppName: customAppName
        )
        if json { print(try SubsJSON.encode(loc)); return }
        logger.log("created group localization \(loc.id) (\(locale))", level: .success)
    }
}

struct SubsGroupLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a group localization.")
    @Argument(help: "subscriptionGroupLocalization id") var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var customAppName: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let loc = try await api.groupLocalizations.update(id: id, name: name, customAppName: customAppName)
        if json { print(try SubsJSON.encode(loc)); return }
        logger.log("updated group localization \(loc.id)", level: .success)
    }
}

struct SubsGroupLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a group localization.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.groupLocalizations.delete(id: id)
        logger.log("deleted group localization \(id)", level: .success)
    }
}

// MARK: - Subscriptions (the products themselves)

struct SubsSubscriptionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "products",
        abstract: "Manage subscriptions (the actual auto-renewing products in a group).",
        subcommands: [
            SubsSubscriptionsListCommand.self,
            SubsSubscriptionsGetCommand.self,
            SubsSubscriptionsCreateCommand.self,
            SubsSubscriptionsUpdateCommand.self,
            SubsSubscriptionsDeleteCommand.self,
        ]
    )
}

struct SubsSubscriptionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List subscriptions in a group.")
    @Option(name: .long) var groupId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.groups.listSubscriptions(groupID: groupId, limit: limit, cursor: cursor)
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Subscriptions (\(page.items.count))")
        for s in page.items {
            let attrs = s.attributes
            print("  \(s.id)\t\(attrs?.productId ?? "")\t\(attrs?.subscriptionPeriod ?? "")\tstate=\(attrs?.state ?? "")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsSubscriptionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a single subscription.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let sub = try await api.subscriptions.get(id: id)
        if json { print(try SubsJSON.encode(sub)); return }
        if let s = sub {
            logger.header("Subscription")
            print("  id:        \(s.id)")
            print("  productId: \(s.attributes?.productId ?? "")")
            print("  name:      \(s.attributes?.name ?? "")")
            print("  period:    \(s.attributes?.subscriptionPeriod ?? "")")
            print("  level:     \(s.attributes?.groupLevel.map(String.init) ?? "")")
            print("  state:     \(s.attributes?.state ?? "")")
        } else {
            logger.log("not found", level: .warning)
        }
    }
}

struct SubsSubscriptionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a subscription inside a group.")
    @Option(name: .long) var groupId: String
    @Option(name: .long, help: "Reverse-DNS StoreKit product id.") var productId: String
    @Option(name: .long) var name: String
    @Option(name: .long, help: "ONE_WEEK, ONE_MONTH, TWO_MONTHS, THREE_MONTHS, SIX_MONTHS, ONE_YEAR") var subscriptionPeriod: String
    @Option(name: .long, help: "Position within the group; lower = shown first.") var groupLevel: Int
    @Option(name: .long, help: "Optional review note.") var reviewNote: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let sub = try await api.subscriptions.create(
            groupID: groupId,
            productId: productId,
            name: name,
            subscriptionPeriod: subscriptionPeriod,
            groupLevel: groupLevel,
            reviewNote: reviewNote
        )
        if json { print(try SubsJSON.encode(sub)); return }
        logger.log("created subscription \(sub.id) (\(productId))", level: .success)
    }
}

struct SubsSubscriptionsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update mutable subscription fields.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var groupLevel: Int?
    @Option(name: .long) var reviewNote: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let sub = try await api.subscriptions.update(
            id: id, name: name, groupLevel: groupLevel, reviewNote: reviewNote
        )
        if json { print(try SubsJSON.encode(sub)); return }
        logger.log("updated subscription \(sub.id)", level: .success)
    }
}

struct SubsSubscriptionsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an unpublished subscription.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.subscriptions.delete(id: id)
        logger.log("deleted subscription \(id)", level: .success)
    }
}

// MARK: - Localizations

struct SubsLocalizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localizations",
        abstract: "Per-locale name + description on a subscription.",
        subcommands: [
            SubsLocalizationsListCommand.self,
            SubsLocalizationsCreateCommand.self,
            SubsLocalizationsUpdateCommand.self,
            SubsLocalizationsDeleteCommand.self,
        ]
    )
}

struct SubsLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List subscription localizations.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.subscriptions.listLocalizations(
            subscriptionID: subscriptionId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Subscription localizations (\(page.items.count))")
        for l in page.items {
            print("  \(l.id)\t\(l.attributes?.locale ?? "?")\t\(l.attributes?.name ?? "")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a subscription localization.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var locale: String
    @Option(name: .long) var name: String
    @Option(name: .long) var description: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let loc = try await api.localizations.create(
            subscriptionID: subscriptionId, locale: locale, name: name, description: description
        )
        if json { print(try SubsJSON.encode(loc)); return }
        logger.log("created subscription localization \(loc.id) (\(locale))", level: .success)
    }
}

struct SubsLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a subscription localization.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var description: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let loc = try await api.localizations.update(id: id, name: name, description: description)
        if json { print(try SubsJSON.encode(loc)); return }
        logger.log("updated subscription localization \(loc.id)", level: .success)
    }
}

struct SubsLocalizationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a subscription localization.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.localizations.delete(id: id)
        logger.log("deleted subscription localization \(id)", level: .success)
    }
}

// MARK: - Prices

struct SubsPricesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prices",
        abstract: "Per-territory subscription prices (immutable: 'change' = create new + delete old).",
        subcommands: [
            SubsPricesListCommand.self,
            SubsPricesSetCommand.self,
            SubsPricesDeleteCommand.self,
        ]
    )
}

struct SubsPricesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List prices for a subscription.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long, help: "Optional ISO 3166-1 alpha-3 filter (e.g. USA).") var territory: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.prices.list(
            subscriptionID: subscriptionId, limit: limit, cursor: cursor, filterTerritory: territory
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Subscription prices (\(page.items.count))")
        for p in page.items {
            print("  \(p.id)")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsPricesSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the per-territory price by creating a new subscriptionPrice record.",
        discussion: """
            Apple keys prices on (subscription, territory, startDate) and \
            does not allow PATCH. Use --price-point-id from `price-points list` \
            and --territory like USA.
            """
    )
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var pricePointId: String
    @Option(name: .long, help: "ISO 3166-1 alpha-3 territory code (e.g. USA).") var territory: String
    @Option(name: .long, help: "Optional ISO-8601 effective date.") var startDate: String?
    @Flag(name: .long, help: "Grandfather existing subscribers onto the old price.") var preserveCurrentPrice: Bool = false
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let price = try await api.prices.create(
            subscriptionID: subscriptionId,
            pricePointID: pricePointId,
            territoryID: territory,
            startDate: parseDate(startDate),
            preserveCurrentPrice: preserveCurrentPrice ? true : nil
        )
        if json { print(try SubsJSON.encode(price)); return }
        logger.log("created price \(price.id) for territory \(territory)", level: .success)
    }
}

struct SubsPricesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a price record.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.prices.delete(id: id)
        logger.log("deleted price \(id)", level: .success)
    }
}

// MARK: - Price Points

struct SubsPricePointsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "price-points",
        abstract: "Read-only catalog of valid Apple price tiers per territory.",
        subcommands: [SubsPricePointsListCommand.self]
    )
}

struct SubsPricePointsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List valid price points for a subscription + territory.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long, help: "ISO 3166-1 alpha-3 territory code.") var territory: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.pricePoints.list(
            subscriptionID: subscriptionId, territoryID: territory, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Price points for \(territory) (\(page.items.count))")
        for pp in page.items {
            let customer = pp.attributes?.customerPrice ?? "?"
            let proceeds = pp.attributes?.proceeds ?? "?"
            print("  \(pp.id)\tcustomer=\(customer)\tproceeds=\(proceeds)")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

// MARK: - Offer Codes

struct SubsOfferCodesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "offer-codes",
        abstract: "Offer codes (win-back / promotional flows).",
        subcommands: [
            SubsOfferCodesListCommand.self,
            SubsOfferCodesGetCommand.self,
            SubsOfferCodesCreateCommand.self,
            SubsOfferCodesUpdateCommand.self,
            SubsOfferCodesDeleteCommand.self,
            SubsOfferCodesOneTimeCommand.self,
            SubsOfferCodesCustomCommand.self,
            SubsOfferCodePricesCommand.self,
        ]
    )
}

struct SubsOfferCodesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List offer codes for a subscription.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.offerCodes.list(
            subscriptionID: subscriptionId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Offer codes (\(page.items.count))")
        for o in page.items {
            let attrs = o.attributes
            print("  \(o.id)\t\(attrs?.referenceName ?? "")\t\(attrs?.offerType ?? "")\tactive=\(attrs?.isActive.map(String.init) ?? "?")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsOfferCodesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch an offer code.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let offer = try await api.offerCodes.get(id: id)
        if json { print(try SubsJSON.encode(offer)); return }
        if let o = offer {
            logger.header("Offer code")
            print("  id:             \(o.id)")
            print("  referenceName:  \(o.attributes?.referenceName ?? "")")
            print("  offerType:      \(o.attributes?.offerType ?? "")")
            print("  duration:       \(o.attributes?.duration ?? "")")
            print("  numPeriods:     \(o.attributes?.numberOfPeriods.map(String.init) ?? "")")
            print("  isActive:       \(o.attributes?.isActive.map(String.init) ?? "")")
            print("  totalCodes:     \(o.attributes?.totalNumberOfCodes.map(String.init) ?? "")")
            print("  redeemedCodes:  \(o.attributes?.totalNumberOfRedeemedCodes.map(String.init) ?? "")")
        } else {
            logger.log("not found", level: .warning)
        }
    }
}

struct SubsOfferCodesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new offer-code program for a subscription."
    )
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var referenceName: String
    @Option(name: .long, help: "FREE_TRIAL | PAY_AS_YOU_GO | PAY_UP_FRONT") var offerType: String
    @Option(name: .long, help: "ONE_WEEK, ONE_MONTH, ...") var duration: String
    @Option(name: .long, help: "Required for PAY_AS_YOU_GO.") var numberOfPeriods: Int?
    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Subset of NEW, EXISTING, EXPIRED. Pass space-separated."
    )
    var customerEligibilities: [String]
    @Option(name: .long, help: "Optional cap on total redemptions.") var totalNumberOfCodes: Int?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let offer = try await api.offerCodes.create(
            subscriptionID: subscriptionId,
            referenceName: referenceName,
            offerType: offerType,
            duration: duration,
            numberOfPeriods: numberOfPeriods,
            customerEligibilities: customerEligibilities,
            totalNumberOfCodes: totalNumberOfCodes
        )
        if json { print(try SubsJSON.encode(offer)); return }
        logger.log("created offer code \(offer.id) (\(referenceName))", level: .success)
    }
}

struct SubsOfferCodesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update reference_name or is_active.")
    @Argument var id: String
    @Option(name: .long) var referenceName: String?
    @Option(name: .long) var isActive: Bool?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let offer = try await api.offerCodes.update(id: id, referenceName: referenceName, isActive: isActive)
        if json { print(try SubsJSON.encode(offer)); return }
        logger.log("updated offer code \(offer.id)", level: .success)
    }
}

struct SubsOfferCodesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an offer code.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.offerCodes.delete(id: id)
        logger.log("deleted offer code \(id)", level: .success)
    }
}

// One-time use codes

struct SubsOfferCodesOneTimeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "one-time",
        abstract: "One-time-use redemption code batches.",
        subcommands: [
            SubsOfferCodesOneTimeListCommand.self,
            SubsOfferCodesOneTimeGenerateCommand.self,
        ]
    )
}

struct SubsOfferCodesOneTimeListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List one-time-use code batches.")
    @Option(name: .long) var offerCodeId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.offerCodeOneTimeUseCodes.list(
            offerCodeID: offerCodeId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("One-time-use code batches (\(page.items.count))")
        for b in page.items {
            let count = b.attributes?.numberOfCodes.map(String.init) ?? "?"
            let active = b.attributes?.isActive.map(String.init) ?? "?"
            print("  \(b.id)\tcount=\(count)\tactive=\(active)")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsOfferCodesOneTimeGenerateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "generate", abstract: "Generate one-time-use redemption codes.")
    @Option(name: .long) var offerCodeId: String
    @Option(name: .long) var count: Int
    @Option(name: .long, help: "Optional ISO-8601 expiration.") var expirationDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let batch = try await api.offerCodeOneTimeUseCodes.create(
            offerCodeID: offerCodeId, numberOfCodes: count, expirationDate: parseDate(expirationDate)
        )
        if json { print(try SubsJSON.encode(batch)); return }
        logger.log("generated \(count) one-time-use codes (batch \(batch.id))", level: .success)
        print("  Apple processes asynchronously; poll list until isActive=true.")
    }
}

// Custom codes

struct SubsOfferCodesCustomCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "custom",
        abstract: "Custom-string redemption codes.",
        subcommands: [
            SubsOfferCodesCustomListCommand.self,
            SubsOfferCodesCustomCreateCommand.self,
            SubsOfferCodesCustomDeleteCommand.self,
        ]
    )
}

struct SubsOfferCodesCustomListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List custom-string codes.")
    @Option(name: .long) var offerCodeId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.offerCodeCustomCodes.list(
            offerCodeID: offerCodeId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Custom codes (\(page.items.count))")
        for c in page.items {
            print("  \(c.id)\t\(c.attributes?.customCode ?? "")\tcount=\(c.attributes?.numberOfCodes.map(String.init) ?? "?")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsOfferCodesCustomCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a custom-string redemption code.")
    @Option(name: .long) var offerCodeId: String
    @Option(name: .long, help: "Code string customers type (e.g. BLACKFRIDAY2025).") var customCode: String
    @Option(name: .long) var count: Int
    @Option(name: .long, help: "Optional ISO-8601 expiration.") var expirationDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let code = try await api.offerCodeCustomCodes.create(
            offerCodeID: offerCodeId,
            customCode: customCode,
            numberOfCodes: count,
            expirationDate: parseDate(expirationDate)
        )
        if json { print(try SubsJSON.encode(code)); return }
        logger.log("created custom code \(code.id) (\(customCode))", level: .success)
    }
}

struct SubsOfferCodesCustomDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a custom code.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.offerCodeCustomCodes.delete(id: id)
        logger.log("deleted custom code \(id)", level: .success)
    }
}

// Offer code prices

struct SubsOfferCodePricesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prices",
        abstract: "Per-territory pricing on an offer code.",
        subcommands: [
            SubsOfferCodePricesListCommand.self,
            SubsOfferCodePricesCreateCommand.self,
        ]
    )
}

struct SubsOfferCodePricesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List offer-code prices.")
    @Option(name: .long) var offerCodeId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.offerCodePrices.list(
            offerCodeID: offerCodeId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Offer code prices (\(page.items.count))")
        for p in page.items { print("  \(p.id)") }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsOfferCodePricesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a per-territory offer-code price.")
    @Option(name: .long) var offerCodeId: String
    @Option(name: .long) var pricePointId: String
    @Option(name: .long) var territory: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let p = try await api.offerCodePrices.create(
            offerCodeID: offerCodeId, pricePointID: pricePointId, territoryID: territory
        )
        if json { print(try SubsJSON.encode(p)); return }
        logger.log("created offer-code price \(p.id) for \(territory)", level: .success)
    }
}

// MARK: - Promotional Offers

struct SubsPromotionalOffersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "promotional-offers",
        abstract: "Promotional intro offers shown to new subscribers via StoreKit.",
        subcommands: [
            SubsPromoListCommand.self,
            SubsPromoGetCommand.self,
            SubsPromoCreateCommand.self,
            SubsPromoUpdateCommand.self,
            SubsPromoDeleteCommand.self,
            SubsPromoPricesCommand.self,
        ]
    )
}

struct SubsPromoListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List promotional offers.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.promotionalOffers.list(
            subscriptionID: subscriptionId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Promotional offers (\(page.items.count))")
        for o in page.items {
            print("  \(o.id)\t\(o.attributes?.name ?? "")\t\(o.attributes?.offerType ?? "")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsPromoGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a promotional offer.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let offer = try await api.promotionalOffers.get(id: id)
        if json { print(try SubsJSON.encode(offer)); return }
        if let o = offer {
            logger.header("Promotional offer")
            print("  id:           \(o.id)")
            print("  name:         \(o.attributes?.name ?? "")")
            print("  offerCode:    \(o.attributes?.offerCode ?? "")")
            print("  offerType:    \(o.attributes?.offerType ?? "")")
            print("  duration:     \(o.attributes?.duration ?? "")")
            print("  numPeriods:   \(o.attributes?.numberOfPeriods.map(String.init) ?? "")")
        } else {
            logger.log("not found", level: .warning)
        }
    }
}

struct SubsPromoCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new promotional offer.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var name: String
    @Option(name: .long, help: "Reverse-DNS id StoreKit targets at purchase.") var offerCode: String
    @Option(name: .long, help: "FREE_TRIAL | PAY_AS_YOU_GO | PAY_UP_FRONT") var offerType: String
    @Option(name: .long) var duration: String
    @Option(name: .long) var numberOfPeriods: Int?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let offer = try await api.promotionalOffers.create(
            subscriptionID: subscriptionId,
            name: name,
            offerCode: offerCode,
            offerType: offerType,
            duration: duration,
            numberOfPeriods: numberOfPeriods
        )
        if json { print(try SubsJSON.encode(offer)); return }
        logger.log("created promotional offer \(offer.id) (\(name))", level: .success)
    }
}

struct SubsPromoUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a promotional offer's display name.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let offer = try await api.promotionalOffers.update(id: id, name: name)
        if json { print(try SubsJSON.encode(offer)); return }
        logger.log("updated promotional offer \(offer.id)", level: .success)
    }
}

struct SubsPromoDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a promotional offer.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.promotionalOffers.delete(id: id)
        logger.log("deleted promotional offer \(id)", level: .success)
    }
}

struct SubsPromoPricesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prices",
        abstract: "Per-territory prices on a promotional offer.",
        subcommands: [
            SubsPromoPricesListCommand.self,
            SubsPromoPricesCreateCommand.self,
        ]
    )
}

struct SubsPromoPricesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List promo-offer prices.")
    @Option(name: .long) var promotionalOfferId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.promotionalOfferPrices.list(
            promotionalOfferID: promotionalOfferId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Promo-offer prices (\(page.items.count))")
        for p in page.items { print("  \(p.id)") }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsPromoPricesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a per-territory promo-offer price.")
    @Option(name: .long) var promotionalOfferId: String
    @Option(name: .long) var pricePointId: String
    @Option(name: .long) var territory: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let p = try await api.promotionalOfferPrices.create(
            promotionalOfferID: promotionalOfferId,
            pricePointID: pricePointId,
            territoryID: territory
        )
        if json { print(try SubsJSON.encode(p)); return }
        logger.log("created promo price \(p.id) for \(territory)", level: .success)
    }
}

// MARK: - Availability

struct SubsAvailabilityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "availability",
        abstract: "Territory availability for a subscription.",
        subcommands: [
            SubsAvailabilityGetCommand.self,
            SubsAvailabilityUpdateCommand.self,
        ]
    )
}

struct SubsAvailabilityGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch current subscription availability.")
    @Option(name: .long) var subscriptionId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let a = try await api.availabilities.get(subscriptionID: subscriptionId)
        if json { print(try SubsJSON.encode(a)); return }
        if let a = a {
            logger.header("Subscription availability")
            print("  id:                          \(a.id)")
            print("  availableInNewTerritories:   \(a.attributes?.availableInNewTerritories.map(String.init) ?? "?")")
        } else {
            logger.log("no availability record yet", level: .warning)
        }
    }
}

struct SubsAvailabilityUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Replace the territory list for a subscription. Pass the full set of territories every time.",
        discussion: """
            Apple treats each POST as an exhaustive replacement. Pass the \
            full set of ISO 3166-1 alpha-3 territory codes you want enabled.
            """
    )
    @Option(name: .long) var subscriptionId: String
    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Full list of ISO 3166-1 alpha-3 territory codes."
    )
    var territories: [String]
    @Flag(name: .long, help: "Auto-enroll into new Apple territories.") var availableInNewTerritories: Bool = false
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let result = try await api.availabilities.update(
            subscriptionID: subscriptionId,
            territoryIDs: territories,
            availableInNewTerritories: availableInNewTerritories
        )
        if json { print(try SubsJSON.encode(result)); return }
        logger.log("updated availability \(result.id) (\(territories.count) territories)", level: .success)
    }
}

// MARK: - Submission

struct SubsSubmissionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submission",
        abstract: "Submit subscription metadata edits for App Review.",
        subcommands: [
            SubsSubmissionListCommand.self,
            SubsSubmissionGetCommand.self,
            SubsSubmissionCreateCommand.self,
        ]
    )
}

struct SubsSubmissionListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List submissions for a subscription.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.submissions.list(
            subscriptionID: subscriptionId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Submissions (\(page.items.count))")
        for s in page.items {
            print("  \(s.id)\tstate=\(s.attributes?.state ?? "?")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsSubmissionGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a submission.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let s = try await api.submissions.get(id: id)
        if json { print(try SubsJSON.encode(s)); return }
        if let s = s {
            logger.header("Submission")
            print("  id:    \(s.id)")
            print("  state: \(s.attributes?.state ?? "")")
        } else {
            logger.log("not found", level: .warning)
        }
    }
}

struct SubsSubmissionCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "Push pending subscription metadata edits to App Review."
    )
    @Option(name: .long) var subscriptionId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let sub = try await api.submissions.create(subscriptionID: subscriptionId)
        if json { print(try SubsJSON.encode(sub)); return }
        logger.log("created submission \(sub.id) (\(sub.attributes?.state ?? ""))", level: .success)
    }
}

// MARK: - Review Screenshots

struct SubsReviewScreenshotsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review-screenshots",
        abstract: "Review-only screenshots Apple requires for subscription approval.",
        subcommands: [
            SubsReviewScreenshotsListCommand.self,
            SubsReviewScreenshotsGetCommand.self,
            SubsReviewScreenshotsCreateCommand.self,
            SubsReviewScreenshotsConfirmCommand.self,
            SubsReviewScreenshotsDeleteCommand.self,
        ]
    )
}

struct SubsReviewScreenshotsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List review screenshots.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.reviewScreenshots.list(
            subscriptionID: subscriptionId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Review screenshots (\(page.items.count))")
        for s in page.items {
            print("  \(s.id)\t\(s.attributes?.fileName ?? "")\tstate=\(s.attributes?.assetDeliveryState?.state ?? "?")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsReviewScreenshotsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a review screenshot.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let s = try await api.reviewScreenshots.get(id: id)
        if json { print(try SubsJSON.encode(s)); return }
        if let s = s {
            logger.header("Review screenshot")
            print("  id:       \(s.id)")
            print("  fileName: \(s.attributes?.fileName ?? "")")
            print("  fileSize: \(s.attributes?.fileSize.map(String.init) ?? "")")
            print("  state:    \(s.attributes?.assetDeliveryState?.state ?? "")")
        } else {
            logger.log("not found", level: .warning)
        }
    }
}

struct SubsReviewScreenshotsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Reserve a review-screenshot slot. Returns uploadOperations for the binary PUT step."
    )
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var fileName: String
    @Option(name: .long) var fileSize: Int
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let s = try await api.reviewScreenshots.create(
            subscriptionID: subscriptionId, fileName: fileName, fileSize: fileSize
        )
        if json { print(try SubsJSON.encode(s)); return }
        logger.log("reserved review screenshot \(s.id)", level: .success)
        print("  uploadOperations: \(s.attributes?.uploadOperations?.count ?? 0) chunk(s) to PUT")
    }
}

struct SubsReviewScreenshotsConfirmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "confirm",
        abstract: "Mark a review screenshot uploaded once the binary chunks have been PUT."
    )
    @Argument(help: "Review screenshot id.") var id: String
    @Option(name: .long, help: "Hex MD5 of the file bytes that were PUT.") var checksum: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let s = try await api.reviewScreenshots.confirmUpload(id: id, checksum: checksum)
        if json { print(try SubsJSON.encode(s)); return }
        logger.log("confirmed upload for \(s.id)", level: .success)
    }
}

struct SubsReviewScreenshotsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a review screenshot.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.reviewScreenshots.delete(id: id)
        logger.log("deleted review screenshot \(id)", level: .success)
    }
}

// MARK: - Images

struct SubsImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "images",
        abstract: "Promotional artwork attached to a subscription.",
        subcommands: [
            SubsImagesListCommand.self,
            SubsImagesCreateCommand.self,
            SubsImagesDeleteCommand.self,
        ]
    )
}

struct SubsImagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List promotional images.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let page = try await api.images.list(
            subscriptionID: subscriptionId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsJSON.encode(EncodablePage(items: page.items, nextCursor: page.nextCursor)))
            return
        }
        logger.header("Promotional images (\(page.items.count))")
        for i in page.items {
            print("  \(i.id)\t\(i.attributes?.fileName ?? "")\tstate=\(i.attributes?.state ?? "?")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsImagesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Reserve a slot for a promotional image.")
    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var fileName: String
    @Option(name: .long) var fileSize: Int
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        let img = try await api.images.create(
            subscriptionID: subscriptionId, fileName: fileName, fileSize: fileSize
        )
        if json { print(try SubsJSON.encode(img)); return }
        logger.log("reserved image \(img.id)", level: .success)
        print("  uploadOperations: \(img.attributes?.uploadOperations?.count ?? 0) chunk(s) to PUT")
    }
}

struct SubsImagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a promotional image.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveSubsAPI(logger: logger)
        try await api.images.delete(id: id)
        logger.log("deleted image \(id)", level: .success)
    }
}

// MARK: - Encodable page envelope

/// Wire shape for `--json` paginated output. Mirrors SubscriptionsAPI.Page
/// so the CLI can encode it without leaking the package-private container.
private struct EncodablePage<Item: Encodable>: Encodable {
    let items: [Item]
    let nextCursor: String?
}
