import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens alt-dist` command. Wraps the App Store
/// Connect Alternative Distribution (EU DMA) APIs as nested
/// subcommands so AI agents (and humans) can drive EU-marketplace
/// + developer-direct distribution workflows without hand-rolling
/// HTTP requests.
///
/// This surface is only relevant for developers participating in
/// Apple's EU Alternative Distribution program. Standard App Store
/// flows are untouched.
///
/// Every leaf subcommand accepts `--json` for machine-readable
/// output; without it, results print as readable text via the
/// shared Logger.
struct AltDistributionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "alt-dist",
        abstract: "Manage Alternative Distribution (EU DMA): keys, packages, domains, marketplace metadata.",
        discussion: """
            Wraps the App Store Connect Alternative Distribution API for \
            developers shipping iOS apps outside the App Store via approved \
            EU marketplaces or developer-direct distribution. Requires \
            credentials via `storescreens auth login` or ASC_KEY_ID / \
            ASC_ISSUER_ID / ASC_KEY_PATH env vars.

            Use `--json` on any leaf subcommand for machine-readable output. \
            The same operations are exposed as MCP tools under the \
            `altdist_*` namespace.

            Note: this surface is only relevant if the developer has \
            registered for Apple's EU Alternative Distribution program. \
            Standard App Store distribution does not use these endpoints.
            """,
        subcommands: [
            ADKeysCommand.self,
            ADPackagesCommand.self,
            ADPackageVersionsCommand.self,
            ADPackageDeltasCommand.self,
            ADPackageVariantsCommand.self,
            ADDomainsCommand.self,
            ADMarketplaceCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// Resolves ASC credentials and builds an AltDistributionAPI client.
/// Throws an ExitCode(1) after logging on failure so subcommands
/// stay tiny.
fileprivate func adClient(logger: Logger) throws -> AltDistributionAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return AltDistributionAPI(client: client)
}

/// Emits any `Encodable` as pretty-printed JSON on stdout.
fileprivate func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

/// Emit-helper for "single resource or nil" results from getXxx calls.
fileprivate func emitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value {
        try emitJSON(value)
    } else {
        print("null")
    }
}

/// Wraps a paged AltDistributionAPI page in the same shape MCP tools emit.
fileprivate struct ADCLIPage<Item: Encodable>: Encodable {
    let data: [Item]
    let nextCursor: String?
}

/// Maps ASCClient.APIError to a readable, formatted error then
/// throws ExitCode(1). Other errors propagate.
fileprivate func surface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
    do {
        return try await block()
    } catch let e as ASCClient.APIError {
        logger.log("App Store Connect API error: HTTP \(e.statusCode)", level: .error)
        for d in e.details {
            print("  [\(d.code)] \(d.title): \(d.detail)")
        }
        throw ExitCode(1)
    }
}

// MARK: - keys

struct ADKeysCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Manage alternative distribution signing keys.",
        subcommands: [
            ADKeysListCommand.self,
            ADKeysGetCommand.self,
            ADKeysCreateCommand.self,
            ADKeysUpdateCommand.self,
            ADKeysDeleteCommand.self,
        ]
    )
}

struct ADKeysListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List alternative distribution keys.")
    @Option(name: .long, help: "Max results per page (default 200).") var limit: Int = 200
    @Option(name: .long, help: "Pagination cursor from a previous page.") var cursor: String?
    @Flag(name: .long, help: "Emit JSON instead of text.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let page = try await surface(
            { try await api.keys.list(limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(ADCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Alternative distribution keys (\(page.data.count))")
        for k in page.data {
            let fp = k.attributes?.sha256Fingerprint ?? "(no fingerprint)"
            print("  \(k.id)  \(fp)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct ADKeysGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an alternative distribution key by id.")
    @Argument(help: "Alternative distribution key id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let key = try await surface({ try await api.keys.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(key)
            return
        }
        guard let key else {
            logger.log("no alternative distribution key \(id)", level: .warning)
            return
        }
        logger.header("Alternative distribution key \(key.id)")
        let pub = (key.attributes?.publicKey ?? "").prefix(80)
        print("  fingerprint: \(key.attributes?.sha256Fingerprint ?? "(none)")")
        print("  public key:  \(pub)\(pub.count >= 80 ? " ..." : "")")
    }
}

struct ADKeysCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Register a new alternative distribution key.")
    @Option(name: .long, help: "Path to a UTF-8 file holding the PEM-encoded public key.")
    var fromFile: String?
    @Option(name: .long, help: "Inline PEM-encoded public key (use --from-file for multi-line inputs).")
    var publicKey: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let pubKey: String
        if let path = fromFile {
            pubKey = try String(contentsOfFile: path, encoding: .utf8)
        } else if let k = publicKey {
            pubKey = k
        } else {
            logger.log("provide --from-file <path> or --public-key <inline>", level: .error)
            throw ExitCode(1)
        }
        let api = try adClient(logger: logger)
        let key = try await surface(
            { try await api.keys.create(publicKey: pubKey) },
            logger: logger
        )
        if json {
            try emitJSON(key)
            return
        }
        logger.log("created alternative distribution key \(key.id)", level: .success)
    }
}

struct ADKeysUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Rotate the public key on an existing key record.")
    @Argument(help: "Alternative distribution key id.") var id: String
    @Option(name: .long, help: "Path to a UTF-8 file holding the new PEM-encoded public key.")
    var fromFile: String?
    @Option(name: .long, help: "Inline new PEM-encoded public key.")
    var publicKey: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let pubKey: String
        if let path = fromFile {
            pubKey = try String(contentsOfFile: path, encoding: .utf8)
        } else if let k = publicKey {
            pubKey = k
        } else {
            logger.log("provide --from-file <path> or --public-key <inline>", level: .error)
            throw ExitCode(1)
        }
        let api = try adClient(logger: logger)
        let key = try await surface(
            { try await api.keys.update(id: id, publicKey: pubKey) },
            logger: logger
        )
        if json {
            try emitJSON(key)
            return
        }
        logger.log("updated alternative distribution key \(key.id)", level: .success)
    }
}

struct ADKeysDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an alternative distribution key.")
    @Argument(help: "Alternative distribution key id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        try await surface({ try await api.keys.delete(id: id) }, logger: logger)
        logger.log("deleted alternative distribution key \(id)", level: .success)
    }
}

// MARK: - packages

struct ADPackagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "packages",
        abstract: "Manage per-app alternative distribution packages.",
        subcommands: [
            ADPackagesListCommand.self,
            ADPackagesGetCommand.self,
            ADPackagesCreateCommand.self,
            ADPackagesDeleteCommand.self,
        ]
    )
}

struct ADPackagesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List alternative distribution packages for an app.")
    @Option(name: .long) var appId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let page = try await surface(
            { try await api.packages.list(appID: appId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(ADCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Alternative distribution packages (\(page.data.count))")
        for p in page.data {
            let ver = p.attributes?.versionString ?? "(no version)"
            let url = p.attributes?.url ?? "(no url)"
            print("  \(p.id)  \(ver)  \(url)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct ADPackagesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an alternative distribution package by id.")
    @Argument(help: "Package id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let pkg = try await surface({ try await api.packages.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(pkg)
            return
        }
        guard let pkg else {
            logger.log("no alternative distribution package \(id)", level: .warning)
            return
        }
        try emitJSON(pkg)
    }
}

struct ADPackagesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create an alternative distribution package for an app.")
    @Option(name: .long) var appId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let pkg = try await surface(
            { try await api.packages.create(appID: appId) },
            logger: logger
        )
        if json {
            try emitJSON(pkg)
            return
        }
        logger.log("created alternative distribution package \(pkg.id) for app \(appId)", level: .success)
    }
}

struct ADPackagesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an alternative distribution package.")
    @Argument(help: "Package id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        try await surface({ try await api.packages.delete(id: id) }, logger: logger)
        logger.log("deleted alternative distribution package \(id)", level: .success)
    }
}

// MARK: - package versions

struct ADPackageVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package-versions",
        abstract: "Manage alternative distribution package versions and their state lifecycle.",
        subcommands: [
            ADPackageVersionsListCommand.self,
            ADPackageVersionsGetCommand.self,
            ADPackageVersionsCreateCommand.self,
            ADPackageVersionsUpdateCommand.self,
            ADPackageVersionsDeleteCommand.self,
            ADPackageVersionsActivateCommand.self,
            ADPackageVersionsDisableCommand.self,
            ADPackageVersionsValidateCommand.self,
        ]
    )
}

struct ADPackageVersionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List versions for a package.")
    @Option(name: .long) var packageId: String
    @Option(name: .long, help: "Filter: CREATED, REPLACED, COMPLETED, ENABLED, DISABLED.") var state: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let stateEnum = state.flatMap { AltDistributionAPI.PackageVersionState(rawValue: $0) }
        if let s = state, stateEnum == nil {
            logger.log("unknown state \(s); expected CREATED, REPLACED, COMPLETED, ENABLED, DISABLED", level: .error)
            throw ExitCode(1)
        }
        let page = try await surface(
            { try await api.packageVersions.list(
                packageID: packageId, state: stateEnum, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(ADCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Package versions (\(page.data.count))")
        for v in page.data {
            let ver = v.attributes?.version ?? "(no version)"
            let st = v.attributes?.state ?? "(no state)"
            print("  \(v.id)  \(ver)  [\(st)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct ADPackageVersionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a package version by id.")
    @Argument(help: "Package version id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let v = try await surface({ try await api.packageVersions.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(v)
            return
        }
        guard let v else {
            logger.log("no package version \(id)", level: .warning)
            return
        }
        print("  id:           \(v.id)")
        print("  version:      \(v.attributes?.version ?? "(none)")")
        print("  state:        \(v.attributes?.state ?? "(none)")")
        print("  url:          \(v.attributes?.url ?? "(none)")")
        print("  fileChecksum: \(v.attributes?.fileChecksum ?? "(none)")")
    }
}

struct ADPackageVersionsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new package version pointing at a developer-hosted binary URL.")
    @Option(name: .long) var packageId: String
    @Option(name: .long, help: "Developer-hosted URL of the notarized binary.") var url: String
    @Option(name: .long, help: "Marketing version string, e.g. \"1.2.0\".") var version: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let v = try await surface(
            { try await api.packageVersions.create(
                packageID: packageId, url: url, version: version
            ) },
            logger: logger
        )
        if json {
            try emitJSON(v)
            return
        }
        logger.log("created package version \(v.id)", level: .success)
    }
}

struct ADPackageVersionsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a package version (url and/or state).")
    @Argument(help: "Package version id.") var id: String
    @Option(name: .long) var url: String?
    @Option(name: .long, help: "CREATED, REPLACED, COMPLETED, ENABLED, DISABLED.") var state: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let stateEnum = state.flatMap { AltDistributionAPI.PackageVersionState(rawValue: $0) }
        if let s = state, stateEnum == nil {
            logger.log("unknown state \(s); expected CREATED, REPLACED, COMPLETED, ENABLED, DISABLED", level: .error)
            throw ExitCode(1)
        }
        let v = try await surface(
            { try await api.packageVersions.update(id: id, url: url, state: stateEnum) },
            logger: logger
        )
        if json {
            try emitJSON(v)
            return
        }
        logger.log("updated package version \(v.id)", level: .success)
    }
}

struct ADPackageVersionsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a package version.")
    @Argument(help: "Package version id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        try await surface({ try await api.packageVersions.delete(id: id) }, logger: logger)
        logger.log("deleted package version \(id)", level: .success)
    }
}

struct ADPackageVersionsActivateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activate",
        abstract: "Activate a completed package version (state -> ENABLED)."
    )
    @Argument(help: "Package version id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let v = try await surface(
            { try await api.packageVersions.activate(id: id) },
            logger: logger
        )
        if json {
            try emitJSON(v)
            return
        }
        logger.log("activated package version \(v.id)", level: .success)
    }
}

struct ADPackageVersionsDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a live package version (state -> DISABLED)."
    )
    @Argument(help: "Package version id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let v = try await surface(
            { try await api.packageVersions.disable(id: id) },
            logger: logger
        )
        if json {
            try emitJSON(v)
            return
        }
        logger.log("disabled package version \(v.id)", level: .success)
    }
}

struct ADPackageVersionsValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate (poll) a package version's current state from Apple."
    )
    @Argument(help: "Package version id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let v = try await surface(
            { try await api.packageVersions.validate(id: id) },
            logger: logger
        )
        if json {
            try emitOptionalJSON(v)
            return
        }
        guard let v else {
            logger.log("no package version \(id)", level: .warning)
            return
        }
        print("  id:    \(v.id)")
        print("  state: \(v.attributes?.state ?? "(none)")")
    }
}

// MARK: - package deltas

struct ADPackageDeltasCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package-deltas",
        abstract: "Read-only binary deltas between package versions.",
        subcommands: [
            ADPackageDeltasListCommand.self,
            ADPackageDeltasGetCommand.self,
        ]
    )
}

struct ADPackageDeltasListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List deltas for a package version.")
    @Option(name: .long) var versionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let page = try await surface(
            { try await api.packageDeltas.list(versionID: versionId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(ADCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Package deltas (\(page.data.count))")
        for d in page.data {
            let url = d.attributes?.url ?? "(no url)"
            print("  \(d.id)  \(url)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct ADPackageDeltasGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a delta by id.")
    @Argument(help: "Delta id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let d = try await surface({ try await api.packageDeltas.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(d)
            return
        }
        guard let d else {
            logger.log("no package delta \(id)", level: .warning)
            return
        }
        try emitJSON(d)
    }
}

// MARK: - package variants

struct ADPackageVariantsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package-variants",
        abstract: "Read-only per-architecture/variant slices of a package version.",
        subcommands: [
            ADPackageVariantsListCommand.self,
            ADPackageVariantsGetCommand.self,
        ]
    )
}

struct ADPackageVariantsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List variants for a package version.")
    @Option(name: .long) var versionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let page = try await surface(
            { try await api.packageVariants.list(versionID: versionId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(ADCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Package variants (\(page.data.count))")
        for v in page.data {
            let lang = v.attributes?.defaultLanguage ?? "(no lang)"
            let url = v.attributes?.url ?? "(no url)"
            print("  \(v.id)  [\(lang)]  \(url)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct ADPackageVariantsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a variant by id.")
    @Argument(help: "Variant id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let v = try await surface({ try await api.packageVariants.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(v)
            return
        }
        guard let v else {
            logger.log("no package variant \(id)", level: .warning)
            return
        }
        try emitJSON(v)
    }
}

// MARK: - domains

struct ADDomainsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "domains",
        abstract: "Manage verified alternative distribution domains.",
        subcommands: [
            ADDomainsListCommand.self,
            ADDomainsGetCommand.self,
            ADDomainsCreateCommand.self,
            ADDomainsUpdateCommand.self,
            ADDomainsDeleteCommand.self,
        ]
    )
}

struct ADDomainsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List verified distribution domains.")
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let page = try await surface(
            { try await api.domains.list(limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(ADCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Alternative distribution domains (\(page.data.count))")
        for d in page.data {
            let dom = d.attributes?.domain ?? "(no domain)"
            let ref = d.attributes?.referrer ?? "(no referrer)"
            print("  \(d.id)  \(dom)  ref=\(ref)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct ADDomainsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a distribution domain by id.")
    @Argument(help: "Domain id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let d = try await surface({ try await api.domains.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(d)
            return
        }
        guard let d else {
            logger.log("no domain \(id)", level: .warning)
            return
        }
        print("  id:       \(d.id)")
        print("  domain:   \(d.attributes?.domain ?? "(none)")")
        print("  referrer: \(d.attributes?.referrer ?? "(none)")")
    }
}

struct ADDomainsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Register a new distribution domain.")
    @Option(name: .long, help: "Fully-qualified domain, e.g. downloads.example.com.") var domain: String
    @Option(name: .long, help: "HTTP referrer Apple expects on download requests (anti-abuse).") var referrer: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let d = try await surface(
            { try await api.domains.create(domain: domain, referrer: referrer) },
            logger: logger
        )
        if json {
            try emitJSON(d)
            return
        }
        logger.log("registered alternative distribution domain \(d.id) (\(domain))", level: .success)
    }
}

struct ADDomainsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a distribution domain.")
    @Argument(help: "Domain id.") var id: String
    @Option(name: .long) var domain: String?
    @Option(name: .long) var referrer: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let d = try await surface(
            { try await api.domains.update(id: id, domain: domain, referrer: referrer) },
            logger: logger
        )
        if json {
            try emitJSON(d)
            return
        }
        logger.log("updated alternative distribution domain \(d.id)", level: .success)
    }
}

struct ADDomainsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a distribution domain.")
    @Argument(help: "Domain id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        try await surface({ try await api.domains.delete(id: id) }, logger: logger)
        logger.log("deleted alternative distribution domain \(id)", level: .success)
    }
}

// MARK: - marketplace (parent for search + webhooks)

struct ADMarketplaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "marketplace",
        abstract: "Marketplace search-catalog metadata and webhook subscriptions.",
        subcommands: [
            ADMarketplaceSearchCommand.self,
            ADMarketplaceWebhooksCommand.self,
        ]
    )
}

// MARK: - marketplace search

struct ADMarketplaceSearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Read or update marketplace search-catalog metadata for an app.",
        subcommands: [
            ADMarketplaceSearchGetCommand.self,
            ADMarketplaceSearchUpdateCommand.self,
        ]
    )
}

struct ADMarketplaceSearchGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read marketplace search-catalog metadata for an app.")
    @Option(name: .long) var appId: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let detail = try await surface(
            { try await api.marketplaceSearch.get(appID: appId) },
            logger: logger
        )
        if json {
            try emitOptionalJSON(detail)
            return
        }
        guard let detail else {
            logger.log("no marketplace search detail for app \(appId)", level: .warning)
            return
        }
        try emitJSON(detail)
    }
}

struct ADMarketplaceSearchUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update marketplace search-catalog metadata.")
    @Argument(help: "marketplaceSearchDetails id (NOT the app id).") var id: String
    @Option(name: .long) var subtitle: String?
    @Option(name: .long) var privacyPolicyUrl: String?
    @Option(name: .long) var customerSupportUrl: String?
    @Option(name: .long) var marketingUrl: String?
    @Option(name: .long) var sellerName: String?
    @Option(name: .long) var ageBandRangeMin: Int?
    @Option(name: .long) var ageBandRangeMax: Int?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let fields = AltDistributionAPI.MarketplaceSearchDetailFields(
            subtitle: subtitle,
            privacyPolicyURL: privacyPolicyUrl,
            customerSupportURL: customerSupportUrl,
            marketingURL: marketingUrl,
            sellerName: sellerName,
            ageBandRangeMin: ageBandRangeMin,
            ageBandRangeMax: ageBandRangeMax
        )
        let detail = try await surface(
            { try await api.marketplaceSearch.update(id: id, fields: fields) },
            logger: logger
        )
        if json {
            try emitJSON(detail)
            return
        }
        logger.log("updated marketplace search detail \(detail.id)", level: .success)
    }
}

// MARK: - marketplace webhooks

struct ADMarketplaceWebhooksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webhooks",
        abstract: "Manage marketplace webhook subscriptions.",
        subcommands: [
            ADMarketplaceWebhooksListCommand.self,
            ADMarketplaceWebhooksGetCommand.self,
            ADMarketplaceWebhooksCreateCommand.self,
            ADMarketplaceWebhooksUpdateCommand.self,
            ADMarketplaceWebhooksDeleteCommand.self,
        ]
    )
}

struct ADMarketplaceWebhooksListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List marketplace webhook subscriptions.")
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let page = try await surface(
            { try await api.marketplaceWebhooks.list(limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(ADCLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Marketplace webhooks (\(page.data.count))")
        for w in page.data {
            let url = w.attributes?.url ?? "(no url)"
            print("  \(w.id)  \(url)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct ADMarketplaceWebhooksGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a marketplace webhook by id.")
    @Argument(help: "Webhook id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let w = try await surface({ try await api.marketplaceWebhooks.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(w)
            return
        }
        guard let w else {
            logger.log("no marketplace webhook \(id)", level: .warning)
            return
        }
        print("  id:  \(w.id)")
        print("  url: \(w.attributes?.url ?? "(none)")")
    }
}

struct ADMarketplaceWebhooksCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a marketplace webhook subscription.")
    @Option(name: .long, help: "HTTPS endpoint Apple will POST events to.") var url: String
    @Option(name: .long, help: "HMAC shared secret Apple signs payloads with.") var secret: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let w = try await surface(
            { try await api.marketplaceWebhooks.create(url: url, secret: secret) },
            logger: logger
        )
        if json {
            try emitJSON(w)
            return
        }
        logger.log("created marketplace webhook \(w.id) -> \(url)", level: .success)
    }
}

struct ADMarketplaceWebhooksUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a marketplace webhook.")
    @Argument(help: "Webhook id.") var id: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var secret: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        let w = try await surface(
            { try await api.marketplaceWebhooks.update(id: id, url: url, secret: secret) },
            logger: logger
        )
        if json {
            try emitJSON(w)
            return
        }
        logger.log("updated marketplace webhook \(w.id)", level: .success)
    }
}

struct ADMarketplaceWebhooksDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a marketplace webhook.")
    @Argument(help: "Webhook id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try adClient(logger: logger)
        try await surface({ try await api.marketplaceWebhooks.delete(id: id) }, logger: logger)
        logger.log("deleted marketplace webhook \(id)", level: .success)
    }
}
