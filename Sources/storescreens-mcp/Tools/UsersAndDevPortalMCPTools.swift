import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for App Store Connect Users + Roles and the
/// Developer Portal (certificates, profiles, devices, bundle IDs, and
/// per-bundleId capabilities). Mirrors the methods on `UsersAPI` and
/// `DevPortalAPI` so an AI agent can manage the team and the
/// code-signing surface without crafting raw ASC HTTP requests.
///
/// All tools resolve credentials through `ASCCredentialResolver.resolve()`
/// (env vars first, then `~/.storescreens/asc-credentials.yml`). Tools
/// return pretty-printed JSON in a single `.text` content block, with
/// `isError: true` set on failures.
///
/// Note: This file is loaded into the same MCP target as `Main.swift`.
/// `Main.swift` owns the actual server bootstrap and tool registration;
/// per the task constraints we do not edit `Main.swift` here, so the
/// dispatch glue lives ready for a separate wiring step that will plug
/// `UsersAndDevPortalMCPTools.tools` into the server's tool list and
/// `UsersAndDevPortalMCPTools.handle(_:)` into the dispatch switch.
package enum UsersAndDevPortalMCPTools {

    // MARK: - Tool catalog

    /// Every users + dev-portal tool exposed by this namespace. Names use
    /// snake_case prefixed with `users_` or `devportal_` so they sort
    /// together when listed alongside the existing capture/render tools.
    package static let tools: [Tool] = [

        // MARK: Users

        Tool(
            name: "users_list",
            description: """
            List App Store Connect team users. Paginated; the response \
            includes a `cursor` you can hand back via the `cursor` argument \
            to fetch the next page. Optionally filter by username (email).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "username_filter": .object([
                        "type": .string("string"),
                        "description": .string("Filter to a single username (email address)."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor from a previous users_list call to fetch the next page."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "users_get",
            description: """
            Fetch one team user by their ASC user id. Returns the user's \
            attributes plus their `roles` list and provisioning rights flag. \
            Useful as a precursor to users_update_role.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "user_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC user id (from users_list)."),
                    ]),
                ]),
                "required": .array([.string("user_id")]),
            ])
        ),
        Tool(
            name: "users_update_role",
            description: """
            PATCH a user's roles, all-apps-visible flag, or provisioning \
            rights. Nil fields stay untouched. The `roles` argument replaces \
            the user's full role list (Apple does not support delta edits). \
            Pass `visible_app_ids` together with `all_apps_visible: false` to \
            restrict the user to a subset of apps.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "user_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC user id."),
                    ]),
                    "roles": .object([
                        "type": .string("array"),
                        "description": .string("New roles (e.g. [\"DEVELOPER\", \"APP_MANAGER\"]). Replaces the existing list."),
                    ]),
                    "all_apps_visible": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether the user can see every app on the team. False scopes them to visible_app_ids."),
                    ]),
                    "provisioning_allowed": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether the user can create/edit provisioning profiles + certificates."),
                    ]),
                    "visible_app_ids": .object([
                        "type": .string("array"),
                        "description": .string("App IDs the user can see when all_apps_visible is false."),
                    ]),
                ]),
                "required": .array([.string("user_id")]),
            ])
        ),
        Tool(
            name: "users_delete",
            description: """
            Remove a user from the App Store Connect team. Irreversible. \
            Apple revokes any sessions and Xcode signing capabilities tied to \
            the user; their provisioning profiles stay valid until expiry.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "user_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC user id to remove."),
                    ]),
                ]),
                "required": .array([.string("user_id")]),
            ])
        ),
        Tool(
            name: "users_invitations_list",
            description: """
            List pending team invitations. Paginated; pass `cursor` to fetch \
            subsequent pages. Optionally filter by recipient email.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "email_filter": .object([
                        "type": .string("string"),
                        "description": .string("Filter to a single invitee email."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor from a previous users_invitations_list call."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "users_invitations_get",
            description: "Fetch one pending team invitation by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "invitation_id": .object([
                        "type": .string("string"),
                        "description": .string("Pending invitation id (from users_invitations_list)."),
                    ]),
                ]),
                "required": .array([.string("invitation_id")]),
            ])
        ),
        Tool(
            name: "users_invitations_create",
            description: """
            Invite a new teammate to the App Store Connect team. Apple emails \
            the user a link to accept. `roles` is required and replaces the \
            invitation's role list. When `all_apps_visible` is false, pass \
            `visible_app_ids` to scope the invitee's access.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "email": .object([
                        "type": .string("string"),
                        "description": .string("Recipient email address."),
                    ]),
                    "first_name": .object([
                        "type": .string("string"),
                        "description": .string("Recipient's first name."),
                    ]),
                    "last_name": .object([
                        "type": .string("string"),
                        "description": .string("Recipient's last name."),
                    ]),
                    "roles": .object([
                        "type": .string("array"),
                        "description": .string("Roles to assign (e.g. [\"DEVELOPER\"])."),
                    ]),
                    "all_apps_visible": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether the user can see every app on the team. Default true."),
                    ]),
                    "provisioning_allowed": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether the user can manage provisioning profiles and certificates. Default false."),
                    ]),
                    "visible_app_ids": .object([
                        "type": .string("array"),
                        "description": .string("App IDs the invitee can see when all_apps_visible is false."),
                    ]),
                ]),
                "required": .array([.string("email"), .string("first_name"), .string("last_name"), .string("roles")]),
            ])
        ),
        Tool(
            name: "users_invitations_cancel",
            description: """
            Cancel a pending team invitation before the recipient accepts it. \
            Once accepted, you must use users_delete instead.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "invitation_id": .object([
                        "type": .string("string"),
                        "description": .string("Pending invitation id."),
                    ]),
                ]),
                "required": .array([.string("invitation_id")]),
            ])
        ),
        Tool(
            name: "users_visible_apps_list",
            description: """
            List the app IDs visible to a team user. Apple still returns the \
            list when `all_apps_visible` is true on the user record, but it's \
            informational in that case; what actually controls visibility is \
            the `all_apps_visible` flag.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "user_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC user id."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor from a previous users_visible_apps_list call."),
                    ]),
                ]),
                "required": .array([.string("user_id")]),
            ])
        ),

        // MARK: DevPortal: Certificates

        Tool(
            name: "devportal_certificates_list",
            description: """
            List signing certificates registered on the team. Filter by \
            certificateType (e.g. IOS_DEVELOPMENT, IOS_DISTRIBUTION, \
            MAC_APP_DISTRIBUTION). Paginated.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "certificate_type": .object([
                        "type": .string("string"),
                        "description": .string("e.g. IOS_DEVELOPMENT, IOS_DISTRIBUTION, MAC_APP_DISTRIBUTION, MAC_INSTALLER_DISTRIBUTION, DEVELOPER_ID_APPLICATION."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "devportal_certificates_get",
            description: "Fetch one signing certificate by id, including the base64-encoded `certificateContent`.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "certificate_id": .object([
                        "type": .string("string"),
                        "description": .string("Certificate id (from devportal_certificates_list)."),
                    ]),
                ]),
                "required": .array([.string("certificate_id")]),
            ])
        ),
        Tool(
            name: "devportal_certificates_create",
            description: """
            Submit a Certificate Signing Request (CSR) and receive a signed \
            certificate from Apple. The CSR must be PEM, base64-encoded. \
            Save the returned `certificateContent` as a .cer file to import \
            into Keychain Access on macOS.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "csr_content": .object([
                        "type": .string("string"),
                        "description": .string("Base64-encoded PEM CSR contents (the result of `openssl req -new ...` then base64)."),
                    ]),
                    "certificate_type": .object([
                        "type": .string("string"),
                        "description": .string("e.g. IOS_DEVELOPMENT, IOS_DISTRIBUTION, MAC_APP_DISTRIBUTION, MAC_INSTALLER_DISTRIBUTION."),
                    ]),
                ]),
                "required": .array([.string("csr_content"), .string("certificate_type")]),
            ])
        ),
        Tool(
            name: "devportal_certificates_delete",
            description: """
            Revoke (delete) a certificate. Irreversible. Provisioning \
            profiles signed by the certificate stay valid until expiry.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "certificate_id": .object([
                        "type": .string("string"),
                        "description": .string("Certificate id to revoke."),
                    ]),
                ]),
                "required": .array([.string("certificate_id")]),
            ])
        ),

        // MARK: DevPortal: Profiles

        Tool(
            name: "devportal_profiles_list",
            description: """
            List provisioning profiles. Filter by profileType (e.g. \
            IOS_APP_STORE, IOS_APP_DEVELOPMENT) and / or bundleId. \
            Paginated.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "profile_type": .object([
                        "type": .string("string"),
                        "description": .string("e.g. IOS_APP_STORE, IOS_APP_DEVELOPMENT, IOS_APP_ADHOC, MAC_APP_STORE, MAC_APP_DEVELOPMENT."),
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Filter to one bundle id (reverse-DNS, e.g. com.example.myapp)."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "devportal_profiles_get",
            description: "Fetch one provisioning profile by id, including the base64-encoded `profileContent`.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "profile_id": .object([
                        "type": .string("string"),
                        "description": .string("Profile id (from devportal_profiles_list)."),
                    ]),
                ]),
                "required": .array([.string("profile_id")]),
            ])
        ),
        Tool(
            name: "devportal_profiles_create",
            description: """
            Create a new provisioning profile. Required: a name, a \
            profileType, a bundleId (ASC's database id from \
            devportal_bundle_ids_list, not the reverse-DNS identifier), \
            and at least one certificate id. For development / ad-hoc \
            profiles, also pass `device_ids`. App Store and In-House \
            profiles ignore the device list.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Profile display name."),
                    ]),
                    "profile_type": .object([
                        "type": .string("string"),
                        "description": .string("e.g. IOS_APP_STORE, IOS_APP_DEVELOPMENT, IOS_APP_ADHOC."),
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id of the bundle (id from devportal_bundle_ids_list, not the reverse-DNS identifier)."),
                    ]),
                    "certificate_ids": .object([
                        "type": .string("array"),
                        "description": .string("IDs of certificates the profile signs against."),
                    ]),
                    "device_ids": .object([
                        "type": .string("array"),
                        "description": .string("IDs of devices the profile permits (required for development / ad-hoc, optional otherwise)."),
                    ]),
                ]),
                "required": .array([.string("name"), .string("profile_type"), .string("bundle_id"), .string("certificate_ids")]),
            ])
        ),
        Tool(
            name: "devportal_profiles_delete",
            description: """
            Delete (invalidate) a provisioning profile. Builds signed with \
            it lose install rights on new devices, but installed copies keep \
            running until the binary signature expires.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "profile_id": .object([
                        "type": .string("string"),
                        "description": .string("Profile id to delete."),
                    ]),
                ]),
                "required": .array([.string("profile_id")]),
            ])
        ),

        // MARK: DevPortal: Devices

        Tool(
            name: "devportal_devices_list",
            description: """
            List registered test devices on the team. Filter by platform \
            (IOS, MAC_OS) and/or status (ENABLED, DISABLED). Paginated.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "platform": .object([
                        "type": .string("string"),
                        "description": .string("IOS or MAC_OS."),
                    ]),
                    "status": .object([
                        "type": .string("string"),
                        "description": .string("ENABLED or DISABLED."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "devportal_devices_get",
            description: "Fetch one registered device by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "device_id": .object([
                        "type": .string("string"),
                        "description": .string("Device id (from devportal_devices_list)."),
                    ]),
                ]),
                "required": .array([.string("device_id")]),
            ])
        ),
        Tool(
            name: "devportal_devices_create",
            description: """
            Register a new test device on the team by name + UDID + platform. \
            Apple's per-team quota is 100 devices per platform per membership \
            year (year resets when you renew the developer-program enrollment).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Display name for the device (e.g. \"Cisco's iPhone 15 Pro\")."),
                    ]),
                    "udid": .object([
                        "type": .string("string"),
                        "description": .string("Device UDID (40-char legacy or 25-char modern)."),
                    ]),
                    "platform": .object([
                        "type": .string("string"),
                        "description": .string("IOS or MAC_OS. Default IOS."),
                    ]),
                ]),
                "required": .array([.string("name"), .string("udid")]),
            ])
        ),
        Tool(
            name: "devportal_devices_modify",
            description: """
            Rename a device or toggle it between ENABLED and DISABLED. \
            Apple does not allow deleting devices outright; disabling frees \
            up a slot in the per-platform quota.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "device_id": .object([
                        "type": .string("string"),
                        "description": .string("Device id."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("New display name. Omit to keep current."),
                    ]),
                    "status": .object([
                        "type": .string("string"),
                        "description": .string("ENABLED or DISABLED. Omit to keep current."),
                    ]),
                ]),
                "required": .array([.string("device_id")]),
            ])
        ),

        // MARK: DevPortal: Bundle IDs

        Tool(
            name: "devportal_bundle_ids_list",
            description: """
            List registered app identifiers. Filter by reverse-DNS identifier \
            substring (Apple's filter is exact-match, not substring; pass the \
            full identifier) and / or platform (IOS, MAC_OS, UNIVERSAL). \
            Paginated.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "identifier": .object([
                        "type": .string("string"),
                        "description": .string("Filter to one reverse-DNS identifier (e.g. com.example.myapp)."),
                    ]),
                    "platform": .object([
                        "type": .string("string"),
                        "description": .string("IOS, MAC_OS, or UNIVERSAL."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "devportal_bundle_ids_get",
            description: "Fetch one app identifier by its ASC database id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id (from devportal_bundle_ids_list, not the reverse-DNS identifier)."),
                    ]),
                ]),
                "required": .array([.string("bundle_id")]),
            ])
        ),
        Tool(
            name: "devportal_bundle_ids_create",
            description: """
            Register a new app identifier. `identifier` is the reverse-DNS \
            string (e.g. com.example.myapp); `name` is the human-readable \
            label shown in the developer portal.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "identifier": .object([
                        "type": .string("string"),
                        "description": .string("Reverse-DNS app identifier (e.g. com.example.myapp)."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Display name shown in the developer portal."),
                    ]),
                    "platform": .object([
                        "type": .string("string"),
                        "description": .string("IOS, MAC_OS, or UNIVERSAL. Default IOS."),
                    ]),
                ]),
                "required": .array([.string("identifier"), .string("name")]),
            ])
        ),
        Tool(
            name: "devportal_bundle_ids_update",
            description: """
            Rename a bundle identifier's display name. The reverse-DNS \
            identifier itself is immutable; only the human-readable label \
            can change.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("New display name."),
                    ]),
                ]),
                "required": .array([.string("bundle_id"), .string("name")]),
            ])
        ),
        Tool(
            name: "devportal_bundle_ids_delete",
            description: """
            Permanently delete an app identifier. Apple blocks this when any \
            active provisioning profile or App Store Connect app references \
            the identifier; delete those first.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id to delete."),
                    ]),
                ]),
                "required": .array([.string("bundle_id")]),
            ])
        ),

        // MARK: DevPortal: Bundle ID Capabilities

        Tool(
            name: "devportal_capabilities_list",
            description: """
            List the capabilities currently enabled on a bundle identifier \
            (e.g. PUSH_NOTIFICATIONS, ICLOUD, APP_GROUPS, HEALTHKIT). \
            Paginated.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id of the bundle (from devportal_bundle_ids_list)."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Page size, 1 to 200. Default 200."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Cursor for pagination."),
                    ]),
                ]),
                "required": .array([.string("bundle_id")]),
            ])
        ),
        Tool(
            name: "devportal_capabilities_enable",
            description: """
            Enable a capability on a bundle identifier. For capabilities \
            that take no configuration (e.g. PUSH_NOTIFICATIONS), omit \
            `settings`. For capabilities like APP_GROUPS or ICLOUD that \
            carry configuration, pass `settings` as an array of objects of \
            the form { key: \"CAPABILITY_SETTING_KEY\", options: [...] }.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("ASC database id of the bundle."),
                    ]),
                    "capability_type": .object([
                        "type": .string("string"),
                        "description": .string("e.g. PUSH_NOTIFICATIONS, ICLOUD, APP_GROUPS, HEALTHKIT, GAME_CENTER."),
                    ]),
                    "settings_json": .object([
                        "type": .string("string"),
                        "description": .string("Optional JSON-encoded array of capability settings. Omit for capabilities without configuration."),
                    ]),
                ]),
                "required": .array([.string("bundle_id"), .string("capability_type")]),
            ])
        ),
        Tool(
            name: "devportal_capabilities_update",
            description: """
            Change a capability's settings array without disabling and \
            re-enabling it. Pass `settings_json` as a JSON-encoded array \
            (same shape as devportal_capabilities_enable).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "capability_id": .object([
                        "type": .string("string"),
                        "description": .string("Capability id (from devportal_capabilities_list)."),
                    ]),
                    "capability_type": .object([
                        "type": .string("string"),
                        "description": .string("Capability type. Apple requires this on PATCH even when only settings change."),
                    ]),
                    "settings_json": .object([
                        "type": .string("string"),
                        "description": .string("Optional JSON-encoded array of capability settings. Omit to clear the settings."),
                    ]),
                ]),
                "required": .array([.string("capability_id"), .string("capability_type")]),
            ])
        ),
        Tool(
            name: "devportal_capabilities_disable",
            description: """
            Disable a capability on a bundle identifier. Existing builds \
            keep the capability until they're replaced; new builds without \
            it can fail entitlement checks at install time.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "capability_id": .object([
                        "type": .string("string"),
                        "description": .string("Capability id."),
                    ]),
                ]),
                "required": .array([.string("capability_id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Routes a `CallTool.Parameters` whose name starts with `users_` or
    /// `devportal_` to the right handler. Returns `nil` when the tool name
    /// does not belong to this namespace, so `Main.swift` can fall through
    /// to its own dispatch table.
    package static func handle(
        _ params: CallTool.Parameters
    ) async throws -> CallTool.Result? {
        switch params.name {
        // Users
        case "users_list":                  return try await handleUsersList(params)
        case "users_get":                   return try await handleUsersGet(params)
        case "users_update_role":           return try await handleUsersUpdateRole(params)
        case "users_delete":                return try await handleUsersDelete(params)
        case "users_invitations_list":      return try await handleInvitationsList(params)
        case "users_invitations_get":       return try await handleInvitationsGet(params)
        case "users_invitations_create":    return try await handleInvitationsCreate(params)
        case "users_invitations_cancel":    return try await handleInvitationsCancel(params)
        case "users_visible_apps_list":     return try await handleVisibleAppsList(params)
        // DevPortal: Certificates
        case "devportal_certificates_list":   return try await handleCertificatesList(params)
        case "devportal_certificates_get":    return try await handleCertificatesGet(params)
        case "devportal_certificates_create": return try await handleCertificatesCreate(params)
        case "devportal_certificates_delete": return try await handleCertificatesDelete(params)
        // DevPortal: Profiles
        case "devportal_profiles_list":     return try await handleProfilesList(params)
        case "devportal_profiles_get":      return try await handleProfilesGet(params)
        case "devportal_profiles_create":   return try await handleProfilesCreate(params)
        case "devportal_profiles_delete":   return try await handleProfilesDelete(params)
        // DevPortal: Devices
        case "devportal_devices_list":      return try await handleDevicesList(params)
        case "devportal_devices_get":       return try await handleDevicesGet(params)
        case "devportal_devices_create":    return try await handleDevicesCreate(params)
        case "devportal_devices_modify":    return try await handleDevicesModify(params)
        // DevPortal: Bundle IDs
        case "devportal_bundle_ids_list":   return try await handleBundleIDsList(params)
        case "devportal_bundle_ids_get":    return try await handleBundleIDsGet(params)
        case "devportal_bundle_ids_create": return try await handleBundleIDsCreate(params)
        case "devportal_bundle_ids_update": return try await handleBundleIDsUpdate(params)
        case "devportal_bundle_ids_delete": return try await handleBundleIDsDelete(params)
        // DevPortal: Capabilities
        case "devportal_capabilities_list":    return try await handleCapabilitiesList(params)
        case "devportal_capabilities_enable":  return try await handleCapabilitiesEnable(params)
        case "devportal_capabilities_update":  return try await handleCapabilitiesUpdate(params)
        case "devportal_capabilities_disable": return try await handleCapabilitiesDisable(params)
        default:
            return nil
        }
    }

    // MARK: - Users handlers

    static func handleUsersList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeUsersAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let usernameFilter = params.arguments?["username_filter"]?.stringValue
            let result = try await api.listUsers(
                limit: limit,
                cursor: cursor,
                filterUsername: usernameFilter
            )
            let payload = UsersListPayload(
                users: result.users.map(UserJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("users_list failed: \(error)")
        }
    }

    static func handleUsersGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["user_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: user_id")
        }
        do {
            let api = try makeUsersAPI()
            guard let user = try await api.getUser(id: id) else {
                return errorResult("No user with id \(id)")
            }
            return jsonResult(UserJSON(user))
        } catch {
            return errorResult("users_get failed: \(error)")
        }
    }

    static func handleUsersUpdateRole(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["user_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: user_id")
        }
        let roles = params.arguments?["roles"]?.arrayValue?.compactMap { $0.stringValue }
        let allAppsVisible = params.arguments?["all_apps_visible"]?.boolValue
        let provisioningAllowed = params.arguments?["provisioning_allowed"]?.boolValue
        let visibleAppIDs = params.arguments?["visible_app_ids"]?.arrayValue?
            .compactMap { $0.stringValue }
        do {
            let api = try makeUsersAPI()
            let update = UsersAPI.UserUpdate(
                roles: roles,
                allAppsVisible: allAppsVisible,
                provisioningAllowed: provisioningAllowed
            )
            let user = try await api.updateUser(
                id: id, update: update, visibleAppIDs: visibleAppIDs
            )
            return jsonResult(UserJSON(user))
        } catch {
            return errorResult("users_update_role failed: \(error)")
        }
    }

    static func handleUsersDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["user_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: user_id")
        }
        do {
            let api = try makeUsersAPI()
            try await api.deleteUser(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "user"))
        } catch {
            return errorResult("users_delete failed: \(error)")
        }
    }

    static func handleInvitationsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeUsersAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let emailFilter = params.arguments?["email_filter"]?.stringValue
            let result = try await api.listInvitations(
                limit: limit,
                cursor: cursor,
                filterEmail: emailFilter
            )
            let payload = InvitationsListPayload(
                invitations: result.invitations.map(InvitationJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("users_invitations_list failed: \(error)")
        }
    }

    static func handleInvitationsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["invitation_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: invitation_id")
        }
        do {
            let api = try makeUsersAPI()
            guard let inv = try await api.getInvitation(id: id) else {
                return errorResult("No pending invitation with id \(id)")
            }
            return jsonResult(InvitationJSON(inv))
        } catch {
            return errorResult("users_invitations_get failed: \(error)")
        }
    }

    static func handleInvitationsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let email = params.arguments?["email"]?.stringValue, !email.isEmpty else {
            return errorResult("Missing required parameter: email")
        }
        guard let firstName = params.arguments?["first_name"]?.stringValue, !firstName.isEmpty else {
            return errorResult("Missing required parameter: first_name")
        }
        guard let lastName = params.arguments?["last_name"]?.stringValue, !lastName.isEmpty else {
            return errorResult("Missing required parameter: last_name")
        }
        guard let rolesAny = params.arguments?["roles"]?.arrayValue,
              !rolesAny.isEmpty else {
            return errorResult("Missing required parameter: roles (non-empty array)")
        }
        let roles = rolesAny.compactMap { $0.stringValue }
        let allAppsVisible = params.arguments?["all_apps_visible"]?.boolValue ?? true
        let provisioningAllowed = params.arguments?["provisioning_allowed"]?.boolValue ?? false
        let visibleAppIDs = params.arguments?["visible_app_ids"]?.arrayValue?
            .compactMap { $0.stringValue } ?? []
        do {
            let api = try makeUsersAPI()
            let inv = try await api.createInvitation(
                email: email,
                firstName: firstName,
                lastName: lastName,
                roles: roles,
                allAppsVisible: allAppsVisible,
                provisioningAllowed: provisioningAllowed,
                visibleAppIDs: visibleAppIDs
            )
            return jsonResult(InvitationJSON(inv))
        } catch {
            return errorResult("users_invitations_create failed: \(error)")
        }
    }

    static func handleInvitationsCancel(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["invitation_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: invitation_id")
        }
        do {
            let api = try makeUsersAPI()
            try await api.cancelInvitation(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "userInvitation"))
        } catch {
            return errorResult("users_invitations_cancel failed: \(error)")
        }
    }

    static func handleVisibleAppsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["user_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: user_id")
        }
        do {
            let api = try makeUsersAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let result = try await api.listVisibleApps(
                userID: id, limit: limit, cursor: cursor
            )
            let payload = VisibleAppsPayload(
                appIDs: result.appIDs, cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("users_visible_apps_list failed: \(error)")
        }
    }

    // MARK: - Certificates handlers

    static func handleCertificatesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeDevPortalAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let type = params.arguments?["certificate_type"]?.stringValue
            let result = try await api.listCertificates(
                type: type, limit: limit, cursor: cursor
            )
            let payload = CertificatesListPayload(
                certificates: result.certificates.map(CertificateJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("devportal_certificates_list failed: \(error)")
        }
    }

    static func handleCertificatesGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["certificate_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: certificate_id")
        }
        do {
            let api = try makeDevPortalAPI()
            guard let cert = try await api.getCertificate(id: id) else {
                return errorResult("No certificate with id \(id)")
            }
            return jsonResult(CertificateJSON(cert))
        } catch {
            return errorResult("devportal_certificates_get failed: \(error)")
        }
    }

    static func handleCertificatesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let csr = params.arguments?["csr_content"]?.stringValue, !csr.isEmpty else {
            return errorResult("Missing required parameter: csr_content")
        }
        guard let type = params.arguments?["certificate_type"]?.stringValue, !type.isEmpty else {
            return errorResult("Missing required parameter: certificate_type")
        }
        do {
            let api = try makeDevPortalAPI()
            let cert = try await api.createCertificate(
                csrContent: csr, certificateType: type
            )
            return jsonResult(CertificateJSON(cert))
        } catch {
            return errorResult("devportal_certificates_create failed: \(error)")
        }
    }

    static func handleCertificatesDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["certificate_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: certificate_id")
        }
        do {
            let api = try makeDevPortalAPI()
            try await api.revokeCertificate(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "certificate"))
        } catch {
            return errorResult("devportal_certificates_delete failed: \(error)")
        }
    }

    // MARK: - Profiles handlers

    static func handleProfilesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeDevPortalAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let type = params.arguments?["profile_type"]?.stringValue
            let bundleIDFilter = params.arguments?["bundle_id"]?.stringValue
            let result = try await api.listProfiles(
                type: type,
                bundleIDFilter: bundleIDFilter,
                limit: limit,
                cursor: cursor
            )
            let payload = ProfilesListPayload(
                profiles: result.profiles.map(ProfileJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("devportal_profiles_list failed: \(error)")
        }
    }

    static func handleProfilesGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["profile_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: profile_id")
        }
        do {
            let api = try makeDevPortalAPI()
            guard let profile = try await api.getProfile(id: id) else {
                return errorResult("No profile with id \(id)")
            }
            return jsonResult(ProfileJSON(profile))
        } catch {
            return errorResult("devportal_profiles_get failed: \(error)")
        }
    }

    static func handleProfilesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("Missing required parameter: name")
        }
        guard let profileType = params.arguments?["profile_type"]?.stringValue, !profileType.isEmpty else {
            return errorResult("Missing required parameter: profile_type")
        }
        guard let bundleID = params.arguments?["bundle_id"]?.stringValue, !bundleID.isEmpty else {
            return errorResult("Missing required parameter: bundle_id")
        }
        guard let certs = params.arguments?["certificate_ids"]?.arrayValue?
                .compactMap({ $0.stringValue }), !certs.isEmpty else {
            return errorResult("Missing required parameter: certificate_ids (non-empty array)")
        }
        let devices = params.arguments?["device_ids"]?.arrayValue?
            .compactMap { $0.stringValue } ?? []
        do {
            let api = try makeDevPortalAPI()
            let profile = try await api.createProfile(
                name: name,
                profileType: profileType,
                bundleIDIdentifier: bundleID,
                certificateIDs: certs,
                deviceIDs: devices
            )
            return jsonResult(ProfileJSON(profile))
        } catch {
            return errorResult("devportal_profiles_create failed: \(error)")
        }
    }

    static func handleProfilesDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["profile_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: profile_id")
        }
        do {
            let api = try makeDevPortalAPI()
            try await api.deleteProfile(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "profile"))
        } catch {
            return errorResult("devportal_profiles_delete failed: \(error)")
        }
    }

    // MARK: - Devices handlers

    static func handleDevicesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeDevPortalAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let platform = params.arguments?["platform"]?.stringValue
            let status = params.arguments?["status"]?.stringValue
            let result = try await api.listDevices(
                platform: platform,
                status: status,
                limit: limit,
                cursor: cursor
            )
            let payload = DevicesListPayload(
                devices: result.devices.map(DeviceJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("devportal_devices_list failed: \(error)")
        }
    }

    static func handleDevicesGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["device_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: device_id")
        }
        do {
            let api = try makeDevPortalAPI()
            guard let device = try await api.getDevice(id: id) else {
                return errorResult("No device with id \(id)")
            }
            return jsonResult(DeviceJSON(device))
        } catch {
            return errorResult("devportal_devices_get failed: \(error)")
        }
    }

    static func handleDevicesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("Missing required parameter: name")
        }
        guard let udid = params.arguments?["udid"]?.stringValue, !udid.isEmpty else {
            return errorResult("Missing required parameter: udid")
        }
        let platform = params.arguments?["platform"]?.stringValue ?? "IOS"
        do {
            let api = try makeDevPortalAPI()
            let device = try await api.registerDevice(
                name: name, udid: udid, platform: platform
            )
            return jsonResult(DeviceJSON(device))
        } catch {
            return errorResult("devportal_devices_create failed: \(error)")
        }
    }

    static func handleDevicesModify(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["device_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: device_id")
        }
        let name = params.arguments?["name"]?.stringValue
        let status = params.arguments?["status"]?.stringValue
        do {
            let api = try makeDevPortalAPI()
            let device = try await api.modifyDevice(
                id: id, name: name, status: status
            )
            return jsonResult(DeviceJSON(device))
        } catch {
            return errorResult("devportal_devices_modify failed: \(error)")
        }
    }

    // MARK: - Bundle IDs handlers

    static func handleBundleIDsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeDevPortalAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let identifier = params.arguments?["identifier"]?.stringValue
            let platform = params.arguments?["platform"]?.stringValue
            let result = try await api.listBundleIDs(
                identifierFilter: identifier,
                platform: platform,
                limit: limit,
                cursor: cursor
            )
            let payload = BundleIDsListPayload(
                bundleIDs: result.bundleIDs.map(BundleIDJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("devportal_bundle_ids_list failed: \(error)")
        }
    }

    static func handleBundleIDsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["bundle_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: bundle_id")
        }
        do {
            let api = try makeDevPortalAPI()
            guard let bundle = try await api.getBundleID(id: id) else {
                return errorResult("No bundle id with id \(id)")
            }
            return jsonResult(BundleIDJSON(bundle))
        } catch {
            return errorResult("devportal_bundle_ids_get failed: \(error)")
        }
    }

    static func handleBundleIDsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let identifier = params.arguments?["identifier"]?.stringValue, !identifier.isEmpty else {
            return errorResult("Missing required parameter: identifier")
        }
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("Missing required parameter: name")
        }
        let platform = params.arguments?["platform"]?.stringValue ?? "IOS"
        do {
            let api = try makeDevPortalAPI()
            let bundle = try await api.createBundleID(
                identifier: identifier, name: name, platform: platform
            )
            return jsonResult(BundleIDJSON(bundle))
        } catch {
            return errorResult("devportal_bundle_ids_create failed: \(error)")
        }
    }

    static func handleBundleIDsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["bundle_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: bundle_id")
        }
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("Missing required parameter: name")
        }
        do {
            let api = try makeDevPortalAPI()
            let bundle = try await api.updateBundleID(id: id, name: name)
            return jsonResult(BundleIDJSON(bundle))
        } catch {
            return errorResult("devportal_bundle_ids_update failed: \(error)")
        }
    }

    static func handleBundleIDsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["bundle_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: bundle_id")
        }
        do {
            let api = try makeDevPortalAPI()
            try await api.deleteBundleID(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "bundleId"))
        } catch {
            return errorResult("devportal_bundle_ids_delete failed: \(error)")
        }
    }

    // MARK: - Capabilities handlers

    static func handleCapabilitiesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["bundle_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: bundle_id")
        }
        do {
            let api = try makeDevPortalAPI()
            let limit = params.arguments?["limit"]?.intValue ?? 200
            let cursor = params.arguments?["cursor"]?.stringValue
            let result = try await api.listCapabilities(
                bundleIDDatabaseID: id, limit: limit, cursor: cursor
            )
            let payload = CapabilitiesListPayload(
                capabilities: result.capabilities.map(CapabilityJSON.init),
                cursor: result.nextCursor
            )
            return jsonResult(payload)
        } catch {
            return errorResult("devportal_capabilities_list failed: \(error)")
        }
    }

    static func handleCapabilitiesEnable(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["bundle_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: bundle_id")
        }
        guard let type = params.arguments?["capability_type"]?.stringValue, !type.isEmpty else {
            return errorResult("Missing required parameter: capability_type")
        }
        let settings = parseSettingsJSON(params.arguments?["settings_json"]?.stringValue)
        do {
            let api = try makeDevPortalAPI()
            let cap = try await api.enableCapability(
                bundleIDDatabaseID: id,
                capabilityType: type,
                settings: settings
            )
            return jsonResult(CapabilityJSON(cap))
        } catch {
            return errorResult("devportal_capabilities_enable failed: \(error)")
        }
    }

    static func handleCapabilitiesUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["capability_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: capability_id")
        }
        guard let type = params.arguments?["capability_type"]?.stringValue, !type.isEmpty else {
            return errorResult("Missing required parameter: capability_type")
        }
        let settings = parseSettingsJSON(params.arguments?["settings_json"]?.stringValue)
        do {
            let api = try makeDevPortalAPI()
            let cap = try await api.updateCapability(
                id: id, capabilityType: type, settings: settings
            )
            return jsonResult(CapabilityJSON(cap))
        } catch {
            return errorResult("devportal_capabilities_update failed: \(error)")
        }
    }

    static func handleCapabilitiesDisable(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["capability_id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: capability_id")
        }
        do {
            let api = try makeDevPortalAPI()
            try await api.disableCapability(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "bundleIdCapability"))
        } catch {
            return errorResult("devportal_capabilities_disable failed: \(error)")
        }
    }

    // MARK: - JSON shapes (stable wire format)

    struct UsersListPayload: Encodable {
        let users: [UserJSON]
        let cursor: String?
    }

    struct InvitationsListPayload: Encodable {
        let invitations: [InvitationJSON]
        let cursor: String?
    }

    struct VisibleAppsPayload: Encodable {
        let appIDs: [String]
        let cursor: String?
    }

    struct CertificatesListPayload: Encodable {
        let certificates: [CertificateJSON]
        let cursor: String?
    }

    struct ProfilesListPayload: Encodable {
        let profiles: [ProfileJSON]
        let cursor: String?
    }

    struct DevicesListPayload: Encodable {
        let devices: [DeviceJSON]
        let cursor: String?
    }

    struct BundleIDsListPayload: Encodable {
        let bundleIDs: [BundleIDJSON]
        let cursor: String?
    }

    struct CapabilitiesListPayload: Encodable {
        let capabilities: [CapabilityJSON]
        let cursor: String?
    }

    struct UserJSON: Encodable {
        let id: String
        let username: String?
        let firstName: String?
        let lastName: String?
        let roles: [String]?
        let allAppsVisible: Bool?
        let provisioningAllowed: Bool?

        init(_ u: UsersAPI.User) {
            self.id = u.id
            self.username = u.attributes?.username
            self.firstName = u.attributes?.firstName
            self.lastName = u.attributes?.lastName
            self.roles = u.attributes?.roles
            self.allAppsVisible = u.attributes?.allAppsVisible
            self.provisioningAllowed = u.attributes?.provisioningAllowed
        }
    }

    struct InvitationJSON: Encodable {
        let id: String
        let email: String?
        let firstName: String?
        let lastName: String?
        let roles: [String]?
        let allAppsVisible: Bool?
        let provisioningAllowed: Bool?
        let expirationDate: Date?

        init(_ i: UsersAPI.UserInvitation) {
            self.id = i.id
            self.email = i.attributes?.email
            self.firstName = i.attributes?.firstName
            self.lastName = i.attributes?.lastName
            self.roles = i.attributes?.roles
            self.allAppsVisible = i.attributes?.allAppsVisible
            self.provisioningAllowed = i.attributes?.provisioningAllowed
            self.expirationDate = i.attributes?.expirationDate
        }
    }

    struct CertificateJSON: Encodable {
        let id: String
        let displayName: String?
        let name: String?
        let serialNumber: String?
        let platform: String?
        let certificateType: String?
        let expirationDate: Date?
        let certificateContent: String?

        init(_ c: DevPortalAPI.Certificate) {
            self.id = c.id
            self.displayName = c.attributes?.displayName
            self.name = c.attributes?.name
            self.serialNumber = c.attributes?.serialNumber
            self.platform = c.attributes?.platform
            self.certificateType = c.attributes?.certificateType
            self.expirationDate = c.attributes?.expirationDate
            self.certificateContent = c.attributes?.certificateContent
        }
    }

    struct ProfileJSON: Encodable {
        let id: String
        let name: String?
        let platform: String?
        let profileType: String?
        let profileState: String?
        let uuid: String?
        let createdDate: Date?
        let expirationDate: Date?
        let profileContent: String?

        init(_ p: DevPortalAPI.Profile) {
            self.id = p.id
            self.name = p.attributes?.name
            self.platform = p.attributes?.platform
            self.profileType = p.attributes?.profileType
            self.profileState = p.attributes?.profileState
            self.uuid = p.attributes?.uuid
            self.createdDate = p.attributes?.createdDate
            self.expirationDate = p.attributes?.expirationDate
            self.profileContent = p.attributes?.profileContent
        }
    }

    struct DeviceJSON: Encodable {
        let id: String
        let name: String?
        let udid: String?
        let deviceClass: String?
        let model: String?
        let platform: String?
        let status: String?
        let addedDate: Date?

        init(_ d: DevPortalAPI.Device) {
            self.id = d.id
            self.name = d.attributes?.name
            self.udid = d.attributes?.udid
            self.deviceClass = d.attributes?.deviceClass
            self.model = d.attributes?.model
            self.platform = d.attributes?.platform
            self.status = d.attributes?.status
            self.addedDate = d.attributes?.addedDate
        }
    }

    struct BundleIDJSON: Encodable {
        let id: String
        let identifier: String?
        let name: String?
        let platform: String?
        let seedId: String?

        init(_ b: DevPortalAPI.BundleID) {
            self.id = b.id
            self.identifier = b.attributes?.identifier
            self.name = b.attributes?.name
            self.platform = b.attributes?.platform
            self.seedId = b.attributes?.seedId
        }
    }

    struct CapabilityJSON: Encodable {
        let id: String
        let capabilityType: String?
        let settings: [DevPortalAPI.CapabilitySetting]?

        init(_ c: DevPortalAPI.BundleIDCapability) {
            self.id = c.id
            self.capabilityType = c.attributes?.capabilityType
            self.settings = c.attributes?.settings
        }
    }

    struct DeleteAck: Encodable {
        let deletedID: String
        let kind: String
    }

    // MARK: - Helpers

    static func makeUsersAPI() throws -> UsersAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return UsersAPI(client: client)
    }

    static func makeDevPortalAPI() throws -> DevPortalAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return DevPortalAPI(client: client)
    }

    /// Decodes the optional `settings_json` argument into the typed
    /// `CapabilitySetting` array. Returns nil if the argument is missing
    /// or empty; throws (via JSONDecoder) if it's malformed, so the
    /// caller's `catch` surfaces a readable error.
    static func parseSettingsJSON(_ raw: String?) -> [DevPortalAPI.CapabilitySetting]? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        return try? decoder.decode([DevPortalAPI.CapabilitySetting].self, from: data)
    }

    static func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text)], isError: false)
        } catch {
            return errorResult("could not encode response JSON: \(error)")
        }
    }

    static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(message)], isError: true)
    }
}
