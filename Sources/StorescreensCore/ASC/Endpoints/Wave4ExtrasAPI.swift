import Foundation
import CryptoKit

/// App Store Connect endpoints for the long tail of small resource families
/// that landed in Apple's API after the initial Wave 1-3 coverage. This is a
/// grab-bag: subscription additions that didn't fit in `SubscriptionsAPI`
/// (intro offers, win-back offers, grace periods, group submissions, the
/// missing price-point-by-id read), customer review summarizations + app
/// review attachments, and the niche late-2025 resources (merchantIds,
/// nominations, appTags, endUserLicenseAgreements, androidToIosAppMappingDetails,
/// actors, appPricePoints V3, appClipAdvancedExperienceImages,
/// inAppPurchaseAvailabilities, inAppPurchaseContents, territoryAvailabilities).
///
/// The wrapper follows the existing AppsAPI / SubscriptionsAPI conventions:
/// JSON:API shaped Codable models, `package` access, 404 → nil where
/// applicable, and 409 "already set" surfaced via APIError.isAlreadySetConflict.
/// Paginated lists accept `limit: Int = 200, cursor: String? = nil` and
/// return the next-page cursor alongside the data.
///
/// Note: some of these resources (notably `customerReviewSummarizations`,
/// `appStoreReviewAttachments`, `nominations`, `appTags`, `actors`,
/// `androidToIosAppMappingDetails`) shipped in Apple's API at v4.0 or later
/// and have minimal public schema documentation. The Codable models capture
/// every attribute Apple has surfaced in test envelopes; future Apple changes
/// may add fields that ride through as ignored values. We surface only the
/// stable subset here, callers needing extra fields can extend Attributes.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi
package struct Wave4ExtrasAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Nested namespaces

    package var subscriptionExtras: SubscriptionExtras { SubscriptionExtras(client: client) }
    package var customerReviewExtras: CustomerReviewExtras { CustomerReviewExtras(client: client) }
    package var merchant: Merchant { Merchant(client: client) }
    package var nominations: Nominations { Nominations(client: client) }
    package var appTags: AppTags { AppTags(client: client) }
    package var eulas: EULAs { EULAs(client: client) }
    package var androidMapping: AndroidMapping { AndroidMapping(client: client) }
    package var actors: Actors { Actors(client: client) }
    package var pricePointsV3: PricePointsV3 { PricePointsV3(client: client) }
    package var appClipAdvancedImages: AppClipAdvancedImages { AppClipAdvancedImages(client: client) }
    package var iapAvailabilities: IAPAvailabilities { IAPAvailabilities(client: client) }
    package var iapContents: IAPContents { IAPContents(client: client) }
    package var territoryAvailabilities: TerritoryAvailabilities { TerritoryAvailabilities(client: client) }

    // MARK: - Shared pagination plumbing

    /// One page of results plus the cursor to fetch the next page. Mirrors
    /// the pattern used by `SubscriptionsAPI.Page`; defined here so this
    /// file does not depend on SubscriptionsAPI's private fileprivate
    /// helpers.
    package struct Page<Item: Sendable>: Sendable {
        package let items: [Item]
        package let nextCursor: String?

        package init(items: [Item], nextCursor: String?) {
            self.items = items
            self.nextCursor = nextCursor
        }
    }

    /// Wire shape for ASC's `links` block on paginated responses.
    fileprivate struct PaginatedLinks: Decodable, Sendable {
        let next: String?
    }

    fileprivate struct PaginatedResponse<T: Decodable & Sendable>: Decodable, Sendable {
        let data: [T]
        let links: PaginatedLinks?
    }

    /// Pulls the `cursor` query param out of Apple's fully-qualified
    /// pagination link so callers stay protocol-agnostic.
    fileprivate static func extractCursor(from links: PaginatedLinks?) -> String? {
        guard let next = links?.next,
              let comps = URLComponents(string: next) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }

    fileprivate static func paginationQuery(
        limit: Int,
        cursor: String?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var q: [String: String] = ["limit": String(limit)]
        if let cursor { q["cursor"] = cursor }
        for (k, v) in extra { q[k] = v }
        return q
    }

    fileprivate static func paginated<T: Decodable & Sendable>(
        client: ASCClient,
        path: String,
        limit: Int,
        cursor: String?,
        extra: [String: String] = [:]
    ) async throws -> Page<T> {
        let resp: PaginatedResponse<T> = try await client.get(
            path: path,
            query: paginationQuery(limit: limit, cursor: cursor, extra: extra),
            as: PaginatedResponse<T>.self
        )
        return Page(items: resp.data, nextCursor: extractCursor(from: resp.links))
    }

    fileprivate static func fetchOrNil<T: Decodable & Sendable>(
        client: ASCClient,
        path: String,
        as type: T.Type
    ) async throws -> T? {
        do {
            return try await client.get(path: path, as: type)
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    // MARK: - Asset upload helper (review attachments + app-clip images)
    //
    // 3-phase reservation flow: POST creates the resource, ASC returns
    // `uploadOperations` with pre-signed PUT URLs; PUT each chunk; PATCH
    // `uploaded: true` + sourceFileChecksum (hex MD5) to finalize. Same
    // shape as MarketingAssetUpload but factored separately so this file
    // is self-contained.

    /// Per-chunk upload instruction Apple returns on the reservation POST.
    package struct UploadOperation: Codable, Sendable {
        package let method: String?
        package let url: String?
        package let length: Int?
        package let offset: Int?
        package let requestHeaders: [HeaderEntry]?

        package struct HeaderEntry: Codable, Sendable {
            package let name: String?
            package let value: String?
        }
    }

    /// Pushes each pre-signed chunk to its URL. `fileData` is the whole
    /// file; chunks are sliced by offset+length. Order is not significant
    /// to Apple, but we walk them in array order for predictability.
    fileprivate static func uploadChunks(
        client: ASCClient,
        operations: [UploadOperation],
        fileData: Data,
        progress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws {
        for (index, op) in operations.enumerated() {
            guard let urlString = op.url,
                  let url = URL(string: urlString),
                  let offset = op.offset,
                  let length = op.length else {
                throw NSError(
                    domain: "Wave4ExtrasAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid uploadOperation entry"]
                )
            }
            let end = offset + length
            guard end <= fileData.count else {
                throw NSError(
                    domain: "Wave4ExtrasAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "chunk offset+length exceeds file"]
                )
            }
            let chunk = fileData.subdata(in: offset..<end)
            var headers: [String: String] = [:]
            for h in (op.requestHeaders ?? []) {
                if let n = h.name, let v = h.value { headers[n] = v }
            }
            try await client.putBinary(absoluteURL: url, headers: headers, body: chunk)
            progress?(index + 1, operations.count)
        }
    }

    /// Hex-encoded MD5 of the file bytes. Apple's `sourceFileChecksum`
    /// uses this format for finalize PATCHes on asset uploads.
    fileprivate static func md5Hex(data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Subscription extras
    //
    // Late additions to the subscriptions surface that did not fit in
    // SubscriptionsAPI's nested namespaces. These mirror Apple's distinct
    // resources:
    //   - subscriptionIntroductoryOffers: intro offers for NEW subscribers
    //     (distinct from `subscriptionPromotionalOffers`, which targets
    //     existing customers)
    //   - winBackOffers: win-back incentives for lapsed subscribers, with
    //     a separate per-territory pricing relationship
    //   - subscriptionGracePeriods: Apple billing grace-period config for
    //     a whole subscription group
    //   - subscriptionGroupSubmissions: single-shot "submit whole group
    //     for review" sibling of `subscriptionSubmissions`
    //   - subscriptionPricePoints: standalone get by id (Wave 1 already
    //     wraps the list path; this fills in the missing single-record GET)

    package struct SubscriptionExtras: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        // MARK: Introductory offers

        package struct IntroductoryOffer: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// "PAY_AS_YOU_GO" | "PAY_UP_FRONT" | "FREE_TRIAL".
                package let offerMode: String?
                /// ISO 8601 duration code (e.g. "ONE_MONTH", "THREE_MONTHS").
                package let duration: String?
                /// Number of periods the offer is honored for.
                package let numberOfPeriods: Int?
                /// ISO 8601 start date.
                package let startDate: Date?
                /// ISO 8601 end date; nil for open-ended offers.
                package let endDate: Date?
                /// Apple territory the offer is scoped to (ISO 3166-1 alpha-3).
                package let territory: String?
            }
        }

        /// Creates a new intro offer on a subscription. ASC scopes intro
        /// offers per-territory; pass the territory id along with the price
        /// point that the offer redeems against.
        @discardableResult
        package func createIntroductoryOffer(
            subscriptionID: String,
            territoryID: String,
            pricePointID: String,
            offerMode: String,
            duration: String,
            numberOfPeriods: Int,
            startDate: Date? = nil,
            endDate: Date? = nil
        ) async throws -> IntroductoryOffer {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionIntroductoryOffers"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let offerMode: String
                    let duration: String
                    let numberOfPeriods: Int
                    let startDate: Date?
                    let endDate: Date?
                }
                struct Rels: Encodable {
                    struct S: Encodable {
                        struct D: Encodable { let type = "subscriptions"; let id: String }
                        let data: D
                    }
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: D
                    }
                    struct PP: Encodable {
                        struct D: Encodable { let type = "subscriptionPricePoints"; let id: String }
                        let data: D
                    }
                    let subscription: S
                    let territory: T
                    let subscriptionPricePoint: PP
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    offerMode: offerMode,
                    duration: duration,
                    numberOfPeriods: numberOfPeriods,
                    startDate: startDate,
                    endDate: endDate
                ),
                relationships: .init(
                    subscription: .init(data: .init(id: subscriptionID)),
                    territory: .init(data: .init(id: territoryID)),
                    subscriptionPricePoint: .init(data: .init(id: pricePointID))
                )
            ))
            struct Resp: Decodable { let data: IntroductoryOffer }
            let resp: Resp = try await client.post(
                path: "subscriptionIntroductoryOffers", body: body, as: Resp.self
            )
            return resp.data
        }

        /// PATCHes the editable subset of an intro offer. Only the date
        /// range is mutable post-creation; other attributes require a
        /// delete + recreate.
        @discardableResult
        package func updateIntroductoryOffer(
            id: String,
            startDate: Date? = nil,
            endDate: Date? = nil
        ) async throws -> IntroductoryOffer {
            struct AttrsPatch: Encodable {
                var startDate: Date?
                var endDate: Date?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionIntroductoryOffers"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(startDate: startDate, endDate: endDate)
            ))
            struct Resp: Decodable { let data: IntroductoryOffer }
            let resp: Resp = try await client.patch(
                path: "subscriptionIntroductoryOffers/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func deleteIntroductoryOffer(id: String) async throws {
            try await client.delete(path: "subscriptionIntroductoryOffers/\(id)")
        }

        // MARK: Win-back offers

        package struct WinBackOffer: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Developer-visible label.
                package let name: String?
                /// Reverse-DNS-style offer identifier StoreKit uses.
                package let offerCode: String?
                /// "PAY_AS_YOU_GO" | "PAY_UP_FRONT" | "FREE_TRIAL".
                package let offerMode: String?
                /// ISO 8601 duration (e.g. "ONE_MONTH").
                package let duration: String?
                package let numberOfPeriods: Int?
                /// ISO 8601 start date the offer becomes active.
                package let startDate: Date?
                /// ISO 8601 end date; nil for open-ended offers.
                package let endDate: Date?
                /// Workflow state Apple maintains.
                package let state: String?
            }
        }

        package func listWinBackOffers(
            subscriptionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<WinBackOffer> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/winBackOffers",
                limit: limit,
                cursor: cursor
            )
        }

        package func getWinBackOffer(id: String) async throws -> WinBackOffer? {
            struct Resp: Decodable { let data: WinBackOffer }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "winBackOffers/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        @discardableResult
        package func createWinBackOffer(
            subscriptionID: String,
            name: String,
            offerCode: String,
            offerMode: String,
            duration: String,
            numberOfPeriods: Int,
            startDate: Date? = nil,
            endDate: Date? = nil
        ) async throws -> WinBackOffer {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "winBackOffers"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let name: String
                    let offerCode: String
                    let offerMode: String
                    let duration: String
                    let numberOfPeriods: Int
                    let startDate: Date?
                    let endDate: Date?
                }
                struct Rels: Encodable {
                    struct S: Encodable {
                        struct D: Encodable { let type = "subscriptions"; let id: String }
                        let data: D
                    }
                    let subscription: S
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    name: name,
                    offerCode: offerCode,
                    offerMode: offerMode,
                    duration: duration,
                    numberOfPeriods: numberOfPeriods,
                    startDate: startDate,
                    endDate: endDate
                ),
                relationships: .init(subscription: .init(data: .init(id: subscriptionID)))
            ))
            struct Resp: Decodable { let data: WinBackOffer }
            let resp: Resp = try await client.post(
                path: "winBackOffers", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func updateWinBackOffer(
            id: String,
            name: String? = nil,
            startDate: Date? = nil,
            endDate: Date? = nil
        ) async throws -> WinBackOffer {
            struct AttrsPatch: Encodable {
                var name: String?
                var startDate: Date?
                var endDate: Date?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "winBackOffers"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(name: name, startDate: startDate, endDate: endDate)
            ))
            struct Resp: Decodable { let data: WinBackOffer }
            let resp: Resp = try await client.patch(
                path: "winBackOffers/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func deleteWinBackOffer(id: String) async throws {
            try await client.delete(path: "winBackOffers/\(id)")
        }

        /// Win-back offers carry a per-territory pricing relationship,
        /// modeled here as a list-only read. Apple expects callers to
        /// create the win-back offer first, then POST `winBackOfferPrices`
        /// records via `createWinBackOfferPrice` once the territories are
        /// known.
        package struct WinBackOfferPrice: Codable, Sendable {
            package let id: String
        }

        package func listWinBackOfferPrices(
            offerID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<WinBackOfferPrice> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "winBackOffers/\(offerID)/prices",
                limit: limit,
                cursor: cursor
            )
        }

        @discardableResult
        package func createWinBackOfferPrice(
            offerID: String,
            territoryID: String,
            pricePointID: String
        ) async throws -> WinBackOfferPrice {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "winBackOfferPrices"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct O: Encodable {
                        struct D: Encodable { let type = "winBackOffers"; let id: String }
                        let data: D
                    }
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: D
                    }
                    struct PP: Encodable {
                        struct D: Encodable { let type = "subscriptionPricePoints"; let id: String }
                        let data: D
                    }
                    let winBackOffer: O
                    let territory: T
                    let subscriptionPricePoint: PP
                }
                let data: Data
            }
            let body = Body(data: .init(
                relationships: .init(
                    winBackOffer: .init(data: .init(id: offerID)),
                    territory: .init(data: .init(id: territoryID)),
                    subscriptionPricePoint: .init(data: .init(id: pricePointID))
                )
            ))
            struct Resp: Decodable { let data: WinBackOfferPrice }
            let resp: Resp = try await client.post(
                path: "winBackOfferPrices", body: body, as: Resp.self
            )
            return resp.data
        }

        // MARK: Grace periods

        /// Subscription billing grace-period config. One record per
        /// subscription group; Apple lets the developer decide how long a
        /// failed renewal keeps the subscription active before lapsing.
        package struct GracePeriod: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// True to opt the group into billing grace periods.
                package let optIn: Bool?
                /// "SIX_DAYS" | "SIXTEEN_DAYS" | "THIRTY_DAYS" - Apple's
                /// fixed enum for grace-period length.
                package let renewalType: String?
                /// Duration in days, when Apple surfaces it.
                package let duration: Int?
            }
        }

        /// GET `/v1/subscriptionGroups/{id}/gracePeriod`. Returns nil when
        /// the group has never had grace periods configured.
        package func getGracePeriod(groupID: String) async throws -> GracePeriod? {
            struct Resp: Decodable { let data: GracePeriod? }
            do {
                let resp: Resp = try await client.get(
                    path: "subscriptionGroups/\(groupID)/gracePeriod",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// PATCH the grace period record by id. Both opt-in flag and
        /// renewal-type duration are editable; nil fields are omitted.
        @discardableResult
        package func updateGracePeriod(
            id: String,
            optIn: Bool? = nil,
            renewalType: String? = nil
        ) async throws -> GracePeriod {
            struct AttrsPatch: Encodable {
                var optIn: Bool?
                var renewalType: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionGracePeriods"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(optIn: optIn, renewalType: renewalType)
            ))
            struct Resp: Decodable { let data: GracePeriod }
            let resp: Resp = try await client.patch(
                path: "subscriptionGracePeriods/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        // MARK: Group submissions

        /// One-shot review submission covering every pending change in a
        /// subscription group. Sibling of the per-subscription
        /// `subscriptionSubmissions` resource Wave 1 already wraps. Create
        /// only - Apple manages the lifecycle internally; callers poll for
        /// state through the standard reviewSubmission feed.
        package struct GroupSubmission: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let state: String?
                package let submittedDate: Date?
            }
        }

        @discardableResult
        package func createGroupSubmission(
            groupID: String
        ) async throws -> GroupSubmission {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionGroupSubmissions"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct G: Encodable {
                        struct D: Encodable { let type = "subscriptionGroups"; let id: String }
                        let data: D
                    }
                    let subscriptionGroup: G
                }
                let data: Data
            }
            let body = Body(data: .init(
                relationships: .init(subscriptionGroup: .init(data: .init(id: groupID)))
            ))
            struct Resp: Decodable { let data: GroupSubmission }
            let resp: Resp = try await client.post(
                path: "subscriptionGroupSubmissions", body: body, as: Resp.self
            )
            return resp.data
        }

        // MARK: Standalone price-point GET

        /// `SubscriptionsAPI.PricePoints` already wraps the per-subscription
        /// list path; this fills in the missing GET by id, which is useful
        /// when the caller already knows the price point id (e.g. from a
        /// previously-cached lookup or a related price record).
        package struct PricePoint: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let customerPrice: String?
                package let proceeds: String?
            }
        }

        package func getPricePoint(id: String) async throws -> PricePoint? {
            struct Resp: Decodable { let data: PricePoint }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "subscriptionPricePoints/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }
    }

    // MARK: - Customer review extras
    //
    // Customer review surfaces beyond the basic list-and-respond flow:
    //   - customerReviewSummarizations: Apple-Intelligence-generated
    //     rollup summaries per app, READ-ONLY
    //   - appStoreReviewAttachments: developer-supplied supporting files
    //     attached to an app-review submission (sign-in walkthroughs,
    //     network captures, etc.); CRUD + 3-phase upload

    package struct CustomerReviewExtras: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        // MARK: Review summarizations (read-only)

        /// Apple Intelligence generated review summary for an app. One
        /// record per (locale, territory) combination; Apple regenerates
        /// these on a rolling cadence as reviews accumulate.
        package struct ReviewSummarization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// IETF locale code Apple generated the summary for.
                package let locale: String?
                /// ISO 3166-1 alpha-3 territory the summary covers.
                package let territory: String?
                /// Apple Intelligence prose summary.
                package let summary: String?
                /// Short list of positive themes Apple identified.
                package let positiveHighlights: [String]?
                /// Short list of negative themes Apple identified.
                package let negativeHighlights: [String]?
                /// ISO 8601 timestamp Apple last regenerated the summary.
                package let lastModifiedDate: Date?
            }
        }

        /// Lists summarizations Apple has generated for the app. Paginated.
        package func listSummarizationsForApp(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<ReviewSummarization> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "apps/\(appID)/customerReviewSummarizations",
                limit: limit,
                cursor: cursor
            )
        }

        package func getSummarization(id: String) async throws -> ReviewSummarization? {
            struct Resp: Decodable { let data: ReviewSummarization }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "customerReviewSummarizations/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        // MARK: App review attachments (CRUD + upload)

        /// One developer-supplied supporting file attached to an app-review
        /// submission. Apple's reviewers see these in the review dashboard
        /// when triaging the submission.
        package struct ReviewAttachment: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileSize: Int?
                package let fileName: String?
                package let sourceFileChecksum: String?
                package let uploadOperations: [UploadOperation]?
                package let assetDeliveryState: AssetDeliveryState?
            }

            package struct AssetDeliveryState: Codable, Sendable {
                package let state: String?
            }
        }

        package func listAttachments(
            reviewDetailID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<ReviewAttachment> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "appStoreReviewDetails/\(reviewDetailID)/appStoreReviewAttachments",
                limit: limit,
                cursor: cursor
            )
        }

        package func getAttachment(id: String) async throws -> ReviewAttachment? {
            struct Resp: Decodable { let data: ReviewAttachment }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "appStoreReviewAttachments/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        /// Phase 1: reserve a new attachment slot, returning the record
        /// with `uploadOperations` Apple expects the caller to PUT to.
        package func createAttachment(
            reviewDetailID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> ReviewAttachment {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "appStoreReviewAttachments"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int
                }
                struct Rels: Encodable {
                    struct R: Encodable {
                        struct D: Encodable { let type = "appStoreReviewDetails"; let id: String }
                        let data: D
                    }
                    let appStoreReviewDetail: R
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(appStoreReviewDetail: .init(data: .init(id: reviewDetailID)))
            ))
            struct Resp: Decodable { let data: ReviewAttachment }
            let resp: Resp = try await client.post(
                path: "appStoreReviewAttachments", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Phase 3: PATCH `uploaded: true` + `sourceFileChecksum` to
        /// finalize. Apple does not accept arbitrary attribute updates on
        /// this resource; only the upload-confirmation fields are mutable.
        @discardableResult
        package func updateAttachment(
            id: String,
            uploaded: Bool? = nil,
            sourceFileChecksum: String? = nil
        ) async throws -> ReviewAttachment {
            struct AttrsPatch: Encodable {
                var uploaded: Bool?
                var sourceFileChecksum: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "appStoreReviewAttachments"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(
                    uploaded: uploaded,
                    sourceFileChecksum: sourceFileChecksum
                )
            ))
            struct Resp: Decodable { let data: ReviewAttachment }
            let resp: Resp = try await client.patch(
                path: "appStoreReviewAttachments/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func deleteAttachment(id: String) async throws {
            try await client.delete(path: "appStoreReviewAttachments/\(id)")
        }

        /// Convenience: runs all three phases (reserve, upload, finalize)
        /// in one call. `fileURL` must point to a readable file on disk.
        @discardableResult
        package func uploadAttachment(
            reviewDetailID: String,
            fileURL: URL,
            chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
        ) async throws -> ReviewAttachment {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let checksum = Wave4ExtrasAPI.md5Hex(data: data)

            let reserved = try await createAttachment(
                reviewDetailID: reviewDetailID,
                fileName: fileName,
                fileSize: data.count
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(
                    domain: "Wave4ExtrasAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
                )
            }
            try await Wave4ExtrasAPI.uploadChunks(
                client: client, operations: ops, fileData: data, progress: chunkProgress
            )
            return try await updateAttachment(
                id: reserved.id,
                uploaded: true,
                sourceFileChecksum: checksum
            )
        }
    }

    // MARK: - Merchant IDs
    //
    // Apple Pay merchant identifiers. Distinct from `merchantDomains`
    // (already wrapped by ApplePayAPI): merchant IDs are the upstream
    // Apple Pay merchant accounts; merchant domains attach to them.
    // Includes the merchant certificate relationship needed for Apple Pay
    // payment processing.

    package struct Merchant: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct MerchantID: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Dotted reverse-DNS identifier (e.g. "merchant.com.example").
                package let identifier: String?
                /// Display label shown in the developer portal.
                package let name: String?
            }
        }

        package func listMerchantIDs(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<MerchantID> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "merchantIds",
                limit: limit,
                cursor: cursor
            )
        }

        package func getMerchantID(id: String) async throws -> MerchantID? {
            struct Resp: Decodable { let data: MerchantID }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "merchantIds/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        @discardableResult
        package func createMerchantID(
            identifier: String,
            name: String
        ) async throws -> MerchantID {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "merchantIds"
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let identifier: String
                    let name: String
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(identifier: identifier, name: name)
            ))
            struct Resp: Decodable { let data: MerchantID }
            let resp: Resp = try await client.post(
                path: "merchantIds", body: body, as: Resp.self
            )
            return resp.data
        }

        /// PATCH the merchant id's display name. The dotted `identifier`
        /// is immutable once created.
        @discardableResult
        package func updateMerchantID(
            id: String,
            name: String
        ) async throws -> MerchantID {
            struct AttrsPatch: Encodable { let name: String }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "merchantIds"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id, attributes: AttrsPatch(name: name)
            ))
            struct Resp: Decodable { let data: MerchantID }
            let resp: Resp = try await client.patch(
                path: "merchantIds/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func deleteMerchantID(id: String) async throws {
            try await client.delete(path: "merchantIds/\(id)")
        }

        // MARK: Merchant ID certificates (relationship)

        package struct MerchantCertificate: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let displayName: String?
                package let serialNumber: String?
                package let certificateContent: String?
                package let expirationDate: Date?
            }
        }

        /// Lists certificates attached to a merchant id. Apple lets each
        /// merchant id carry multiple certificates (typically one active +
        /// one on deck for rotation). Paginated.
        package func listMerchantCertificates(
            merchantIDID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<MerchantCertificate> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "merchantIds/\(merchantIDID)/merchantIdCertificates",
                limit: limit,
                cursor: cursor
            )
        }
    }

    // MARK: - Nominations
    //
    // App Store editorial feature nomination submissions. Developers send
    // these to Apple's editorial team to be considered for App Store
    // collections, Today tab features, etc. CRUD lifecycle plus a
    // `state` attribute Apple updates as the nomination flows through
    // review.

    package struct Nominations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Nomination: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Free-form headline the developer wrote for the
                /// nomination.
                package let title: String?
                /// Long-form pitch describing why the editorial team
                /// should feature the app.
                package let description: String?
                /// Apple's enum for the nomination workflow state, e.g.
                /// "DRAFT", "SUBMITTED", "ACCEPTED", "REJECTED".
                package let state: String?
                /// ISO 8601 timestamp the developer last edited the
                /// nomination.
                package let lastModifiedDate: Date?
            }
        }

        package func listNominations(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Nomination> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "apps/\(appID)/nominations",
                limit: limit,
                cursor: cursor
            )
        }

        package func getNomination(id: String) async throws -> Nomination? {
            struct Resp: Decodable { let data: Nomination }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "nominations/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        @discardableResult
        package func createNomination(
            appID: String,
            title: String,
            description: String
        ) async throws -> Nomination {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "nominations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let title: String
                    let description: String
                }
                struct Rels: Encodable {
                    struct A: Encodable {
                        struct D: Encodable { let type = "apps"; let id: String }
                        let data: D
                    }
                    let app: A
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(title: title, description: description),
                relationships: .init(app: .init(data: .init(id: appID)))
            ))
            struct Resp: Decodable { let data: Nomination }
            let resp: Resp = try await client.post(
                path: "nominations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func updateNomination(
            id: String,
            title: String? = nil,
            description: String? = nil
        ) async throws -> Nomination {
            struct AttrsPatch: Encodable {
                var title: String?
                var description: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "nominations"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(title: title, description: description)
            ))
            struct Resp: Decodable { let data: Nomination }
            let resp: Resp = try await client.patch(
                path: "nominations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func deleteNomination(id: String) async throws {
            try await client.delete(path: "nominations/\(id)")
        }
    }

    // MARK: - App tags
    //
    // Per-territory app tags Apple uses for store search and category
    // surfacing. Update-only resource: Apple lets developers attach a set
    // of tags from a fixed taxonomy; replacing the set wholesale is the
    // only mutation.

    package struct AppTags: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct AppTag: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Apple's tag identifier from the editorial taxonomy.
                package let tag: String?
                /// Human-readable label Apple surfaces in the App Store.
                package let displayName: String?
            }
        }

        /// PATCHes the app's tag list for a given territory. Pass the
        /// full desired set of `tagIDs` - ASC replaces the existing tags
        /// wholesale on each call.
        @discardableResult
        package func updateAppTags(
            appID: String,
            territoryID: String,
            tagIDs: [String]
        ) async throws -> [AppTag] {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "appTags"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct A: Encodable {
                        struct D: Encodable { let type = "apps"; let id: String }
                        let data: D
                    }
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: D
                    }
                    struct Tags: Encodable {
                        struct D: Encodable { let type = "appTags"; let id: String }
                        let data: [D]
                    }
                    let app: A
                    let territory: T
                    let tags: Tags
                }
                let data: Data
            }
            let body = Body(data: .init(
                relationships: .init(
                    app: .init(data: .init(id: appID)),
                    territory: .init(data: .init(id: territoryID)),
                    tags: .init(data: tagIDs.map { .init(id: $0) })
                )
            ))
            struct Resp: Decodable { let data: [AppTag] }
            let resp: Resp = try await client.post(
                path: "appTags", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - End-user license agreements
    //
    // Per-app custom EULA. Apple ships a default EULA every app inherits;
    // these records let the developer override it per territory. CRUD plus
    // a territory relationship for the per-territory targeting.

    package struct EULAs: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct EULA: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Full EULA text the customer sees on the App Store.
                package let agreementText: String?
            }
        }

        package func listEULAs(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<EULA> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "apps/\(appID)/endUserLicenseAgreement",
                limit: limit,
                cursor: cursor
            )
        }

        package func getEULA(id: String) async throws -> EULA? {
            struct Resp: Decodable { let data: EULA }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "endUserLicenseAgreements/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        @discardableResult
        package func createEULA(
            appID: String,
            agreementText: String,
            territoryIDs: [String]
        ) async throws -> EULA {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "endUserLicenseAgreements"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let agreementText: String
                }
                struct Rels: Encodable {
                    struct A: Encodable {
                        struct D: Encodable { let type = "apps"; let id: String }
                        let data: D
                    }
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: [D]
                    }
                    let app: A
                    let territories: T
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(agreementText: agreementText),
                relationships: .init(
                    app: .init(data: .init(id: appID)),
                    territories: .init(data: territoryIDs.map { .init(id: $0) })
                )
            ))
            struct Resp: Decodable { let data: EULA }
            let resp: Resp = try await client.post(
                path: "endUserLicenseAgreements", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func updateEULA(
            id: String,
            agreementText: String? = nil,
            territoryIDs: [String]? = nil
        ) async throws -> EULA {
            struct AttrsPatch: Encodable {
                var agreementText: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "endUserLicenseAgreements"
                    let id: String
                    let attributes: AttrsPatch
                    let relationships: Rels?
                }
                struct Rels: Encodable {
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: [D]
                    }
                    let territories: T
                }
                let data: Data
            }
            let rels: Body.Rels? = territoryIDs.map { ids in
                .init(territories: .init(data: ids.map { .init(id: $0) }))
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(agreementText: agreementText),
                relationships: rels
            ))
            struct Resp: Decodable { let data: EULA }
            let resp: Resp = try await client.patch(
                path: "endUserLicenseAgreements/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func deleteEULA(id: String) async throws {
            try await client.delete(path: "endUserLicenseAgreements/\(id)")
        }
    }

    // MARK: - Android-to-iOS app mapping
    //
    // Metadata Apple uses when prompting Android users to switch to the
    // developer's iOS app. The record carries the Play Store package id
    // and a few display fields used in the migration prompts.

    package struct AndroidMapping: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct AndroidToIos: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Google Play package identifier (e.g. com.example.app).
                package let androidAppPackageName: String?
                /// Free-form pitch shown to migrating users.
                package let migrationDescription: String?
            }
        }

        /// GET `/v1/apps/{id}/androidToIosAppMappingDetails`. Returns nil
        /// when the app has never had a mapping configured.
        package func getMapping(appID: String) async throws -> AndroidToIos? {
            struct Resp: Decodable { let data: AndroidToIos? }
            do {
                let resp: Resp = try await client.get(
                    path: "apps/\(appID)/androidToIosAppMappingDetails",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func createMapping(
            appID: String,
            androidAppPackageName: String,
            migrationDescription: String? = nil
        ) async throws -> AndroidToIos {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "androidToIosAppMappingDetails"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let androidAppPackageName: String
                    let migrationDescription: String?
                }
                struct Rels: Encodable {
                    struct A: Encodable {
                        struct D: Encodable { let type = "apps"; let id: String }
                        let data: D
                    }
                    let app: A
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    androidAppPackageName: androidAppPackageName,
                    migrationDescription: migrationDescription
                ),
                relationships: .init(app: .init(data: .init(id: appID)))
            ))
            struct Resp: Decodable { let data: AndroidToIos }
            let resp: Resp = try await client.post(
                path: "androidToIosAppMappingDetails", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func updateMapping(
            id: String,
            androidAppPackageName: String? = nil,
            migrationDescription: String? = nil
        ) async throws -> AndroidToIos {
            struct AttrsPatch: Encodable {
                var androidAppPackageName: String?
                var migrationDescription: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "androidToIosAppMappingDetails"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(
                    androidAppPackageName: androidAppPackageName,
                    migrationDescription: migrationDescription
                )
            ))
            struct Resp: Decodable { let data: AndroidToIos }
            let resp: Resp = try await client.patch(
                path: "androidToIosAppMappingDetails/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func deleteMapping(id: String) async throws {
            try await client.delete(path: "androidToIosAppMappingDetails/\(id)")
        }
    }

    // MARK: - Actors
    //
    // Niche read-only registry of in-app actors. Apple uses this on the
    // games side for player / persona attribution. List + get only; the
    // schema is minimal and Apple has not published a write surface.

    package struct Actors: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Actor: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let name: String?
                package let role: String?
            }
        }

        package func listActors(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Actor> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "actors",
                limit: limit,
                cursor: cursor
            )
        }

        package func getActor(id: String) async throws -> Actor? {
            struct Resp: Decodable { let data: Actor }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "actors/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }
    }

    // MARK: - App price points V3
    //
    // PricingAvailabilityAPI already wraps the per-app list path; this
    // adds the standalone get-by-id endpoint plus the "equalizations"
    // sub-resource Apple uses to surface the conversion from one
    // territory's price point to the equivalent in another.

    package struct PricePointsV3: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PricePoint: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let customerPrice: String?
                package let proceeds: String?
                package let priceTier: String?
                /// Apple territory the point applies to.
                package let territory: String?
            }
        }

        /// GET `/v3/appPricePoints/{id}`. Returns nil on 404. Uses Apple's
        /// V3 API namespace explicitly via the `v3/` path prefix.
        package func getPricePoint(id: String) async throws -> PricePoint? {
            struct Resp: Decodable { let data: PricePoint }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "v3/appPricePoints/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        /// Lists equalization records for a given price point. Apple emits
        /// one record per (target territory) describing the equivalent
        /// price point on that storefront. Paginated.
        package struct Equalization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// ISO 3166-1 alpha-3 territory of the equivalent point.
                package let territory: String?
                /// Customer-facing price in the equivalent territory.
                package let customerPrice: String?
            }
        }

        package func listEqualizations(
            pricePointID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Equalization> {
            try await Wave4ExtrasAPI.paginated(
                client: client,
                path: "v3/appPricePoints/\(pricePointID)/equalizations",
                limit: limit,
                cursor: cursor
            )
        }
    }

    // MARK: - App Clip advanced experience images
    //
    // Sibling of `appClipAdvancedExperiences` (already wrapped by
    // MarketingAPI's AppClipsAPI). Each advanced experience can carry a
    // header image Apple shows in the App Clip card preview.

    package struct AppClipAdvancedImages: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct AdvancedImage: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileSize: Int?
                package let fileName: String?
                package let sourceFileChecksum: String?
                package let uploadOperations: [UploadOperation]?
                package let assetDeliveryState: AssetDeliveryState?
            }

            package struct AssetDeliveryState: Codable, Sendable {
                package let state: String?
            }
        }

        package func getImage(id: String) async throws -> AdvancedImage? {
            struct Resp: Decodable { let data: AdvancedImage }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "appClipAdvancedExperienceImages/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        /// Phase 1 - reserve a new image slot on the advanced experience.
        package func createImage(
            advancedExperienceID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> AdvancedImage {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "appClipAdvancedExperienceImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int
                }
                struct Rels: Encodable {
                    struct E: Encodable {
                        struct D: Encodable { let type = "appClipAdvancedExperiences"; let id: String }
                        let data: D
                    }
                    let appClipAdvancedExperience: E
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(appClipAdvancedExperience: .init(data: .init(id: advancedExperienceID)))
            ))
            struct Resp: Decodable { let data: AdvancedImage }
            let resp: Resp = try await client.post(
                path: "appClipAdvancedExperienceImages", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Phase 3 - PATCH `uploaded: true` + sourceFileChecksum to
        /// finalize. Apple ignores other attribute changes on this PATCH.
        @discardableResult
        package func updateImage(
            id: String,
            uploaded: Bool? = nil,
            sourceFileChecksum: String? = nil
        ) async throws -> AdvancedImage {
            struct AttrsPatch: Encodable {
                var uploaded: Bool?
                var sourceFileChecksum: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "appClipAdvancedExperienceImages"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(
                    uploaded: uploaded,
                    sourceFileChecksum: sourceFileChecksum
                )
            ))
            struct Resp: Decodable { let data: AdvancedImage }
            let resp: Resp = try await client.patch(
                path: "appClipAdvancedExperienceImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Convenience: all three phases (reserve, upload chunks, finalize).
        @discardableResult
        package func uploadImage(
            advancedExperienceID: String,
            fileURL: URL,
            chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
        ) async throws -> AdvancedImage {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let checksum = Wave4ExtrasAPI.md5Hex(data: data)

            let reserved = try await createImage(
                advancedExperienceID: advancedExperienceID,
                fileName: fileName,
                fileSize: data.count
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(
                    domain: "Wave4ExtrasAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
                )
            }
            try await Wave4ExtrasAPI.uploadChunks(
                client: client, operations: ops, fileData: data, progress: chunkProgress
            )
            return try await updateImage(
                id: reserved.id,
                uploaded: true,
                sourceFileChecksum: checksum
            )
        }
    }

    // MARK: - In-app purchase availabilities
    //
    // Per-territory availability gate for one-time IAPs. Sibling of
    // `subscriptionAvailabilities` (already in SubscriptionsAPI). Create
    // and get only - Apple replaces the territory list wholesale on each
    // create, the prior record stays accessible by id for audit.

    package struct IAPAvailabilities: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Availability: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let availableInNewTerritories: Bool?
            }
        }

        /// GET `/v1/inAppPurchases/{id}/inAppPurchaseAvailability`. Returns
        /// nil when the IAP has never had availability configured.
        package func getAvailability(iapID: String) async throws -> Availability? {
            struct Resp: Decodable { let data: Availability? }
            do {
                let resp: Resp = try await client.get(
                    path: "inAppPurchases/\(iapID)/inAppPurchaseAvailability",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Creates a new availability record. Pass the full set of
        /// allowed territory ids - Apple treats this as the new
        /// exhaustive list.
        @discardableResult
        package func createAvailability(
            iapID: String,
            territoryIDs: [String],
            availableInNewTerritories: Bool
        ) async throws -> Availability {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseAvailabilities"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable { let availableInNewTerritories: Bool }
                struct Rels: Encodable {
                    struct IAP: Encodable {
                        struct D: Encodable { let type = "inAppPurchases"; let id: String }
                        let data: D
                    }
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: [D]
                    }
                    let inAppPurchase: IAP
                    let availableTerritories: T
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(availableInNewTerritories: availableInNewTerritories),
                relationships: .init(
                    inAppPurchase: .init(data: .init(id: iapID)),
                    availableTerritories: .init(data: territoryIDs.sorted().map { .init(id: $0) })
                )
            ))
            struct Resp: Decodable { let data: Availability }
            let resp: Resp = try await client.post(
                path: "inAppPurchaseAvailabilities", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - In-app purchase contents
    //
    // Apple-hosted content metadata for non-consumable IAPs that deliver
    // downloadable payloads (rare in modern apps). InAppPurchasesAPI
    // already wraps the editable `ContentHostings` sub-resource on the
    // IAP itself; this `inAppPurchaseContent` standalone resource carries
    // the per-content metadata. Read-only here - Apple has not surfaced a
    // public create or update path.

    package struct IAPContents: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct IAPContent: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int?
                package let lastModifiedDate: Date?
            }
        }

        package func getContent(id: String) async throws -> IAPContent? {
            struct Resp: Decodable { let data: IAPContent }
            guard let resp = try await Wave4ExtrasAPI.fetchOrNil(
                client: client,
                path: "inAppPurchaseContents/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }
    }

    // MARK: - Territory availabilities (per-app)
    //
    // One-shot update to an app's per-territory availability. Apple
    // expects callers to pass the full desired territory list every
    // time; the existing list is replaced wholesale. Apple does not
    // surface a GET on this resource - use
    // PricingAvailabilityAPI.getCurrentAvailability for read.

    package struct TerritoryAvailabilities: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Availability: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let availableInNewTerritories: Bool?
            }
        }

        /// PATCH the app's territory availability. Pass `available: true`
        /// to flip on the territory, false to flip it off. Apple processes
        /// the update synchronously and the new state is visible on the
        /// next read of the app's availability record.
        @discardableResult
        package func updateAvailability(
            appID: String,
            territoryID: String,
            available: Bool
        ) async throws -> Availability {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "territoryAvailabilities"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let available: Bool
                }
                let data: Data
            }
            // Apple keys territoryAvailability by a composite of app + territory.
            // The PATCH path Apple documents takes the dotted compound id.
            let compoundID = "\(appID)-\(territoryID)"
            let body = Body(data: .init(
                id: compoundID,
                attributes: .init(available: available)
            ))
            struct Resp: Decodable { let data: Availability }
            let resp: Resp = try await client.patch(
                path: "territoryAvailabilities/\(compoundID)", body: body, as: Resp.self
            )
            return resp.data
        }
    }
}
