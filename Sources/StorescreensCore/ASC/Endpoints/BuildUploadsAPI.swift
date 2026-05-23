import Foundation
import CryptoKit

/// App Store Connect endpoints for the API-native build upload pipeline
/// introduced in OpenAPI spec v4.1 (October 2025). This is the programmatic
/// equivalent of `xcrun altool --upload-app`: it reserves chunked uploads
/// against ASC, PUTs the .ipa bytes to Apple's signed S3-style URLs, then
/// PATCHes a commit so ASC kicks off binary processing. The processed
/// result surfaces as a regular `Build` resource (the same one the
/// existing `BuildsAPI` already wraps).
///
/// Two resources back the workflow:
///   - `buildUploads`: the outer reservation that ties the upload to a
///     specific `app`. Apple uses this to allocate storage, scope the
///     upload to a developer account, and report processing status.
///   - `buildUploadFiles`: one record per concrete file inside the
///     reservation (typically a single .ipa, sometimes multiple if Apple
///     decides to split the file). Each file carries the per-chunk
///     `uploadOperations` (signed PUT URLs + headers) that the client
///     actually uses to push bytes.
///
/// Upload flow:
///   1. POST `/buildUploads` with the .ipa's `fileName`, `fileSize`, plus
///      the `app` relationship. Apple responds with a buildUpload whose
///      `state` is `PENDING`.
///   2. POST `/buildUploadFiles` with the buildUpload relationship + the
///      file metadata (`fileName`, `fileSize`, optional precomputed
///      `sourceFileChecksum`). Apple responds with the file resource
///      and its `uploadOperations` array - same shape as screenshots/
///      previews/encryption-docs.
///   3. PUT each chunk to its `uploadOperations[i].url` with the
///      headers Apple specified. These URLs are pre-signed; no ASC
///      Authorization header is needed (and adding one breaks them).
///   4. PATCH `/buildUploadFiles/{id}` with `uploaded: true` once every
///      chunk for that file has been PUT successfully. ASC validates
///      and transitions the file's `state`.
///   5. Optional: poll `/buildUploads/{id}` until `state` reaches
///      `VALID` (binary processed successfully) or `INVALID` / `FAILED`
///      (rejected with `errorMessages` populated). The corresponding
///      `Build` resource becomes available under the app at that point.
///
/// This is the API-native alternative to the altool wrapper in
/// `Sources/StorescreensCore/Upload/AltoolUploader.swift`. The altool
/// path remains the recommended one as of this writing because it is
/// battle-tested across thousands of submissions and gets implicit
/// notarization-style validation from Apple's tooling; the buildUploads
/// path is documented here for early adopters and for CI environments
/// where Xcode is not available (containers, headless Linux runners
/// once Apple ships cross-platform support, etc.).
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi
///       (Build Uploads section, spec v4.1+)
package struct BuildUploadsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    /// Nested namespace wrapping the `buildUploads` resource (the outer
    /// reservation). Access via `BuildUploadsAPI(client:).uploads`.
    package var uploads: Uploads { Uploads(client: client) }

    /// Nested namespace wrapping the `buildUploadFiles` resource (the
    /// per-file chunked-upload child). Access via
    /// `BuildUploadsAPI(client:).files`.
    package var files: Files { Files(client: client) }

    // MARK: - Shared models

    /// Per-chunk upload instruction Apple returns inside a buildUploadFile's
    /// `uploadOperations`. Identical shape to the screenshot / preview /
    /// encryption-document flows.
    package struct UploadOperation: Codable, Sendable {
        package let method: String            // typically "PUT"
        package let url: String
        package let length: Int
        package let offset: Int
        package let requestHeaders: [HeaderEntry]

        package struct HeaderEntry: Codable, Sendable {
            package let name: String
            package let value: String
        }
    }

    /// Free-form error envelope Apple attaches when a buildUpload (or one
    /// of its files) ends up in `FAILED` / `INVALID`. Modeled as an array
    /// of structured entries so callers can surface message + code without
    /// stringly parsing.
    package struct ErrorMessage: Codable, Sendable {
        package let code: String?
        package let message: String?
    }

    /// Aggregate "result" of a full `uploadIpa` run. Wraps the terminal
    /// buildUpload, every file that hung off it, and (when ASC processing
    /// finished within the caller's poll window) the resulting `Build`
    /// resource. The same `BuildsAPI.Build` type the rest of the SDK
    /// already uses - buildUploads do not introduce a new build type;
    /// they're just a fresh upload pipeline for the existing one.
    package typealias Build = BuildsAPI.Build

    /// Result returned by the high-level `uploadIpa` convenience: the
    /// terminal buildUpload + buildUploadFiles, plus the matching
    /// processed `Build` if it surfaced before the timeout.
    package struct UploadIpaResult: Sendable {
        package let upload: Uploads.BuildUpload
        package let files: [Files.BuildUploadFile]
        /// The processed Build resource on the app, if ASC finished
        /// binary processing within the caller's poll window. Nil means
        /// the .ipa is uploaded successfully but ASC is still processing
        /// (or processing failed - in which case `upload.attributes?.state`
        /// will be `FAILED` / `INVALID` and `errorMessages` populated).
        package let build: Build?
    }

    // MARK: - Relationship endpoint: apps/{id}/buildUploads

    /// Lists the buildUploads that have been registered for an app via
    /// the API-native pipeline. Independent from the older `/builds`
    /// listing because buildUploads include in-flight (PENDING /
    /// UPLOADED) reservations that have not yet materialized into Build
    /// resources.
    package func listBuildUploads(
        appID: String,
        limit: Int = 50
    ) async throws -> [Uploads.BuildUpload] {
        struct Resp: Decodable { let data: [Uploads.BuildUpload] }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/buildUploads",
            query: ["limit": String(min(max(limit, 1), 200))],
            as: Resp.self
        )
        return resp.data
    }

    // MARK: - High-level: uploadIpa

    /// Default chunk size used when slicing the .ipa for chunk-level MD5
    /// computation and FileHandle reads. Apple's reservation also
    /// dictates a per-chunk `length` on each `uploadOperation`; we always
    /// honor that. This constant only matters for the initial chunked
    /// read of the local file when we precompute the global MD5.
    package static let readChunkSize: Int = 4 * 1024 * 1024 // 4 MiB

    /// Maximum total wait time when polling the buildUpload for a
    /// terminal `state` (VALID / INVALID / FAILED) inside `uploadIpa`.
    /// Tuned for typical ASC processing - most builds reach VALID inside
    /// a couple of minutes, big binaries can take 10+. Callers can pass
    /// their own value via `processingTimeout`.
    package static let defaultProcessingTimeout: TimeInterval = 15 * 60
    package static let defaultProcessingPollInterval: TimeInterval = 10

    /// Full create -> chunk-PUT -> commit -> poll workflow for a single
    /// .ipa file. Returns the resulting `Build` resource once ASC
    /// finishes processing; if processing has not completed within
    /// `processingTimeout` (default 15 minutes), the helper returns
    /// after the file is committed and ASC has accepted ownership - at
    /// that point the buildUpload is in a terminal "uploaded" state but
    /// the Build resource may not exist yet.
    ///
    /// `progress` callback fires once per chunk PUT, with
    /// (bytesPutSoFar, totalBytes). Used by the CLI to stream upload
    /// progress to stderr.
    @discardableResult
    package func uploadIpa(
        path: URL,
        appID: String,
        progress: ((Int64, Int64) -> Void)? = nil,
        processingTimeout: TimeInterval = BuildUploadsAPI.defaultProcessingTimeout,
        processingPollInterval: TimeInterval = BuildUploadsAPI.defaultProcessingPollInterval
    ) async throws -> Build {
        let result = try await uploadIpaDetailed(
            path: path,
            appID: appID,
            progress: progress,
            processingTimeout: processingTimeout,
            processingPollInterval: processingPollInterval
        )
        if let build = result.build { return build }
        // ASC accepted the upload but processing has not produced a Build
        // resource yet. Surface a descriptive error so callers can either
        // retry or treat it as "still processing".
        let state = result.upload.attributes?.state ?? "UNKNOWN"
        throw NSError(
            domain: "BuildUploadsAPI",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "buildUpload \(result.upload.id) is in state \(state); no Build resource surfaced within \(Int(processingTimeout))s"
            ]
        )
    }

    /// Detailed variant of `uploadIpa` that returns the buildUpload,
    /// per-file metadata, and the matching Build (if processing
    /// finished). Prefer this when you need the in-flight resources
    /// for diagnostics or for an explicit "did processing complete?"
    /// branch. The plain `uploadIpa` throws when no Build surfaces.
    package func uploadIpaDetailed(
        path: URL,
        appID: String,
        progress: ((Int64, Int64) -> Void)? = nil,
        processingTimeout: TimeInterval = BuildUploadsAPI.defaultProcessingTimeout,
        processingPollInterval: TimeInterval = BuildUploadsAPI.defaultProcessingPollInterval
    ) async throws -> UploadIpaResult {
        // 1. Inspect the file on disk.
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw NSError(
                domain: "BuildUploadsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "file not found at \(path.path)"]
            )
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw NSError(
                domain: "BuildUploadsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "file at \(path.path) is empty"]
            )
        }
        let fileName = path.lastPathComponent

        // 2. Phase 1 - POST /buildUploads with the file metadata + app
        //    relationship. Apple may return uploadOperations directly on
        //    the buildUpload (older spec) or require a follow-up
        //    POST /buildUploadFiles (newer spec). We handle both shapes.
        let buildUpload = try await uploads.create(
            appID: appID,
            fileName: fileName,
            fileSize: fileSize
        )

        // 3. Phase 2 - POST /buildUploadFiles. ASC returns the file with
        //    the per-chunk uploadOperations populated.
        let md5 = try Self.fileMD5Hex(path: path)
        let uploadFile = try await files.create(
            buildUploadID: buildUpload.id,
            fileName: fileName,
            fileSize: fileSize,
            sourceFileChecksum: md5
        )
        guard let operations = uploadFile.attributes?.uploadOperations,
              !operations.isEmpty else {
            throw NSError(
                domain: "BuildUploadsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "ASC returned no uploadOperations for buildUploadFile \(uploadFile.id)"]
            )
        }

        // 4. Phase 3 - PUT each chunk. We stream from disk with
        //    FileHandle so multi-GB .ipas don't have to live in memory.
        try await Self.uploadChunks(
            client: client,
            operations: operations,
            filePath: path,
            totalBytes: fileSize,
            progress: progress
        )

        // 5. Phase 4 - PATCH commit on the file.
        let committedFile = try await files.commit(
            id: uploadFile.id,
            sourceFileChecksum: md5
        )

        // 6. Phase 5 - poll the buildUpload for a terminal state, then
        //    look up the matching Build resource on the app.
        let terminalUpload = try await waitForBuildUploadTerminalState(
            id: buildUpload.id,
            timeout: processingTimeout,
            pollInterval: processingPollInterval
        )
        let build = try await findProcessedBuild(
            appID: appID,
            buildUploadID: buildUpload.id,
            timeout: processingTimeout,
            pollInterval: processingPollInterval
        )
        return UploadIpaResult(
            upload: terminalUpload,
            files: [committedFile],
            build: build
        )
    }

    // MARK: - Polling helpers

    /// States Apple uses for the buildUpload's `state` attribute that
    /// signal "client work is done - ASC has taken ownership of the
    /// bytes." After any of these, polling for further progress only
    /// makes sense via the resulting `Build` resource (BuildsAPI).
    package static let terminalBuildUploadStates: Set<String> = [
        "UPLOADED", "PROCESSING", "VALID", "INVALID", "FAILED",
    ]

    /// Poll `/buildUploads/{id}` until its state hits one of
    /// `terminalBuildUploadStates` or the timeout elapses. Returns the
    /// last observed buildUpload either way; callers should inspect
    /// `attributes?.state` and `errorMessages`.
    package func waitForBuildUploadTerminalState(
        id: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws -> Uploads.BuildUpload {
        let deadline = Date().addingTimeInterval(timeout)
        var current: Uploads.BuildUpload = try await uploads.get(id: id) ?? {
            throw NSError(
                domain: "BuildUploadsAPI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "buildUpload \(id) disappeared"]
            )
        }()
        while Date() < deadline {
            let state = current.attributes?.state ?? ""
            if Self.terminalBuildUploadStates.contains(state) {
                return current
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if let next = try await uploads.get(id: id) {
                current = next
            }
        }
        return current
    }

    /// Hunt for the `Build` resource that materialized out of this
    /// buildUpload. Apple does not expose a direct buildUpload->build
    /// relationship link, but the build appears under
    /// `apps/{id}/builds` with the same upload identity. We poll the
    /// app's builds list, newest first, and match on
    /// `attributes.uploadedDate >= the upload's createdDate`. If
    /// nothing matches inside the timeout, we return nil so the
    /// caller can decide what to do.
    package func findProcessedBuild(
        appID: String,
        buildUploadID: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws -> Build? {
        let deadline = Date().addingTimeInterval(timeout)
        let buildsAPI = BuildsAPI(client: client)
        // We have no direct relationship, so we just return the newest
        // VALID build for the app. Callers wanting stricter matching can
        // poll BuildsAPI themselves on a marketingVersion / version pair.
        while Date() < deadline {
            // List recent builds for the app (no marketingVersion filter
            // because we don't know it from the .ipa alone).
            struct BuildResp: Decodable { let data: [Build] }
            let resp: BuildResp = try await client.get(
                path: "builds",
                query: [
                    "filter[app]": appID,
                    "sort": "-uploadedDate",
                    "limit": "5",
                ],
                as: BuildResp.self
            )
            if let valid = resp.data.first(where: {
                $0.attributes?.processingState == "VALID"
            }) {
                return valid
            }
            // If the newest build is in PROCESSING but FAILED never
            // surfaced, keep waiting; otherwise just sleep and retry.
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        // Suppress unused-warning on parameter (kept in signature for
        // future spec evolution where buildUploads expose a direct rel).
        _ = buildUploadID
        _ = buildsAPI
        return nil
    }

    // MARK: - Chunked PUT

    /// Push every chunk in `operations` to its pre-signed URL. Streams
    /// from disk via `FileHandle` so multi-GB .ipas don't live in RAM.
    /// Each chunk gets at most one retry on transient failures (network
    /// error, 502/503/504). Apple's signed URLs are single-use under
    /// normal operation, but Apple's S3 fronting tolerates a re-PUT of
    /// the same chunk within a short window, which is enough to absorb
    /// the typical TLS-reset / gateway hiccup class of flakes.
    package static func uploadChunks(
        client: ASCClient,
        operations: [UploadOperation],
        filePath: URL,
        totalBytes: Int64,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        let handle = try FileHandle(forReadingFrom: filePath)
        defer { try? handle.close() }

        // Sequential chunk uploads. Concurrent PUTs would be faster on
        // fat pipes, but Apple does not document ordering safety and
        // the bytes-per-second wins on a typical broadband link aren't
        // material for a single .ipa.
        var bytesUploaded: Int64 = 0
        for op in operations {
            try handle.seek(toOffset: UInt64(op.offset))
            let chunk = try handle.read(upToCount: op.length) ?? Data()
            guard chunk.count == op.length else {
                throw NSError(
                    domain: "BuildUploadsAPI", code: -1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "short read at offset \(op.offset): got \(chunk.count) of \(op.length) bytes"]
                )
            }
            guard let url = URL(string: op.url) else {
                throw NSError(
                    domain: "BuildUploadsAPI", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid uploadOperation URL"]
                )
            }
            var headers: [String: String] = [:]
            for h in op.requestHeaders { headers[h.name] = h.value }

            // Retry-once on transient failure: Apple's S3 fronting
            // tolerates a re-PUT of the same chunk within a short
            // window, which is enough to absorb the typical TLS-reset /
            // gateway hiccup class of flakes.
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

    // MARK: - Local MD5 over a file on disk

    /// Compute the hex-encoded MD5 of a file on disk without loading the
    /// whole file into memory. ASC uses MD5 as an integrity check on
    /// uploaded assets; we send it on both the buildUploadFile
    /// reservation (so Apple's server-side checksum compare has the
    /// expected value before we PATCH commit) and the final commit body.
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

    // MARK: - Nested: Uploads

    /// Wraps the `/buildUploads` resource. Apple's spec treats this as
    /// the outer reservation: it's the handle ASC uses to scope chunked
    /// uploads to an app, surface processing state, and expose any
    /// `errorMessages` produced by binary validation.
    package struct Uploads {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct BuildUpload: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// "PENDING" (just created, no files yet), "UPLOADED"
                /// (every file's bytes accepted), "PROCESSING" (ASC
                /// validating the binary), "VALID" (a corresponding
                /// Build resource now exists), "INVALID" / "FAILED"
                /// (rejected - inspect `errorMessages`).
                package let state: String?
                package let fileName: String?
                package let fileSize: Int64?
                package let createdDate: Date?
                package let errorMessages: [ErrorMessage]?
            }
        }

        /// POST `/buildUploads`. Creates the reservation. Required: `appID`
        /// (the relationship), plus `fileName` and `fileSize` of the .ipa
        /// that will be uploaded.
        package func create(
            appID: String,
            fileName: String,
            fileSize: Int64
        ) async throws -> BuildUpload {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "buildUploads"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int64
                }
                struct Rels: Encodable {
                    struct A: Encodable {
                        struct Data: Encodable {
                            let type = "apps"
                            let id: String
                        }
                        let data: Data
                    }
                    let app: A
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(app: .init(data: .init(id: appID)))
            ))
            struct Resp: Decodable { let data: BuildUpload }
            do {
                let resp: Resp = try await client.post(
                    path: "buildUploads", body: body, as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                // 409 "already set" - ASC has an open buildUpload that
                // matches. Re-throw so the caller can decide whether to
                // recover by listing + reusing, or fail loudly.
                throw e
            }
        }

        /// GET `/buildUploads/{id}`. Returns nil on 404, e.g. when polling
        /// a buildUpload that ASC has already garbage-collected after
        /// processing completed (rare but possible).
        package func get(id: String) async throws -> BuildUpload? {
            struct Resp: Decodable { let data: BuildUpload }
            do {
                let resp: Resp = try await client.get(
                    path: "buildUploads/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// GET `/buildUploads` - global list, filtered by app id. Used
        /// by the relationship endpoint helper on `BuildUploadsAPI` and
        /// by CLI listing.
        package func list(appID: String, limit: Int = 50) async throws -> [BuildUpload] {
            struct Resp: Decodable { let data: [BuildUpload] }
            let resp: Resp = try await client.get(
                path: "buildUploads",
                query: [
                    "filter[app]": appID,
                    "limit": String(min(max(limit, 1), 200)),
                ],
                as: Resp.self
            )
            return resp.data
        }

        /// DELETE `/buildUploads/{id}`. Discards an in-progress upload
        /// (Apple lets you clean up partially-uploaded reservations so
        /// they don't linger).
        package func delete(id: String) async throws {
            try await client.delete(path: "buildUploads/\(id)")
        }
    }

    // MARK: - Nested: Files

    /// Wraps the `/buildUploadFiles` resource. Each file inside a
    /// buildUpload is a chunked upload target: Apple returns one
    /// `uploadOperations` array per file with the signed URLs the
    /// client uses to push bytes.
    package struct Files {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct BuildUploadFile: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let fileName: String?
                package let fileSize: Int64?
                package let sourceFileChecksum: String?
                /// "AWAITING_UPLOAD", "UPLOADED" (after the PATCH
                /// commit), "INVALID" (ASC's per-file validation
                /// rejected the bytes).
                package let state: String?
                package let uploaded: Bool?
                /// Pre-signed chunk PUT URLs + headers + offsets +
                /// lengths. Populated on the POST create response.
                package let uploadOperations: [UploadOperation]?
                package let errorMessages: [ErrorMessage]?
            }
        }

        /// POST `/buildUploadFiles`. Reserves chunked uploads for a
        /// single file under an existing `buildUpload`. The response's
        /// `uploadOperations` is the signed-URL list the client PUTs
        /// to. Optionally include a precomputed MD5 in
        /// `sourceFileChecksum` so Apple's server-side compare has the
        /// expected value before we PATCH commit.
        package func create(
            buildUploadID: String,
            fileName: String,
            fileSize: Int64,
            sourceFileChecksum: String? = nil
        ) async throws -> BuildUploadFile {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "buildUploadFiles"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let fileName: String
                    let fileSize: Int64
                    let sourceFileChecksum: String?
                }
                struct Rels: Encodable {
                    struct U: Encodable {
                        struct Data: Encodable {
                            let type = "buildUploads"
                            let id: String
                        }
                        let data: Data
                    }
                    let buildUpload: U
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
                    buildUpload: .init(data: .init(id: buildUploadID))
                )
            ))
            struct Resp: Decodable { let data: BuildUploadFile }
            do {
                let resp: Resp = try await client.post(
                    path: "buildUploadFiles", body: body, as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.isAlreadySetConflict {
                throw e
            }
        }

        /// GET `/buildUploadFiles/{id}`. Returns nil on 404.
        package func get(id: String) async throws -> BuildUploadFile? {
            struct Resp: Decodable { let data: BuildUploadFile }
            do {
                let resp: Resp = try await client.get(
                    path: "buildUploadFiles/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// GET `/buildUploads/{id}/buildUploadFiles`. Lists every file
        /// hanging off a buildUpload.
        package func list(
            buildUploadID: String, limit: Int = 50
        ) async throws -> [BuildUploadFile] {
            struct Resp: Decodable { let data: [BuildUploadFile] }
            let resp: Resp = try await client.get(
                path: "buildUploads/\(buildUploadID)/buildUploadFiles",
                query: ["limit": String(min(max(limit, 1), 200))],
                as: Resp.self
            )
            return resp.data
        }

        /// PATCH `/buildUploadFiles/{id}` with `uploaded: true` plus
        /// the file checksum. ASC validates the checksum matches what
        /// it received across all chunks and either transitions state
        /// to `UPLOADED` or surfaces `errorMessages`.
        @discardableResult
        package func commit(
            id: String,
            sourceFileChecksum: String
        ) async throws -> BuildUploadFile {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "buildUploadFiles"
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
            struct Resp: Decodable { let data: BuildUploadFile }
            let resp: Resp = try await client.patch(
                path: "buildUploadFiles/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }
    }
}
