import Foundation
import CryptoKit

/// App Store Connect endpoints for one-time In-App Purchases (IAP V2 API).
///
/// Apple deprecated the original V1 IAP endpoints in 2023; this wrapper
/// covers only the V2 surface (`inAppPurchases/v2` create/update, plus the
/// satellite resources that hang off it). Subscriptions are a separate
/// resource family (`subscriptionGroups`, `subscriptions`) and are NOT
/// covered here — V2 IAP only handles consumable, non-consumable, and
/// non-renewing subscription product types.
///
/// Resources covered:
///   - inAppPurchases (V2): list/get/create/update/delete the parent IAP
///   - inAppPurchaseLocalizations: per-locale name + description
///   - inAppPurchasePricePoints: read-only catalog of valid price tiers
///   - inAppPurchasePriceSchedules: set manual prices with territory config
///   - inAppPurchaseSubmissions: submit an IAP for review
///   - inAppPurchaseContentHostings: Apple-hosted content for non-consumables
///   - inAppPurchaseImages: promotional images on the IAP detail page
///   - inAppPurchaseAppStoreReviewScreenshots: review screenshots Apple needs
///   - inAppPurchasePromotionalImages: artwork used in featured slots
///   - promotedPurchases: which IAPs are promoted in the App Store storefront
///   - promotedPurchaseImages: artwork for those promoted slots
///
/// Each nested namespace mirrors the AppsAPI pattern of one type per Apple
/// resource family. All endpoints surface 404 as nil where the call shape
/// allows it (single-resource gets) and surface 409 "already set" through
/// `ASCClient.APIError.isAlreadySetConflict`, same convention as elsewhere.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/app_store/in-app_purchases
package struct InAppPurchasesAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // Nested namespaces — each maps to one Apple resource family.
    package var purchases: Purchases { Purchases(client: client) }
    package var localizations: Localizations { Localizations(client: client) }
    package var pricePoints: PricePoints { PricePoints(client: client) }
    package var priceSchedules: PriceSchedules { PriceSchedules(client: client) }
    package var submissions: Submissions { Submissions(client: client) }
    package var contentHostings: ContentHostings { ContentHostings(client: client) }
    package var images: Images { Images(client: client) }
    package var reviewScreenshots: ReviewScreenshots { ReviewScreenshots(client: client) }
    package var promotionalImages: PromotionalImages { PromotionalImages(client: client) }
    package var promotedPurchases: PromotedPurchases { PromotedPurchases(client: client) }
    package var promotedPurchaseImages: PromotedPurchaseImages { PromotedPurchaseImages(client: client) }

    // MARK: - Shared pagination shape

    /// A page of results plus the cursor needed to fetch the next page. Apple
    /// returns the cursor in `links.next` as a full URL; we hand it back as
    /// an opaque string and pass it back unchanged on the follow-up call.
    package struct Page<Item: Codable & Sendable>: Sendable {
        package let items: [Item]
        package let nextCursor: String?
    }

    /// Apple's JSON:API "links" block. The next URL embeds the cursor as a
    /// `cursor` query parameter; we extract it so callers can pass just the
    /// opaque cursor token rather than juggling URLs.
    fileprivate struct PaginationLinks: Decodable {
        let next: String?
    }

    fileprivate struct PagedResponse<Item: Codable & Sendable>: Decodable {
        let data: [Item]
        let links: PaginationLinks?
    }

    /// Extracts the `cursor` query value from Apple's `links.next` URL. Apple
    /// embeds an opaque token there; we hand it back as-is.
    fileprivate static func extractCursor(from links: PaginationLinks?) -> String? {
        guard let next = links?.next, let comps = URLComponents(string: next) else {
            return nil
        }
        return comps.queryItems?.first { $0.name == "cursor" }?.value
    }

    // MARK: - Shared utility: query with optional cursor

    fileprivate static func paginationQuery(limit: Int, cursor: String?) -> [String: String] {
        var q: [String: String] = ["limit": String(limit)]
        if let cursor { q["cursor"] = cursor }
        return q
    }

    fileprivate static func wrapPage<Item: Codable & Sendable>(_ resp: PagedResponse<Item>) -> Page<Item> {
        Page(items: resp.data, nextCursor: extractCursor(from: resp.links))
    }

    // MARK: - In-App Purchases (V2 parent resource)

    /// Operations on the V2 inAppPurchases resource.
    ///
    /// Apple uses three product types here:
    ///   - `CONSUMABLE` — used up on purchase (e.g. in-game coins)
    ///   - `NON_CONSUMABLE` — permanent unlock (e.g. ad-removal)
    ///   - `NON_RENEWING_SUBSCRIPTION` — fixed duration, no auto-renew
    /// Auto-renewing subscriptions are a different resource family
    /// (`subscriptionGroups`, `subscriptions`) and are not handled here.
    package struct Purchases: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Purchase: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let name: String?
                /// Bundle-scoped product id, e.g. "com.acme.pro_unlock".
                package let productId: String?
                /// "CONSUMABLE" | "NON_CONSUMABLE" | "NON_RENEWING_SUBSCRIPTION".
                package let inAppPurchaseType: String?
                /// "MISSING_METADATA" | "READY_TO_SUBMIT" | "WAITING_FOR_REVIEW" |
                /// "IN_REVIEW" | "DEVELOPER_ACTION_NEEDED" | "PENDING_BINARY_APPROVAL" |
                /// "APPROVED" | "REJECTED" | "DEVELOPER_REMOVED_FROM_SALE" | "REMOVED_FROM_SALE".
                package let state: String?
                /// Customer-facing pricing model: "PAY_AS_YOU_GO" | "PAY_UP_FRONT" | "FREE_OF_CHARGE".
                /// Not always populated — depends on the product type.
                package let reviewNote: String?
                package let familySharable: Bool?
                /// Only meaningful for NON_RENEWING_SUBSCRIPTION; ISO 8601 duration.
                package let availableInAllTerritories: Bool?
            }
        }

        /// Lists IAPs for an app. Apple returns a paginated list; callers
        /// pass the returned cursor on the next call until `nextCursor` is nil.
        package func list(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Purchase> {
            let resp: PagedResponse<Purchase> = try await client.get(
                path: "apps/\(appID)/inAppPurchasesV2",
                query: paginationQuery(limit: limit, cursor: cursor),
                as: PagedResponse<Purchase>.self
            )
            return wrapPage(resp)
        }

        /// Returns nil on 404 so callers can branch on "not found" without try/catch.
        package func get(id: String) async throws -> Purchase? {
            struct Resp: Decodable { let data: Purchase }
            do {
                let resp: Resp = try await client.get(
                    path: "inAppPurchases/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Find the IAP whose `productId` matches. Returns nil if no match.
        /// Walks pages with a default cap of 5 pages (~1000 IAPs) to bound the
        /// search. Most apps have < 50 IAPs; callers with more should use
        /// `list` + cursor directly.
        package func findByProductID(
            appID: String,
            productID: String,
            maxPages: Int = 5
        ) async throws -> Purchase? {
            var cursor: String? = nil
            for _ in 0..<maxPages {
                let page = try await list(appID: appID, limit: 200, cursor: cursor)
                if let hit = page.items.first(where: { $0.attributes?.productId == productID }) {
                    return hit
                }
                guard let next = page.nextCursor else { return nil }
                cursor = next
            }
            return nil
        }

        package struct CreateFields: Sendable, Equatable {
            package var name: String
            package var productID: String
            /// "CONSUMABLE" | "NON_CONSUMABLE" | "NON_RENEWING_SUBSCRIPTION".
            package var inAppPurchaseType: String
            package var reviewNote: String?
            package var familySharable: Bool?
            package var availableInAllTerritories: Bool?

            package init(
                name: String,
                productID: String,
                inAppPurchaseType: String,
                reviewNote: String? = nil,
                familySharable: Bool? = nil,
                availableInAllTerritories: Bool? = nil
            ) {
                self.name = name
                self.productID = productID
                self.inAppPurchaseType = inAppPurchaseType
                self.reviewNote = reviewNote
                self.familySharable = familySharable
                self.availableInAllTerritories = availableInAllTerritories
            }
        }

        @discardableResult
        package func create(appID: String, fields: CreateFields) async throws -> Purchase {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchases"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let name: String
                    let productId: String
                    let inAppPurchaseType: String
                    let reviewNote: String?
                    let familySharable: Bool?
                    let availableInAllTerritories: Bool?
                }
                struct Rels: Encodable {
                    struct App: Encodable {
                        struct Data: Encodable { let type = "apps"; let id: String }
                        let data: Data
                    }
                    let app: App
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    name: fields.name,
                    productId: fields.productID,
                    inAppPurchaseType: fields.inAppPurchaseType,
                    reviewNote: fields.reviewNote,
                    familySharable: fields.familySharable,
                    availableInAllTerritories: fields.availableInAllTerritories
                ),
                relationships: .init(app: .init(data: .init(id: appID)))
            ))
            struct Resp: Decodable { let data: Purchase }
            let resp: Resp = try await client.post(
                path: "v2/inAppPurchases",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package struct UpdateFields: Sendable, Equatable {
            package var name: String?
            package var reviewNote: String?
            package var familySharable: Bool?
            package var availableInAllTerritories: Bool?

            package init(
                name: String? = nil,
                reviewNote: String? = nil,
                familySharable: Bool? = nil,
                availableInAllTerritories: Bool? = nil
            ) {
                self.name = name
                self.reviewNote = reviewNote
                self.familySharable = familySharable
                self.availableInAllTerritories = availableInAllTerritories
            }
        }

        /// PATCH the IAP. Nil fields stay untouched on ASC. Product ID and
        /// product type are NOT editable post-create; Apple rejects either
        /// field appearing in a PATCH body.
        @discardableResult
        package func update(id: String, fields: UpdateFields) async throws -> Purchase {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchases"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let name: String?
                    let reviewNote: String?
                    let familySharable: Bool?
                    let availableInAllTerritories: Bool?
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(
                    name: fields.name,
                    reviewNote: fields.reviewNote,
                    familySharable: fields.familySharable,
                    availableInAllTerritories: fields.availableInAllTerritories
                )
            ))
            struct Resp: Decodable { let data: Purchase }
            let resp: Resp = try await client.patch(
                path: "inAppPurchases/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        /// Deletes the IAP. Apple only permits delete while the IAP is in
        /// MISSING_METADATA, READY_TO_SUBMIT, or DEVELOPER_ACTION_NEEDED;
        /// approved IAPs can be removed-from-sale but not deleted.
        package func delete(id: String) async throws {
            try await client.delete(path: "inAppPurchases/\(id)")
        }
    }

    // MARK: - Localizations

    /// Per-locale display fields (name, description) on an IAP.
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
                /// "PREPARE_FOR_SUBMISSION" | "APPROVED" | "REJECTED" |
                /// "WAITING_FOR_REVIEW".
                package let state: String?
            }
        }

        package func list(
            iapID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Localization> {
            let resp: PagedResponse<Localization> = try await client.get(
                path: "inAppPurchases/\(iapID)/inAppPurchaseLocalizations",
                query: paginationQuery(limit: limit, cursor: cursor),
                as: PagedResponse<Localization>.self
            )
            return wrapPage(resp)
        }

        package func get(id: String) async throws -> Localization? {
            struct Resp: Decodable { let data: Localization }
            do {
                let resp: Resp = try await client.get(
                    path: "inAppPurchaseLocalizations/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        package func find(iapID: String, locale: String) async throws -> Localization? {
            // IAPs typically have < 40 locales; one page covers it.
            let page = try await list(iapID: iapID, limit: 200, cursor: nil)
            return page.items.first { $0.attributes?.locale == locale }
        }

        @discardableResult
        package func create(
            iapID: String,
            locale: String,
            name: String,
            description: String?
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    let name: String
                    let description: String?
                }
                struct Rels: Encodable {
                    struct IAP: Encodable {
                        struct Data: Encodable { let type = "inAppPurchases"; let id: String }
                        let data: Data
                    }
                    let inAppPurchaseV2: IAP
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(locale: locale, name: name, description: description),
                relationships: .init(inAppPurchaseV2: .init(data: .init(id: iapID)))
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.post(
                path: "inAppPurchaseLocalizations",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package struct UpdateFields: Sendable, Equatable {
            package var name: String?
            package var description: String?

            package init(name: String? = nil, description: String? = nil) {
                self.name = name
                self.description = description
            }
        }

        @discardableResult
        package func update(id: String, fields: UpdateFields) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseLocalizations"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let name: String?
                    let description: String?
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(name: fields.name, description: fields.description)
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.patch(
                path: "inAppPurchaseLocalizations/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "inAppPurchaseLocalizations/\(id)")
        }

        /// Find-or-create convenience: returns the localization, creating it
        /// if missing. If created, `name` is required (Apple rejects a blank
        /// name).
        @discardableResult
        package func findOrCreate(
            iapID: String,
            locale: String,
            name: String,
            description: String? = nil
        ) async throws -> Localization {
            if let existing = try await find(iapID: iapID, locale: locale) {
                return existing
            }
            return try await create(
                iapID: iapID, locale: locale, name: name, description: description
            )
        }
    }

    // MARK: - Price points (read-only catalog)

    /// Read-only catalog of valid price tiers per territory. The IDs returned
    /// here are what `priceSchedules.set` expects in its manual-price list.
    package struct PricePoints: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PricePoint: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Customer-facing price in the territory's currency, as a
                /// decimal string (e.g. "9.99").
                package let customerPrice: String?
                /// Developer's take in the same currency.
                package let proceeds: String?
                /// ISO 4217 currency code, e.g. "USD". Some payloads carry the
                /// territory under a relationships block instead — keep this
                /// nullable.
                package let priceTier: String?
            }
        }

        /// Lists price points for an IAP, optionally filtered to a single
        /// territory. Pass `territoryID` like "USA" (ISO 3166-1 alpha-3) to
        /// scope the list — without it you'll get every territory's tier,
        /// which is hundreds of rows per IAP.
        package func list(
            iapID: String,
            territoryID: String? = nil,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PricePoint> {
            var query = paginationQuery(limit: limit, cursor: cursor)
            if let territoryID {
                query["filter[territory]"] = territoryID
            }
            let resp: PagedResponse<PricePoint> = try await client.get(
                path: "inAppPurchases/\(iapID)/pricePoints",
                query: query,
                as: PagedResponse<PricePoint>.self
            )
            return wrapPage(resp)
        }

        package func get(id: String) async throws -> PricePoint? {
            struct Resp: Decodable { let data: PricePoint }
            do {
                let resp: Resp = try await client.get(
                    path: "inAppPurchasePricePoints/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Finds the price point whose `customerPrice` matches the requested
        /// decimal string (e.g. "9.99"). Useful when the caller knows the
        /// dollar amount but not Apple's opaque tier id. Returns nil when no
        /// matching tier exists in the territory.
        package func findByCustomerPrice(
            iapID: String,
            territoryID: String,
            customerPrice: String
        ) async throws -> PricePoint? {
            // Walk pages until we find a hit or run out. Apple has ~90 tiers
            // per territory so one page usually covers it.
            var cursor: String? = nil
            for _ in 0..<5 {
                let page = try await list(
                    iapID: iapID, territoryID: territoryID, limit: 200, cursor: cursor
                )
                if let hit = page.items.first(where: {
                    $0.attributes?.customerPrice == customerPrice
                }) {
                    return hit
                }
                guard let next = page.nextCursor else { return nil }
                cursor = next
            }
            return nil
        }
    }

    // MARK: - Price schedules

    /// Manual price configuration on an IAP. A schedule binds the IAP to one
    /// or more (territory, price-point, start-date) tuples; Apple uses the
    /// schedule to compute the customer-facing price at any given moment.
    package struct PriceSchedules: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PriceSchedule: Codable, Sendable {
            package let id: String
        }

        package struct Price: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// ISO 8601 start date when this price becomes active.
                package let startDate: Date?
                /// ISO 8601 end date; nil when the price runs indefinitely.
                package let endDate: Date?
            }
        }

        /// Returns the IAP's current price schedule, or nil if none is set.
        /// Apple represents this as a 1:1 sub-resource on the IAP.
        package func get(iapID: String) async throws -> PriceSchedule? {
            struct Resp: Decodable { let data: PriceSchedule? }
            do {
                let resp: Resp = try await client.get(
                    path: "inAppPurchases/\(iapID)/iapPriceSchedule",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Lists the price entries that make up a schedule. Most IAPs only
        /// have one entry (current price), but scheduled price changes show
        /// up as additional entries with future startDates.
        package func listPrices(
            scheduleID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Price> {
            let resp: PagedResponse<Price> = try await client.get(
                path: "iapPriceSchedules/\(scheduleID)/manualPrices",
                query: paginationQuery(limit: limit, cursor: cursor),
                as: PagedResponse<Price>.self
            )
            return wrapPage(resp)
        }

        /// One (territory, price-point) entry the caller wants to schedule.
        /// `startDate` is optional; when nil Apple applies the price immediately.
        package struct DesiredPrice: Sendable, Equatable {
            package let territoryID: String
            package let pricePointID: String
            package let startDate: Date?

            package init(territoryID: String, pricePointID: String, startDate: Date? = nil) {
                self.territoryID = territoryID
                self.pricePointID = pricePointID
                self.startDate = startDate
            }
        }

        /// Creates (or replaces) the IAP's price schedule. Apple's V2 IAP
        /// pricing endpoint is create-only: every call is a fresh record that
        /// supersedes whatever was previously on file. The caller passes the
        /// full desired list of (territory, price-point) tuples.
        ///
        /// `baseTerritoryID` is the territory whose price Apple uses to
        /// compute equivalents for any territory NOT in `prices` — usually
        /// "USA" for English-first apps.
        @discardableResult
        package func set(
            iapID: String,
            baseTerritoryID: String,
            prices: [DesiredPrice]
        ) async throws -> PriceSchedule {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "iapPriceSchedules"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct IAPRel: Encodable {
                        struct D: Encodable { let type = "inAppPurchases"; let id: String }
                        let data: D
                    }
                    struct TerRel: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: D
                    }
                    struct PricesRel: Encodable {
                        struct D: Encodable { let type = "iapPrices"; let id: String }
                        let data: [D]
                    }
                    let inAppPurchase: IAPRel
                    let baseTerritory: TerRel
                    let manualPrices: PricesRel
                }
                struct Included: Encodable {
                    let type = "iapPrices"
                    let id: String
                    let attributes: Attrs
                    let relationships: ManualRels

                    struct Attrs: Encodable {
                        let startDate: Date?
                    }
                    struct ManualRels: Encodable {
                        struct Ter: Encodable {
                            struct D: Encodable { let type = "territories"; let id: String }
                            let data: D
                        }
                        struct Point: Encodable {
                            struct D: Encodable { let type = "inAppPurchasePricePoints"; let id: String }
                            let data: D
                        }
                        let territory: Ter
                        let inAppPurchasePricePoint: Point
                    }
                }
                let data: Data
                let included: [Included]
            }

            // Each manual-price entry needs a synthetic id that we cross-reference
            // from the relationships block into the `included` block. Sequential
            // strings like "price-0", "price-1" are what Apple's examples use.
            let synthetic = prices.enumerated().map { idx, p in
                (id: "price-\(idx)", price: p)
            }
            let body = Body(
                data: .init(
                    relationships: .init(
                        inAppPurchase: .init(data: .init(id: iapID)),
                        baseTerritory: .init(data: .init(id: baseTerritoryID)),
                        manualPrices: .init(data: synthetic.map { .init(id: $0.id) })
                    )
                ),
                included: synthetic.map { entry in
                    Body.Included(
                        id: entry.id,
                        attributes: .init(startDate: entry.price.startDate),
                        relationships: .init(
                            territory: .init(data: .init(id: entry.price.territoryID)),
                            inAppPurchasePricePoint: .init(data: .init(id: entry.price.pricePointID))
                        )
                    )
                }
            )
            struct Resp: Decodable { let data: PriceSchedule }
            let resp: Resp = try await client.post(
                path: "iapPriceSchedules",
                body: body,
                as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - Submissions

    /// Submission of an IAP for App Review. An IAP submission is similar in
    /// shape to a `reviewSubmission` for an app store version: create one,
    /// then check `state` to see whether Apple has approved or rejected it.
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
            }
        }

        /// Lists submissions for an IAP. Submissions don't have a separate
        /// "open" vs "history" filter; check `attributes.state` to identify
        /// in-flight ones.
        package func list(
            iapID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Submission> {
            let resp: PagedResponse<Submission> = try await client.get(
                path: "inAppPurchases/\(iapID)/inAppPurchaseSubmissions",
                query: paginationQuery(limit: limit, cursor: cursor),
                as: PagedResponse<Submission>.self
            )
            return wrapPage(resp)
        }

        package func get(id: String) async throws -> Submission? {
            struct Resp: Decodable { let data: Submission }
            do {
                let resp: Resp = try await client.get(
                    path: "inAppPurchaseSubmissions/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Creates a new submission for the IAP. Apple gates this on the IAP
        /// being in `READY_TO_SUBMIT` state; submission of an IAP that is
        /// missing required metadata returns a 409 with details.
        @discardableResult
        package func create(iapID: String) async throws -> Submission {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseSubmissions"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct IAP: Encodable {
                        struct Data: Encodable { let type = "inAppPurchases"; let id: String }
                        let data: Data
                    }
                    let inAppPurchaseV2: IAP
                }
                let data: Data
            }
            let body = Body(data: .init(
                relationships: .init(inAppPurchaseV2: .init(data: .init(id: iapID)))
            ))
            struct Resp: Decodable { let data: Submission }
            let resp: Resp = try await client.post(
                path: "inAppPurchaseSubmissions",
                body: body,
                as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - Content hostings (Apple-hosted IAP content)

    /// Apple-hosted content payload for non-consumable IAPs that need to
    /// deliver files (e.g. downloadable level packs). Rare in modern apps;
    /// most apps deliver IAP content over their own backend.
    package struct ContentHostings: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct ContentHosting: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int?
                package let contentHostingState: String?
            }
        }

        /// Returns the content hosting record for an IAP, or nil if none is
        /// set. Apple represents this as a 1:1 sub-resource on the IAP.
        package func get(iapID: String) async throws -> ContentHosting? {
            struct Resp: Decodable { let data: ContentHosting? }
            do {
                let resp: Resp = try await client.get(
                    path: "inAppPurchases/\(iapID)/iapContentHosting",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Updates the content hosting record. Apple supports turning
        /// hosting on/off and updating metadata; the upload of the actual
        /// content file is a separate file-asset workflow not modeled here.
        package struct UpdateFields: Sendable, Equatable {
            package var fileName: String?

            package init(fileName: String? = nil) {
                self.fileName = fileName
            }
        }

        @discardableResult
        package func update(id: String, fields: UpdateFields) async throws -> ContentHosting {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "iapContentHostings"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let fileName: String?
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(fileName: fields.fileName)
            ))
            struct Resp: Decodable { let data: ContentHosting }
            let resp: Resp = try await client.patch(
                path: "iapContentHostings/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - Promotional images on the IAP detail page

    /// Images displayed on the IAP's detail page in the App Store. Different
    /// from `PromotionalImages` (which is the featured-slot artwork) and from
    /// `ReviewScreenshots` (which is what Apple reviewers see).
    package struct Images: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Image: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int?
                package let imageAsset: ImageAsset?
                package let sourceFileChecksum: String?
                package let uploadOperations: [ScreenshotsAPI.UploadOperation]?
                package let assetDeliveryState: AssetDeliveryState?

                package struct ImageAsset: Codable, Sendable {
                    package let templateUrl: String?
                    package let width: Int?
                    package let height: Int?
                }
                package struct AssetDeliveryState: Codable, Sendable {
                    package let state: String?
                }
            }
        }

        package func list(
            iapID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Image> {
            let resp: PagedResponse<Image> = try await client.get(
                path: "inAppPurchases/\(iapID)/images",
                query: paginationQuery(limit: limit, cursor: cursor),
                as: PagedResponse<Image>.self
            )
            return wrapPage(resp)
        }

        package func get(id: String) async throws -> Image? {
            struct Resp: Decodable { let data: Image }
            do {
                let resp: Resp = try await client.get(
                    path: "inAppPurchaseImages/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Step 1 of upload: reserve a slot. Returns the image record with
        /// `uploadOperations` populated.
        @discardableResult
        package func reserve(
            iapID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileSize: Int
                    let fileName: String
                }
                struct Rels: Encodable {
                    struct IAP: Encodable {
                        struct Data: Encodable { let type = "inAppPurchases"; let id: String }
                        let data: Data
                    }
                    let inAppPurchaseV2: IAP
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileSize: fileSize, fileName: fileName),
                relationships: .init(inAppPurchaseV2: .init(data: .init(id: iapID)))
            ))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.post(
                path: "inAppPurchaseImages",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        /// Step 3: confirm the upload with MD5 checksum.
        @discardableResult
        package func confirmUpload(id: String, md5Checksum: String) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let uploaded: Bool
                    let sourceFileChecksum: String
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(uploaded: true, sourceFileChecksum: md5Checksum)
            ))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.patch(
                path: "inAppPurchaseImages/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        /// Updates the image record's metadata. Apple permits renaming the
        /// uploaded file via PATCH; the bytes themselves can only be replaced
        /// by deleting + re-uploading.
        @discardableResult
        package func update(id: String, fileName: String?) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let fileName: String?
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(fileName: fileName)))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.patch(
                path: "inAppPurchaseImages/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "inAppPurchaseImages/\(id)")
        }

        /// Convenience: runs the full 3-step upload from a local file URL.
        @discardableResult
        package func upload(iapID: String, fileURL: URL) async throws -> Image {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let fileSize = data.count
            let md5 = ScreenshotsAPI.md5Hex(data: data)

            let reserved = try await reserve(
                iapID: iapID, fileName: fileName, fileSize: fileSize
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(domain: "InAppPurchasesAPI", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"])
            }
            try await ScreenshotsAPI(client: client).uploadChunks(operations: ops, fileData: data)
            return try await confirmUpload(id: reserved.id, md5Checksum: md5)
        }
    }

    // MARK: - App Store review screenshots (one per IAP)

    /// Screenshot Apple's reviewers see when triaging an IAP. Required for
    /// every IAP before submission; without it, `submissions.create` returns
    /// 409 with a "missing review screenshot" detail.
    package struct ReviewScreenshots: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct ReviewScreenshot: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int?
                package let sourceFileChecksum: String?
                package let uploadOperations: [ScreenshotsAPI.UploadOperation]?
                package let assetDeliveryState: AssetDeliveryState?

                package struct AssetDeliveryState: Codable, Sendable {
                    package let state: String?
                }
            }
        }

        /// Returns the IAP's review screenshot record, or nil if none is set.
        package func get(iapID: String) async throws -> ReviewScreenshot? {
            struct Resp: Decodable { let data: ReviewScreenshot? }
            do {
                let resp: Resp = try await client.get(
                    path: "inAppPurchases/\(iapID)/appStoreReviewScreenshot",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Step 1 of upload — reserve a slot.
        @discardableResult
        package func reserve(
            iapID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> ReviewScreenshot {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseAppStoreReviewScreenshots"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileSize: Int
                    let fileName: String
                }
                struct Rels: Encodable {
                    struct IAP: Encodable {
                        struct Data: Encodable { let type = "inAppPurchases"; let id: String }
                        let data: Data
                    }
                    let inAppPurchaseV2: IAP
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileSize: fileSize, fileName: fileName),
                relationships: .init(inAppPurchaseV2: .init(data: .init(id: iapID)))
            ))
            struct Resp: Decodable { let data: ReviewScreenshot }
            let resp: Resp = try await client.post(
                path: "inAppPurchaseAppStoreReviewScreenshots",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        /// Step 3: confirm with MD5 checksum.
        @discardableResult
        package func confirmUpload(id: String, md5Checksum: String) async throws -> ReviewScreenshot {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseAppStoreReviewScreenshots"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let uploaded: Bool
                    let sourceFileChecksum: String
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(uploaded: true, sourceFileChecksum: md5Checksum)
            ))
            struct Resp: Decodable { let data: ReviewScreenshot }
            let resp: Resp = try await client.patch(
                path: "inAppPurchaseAppStoreReviewScreenshots/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fileName: String?) async throws -> ReviewScreenshot {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "inAppPurchaseAppStoreReviewScreenshots"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let fileName: String?
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(fileName: fileName)))
            struct Resp: Decodable { let data: ReviewScreenshot }
            let resp: Resp = try await client.patch(
                path: "inAppPurchaseAppStoreReviewScreenshots/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "inAppPurchaseAppStoreReviewScreenshots/\(id)")
        }

        /// Convenience: runs the full 3-step upload from a local file URL.
        @discardableResult
        package func upload(iapID: String, fileURL: URL) async throws -> ReviewScreenshot {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let fileSize = data.count
            let md5 = ScreenshotsAPI.md5Hex(data: data)

            let reserved = try await reserve(
                iapID: iapID, fileName: fileName, fileSize: fileSize
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(domain: "InAppPurchasesAPI", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"])
            }
            try await ScreenshotsAPI(client: client).uploadChunks(operations: ops, fileData: data)
            return try await confirmUpload(id: reserved.id, md5Checksum: md5)
        }
    }

    // MARK: - Promotional images (featured-slot artwork)

    /// Artwork Apple uses in featured slots on the App Store storefront.
    /// Different from `Images` (the IAP detail page) and from
    /// `PromotedPurchaseImages` (the artwork tied to a `promotedPurchases`
    /// record). Note Apple's docs do NOT list an update operation for this
    /// resource — only list/create/delete — matching the deliverable spec.
    package struct PromotionalImages: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PromotionalImage: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int?
                package let sourceFileChecksum: String?
                package let uploadOperations: [ScreenshotsAPI.UploadOperation]?
                package let state: String?
            }
        }

        package func list(
            iapID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PromotionalImage> {
            let resp: PagedResponse<PromotionalImage> = try await client.get(
                path: "inAppPurchases/\(iapID)/promotionalImages",
                query: paginationQuery(limit: limit, cursor: cursor),
                as: PagedResponse<PromotionalImage>.self
            )
            return wrapPage(resp)
        }

        @discardableResult
        package func reserve(
            iapID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> PromotionalImage {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "promotedPurchaseImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileSize: Int
                    let fileName: String
                }
                struct Rels: Encodable {
                    struct IAP: Encodable {
                        struct Data: Encodable { let type = "inAppPurchases"; let id: String }
                        let data: Data
                    }
                    let inAppPurchaseV2: IAP
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileSize: fileSize, fileName: fileName),
                relationships: .init(inAppPurchaseV2: .init(data: .init(id: iapID)))
            ))
            struct Resp: Decodable { let data: PromotionalImage }
            let resp: Resp = try await client.post(
                path: "promotedPurchaseImages",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func confirmUpload(id: String, md5Checksum: String) async throws -> PromotionalImage {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "promotedPurchaseImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let uploaded: Bool
                    let sourceFileChecksum: String
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(uploaded: true, sourceFileChecksum: md5Checksum)
            ))
            struct Resp: Decodable { let data: PromotionalImage }
            let resp: Resp = try await client.patch(
                path: "promotedPurchaseImages/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "promotedPurchaseImages/\(id)")
        }

        /// Convenience: runs the full upload from a local file URL.
        @discardableResult
        package func upload(iapID: String, fileURL: URL) async throws -> PromotionalImage {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let fileSize = data.count
            let md5 = ScreenshotsAPI.md5Hex(data: data)

            let reserved = try await reserve(
                iapID: iapID, fileName: fileName, fileSize: fileSize
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(domain: "InAppPurchasesAPI", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"])
            }
            try await ScreenshotsAPI(client: client).uploadChunks(operations: ops, fileData: data)
            return try await confirmUpload(id: reserved.id, md5Checksum: md5)
        }
    }

    // MARK: - Promoted purchases (storefront promotion config)

    /// `promotedPurchases` toggles which IAPs are promoted in the App Store
    /// storefront. Apple permits up to 20 promoted IAPs per app at any time;
    /// each can be independently enabled/disabled and reordered.
    package struct PromotedPurchases: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PromotedPurchase: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let enabled: Bool?
                /// "APPROVED" | "REJECTED" | "PENDING_REVIEW".
                package let state: String?
                /// 0-based display order in the storefront promotional grid.
                package let visibleForDistribution: Bool?
            }
        }

        package func list(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PromotedPurchase> {
            let resp: PagedResponse<PromotedPurchase> = try await client.get(
                path: "apps/\(appID)/promotedPurchases",
                query: paginationQuery(limit: limit, cursor: cursor),
                as: PagedResponse<PromotedPurchase>.self
            )
            return wrapPage(resp)
        }

        package func get(id: String) async throws -> PromotedPurchase? {
            struct Resp: Decodable { let data: PromotedPurchase }
            do {
                let resp: Resp = try await client.get(
                    path: "promotedPurchases/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Toggles whether the IAP is promoted in the storefront.
        @discardableResult
        package func update(
            id: String,
            enabled: Bool?,
            visibleForDistribution: Bool? = nil
        ) async throws -> PromotedPurchase {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "promotedPurchases"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let enabled: Bool?
                    let visibleForDistribution: Bool?
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(enabled: enabled, visibleForDistribution: visibleForDistribution)
            ))
            struct Resp: Decodable { let data: PromotedPurchase }
            let resp: Resp = try await client.patch(
                path: "promotedPurchases/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - Promoted purchase images

    /// Artwork tied to a specific `promotedPurchases` record. Different from
    /// `PromotionalImages` which is the catalog of all promotional artwork
    /// across the app; this is the per-promotion attachment.
    package struct PromotedPurchaseImages: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PromotedImage: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int?
                package let sourceFileChecksum: String?
                package let uploadOperations: [ScreenshotsAPI.UploadOperation]?
                package let state: String?
                package let assetDeliveryState: AssetDeliveryState?

                package struct AssetDeliveryState: Codable, Sendable {
                    package let state: String?
                }
            }
        }

        package func list(
            promotedPurchaseID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PromotedImage> {
            let resp: PagedResponse<PromotedImage> = try await client.get(
                path: "promotedPurchases/\(promotedPurchaseID)/promotionImages",
                query: paginationQuery(limit: limit, cursor: cursor),
                as: PagedResponse<PromotedImage>.self
            )
            return wrapPage(resp)
        }

        package func get(id: String) async throws -> PromotedImage? {
            struct Resp: Decodable { let data: PromotedImage }
            do {
                let resp: Resp = try await client.get(
                    path: "promotedPurchaseImages/\(id)",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func reserve(
            promotedPurchaseID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> PromotedImage {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "promotedPurchaseImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileSize: Int
                    let fileName: String
                }
                struct Rels: Encodable {
                    struct PP: Encodable {
                        struct Data: Encodable { let type = "promotedPurchases"; let id: String }
                        let data: Data
                    }
                    let promotedPurchase: PP
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileSize: fileSize, fileName: fileName),
                relationships: .init(promotedPurchase: .init(data: .init(id: promotedPurchaseID)))
            ))
            struct Resp: Decodable { let data: PromotedImage }
            let resp: Resp = try await client.post(
                path: "promotedPurchaseImages",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func confirmUpload(id: String, md5Checksum: String) async throws -> PromotedImage {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "promotedPurchaseImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let uploaded: Bool
                    let sourceFileChecksum: String
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(uploaded: true, sourceFileChecksum: md5Checksum)
            ))
            struct Resp: Decodable { let data: PromotedImage }
            let resp: Resp = try await client.patch(
                path: "promotedPurchaseImages/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fileName: String?) async throws -> PromotedImage {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "promotedPurchaseImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let fileName: String?
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(fileName: fileName)))
            struct Resp: Decodable { let data: PromotedImage }
            let resp: Resp = try await client.patch(
                path: "promotedPurchaseImages/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "promotedPurchaseImages/\(id)")
        }

        /// Convenience: runs the full 3-step upload from a local file URL.
        @discardableResult
        package func upload(promotedPurchaseID: String, fileURL: URL) async throws -> PromotedImage {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let fileSize = data.count
            let md5 = ScreenshotsAPI.md5Hex(data: data)

            let reserved = try await reserve(
                promotedPurchaseID: promotedPurchaseID,
                fileName: fileName,
                fileSize: fileSize
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(domain: "InAppPurchasesAPI", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"])
            }
            try await ScreenshotsAPI(client: client).uploadChunks(operations: ops, fileData: data)
            return try await confirmUpload(id: reserved.id, md5Checksum: md5)
        }
    }
}
