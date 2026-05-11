import ArgumentParser
import Foundation
import StorescreensCore

// MARK: - Shared helpers

/// Common --json flag + credential resolution shared across the marketing
/// command tree. Mirrors `StatusCommand.emitJSON` so output is consistent
/// across the CLI.
enum MarketingCLIHelpers {

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

    /// Progress-aware chunk-upload callback. Prints a per-chunk line for
    /// files large enough to be sliced into 2+ chunks; otherwise stays quiet.
    static func uploadProgress(forBytes byteCount: Int, logger: Logger) -> ((Int, Int) -> Void)? {
        // ~5 MB threshold matches the chunk size Apple typically returns.
        guard byteCount > 5_000_000 else { return nil }
        return { index, total in
            logger.log("uploaded chunk \(index)/\(total)", level: .info)
        }
    }
}

// MARK: - storescreens previews

struct PreviewsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "previews",
        abstract: "Manage App Preview videos on App Store Connect.",
        discussion: """
            App Preview videos appear before screenshots in the App Store carousel. \
            Each (locale, deviceType) has one appPreviewSet that holds up to three \
            preview videos. Uploads use Apple's 3-phase reserve / chunk-upload / \
            confirm flow.
            """,
        subcommands: [
            PreviewSetsListCommand.self,
            PreviewSetsCreateCommand.self,
            PreviewSetsDeleteCommand.self,
            PreviewsListCommand.self,
            PreviewsUploadCommand.self,
            PreviewsDeleteCommand.self,
        ]
    )
}

struct PreviewSetsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sets-list",
        abstract: "List appPreviewSets on a version localization."
    )
    @Option(name: .long, help: "appStoreVersionLocalization id.") var localizationId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let sets = try await AppPreviewsAPI(client: client).listPreviewSets(localizationID: localizationId)
            if json { try MarketingCLIHelpers.emitJSON(sets); return }
            logger.header("Preview sets (\(sets.count))")
            for s in sets {
                print("  \(s.id)  \(s.attributes?.previewType ?? "(no type)")")
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "sets-list")
        }
    }
}

struct PreviewSetsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sets-create",
        abstract: "Create (or find) an appPreviewSet for the given (localization, previewType)."
    )
    @Option(name: .long, help: "appStoreVersionLocalization id.") var localizationId: String
    @Option(name: .long, help: "previewType code (e.g. APP_IPHONE_67).") var previewType: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let set = try await AppPreviewsAPI(client: client).findOrCreatePreviewSet(
                localizationID: localizationId, previewType: previewType
            )
            if json { try MarketingCLIHelpers.emitJSON(set); return }
            logger.log("set \(set.id) (\(set.attributes?.previewType ?? "")) ready", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "sets-create")
        }
    }
}

struct PreviewSetsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sets-delete",
        abstract: "Delete an appPreviewSet (and every preview video inside)."
    )
    @Argument(help: "appPreviewSet id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            try await AppPreviewsAPI(client: client).deletePreviewSet(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted appPreviewSet \(id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "sets-delete")
        }
    }
}

struct PreviewsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List previews inside an appPreviewSet."
    )
    @Option(name: .long, help: "appPreviewSet id.") var setId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let previews = try await AppPreviewsAPI(client: client).listPreviews(setID: setId)
            if json { try MarketingCLIHelpers.emitJSON(previews); return }
            logger.header("Previews (\(previews.count))")
            for p in previews {
                print("  \(p.id)  \(p.attributes?.fileName ?? "(no name)")")
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "previews list")
        }
    }
}

struct PreviewsUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload a preview video to an appPreviewSet."
    )
    @Option(name: .long, help: "appPreviewSet id.") var setId: String
    @Option(name: .long, help: "Path to the .mp4/.mov file.") var file: String
    @Option(name: .long, help: "MIME type (default video/mp4).") var mimeType: String?
    @Option(name: .long, help: "Poster-frame timecode (HH:MM:SS.mmm).") var posterTimeCode: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        let progress = MarketingCLIHelpers.uploadProgress(forBytes: bytes, logger: logger)
        do {
            let preview = try await AppPreviewsAPI(client: client).uploadPreview(
                setID: setId,
                fileURL: url,
                mimeType: mimeType,
                previewFrameTimeCode: posterTimeCode,
                chunkProgress: progress
            )
            if json { try MarketingCLIHelpers.emitJSON(preview); return }
            logger.log("uploaded preview \(preview.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "previews upload")
        }
    }
}

struct PreviewsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a single preview."
    )
    @Argument(help: "appPreview id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            try await AppPreviewsAPI(client: client).deletePreview(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted appPreview \(id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "previews delete")
        }
    }
}

// MARK: - storescreens app-clips

struct AppClipsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-clips",
        abstract: "Manage App Clips: experiences, localizations, review details, headers.",
        subcommands: [
            AppClipsListCommand.self,
            AppClipsCreateCommand.self,
            AppClipExperiencesListCommand.self,
            AppClipExperienceCreateCommand.self,
            AppClipExperienceAdvancedListCommand.self,
            AppClipExperienceAdvancedCreateCommand.self,
            AppClipHeadersUploadCommand.self,
            AppClipReviewDetailGetCommand.self,
            AppClipReviewDetailUpdateCommand.self,
        ]
    )
}

