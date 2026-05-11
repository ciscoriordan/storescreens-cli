import ArgumentParser
import Foundation
import StorescreensCore

/// Parent command for the grab-bag of late-2025 niche resources covered
/// by `Wave4ExtrasAPI`: merchantIds, nominations, appTags,
/// endUserLicenseAgreements, androidToIosAppMappingDetails, actors,
/// appPricePoints V3, appClipAdvancedExperienceImages,
/// inAppPurchaseAvailabilities, inAppPurchaseContents,
/// territoryAvailabilities.
///
/// All subcommands resolve credentials through
/// `ASCCredentialResolver.resolve()` and emit either a human-readable
/// summary or pretty-printed JSON (with `--json`). This file does not
/// register itself in Main.swift; the parent agent wires it in.
struct AscExtrasCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "asc-extras",
        abstract: "Grab-bag of small App Store Connect resource families.",
        discussion: """
            Wraps the late-2025 niche resources Apple added to the App \
            Store Connect API: merchant ids, editorial nominations, \
            app tags, custom EULAs, Android-to-iOS mapping, in-app \
            actors, app price points V3, app clip advanced experience \
            images, in-app purchase availabilities + contents, and \
            per-app territory availabilities.
            """,
        subcommands: [
            AscExtrasMerchantIdsCommand.self,
            AscExtrasNominationsCommand.self,
            AscExtrasAppTagsCommand.self,
            AscExtrasEulasCommand.self,
            AscExtrasAndroidToIosCommand.self,
            AscExtrasActorsCommand.self,
            AscExtrasAppPricePointsV3Command.self,
            AscExtrasAppClipImagesCommand.self,
            AscExtrasIapAvailabilitiesCommand.self,
            AscExtrasIapContentsCommand.self,
            AscExtrasTerritoryAvailabilitiesCommand.self,
        ]
    )
}

// MARK: - Shared plumbing

private enum AscExtrasJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private func resolveAscExtras(logger: Logger) async throws -> Wave4ExtrasAPI {
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

private struct EncodableAscExtrasPage<Item: Encodable>: Encodable {
    let items: [Item]
    let nextCursor: String?
}

// MARK: - Merchant IDs

struct AscExtrasMerchantIdsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merchant-ids",
        abstract: "Apple Pay merchant identifiers (distinct from merchantDomains).",
        subcommands: [
            AscExtrasMerchantIdsListCommand.self,
            AscExtrasMerchantIdsGetCommand.self,
            AscExtrasMerchantIdsCreateCommand.self,
            AscExtrasMerchantIdsUpdateCommand.self,
            AscExtrasMerchantIdsDeleteCommand.self,
        ]
    )
}

struct AscExtrasMerchantIdsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List merchant ids on the team.")
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).merchant
        let page = try await api.listMerchantIDs(limit: limit, cursor: cursor)
        if json {
            print(try AscExtrasJSON.encode(
                EncodableAscExtrasPage(items: page.items, nextCursor: page.nextCursor)
            ))
            return
        }
        logger.header("Merchant ids (\(page.items.count))")
        for m in page.items {
            print("  \(m.id)\t\(m.attributes?.identifier ?? "")\t\(m.attributes?.name ?? "")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct AscExtrasMerchantIdsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch one merchant id.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).merchant
        guard let m = try await api.getMerchantID(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json { print(try AscExtrasJSON.encode(m)); return }
        logger.header("Merchant id")
        print("  id:          \(m.id)")
        print("  identifier:  \(m.attributes?.identifier ?? "(none)")")
        print("  name:        \(m.attributes?.name ?? "(none)")")
    }
}

struct AscExtrasMerchantIdsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Register a new merchant id.")
    @Option(name: .long, help: "Dotted reverse-DNS merchant id (e.g. merchant.com.example).") var identifier: String
    @Option(name: .long) var name: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).merchant
        let m = try await api.createMerchantID(identifier: identifier, name: name)
        if json { print(try AscExtrasJSON.encode(m)); return }
        logger.log("created merchant id \(m.id) (\(identifier))", level: .success)
    }
}

struct AscExtrasMerchantIdsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Rename a merchant id's display label.")
    @Argument var id: String
    @Option(name: .long) var name: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).merchant
        let m = try await api.updateMerchantID(id: id, name: name)
        if json { print(try AscExtrasJSON.encode(m)); return }
        logger.log("renamed merchant id \(m.id)", level: .success)
    }
}

struct AscExtrasMerchantIdsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a merchant id.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).merchant
        try await api.deleteMerchantID(id: id)
        logger.log("deleted merchant id \(id)", level: .success)
    }
}

// MARK: - Nominations

struct AscExtrasNominationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nominations",
        abstract: "App Store editorial feature nominations.",
        subcommands: [
            AscExtrasNominationsListCommand.self,
            AscExtrasNominationsGetCommand.self,
            AscExtrasNominationsCreateCommand.self,
            AscExtrasNominationsUpdateCommand.self,
            AscExtrasNominationsDeleteCommand.self,
        ]
    )
}

struct AscExtrasNominationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List nominations on an app.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).nominations
        let page = try await api.listNominations(appID: appId, limit: limit, cursor: cursor)
        if json {
            print(try AscExtrasJSON.encode(
                EncodableAscExtrasPage(items: page.items, nextCursor: page.nextCursor)
            ))
            return
        }
        logger.header("Nominations (\(page.items.count))")
        for n in page.items {
            print("  \(n.id)\t\(n.attributes?.title ?? "")\tstate=\(n.attributes?.state ?? "")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct AscExtrasNominationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a nomination.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).nominations
        guard let n = try await api.getNomination(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json { print(try AscExtrasJSON.encode(n)); return }
        logger.header("Nomination")
        print("  id:    \(n.id)")
        print("  title: \(n.attributes?.title ?? "(none)")")
        print("  state: \(n.attributes?.state ?? "(none)")")
    }
}

struct AscExtrasNominationsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Submit a new nomination.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var title: String
    @Option(name: .long) var description: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).nominations
        let n = try await api.createNomination(appID: appId, title: title, description: description)
        if json { print(try AscExtrasJSON.encode(n)); return }
        logger.log("created nomination \(n.id)", level: .success)
    }
}

struct AscExtrasNominationsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Edit a nomination's title or description.")
    @Argument var id: String
    @Option(name: .long) var title: String?
    @Option(name: .long) var description: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).nominations
        let n = try await api.updateNomination(id: id, title: title, description: description)
        if json { print(try AscExtrasJSON.encode(n)); return }
        logger.log("updated nomination \(n.id)", level: .success)
    }
}

struct AscExtrasNominationsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a nomination.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).nominations
        try await api.deleteNomination(id: id)
        logger.log("deleted nomination \(id)", level: .success)
    }
}

// MARK: - App tags

struct AscExtrasAppTagsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-tags",
        abstract: "Per-territory app tags from Apple's editorial taxonomy.",
        subcommands: [
            AscExtrasAppTagsUpdateCommand.self,
        ]
    )
}

struct AscExtrasAppTagsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Replace an app's per-territory tag list with the supplied set."
    )

    @Option(name: .long) var appId: String
    @Option(name: .long) var territoryId: String
    @Option(name: .long, parsing: .upToNextOption, help: "appTag ids to apply. Pass none to clear.") var tagIds: [String]
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).appTags
        let tags = try await api.updateAppTags(
            appID: appId, territoryID: territoryId, tagIDs: tagIds
        )
        if json {
            print(try AscExtrasJSON.encode(tags))
            return
        }
        logger.log("updated app tags for app=\(appId) territory=\(territoryId) (\(tags.count) tags)", level: .success)
        for t in tags {
            print("  \(t.id)\t\(t.attributes?.tag ?? "")\t\(t.attributes?.displayName ?? "")")
        }
    }
}

// MARK: - EULAs

struct AscExtrasEulasCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eulas",
        abstract: "Custom per-app EULA records.",
        subcommands: [
            AscExtrasEulasListCommand.self,
            AscExtrasEulasGetCommand.self,
            AscExtrasEulasCreateCommand.self,
            AscExtrasEulasUpdateCommand.self,
            AscExtrasEulasDeleteCommand.self,
        ]
    )
}

