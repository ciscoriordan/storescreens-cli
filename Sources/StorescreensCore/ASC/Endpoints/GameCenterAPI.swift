import Foundation
import CryptoKit

// MARK: - Shared upload helper (3-phase for Game Center image assets)

/// Reservation + chunk PUT + checksum-confirm upload, reused by every Game
/// Center image resource (achievement / leaderboard / leaderboard-set). The
/// shape mirrors `MarketingAssetUpload`:
///   1. POST creates the resource carrying `fileName` + `fileSize`. Apple
///      returns the record with `uploadOperations` (pre-signed PUT URLs and
///      header instructions per chunk).
///   2. PUT each chunk to the URL Apple handed back, slicing by
///      offset+length.
///   3. PATCH `uploaded: true` + `sourceFileChecksum` (hex MD5) to finalize.
///
/// Callers compose this with a resource-typed reservation POST that returns
/// the `uploadOperations` array, then call `uploadChunks` plus the
/// per-resource `confirmUpload` PATCH.
package enum GameCenterAssetUpload {

    /// Per-chunk upload instruction returned on the reservation POST.
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

    /// Phase 2 — push every chunk to its pre-signed URL.
    package static func uploadChunks(
        client: ASCClient,
        operations: [UploadOperation],
        fileData: Data,
        progress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws {
        for (index, op) in operations.enumerated() {
            guard let url = URL(string: op.url) else {
                throw NSError(
                    domain: "GameCenterAssetUpload",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid uploadOperation URL"]
                )
            }
            let end = op.offset + op.length
            guard end <= fileData.count else {
                throw NSError(
                    domain: "GameCenterAssetUpload",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "chunk offset+length exceeds file"]
                )
            }
            let chunk = fileData.subdata(in: op.offset..<end)
            var headers: [String: String] = [:]
            for h in op.requestHeaders { headers[h.name] = h.value }
            try await client.putBinary(absoluteURL: url, headers: headers, body: chunk)
            progress?(index + 1, operations.count)
        }
    }

    /// Hex-encoded MD5 of the file bytes, matching Apple's
    /// `sourceFileChecksum` shape.
    package static func md5Hex(data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - GameCenterAPI master struct

/// App Store Connect endpoints for Game Center. Wraps the JSON:API resources
/// Apple groups under "Game Center" in the docs:
///
///   - gameCenterDetails (per-app parent record)
///   - gameCenterAppVersions (per-detail versions for staging releases)
///   - gameCenterGroups + gameCenterGroupLocalizations (cross-app groups)
///   - gameCenterAchievements + gameCenterAchievementLocalizations
///   - gameCenterAchievementImages (3-phase asset upload)
///   - gameCenterAchievementReleases (per app-version staging)
///   - gameCenterLeaderboards + gameCenterLeaderboardLocalizations
///   - gameCenterLeaderboardImages (3-phase asset upload)
///   - gameCenterLeaderboardReleases
///   - gameCenterLeaderboardSets + gameCenterLeaderboardSetLocalizations
///   - gameCenterLeaderboardSetImages (3-phase asset upload)
///   - gameCenterLeaderboardSetMembers + member localizations
///     (with reorderLeaderboards relationship op)
///   - gameCenterLeaderboardSetReleases
///   - gameCenterMatchmakingQueues
///   - gameCenterMatchmakingRuleSets
///   - gameCenterMatchmakingRules
///   - gameCenterMatchmakingTeamConfigurations
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/game-center
///
/// Pagination convention: every list endpoint accepts an optional `limit` and
/// `cursor` and returns `(items, nextCursor)`. The cursor is Apple's opaque
/// `links.next` continuation token; pass it back unchanged on the next call
/// to get the next page. When `nextCursor` is nil, the caller has reached the
/// end of the list. 404 on `get` returns nil. 409 conflicts surface via
/// `ASCClient.APIError.isAlreadySetConflict`.
package struct GameCenterAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // Nested namespaces — each maps to one Apple resource family.
    package var details: Details { Details(client: client) }
    package var appVersions: AppVersions { AppVersions(client: client) }
    package var groups: Groups { Groups(client: client) }
    package var groupLocalizations: GroupLocalizations { GroupLocalizations(client: client) }
    package var achievements: Achievements { Achievements(client: client) }
    package var achievementLocalizations: AchievementLocalizations { AchievementLocalizations(client: client) }
    package var achievementImages: AchievementImages { AchievementImages(client: client) }
    package var achievementReleases: AchievementReleases { AchievementReleases(client: client) }
    package var leaderboards: Leaderboards { Leaderboards(client: client) }
    package var leaderboardLocalizations: LeaderboardLocalizations { LeaderboardLocalizations(client: client) }
    package var leaderboardImages: LeaderboardImages { LeaderboardImages(client: client) }
    package var leaderboardReleases: LeaderboardReleases { LeaderboardReleases(client: client) }
    package var leaderboardSets: LeaderboardSets { LeaderboardSets(client: client) }
    package var leaderboardSetLocalizations: LeaderboardSetLocalizations { LeaderboardSetLocalizations(client: client) }
    package var leaderboardSetImages: LeaderboardSetImages { LeaderboardSetImages(client: client) }
    package var leaderboardSetMembers: LeaderboardSetMembers { LeaderboardSetMembers(client: client) }
    package var leaderboardSetMemberLocalizations: LeaderboardSetMemberLocalizations { LeaderboardSetMemberLocalizations(client: client) }
    package var leaderboardSetReleases: LeaderboardSetReleases { LeaderboardSetReleases(client: client) }
    package var matchmakingQueues: MatchmakingQueues { MatchmakingQueues(client: client) }
    package var matchmakingRuleSets: MatchmakingRuleSets { MatchmakingRuleSets(client: client) }
    package var matchmakingRules: MatchmakingRules { MatchmakingRules(client: client) }
    package var matchmakingTeamConfigurations: MatchmakingTeamConfigurations { MatchmakingTeamConfigurations(client: client) }

    // MARK: - Shared paged response shape

    /// A page of results plus the opaque cursor for the next page. Apple
    /// returns the next URL with a base64-style `cursor=` query parameter; we
    /// extract the cursor value so callers hand it back without parsing.
    package struct Page<Item: Codable & Sendable>: Sendable {
        package let items: [Item]
        package let nextCursor: String?
    }

    fileprivate struct PageEnvelope<Item: Codable>: Decodable {
        struct Links: Decodable { let next: String? }
        let data: [Item]
        let links: Links?
    }

    fileprivate static func extractCursor(from link: String?) -> String? {
        guard let link, !link.isEmpty,
              let comps = URLComponents(string: link)
        else { return nil }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }

    fileprivate static func listQuery(
        limit: Int,
        cursor: String?,
        extras: [String: String] = [:]
    ) -> [String: String] {
        var q = extras
        q["limit"] = String(limit)
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return q
    }

    fileprivate static func wrapPage<Item: Codable & Sendable>(_ envelope: PageEnvelope<Item>) -> Page<Item> {
        Page(items: envelope.data, nextCursor: extractCursor(from: envelope.links?.next))
    }

    // MARK: - gameCenterDetails

    /// The per-app Game Center detail record. Apple materializes one per app
    /// once Game Center is enabled; you GET it via the relationship from
    /// `apps/{id}/gameCenterDetail` and PATCH attributes like
    /// `arcadeEnabled` or `challengeEnabled`.
    package struct Details: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Detail: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let arcadeEnabled: Bool?
                package let challengeEnabled: Bool?
            }
        }

        /// GET the gameCenterDetail for an app via the
        /// `apps/{appID}/gameCenterDetail` relationship. Returns nil when
        /// Apple has not materialized the record yet (Game Center not enabled).
        package func getForApp(appID: String) async throws -> Detail? {
            struct Resp: Decodable { let data: Detail? }
            do {
                let resp: Resp = try await client.get(
                    path: "apps/\(appID)/gameCenterDetail",
                    as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// GET a gameCenterDetail by its direct id.
        package func get(id: String) async throws -> Detail? {
            struct Resp: Decodable { let data: Detail }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterDetails/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// PATCH the gameCenterDetail attributes. Nil fields stay untouched.
        @discardableResult
        package func update(
            id: String,
            arcadeEnabled: Bool? = nil,
            challengeEnabled: Bool? = nil
        ) async throws -> Detail {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterDetails"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    var arcadeEnabled: Bool?
                    var challengeEnabled: Bool?
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(
                    arcadeEnabled: arcadeEnabled,
                    challengeEnabled: challengeEnabled
                )
            ))
            struct Resp: Decodable { let data: Detail }
            let resp: Resp = try await client.patch(
                path: "gameCenterDetails/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - gameCenterAppVersions

    /// Per-app-version staging record. Apple uses these to gate which
    /// achievements / leaderboards are visible in a given app version, and to
    /// stage release configurations across versions of the same app. Each
    /// detail can have many app versions.
    package struct AppVersions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct AppVersion: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let live: Bool?
            }
        }

        package func list(
            detailID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<AppVersion> {
            let resp: PageEnvelope<AppVersion> = try await client.get(
                path: "gameCenterDetails/\(detailID)/gameCenterAppVersions",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<AppVersion>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> AppVersion? {
            struct Resp: Decodable { let data: AppVersion }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterAppVersions/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Creates a new gameCenterAppVersion attached to a detail record.
        /// Optionally relates it to a concrete appStoreVersion id for staging.
        @discardableResult
        package func create(
            detailID: String,
            appStoreVersionID: String? = nil
        ) async throws -> AppVersion {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAppVersions"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct DetailRel: Encodable {
                        struct D: Encodable { let type = "gameCenterDetails"; let id: String }
                        let data: D
                    }
                    struct ASVRel: Encodable {
                        struct D: Encodable { let type = "appStoreVersions"; let id: String }
                        let data: D
                    }
                    let gameCenterDetail: DetailRel
                    var appStoreVersion: ASVRel?
                }
                let data: Data
            }
            let body = Body(data: .init(relationships: .init(
                gameCenterDetail: .init(data: .init(id: detailID)),
                appStoreVersion: appStoreVersionID.map { .init(data: .init(id: $0)) }
            )))
            struct Resp: Decodable { let data: AppVersion }
            let resp: Resp = try await client.post(
                path: "gameCenterAppVersions", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, live: Bool? = nil) async throws -> AppVersion {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAppVersions"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var live: Bool? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(live: live)))
            struct Resp: Decodable { let data: AppVersion }
            let resp: Resp = try await client.patch(
                path: "gameCenterAppVersions/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterAppVersions/\(id)")
        }
    }

    // MARK: - gameCenterGroups

    /// Cross-app Game Center groups. A group lets one team share achievements
    /// or leaderboards across multiple apps. The relationship to apps is
    /// many-to-many.
    package struct Groups: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Group: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let groupId: String?
            }
        }

        package func list(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Group> {
            let resp: PageEnvelope<Group> = try await client.get(
                path: "gameCenterGroups",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Group>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Group? {
            struct Resp: Decodable { let data: Group }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterGroups/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            referenceName: String,
            groupID: String
        ) async throws -> Group {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterGroups"
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    let referenceName: String
                    let groupId: String
                }
                let data: Data
            }
            let body = Body(data: .init(attributes: .init(
                referenceName: referenceName, groupId: groupID
            )))
            struct Resp: Decodable { let data: Group }
            let resp: Resp = try await client.post(
                path: "gameCenterGroups", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            referenceName: String? = nil
        ) async throws -> Group {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterGroups"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var referenceName: String? }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(referenceName: referenceName)
            ))
            struct Resp: Decodable { let data: Group }
            let resp: Resp = try await client.patch(
                path: "gameCenterGroups/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterGroups/\(id)")
        }

        /// Attaches one or more apps to this group via the
        /// `gameCenterGroups/{id}/relationships/gameCenterDetails` endpoint.
        package func addDetails(
            groupID: String,
            detailIDs: [String]
        ) async throws {
            struct Body: Encodable {
                struct D: Encodable { let type = "gameCenterDetails"; let id: String }
                let data: [D]
            }
            let body = Body(data: detailIDs.map { .init(id: $0) })
            _ = try await client.post(
                path: "gameCenterGroups/\(groupID)/relationships/gameCenterDetails",
                body: body, as: ASCClient.EmptyBody.self
            )
        }
    }

    // MARK: - gameCenterGroupLocalizations

    /// Per-locale localized name of a Game Center group, shown in the Game
    /// Center UI on the device. One record per locale per group.
    package struct GroupLocalizations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Localization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let locale: String?
                package let name: String?
            }
        }

        package func list(
            groupID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Localization> {
            let resp: PageEnvelope<Localization> = try await client.get(
                path: "gameCenterGroups/\(groupID)/gameCenterGroupLocalizations",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Localization>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Localization? {
            struct Resp: Decodable { let data: Localization }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterGroupLocalizations/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            groupID: String,
            locale: String,
            name: String
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterGroupLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    let name: String
                }
                struct Rels: Encodable {
                    struct G: Encodable {
                        struct D: Encodable { let type = "gameCenterGroups"; let id: String }
                        let data: D
                    }
                    let gameCenterGroup: G
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(locale: locale, name: name),
                relationships: .init(gameCenterGroup: .init(data: .init(id: groupID)))
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.post(
                path: "gameCenterGroupLocalizations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(
            id: String,
            name: String? = nil
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterGroupLocalizations"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var name: String? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(name: name)))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.patch(
                path: "gameCenterGroupLocalizations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterGroupLocalizations/\(id)")
        }
    }

    // MARK: - gameCenterAchievements

    /// Game Center achievements. Each app or group can host many. An
    /// achievement is identified by a `vendorIdentifier` chosen by the
    /// developer (e.g. "first_blood"), carries a point value, and can be
    /// hidden until earned.
    package struct Achievements: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Achievement: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let vendorIdentifier: String?
                package let points: Int?
                package let showBeforeEarned: Bool?
                package let repeatable: Bool?
                package let archived: Bool?
            }
        }

        /// Fields accepted on create/update. Nil fields are omitted from the
        /// wire body so existing values stay untouched on a PATCH.
        package struct Fields: Sendable, Equatable {
            package var referenceName: String?
            package var vendorIdentifier: String?
            package var points: Int?
            package var showBeforeEarned: Bool?
            package var repeatable: Bool?

            package init(
                referenceName: String? = nil,
                vendorIdentifier: String? = nil,
                points: Int? = nil,
                showBeforeEarned: Bool? = nil,
                repeatable: Bool? = nil
            ) {
                self.referenceName = referenceName
                self.vendorIdentifier = vendorIdentifier
                self.points = points
                self.showBeforeEarned = showBeforeEarned
                self.repeatable = repeatable
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var referenceName: String?
            var vendorIdentifier: String?
            var points: Int?
            var showBeforeEarned: Bool?
            var repeatable: Bool?

            init(fields: Fields) {
                self.referenceName = fields.referenceName
                self.vendorIdentifier = fields.vendorIdentifier
                self.points = fields.points
                self.showBeforeEarned = fields.showBeforeEarned
                self.repeatable = fields.repeatable
            }
        }

        /// Lists achievements for an app via the parent relationship.
        package func listForApp(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Achievement> {
            let resp: PageEnvelope<Achievement> = try await client.get(
                path: "apps/\(appID)/gameCenterAchievements",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Achievement>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        /// Lists achievements for a gameCenterDetail directly.
        package func listForDetail(
            detailID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Achievement> {
            let resp: PageEnvelope<Achievement> = try await client.get(
                path: "gameCenterDetails/\(detailID)/gameCenterAchievements",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Achievement>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        /// Lists achievements that belong to a cross-app group.
        package func listForGroup(
            groupID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Achievement> {
            let resp: PageEnvelope<Achievement> = try await client.get(
                path: "gameCenterGroups/\(groupID)/gameCenterAchievements",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Achievement>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Achievement? {
            struct Resp: Decodable { let data: Achievement }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterAchievements/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Creates an achievement scoped to a single gameCenterDetail. Pass
        /// `groupID` instead of `detailID` to create one shared across a
        /// cross-app group.
        @discardableResult
        package func create(
            detailID: String? = nil,
            groupID: String? = nil,
            fields: Fields
        ) async throws -> Achievement {
            precondition(detailID != nil || groupID != nil, "must supply detailID or groupID")
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievements"
                    let attributes: AttrsPatch
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct DetailRel: Encodable {
                        struct D: Encodable { let type = "gameCenterDetails"; let id: String }
                        let data: D
                    }
                    struct GroupRel: Encodable {
                        struct D: Encodable { let type = "gameCenterGroups"; let id: String }
                        let data: D
                    }
                    var gameCenterDetail: DetailRel?
                    var gameCenterGroup: GroupRel?
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: AttrsPatch(fields: fields),
                relationships: .init(
                    gameCenterDetail: detailID.map { .init(data: .init(id: $0)) },
                    gameCenterGroup: groupID.map { .init(data: .init(id: $0)) }
                )
            ))
            struct Resp: Decodable { let data: Achievement }
            let resp: Resp = try await client.post(
                path: "gameCenterAchievements", body: body, as: Resp.self
            )
            return resp.data
        }

        /// PATCH the achievement with any non-nil fields.
        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Achievement {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievements"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Achievement }
            let resp: Resp = try await client.patch(
                path: "gameCenterAchievements/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Toggles `archived` on an achievement. Archived achievements are
        /// hidden from the Game Center catalog but remain on testers'
        /// accounts. This is a special operation Apple exposes only as a
        /// PATCH on the `archived` attribute, not as a separate endpoint.
        @discardableResult
        package func archive(id: String, archived: Bool = true) async throws -> Achievement {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievements"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { let archived: Bool }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(archived: archived)))
            struct Resp: Decodable { let data: Achievement }
            let resp: Resp = try await client.patch(
                path: "gameCenterAchievements/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterAchievements/\(id)")
        }
    }

    // MARK: - gameCenterAchievementLocalizations

    /// Per-locale title + description for an achievement. Required for at
    /// least one locale before submission.
    package struct AchievementLocalizations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Localization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let locale: String?
                package let name: String?
                package let beforeEarnedDescription: String?
                package let afterEarnedDescription: String?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var name: String?
            package var beforeEarnedDescription: String?
            package var afterEarnedDescription: String?

            package init(
                name: String? = nil,
                beforeEarnedDescription: String? = nil,
                afterEarnedDescription: String? = nil
            ) {
                self.name = name
                self.beforeEarnedDescription = beforeEarnedDescription
                self.afterEarnedDescription = afterEarnedDescription
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var name: String?
            var beforeEarnedDescription: String?
            var afterEarnedDescription: String?

            init(fields: Fields) {
                self.name = fields.name
                self.beforeEarnedDescription = fields.beforeEarnedDescription
                self.afterEarnedDescription = fields.afterEarnedDescription
            }
        }

        package func list(
            achievementID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Localization> {
            let resp: PageEnvelope<Localization> = try await client.get(
                path: "gameCenterAchievements/\(achievementID)/localizations",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Localization>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Localization? {
            struct Resp: Decodable { let data: Localization }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterAchievementLocalizations/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            achievementID: String,
            locale: String,
            fields: Fields
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievementLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    var name: String?
                    var beforeEarnedDescription: String?
                    var afterEarnedDescription: String?
                }
                struct Rels: Encodable {
                    struct A: Encodable {
                        struct D: Encodable { let type = "gameCenterAchievements"; let id: String }
                        let data: D
                    }
                    let gameCenterAchievement: A
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    locale: locale,
                    name: fields.name,
                    beforeEarnedDescription: fields.beforeEarnedDescription,
                    afterEarnedDescription: fields.afterEarnedDescription
                ),
                relationships: .init(
                    gameCenterAchievement: .init(data: .init(id: achievementID))
                )
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.post(
                path: "gameCenterAchievementLocalizations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievementLocalizations"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.patch(
                path: "gameCenterAchievementLocalizations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterAchievementLocalizations/\(id)")
        }
    }

    // MARK: - gameCenterAchievementImages

    /// Per-localization achievement image (the icon shown next to the title
    /// in Game Center). Uploaded via the 3-phase reservation flow defined at
    /// the top of this file.
    package struct AchievementImages: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Image: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int?
                package let imageAsset: ImageAsset?
                package let sourceFileChecksum: String?
                package let uploadOperations: [GameCenterAssetUpload.UploadOperation]?
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
            localizationID: String,
            limit: Int = 50,
            cursor: String? = nil
        ) async throws -> Page<Image> {
            let resp: PageEnvelope<Image> = try await client.get(
                path: "gameCenterAchievementLocalizations/\(localizationID)/gameCenterAchievementImage",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Image>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Image? {
            struct Resp: Decodable { let data: Image }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterAchievementImages/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Phase 1 — reserve. Returns the image record with
        /// `uploadOperations` populated.
        @discardableResult
        package func reserve(
            localizationID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievementImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int
                }
                struct Rels: Encodable {
                    struct L: Encodable {
                        struct D: Encodable { let type = "gameCenterAchievementLocalizations"; let id: String }
                        let data: D
                    }
                    let gameCenterAchievementLocalization: L
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(gameCenterAchievementLocalization: .init(data: .init(id: localizationID)))
            ))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.post(
                path: "gameCenterAchievementImages", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Phase 3 — finalize.
        @discardableResult
        package func confirmUpload(id: String, md5Checksum: String) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievementImages"
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
                path: "gameCenterAchievementImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fileName: String? = nil) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievementImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var fileName: String? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(fileName: fileName)))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.patch(
                path: "gameCenterAchievementImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterAchievementImages/\(id)")
        }

        /// Convenience: runs the full 3-step upload from a local file URL.
        @discardableResult
        package func upload(
            localizationID: String,
            fileURL: URL,
            chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
        ) async throws -> Image {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let md5 = GameCenterAssetUpload.md5Hex(data: data)
            let reserved = try await reserve(
                localizationID: localizationID,
                fileName: fileName, fileSize: data.count
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(
                    domain: "GameCenterAPI.AchievementImages", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
                )
            }
            try await GameCenterAssetUpload.uploadChunks(
                client: client, operations: ops, fileData: data, progress: chunkProgress
            )
            return try await confirmUpload(id: reserved.id, md5Checksum: md5)
        }
    }

    // MARK: - gameCenterAchievementReleases

    /// Staging records that gate which achievement appears in a specific
    /// gameCenterAppVersion. Used to roll out a new achievement only with the
    /// next App Store release.
    package struct AchievementReleases: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Release: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let live: Bool?
            }
        }

        package func list(
            appVersionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Release> {
            let resp: PageEnvelope<Release> = try await client.get(
                path: "gameCenterAppVersions/\(appVersionID)/gameCenterAchievementReleases",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Release>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Release? {
            struct Resp: Decodable { let data: Release }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterAchievementReleases/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            appVersionID: String,
            achievementID: String,
            live: Bool? = nil
        ) async throws -> Release {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievementReleases"
                    let attributes: Attrs?
                    let relationships: Rels
                }
                struct Attrs: Encodable { var live: Bool? }
                struct Rels: Encodable {
                    struct AVRel: Encodable {
                        struct D: Encodable { let type = "gameCenterAppVersions"; let id: String }
                        let data: D
                    }
                    struct ARel: Encodable {
                        struct D: Encodable { let type = "gameCenterAchievements"; let id: String }
                        let data: D
                    }
                    let gameCenterAppVersion: AVRel
                    let gameCenterAchievement: ARel
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: live.map { Body.Attrs(live: $0) },
                relationships: .init(
                    gameCenterAppVersion: .init(data: .init(id: appVersionID)),
                    gameCenterAchievement: .init(data: .init(id: achievementID))
                )
            ))
            struct Resp: Decodable { let data: Release }
            let resp: Resp = try await client.post(
                path: "gameCenterAchievementReleases", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, live: Bool? = nil) async throws -> Release {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievementReleases"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var live: Bool? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(live: live)))
            struct Resp: Decodable { let data: Release }
            let resp: Resp = try await client.patch(
                path: "gameCenterAchievementReleases/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterAchievementReleases/\(id)")
        }
    }

    // MARK: - gameCenterLeaderboards

    /// Game Center leaderboards. Hosted per-app or per-group; each carries a
    /// vendor identifier and a sort strategy.
    package struct Leaderboards: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Leaderboard: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let vendorIdentifier: String?
                package let defaultFormatter: String?
                package let submissionType: String?
                package let scoreSortType: String?
                package let scoreRangeStart: String?
                package let scoreRangeEnd: String?
                package let recurrenceStartDate: Date?
                package let recurrenceDuration: String?
                package let recurrenceRule: String?
                package let archived: Bool?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var referenceName: String?
            package var vendorIdentifier: String?
            package var defaultFormatter: String?
            package var submissionType: String?
            package var scoreSortType: String?
            package var scoreRangeStart: String?
            package var scoreRangeEnd: String?
            package var recurrenceDuration: String?
            package var recurrenceRule: String?

            package init(
                referenceName: String? = nil,
                vendorIdentifier: String? = nil,
                defaultFormatter: String? = nil,
                submissionType: String? = nil,
                scoreSortType: String? = nil,
                scoreRangeStart: String? = nil,
                scoreRangeEnd: String? = nil,
                recurrenceDuration: String? = nil,
                recurrenceRule: String? = nil
            ) {
                self.referenceName = referenceName
                self.vendorIdentifier = vendorIdentifier
                self.defaultFormatter = defaultFormatter
                self.submissionType = submissionType
                self.scoreSortType = scoreSortType
                self.scoreRangeStart = scoreRangeStart
                self.scoreRangeEnd = scoreRangeEnd
                self.recurrenceDuration = recurrenceDuration
                self.recurrenceRule = recurrenceRule
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var referenceName: String?
            var vendorIdentifier: String?
            var defaultFormatter: String?
            var submissionType: String?
            var scoreSortType: String?
            var scoreRangeStart: String?
            var scoreRangeEnd: String?
            var recurrenceDuration: String?
            var recurrenceRule: String?

            init(fields: Fields) {
                self.referenceName = fields.referenceName
                self.vendorIdentifier = fields.vendorIdentifier
                self.defaultFormatter = fields.defaultFormatter
                self.submissionType = fields.submissionType
                self.scoreSortType = fields.scoreSortType
                self.scoreRangeStart = fields.scoreRangeStart
                self.scoreRangeEnd = fields.scoreRangeEnd
                self.recurrenceDuration = fields.recurrenceDuration
                self.recurrenceRule = fields.recurrenceRule
            }
        }

        package func listForApp(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Leaderboard> {
            let resp: PageEnvelope<Leaderboard> = try await client.get(
                path: "apps/\(appID)/gameCenterLeaderboards",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Leaderboard>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func listForDetail(
            detailID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Leaderboard> {
            let resp: PageEnvelope<Leaderboard> = try await client.get(
                path: "gameCenterDetails/\(detailID)/gameCenterLeaderboards",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Leaderboard>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func listForGroup(
            groupID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Leaderboard> {
            let resp: PageEnvelope<Leaderboard> = try await client.get(
                path: "gameCenterGroups/\(groupID)/gameCenterLeaderboards",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Leaderboard>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Leaderboard? {
            struct Resp: Decodable { let data: Leaderboard }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboards/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            detailID: String? = nil,
            groupID: String? = nil,
            fields: Fields
        ) async throws -> Leaderboard {
            precondition(detailID != nil || groupID != nil, "must supply detailID or groupID")
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboards"
                    let attributes: AttrsPatch
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct DetailRel: Encodable {
                        struct D: Encodable { let type = "gameCenterDetails"; let id: String }
                        let data: D
                    }
                    struct GroupRel: Encodable {
                        struct D: Encodable { let type = "gameCenterGroups"; let id: String }
                        let data: D
                    }
                    var gameCenterDetail: DetailRel?
                    var gameCenterGroup: GroupRel?
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: AttrsPatch(fields: fields),
                relationships: .init(
                    gameCenterDetail: detailID.map { .init(data: .init(id: $0)) },
                    gameCenterGroup: groupID.map { .init(data: .init(id: $0)) }
                )
            ))
            struct Resp: Decodable { let data: Leaderboard }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboards", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Leaderboard {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboards"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Leaderboard }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboards/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Toggles `archived` on a leaderboard. Same shape as the achievement
        /// archive op: a PATCH on the `archived` attribute. Archived
        /// leaderboards hide from the Game Center catalog.
        @discardableResult
        package func archive(id: String, archived: Bool = true) async throws -> Leaderboard {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboards"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { let archived: Bool }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(archived: archived)))
            struct Resp: Decodable { let data: Leaderboard }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboards/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboards/\(id)")
        }
    }

    // MARK: - gameCenterLeaderboardLocalizations

    package struct LeaderboardLocalizations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Localization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let locale: String?
                package let name: String?
                package let formatterOverride: String?
                package let formatterSuffix: String?
                package let formatterSuffixSingular: String?
                package let scoreFormat: String?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var name: String?
            package var formatterOverride: String?
            package var formatterSuffix: String?
            package var formatterSuffixSingular: String?
            package var scoreFormat: String?

            package init(
                name: String? = nil,
                formatterOverride: String? = nil,
                formatterSuffix: String? = nil,
                formatterSuffixSingular: String? = nil,
                scoreFormat: String? = nil
            ) {
                self.name = name
                self.formatterOverride = formatterOverride
                self.formatterSuffix = formatterSuffix
                self.formatterSuffixSingular = formatterSuffixSingular
                self.scoreFormat = scoreFormat
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var name: String?
            var formatterOverride: String?
            var formatterSuffix: String?
            var formatterSuffixSingular: String?
            var scoreFormat: String?

            init(fields: Fields) {
                self.name = fields.name
                self.formatterOverride = fields.formatterOverride
                self.formatterSuffix = fields.formatterSuffix
                self.formatterSuffixSingular = fields.formatterSuffixSingular
                self.scoreFormat = fields.scoreFormat
            }
        }

        package func list(
            leaderboardID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Localization> {
            let resp: PageEnvelope<Localization> = try await client.get(
                path: "gameCenterLeaderboards/\(leaderboardID)/localizations",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Localization>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Localization? {
            struct Resp: Decodable { let data: Localization }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardLocalizations/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            leaderboardID: String,
            locale: String,
            fields: Fields
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    var name: String?
                    var formatterOverride: String?
                    var formatterSuffix: String?
                    var formatterSuffixSingular: String?
                    var scoreFormat: String?
                }
                struct Rels: Encodable {
                    struct L: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboards"; let id: String }
                        let data: D
                    }
                    let gameCenterLeaderboard: L
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    locale: locale,
                    name: fields.name,
                    formatterOverride: fields.formatterOverride,
                    formatterSuffix: fields.formatterSuffix,
                    formatterSuffixSingular: fields.formatterSuffixSingular,
                    scoreFormat: fields.scoreFormat
                ),
                relationships: .init(
                    gameCenterLeaderboard: .init(data: .init(id: leaderboardID))
                )
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardLocalizations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardLocalizations"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboardLocalizations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboardLocalizations/\(id)")
        }
    }

    // MARK: - gameCenterLeaderboardImages

    /// Per-localization leaderboard icon, uploaded via the 3-phase flow.
    package struct LeaderboardImages: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Image: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int?
                package let imageAsset: ImageAsset?
                package let sourceFileChecksum: String?
                package let uploadOperations: [GameCenterAssetUpload.UploadOperation]?
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
            localizationID: String,
            limit: Int = 50,
            cursor: String? = nil
        ) async throws -> Page<Image> {
            let resp: PageEnvelope<Image> = try await client.get(
                path: "gameCenterLeaderboardLocalizations/\(localizationID)/gameCenterLeaderboardImage",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Image>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Image? {
            struct Resp: Decodable { let data: Image }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardImages/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func reserve(
            localizationID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int
                }
                struct Rels: Encodable {
                    struct L: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboardLocalizations"; let id: String }
                        let data: D
                    }
                    let gameCenterLeaderboardLocalization: L
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(gameCenterLeaderboardLocalization: .init(data: .init(id: localizationID)))
            ))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardImages", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func confirmUpload(id: String, md5Checksum: String) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardImages"
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
                path: "gameCenterLeaderboardImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fileName: String? = nil) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var fileName: String? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(fileName: fileName)))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboardImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboardImages/\(id)")
        }

        @discardableResult
        package func upload(
            localizationID: String,
            fileURL: URL,
            chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
        ) async throws -> Image {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let md5 = GameCenterAssetUpload.md5Hex(data: data)
            let reserved = try await reserve(
                localizationID: localizationID,
                fileName: fileName, fileSize: data.count
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(
                    domain: "GameCenterAPI.LeaderboardImages", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
                )
            }
            try await GameCenterAssetUpload.uploadChunks(
                client: client, operations: ops, fileData: data, progress: chunkProgress
            )
            return try await confirmUpload(id: reserved.id, md5Checksum: md5)
        }
    }

    // MARK: - gameCenterLeaderboardReleases

    /// Per-app-version staging records for leaderboards. Same shape as
    /// achievement releases.
    package struct LeaderboardReleases: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Release: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let live: Bool?
            }
        }

        package func list(
            appVersionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Release> {
            let resp: PageEnvelope<Release> = try await client.get(
                path: "gameCenterAppVersions/\(appVersionID)/gameCenterLeaderboardReleases",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Release>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Release? {
            struct Resp: Decodable { let data: Release }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardReleases/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            appVersionID: String,
            leaderboardID: String,
            live: Bool? = nil
        ) async throws -> Release {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardReleases"
                    let attributes: Attrs?
                    let relationships: Rels
                }
                struct Attrs: Encodable { var live: Bool? }
                struct Rels: Encodable {
                    struct AVRel: Encodable {
                        struct D: Encodable { let type = "gameCenterAppVersions"; let id: String }
                        let data: D
                    }
                    struct LRel: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboards"; let id: String }
                        let data: D
                    }
                    let gameCenterAppVersion: AVRel
                    let gameCenterLeaderboard: LRel
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: live.map { Body.Attrs(live: $0) },
                relationships: .init(
                    gameCenterAppVersion: .init(data: .init(id: appVersionID)),
                    gameCenterLeaderboard: .init(data: .init(id: leaderboardID))
                )
            ))
            struct Resp: Decodable { let data: Release }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardReleases", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, live: Bool? = nil) async throws -> Release {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardReleases"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var live: Bool? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(live: live)))
            struct Resp: Decodable { let data: Release }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboardReleases/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboardReleases/\(id)")
        }
    }

    // MARK: - gameCenterLeaderboardSets

    /// A leaderboard set groups multiple leaderboards into one folder shown
    /// in Game Center. The set itself carries a vendor identifier and may be
    /// archived just like leaderboards / achievements.
    package struct LeaderboardSets: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct LeaderboardSet: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let vendorIdentifier: String?
                package let archived: Bool?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var referenceName: String?
            package var vendorIdentifier: String?

            package init(
                referenceName: String? = nil,
                vendorIdentifier: String? = nil
            ) {
                self.referenceName = referenceName
                self.vendorIdentifier = vendorIdentifier
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var referenceName: String?
            var vendorIdentifier: String?

            init(fields: Fields) {
                self.referenceName = fields.referenceName
                self.vendorIdentifier = fields.vendorIdentifier
            }
        }

        package func listForApp(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<LeaderboardSet> {
            let resp: PageEnvelope<LeaderboardSet> = try await client.get(
                path: "apps/\(appID)/gameCenterLeaderboardSets",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<LeaderboardSet>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func listForDetail(
            detailID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<LeaderboardSet> {
            let resp: PageEnvelope<LeaderboardSet> = try await client.get(
                path: "gameCenterDetails/\(detailID)/gameCenterLeaderboardSets",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<LeaderboardSet>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func listForGroup(
            groupID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<LeaderboardSet> {
            let resp: PageEnvelope<LeaderboardSet> = try await client.get(
                path: "gameCenterGroups/\(groupID)/gameCenterLeaderboardSets",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<LeaderboardSet>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> LeaderboardSet? {
            struct Resp: Decodable { let data: LeaderboardSet }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardSets/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            detailID: String? = nil,
            groupID: String? = nil,
            fields: Fields
        ) async throws -> LeaderboardSet {
            precondition(detailID != nil || groupID != nil, "must supply detailID or groupID")
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSets"
                    let attributes: AttrsPatch
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct DetailRel: Encodable {
                        struct D: Encodable { let type = "gameCenterDetails"; let id: String }
                        let data: D
                    }
                    struct GroupRel: Encodable {
                        struct D: Encodable { let type = "gameCenterGroups"; let id: String }
                        let data: D
                    }
                    var gameCenterDetail: DetailRel?
                    var gameCenterGroup: GroupRel?
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: AttrsPatch(fields: fields),
                relationships: .init(
                    gameCenterDetail: detailID.map { .init(data: .init(id: $0)) },
                    gameCenterGroup: groupID.map { .init(data: .init(id: $0)) }
                )
            ))
            struct Resp: Decodable { let data: LeaderboardSet }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardSets", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> LeaderboardSet {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSets"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: LeaderboardSet }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboardSets/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func archive(id: String, archived: Bool = true) async throws -> LeaderboardSet {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSets"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { let archived: Bool }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(archived: archived)))
            struct Resp: Decodable { let data: LeaderboardSet }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboardSets/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboardSets/\(id)")
        }
    }

    // MARK: - gameCenterLeaderboardSetLocalizations

    package struct LeaderboardSetLocalizations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Localization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let locale: String?
                package let name: String?
            }
        }

        package func list(
            setID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Localization> {
            let resp: PageEnvelope<Localization> = try await client.get(
                path: "gameCenterLeaderboardSets/\(setID)/localizations",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Localization>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Localization? {
            struct Resp: Decodable { let data: Localization }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardSetLocalizations/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            setID: String,
            locale: String,
            name: String
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    let name: String
                }
                struct Rels: Encodable {
                    struct S: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboardSets"; let id: String }
                        let data: D
                    }
                    let gameCenterLeaderboardSet: S
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(locale: locale, name: name),
                relationships: .init(
                    gameCenterLeaderboardSet: .init(data: .init(id: setID))
                )
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardSetLocalizations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, name: String? = nil) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetLocalizations"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var name: String? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(name: name)))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboardSetLocalizations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboardSetLocalizations/\(id)")
        }
    }

    // MARK: - gameCenterLeaderboardSetImages

    /// Per-localization image for a leaderboard set. 3-phase upload.
    package struct LeaderboardSetImages: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Image: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int?
                package let imageAsset: ImageAsset?
                package let sourceFileChecksum: String?
                package let uploadOperations: [GameCenterAssetUpload.UploadOperation]?
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
            localizationID: String,
            limit: Int = 50,
            cursor: String? = nil
        ) async throws -> Page<Image> {
            let resp: PageEnvelope<Image> = try await client.get(
                path: "gameCenterLeaderboardSetLocalizations/\(localizationID)/gameCenterLeaderboardSetImage",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Image>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Image? {
            struct Resp: Decodable { let data: Image }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardSetImages/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func reserve(
            localizationID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int
                }
                struct Rels: Encodable {
                    struct L: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboardSetLocalizations"; let id: String }
                        let data: D
                    }
                    let gameCenterLeaderboardSetLocalization: L
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(
                    gameCenterLeaderboardSetLocalization: .init(data: .init(id: localizationID))
                )
            ))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardSetImages", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func confirmUpload(id: String, md5Checksum: String) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetImages"
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
                path: "gameCenterLeaderboardSetImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fileName: String? = nil) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var fileName: String? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(fileName: fileName)))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboardSetImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboardSetImages/\(id)")
        }

        @discardableResult
        package func upload(
            localizationID: String,
            fileURL: URL,
            chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
        ) async throws -> Image {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let md5 = GameCenterAssetUpload.md5Hex(data: data)
            let reserved = try await reserve(
                localizationID: localizationID,
                fileName: fileName, fileSize: data.count
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(
                    domain: "GameCenterAPI.LeaderboardSetImages", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
                )
            }
            try await GameCenterAssetUpload.uploadChunks(
                client: client, operations: ops, fileData: data, progress: chunkProgress
            )
            return try await confirmUpload(id: reserved.id, md5Checksum: md5)
        }
    }

    // MARK: - gameCenterLeaderboardSetMembers

    /// Membership record that wires a leaderboard into a leaderboard set.
    /// The order of these records inside a set controls the display order in
    /// Game Center; `reorderLeaderboards` rewrites the order in bulk.
    package struct LeaderboardSetMembers: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Member: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Position inside the set; lower values appear first.
                package let order: Int?
            }
        }

        package func list(
            setID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Member> {
            let resp: PageEnvelope<Member> = try await client.get(
                path: "gameCenterLeaderboardSets/\(setID)/gameCenterLeaderboardSetMembers",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Member>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Member? {
            struct Resp: Decodable { let data: Member }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardSetMembers/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Adds a leaderboard to a set. The member record's `order` is
        /// assigned by Apple; use `reorderLeaderboards` to change the order
        /// after creation.
        @discardableResult
        package func create(
            setID: String,
            leaderboardID: String
        ) async throws -> Member {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetMembers"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct SRel: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboardSets"; let id: String }
                        let data: D
                    }
                    struct LRel: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboards"; let id: String }
                        let data: D
                    }
                    let gameCenterLeaderboardSet: SRel
                    let gameCenterLeaderboard: LRel
                }
                let data: Data
            }
            let body = Body(data: .init(relationships: .init(
                gameCenterLeaderboardSet: .init(data: .init(id: setID)),
                gameCenterLeaderboard: .init(data: .init(id: leaderboardID))
            )))
            struct Resp: Decodable { let data: Member }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardSetMembers", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboardSetMembers/\(id)")
        }

        /// Special op — Apple exposes a relationship PATCH that rewrites the
        /// `gameCenterLeaderboards` relationship of a set in one shot.
        /// `leaderboardIDs` is the new ordered list; the relationship body
        /// sends the array verbatim so the resulting `order` on each member
        /// matches the index in the array.
        package func reorderLeaderboards(
            setID: String,
            leaderboardIDs: [String]
        ) async throws {
            struct Body: Encodable {
                struct D: Encodable { let type = "gameCenterLeaderboards"; let id: String }
                let data: [D]
            }
            let body = Body(data: leaderboardIDs.map { .init(id: $0) })
            struct Resp: Decodable {
                struct D: Decodable { let id: String }
                let data: [D]?
            }
            _ = try await client.patch(
                path: "gameCenterLeaderboardSets/\(setID)/relationships/gameCenterLeaderboards",
                body: body, as: Resp.self
            )
        }
    }

    // MARK: - gameCenterLeaderboardSetMemberLocalizations

    /// Per-locale name override for a set member. Apple uses this when the
    /// leaderboard's own localization should display differently inside a
    /// specific set.
    package struct LeaderboardSetMemberLocalizations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Localization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let locale: String?
                package let name: String?
            }
        }

        package func list(
            memberID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Localization> {
            let resp: PageEnvelope<Localization> = try await client.get(
                path: "gameCenterLeaderboardSetMembers/\(memberID)/gameCenterLeaderboardSetMemberLocalizations",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Localization>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Localization? {
            struct Resp: Decodable { let data: Localization }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardSetMemberLocalizations/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            memberID: String,
            locale: String,
            name: String
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetMemberLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    let name: String
                }
                struct Rels: Encodable {
                    struct M: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboardSetMembers"; let id: String }
                        let data: D
                    }
                    let gameCenterLeaderboardSetMember: M
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(locale: locale, name: name),
                relationships: .init(
                    gameCenterLeaderboardSetMember: .init(data: .init(id: memberID))
                )
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardSetMemberLocalizations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, name: String? = nil) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetMemberLocalizations"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var name: String? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(name: name)))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboardSetMemberLocalizations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboardSetMemberLocalizations/\(id)")
        }
    }

    // MARK: - gameCenterLeaderboardSetReleases

    /// Staging record for a leaderboard set in a given app version.
    package struct LeaderboardSetReleases: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Release: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let live: Bool?
            }
        }

        package func list(
            appVersionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Release> {
            let resp: PageEnvelope<Release> = try await client.get(
                path: "gameCenterAppVersions/\(appVersionID)/gameCenterLeaderboardSetReleases",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Release>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Release? {
            struct Resp: Decodable { let data: Release }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardSetReleases/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            appVersionID: String,
            leaderboardSetID: String,
            live: Bool? = nil
        ) async throws -> Release {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetReleases"
                    let attributes: Attrs?
                    let relationships: Rels
                }
                struct Attrs: Encodable { var live: Bool? }
                struct Rels: Encodable {
                    struct AVRel: Encodable {
                        struct D: Encodable { let type = "gameCenterAppVersions"; let id: String }
                        let data: D
                    }
                    struct SRel: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboardSets"; let id: String }
                        let data: D
                    }
                    let gameCenterAppVersion: AVRel
                    let gameCenterLeaderboardSet: SRel
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: live.map { Body.Attrs(live: $0) },
                relationships: .init(
                    gameCenterAppVersion: .init(data: .init(id: appVersionID)),
                    gameCenterLeaderboardSet: .init(data: .init(id: leaderboardSetID))
                )
            ))
            struct Resp: Decodable { let data: Release }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardSetReleases", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, live: Bool? = nil) async throws -> Release {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetReleases"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var live: Bool? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(live: live)))
            struct Resp: Decodable { let data: Release }
            let resp: Resp = try await client.patch(
                path: "gameCenterLeaderboardSetReleases/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterLeaderboardSetReleases/\(id)")
        }
    }

    // MARK: - gameCenterMatchmakingQueues

    /// Game Center matchmaking queue. Each queue maps a client-side join
    /// request to a rule set + team configuration; many queues per app.
    package struct MatchmakingQueues: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Queue: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let classicMatchmakingBundleIds: [String]?
                package let experimentRuleSetId: String?
                package let experimentRuleSetTrafficShare: Int?
                package let ruleSetId: String?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var referenceName: String?
            package var classicMatchmakingBundleIDs: [String]?
            package var experimentRuleSetID: String?
            package var experimentRuleSetTrafficShare: Int?
            package var ruleSetID: String?

            package init(
                referenceName: String? = nil,
                classicMatchmakingBundleIDs: [String]? = nil,
                experimentRuleSetID: String? = nil,
                experimentRuleSetTrafficShare: Int? = nil,
                ruleSetID: String? = nil
            ) {
                self.referenceName = referenceName
                self.classicMatchmakingBundleIDs = classicMatchmakingBundleIDs
                self.experimentRuleSetID = experimentRuleSetID
                self.experimentRuleSetTrafficShare = experimentRuleSetTrafficShare
                self.ruleSetID = ruleSetID
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var referenceName: String?
            var classicMatchmakingBundleIds: [String]?
            var experimentRuleSetId: String?
            var experimentRuleSetTrafficShare: Int?
            var ruleSetId: String?

            init(fields: Fields) {
                self.referenceName = fields.referenceName
                self.classicMatchmakingBundleIds = fields.classicMatchmakingBundleIDs
                self.experimentRuleSetId = fields.experimentRuleSetID
                self.experimentRuleSetTrafficShare = fields.experimentRuleSetTrafficShare
                self.ruleSetId = fields.ruleSetID
            }
        }

        package func listForApp(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Queue> {
            let resp: PageEnvelope<Queue> = try await client.get(
                path: "apps/\(appID)/gameCenterMatchmakingQueues",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Queue>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Queue? {
            struct Resp: Decodable { let data: Queue }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterMatchmakingQueues/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            appID: String,
            fields: Fields
        ) async throws -> Queue {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingQueues"
                    let attributes: AttrsPatch
                    let relationships: Rels
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
                attributes: AttrsPatch(fields: fields),
                relationships: .init(app: .init(data: .init(id: appID)))
            ))
            struct Resp: Decodable { let data: Queue }
            let resp: Resp = try await client.post(
                path: "gameCenterMatchmakingQueues", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Queue {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingQueues"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Queue }
            let resp: Resp = try await client.patch(
                path: "gameCenterMatchmakingQueues/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterMatchmakingQueues/\(id)")
        }
    }

    // MARK: - gameCenterMatchmakingRuleSets

    /// A matchmaking rule set ties a list of rules to a max-player count.
    /// Each queue references exactly one rule set as its active config.
    package struct MatchmakingRuleSets: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct RuleSet: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let ruleLanguageVersion: Int?
                package let minPlayers: Int?
                package let maxPlayers: Int?
                package let teams: Int?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var referenceName: String?
            package var ruleLanguageVersion: Int?
            package var minPlayers: Int?
            package var maxPlayers: Int?
            package var teams: Int?

            package init(
                referenceName: String? = nil,
                ruleLanguageVersion: Int? = nil,
                minPlayers: Int? = nil,
                maxPlayers: Int? = nil,
                teams: Int? = nil
            ) {
                self.referenceName = referenceName
                self.ruleLanguageVersion = ruleLanguageVersion
                self.minPlayers = minPlayers
                self.maxPlayers = maxPlayers
                self.teams = teams
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var referenceName: String?
            var ruleLanguageVersion: Int?
            var minPlayers: Int?
            var maxPlayers: Int?
            var teams: Int?

            init(fields: Fields) {
                self.referenceName = fields.referenceName
                self.ruleLanguageVersion = fields.ruleLanguageVersion
                self.minPlayers = fields.minPlayers
                self.maxPlayers = fields.maxPlayers
                self.teams = fields.teams
            }
        }

        /// Lists rule sets attached to a queue. The relationship is
        /// `gameCenterMatchmakingQueues/{id}/relationships/ruleSets` — Apple
        /// surfaces them per-queue rather than per-app.
        package func listForQueue(
            queueID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<RuleSet> {
            let resp: PageEnvelope<RuleSet> = try await client.get(
                path: "gameCenterMatchmakingQueues/\(queueID)/ruleSets",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<RuleSet>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> RuleSet? {
            struct Resp: Decodable { let data: RuleSet }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterMatchmakingRuleSets/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            queueID: String,
            fields: Fields
        ) async throws -> RuleSet {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingRuleSets"
                    let attributes: AttrsPatch
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct Q: Encodable {
                        struct D: Encodable { let type = "gameCenterMatchmakingQueues"; let id: String }
                        let data: D
                    }
                    let matchmakingQueue: Q
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: AttrsPatch(fields: fields),
                relationships: .init(matchmakingQueue: .init(data: .init(id: queueID)))
            ))
            struct Resp: Decodable { let data: RuleSet }
            let resp: Resp = try await client.post(
                path: "gameCenterMatchmakingRuleSets", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> RuleSet {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingRuleSets"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: RuleSet }
            let resp: Resp = try await client.patch(
                path: "gameCenterMatchmakingRuleSets/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterMatchmakingRuleSets/\(id)")
        }
    }

    // MARK: - gameCenterMatchmakingRules

    /// Individual matchmaking rule. Each rule is a typed expression Apple
    /// evaluates against a candidate player set; the `expression` attribute is
    /// the JSON DSL Apple expects in the request.
    package struct MatchmakingRules: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Rule: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let description: String?
                package let type: String?
                package let expression: String?
                package let weight: Double?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var referenceName: String?
            package var description: String?
            package var type: String?
            package var expression: String?
            package var weight: Double?

            package init(
                referenceName: String? = nil,
                description: String? = nil,
                type: String? = nil,
                expression: String? = nil,
                weight: Double? = nil
            ) {
                self.referenceName = referenceName
                self.description = description
                self.type = type
                self.expression = expression
                self.weight = weight
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var referenceName: String?
            var description: String?
            var type: String?
            var expression: String?
            var weight: Double?

            init(fields: Fields) {
                self.referenceName = fields.referenceName
                self.description = fields.description
                self.type = fields.type
                self.expression = fields.expression
                self.weight = fields.weight
            }
        }

        package func listForRuleSet(
            ruleSetID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Rule> {
            let resp: PageEnvelope<Rule> = try await client.get(
                path: "gameCenterMatchmakingRuleSets/\(ruleSetID)/rules",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Rule>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Rule? {
            struct Resp: Decodable { let data: Rule }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterMatchmakingRules/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            ruleSetID: String,
            fields: Fields
        ) async throws -> Rule {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingRules"
                    let attributes: AttrsPatch
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct R: Encodable {
                        struct D: Encodable { let type = "gameCenterMatchmakingRuleSets"; let id: String }
                        let data: D
                    }
                    let matchmakingRuleSet: R
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: AttrsPatch(fields: fields),
                relationships: .init(matchmakingRuleSet: .init(data: .init(id: ruleSetID)))
            ))
            struct Resp: Decodable { let data: Rule }
            let resp: Resp = try await client.post(
                path: "gameCenterMatchmakingRules", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Rule {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingRules"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Rule }
            let resp: Resp = try await client.patch(
                path: "gameCenterMatchmakingRules/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterMatchmakingRules/\(id)")
        }

        // MARK: Rule testing endpoints

        /// Generic single-attribute test result Apple returns from the
        /// per-rule-set test endpoints. We surface the raw JSON so callers
        /// can inspect Apple's match assignments and rule outputs without
        /// us reshaping them.
        package struct TestResult: Codable, Sendable {
            package let id: String?
            package let type: String?
            package let attributes: AttributesPayload?

            package struct AttributesPayload: Codable, Sendable {
                package let serializedResult: String?
            }
        }

        /// Submits a `requests` JSON DSL payload to Apple's match-test
        /// endpoint and returns the deserialized result. The body shape Apple
        /// wants is `{ "data": { "type": "gameCenterMatchmakingRuleSetTests",
        /// "attributes": { "matchmakingRequests": <json> } } }`.
        @discardableResult
        package func testRuleSetMatch(
            ruleSetID: String,
            matchmakingRequests: String
        ) async throws -> TestResult {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingRuleSetTests"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable { let matchmakingRequests: String }
                struct Rels: Encodable {
                    struct R: Encodable {
                        struct D: Encodable { let type = "gameCenterMatchmakingRuleSets"; let id: String }
                        let data: D
                    }
                    let matchmakingRuleSet: R
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(matchmakingRequests: matchmakingRequests),
                relationships: .init(matchmakingRuleSet: .init(data: .init(id: ruleSetID)))
            ))
            struct Resp: Decodable { let data: TestResult }
            let resp: Resp = try await client.post(
                path: "gameCenterMatchmakingRuleSetTests", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Submits a `requests` JSON DSL payload to Apple's
        /// per-queue match-test endpoint. Used to validate that a queue's
        /// currently active rule-set yields the expected assignment for a
        /// candidate request batch before promoting changes.
        @discardableResult
        package func testQueueMatch(
            queueID: String,
            matchmakingRequests: String
        ) async throws -> TestResult {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingQueueTests"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable { let matchmakingRequests: String }
                struct Rels: Encodable {
                    struct Q: Encodable {
                        struct D: Encodable { let type = "gameCenterMatchmakingQueues"; let id: String }
                        let data: D
                    }
                    let matchmakingQueue: Q
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(matchmakingRequests: matchmakingRequests),
                relationships: .init(matchmakingQueue: .init(data: .init(id: queueID)))
            ))
            struct Resp: Decodable { let data: TestResult }
            let resp: Resp = try await client.post(
                path: "gameCenterMatchmakingQueueTests", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - gameCenterMatchmakingTeamConfigurations

    /// Team configuration that gates how a rule set splits players across
    /// teams in a match.
    package struct MatchmakingTeamConfigurations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Configuration: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let maxPlayers: Int?
                package let minPlayers: Int?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var referenceName: String?
            package var maxPlayers: Int?
            package var minPlayers: Int?

            package init(
                referenceName: String? = nil,
                maxPlayers: Int? = nil,
                minPlayers: Int? = nil
            ) {
                self.referenceName = referenceName
                self.maxPlayers = maxPlayers
                self.minPlayers = minPlayers
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var referenceName: String?
            var maxPlayers: Int?
            var minPlayers: Int?

            init(fields: Fields) {
                self.referenceName = fields.referenceName
                self.maxPlayers = fields.maxPlayers
                self.minPlayers = fields.minPlayers
            }
        }

        package func listForRuleSet(
            ruleSetID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Configuration> {
            let resp: PageEnvelope<Configuration> = try await client.get(
                path: "gameCenterMatchmakingRuleSets/\(ruleSetID)/teams",
                query: GameCenterAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Configuration>.self
            )
            return GameCenterAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Configuration? {
            struct Resp: Decodable { let data: Configuration }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterMatchmakingTeams/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            ruleSetID: String,
            fields: Fields
        ) async throws -> Configuration {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingTeams"
                    let attributes: AttrsPatch
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct R: Encodable {
                        struct D: Encodable { let type = "gameCenterMatchmakingRuleSets"; let id: String }
                        let data: D
                    }
                    let matchmakingRuleSet: R
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: AttrsPatch(fields: fields),
                relationships: .init(matchmakingRuleSet: .init(data: .init(id: ruleSetID)))
            ))
            struct Resp: Decodable { let data: Configuration }
            let resp: Resp = try await client.post(
                path: "gameCenterMatchmakingTeams", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Configuration {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterMatchmakingTeams"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Configuration }
            let resp: Resp = try await client.patch(
                path: "gameCenterMatchmakingTeams/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterMatchmakingTeams/\(id)")
        }
    }
}