struct AppClipsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List App Clips for an app."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let clips = try await AppClipsAPI(client: client).listAppClips(appID: appId)
            if json { try MarketingCLIHelpers.emitJSON(clips); return }
            logger.header("App Clips (\(clips.count))")
            for c in clips {
                print("  \(c.id)  \(c.attributes?.bundleId ?? "")")
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "app-clips list")
        }
    }
}

struct AppClipsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an App Clip resource on an app."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Option(name: .long, help: "Child bundle id (e.g. com.example.app.Clip).") var bundleId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let clip = try await AppClipsAPI(client: client).createAppClip(
                appID: appId, bundleID: bundleId
            )
            if json { try MarketingCLIHelpers.emitJSON(clip); return }
            logger.log("created appClip \(clip.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "app-clips create")
        }
    }
}

struct AppClipExperiencesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experiences-list",
        abstract: "List default experiences on an App Clip."
    )
    @Option(name: .long, help: "appClip id.") var appClipId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let list = try await AppClipsAPI(client: client).listDefaultExperiences(appClipID: appClipId)
            if json { try MarketingCLIHelpers.emitJSON(list); return }
            logger.header("Default experiences (\(list.count))")
            for e in list { print("  \(e.id)  action=\(e.attributes?.action ?? "")") }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiences-list")
        }
    }
}

struct AppClipExperienceCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experience-create",
        abstract: "Create a default experience on an App Clip."
    )
    @Option(name: .long, help: "appClip id.") var appClipId: String
    @Option(name: .long, help: "Action verb (OPEN/VIEW/PLAY).") var action: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let exp = try await AppClipsAPI(client: client).createDefaultExperience(
                appClipID: appClipId, action: action
            )
            if json { try MarketingCLIHelpers.emitJSON(exp); return }
            logger.log("created default experience \(exp.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experience-create")
        }
    }
}

struct AppClipExperienceAdvancedListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experience-advanced-list",
        abstract: "List advanced (URL-triggered) experiences on an App Clip."
    )
    @Option(name: .long, help: "appClip id.") var appClipId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let list = try await AppClipsAPI(client: client).listAdvancedExperiences(appClipID: appClipId)
            if json { try MarketingCLIHelpers.emitJSON(list); return }
            logger.header("Advanced experiences (\(list.count))")
            for e in list {
                print("  \(e.id)  link=\(e.attributes?.link ?? "")")
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experience-advanced-list")
        }
    }
}

struct AppClipExperienceAdvancedCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experience-advanced-create",
        abstract: "Create a URL-triggered advanced experience on an App Clip."
    )
    @Option(name: .long, help: "appClip id.") var appClipId: String
    @Option(name: .long, help: "Trigger URL.") var link: String
    @Option(name: .long, help: "Action verb.") var action: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let exp = try await AppClipsAPI(client: client).createAdvancedExperience(
                appClipID: appClipId, link: link, action: action
            )
            if json { try MarketingCLIHelpers.emitJSON(exp); return }
            logger.log("created advanced experience \(exp.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experience-advanced-create")
        }
    }
}

struct AppClipHeadersUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "header-upload",
        abstract: "Upload a header image to an App Clip default experience localization."
    )
    @Option(name: .long, help: "appClipDefaultExperienceLocalization id.") var experienceLocalizationId: String
    @Option(name: .long, help: "Path to image file.") var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        let progress = MarketingCLIHelpers.uploadProgress(forBytes: bytes, logger: logger)
        do {
            let h = try await AppClipsAPI(client: client).uploadHeader(
                experienceLocalizationID: experienceLocalizationId,
                fileURL: url,
                chunkProgress: progress
            )
            if json { try MarketingCLIHelpers.emitJSON(h); return }
            logger.log("uploaded header \(h.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "header-upload")
        }
    }
}

struct AppClipReviewDetailGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review-detail-get",
        abstract: "Fetch an App Clip's review-detail invocation URLs."
    )
    @Option(name: .long, help: "appClipDefaultExperience id.") var experienceId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let detail = try await AppClipsAPI(client: client).getReviewDetail(experienceID: experienceId)
            if json { try MarketingCLIHelpers.emitJSON(["detail": detail]); return }
            if let detail {
                logger.log("review detail \(detail.id)", level: .success)
                for u in detail.attributes?.invocationUrls ?? [] { print("  \(u)") }
            } else {
                logger.log("no review detail attached", level: .info)
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "review-detail-get")
        }
    }
}

struct AppClipReviewDetailUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review-detail-update",
        abstract: "Set the invocation URLs on an App Clip review-detail record."
    )
    @Argument(help: "appClipAppStoreReviewDetail id.") var id: String
    @Option(name: .long, parsing: .upToNextOption, help: "Invocation URLs.") var invocationUrl: [String] = []
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let d = try await AppClipsAPI(client: client).updateReviewDetail(
                id: id, invocationUrls: invocationUrl.isEmpty ? nil : invocationUrl
            )
            if json { try MarketingCLIHelpers.emitJSON(d); return }
            logger.log("updated review detail \(d.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "review-detail-update")
        }
    }
}

// MARK: - storescreens cpp (Custom Product Pages)

