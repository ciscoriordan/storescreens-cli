import ArgumentParser
import Foundation
import StorescreensCore

// MARK: - storescreens background-assets

/// Parent command for the App Store Connect Background Assets resources
/// (Apple's 200GB-per-app post-install asset download mechanism, introduced
/// in OpenAPI spec v4.0 June 2025 with v4.1 additions in October 2025).
///
/// The Background Assets feature lets apps ship media (game packs, large
/// content libraries, multi-GB ML model weights) outside the .ipa binary.
/// Apple downloads the asset to the device after install / on first
/// launch, with no size limit on the .ipa itself. This command wraps the
/// six JSON:API resources Apple ships under the feature:
///
///   - backgroundAssets: the parent record attached to an app
///   - backgroundAssetVersions: one logical asset release per app version
///   - backgroundAssetUploadFiles: chunked-upload children of a version
///   - backgroundAssetVersionAppStoreReleases: read-only App Store state
///   - backgroundAssetVersionExternalBetaReleases: read-only external beta state
///   - backgroundAssetVersionInternalBetaReleases: read-only internal beta state
struct BackgroundAssetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "background-assets",
        abstract: "Manage Background Assets (App Store Connect post-install asset downloads).",
        discussion: """
            Background Assets ship media outside the .ipa, with Apple downloading the asset to \
            the device after install. The full upload flow is:
            1) `storescreens background-assets create --app-id <id>` creates the parent record.
            2) `storescreens background-assets versions-create --background-asset-id <id>` adds a version.
            3) `storescreens background-assets upload-file --version-id <id> --file ./pack.bin` \
               uploads one chunked file. Repeat for each file in the pack.
            4) Poll the release-state records to track rollout on each delivery channel.
            """,
        subcommands: [
            // backgroundAssets CRUD
            BgAssetsListCommand.self,
            BgAssetsListForAppCommand.self,
            BgAssetsGetCommand.self,
            BgAssetsCreateCommand.self,
            BgAssetsUpdateCommand.self,
            BgAssetsDeleteCommand.self,
            // backgroundAssetVersions
            BgAssetVersionsListCommand.self,
            BgAssetVersionsGetCommand.self,
            BgAssetVersionsCreateCommand.self,
            // backgroundAssetUploadFiles
            BgAssetFilesListCommand.self,
            BgAssetFilesGetCommand.self,
            BgAssetFilesCreateCommand.self,
            BgAssetFilesCommitCommand.self,
            BgAssetUploadFileCommand.self,
            // Read-only release records
            BgAssetAppStoreReleaseGetCommand.self,
            BgAssetExternalBetaReleaseGetCommand.self,
            BgAssetInternalBetaReleaseGetCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// CLI helpers private to the background-assets command tree. Mirrors the
/// BuildUploadsCLIHelpers shape so user-facing error rendering stays
/// consistent across the CLI.
enum BackgroundAssetsCLIHelpers {
    static func loadClient(logger: Logger) throws -> ASCClient {
        guard ASCCredentialResolver.isConfigured() else {
            logger.log("no ASC credentials configured", level: .error)
            print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
            throw ExitCode(1)
        }
        do {
            let creds = try ASCCredentialResolver.resolve()
            return ASCClient(credentials: creds)
        } catch {
            logger.log("credentials broken: \(error)", level: .error)
            throw ExitCode(1)
        }
    }

    static func emitJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    static func failAPI(_ error: Error, logger: Logger, context: String) -> ExitCode {
        if let api = error as? ASCClient.APIError {
            logger.log("\(context) failed: HTTP \(api.statusCode)", level: .error)
            for d in api.details { print("  [\(d.code)] \(d.title): \(d.detail)") }
        } else {
            logger.log("\(context) failed: \(error.localizedDescription)", level: .error)
        }
        return ExitCode(1)
    }

    /// Format a byte count as a human-readable string (KiB / MiB / GiB)
    /// for upload progress output.
    static func humanBytes(_ bytes: Int64) -> String {
        let kib = 1024.0
        let mib = kib * 1024.0
        let gib = mib * 1024.0
        let b = Double(bytes)
        if b >= gib { return String(format: "%.2f GiB", b / gib) }
        if b >= mib { return String(format: "%.1f MiB", b / mib) }
        if b >= kib { return String(format: "%.1f KiB", b / kib) }
        return "\(bytes) B"
    }
}

// MARK: - backgroundAssets: list

struct BgAssetsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List backgroundAssets for an app (uses GET /backgroundAssets?filter[app])."
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Option(name: .long, help: "Page size (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Cursor from a previous nextCursor.") var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            let page = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.list(
                appID: appId, limit: limit, cursor: cursor
            )
            if json {
                try BackgroundAssetsCLIHelpers.emitJSON(BgAssetsPageDTO(
                    data: page.data, nextCursor: page.nextCursor
                ))
                return
            }
            logger.header("Background assets (\(page.data.count))")
            for a in page.data {
                let appStore = a.attributes?.appStoreState ?? "?"
                let beta = a.attributes?.externalBetaState ?? "?"
                print("  \(a.id)  appStore=\(appStore)  beta=\(beta)")
            }
            if let c = page.nextCursor { print("  nextCursor: \(c)") }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "list")
        }
    }
}

