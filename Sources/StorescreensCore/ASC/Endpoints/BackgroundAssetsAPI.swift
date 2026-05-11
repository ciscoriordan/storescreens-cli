import Foundation
import CryptoKit

/// App Store Connect endpoints for two related groups: (A) Background Assets
/// (Apple's 200GB-per-app post-install asset download mechanism, introduced
/// in OpenAPI spec v4.0, June 2025, with v4.1 additions in October 2025) and
/// (B) App Store Version Release Control (phased rollout management, editorial
/// promo carousel opt-in, manual release triggers, end-of-pre-order action).
///
/// The two groups ship together because they're complementary release-level
/// surfaces: Background Assets governs the bulky media that ships *alongside*
/// a version (downloaded after install so the app binary stays small), and
/// Release Control governs *when and how* the version itself reaches users.
/// In production workflows the same release engineer is typically toggling
/// both at the same point in the release timeline, which is why a single
/// `storescreens` parent wrapper keeps them adjacent.
///
/// Master struct exposes two nested namespaces (mirrors WebhooksAPI / TestFlightAPI):
///
///   let api = BackgroundAssetsAPI(client: client)
///   try await api.assets.backgroundAssets.list(appID: "12345")
///   try await api.releaseControl.phasedReleases.create(versionID: "67890")
///
/// Both namespaces share the same `ASCClient` and the same pagination /
/// cursor envelope, so they read consistently with the rest of the SDK.
///
/// Docs:
///   - Background Assets:
///     https://developer.apple.com/documentation/appstoreconnectapi/background_assets
///   - Version Release Control (phased releases, promotions, release requests):
///     https://developer.apple.com/documentation/appstoreconnectapi/app_store_version_phased_releases
package struct BackgroundAssetsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Nested namespaces

    /// Background Assets group: backgroundAssets + backgroundAssetVersions +
    /// backgroundAssetUploadFiles + the three read-only release-state resources
    /// (App Store, External Beta, Internal Beta).
    package var assets: Assets { Assets(client: client) }

    /// Version Release Control group: appStoreVersionPhasedReleases,
    /// appStoreVersionPromotions, appStoreVersionReleaseRequests, and
    /// endAppAvailabilityPreOrders.
    package var releaseControl: ReleaseControl { ReleaseControl(client: client) }

    // MARK: - Shared paged response shape

    /// Generic JSON:API page envelope. Mirrors WebhooksAPI.Page so cursor
    /// pagination behaves identically across the SDK.
    package struct Page<Item: Codable & Sendable>: Sendable {
        package let data: [Item]
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
        q["limit"] = String(min(max(limit, 1), 200))
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return q
    }

    // MARK: - Shared upload-operation shape

    /// Per-chunk upload instruction returned by ASC on a
    /// backgroundAssetUploadFile POST. Mirrors the shape used everywhere
    /// else in the SDK (screenshots, previews, buildUploadFiles): a method,
    /// pre-signed URL, byte offset + length, and the request headers
    /// Apple wants on the PUT.
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

    /// Free-form error envelope Apple attaches when a background asset upload
    /// surfaces a validation problem. Same struct shape buildUploads uses.
    package struct ErrorMessage: Codable, Sendable {
        package let code: String?
        package let message: String?
    }

    // MARK: - High-level: uploadBackgroundAssetFile

    /// Default per-read chunk size when hashing a file on disk. Background
    /// assets can be very large (Apple allows up to ~200GB per app across
    /// all versions), so we never load the file fully into memory. Apple's
    /// reservation dictates the per-chunk PUT length on each
    /// `uploadOperation`; we always honor that. This constant only governs
    /// the local MD5 streaming.
    package static let readChunkSize: Int = 4 * 1024 * 1024 // 4 MiB

    /// Aggregate result of a full chunked upload run. Wraps the committed
    /// `BackgroundAssetUploadFile`. Background assets can have many files
    /// per version (mirrors buildUploads' one-or-more-files semantics), so
    /// callers typically chain several of these for a single
    /// backgroundAssetVersion.
    package struct UploadFileResult: Sendable {
        package let file: Assets.BackgroundAssetUploadFile
    }

    /// Full create -> chunk-PUT -> commit workflow for a single
    /// background-asset file. Reads bytes from disk via `FileHandle` so
    /// multi-GB packs don't sit in memory.
    ///
    /// `progress` callback fires once per chunk PUT, with
    /// (bytesPutSoFar, totalBytes). Used by the CLI to stream progress to
    /// stderr while the upload runs.
    @discardableResult
    package func uploadBackgroundAssetFile(
        path: URL,
        versionID: String,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> UploadFileResult {
        // 1. Inspect the file on disk.
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw NSError(
                domain: "BackgroundAssetsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "file not found at \(path.path)"]
            )
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw NSError(
                domain: "BackgroundAssetsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "file at \(path.path) is empty"]
            )
        }
        let fileName = path.lastPathComponent
        let md5 = try Self.fileMD5Hex(path: path)

        // 2. Phase 1 — POST /backgroundAssetUploadFiles with the parent
        //    backgroundAssetVersion relationship + file metadata. Apple
        //    returns the per-chunk uploadOperations on the response.
        let reserved = try await assets.uploadFiles.create(
            versionID: versionID,
            fileName: fileName,
            fileSize: fileSize,
            sourceFileChecksum: md5
        )
        guard let operations = reserved.attributes?.uploadOperations,
              !operations.isEmpty else {
            throw NSError(
                domain: "BackgroundAssetsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "ASC returned no uploadOperations for backgroundAssetUploadFile \(reserved.id)"]
            )
        }

        // 3. Phase 2 — PUT each chunk to its signed URL. Streams from disk
        //    via FileHandle.
        try await Self.uploadChunks(
            client: client,
            operations: operations,
            filePath: path,
            totalBytes: fileSize,
            progress: progress
        )

        // 4. Phase 3 — PATCH commit. ASC validates the checksum + transitions
        //    state to UPLOADED, or surfaces errorMessages on rejection.
        let committed = try await assets.uploadFiles.commit(
            id: reserved.id,
            sourceFileChecksum: md5
        )
        return UploadFileResult(file: committed)
    }

    /// Push every chunk in `operations` to its pre-signed URL. Streams from
    /// disk via `FileHandle` so multi-GB packs don't live in RAM. Each
    /// chunk gets at most one retry on transient failures, mirroring the
    /// BuildUploadsAPI behavior.
    package static func uploadChunks(
        client: ASCClient,
        operations: [UploadOperation],
        filePath: URL,
        totalBytes: Int64,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        let handle = try FileHandle(forReadingFrom: filePath)
        defer { try? handle.close() }

        var bytesUploaded: Int64 = 0
        for op in operations {
            try handle.seek(toOffset: UInt64(op.offset))
            let chunk = try handle.read(upToCount: op.length) ?? Data()
            guard chunk.count == op.length else {
                throw NSError(
                    domain: "BackgroundAssetsAPI", code: -1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "short read at offset \(op.offset): got \(chunk.count) of \(op.length) bytes"]
                )
            }
            guard let url = URL(string: op.url) else {
                throw NSError(
                    domain: "BackgroundAssetsAPI", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid uploadOperation URL"]
                )
            }
            var headers: [String: String] = [:]
            for h in op.requestHeaders { headers[h.name] = h.value }

            // Retry-once on transient failure: Apple's S3 fronting
            // tolerates a re-PUT of the same chunk within a short window.
            do {
                try await client.putBinary(absoluteURL: url, headers: headers, body: chunk)
            } catch {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try await client.putBinary(absoluteURL: url, headers: headers, body: chunk)
            }
            bytesUploaded += Int64(op.length)
            progress?(bytesUploaded, totalBytes)
        }
    }

    /// Compute the hex-encoded MD5 of a file on disk without loading the
    /// whole file into memory. Apple validates this checksum on the PATCH
    /// commit and rejects the upload on mismatch.
    package static func fileMD5Hex(path: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while true {
            let chunk = try handle.read(upToCount: readChunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Nested: Assets

    /// Background Assets namespace. Wraps the six JSON:API resources Apple
    /// ships under the Background Assets feature: the parent
    /// `backgroundAssets` (one per app), `backgroundAssetVersions`
    /// (one logical asset release per version), `backgroundAssetUploadFiles`
    /// (the chunked-upload children), and the three read-only release-state
    /// records that surface the rollout state of a backgroundAssetVersion
    /// on each delivery channel (App Store, External Beta, Internal Beta).
    package struct Assets {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        // MARK: - Sub-namespaces

        /// backgroundAssets CRUD. The parent resource attached to an app.
        package var backgroundAssets: BackgroundAssets { BackgroundAssets(client: client) }

        /// backgroundAssetVersions create + get. One version per logical
        /// background-asset release.
        package var versions: Versions { Versions(client: client) }

        /// backgroundAssetUploadFiles create + get + update. The chunked
        /// upload child of a backgroundAssetVersion.
        package var uploadFiles: UploadFiles { UploadFiles(client: client) }

        /// backgroundAssetVersionAppStoreReleases — read-only release-state
        /// records for the App Store delivery channel (spec v4.1).
        package var appStoreReleases: AppStoreReleases { AppStoreReleases(client: client) }

        /// backgroundAssetVersionExternalBetaReleases — read-only
        /// release-state records for the External Beta delivery channel.
        package var externalBetaReleases: ExternalBetaReleases { ExternalBetaReleases(client: client) }

        /// backgroundAssetVersionInternalBetaReleases — read-only
        /// release-state records for the Internal Beta delivery channel.
        package var internalBetaReleases: InternalBetaReleases { InternalBetaReleases(client: client) }

        // MARK: - Shared models

        /// One `backgroundAsset` record. Apple ships one per app. Tracks
        /// the overall lifecycle state of the asset on each delivery channel
        /// plus the relationship to a `manifest` (the JSON document
        /// describing the asset's files and metadata).
        package struct BackgroundAsset: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?
            package let relationships: Relationships?

            package struct Attributes: Codable, Sendable {
                /// Internal beta delivery state, e.g.
                /// "AWAITING_REVIEW" / "APPROVED" / "REJECTED".
                package let internalBetaState: String?
                /// External (TestFlight) beta delivery state.
                package let externalBetaState: String?
                /// App Store delivery state.
                package let appStoreState: String?
                /// Most recent change Apple recorded on this asset (any
                /// version transition, manifest update, etc.).
                package let lastUpdated: Date?
            }

            package struct Relationships: Codable, Sendable {
                package let app: AppRel?
                package let manifest: ManifestRel?

                package struct AppRel: Codable, Sendable {
                    package let data: Ref?
                    package struct Ref: Codable, Sendable {
                        package let id: String
                        package let type: String
                    }
                }

                package struct ManifestRel: Codable, Sendable {
                    package let data: Ref?
                    package struct Ref: Codable, Sendable {
                        package let id: String
                        package let type: String
                    }
                }
            }
        }

        /// One `backgroundAssetVersion`. Apple ships one record per logical
        /// release of the background asset. Captures per-version delivery
        /// state plus the file list.
        package struct BackgroundAssetVersion: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?
            package let relationships: Relationships?

            package struct Attributes: Codable, Sendable {
                /// Internal beta delivery state for this version.
                package let internalBetaState: String?
                /// App Store delivery state for this version.
                package let appStoreState: String?
                /// Free-form version number Apple keeps around for the
                /// asset (independent of the app's marketing version).
                package let version: String?
                /// When Apple first accepted this version.
                package let createdDate: Date?
            }

            package struct Relationships: Codable, Sendable {
                package let backgroundAsset: BackgroundAssetRel?
                package let files: FilesRel?

                package struct BackgroundAssetRel: Codable, Sendable {
                    package let data: Ref?
                    package struct Ref: Codable, Sendable {
                        package let id: String
                        package let type: String
                    }
                }

                package struct FilesRel: Codable, Sendable {
                    package let data: [Ref]?
                    package struct Ref: Codable, Sendable {
                        package let id: String
                        package let type: String
                    }
                }
            }
        }

        /// One `backgroundAssetUploadFile`. Each entry is a chunked-upload
        /// target. Mirrors `buildUploadFiles` semantics: the POST response
        /// includes `uploadOperations`, the PUTs push bytes, the PATCH
        /// commits.
        package struct BackgroundAssetUploadFile: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int64?
                package let sourceFileChecksum: String?
                /// "AWAITING_UPLOAD", "UPLOADED" (after the PATCH commit),
                /// "INVALID" (per-file validation rejected the bytes).
                package let state: String?
                package let uploaded: Bool?
                /// Pre-signed chunk PUT URLs + headers + offsets + lengths.
                /// Populated on the POST create response.
                package let uploadOperations: [UploadOperation]?
                package let errorMessages: [ErrorMessage]?
            }
        }

        /// Read-only release-state record. Apple surfaces one of these per
        /// delivery channel (App Store, External Beta, Internal Beta) so
        /// callers can poll the rollout state of a `backgroundAssetVersion`
        /// without parsing the parent's aggregate state.
        package struct ReleaseRecord: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Channel-scoped state, e.g. "ACTIVE" / "INACTIVE" /
                /// "WAITING" / "FAILED". Apple's vocabulary varies per
                /// channel; we treat it as opaque-but-string.
                package let state: String?
                /// When this release became effective on the channel.
                package let releaseDate: Date?
            }
        }

        /// PATCH fields accepted on a backgroundAsset. Nil fields are
        /// omitted from the wire body so existing values stay untouched.
        /// Apple's editable surface is small here: typically just the
        /// per-channel state toggles when an asset is being moved between
        /// review states programmatically.
        package struct BackgroundAssetUpdateFields: Sendable, Equatable {
            package var internalBetaState: String?
            package var externalBetaState: String?
            package var appStoreState: String?

            package init(
                internalBetaState: String? = nil,
                externalBetaState: String? = nil,
                appStoreState: String? = nil
            ) {
                self.internalBetaState = internalBetaState
                self.externalBetaState = externalBetaState
                self.appStoreState = appStoreState
            }
        }

        // MARK: - backgroundAssets CRUD

        /// Wraps the `/backgroundAssets` resource. One per app.
        package struct BackgroundAssets {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            /// GET `/backgroundAssets` filtered by app id, paginated.
            package func list(
                appID: String,
                limit: Int = 200,
                cursor: String? = nil
            ) async throws -> Page<BackgroundAsset> {
                let query = BackgroundAssetsAPI.listQuery(
                    limit: limit,
                    cursor: cursor,
                    extras: ["filter[app]": appID]
                )
                let resp: PageEnvelope<BackgroundAsset> = try await client.get(
                    path: "backgroundAssets",
                    query: query,
                    as: PageEnvelope<BackgroundAsset>.self
                )
                return .init(
                    data: resp.data,
                    nextCursor: BackgroundAssetsAPI.extractCursor(from: resp.links?.next)
                )
            }

            /// GET `/apps/{id}/backgroundAssets` — relationship form, same
            /// data as the filter[app] list. Kept separate so callers can
            /// mirror Apple's URL exactly.
            package func listForApp(
                appID: String,
                limit: Int = 200,
                cursor: String? = nil
            ) async throws -> Page<BackgroundAsset> {
                let query = BackgroundAssetsAPI.listQuery(limit: limit, cursor: cursor)
                let resp: PageEnvelope<BackgroundAsset> = try await client.get(
                    path: "apps/\(appID)/backgroundAssets",
                    query: query,
                    as: PageEnvelope<BackgroundAsset>.self
                )
                return .init(
                    data: resp.data,
                    nextCursor: BackgroundAssetsAPI.extractCursor(from: resp.links?.next)
                )
            }

            /// GET `/backgroundAssets/{id}`. Returns nil on 404.
            package func get(id: String) async throws -> BackgroundAsset? {
                struct Resp: Decodable { let data: BackgroundAsset }
                do {
                    let resp: Resp = try await client.get(
                        path: "backgroundAssets/\(id)", as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.statusCode == 404 {
                    return nil
                }
            }

            /// POST `/backgroundAssets`. Creates the parent record on the
            /// given app. Apple allows at most one backgroundAsset per app
            /// at any time, so this 409s with `isAlreadySetConflict` when a
            /// record already exists.
            @discardableResult
            package func create(appID: String) async throws -> BackgroundAsset {
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "backgroundAssets"
                        let relationships: Rels
                    }
                    struct Rels: Encodable {
                        struct App: Encodable {
                            struct D: Encodable { let type = "apps"; let id: String }
                            let data: D
                        }
                        let app: App
                    }
                    let data: Data
                }
                let body = Body(data: .init(
                    relationships: .init(app: .init(data: .init(id: appID)))
                ))
                struct Resp: Decodable { let data: BackgroundAsset }
                do {
                    let resp: Resp = try await client.post(
                        path: "backgroundAssets", body: body, as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                    throw e
                }
            }

            /// PATCH `/backgroundAssets/{id}` with any non-nil fields.
            /// Apple's editable surface is small here (typically just the
            /// per-channel state toggles when staging an asset). Returns
            /// the updated resource.
            @discardableResult
            package func update(
                id: String,
                fields: BackgroundAssetUpdateFields
            ) async throws -> BackgroundAsset {
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "backgroundAssets"
                        let id: String
                        let attributes: Attrs
                    }
                    struct Attrs: Encodable {
                        var internalBetaState: String?
                        var externalBetaState: String?
                        var appStoreState: String?
                    }
                    let data: Data
                }
                let body = Body(data: .init(
                    id: id,
                    attributes: .init(
                        internalBetaState: fields.internalBetaState,
                        externalBetaState: fields.externalBetaState,
                        appStoreState: fields.appStoreState
                    )
                ))
                struct Resp: Decodable { let data: BackgroundAsset }
                let resp: Resp = try await client.patch(
                    path: "backgroundAssets/\(id)", body: body, as: Resp.self
                )
                return resp.data
            }

            /// DELETE `/backgroundAssets/{id}`. Removes the asset record
            /// and (cascades) every child version + file. Use with care.
            package func delete(id: String) async throws {
                try await client.delete(path: "backgroundAssets/\(id)")
            }
        }

        // MARK: - backgroundAssetVersions create + get

        /// Wraps the `/backgroundAssetVersions` resource. One version per
        /// logical release of the asset.
        package struct Versions {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            /// GET `/backgroundAssets/{id}/backgroundAssetVersions` —
            /// paginated list of every version on the parent asset.
            package func list(
                backgroundAssetID: String,
                limit: Int = 200,
                cursor: String? = nil
            ) async throws -> Page<BackgroundAssetVersion> {
                let query = BackgroundAssetsAPI.listQuery(limit: limit, cursor: cursor)
                let resp: PageEnvelope<BackgroundAssetVersion> = try await client.get(
                    path: "backgroundAssets/\(backgroundAssetID)/backgroundAssetVersions",
                    query: query,
                    as: PageEnvelope<BackgroundAssetVersion>.self
                )
                return .init(
                    data: resp.data,
                    nextCursor: BackgroundAssetsAPI.extractCursor(from: resp.links?.next)
                )
            }

            /// GET `/backgroundAssetVersions/{id}`. Returns nil on 404.
            package func get(id: String) async throws -> BackgroundAssetVersion? {
                struct Resp: Decodable { let data: BackgroundAssetVersion }
                do {
                    let resp: Resp = try await client.get(
                        path: "backgroundAssetVersions/\(id)", as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.statusCode == 404 {
                    return nil
                }
            }

            /// POST `/backgroundAssetVersions`. Creates a new version
            /// attached to an existing backgroundAsset. After creation,
            /// register one or more `backgroundAssetUploadFiles` and
            /// chunk-PUT the bytes.
            @discardableResult
            package func create(
                backgroundAssetID: String,
                version: String? = nil
            ) async throws -> BackgroundAssetVersion {
                struct Attrs: Encodable {
                    let version: String?
                }
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "backgroundAssetVersions"
                        let attributes: Attrs?
                        let relationships: Rels
                    }
                    struct Rels: Encodable {
                        struct BA: Encodable {
                            struct D: Encodable {
                                let type = "backgroundAssets"
                                let id: String
                            }
                            let data: D
                        }
                        let backgroundAsset: BA
                    }
                    let data: Data
                }
                let body = Body(data: .init(
                    attributes: version.map { Attrs(version: $0) },
                    relationships: .init(
                        backgroundAsset: .init(data: .init(id: backgroundAssetID))
                    )
                ))
                struct Resp: Decodable { let data: BackgroundAssetVersion }
                do {
                    let resp: Resp = try await client.post(
                        path: "backgroundAssetVersions", body: body, as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                    throw e
                }
            }
        }

        // MARK: - backgroundAssetUploadFiles CRUD-ish (create / get / update)

        /// Wraps the `/backgroundAssetUploadFiles` resource. Chunked-upload
        /// child of a `backgroundAssetVersion`. Mirrors `buildUploadFiles`:
        /// POST registers a file + size and returns `uploadOperations`,
        /// PUT each chunk to its signed URL, PATCH `uploaded:true` to
        /// commit.
        package struct UploadFiles {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            /// GET `/backgroundAssetVersions/{id}/backgroundAssetUploadFiles`
            /// — paginated list of every file on a version.
            package func list(
                versionID: String,
                limit: Int = 200,
                cursor: String? = nil
            ) async throws -> Page<BackgroundAssetUploadFile> {
                let query = BackgroundAssetsAPI.listQuery(limit: limit, cursor: cursor)
                let resp: PageEnvelope<BackgroundAssetUploadFile> = try await client.get(
                    path: "backgroundAssetVersions/\(versionID)/backgroundAssetUploadFiles",
                    query: query,
                    as: PageEnvelope<BackgroundAssetUploadFile>.self
                )
                return .init(
                    data: resp.data,
                    nextCursor: BackgroundAssetsAPI.extractCursor(from: resp.links?.next)
                )
            }

            /// GET `/backgroundAssetUploadFiles/{id}`. Returns nil on 404.
            package func get(id: String) async throws -> BackgroundAssetUploadFile? {
                struct Resp: Decodable { let data: BackgroundAssetUploadFile }
                do {
                    let resp: Resp = try await client.get(
                        path: "backgroundAssetUploadFiles/\(id)", as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.statusCode == 404 {
                    return nil
                }
            }

            /// POST `/backgroundAssetUploadFiles`. Reserves a chunked-upload
            /// target inside an existing `backgroundAssetVersion`. The
            /// response includes `uploadOperations` (signed PUT URLs).
            /// Optionally include a precomputed `sourceFileChecksum` (hex
            /// MD5) so Apple validates against the expected value before we
            /// PATCH commit.
            @discardableResult
            package func create(
                versionID: String,
                fileName: String,
                fileSize: Int64,
                sourceFileChecksum: String? = nil
            ) async throws -> BackgroundAssetUploadFile {
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "backgroundAssetUploadFiles"
                        let attributes: Attrs
                        let relationships: Rels
                    }
                    struct Attrs: Encodable {
                        let fileName: String
                        let fileSize: Int64
                        let sourceFileChecksum: String?
                    }
                    struct Rels: Encodable {
                        struct V: Encodable {
                            struct D: Encodable {
                                let type = "backgroundAssetVersions"
                                let id: String
                            }
                            let data: D
                        }
                        let backgroundAssetVersion: V
                    }
                    let data: Data
                }
                let body = Body(data: .init(
                    attributes: .init(
                        fileName: fileName,
                        fileSize: fileSize,
                        sourceFileChecksum: sourceFileChecksum
                    ),
                    relationships: .init(
                        backgroundAssetVersion: .init(data: .init(id: versionID))
                    )
                ))
                struct Resp: Decodable { let data: BackgroundAssetUploadFile }
                do {
                    let resp: Resp = try await client.post(
                        path: "backgroundAssetUploadFiles", body: body, as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                    throw e
                }
            }

            /// PATCH `/backgroundAssetUploadFiles/{id}` with `uploaded:true`
            /// + `sourceFileChecksum`. Run this after every chunk for the
            /// file has been PUT successfully. ASC validates the checksum
            /// and transitions state to `UPLOADED` (or surfaces
            /// `errorMessages` on rejection).
            @discardableResult
            package func commit(
                id: String,
                sourceFileChecksum: String
            ) async throws -> BackgroundAssetUploadFile {
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "backgroundAssetUploadFiles"
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
                    attributes: .init(uploaded: true, sourceFileChecksum: sourceFileChecksum)
                ))
                struct Resp: Decodable { let data: BackgroundAssetUploadFile }
                let resp: Resp = try await client.patch(
                    path: "backgroundAssetUploadFiles/\(id)", body: body, as: Resp.self
                )
                return resp.data
            }
        }

        // MARK: - Read-only release-state records (App Store / External / Internal)

        /// `backgroundAssetVersionAppStoreReleases` — read-only state for
        /// the App Store delivery channel (spec v4.1).
        package struct AppStoreReleases {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            /// GET `/backgroundAssetVersionAppStoreReleases/{id}`. Returns
            /// nil on 404.
            package func get(id: String) async throws -> ReleaseRecord? {
                struct Resp: Decodable { let data: ReleaseRecord }
                do {
                    let resp: Resp = try await client.get(
                        path: "backgroundAssetVersionAppStoreReleases/\(id)", as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.statusCode == 404 {
                    return nil
                }
            }
        }

        /// `backgroundAssetVersionExternalBetaReleases` — read-only state
        /// for the External Beta (TestFlight public-link) delivery channel.
        package struct ExternalBetaReleases {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            package func get(id: String) async throws -> ReleaseRecord? {
                struct Resp: Decodable { let data: ReleaseRecord }
                do {
                    let resp: Resp = try await client.get(
                        path: "backgroundAssetVersionExternalBetaReleases/\(id)", as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.statusCode == 404 {
                    return nil
                }
            }
        }

        /// `backgroundAssetVersionInternalBetaReleases` — read-only state
        /// for the Internal Beta (internal-tester) delivery channel.
        package struct InternalBetaReleases {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            package func get(id: String) async throws -> ReleaseRecord? {
                struct Resp: Decodable { let data: ReleaseRecord }
                do {
                    let resp: Resp = try await client.get(
                        path: "backgroundAssetVersionInternalBetaReleases/\(id)", as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.statusCode == 404 {
                    return nil
                }
            }
        }
    }

    // MARK: - Nested: ReleaseControl

    /// Version Release Control namespace. Wraps the four release-action
    /// resources Apple ships under the App Store Version surface:
    ///
    ///   - `appStoreVersionPhasedReleases`: start, pause/resume/expedite,
    ///     or revert a 7-day phased rollout.
    ///   - `appStoreVersionPromotions`: one-shot opt-in to App Store
    ///     editorial promo carousels.
    ///   - `appStoreVersionReleaseRequests`: the modern "release this
    ///     manually-released version now" action.
    ///   - `endAppAvailabilityPreOrders`: one-shot to end an app's
    ///     pre-order period early.
    ///
    /// Each resource maps to a different point in the release timeline; the
    /// shared parent (`appStoreVersion`, or `app` for pre-orders) is set
    /// by relationship at create time.
    package struct ReleaseControl {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        // MARK: - Sub-namespaces

        /// Phased releases CRUD: create / update (pause/resume/expedite) /
        /// delete (revert to immediate release).
        package var phasedReleases: PhasedReleases { PhasedReleases(client: client) }

        /// Version promotions: create-only opt-in to editorial promo
        /// carousels.
        package var promotions: Promotions { Promotions(client: client) }

        /// Version release requests: create-only manual release trigger.
        package var releaseRequests: ReleaseRequests { ReleaseRequests(client: client) }

        /// End pre-orders early: create-only action attached to an app.
        package var endPreOrders: EndPreOrders { EndPreOrders(client: client) }

        // MARK: - Shared models

        /// One `appStoreVersionPhasedRelease`. Apple maps the phased-release
        /// state machine to the `phasedReleaseState` attribute:
        ///   - INACTIVE: created but not yet rolled out
        ///   - ACTIVE: rollout in progress (7 day window)
        ///   - PAUSED: developer paused the rollout
        ///   - COMPLETE: rollout finished
        /// `currentDayNumber` tracks day 1-7 within the rollout.
        package struct PhasedRelease: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let phasedReleaseState: String?
                package let currentDayNumber: Int?
                package let startDate: Date?
                package let totalPauseDuration: Double?
            }
        }

        /// One `appStoreVersionPromotion`. Apple ships this as a one-shot
        /// opt-in record: creating it adds the version to the editorial
        /// promo carousel pool; there's no update or delete surface today.
        package struct Promotion: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let state: String?
                package let createdDate: Date?
            }
        }

        /// One `appStoreVersionReleaseRequest`. Apple ships this as a
        /// one-shot release trigger: creating it tells ASC to release the
        /// associated `appStoreVersion` (which must be a manual-release
        /// version in `PENDING_DEVELOPER_RELEASE`).
        package struct ReleaseRequest: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let state: String?
                package let createdDate: Date?
            }
        }

        /// One `endAppAvailabilityPreOrder`. Apple ships this as a one-shot
        /// action: creating it ends the pre-order period for the parent app
        /// immediately, transitioning customers from pre-order to
        /// purchase / install state.
        package struct EndPreOrder: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let state: String?
                package let createdDate: Date?
            }
        }

        // MARK: - appStoreVersionPhasedReleases

        /// Wraps the `/appStoreVersionPhasedReleases` resource. Manages the
        /// 7-day phased rollout for a version.
        package struct PhasedReleases {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            /// GET `/appStoreVersions/{id}/appStoreVersionPhasedRelease` —
            /// the relationship form. Apple ships at most one phased-release
            /// record per version, so this returns a single optional value.
            package func getForVersion(versionID: String) async throws -> PhasedRelease? {
                struct Resp: Decodable { let data: PhasedRelease }
                do {
                    let resp: Resp = try await client.get(
                        path: "appStoreVersions/\(versionID)/appStoreVersionPhasedRelease",
                        as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.statusCode == 404 {
                    return nil
                }
            }

            /// GET `/appStoreVersionPhasedReleases/{id}`. Returns nil on 404.
            package func get(id: String) async throws -> PhasedRelease? {
                struct Resp: Decodable { let data: PhasedRelease }
                do {
                    let resp: Resp = try await client.get(
                        path: "appStoreVersionPhasedReleases/\(id)", as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.statusCode == 404 {
                    return nil
                }
            }

            /// POST `/appStoreVersionPhasedReleases`. Starts a phased
            /// release on the parent version. ASC will begin the 7-day
            /// rollout once the version actually goes live; until then the
            /// record stays in `INACTIVE`.
            ///
            /// `phasedReleaseState` defaults to nil (Apple picks ACTIVE for
            /// most new records), but callers can pass it explicitly for
            /// edge cases.
            @discardableResult
            package func create(
                versionID: String,
                phasedReleaseState: String? = nil
            ) async throws -> PhasedRelease {
                struct Attrs: Encodable {
                    let phasedReleaseState: String?
                }
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "appStoreVersionPhasedReleases"
                        let attributes: Attrs?
                        let relationships: Rels
                    }
                    struct Rels: Encodable {
                        struct V: Encodable {
                            struct D: Encodable {
                                let type = "appStoreVersions"
                                let id: String
                            }
                            let data: D
                        }
                        let appStoreVersion: V
                    }
                    let data: Data
                }
                let body = Body(data: .init(
                    attributes: phasedReleaseState.map { Attrs(phasedReleaseState: $0) },
                    relationships: .init(appStoreVersion: .init(data: .init(id: versionID)))
                ))
                struct Resp: Decodable { let data: PhasedRelease }
                do {
                    let resp: Resp = try await client.post(
                        path: "appStoreVersionPhasedReleases", body: body, as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                    throw e
                }
            }

            /// PATCH `/appStoreVersionPhasedReleases/{id}` to change the
            /// rollout state. Apple uses three transitions on this
            /// attribute:
            ///   - PAUSED: developer pauses the rollout (no further users
            ///     get the version until resumed)
            ///   - ACTIVE: resume from PAUSED back to in-progress rollout
            ///   - COMPLETE: expedite the rollout immediately to 100%
            @discardableResult
            package func update(
                id: String,
                phasedReleaseState: String
            ) async throws -> PhasedRelease {
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "appStoreVersionPhasedReleases"
                        let id: String
                        let attributes: Attrs
                    }
                    struct Attrs: Encodable {
                        let phasedReleaseState: String
                    }
                    let data: Data
                }
                let body = Body(data: .init(
                    id: id,
                    attributes: .init(phasedReleaseState: phasedReleaseState)
                ))
                struct Resp: Decodable { let data: PhasedRelease }
                let resp: Resp = try await client.patch(
                    path: "appStoreVersionPhasedReleases/\(id)", body: body, as: Resp.self
                )
                return resp.data
            }

            /// DELETE `/appStoreVersionPhasedReleases/{id}`. Reverts the
            /// version to immediate release (the rollout never happens).
            /// Safe to call before the version actually goes live.
            package func delete(id: String) async throws {
                try await client.delete(path: "appStoreVersionPhasedReleases/\(id)")
            }
        }

        // MARK: - appStoreVersionPromotions (create only)

        /// Wraps the `/appStoreVersionPromotions` resource. One-shot opt-in
        /// to App Store editorial promo carousels.
        package struct Promotions {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            /// POST `/appStoreVersionPromotions`. Opts the parent version
            /// into editorial promo carousel consideration. Apple decides
            /// whether the version actually appears; this is a request to
            /// be considered, not a guarantee.
            @discardableResult
            package func create(versionID: String) async throws -> Promotion {
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "appStoreVersionPromotions"
                        let relationships: Rels
                    }
                    struct Rels: Encodable {
                        struct V: Encodable {
                            struct D: Encodable {
                                let type = "appStoreVersions"
                                let id: String
                            }
                            let data: D
                        }
                        let appStoreVersion: V
                    }
                    let data: Data
                }
                let body = Body(data: .init(
                    relationships: .init(appStoreVersion: .init(data: .init(id: versionID)))
                ))
                struct Resp: Decodable { let data: Promotion }
                do {
                    let resp: Resp = try await client.post(
                        path: "appStoreVersionPromotions", body: body, as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                    throw e
                }
            }
        }

        // MARK: - appStoreVersionReleaseRequests (create only)

        /// Wraps the `/appStoreVersionReleaseRequests` resource. Modern
        /// "release this manually-released version now" action.
        package struct ReleaseRequests {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            /// POST `/appStoreVersionReleaseRequests`. Triggers release of
            /// the parent version. The version must be in
            /// `PENDING_DEVELOPER_RELEASE` (manual release approved by
            /// Apple Review and waiting on the developer to publish). For
            /// auto-released versions, this 409s with
            /// `isAlreadySetConflict` since the version is already on its
            /// way out.
            @discardableResult
            package func create(versionID: String) async throws -> ReleaseRequest {
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "appStoreVersionReleaseRequests"
                        let relationships: Rels
                    }
                    struct Rels: Encodable {
                        struct V: Encodable {
                            struct D: Encodable {
                                let type = "appStoreVersions"
                                let id: String
                            }
                            let data: D
                        }
                        let appStoreVersion: V
                    }
                    let data: Data
                }
                let body = Body(data: .init(
                    relationships: .init(appStoreVersion: .init(data: .init(id: versionID)))
                ))
                struct Resp: Decodable { let data: ReleaseRequest }
                do {
                    let resp: Resp = try await client.post(
                        path: "appStoreVersionReleaseRequests", body: body, as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                    throw e
                }
            }
        }

        // MARK: - endAppAvailabilityPreOrders (create only)

        /// Wraps the `/endAppAvailabilityPreOrders` resource. One-shot to
        /// end an app's pre-order period early.
        package struct EndPreOrders {
            package let client: ASCClient

            package init(client: ASCClient) {
                self.client = client
            }

            /// POST `/endAppAvailabilityPreOrders`. Transitions the app
            /// from pre-order availability to live release immediately. The
            /// app must currently be in a pre-order availability state; if
            /// not, ASC 409s with `isAlreadySetConflict`.
            @discardableResult
            package func create(appID: String) async throws -> EndPreOrder {
                struct Body: Encodable {
                    struct Data: Encodable {
                        let type = "endAppAvailabilityPreOrders"
                        let relationships: Rels
                    }
                    struct Rels: Encodable {
                        struct A: Encodable {
                            struct D: Encodable {
                                let type = "apps"
                                let id: String
                            }
                            let data: D
                        }
                        let app: A
                    }
                    let data: Data
                }
                let body = Body(data: .init(
                    relationships: .init(app: .init(data: .init(id: appID)))
                ))
                struct Resp: Decodable { let data: EndPreOrder }
                do {
                    let resp: Resp = try await client.post(
                        path: "endAppAvailabilityPreOrders", body: body, as: Resp.self
                    )
                    return resp.data
                } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                    throw e
                }
            }
        }
    }
}