struct CustomProductPagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cpp",
        abstract: "Manage Custom Product Pages (campaign-variant landing pages).",
        subcommands: [
            CPPListCommand.self,
            CPPCreateCommand.self,
            CPPUpdateCommand.self,
            CPPDeleteCommand.self,
            CPPVersionsListCommand.self,
            CPPVersionsCreateCommand.self,
            CPPLocalizationsListCommand.self,
            CPPLocalizationsCreateCommand.self,
            CPPLocalizationsUpdateCommand.self,
        ]
    )
}

struct CPPListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List custom product pages for an app."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Option(name: .long, help: "Pagination cursor.") var cursor: String?
    @Option(name: .long, help: "Page size (default 200).") var limit: Int = 200
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let result = try await CustomProductPagesAPI(client: client).listPages(
                appID: appId, limit: limit, cursor: cursor
            )
            if json {
                struct Out: Encodable {
                    let pages: [CustomProductPagesAPI.Page]
                    let nextCursor: String?
                }
                try MarketingCLIHelpers.emitJSON(Out(pages: result.pages, nextCursor: result.nextCursor))
                return
            }
            logger.header("Custom product pages (\(result.pages.count))")
            for p in result.pages {
                let vis = p.attributes?.visible == true ? "visible" : "hidden"
                print("  \(p.id)  \(p.attributes?.name ?? "")  [\(vis)]")
            }
            if let next = result.nextCursor { print("  (more: cursor \(next))") }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "cpp list")
        }
    }
}

struct CPPCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a custom product page."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Option(name: .long, help: "Display name for the page.") var name: String
    @Flag(name: .long, inversion: .prefixedNo, help: "Whether the page is visible (default yes).") var visible: Bool = true
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let page = try await CustomProductPagesAPI(client: client).createPage(
                appID: appId, name: name, visible: visible
            )
            if json { try MarketingCLIHelpers.emitJSON(page); return }
            logger.log("created cpp \(page.id) (\(page.attributes?.name ?? ""))", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "cpp create")
        }
    }
}

struct CPPUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a custom product page's name or visibility."
    )
    @Argument(help: "customProductPage id.") var id: String
    @Option(name: .long, help: "New name.") var name: String?
    @Flag(name: .long, inversion: .prefixedNo, help: "Set visibility.") var visible: Bool?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let page = try await CustomProductPagesAPI(client: client).updatePage(
                id: id, name: name, visible: visible
            )
            if json { try MarketingCLIHelpers.emitJSON(page); return }
            logger.log("updated cpp \(page.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "cpp update")
        }
    }
}

struct CPPDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a custom product page."
    )
    @Argument(help: "customProductPage id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            try await CustomProductPagesAPI(client: client).deletePage(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted cpp \(id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "cpp delete")
        }
    }
}

struct CPPVersionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "versions-list",
        abstract: "List versions of a custom product page."
    )
    @Option(name: .long, help: "customProductPage id.") var pageId: String
    @Option(name: .long, help: "Pagination cursor.") var cursor: String?
    @Option(name: .long, help: "Page size.") var limit: Int = 200
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let result = try await CustomProductPagesAPI(client: client).listVersions(
                pageID: pageId, limit: limit, cursor: cursor
            )
            if json {
                struct Out: Encodable {
                    let versions: [CustomProductPagesAPI.Version]
                    let nextCursor: String?
                }
                try MarketingCLIHelpers.emitJSON(Out(versions: result.versions, nextCursor: result.nextCursor))
                return
            }
            logger.header("Versions (\(result.versions.count))")
            for v in result.versions {
                print("  \(v.id)  state=\(v.attributes?.state ?? "")")
            }
            if let next = result.nextCursor { print("  (more: cursor \(next))") }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "cpp versions-list")
        }
    }
}

struct CPPVersionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "versions-create",
        abstract: "Create a fresh editable version on a custom product page."
    )
    @Option(name: .long, help: "customProductPage id.") var pageId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let v = try await CustomProductPagesAPI(client: client).createVersion(pageID: pageId)
            if json { try MarketingCLIHelpers.emitJSON(v); return }
            logger.log("created cpp version \(v.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "cpp versions-create")
        }
    }
}

struct CPPLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localizations-list",
        abstract: "List per-locale localizations on a cpp version."
    )
    @Option(name: .long, help: "customProductPageVersion id.") var versionId: String
    @Option(name: .long, help: "Pagination cursor.") var cursor: String?
    @Option(name: .long, help: "Page size.") var limit: Int = 200
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let result = try await CustomProductPagesAPI(client: client).listLocalizations(
                versionID: versionId, limit: limit, cursor: cursor
            )
            if json {
                struct Out: Encodable {
                    let localizations: [CustomProductPagesAPI.Localization]
                    let nextCursor: String?
                }
                try MarketingCLIHelpers.emitJSON(Out(localizations: result.localizations, nextCursor: result.nextCursor))
                return
            }
            logger.header("Localizations (\(result.localizations.count))")
            for loc in result.localizations {
                print("  \(loc.id)  \(loc.attributes?.locale ?? "")")
            }
            if let next = result.nextCursor { print("  (more: cursor \(next))") }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "cpp localizations-list")
        }
    }
}