// MARK: - backgroundAssets: list-for-app

struct BgAssetsListForAppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-for-app",
        abstract: "List backgroundAssets via the relationship endpoint apps/{id}/backgroundAssets."
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Option(name: .long, help: "Page size (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Cursor from a previous nextCursor.") var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            let page = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.listForApp(
                appID: appId, limit: limit, cursor: cursor
            )
            if json {
                try BackgroundAssetsCLIHelpers.emitJSON(page.data)
                return
            }
            logger.header("Background assets via apps/\(appId) (\(page.data.count))")
            for a in page.data {
                let appStore = a.attributes?.appStoreState ?? "?"
                let beta = a.attributes?.externalBetaState ?? "?"
                print("  \(a.id)  appStore=\(appStore)  beta=\(beta)")
            }
            if let c = page.nextCursor { print("  nextCursor: \(c)") }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "list-for-app")
        }
    }
}

// MARK: - backgroundAssets: get

struct BgAssetsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch a single backgroundAsset by id."
    )
    @Option(name: .long, help: "backgroundAsset id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            guard let asset = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.get(id: id) else {
                logger.log("backgroundAsset \(id) not found", level: .error)
                throw ExitCode(1)
            }
            if json { try BackgroundAssetsCLIHelpers.emitJSON(asset); return }
            logger.header("backgroundAsset \(asset.id)")
            print("  appStoreState:    \(asset.attributes?.appStoreState ?? "?")")
            print("  externalBetaState:\(asset.attributes?.externalBetaState ?? "?")")
            print("  internalBetaState:\(asset.attributes?.internalBetaState ?? "?")")
            if let d = asset.attributes?.lastUpdated {
                print("  lastUpdated:      \(ISO8601DateFormatter().string(from: d))")
            }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "get")
        }
    }
}

// MARK: - backgroundAssets: create

struct BgAssetsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "POST /backgroundAssets — create the parent record on an app."
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            let asset = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.create(
                appID: appId
            )
            if json { try BackgroundAssetsCLIHelpers.emitJSON(asset); return }
            logger.log("created backgroundAsset \(asset.id)", level: .success)
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "create")
        }
    }
}

// MARK: - backgroundAssets: update

struct BgAssetsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "PATCH /backgroundAssets/{id} with any combination of state attributes."
    )
    @Option(name: .long, help: "backgroundAsset id.") var id: String
    @Option(name: .long, help: "New internal beta delivery state.") var internalBetaState: String?
    @Option(name: .long, help: "New external beta delivery state.") var externalBetaState: String?
    @Option(name: .long, help: "New App Store delivery state.") var appStoreState: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        let fields = BackgroundAssetsAPI.Assets.BackgroundAssetUpdateFields(
            internalBetaState: internalBetaState,
            externalBetaState: externalBetaState,
            appStoreState: appStoreState
        )
        do {
            let asset = try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.update(
                id: id, fields: fields
            )
            if json { try BackgroundAssetsCLIHelpers.emitJSON(asset); return }
            logger.log("updated backgroundAsset \(asset.id)", level: .success)
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "update")
        }
    }
}

