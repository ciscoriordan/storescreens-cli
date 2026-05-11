import MCP
import Foundation
import StorescreensCore

/// MCP tool surface for the Game Center surfaces added in App Store Connect
/// OpenAPI spec v4.0 (June 2025) and v4.2 (December 2025):
///
///   - Activities (CRUD + images + per-locale + versions)
///   - Challenges (CRUD + images + per-locale + versions)
///   - V2 versioning for Achievements / Leaderboards / LeaderboardSets
///   - Sandbox-only score + achievement progress submissions
///
/// Every tool is a thin wrapper around a `GameCenterActivitiesAPI` namespace
/// method. Inputs arrive as JSON arguments, outputs are pretty-printed JSON
/// text content so AI agents get a stable, machine-readable response shape
/// without having to construct raw HTTP requests against Apple's API.
///
/// Tool naming convention: `gc_<resource>_<op>` (snake_case). All names in
/// this file are distinct from those defined in `GameCenterMCPTools` (which
/// covers the Wave 2 V1 surface), so a dispatcher routing both files by tool
/// name will never see a collision.
enum GameCenterActivitiesMCPTools {

    // MARK: - Tool definitions

    static let tools: [Tool] = [

        // Activities ------------------------------------------------------

        Tool(
            name: "gc_activities_list",
            description: "List Game Center activities for an app, gameCenterDetail, or gameCenterGroup. Supply exactly one of app_id, detail_id, or group_id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "detail_id": .object(["type": .string("string")]),
                    "group_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "gc_activities_get",
            description: "Get a gameCenterActivity by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_activities_create",
            description: "Create a Game Center activity under a gameCenterDetail or a gameCenterGroup. Activity types include EVENT and TOURNAMENT.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "detail_id": .object(["type": .string("string")]),
                    "group_id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                    "activity_type": .object(["type": .string("string"), "description": .string("EVENT or TOURNAMENT")]),
                    "event_start_date": .object(["type": .string("string"), "description": .string("ISO-8601 timestamp")]),
                    "event_end_date": .object(["type": .string("string"), "description": .string("ISO-8601 timestamp")]),
                ]),
                "required": .array([.string("reference_name"), .string("vendor_identifier")]),
            ])
        ),
        Tool(
            name: "gc_activities_update",
            description: "PATCH a Game Center activity. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                    "activity_type": .object(["type": .string("string")]),
                    "event_start_date": .object(["type": .string("string")]),
                    "event_end_date": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_activities_archive",
            description: "Toggle archived on a Game Center activity to hide it from the catalog.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "archived": .object(["type": .string("boolean"), "description": .string("Default true.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_activities_delete",
            description: "Delete a Game Center activity.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Activity localizations ------------------------------------------

        Tool(
            name: "gc_activity_localizations_list",
            description: "List per-locale display copy records for a Game Center activity.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "activity_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("activity_id")]),
            ])
        ),
        Tool(
            name: "gc_activity_localizations_get",
            description: "Get a gameCenterActivityLocalization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_activity_localizations_create",
            description: "Create a per-locale record for an activity with name, subtitle, and description text.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "activity_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string"), "description": .string("BCP-47 locale, e.g. en-US")]),
                    "name": .object(["type": .string("string")]),
                    "subtitle": .object(["type": .string("string")]),
                    "activity_description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("activity_id"), .string("locale")]),
            ])
        ),
        Tool(
            name: "gc_activity_localizations_update",
            description: "Update fields on an activity locale entry. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "subtitle": .object(["type": .string("string")]),
                    "activity_description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_activity_localizations_delete",
            description: "Delete an activity locale entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Activity images -------------------------------------------------

        Tool(
            name: "gc_activity_images_list",
            description: "List activity images attached to a per-locale activity record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localization_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("localization_id")]),
            ])
        ),
        Tool(
            name: "gc_activity_images_get",
            description: "Get a gameCenterActivityImage by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_activity_images_upload",
            description: "Upload an activity image. Runs the full 3-phase reservation + chunk PUT + checksum confirm flow.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localization_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string"), "description": .string("Absolute path to the PNG file")]),
                ]),
                "required": .array([.string("localization_id"), .string("file_path")]),
            ])
        ),
        Tool(
            name: "gc_activity_images_update",
            description: "PATCH an activity image's metadata (currently just fileName). Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "file_name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_activity_images_delete",
            description: "Delete an activity image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Activity versions -----------------------------------------------

        Tool(
            name: "gc_activity_versions_list",
            description: "List per-app-version snapshots of an activity's config.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "activity_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("activity_id")]),
            ])
        ),
        Tool(
            name: "gc_activity_versions_get",
            description: "Get a gameCenterActivityVersion by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_activity_versions_create",
            description: "Create an activity version snapshot. Optionally bind it to a specific gameCenterAppVersion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "activity_id": .object(["type": .string("string")]),
                    "app_version_id": .object(["type": .string("string")]),
                    "live": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("activity_id")]),
            ])
        ),
        Tool(
            name: "gc_activity_versions_update",
            description: "PATCH an activity version snapshot. Flips the live flag.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "live": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Challenges ------------------------------------------------------

        Tool(
            name: "gc_challenges_list",
            description: "List Game Center challenges for an app, gameCenterDetail, or gameCenterGroup. Supply exactly one of app_id, detail_id, or group_id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "detail_id": .object(["type": .string("string")]),
                    "group_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "gc_challenges_get",
            description: "Get a gameCenterChallenge by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_challenges_create",
            description: "Create a Game Center challenge under a gameCenterDetail or a gameCenterGroup. Optionally link to a leaderboard so scores feed a ranking.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "detail_id": .object(["type": .string("string")]),
                    "group_id": .object(["type": .string("string")]),
                    "leaderboard_id": .object(["type": .string("string"), "description": .string("Optional gameCenterLeaderboard to link the challenge to")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                    "challenge_type": .object(["type": .string("string"), "description": .string("Apple challenge type identifier")]),
                ]),
                "required": .array([.string("reference_name"), .string("vendor_identifier")]),
            ])
        ),
        Tool(
            name: "gc_challenges_update",
            description: "PATCH a Game Center challenge. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                    "challenge_type": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_challenges_archive",
            description: "Toggle archived on a Game Center challenge.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "archived": .object(["type": .string("boolean"), "description": .string("Default true.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_challenges_delete",
            description: "Delete a Game Center challenge.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Challenge localizations -----------------------------------------

        Tool(
            name: "gc_challenge_localizations_list",
            description: "List per-locale display copy records for a Game Center challenge.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "challenge_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("challenge_id")]),
            ])
        ),
        Tool(
            name: "gc_challenge_localizations_get",
            description: "Get a gameCenterChallengeLocalization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_challenge_localizations_create",
            description: "Create a per-locale record for a challenge with name, subtitle, and description text.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "challenge_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "subtitle": .object(["type": .string("string")]),
                    "challenge_description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("challenge_id"), .string("locale")]),
            ])
        ),
        Tool(
            name: "gc_challenge_localizations_update",
            description: "Update fields on a challenge locale entry. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "subtitle": .object(["type": .string("string")]),
                    "challenge_description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_challenge_localizations_delete",
            description: "Delete a challenge locale entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Challenge images ------------------------------------------------

        Tool(
            name: "gc_challenge_images_list",
            description: "List challenge images attached to a per-locale challenge record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localization_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("localization_id")]),
            ])
        ),
        Tool(
            name: "gc_challenge_images_get",
            description: "Get a gameCenterChallengeImage by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_challenge_images_upload",
            description: "Upload a challenge image. Runs the full 3-phase reservation + chunk PUT + checksum confirm flow.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localization_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string"), "description": .string("Absolute path to the PNG file")]),
                ]),
                "required": .array([.string("localization_id"), .string("file_path")]),
            ])
        ),
        Tool(
            name: "gc_challenge_images_update",
            description: "PATCH a challenge image's metadata (currently just fileName).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "file_name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_challenge_images_delete",
            description: "Delete a challenge image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Challenge versions ----------------------------------------------

        Tool(
            name: "gc_challenge_versions_list",
            description: "List per-app-version snapshots of a challenge's config.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "challenge_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("challenge_id")]),
            ])
        ),
        Tool(
            name: "gc_challenge_versions_get",
            description: "Get a gameCenterChallengeVersion by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_challenge_versions_create",
            description: "Create a challenge version snapshot. Apple does not support update or delete on this resource.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "challenge_id": .object(["type": .string("string")]),
                    "app_version_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("challenge_id")]),
            ])
        ),

        // V2 versioning: achievements / leaderboards / leaderboard-sets --

        Tool(
            name: "gc_achievement_versions_v2_list",
            description: "List per-app-version snapshots (V2) of an achievement's config.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "achievement_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("achievement_id")]),
            ])
        ),
        Tool(
            name: "gc_achievement_versions_v2_get",
            description: "Get a V2 gameCenterAchievementVersion by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_achievement_versions_v2_create",
            description: "Create a V2 per-app-version snapshot of an achievement.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "achievement_id": .object(["type": .string("string")]),
                    "app_version_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("achievement_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_versions_v2_list",
            description: "List per-app-version snapshots (V2) of a leaderboard's config.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "leaderboard_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("leaderboard_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_versions_v2_get",
            description: "Get a V2 gameCenterLeaderboardVersion by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_versions_v2_create",
            description: "Create a V2 per-app-version snapshot of a leaderboard.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "leaderboard_id": .object(["type": .string("string")]),
                    "app_version_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("leaderboard_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_versions_v2_list",
            description: "List per-app-version snapshots (V2) of a leaderboard set's config.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "leaderboard_set_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("leaderboard_set_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_versions_v2_get",
            description: "Get a V2 gameCenterLeaderboardSetVersion by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_versions_v2_create",
            description: "Create a V2 per-app-version snapshot of a leaderboard set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "leaderboard_set_id": .object(["type": .string("string")]),
                    "app_version_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("leaderboard_set_id")]),
            ])
        ),

        // Sandbox-only submission endpoints -------------------------------

        Tool(
            name: "gc_leaderboard_entry_submissions_create",
            description: "Sandbox-only: submit a fake player score for a leaderboard. Apple rejects calls outside the sandbox environment. Create-only resource.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "leaderboard_id": .object(["type": .string("string")]),
                    "player_id": .object(["type": .string("string"), "description": .string("gameCenterPlayer id of the sandbox tester")]),
                    "score": .object(["type": .string("string"), "description": .string("Stringified integer score")]),
                    "context": .object(["type": .string("string"), "description": .string("Optional opaque context payload")]),
                ]),
                "required": .array([.string("leaderboard_id"), .string("player_id"), .string("score")]),
            ])
        ),
        Tool(
            name: "gc_player_achievement_submissions_create",
            description: "Sandbox-only: submit a fake achievement progress event for a player. Apple rejects calls outside the sandbox environment. Create-only resource.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "achievement_id": .object(["type": .string("string")]),
                    "player_id": .object(["type": .string("string"), "description": .string("gameCenterPlayer id of the sandbox tester")]),
                    "percent_complete": .object(["type": .string("number"), "description": .string("0-100; 100 marks the achievement earned")]),
                ]),
                "required": .array([.string("achievement_id"), .string("player_id"), .string("percent_complete")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    static let toolNames: Set<String> = Set(tools.map(\.name))

    /// Master entry point. Resolves credentials, constructs the API wrapper,
    /// and dispatches to the matching handler by tool name. Returns a
    /// `CallTool.Result` with `isError: true` for unknown names or API
    /// failures, so the agent can react cleanly without further parsing.
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
        let api = GameCenterActivitiesAPI(client: client)

        do {
            switch params.name {

            // Activities
            case "gc_activities_list":    return try await handleActivitiesList(params, api: api)
            case "gc_activities_get":     return try await handleActivitiesGet(params, api: api)
            case "gc_activities_create":  return try await handleActivitiesCreate(params, api: api)
            case "gc_activities_update":  return try await handleActivitiesUpdate(params, api: api)
            case "gc_activities_archive": return try await handleActivitiesArchive(params, api: api)
            case "gc_activities_delete":  return try await handleActivitiesDelete(params, api: api)

            // Activity localizations
            case "gc_activity_localizations_list":   return try await handleActivityLocalizationsList(params, api: api)
            case "gc_activity_localizations_get":    return try await handleActivityLocalizationsGet(params, api: api)
            case "gc_activity_localizations_create": return try await handleActivityLocalizationsCreate(params, api: api)
            case "gc_activity_localizations_update": return try await handleActivityLocalizationsUpdate(params, api: api)
            case "gc_activity_localizations_delete": return try await handleActivityLocalizationsDelete(params, api: api)

            // Activity images
            case "gc_activity_images_list":   return try await handleActivityImagesList(params, api: api)
            case "gc_activity_images_get":    return try await handleActivityImagesGet(params, api: api)
            case "gc_activity_images_upload": return try await handleActivityImagesUpload(params, api: api)
            case "gc_activity_images_update": return try await handleActivityImagesUpdate(params, api: api)
            case "gc_activity_images_delete": return try await handleActivityImagesDelete(params, api: api)

            // Activity versions
            case "gc_activity_versions_list":   return try await handleActivityVersionsList(params, api: api)
            case "gc_activity_versions_get":    return try await handleActivityVersionsGet(params, api: api)
            case "gc_activity_versions_create": return try await handleActivityVersionsCreate(params, api: api)
            case "gc_activity_versions_update": return try await handleActivityVersionsUpdate(params, api: api)

            // Challenges
            case "gc_challenges_list":    return try await handleChallengesList(params, api: api)
            case "gc_challenges_get":     return try await handleChallengesGet(params, api: api)
            case "gc_challenges_create":  return try await handleChallengesCreate(params, api: api)
            case "gc_challenges_update":  return try await handleChallengesUpdate(params, api: api)
            case "gc_challenges_archive": return try await handleChallengesArchive(params, api: api)
            case "gc_challenges_delete":  return try await handleChallengesDelete(params, api: api)

            // Challenge localizations
            case "gc_challenge_localizations_list":   return try await handleChallengeLocalizationsList(params, api: api)
            case "gc_challenge_localizations_get":    return try await handleChallengeLocalizationsGet(params, api: api)
            case "gc_challenge_localizations_create": return try await handleChallengeLocalizationsCreate(params, api: api)
            case "gc_challenge_localizations_update": return try await handleChallengeLocalizationsUpdate(params, api: api)
            case "gc_challenge_localizations_delete": return try await handleChallengeLocalizationsDelete(params, api: api)

            // Challenge images
            case "gc_challenge_images_list":   return try await handleChallengeImagesList(params, api: api)
            case "gc_challenge_images_get":    return try await handleChallengeImagesGet(params, api: api)
            case "gc_challenge_images_upload": return try await handleChallengeImagesUpload(params, api: api)
            case "gc_challenge_images_update": return try await handleChallengeImagesUpdate(params, api: api)
            case "gc_challenge_images_delete": return try await handleChallengeImagesDelete(params, api: api)

            // Challenge versions
            case "gc_challenge_versions_list":   return try await handleChallengeVersionsList(params, api: api)
            case "gc_challenge_versions_get":    return try await handleChallengeVersionsGet(params, api: api)
            case "gc_challenge_versions_create": return try await handleChallengeVersionsCreate(params, api: api)

            // V2 versioning
            case "gc_achievement_versions_v2_list":   return try await handleAchievementVersionsV2List(params, api: api)
            case "gc_achievement_versions_v2_get":    return try await handleAchievementVersionsV2Get(params, api: api)
            case "gc_achievement_versions_v2_create": return try await handleAchievementVersionsV2Create(params, api: api)

            case "gc_leaderboard_versions_v2_list":   return try await handleLeaderboardVersionsV2List(params, api: api)
            case "gc_leaderboard_versions_v2_get":    return try await handleLeaderboardVersionsV2Get(params, api: api)
            case "gc_leaderboard_versions_v2_create": return try await handleLeaderboardVersionsV2Create(params, api: api)

            case "gc_leaderboard_set_versions_v2_list":   return try await handleLeaderboardSetVersionsV2List(params, api: api)
            case "gc_leaderboard_set_versions_v2_get":    return try await handleLeaderboardSetVersionsV2Get(params, api: api)
            case "gc_leaderboard_set_versions_v2_create": return try await handleLeaderboardSetVersionsV2Create(params, api: api)

            // Sandbox-only submissions
            case "gc_leaderboard_entry_submissions_create":  return try await handleLeaderboardEntrySubmissionsCreate(params, api: api)
            case "gc_player_achievement_submissions_create": return try await handlePlayerAchievementSubmissionsCreate(params, api: api)

            default:
                return errorResult("Unknown Game Center Activities tool: \(params.name)")
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
        guard let s = arg(params, key)?.stringValue, !s.isEmpty else {
            throw MCPArgError("Missing required string argument: \(key)")
        }
        return s
    }

    private static func optionalString(_ params: CallTool.Parameters, _ key: String) -> String? {
        let s = arg(params, key)?.stringValue
        if let s, s.isEmpty { return nil }
        return s
    }

    private static func optionalInt(_ params: CallTool.Parameters, _ key: String) -> Int? {
        if let v = arg(params, key)?.intValue { return v }
        if let s = arg(params, key)?.stringValue, let i = Int(s) { return i }
        return nil
    }

    private static func optionalDouble(_ params: CallTool.Parameters, _ key: String) -> Double? {
        if let v = arg(params, key)?.doubleValue { return v }
        if let v = arg(params, key)?.intValue { return Double(v) }
        if let s = arg(params, key)?.stringValue, let d = Double(s) { return d }
        return nil
    }

    private static func optionalBool(_ params: CallTool.Parameters, _ key: String) -> Bool? {
        arg(params, key)?.boolValue
    }

    private static func requireDouble(_ params: CallTool.Parameters, _ key: String) throws -> Double {
        guard let d = optionalDouble(params, key) else {
            throw MCPArgError("Missing required number argument: \(key)")
        }
        return d
    }

    /// Parses an ISO-8601 timestamp string. Used by activity event-window
    /// fields (eventStartDate / eventEndDate).
    private static func optionalISODate(_ params: CallTool.Parameters, _ key: String) -> Date? {
        guard let s = optionalString(params, key) else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
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

    /// Encodable wrapper for paginated responses. Mirrors the shape used by
    /// the rest of the MCP family so agents can rely on a stable
    /// `{ data, nextCursor }` envelope.
    private struct PageOut<Item: Encodable>: Encodable {
        let data: [Item]
        let nextCursor: String?
    }

    // MARK: - Handlers: Activities

    private static func handleActivitiesList(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        if let appID = optionalString(params, "app_id") {
            let page = try await api.activities.listForApp(appID: appID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let detailID = optionalString(params, "detail_id") {
            let page = try await api.activities.listForDetail(detailID: detailID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let groupID = optionalString(params, "group_id") {
            let page = try await api.activities.listForGroup(groupID: groupID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        return errorResult("gc_activities_list requires one of app_id, detail_id, or group_id")
    }

    private static func handleActivitiesGet(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let activity = try await api.activities.get(id: id)
        return try jsonText(activity)
    }

    private static func handleActivitiesCreate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let detailID = optionalString(params, "detail_id")
        let groupID = optionalString(params, "group_id")
        guard detailID != nil || groupID != nil else {
            return errorResult("gc_activities_create requires either detail_id or group_id")
        }
        let fields = GameCenterActivitiesAPI.Activities.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier"),
            activityType: optionalString(params, "activity_type"),
            eventStartDate: optionalISODate(params, "event_start_date"),
            eventEndDate: optionalISODate(params, "event_end_date")
        )
        let activity = try await api.activities.create(detailID: detailID, groupID: groupID, fields: fields)
        return try jsonText(activity)
    }

    private static func handleActivitiesUpdate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterActivitiesAPI.Activities.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier"),
            activityType: optionalString(params, "activity_type"),
            eventStartDate: optionalISODate(params, "event_start_date"),
            eventEndDate: optionalISODate(params, "event_end_date")
        )
        let activity = try await api.activities.update(id: id, fields: fields)
        return try jsonText(activity)
    }

    private static func handleActivitiesArchive(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let archived = optionalBool(params, "archived") ?? true
        let activity = try await api.activities.archive(id: id, archived: archived)
        return try jsonText(activity)
    }

    private static func handleActivitiesDelete(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.activities.delete(id: id)
        return ackResult("Deleted gameCenterActivity \(id)")
    }

    // MARK: - Handlers: Activity localizations

    private static func handleActivityLocalizationsList(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let activityID = try requireString(params, "activity_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.activityLocalizations.list(
            activityID: activityID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleActivityLocalizationsGet(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let loc = try await api.activityLocalizations.get(id: id)
        return try jsonText(loc)
    }

    private static func handleActivityLocalizationsCreate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let activityID = try requireString(params, "activity_id")
        let locale = try requireString(params, "locale")
        let fields = GameCenterActivitiesAPI.ActivityLocalizations.Fields(
            name: optionalString(params, "name"),
            subtitle: optionalString(params, "subtitle"),
            activityDescription: optionalString(params, "activity_description")
        )
        let loc = try await api.activityLocalizations.create(
            activityID: activityID, locale: locale, fields: fields
        )
        return try jsonText(loc)
    }

    private static func handleActivityLocalizationsUpdate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterActivitiesAPI.ActivityLocalizations.Fields(
            name: optionalString(params, "name"),
            subtitle: optionalString(params, "subtitle"),
            activityDescription: optionalString(params, "activity_description")
        )
        let loc = try await api.activityLocalizations.update(id: id, fields: fields)
        return try jsonText(loc)
    }

    private static func handleActivityLocalizationsDelete(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.activityLocalizations.delete(id: id)
        return ackResult("Deleted gameCenterActivityLocalization \(id)")
    }

    // MARK: - Handlers: Activity images

    private static func handleActivityImagesList(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let limit = optionalInt(params, "limit") ?? 50
        let cursor = optionalString(params, "cursor")
        let page = try await api.activityImages.list(
            localizationID: localizationID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleActivityImagesGet(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let image = try await api.activityImages.get(id: id)
        return try jsonText(image)
    }

    private static func handleActivityImagesUpload(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let path = try requireString(params, "file_path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let image = try await api.activityImages.upload(localizationID: localizationID, fileURL: url)
        return try jsonText(image)
    }

    private static func handleActivityImagesUpdate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fileName = optionalString(params, "file_name")
        let image = try await api.activityImages.update(id: id, fileName: fileName)
        return try jsonText(image)
    }

    private static func handleActivityImagesDelete(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.activityImages.delete(id: id)
        return ackResult("Deleted gameCenterActivityImage \(id)")
    }

    // MARK: - Handlers: Activity versions

    private static func handleActivityVersionsList(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let activityID = try requireString(params, "activity_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.activityVersions.list(
            activityID: activityID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleActivityVersionsGet(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let version = try await api.activityVersions.get(id: id)
        return try jsonText(version)
    }

    private static func handleActivityVersionsCreate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let activityID = try requireString(params, "activity_id")
        let appVersionID = optionalString(params, "app_version_id")
        let fields = GameCenterActivitiesAPI.ActivityVersions.Fields(
            live: optionalBool(params, "live")
        )
        let version = try await api.activityVersions.create(
            activityID: activityID, appVersionID: appVersionID, fields: fields
        )
        return try jsonText(version)
    }

    private static func handleActivityVersionsUpdate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterActivitiesAPI.ActivityVersions.Fields(
            live: optionalBool(params, "live")
        )
        let version = try await api.activityVersions.update(id: id, fields: fields)
        return try jsonText(version)
    }

    // MARK: - Handlers: Challenges

    private static func handleChallengesList(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        if let appID = optionalString(params, "app_id") {
            let page = try await api.challenges.listForApp(appID: appID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let detailID = optionalString(params, "detail_id") {
            let page = try await api.challenges.listForDetail(detailID: detailID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let groupID = optionalString(params, "group_id") {
            let page = try await api.challenges.listForGroup(groupID: groupID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        return errorResult("gc_challenges_list requires one of app_id, detail_id, or group_id")
    }

    private static func handleChallengesGet(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let challenge = try await api.challenges.get(id: id)
        return try jsonText(challenge)
    }

    private static func handleChallengesCreate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let detailID = optionalString(params, "detail_id")
        let groupID = optionalString(params, "group_id")
        guard detailID != nil || groupID != nil else {
            return errorResult("gc_challenges_create requires either detail_id or group_id")
        }
        let fields = GameCenterActivitiesAPI.Challenges.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier"),
            challengeType: optionalString(params, "challenge_type")
        )
        let challenge = try await api.challenges.create(
            detailID: detailID, groupID: groupID,
            leaderboardID: optionalString(params, "leaderboard_id"),
            fields: fields
        )
        return try jsonText(challenge)
    }

    private static func handleChallengesUpdate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterActivitiesAPI.Challenges.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier"),
            challengeType: optionalString(params, "challenge_type")
        )
        let challenge = try await api.challenges.update(id: id, fields: fields)
        return try jsonText(challenge)
    }

    private static func handleChallengesArchive(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let archived = optionalBool(params, "archived") ?? true
        let challenge = try await api.challenges.archive(id: id, archived: archived)
        return try jsonText(challenge)
    }

    private static func handleChallengesDelete(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.challenges.delete(id: id)
        return ackResult("Deleted gameCenterChallenge \(id)")
    }

    // MARK: - Handlers: Challenge localizations

    private static func handleChallengeLocalizationsList(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let challengeID = try requireString(params, "challenge_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.challengeLocalizations.list(
            challengeID: challengeID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleChallengeLocalizationsGet(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let loc = try await api.challengeLocalizations.get(id: id)
        return try jsonText(loc)
    }

    private static func handleChallengeLocalizationsCreate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let challengeID = try requireString(params, "challenge_id")
        let locale = try requireString(params, "locale")
        let fields = GameCenterActivitiesAPI.ChallengeLocalizations.Fields(
            name: optionalString(params, "name"),
            subtitle: optionalString(params, "subtitle"),
            challengeDescription: optionalString(params, "challenge_description")
        )
        let loc = try await api.challengeLocalizations.create(
            challengeID: challengeID, locale: locale, fields: fields
        )
        return try jsonText(loc)
    }

    private static func handleChallengeLocalizationsUpdate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterActivitiesAPI.ChallengeLocalizations.Fields(
            name: optionalString(params, "name"),
            subtitle: optionalString(params, "subtitle"),
            challengeDescription: optionalString(params, "challenge_description")
        )
        let loc = try await api.challengeLocalizations.update(id: id, fields: fields)
        return try jsonText(loc)
    }

    private static func handleChallengeLocalizationsDelete(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.challengeLocalizations.delete(id: id)
        return ackResult("Deleted gameCenterChallengeLocalization \(id)")
    }

    // MARK: - Handlers: Challenge images

    private static func handleChallengeImagesList(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let limit = optionalInt(params, "limit") ?? 50
        let cursor = optionalString(params, "cursor")
        let page = try await api.challengeImages.list(
            localizationID: localizationID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleChallengeImagesGet(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let image = try await api.challengeImages.get(id: id)
        return try jsonText(image)
    }

    private static func handleChallengeImagesUpload(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let path = try requireString(params, "file_path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let image = try await api.challengeImages.upload(localizationID: localizationID, fileURL: url)
        return try jsonText(image)
    }

    private static func handleChallengeImagesUpdate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fileName = optionalString(params, "file_name")
        let image = try await api.challengeImages.update(id: id, fileName: fileName)
        return try jsonText(image)
    }

    private static func handleChallengeImagesDelete(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.challengeImages.delete(id: id)
        return ackResult("Deleted gameCenterChallengeImage \(id)")
    }

    // MARK: - Handlers: Challenge versions

    private static func handleChallengeVersionsList(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let challengeID = try requireString(params, "challenge_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.challengeVersions.list(
            challengeID: challengeID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleChallengeVersionsGet(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let version = try await api.challengeVersions.get(id: id)
        return try jsonText(version)
    }

    private static func handleChallengeVersionsCreate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let challengeID = try requireString(params, "challenge_id")
        let appVersionID = optionalString(params, "app_version_id")
        let version = try await api.challengeVersions.create(
            challengeID: challengeID, appVersionID: appVersionID
        )
        return try jsonText(version)
    }

    // MARK: - Handlers: V2 versioning

    private static func handleAchievementVersionsV2List(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let achievementID = try requireString(params, "achievement_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.achievementVersionsV2.list(
            achievementID: achievementID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleAchievementVersionsV2Get(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let version = try await api.achievementVersionsV2.get(id: id)
        return try jsonText(version)
    }

    private static func handleAchievementVersionsV2Create(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let achievementID = try requireString(params, "achievement_id")
        let appVersionID = optionalString(params, "app_version_id")
        let version = try await api.achievementVersionsV2.create(
            achievementID: achievementID, appVersionID: appVersionID
        )
        return try jsonText(version)
    }

    private static func handleLeaderboardVersionsV2List(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let leaderboardID = try requireString(params, "leaderboard_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardVersionsV2.list(
            leaderboardID: leaderboardID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardVersionsV2Get(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let version = try await api.leaderboardVersionsV2.get(id: id)
        return try jsonText(version)
    }

    private static func handleLeaderboardVersionsV2Create(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let leaderboardID = try requireString(params, "leaderboard_id")
        let appVersionID = optionalString(params, "app_version_id")
        let version = try await api.leaderboardVersionsV2.create(
            leaderboardID: leaderboardID, appVersionID: appVersionID
        )
        return try jsonText(version)
    }

    private static func handleLeaderboardSetVersionsV2List(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let leaderboardSetID = try requireString(params, "leaderboard_set_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardSetVersionsV2.list(
            leaderboardSetID: leaderboardSetID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardSetVersionsV2Get(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let version = try await api.leaderboardSetVersionsV2.get(id: id)
        return try jsonText(version)
    }

    private static func handleLeaderboardSetVersionsV2Create(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let leaderboardSetID = try requireString(params, "leaderboard_set_id")
        let appVersionID = optionalString(params, "app_version_id")
        let version = try await api.leaderboardSetVersionsV2.create(
            leaderboardSetID: leaderboardSetID, appVersionID: appVersionID
        )
        return try jsonText(version)
    }

    // MARK: - Handlers: Sandbox-only submissions

    private static func handleLeaderboardEntrySubmissionsCreate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let leaderboardID = try requireString(params, "leaderboard_id")
        let playerID = try requireString(params, "player_id")
        let score = try requireString(params, "score")
        let context = optionalString(params, "context")
        let submission = try await api.leaderboardEntrySubmissions.create(
            leaderboardID: leaderboardID, playerID: playerID, score: score, context: context
        )
        return try jsonText(submission)
    }

    private static func handlePlayerAchievementSubmissionsCreate(
        _ params: CallTool.Parameters, api: GameCenterActivitiesAPI
    ) async throws -> CallTool.Result {
        let achievementID = try requireString(params, "achievement_id")
        let playerID = try requireString(params, "player_id")
        let percentComplete = try requireDouble(params, "percent_complete")
        let submission = try await api.playerAchievementSubmissions.create(
            achievementID: achievementID, playerID: playerID, percentComplete: percentComplete
        )
        return try jsonText(submission)
    }
}