struct CPPLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localizations-create",
        abstract: "Create a per-locale localization with promotional text on a cpp version."
    )
    @Option(name: .long, help: "customProductPageVersion id.") var versionId: String
    @Option(name: .long, help: "Locale (e.g. en-US).") var locale: String
    @Option(name: .long, help: "Promotional text.") var promotionalText: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let loc = try await CustomProductPagesAPI(client: client).createLocalization(
                versionID: versionId, locale: locale, promotionalText: promotionalText
            )
            if json { try MarketingCLIHelpers.emitJSON(loc); return }
            logger.log("created cpp localization \(loc.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "cpp localizations-create")
        }
    }
}

struct CPPLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localizations-update",
        abstract: "Update promotional text on a cpp localization."
    )
    @Argument(help: "customProductPageLocalization id.") var id: String
    @Option(name: .long, help: "Promotional text.") var promotionalText: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let loc = try await CustomProductPagesAPI(client: client).updateLocalization(
                id: id, promotionalText: promotionalText
            )
            if json { try MarketingCLIHelpers.emitJSON(loc); return }
            logger.log("updated cpp localization \(loc.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "cpp localizations-update")
        }
    }
}

// MARK: - storescreens events (App Events)

struct EventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Manage in-app App Events (in-store tournaments, premieres, content drops).",
        subcommands: [
            EventsListCommand.self,
            EventsGetCommand.self,
            EventsCreateCommand.self,
            EventsUpdateCommand.self,
            EventsDeleteCommand.self,
            EventsLocalizationsListCommand.self,
            EventsLocalizationsCreateCommand.self,
            EventsLocalizationsUpdateCommand.self,
            EventsScreenshotsUploadCommand.self,
            EventsVideosUploadCommand.self,
        ]
    )
}

struct EventsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List App Events for an app."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Option(name: .long, help: "Pagination cursor.") var cursor: String?
    @Option(name: .long, help: "Page size.") var limit: Int = 200
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let result = try await AppEventsAPI(client: client).listAppEvents(
                appID: appId, limit: limit, cursor: cursor
            )
            if json {
                struct Out: Encodable {
                    let events: [AppEventsAPI.AppEvent]
                    let nextCursor: String?
                }
                try MarketingCLIHelpers.emitJSON(Out(events: result.events, nextCursor: result.nextCursor))
                return
            }
            logger.header("App Events (\(result.events.count))")
            for e in result.events {
                let name = e.attributes?.referenceName ?? "(no name)"
                let state = e.attributes?.eventState ?? "(no state)"
                print("  \(e.id)  \(name)  [\(state)]")
            }
            if let next = result.nextCursor { print("  (more: cursor \(next))") }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events list")
        }
    }
}

struct EventsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a single App Event."
    )
    @Argument(help: "appEvent id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let e = try await AppEventsAPI(client: client).getAppEvent(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["event": e]); return }
            if let e {
                logger.log("event \(e.id) state=\(e.attributes?.eventState ?? "?")", level: .success)
            } else {
                logger.log("no event \(id)", level: .warning)
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events get")
        }
    }
}

struct EventsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an App Event on an app."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Option(name: .long, help: "Internal reference name.") var referenceName: String?
    @Option(name: .long, help: "Badge code.") var badge: String?
    @Option(name: .long, help: "In-app deep link.") var deepLink: String?
    @Option(name: .long, help: "Purchase requirement.") var purchaseRequirement: String?
    @Option(name: .long, help: "Primary locale.") var primaryLocale: String?
    @Option(name: .long, help: "Priority code.") var priority: String?
    @Option(name: .long, help: "Purpose code.") var purpose: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let fields = AppEventsAPI.EventFields(
            referenceName: referenceName,
            badge: badge,
            deepLink: deepLink,
            purchaseRequirement: purchaseRequirement,
            primaryLocale: primaryLocale,
            priority: priority,
            purpose: purpose
        )
        do {
            let event = try await AppEventsAPI(client: client).createAppEvent(
                appID: appId, fields: fields
            )
            if json { try MarketingCLIHelpers.emitJSON(event); return }
            logger.log("created event \(event.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events create")
        }
    }
}

struct EventsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an App Event's fields."
    )
    @Argument(help: "appEvent id.") var id: String
    @Option(name: .long, help: "Reference name.") var referenceName: String?
    @Option(name: .long, help: "Badge code.") var badge: String?
    @Option(name: .long, help: "Deep link.") var deepLink: String?
    @Option(name: .long, help: "Purchase requirement.") var purchaseRequirement: String?
    @Option(name: .long, help: "Primary locale.") var primaryLocale: String?
    @Option(name: .long, help: "Priority code.") var priority: String?
    @Option(name: .long, help: "Purpose code.") var purpose: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let fields = AppEventsAPI.EventFields(
            referenceName: referenceName,
            badge: badge,
            deepLink: deepLink,
            purchaseRequirement: purchaseRequirement,
            primaryLocale: primaryLocale,
            priority: priority,
            purpose: purpose
        )
        do {
            let event = try await AppEventsAPI(client: client).updateAppEvent(id: id, fields: fields)
            if json { try MarketingCLIHelpers.emitJSON(event); return }
            logger.log("updated event \(event.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events update")
        }
    }
}

struct EventsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an App Event."
    )
    @Argument(help: "appEvent id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            try await AppEventsAPI(client: client).deleteAppEvent(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted event \(id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events delete")
        }
    }
}