// MARK: - backgroundAssets: delete

struct BgAssetsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "DELETE /backgroundAssets/{id} (cascades to versions + files)."
    )
    @Argument(help: "backgroundAsset id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            try await BackgroundAssetsAPI(client: client).assets.backgroundAssets.delete(id: id)
            if json { try BackgroundAssetsCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted backgroundAsset \(id)", level: .success)
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "delete")
        }
    }
}

// MARK: - backgroundAssetVersions: list

struct BgAssetVersionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "versions-list",
        abstract: "List backgroundAssetVersions hanging off a backgroundAsset."
    )
    @Option(name: .long, help: "backgroundAsset id.") var backgroundAssetId: String
    @Option(name: .long, help: "Page size (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Cursor from a previous nextCursor.") var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            let page = try await BackgroundAssetsAPI(client: client).assets.versions.list(
                backgroundAssetID: backgroundAssetId, limit: limit, cursor: cursor
            )
            if json { try BackgroundAssetsCLIHelpers.emitJSON(page.data); return }
            logger.header("backgroundAssetVersions (\(page.data.count))")
            for v in page.data {
                let version = v.attributes?.version ?? "(no version)"
                let state = v.attributes?.appStoreState ?? "?"
                print("  \(v.id)  \(version)  appStore=\(state)")
            }
            if let c = page.nextCursor { print("  nextCursor: \(c)") }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "versions-list")
        }
    }
}

// MARK: - backgroundAssetVersions: get

struct BgAssetVersionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "versions-get",
        abstract: "Fetch a single backgroundAssetVersion by id."
    )
    @Option(name: .long, help: "backgroundAssetVersion id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            guard let v = try await BackgroundAssetsAPI(client: client).assets.versions.get(id: id) else {
                logger.log("backgroundAssetVersion \(id) not found", level: .error)
                throw ExitCode(1)
            }
            if json { try BackgroundAssetsCLIHelpers.emitJSON(v); return }
            logger.header("backgroundAssetVersion \(v.id)")
            print("  version:           \(v.attributes?.version ?? "?")")
            print("  appStoreState:     \(v.attributes?.appStoreState ?? "?")")
            print("  internalBetaState: \(v.attributes?.internalBetaState ?? "?")")
            if let files = v.relationships?.files?.data {
                print("  files:             \(files.count)")
            }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "versions-get")
        }
    }
}

// MARK: - backgroundAssetVersions: create

struct BgAssetVersionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "versions-create",
        abstract: "POST /backgroundAssetVersions — create a new version on an existing backgroundAsset."
    )
    @Option(name: .long, help: "Parent backgroundAsset id.") var backgroundAssetId: String
    @Option(name: .long, help: "Optional version label.") var version: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            let v = try await BackgroundAssetsAPI(client: client).assets.versions.create(
                backgroundAssetID: backgroundAssetId, version: version
            )
            if json { try BackgroundAssetsCLIHelpers.emitJSON(v); return }
            logger.log("created backgroundAssetVersion \(v.id)", level: .success)
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "versions-create")
        }
    }
}

// MARK: - backgroundAssetUploadFiles: list

struct BgAssetFilesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files-list",
        abstract: "List backgroundAssetUploadFiles on a backgroundAssetVersion."
    )
    @Option(name: .long, help: "backgroundAssetVersion id.") var versionId: String
    @Option(name: .long, help: "Page size (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Cursor from a previous nextCursor.") var cursor: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            let page = try await BackgroundAssetsAPI(client: client).assets.uploadFiles.list(
                versionID: versionId, limit: limit, cursor: cursor
            )
            if json { try BackgroundAssetsCLIHelpers.emitJSON(page.data); return }
            logger.header("backgroundAssetUploadFiles (\(page.data.count))")
            for f in page.data {
                let state = f.attributes?.state ?? "?"
                let name = f.attributes?.fileName ?? "(no name)"
                print("  \(f.id)  \(state)  \(name)")
            }
            if let c = page.nextCursor { print("  nextCursor: \(c)") }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "files-list")
        }
    }
}

// MARK: - backgroundAssetUploadFiles: get

