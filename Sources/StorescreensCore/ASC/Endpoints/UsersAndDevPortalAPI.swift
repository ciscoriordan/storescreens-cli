import Foundation

// MARK: - Users API

/// App Store Connect endpoints for team users and invitations (the "Users
/// and Access" panel in the ASC web UI), plus the per-user visible-apps
/// relationship.
///
/// Apple's role taxonomy is a single string enum (`userRole`) with values
/// like `ADMIN`, `FINANCE`, `ACCOUNT_HOLDER`, `SALES`, `MARKETING`,
/// `APP_MANAGER`, `DEVELOPER`, `ACCESS_TO_REPORTS`, `CUSTOMER_SUPPORT`,
/// `CREATE_APPS`, `CLOUD_MANAGED_DEVELOPER_ID`, `CLOUD_MANAGED_APP_DISTRIBUTION`,
/// and the App Review roles (`APP_MANAGER`, `READ_ONLY`). Roles are not
/// stamped onto the wire as nested objects; they're a comma-joined list on
/// the `roles` attribute. We round-trip raw strings so a future Apple-added
/// role still works without a code change.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/users
package struct UsersAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    /// String values Apple documents for the `roles` attribute on
    /// `users` and `userInvitations`. Kept here as constants so callers
    /// can spell-check at the type level. The wire type is `String` so
    /// any unknown value still round-trips.
    package enum Role {
        package static let admin              = "ADMIN"
        package static let finance            = "FINANCE"
        package static let accountHolder      = "ACCOUNT_HOLDER"
        package static let sales              = "SALES"
        package static let marketing          = "MARKETING"
        package static let appManager         = "APP_MANAGER"
        package static let developer          = "DEVELOPER"
        package static let accessToReports    = "ACCESS_TO_REPORTS"
        package static let customerSupport    = "CUSTOMER_SUPPORT"
        package static let createApps         = "CREATE_APPS"
        package static let cloudManagedDeveloperID
            = "CLOUD_MANAGED_DEVELOPER_ID"
        package static let cloudManagedAppDistribution
            = "CLOUD_MANAGED_APP_DISTRIBUTION"
        package static let generateIndividualKeys
            = "GENERATE_INDIVIDUAL_KEYS"
        package static let imageManager       = "IMAGE_MANAGER"
        package static let appPurchaseManager = "APP_PURCHASE_MANAGER"
        package static let readOnly           = "READ_ONLY"

        /// Validates a free-form role string against the known set. Unknown
        /// roles aren't an error (Apple adds new ones), but callers can use
        /// this to warn the operator.
        package static let known: Set<String> = [
            admin, finance, accountHolder, sales, marketing, appManager,
            developer, accessToReports, customerSupport, createApps,
            cloudManagedDeveloperID, cloudManagedAppDistribution,
            generateIndividualKeys, imageManager, appPurchaseManager,
            readOnly,
        ]
    }

    // MARK: - User

    package struct User: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let username: String?
            package let firstName: String?
            package let lastName: String?
            /// Mirrors Apple's wire shape: an array of UserRole strings.
            package let roles: [String]?
            /// True when the user can see all of the team's apps. False
            /// means the user is restricted to the apps in their
            /// `visibleApps` relationship.
            package let allAppsVisible: Bool?
            /// True when the user can manage provisioning profiles +
            /// certificates from the Developer Portal.
            package let provisioningAllowed: Bool?
        }
    }

    /// Lists team users. Paginated: pass `cursor` from the previous
    /// response to fetch the next page; the returned `nextCursor` is nil
    /// when there are no more pages.
    package func listUsers(
        limit: Int = 200,
        cursor: String? = nil,
        filterUsername: String? = nil
    ) async throws -> (users: [User], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        if let filterUsername { query["filter[username]"] = filterUsername }
        struct Resp: Decodable {
            let data: [User]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "users",
            query: query,
            as: Resp.self
        )
        return (resp.data, Self.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/users/{id}`. Returns nil on 404.
    package func getUser(id: String) async throws -> User? {
        struct Resp: Decodable { let data: User }
        do {
            let resp: Resp = try await client.get(path: "users/\(id)", as: Resp.self)
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Looks up a user by their `username` (email address). Returns nil if
    /// no user matches. Single-page fetch, ASC lists are tiny for users.
    package func findUser(username: String) async throws -> User? {
        let (users, _) = try await listUsers(limit: 1, filterUsername: username)
        return users.first
    }

    /// Editable attributes on `users`. Nil fields are omitted from the wire
    /// body so they stay untouched.
    package struct UserUpdate: Sendable, Equatable {
        package var roles: [String]?
        package var allAppsVisible: Bool?
        package var provisioningAllowed: Bool?

        package init(
            roles: [String]? = nil,
            allAppsVisible: Bool? = nil,
            provisioningAllowed: Bool? = nil
        ) {
            self.roles = roles
            self.allAppsVisible = allAppsVisible
            self.provisioningAllowed = provisioningAllowed
        }
    }

    /// PATCH `/v1/users/{id}` to update any combination of role list,
    /// all-apps-visible flag, and provisioning rights. Nil values stay
    /// untouched.
    @discardableResult
    package func updateUser(
        id: String,
        update: UserUpdate,
        visibleAppIDs: [String]? = nil
    ) async throws -> User {
        struct AttrsPatch: Encodable {
            var roles: [String]?
            var allAppsVisible: Bool?
            var provisioningAllowed: Bool?
        }
        struct AppRef: Encodable {
            let type = "apps"
            let id: String
        }
        struct VisibleApps: Encodable {
            let data: [AppRef]
        }
        struct Rels: Encodable {
            var visibleApps: VisibleApps?
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "users"
                let id: String
                let attributes: AttrsPatch
                let relationships: Rels?
            }
            let data: Data
        }
        let attrs = AttrsPatch(
            roles: update.roles,
            allAppsVisible: update.allAppsVisible,
            provisioningAllowed: update.provisioningAllowed
        )
        let rels: Rels?
        if let visibleAppIDs {
            rels = Rels(visibleApps: .init(data: visibleAppIDs.map { .init(id: $0) }))
        } else {
            rels = nil
        }
        let body = Body(data: .init(
            id: id, attributes: attrs, relationships: rels
        ))
        struct Resp: Decodable { let data: User }
        let resp: Resp = try await client.patch(
            path: "users/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/users/{id}` to remove a user from the team. ASC
    /// returns 204 on success.
    package func deleteUser(id: String) async throws {
        try await client.delete(path: "users/\(id)")
    }

    // MARK: - User invitations

    package struct UserInvitation: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let email: String?
            package let firstName: String?
            package let lastName: String?
            package let expirationDate: Date?
            package let roles: [String]?
            package let allAppsVisible: Bool?
            package let provisioningAllowed: Bool?
        }
    }

    package func listInvitations(
        limit: Int = 200,
        cursor: String? = nil,
        filterEmail: String? = nil
    ) async throws -> (invitations: [UserInvitation], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        if let filterEmail { query["filter[email]"] = filterEmail }
        struct Resp: Decodable {
            let data: [UserInvitation]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "userInvitations",
            query: query,
            as: Resp.self
        )
        return (resp.data, Self.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/userInvitations/{id}`. Returns nil on 404.
    package func getInvitation(id: String) async throws -> UserInvitation? {
        struct Resp: Decodable { let data: UserInvitation }
        do {
            let resp: Resp = try await client.get(
                path: "userInvitations/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Creates a pending invitation for an email. Apple emails the user a
    /// link to accept and join the team with the given roles. Optionally
    /// restrict visible apps when `allAppsVisible == false`.
    package func createInvitation(
        email: String,
        firstName: String,
        lastName: String,
        roles: [String],
        allAppsVisible: Bool = true,
        provisioningAllowed: Bool = false,
        visibleAppIDs: [String] = []
    ) async throws -> UserInvitation {
        struct AppRef: Encodable {
            let type = "apps"
            let id: String
        }
        struct VisibleApps: Encodable { let data: [AppRef] }
        struct Rels: Encodable { var visibleApps: VisibleApps? }
        struct Attrs: Encodable {
            let email: String
            let firstName: String
            let lastName: String
            let roles: [String]
            let allAppsVisible: Bool
            let provisioningAllowed: Bool
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "userInvitations"
                let attributes: Attrs
                let relationships: Rels?
            }
            let data: Data
        }
        let rels: Rels?
        if !allAppsVisible && !visibleAppIDs.isEmpty {
            rels = Rels(visibleApps: .init(data: visibleAppIDs.map { .init(id: $0) }))
        } else {
            rels = nil
        }
        let body = Body(data: .init(
            attributes: .init(
                email: email,
                firstName: firstName,
                lastName: lastName,
                roles: roles,
                allAppsVisible: allAppsVisible,
                provisioningAllowed: provisioningAllowed
            ),
            relationships: rels
        ))
        struct Resp: Decodable { let data: UserInvitation }
        let resp: Resp = try await client.post(
            path: "userInvitations", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/userInvitations/{id}` to cancel a pending invitation
    /// before the recipient accepts it.
    package func cancelInvitation(id: String) async throws {
        try await client.delete(path: "userInvitations/\(id)")
    }

    // MARK: - Visible apps

    /// GET `/v1/users/{id}/visibleApps`. Returns the IDs of apps the user
    /// has scoped access to. When `attributes.allAppsVisible == true` on
    /// the user record, this list is informational only, the user sees
    /// every app on the team.
    package func listVisibleApps(
        userID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (appIDs: [String], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        struct Resp: Decodable {
            struct Ref: Decodable { let id: String }
            let data: [Ref]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "users/\(userID)/visibleApps",
            query: query,
            as: Resp.self
        )
        return (resp.data.map(\.id), Self.extractCursor(from: resp.links?.next))
    }

    // MARK: - Helpers

    /// Apple's `links.next` is a fully-qualified URL with a `cursor`
    /// query parameter. Pull just the cursor value out so callers can
    /// hand it back to us verbatim on the next call.
    package static func extractCursor(from nextLink: String?) -> String? {
        guard let nextLink, let comps = URLComponents(string: nextLink) else {
            return nil
        }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }
}

// MARK: - Developer Portal API

/// App Store Connect endpoints for the code-signing surface (the
/// "Certificates, Identifiers & Profiles" pages of the Apple Developer
/// portal, surfaced through the App Store Connect API).
///
/// Four resource families:
///
///   - `certificates`, signing certificates (DEVELOPMENT,
///     DISTRIBUTION, MAC_APP_DISTRIBUTION, etc.). Create takes a CSR; ASC
///     responds with the signed certificate data.
///   - `profiles`, provisioning profiles. Tied to a bundleId, a list of
///     certificates, and a list of devices.
///   - `devices`, registered test devices keyed by UDID + platform.
///   - `bundleIds` + `bundleIdCapabilities`, app identifiers and the
///     capabilities (Push, iCloud, App Groups, etc.) enabled on them.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/profiles
///        https://developer.apple.com/documentation/appstoreconnectapi/certificates
///        https://developer.apple.com/documentation/appstoreconnectapi/devices
///        https://developer.apple.com/documentation/appstoreconnectapi/bundle_ids
package struct DevPortalAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Certificates

    /// String values Apple documents for `certificates.certificateType`.
    /// The wire type is `String` so any unknown value still round-trips.
    package enum CertificateType {
        package static let iosDevelopment        = "IOS_DEVELOPMENT"
        package static let iosDistribution       = "IOS_DISTRIBUTION"
        package static let macAppDistribution    = "MAC_APP_DISTRIBUTION"
        package static let macInstallerDistribution
            = "MAC_INSTALLER_DISTRIBUTION"
        package static let macAppDevelopment     = "MAC_APP_DEVELOPMENT"
        package static let developerIDKext       = "DEVELOPER_ID_KEXT"
        package static let developerIDApplication
            = "DEVELOPER_ID_APPLICATION"
        package static let development           = "DEVELOPMENT"
        package static let distribution          = "DISTRIBUTION"
        package static let passTypeID            = "PASS_TYPE_ID"
        package static let passTypeIDWithNFC     = "PASS_TYPE_ID_WITH_NFC"

        package static let known: Set<String> = [
            iosDevelopment, iosDistribution, macAppDistribution,
            macInstallerDistribution, macAppDevelopment, developerIDKext,
            developerIDApplication, development, distribution,
            passTypeID, passTypeIDWithNFC,
        ]
    }

    package struct Certificate: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let certificateContent: String?
            package let displayName: String?
            package let expirationDate: Date?
            package let name: String?
            package let platform: String?
            package let serialNumber: String?
            package let certificateType: String?
        }
    }

    package func listCertificates(
        type: String? = nil,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (certificates: [Certificate], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        if let type { query["filter[certificateType]"] = type }
        struct Resp: Decodable {
            let data: [Certificate]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "certificates",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/certificates/{id}`. Returns nil on 404.
    package func getCertificate(id: String) async throws -> Certificate? {
        struct Resp: Decodable { let data: Certificate }
        do {
            let resp: Resp = try await client.get(
                path: "certificates/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Creates a certificate from a base64-encoded PEM CSR
    /// (`csrContent`). Apple signs the request and returns the certificate
    /// data in `attributes.certificateContent` (also base64-encoded).
    /// Save that to a `.cer` file to import into Keychain Access.
    package func createCertificate(
        csrContent: String,
        certificateType: String
    ) async throws -> Certificate {
        struct Attrs: Encodable {
            let csrContent: String
            let certificateType: String
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "certificates"
                let attributes: Attrs
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(csrContent: csrContent, certificateType: certificateType)
        ))
        struct Resp: Decodable { let data: Certificate }
        let resp: Resp = try await client.post(
            path: "certificates", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/certificates/{id}`. Revokes the certificate; this is
    /// irreversible. Provisioning profiles signed by the certificate stay
    /// valid until they expire on their own schedule.
    package func revokeCertificate(id: String) async throws {
        try await client.delete(path: "certificates/\(id)")
    }

    // MARK: - Profiles

    /// String values Apple documents for `profiles.profileType`.
    package enum ProfileType {
        package static let iosAppDevelopment   = "IOS_APP_DEVELOPMENT"
        package static let iosAppStore         = "IOS_APP_STORE"
        package static let iosAppAdHoc         = "IOS_APP_ADHOC"
        package static let iosAppInhouse       = "IOS_APP_INHOUSE"
        package static let macAppDevelopment   = "MAC_APP_DEVELOPMENT"
        package static let macAppStore         = "MAC_APP_STORE"
        package static let macAppDirect        = "MAC_APP_DIRECT"
        package static let tvOSAppDevelopment  = "TVOS_APP_DEVELOPMENT"
        package static let tvOSAppStore        = "TVOS_APP_STORE"
        package static let tvOSAppAdHoc        = "TVOS_APP_ADHOC"
        package static let tvOSAppInhouse      = "TVOS_APP_INHOUSE"
        package static let macCatalystAppDevelopment
            = "MAC_CATALYST_APP_DEVELOPMENT"
        package static let macCatalystAppStore = "MAC_CATALYST_APP_STORE"
        package static let macCatalystAppDirect
            = "MAC_CATALYST_APP_DIRECT"

        package static let known: Set<String> = [
            iosAppDevelopment, iosAppStore, iosAppAdHoc, iosAppInhouse,
            macAppDevelopment, macAppStore, macAppDirect,
            tvOSAppDevelopment, tvOSAppStore, tvOSAppAdHoc, tvOSAppInhouse,
            macCatalystAppDevelopment, macCatalystAppStore,
            macCatalystAppDirect,
        ]
    }

    package struct Profile: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let name: String?
            package let platform: String?
            package let profileContent: String?
            package let uuid: String?
            package let createdDate: Date?
            package let profileState: String?
            package let profileType: String?
            package let expirationDate: Date?
        }
    }

    package func listProfiles(
        type: String? = nil,
        bundleIDFilter: String? = nil,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (profiles: [Profile], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        if let type { query["filter[profileType]"] = type }
        if let bundleIDFilter { query["filter[bundleId]"] = bundleIDFilter }
        struct Resp: Decodable {
            let data: [Profile]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "profiles",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/profiles/{id}`. Returns nil on 404.
    package func getProfile(id: String) async throws -> Profile? {
        struct Resp: Decodable { let data: Profile }
        do {
            let resp: Resp = try await client.get(
                path: "profiles/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Creates a provisioning profile. Required relationships: a
    /// `bundleId`, at least one `certificate`, and (for development /
    /// ad-hoc profiles) one or more `device` IDs. App Store and In-House
    /// profiles ignore the device list, pass an empty array.
    package func createProfile(
        name: String,
        profileType: String,
        bundleIDIdentifier: String,
        certificateIDs: [String],
        deviceIDs: [String] = []
    ) async throws -> Profile {
        struct Attrs: Encodable {
            let name: String
            let profileType: String
        }
        struct BundleRef: Encodable {
            struct D: Encodable { let type = "bundleIds"; let id: String }
            let data: D
        }
        struct CertRef: Encodable {
            let type = "certificates"
            let id: String
        }
        struct CertsRel: Encodable { let data: [CertRef] }
        struct DeviceRef: Encodable {
            let type = "devices"
            let id: String
        }
        struct DevicesRel: Encodable { let data: [DeviceRef] }
        struct Rels: Encodable {
            let bundleId: BundleRef
            let certificates: CertsRel
            var devices: DevicesRel?
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "profiles"
                let attributes: Attrs
                let relationships: Rels
            }
            let data: Data
        }
        let devicesRel: DevicesRel? = deviceIDs.isEmpty
            ? nil
            : DevicesRel(data: deviceIDs.map { DeviceRef(id: $0) })
        let body = Body(data: .init(
            attributes: .init(name: name, profileType: profileType),
            relationships: .init(
                bundleId: .init(data: .init(id: bundleIDIdentifier)),
                certificates: .init(data: certificateIDs.map { .init(id: $0) }),
                devices: devicesRel
            )
        ))
        struct Resp: Decodable { let data: Profile }
        let resp: Resp = try await client.post(
            path: "profiles", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/profiles/{id}` invalidates the profile immediately.
    /// Builds signed with it lose the right to install on new devices,
    /// but already-installed copies keep running until their app's
    /// signature expires.
    package func deleteProfile(id: String) async throws {
        try await client.delete(path: "profiles/\(id)")
    }

    // MARK: - Devices

    /// String values Apple documents for `devices.deviceClass`.
    package enum DeviceClass {
        package static let appleWatch    = "APPLE_WATCH"
        package static let iPad          = "IPAD"
        package static let iPhone        = "IPHONE"
        package static let iPod          = "IPOD"
        package static let appleTV       = "APPLE_TV"
        package static let mac           = "MAC"
    }

    /// String values Apple documents for `devices.platform`. Note this
    /// uses `IOS` for iPhone/iPad and `MAC_OS` for Mac, mirroring the
    /// platform strings used elsewhere in the API.
    package enum DevicePlatform {
        package static let ios   = "IOS"
        package static let macOS = "MAC_OS"
    }

    /// String values Apple documents for `devices.status`. `ENABLED`
    /// devices count against the team's 100-device-per-class quota;
    /// `DISABLED` devices don't.
    package enum DeviceStatus {
        package static let enabled  = "ENABLED"
        package static let disabled = "DISABLED"
    }

    package struct Device: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let addedDate: Date?
            package let name: String?
            package let deviceClass: String?
            package let model: String?
            package let udid: String?
            package let platform: String?
            package let status: String?
        }
    }

    package func listDevices(
        platform: String? = nil,
        status: String? = nil,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (devices: [Device], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        if let platform { query["filter[platform]"] = platform }
        if let status { query["filter[status]"] = status }
        struct Resp: Decodable {
            let data: [Device]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "devices",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/devices/{id}`. Returns nil on 404.
    package func getDevice(id: String) async throws -> Device? {
        struct Resp: Decodable { let data: Device }
        do {
            let resp: Resp = try await client.get(
                path: "devices/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Registers a new test device on the team. The UDID is the 40-char
    /// (legacy) or 25-char (recent iOS / iPad) device identifier.
    /// Apple rejects duplicate UDIDs with a 409, wrap that with
    /// `APIError.isAlreadySetConflict` if your caller wants a no-op
    /// fallback to lookup-by-UDID.
    package func registerDevice(
        name: String,
        udid: String,
        platform: String = "IOS"
    ) async throws -> Device {
        struct Attrs: Encodable {
            let name: String
            let udid: String
            let platform: String
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "devices"
                let attributes: Attrs
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(name: name, udid: udid, platform: platform)
        ))
        struct Resp: Decodable { let data: Device }
        let resp: Resp = try await client.post(
            path: "devices", body: body, as: Resp.self
        )
        return resp.data
    }

    /// PATCH `/v1/devices/{id}` to rename or toggle a device's status
    /// between `ENABLED` and `DISABLED`. Apple does not allow deleting a
    /// device, only disabling it, disabled devices free up a slot in
    /// the per-class quota.
    @discardableResult
    package func modifyDevice(
        id: String,
        name: String? = nil,
        status: String? = nil
    ) async throws -> Device {
        struct AttrsPatch: Encodable {
            var name: String?
            var status: String?
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "devices"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: AttrsPatch(name: name, status: status)
        ))
        struct Resp: Decodable { let data: Device }
        let resp: Resp = try await client.patch(
            path: "devices/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    // MARK: - Bundle IDs

    /// String values Apple documents for `bundleIds.platform`.
    package enum BundleIDPlatform {
        package static let ios       = "IOS"
        package static let macOS     = "MAC_OS"
        package static let universal = "UNIVERSAL"
    }

    package struct BundleID: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Reverse-DNS identifier (e.g. "com.example.myapp").
            package let identifier: String?
            package let name: String?
            package let platform: String?
            package let seedId: String?
        }
    }

    package func listBundleIDs(
        identifierFilter: String? = nil,
        platform: String? = nil,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (bundleIDs: [BundleID], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        if let identifierFilter { query["filter[identifier]"] = identifierFilter }
        if let platform { query["filter[platform]"] = platform }
        struct Resp: Decodable {
            let data: [BundleID]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "bundleIds",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// GET `/v1/bundleIds/{id}`. Returns nil on 404.
    package func getBundleID(id: String) async throws -> BundleID? {
        struct Resp: Decodable { let data: BundleID }
        do {
            let resp: Resp = try await client.get(
                path: "bundleIds/\(id)", as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// Looks up a bundleId by its reverse-DNS identifier. Returns nil if
    /// no match.
    package func findBundleID(identifier: String) async throws -> BundleID? {
        let (matches, _) = try await listBundleIDs(identifierFilter: identifier, limit: 1)
        return matches.first
    }

    /// Registers a new app identifier. `identifier` is reverse-DNS
    /// ("com.example.myapp"); `name` is the human-readable label shown
    /// in the developer portal. ASC creates a `seedId` automatically.
    package func createBundleID(
        identifier: String,
        name: String,
        platform: String = "IOS"
    ) async throws -> BundleID {
        struct Attrs: Encodable {
            let identifier: String
            let name: String
            let platform: String
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "bundleIds"
                let attributes: Attrs
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(identifier: identifier, name: name, platform: platform)
        ))
        struct Resp: Decodable { let data: BundleID }
        let resp: Resp = try await client.post(
            path: "bundleIds", body: body, as: Resp.self
        )
        return resp.data
    }

    /// PATCH `/v1/bundleIds/{id}` to rename the bundle identifier's
    /// human-readable label. The `identifier` itself (reverse-DNS) is
    /// immutable.
    @discardableResult
    package func updateBundleID(id: String, name: String) async throws -> BundleID {
        struct AttrsPatch: Encodable { let name: String }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "bundleIds"
                let id: String
                let attributes: AttrsPatch
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: AttrsPatch(name: name)
        ))
        struct Resp: Decodable { let data: BundleID }
        let resp: Resp = try await client.patch(
            path: "bundleIds/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/bundleIds/{id}` permanently deletes the identifier.
    /// Apple blocks this if any active provisioning profiles or apps in
    /// App Store Connect reference the bundle id.
    package func deleteBundleID(id: String) async throws {
        try await client.delete(path: "bundleIds/\(id)")
    }

    // MARK: - Bundle ID Capabilities

    /// String values Apple documents for `bundleIdCapabilities.capabilityType`.
    /// Apple adds new capabilities over time; the wire type is `String`
    /// so any unknown value still round-trips.
    package enum CapabilityType {
        package static let appGroups               = "APP_GROUPS"
        package static let applePay                = "APPLE_PAY"
        package static let appleSignIn             = "APPLE_ID_AUTH"
        package static let associatedDomains       = "ASSOCIATED_DOMAINS"
        package static let autoFillCredentialProvider
            = "AUTOFILL_CREDENTIAL_PROVIDER"
        package static let classKit                = "CLASSKIT"
        package static let dataProtection          = "DATA_PROTECTION"
        package static let extendedVirtualAddressing
            = "EXTENDED_VIRTUAL_ADDRESSING"
        package static let fileProvider            = "FILE_PROVIDER_TESTING_MODE"
        package static let fonts                   = "FONT_INSTALLATION"
        package static let gameCenter              = "GAME_CENTER"
        package static let healthKit               = "HEALTHKIT"
        package static let homeKit                 = "HOMEKIT"
        package static let hotspot                 = "HOT_SPOT"
        package static let iCloud                  = "ICLOUD"
        package static let inAppPurchase           = "IN_APP_PURCHASE"
        package static let interAppAudio           = "INTER_APP_AUDIO"
        package static let maps                    = "MAPS"
        package static let multipath               = "MULTIPATH"
        package static let networkExtensions       = "NETWORK_EXTENSIONS"
        package static let nfcTagReading           = "NFC_TAG_READING"
        package static let personalVPN             = "PERSONAL_VPN"
        package static let pushNotifications       = "PUSH_NOTIFICATIONS"
        package static let siri                    = "SIRIKIT"
        package static let systemExtension         = "SYSTEM_EXTENSION_INSTALL"
        package static let userManagement          = "USER_MANAGEMENT"
        package static let wallet                  = "WALLET"
        package static let wirelessAccessoryConfiguration
            = "WIRELESS_ACCESSORY_CONFIGURATION"
        package static let driverKit               = "DRIVERKIT"
        package static let groupActivities         = "GROUP_ACTIVITIES"
        package static let familyControls          = "FAMILY_CONTROLS"
        package static let communicationNotifications
            = "COMMUNICATION_NOTIFICATIONS"
        package static let timeSensitiveNotifications
            = "TIME_SENSITIVE_NOTIFICATIONS"
        package static let appAttest               = "APP_ATTEST"
    }

    package struct BundleIDCapability: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            package let capabilityType: String?
            /// Per-capability free-form settings array. Apple's wire shape
            /// for the inner items is a polymorphic JSON object; we model
            /// it as opaque key/value strings so we don't lose data while
            /// staying forward-compatible.
            package let settings: [CapabilitySetting]?
        }
    }

    /// A single key/value entry inside `bundleIdCapabilities.settings`.
    /// Apple's wire shape nests `options` arrays under each setting; we
    /// flatten that down to a key + a list of selected option strings
    /// since most capability settings only carry an enabled / disabled or
    /// a small enum selection.
    package struct CapabilitySetting: Codable, Sendable {
        package let key: String?
        package let options: [Option]?

        package struct Option: Codable, Sendable {
            package let key: String?
            package let enabled: Bool?
            package let supportsWildcard: Bool?
        }
    }

    package func listCapabilities(
        bundleIDDatabaseID: String,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> (capabilities: [BundleIDCapability], nextCursor: String?) {
        var query: [String: String] = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        struct Resp: Decodable {
            let data: [BundleIDCapability]
            let links: Links?
            struct Links: Decodable { let next: String? }
        }
        let resp: Resp = try await client.get(
            path: "bundleIds/\(bundleIDDatabaseID)/bundleIdCapabilities",
            query: query,
            as: Resp.self
        )
        return (resp.data, UsersAPI.extractCursor(from: resp.links?.next))
    }

    /// Enables a capability on a bundleId. The optional `settings` field
    /// holds per-capability configuration (e.g. iCloud's container list,
    /// AppGroups' group ids). Pass nil for capabilities that take no
    /// configuration (e.g. Push Notifications).
    package func enableCapability(
        bundleIDDatabaseID: String,
        capabilityType: String,
        settings: [CapabilitySetting]? = nil
    ) async throws -> BundleIDCapability {
        struct Attrs: Encodable {
            let capabilityType: String
            let settings: [CapabilitySetting]?
        }
        struct BundleRef: Encodable {
            struct D: Encodable { let type = "bundleIds"; let id: String }
            let data: D
        }
        struct Rels: Encodable { let bundleId: BundleRef }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "bundleIdCapabilities"
                let attributes: Attrs
                let relationships: Rels
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(capabilityType: capabilityType, settings: settings),
            relationships: .init(bundleId: .init(data: .init(id: bundleIDDatabaseID)))
        ))
        struct Resp: Decodable { let data: BundleIDCapability }
        let resp: Resp = try await client.post(
            path: "bundleIdCapabilities", body: body, as: Resp.self
        )
        return resp.data
    }

    /// PATCH `/v1/bundleIdCapabilities/{id}` to change a capability's
    /// settings array without disabling+re-enabling it.
    @discardableResult
    package func updateCapability(
        id: String,
        capabilityType: String,
        settings: [CapabilitySetting]? = nil
    ) async throws -> BundleIDCapability {
        struct Attrs: Encodable {
            let capabilityType: String
            let settings: [CapabilitySetting]?
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "bundleIdCapabilities"
                let id: String
                let attributes: Attrs
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(capabilityType: capabilityType, settings: settings)
        ))
        struct Resp: Decodable { let data: BundleIDCapability }
        let resp: Resp = try await client.patch(
            path: "bundleIdCapabilities/\(id)", body: body, as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/bundleIdCapabilities/{id}` to disable the capability.
    /// Existing builds keep the capability until they're replaced; new
    /// builds without it can fail entitlement checks at install time.
    package func disableCapability(id: String) async throws {
        try await client.delete(path: "bundleIdCapabilities/\(id)")
    }
}