struct EventsLocalizationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localizations-list",
        abstract: "List per-locale localizations on an App Event."
    )
    @Option(name: .long, help: "appEvent id.") var eventId: String
    @Option(name: .long, help: "Pagination cursor.") var cursor: String?
    @Option(name: .long, help: "Page size.") var limit: Int = 200
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let result = try await AppEventsAPI(client: client).listLocalizations(
                eventID: eventId, limit: limit, cursor: cursor
            )
            if json {
                struct Out: Encodable {
                    let localizations: [AppEventsAPI.EventLocalization]
                    let nextCursor: String?
                }
                try MarketingCLIHelpers.emitJSON(Out(localizations: result.localizations, nextCursor: result.nextCursor))
                return
            }
            logger.header("Event localizations (\(result.localizations.count))")
            for loc in result.localizations {
                print("  \(loc.id)  \(loc.attributes?.locale ?? "")")
            }
            if let next = result.nextCursor { print("  (more: cursor \(next))") }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events localizations-list")
        }
    }
}

struct EventsLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localizations-create",
        abstract: "Create a per-locale localization for an App Event."
    )
    @Option(name: .long, help: "appEvent id.") var eventId: String
    @Option(name: .long, help: "Locale.") var locale: String
    @Option(name: .long, help: "Name.") var name: String?
    @Option(name: .long, help: "Short description.") var shortDescription: String?
    @Option(name: .long, help: "Long description.") var longDescription: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let loc = try await AppEventsAPI(client: client).createLocalization(
                eventID: eventId, locale: locale,
                name: name, shortDescription: shortDescription, longDescription: longDescription
            )
            if json { try MarketingCLIHelpers.emitJSON(loc); return }
            logger.log("created event localization \(loc.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events localizations-create")
        }
    }
}

struct EventsLocalizationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localizations-update",
        abstract: "Update an App Event localization."
    )
    @Argument(help: "appEventLocalization id.") var id: String
    @Option(name: .long, help: "Name.") var name: String?
    @Option(name: .long, help: "Short description.") var shortDescription: String?
    @Option(name: .long, help: "Long description.") var longDescription: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let loc = try await AppEventsAPI(client: client).updateLocalization(
                id: id, name: name, shortDescription: shortDescription, longDescription: longDescription
            )
            if json { try MarketingCLIHelpers.emitJSON(loc); return }
            logger.log("updated event localization \(loc.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events localizations-update")
        }
    }
}

struct EventsScreenshotsUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot-upload",
        abstract: "Upload a screenshot to an App Event localization."
    )
    @Option(name: .long, help: "appEventLocalization id.") var localizationId: String
    @Option(name: .long, help: "Path to the PNG.") var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        let progress = MarketingCLIHelpers.uploadProgress(forBytes: bytes, logger: logger)
        do {
            let shot = try await AppEventsAPI(client: client).uploadScreenshot(
                localizationID: localizationId, fileURL: url, chunkProgress: progress
            )
            if json { try MarketingCLIHelpers.emitJSON(shot); return }
            logger.log("uploaded event screenshot \(shot.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events screenshot-upload")
        }
    }
}

struct EventsVideosUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video-upload",
        abstract: "Upload a video clip to an App Event localization."
    )
    @Option(name: .long, help: "appEventLocalization id.") var localizationId: String
    @Option(name: .long, help: "Path to the video file.") var file: String
    @Option(name: .long, help: "Poster-frame timecode.") var posterTimeCode: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        let progress = MarketingCLIHelpers.uploadProgress(forBytes: bytes, logger: logger)
        do {
            let clip = try await AppEventsAPI(client: client).uploadVideoClip(
                localizationID: localizationId,
                fileURL: url,
                previewFrameTimeCode: posterTimeCode,
                chunkProgress: progress
            )
            if json { try MarketingCLIHelpers.emitJSON(clip); return }
            logger.log("uploaded event video \(clip.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "events video-upload")
        }
    }
}

// MARK: - storescreens experiments

struct ExperimentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experiments",
        abstract: "Manage App Store Version Experiments (A/B tests on screenshots + product pages).",
        subcommands: [
            ExperimentsListCommand.self,
            ExperimentsGetCommand.self,
            ExperimentsCreateCommand.self,
            ExperimentsUpdateCommand.self,
            ExperimentsDeleteCommand.self,
            ExperimentsTreatmentsListCommand.self,
            ExperimentsTreatmentsCreateCommand.self,
            ExperimentsTreatmentLocalizationsCreateCommand.self,
            ExperimentsTreatmentScreenshotsUploadCommand.self,
            ExperimentsTreatmentPreviewsUploadCommand.self,
        ]
    )
}

struct ExperimentsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List experiments on an App Store version."
    )
    @Option(name: .long, help: "appStoreVersion id.") var versionId: String
    @Option(name: .long, help: "Pagination cursor.") var cursor: String?
    @Option(name: .long, help: "Page size.") var limit: Int = 200
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let result = try await ExperimentsAPI(client: client).listExperiments(
                versionID: versionId, limit: limit, cursor: cursor
            )
            if json {
                struct Out: Encodable {
                    let experiments: [ExperimentsAPI.Experiment]
                    let nextCursor: String?
                }
                try MarketingCLIHelpers.emitJSON(Out(experiments: result.experiments, nextCursor: result.nextCursor))
                return
            }
            logger.header("Experiments (\(result.experiments.count))")
            for e in result.experiments {
                let name = e.attributes?.name ?? "(no name)"
                let state = e.attributes?.state ?? "(no state)"
                print("  \(e.id)  \(name)  [\(state)]")
            }
            if let next = result.nextCursor { print("  (more: cursor \(next))") }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments list")
        }
    }
}

