import Foundation

/// App Store Connect endpoints covering the "Pricing and Availability"
/// screen of the ASC web UI — territory availability plus the app's price
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
    /// PATCH — ASC needs the full set, not a wildcard.
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
    /// unchanged availability. Single-page fetch — 200 covers Apple's full
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
            /// Customer-facing price in the territory's currency. For a free
            /// app this is "0" / "0.00".
            package let customerPrice: String?
            /// Developer's take in the territory's currency. Same "0" for free.
            package let proceeds: String?
        }
    }

    /// Lists app-specific price points for a single territory, sorted by
    /// price ascending. For a free-tier lookup we only need the cheapest
    /// record ("0"), so `limit=1&sort=priceTier` is plenty. The ID returned
    /// is what `appPriceSchedules` expects in its `manualPrices` relationship.
    package func listAppPricePoints(
        appID: String,
        territoryID: String,
        limit: Int = 5
    ) async throws -> [PricePoint] {
        struct Resp: Decodable { let data: [PricePoint] }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/appPricePoints",
            query: [
                "filter[territory]": territoryID,
                "sort": "priceTier",
                "limit": String(limit),
            ],
            as: Resp.self
        )
        return resp.data
    }

    /// Finds the "free" price point for the given territory — the one whose
    /// customerPrice equals "0" / "0.00". Returns nil if no free tier exists
    /// (paid-only apps, unusual territories).
    package func findFreePricePoint(
        appID: String,
        territoryID: String
    ) async throws -> PricePoint? {
        let points = try await listAppPricePoints(appID: appID, territoryID: territoryID)
        return points.first { p in
            let s = p.attributes?.customerPrice ?? ""
            return Double(s) == 0
        }
    }

    package struct PriceSchedule: Codable, Sendable {
        package let id: String
    }

    /// Creates a new price schedule for the app, setting the base territory
    /// and a single manual price point. Apple auto-computes equivalent prices
    /// for all other territories from the base + price point. Use this for
    /// both free and paid apps — for free, pass the free price point's ID.
    @discardableResult
    package func createPriceSchedule(
        appID: String,
        baseTerritoryID: String,
        pricePointID: String
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
            let data: Data
        }
        let body = Body(data: .init(
            relationships: .init(
                app: .init(data: .init(id: appID)),
                baseTerritory: .init(data: .init(id: baseTerritoryID)),
                manualPrices: .init(data: [.init(id: pricePointID)])
            )
        ))
        struct Resp: Decodable { let data: PriceSchedule }
        let resp: Resp = try await client.post(
            path: "appPriceSchedules",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// Returns true when the app already has a price schedule on file. Used
    /// as an idempotency guard — creating a second schedule blindly would
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
