import ArgumentParser
import Foundation
import StorescreensCore

/// Parent command for the subscription additions covered by
/// `Wave4ExtrasAPI.SubscriptionExtras`: introductory offers, win-back
/// offers, billing grace periods, group-wide submissions, and the
/// standalone subscription-price-point GET by id.
///
/// All subcommands resolve credentials through
/// `ASCCredentialResolver.resolve()` and emit either a human-readable
/// summary or pretty-printed JSON (with `--json`). This file does not
/// register itself in Main.swift; the parent agent wires it in when
/// integrating.
struct SubscriptionExtrasCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subs-extras",
        abstract: "Late-arriving subscription resources (intro offers, win-back, grace periods, group submissions).",
        discussion: """
            Wraps the subscription resources that did not fit into the \
            original `subscriptions` parent command. Requires ASC credentials \
            (run `storescreens auth login`, or set ASC_KEY_ID / \
            ASC_ISSUER_ID / ASC_KEY_PATH).
            """,
        subcommands: [
            SubsExtrasIntroOffersCommand.self,
            SubsExtrasWinBackOffersCommand.self,
            SubsExtrasGracePeriodCommand.self,
            SubsExtrasGroupSubmissionCommand.self,
            SubsExtrasPricePointGetCommand.self,
        ]
    )
}

// MARK: - Shared plumbing

private enum SubsExtrasJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private func resolveExtrasAPI(logger: Logger) async throws -> Wave4ExtrasAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return Wave4ExtrasAPI(client: client)
}

private let subsExtrasISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func parseExtrasDate(_ str: String?) -> Date? {
    guard let str else { return nil }
    if let d = subsExtrasISO8601.date(from: str) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: str)
}

private struct EncodableExtrasPage<Item: Encodable>: Encodable {
    let items: [Item]
    let nextCursor: String?
}

// MARK: - Intro offers

struct SubsExtrasIntroOffersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "intro-offers",
        abstract: "Introductory offers for new subscribers.",
        subcommands: [
            SubsExtrasIntroOffersCreateCommand.self,
            SubsExtrasIntroOffersUpdateCommand.self,
            SubsExtrasIntroOffersDeleteCommand.self,
        ]
    )
}

struct SubsExtrasIntroOffersCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an introductory offer."
    )

    @Option(name: .long) var subscriptionId: String
    @Option(name: .long, help: "Apple territory id (e.g. USA).") var territoryId: String
    @Option(name: .long, help: "subscriptionPricePoint id.") var pricePointId: String
    @Option(name: .long, help: "PAY_AS_YOU_GO | PAY_UP_FRONT | FREE_TRIAL.") var offerMode: String
    @Option(name: .long, help: "Apple duration enum (e.g. ONE_MONTH).") var duration: String
    @Option(name: .long, help: "Number of periods the offer covers.") var numberOfPeriods: Int
    @Option(name: .long, help: "Optional ISO 8601 start date.") var startDate: String?
    @Option(name: .long, help: "Optional ISO 8601 end date.") var endDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        let offer = try await api.createIntroductoryOffer(
            subscriptionID: subscriptionId,
            territoryID: territoryId,
            pricePointID: pricePointId,
            offerMode: offerMode,
            duration: duration,
            numberOfPeriods: numberOfPeriods,
            startDate: parseExtrasDate(startDate),
            endDate: parseExtrasDate(endDate)
        )
        if json {
            print(try SubsExtrasJSON.encode(offer))
        } else {
            logger.log("created intro offer \(offer.id)", level: .success)
        }
    }
}

struct SubsExtrasIntroOffersUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an intro offer's date range."
    )

    @Argument(help: "subscriptionIntroductoryOffer id") var id: String
    @Option(name: .long) var startDate: String?
    @Option(name: .long) var endDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        let offer = try await api.updateIntroductoryOffer(
            id: id,
            startDate: parseExtrasDate(startDate),
            endDate: parseExtrasDate(endDate)
        )
        if json {
            print(try SubsExtrasJSON.encode(offer))
        } else {
            logger.log("updated intro offer \(offer.id)", level: .success)
        }
    }
}

struct SubsExtrasIntroOffersDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an intro offer by id."
    )

    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        try await api.deleteIntroductoryOffer(id: id)
        logger.log("deleted intro offer \(id)", level: .success)
    }
}

// MARK: - Win-back offers

struct SubsExtrasWinBackOffersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "winback-offers",
        abstract: "Win-back offers for lapsed subscribers.",
        subcommands: [
            SubsExtrasWinBackOffersListCommand.self,
            SubsExtrasWinBackOffersGetCommand.self,
            SubsExtrasWinBackOffersCreateCommand.self,
            SubsExtrasWinBackOffersUpdateCommand.self,
            SubsExtrasWinBackOffersDeleteCommand.self,
            SubsExtrasWinBackPricesListCommand.self,
            SubsExtrasWinBackPricesCreateCommand.self,
        ]
    )
}

struct SubsExtrasWinBackOffersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List win-back offers on a subscription."
    )

    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        let page = try await api.listWinBackOffers(
            subscriptionID: subscriptionId, limit: limit, cursor: cursor
        )
        if json {
            print(try SubsExtrasJSON.encode(
                EncodableExtrasPage(items: page.items, nextCursor: page.nextCursor)
            ))
            return
        }
        logger.header("Win-back offers (\(page.items.count))")
        for o in page.items {
            print("  \(o.id)\t\(o.attributes?.name ?? "")\tstate=\(o.attributes?.state ?? "")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsExtrasWinBackOffersGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a win-back offer.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        guard let offer = try await api.getWinBackOffer(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json {
            print(try SubsExtrasJSON.encode(offer))
        } else {
            logger.header("Win-back offer")
            print("  id:    \(offer.id)")
            print("  name:  \(offer.attributes?.name ?? "(none)")")
            print("  code:  \(offer.attributes?.offerCode ?? "(none)")")
            print("  state: \(offer.attributes?.state ?? "(none)")")
        }
    }
}

struct SubsExtrasWinBackOffersCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a win-back offer.")

    @Option(name: .long) var subscriptionId: String
    @Option(name: .long) var name: String
    @Option(name: .long) var offerCode: String
    @Option(name: .long, help: "PAY_AS_YOU_GO | PAY_UP_FRONT | FREE_TRIAL.") var offerMode: String
    @Option(name: .long) var duration: String
    @Option(name: .long) var numberOfPeriods: Int
    @Option(name: .long) var startDate: String?
    @Option(name: .long) var endDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        let offer = try await api.createWinBackOffer(
            subscriptionID: subscriptionId,
            name: name,
            offerCode: offerCode,
            offerMode: offerMode,
            duration: duration,
            numberOfPeriods: numberOfPeriods,
            startDate: parseExtrasDate(startDate),
            endDate: parseExtrasDate(endDate)
        )
        if json {
            print(try SubsExtrasJSON.encode(offer))
        } else {
            logger.log("created win-back offer \(offer.id)", level: .success)
        }
    }
}

struct SubsExtrasWinBackOffersUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a win-back offer.")
    @Argument var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var startDate: String?
    @Option(name: .long) var endDate: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        let offer = try await api.updateWinBackOffer(
            id: id,
            name: name,
            startDate: parseExtrasDate(startDate),
            endDate: parseExtrasDate(endDate)
        )
        if json {
            print(try SubsExtrasJSON.encode(offer))
        } else {
            logger.log("updated win-back offer \(offer.id)", level: .success)
        }
    }
}

struct SubsExtrasWinBackOffersDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a win-back offer.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        try await api.deleteWinBackOffer(id: id)
        logger.log("deleted win-back offer \(id)", level: .success)
    }
}

struct SubsExtrasWinBackPricesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prices-list",
        abstract: "List per-territory prices on a win-back offer."
    )
    @Option(name: .long) var offerId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        let page = try await api.listWinBackOfferPrices(
            offerID: offerId, limit: limit, cursor: cursor
        )
        let ids = page.items.map { ["id": $0.id] }
        if json {
            print(try SubsExtrasJSON.encode(
                EncodableExtrasPage(items: ids, nextCursor: page.nextCursor)
            ))
            return
        }
        logger.header("Win-back offer prices (\(page.items.count))")
        for p in page.items { print("  \(p.id)") }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct SubsExtrasWinBackPricesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prices-create",
        abstract: "Attach a (territory, price-point) tuple to a win-back offer."
    )
    @Option(name: .long) var offerId: String
    @Option(name: .long) var territoryId: String
    @Option(name: .long, help: "subscriptionPricePoint id.") var pricePointId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        let price = try await api.createWinBackOfferPrice(
            offerID: offerId, territoryID: territoryId, pricePointID: pricePointId
        )
        if json {
            print(try SubsExtrasJSON.encode(["id": price.id]))
        } else {
            logger.log("created win-back offer price \(price.id)", level: .success)
        }
    }
}

// MARK: - Grace period

struct SubsExtrasGracePeriodCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grace-period",
        abstract: "Subscription billing grace period config.",
        subcommands: [
            SubsExtrasGracePeriodGetCommand.self,
            SubsExtrasGracePeriodUpdateCommand.self,
        ]
    )
}

struct SubsExtrasGracePeriodGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a subscription group's grace period.")
    @Option(name: .long, help: "subscriptionGroup id.") var groupId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        guard let gp = try await api.getGracePeriod(groupID: groupId) else {
            logger.log("no grace period configured", level: .warning)
            return
        }
        if json {
            print(try SubsExtrasJSON.encode(gp))
        } else {
            logger.header("Grace period")
            print("  id:           \(gp.id)")
            print("  optIn:        \(gp.attributes?.optIn.map(String.init(describing:)) ?? "(none)")")
            print("  renewalType:  \(gp.attributes?.renewalType ?? "(none)")")
        }
    }
}

struct SubsExtrasGracePeriodUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a grace period record.")
    @Argument(help: "subscriptionGracePeriod record id") var id: String
    @Option(name: .long) var optIn: Bool?
    @Option(name: .long, help: "SIX_DAYS | SIXTEEN_DAYS | THIRTY_DAYS.") var renewalType: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        let gp = try await api.updateGracePeriod(
            id: id, optIn: optIn, renewalType: renewalType
        )
        if json {
            print(try SubsExtrasJSON.encode(gp))
        } else {
            logger.log("updated grace period \(gp.id)", level: .success)
        }
    }
}

// MARK: - Group submission

struct SubsExtrasGroupSubmissionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group-submission",
        abstract: "One-shot submit-for-review covering a whole subscription group.",
        subcommands: [
            SubsExtrasGroupSubmissionCreateCommand.self,
        ]
    )
}

struct SubsExtrasGroupSubmissionCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Submit a subscription group for review."
    )
    @Option(name: .long, help: "subscriptionGroup id.") var groupId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        let sub = try await api.createGroupSubmission(groupID: groupId)
        if json {
            print(try SubsExtrasJSON.encode(sub))
        } else {
            logger.log("created group submission \(sub.id) state=\(sub.attributes?.state ?? "?")", level: .success)
        }
    }
}

// MARK: - Price point GET

struct SubsExtrasPricePointGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "price-point-get",
        abstract: "Fetch a single subscriptionPricePoint by id."
    )
    @Argument(help: "subscriptionPricePoint id") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveExtrasAPI(logger: logger).subscriptionExtras
        guard let pp = try await api.getPricePoint(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json {
            print(try SubsExtrasJSON.encode(pp))
        } else {
            logger.header("Subscription price point")
            print("  id:             \(pp.id)")
            print("  customerPrice:  \(pp.attributes?.customerPrice ?? "(none)")")
            print("  proceeds:       \(pp.attributes?.proceeds ?? "(none)")")
        }
    }
}