struct ExperimentsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a single experiment."
    )
    @Argument(help: "appStoreVersionExperiment id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let exp = try await ExperimentsAPI(client: client).getExperiment(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["experiment": exp]); return }
            if let exp {
                logger.log("experiment \(exp.id) state=\(exp.attributes?.state ?? "?")", level: .success)
            } else {
                logger.log("no experiment \(id)", level: .warning)
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments get")
        }
    }
}

struct ExperimentsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an A/B experiment on a version."
    )
    @Option(name: .long, help: "appStoreVersion id.") var versionId: String
    @Option(name: .long, help: "Experiment name.") var name: String
    @Option(name: .long, help: "Traffic share (0-100).") var trafficProportion: Int?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let exp = try await ExperimentsAPI(client: client).createExperiment(
                versionID: versionId, name: name, trafficProportion: trafficProportion
            )
            if json { try MarketingCLIHelpers.emitJSON(exp); return }
            logger.log("created experiment \(exp.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments create")
        }
    }
}

struct ExperimentsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an experiment (rename, change traffic share, or start it)."
    )
    @Argument(help: "appStoreVersionExperiment id.") var id: String
    @Option(name: .long, help: "New name.") var name: String?
    @Option(name: .long, help: "Traffic share.") var trafficProportion: Int?
    @Flag(name: .long, inversion: .prefixedNo, help: "Flip to --started to launch.") var started: Bool?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let exp = try await ExperimentsAPI(client: client).updateExperiment(
                id: id, name: name, trafficProportion: trafficProportion, started: started
            )
            if json { try MarketingCLIHelpers.emitJSON(exp); return }
            logger.log("updated experiment \(exp.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments update")
        }
    }
}

struct ExperimentsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an experiment."
    )
    @Argument(help: "appStoreVersionExperiment id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            try await ExperimentsAPI(client: client).deleteExperiment(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted experiment \(id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments delete")
        }
    }
}

struct ExperimentsTreatmentsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "treatments-list",
        abstract: "List treatments (variants) for an experiment."
    )
    @Option(name: .long, help: "appStoreVersionExperiment id.") var experimentId: String
    @Option(name: .long, help: "Pagination cursor.") var cursor: String?
    @Option(name: .long, help: "Page size.") var limit: Int = 200
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let result = try await ExperimentsAPI(client: client).listTreatments(
                experimentID: experimentId, limit: limit, cursor: cursor
            )
            if json {
                struct Out: Encodable {
                    let treatments: [ExperimentsAPI.Treatment]
                    let nextCursor: String?
                }
                try MarketingCLIHelpers.emitJSON(Out(treatments: result.treatments, nextCursor: result.nextCursor))
                return
            }
            logger.header("Treatments (\(result.treatments.count))")
            for t in result.treatments {
                let name = t.attributes?.name ?? "(no name)"
                print("  \(t.id)  \(name)")
            }
            if let next = result.nextCursor { print("  (more: cursor \(next))") }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments treatments-list")
        }
    }
}

struct ExperimentsTreatmentsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "treatments-create",
        abstract: "Create a treatment variant on an experiment."
    )
    @Option(name: .long, help: "appStoreVersionExperiment id.") var experimentId: String
    @Option(name: .long, help: "Treatment name.") var name: String
    @Option(name: .long, help: "Traffic share.") var trafficProportion: Int?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let t = try await ExperimentsAPI(client: client).createTreatment(
                experimentID: experimentId, name: name, trafficProportion: trafficProportion
            )
            if json { try MarketingCLIHelpers.emitJSON(t); return }
            logger.log("created treatment \(t.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments treatments-create")
        }
    }
}

struct ExperimentsTreatmentLocalizationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "treatment-localizations-create",
        abstract: "Create a per-locale localization on a treatment."
    )
    @Option(name: .long, help: "appStoreVersionExperimentTreatment id.") var treatmentId: String
    @Option(name: .long, help: "Locale.") var locale: String
    @Option(name: .long, help: "Promotional text.") var promotionalText: String?
    @Option(name: .long, help: "Description.") var description: String?
    @Option(name: .long, help: "Keywords (comma-separated).") var keywords: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let loc = try await ExperimentsAPI(client: client).createTreatmentLocalization(
                treatmentID: treatmentId, locale: locale,
                promotionalText: promotionalText, description: description, keywords: keywords
            )
            if json { try MarketingCLIHelpers.emitJSON(loc); return }
            logger.log("created treatment localization \(loc.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments treatment-localizations-create")
        }
    }
}

struct ExperimentsTreatmentScreenshotsUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "treatment-screenshot-upload",
        abstract: "Upload a screenshot to a treatment's appScreenshotSet."
    )
    @Option(name: .long, help: "appScreenshotSet id (treatment-owned).") var setId: String
    @Option(name: .long, help: "Path to the PNG.") var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        let progress = MarketingCLIHelpers.uploadProgress(forBytes: bytes, logger: logger)
        do {
            let shot = try await ExperimentsAPI(client: client).uploadTreatmentScreenshot(
                setID: setId, fileURL: url, chunkProgress: progress
            )
            if json { try MarketingCLIHelpers.emitJSON(shot); return }
            logger.log("uploaded treatment screenshot \(shot.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments treatment-screenshot-upload")
        }
    }
}

struct ExperimentsTreatmentPreviewsUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "treatment-preview-upload",
        abstract: "Upload a preview video to a treatment's appPreviewSet."
    )
    @Option(name: .long, help: "appPreviewSet id (treatment-owned).") var setId: String
    @Option(name: .long, help: "Path to the video.") var file: String
    @Option(name: .long, help: "MIME type.") var mimeType: String?
    @Option(name: .long, help: "Poster-frame timecode.") var posterTimeCode: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        let progress = MarketingCLIHelpers.uploadProgress(forBytes: bytes, logger: logger)
        do {
            let preview = try await ExperimentsAPI(client: client).uploadTreatmentPreview(
                setID: setId, fileURL: url, mimeType: mimeType,
                previewFrameTimeCode: posterTimeCode, chunkProgress: progress
            )
            if json { try MarketingCLIHelpers.emitJSON(preview); return }
            logger.log("uploaded treatment preview \(preview.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "experiments treatment-preview-upload")
        }
    }
}

// MARK: - storescreens encryption-decl

struct EncryptionDeclCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encryption-decl",
        abstract: "Manage app encryption declarations (standalone ERN-style paperwork).",
        subcommands: [
            EncryptionDeclListCommand.self,
            EncryptionDeclGetCommand.self,
            EncryptionDeclCreateCommand.self,
            EncryptionDeclUpdateCommand.self,
            EncryptionDeclDocumentsListCommand.self,
            EncryptionDeclDocumentsUploadCommand.self,
            EncryptionDeclDocumentsDeleteCommand.self,
        ]
    )
}

struct EncryptionDeclListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List encryption declarations for an app."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Option(name: .long, help: "Pagination cursor.") var cursor: String?
    @Option(name: .long, help: "Page size.") var limit: Int = 200
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let result = try await EncryptionDeclarationsAPI(client: client).listDeclarations(
                appID: appId, limit: limit, cursor: cursor
            )
            if json {
                struct Out: Encodable {
                    let declarations: [EncryptionDeclarationsAPI.Declaration]
                    let nextCursor: String?
                }
                try MarketingCLIHelpers.emitJSON(Out(declarations: result.declarations, nextCursor: result.nextCursor))
                return
            }
            logger.header("Encryption declarations (\(result.declarations.count))")
            for d in result.declarations {
                let state = d.attributes?.appEncryptionDeclarationState ?? "(no state)"
                print("  \(d.id)  [\(state)]")
            }
            if let next = result.nextCursor { print("  (more: cursor \(next))") }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "encryption-decl list")
        }
    }
}

struct EncryptionDeclGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a single encryption declaration."
    )
    @Argument(help: "appEncryptionDeclaration id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let d = try await EncryptionDeclarationsAPI(client: client).getDeclaration(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["declaration": d]); return }
            if let d {
                logger.log("declaration \(d.id) state=\(d.attributes?.appEncryptionDeclarationState ?? "?")", level: .success)
            } else {
                logger.log("no declaration \(id)", level: .warning)
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "encryption-decl get")
        }
    }
}

struct EncryptionDeclCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an encryption declaration on an app."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Flag(name: .long, inversion: .prefixedNo, help: "App uses encryption.") var usesEncryption: Bool?
    @Flag(name: .long, inversion: .prefixedNo, help: "Contains proprietary cryptography.") var containsProprietaryCryptography: Bool?
    @Flag(name: .long, inversion: .prefixedNo, help: "Contains third-party cryptography.") var containsThirdPartyCryptography: Bool?
    @Flag(name: .long, inversion: .prefixedNo, help: "Available on French App Store.") var availableOnFrenchStore: Bool?
    @Option(name: .long, help: "Platform (IOS / MAC_OS / TV_OS / VISION_OS).") var platform: String?
    @Flag(name: .long, inversion: .prefixedNo, help: "Exempt from export compliance.") var exempt: Bool?
    @Option(name: .long, help: "Document name.") var documentName: String?
    @Option(name: .long, help: "Document type.") var documentType: String?
    @Option(name: .long, help: "Code value / ERN.") var codeValue: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let fields = EncryptionDeclarationsAPI.DeclarationFields(
            usesEncryption: usesEncryption,
            containsProprietaryCryptography: containsProprietaryCryptography,
            containsThirdPartyCryptography: containsThirdPartyCryptography,
            availableOnFrenchStore: availableOnFrenchStore,
            platform: platform,
            exempt: exempt,
            documentName: documentName,
            documentType: documentType,
            codeValue: codeValue
        )
        do {
            let d = try await EncryptionDeclarationsAPI(client: client).createDeclaration(
                appID: appId, fields: fields
            )
            if json { try MarketingCLIHelpers.emitJSON(d); return }
            logger.log("created declaration \(d.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "encryption-decl create")
        }
    }
}