struct BgAssetFilesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files-get",
        abstract: "Fetch a single backgroundAssetUploadFile (inspect uploadOperations + state)."
    )
    @Option(name: .long, help: "backgroundAssetUploadFile id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            guard let f = try await BackgroundAssetsAPI(client: client).assets.uploadFiles.get(id: id) else {
                logger.log("backgroundAssetUploadFile \(id) not found", level: .error)
                throw ExitCode(1)
            }
            if json { try BackgroundAssetsCLIHelpers.emitJSON(f); return }
            logger.header("backgroundAssetUploadFile \(f.id)")
            print("  state:    \(f.attributes?.state ?? "?")")
            print("  fileName: \(f.attributes?.fileName ?? "?")")
            print("  uploaded: \(f.attributes?.uploaded.map(String.init(describing:)) ?? "?")")
            if let ops = f.attributes?.uploadOperations {
                print("  uploadOperations: \(ops.count)")
            }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "files-get")
        }
    }
}

// MARK: - backgroundAssetUploadFiles: create

struct BgAssetFilesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files-create",
        abstract: "POST /backgroundAssetUploadFiles — reserve a chunked-upload target inside a backgroundAssetVersion."
    )
    @Option(name: .long, help: "Parent backgroundAssetVersion id.") var versionId: String
    @Option(name: .long, help: "File name (e.g. pack-01.bin).") var fileName: String
    @Option(name: .long, help: "File size in bytes.") var fileSize: Int64
    @Option(name: .long, help: "Optional precomputed hex MD5.") var sourceFileChecksum: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            let f = try await BackgroundAssetsAPI(client: client).assets.uploadFiles.create(
                versionID: versionId,
                fileName: fileName,
                fileSize: fileSize,
                sourceFileChecksum: sourceFileChecksum
            )
            if json { try BackgroundAssetsCLIHelpers.emitJSON(f); return }
            logger.log("created backgroundAssetUploadFile \(f.id)", level: .success)
            if let ops = f.attributes?.uploadOperations {
                logger.log("uploadOperations: \(ops.count) chunk(s)", level: .info)
            }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "files-create")
        }
    }
}

// MARK: - backgroundAssetUploadFiles: commit

struct BgAssetFilesCommitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files-commit",
        abstract: "PATCH /backgroundAssetUploadFiles/{id} with uploaded:true + sourceFileChecksum."
    )
    @Option(name: .long, help: "backgroundAssetUploadFile id.") var id: String
    @Option(name: .long, help: "Hex MD5 over the file bytes.") var sourceFileChecksum: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            let f = try await BackgroundAssetsAPI(client: client).assets.uploadFiles.commit(
                id: id, sourceFileChecksum: sourceFileChecksum
            )
            if json { try BackgroundAssetsCLIHelpers.emitJSON(f); return }
            logger.log("committed backgroundAssetUploadFile \(f.id) (state \(f.attributes?.state ?? "?"))", level: .success)
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "files-commit")
        }
    }
}

// MARK: - High-level: upload-file

struct BgAssetUploadFileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload-file",
        abstract: "End-to-end chunked upload of a single background-asset file.",
        discussion: """
            Reads the file from disk, registers a backgroundAssetUploadFile with App Store Connect, \
            PUTs every chunk to the signed URLs Apple returns, then commits the file. Per-chunk \
            progress is streamed to stderr so --json output on stdout stays parseable.
            """
    )
    @Option(name: .long, help: "Parent backgroundAssetVersion id.") var versionId: String
    @Option(name: .long, help: "Path to the file on disk.") var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int64) ?? 0

        // Per-chunk progress to stderr so json on stdout is still parseable.
        // Mirrors `build-uploads upload-ipa` and `previews upload`.
        let progress: (Int64, Int64) -> Void = { uploaded, total in
            let pct = total > 0 ? (Double(uploaded) / Double(total)) * 100 : 0
            let msg = "uploaded \(BackgroundAssetsCLIHelpers.humanBytes(uploaded)) / \(BackgroundAssetsCLIHelpers.humanBytes(total)) (\(String(format: "%.1f", pct))%)"
            FileHandle.standardError.write(Data("  \(msg)\n".utf8))
        }

        if !json {
            logger.log("uploading \(file) (\(BackgroundAssetsCLIHelpers.humanBytes(bytes))) to version \(versionId)", level: .info)
        }

        do {
            let result = try await BackgroundAssetsAPI(client: client).uploadBackgroundAssetFile(
                path: url,
                versionID: versionId,
                progress: progress
            )
            if json { try BackgroundAssetsCLIHelpers.emitJSON(result.file); return }
            logger.header("Upload complete")
            print("  file:     \(result.file.id)")
            print("  state:    \(result.file.attributes?.state ?? "?")")
            print("  fileName: \(result.file.attributes?.fileName ?? "?")")
            if let errs = result.file.attributes?.errorMessages, !errs.isEmpty {
                print("  errors:")
                for e in errs {
                    print("    [\(e.code ?? "?")] \(e.message ?? "")")
                }
            }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "upload-file")
        }
    }
}

