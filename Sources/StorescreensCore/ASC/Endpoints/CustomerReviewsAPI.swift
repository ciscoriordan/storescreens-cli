import Foundation

/// App Store Connect endpoints covering the Customer Reviews feature: the
/// star-ratings and free-form reviews customers leave on an app's App Store
/// listing, plus the developer's per-review reply ("Developer Response").
///
/// Read-only for `customerReviews` themselves (developers can't post a
/// customer review). The only write operations live on
/// `customerReviewResponses`, where the developer can publish a single
/// response per review, edit it, or delete it.
///
/// Apple's docs:
///   - https://developer.apple.com/documentation/appstoreconnectapi/customer_reviews
///   - https://developer.apple.com/documentation/appstoreconnectapi/customerreview
///   - https://developer.apple.com/documentation/appstoreconnectapi/customerreviewresponse
///
/// NOTE: Apple also exposes a separate, legacy `customerReviewResponseV1`
/// resource for the older response shape. It is deprecated in favor of
/// `customerReviewResponses` and intentionally not wrapped here. New code
/// (CLI and MCP) routes everything through the v1 `customerReviewResponses`
/// resource only.
///
/// NOTE: A separate per-territory rating summary resource is not currently
/// exposed by this wrapper. Apple lists it under "ratings" in some surface
/// areas (`customerReviewSummarizations`) but the v1 shape is undocumented
/// in the public ASC reference and we have not seen it return data in test
/// runs. Callers who need a quick territory breakdown can list reviews
/// once and group by `attributes.territory` in-process (see
/// `listAllUnanswered` for a working multi-page pattern). When Apple
/// publishes a stable summary resource we'll add it as a new method here.
package struct CustomerReviewsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Models

    /// One customer review on the App Store. Read-only from a developer's
    /// perspective: the API does not let you create, edit, or delete a
    /// customer review (only the developer's reply, see
    /// `CustomerReviewResponse`).
    package struct CustomerReview: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Star rating, 1 to 5. ASC returns this as an integer.
            package let rating: Int?
            /// Review title (short, optional in the reviewer UI).
            package let title: String?
            /// Review body. Can be empty when the reviewer left only a star
            /// rating with no text.
            package let body: String?
            /// The display name the reviewer chose on the App Store.
            package let reviewerNickname: String?
            /// When the review was posted by the customer. ISO 8601.
            package let createdDate: Date?
            /// ISO 3166-1 alpha-3 territory the reviewer's App Store account
            /// is registered in (e.g. "USA", "GBR", "JPN").
            package let territory: String?
        }
    }

    /// Developer's published response to a customer review. There is at most
    /// one response per review; writing a new one replaces the previous
    /// `responseBody`.
    package struct CustomerReviewResponse: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// The body of the developer response, as it appears on the App
            /// Store under "Developer Response".
            package let responseBody: String?
            /// When the developer last edited the response. ISO 8601.
            package let lastModifiedDate: Date?
            /// Workflow state. Typically "PUBLISHED" once Apple's moderation
            /// has cleared the response. "PENDING_PUBLISH" appears briefly
            /// after a `respond` POST while Apple is processing.
            package let state: String?
        }
    }

    // MARK: - Pagination envelope

    /// Page of customer reviews returned by the list endpoint. `cursor` is
    /// Apple's pagination token: pass it back as the `cursor` argument to
    /// `listReviews` to fetch the next page. Nil cursor means there are no
    /// more pages.
    package struct ReviewsPage: Sendable {
        package let reviews: [CustomerReview]
        package let cursor: String?
    }

    // MARK: - List filters

    /// Optional filters supported by `listReviews`. Combine any subset.
    package struct ListFilters: Sendable, Equatable {
        /// ISO 3166-1 alpha-3 territory code, e.g. "USA", "GBR".
        package var territory: String?
        /// Star rating to match exactly. ASC also accepts ranges but the
        /// public API only supports equality here.
        package var rating: Int?
        /// True to return only reviews whose body or title was edited by the
        /// reviewer after first publish. Apple exposes this as
        /// `filter[edited]`.
        package var edited: Bool?
        /// True to return only reviews that already have a developer
        /// response; false for reviews still waiting for a reply.
        ///
        /// Apple expresses this with
        /// `filter[publishedResponse.state]`: presence implies a response,
        /// so we encode it as `PUBLISHED` (has response) or omit the param
        /// and post-filter in-process for "no response" (the API does not
        /// have a negation filter). See `listReviews` for the actual logic.
        package var hasResponse: Bool?

        package init(
            territory: String? = nil,
            rating: Int? = nil,
            edited: Bool? = nil,
            hasResponse: Bool? = nil
        ) {
            self.territory = territory
            self.rating = rating
            self.edited = edited
            self.hasResponse = hasResponse
        }
    }

    /// Sort directions accepted by `listReviews`. Apple supports sorting by
    /// `createdDate` and `rating` in either direction. Default is
    /// `createdDateDesc` (newest first), which matches the App Store web UI.
    package enum ReviewSort: String, Sendable {
        case createdDateDesc = "-createdDate"
        case createdDateAsc  = "createdDate"
        case ratingDesc      = "-rating"
        case ratingAsc       = "rating"
    }

    // MARK: - Reviews: list / get

    /// Lists reviews for the app. Returns a page of results plus an optional
    /// `cursor` to fetch the next page.
    ///
    /// The `hasResponse: false` filter requires post-processing because ASC
    /// only natively supports filtering for the *presence* of a published
    /// response via `filter[publishedResponse.state]`. To express "give me
    /// unanswered reviews" we list without that filter and drop any review
    /// that has a `publishedResponse` relationship. The wire-side pagination
    /// is preserved exactly.
    package func listReviews(
        appID: String,
        filters: ListFilters = ListFilters(),
        sort: ReviewSort = .createdDateDesc,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> ReviewsPage {
        var query: [String: String] = [
            "limit": String(max(1, min(limit, 200))),
            "sort": sort.rawValue,
        ]
        if let territory = filters.territory { query["filter[territory]"] = territory }
        if let rating = filters.rating       { query["filter[rating]"]    = String(rating) }
        if let edited = filters.edited       { query["filter[edited]"]    = edited ? "true" : "false" }

        // Native filter only encodes "must have a published response".
        // "Has no response" is post-filtered below by inspecting each
        // review's `publishedResponse` relationship via an include.
        if filters.hasResponse == true {
            query["filter[publishedResponse.state]"] = "PUBLISHED"
        }
        if filters.hasResponse == false {
            // Ask ASC to side-load the response relationship so we can tell
            // which reviews already have one without an extra per-review GET.
            query["include"] = "response"
        }
        if let cursor { query["cursor"] = cursor }

        struct Resp: Decodable {
            struct DataEntry: Decodable {
                let id: String
                let attributes: CustomerReview.Attributes?
                let relationships: Relationships?
                struct Relationships: Decodable {
                    let response: ResponseRel?
                    struct ResponseRel: Decodable {
                        let data: Ref?
                        struct Ref: Decodable { let id: String; let type: String }
                    }
                }
            }
            struct Links: Decodable { let next: String? }
            let data: [DataEntry]
            let links: Links?
        }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/customerReviews",
            query: query,
            as: Resp.self
        )

        // Translate Apple's `links.next` (a fully-qualified URL with the next
        // cursor embedded) into the bare cursor token callers pass back.
        let nextCursor: String? = {
            guard let next = resp.links?.next else { return nil }
            return Self.extractCursor(from: next)
        }()

        let raw = resp.data.map { d in
            CustomerReview(id: d.id, attributes: d.attributes)
        }

        // Apply the local-only `hasResponse: false` filter by dropping rows
        // whose included `response` relationship has data attached.
        let filtered: [CustomerReview]
        if filters.hasResponse == false {
            let answeredIDs = Set(
                resp.data.compactMap { d -> String? in
                    guard d.relationships?.response?.data != nil else { return nil }
                    return d.id
                }
            )
            filtered = raw.filter { !answeredIDs.contains($0.id) }
        } else {
            filtered = raw
        }

        return ReviewsPage(reviews: filtered, cursor: nextCursor)
    }

    /// Pulls all pages of `listReviews` up to `maxPages` (safety cap). Use
    /// for compound operations like "every unanswered review for triage."
    /// Defaults to 25 pages \* 200 reviews = 5,000 reviews max; bump
    /// `maxPages` when you genuinely need everything.
    package func listAllReviews(
        appID: String,
        filters: ListFilters = ListFilters(),
        sort: ReviewSort = .createdDateDesc,
        pageSize: Int = 200,
        maxPages: Int = 25
    ) async throws -> [CustomerReview] {
        var collected: [CustomerReview] = []
        var cursor: String? = nil
        var page = 0
        repeat {
            let result = try await listReviews(
                appID: appID,
                filters: filters,
                sort: sort,
                limit: pageSize,
                cursor: cursor
            )
            collected.append(contentsOf: result.reviews)
            cursor = result.cursor
            page += 1
        } while cursor != nil && page < maxPages
        return collected
    }

    /// Lists reviews that have no developer response yet. Convenience over
    /// `listAllReviews(filters: ListFilters(hasResponse: false))` for the
    /// common "what still needs a reply" workflow.
    package func listAllUnanswered(
        appID: String,
        territory: String? = nil,
        rating: Int? = nil,
        sort: ReviewSort = .createdDateDesc,
        maxPages: Int = 25
    ) async throws -> [CustomerReview] {
        var filters = ListFilters(hasResponse: false)
        filters.territory = territory
        filters.rating = rating
        return try await listAllReviews(
            appID: appID,
            filters: filters,
            sort: sort,
            maxPages: maxPages
        )
    }

    /// GET `/v1/customerReviews/{id}`. Returns nil on 404 so callers can
    /// distinguish "no such review" from any other transport error.
    package func getReview(id: String) async throws -> CustomerReview? {
        struct Resp: Decodable { let data: CustomerReview }
        do {
            let resp: Resp = try await client.get(
                path: "customerReviews/\(id)",
                as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// GET `/v1/customerReviews/{id}/response`. Returns nil when the review
    /// has no developer response yet (404 or empty data envelope) so the
    /// caller can decide between POST (create) and PATCH (update).
    package func getResponse(reviewID: String) async throws -> CustomerReviewResponse? {
        struct Resp: Decodable {
            struct DataObj: Decodable {
                let id: String
                let attributes: CustomerReviewResponse.Attributes?
            }
            let data: DataObj?
        }
        do {
            let resp: Resp = try await client.get(
                path: "customerReviews/\(reviewID)/response",
                as: Resp.self
            )
            guard let d = resp.data else { return nil }
            return CustomerReviewResponse(id: d.id, attributes: d.attributes)
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    // MARK: - Responses: create / update / delete

    /// POST `/v1/customerReviewResponses`. Publishes the developer's reply
    /// to `reviewID`. ASC moderates the response asynchronously; the
    /// returned `attributes.state` is typically `PENDING_PUBLISH` until
    /// moderation completes, then `PUBLISHED`.
    ///
    /// Apple enforces one response per review. Calling create on a review
    /// that already has a response will 409 with an `already exists`
    /// detail. Prefer `respondOrUpdate` from a script: it does the find
    /// then routes to POST or PATCH.
    @discardableResult
    package func createResponse(
        reviewID: String,
        responseBody: String
    ) async throws -> CustomerReviewResponse {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "customerReviewResponses"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let responseBody: String
            }
            struct Rels: Encodable {
                struct Review: Encodable {
                    struct Data: Encodable { let type = "customerReviews"; let id: String }
                    let data: Data
                }
                let review: Review
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(responseBody: responseBody),
            relationships: .init(review: .init(data: .init(id: reviewID)))
        ))
        struct Resp: Decodable { let data: CustomerReviewResponse }
        let resp: Resp = try await client.post(
            path: "customerReviewResponses",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// PATCH `/v1/customerReviewResponses/{id}`. Replaces the existing
    /// `responseBody` with the supplied text. Apple re-runs moderation, so
    /// the response can briefly drop back to `PENDING_PUBLISH`.
    @discardableResult
    package func updateResponse(
        id: String,
        responseBody: String
    ) async throws -> CustomerReviewResponse {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "customerReviewResponses"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let responseBody: String
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(responseBody: responseBody)
        ))
        struct Resp: Decodable { let data: CustomerReviewResponse }
        let resp: Resp = try await client.patch(
            path: "customerReviewResponses/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/customerReviewResponses/{id}`. Removes the developer
    /// response. The customer review itself is unaffected.
    package func deleteResponse(id: String) async throws {
        try await client.delete(path: "customerReviewResponses/\(id)")
    }

    /// Find-or-create convenience: if the review already has a response,
    /// PATCH it; otherwise POST a fresh one. Idempotent for repeat
    /// invocations from a script.
    @discardableResult
    package func respondOrUpdate(
        reviewID: String,
        responseBody: String
    ) async throws -> CustomerReviewResponse {
        if let existing = try await getResponse(reviewID: reviewID) {
            return try await updateResponse(id: existing.id, responseBody: responseBody)
        }
        return try await createResponse(reviewID: reviewID, responseBody: responseBody)
    }

    // MARK: - Helpers

    /// Pulls the `cursor` query parameter out of a fully-qualified Apple
    /// pagination URL. Apple's pagination contract is "give us back the
    /// cursor we gave you", so callers want the bare token, not the URL.
    static func extractCursor(from urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }
}
