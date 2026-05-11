import ArgumentParser
import Foundation
import StorescreensCore

// MARK: - storescreens build-uploads

/// Parent command for the API-native build upload pipeline (App Store
/// Connect's `buildUploads` + `buildUploadFiles` resources, introduced in
/// OpenAPI spec v4.1, October 2025).
///
/// This is the API-native alternative to the existing `storescreens
/// upload-build` command (which wraps `xcrun altool --upload-app`). The
/// altool path is still recommended for production submissions because
/// it is battle-tested and inherits Apple's local validation hooks. The
/// buildUploads path is documented here for early adopters and for CI
/// environments where Xcode is not available.
struct BuildUploadsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-uploads",
        abstract: "Upload .ipa binaries to App Store Connect via the API-native build upload pipeline.",
        discussion: """
            buildUploads / buildUploadFiles are App Store Connect's API-native chunked binary upload \
            resources. They are an alternative to `xcrun altool --upload-app`. The full flow is:
            1) `storescreens build-uploads upload-ipa --app-id <id> --file MyApp.ipa` uploads the binary, \
               polls for processing, and prints the resulting Build resource.
            2) Individual subcommands (`create`, `files-create`, `files-commit`, `get`) expose the \
               primitive resources for advanced workflows (resumable uploads, multi-file binaries, etc.).
            """,
        subcommands: [
            BuildUploadsListCommand.self,
            BuildUploadsListForAppCommand.self,
            BuildUploadsGetCommand.self,
            BuildUploadsCreateCommand.self,
            BuildUploadsDeleteCommand.self,
            BuildUploadsFilesListCommand.self,
            BuildUploadsFilesGetCommand.self,
            BuildUploadsFilesCreateCommand.self,
            BuildUploadsFilesCommitCommand.self,
            BuildUploadsUploadIpaCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// CLI helpers private to the build-uploads command tree. Mirrors the
/// MarketingCLIHelpers shape so the user-facing error rendering stays
/// consistent across the CLI. Kept private to this file so it does not
/// clash with the marketing helpers (same shape, different namespace).
enum BuildUploadsCLIHelpers {
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

// MARK: - list (filter[app] form)

struct BuildUploadsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List buildUploads for an app (uses GET /buildUploads?filter[app])."
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Option(name: .long, help: "Page size (default 50).") var limit: Int = 50
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        do {
            let uploads = try await BuildUploadsAPI(client: client).uploads.list(
                appID: appId, limit: limit
            )
            if json { try BuildUploadsCLIHelpers.emitJSON(uploads); return }
            logger.header("Build uploads (\(uploads.count))")
            for u in uploads {
                let state = u.attributes?.state ?? "(no state)"
                let name = u.attributes?.fileName ?? "(no name)"
                print("  \(u.id)  \(state)  \(name)")
            }
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "list")
        }
    }
}

// MARK: - list-for-app (relationship endpoint)

struct BuildUploadsListForAppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-for-app",
        abstract: "List buildUploads via the relationship endpoint apps/{id}/buildUploads."
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Option(name: .long, help: "Page size (default 50).") var limit: Int = 50
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        do {
            let uploads = try await BuildUploadsAPI(client: client).listBuildUploads(
                appID: appId, limit: limit
            )
            if json { try BuildUploadsCLIHelpers.emitJSON(uploads); return }
            logger.header("Build uploads via apps/\(appId) (\(uploads.count))")
            for u in uploads {
                let state = u.attributes?.state ?? "(no state)"
                let name = u.attributes?.fileName ?? "(no name)"
                print("  \(u.id)  \(state)  \(name)")
            }
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "list-for-app")
        }
    }
}

// MARK: - get

struct BuildUploadsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch a single buildUpload by id (poll state / errorMessages)."
    )
    @Option(name: .long, help: "buildUpload id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        do {
            guard let upload = try await BuildUploadsAPI(client: client).uploads.get(id: id) else {
                logger.log("buildUpload \(id) not found", level: .error)
                throw ExitCode(1)
            }
            if json { try BuildUploadsCLIHelpers.emitJSON(upload); return }
            logger.header("buildUpload \(upload.id)")
            print("  state:      \(upload.attributes?.state ?? "?")")
            print("  fileName:   \(upload.attributes?.fileName ?? "?")")
            if let s = upload.attributes?.fileSize {
                print("  fileSize:   \(BuildUploadsCLIHelpers.humanBytes(s))")
            }
            if let errs = upload.attributes?.errorMessages, !errs.isEmpty {
                print("  errors:")
                for e in errs {
                    print("    [\(e.code ?? "?")] \(e.message ?? "")")
                }
            }
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "get")
        }
    }
}

