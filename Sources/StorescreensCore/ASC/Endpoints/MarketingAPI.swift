import Foundation
import CryptoKit

// MARK: - Shared upload helper

/// Asset-reservation 3-phase upload, factored out of the marketing-surface
/// APIs that all share it (App Previews, App Event screenshots, App Event
/// video clips, Experiment screenshots, Experiment video clips). All ASC
/// asset endpoints follow the same shape:
///   1. POST creates the resource with `fileName` + `fileSize`. Apple
///      responds with `uploadOperations` containing pre-signed PUT URLs.
///   2. PUT each chunk to the URL Apple returned (offset/length slicing).
///   3. PATCH `uploaded: true` + `sourceFileChecksum` (hex MD5) to finalize.
///
/// Callers wrap this with their own resource-typed POST that returns the
/// `uploadOperations` array, then call `uploadChunks` + `finalize` here.
package enum MarketingAssetUpload {

    /// Per-chunk upload instruction returned by ASC on the reservation POST.
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

    /// Phase 2 — push each pre-signed chunk to its URL. `fileData` is the
    /// whole file; we slice by offset+length per operation. Order matters
    /// only insofar as Apple needs all chunks present before the PATCH;
    /// the chunks themselves are independent.
    package static func uploadChunks(
        client: ASCClient,
        operations: [UploadOperation],
        fileData: Data,
        progress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws {
        for (index, op) in operations.enumerated() {
            guard let url = URL(string: op.url) else {
                throw NSError(
                    domain: "MarketingAssetUpload",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid uploadOperation URL"]
                )
            }
            let end = op.offset + op.length
            guard end <= fileData.count else {
                throw NSError(
                    domain: "MarketingAssetUpload",
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

    /// Apple's sourceFileChecksum is hex-encoded MD5 of the file bytes.
    /// Same as ScreenshotsAPI; reused so call sites in this file don't have
    /// to depend on the screenshots module.
    package static func md5Hex(data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - App Previews

/// App Store Connect endpoints for app preview videos (the short clips that
/// appear before screenshots in the App Store carousel). Mirrors the
/// screenshots-set + screenshot pattern: each (locale, deviceType) has at
/// most one `appPreviewSet`, and each set holds up to three `appPreview`
/// videos. Upload is the 3-phase reservation flow defined above.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/app_previews
package struct AppPreviewsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: Preview sets

    package struct PreviewSet: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// e.g. "APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129". Note these
            /// are `previewType` values (Apple keeps a separate enum from
            /// the screenshot displayType set).
            package let previewType: String?
        }
    }

    package func listPreviewSets(localizationID: String) async throws -> [PreviewSet] {
        struct Resp: Decodable { let data: [PreviewSet] }
        let resp: Resp = try await client.get(
            path: "appStoreVersionLocalizations/\(localizationID)/appPreviewSets",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func createPreviewSet(
        localizationID: String,
        previewType: String
    ) async throws -> PreviewSet {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appPreviewSets"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable { let previewType: String }
            struct Rels: Encodable {
                struct L: Encodable {
                    struct Data: Encodable {
                        let type = "appStoreVersionLocalizations"
                        let id: String
                    }
                    let data: Data
                }
                let appStoreVersionLocalization: L
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(previewType: previewType),
            relationships: .init(
                appStoreVersionLocalization: .init(data: .init(id: localizationID))
            )
        ))
        struct Resp: Decodable { let data: PreviewSet }
        let resp: Resp = try await client.post(
            path: "appPreviewSets", body: body, as: Resp.self
        )
        return resp.data
    }

    package func findOrCreatePreviewSet(
        localizationID: String,
        previewType: String
    ) async throws -> PreviewSet {
        let sets = try await listPreviewSets(localizationID: localizationID)
        if let existing = sets.first(where: { $0.attributes?.previewType == previewType }) {
            return existing
        }
        return try await createPreviewSet(
            localizationID: localizationID, previewType: previewType
        )
    }

    package func deletePreviewSet(id: String) async throws {
        try await client.delete(path: "appPreviewSets/\(id)")
    }

    // MARK: Previews (videos inside a set)

    package struct Preview: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let fileSize: Int?
            package let fileName: String?
            package let sourceFileChecksum: String?
            package let previewFrameTimeCode: String?
            package let mimeType: String?
            package let videoUrl: String?
            package let previewImage: PreviewImage?
            package let uploadOperations: [MarketingAssetUpload.UploadOperation]?
            package let assetDeliveryState: AssetDeliveryState?
        }

        package struct PreviewImage: Codable, Sendable {
            package let templateUrl: String?
            package let width: Int?
            package let height: Int?
        }

        package struct AssetDeliveryState: Codable, Sendable {
            package let state: String?
        }
    }

    package func listPreviews(setID: String) async throws -> [Preview] {
        struct Resp: Decodable { let data: [Preview] }
        let resp: Resp = try await client.get(
            path: "appPreviewSets/\(setID)/appPreviews",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func deletePreview(id: String) async throws {
        try await client.delete(path: "appPreviews/\(id)")
    }

    /// Phase 1 — reserve. Returns the preview with `uploadOperations`.
    package func reservePreview(
        setID: String,
        fileName: String,
        fileSize: Int,
        mimeType: String? = nil
    ) async throws -> Preview {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appPreviews"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let fileSize: Int
                let fileName: String
                let mimeType: String?
            }
            struct Rels: Encodable {
                struct Set: Encodable {
                    struct Data: Encodable { let type = "appPreviewSets"; let id: String }
                    let data: Data
                }
                let appPreviewSet: Set
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(fileSize: fileSize, fileName: fileName, mimeType: mimeType),
            relationships: .init(appPreviewSet: .init(data: .init(id: setID)))
        ))
        struct Resp: Decodable { let data: Preview }
        let resp: Resp = try await client.post(
            path: "appPreviews", body: body, as: Resp.self
        )
        return resp.data
    }

    /// Phase 3 — finalize. PATCH `uploaded: true` + checksum.
    @discardableResult
    package func confirmPreviewUpload(
        previewID: String,
        md5Checksum: String,
        previewFrameTimeCode: String? = nil
    ) async throws -> Preview {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appPreviews"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let uploaded: Bool
                let sourceFileChecksum: String
                let previewFrameTimeCode: String?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: previewID,
            attributes: .init(
                uploaded: true,
                sourceFileChecksum: md5Checksum,
                previewFrameTimeCode: previewFrameTimeCode
            )
        ))
        struct Resp: Decodable { let data: Preview }
        let resp: Resp = try await client.patch(
            path: "appPreviews/\(previewID)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// All three phases. `mimeType` should be the actual video MIME (Apple
    /// accepts "video/mp4", "video/quicktime", etc.). `previewFrameTimeCode`
    /// is an HH:MM:SS.mmm timestamp Apple uses for the poster frame.
    @discardableResult
    package func uploadPreview(
        setID: String,
        fileURL: URL,
        mimeType: String? = nil,
        previewFrameTimeCode: String? = nil,
        chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Preview {
        let data = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        let md5 = MarketingAssetUpload.md5Hex(data: data)

        let reserved = try await reservePreview(
            setID: setID,
            fileName: fileName,
            fileSize: data.count,
            mimeType: mimeType
        )
        guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
            throw NSError(
                domain: "AppPreviewsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
            )
        }
        try await MarketingAssetUpload.uploadChunks(
            client: client, operations: ops, fileData: data, progress: chunkProgress
        )
        return try await confirmPreviewUpload(
            previewID: reserved.id,
            md5Checksum: md5,
            previewFrameTimeCode: previewFrameTimeCode
        )
    }
}

// MARK: - App Clips

/// App Store Connect endpoints for App Clips. Each app can have at most one
/// primary `appClip`, which in turn holds default + advanced experiences,
/// a header image, and review notes.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/app_clips
package struct AppClipsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: AppClip resource

    package struct AppClip: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let bundleId: String?
        }
    }

    /// Lists `appClips` belonging to an app. Apple constrains this to a
    /// single clip per app today, but the relationship is one-to-many in
    /// the schema, so we still return an array.
    package func listAppClips(appID: String) async throws -> [AppClip] {
        struct Resp: Decodable { let data: [AppClip] }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/appClips",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func getAppClip(id: String) async throws -> AppClip? {
        struct Resp: Decodable { let data: AppClip }
        do {
            let resp: Resp = try await client.get(
                path: "appClips/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Creates a new appClip resource attached to an app, with a chosen
    /// bundle id (must be a child of the app's bundle id, e.g.
    /// "com.example.app.Clip").
    package func createAppClip(appID: String, bundleID: String) async throws -> AppClip {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClips"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable { let bundleId: String }
            struct Rels: Encodable {
                struct A: Encodable {
                    struct Data: Encodable { let type = "apps"; let id: String }
                    let data: Data
                }
                let app: A
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(bundleId: bundleID),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: AppClip }
        let resp: Resp = try await client.post(
            path: "appClips", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: Default experiences

    package struct DefaultExperience: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// The "Clip" version that gets surfaced when no advanced
            /// experience matches a URL. Apple represents the action verb
            /// in `action` ("OPEN", "VIEW", "PLAY"). Nil while ASC is still
            /// materializing the record.
            package let action: String?
        }
    }

    package func listDefaultExperiences(appClipID: String) async throws -> [DefaultExperience] {
        struct Resp: Decodable { let data: [DefaultExperience] }
        let resp: Resp = try await client.get(
            path: "appClips/\(appClipID)/appClipDefaultExperiences",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func createDefaultExperience(
        appClipID: String,
        action: String? = nil
    ) async throws -> DefaultExperience {
        struct Attrs: Encodable { let action: String? }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipDefaultExperiences"
                let attributes: Attrs?
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct C: Encodable {
                    struct Data: Encodable { let type = "appClips"; let id: String }
                    let data: Data
                }
                let appClip: C
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: action.map { Attrs(action: $0) },
            relationships: .init(appClip: .init(data: .init(id: appClipID)))
        ))
        struct Resp: Decodable { let data: DefaultExperience }
        let resp: Resp = try await client.post(
            path: "appClipDefaultExperiences", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateDefaultExperience(
        id: String,
        action: String?
    ) async throws -> DefaultExperience {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipDefaultExperiences"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { let action: String? }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: .init(action: action)))
        struct Resp: Decodable { let data: DefaultExperience }
        let resp: Resp = try await client.patch(
            path: "appClipDefaultExperiences/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteDefaultExperience(id: String) async throws {
        try await client.delete(path: "appClipDefaultExperiences/\(id)")
    }

    // MARK: Default experience localizations

    package struct DefaultExperienceLocalization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let locale: String?
            package let subtitle: String?
        }
    }

    package func listDefaultExperienceLocalizations(
        experienceID: String
    ) async throws -> [DefaultExperienceLocalization] {
        struct Resp: Decodable { let data: [DefaultExperienceLocalization] }
        let resp: Resp = try await client.get(
            path: "appClipDefaultExperiences/\(experienceID)/appClipDefaultExperienceLocalizations",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    package func createDefaultExperienceLocalization(
        experienceID: String,
        locale: String,
        subtitle: String? = nil
    ) async throws -> DefaultExperienceLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipDefaultExperienceLocalizations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let locale: String
                let subtitle: String?
            }
            struct Rels: Encodable {
                struct E: Encodable {
                    struct Data: Encodable {
                        let type = "appClipDefaultExperiences"
                        let id: String
                    }
                    let data: Data
                }
                let appClipDefaultExperience: E
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(locale: locale, subtitle: subtitle),
            relationships: .init(appClipDefaultExperience: .init(data: .init(id: experienceID)))
        ))
        struct Resp: Decodable { let data: DefaultExperienceLocalization }
        let resp: Resp = try await client.post(
            path: "appClipDefaultExperienceLocalizations", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateDefaultExperienceLocalization(
        id: String,
        subtitle: String?
    ) async throws -> DefaultExperienceLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipDefaultExperienceLocalizations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { let subtitle: String? }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: .init(subtitle: subtitle)))
        struct Resp: Decodable { let data: DefaultExperienceLocalization }
        let resp: Resp = try await client.patch(
            path: "appClipDefaultExperienceLocalizations/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteDefaultExperienceLocalization(id: String) async throws {
        try await client.delete(path: "appClipDefaultExperienceLocalizations/\(id)")
    }

    // MARK: Advanced experiences

    package struct AdvancedExperience: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let action: String?
            package let isPoweredBy: Bool?
            package let link: String?
            package let place: Place?
            package let status: String?
            package let version: Int?

            package struct Place: Codable, Sendable {
                package let placeId: String?
                package let names: [String]?
            }
        }
    }

    package func listAdvancedExperiences(appClipID: String) async throws -> [AdvancedExperience] {
        struct Resp: Decodable { let data: [AdvancedExperience] }
        let resp: Resp = try await client.get(
            path: "appClips/\(appClipID)/appClipAdvancedExperiences",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    package func createAdvancedExperience(
        appClipID: String,
        link: String,
        action: String? = nil,
        isPoweredBy: Bool? = nil
    ) async throws -> AdvancedExperience {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipAdvancedExperiences"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let link: String
                let action: String?
                let isPoweredBy: Bool?
            }
            struct Rels: Encodable {
                struct C: Encodable {
                    struct Data: Encodable { let type = "appClips"; let id: String }
                    let data: Data
                }
                let appClip: C
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(link: link, action: action, isPoweredBy: isPoweredBy),
            relationships: .init(appClip: .init(data: .init(id: appClipID)))
        ))
        struct Resp: Decodable { let data: AdvancedExperience }
        let resp: Resp = try await client.post(
            path: "appClipAdvancedExperiences", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateAdvancedExperience(
        id: String,
        link: String? = nil,
        action: String? = nil,
        isPoweredBy: Bool? = nil
    ) async throws -> AdvancedExperience {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipAdvancedExperiences"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let link: String?
                let action: String?
                let isPoweredBy: Bool?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(link: link, action: action, isPoweredBy: isPoweredBy)
        ))
        struct Resp: Decodable { let data: AdvancedExperience }
        let resp: Resp = try await client.patch(
            path: "appClipAdvancedExperiences/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteAdvancedExperience(id: String) async throws {
        try await client.delete(path: "appClipAdvancedExperiences/\(id)")
    }

    // MARK: Advanced experience localizations

    package struct AdvancedExperienceLocalization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let language: String?
            package let title: String?
            package let subtitle: String?
        }
    }

    package func listAdvancedExperienceLocalizations(
        experienceID: String
    ) async throws -> [AdvancedExperienceLocalization] {
        struct Resp: Decodable { let data: [AdvancedExperienceLocalization] }
        let resp: Resp = try await client.get(
            path: "appClipAdvancedExperiences/\(experienceID)/appClipAdvancedExperienceLocalizations",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    package func createAdvancedExperienceLocalization(
        experienceID: String,
        language: String,
        title: String? = nil,
        subtitle: String? = nil
    ) async throws -> AdvancedExperienceLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipAdvancedExperienceLocalizations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let language: String
                let title: String?
                let subtitle: String?
            }
            struct Rels: Encodable {
                struct E: Encodable {
                    struct Data: Encodable {
                        let type = "appClipAdvancedExperiences"
                        let id: String
                    }
                    let data: Data
                }
                let appClipAdvancedExperience: E
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(language: language, title: title, subtitle: subtitle),
            relationships: .init(appClipAdvancedExperience: .init(data: .init(id: experienceID)))
        ))
        struct Resp: Decodable { let data: AdvancedExperienceLocalization }
        let resp: Resp = try await client.post(
            path: "appClipAdvancedExperienceLocalizations", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateAdvancedExperienceLocalization(
        id: String,
        title: String? = nil,
        subtitle: String? = nil
    ) async throws -> AdvancedExperienceLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipAdvancedExperienceLocalizations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let title: String?
                let subtitle: String?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: .init(title: title, subtitle: subtitle)
        ))
        struct Resp: Decodable { let data: AdvancedExperienceLocalization }
        let resp: Resp = try await client.patch(
            path: "appClipAdvancedExperienceLocalizations/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteAdvancedExperienceLocalization(id: String) async throws {
        try await client.delete(path: "appClipAdvancedExperienceLocalizations/\(id)")
    }

    // MARK: Review details

    package struct AppStoreReviewDetail: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let invocationUrls: [String]?
        }
    }

    package func getReviewDetail(experienceID: String) async throws -> AppStoreReviewDetail? {
        struct Resp: Decodable {
            struct DataObj: Decodable {
                let id: String
                let attributes: AppStoreReviewDetail.Attributes?
            }
            let data: DataObj?
        }
        do {
            let resp: Resp = try await client.get(
                path: "appClipDefaultExperiences/\(experienceID)/appClipAppStoreReviewDetail",
                as: Resp.self
            )
            guard let d = resp.data else { return nil }
            return AppStoreReviewDetail(id: d.id, attributes: d.attributes)
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    @discardableResult
    package func updateReviewDetail(
        id: String,
        invocationUrls: [String]?
    ) async throws -> AppStoreReviewDetail {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipAppStoreReviewDetails"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { let invocationUrls: [String]? }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: .init(invocationUrls: invocationUrls)
        ))
        struct Resp: Decodable { let data: AppStoreReviewDetail }
        let resp: Resp = try await client.patch(
            path: "appClipAppStoreReviewDetails/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: Header images

    /// The header image (sometimes shown at the top of an App Clip card).
    /// Uploaded via the same 3-phase pattern as previews/screenshots.
    package struct Header: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let fileSize: Int?
            package let fileName: String?
            package let imageAsset: ImageAsset?
            package let uploadOperations: [MarketingAssetUpload.UploadOperation]?
            package let uploaded: Bool?
            package let sourceFileChecksum: String?
        }

        package struct ImageAsset: Codable, Sendable {
            package let templateUrl: String?
            package let width: Int?
            package let height: Int?
        }
    }

    package func listHeaders(experienceLocalizationID: String) async throws -> [Header] {
        struct Resp: Decodable { let data: [Header] }
        let resp: Resp = try await client.get(
            path: "appClipDefaultExperienceLocalizations/\(experienceLocalizationID)/appClipHeaderImage",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func reserveHeader(
        experienceLocalizationID: String,
        fileName: String,
        fileSize: Int
    ) async throws -> Header {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipHeaderImages"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let fileSize: Int
                let fileName: String
            }
            struct Rels: Encodable {
                struct L: Encodable {
                    struct Data: Encodable {
                        let type = "appClipDefaultExperienceLocalizations"
                        let id: String
                    }
                    let data: Data
                }
                let appClipDefaultExperienceLocalization: L
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(fileSize: fileSize, fileName: fileName),
            relationships: .init(
                appClipDefaultExperienceLocalization: .init(data: .init(id: experienceLocalizationID))
            )
        ))
        struct Resp: Decodable { let data: Header }
        let resp: Resp = try await client.post(
            path: "appClipHeaderImages", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func confirmHeaderUpload(
        headerID: String,
        md5Checksum: String
    ) async throws -> Header {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appClipHeaderImages"
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
            id: headerID,
            attributes: .init(uploaded: true, sourceFileChecksum: md5Checksum)
        ))
        struct Resp: Decodable { let data: Header }
        let resp: Resp = try await client.patch(
            path: "appClipHeaderImages/\(headerID)", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func uploadHeader(
        experienceLocalizationID: String,
        fileURL: URL,
        chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Header {
        let data = try Data(contentsOf: fileURL)
        let md5 = MarketingAssetUpload.md5Hex(data: data)
        let reserved = try await reserveHeader(
            experienceLocalizationID: experienceLocalizationID,
            fileName: fileURL.lastPathComponent,
            fileSize: data.count
        )
        guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
            throw NSError(
                domain: "AppClipsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
            )
        }
        try await MarketingAssetUpload.uploadChunks(
            client: client, operations: ops, fileData: data, progress: chunkProgress
        )
        return try await confirmHeaderUpload(headerID: reserved.id, md5Checksum: md5)
    }

    package func deleteHeader(id: String) async throws {
        try await client.delete(path: "appClipHeaderImages/\(id)")
    }
}

// MARK: - Custom Product Pages

/// App Store Connect endpoints for custom product pages (up to 35 alternate
/// product page variants per app, each with their own screenshots / preview
/// videos / promo text — used to A/B different campaign landing experiences).
/// Each `appCustomProductPage` has one editable + zero-or-more historical
/// `appCustomProductPageVersions`. Each version has per-locale
/// `appCustomProductPageLocalizations` that hold the screenshot sets +
/// promo text overrides for that page variant.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/custom_product_pages
package struct CustomProductPagesAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: Pages

    package struct Page: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let name: String?
            package let visible: Bool?
            package let url: String?
        }
    }

    package func listPages(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (pages: [Page], nextCursor: String?) {
        struct Resp: Decodable {
            let data: [Page]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        var query: [String: String] = ["limit": "\(limit)"]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/appCustomProductPages",
            query: query, as: Resp.self
        )
        return (resp.data, resp.links?.next)
    }

    package func getPage(id: String) async throws -> Page? {
        struct Resp: Decodable { let data: Page }
        do {
            let resp: Resp = try await client.get(
                path: "appCustomProductPages/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    package func createPage(
        appID: String,
        name: String,
        visible: Bool = true
    ) async throws -> Page {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appCustomProductPages"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let name: String
                let visible: Bool
            }
            struct Rels: Encodable {
                struct A: Encodable {
                    struct Data: Encodable { let type = "apps"; let id: String }
                    let data: Data
                }
                let app: A
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(name: name, visible: visible),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: Page }
        let resp: Resp = try await client.post(
            path: "appCustomProductPages", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updatePage(
        id: String,
        name: String? = nil,
        visible: Bool? = nil
    ) async throws -> Page {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appCustomProductPages"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let name: String?
                let visible: Bool?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: .init(name: name, visible: visible)
        ))
        struct Resp: Decodable { let data: Page }
        let resp: Resp = try await client.patch(
            path: "appCustomProductPages/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deletePage(id: String) async throws {
        try await client.delete(path: "appCustomProductPages/\(id)")
    }

    // MARK: Versions

    package struct Version: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let state: String?
            package let version: Int?
        }
    }

    package func listVersions(
        pageID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (versions: [Version], nextCursor: String?) {
        struct Resp: Decodable {
            let data: [Version]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        var query: [String: String] = ["limit": "\(limit)"]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "appCustomProductPages/\(pageID)/customProductPageVersions",
            query: query, as: Resp.self
        )
        return (resp.data, resp.links?.next)
    }

    package func createVersion(pageID: String) async throws -> Version {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appCustomProductPageVersions"
                let relationships: Rels
            }
            struct Rels: Encodable {
                struct P: Encodable {
                    struct Data: Encodable { let type = "appCustomProductPages"; let id: String }
                    let data: Data
                }
                let customProductPage: P
            }
            let data: Data
        }
        let body = Body(data: .init(
            relationships: .init(customProductPage: .init(data: .init(id: pageID)))
        ))
        struct Resp: Decodable { let data: Version }
        let resp: Resp = try await client.post(
            path: "appCustomProductPageVersions", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteVersion(id: String) async throws {
        try await client.delete(path: "appCustomProductPageVersions/\(id)")
    }

    // MARK: Localizations

    package struct Localization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let locale: String?
            package let promotionalText: String?
        }
    }

    package func listLocalizations(
        versionID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (localizations: [Localization], nextCursor: String?) {
        struct Resp: Decodable {
            let data: [Localization]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        var query: [String: String] = ["limit": "\(limit)"]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "appCustomProductPageVersions/\(versionID)/customProductPageLocalizations",
            query: query, as: Resp.self
        )
        return (resp.data, resp.links?.next)
    }

    package func createLocalization(
        versionID: String,
        locale: String,
        promotionalText: String? = nil
    ) async throws -> Localization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appCustomProductPageLocalizations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let locale: String
                let promotionalText: String?
            }
            struct Rels: Encodable {
                struct V: Encodable {
                    struct Data: Encodable {
                        let type = "appCustomProductPageVersions"
                        let id: String
                    }
                    let data: Data
                }
                let customProductPageVersion: V
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(locale: locale, promotionalText: promotionalText),
            relationships: .init(customProductPageVersion: .init(data: .init(id: versionID)))
        ))
        struct Resp: Decodable { let data: Localization }
        let resp: Resp = try await client.post(
            path: "appCustomProductPageLocalizations", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateLocalization(
        id: String,
        promotionalText: String?
    ) async throws -> Localization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appCustomProductPageLocalizations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable { let promotionalText: String? }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: .init(promotionalText: promotionalText)
        ))
        struct Resp: Decodable { let data: Localization }
        let resp: Resp = try await client.patch(
            path: "appCustomProductPageLocalizations/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteLocalization(id: String) async throws {
        try await client.delete(path: "appCustomProductPageLocalizations/\(id)")
    }
}