struct EncryptionDeclUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an encryption declaration."
    )
    @Argument(help: "appEncryptionDeclaration id.") var id: String
    @Flag(name: .long, inversion: .prefixedNo, help: "App uses encryption.") var usesEncryption: Bool?
    @Flag(name: .long, inversion: .prefixedNo, help: "Contains proprietary cryptography.") var containsProprietaryCryptography: Bool?
    @Flag(name: .long, inversion: .prefixedNo, help: "Contains third-party cryptography.") var containsThirdPartyCryptography: Bool?
    @Flag(name: .long, inversion: .prefixedNo, help: "Available on French App Store.") var availableOnFrenchStore: Bool?
    @Option(name: .long, help: "Platform.") var platform: String?
    @Flag(name: .long, inversion: .prefixedNo, help: "Exempt from export compliance.") var exempt: Bool?
    @Option(name: .long, help: "Document name.") var documentName: String?
    @Option(name: .long, help: "Document type.") var documentType: String?
    @Option(name: .long, help: "Code value / ERN.") var codeValue: String?
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let fields = EncryptionDeclarationsAPI.DeclarationFields(
            usesEncryption: usesEncryption,
            containsProprietaryCryptography: containsProprietaryCryptography,
            containsThirdPartyCryptography: containsThirdPartyCryptography,
            availableOnFrenchStore: availableOnFrenchStore,
            platform: platform,
            exempt: exempt,
            documentName: documentName,
            documentType: documentType,
            codeValue: codeValue
        )
        do {
            let d = try await EncryptionDeclarationsAPI(client: client).updateDeclaration(
                id: id, fields: fields
            )
            if json { try MarketingCLIHelpers.emitJSON(d); return }
            logger.log("updated declaration \(d.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "encryption-decl update")
        }
    }
}

struct EncryptionDeclDocumentsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "documents-list",
        abstract: "List supporting documents attached to a declaration."
    )
    @Option(name: .long, help: "appEncryptionDeclaration id.") var declarationId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let docs = try await EncryptionDeclarationsAPI(client: client).listDocuments(declarationID: declarationId)
            if json { try MarketingCLIHelpers.emitJSON(docs); return }
            logger.header("Documents (\(docs.count))")
            for d in docs {
                print("  \(d.id)  \(d.attributes?.fileName ?? "")")
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "encryption-decl documents-list")
        }
    }
}

struct EncryptionDeclDocumentsUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "documents-upload",
        abstract: "Upload a supporting document to an encryption declaration."
    )
    @Option(name: .long, help: "appEncryptionDeclaration id.") var declarationId: String
    @Option(name: .long, help: "Path to the document file.") var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        let progress = MarketingCLIHelpers.uploadProgress(forBytes: bytes, logger: logger)
        do {
            let doc = try await EncryptionDeclarationsAPI(client: client).uploadDocument(
                declarationID: declarationId, fileURL: url, chunkProgress: progress
            )
            if json { try MarketingCLIHelpers.emitJSON(doc); return }
            logger.log("uploaded document \(doc.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "encryption-decl documents-upload")
        }
    }
}

struct EncryptionDeclDocumentsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "documents-delete",
        abstract: "Delete a supporting document."
    )
    @Argument(help: "appEncryptionDeclarationDocument id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            try await EncryptionDeclarationsAPI(client: client).deleteDocument(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted document \(id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "encryption-decl documents-delete")
        }
    }
}

// MARK: - storescreens routing-coverage

struct RoutingCoverageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "routing-coverage",
        abstract: "Manage the routing-app coverage JSON file attached to a Driving / Navigation app.",
        subcommands: [
            RoutingCoverageGetCommand.self,
            RoutingCoverageUploadCommand.self,
            RoutingCoverageDeleteCommand.self,
        ]
    )
}

struct RoutingCoverageGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get the routing coverage attached to an app."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            let cov = try await RoutingCoverageAPI(client: client).getCoverage(appID: appId)
            if json { try MarketingCLIHelpers.emitJSON(["coverage": cov]); return }
            if let cov {
                let state = cov.attributes?.assetDeliveryState?.state ?? "(no state)"
                logger.log("coverage \(cov.id) [\(state)]", level: .success)
            } else {
                logger.log("no routing coverage attached", level: .info)
            }
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "routing-coverage get")
        }
    }
}

struct RoutingCoverageUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload a routing coverage file to an app."
    )
    @Option(name: .long, help: "App id.") var appId: String
    @Option(name: .long, help: "Path to the .geojson / .json file.") var file: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        let url = URL(fileURLWithPath: file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        let progress = MarketingCLIHelpers.uploadProgress(forBytes: bytes, logger: logger)
        do {
            let cov = try await RoutingCoverageAPI(client: client).uploadCoverage(
                appID: appId, fileURL: url, chunkProgress: progress
            )
            if json { try MarketingCLIHelpers.emitJSON(cov); return }
            logger.log("uploaded routing coverage \(cov.id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "routing-coverage upload")
        }
    }
}

struct RoutingCoverageDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an app's routing coverage."
    )
    @Argument(help: "routingAppCoverage id.") var id: String
    @Flag(name: .long, help: "Emit JSON.") var json: Bool = false
    func run() async throws {
        let logger = Logger()
        let client = try MarketingCLIHelpers.loadClient(logger: logger)
        do {
            try await RoutingCoverageAPI(client: client).deleteCoverage(id: id)
            if json { try MarketingCLIHelpers.emitJSON(["deleted": id]); return }
            logger.log("deleted routing coverage \(id)", level: .success)
        } catch {
            throw MarketingCLIHelpers.failAPI(error, logger: logger, context: "routing-coverage delete")
        }
    }
}