// MARK: - Read-only release records: App Store

struct BgAssetAppStoreReleaseGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-store-release-get",
        abstract: "Read the App Store delivery release-state record for a backgroundAssetVersion (spec v4.1)."
    )
    @Option(name: .long, help: "backgroundAssetVersionAppStoreRelease id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            guard let r = try await BackgroundAssetsAPI(client: client).assets.appStoreReleases.get(id: id) else {
                logger.log("backgroundAssetVersionAppStoreRelease \(id) not found", level: .error)
                throw ExitCode(1)
            }
            if json { try BackgroundAssetsCLIHelpers.emitJSON(r); return }
            logger.header("App Store release \(r.id)")
            print("  state:       \(r.attributes?.state ?? "?")")
            if let d = r.attributes?.releaseDate {
                print("  releaseDate: \(ISO8601DateFormatter().string(from: d))")
            }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "app-store-release-get")
        }
    }
}

// MARK: - Read-only release records: External Beta

struct BgAssetExternalBetaReleaseGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "external-beta-release-get",
        abstract: "Read the External Beta delivery release-state record for a backgroundAssetVersion."
    )
    @Option(name: .long, help: "backgroundAssetVersionExternalBetaRelease id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            guard let r = try await BackgroundAssetsAPI(client: client).assets.externalBetaReleases.get(id: id) else {
                logger.log("backgroundAssetVersionExternalBetaRelease \(id) not found", level: .error)
                throw ExitCode(1)
            }
            if json { try BackgroundAssetsCLIHelpers.emitJSON(r); return }
            logger.header("External beta release \(r.id)")
            print("  state:       \(r.attributes?.state ?? "?")")
            if let d = r.attributes?.releaseDate {
                print("  releaseDate: \(ISO8601DateFormatter().string(from: d))")
            }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "external-beta-release-get")
        }
    }
}

// MARK: - Read-only release records: Internal Beta

struct BgAssetInternalBetaReleaseGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "internal-beta-release-get",
        abstract: "Read the Internal Beta delivery release-state record for a backgroundAssetVersion."
    )
    @Option(name: .long, help: "backgroundAssetVersionInternalBetaRelease id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BackgroundAssetsCLIHelpers.loadClient(logger: logger)
        do {
            guard let r = try await BackgroundAssetsAPI(client: client).assets.internalBetaReleases.get(id: id) else {
                logger.log("backgroundAssetVersionInternalBetaRelease \(id) not found", level: .error)
                throw ExitCode(1)
            }
            if json { try BackgroundAssetsCLIHelpers.emitJSON(r); return }
            logger.header("Internal beta release \(r.id)")
            print("  state:       \(r.attributes?.state ?? "?")")
            if let d = r.attributes?.releaseDate {
                print("  releaseDate: \(ISO8601DateFormatter().string(from: d))")
            }
        } catch {
            throw BackgroundAssetsCLIHelpers.failAPI(error, logger: logger, context: "internal-beta-release-get")
        }
    }
}

// MARK: - DTOs

/// Flat-shape page envelope used by `list` to emit both the items and
/// the cursor in a single JSON object.
private struct BgAssetsPageDTO: Encodable {
    let data: [BackgroundAssetsAPI.Assets.BackgroundAsset]
    let nextCursor: String?
}