// MARK: - App Events

/// App Store Connect endpoints for App Events (in-app events shown on the
/// App Store — tournaments, premieres, new content drops). Each `appEvent`
/// has per-locale `appEventLocalizations` plus `appEventScreenshots` and
/// `appEventVideoClips` (both uploaded via the 3-phase reservation flow).
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/app_events
package struct AppEventsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: Events

    package struct AppEvent: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let referenceName: String?
            package let badge: String?
            package let deepLink: String?
            package let purchaseRequirement: String?
            package let primaryLocale: String?
            package let priority: String?
            package let purpose: String?
            package let territorySchedules: [TerritorySchedule]?
            package let eventState: String?
            package let publishStart: Date?
            package let eventStart: Date?
            package let eventEnd: Date?

            package struct TerritorySchedule: Codable, Sendable {
                package let territories: [String]?
                package let publishStart: Date?
                package let eventStart: Date?
                package let eventEnd: Date?
            }
        }
    }

    package func listAppEvents(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (events: [AppEvent], nextCursor: String?) {
        struct Resp: Decodable {
            let data: [AppEvent]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        var query: [String: String] = ["limit": "\(limit)"]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/appEvents",
            query: query, as: Resp.self
        )
        return (resp.data, resp.links?.next)
    }

    package func getAppEvent(id: String) async throws -> AppEvent? {
        struct Resp: Decodable { let data: AppEvent }
        do {
            let resp: Resp = try await client.get(
                path: "appEvents/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Fields shared between create and update. All optional — only non-nil
    /// values are PATCHed onto ASC. Mirrors the AppStoreReviewDetail pattern
    /// in AppsAPI.swift for the same reason: keeps unchanged attributes
    /// untouched.
    package struct EventFields: Sendable {
        package var referenceName: String?
        package var badge: String?
        package var deepLink: String?
        package var purchaseRequirement: String?
        package var primaryLocale: String?
        package var priority: String?
        package var purpose: String?
        package var territorySchedules: [AppEvent.Attributes.TerritorySchedule]?

        package init(
            referenceName: String? = nil,
            badge: String? = nil,
            deepLink: String? = nil,
            purchaseRequirement: String? = nil,
            primaryLocale: String? = nil,
            priority: String? = nil,
            purpose: String? = nil,
            territorySchedules: [AppEvent.Attributes.TerritorySchedule]? = nil
        ) {
            self.referenceName = referenceName
            self.badge = badge
            self.deepLink = deepLink
            self.purchaseRequirement = purchaseRequirement
            self.primaryLocale = primaryLocale
            self.priority = priority
            self.purpose = purpose
            self.territorySchedules = territorySchedules
        }
    }

    package func createAppEvent(
        appID: String,
        fields: EventFields
    ) async throws -> AppEvent {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEvents"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let referenceName: String?
                let badge: String?
                let deepLink: String?
                let purchaseRequirement: String?
                let primaryLocale: String?
                let priority: String?
                let purpose: String?
                let territorySchedules: [AppEvent.Attributes.TerritorySchedule]?
            }
            struct Rels: Encodable {
                struct A: Encodable {
                    struct Data: Encodable { let type = "apps"; let id: String }
                    let data: Data
                }
                let app: A
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(
                referenceName: fields.referenceName,
                badge: fields.badge,
                deepLink: fields.deepLink,
                purchaseRequirement: fields.purchaseRequirement,
                primaryLocale: fields.primaryLocale,
                priority: fields.priority,
                purpose: fields.purpose,
                territorySchedules: fields.territorySchedules
            ),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: AppEvent }
        let resp: Resp = try await client.post(
            path: "appEvents", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateAppEvent(
        id: String,
        fields: EventFields
    ) async throws -> AppEvent {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEvents"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let referenceName: String?
                let badge: String?
                let deepLink: String?
                let purchaseRequirement: String?
                let primaryLocale: String?
                let priority: String?
                let purpose: String?
                let territorySchedules: [AppEvent.Attributes.TerritorySchedule]?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(
                referenceName: fields.referenceName,
                badge: fields.badge,
                deepLink: fields.deepLink,
                purchaseRequirement: fields.purchaseRequirement,
                primaryLocale: fields.primaryLocale,
                priority: fields.priority,
                purpose: fields.purpose,
                territorySchedules: fields.territorySchedules
            )
        ))
        struct Resp: Decodable { let data: AppEvent }
        let resp: Resp = try await client.patch(
            path: "appEvents/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteAppEvent(id: String) async throws {
        try await client.delete(path: "appEvents/\(id)")
    }

    // MARK: Event localizations

    package struct EventLocalization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let locale: String?
            package let name: String?
            package let shortDescription: String?
            package let longDescription: String?
        }
    }

    package func listLocalizations(
        eventID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (localizations: [EventLocalization], nextCursor: String?) {
        struct Resp: Decodable {
            let data: [EventLocalization]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        var query: [String: String] = ["limit": "\(limit)"]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "appEvents/\(eventID)/localizations",
            query: query, as: Resp.self
        )
        return (resp.data, resp.links?.next)
    }

    package func createLocalization(
        eventID: String,
        locale: String,
        name: String? = nil,
        shortDescription: String? = nil,
        longDescription: String? = nil
    ) async throws -> EventLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEventLocalizations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let locale: String
                let name: String?
                let shortDescription: String?
                let longDescription: String?
            }
            struct Rels: Encodable {
                struct E: Encodable {
                    struct Data: Encodable { let type = "appEvents"; let id: String }
                    let data: Data
                }
                let appEvent: E
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(
                locale: locale,
                name: name,
                shortDescription: shortDescription,
                longDescription: longDescription
            ),
            relationships: .init(appEvent: .init(data: .init(id: eventID)))
        ))
        struct Resp: Decodable { let data: EventLocalization }
        let resp: Resp = try await client.post(
            path: "appEventLocalizations", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateLocalization(
        id: String,
        name: String? = nil,
        shortDescription: String? = nil,
        longDescription: String? = nil
    ) async throws -> EventLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEventLocalizations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let name: String?
                let shortDescription: String?
                let longDescription: String?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(
                name: name,
                shortDescription: shortDescription,
                longDescription: longDescription
            )
        ))
        struct Resp: Decodable { let data: EventLocalization }
        let resp: Resp = try await client.patch(
            path: "appEventLocalizations/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteLocalization(id: String) async throws {
        try await client.delete(path: "appEventLocalizations/\(id)")
    }

    // MARK: Event screenshots (3-phase upload)

    package struct EventScreenshot: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let fileSize: Int?
            package let fileName: String?
            package let sourceFileChecksum: String?
            package let imageAsset: ImageAsset?
            package let assetToken: String?
            package let assetType: String?
            package let uploadOperations: [MarketingAssetUpload.UploadOperation]?
            package let uploaded: Bool?
            package let assetDeliveryState: AssetDeliveryState?
        }

        package struct ImageAsset: Codable, Sendable {
            package let templateUrl: String?
            package let width: Int?
            package let height: Int?
        }

        package struct AssetDeliveryState: Codable, Sendable {
            package let state: String?
        }
    }

    package func listScreenshots(localizationID: String) async throws -> [EventScreenshot] {
        struct Resp: Decodable { let data: [EventScreenshot] }
        let resp: Resp = try await client.get(
            path: "appEventLocalizations/\(localizationID)/appEventScreenshots",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func reserveScreenshot(
        localizationID: String,
        fileName: String,
        fileSize: Int
    ) async throws -> EventScreenshot {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEventScreenshots"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let fileSize: Int
                let fileName: String
            }
            struct Rels: Encodable {
                struct L: Encodable {
                    struct Data: Encodable {
                        let type = "appEventLocalizations"
                        let id: String
                    }
                    let data: Data
                }
                let appEventLocalization: L
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(fileSize: fileSize, fileName: fileName),
            relationships: .init(
                appEventLocalization: .init(data: .init(id: localizationID))
            )
        ))
        struct Resp: Decodable { let data: EventScreenshot }
        let resp: Resp = try await client.post(
            path: "appEventScreenshots", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func confirmScreenshotUpload(
        screenshotID: String,
        md5Checksum: String
    ) async throws -> EventScreenshot {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEventScreenshots"
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
            id: screenshotID,
            attributes: .init(uploaded: true, sourceFileChecksum: md5Checksum)
        ))
        struct Resp: Decodable { let data: EventScreenshot }
        let resp: Resp = try await client.patch(
            path: "appEventScreenshots/\(screenshotID)", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func uploadScreenshot(
        localizationID: String,
        fileURL: URL,
        chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws -> EventScreenshot {
        let data = try Data(contentsOf: fileURL)
        let md5 = MarketingAssetUpload.md5Hex(data: data)
        let reserved = try await reserveScreenshot(
            localizationID: localizationID,
            fileName: fileURL.lastPathComponent,
            fileSize: data.count
        )
        guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
            throw NSError(
                domain: "AppEventsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
            )
        }
        try await MarketingAssetUpload.uploadChunks(
            client: client, operations: ops, fileData: data, progress: chunkProgress
        )
        return try await confirmScreenshotUpload(
            screenshotID: reserved.id, md5Checksum: md5
        )
    }

    package func deleteScreenshot(id: String) async throws {
        try await client.delete(path: "appEventScreenshots/\(id)")
    }

    // MARK: Event video clips (3-phase upload)

    package struct VideoClip: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let fileSize: Int?
            package let fileName: String?
            package let sourceFileChecksum: String?
            package let previewFrameTimeCode: String?
            package let previewImage: PreviewImage?
            package let videoUrl: String?
            package let videoDeliveryState: DeliveryState?
            package let uploadOperations: [MarketingAssetUpload.UploadOperation]?
            package let uploaded: Bool?
        }

        package struct PreviewImage: Codable, Sendable {
            package let templateUrl: String?
            package let width: Int?
            package let height: Int?
        }

        package struct DeliveryState: Codable, Sendable {
            package let state: String?
        }
    }

    package func listVideoClips(localizationID: String) async throws -> [VideoClip] {
        struct Resp: Decodable { let data: [VideoClip] }
        let resp: Resp = try await client.get(
            path: "appEventLocalizations/\(localizationID)/appEventVideoClips",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func reserveVideoClip(
        localizationID: String,
        fileName: String,
        fileSize: Int
    ) async throws -> VideoClip {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEventVideoClips"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let fileSize: Int
                let fileName: String
            }
            struct Rels: Encodable {
                struct L: Encodable {
                    struct Data: Encodable {
                        let type = "appEventLocalizations"
                        let id: String
                    }
                    let data: Data
                }
                let appEventLocalization: L
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(fileSize: fileSize, fileName: fileName),
            relationships: .init(
                appEventLocalization: .init(data: .init(id: localizationID))
            )
        ))
        struct Resp: Decodable { let data: VideoClip }
        let resp: Resp = try await client.post(
            path: "appEventVideoClips", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func confirmVideoClipUpload(
        clipID: String,
        md5Checksum: String,
        previewFrameTimeCode: String? = nil
    ) async throws -> VideoClip {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEventVideoClips"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let uploaded: Bool
                let sourceFileChecksum: String
                let previewFrameTimeCode: String?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: clipID,
            attributes: .init(
                uploaded: true,
                sourceFileChecksum: md5Checksum,
                previewFrameTimeCode: previewFrameTimeCode
            )
        ))
        struct Resp: Decodable { let data: VideoClip }
        let resp: Resp = try await client.patch(
            path: "appEventVideoClips/\(clipID)", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func uploadVideoClip(
        localizationID: String,
        fileURL: URL,
        previewFrameTimeCode: String? = nil,
        chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws -> VideoClip {
        let data = try Data(contentsOf: fileURL)
        let md5 = MarketingAssetUpload.md5Hex(data: data)
        let reserved = try await reserveVideoClip(
            localizationID: localizationID,
            fileName: fileURL.lastPathComponent,
            fileSize: data.count
        )
        guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
            throw NSError(
                domain: "AppEventsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
            )
        }
        try await MarketingAssetUpload.uploadChunks(
            client: client, operations: ops, fileData: data, progress: chunkProgress
        )
        return try await confirmVideoClipUpload(
            clipID: reserved.id,
            md5Checksum: md5,
            previewFrameTimeCode: previewFrameTimeCode
        )
    }

    package func deleteVideoClip(id: String) async throws {
        try await client.delete(path: "appEventVideoClips/\(id)")
    }
}

// MARK: - App Store Version Experiments (V2)

/// App Store Connect endpoints for screenshot / product-page A/B experiments
/// scoped to a particular App Store Version. The V2 surface (which replaced
/// V1) takes treatments as a relationship of the experiment itself. Each
/// treatment is a variant with its own per-locale localizations, screenshots,
/// and preview videos; ASC rotates between treatments + the control while
/// the experiment runs.
///
/// Path uses the explicit `v2/` prefix (see ASCClient.buildURL for the
/// version-prefix handling); the resource itself is hung off v1
/// `appStoreVersions/{id}`.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/app_store_version_experiments
package struct ExperimentsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: Experiments

    package struct Experiment: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let name: String?
            package let trafficProportion: Int?
            package let reviewRequired: Bool?
            package let state: String?
            package let startDate: Date?
            package let endDate: Date?
            package let started: Bool?
        }
    }

    package func listExperiments(
        versionID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (experiments: [Experiment], nextCursor: String?) {
        struct Resp: Decodable {
            let data: [Experiment]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        var query: [String: String] = ["limit": "\(limit)"]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "appStoreVersions/\(versionID)/appStoreVersionExperimentsV2",
            query: query, as: Resp.self
        )
        return (resp.data, resp.links?.next)
    }

    package func getExperiment(id: String) async throws -> Experiment? {
        struct Resp: Decodable { let data: Experiment }
        do {
            let resp: Resp = try await client.get(
                path: "v2/appStoreVersionExperiments/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    package func createExperiment(
        versionID: String,
        name: String,
        trafficProportion: Int? = nil
    ) async throws -> Experiment {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersionExperiments"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let name: String
                let trafficProportion: Int?
            }
            struct Rels: Encodable {
                struct V: Encodable {
                    struct Data: Encodable {
                        let type = "appStoreVersions"
                        let id: String
                    }
                    let data: Data
                }
                let appStoreVersion: V
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(name: name, trafficProportion: trafficProportion),
            relationships: .init(appStoreVersion: .init(data: .init(id: versionID)))
        ))
        struct Resp: Decodable { let data: Experiment }
        let resp: Resp = try await client.post(
            path: "v2/appStoreVersionExperiments", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateExperiment(
        id: String,
        name: String? = nil,
        trafficProportion: Int? = nil,
        started: Bool? = nil
    ) async throws -> Experiment {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersionExperiments"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let name: String?
                let trafficProportion: Int?
                let started: Bool?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(name: name, trafficProportion: trafficProportion, started: started)
        ))
        struct Resp: Decodable { let data: Experiment }
        let resp: Resp = try await client.patch(
            path: "v2/appStoreVersionExperiments/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteExperiment(id: String) async throws {
        try await client.delete(path: "v2/appStoreVersionExperiments/\(id)")
    }

    // MARK: Treatments

    package struct Treatment: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let name: String?
            package let trafficProportion: Int?
            package let promotedDate: Date?
            package let state: String?
            package let imageAsset: ImageAsset?
        }

        package struct ImageAsset: Codable, Sendable {
            package let templateUrl: String?
            package let width: Int?
            package let height: Int?
        }
    }

    package func listTreatments(
        experimentID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (treatments: [Treatment], nextCursor: String?) {
        struct Resp: Decodable {
            let data: [Treatment]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        var query: [String: String] = ["limit": "\(limit)"]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "v2/appStoreVersionExperiments/\(experimentID)/appStoreVersionExperimentTreatments",
            query: query, as: Resp.self
        )
        return (resp.data, resp.links?.next)
    }

    package func createTreatment(
        experimentID: String,
        name: String,
        trafficProportion: Int? = nil
    ) async throws -> Treatment {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersionExperimentTreatments"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let name: String
                let trafficProportion: Int?
            }
            struct Rels: Encodable {
                struct E: Encodable {
                    struct Data: Encodable {
                        let type = "appStoreVersionExperiments"
                        let id: String
                    }
                    let data: Data
                }
                let appStoreVersionExperimentV2: E
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(name: name, trafficProportion: trafficProportion),
            relationships: .init(
                appStoreVersionExperimentV2: .init(data: .init(id: experimentID))
            )
        ))
        struct Resp: Decodable { let data: Treatment }
        let resp: Resp = try await client.post(
            path: "appStoreVersionExperimentTreatments", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateTreatment(
        id: String,
        name: String? = nil,
        trafficProportion: Int? = nil
    ) async throws -> Treatment {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersionExperimentTreatments"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let name: String?
                let trafficProportion: Int?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id, attributes: .init(name: name, trafficProportion: trafficProportion)
        ))
        struct Resp: Decodable { let data: Treatment }
        let resp: Resp = try await client.patch(
            path: "appStoreVersionExperimentTreatments/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteTreatment(id: String) async throws {
        try await client.delete(path: "appStoreVersionExperimentTreatments/\(id)")
    }

    // MARK: Treatment localizations

    package struct TreatmentLocalization: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let locale: String?
            package let promotionalText: String?
            package let description: String?
            package let keywords: String?
        }
    }

    package func listTreatmentLocalizations(
        treatmentID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (localizations: [TreatmentLocalization], nextCursor: String?) {
        struct Resp: Decodable {
            let data: [TreatmentLocalization]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        var query: [String: String] = ["limit": "\(limit)"]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "appStoreVersionExperimentTreatments/\(treatmentID)/appStoreVersionExperimentTreatmentLocalizations",
            query: query, as: Resp.self
        )
        return (resp.data, resp.links?.next)
    }

    package func createTreatmentLocalization(
        treatmentID: String,
        locale: String,
        promotionalText: String? = nil,
        description: String? = nil,
        keywords: String? = nil
    ) async throws -> TreatmentLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersionExperimentTreatmentLocalizations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let locale: String
                let promotionalText: String?
                let description: String?
                let keywords: String?
            }
            struct Rels: Encodable {
                struct T: Encodable {
                    struct Data: Encodable {
                        let type = "appStoreVersionExperimentTreatments"
                        let id: String
                    }
                    let data: Data
                }
                let appStoreVersionExperimentTreatment: T
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(
                locale: locale,
                promotionalText: promotionalText,
                description: description,
                keywords: keywords
            ),
            relationships: .init(
                appStoreVersionExperimentTreatment: .init(data: .init(id: treatmentID))
            )
        ))
        struct Resp: Decodable { let data: TreatmentLocalization }
        let resp: Resp = try await client.post(
            path: "appStoreVersionExperimentTreatmentLocalizations", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateTreatmentLocalization(
        id: String,
        promotionalText: String? = nil,
        description: String? = nil,
        keywords: String? = nil
    ) async throws -> TreatmentLocalization {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appStoreVersionExperimentTreatmentLocalizations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let promotionalText: String?
                let description: String?
                let keywords: String?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(
                promotionalText: promotionalText,
                description: description,
                keywords: keywords
            )
        ))
        struct Resp: Decodable { let data: TreatmentLocalization }
        let resp: Resp = try await client.patch(
            path: "appStoreVersionExperimentTreatmentLocalizations/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    package func deleteTreatmentLocalization(id: String) async throws {
        try await client.delete(
            path: "appStoreVersionExperimentTreatmentLocalizations/\(id)"
        )
    }

    // MARK: Treatment screenshots (3-phase upload)

    package struct TreatmentScreenshot: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let fileSize: Int?
            package let fileName: String?
            package let sourceFileChecksum: String?
            package let imageAsset: ImageAsset?
            package let assetDeliveryState: AssetDeliveryState?
            package let uploadOperations: [MarketingAssetUpload.UploadOperation]?
            package let uploaded: Bool?
        }

        package struct ImageAsset: Codable, Sendable {
            package let templateUrl: String?
            package let width: Int?
            package let height: Int?
        }

        package struct AssetDeliveryState: Codable, Sendable {
            package let state: String?
        }
    }

    package func listTreatmentScreenshots(
        treatmentLocalizationID: String
    ) async throws -> [TreatmentScreenshot] {
        struct Resp: Decodable { let data: [TreatmentScreenshot] }
        let resp: Resp = try await client.get(
            path: "appStoreVersionExperimentTreatmentLocalizations/\(treatmentLocalizationID)/appScreenshotSets",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    /// Reservation POST for an experiment-treatment screenshot. Note Apple
    /// reuses the `appScreenshots` resource type, just linked to a treatment
    /// localization's screenshot set instead of a version localization's set.
    /// `setID` is the appScreenshotSet attached to the treatment localization.
    package func reserveTreatmentScreenshot(
        setID: String,
        fileName: String,
        fileSize: Int
    ) async throws -> TreatmentScreenshot {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appScreenshots"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let fileSize: Int
                let fileName: String
            }
            struct Rels: Encodable {
                struct S: Encodable {
                    struct Data: Encodable { let type = "appScreenshotSets"; let id: String }
                    let data: Data
                }
                let appScreenshotSet: S
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(fileSize: fileSize, fileName: fileName),
            relationships: .init(appScreenshotSet: .init(data: .init(id: setID)))
        ))
        struct Resp: Decodable { let data: TreatmentScreenshot }
        let resp: Resp = try await client.post(
            path: "appScreenshots", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func confirmTreatmentScreenshotUpload(
        screenshotID: String,
        md5Checksum: String
    ) async throws -> TreatmentScreenshot {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appScreenshots"
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
            id: screenshotID,
            attributes: .init(uploaded: true, sourceFileChecksum: md5Checksum)
        ))
        struct Resp: Decodable { let data: TreatmentScreenshot }
        let resp: Resp = try await client.patch(
            path: "appScreenshots/\(screenshotID)", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func uploadTreatmentScreenshot(
        setID: String,
        fileURL: URL,
        chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws -> TreatmentScreenshot {
        let data = try Data(contentsOf: fileURL)
        let md5 = MarketingAssetUpload.md5Hex(data: data)
        let reserved = try await reserveTreatmentScreenshot(
            setID: setID,
            fileName: fileURL.lastPathComponent,
            fileSize: data.count
        )
        guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
            throw NSError(
                domain: "ExperimentsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
            )
        }
        try await MarketingAssetUpload.uploadChunks(
            client: client, operations: ops, fileData: data, progress: chunkProgress
        )
        return try await confirmTreatmentScreenshotUpload(
            screenshotID: reserved.id, md5Checksum: md5
        )
    }

    // MARK: Treatment preview videos (3-phase upload)

    package struct TreatmentPreview: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let fileSize: Int?
            package let fileName: String?
            package let sourceFileChecksum: String?
            package let mimeType: String?
            package let previewFrameTimeCode: String?
            package let videoUrl: String?
            package let previewImage: PreviewImage?
            package let uploadOperations: [MarketingAssetUpload.UploadOperation]?
            package let uploaded: Bool?
        }

        package struct PreviewImage: Codable, Sendable {
            package let templateUrl: String?
            package let width: Int?
            package let height: Int?
        }
    }

    /// Reservation POST for an experiment-treatment preview video. As with
    /// screenshots, Apple reuses the `appPreviews` resource type linked to
    /// an `appPreviewSet` owned by a treatment localization.
    package func reserveTreatmentPreview(
        setID: String,
        fileName: String,
        fileSize: Int,
        mimeType: String? = nil
    ) async throws -> TreatmentPreview {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appPreviews"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let fileSize: Int
                let fileName: String
                let mimeType: String?
            }
            struct Rels: Encodable {
                struct S: Encodable {
                    struct Data: Encodable { let type = "appPreviewSets"; let id: String }
                    let data: Data
                }
                let appPreviewSet: S
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(fileSize: fileSize, fileName: fileName, mimeType: mimeType),
            relationships: .init(appPreviewSet: .init(data: .init(id: setID)))
        ))
        struct Resp: Decodable { let data: TreatmentPreview }
        let resp: Resp = try await client.post(
            path: "appPreviews", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func confirmTreatmentPreviewUpload(
        previewID: String,
        md5Checksum: String,
        previewFrameTimeCode: String? = nil
    ) async throws -> TreatmentPreview {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appPreviews"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let uploaded: Bool
                let sourceFileChecksum: String
                let previewFrameTimeCode: String?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: previewID,
            attributes: .init(
                uploaded: true,
                sourceFileChecksum: md5Checksum,
                previewFrameTimeCode: previewFrameTimeCode
            )
        ))
        struct Resp: Decodable { let data: TreatmentPreview }
        let resp: Resp = try await client.patch(
            path: "appPreviews/\(previewID)", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func uploadTreatmentPreview(
        setID: String,
        fileURL: URL,
        mimeType: String? = nil,
        previewFrameTimeCode: String? = nil,
        chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws -> TreatmentPreview {
        let data = try Data(contentsOf: fileURL)
        let md5 = MarketingAssetUpload.md5Hex(data: data)
        let reserved = try await reserveTreatmentPreview(
            setID: setID,
            fileName: fileURL.lastPathComponent,
            fileSize: data.count,
            mimeType: mimeType
        )
        guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
            throw NSError(
                domain: "ExperimentsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
            )
        }
        try await MarketingAssetUpload.uploadChunks(
            client: client, operations: ops, fileData: data, progress: chunkProgress
        )
        return try await confirmTreatmentPreviewUpload(
            previewID: reserved.id,
            md5Checksum: md5,
            previewFrameTimeCode: previewFrameTimeCode
        )
    }
}

