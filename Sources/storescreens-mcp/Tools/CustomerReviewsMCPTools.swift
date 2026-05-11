import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for App Store Connect Customer Reviews + Developer
/// Responses. Mirrors the methods on `CustomerReviewsAPI` so an AI agent
/// can list, inspect, and respond to App Store reviews without crafting raw
/// ASC HTTP requests.
///
/// All tools resolve credentials through `ASCCredentialResolver.resolve()`
/// (env vars first, then `~/.storescreens/asc-credentials.yml`). Tools
/// return pretty-printed JSON in a single `.text` content block, with
/// `isError: true` set on failures.
///
/// Note: This file is loaded into the same MCP target as `Main.swift`.
/// `Main.swift` owns the actual server bootstrap and tool registration;
/// per the task constraints we do not edit `Main.swift` here, so the
/// dispatch glue lives unused until a separate wiring step plugs
/// `CustomerReviewsMCPTools.tools` into `StorescreensMCP.tools` and
/// `CustomerReviewsMCPTools.handle(_:)` into the dispatch `switch`.
package enum CustomerReviewsMCPTools {

    // MARK: - Tool catalog

    /// Every customer-reviews tool exposed by this MCP namespace. Names use
    /// snake_case (`reviews_<verb>`) so they sort together when listed
    /// alongside the existing capture/render tools.
    package static let tools: [Tool] = [
        Tool(
            name: "reviews_list",
            description: """
            List customer reviews for an App Store Connect app. Supports rich \
            filters: territory (ISO 3166-1 alpha-3), star rating (1-5), \
            whether the review has a developer response, and whether the \
            review was edited by the user. Results sorted newest-first by \
            default. Returns a JSON envelope with `reviews` and a `cursor` \
            for paginating further pages.
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
                        "description": .string("ISO 3166-1 alpha-3 territory code (e.g. \"USA\", \"GBR\", \"JPN\")."),
                    ]),
                    "rating": .object([
                        "type": .string("integer"),
                        "description": .string("Filter to one star rating, 1 through 5."),
                    ]),
                    "edited": .object([
                        "type": .string("boolean"),
                        "description": .string("Filter to reviews the customer has edited since first posting."),
                    ]),
                    "has_response": .object([
                        "type": .string("boolean"),
                        "description": .string("True: only reviews already answered by the developer. False: only unanswered reviews."),
                    ]),
                    "sort": .object([
                        "type": .string("string"),
                        "description": .string("Sort order. One of: createdDateDesc (default), createdDateAsc, ratingDesc, ratingAsc."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor from a previous reviews_list call; fetches the next page."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "reviews_get",
            description: """
            Fetch one customer review by its review id. Returns the review's \
            full attributes (rating, title, body, reviewerNickname, \
            createdDate, territory) plus the existing developer response if \
            present, so the caller can decide whether to create a new \
            response or update the current one.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "review_id": .object([
                        "type": .string("string"),
                        "description": .string("Customer review id (from reviews_list)."),
                    ]),
                ]),
                "required": .array([.string("review_id")]),
            ])
        ),
        Tool(
            name: "reviews_list_unanswered",
            description: """
            Compound helper: paginate through every customer review that \
            does NOT have a developer response yet, optionally narrowed by \
            territory and/or star rating. Useful for triage workflows like \
            \"show me every unanswered 1-star review in USA\".
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
                        "description": .string("Optional ISO 3166-1 alpha-3 territory code."),
                    ]),
                    "rating": .object([
                        "type": .string("integer"),
                        "description": .string("Optional star rating filter, 1 through 5."),
                    ]),
                    "sort": .object([
                        "type": .string("string"),
                        "description": .string("Sort order. Defaults to createdDateDesc (newest first)."),
                    ]),
                    "max_pages": .object([
                        "type": .string("integer"),
                        "description": .string("Safety cap on pagination depth. Default 25 (= up to 5000 reviews)."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "reviews_response_create",
            description: """
            Publish the developer's response to a customer review. \
            One response per review; on a review that already has a \
            response, prefer reviews_response_update. Apple moderates \
            responses asynchronously, so the returned `state` is often \
            PENDING_PUBLISH at first and transitions to PUBLISHED on the \
            App Store within minutes.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "review_id": .object([
                        "type": .string("string"),
                        "description": .string("Customer review id to respond to."),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Response body text. Apple's review-response guidelines apply: be respectful, non-promotional, and keep customer PII out."),
                    ]),
                ]),
                "required": .array([.string("review_id"), .string("body")]),
            ])
        ),
        Tool(
            name: "reviews_response_update",
            description: """
            Edit an existing developer response. Replaces the `responseBody` \
            and re-submits the response to Apple's moderation pipeline.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "response_id": .object([
                        "type": .string("string"),
                        "description": .string("Customer review response id (from reviews_get or reviews_list with has_response: true)."),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("New response body text."),
                    ]),
                ]),
                "required": .array([.string("response_id"), .string("body")]),
            ])
        ),
        Tool(
            name: "reviews_response_delete",
            description: """
            Delete the developer response from a review. The customer's \
            review is unaffected; the response disappears from the App \
            Store listing.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "response_id": .object([
                        "type": .string("string"),
                        "description": .string("Customer review response id to delete."),
                    ]),
                ]),
                "required": .array([.string("response_id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Routes a `CallTool.Parameters` whose name starts with `reviews_` to
    /// the right handler. Returns `nil` when the tool name does not belong
    /// to this namespace, so `Main.swift` can fall through to its own
    /// dispatch table.
    package static func handle(
        _ params: CallTool.Parameters
    ) async throws -> CallTool.Result? {
        switch params.name {
        case "reviews_list":             return try await handleList(params)
        case "reviews_get":              return try await handleGet(params)
        case "reviews_list_unanswered":  return try await handleListUnanswered(params)
        case "reviews_response_create":  return try await handleResponseCreate(params)
        case "reviews_response_update":  return try await handleResponseUpdate(params)
        case "reviews_response_delete":  return try await handleResponseDelete(params)
        default:
            return nil
        }
    }

    // MARK: - Handlers

    static func handleList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }

        let filters = CustomerReviewsAPI.ListFilters(
            territory: params.arguments?["territory"]?.stringValue,
            rating: params.arguments?["rating"]?.intValue,
            edited: params.arguments?["edited"]?.boolValue,
            hasResponse: params.arguments?["has_response"]?.boolValue
        )
        let sort = parseSort(params.arguments?["sort"]?.stringValue)
        let limit = params.arguments?["limit"]?.intValue ?? 200
        let cursor = params.arguments?["cursor"]?.stringValue

        do {
            let api = try makeAPI()
            let page = try await api.listReviews(
                appID: appID,
                filters: filters,
                sort: sort,
                limit: limit,
                cursor: cursor
            )
            let payload = ReviewsListPayload(
                reviews: page.reviews.map(ReviewJSON.init),
                cursor: page.cursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("reviews_list failed: \(error)")
        }
    }

    static func handleGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let reviewID = params.arguments?["review_id"]?.stringValue, !reviewID.isEmpty else {
            return errorResult("Missing required parameter: review_id")
        }
        do {
            let api = try makeAPI()
            guard let review = try await api.getReview(id: reviewID) else {
                return errorResult("No customer review with id \(reviewID)")
            }
            let response = try? await api.getResponse(reviewID: reviewID)
            let payload = ReviewWithResponseJSON(
                review: ReviewJSON(review),
                response: response.map(ResponseJSON.init)
            )
            return jsonResult(payload)
        } catch {
            return errorResult("reviews_get failed: \(error)")
        }
    }

    static func handleListUnanswered(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        let territory = params.arguments?["territory"]?.stringValue
        let rating = params.arguments?["rating"]?.intValue
        let sort = parseSort(params.arguments?["sort"]?.stringValue)
        let maxPages = params.arguments?["max_pages"]?.intValue ?? 25

        do {
            let api = try makeAPI()
            let reviews = try await api.listAllUnanswered(
                appID: appID,
                territory: territory,
                rating: rating,
                sort: sort,
                maxPages: maxPages
            )
            let payload = UnansweredPayload(
                count: reviews.count,
                reviews: reviews.map(ReviewJSON.init)
            )
            return jsonResult(payload)
        } catch {
            return errorResult("reviews_list_unanswered failed: \(error)")
        }
    }

    static func handleResponseCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let reviewID = params.arguments?["review_id"]?.stringValue, !reviewID.isEmpty else {
            return errorResult("Missing required parameter: review_id")
        }
        guard let body = params.arguments?["body"]?.stringValue, !body.isEmpty else {
            return errorResult("Missing required parameter: body")
        }
        do {
            let api = try makeAPI()
            let response = try await api.createResponse(reviewID: reviewID, responseBody: body)
            return jsonResult(ResponseJSON(response))
        } catch {
            return errorResult("reviews_response_create failed: \(error)")
        }
    }

    static func handleResponseUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["response_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: response_id")
        }
        guard let body = params.arguments?["body"]?.stringValue, !body.isEmpty else {
            return errorResult("Missing required parameter: body")
        }
        do {
            let api = try makeAPI()
            let response = try await api.updateResponse(id: id, responseBody: body)
            return jsonResult(ResponseJSON(response))
        } catch {
            return errorResult("reviews_response_update failed: \(error)")
        }
    }

    static func handleResponseDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["response_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: response_id")
        }
        do {
            let api = try makeAPI()
            try await api.deleteResponse(id: id)
            return jsonResult(DeleteAck(deletedResponseID: id))
        } catch {
            return errorResult("reviews_response_delete failed: \(error)")
        }
    }

    // MARK: - JSON shapes (stable wire format)

    struct ReviewsListPayload: Encodable {
        let reviews: [ReviewJSON]
        let cursor: String?
    }

    struct UnansweredPayload: Encodable {
        let count: Int
        let reviews: [ReviewJSON]
    }

    struct ReviewWithResponseJSON: Encodable {
        let review: ReviewJSON
        let response: ResponseJSON?
    }

    struct ReviewJSON: Encodable {
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

    struct ResponseJSON: Encodable {
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

    struct DeleteAck: Encodable {
        let deletedResponseID: String
    }

    // MARK: - Helpers

    static func makeAPI() throws -> CustomerReviewsAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return CustomerReviewsAPI(client: client)
    }

    static func parseSort(_ raw: String?) -> CustomerReviewsAPI.ReviewSort {
        switch raw {
        case "createdDateAsc":  return .createdDateAsc
        case "ratingDesc":      return .ratingDesc
        case "ratingAsc":       return .ratingAsc
        case "createdDateDesc": return .createdDateDesc
        default:                return .createdDateDesc
        }
    }

    static func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
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
