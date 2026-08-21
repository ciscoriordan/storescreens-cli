import Foundation

/// App Store Connect endpoints covering the "Pricing and Availability"
/// screen of the ASC web UI - territory availability plus the app's price
/// schedule. Both must be set before a brand-new app can be submitted for
/// review, and neither carries over automatically across submissions, so
/// `storescreens submit` applies them when the config requests it.
///
/// Two different API versions are in play here because Apple split the
/// resources as they evolved:
///
///   - Territory availability lives at /v2: `POST /v2/appAvailabilities`
///     creates a fresh availability for the app. The read-side is
///     `GET /v1/apps/{id}/appAvailabilityV2`.
///   - Price schedules live at /v1: `POST /v1/appPriceSchedules` creates
///     a schedule pointing at app-specific price-point IDs that we have
///     to look up per territory via `/v1/apps/{id}/appPricePoints`.
package struct PricingAvailabilityAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Territories

    package struct Territory: Codable, Sendable {
        /// ISO 3166-1 alpha-3 code, e.g. "USA", "CAN", "GBR".
        package let id: String
    }

    /// Lists every territory App Store Connect supports. Used to resolve the
    /// "all territories" shorthand into an explicit list for the availability
    /// PATCH - ASC needs the full set, not a wildcard.
    package func listTerritories() async throws -> [Territory] {
        struct Resp: Decodable { let data: [Territory] }
        let resp: Resp = try await client.get(
            path: "territories",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    // MARK: - Availability

    package struct Availability: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let availableInNewTerritories: Bool?
        }
    }

    /// Fetches the app's current availability-v2 record. Returns nil when the
    /// app has never had availability set (brand-new apps, typically). Any
    /// other error propagates.
    package func getCurrentAvailability(appID: String) async throws -> Availability? {
        struct Resp: Decodable { let data: Availability }
        do {
            let resp: Resp = try await client.get(
                path: "apps/\(appID)/appAvailabilityV2",
                as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Creates a new app availability, setting both the explicit territory
    /// list and the "enroll new territories automatically" toggle.
    ///
    /// Apple's v2 availability endpoint is create-only: every call is a
    /// fresh record that replaces the previous one. So a no-op diff has to
    /// live in the caller (compare current vs desired before calling).
    @discardableResult
    package func createAvailability(
        appID: String,
        territoryIDs: [String],
        availableInNewTerritories: Bool
    ) async throws -> Availability {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appAvailabilities"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable { let availableInNewTerritories: Bool }
            struct Rels: Encodable {
                struct AppRel: Encodable {
                    struct D: Encodable { let type = "apps"; let id: String }
                    let data: D
                }
                struct TerRel: Encodable {
                    struct D: Encodable { let type = "territories"; let id: String }
                    let data: [D]
                }
                let app: AppRel
                let availableTerritories: TerRel
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(availableInNewTerritories: availableInNewTerritories),
            relationships: .init(
                app: .init(data: .init(id: appID)),
                availableTerritories: .init(data: territoryIDs.sorted().map { .init(id: $0) })
            )
        ))
        struct Resp: Decodable { let data: Availability }
        let resp: Resp = try await client.post(
            path: "v2/appAvailabilities",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// Returns the set of territory IDs that are currently available for the
    /// app. Used to diff against the desired list so we don't re-POST an
    /// unchanged availability. Single-page fetch - 200 covers Apple's full
    /// territory count comfortably.
    package func listAvailableTerritories(availabilityID: String) async throws -> Set<String> {
        struct Ref: Decodable { let id: String }
        struct Resp: Decodable { let data: [Ref] }
        let resp: Resp = try await client.get(
            path: "appAvailabilities/\(availabilityID)/availableTerritories",
            query: ["limit": "200"],
            as: Resp.self
        )
        return Set(resp.data.map(\.id))
    }

    // MARK: - Pricing

    package struct PricePoint: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Customer-facing price in the territory's currency, as Apple
            /// formats it - the free tier comes back as "0.0", not "0.00", so
            /// compare these numerically rather than by string.
            package let customerPrice: String?
            /// Developer's take in the territory's currency. Same "0" for free.
            package let proceeds: String?
        }
    }

    /// Lists app-specific price points for a single territory, cheapest
    /// first. For a free-tier lookup we only need the cheapest record ("0"),
    /// so the default `limit=5` is plenty. The ID returned is what
    /// `appPriceSchedules` expects in its `manualPrices` relationship.
    ///
    /// Apple rejects `sort` on this relationship endpoint with a 400
    /// (PARAMETER_ERROR.ILLEGAL) even though it accepts it on other
    /// price-point collections, so the ladder is ordered client-side instead.
    /// Apple already hands it back ascending by tier; re-sorting keeps the
    /// "cheapest first" contract from resting on undocumented ordering.
    ///
    /// For resolving an arbitrary amount to the nearest tier, use the paged
    /// `findPricePoint(appID:territoryID:targetPrice:)` instead - a single
    /// territory's price ladder can run to hundreds of tiers.
    package func listAppPricePoints(
        appID: String,
        territoryID: String,
        limit: Int = 5,
        cursor: String? = nil
    ) async throws -> (points: [PricePoint], nextCursor: String?) {
        struct Links: Decodable { let next: String? }
        struct Resp: Decodable { let data: [PricePoint]; let links: Links? }
        var query = [
            "filter[territory]": territoryID,
            "limit": String(limit),
        ]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/appPricePoints",
            query: query,
            as: Resp.self
        )
        let next = resp.links?.next.flatMap {
            URLComponents(string: $0)?.queryItems?.first { $0.name == "cursor" }?.value
        }
        return (Self.sortedByPrice(resp.data), next)
    }

    /// Orders one page of price points by customer price ascending. Pure (no
    /// network) so the "cheapest first" ordering can be unit-tested directly.
    /// Tiers whose customerPrice will not parse sort last in their original
    /// order rather than being dropped, and equal prices keep their incoming
    /// order so the ladder stays deterministic.
    package static func sortedByPrice(_ points: [PricePoint]) -> [PricePoint] {
        points.enumerated().sorted { l, r in
            let lp = Double(l.element.attributes?.customerPrice ?? "") ?? .greatestFiniteMagnitude
            let rp = Double(r.element.attributes?.customerPrice ?? "") ?? .greatestFiniteMagnitude
            return lp == rp ? l.offset < r.offset : lp < rp
        }.map(\.element)
    }

    /// The outcome of resolving a requested amount (in a territory's local
    /// currency) to one of Apple's fixed price points. `isExact` is true when
    /// a tier matched the request to the cent; otherwise `point` is the
    /// nearest tier and `actual` differs from `requested`.
    package struct ResolvedPrice: Sendable {
        package let point: PricePoint
        package let requested: Double
        package let actual: Double
        package var isExact: Bool { abs(actual - requested) < 0.005 }
    }

    /// Picks the price point whose customerPrice is closest to `target`. Pure
    /// (no network) so the nearest-tier selection can be unit-tested directly.
    /// Earlier ties win, which - given an ascending-by-tier list - means the
    /// lower of two equidistant prices. Returns nil when no point has a
    /// parseable customerPrice.
    package static func nearestPricePoint(
        _ points: [PricePoint],
        to target: Double
    ) -> (point: PricePoint, value: Double)? {
        var best: (PricePoint, Double)?
        var bestDiff = Double.greatestFiniteMagnitude
        for p in points {
            guard let s = p.attributes?.customerPrice, let value = Double(s) else { continue }
            let diff = abs(value - target)
            if diff < bestDiff {
                bestDiff = diff
                best = (p, value)
            }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    /// Resolves a requested price (in the territory's local currency, e.g.
    /// "4.99" for USA) to the nearest valid App Store price point for that
    /// territory. Apple's price points are a fixed ladder per territory, so a
    /// requested amount that isn't on the ladder snaps to the closest tier.
    ///
    /// Pages `appPricePoints` ascending by tier and stops early once a page's
    /// top tier passes the requested amount (the ladder is monotonic, so the
    /// bracketing tiers are already collected), then picks the nearest from
    /// everything fetched. Returns nil only when the territory has no price
    /// points at all.
    package func findPricePoint(
        appID: String,
        territoryID: String,
        targetPrice: Double
    ) async throws -> ResolvedPrice? {
        var collected: [PricePoint] = []
        var cursor: String? = nil

        repeat {
            let (points, next) = try await listAppPricePoints(
                appID: appID, territoryID: territoryID, limit: 200, cursor: cursor
            )
            if points.isEmpty { break }
            collected.append(contentsOf: points)
            // Ladder is ascending by tier; once a page's top tier reaches the
            // target, both bracketing tiers have been collected - stop paging.
            let pageMax = points.compactMap { $0.attributes?.customerPrice }.compactMap(Double.init).max()
            if let pageMax, pageMax >= targetPrice { break }
            cursor = next
        } while cursor != nil

        guard let (point, value) = Self.nearestPricePoint(collected, to: targetPrice) else { return nil }
        return ResolvedPrice(point: point, requested: targetPrice, actual: value)
    }

    /// One manual (explicitly set) price entry in a schedule: a territory plus
    /// the app-specific price-point ID that fixes its price.
    package struct ManualPrice: Sendable, Equatable {
        package let territoryID: String
        package let pricePointID: String

        package init(territoryID: String, pricePointID: String) {
            self.territoryID = territoryID
            self.pricePointID = pricePointID
        }
    }

    package struct PriceSchedule: Codable, Sendable {
        package let id: String
    }

    /// Creates (replaces) the app's price schedule from an explicit list of
    /// manual per-territory prices. Apple auto-computes equivalent prices for
    /// every territory NOT in `manualPrices`, using `baseTerritoryID` as the
    /// anchor - so the base territory's price should always be present in the
    /// list. Use one entry for a uniform price (free or single paid tier), or
    /// base + overrides for true per-territory pricing.
    ///
    /// The request mirrors Apple's `iapPriceSchedules` shape: each manual
    /// price is a synthetic `appPrices` object in the `included` array that
    /// links a territory to an `appPricePoints` id, and the schedule's
    /// `manualPrices` relationship references those synthetic ids.
    @discardableResult
    package func createPriceSchedule(
        appID: String,
        baseTerritoryID: String,
        manualPrices: [ManualPrice]
    ) async throws -> PriceSchedule {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appPriceSchedules"
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct AppRel: Encodable {
                    struct D: Encodable { let type = "apps"; let id: String }
                    let data: D
                }
                struct TerritoryRel: Encodable {
                    struct D: Encodable { let type = "territories"; let id: String }
                    let data: D
                }
                struct PricesRel: Encodable {
                    struct D: Encodable { let type = "appPrices"; let id: String }
                    let data: [D]
                }
                let app: AppRel
                let baseTerritory: TerritoryRel
                let manualPrices: PricesRel
            }
            struct Included: Encodable {
                let type = "appPrices"
                let id: String
                let relationships: Rels

                struct Rels: Encodable {
                    struct Ter: Encodable {
                        struct D: Encodable { let type = "territories"; let id: String }
                        let data: D
                    }
                    struct Point: Encodable {
                        struct D: Encodable { let type = "appPricePoints"; let id: String }
                        let data: D
                    }
                    let territory: Ter
                    let appPricePoint: Point
                }
            }
            let data: Data
            let included: [Included]
        }

        // Each manual price needs a synthetic id that the relationships block
        // cross-references into the `included` block. Sequential "price-N"
        // strings match Apple's own examples.
        let synthetic = manualPrices.enumerated().map { idx, p in
            (id: "price-\(idx)", price: p)
        }
        let body = Body(
            data: .init(
                relationships: .init(
                    app: .init(data: .init(id: appID)),
                    baseTerritory: .init(data: .init(id: baseTerritoryID)),
                    manualPrices: .init(data: synthetic.map { .init(id: $0.id) })
                )
            ),
            included: synthetic.map { entry in
                Body.Included(
                    id: entry.id,
                    relationships: .init(
                        territory: .init(data: .init(id: entry.price.territoryID)),
                        appPricePoint: .init(data: .init(id: entry.price.pricePointID))
                    )
                )
            }
        )
        struct Resp: Decodable { let data: PriceSchedule }
        let resp: Resp = try await client.post(
            path: "appPriceSchedules",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    // MARK: - Pricing plan (resolve amounts -> price points)

    package enum PricingError: Error, CustomStringConvertible {
        /// The territory returned no price points at all (unusual; usually a
        /// bad territory code or an app not yet available there).
        case noPricePoints(territory: String)

        package var description: String {
            switch self {
            case .noPricePoints(let t):
                return "no App Store price points available for territory \(t)"
            }
        }
    }

    /// A fully resolved pricing intent: the manual prices to send to
    /// `createPriceSchedule`, plus a per-territory record of what each
    /// requested amount snapped to (for reporting "requested 5.00, set 4.99").
    package struct PricingPlan: Sendable {
        package let baseTerritory: String
        package let manualPrices: [ManualPrice]
        package let resolutions: [Resolution]

        package struct Resolution: Sendable, Codable {
            package let territory: String
            package let requested: Double
            package let actual: Double
            package let isExact: Bool
            package let pricePointID: String
        }
    }

    /// Resolves a desired base price (in the base territory's local currency)
    /// plus optional per-territory overrides into concrete manual price
    /// points. The base territory is always included as a manual price - it is
    /// the anchor Apple uses to equivalence every unlisted territory. Pass
    /// `basePrice: 0` for a free app (the territory's "0" tier resolves
    /// exactly). Each amount snaps to the nearest valid App Store tier.
    package func resolvePricing(
        appID: String,
        baseTerritory: String,
        basePrice: Double,
        territoryPrices: [String: Double] = [:]
    ) async throws -> PricingPlan {
        var manual: [ManualPrice] = []
        var resolutions: [PricingPlan.Resolution] = []

        func resolve(_ territory: String, _ amount: Double) async throws {
            guard let r = try await findPricePoint(
                appID: appID, territoryID: territory, targetPrice: amount
            ) else {
                throw PricingError.noPricePoints(territory: territory)
            }
            manual.append(ManualPrice(territoryID: territory, pricePointID: r.point.id))
            resolutions.append(.init(
                territory: territory,
                requested: amount,
                actual: r.actual,
                isExact: r.isExact,
                pricePointID: r.point.id
            ))
        }

        // Base territory first - it anchors equivalencing for the rest.
        try await resolve(baseTerritory, basePrice)
        // Overrides, sorted for deterministic output; skip a duplicate base.
        for (territory, amount) in territoryPrices.sorted(by: { $0.key < $1.key })
        where territory != baseTerritory {
            try await resolve(territory, amount)
        }

        return PricingPlan(
            baseTerritory: baseTerritory,
            manualPrices: manual,
            resolutions: resolutions
        )
    }

    /// The current price schedule as a flat, human-readable summary: the base
    /// territory plus every manually set per-territory price. Territories not
    /// listed get Apple's auto-computed equivalent of the base price.
    package struct ScheduleDetails: Codable, Sendable {
        package let scheduleID: String
        package let baseTerritory: String?
        package let manualPrices: [TerritoryPrice]
    }

    package struct TerritoryPrice: Codable, Sendable {
        package let territory: String
        package let customerPrice: String?
        package let proceeds: String?
        package let pricePointID: String
    }

    /// Reads the app's current price schedule and expands its manual prices
    /// into a territory -> price table. Returns nil when the app has no
    /// schedule yet (brand-new apps). One call for the schedule (to get the
    /// base territory + schedule id), one for the manual-price list with the
    /// price points and territories sideloaded.
    package func getPriceScheduleDetails(appID: String) async throws -> ScheduleDetails? {
        // Schedule head: id + base territory.
        struct ScheduleResp: Decodable {
            struct Data: Decodable {
                let id: String
                let relationships: Rels?
                struct Rels: Decodable {
                    struct Ref: Decodable { struct D: Decodable { let id: String }; let data: D? }
                    let baseTerritory: Ref?
                }
            }
            let data: Data
        }
        let schedule: ScheduleResp
        do {
            schedule = try await client.get(
                path: "apps/\(appID)/appPriceSchedule",
                query: ["include": "baseTerritory"],
                as: ScheduleResp.self
            )
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
        let scheduleID = schedule.data.id
        let baseTerritory = schedule.data.relationships?.baseTerritory?.data?.id

        // Manual prices with their price points + territories sideloaded.
        struct PricesResp: Decodable {
            struct Price: Decodable {
                let id: String
                let relationships: Rels?
                struct Rels: Decodable {
                    struct Ref: Decodable { struct D: Decodable { let type: String; let id: String }; let data: D? }
                    let territory: Ref?
                    let appPricePoint: Ref?
                }
            }
            struct IncludedPoint: Decodable {
                let type: String
                let id: String
                let attributes: Attrs?
                struct Attrs: Decodable { let customerPrice: String?; let proceeds: String? }
            }
            let data: [Price]
            let included: [IncludedPoint]?
        }
        let prices: PricesResp = try await client.get(
            path: "appPriceSchedules/\(scheduleID)/manualPrices",
            query: ["include": "appPricePoint,territory", "limit": "200"],
            as: PricesResp.self
        )

        // Map appPricePoints id -> price attributes from the sideload.
        var pointAttrs: [String: PricesResp.IncludedPoint.Attrs] = [:]
        for inc in prices.included ?? [] where inc.type == "appPricePoints" {
            if let a = inc.attributes { pointAttrs[inc.id] = a }
        }

        let table: [TerritoryPrice] = prices.data.compactMap { price in
            let territory = price.relationships?.territory?.data?.id
            let pointID = price.relationships?.appPricePoint?.data?.id
            guard let territory, let pointID else { return nil }
            let attrs = pointAttrs[pointID]
            return TerritoryPrice(
                territory: territory,
                customerPrice: attrs?.customerPrice,
                proceeds: attrs?.proceeds,
                pricePointID: pointID
            )
        }.sorted { $0.territory < $1.territory }

        return ScheduleDetails(
            scheduleID: scheduleID,
            baseTerritory: baseTerritory,
            manualPrices: table
        )
    }

    /// Returns true when the app already has a price schedule on file. Used
    /// as an idempotency guard - creating a second schedule blindly would
    /// replace the first, which is destructive if someone already set
    /// something by hand in the ASC web UI.
    package func hasExistingPriceSchedule(appID: String) async throws -> Bool {
        struct Ref: Decodable { let id: String? }
        struct Resp: Decodable { let data: Ref? }
        do {
            let resp: Resp = try await client.get(
                path: "apps/\(appID)/appPriceSchedule",
                as: Resp.self
            )
            return resp.data?.id != nil
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return false
        }
    }
}