// MARK: - create

struct BuildUploadsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "POST /buildUploads — reserve a chunked upload for an app. Returns the buildUpload."
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Option(name: .long, help: ".ipa file name (e.g. MyApp.ipa).") var fileName: String
    @Option(name: .long, help: ".ipa file size in bytes.") var fileSize: Int64
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        do {
            let upload = try await BuildUploadsAPI(client: client).uploads.create(
                appID: appId, fileName: fileName, fileSize: fileSize
            )
            if json { try BuildUploadsCLIHelpers.emitJSON(upload); return }
            logger.log("created buildUpload \(upload.id) (state \(upload.attributes?.state ?? "?"))", level: .success)
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "create")
        }
    }
}

// MARK: - delete

struct BuildUploadsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Discard an in-progress buildUpload reservation."
    )
    @Argument(help: "buildUpload id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        do {
            try await BuildUploadsAPI(client: client).uploads.delete(id: id)
            if json { try BuildUploadsCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted buildUpload \(id)", level: .success)
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "delete")
        }
    }
}

// MARK: - files-list

struct BuildUploadsFilesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files-list",
        abstract: "List buildUploadFiles attached to a buildUpload."
    )
    @Option(name: .long, help: "buildUpload id.") var buildUploadId: String
    @Option(name: .long, help: "Page size (default 50).") var limit: Int = 50
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        do {
            let files = try await BuildUploadsAPI(client: client).files.list(
                buildUploadID: buildUploadId, limit: limit
            )
            if json { try BuildUploadsCLIHelpers.emitJSON(files); return }
            logger.header("buildUploadFiles (\(files.count))")
            for f in files {
                let state = f.attributes?.state ?? "(no state)"
                let name = f.attributes?.fileName ?? "(no name)"
                print("  \(f.id)  \(state)  \(name)")
            }
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "files-list")
        }
    }
}

// MARK: - files-get

struct BuildUploadsFilesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files-get",
        abstract: "Fetch a single buildUploadFile (inspect uploadOperations + state)."
    )
    @Option(name: .long, help: "buildUploadFile id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        do {
            guard let file = try await BuildUploadsAPI(client: client).files.get(id: id) else {
                logger.log("buildUploadFile \(id) not found", level: .error)
                throw ExitCode(1)
            }
            if json { try BuildUploadsCLIHelpers.emitJSON(file); return }
            logger.header("buildUploadFile \(file.id)")
            print("  state:    \(file.attributes?.state ?? "?")")
            print("  fileName: \(file.attributes?.fileName ?? "?")")
            print("  uploaded: \(file.attributes?.uploaded.map(String.init(describing:)) ?? "?")")
            if let ops = file.attributes?.uploadOperations {
                print("  uploadOperations: \(ops.count)")
            }
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "files-get")
        }
    }
}

// MARK: - files-create

struct BuildUploadsFilesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files-create",
        abstract: "POST /buildUploadFiles — reserve a chunked-upload target inside a buildUpload."
    )
    @Option(name: .long, help: "Parent buildUpload id.") var buildUploadId: String
    @Option(name: .long, help: "File name (e.g. MyApp.ipa).") var fileName: String
    @Option(name: .long, help: "File size in bytes.") var fileSize: Int64
    @Option(name: .long, help: "Optional precomputed hex MD5 of the file bytes.") var sourceFileChecksum: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        do {
            let file = try await BuildUploadsAPI(client: client).files.create(
                buildUploadID: buildUploadId,
                fileName: fileName,
                fileSize: fileSize,
                sourceFileChecksum: sourceFileChecksum
            )
            if json { try BuildUploadsCLIHelpers.emitJSON(file); return }
            logger.log("created buildUploadFile \(file.id)", level: .success)
            if let ops = file.attributes?.uploadOperations {
                logger.log("uploadOperations: \(ops.count) chunk(s)", level: .info)
            }
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "files-create")
        }
    }
}

// MARK: - files-commit

struct BuildUploadsFilesCommitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files-commit",
        abstract: "PATCH /buildUploadFiles/{id} with uploaded:true + sourceFileChecksum."
    )
    @Option(name: .long, help: "buildUploadFile id.") var id: String
    @Option(name: .long, help: "Hex MD5 of the file bytes.") var sourceFileChecksum: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        do {
            let file = try await BuildUploadsAPI(client: client).files.commit(
                id: id, sourceFileChecksum: sourceFileChecksum
            )
            if json { try BuildUploadsCLIHelpers.emitJSON(file); return }
            logger.log("committed buildUploadFile \(file.id) (state \(file.attributes?.state ?? "?"))", level: .success)
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "files-commit")
        }
    }
}

// MARK: - upload-ipa (high-level convenience)

struct BuildUploadsUploadIpaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload-ipa",
        abstract: "End-to-end .ipa upload via the API-native pipeline.",
        discussion: """
            Reads the .ipa from disk, registers a buildUpload + buildUploadFile with App Store Connect, \
            PUTs every chunk to the signed URLs Apple returns, commits the file, then polls until ASC \
            finishes processing or the timeout elapses. Per-chunk progress is streamed to stderr.

            This is the API-native equivalent of `storescreens upload-build` (which wraps xcrun altool). \
            The altool path remains recommended for production submissions; this command exists for \
            early adopters and for CI environments where Xcode is not available.
            """
    )
    @Option(name: .long, help: "Numeric ASC app id.") var appId: String
    @Option(name: .long, help: "Path to the .ipa on disk.") var file: String
    @Option(name: .long, help: "Max seconds to wait for ASC processing (default 900).") var processingTimeout: Int = 900
    @Option(name: .long, help: "Seconds between status polls (default 10).") var processingPollInterval: Int = 10
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try BuildUploadsCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int64) ?? 0

        // Stream per-chunk progress to stderr so json mode on stdout is
        // still parseable. Mirrors the `previews upload` pattern but
        // with byte totals instead of chunk indices.
        let progress: (Int64, Int64) -> Void = { uploaded, total in
            let pct = total > 0 ? (Double(uploaded) / Double(total)) * 100 : 0
            let msg = "uploaded \(BuildUploadsCLIHelpers.humanBytes(uploaded)) / \(BuildUploadsCLIHelpers.humanBytes(total)) (\(String(format: "%.1f", pct))%)"
            FileHandle.standardError.write(Data("  \(msg)\n".utf8))
        }

        if !json {
            logger.log("uploading \(file) (\(BuildUploadsCLIHelpers.humanBytes(bytes))) to app \(appId)", level: .info)
        }

        do {
            let result = try await BuildUploadsAPI(client: client).uploadIpaDetailed(
                path: url,
                appID: appId,
                progress: progress,
                processingTimeout: TimeInterval(processingTimeout),
                processingPollInterval: TimeInterval(processingPollInterval)
            )
            if json {
                try BuildUploadsCLIHelpers.emitJSON(UploadIpaCLIDTO(result: result))
                return
            }
            logger.header("Upload complete")
            print("  buildUpload: \(result.upload.id)")
            print("  state:       \(result.upload.attributes?.state ?? "?")")
            for f in result.files {
                print("  file:        \(f.id) (state \(f.attributes?.state ?? "?"))")
            }
            if let build = result.build {
                print("  build:       \(build.id) (\(build.attributes?.processingState ?? "?"))")
                print("  version:     \(build.attributes?.version ?? "?")")
            } else {
                print("  build:       (still processing — re-run `get` later or check with `storescreens testflight builds`)")
            }
            if let errs = result.upload.attributes?.errorMessages, !errs.isEmpty {
                print("  errors:")
                for e in errs {
                    print("    [\(e.code ?? "?")] \(e.message ?? "")")
                }
            }
        } catch {
            throw BuildUploadsCLIHelpers.failAPI(error, logger: logger, context: "upload-ipa")
        }
    }
}

// MARK: - JSON DTO for upload-ipa

/// Flat-shape JSON view of `BuildUploadsAPI.UploadIpaResult` so the CLI
/// `--json` output has a stable schema independent of the underlying
/// SDK type evolution.
private struct UploadIpaCLIDTO: Encodable {
    let buildUpload: BuildUploadsAPI.Uploads.BuildUpload
    let files: [BuildUploadsAPI.Files.BuildUploadFile]
    let build: BuildUploadsAPI.Build?

    init(result: BuildUploadsAPI.UploadIpaResult) {
        self.buildUpload = result.upload
        self.files = result.files
        self.build = result.build
    }
}
