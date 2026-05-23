import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens reviews` parent command. Wraps the App Store Connect
/// Customer Reviews + Developer Responses APIs so a CLI user (or AI agent
/// driving the CLI) can list reviews, inspect one by id, and post / edit /
/// delete the developer response.
///
/// All subcommands resolve credentials with `ASCCredentialResolver.resolve()`
/// (env vars first, then `~/.storescreens/asc-credentials.yml`). Each
/// subcommand supports `--json` for machine-readable output; without
/// `--json` they emit compact human-readable text using the project's
/// shared `Logger`.
///
/// `storescreens reviews response …` exists as a nested namespace
/// (`response update`, `response delete`) so the verb-noun mapping mirrors
/// the underlying REST resources. The shorter `reviews respond` shortcut
/// is wired as a sibling for the common create-or-update flow.
struct ReviewsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reviews",
        abstract: "List App Store reviews and post developer responses.",
        discussion: """
            Reads the app id from `storescreens.yml` (app_store_connect.app_id) \
            when --app-id is omitted. Requires `storescreens auth login` or the \
            ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH env vars.

            Example:
              storescreens reviews list --rating 1 --unanswered
              storescreens reviews get --id ABC123
              storescreens reviews respond --id ABC123 --body "Thanks for the feedback!"
              storescreens reviews response update --id RESP456 --body "Updated reply"
              storescreens reviews response delete --id RESP456
            """,
        subcommands: [
            ReviewsListCommand.self,
            ReviewsGetCommand.self,
            ReviewsRespondCommand.self,
            ReviewsResponseCommand.self,
        ],
        defaultSubcommand: ReviewsListCommand.self
    )
}

// MARK: - Shared helpers

/// Common option block for "which app are we operating on" - the app id is
/// the only required argument for every reviews command. Pulls from
/// storescreens.yml when omitted on the command line.
private struct AppIDResolver {
    /// Returns a resolved app id (and the config path it came from, for
    /// error messages). Throws ExitCode(1) on failure after printing a
    /// pointer to the fix.
    static func resolve(explicit: String?, configPath: String, logger: Logger) throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        guard FileManager.default.fileExists(atPath: configPath) else {
            logger.log("no --app-id supplied and no \(configPath) to read app_id from", level: .error)
            print("  pass --app-id <numeric id> or add app_store_connect.app_id to storescreens.yml")
            throw ExitCode(1)
        }
        let config: CaptureConfig
        do {
            config = try ConfigLoader().load(from: configPath)
        } catch {
            logger.log("could not read \(configPath): \(error)", level: .error)
            throw ExitCode(1)
        }
        guard let appID = config.appStoreConnect?.appID, !appID.isEmpty else {
            logger.log("no app_store_connect.app_id in \(configPath); pass --app-id explicitly", level: .error)
            throw ExitCode(1)
        }
        return appID
    }
}

private struct ReviewsAuth {
    /// Resolves credentials and builds a `CustomerReviewsAPI` client.
    static func makeAPI(logger: Logger) throws -> CustomerReviewsAPI {
        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            logger.log("credentials not configured: \(error)", level: .error)
            print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
            throw ExitCode(1)
        }
        let client = ASCClient(credentials: creds)
        return CustomerReviewsAPI(client: client)
    }
}

/// Pretty JSON encoder shared by all `--json` paths. ISO 8601 dates, sorted
/// keys for diffable output.
private func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

/// Render a 1-5 rating as a row of filled / empty stars (ASCII; the project
/// convention is no emoji in output).
private func ratingStars(_ rating: Int?) -> String {
    guard let r = rating, r >= 0, r <= 5 else { return "(no rating)" }
    let filled = String(repeating: "*", count: r)
    let empty = String(repeating: "-", count: 5 - r)
    return "[\(filled)\(empty)]"
}

/// Human-readable date for review timestamps. Local TZ.
private let reviewDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = .current
    return f
}()

/// Single-line preview of a review body, truncated to ~80 characters.
private func bodySnippet(_ body: String?, max: Int = 80) -> String {
    guard let body, !body.isEmpty else { return "(no body)" }
    let collapsed = body
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .trimmingCharacters(in: .whitespaces)
    if collapsed.count <= max { return collapsed }
    let end = collapsed.index(collapsed.startIndex, offsetBy: max)
    return String(collapsed[..<end]) + "..."
}

/// JSON output shapes - kept in sync with the MCP wire format so scripted
/// consumers see one stable schema across CLI + MCP.
private struct ReviewJSONOut: Encodable {
    let id: String
    let rating: Int?
    let title: String?
    let body: String?
    let reviewerNickname: String?
    let createdDate: Date?
    let territory: String?

    init(_ r: CustomerReviewsAPI.CustomerReview) {
        self.id = r.id
        self.rating = r.attributes?.rating
        self.title = r.attributes?.title
        self.body = r.attributes?.body
        self.reviewerNickname = r.attributes?.reviewerNickname
        self.createdDate = r.attributes?.createdDate
        self.territory = r.attributes?.territory
    }
}

private struct ResponseJSONOut: Encodable {
    let id: String
    let responseBody: String?
    let lastModifiedDate: Date?
    let state: String?

    init(_ r: CustomerReviewsAPI.CustomerReviewResponse) {
        self.id = r.id
        self.responseBody = r.attributes?.responseBody
        self.lastModifiedDate = r.attributes?.lastModifiedDate
        self.state = r.attributes?.state
    }
}

// MARK: - list

struct ReviewsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List customer reviews for an app, with optional filters."
    )

    @Option(name: .long, help: "App Store Connect app id. Reads from storescreens.yml when omitted.")
    var appId: String?

    @Option(name: [.long, .customShort("c")], help: "Path to storescreens.yml.")
    var config: String = "storescreens.yml"

    @Option(name: .long, help: "ISO 3166-1 alpha-3 territory code (e.g. USA, GBR, JPN).")
    var territory: String?

    @Option(name: .long, help: "Filter to one star rating, 1 through 5.")
    var rating: Int?

    @Flag(name: .long, help: "Show only reviews that have NOT been answered by the developer.")
    var unanswered: Bool = false

    @Flag(name: .long, help: "Show only reviews that already have a developer response.")
    var answered: Bool = false

    @Flag(name: .long, help: "Show only reviews the customer has edited since first posting.")
    var edited: Bool = false

    @Option(name: .long, help: "Sort order: createdDateDesc (default), createdDateAsc, ratingDesc, ratingAsc.")
    var sort: String = "createdDateDesc"

    @Option(name: .long, help: "Page size, 1-200. Default 50 for human output, 200 with --all or --json.")
    var limit: Int?

    @Option(name: .long, help: "Cursor returned by a previous reviews list call (for paging).")
    var cursor: String?

    @Flag(name: .long, help: "Paginate through every matching review (up to 25 pages).")
    var all: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let appID = try AppIDResolver.resolve(explicit: appId, configPath: config, logger: logger)
        let api = try ReviewsAuth.makeAPI(logger: logger)

        if unanswered && answered {
            logger.log("--unanswered and --answered are mutually exclusive", level: .error)
            throw ExitCode(1)
        }
        let hasResponse: Bool? = unanswered ? false : (answered ? true : nil)
        let filters = CustomerReviewsAPI.ListFilters(
            territory: territory,
            rating: rating,
            edited: edited ? true : nil,
            hasResponse: hasResponse
        )
        let parsedSort: CustomerReviewsAPI.ReviewSort = {
            switch sort {
            case "createdDateAsc":  return .createdDateAsc
            case "ratingDesc":      return .ratingDesc
            case "ratingAsc":       return .ratingAsc
            default:                return .createdDateDesc
            }
        }()

        do {
            if all {
                let reviews = try await api.listAllReviews(
                    appID: appID,
                    filters: filters,
                    sort: parsedSort,
                    pageSize: limit ?? 200
                )
                if json {
                    try emitJSON(JSONListOutput(reviews: reviews.map(ReviewJSONOut.init), cursor: nil))
                } else {
                    printHumanList(reviews: reviews, cursor: nil, logger: logger)
                }
            } else {
                let pageSize = limit ?? (json ? 200 : 50)
                let page = try await api.listReviews(
                    appID: appID,
                    filters: filters,
                    sort: parsedSort,
                    limit: pageSize,
                    cursor: cursor
                )
                if json {
                    try emitJSON(JSONListOutput(reviews: page.reviews.map(ReviewJSONOut.init), cursor: page.cursor))
                } else {
                    printHumanList(reviews: page.reviews, cursor: page.cursor, logger: logger)
                }
            }
        } catch let e as ASCClient.APIError {
            logger.log("list failed: HTTP \(e.statusCode)", level: .error)
            for d in e.details { print("  [\(d.code)] \(d.title): \(d.detail)") }
            throw ExitCode(1)
        }
    }

    private func printHumanList(
        reviews: [CustomerReviewsAPI.CustomerReview],
        cursor: String?,
        logger: Logger
    ) {
        if reviews.isEmpty {
            logger.log("no reviews match these filters", level: .info)
            return
        }
        logger.header("Reviews (\(reviews.count))")
        for r in reviews {
            let stars = ratingStars(r.attributes?.rating)
            let title = r.attributes?.title ?? "(no title)"
            let reviewer = r.attributes?.reviewerNickname ?? "(anonymous)"
            let territory = r.attributes?.territory ?? "?"
            let dateStr = r.attributes?.createdDate.map { reviewDateFormatter.string(from: $0) } ?? "(no date)"
            let snippet = bodySnippet(r.attributes?.body)
            print("  \(stars) \(title)")
            print("       \(reviewer) (\(territory))  \(dateStr)  id: \(r.id)")
            print("       \(snippet)")
        }
        if let cursor {
            print("")
            print("  more pages available. Re-run with --cursor \(cursor)")
        }
    }

    private struct JSONListOutput: Encodable {
        let reviews: [ReviewJSONOut]
        let cursor: String?
    }
}

// MARK: - get

struct ReviewsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show a single customer review (and the developer response, if any)."
    )

    @Option(name: .long, help: "Customer review id.")
    var id: String

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try ReviewsAuth.makeAPI(logger: logger)

        do {
            guard let review = try await api.getReview(id: id) else {
                logger.log("no customer review with id \(id)", level: .error)
                throw ExitCode(1)
            }
            let response = try? await api.getResponse(reviewID: id)

            if json {
                struct Out: Encodable {
                    let review: ReviewJSONOut
                    let response: ResponseJSONOut?
                }
                try emitJSON(Out(
                    review: ReviewJSONOut(review),
                    response: response.map(ResponseJSONOut.init)
                ))
                return
            }

            logger.header("Review \(review.id)")
            let stars = ratingStars(review.attributes?.rating)
            let title = review.attributes?.title ?? "(no title)"
            let reviewer = review.attributes?.reviewerNickname ?? "(anonymous)"
            let territory = review.attributes?.territory ?? "?"
            let dateStr = review.attributes?.createdDate.map { reviewDateFormatter.string(from: $0) } ?? "(no date)"
            print("  rating:    \(stars)")
            print("  title:     \(title)")
            print("  reviewer:  \(reviewer)")
            print("  territory: \(territory)")
            print("  posted:    \(dateStr)")
            print("")
            print("  body:")
            let body = review.attributes?.body ?? "(no body)"
            for line in body.components(separatedBy: "\n") {
                print("    \(line)")
            }
            print("")
            if let response {
                let respDate = response.attributes?.lastModifiedDate.map { reviewDateFormatter.string(from: $0) } ?? "(no date)"
                let state = response.attributes?.state ?? "(no state)"
                logger.header("Developer response")
                print("  id:        \(response.id)")
                print("  state:     \(state)")
                print("  modified:  \(respDate)")
                print("")
                let respBody = response.attributes?.responseBody ?? "(no body)"
                for line in respBody.components(separatedBy: "\n") {
                    print("    \(line)")
                }
            } else {
                logger.log("no developer response yet", level: .info)
                print("  reply with: storescreens reviews respond --id \(review.id) --body \"...\"")
            }
        } catch let e as ASCClient.APIError {
            logger.log("get failed: HTTP \(e.statusCode)", level: .error)
            for d in e.details { print("  [\(d.code)] \(d.title): \(d.detail)") }
            throw ExitCode(1)
        }
    }
}

// MARK: - respond (create or update shortcut)

struct ReviewsRespondCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "respond",
        abstract: "Publish (or update) the developer response to a customer review."
    )

    @Option(name: .long, help: "Customer review id to respond to.")
    var id: String

    @Option(name: .long, help: "Response body text.")
    var body: String

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try ReviewsAuth.makeAPI(logger: logger)
        do {
            let resp = try await api.respondOrUpdate(reviewID: id, responseBody: body)
            if json {
                try emitJSON(ResponseJSONOut(resp))
                return
            }
            let state = resp.attributes?.state ?? "(unknown)"
            logger.log("response published (id \(resp.id), state \(state))", level: .success)
            if state == "PENDING_PUBLISH" {
                print("  Apple is moderating the response. It will appear on the App Store within minutes.")
            }
        } catch let e as ASCClient.APIError {
            logger.log("respond failed: HTTP \(e.statusCode)", level: .error)
            for d in e.details { print("  [\(d.code)] \(d.title): \(d.detail)") }
            throw ExitCode(1)
        }
    }
}

// MARK: - response (update/delete)

struct ReviewsResponseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "response",
        abstract: "Edit or delete an existing developer response.",
        subcommands: [
            ReviewsResponseUpdateCommand.self,
            ReviewsResponseDeleteCommand.self,
        ]
    )
}

struct ReviewsResponseUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Replace the body of an existing developer response."
    )

    @Option(name: .long, help: "Customer review response id (NOT the review id).")
    var id: String

    @Option(name: .long, help: "New response body text.")
    var body: String

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try ReviewsAuth.makeAPI(logger: logger)
        do {
            let resp = try await api.updateResponse(id: id, responseBody: body)
            if json {
                try emitJSON(ResponseJSONOut(resp))
                return
            }
            let state = resp.attributes?.state ?? "(unknown)"
            logger.log("response updated (id \(resp.id), state \(state))", level: .success)
        } catch let e as ASCClient.APIError {
            logger.log("update failed: HTTP \(e.statusCode)", level: .error)
            for d in e.details { print("  [\(d.code)] \(d.title): \(d.detail)") }
            throw ExitCode(1)
        }
    }
}

struct ReviewsResponseDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a developer response from a review."
    )

    @Option(name: .long, help: "Customer review response id to delete.")
    var id: String

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var force: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try ReviewsAuth.makeAPI(logger: logger)

        if !force {
            print("Delete response \(id)? Type 'yes' to confirm: ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer == "yes" || answer == "y" else {
                logger.log("aborted", level: .warning)
                throw ExitCode(1)
            }
        }

        do {
            try await api.deleteResponse(id: id)
            if json {
                struct Ack: Encodable { let deletedResponseID: String }
                try emitJSON(Ack(deletedResponseID: id))
                return
            }
            logger.log("deleted response \(id)", level: .success)
        } catch let e as ASCClient.APIError {
            logger.log("delete failed: HTTP \(e.statusCode)", level: .error)
            for d in e.details { print("  [\(d.code)] \(d.title): \(d.detail)") }
            throw ExitCode(1)
        }
    }
}
