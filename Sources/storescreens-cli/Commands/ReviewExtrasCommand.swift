import ArgumentParser
import Foundation
import StorescreensCore

/// Parent command for the customer-review surfaces covered by
/// `Wave4ExtrasAPI.CustomerReviewExtras`: Apple Intelligence generated
/// review summarizations (read-only) and App Store review attachments
/// (CRUD plus 3-phase upload).
///
/// All subcommands resolve credentials through
/// `ASCCredentialResolver.resolve()` and emit either a human-readable
/// summary or pretty-printed JSON (with `--json`). This file does not
/// register itself in Main.swift; the parent agent wires it in.
struct ReviewExtrasCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review-extras",
        abstract: "Customer review summarizations + App Store review attachments.",
        discussion: """
            Wraps the customer review resources that did not fit in the \
            base `reviews` command: Apple Intelligence summary rollups and \
            developer-supplied review attachments (sign-in walkthroughs, \
            network captures, etc.) attached to App Review submissions.
            """,
        subcommands: [
            ReviewExtrasSummarizationsCommand.self,
            ReviewExtrasAttachmentsCommand.self,
        ]
    )
}

// MARK: - Shared plumbing

private enum ReviewExtrasJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private func resolveReviewExtras(logger: Logger) async throws -> Wave4ExtrasAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return Wave4ExtrasAPI(client: client)
}

private struct EncodableReviewPage<Item: Encodable>: Encodable {
    let items: [Item]
    let nextCursor: String?
}

// MARK: - Summarizations

struct ReviewExtrasSummarizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarizations",
        abstract: "Apple Intelligence review summaries. Read-only.",
        subcommands: [
            ReviewExtrasSummarizationsListCommand.self,
            ReviewExtrasSummarizationsGetCommand.self,
        ]
    )
}

struct ReviewExtrasSummarizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Apple Intelligence summaries for an app."
    )

    @Option(name: .long) var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveReviewExtras(logger: logger).customerReviewExtras
        let page = try await api.listSummarizationsForApp(
            appID: appId, limit: limit, cursor: cursor
        )
        if json {
            print(try ReviewExtrasJSON.encode(
                EncodableReviewPage(items: page.items, nextCursor: page.nextCursor)
            ))
            return
        }
        logger.header("Review summarizations (\(page.items.count))")
        for s in page.items {
            let locale = s.attributes?.locale ?? "?"
            let territory = s.attributes?.territory ?? "?"
            print("  \(s.id)\t\(locale)\t\(territory)")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct ReviewExtrasSummarizationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch a single review summarization by id."
    )

    @Argument(help: "customerReviewSummarization id") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveReviewExtras(logger: logger).customerReviewExtras
        guard let s = try await api.getSummarization(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json {
            print(try ReviewExtrasJSON.encode(s))
            return
        }
        logger.header("Summarization")
        print("  id:        \(s.id)")
        print("  locale:    \(s.attributes?.locale ?? "(none)")")
        print("  territory: \(s.attributes?.territory ?? "(none)")")
        if let summary = s.attributes?.summary {
            print("  summary:")
            for line in summary.split(separator: "\n") {
                print("    \(line)")
            }
        }
    }
}

// MARK: - Attachments

struct ReviewExtrasAttachmentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachments",
        abstract: "Supporting files attached to an App Review submission.",
        subcommands: [
            ReviewExtrasAttachmentsListCommand.self,
            ReviewExtrasAttachmentsGetCommand.self,
            ReviewExtrasAttachmentsCreateCommand.self,
            ReviewExtrasAttachmentsUpdateCommand.self,
            ReviewExtrasAttachmentsDeleteCommand.self,
            ReviewExtrasAttachmentsUploadCommand.self,
        ]
    )
}

struct ReviewExtrasAttachmentsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List attachments on a review-detail record."
    )

    @Option(name: .long, help: "appStoreReviewDetail id.") var reviewDetailId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveReviewExtras(logger: logger).customerReviewExtras
        let page = try await api.listAttachments(
            reviewDetailID: reviewDetailId, limit: limit, cursor: cursor
        )
        if json {
            print(try ReviewExtrasJSON.encode(
                EncodableReviewPage(items: page.items, nextCursor: page.nextCursor)
            ))
            return
        }
        logger.header("Review attachments (\(page.items.count))")
        for a in page.items {
            let name = a.attributes?.fileName ?? "(no name)"
            let size = a.attributes?.fileSize.map(String.init(describing:)) ?? "?"
            let state = a.attributes?.assetDeliveryState?.state ?? "?"
            print("  \(a.id)\t\(name)\t\(size)b\tstate=\(state)")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct ReviewExtrasAttachmentsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a single review attachment.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveReviewExtras(logger: logger).customerReviewExtras
        guard let a = try await api.getAttachment(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json {
            print(try ReviewExtrasJSON.encode(a))
            return
        }
        logger.header("Review attachment")
        print("  id:         \(a.id)")
        print("  fileName:   \(a.attributes?.fileName ?? "(none)")")
        print("  fileSize:   \(a.attributes?.fileSize.map(String.init(describing:)) ?? "(none)")")
        print("  checksum:   \(a.attributes?.sourceFileChecksum ?? "(none)")")
        print("  state:      \(a.attributes?.assetDeliveryState?.state ?? "(none)")")
    }
}

struct ReviewExtrasAttachmentsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Phase 1: reserve a new attachment slot."
    )

    @Option(name: .long) var reviewDetailId: String
    @Option(name: .long) var fileName: String
    @Option(name: .long) var fileSize: Int
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveReviewExtras(logger: logger).customerReviewExtras
        let a = try await api.createAttachment(
            reviewDetailID: reviewDetailId, fileName: fileName, fileSize: fileSize
        )
        if json {
            print(try ReviewExtrasJSON.encode(a))
        } else {
            logger.log("reserved attachment \(a.id)", level: .success)
        }
    }
}

struct ReviewExtrasAttachmentsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Phase 3: finalize an attachment (uploaded:true + checksum)."
    )

    @Argument var id: String
    @Option(name: .long) var uploaded: Bool?
    @Option(name: .long, help: "Hex MD5 of the file bytes.") var sourceFileChecksum: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveReviewExtras(logger: logger).customerReviewExtras
        let a = try await api.updateAttachment(
            id: id, uploaded: uploaded, sourceFileChecksum: sourceFileChecksum
        )
        if json {
            print(try ReviewExtrasJSON.encode(a))
        } else {
            logger.log("updated attachment \(a.id)", level: .success)
        }
    }
}

struct ReviewExtrasAttachmentsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a review attachment.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveReviewExtras(logger: logger).customerReviewExtras
        try await api.deleteAttachment(id: id)
        logger.log("deleted attachment \(id)", level: .success)
    }
}

struct ReviewExtrasAttachmentsUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Run all three phases (reserve, PUT chunks, finalize) in one call."
    )

    @Option(name: .long) var reviewDetailId: String
    @Option(name: .long, help: "Path to the file to upload.") var filePath: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveReviewExtras(logger: logger).customerReviewExtras
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        let a = try await api.uploadAttachment(reviewDetailID: reviewDetailId, fileURL: url) {
            index, total in
            logger.progress(index, of: total, message: "chunk")
        }
        if json {
            print(try ReviewExtrasJSON.encode(a))
        } else {
            logger.log("uploaded attachment \(a.id)", level: .success)
        }
    }
}