// MARK: - App Encryption Declarations

/// App Store Connect endpoints for the full `appEncryptionDeclarations`
/// resource (the standalone ERN-paperwork object, distinct from the simpler
/// `usesNonExemptEncryption` field already handled by submit's export
/// compliance flow). Used when an app's encryption usage requires a full
/// declaration with supporting documents (e.g. dual-use list paperwork
/// when the app ships restricted cryptography).
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/app_encryption_declarations
package struct EncryptionDeclarationsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: Declarations

    package struct Declaration: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let appEncryptionDeclarationState: String?
            package let createdDate: Date?
            package let usesEncryption: Bool?
            package let containsProprietaryCryptography: Bool?
            package let containsThirdPartyCryptography: Bool?
            package let availableOnFrenchStore: Bool?
            package let platform: String?
            package let exempt: Bool?
            package let documentName: String?
            package let documentType: String?
            package let documentUrl: String?
            package let uploadedDate: Date?
            package let codeValue: String?
        }
    }

    package func listDeclarations(
        appID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (declarations: [Declaration], nextCursor: String?) {
        struct Resp: Decodable {
            let data: [Declaration]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        var query: [String: String] = [
            "filter[app]": appID,
            "limit": "\(limit)",
        ]
        if let cursor { query["cursor"] = cursor }
        let resp: Resp = try await client.get(
            path: "appEncryptionDeclarations",
            query: query, as: Resp.self
        )
        return (resp.data, resp.links?.next)
    }

    package func getDeclaration(id: String) async throws -> Declaration? {
        struct Resp: Decodable { let data: Declaration }
        do {
            let resp: Resp = try await client.get(
                path: "appEncryptionDeclarations/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Fields shared between create and update. All optional; only non-nil
    /// values are sent.
    package struct DeclarationFields: Sendable {
        package var usesEncryption: Bool?
        package var containsProprietaryCryptography: Bool?
        package var containsThirdPartyCryptography: Bool?
        package var availableOnFrenchStore: Bool?
        package var platform: String?
        package var exempt: Bool?
        package var documentName: String?
        package var documentType: String?
        package var codeValue: String?

        package init(
            usesEncryption: Bool? = nil,
            containsProprietaryCryptography: Bool? = nil,
            containsThirdPartyCryptography: Bool? = nil,
            availableOnFrenchStore: Bool? = nil,
            platform: String? = nil,
            exempt: Bool? = nil,
            documentName: String? = nil,
            documentType: String? = nil,
            codeValue: String? = nil
        ) {
            self.usesEncryption = usesEncryption
            self.containsProprietaryCryptography = containsProprietaryCryptography
            self.containsThirdPartyCryptography = containsThirdPartyCryptography
            self.availableOnFrenchStore = availableOnFrenchStore
            self.platform = platform
            self.exempt = exempt
            self.documentName = documentName
            self.documentType = documentType
            self.codeValue = codeValue
        }
    }

    package func createDeclaration(
        appID: String,
        fields: DeclarationFields
    ) async throws -> Declaration {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEncryptionDeclarations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let usesEncryption: Bool?
                let containsProprietaryCryptography: Bool?
                let containsThirdPartyCryptography: Bool?
                let availableOnFrenchStore: Bool?
                let platform: String?
                let exempt: Bool?
                let documentName: String?
                let documentType: String?
                let codeValue: String?
            }
            struct Rels: Encodable {
                struct A: Encodable {
                    struct Data: Encodable { let type = "apps"; let id: String }
                    let data: Data
                }
                let app: A
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(
                usesEncryption: fields.usesEncryption,
                containsProprietaryCryptography: fields.containsProprietaryCryptography,
                containsThirdPartyCryptography: fields.containsThirdPartyCryptography,
                availableOnFrenchStore: fields.availableOnFrenchStore,
                platform: fields.platform,
                exempt: fields.exempt,
                documentName: fields.documentName,
                documentType: fields.documentType,
                codeValue: fields.codeValue
            ),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: Declaration }
        let resp: Resp = try await client.post(
            path: "appEncryptionDeclarations", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func updateDeclaration(
        id: String,
        fields: DeclarationFields
    ) async throws -> Declaration {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEncryptionDeclarations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let usesEncryption: Bool?
                let containsProprietaryCryptography: Bool?
                let containsThirdPartyCryptography: Bool?
                let availableOnFrenchStore: Bool?
                let platform: String?
                let exempt: Bool?
                let documentName: String?
                let documentType: String?
                let codeValue: String?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(
                usesEncryption: fields.usesEncryption,
                containsProprietaryCryptography: fields.containsProprietaryCryptography,
                containsThirdPartyCryptography: fields.containsThirdPartyCryptography,
                availableOnFrenchStore: fields.availableOnFrenchStore,
                platform: fields.platform,
                exempt: fields.exempt,
                documentName: fields.documentName,
                documentType: fields.documentType,
                codeValue: fields.codeValue
            )
        ))
        struct Resp: Decodable { let data: Declaration }
        let resp: Resp = try await client.patch(
            path: "appEncryptionDeclarations/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: Declaration documents

    package struct Document: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let fileSize: Int?
            package let fileName: String?
            package let sourceFileChecksum: String?
            package let assetToken: String?
            package let assetDeliveryState: AssetDeliveryState?
            package let uploadOperations: [MarketingAssetUpload.UploadOperation]?
            package let uploaded: Bool?
        }

        package struct AssetDeliveryState: Codable, Sendable {
            package let state: String?
        }
    }

    package func listDocuments(declarationID: String) async throws -> [Document] {
        struct Resp: Decodable { let data: [Document] }
        let resp: Resp = try await client.get(
            path: "appEncryptionDeclarations/\(declarationID)/appEncryptionDeclarationDocument",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func reserveDocument(
        declarationID: String,
        fileName: String,
        fileSize: Int
    ) async throws -> Document {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEncryptionDeclarationDocuments"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let fileSize: Int
                let fileName: String
            }
            struct Rels: Encodable {
                struct D: Encodable {
                    struct Data: Encodable {
                        let type = "appEncryptionDeclarations"
                        let id: String
                    }
                    let data: Data
                }
                let appEncryptionDeclaration: D
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(fileSize: fileSize, fileName: fileName),
            relationships: .init(
                appEncryptionDeclaration: .init(data: .init(id: declarationID))
            )
        ))
        struct Resp: Decodable { let data: Document }
        let resp: Resp = try await client.post(
            path: "appEncryptionDeclarationDocuments", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func confirmDocumentUpload(
        documentID: String,
        md5Checksum: String
    ) async throws -> Document {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appEncryptionDeclarationDocuments"
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
            id: documentID,
            attributes: .init(uploaded: true, sourceFileChecksum: md5Checksum)
        ))
        struct Resp: Decodable { let data: Document }
        let resp: Resp = try await client.patch(
            path: "appEncryptionDeclarationDocuments/\(documentID)", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func uploadDocument(
        declarationID: String,
        fileURL: URL,
        chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Document {
        let data = try Data(contentsOf: fileURL)
        let md5 = MarketingAssetUpload.md5Hex(data: data)
        let reserved = try await reserveDocument(
            declarationID: declarationID,
            fileName: fileURL.lastPathComponent,
            fileSize: data.count
        )
        guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
            throw NSError(
                domain: "EncryptionDeclarationsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
            )
        }
        try await MarketingAssetUpload.uploadChunks(
            client: client, operations: ops, fileData: data, progress: chunkProgress
        )
        return try await confirmDocumentUpload(
            documentID: reserved.id, md5Checksum: md5
        )
    }

    package func deleteDocument(id: String) async throws {
        try await client.delete(path: "appEncryptionDeclarationDocuments/\(id)")
    }
}

// MARK: - Routing App Coverage

/// App Store Connect endpoints for the routing-app coverage file (the
/// JSON-mapped polygon describing where a "Driving and Navigation" app
/// provides coverage). At most one coverage record per app. Upload is
/// the same 3-phase reservation flow, but the asset Apple expects is a
/// JSON file, not an image or video.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/routing_app_coverages
package struct RoutingCoverageAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    package struct Coverage: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let fileSize: Int?
            package let fileName: String?
            package let sourceFileChecksum: String?
            package let assetDeliveryState: AssetDeliveryState?
            package let uploadOperations: [MarketingAssetUpload.UploadOperation]?
            package let uploaded: Bool?
        }

        package struct AssetDeliveryState: Codable, Sendable {
            package let state: String?
        }
    }

    /// GET `/v1/apps/{id}/routingAppCoverage`. Returns nil if no coverage
    /// has been attached yet (404 from ASC).
    package func getCoverage(appID: String) async throws -> Coverage? {
        struct Resp: Decodable { let data: Coverage? }
        do {
            let resp: Resp = try await client.get(
                path: "apps/\(appID)/routingAppCoverage", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Reservation POST. Resource is `routingAppCoverages` attached to the
    /// app via a one-to-one relationship.
    package func reserveCoverage(
        appID: String,
        fileName: String,
        fileSize: Int
    ) async throws -> Coverage {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "routingAppCoverages"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let fileSize: Int
                let fileName: String
            }
            struct Rels: Encodable {
                struct A: Encodable {
                    struct Data: Encodable { let type = "apps"; let id: String }
                    let data: Data
                }
                let app: A
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(fileSize: fileSize, fileName: fileName),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: Coverage }
        let resp: Resp = try await client.post(
            path: "routingAppCoverages", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func confirmCoverageUpload(
        coverageID: String,
        md5Checksum: String
    ) async throws -> Coverage {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "routingAppCoverages"
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
            id: coverageID,
            attributes: .init(uploaded: true, sourceFileChecksum: md5Checksum)
        ))
        struct Resp: Decodable { let data: Coverage }
        let resp: Resp = try await client.patch(
            path: "routingAppCoverages/\(coverageID)", body: body, as: Resp.self
        )
        return resp.data
    }

    @discardableResult
    package func uploadCoverage(
        appID: String,
        fileURL: URL,
        chunkProgress: ((_ index: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Coverage {
        let data = try Data(contentsOf: fileURL)
        let md5 = MarketingAssetUpload.md5Hex(data: data)
        let reserved = try await reserveCoverage(
            appID: appID,
            fileName: fileURL.lastPathComponent,
            fileSize: data.count
        )
        guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
            throw NSError(
                domain: "RoutingCoverageAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"]
            )
        }
        try await MarketingAssetUpload.uploadChunks(
            client: client, operations: ops, fileData: data, progress: chunkProgress
        )
        return try await confirmCoverageUpload(
            coverageID: reserved.id, md5Checksum: md5
        )
    }

    package func deleteCoverage(id: String) async throws {
        try await client.delete(path: "routingAppCoverages/\(id)")
    }
}