struct AscExtrasEulasListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List custom EULAs on an app.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).eulas
        let page = try await api.listEULAs(appID: appId, limit: limit, cursor: cursor)
        if json {
            print(try AscExtrasJSON.encode(
                EncodableAscExtrasPage(items: page.items, nextCursor: page.nextCursor)
            ))
            return
        }
        logger.header("EULAs (\(page.items.count))")
        for e in page.items {
            let snippet = e.attributes?.agreementText?.prefix(60) ?? ""
            print("  \(e.id)\t\(snippet)...")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct AscExtrasEulasGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a custom EULA.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).eulas
        guard let e = try await api.getEULA(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json { print(try AscExtrasJSON.encode(e)); return }
        logger.header("EULA")
        print("  id:   \(e.id)")
        print("  text: \(e.attributes?.agreementText ?? "(none)")")
    }
}

struct AscExtrasEulasCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new custom EULA.")
    @Option(name: .long) var appId: String
    @Option(name: .long, help: "Full EULA text.") var agreementText: String
    @Option(name: .long, parsing: .upToNextOption, help: "Territory ids to scope the EULA to.") var territoryIds: [String]
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).eulas
        let e = try await api.createEULA(
            appID: appId, agreementText: agreementText, territoryIDs: territoryIds
        )
        if json { print(try AscExtrasJSON.encode(e)); return }
        logger.log("created EULA \(e.id) (\(territoryIds.count) territories)", level: .success)
    }
}

struct AscExtrasEulasUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an EULA's text or territories.")
    @Argument var id: String
    @Option(name: .long) var agreementText: String?
    @Option(name: .long, parsing: .upToNextOption, help: "Pass to replace the territory list.") var territoryIds: [String] = []
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).eulas
        // Empty list still means "don't touch the existing list" — we
        // only forward territoryIDs when the caller explicitly passed at
        // least one. Use --no-territories style if needed by passing one
        // dummy and explicitly excluding others.
        let territoriesArg: [String]? = territoryIds.isEmpty ? nil : territoryIds
        let e = try await api.updateEULA(
            id: id, agreementText: agreementText, territoryIDs: territoriesArg
        )
        if json { print(try AscExtrasJSON.encode(e)); return }
        logger.log("updated EULA \(e.id)", level: .success)
    }
}

struct AscExtrasEulasDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a custom EULA.")
    @Argument var id: String

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).eulas
        try await api.deleteEULA(id: id)
        logger.log("deleted EULA \(id)", level: .success)
    }
}

// MARK: - Android-to-iOS mapping

struct AscExtrasAndroidToIosCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android-to-ios",
        abstract: "Metadata for Android-to-iOS user migration flows.",
        subcommands: [
            AscExtrasAndroidGetCommand.self,
            AscExtrasAndroidUpdateCommand.self,
        ]
    )
}

struct AscExtrasAndroidGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch the mapping for an app.")
    @Option(name: .long) var appId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).androidMapping
        guard let m = try await api.getMapping(appID: appId) else {
            logger.log("no mapping configured", level: .warning)
            return
        }
        if json { print(try AscExtrasJSON.encode(m)); return }
        logger.header("Android-to-iOS mapping")
        print("  id:                \(m.id)")
        print("  android package:   \(m.attributes?.androidAppPackageName ?? "(none)")")
        print("  description:       \(m.attributes?.migrationDescription ?? "(none)")")
    }
}

struct AscExtrasAndroidUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Create-or-update the mapping for an app."
    )

    @Option(name: .long) var appId: String
    @Option(name: .long, help: "Google Play package id (com.example.app).") var androidPackage: String?
    @Option(name: .long) var migrationDescription: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).androidMapping
        if let existing = try await api.getMapping(appID: appId) {
            let updated = try await api.updateMapping(
                id: existing.id,
                androidAppPackageName: androidPackage,
                migrationDescription: migrationDescription
            )
            if json { print(try AscExtrasJSON.encode(updated)); return }
            logger.log("updated mapping \(updated.id)", level: .success)
            return
        }
        guard let pkg = androidPackage else {
            logger.log("no existing mapping for app \(appId); pass --android-package to create one", level: .error)
            throw ExitCode(1)
        }
        let created = try await api.createMapping(
            appID: appId,
            androidAppPackageName: pkg,
            migrationDescription: migrationDescription
        )
        if json { print(try AscExtrasJSON.encode(created)); return }
        logger.log("created mapping \(created.id)", level: .success)
    }
}

// MARK: - Actors

