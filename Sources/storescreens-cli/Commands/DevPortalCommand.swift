import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens devportal …` parent command: code-signing surface
/// management against the Apple Developer Portal endpoints surfaced
/// through App Store Connect (certificates, profiles, devices, bundle
/// IDs, and per-bundleId capabilities).
struct DevPortalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devportal",
        abstract: "Manage certificates, profiles, devices, and bundle IDs.",
        discussion: """
            Wraps Apple's Certificates, Profiles, Devices, Bundle IDs, and \
            Bundle ID Capabilities endpoints. Requires ASC credentials with \
            the App Manager or Admin role.

            Certificate types: IOS_DEVELOPMENT, IOS_DISTRIBUTION, \
            MAC_APP_DISTRIBUTION, MAC_INSTALLER_DISTRIBUTION, \
            DEVELOPER_ID_APPLICATION, DEVELOPMENT, DISTRIBUTION.

            Profile types: IOS_APP_STORE, IOS_APP_DEVELOPMENT, IOS_APP_ADHOC, \
            MAC_APP_STORE, MAC_APP_DEVELOPMENT, TVOS_APP_STORE.

            Capability types Apple documents include: PUSH_NOTIFICATIONS, \
            ICLOUD, APP_GROUPS, HEALTHKIT, GAME_CENTER, ASSOCIATED_DOMAINS, \
            SIRIKIT, NETWORK_EXTENSIONS, NFC_TAG_READING, APP_ATTEST.
            """,
        subcommands: [
            DevPortalCertificatesCommand.self,
            DevPortalProfilesCommand.self,
            DevPortalDevicesCommand.self,
            DevPortalBundleIDsCommand.self,
            DevPortalCapabilitiesCommand.self,
        ]
    )
}

// MARK: - shared helpers

@discardableResult
private func resolveDevPortalAPI(logger: Logger) throws -> DevPortalAPI {
    guard ASCCredentialResolver.isConfigured() else {
        logger.log("no ASC credentials configured", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let creds = try ASCCredentialResolver.resolve()
    let client = ASCClient(credentials: creds)
    return DevPortalAPI(client: client)
}

private func emitDevPortalJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

private func splitCSV(_ raw: String?) -> [String] {
    raw?.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty } ?? []
}

// MARK: - certificates

struct DevPortalCertificatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "certificates",
        abstract: "Manage signing certificates.",
        subcommands: [
            DevPortalCertificatesListCommand.self,
            DevPortalCertificatesGetCommand.self,
            DevPortalCertificatesCreateCommand.self,
            DevPortalCertificatesDeleteCommand.self,
        ],
        defaultSubcommand: DevPortalCertificatesListCommand.self
    )
}

struct DevPortalCertificatesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List signing certificates, optionally filtered by type."
    )

    @Option(name: .long, help: "Filter by certificate type (e.g. IOS_DISTRIBUTION).")
    var type: String?

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        let result = try await api.listCertificates(
            type: type, limit: limit, cursor: cursor
        )
        if json {
            struct Out: Encodable {
                let certificates: [DevPortalAPI.Certificate]
                let nextCursor: String?
            }
            try emitDevPortalJSON(Out(
                certificates: result.certificates,
                nextCursor: result.nextCursor
            ))
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
            print("    type:   \(c.attributes?.certificateType ?? "(unknown)")")
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

struct DevPortalCertificatesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one certificate by id."
    )

    @Argument(help: "Certificate id.")
    var certificateID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        guard let cert = try await api.getCertificate(id: certificateID) else {
            logger.log("no certificate with id \(certificateID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitDevPortalJSON(cert)
            return
        }
        logger.header(cert.attributes?.displayName ?? cert.id)
        print("  id:               \(cert.id)")
        print("  name:             \(cert.attributes?.name ?? "(unset)")")
        print("  type:             \(cert.attributes?.certificateType ?? "(unset)")")
        print("  platform:         \(cert.attributes?.platform ?? "(unset)")")
        print("  expirationDate:   \(cert.attributes?.expirationDate.map(String.init(describing:)) ?? "(unset)")")
        if cert.attributes?.certificateContent != nil {
            print("  certificateContent: (base64 contents, run with --json to access)")
        }
    }
}

struct DevPortalCertificatesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Submit a CSR and receive a signed certificate.",
        discussion: """
            Generates a fresh certificate from a Certificate Signing Request \
            (CSR). The CSR must be PEM-encoded then base64-wrapped. Apple \
            returns the certificate content in JSON; redirect with --json and \
            jq to extract it to a .cer file.
            """
    )

    @Option(name: .long, help: "Path to base64-encoded CSR file.")
    var csrFile: String

    @Option(name: .long, help: "Certificate type (e.g. IOS_DISTRIBUTION).")
    var type: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let csrPath = (csrFile as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: csrPath) else {
            logger.log("CSR file not found: \(csrPath)", level: .error)
            throw ExitCode(1)
        }
        let csr = try String(contentsOfFile: csrPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let api = try resolveDevPortalAPI(logger: logger)
        let cert = try await api.createCertificate(
            csrContent: csr, certificateType: type
        )
        if json {
            try emitDevPortalJSON(cert)
        } else {
            logger.log("created certificate \(cert.id)", level: .success)
            print("  type:    \(cert.attributes?.certificateType ?? "(unknown)")")
            if let exp = cert.attributes?.expirationDate {
                print("  expires: \(exp)")
            }
        }
    }
}

struct DevPortalCertificatesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Revoke a certificate. Irreversible."
    )

    @Argument(help: "Certificate id.")
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
        let api = try resolveDevPortalAPI(logger: logger)
        try await api.revokeCertificate(id: certificateID)
        logger.log("revoked certificate \(certificateID)", level: .success)
    }
}

// MARK: - profiles

struct DevPortalProfilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "Manage provisioning profiles.",
        subcommands: [
            DevPortalProfilesListCommand.self,
            DevPortalProfilesGetCommand.self,
            DevPortalProfilesCreateCommand.self,
            DevPortalProfilesDeleteCommand.self,
        ],
        defaultSubcommand: DevPortalProfilesListCommand.self
    )
}

struct DevPortalProfilesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List provisioning profiles."
    )

    @Option(name: .long, help: "Filter by profileType (e.g. IOS_APP_STORE).")
    var type: String?

    @Option(name: .long, help: "Filter by bundle id (reverse-DNS).")
    var bundleId: String?

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        let result = try await api.listProfiles(
            type: type, bundleIDFilter: bundleId, limit: limit, cursor: cursor
        )
        if json {
            struct Out: Encodable {
                let profiles: [DevPortalAPI.Profile]
                let nextCursor: String?
            }
            try emitDevPortalJSON(Out(
                profiles: result.profiles,
                nextCursor: result.nextCursor
            ))
            return
        }
        logger.header("Profiles (\(result.profiles.count))")
        if result.profiles.isEmpty {
            print("  (none)")
            return
        }
        for p in result.profiles {
            print("  \(p.attributes?.name ?? "(no name)")")
            print("    id:    \(p.id)")
            print("    type:  \(p.attributes?.profileType ?? "(unknown)")")
            print("    state: \(p.attributes?.profileState ?? "(unknown)")")
            if let exp = p.attributes?.expirationDate {
                print("    exp:   \(exp)")
            }
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct DevPortalProfilesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one provisioning profile by id."
    )

    @Argument(help: "Profile id.")
    var profileID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        guard let p = try await api.getProfile(id: profileID) else {
            logger.log("no profile with id \(profileID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitDevPortalJSON(p)
            return
        }
        logger.header(p.attributes?.name ?? p.id)
        print("  id:        \(p.id)")
        print("  type:      \(p.attributes?.profileType ?? "(unset)")")
        print("  state:     \(p.attributes?.profileState ?? "(unset)")")
        print("  platform:  \(p.attributes?.platform ?? "(unset)")")
        print("  uuid:      \(p.attributes?.uuid ?? "(unset)")")
        print("  expires:   \(p.attributes?.expirationDate.map(String.init(describing:)) ?? "(unset)")")
        if p.attributes?.profileContent != nil {
            print("  profileContent: (base64 contents, run with --json to access)")
        }
    }
}

struct DevPortalProfilesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new provisioning profile.",
        discussion: """
            Required relationships: a bundleId (ASC database id, NOT the \
            reverse-DNS identifier), at least one certificate id, and for \
            development / ad-hoc profiles, one or more device ids. App Store \
            and In-House profiles ignore the device list.
            """
    )

    @Option(name: .long, help: "Profile display name.")
    var name: String

    @Option(name: .long, help: "Profile type (e.g. IOS_APP_STORE).")
    var type: String

    @Option(name: .long, help: "ASC database id of the bundle (from `devportal bundle-ids list`).")
    var bundleId: String

    @Option(name: .long, help: "Comma-separated certificate ids.")
    var certificates: String

    @Option(name: .long, help: "Comma-separated device ids (required for development / ad-hoc).")
    var devices: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let certs = splitCSV(certificates)
        guard !certs.isEmpty else {
            logger.log("--certificates must contain at least one id", level: .error)
            throw ExitCode(1)
        }
        let devs = splitCSV(devices)
        let api = try resolveDevPortalAPI(logger: logger)
        let profile = try await api.createProfile(
            name: name,
            profileType: type,
            bundleIDIdentifier: bundleId,
            certificateIDs: certs,
            deviceIDs: devs
        )
        if json {
            try emitDevPortalJSON(profile)
        } else {
            logger.log("created profile \(profile.id)", level: .success)
            print("  name:   \(profile.attributes?.name ?? "(unset)")")
            print("  type:   \(profile.attributes?.profileType ?? "(unset)")")
            print("  state:  \(profile.attributes?.profileState ?? "(unset)")")
        }
    }
}

struct DevPortalProfilesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a provisioning profile."
    )

    @Argument(help: "Profile id.")
    var profileID: String

    @Flag(name: [.short, .long], help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let logger = Logger()
        if !yes {
            print("About to delete profile \(profileID). Continue? [y/N] ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                logger.log("aborted", level: .info)
                return
            }
        }
        let api = try resolveDevPortalAPI(logger: logger)
        try await api.deleteProfile(id: profileID)
        logger.log("deleted profile \(profileID)", level: .success)
    }
}

// MARK: - devices

struct DevPortalDevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "Manage registered test devices.",
        subcommands: [
            DevPortalDevicesListCommand.self,
            DevPortalDevicesGetCommand.self,
            DevPortalDevicesCreateCommand.self,
            DevPortalDevicesModifyCommand.self,
        ],
        defaultSubcommand: DevPortalDevicesListCommand.self
    )
}

struct DevPortalDevicesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List registered test devices."
    )

    @Option(name: .long, help: "Filter by platform (IOS, MAC_OS).")
    var platform: String?

    @Option(name: .long, help: "Filter by status (ENABLED, DISABLED).")
    var status: String?

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        let result = try await api.listDevices(
            platform: platform, status: status, limit: limit, cursor: cursor
        )
        if json {
            struct Out: Encodable {
                let devices: [DevPortalAPI.Device]
                let nextCursor: String?
            }
            try emitDevPortalJSON(Out(devices: result.devices, nextCursor: result.nextCursor))
            return
        }
        logger.header("Devices (\(result.devices.count))")
        if result.devices.isEmpty {
            print("  (none)")
            return
        }
        for d in result.devices {
            print("  \(d.attributes?.name ?? "(no name)")")
            print("    id:       \(d.id)")
            print("    udid:     \(d.attributes?.udid ?? "(unknown)")")
            print("    platform: \(d.attributes?.platform ?? "(unknown)")")
            print("    status:   \(d.attributes?.status ?? "(unknown)")")
            if let model = d.attributes?.model { print("    model:    \(model)") }
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct DevPortalDevicesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one device by id."
    )

    @Argument(help: "Device id.")
    var deviceID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        guard let d = try await api.getDevice(id: deviceID) else {
            logger.log("no device with id \(deviceID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitDevPortalJSON(d)
            return
        }
        logger.header(d.attributes?.name ?? d.id)
        print("  id:           \(d.id)")
        print("  udid:         \(d.attributes?.udid ?? "(unset)")")
        print("  platform:     \(d.attributes?.platform ?? "(unset)")")
        print("  status:       \(d.attributes?.status ?? "(unset)")")
        print("  device class: \(d.attributes?.deviceClass ?? "(unset)")")
        print("  model:        \(d.attributes?.model ?? "(unset)")")
    }
}

struct DevPortalDevicesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Register a new test device."
    )

    @Option(name: .long, help: "Device display name.")
    var name: String

    @Option(name: .long, help: "Device UDID.")
    var udid: String

    @Option(name: .long, help: "Platform (IOS, MAC_OS). Default IOS.")
    var platform: String = "IOS"

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        let d = try await api.registerDevice(
            name: name, udid: udid, platform: platform
        )
        if json {
            try emitDevPortalJSON(d)
        } else {
            logger.log("registered device \(d.id)", level: .success)
        }
    }
}

struct DevPortalDevicesModifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "modify",
        abstract: "Rename a device or change its ENABLED/DISABLED status."
    )

    @Argument(help: "Device id.")
    var deviceID: String

    @Option(name: .long, help: "New display name.")
    var name: String?

    @Option(name: .long, help: "New status (ENABLED or DISABLED).")
    var status: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        let d = try await api.modifyDevice(id: deviceID, name: name, status: status)
        if json {
            try emitDevPortalJSON(d)
        } else {
            logger.log("modified device \(d.id)", level: .success)
            if let n = d.attributes?.name { print("  name:   \(n)") }
            if let s = d.attributes?.status { print("  status: \(s)") }
        }
    }
}

// MARK: - bundle ids

struct DevPortalBundleIDsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-ids",
        abstract: "Manage registered app identifiers (bundle IDs).",
        subcommands: [
            DevPortalBundleIDsListCommand.self,
            DevPortalBundleIDsGetCommand.self,
            DevPortalBundleIDsCreateCommand.self,
            DevPortalBundleIDsUpdateCommand.self,
            DevPortalBundleIDsDeleteCommand.self,
        ],
        defaultSubcommand: DevPortalBundleIDsListCommand.self
    )
}

struct DevPortalBundleIDsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List registered bundle IDs."
    )

    @Option(name: .long, help: "Filter to one reverse-DNS identifier (e.g. com.example.myapp).")
    var identifier: String?

    @Option(name: .long, help: "Filter by platform (IOS, MAC_OS, UNIVERSAL).")
    var platform: String?

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        let result = try await api.listBundleIDs(
            identifierFilter: identifier,
            platform: platform,
            limit: limit,
            cursor: cursor
        )
        if json {
            struct Out: Encodable {
                let bundleIds: [DevPortalAPI.BundleID]
                let nextCursor: String?
            }
            try emitDevPortalJSON(Out(bundleIds: result.bundleIDs, nextCursor: result.nextCursor))
            return
        }
        logger.header("Bundle IDs (\(result.bundleIDs.count))")
        if result.bundleIDs.isEmpty {
            print("  (none)")
            return
        }
        for b in result.bundleIDs {
            print("  \(b.attributes?.identifier ?? "(no identifier)")")
            print("    id:       \(b.id)")
            print("    name:     \(b.attributes?.name ?? "(unset)")")
            print("    platform: \(b.attributes?.platform ?? "(unknown)")")
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct DevPortalBundleIDsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one bundle ID by its ASC database id."
    )

    @Argument(help: "ASC bundle id (database id, not reverse-DNS).")
    var bundleID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        guard let b = try await api.getBundleID(id: bundleID) else {
            logger.log("no bundle id with id \(bundleID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitDevPortalJSON(b)
            return
        }
        logger.header(b.attributes?.identifier ?? b.id)
        print("  id:         \(b.id)")
        print("  identifier: \(b.attributes?.identifier ?? "(unset)")")
        print("  name:       \(b.attributes?.name ?? "(unset)")")
        print("  platform:   \(b.attributes?.platform ?? "(unset)")")
        print("  seed id:    \(b.attributes?.seedId ?? "(unset)")")
    }
}

struct DevPortalBundleIDsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Register a new app identifier."
    )

    @Option(name: .long, help: "Reverse-DNS identifier (e.g. com.example.myapp).")
    var identifier: String

    @Option(name: .long, help: "Display name shown in the developer portal.")
    var name: String

    @Option(name: .long, help: "Platform (IOS, MAC_OS, UNIVERSAL). Default IOS.")
    var platform: String = "IOS"

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        let b = try await api.createBundleID(
            identifier: identifier, name: name, platform: platform
        )
        if json {
            try emitDevPortalJSON(b)
        } else {
            logger.log("created bundle id \(b.id)", level: .success)
            print("  identifier: \(b.attributes?.identifier ?? "(unset)")")
            print("  name:       \(b.attributes?.name ?? "(unset)")")
        }
    }
}

struct DevPortalBundleIDsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Rename a bundle ID's display name."
    )

    @Argument(help: "ASC bundle id.")
    var bundleID: String

    @Option(name: .long, help: "New display name.")
    var name: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        let b = try await api.updateBundleID(id: bundleID, name: name)
        if json {
            try emitDevPortalJSON(b)
        } else {
            logger.log("renamed bundle id \(b.id) to \(b.attributes?.name ?? "(?)")", level: .success)
        }
    }
}

struct DevPortalBundleIDsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an app identifier. Blocked if any profiles or apps reference it."
    )

    @Argument(help: "ASC bundle id.")
    var bundleID: String

    @Flag(name: [.short, .long], help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let logger = Logger()
        if !yes {
            print("About to delete bundle id \(bundleID). Continue? [y/N] ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                logger.log("aborted", level: .info)
                return
            }
        }
        let api = try resolveDevPortalAPI(logger: logger)
        try await api.deleteBundleID(id: bundleID)
        logger.log("deleted bundle id \(bundleID)", level: .success)
    }
}

// MARK: - capabilities

struct DevPortalCapabilitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Manage capabilities (Push, iCloud, App Groups, etc.) on a bundle ID.",
        subcommands: [
            DevPortalCapabilitiesListCommand.self,
            DevPortalCapabilitiesEnableCommand.self,
            DevPortalCapabilitiesDisableCommand.self,
        ],
        defaultSubcommand: DevPortalCapabilitiesListCommand.self
    )
}

struct DevPortalCapabilitiesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List capabilities currently enabled on a bundle ID."
    )

    @Option(name: .long, help: "ASC bundle id (database id, from `devportal bundle-ids list`).")
    var bundleId: String

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveDevPortalAPI(logger: logger)
        let result = try await api.listCapabilities(
            bundleIDDatabaseID: bundleId, limit: limit, cursor: cursor
        )
        if json {
            struct Out: Encodable {
                let capabilities: [DevPortalAPI.BundleIDCapability]
                let nextCursor: String?
            }
            try emitDevPortalJSON(Out(
                capabilities: result.capabilities,
                nextCursor: result.nextCursor
            ))
            return
        }
        logger.header("Capabilities on \(bundleId) (\(result.capabilities.count))")
        if result.capabilities.isEmpty {
            print("  (none enabled)")
            return
        }
        for c in result.capabilities {
            print("  \(c.attributes?.capabilityType ?? "(unknown)")")
            print("    id: \(c.id)")
            if let settings = c.attributes?.settings, !settings.isEmpty {
                print("    settings:")
                for s in settings {
                    print("      \(s.key ?? "(unnamed)")")
                }
            }
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

struct DevPortalCapabilitiesEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a capability on a bundle ID.",
        discussion: """
            For capabilities that take no configuration (e.g. PUSH_NOTIFICATIONS), \
            pass --bundle-id and --type only. For capabilities like APP_GROUPS or \
            ICLOUD, pass --settings-file pointing at a JSON file with the \
            capability settings array.
            """
    )

    @Option(name: .long, help: "ASC bundle id.")
    var bundleId: String

    @Option(name: .long, help: "Capability type (e.g. PUSH_NOTIFICATIONS).")
    var type: String

    @Option(name: .long, help: "Optional path to a JSON file with the capability settings array.")
    var settingsFile: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let settings: [DevPortalAPI.CapabilitySetting]?
        if let path = settingsFile {
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                logger.log("settings file not found: \(expanded)", level: .error)
                throw ExitCode(1)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
            let decoder = JSONDecoder()
            settings = try decoder.decode([DevPortalAPI.CapabilitySetting].self, from: data)
        } else {
            settings = nil
        }
        let api = try resolveDevPortalAPI(logger: logger)
        let cap = try await api.enableCapability(
            bundleIDDatabaseID: bundleId,
            capabilityType: type,
            settings: settings
        )
        if json {
            try emitDevPortalJSON(cap)
        } else {
            logger.log("enabled \(type) on \(bundleId)", level: .success)
            print("  capability id: \(cap.id)")
        }
    }
}

struct DevPortalCapabilitiesDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a capability."
    )

    @Argument(help: "Capability id.")
    var capabilityID: String

    @Flag(name: [.short, .long], help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let logger = Logger()
        if !yes {
            print("About to disable capability \(capabilityID). Continue? [y/N] ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                logger.log("aborted", level: .info)
                return
            }
        }
        let api = try resolveDevPortalAPI(logger: logger)
        try await api.disableCapability(id: capabilityID)
        logger.log("disabled capability \(capabilityID)", level: .success)
    }
}
