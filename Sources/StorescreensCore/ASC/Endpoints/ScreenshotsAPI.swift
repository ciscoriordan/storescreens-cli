import Foundation
import CryptoKit

/// App Store Connect endpoints for screenshot sets and screenshot upload.
///
/// Upload is a three-step dance:
///   1. POST /appScreenshots reserves a slot and returns `uploadOperations`
///      with pre-signed URLs + per-chunk offset/length/headers.
///   2. PUT each chunk of the binary file to the returned URL.
///   3. PATCH /appScreenshots/{id} with `uploaded:true` + `sourceFileChecksum`
///      (MD5 of the file bytes) to finalize.
package struct ScreenshotsAPI {
    package let client: ASCClient

    package init(client: ASCClient) { self.client = client }

    // MARK: - Screenshot sets

    package struct ScreenshotSet: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let screenshotDisplayType: String?
        }
    }

    package func listScreenshotSets(localizationID: String) async throws -> [ScreenshotSet] {
        struct Resp: Decodable { let data: [ScreenshotSet] }
        let resp: Resp = try await client.get(
            path: "appStoreVersionLocalizations/\(localizationID)/appScreenshotSets",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func createScreenshotSet(
        localizationID: String,
        displayType: String
    ) async throws -> ScreenshotSet {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "appScreenshotSets"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable { let screenshotDisplayType: String }
            struct Rels: Encodable {
                struct L: Encodable {
                    struct Data: Encodable { let type = "appStoreVersionLocalizations"; let id: String }
                    let data: Data
                }
                let appStoreVersionLocalization: L
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(screenshotDisplayType: displayType),
            relationships: .init(appStoreVersionLocalization: .init(data: .init(id: localizationID)))
        ))
        struct Resp: Decodable { let data: ScreenshotSet }
        let resp: Resp = try await client.post(path: "appScreenshotSets", body: body, as: Resp.self)
        return resp.data
    }

    package func findOrCreateSet(
        localizationID: String,
        displayType: String
    ) async throws -> ScreenshotSet {
        let sets = try await listScreenshotSets(localizationID: localizationID)
        if let existing = sets.first(where: { $0.attributes?.screenshotDisplayType == displayType }) {
            return existing
        }
        return try await createScreenshotSet(localizationID: localizationID, displayType: displayType)
    }

    /// Deletes the screenshot set itself (and every screenshot inside). Used
    /// before a fresh upload so ASC's "the local PNGs are source of truth"
    /// semantics hold.
    package func deleteScreenshotSet(id: String) async throws {
        try await client.delete(path: "appScreenshotSets/\(id)")
    }

    /// Lists screenshots in a set (so we can delete them individually without
    /// recreating the set, useful to preserve the set's id if anything else
    /// references it).
    package struct ScreenshotInSet: Codable, Sendable {
        package let id: String
    }

    package func listScreenshots(setID: String) async throws -> [ScreenshotInSet] {
        struct Resp: Decodable { let data: [ScreenshotInSet] }
        let resp: Resp = try await client.get(
            path: "appScreenshotSets/\(setID)/appScreenshots",
            query: ["limit": "50"],
            as: Resp.self
        )
        return resp.data
    }

    package func deleteScreenshot(id: String) async throws {
        try await client.delete(path: "appScreenshots/\(id)")
    }

    // MARK: - Screenshot upload

    /// Per-chunk upload instruction Apple returns on reservation.
    package struct UploadOperation: Codable, Sendable {
        package let method: String            // "PUT"
        package let url: String
        package let length: Int
        package let offset: Int
        package let requestHeaders: [HeaderEntry]

        package struct HeaderEntry: Codable, Sendable {
            package let name: String
            package let value: String
        }
    }

    package struct Screenshot: Codable, Sendable {
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

    /// Step 1 — reserve an upload slot. Returns the newly created screenshot
    /// with `uploadOperations` populated.
    package func reserveScreenshot(
        setID: String,
        fileName: String,
        fileSize: Int
    ) async throws -> Screenshot {
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
                struct Set: Encodable {
                    struct Data: Encodable { let type = "appScreenshotSets"; let id: String }
                    let data: Data
                }
                let appScreenshotSet: Set
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(fileSize: fileSize, fileName: fileName),
            relationships: .init(appScreenshotSet: .init(data: .init(id: setID)))
        ))
        struct Resp: Decodable { let data: Screenshot }
        let resp: Resp = try await client.post(
            path: "appScreenshots",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// Step 2 — upload each chunk to the pre-signed URL Apple returned.
    /// `fileData` is the whole file; we slice by offset/length per operation.
    package func uploadChunks(
        operations: [UploadOperation],
        fileData: Data
    ) async throws {
        for op in operations {
            guard let url = URL(string: op.url) else {
                throw NSError(domain: "ScreenshotsAPI", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "invalid uploadOperation URL"])
            }
            let end = op.offset + op.length
            guard end <= fileData.count else {
                throw NSError(domain: "ScreenshotsAPI", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "chunk offset+length exceeds file"])
            }
            let chunk = fileData.subdata(in: op.offset..<end)
            var headers: [String: String] = [:]
            for h in op.requestHeaders { headers[h.name] = h.value }
            try await client.putBinary(absoluteURL: url, headers: headers, body: chunk)
        }
    }

    /// Step 3 — PATCH uploaded=true + checksum. Apple validates the checksum
    /// against what it received and rejects mismatched uploads.
    @discardableResult
    package func confirmUpload(
        screenshotID: String,
        md5Checksum: String
    ) async throws -> Screenshot {
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
        struct Resp: Decodable { let data: Screenshot }
        let resp: Resp = try await client.patch(
            path: "appScreenshots/\(screenshotID)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// Convenience — runs the full 3-step upload for a file URL.
    @discardableResult
    package func uploadScreenshot(
        setID: String,
        fileURL: URL
    ) async throws -> Screenshot {
        let data = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        let fileSize = data.count
        let md5 = Self.md5Hex(data: data)

        let reserved = try await reserveScreenshot(
            setID: setID, fileName: fileName, fileSize: fileSize
        )
        guard let ops = reserved.attributes?.uploadOperations, !ops.isEmpty else {
            throw NSError(domain: "ScreenshotsAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Apple returned no uploadOperations"])
        }
        try await uploadChunks(operations: ops, fileData: data)
        return try await confirmUpload(screenshotID: reserved.id, md5Checksum: md5)
    }

    // MARK: - Helpers

    /// Apple's sourceFileChecksum is hex-encoded MD5 of the file bytes.
    /// MD5 is cryptographically weak but Apple uses it as an integrity
    /// check, not a security primitive — we just have to match what they
    /// expect.
    package static func md5Hex(data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
