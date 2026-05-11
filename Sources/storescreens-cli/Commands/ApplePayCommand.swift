import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens apple-pay …` parent command: manages the Apple Pay
/// surface (pass type identifiers, signed certificates, and Apple Pay on
/// the Web merchant domains).
struct ApplePayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-pay",
        abstract: "Manage Apple Pay pass type IDs, certificates, and merchant domains.",
        discussion: """
            Wraps Apple's passTypeIds, passTypeIdCertificates, and \
            merchantDomains endpoints. Requires ASC credentials with App \
            Manager or Admin scope.

            Pass type identifiers are the dotted strings (pass.com.example.myapp) \
            that Wallet uses to namespace passes. Each pass type id can have \
            one or more signed certificates; you submit a CSR and Apple \
            returns the signed certificate data. Merchant domains gate Apple \
            Pay on the Web, the team claims a domain and then triggers Apple \
            to validate ownership against /.well-known/apple-developer-merchantid-domain-association.
            """,
        subcommands: [
            ApplePayPassTypeIDsCommand.self,
            ApplePayCertificatesCommand.self,
            ApplePayMerchantDomainsCommand.self,
        ]
    )
}

// MARK: - shared helpers

@discardableResult
private func resolveApplePayAPI(logger: Logger) throws -> ApplePayAPI {
    guard ASCCredentialResolver.isConfigured() else {
        logger.log("no ASC credentials configured", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let creds = try ASCCredentialResolver.resolve()
    let client = ASCClient(credentials: creds)
    return ApplePayAPI(client: client)
}

private func emitApplePayJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

// MARK: - pass-type-ids

struct ApplePayPassTypeIDsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pass-type-ids",
        abstract: "Manage Apple Pay pass type identifiers.",
        subcommands: [
            ApplePayPassTypeIDsListCommand.self,
            ApplePayPassTypeIDsGetCommand.self,
            ApplePayPassTypeIDsCreateCommand.self,
            ApplePayPassTypeIDsUpdateCommand.self,
            ApplePayPassTypeIDsDeleteCommand.self,
        ],
        defaultSubcommand: ApplePayPassTypeIDsListCommand.self
    )
}

struct ApplePayPassTypeIDsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List pass type identifiers, optionally filtered by dotted identifier."
    )

    @Option(name: .long, help: "Filter to one dotted identifier (e.g. pass.com.example.myapp).")
    var identifier: String?

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        let result = try await api.listPassTypeIDs(
            limit: limit, cursor: cursor, filterIdentifier: identifier
        )
        if json {
            struct Out: Encodable {
                let passTypeIDs: [ApplePayAPI.PassTypeID]
                let nextCursor: String?
            }
            try emitApplePayJSON(Out(passTypeIDs: result.passTypeIDs, nextCursor: result.nextCursor))
            return
        }
        logger.header("Pass type identifiers (\(result.passTypeIDs.count))")
        if result.passTypeIDs.isEmpty {
            print("  (none)")
            return
        }
        for p in result.passTypeIDs {
            print("  \(p.attributes?.identifier ?? "(no identifier)")")
            print("    id:   \(p.id)")
            print("    name: \(p.attributes?.name ?? "(no name)")")
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct ApplePayPassTypeIDsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one pass type identifier by id."
    )

    @Argument(help: "ASC database id.")
    var passTypeID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        guard let p = try await api.getPassTypeID(id: passTypeID) else {
            logger.log("no pass type id with id \(passTypeID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitApplePayJSON(p)
            return
        }
        logger.header(p.attributes?.identifier ?? p.id)
        print("  id:         \(p.id)")
        print("  identifier: \(p.attributes?.identifier ?? "(unset)")")
        print("  name:       \(p.attributes?.name ?? "(unset)")")
    }
}

struct ApplePayPassTypeIDsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Register a new pass type identifier.",
        discussion: """
            The identifier must begin with "pass." and use reverse-DNS \
            notation (e.g. pass.com.example.myapp). The name is the \
            human-readable label for the developer portal.
            """
    )

    @Option(name: .long, help: "Dotted pass type identifier (e.g. pass.com.example.myapp).")
    var identifier: String

    @Option(name: .long, help: "Display name in the developer portal.")
    var name: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        let p = try await api.createPassTypeID(identifier: identifier, name: name)
        if json {
            try emitApplePayJSON(p)
        } else {
            logger.log("created pass type id \(p.attributes?.identifier ?? p.id)", level: .success)
            print("  id: \(p.id)")
        }
    }
}

struct ApplePayPassTypeIDsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Rename a pass type identifier's display name."
    )

    @Argument(help: "ASC database id.")
    var passTypeID: String

    @Option(name: .long, help: "New display name.")
    var name: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        let p = try await api.updatePassTypeID(id: passTypeID, name: name)
        if json {
            try emitApplePayJSON(p)
        } else {
            logger.log("renamed pass type id \(p.id) to \(name)", level: .success)
        }
    }
}

struct ApplePayPassTypeIDsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a pass type identifier."
    )

    @Argument(help: "ASC database id to delete.")
    var passTypeID: String

    @Flag(name: [.short, .long], help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let logger = Logger()
        if !yes {
            print("About to delete pass type id \(passTypeID). Continue? [y/N] ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                logger.log("aborted", level: .info)
                return
            }
        }
        let api = try resolveApplePayAPI(logger: logger)
        try await api.deletePassTypeID(id: passTypeID)
        logger.log("deleted pass type id \(passTypeID)", level: .success)
    }
}

// MARK: - certificates

struct ApplePayCertificatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "certificates",
        abstract: "Manage signed pass type id certificates.",
        subcommands: [
            ApplePayCertificatesListCommand.self,
            ApplePayCertificatesGetCommand.self,
            ApplePayCertificatesCreateCommand.self,
            ApplePayCertificatesDeleteCommand.self,
        ],
        defaultSubcommand: ApplePayCertificatesListCommand.self
    )
}

struct ApplePayCertificatesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List certificates signed against a pass type identifier."
    )

    @Argument(help: "ASC database id of the pass type id.")
    var passTypeID: String

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        let result = try await api.listPassTypeIDCertificates(
            passTypeIDDatabaseID: passTypeID, limit: limit, cursor: cursor
        )
        if json {
            struct Out: Encodable {
                let certificates: [ApplePayAPI.PassTypeIDCertificate]
                let nextCursor: String?
            }
            try emitApplePayJSON(Out(certificates: result.certificates, nextCursor: result.nextCursor))
            return
        }
        logger.header("Certificates (\(result.certificates.count))")
        if result.certificates.isEmpty {
            print("  (none)")
            return
        }
        for c in result.certificates {
            let name = c.attributes?.displayName ?? c.attributes?.name ?? "(no name)"
            print("  \(name)")
            print("    id:     \(c.id)")
            if let exp = c.attributes?.expirationDate {
                print("    exp:    \(exp)")
            }
            if let sn = c.attributes?.serialNumber {
                print("    serial: \(sn)")
            }
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct ApplePayCertificatesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one pass type id certificate by id."
    )

    @Argument(help: "Certificate id.")
    var certificateID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        guard let cert = try await api.getPassTypeIDCertificate(id: certificateID) else {
            logger.log("no certificate with id \(certificateID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitApplePayJSON(cert)
            return
        }
        logger.header(cert.attributes?.displayName ?? cert.id)
        print("  id:             \(cert.id)")
        print("  name:           \(cert.attributes?.name ?? "(unset)")")
        print("  serial:         \(cert.attributes?.serialNumber ?? "(unset)")")
        print("  type:           \(cert.attributes?.certificateType ?? "(unset)")")
        print("  platform:       \(cert.attributes?.platform ?? "(unset)")")
        print("  expirationDate: \(cert.attributes?.expirationDate.map(String.init(describing:)) ?? "(unset)")")
        if cert.attributes?.certificateContent != nil {
            print("  certificateContent: (base64 contents, run with --json to access)")
        }
    }
}

struct ApplePayCertificatesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Submit a CSR and receive a signed pass type id certificate.",
        discussion: """
            Apple signs the CSR using the pass type id's seed material and \
            returns the certificate content base64-encoded. Generate the CSR \
            with `openssl req -new -newkey rsa:2048 -nodes -keyout key.pem \
            -out req.csr -subj "/CN=..."` then `base64 -i req.csr`. Save the \
            returned `certificateContent` to a `.cer` file.
            """
    )

    @Option(name: .long, help: "ASC database id of the pass type id.")
    var passTypeID: String

    @Option(name: .long, help: "Path to base64-encoded CSR file.")
    var csrFile: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let csrPath = (csrFile as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: csrPath) else {
            logger.log("CSR file not found at \(csrPath)", level: .error)
            throw ExitCode(1)
        }
        let csr = try String(contentsOfFile: csrPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !csr.isEmpty else {
            logger.log("CSR file is empty", level: .error)
            throw ExitCode(1)
        }
        let api = try resolveApplePayAPI(logger: logger)
        let cert = try await api.createPassTypeIDCertificate(
            passTypeIDDatabaseID: passTypeID, csrContent: csr
        )
        if json {
            try emitApplePayJSON(cert)
        } else {
            logger.log("created certificate \(cert.id)", level: .success)
            print("  run with --json to extract the base64 certificateContent")
        }
    }
}

struct ApplePayCertificatesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Revoke a pass type id certificate. Irreversible."
    )

    @Argument(help: "Certificate id to revoke.")
    var certificateID: String

    @Flag(name: [.short, .long], help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let logger = Logger()
        if !yes {
            print("About to revoke certificate \(certificateID). Continue? [y/N] ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                logger.log("aborted", level: .info)
                return
            }
        }
        let api = try resolveApplePayAPI(logger: logger)
        try await api.revokePassTypeIDCertificate(id: certificateID)
        logger.log("revoked certificate \(certificateID)", level: .success)
    }
}

// MARK: - merchant-domains

struct ApplePayMerchantDomainsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merchant-domains",
        abstract: "Manage Apple Pay on the Web merchant domains.",
        subcommands: [
            ApplePayMerchantDomainsListCommand.self,
            ApplePayMerchantDomainsGetCommand.self,
            ApplePayMerchantDomainsCreateCommand.self,
            ApplePayMerchantDomainsValidateCommand.self,
            ApplePayMerchantDomainsDeleteCommand.self,
        ],
        defaultSubcommand: ApplePayMerchantDomainsListCommand.self
    )
}

struct ApplePayMerchantDomainsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List claimed Apple Pay merchant domains."
    )

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        let result = try await api.listMerchantDomains(limit: limit, cursor: cursor)
        if json {
            struct Out: Encodable {
                let merchantDomains: [ApplePayAPI.MerchantDomain]
                let nextCursor: String?
            }
            try emitApplePayJSON(Out(merchantDomains: result.merchantDomains, nextCursor: result.nextCursor))
            return
        }
        logger.header("Merchant domains (\(result.merchantDomains.count))")
        if result.merchantDomains.isEmpty {
            print("  (none)")
            return
        }
        for d in result.merchantDomains {
            print("  \(d.attributes?.domain ?? "(no domain)")")
            print("    id:    \(d.id)")
            print("    state: \(d.attributes?.domainState ?? "(unknown)")")
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct ApplePayMerchantDomainsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one merchant domain by id."
    )

    @Argument(help: "Merchant domain id.")
    var domainID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        guard let d = try await api.getMerchantDomain(id: domainID) else {
            logger.log("no merchant domain with id \(domainID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitApplePayJSON(d)
            return
        }
        logger.header(d.attributes?.domain ?? d.id)
        print("  id:          \(d.id)")
        print("  domain:      \(d.attributes?.domain ?? "(unset)")")
        print("  domainState: \(d.attributes?.domainState ?? "(unset)")")
    }
}

struct ApplePayMerchantDomainsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Claim a new Apple Pay merchant domain.",
        discussion: """
            Apple does not validate the domain at creation time, host \
            /.well-known/apple-developer-merchantid-domain-association on \
            the claimed URL, then run `apple-pay merchant-domains validate`.
            """
    )

    @Option(name: .long, help: "Fully-qualified domain name (e.g. shop.example.com).")
    var domain: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        let d = try await api.createMerchantDomain(domain: domain)
        if json {
            try emitApplePayJSON(d)
        } else {
            logger.log("claimed merchant domain \(d.attributes?.domain ?? domain)", level: .success)
            print("  id:    \(d.id)")
            print("  state: \(d.attributes?.domainState ?? "(unknown)")")
            print("")
            print("  next step: host the well-known association file then run")
            print("    storescreens apple-pay merchant-domains validate \(d.id)")
        }
    }
}

struct ApplePayMerchantDomainsValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Trigger Apple to verify ownership of a merchant domain.",
        discussion: """
            Apple fetches the well-known association file at the claimed \
            domain and flips the state to VERIFIED on success, VERIFY_FAILED \
            on failure. Retry after fixing the well-known file.
            """
    )

    @Argument(help: "Merchant domain id to validate.")
    var domainID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveApplePayAPI(logger: logger)
        let d = try await api.validateMerchantDomain(id: domainID)
        if json {
            try emitApplePayJSON(d)
        } else {
            let state = d.attributes?.domainState ?? "(unknown)"
            if state == "VERIFIED" {
                logger.log("merchant domain \(d.id) verified", level: .success)
            } else if state == "VERIFY_FAILED" {
                logger.log("verification failed for \(d.id)", level: .error)
                print("  check the well-known file at the claimed URL and retry")
            } else {
                logger.log("merchant domain \(d.id) state: \(state)", level: .info)
            }
        }
    }
}

struct ApplePayMerchantDomainsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Revoke a merchant domain claim."
    )

    @Argument(help: "Merchant domain id to delete.")
    var domainID: String

    @Flag(name: [.short, .long], help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let logger = Logger()
        if !yes {
            print("About to revoke merchant domain \(domainID). Web payments will stop. Continue? [y/N] ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                logger.log("aborted", level: .info)
                return
            }
        }
        let api = try resolveApplePayAPI(logger: logger)
        try await api.deleteMerchantDomain(id: domainID)
        logger.log("deleted merchant domain \(domainID)", level: .success)
    }
}
