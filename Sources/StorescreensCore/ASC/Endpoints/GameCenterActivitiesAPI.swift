import Foundation
import CryptoKit

// MARK: - Shared upload helper for Activity / Challenge image assets

/// Reservation + chunk PUT + checksum-confirm upload, used by the Activity and
/// Challenge image resources in this file. Mirrors `GameCenterAssetUpload`
/// (Wave 2's helper at the top of GameCenterAPI.swift) but kept as a separate
/// copy here so the two files don't share symbols.
///
/// Phases:
///   1. POST creates the image record carrying `fileName` + `fileSize`. Apple
///      returns the record with `uploadOperations` (pre-signed PUT URLs plus
///      per-chunk header instructions).
///   2. PUT each chunk to its URL, slicing by offset+length.
///   3. PATCH `uploaded: true` + `sourceFileChecksum` (hex MD5) to finalize.
package enum GameCenterActivityAssetUpload {

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

    /// Phase 2, push every chunk to its pre-signed URL.
    package static func uploadChunks(
        client: ASCClient,
        operations: [UploadOperation],
        fileData: Data,
        progress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws {
        for (index, op) in operations.enumerated() {
            guard let url = URL(string: op.url) else {
                throw NSError(
                    domain: "GameCenterActivityAssetUpload",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid uploadOperation URL"]
                )
            }
            let end = op.offset + op.length
            guard end <= fileData.count else {
                throw NSError(
                    domain: "GameCenterActivityAssetUpload",
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

// MARK: - GameCenterActivitiesAPI master struct

/// App Store Connect endpoints for the Game Center surfaces added in
/// OpenAPI spec v4.0 (June 2025) and v4.2 (December 2025):
///
///   - gameCenterActivities, gameCenterActivityImages,
///     gameCenterActivityLocalizations, gameCenterActivityVersions
///     (in-game events and tournaments shown in the Game Center surface)
///   - gameCenterChallenges, gameCenterChallengeImages,
///     gameCenterChallengeLocalizations, gameCenterChallengeVersions
///     (player-vs-player or community challenges, optionally linked to a
///     leaderboard)
///   - gameCenterAchievementVersions (V2),
///     gameCenterLeaderboardVersions (V2),
///     gameCenterLeaderboardSetVersions (V2)
///     (per-app-version snapshots of achievement / leaderboard / set config)
///   - gameCenterLeaderboardEntrySubmissions (test-only score submit)
///   - gameCenterPlayerAchievementSubmissions (test-only achievement submit)
///
/// Pagination convention matches GameCenterAPI: every list endpoint takes
/// `limit: Int = 200, cursor: String? = nil` and returns `Page` carrying the
/// items plus an opaque `nextCursor` extracted from Apple's `links.next`.
///
/// 404 on get returns nil. 409 conflicts surface via
/// `ASCClient.APIError.isAlreadySetConflict`.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/game-center
package struct GameCenterActivitiesAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // Activities ------------------------------------------------------------
    package var activities: Activities { Activities(client: client) }
    package var activityImages: ActivityImages { ActivityImages(client: client) }
    package var activityLocalizations: ActivityLocalizations { ActivityLocalizations(client: client) }
    package var activityVersions: ActivityVersions { ActivityVersions(client: client) }

    // Challenges ------------------------------------------------------------
    package var challenges: Challenges { Challenges(client: client) }
    package var challengeImages: ChallengeImages { ChallengeImages(client: client) }
    package var challengeLocalizations: ChallengeLocalizations { ChallengeLocalizations(client: client) }
    package var challengeVersions: ChallengeVersions { ChallengeVersions(client: client) }

    // V2 versioning ---------------------------------------------------------
    package var achievementVersionsV2: AchievementVersionsV2 { AchievementVersionsV2(client: client) }
    package var leaderboardVersionsV2: LeaderboardVersionsV2 { LeaderboardVersionsV2(client: client) }
    package var leaderboardSetVersionsV2: LeaderboardSetVersionsV2 { LeaderboardSetVersionsV2(client: client) }

    // Testing-only submission endpoints -------------------------------------
    package var leaderboardEntrySubmissions: LeaderboardEntrySubmissions { LeaderboardEntrySubmissions(client: client) }
    package var playerAchievementSubmissions: PlayerAchievementSubmissions { PlayerAchievementSubmissions(client: client) }

    // MARK: - Shared paged response shape

    /// A page of items plus an opaque cursor for the next page. Cursor is
    /// extracted from Apple's `links.next` so callers can pass it back
    /// unchanged on the next call. When `nextCursor` is nil, the caller has
    /// reached the end of the list.
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

    // MARK: - gameCenterActivities

    /// Live in-game events and tournaments shown in the Game Center surface.
    /// Each activity is hosted under a `gameCenterDetail` (per-app) or a
    /// cross-app `gameCenterGroup`, has a vendor identifier, a kind
    /// ("EVENT" | "TOURNAMENT" | …), and an optional `eventStartDate` /
    /// `eventEndDate` window. Localizations carry per-locale display copy
    /// and images carry per-locale art.
    package struct Activities: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Activity: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let vendorIdentifier: String?
                package let activityType: String?
                package let activityState: String?
                package let eventStartDate: Date?
                package let eventEndDate: Date?
                package let archived: Bool?
            }
        }

        /// Fields accepted on create/update. Nil fields are omitted from the
        /// wire body so existing values stay untouched on PATCH.
        package struct Fields: Sendable, Equatable {
            package var referenceName: String?
            package var vendorIdentifier: String?
            package var activityType: String?
            package var eventStartDate: Date?
            package var eventEndDate: Date?

            package init(
                referenceName: String? = nil,
                vendorIdentifier: String? = nil,
                activityType: String? = nil,
                eventStartDate: Date? = nil,
                eventEndDate: Date? = nil
            ) {
                self.referenceName = referenceName
                self.vendorIdentifier = vendorIdentifier
                self.activityType = activityType
                self.eventStartDate = eventStartDate
                self.eventEndDate = eventEndDate
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var referenceName: String?
            var vendorIdentifier: String?
            var activityType: String?
            var eventStartDate: Date?
            var eventEndDate: Date?

            init(fields: Fields) {
                self.referenceName = fields.referenceName
                self.vendorIdentifier = fields.vendorIdentifier
                self.activityType = fields.activityType
                self.eventStartDate = fields.eventStartDate
                self.eventEndDate = fields.eventEndDate
            }
        }

        /// Lists activities for an app via the parent relationship.
        package func listForApp(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Activity> {
            let resp: PageEnvelope<Activity> = try await client.get(
                path: "apps/\(appID)/gameCenterActivities",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Activity>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        /// Lists activities for a gameCenterDetail directly.
        package func listForDetail(
            detailID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Activity> {
            let resp: PageEnvelope<Activity> = try await client.get(
                path: "gameCenterDetails/\(detailID)/gameCenterActivities",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Activity>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        /// Lists activities under a cross-app group.
        package func listForGroup(
            groupID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Activity> {
            let resp: PageEnvelope<Activity> = try await client.get(
                path: "gameCenterGroups/\(groupID)/gameCenterActivities",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Activity>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Activity? {
            struct Resp: Decodable { let data: Activity }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterActivities/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Creates an activity under a single gameCenterDetail. Pass `groupID`
        /// instead of `detailID` to create one shared across a cross-app group.
        @discardableResult
        package func create(
            detailID: String? = nil,
            groupID: String? = nil,
            fields: Fields
        ) async throws -> Activity {
            precondition(detailID != nil || groupID != nil, "must supply detailID or groupID")
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivities"
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
            struct Resp: Decodable { let data: Activity }
            let resp: Resp = try await client.post(
                path: "gameCenterActivities", body: body, as: Resp.self
            )
            return resp.data
        }

        /// PATCH the activity with any non-nil fields. Nil fields stay
        /// untouched on App Store Connect.
        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Activity {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivities"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Activity }
            let resp: Resp = try await client.patch(
                path: "gameCenterActivities/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Toggles `archived` on an activity. Archived activities are hidden
        /// from the Game Center catalog but retain their history.
        @discardableResult
        package func archive(id: String, archived: Bool = true) async throws -> Activity {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivities"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { let archived: Bool }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(archived: archived)))
            struct Resp: Decodable { let data: Activity }
            let resp: Resp = try await client.patch(
                path: "gameCenterActivities/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterActivities/\(id)")
        }
    }

    // MARK: - gameCenterActivityLocalizations

    /// Per-locale display copy for an activity: name, subtitle, description.
    /// At least one locale is required before submission.
    package struct ActivityLocalizations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Localization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let locale: String?
                package let name: String?
                package let subtitle: String?
                package let activityDescription: String?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var name: String?
            package var subtitle: String?
            package var activityDescription: String?

            package init(
                name: String? = nil,
                subtitle: String? = nil,
                activityDescription: String? = nil
            ) {
                self.name = name
                self.subtitle = subtitle
                self.activityDescription = activityDescription
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var name: String?
            var subtitle: String?
            var activityDescription: String?

            init(fields: Fields) {
                self.name = fields.name
                self.subtitle = fields.subtitle
                self.activityDescription = fields.activityDescription
            }
        }

        package func list(
            activityID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Localization> {
            let resp: PageEnvelope<Localization> = try await client.get(
                path: "gameCenterActivities/\(activityID)/localizations",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Localization>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Localization? {
            struct Resp: Decodable { let data: Localization }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterActivityLocalizations/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            activityID: String,
            locale: String,
            fields: Fields
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivityLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    var name: String?
                    var subtitle: String?
                    var activityDescription: String?
                }
                struct Rels: Encodable {
                    struct A: Encodable {
                        struct D: Encodable { let type = "gameCenterActivities"; let id: String }
                        let data: D
                    }
                    let gameCenterActivity: A
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    locale: locale,
                    name: fields.name,
                    subtitle: fields.subtitle,
                    activityDescription: fields.activityDescription
                ),
                relationships: .init(gameCenterActivity: .init(data: .init(id: activityID)))
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.post(
                path: "gameCenterActivityLocalizations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivityLocalizations"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.patch(
                path: "gameCenterActivityLocalizations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterActivityLocalizations/\(id)")
        }
    }

    // MARK: - gameCenterActivityImages

    /// Per-localization activity image. Uploaded via the 3-phase reservation
    /// flow defined at the top of this file.
    package struct ActivityImages: Sendable {
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
                package let uploadOperations: [GameCenterActivityAssetUpload.UploadOperation]?
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
                path: "gameCenterActivityLocalizations/\(localizationID)/gameCenterActivityImage",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Image>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Image? {
            struct Resp: Decodable { let data: Image }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterActivityImages/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Phase 1, reserve. Returns the image record with
        /// `uploadOperations` populated.
        @discardableResult
        package func reserve(
            localizationID: String,
            fileName: String,
            fileSize: Int
        ) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivityImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int
                }
                struct Rels: Encodable {
                    struct L: Encodable {
                        struct D: Encodable { let type = "gameCenterActivityLocalizations"; let id: String }
                        let data: D
                    }
                    let gameCenterActivityLocalization: L
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(gameCenterActivityLocalization: .init(data: .init(id: localizationID)))
            ))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.post(
                path: "gameCenterActivityImages", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Phase 3, finalize.
        @discardableResult
        package func confirmUpload(id: String, md5Checksum: String) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivityImages"
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
                path: "gameCenterActivityImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fileName: String? = nil) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivityImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var fileName: String? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(fileName: fileName)))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.patch(
                path: "gameCenterActivityImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterActivityImages/\(id)")
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
            let md5 = GameCenterActivityAssetUpload.md5Hex(data: data)
            let reserved = try await reserve(
                localizationID: localizationID,
                fileName: fileName, fileSize: data.count
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(
                    domain: "GameCenterActivitiesAPI.ActivityImages", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
                )
            }
            try await GameCenterActivityAssetUpload.uploadChunks(
                client: client, operations: ops, fileData: data, progress: chunkProgress
            )
            return try await confirmUpload(id: reserved.id, md5Checksum: md5)
        }
    }

    // MARK: - gameCenterActivityVersions

    /// Per-app-version snapshot of an activity's configuration. Created when
    /// you cut a new app version that needs to include the activity, so the
    /// activity's wire shape can evolve independently of the live shape on
    /// older app versions. No delete: once a version-snapshot exists, Apple
    /// keeps it around for the lifetime of the parent activity.
    package struct ActivityVersions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Version: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let live: Bool?
                package let versionState: String?
                package let createdDate: Date?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var live: Bool?

            package init(live: Bool? = nil) {
                self.live = live
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var live: Bool?

            init(fields: Fields) {
                self.live = fields.live
            }
        }

        package func list(
            activityID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Version> {
            let resp: PageEnvelope<Version> = try await client.get(
                path: "gameCenterActivities/\(activityID)/gameCenterActivityVersions",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Version>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Version? {
            struct Resp: Decodable { let data: Version }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterActivityVersions/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Create an activity version snapshot, scoped to a parent activity
        /// and optionally to a specific gameCenterAppVersion.
        @discardableResult
        package func create(
            activityID: String,
            appVersionID: String? = nil,
            fields: Fields = Fields()
        ) async throws -> Version {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivityVersions"
                    var attributes: AttrsPatch?
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct ARel: Encodable {
                        struct D: Encodable { let type = "gameCenterActivities"; let id: String }
                        let data: D
                    }
                    struct AVRel: Encodable {
                        struct D: Encodable { let type = "gameCenterAppVersions"; let id: String }
                        let data: D
                    }
                    let gameCenterActivity: ARel
                    var gameCenterAppVersion: AVRel?
                }
                let data: Data
            }
            let attrs: AttrsPatch? = (fields.live == nil) ? nil : AttrsPatch(fields: fields)
            let body = Body(data: .init(
                attributes: attrs,
                relationships: .init(
                    gameCenterActivity: .init(data: .init(id: activityID)),
                    gameCenterAppVersion: appVersionID.map { .init(data: .init(id: $0)) }
                )
            ))
            struct Resp: Decodable { let data: Version }
            let resp: Resp = try await client.post(
                path: "gameCenterActivityVersions", body: body, as: Resp.self
            )
            return resp.data
        }

        /// PATCH the activity version snapshot. Apple supports updating
        /// `live` to flip whether the snapshot is in production.
        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Version {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterActivityVersions"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Version }
            let resp: Resp = try await client.patch(
                path: "gameCenterActivityVersions/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - gameCenterChallenges

    /// Player-vs-player or community challenges. Each challenge optionally
    /// links to a leaderboard so scores submitted via the challenge feed into
    /// a ranking. Hosted under a `gameCenterDetail` or cross-app
    /// `gameCenterGroup`.
    package struct Challenges: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Challenge: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let referenceName: String?
                package let vendorIdentifier: String?
                package let challengeType: String?
                package let challengeState: String?
                package let archived: Bool?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var referenceName: String?
            package var vendorIdentifier: String?
            package var challengeType: String?

            package init(
                referenceName: String? = nil,
                vendorIdentifier: String? = nil,
                challengeType: String? = nil
            ) {
                self.referenceName = referenceName
                self.vendorIdentifier = vendorIdentifier
                self.challengeType = challengeType
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var referenceName: String?
            var vendorIdentifier: String?
            var challengeType: String?

            init(fields: Fields) {
                self.referenceName = fields.referenceName
                self.vendorIdentifier = fields.vendorIdentifier
                self.challengeType = fields.challengeType
            }
        }

        package func listForApp(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Challenge> {
            let resp: PageEnvelope<Challenge> = try await client.get(
                path: "apps/\(appID)/gameCenterChallenges",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Challenge>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func listForDetail(
            detailID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Challenge> {
            let resp: PageEnvelope<Challenge> = try await client.get(
                path: "gameCenterDetails/\(detailID)/gameCenterChallenges",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Challenge>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func listForGroup(
            groupID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Challenge> {
            let resp: PageEnvelope<Challenge> = try await client.get(
                path: "gameCenterGroups/\(groupID)/gameCenterChallenges",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Challenge>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Challenge? {
            struct Resp: Decodable { let data: Challenge }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterChallenges/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Creates a challenge under a single gameCenterDetail or a
        /// cross-app gameCenterGroup. Optionally link it to a leaderboard so
        /// scores feed into a ranking.
        @discardableResult
        package func create(
            detailID: String? = nil,
            groupID: String? = nil,
            leaderboardID: String? = nil,
            fields: Fields
        ) async throws -> Challenge {
            precondition(detailID != nil || groupID != nil, "must supply detailID or groupID")
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterChallenges"
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
                    struct LeaderboardRel: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboards"; let id: String }
                        let data: D
                    }
                    var gameCenterDetail: DetailRel?
                    var gameCenterGroup: GroupRel?
                    var gameCenterLeaderboard: LeaderboardRel?
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: AttrsPatch(fields: fields),
                relationships: .init(
                    gameCenterDetail: detailID.map { .init(data: .init(id: $0)) },
                    gameCenterGroup: groupID.map { .init(data: .init(id: $0)) },
                    gameCenterLeaderboard: leaderboardID.map { .init(data: .init(id: $0)) }
                )
            ))
            struct Resp: Decodable { let data: Challenge }
            let resp: Resp = try await client.post(
                path: "gameCenterChallenges", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Challenge {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterChallenges"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Challenge }
            let resp: Resp = try await client.patch(
                path: "gameCenterChallenges/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Toggles `archived` on a challenge.
        @discardableResult
        package func archive(id: String, archived: Bool = true) async throws -> Challenge {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterChallenges"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { let archived: Bool }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(archived: archived)))
            struct Resp: Decodable { let data: Challenge }
            let resp: Resp = try await client.patch(
                path: "gameCenterChallenges/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterChallenges/\(id)")
        }
    }

    // MARK: - gameCenterChallengeLocalizations

    /// Per-locale display copy for a challenge: name, subtitle, description.
    package struct ChallengeLocalizations: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Localization: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let locale: String?
                package let name: String?
                package let subtitle: String?
                package let challengeDescription: String?
            }
        }

        package struct Fields: Sendable, Equatable {
            package var name: String?
            package var subtitle: String?
            package var challengeDescription: String?

            package init(
                name: String? = nil,
                subtitle: String? = nil,
                challengeDescription: String? = nil
            ) {
                self.name = name
                self.subtitle = subtitle
                self.challengeDescription = challengeDescription
            }
        }

        fileprivate struct AttrsPatch: Encodable {
            var name: String?
            var subtitle: String?
            var challengeDescription: String?

            init(fields: Fields) {
                self.name = fields.name
                self.subtitle = fields.subtitle
                self.challengeDescription = fields.challengeDescription
            }
        }

        package func list(
            challengeID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Localization> {
            let resp: PageEnvelope<Localization> = try await client.get(
                path: "gameCenterChallenges/\(challengeID)/localizations",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Localization>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Localization? {
            struct Resp: Decodable { let data: Localization }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterChallengeLocalizations/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            challengeID: String,
            locale: String,
            fields: Fields
        ) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterChallengeLocalizations"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let locale: String
                    var name: String?
                    var subtitle: String?
                    var challengeDescription: String?
                }
                struct Rels: Encodable {
                    struct C: Encodable {
                        struct D: Encodable { let type = "gameCenterChallenges"; let id: String }
                        let data: D
                    }
                    let gameCenterChallenge: C
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    locale: locale,
                    name: fields.name,
                    subtitle: fields.subtitle,
                    challengeDescription: fields.challengeDescription
                ),
                relationships: .init(gameCenterChallenge: .init(data: .init(id: challengeID)))
            ))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.post(
                path: "gameCenterChallengeLocalizations", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fields: Fields) async throws -> Localization {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterChallengeLocalizations"
                    let id: String
                    let attributes: AttrsPatch
                }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: AttrsPatch(fields: fields)))
            struct Resp: Decodable { let data: Localization }
            let resp: Resp = try await client.patch(
                path: "gameCenterChallengeLocalizations/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterChallengeLocalizations/\(id)")
        }
    }

    // MARK: - gameCenterChallengeImages

    /// Per-localization challenge image. Uploaded via the 3-phase reservation
    /// flow defined at the top of this file.
    package struct ChallengeImages: Sendable {
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
                package let uploadOperations: [GameCenterActivityAssetUpload.UploadOperation]?
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
                path: "gameCenterChallengeLocalizations/\(localizationID)/gameCenterChallengeImage",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Image>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Image? {
            struct Resp: Decodable { let data: Image }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterChallengeImages/\(id)", as: Resp.self
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
                    let type = "gameCenterChallengeImages"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int
                }
                struct Rels: Encodable {
                    struct L: Encodable {
                        struct D: Encodable { let type = "gameCenterChallengeLocalizations"; let id: String }
                        let data: D
                    }
                    let gameCenterChallengeLocalization: L
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(gameCenterChallengeLocalization: .init(data: .init(id: localizationID)))
            ))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.post(
                path: "gameCenterChallengeImages", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func confirmUpload(id: String, md5Checksum: String) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterChallengeImages"
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
                path: "gameCenterChallengeImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        @discardableResult
        package func update(id: String, fileName: String? = nil) async throws -> Image {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterChallengeImages"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { var fileName: String? }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(fileName: fileName)))
            struct Resp: Decodable { let data: Image }
            let resp: Resp = try await client.patch(
                path: "gameCenterChallengeImages/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "gameCenterChallengeImages/\(id)")
        }

        @discardableResult
        package func upload(
            localizationID: String,
            fileURL: URL,
            chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
        ) async throws -> Image {
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            let md5 = GameCenterActivityAssetUpload.md5Hex(data: data)
            let reserved = try await reserve(
                localizationID: localizationID,
                fileName: fileName, fileSize: data.count
            )
            guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
                throw NSError(
                    domain: "GameCenterActivitiesAPI.ChallengeImages", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
                )
            }
            try await GameCenterActivityAssetUpload.uploadChunks(
                client: client, operations: ops, fileData: data, progress: chunkProgress
            )
            return try await confirmUpload(id: reserved.id, md5Checksum: md5)
        }
    }

    // MARK: - gameCenterChallengeVersions

    /// Per-app-version snapshot of a challenge. Apple supports create + get
    /// only: no update, no delete.
    package struct ChallengeVersions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Version: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let live: Bool?
                package let versionState: String?
                package let createdDate: Date?
            }
        }

        package func list(
            challengeID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Version> {
            let resp: PageEnvelope<Version> = try await client.get(
                path: "gameCenterChallenges/\(challengeID)/gameCenterChallengeVersions",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Version>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Version? {
            struct Resp: Decodable { let data: Version }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterChallengeVersions/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            challengeID: String,
            appVersionID: String? = nil
        ) async throws -> Version {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterChallengeVersions"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct CRel: Encodable {
                        struct D: Encodable { let type = "gameCenterChallenges"; let id: String }
                        let data: D
                    }
                    struct AVRel: Encodable {
                        struct D: Encodable { let type = "gameCenterAppVersions"; let id: String }
                        let data: D
                    }
                    let gameCenterChallenge: CRel
                    var gameCenterAppVersion: AVRel?
                }
                let data: Data
            }
            let body = Body(data: .init(relationships: .init(
                gameCenterChallenge: .init(data: .init(id: challengeID)),
                gameCenterAppVersion: appVersionID.map { .init(data: .init(id: $0)) }
            )))
            struct Resp: Decodable { let data: Version }
            let resp: Resp = try await client.post(
                path: "gameCenterChallengeVersions", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - gameCenterAchievementVersions (V2)

    /// V2 versioning resource for achievements (spec v4.2). Creates a
    /// per-app-version snapshot of an achievement's config. Apple supports
    /// create + get only on this resource.
    package struct AchievementVersionsV2: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Version: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let live: Bool?
                package let versionState: String?
                package let createdDate: Date?
            }
        }

        package func list(
            achievementID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Version> {
            let resp: PageEnvelope<Version> = try await client.get(
                path: "gameCenterAchievements/\(achievementID)/gameCenterAchievementVersions",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Version>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Version? {
            struct Resp: Decodable { let data: Version }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterAchievementVersions/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            achievementID: String,
            appVersionID: String? = nil
        ) async throws -> Version {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterAchievementVersions"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct ARel: Encodable {
                        struct D: Encodable { let type = "gameCenterAchievements"; let id: String }
                        let data: D
                    }
                    struct AVRel: Encodable {
                        struct D: Encodable { let type = "gameCenterAppVersions"; let id: String }
                        let data: D
                    }
                    let gameCenterAchievement: ARel
                    var gameCenterAppVersion: AVRel?
                }
                let data: Data
            }
            let body = Body(data: .init(relationships: .init(
                gameCenterAchievement: .init(data: .init(id: achievementID)),
                gameCenterAppVersion: appVersionID.map { .init(data: .init(id: $0)) }
            )))
            struct Resp: Decodable { let data: Version }
            let resp: Resp = try await client.post(
                path: "gameCenterAchievementVersions", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - gameCenterLeaderboardVersions (V2)

    /// V2 versioning resource for leaderboards (spec v4.2). Creates a
    /// per-app-version snapshot of a leaderboard's config.
    package struct LeaderboardVersionsV2: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Version: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let live: Bool?
                package let versionState: String?
                package let createdDate: Date?
            }
        }

        package func list(
            leaderboardID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Version> {
            let resp: PageEnvelope<Version> = try await client.get(
                path: "gameCenterLeaderboards/\(leaderboardID)/gameCenterLeaderboardVersions",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Version>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Version? {
            struct Resp: Decodable { let data: Version }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardVersions/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            leaderboardID: String,
            appVersionID: String? = nil
        ) async throws -> Version {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardVersions"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct LRel: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboards"; let id: String }
                        let data: D
                    }
                    struct AVRel: Encodable {
                        struct D: Encodable { let type = "gameCenterAppVersions"; let id: String }
                        let data: D
                    }
                    let gameCenterLeaderboard: LRel
                    var gameCenterAppVersion: AVRel?
                }
                let data: Data
            }
            let body = Body(data: .init(relationships: .init(
                gameCenterLeaderboard: .init(data: .init(id: leaderboardID)),
                gameCenterAppVersion: appVersionID.map { .init(data: .init(id: $0)) }
            )))
            struct Resp: Decodable { let data: Version }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardVersions", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - gameCenterLeaderboardSetVersions (V2)

    /// V2 versioning resource for leaderboard sets (spec v4.2). Creates a
    /// per-app-version snapshot of a leaderboard set's config.
    package struct LeaderboardSetVersionsV2: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Version: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let live: Bool?
                package let versionState: String?
                package let createdDate: Date?
            }
        }

        package func list(
            leaderboardSetID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Version> {
            let resp: PageEnvelope<Version> = try await client.get(
                path: "gameCenterLeaderboardSets/\(leaderboardSetID)/gameCenterLeaderboardSetVersions",
                query: GameCenterActivitiesAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Version>.self
            )
            return GameCenterActivitiesAPI.wrapPage(resp)
        }

        package func get(id: String) async throws -> Version? {
            struct Resp: Decodable { let data: Version }
            do {
                let resp: Resp = try await client.get(
                    path: "gameCenterLeaderboardSetVersions/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        @discardableResult
        package func create(
            leaderboardSetID: String,
            appVersionID: String? = nil
        ) async throws -> Version {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardSetVersions"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct LSRel: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboardSets"; let id: String }
                        let data: D
                    }
                    struct AVRel: Encodable {
                        struct D: Encodable { let type = "gameCenterAppVersions"; let id: String }
                        let data: D
                    }
                    let gameCenterLeaderboardSet: LSRel
                    var gameCenterAppVersion: AVRel?
                }
                let data: Data
            }
            let body = Body(data: .init(relationships: .init(
                gameCenterLeaderboardSet: .init(data: .init(id: leaderboardSetID)),
                gameCenterAppVersion: appVersionID.map { .init(data: .init(id: $0)) }
            )))
            struct Resp: Decodable { let data: Version }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardSetVersions", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - gameCenterLeaderboardEntrySubmissions (test only)

    /// Sandbox-only score submission. POST a fake player score so QA can drive
    /// rendering and ranking flows without a real Game Center client. Apple
    /// only accepts create on this resource: no get, no update, no delete.
    /// Apple rejects calls outside the sandbox environment.
    package struct LeaderboardEntrySubmissions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Submission: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let score: String?
                package let context: String?
                package let submittedDate: Date?
            }
        }

        /// Submit a sandbox score for `leaderboardID` on behalf of
        /// `playerID`. Score is a stringified integer matching the
        /// leaderboard's submission type.
        @discardableResult
        package func create(
            leaderboardID: String,
            playerID: String,
            score: String,
            context: String? = nil
        ) async throws -> Submission {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterLeaderboardEntrySubmissions"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let score: String
                    var context: String?
                }
                struct Rels: Encodable {
                    struct LRel: Encodable {
                        struct D: Encodable { let type = "gameCenterLeaderboards"; let id: String }
                        let data: D
                    }
                    struct PRel: Encodable {
                        struct D: Encodable { let type = "gameCenterPlayers"; let id: String }
                        let data: D
                    }
                    let gameCenterLeaderboard: LRel
                    let gameCenterPlayer: PRel
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(score: score, context: context),
                relationships: .init(
                    gameCenterLeaderboard: .init(data: .init(id: leaderboardID)),
                    gameCenterPlayer: .init(data: .init(id: playerID))
                )
            ))
            struct Resp: Decodable { let data: Submission }
            let resp: Resp = try await client.post(
                path: "gameCenterLeaderboardEntrySubmissions", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - gameCenterPlayerAchievementSubmissions (test only)

    /// Sandbox-only achievement progress submission. POST a fake earn /
    /// progress event on behalf of a test player. Create-only, same
    /// restrictions as `LeaderboardEntrySubmissions`.
    package struct PlayerAchievementSubmissions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) { self.client = client }

        package struct Submission: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let percentComplete: Double?
                package let submittedDate: Date?
            }
        }

        /// Submit a sandbox achievement progress event. `percentComplete` of
        /// 100 marks the achievement earned.
        @discardableResult
        package func create(
            achievementID: String,
            playerID: String,
            percentComplete: Double
        ) async throws -> Submission {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "gameCenterPlayerAchievementSubmissions"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let percentComplete: Double
                }
                struct Rels: Encodable {
                    struct ARel: Encodable {
                        struct D: Encodable { let type = "gameCenterAchievements"; let id: String }
                        let data: D
                    }
                    struct PRel: Encodable {
                        struct D: Encodable { let type = "gameCenterPlayers"; let id: String }
                        let data: D
                    }
                    let gameCenterAchievement: ARel
                    let gameCenterPlayer: PRel
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(percentComplete: percentComplete),
                relationships: .init(
                    gameCenterAchievement: .init(data: .init(id: achievementID)),
                    gameCenterPlayer: .init(data: .init(id: playerID))
                )
            ))
            struct Resp: Decodable { let data: Submission }
            let resp: Resp = try await client.post(
                path: "gameCenterPlayerAchievementSubmissions", body: body, as: Resp.self
            )
            return resp.data
        }
    }
}