struct AscExtrasActorsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "actors",
        abstract: "Read-only registry of in-app actors.",
        subcommands: [
            AscExtrasActorsListCommand.self,
            AscExtrasActorsGetCommand.self,
        ]
    )
}

struct AscExtrasActorsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List in-app actors.")
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).actors
        let page = try await api.listActors(limit: limit, cursor: cursor)
        if json {
            print(try AscExtrasJSON.encode(
                EncodableAscExtrasPage(items: page.items, nextCursor: page.nextCursor)
            ))
            return
        }
        logger.header("Actors (\(page.items.count))")
        for a in page.items {
            print("  \(a.id)\t\(a.attributes?.name ?? "")\t\(a.attributes?.role ?? "")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

struct AscExtrasActorsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch one actor by id.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).actors
        guard let a = try await api.getActor(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json { print(try AscExtrasJSON.encode(a)); return }
        logger.header("Actor")
        print("  id:   \(a.id)")
        print("  name: \(a.attributes?.name ?? "(none)")")
        print("  role: \(a.attributes?.role ?? "(none)")")
    }
}

// MARK: - App price points V3

struct AscExtrasAppPricePointsV3Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-price-points-v3",
        abstract: "Apple V3 app price-point endpoints.",
        subcommands: [
            AscExtrasAppPricePointsV3GetCommand.self,
            AscExtrasAppPricePointsV3EqualizationsCommand.self,
        ]
    )
}

struct AscExtrasAppPricePointsV3GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch a V3 app price point.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).pricePointsV3
        guard let p = try await api.getPricePoint(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json { print(try AscExtrasJSON.encode(p)); return }
        logger.header("App price point V3")
        print("  id:             \(p.id)")
        print("  territory:      \(p.attributes?.territory ?? "(none)")")
        print("  customerPrice:  \(p.attributes?.customerPrice ?? "(none)")")
        print("  proceeds:       \(p.attributes?.proceeds ?? "(none)")")
    }
}

struct AscExtrasAppPricePointsV3EqualizationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "equalizations",
        abstract: "List cross-territory equivalent price points."
    )
    @Argument(help: "Price point id") var id: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).pricePointsV3
        let page = try await api.listEqualizations(
            pricePointID: id, limit: limit, cursor: cursor
        )
        if json {
            print(try AscExtrasJSON.encode(
                EncodableAscExtrasPage(items: page.items, nextCursor: page.nextCursor)
            ))
            return
        }
        logger.header("Equalizations (\(page.items.count))")
        for e in page.items {
            print("  \(e.id)\t\(e.attributes?.territory ?? "?")\t\(e.attributes?.customerPrice ?? "?")")
        }
        if let c = page.nextCursor { print("  next-cursor: \(c)") }
    }
}

// MARK: - App clip advanced experience images

struct AscExtrasAppClipImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-clip-images",
        abstract: "Header images on app clip advanced experiences.",
        subcommands: [
            AscExtrasAppClipImagesGetCommand.self,
            AscExtrasAppClipImagesCreateCommand.self,
            AscExtrasAppClipImagesUpdateCommand.self,
            AscExtrasAppClipImagesUploadCommand.self,
        ]
    )
}

struct AscExtrasAppClipImagesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch one advanced experience image.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).appClipAdvancedImages
        guard let img = try await api.getImage(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json { print(try AscExtrasJSON.encode(img)); return }
        logger.header("Advanced experience image")
        print("  id:       \(img.id)")
        print("  fileName: \(img.attributes?.fileName ?? "(none)")")
        print("  state:    \(img.attributes?.assetDeliveryState?.state ?? "(none)")")
    }
}

struct AscExtrasAppClipImagesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Reserve a new image slot (phase 1 of upload).")
    @Option(name: .long) var advancedExperienceId: String
    @Option(name: .long) var fileName: String
    @Option(name: .long) var fileSize: Int
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).appClipAdvancedImages
        let img = try await api.createImage(
            advancedExperienceID: advancedExperienceId,
            fileName: fileName,
            fileSize: fileSize
        )
        if json { print(try AscExtrasJSON.encode(img)); return }
        logger.log("reserved image \(img.id)", level: .success)
    }
}

struct AscExtrasAppClipImagesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Finalize an image (phase 3 of upload).")
    @Argument var id: String
    @Option(name: .long) var uploaded: Bool?
    @Option(name: .long, help: "Hex MD5 of the file.") var sourceFileChecksum: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).appClipAdvancedImages
        let img = try await api.updateImage(
            id: id, uploaded: uploaded, sourceFileChecksum: sourceFileChecksum
        )
        if json { print(try AscExtrasJSON.encode(img)); return }
        logger.log("updated image \(img.id)", level: .success)
    }
}

struct AscExtrasAppClipImagesUploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Run all 3 phases of image upload.")
    @Option(name: .long) var advancedExperienceId: String
    @Option(name: .long, help: "Path to the local image file.") var filePath: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).appClipAdvancedImages
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        let img = try await api.uploadImage(advancedExperienceID: advancedExperienceId, fileURL: url) {
            index, total in
            logger.progress(index, of: total, message: "chunk")
        }
        if json { print(try AscExtrasJSON.encode(img)); return }
        logger.log("uploaded image \(img.id)", level: .success)
    }
}

// MARK: - IAP availabilities

struct AscExtrasIapAvailabilitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iap-availabilities",
        abstract: "Per-territory availability for one-time in-app purchases.",
        subcommands: [
            AscExtrasIapAvailabilitiesGetCommand.self,
            AscExtrasIapAvailabilitiesCreateCommand.self,
        ]
    )
}

struct AscExtrasIapAvailabilitiesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch an IAP's availability.")
    @Option(name: .long) var iapId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).iapAvailabilities
        guard let av = try await api.getAvailability(iapID: iapId) else {
            logger.log("no availability configured", level: .warning)
            return
        }
        if json { print(try AscExtrasJSON.encode(av)); return }
        logger.header("IAP availability")
        print("  id:                          \(av.id)")
        print("  availableInNewTerritories:   \(av.attributes?.availableInNewTerritories.map(String.init(describing:)) ?? "(none)")")
    }
}

struct AscExtrasIapAvailabilitiesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Replace an IAP's territory availability with a new list."
    )
    @Option(name: .long) var iapId: String
    @Option(name: .long, parsing: .upToNextOption, help: "Territory ids to allow.") var territoryIds: [String]
    @Option(name: .long) var availableInNewTerritories: Bool = false
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).iapAvailabilities
        let av = try await api.createAvailability(
            iapID: iapId,
            territoryIDs: territoryIds,
            availableInNewTerritories: availableInNewTerritories
        )
        if json { print(try AscExtrasJSON.encode(av)); return }
        logger.log("set IAP availability \(av.id) (\(territoryIds.count) territories)", level: .success)
    }
}

// MARK: - IAP contents

struct AscExtrasIapContentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iap-contents",
        abstract: "Apple-hosted content metadata for IAPs.",
        subcommands: [
            AscExtrasIapContentsGetCommand.self,
        ]
    )
}

struct AscExtrasIapContentsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Fetch an inAppPurchaseContent record.")
    @Argument var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).iapContents
        guard let c = try await api.getContent(id: id) else {
            logger.log("not found", level: .warning)
            throw ExitCode(1)
        }
        if json { print(try AscExtrasJSON.encode(c)); return }
        logger.header("IAP content")
        print("  id:        \(c.id)")
        print("  fileName:  \(c.attributes?.fileName ?? "(none)")")
        print("  fileSize:  \(c.attributes?.fileSize.map(String.init(describing:)) ?? "(none)")")
    }
}

// MARK: - Territory availabilities

struct AscExtrasTerritoryAvailabilitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "territory-availabilities",
        abstract: "Per-(app, territory) availability flag.",
        subcommands: [
            AscExtrasTerritoryAvailabilitiesUpdateCommand.self,
        ]
    )
}

struct AscExtrasTerritoryAvailabilitiesUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Flip an (app, territory) availability on or off."
    )

    @Option(name: .long) var appId: String
    @Option(name: .long) var territoryId: String
    @Option(name: .long, help: "true to enable, false to disable.") var available: Bool
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try await resolveAscExtras(logger: logger).territoryAvailabilities
        let av = try await api.updateAvailability(
            appID: appId, territoryID: territoryId, available: available
        )
        if json { print(try AscExtrasJSON.encode(av)); return }
        logger.log("updated availability \(av.id) (\(territoryId) → available=\(available))", level: .success)
    }
}
