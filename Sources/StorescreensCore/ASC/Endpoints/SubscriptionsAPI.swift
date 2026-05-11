import Foundation

/// App Store Connect endpoints for the Auto-Renewable Subscriptions family
/// of resources (separate from one-time in-app purchases).
///
/// The model has four big chunks:
///
///   1. Groups + subscriptions
///      Subscriptions live inside subscriptionGroups. A group defines the
///      "service" the user is buying into, and the subscriptions in that
///      group are different durations / levels of the same service.
///      subscriptionGroupLocalizations carry the per-locale display name
///      shown to subscribers on the management screen.
///
///   2. Per-subscription metadata
///      subscriptionLocalizations (per-locale name + description),
///      subscriptionPrices (one record per territory; create/delete only
///      because prices are immutable once set), subscriptionPricePoints
///      (read-only catalog of valid Apple price tiers).
///
///   3. Offers
///      subscriptionOfferCodes + the three related code-issuance resources
///      (one-time, custom, and per-territory pricing) cover the win-back
///      / promotional-code flow. subscriptionPromotionalOffers covers the
///      "first month free" style intro offers for new subscribers,
///      paired with subscriptionPromotionalOfferPrices for territory pricing.
///
///   4. Submission + assets
///      subscriptionAvailabilities (territory availability),
///      subscriptionSubmissions (sibling to the IAP submissions flow,
///      used to ship metadata edits for App Review),
///      subscriptionAppStoreReviewScreenshots (review-only screenshots
///      Apple requires for approval), subscriptionImages
///      (promotional artwork).
///
/// All wrappers follow the existing AppsAPI / BuildsAPI conventions:
/// JSON:API shaped Codable models, `package` access, 404 → nil where
/// applicable, and 409 "already set" surfaced via APIError.isAlreadySetConflict.
/// Paginated lists accept `limit: Int = 200, cursor: String? = nil` and
/// return the next-page cursor alongside the data.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi
package struct SubscriptionsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Nested namespaces

    package var groups: Groups { Groups(client: client) }
    package var groupLocalizations: GroupLocalizations { GroupLocalizations(client: client) }
    package var subscriptions: Subscriptions { Subscriptions(client: client) }
    package var localizations: Localizations { Localizations(client: client) }
    package var prices: Prices { Prices(client: client) }
    package var pricePoints: PricePoints { PricePoints(client: client) }
    package var offerCodes: OfferCodes { OfferCodes(client: client) }
    package var offerCodeOneTimeUseCodes: OfferCodeOneTimeUseCodes { OfferCodeOneTimeUseCodes(client: client) }
    package var offerCodeCustomCodes: OfferCodeCustomCodes { OfferCodeCustomCodes(client: client) }
    package var offerCodePrices: OfferCodePrices { OfferCodePrices(client: client) }
    package var promotionalOffers: PromotionalOffers { PromotionalOffers(client: client) }
    package var promotionalOfferPrices: PromotionalOfferPrices { PromotionalOfferPrices(client: client) }
    package var availabilities: Availabilities { Availabilities(client: client) }
    package var submissions: Submissions { Submissions(client: client) }
    package var reviewScreenshots: ReviewScreenshots { ReviewScreenshots(client: client) }
    package var images: Images { Images(client: client) }

    // MARK: - Shared pagination plumbing

    /// One page of results plus the cursor needed to fetch the next page.
    /// Apple returns `links.next` with a fully-formed URL when more records
    /// exist; we extract the `cursor` query param so callers stay protocol-agnostic.
    package struct Page<Item: Sendable>: Sendable {
        package let items: [Item]
        package let nextCursor: String?

        package init(items: [Item], nextCursor: String?) {
            self.items = items
            self.nextCursor = nextCursor
        }
    }

    /// Wire shape for ASC's pagination links block. Only `next` is interesting.
    fileprivate struct PaginatedLinks: Decodable, Sendable {
        let next: String?
    }

    fileprivate struct PaginatedResponse<T: Decodable & Sendable>: Decodable, Sendable {
        let data: [T]
        let links: PaginatedLinks?
    }

    /// Parses Apple's `links.next` URL and returns just the `cursor` query
    /// param so callers can hand it back to the next call. Returns nil when
    /// no next page exists or the URL is malformed.
    fileprivate static func extractCursor(from links: PaginatedLinks?) -> String? {
        guard let next = links?.next,
              let comps = URLComponents(string: next) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }

    /// Builds the standard list-query dict. `extraQuery` overrides any
    /// shared key when the caller needs a filter or include directive.
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

    /// Shared helper: throws-on-error, returns Page<T>.
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

    /// Generic 404 → nil helper for single-record GETs.
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

    // MARK: - Subscription Groups
    //
    // A subscriptionGroup wraps one or more subscriptions in the same
    // service tier. Apple shows a per-group name to the user on the
    // subscription-management screen; the referenceName is for internal
    // App Store Connect display only.

    package struct Groups: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Group: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Developer-visible identifier shown on the ASC web UI.
                package let referenceName: String?
            }
        }

        package func list(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Group> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "apps/\(appID)/subscriptionGroups",
                limit: limit,
                cursor: cursor
            )
        }

        package func get(id: String) async throws -> Group? {
            struct Resp: Decodable { let data: Group }
            guard let resp = try await SubscriptionsAPI.fetchOrNil(
                client: client, path: "subscriptionGroups/\(id)", as: Resp.self
            ) else { return nil }
            return resp.data
        }

        package func create(
            appID: String,
            referenceName: String
        ) async throws -> Group {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionGroups"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable { let referenceName: String }
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
                attributes: .init(referenceName: referenceName),
                relationships: .init(app: .init(data: .init(id: appID)))
            ))
            struct Resp: Decodable { let data: Group }
            let resp: Resp = try await client.post(
                path: "subscriptionGroups", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            referenceName: String
        ) async throws -> Group {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionGroups"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { let referenceName: String }
                let data: Data
            }
            let body = Body(data: .init(
                id: id, attributes: .init(referenceName: referenceName)
            ))
            struct Resp: Decodable { let data: Group }
            let resp: Resp = try await client.patch(
                path: "subscriptionGroups/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptionGroups/\(id)")
        }

        /// List subscriptions in this group. Convenience for the common
        /// "give me everything under group X" navigation.
        package func listSubscriptions(
            groupID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Subscriptions.Subscription> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptionGroups/\(groupID)/subscriptions",
                limit: limit,
                cursor: cursor
            )
        }

        /// List the per-locale group localizations attached to a group.
        package func listLocalizations(
            groupID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<GroupLocalizations.GroupLocalization> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptionGroups/\(groupID)/subscriptionGroupLocalizations",
                limit: limit,
                cursor: cursor
            )
        }
    }

    // MARK: - Subscription Group Localizations
    //
    // Per-locale custom app name + reference name. The name field is
    // shown to subscribers on the subscription-management screen for
    // that locale.

    package struct GroupLocalizations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct GroupLocalization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// e.g. "en-US", "ja", "es-ES".
                package let locale: String?
                /// User-visible name shown for this group in this locale.
                package let name: String?
                /// "PREPARE_FOR_SUBMISSION", "WAITING_FOR_REVIEW", "APPROVED", "REJECTED".
                package let state: String?
                /// Apple's custom app-name for the subscription group when
                /// the developer overrides the default app name. Optional.
                package let customAppName: String?
            }
        }

        package func get(id: String) async throws -> GroupLocalization? {
            struct Resp: Decodable { let data: GroupLocalization }
            guard let resp = try await SubscriptionsAPI.fetchOrNil(
                client: client,
                path: "subscriptionGroupLocalizations/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        package func create(
            groupID: String,
            locale: String,
            name: String,
            customAppName: String? = nil
        ) async throws -> GroupLocalization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionGroupLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    let name: String
                    let customAppName: String?
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
                attributes: .init(locale: locale, name: name, customAppName: customAppName),
                relationships: .init(subscriptionGroup: .init(data: .init(id: groupID)))
            ))
            struct Resp: Decodable { let data: GroupLocalization }
            let resp: Resp = try await client.post(
                path: "subscriptionGroupLocalizations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            name: String? = nil,
            customAppName: String? = nil
        ) async throws -> GroupLocalization {
            struct AttrsPatch: Encodable {
                var name: String?
                var customAppName: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionGroupLocalizations"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(name: name, customAppName: customAppName)
            ))
            struct Resp: Decodable { let data: GroupLocalization }
            let resp: Resp = try await client.patch(
                path: "subscriptionGroupLocalizations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptionGroupLocalizations/\(id)")
        }
    }

    // MARK: - Subscriptions
    //
    // The actual auto-renewing product the customer pays for. Belongs to
    // exactly one subscriptionGroup. groupLevel + subscriptionPeriod +
    // productId form the unique identity Apple keys off.

    package struct Subscriptions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Subscription: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Reverse-DNS product ID; matches the StoreKit identifier
                /// the binary sends at purchase time.
                package let productId: String?
                /// Developer-facing label shown in ASC.
                package let name: String?
                /// "ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS",
                /// "SIX_MONTHS", "ONE_YEAR".
                package let subscriptionPeriod: String?
                /// 1-based position within the group; lower numbers are
                /// shown first on the upsell screen Apple generates for
                /// downgrade/upgrade flows.
                package let groupLevel: Int?
                /// Free-form text shown to App Review explaining the
                /// subscription.
                package let reviewNote: String?
                /// "MISSING_METADATA", "READY_TO_SUBMIT", "WAITING_FOR_REVIEW",
                /// "IN_REVIEW", "APPROVED", "DEVELOPER_REMOVED_FROM_SALE",
                /// "REJECTED", etc.
                package let state: String?
                /// "AUTO_RENEWABLE" — included so callers don't have to
                /// guess at the family.
                package let familyId: String?
            }
        }

        package func get(id: String) async throws -> Subscription? {
            struct Resp: Decodable { let data: Subscription }
            guard let resp = try await SubscriptionsAPI.fetchOrNil(
                client: client, path: "subscriptions/\(id)", as: Resp.self
            ) else { return nil }
            return resp.data
        }

        package func create(
            groupID: String,
            productId: String,
            name: String,
            subscriptionPeriod: String,
            groupLevel: Int,
            reviewNote: String? = nil
        ) async throws -> Subscription {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptions"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let productId: String
                    let name: String
                    let subscriptionPeriod: String
                    let groupLevel: Int
                    let reviewNote: String?
                }
                struct Rels: Encodable {
                    struct G: Encodable {
                        struct D: Encodable { let type = "subscriptionGroups"; let id: String }
                        let data: D
                    }
                    let group: G
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    productId: productId,
                    name: name,
                    subscriptionPeriod: subscriptionPeriod,
                    groupLevel: groupLevel,
                    reviewNote: reviewNote
                ),
                relationships: .init(group: .init(data: .init(id: groupID)))
            ))
            struct Resp: Decodable { let data: Subscription }
            let resp: Resp = try await client.post(
                path: "subscriptions", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            name: String? = nil,
            groupLevel: Int? = nil,
            reviewNote: String? = nil
        ) async throws -> Subscription {
            struct AttrsPatch: Encodable {
                var name: String?
                var groupLevel: Int?
                var reviewNote: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptions"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(name: name, groupLevel: groupLevel, reviewNote: reviewNote)
            ))
            struct Resp: Decodable { let data: Subscription }
            let resp: Resp = try await client.patch(
                path: "subscriptions/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptions/\(id)")
        }

        /// Per-locale localizations attached to this subscription.
        package func listLocalizations(
            subscriptionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Localizations.Localization> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/subscriptionLocalizations",
                limit: limit,
                cursor: cursor
            )
        }

        /// The subscription's price schedule. One entry per territory.
        package func listPrices(
            subscriptionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Prices.Price> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/prices",
                limit: limit,
                cursor: cursor
            )
        }
    }

    // MARK: - Subscription Localizations
    //
    // Per-locale name + description shown on the App Store product page
    // and on the subscription-management screen.

    package struct Localizations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Localization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let locale: String?
                package let name: String?
                package let description: String?
                package let state: String?
            }
        }

        package func get(id: String) async throws -> Localization? {
            struct Resp: Decodable { let data: Localization }
            guard let resp = try await SubscriptionsAPI.fetchOrNil(
                client: client,
                path: "subscriptionLocalizations/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        package func create(
            subscriptionID: String,
            locale: String,
            name: String,
            description: String? = nil
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    let name: String
                    let description: String?
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
                attributes: .init(locale: locale, name: name, description: description),
                relationships: .init(subscription: .init(data: .init(id: subscriptionID)))
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.post(
                path: "subscriptionLocalizations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            name: String? = nil,
            description: String? = nil
        ) async throws -> Localization {
            struct AttrsPatch: Encodable {
                var name: String?
                var description: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionLocalizations"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(name: name, description: description)
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.patch(
                path: "subscriptionLocalizations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptionLocalizations/\(id)")
        }
    }

    // MARK: - Subscription Prices
    //
    // Subscription prices are immutable per (subscription, territory).
    // Changing a price is a create-new-and-delete-old dance, so the
    // wrapper exposes list + create + delete (no update).

    package struct Prices: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Price: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Effective date Apple applies this price; null means
                /// "as soon as accepted".
                package let startDate: Date?
                /// Effective end date; null means "until replaced".
                package let endDate: Date?
                /// True when the price was auto-renewing onto the new tier.
                package let preserveCurrentPrice: Bool?
            }
        }

        package func list(
            subscriptionID: String,
            limit: Int = 200,
            cursor: String? = nil,
            filterTerritory: String? = nil
        ) async throws -> Page<Price> {
            var extra: [String: String] = [:]
            if let t = filterTerritory { extra["filter[territory]"] = t }
            return try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/prices",
                limit: limit,
                cursor: cursor,
                extra: extra
            )
        }

        /// Create a new price record. ASC keys off (subscription,
        /// territory, startDate); pass `preserveCurrentPrice = true` if
        /// you want existing subscribers grandfathered onto the old
        /// price rather than auto-rolled.
        package func create(
            subscriptionID: String,
            pricePointID: String,
            territoryID: String,
            startDate: Date? = nil,
            preserveCurrentPrice: Bool? = nil
        ) async throws -> Price {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionPrices"
                    let attributes: Attrs?
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let startDate: Date?
                    let preserveCurrentPrice: Bool?
                }
                struct Rels: Encodable {
                    struct S: Encodable {
                        struct D: Encodable { let type = "subscriptions"; let id: String }
                        let data: D
                    }
                    struct PP: Encodable {
                        struct D: Encodable { let type = "subscriptionPricePoints"; let id: String }
                        let data: D
                    }
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: D
                    }
                    let subscription: S
                    let subscriptionPricePoint: PP
                    let territory: T
                }
                let data: Data
            }
            let attrs: Body.Attrs? = (startDate == nil && preserveCurrentPrice == nil)
                ? nil
                : Body.Attrs(startDate: startDate, preserveCurrentPrice: preserveCurrentPrice)
            let body = Body(data: .init(
                attributes: attrs,
                relationships: .init(
                    subscription: .init(data: .init(id: subscriptionID)),
                    subscriptionPricePoint: .init(data: .init(id: pricePointID)),
                    territory: .init(data: .init(id: territoryID))
                )
            ))
            struct Resp: Decodable { let data: Price }
            let resp: Resp = try await client.post(
                path: "subscriptionPrices", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptionPrices/\(id)")
        }
    }

    // MARK: - Subscription Price Points
    //
    // Read-only catalog of Apple's tiered price points per (territory,
    // subscription duration). Resolve a UI price like "$9.99" to the
    // price-point ID that subscriptionPrices.create wants.

    package struct PricePoints: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PricePoint: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Customer-facing price in the territory's currency,
                /// formatted as "9.99".
                package let customerPrice: String?
                /// Developer proceeds after Apple's commission, same units.
                package let proceeds: String?
            }
        }

        /// List price points for a given subscription, scoped to one
        /// territory. Apple paginates this, so honor cursor/limit.
        package func list(
            subscriptionID: String,
            territoryID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PricePoint> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/pricePoints",
                limit: limit,
                cursor: cursor,
                extra: ["filter[territory]": territoryID]
            )
        }

        /// Convenience: linear scan for the cheapest tier in a territory.
        /// Useful for "what's the lowest price you can ship at?" tooling.
        package func findLowest(
            subscriptionID: String,
            territoryID: String
        ) async throws -> PricePoint? {
            let page = try await list(
                subscriptionID: subscriptionID,
                territoryID: territoryID,
                limit: 200
            )
            return page.items.min { l, r in
                let lp = Double(l.attributes?.customerPrice ?? "") ?? .greatestFiniteMagnitude
                let rp = Double(r.attributes?.customerPrice ?? "") ?? .greatestFiniteMagnitude
                return lp < rp
            }
        }
    }

    // MARK: - Subscription Offer Codes
    //
    // Offer codes drive the "win-back" and promotional flows. A single
    // offerCode resource owns the program; the code material itself
    // lives in either the one-time-use or custom-codes child resource.

    package struct OfferCodes: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct OfferCode: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Developer-visible label.
                package let referenceName: String?
                /// "FREE_TRIAL" | "PAY_AS_YOU_GO" | "PAY_UP_FRONT".
                package let offerType: String?
                /// "ONE_WEEK", "ONE_MONTH", ... matches subscriptionPeriod.
                package let duration: String?
                /// Periods the discounted price holds (Pay-as-you-go only).
                package let numberOfPeriods: Int?
                /// Single-code "PAY_AS_YOU_GO" specifics: customer pays full
                /// price at this point.
                package let isActive: Bool?
                package let totalNumberOfCodes: Int?
                package let totalNumberOfRedeemedCodes: Int?
                /// Eligibility: "NEW", "EXISTING", "EXPIRED" (or combinations).
                package let customerEligibilities: [String]?
            }
        }

        package func list(
            subscriptionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<OfferCode> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/offerCodes",
                limit: limit,
                cursor: cursor
            )
        }

        package func get(id: String) async throws -> OfferCode? {
            struct Resp: Decodable { let data: OfferCode }
            guard let resp = try await SubscriptionsAPI.fetchOrNil(
                client: client, path: "subscriptionOfferCodes/\(id)", as: Resp.self
            ) else { return nil }
            return resp.data
        }

        /// Creates a new offer-code program against a subscription.
        /// territoryIDs decides where the offer is redeemable; the
        /// caller usually couples this with `offerCodePrices.create`
        /// per-territory afterwards.
        package func create(
            subscriptionID: String,
            referenceName: String,
            offerType: String,
            duration: String,
            numberOfPeriods: Int? = nil,
            customerEligibilities: [String],
            totalNumberOfCodes: Int? = nil
        ) async throws -> OfferCode {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionOfferCodes"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let referenceName: String
                    let offerType: String
                    let duration: String
                    let numberOfPeriods: Int?
                    let customerEligibilities: [String]
                    let totalNumberOfCodes: Int?
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
                    referenceName: referenceName,
                    offerType: offerType,
                    duration: duration,
                    numberOfPeriods: numberOfPeriods,
                    customerEligibilities: customerEligibilities,
                    totalNumberOfCodes: totalNumberOfCodes
                ),
                relationships: .init(subscription: .init(data: .init(id: subscriptionID)))
            ))
            struct Resp: Decodable { let data: OfferCode }
            let resp: Resp = try await client.post(
                path: "subscriptionOfferCodes", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            referenceName: String? = nil,
            isActive: Bool? = nil
        ) async throws -> OfferCode {
            struct AttrsPatch: Encodable {
                var referenceName: String?
                var active: Bool?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionOfferCodes"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(referenceName: referenceName, active: isActive)
            ))
            struct Resp: Decodable { let data: OfferCode }
            let resp: Resp = try await client.patch(
                path: "subscriptionOfferCodes/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptionOfferCodes/\(id)")
        }
    }

    // MARK: - Offer Code One-Time-Use Codes
    //
    // Apple generates a batch of unique single-use codes. Create with a
    // count; list to retrieve generated codes.

    package struct OfferCodeOneTimeUseCodes: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct OneTimeUseCode: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// e.g. "ABCD-EFGH-IJKL".
                package let numberOfCodes: Int?
                /// True once Apple has fully generated the batch.
                package let isActive: Bool?
                package let createdDate: Date?
                package let expirationDate: Date?
            }
        }

        package func list(
            offerCodeID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<OneTimeUseCode> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptionOfferCodes/\(offerCodeID)/oneTimeUseCodes",
                limit: limit,
                cursor: cursor
            )
        }

        /// Generates `numberOfCodes` fresh one-time-use codes against the
        /// parent offer code program. Apple processes the batch
        /// asynchronously; poll list/get until isActive is true.
        package func create(
            offerCodeID: String,
            numberOfCodes: Int,
            expirationDate: Date? = nil
        ) async throws -> OneTimeUseCode {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionOfferCodeOneTimeUseCodes"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let numberOfCodes: Int
                    let expirationDate: Date?
                }
                struct Rels: Encodable {
                    struct O: Encodable {
                        struct D: Encodable { let type = "subscriptionOfferCodes"; let id: String }
                        let data: D
                    }
                    let offerCode: O
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(numberOfCodes: numberOfCodes, expirationDate: expirationDate),
                relationships: .init(offerCode: .init(data: .init(id: offerCodeID)))
            ))
            struct Resp: Decodable { let data: OneTimeUseCode }
            let resp: Resp = try await client.post(
                path: "subscriptionOfferCodeOneTimeUseCodes", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - Offer Code Custom Codes
    //
    // Developer-chosen redemption strings (e.g. "BLACKFRIDAY2025").
    // Useful for marketing campaigns where you want a memorable code.

    package struct OfferCodeCustomCodes: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct CustomCode: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// The actual code string customers type.
                package let customCode: String?
                package let numberOfCodes: Int?
                package let isActive: Bool?
                package let createdDate: Date?
                package let expirationDate: Date?
            }
        }

        package func list(
            offerCodeID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<CustomCode> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptionOfferCodes/\(offerCodeID)/customCodes",
                limit: limit,
                cursor: cursor
            )
        }

        package func create(
            offerCodeID: String,
            customCode: String,
            numberOfCodes: Int,
            expirationDate: Date? = nil
        ) async throws -> CustomCode {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionOfferCodeCustomCodes"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let customCode: String
                    let numberOfCodes: Int
                    let expirationDate: Date?
                }
                struct Rels: Encodable {
                    struct O: Encodable {
                        struct D: Encodable { let type = "subscriptionOfferCodes"; let id: String }
                        let data: D
                    }
                    let offerCode: O
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    customCode: customCode,
                    numberOfCodes: numberOfCodes,
                    expirationDate: expirationDate
                ),
                relationships: .init(offerCode: .init(data: .init(id: offerCodeID)))
            ))
            struct Resp: Decodable { let data: CustomCode }
            let resp: Resp = try await client.post(
                path: "subscriptionOfferCodeCustomCodes", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptionOfferCodeCustomCodes/\(id)")
        }
    }

    // MARK: - Offer Code Prices
    //
    // Per-territory price points for an offer code. One record per
    // territory; create + list only.

    package struct OfferCodePrices: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct OfferCodePrice: Codable, Sendable {
            package let id: String
        }

        package func list(
            offerCodeID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<OfferCodePrice> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptionOfferCodes/\(offerCodeID)/prices",
                limit: limit,
                cursor: cursor
            )
        }

        package func create(
            offerCodeID: String,
            pricePointID: String,
            territoryID: String
        ) async throws -> OfferCodePrice {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionOfferCodePrices"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct O: Encodable {
                        struct D: Encodable { let type = "subscriptionOfferCodes"; let id: String }
                        let data: D
                    }
                    struct PP: Encodable {
                        struct D: Encodable { let type = "subscriptionPricePoints"; let id: String }
                        let data: D
                    }
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: D
                    }
                    let offerCode: O
                    let subscriptionPricePoint: PP
                    let territory: T
                }
                let data: Data
            }
            let body = Body(data: .init(
                relationships: .init(
                    offerCode: .init(data: .init(id: offerCodeID)),
                    subscriptionPricePoint: .init(data: .init(id: pricePointID)),
                    territory: .init(data: .init(id: territoryID))
                )
            ))
            struct Resp: Decodable { let data: OfferCodePrice }
            let resp: Resp = try await client.post(
                path: "subscriptionOfferCodePrices", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - Promotional Offers
    //
    // Introductory offers Apple shows to new subscribers when the binary
    // calls into StoreKit's introductory-price entitlement. Unlike offer
    // codes, these don't require a code; the StoreKit framework targets
    // them by id.

    package struct PromotionalOffers: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PromotionalOffer: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Developer-visible name.
                package let name: String?
                /// Reverse-DNS identifier used by StoreKit at purchase.
                package let offerCode: String?
                /// "FREE_TRIAL" | "PAY_AS_YOU_GO" | "PAY_UP_FRONT".
                package let offerType: String?
                package let duration: String?
                package let numberOfPeriods: Int?
            }
        }

        package func list(
            subscriptionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PromotionalOffer> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/promotionalOffers",
                limit: limit,
                cursor: cursor
            )
        }

        package func get(id: String) async throws -> PromotionalOffer? {
            struct Resp: Decodable { let data: PromotionalOffer }
            guard let resp = try await SubscriptionsAPI.fetchOrNil(
                client: client,
                path: "subscriptionPromotionalOffers/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        package func create(
            subscriptionID: String,
            name: String,
            offerCode: String,
            offerType: String,
            duration: String,
            numberOfPeriods: Int? = nil
        ) async throws -> PromotionalOffer {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionPromotionalOffers"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let name: String
                    let offerCode: String
                    let offerType: String
                    let duration: String
                    let numberOfPeriods: Int?
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
                    offerType: offerType,
                    duration: duration,
                    numberOfPeriods: numberOfPeriods
                ),
                relationships: .init(subscription: .init(data: .init(id: subscriptionID)))
            ))
            struct Resp: Decodable { let data: PromotionalOffer }
            let resp: Resp = try await client.post(
                path: "subscriptionPromotionalOffers", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            name: String? = nil
        ) async throws -> PromotionalOffer {
            struct AttrsPatch: Encodable {
                var name: String?
            }
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionPromotionalOffers"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: AttrsPatch(name: name)
            ))
            struct Resp: Decodable { let data: PromotionalOffer }
            let resp: Resp = try await client.patch(
                path: "subscriptionPromotionalOffers/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptionPromotionalOffers/\(id)")
        }
    }

    // MARK: - Promotional Offer Prices
    //
    // Per-territory pricing for a promotional offer.

    package struct PromotionalOfferPrices: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PromoOfferPrice: Codable, Sendable {
            package let id: String
        }

        package func list(
            promotionalOfferID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PromoOfferPrice> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptionPromotionalOffers/\(promotionalOfferID)/prices",
                limit: limit,
                cursor: cursor
            )
        }

        package func create(
            promotionalOfferID: String,
            pricePointID: String,
            territoryID: String
        ) async throws -> PromoOfferPrice {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionPromotionalOfferPrices"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct P: Encodable {
                        struct D: Encodable { let type = "subscriptionPromotionalOffers"; let id: String }
                        let data: D
                    }
                    struct PP: Encodable {
                        struct D: Encodable { let type = "subscriptionPricePoints"; let id: String }
                        let data: D
                    }
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: D
                    }
                    let subscriptionPromotionalOffer: P
                    let subscriptionPricePoint: PP
                    let territory: T
                }
                let data: Data
            }
            let body = Body(data: .init(
                relationships: .init(
                    subscriptionPromotionalOffer: .init(data: .init(id: promotionalOfferID)),
                    subscriptionPricePoint: .init(data: .init(id: pricePointID)),
                    territory: .init(data: .init(id: territoryID))
                )
            ))
            struct Resp: Decodable { let data: PromoOfferPrice }
            let resp: Resp = try await client.post(
                path: "subscriptionPromotionalOfferPrices", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - Subscription Availabilities
    //
    // Territory availability for a subscription. Single get + update; ASC
    // replaces the territory list wholesale on each PATCH.

    package struct Availabilities: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Availability: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// True when newly added Apple territories auto-enroll.
                package let availableInNewTerritories: Bool?
            }
        }

        /// Fetches the subscription's current availability record. Returns
        /// nil when the subscription has never had availability set.
        package func get(subscriptionID: String) async throws -> Availability? {
            struct Resp: Decodable { let data: Availability }
            guard let resp = try await SubscriptionsAPI.fetchOrNil(
                client: client,
                path: "subscriptions/\(subscriptionID)/subscriptionAvailability",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        /// Replaces the subscription's territory list. Pass the full set
        /// of allowed territories every time; ASC interprets this as the
        /// new exhaustive list.
        @discardableResult
        package func update(
            subscriptionID: String,
            territoryIDs: [String],
            availableInNewTerritories: Bool
        ) async throws -> Availability {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionAvailabilities"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable { let availableInNewTerritories: Bool }
                struct Rels: Encodable {
                    struct S: Encodable {
                        struct D: Encodable { let type = "subscriptions"; let id: String }
                        let data: D
                    }
                    struct T: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: [D]
                    }
                    let subscription: S
                    let availableTerritories: T
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(availableInNewTerritories: availableInNewTerritories),
                relationships: .init(
                    subscription: .init(data: .init(id: subscriptionID)),
                    availableTerritories: .init(data: territoryIDs.sorted().map { .init(id: $0) })
                )
            ))
            struct Resp: Decodable { let data: Availability }
            let resp: Resp = try await client.post(
                path: "subscriptionAvailabilities", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - Subscription Submissions
    //
    // Sibling of `reviewSubmissions` for the in-app-purchase / subscription
    // family. Used to push metadata changes (localizations, review
    // screenshots, review note) to App Review.

    package struct Submissions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Submission: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// "WAITING_FOR_REVIEW" | "IN_REVIEW" | "APPROVED" |
                /// "REJECTED" | "CANCELED".
                package let state: String?
                package let submittedDate: Date?
            }
        }

        package func list(
            subscriptionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Submission> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/subscriptionSubmissions",
                limit: limit,
                cursor: cursor
            )
        }

        package func get(id: String) async throws -> Submission? {
            struct Resp: Decodable { let data: Submission }
            guard let resp = try await SubscriptionsAPI.fetchOrNil(
                client: client,
                path: "subscriptionSubmissions/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        /// Submit a subscription's pending metadata edits for App Review.
        /// Returns the new submission record in WAITING_FOR_REVIEW.
        package func create(
            subscriptionID: String
        ) async throws -> Submission {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionSubmissions"
                    let relationships: Rels
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
                relationships: .init(subscription: .init(data: .init(id: subscriptionID)))
            ))
            struct Resp: Decodable { let data: Submission }
            let resp: Resp = try await client.post(
                path: "subscriptionSubmissions", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - App Store Review Screenshots
    //
    // Review-only screenshots Apple requires for subscription approval
    // (visual proof of the subscription paywall, value prop, etc).
    // CRUD per resource; the binary upload follows the same three-step
    // dance as appScreenshots — POST creates the slot and returns
    // `uploadOperations`, the caller PUTs the chunks, then a PATCH
    // marks it uploaded.

    package struct ReviewScreenshots: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        /// Per-chunk upload instruction Apple returns on reservation.
        package struct UploadOperation: Codable, Sendable {
            package let method: String
            package let url: String
            package let length: Int
            package let offset: Int
            package let requestHeaders: [HeaderEntry]

            package struct HeaderEntry: Codable, Sendable {
                package let name: String
                package let value: String
            }
        }

        package struct ReviewScreenshot: Codable, Sendable {
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

        package func list(
            subscriptionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<ReviewScreenshot> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/appStoreReviewScreenshot",
                limit: limit,
                cursor: cursor
            )
        }

        package func get(id: String) async throws -> ReviewScreenshot? {
            struct Resp: Decodable { let data: ReviewScreenshot }
            guard let resp = try await SubscriptionsAPI.fetchOrNil(
                client: client,
                path: "subscriptionAppStoreReviewScreenshots/\(id)",
                as: Resp.self
            ) else { return nil }
            return resp.data
        }

        /// Reserves a new review-screenshot slot. The returned record's
        /// `uploadOperations` carry the pre-signed URLs callers PUT the
        /// chunks to.
        package func create(
            subscriptionID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> ReviewScreenshot {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionAppStoreReviewScreenshots"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int
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
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(subscription: .init(data: .init(id: subscriptionID)))
            ))
            struct Resp: Decodable { let data: ReviewScreenshot }
            let resp: Resp = try await client.post(
                path: "subscriptionAppStoreReviewScreenshots", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Marks the asset uploaded once the binary chunks have been PUT.
        /// `checksum` is the MD5 of the file bytes that ASC matches against
        /// what arrived.
        @discardableResult
        package func confirmUpload(
            id: String,
            checksum: String
        ) async throws -> ReviewScreenshot {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionAppStoreReviewScreenshots"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let uploaded = true
                    let sourceFileChecksum: String
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id, attributes: .init(sourceFileChecksum: checksum)
            ))
            struct Resp: Decodable { let data: ReviewScreenshot }
            let resp: Resp = try await client.patch(
                path: "subscriptionAppStoreReviewScreenshots/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptionAppStoreReviewScreenshots/\(id)")
        }
    }

    // MARK: - Subscription Images
    //
    // Promotional artwork. Same three-step upload as review screenshots.

    package struct Images: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct UploadOperation: Codable, Sendable {
            package let method: String
            package let url: String
            package let length: Int
            package let offset: Int
            package let requestHeaders: [HeaderEntry]

            package struct HeaderEntry: Codable, Sendable {
                package let name: String
                package let value: String
            }
        }

        package struct Image: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileSize: Int?
                package let fileName: String?
                package let sourceFileChecksum: String?
                package let uploadOperations: [UploadOperation]?
                package let state: String?
            }
        }

        package func list(
            subscriptionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Image> {
            try await SubscriptionsAPI.paginated(
                client: client,
                path: "subscriptions/\(subscriptionID)/images",
                limit: limit,
                cursor: cursor
            )
        }

        package func create(
            subscriptionID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "subscriptionImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int
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
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(subscription: .init(data: .init(id: subscriptionID)))
            ))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.post(
                path: "subscriptionImages", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "subscriptionImages/\(id)")
        }
    }
}
