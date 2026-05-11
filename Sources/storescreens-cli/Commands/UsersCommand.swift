import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens users …` parent command: team-member management against
/// the App Store Connect Users + Invitations endpoints. Read-only commands
/// only fetch; write commands (invite, update, delete, cancel) mutate
/// real ASC team state, so the live operator should run these knowingly.
struct UsersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "users",
        abstract: "Manage App Store Connect team users, invitations, and roles.",
        discussion: """
            Wraps Apple's Users and Roles endpoints. Requires ASC credentials \
            (env vars or `storescreens auth login`).

            Roles Apple documents: ADMIN, FINANCE, ACCOUNT_HOLDER, SALES, \
            MARKETING, APP_MANAGER, DEVELOPER, ACCESS_TO_REPORTS, \
            CUSTOMER_SUPPORT, CREATE_APPS, CLOUD_MANAGED_DEVELOPER_ID, \
            CLOUD_MANAGED_APP_DISTRIBUTION, GENERATE_INDIVIDUAL_KEYS, \
            IMAGE_MANAGER, APP_PURCHASE_MANAGER, READ_ONLY.
            """,
        subcommands: [
            UsersListCommand.self,
            UsersGetCommand.self,
            UsersUpdateCommand.self,
            UsersDeleteCommand.self,
            UsersInviteCommand.self,
            UsersInvitationsListCommand.self,
            UsersInvitationsCancelCommand.self,
            UsersVisibleAppsCommand.self,
        ],
        defaultSubcommand: UsersListCommand.self
    )
}

// MARK: - shared helpers

/// Resolves credentials, prints a friendly error if missing, otherwise
/// returns a UsersAPI ready to call.
@discardableResult
private func resolveUsersAPI(logger: Logger) throws -> UsersAPI {
    guard ASCCredentialResolver.isConfigured() else {
        logger.log("no ASC credentials configured", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let creds = try ASCCredentialResolver.resolve()
    let client = ASCClient(credentials: creds)
    return UsersAPI(client: client)
}

private func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

// MARK: - list

struct UsersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List team users."
    )

    @Option(name: .long, help: "Filter to a single username (email).")
    var username: String?

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call to fetch the next page.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveUsersAPI(logger: logger)
        let result = try await api.listUsers(
            limit: limit, cursor: cursor, filterUsername: username
        )
        if json {
            struct Out: Encodable {
                let users: [UsersAPI.User]
                let nextCursor: String?
            }
            try emitJSON(Out(users: result.users, nextCursor: result.nextCursor))
            return
        }
        logger.header("Team users (\(result.users.count))")
        if result.users.isEmpty {
            print("  (none)")
            return
        }
        for u in result.users {
            let name = [u.attributes?.firstName, u.attributes?.lastName]
                .compactMap { $0 }.joined(separator: " ")
            let nameStr = name.isEmpty ? "(no name)" : name
            let roles = u.attributes?.roles?.joined(separator: ", ") ?? "(no roles)"
            let visibility = u.attributes?.allAppsVisible == true ? "all apps" : "scoped"
            print("  \(u.attributes?.username ?? "(no email)")  \(nameStr)")
            print("    id:    \(u.id)")
            print("    roles: \(roles)")
            print("    apps:  \(visibility)")
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

// MARK: - get

struct UsersGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one team user by id."
    )

    @Argument(help: "ASC user id.")
    var userID: String

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveUsersAPI(logger: logger)
        guard let user = try await api.getUser(id: userID) else {
            logger.log("no user with id \(userID)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try emitJSON(user)
            return
        }
        logger.header(user.attributes?.username ?? user.id)
        print("  id:                   \(user.id)")
        print("  username:             \(user.attributes?.username ?? "(unset)")")
        print("  first name:           \(user.attributes?.firstName ?? "(unset)")")
        print("  last name:            \(user.attributes?.lastName ?? "(unset)")")
        print("  roles:                \(user.attributes?.roles?.joined(separator: ", ") ?? "(none)")")
        print("  all apps visible:     \(user.attributes?.allAppsVisible.map(String.init) ?? "(unset)")")
        print("  provisioning allowed: \(user.attributes?.provisioningAllowed.map(String.init) ?? "(unset)")")
    }
}

// MARK: - update

struct UsersUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a user's roles, visibility, or provisioning rights.",
        discussion: """
            Pass --roles as a comma-separated list. The new list REPLACES the \
            existing one (Apple does not support delta edits). Use --visible-apps \
            with --all-apps-visible=false to restrict the user's view of apps.
            """
    )

    @Argument(help: "ASC user id.")
    var userID: String

    @Option(name: .long, help: "Comma-separated role list (e.g. \"DEVELOPER,APP_MANAGER\"). Replaces the existing roles.")
    var roles: String?

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Whether the user sees every app on the team."
    )
    var allAppsVisible: Bool?

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Whether the user can manage provisioning profiles and certificates."
    )
    var provisioningAllowed: Bool?

    @Option(name: .long, help: "Comma-separated app IDs the user can see when --no-all-apps-visible.")
    var visibleApps: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveUsersAPI(logger: logger)

        let rolesList = roles?.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let visibleAppIDs = visibleApps?.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let update = UsersAPI.UserUpdate(
            roles: rolesList,
            allAppsVisible: allAppsVisible,
            provisioningAllowed: provisioningAllowed
        )
        let user = try await api.updateUser(
            id: userID, update: update, visibleAppIDs: visibleAppIDs
        )
        if json {
            try emitJSON(user)
        } else {
            logger.log("updated user \(user.id)", level: .success)
            if let rs = user.attributes?.roles {
                print("  roles now: \(rs.joined(separator: ", "))")
            }
        }
    }
}

// MARK: - delete

struct UsersDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Remove a user from the team. Irreversible."
    )

    @Argument(help: "ASC user id to remove.")
    var userID: String

    @Flag(name: [.short, .long], help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let logger = Logger()
        if !yes {
            print("About to remove user \(userID) from the team. Continue? [y/N] ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                logger.log("aborted", level: .info)
                return
            }
        }
        let api = try resolveUsersAPI(logger: logger)
        try await api.deleteUser(id: userID)
        logger.log("deleted user \(userID)", level: .success)
    }
}

// MARK: - invite

struct UsersInviteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invite",
        abstract: "Send a team invitation to a new email address.",
        discussion: """
            Creates a pending invitation. Apple emails the invitee a link to \
            accept. Pass --roles as a comma-separated list. Use --visible-apps \
            with --no-all-apps-visible to scope the invitee's view of apps.
            """
    )

    @Option(name: .long, help: "Invitee email address.")
    var email: String

    @Option(name: .long, help: "Invitee first name.")
    var firstName: String

    @Option(name: .long, help: "Invitee last name.")
    var lastName: String

    @Option(name: .long, help: "Comma-separated role list (e.g. \"DEVELOPER\").")
    var roles: String

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Whether the invitee can see every app on the team. Default true."
    )
    var allAppsVisible: Bool = true

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Whether the invitee can manage provisioning profiles and certificates. Default false."
    )
    var provisioningAllowed: Bool = false

    @Option(name: .long, help: "Comma-separated app IDs to share with the invitee when --no-all-apps-visible.")
    var visibleApps: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveUsersAPI(logger: logger)

        let rolesList = roles.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !rolesList.isEmpty else {
            logger.log("--roles must contain at least one role", level: .error)
            throw ExitCode(1)
        }
        let visibleAppIDs = visibleApps?.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        let inv = try await api.createInvitation(
            email: email,
            firstName: firstName,
            lastName: lastName,
            roles: rolesList,
            allAppsVisible: allAppsVisible,
            provisioningAllowed: provisioningAllowed,
            visibleAppIDs: visibleAppIDs
        )
        if json {
            try emitJSON(inv)
        } else {
            logger.log("invitation sent to \(email)", level: .success)
            print("  invitation id: \(inv.id)")
            if let exp = inv.attributes?.expirationDate {
                print("  expires:       \(exp)")
            }
        }
    }
}

// MARK: - invitations list

struct UsersInvitationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invitations",
        abstract: "List pending team invitations."
    )

    @Option(name: .long, help: "Filter to a single invitee email.")
    var email: String?

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveUsersAPI(logger: logger)
        let result = try await api.listInvitations(
            limit: limit, cursor: cursor, filterEmail: email
        )
        if json {
            struct Out: Encodable {
                let invitations: [UsersAPI.UserInvitation]
                let nextCursor: String?
            }
            try emitJSON(Out(invitations: result.invitations, nextCursor: result.nextCursor))
            return
        }
        logger.header("Pending invitations (\(result.invitations.count))")
        if result.invitations.isEmpty {
            print("  (none)")
            return
        }
        for i in result.invitations {
            let name = [i.attributes?.firstName, i.attributes?.lastName]
                .compactMap { $0 }.joined(separator: " ")
            print("  \(i.attributes?.email ?? "(no email)")  \(name)")
            print("    id:    \(i.id)")
            print("    roles: \(i.attributes?.roles?.joined(separator: ", ") ?? "(none)")")
            if let exp = i.attributes?.expirationDate {
                print("    exp:   \(exp)")
            }
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}

// MARK: - invitations cancel

struct UsersInvitationsCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel-invitation",
        abstract: "Cancel a pending team invitation before it's accepted."
    )

    @Argument(help: "Pending invitation id.")
    var invitationID: String

    func run() async throws {
        let logger = Logger()
        let api = try resolveUsersAPI(logger: logger)
        try await api.cancelInvitation(id: invitationID)
        logger.log("canceled invitation \(invitationID)", level: .success)
    }
}

// MARK: - visible apps

struct UsersVisibleAppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "visible-apps",
        abstract: "List app IDs visible to a team user."
    )

    @Argument(help: "ASC user id.")
    var userID: String

    @Option(name: .long, help: "Page size (1..200).")
    var limit: Int = 200

    @Option(name: .long, help: "Cursor from a previous list call.")
    var cursor: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try resolveUsersAPI(logger: logger)
        let result = try await api.listVisibleApps(
            userID: userID, limit: limit, cursor: cursor
        )
        if json {
            struct Out: Encodable {
                let appIDs: [String]
                let nextCursor: String?
            }
            try emitJSON(Out(appIDs: result.appIDs, nextCursor: result.nextCursor))
            return
        }
        logger.header("Visible apps for \(userID) (\(result.appIDs.count))")
        if result.appIDs.isEmpty {
            print("  (none)")
            return
        }
        for id in result.appIDs {
            print("  \(id)")
        }
        if let next = result.nextCursor {
            print("")
            print("  more pages available, pass --cursor \(next)")
        }
    }
}
