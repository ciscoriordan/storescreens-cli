import MCP
import Foundation
import StorescreensCore

/// MCP tool surface for App Store Connect TestFlight endpoints.
///
/// Every tool is a thin wrapper around a `TestFlightAPI` method. Inputs
/// arrive as JSON arguments, outputs are pretty-printed JSON text content
/// so AI agents get a stable, machine-readable response shape without
/// having to construct raw HTTP requests against Apple's API.
///
/// Tool naming convention: `testflight_<resource>_<op>` (snake_case).
enum TestFlightMCPTools {

    // MARK: - Tool definitions

    static let tools: [Tool] = [

        // betaGroups -----------------------------------------------------

        Tool(
            name: "testflight_beta_groups_list",
            description: """
            List TestFlight beta groups for an app. Returns each group's id, name, \
            internal/external flag, public link state, and feedback toggle. Supports \
            cursor-based pagination via the `cursor` argument.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string"), "description": .string("Numeric ASC app id")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max results per page (default 200)")]),
                    "cursor": .object(["type": .string("string"), "description": .string("Opaque pagination cursor from a prior page's nextCursor")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_groups_get",
            description: "Get a single beta group by id. Returns null if not found.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Beta group id")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_groups_create",
            description: """
            Create a new beta group on an app. Optional fields control public link \
            behavior and feedback. `name` is required.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string"), "description": .string("Numeric ASC app id")]),
                    "name": .object(["type": .string("string"), "description": .string("Group name shown in ASC and to testers")]),
                    "public_link_enabled": .object(["type": .string("boolean")]),
                    "public_link_limit": .object(["type": .string("integer")]),
                    "public_link_limit_enabled": .object(["type": .string("boolean")]),
                    "feedback_enabled": .object(["type": .string("boolean")]),
                    "has_access_to_all_builds": .object(["type": .string("boolean")]),
                    "ios_builds_available_for_apple_silicon_mac": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("app_id"), .string("name")]),
            ])
        ),

        Tool(
            name: "testflight_beta_groups_update",
            description: """
            Update a beta group's mutable attributes. Nil/omitted fields stay as is. \
            Use this to rename a group, toggle the public link, or change feedback settings.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Beta group id")]),
                    "name": .object(["type": .string("string")]),
                    "public_link_enabled": .object(["type": .string("boolean")]),
                    "public_link_limit": .object(["type": .string("integer")]),
                    "public_link_limit_enabled": .object(["type": .string("boolean")]),
                    "feedback_enabled": .object(["type": .string("boolean")]),
                    "has_access_to_all_builds": .object(["type": .string("boolean")]),
                    "ios_builds_available_for_apple_silicon_mac": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_groups_delete",
            description: "Delete a beta group. Testers stay on the app but lose access to the group's builds.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Beta group id")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_groups_add_builds",
            description: "Attach one or more builds to a beta group. Tester install fans out automatically.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_id": .object(["type": .string("string")]),
                    "build_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("List of build resource ids"),
                    ]),
                ]),
                "required": .array([.string("group_id"), .string("build_ids")]),
            ])
        ),

        Tool(
            name: "testflight_beta_groups_remove_builds",
            description: "Detach builds from a beta group. The build resources themselves are untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_id": .object(["type": .string("string")]),
                    "build_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("group_id"), .string("build_ids")]),
            ])
        ),

        Tool(
            name: "testflight_beta_groups_add_testers",
            description: "Add existing beta testers to a group. Testers receive the group's invitation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_id": .object(["type": .string("string")]),
                    "tester_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("group_id"), .string("tester_ids")]),
            ])
        ),

        Tool(
            name: "testflight_beta_groups_remove_testers",
            description: "Remove testers from a group. The testers stay attached to the app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_id": .object(["type": .string("string")]),
                    "tester_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("group_id"), .string("tester_ids")]),
            ])
        ),

        Tool(
            name: "testflight_beta_groups_create_and_invite",
            description: "Create a new beta group and add a list of existing testers to it in one call.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "tester_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "public_link_enabled": .object(["type": .string("boolean")]),
                    "feedback_enabled": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("app_id"), .string("name"), .string("tester_ids")]),
            ])
        ),

        // betaTesters ---------------------------------------------------

        Tool(
            name: "testflight_beta_testers_list",
            description: "List beta testers scoped to one app. Supports cursor pagination.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_testers_get",
            description: "Get a single beta tester by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_testers_create",
            description: """
            Create a new beta tester on an app. `email` is required; firstName/lastName \
            are optional. Pass `beta_group_ids` to attach the tester to one or more groups \
            in the same call.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "email": .object(["type": .string("string")]),
                    "first_name": .object(["type": .string("string")]),
                    "last_name": .object(["type": .string("string")]),
                    "beta_group_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("app_id"), .string("email")]),
            ])
        ),

        Tool(
            name: "testflight_beta_testers_delete",
            description: "Delete a beta tester across all apps and groups they belong to.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_testers_remove_from_app",
            description: "Remove a tester from one specific app, keeping their record on other apps.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tester_id": .object(["type": .string("string")]),
                    "app_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("tester_id"), .string("app_id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_testers_assign_to_groups",
            description: "Add an existing tester to one or more beta groups.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tester_id": .object(["type": .string("string")]),
                    "group_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("tester_id"), .string("group_ids")]),
            ])
        ),

        Tool(
            name: "testflight_beta_testers_remove_from_groups",
            description: "Remove a tester from one or more beta groups while keeping them on the app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tester_id": .object(["type": .string("string")]),
                    "group_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("tester_id"), .string("group_ids")]),
            ])
        ),

        Tool(
            name: "testflight_beta_tester_invitations_create",
            description: """
            Re-send (or send for the first time) a TestFlight invitation email to a tester. \
            Useful when a tester said they never got their invite.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tester_id": .object(["type": .string("string")]),
                    "app_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("tester_id"), .string("app_id")]),
            ])
        ),

        // prereleaseVersions --------------------------------------------

        Tool(
            name: "testflight_prerelease_versions_list",
            description: "List pre-release version trains for an app. Read-only; ASC creates these automatically.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "platform": .object(["type": .string("string"), "description": .string("IOS, MAC_OS, TV_OS, VISION_OS")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "testflight_prerelease_versions_get",
            description: "Get a single pre-release version by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // builds (TestFlight slice) -------------------------------------

        Tool(
            name: "testflight_builds_list",
            description: """
            List builds with TestFlight-relevant filters: `expired`, `processing_state` \
            (PROCESSING, FAILED, INVALID, VALID), and `prerelease_version_id`. Useful for \
            finding the right build before pushing it to a group.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "expired": .object(["type": .string("boolean")]),
                    "processing_state": .object(["type": .string("string")]),
                    "prerelease_version_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),

        Tool(
            name: "testflight_builds_get",
            description: "Get a single build by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_builds_set_expired",
            description: "Flip the `expired` flag on a build to retire it from TestFlight without deletion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "expired": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id"), .string("expired")]),
            ])
        ),

        // buildBetaDetails ----------------------------------------------

        Tool(
            name: "testflight_build_beta_detail_get",
            description: "Get the buildBetaDetail record attached to a build (internal/external testing state, auto-notify).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_id")]),
            ])
        ),

        Tool(
            name: "testflight_build_beta_detail_update",
            description: "Toggle `auto_notify_enabled` on a buildBetaDetail. Controls whether Apple emails testers automatically when this build finishes processing.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("buildBetaDetails id, NOT the build id")]),
                    "auto_notify_enabled": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id"), .string("auto_notify_enabled")]),
            ])
        ),

        // buildBetaNotifications ----------------------------------------

        Tool(
            name: "testflight_build_beta_notifications_create",
            description: """
            Send the "a new build is available to test" email to every tester in every group \
            attached to this build. One-shot: ASC has no list/get for this resource.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_id")]),
            ])
        ),

        // betaAppLocalizations -----------------------------------------

        Tool(
            name: "testflight_beta_app_localizations_list",
            description: "List per-locale TestFlight App Information records for an app (description, feedback email, marketing/privacy URLs).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_app_localizations_get",
            description: "Get a single beta app localization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_app_localizations_create",
            description: "Create a new per-locale TestFlight App Information record. `locale` is required; other fields are optional.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                    "feedback_email": .object(["type": .string("string")]),
                    "marketing_url": .object(["type": .string("string")]),
                    "privacy_policy_url": .object(["type": .string("string")]),
                    "tv_os_privacy_policy": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id"), .string("locale")]),
            ])
        ),

        Tool(
            name: "testflight_beta_app_localizations_update",
            description: "Update a per-locale TestFlight App Information record. Nil/omitted fields stay as is.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                    "feedback_email": .object(["type": .string("string")]),
                    "marketing_url": .object(["type": .string("string")]),
                    "privacy_policy_url": .object(["type": .string("string")]),
                    "tv_os_privacy_policy": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_app_localizations_delete",
            description: "Delete a per-locale TestFlight App Information record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // betaBuildLocalizations ---------------------------------------

        Tool(
            name: "testflight_beta_build_localizations_list",
            description: "List per-locale What to Test notes attached to a build.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_build_localizations_get",
            description: "Get a single per-locale What to Test record by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_build_localizations_create",
            description: "Create a per-locale What to Test record on a build.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string")]),
                    "whats_new": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_id"), .string("locale")]),
            ])
        ),

        Tool(
            name: "testflight_beta_build_localizations_update",
            description: "Update the What to Test text for a beta build localization.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "whats_new": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_build_localizations_delete",
            description: "Delete a per-locale What to Test record from a build.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // betaAppReviewDetails -----------------------------------------

        Tool(
            name: "testflight_beta_app_review_detail_get",
            description: "Read the TestFlight Beta App Review contact info and demo account fields attached to an app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_app_review_detail_update",
            description: "Update the TestFlight Beta App Review contact info for an app. Nil/omitted fields stay as is.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("betaAppReviewDetails id, NOT the app id")]),
                    "contact_first_name": .object(["type": .string("string")]),
                    "contact_last_name": .object(["type": .string("string")]),
                    "contact_phone": .object(["type": .string("string")]),
                    "contact_email": .object(["type": .string("string")]),
                    "demo_account_name": .object(["type": .string("string")]),
                    "demo_account_password": .object(["type": .string("string")]),
                    "demo_account_required": .object(["type": .string("boolean")]),
                    "notes": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // betaAppReviewSubmissions -------------------------------------

        Tool(
            name: "testflight_beta_app_review_submissions_list",
            description: "List historical and pending Beta App Review submissions for an app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_app_review_submissions_get",
            description: "Get a single Beta App Review submission by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_app_review_submissions_create",
            description: "Submit a build for Beta App Review. Required before a build can be made available to external testers.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_id")]),
            ])
        ),

        // betaLicenseAgreements ----------------------------------------

        Tool(
            name: "testflight_beta_license_agreement_get",
            description: "Read the TestFlight EULA testers must accept before installing a build.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "testflight_beta_license_agreement_update",
            description: "Replace the TestFlight EULA text for an app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("betaLicenseAgreements id, NOT the app id")]),
                    "agreement_text": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id"), .string("agreement_text")]),
            ])
        ),

        // betaTesterMetrics -------------------------------------------

        Tool(
            name: "testflight_beta_tester_metrics_list",
            description: "Per-tester install/launch counts for an app. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        // buildBundles ------------------------------------------------

        Tool(
            name: "testflight_build_bundles_list",
            description: "List the bundles inside a build: primary .app plus extensions, app clips, watch apps. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_id")]),
            ])
        ),

        Tool(
            name: "testflight_build_bundles_get",
            description: "Get a single build bundle by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // buildIcons --------------------------------------------------

        Tool(
            name: "testflight_build_icons_list",
            description: "List app icon image assets attached to a build. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Tool names handled by this module. Used by the MCP main dispatcher
    /// to route a CallTool request to `handle` when the name starts with
    /// `testflight_`.
    static let toolNames: Set<String> = Set(tools.map(\.name))

    /// Master entry point. Resolves credentials, constructs the API
    /// wrapper, and dispatches to the matching handler by tool name. All
    /// handlers return JSON text content; errors surface as
    /// `isError: true` results so the agent can react cleanly.
    static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            return errorResult(
                "App Store Connect credentials are not configured. " +
                "Run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / " +
                "ASC_KEY_PATH. (\(error))"
            )
        }
        let client = ASCClient(credentials: creds)
        let api = TestFlightAPI(client: client)

        do {
            switch params.name {

            case "testflight_beta_groups_list":
                return try await handleBetaGroupsList(params, api: api)
            case "testflight_beta_groups_get":
                return try await handleBetaGroupsGet(params, api: api)
            case "testflight_beta_groups_create":
                return try await handleBetaGroupsCreate(params, api: api)
            case "testflight_beta_groups_update":
                return try await handleBetaGroupsUpdate(params, api: api)
            case "testflight_beta_groups_delete":
                return try await handleBetaGroupsDelete(params, api: api)
            case "testflight_beta_groups_add_builds":
                return try await handleBetaGroupsAddBuilds(params, api: api)
            case "testflight_beta_groups_remove_builds":
                return try await handleBetaGroupsRemoveBuilds(params, api: api)
            case "testflight_beta_groups_add_testers":
                return try await handleBetaGroupsAddTesters(params, api: api)
            case "testflight_beta_groups_remove_testers":
                return try await handleBetaGroupsRemoveTesters(params, api: api)
            case "testflight_beta_groups_create_and_invite":
                return try await handleBetaGroupsCreateAndInvite(params, api: api)

            case "testflight_beta_testers_list":
                return try await handleBetaTestersList(params, api: api)
            case "testflight_beta_testers_get":
                return try await handleBetaTestersGet(params, api: api)
            case "testflight_beta_testers_create":
                return try await handleBetaTestersCreate(params, api: api)
            case "testflight_beta_testers_delete":
                return try await handleBetaTestersDelete(params, api: api)
            case "testflight_beta_testers_remove_from_app":
                return try await handleBetaTestersRemoveFromApp(params, api: api)
            case "testflight_beta_testers_assign_to_groups":
                return try await handleBetaTestersAssignToGroups(params, api: api)
            case "testflight_beta_testers_remove_from_groups":
                return try await handleBetaTestersRemoveFromGroups(params, api: api)
            case "testflight_beta_tester_invitations_create":
                return try await handleBetaTesterInvitationsCreate(params, api: api)

            case "testflight_prerelease_versions_list":
                return try await handlePrereleaseVersionsList(params, api: api)
            case "testflight_prerelease_versions_get":
                return try await handlePrereleaseVersionsGet(params, api: api)

            case "testflight_builds_list":
                return try await handleBuildsList(params, api: api)
            case "testflight_builds_get":
                return try await handleBuildsGet(params, api: api)
            case "testflight_builds_set_expired":
                return try await handleBuildsSetExpired(params, api: api)

            case "testflight_build_beta_detail_get":
                return try await handleBuildBetaDetailGet(params, api: api)
            case "testflight_build_beta_detail_update":
                return try await handleBuildBetaDetailUpdate(params, api: api)

            case "testflight_build_beta_notifications_create":
                return try await handleBuildBetaNotificationsCreate(params, api: api)

            case "testflight_beta_app_localizations_list":
                return try await handleBetaAppLocalizationsList(params, api: api)
            case "testflight_beta_app_localizations_get":
                return try await handleBetaAppLocalizationsGet(params, api: api)
            case "testflight_beta_app_localizations_create":
                return try await handleBetaAppLocalizationsCreate(params, api: api)
            case "testflight_beta_app_localizations_update":
                return try await handleBetaAppLocalizationsUpdate(params, api: api)
            case "testflight_beta_app_localizations_delete":
                return try await handleBetaAppLocalizationsDelete(params, api: api)

            case "testflight_beta_build_localizations_list":
                return try await handleBetaBuildLocalizationsList(params, api: api)
            case "testflight_beta_build_localizations_get":
                return try await handleBetaBuildLocalizationsGet(params, api: api)
            case "testflight_beta_build_localizations_create":
                return try await handleBetaBuildLocalizationsCreate(params, api: api)
            case "testflight_beta_build_localizations_update":
                return try await handleBetaBuildLocalizationsUpdate(params, api: api)
            case "testflight_beta_build_localizations_delete":
                return try await handleBetaBuildLocalizationsDelete(params, api: api)

            case "testflight_beta_app_review_detail_get":
                return try await handleBetaAppReviewDetailGet(params, api: api)
            case "testflight_beta_app_review_detail_update":
                return try await handleBetaAppReviewDetailUpdate(params, api: api)

            case "testflight_beta_app_review_submissions_list":
                return try await handleBetaAppReviewSubmissionsList(params, api: api)
            case "testflight_beta_app_review_submissions_get":
                return try await handleBetaAppReviewSubmissionsGet(params, api: api)
            case "testflight_beta_app_review_submissions_create":
                return try await handleBetaAppReviewSubmissionsCreate(params, api: api)

            case "testflight_beta_license_agreement_get":
                return try await handleBetaLicenseAgreementGet(params, api: api)
            case "testflight_beta_license_agreement_update":
                return try await handleBetaLicenseAgreementUpdate(params, api: api)

            case "testflight_beta_tester_metrics_list":
                return try await handleBetaTesterMetricsList(params, api: api)

            case "testflight_build_bundles_list":
                return try await handleBuildBundlesList(params, api: api)
            case "testflight_build_bundles_get":
                return try await handleBuildBundlesGet(params, api: api)

            case "testflight_build_icons_list":
                return try await handleBuildIconsList(params, api: api)

            default:
                return errorResult("Unknown TestFlight tool: \(params.name)")
            }
        } catch let e as ASCClient.APIError {
            return errorResult(
                "App Store Connect API error (HTTP \(e.statusCode))\n" +
                e.details.map { "  [\($0.code)] \($0.title): \($0.detail)" }
                    .joined(separator: "\n")
            )
        } catch {
            return errorResult("Error: \(error)")
        }
    }

    // MARK: - Argument helpers

    private static func arg(_ params: CallTool.Parameters, _ key: String) -> Value? {
        params.arguments?[key]
    }

    private static func requireString(_ params: CallTool.Parameters, _ key: String) throws -> String {
        guard let s = arg(params, key)?.stringValue else {
            throw MCPArgError("Missing required string argument: \(key)")
        }
        return s
    }

    private static func optionalString(_ params: CallTool.Parameters, _ key: String) -> String? {
        arg(params, key)?.stringValue
    }

    private static func optionalInt(_ params: CallTool.Parameters, _ key: String) -> Int? {
        if let v = arg(params, key)?.intValue { return v }
        if let s = arg(params, key)?.stringValue, let i = Int(s) { return i }
        return nil
    }

    private static func optionalBool(_ params: CallTool.Parameters, _ key: String) -> Bool? {
        arg(params, key)?.boolValue
    }

    private static func requireBool(_ params: CallTool.Parameters, _ key: String) throws -> Bool {
        guard let b = arg(params, key)?.boolValue else {
            throw MCPArgError("Missing required boolean argument: \(key)")
        }
        return b
    }

    private static func requireStringArray(
        _ params: CallTool.Parameters, _ key: String
    ) throws -> [String] {
        guard let arr = arg(params, key)?.arrayValue else {
            throw MCPArgError("Missing required array argument: \(key)")
        }
        let items = arr.compactMap(\.stringValue)
        if items.isEmpty {
            throw MCPArgError("Array argument \(key) is empty or contains non-strings")
        }
        return items
    }

    private static func optionalStringArray(
        _ params: CallTool.Parameters, _ key: String
    ) -> [String] {
        guard let arr = arg(params, key)?.arrayValue else { return [] }
        return arr.compactMap(\.stringValue)
    }

    private struct MCPArgError: Error, CustomStringConvertible {
        let description: String
        init(_ m: String) { self.description = m }
    }

    // MARK: - JSON output

    private static func jsonText<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)])
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func ackResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)])
    }

    // MARK: - Page wrapper for JSON output

    private struct PageOut<Item: Encodable>: Encodable {
        let data: [Item]
        let nextCursor: String?
    }

    // MARK: - Handlers: betaGroups

    private static func handleBetaGroupsList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listBetaGroups(appID: appID, limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBetaGroupsGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let group = try await api.getBetaGroup(id: id)
        return try jsonText(group)
    }

    private static func handleBetaGroupsCreate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let name = try requireString(params, "name")
        let fields = TestFlightAPI.BetaGroupFields(
            publicLinkEnabled: optionalBool(params, "public_link_enabled"),
            publicLinkLimit: optionalInt(params, "public_link_limit"),
            publicLinkLimitEnabled: optionalBool(params, "public_link_limit_enabled"),
            feedbackEnabled: optionalBool(params, "feedback_enabled"),
            hasAccessToAllBuilds: optionalBool(params, "has_access_to_all_builds"),
            iosBuildsAvailableForAppleSiliconMac: optionalBool(params, "ios_builds_available_for_apple_silicon_mac")
        )
        let group = try await api.createBetaGroup(appID: appID, name: name, fields: fields)
        return try jsonText(group)
    }

    private static func handleBetaGroupsUpdate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = TestFlightAPI.BetaGroupFields(
            name: optionalString(params, "name"),
            publicLinkEnabled: optionalBool(params, "public_link_enabled"),
            publicLinkLimit: optionalInt(params, "public_link_limit"),
            publicLinkLimitEnabled: optionalBool(params, "public_link_limit_enabled"),
            feedbackEnabled: optionalBool(params, "feedback_enabled"),
            hasAccessToAllBuilds: optionalBool(params, "has_access_to_all_builds"),
            iosBuildsAvailableForAppleSiliconMac: optionalBool(params, "ios_builds_available_for_apple_silicon_mac")
        )
        let group = try await api.updateBetaGroup(id: id, fields: fields)
        return try jsonText(group)
    }

    private static func handleBetaGroupsDelete(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.deleteBetaGroup(id: id)
        return ackResult("Deleted beta group \(id)")
    }

    private static func handleBetaGroupsAddBuilds(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let groupID = try requireString(params, "group_id")
        let buildIDs = try requireStringArray(params, "build_ids")
        try await api.addBuildsToBetaGroup(groupID: groupID, buildIDs: buildIDs)
        return ackResult("Added \(buildIDs.count) build(s) to group \(groupID)")
    }

    private static func handleBetaGroupsRemoveBuilds(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let groupID = try requireString(params, "group_id")
        let buildIDs = try requireStringArray(params, "build_ids")
        try await api.removeBuildsFromBetaGroup(groupID: groupID, buildIDs: buildIDs)
        return ackResult("Removed \(buildIDs.count) build(s) from group \(groupID)")
    }

    private static func handleBetaGroupsAddTesters(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let groupID = try requireString(params, "group_id")
        let testerIDs = try requireStringArray(params, "tester_ids")
        try await api.addTestersToBetaGroup(groupID: groupID, testerIDs: testerIDs)
        return ackResult("Added \(testerIDs.count) tester(s) to group \(groupID)")
    }

    private static func handleBetaGroupsRemoveTesters(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let groupID = try requireString(params, "group_id")
        let testerIDs = try requireStringArray(params, "tester_ids")
        try await api.removeTestersFromBetaGroup(groupID: groupID, testerIDs: testerIDs)
        return ackResult("Removed \(testerIDs.count) tester(s) from group \(groupID)")
    }

    private static func handleBetaGroupsCreateAndInvite(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let name = try requireString(params, "name")
        let testerIDs = try requireStringArray(params, "tester_ids")
        let fields = TestFlightAPI.BetaGroupFields(
            publicLinkEnabled: optionalBool(params, "public_link_enabled"),
            feedbackEnabled: optionalBool(params, "feedback_enabled")
        )
        let group = try await api.createBetaGroupAndInvite(
            appID: appID, name: name, testerIDs: testerIDs, fields: fields
        )
        return try jsonText(group)
    }

    // MARK: - Handlers: betaTesters

    private static func handleBetaTestersList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listBetaTesters(appID: appID, limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBetaTestersGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let tester = try await api.getBetaTester(id: id)
        return try jsonText(tester)
    }

    private static func handleBetaTestersCreate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let email = try requireString(params, "email")
        let firstName = optionalString(params, "first_name")
        let lastName = optionalString(params, "last_name")
        let groupIDs = optionalStringArray(params, "beta_group_ids")
        let tester = try await api.createBetaTester(
            appID: appID, email: email,
            firstName: firstName, lastName: lastName,
            betaGroupIDs: groupIDs
        )
        return try jsonText(tester)
    }

    private static func handleBetaTestersDelete(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.deleteBetaTester(id: id)
        return ackResult("Deleted beta tester \(id)")
    }

    private static func handleBetaTestersRemoveFromApp(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let testerID = try requireString(params, "tester_id")
        let appID = try requireString(params, "app_id")
        try await api.removeBetaTesterFromApp(testerID: testerID, appID: appID)
        return ackResult("Removed tester \(testerID) from app \(appID)")
    }

    private static func handleBetaTestersAssignToGroups(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let testerID = try requireString(params, "tester_id")
        let groupIDs = try requireStringArray(params, "group_ids")
        try await api.assignBetaTesterToGroups(testerID: testerID, groupIDs: groupIDs)
        return ackResult("Assigned tester \(testerID) to \(groupIDs.count) group(s)")
    }

    private static func handleBetaTestersRemoveFromGroups(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let testerID = try requireString(params, "tester_id")
        let groupIDs = try requireStringArray(params, "group_ids")
        try await api.removeBetaTesterFromGroups(testerID: testerID, groupIDs: groupIDs)
        return ackResult("Removed tester \(testerID) from \(groupIDs.count) group(s)")
    }

    private static func handleBetaTesterInvitationsCreate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let testerID = try requireString(params, "tester_id")
        let appID = try requireString(params, "app_id")
        let invitation = try await api.createBetaTesterInvitation(
            testerID: testerID, appID: appID
        )
        return try jsonText(invitation)
    }

    // MARK: - Handlers: prereleaseVersions

    private static func handlePrereleaseVersionsList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let platform = optionalString(params, "platform")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listPrereleaseVersions(
            appID: appID, platform: platform, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handlePrereleaseVersionsGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let version = try await api.getPrereleaseVersion(id: id)
        return try jsonText(version)
    }

    // MARK: - Handlers: builds

    private static func handleBuildsList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = optionalString(params, "app_id")
        let expired = optionalBool(params, "expired")
        let processingState = optionalString(params, "processing_state")
        let prereleaseID = optionalString(params, "prerelease_version_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listBuilds(
            appID: appID,
            expired: expired,
            processingState: processingState,
            preReleaseVersionID: prereleaseID,
            limit: limit,
            cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBuildsGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let build = try await api.getBuild(id: id)
        return try jsonText(build)
    }

    private static func handleBuildsSetExpired(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let expired = try requireBool(params, "expired")
        let build = try await api.setBuildExpired(id: id, expired: expired)
        return try jsonText(build)
    }

    // MARK: - Handlers: buildBetaDetails / notifications

    private static func handleBuildBetaDetailGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let buildID = try requireString(params, "build_id")
        let detail = try await api.getBuildBetaDetail(buildID: buildID)
        return try jsonText(detail)
    }

    private static func handleBuildBetaDetailUpdate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let autoNotify = try requireBool(params, "auto_notify_enabled")
        let detail = try await api.updateBuildBetaDetail(
            id: id, autoNotifyEnabled: autoNotify
        )
        return try jsonText(detail)
    }

    private static func handleBuildBetaNotificationsCreate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let buildID = try requireString(params, "build_id")
        let notification = try await api.sendBuildBetaNotification(buildID: buildID)
        return try jsonText(notification)
    }

    // MARK: - Handlers: betaAppLocalizations

    private static func handleBetaAppLocalizationsList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listBetaAppLocalizations(
            appID: appID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBetaAppLocalizationsGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let loc = try await api.getBetaAppLocalization(id: id)
        return try jsonText(loc)
    }

    private static func handleBetaAppLocalizationsCreate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let locale = try requireString(params, "locale")
        let fields = TestFlightAPI.BetaAppLocalizationFields(
            description: optionalString(params, "description"),
            feedbackEmail: optionalString(params, "feedback_email"),
            marketingURL: optionalString(params, "marketing_url"),
            privacyPolicyURL: optionalString(params, "privacy_policy_url"),
            tvOsPrivacyPolicy: optionalString(params, "tv_os_privacy_policy")
        )
        let loc = try await api.createBetaAppLocalization(
            appID: appID, locale: locale, fields: fields
        )
        return try jsonText(loc)
    }

    private static func handleBetaAppLocalizationsUpdate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = TestFlightAPI.BetaAppLocalizationFields(
            description: optionalString(params, "description"),
            feedbackEmail: optionalString(params, "feedback_email"),
            marketingURL: optionalString(params, "marketing_url"),
            privacyPolicyURL: optionalString(params, "privacy_policy_url"),
            tvOsPrivacyPolicy: optionalString(params, "tv_os_privacy_policy")
        )
        let loc = try await api.updateBetaAppLocalization(id: id, fields: fields)
        return try jsonText(loc)
    }

    private static func handleBetaAppLocalizationsDelete(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.deleteBetaAppLocalization(id: id)
        return ackResult("Deleted beta app localization \(id)")
    }

    // MARK: - Handlers: betaBuildLocalizations

    private static func handleBetaBuildLocalizationsList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let buildID = try requireString(params, "build_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listBetaBuildLocalizations(
            buildID: buildID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBetaBuildLocalizationsGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let loc = try await api.getBetaBuildLocalization(id: id)
        return try jsonText(loc)
    }

    private static func handleBetaBuildLocalizationsCreate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let buildID = try requireString(params, "build_id")
        let locale = try requireString(params, "locale")
        let whatsNew = optionalString(params, "whats_new")
        let loc = try await api.createBetaBuildLocalization(
            buildID: buildID, locale: locale, whatsNew: whatsNew
        )
        return try jsonText(loc)
    }

    private static func handleBetaBuildLocalizationsUpdate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let whatsNew = optionalString(params, "whats_new")
        let loc = try await api.updateBetaBuildLocalization(id: id, whatsNew: whatsNew)
        return try jsonText(loc)
    }

    private static func handleBetaBuildLocalizationsDelete(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.deleteBetaBuildLocalization(id: id)
        return ackResult("Deleted beta build localization \(id)")
    }

    // MARK: - Handlers: betaAppReviewDetails

    private static func handleBetaAppReviewDetailGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let detail = try await api.getBetaAppReviewDetail(appID: appID)
        return try jsonText(detail)
    }

    private static func handleBetaAppReviewDetailUpdate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = TestFlightAPI.BetaAppReviewDetailFields(
            contactFirstName: optionalString(params, "contact_first_name"),
            contactLastName: optionalString(params, "contact_last_name"),
            contactPhone: optionalString(params, "contact_phone"),
            contactEmail: optionalString(params, "contact_email"),
            demoAccountName: optionalString(params, "demo_account_name"),
            demoAccountPassword: optionalString(params, "demo_account_password"),
            demoAccountRequired: optionalBool(params, "demo_account_required"),
            notes: optionalString(params, "notes")
        )
        let detail = try await api.updateBetaAppReviewDetail(id: id, fields: fields)
        return try jsonText(detail)
    }

    // MARK: - Handlers: betaAppReviewSubmissions

    private static func handleBetaAppReviewSubmissionsList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listBetaAppReviewSubmissions(
            appID: appID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBetaAppReviewSubmissionsGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let submission = try await api.getBetaAppReviewSubmission(id: id)
        return try jsonText(submission)
    }

    private static func handleBetaAppReviewSubmissionsCreate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let buildID = try requireString(params, "build_id")
        let submission = try await api.createBetaAppReviewSubmission(buildID: buildID)
        return try jsonText(submission)
    }

    // MARK: - Handlers: betaLicenseAgreement

    private static func handleBetaLicenseAgreementGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let agreement = try await api.getBetaLicenseAgreement(appID: appID)
        return try jsonText(agreement)
    }

    private static func handleBetaLicenseAgreementUpdate(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let text = try requireString(params, "agreement_text")
        let agreement = try await api.updateBetaLicenseAgreement(
            id: id, agreementText: text
        )
        return try jsonText(agreement)
    }

    // MARK: - Handlers: betaTesterMetrics

    private static func handleBetaTesterMetricsList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listBetaTesterMetrics(
            appID: appID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    // MARK: - Handlers: buildBundles

    private static func handleBuildBundlesList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let buildID = try requireString(params, "build_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.listBuildBundles(
            buildID: buildID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBuildBundlesGet(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let bundle = try await api.getBuildBundle(id: id)
        return try jsonText(bundle)
    }

    // MARK: - Handlers: buildIcons

    private static func handleBuildIconsList(
        _ params: CallTool.Parameters, api: TestFlightAPI
    ) async throws -> CallTool.Result {
        let buildID = try requireString(params, "build_id")
        let limit = optionalInt(params, "limit") ?? 50
        let cursor = optionalString(params, "cursor")
        let page = try await api.listBuildIcons(
            buildID: buildID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }
}
