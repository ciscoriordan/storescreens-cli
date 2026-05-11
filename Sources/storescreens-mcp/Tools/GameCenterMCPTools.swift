import MCP
import Foundation
import StorescreensCore

/// MCP tool surface for App Store Connect Game Center endpoints.
///
/// Every tool is a thin wrapper around a `GameCenterAPI` namespace method.
/// Inputs arrive as JSON arguments, outputs are pretty-printed JSON text
/// content so AI agents get a stable, machine-readable response shape without
/// having to construct raw HTTP requests against Apple's API.
///
/// Tool naming convention: `gc_<resource>_<op>` (snake_case). Plug into the
/// MCP dispatcher in `Main.swift` with a `params.name.hasPrefix("gc_")` check
/// that forwards to `GameCenterMCPTools.handle(params)`.
enum GameCenterMCPTools {

    // MARK: - Tool definitions

    static let tools: [Tool] = [

        // Details ---------------------------------------------------------

        Tool(
            name: "gc_details_get_for_app",
            description: "Get the gameCenterDetail attached to an app. Returns null if Game Center has not been enabled for the app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string"), "description": .string("Numeric ASC app id")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "gc_details_get",
            description: "Get a gameCenterDetail by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_details_update",
            description: "PATCH the gameCenterDetail attributes (arcadeEnabled, challengeEnabled). Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "arcade_enabled": .object(["type": .string("boolean")]),
                    "challenge_enabled": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // App Versions ----------------------------------------------------

        Tool(
            name: "gc_app_versions_list",
            description: "List gameCenterAppVersions attached to a gameCenterDetail. Used for staging releases of achievements / leaderboards per app version.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "detail_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("detail_id")]),
            ])
        ),
        Tool(
            name: "gc_app_versions_get",
            description: "Get a gameCenterAppVersion by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_app_versions_create",
            description: "Create a new gameCenterAppVersion under a gameCenterDetail. Optionally relate it to an appStoreVersion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "detail_id": .object(["type": .string("string")]),
                    "app_store_version_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("detail_id")]),
            ])
        ),
        Tool(
            name: "gc_app_versions_update",
            description: "PATCH a gameCenterAppVersion. Currently only `live` is settable.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "live": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_app_versions_delete",
            description: "Delete a gameCenterAppVersion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Groups ----------------------------------------------------------

        Tool(
            name: "gc_groups_list",
            description: "List Game Center groups (cross-app containers for shared achievements / leaderboards).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "gc_groups_get",
            description: "Get a gameCenterGroup by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_groups_create",
            description: "Create a gameCenterGroup with referenceName + groupId (the Game Center identifier shared across apps).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "reference_name": .object(["type": .string("string")]),
                    "group_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("reference_name"), .string("group_id")]),
            ])
        ),
        Tool(
            name: "gc_groups_update",
            description: "Rename a gameCenterGroup. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_groups_delete",
            description: "Delete a gameCenterGroup.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_groups_add_details",
            description: "Attach one or more gameCenterDetails (apps) to a group.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_id": .object(["type": .string("string")]),
                    "detail_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("group_id"), .string("detail_ids")]),
            ])
        ),

        // Group localizations --------------------------------------------

        Tool(
            name: "gc_group_localizations_list",
            description: "List per-locale display-name records for a Game Center group.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("group_id")]),
            ])
        ),
        Tool(
            name: "gc_group_localizations_get",
            description: "Get a gameCenterGroupLocalization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_group_localizations_create",
            description: "Create a new locale entry for a Game Center group.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string"), "description": .string("BCP-47 locale code, e.g. en-US")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("group_id"), .string("locale"), .string("name")]),
            ])
        ),
        Tool(
            name: "gc_group_localizations_update",
            description: "Update the localized name of a group locale entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_group_localizations_delete",
            description: "Delete a localized name entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Achievements ---------------------------------------------------

        Tool(
            name: "gc_achievements_list",
            description: "List achievements for an app, gameCenterDetail, or gameCenterGroup. Supply exactly one of app_id, detail_id, or group_id.",
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
            name: "gc_achievements_get",
            description: "Get a gameCenterAchievement by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_achievements_create",
            description: "Create an achievement under a gameCenterDetail or a gameCenterGroup.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "detail_id": .object(["type": .string("string")]),
                    "group_id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                    "points": .object(["type": .string("integer")]),
                    "show_before_earned": .object(["type": .string("boolean")]),
                    "repeatable": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("reference_name"), .string("vendor_identifier"), .string("points")]),
            ])
        ),
        Tool(
            name: "gc_achievements_update",
            description: "PATCH an achievement. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                    "points": .object(["type": .string("integer")]),
                    "show_before_earned": .object(["type": .string("boolean")]),
                    "repeatable": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_achievements_archive",
            description: "Toggle `archived` on an achievement to hide it from the Game Center catalog.",
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
            name: "gc_achievements_delete",
            description: "Delete an achievement.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Achievement localizations --------------------------------------

        Tool(
            name: "gc_achievement_localizations_list",
            description: "List per-locale title + description records for an achievement.",
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
            name: "gc_achievement_localizations_get",
            description: "Get a gameCenterAchievementLocalization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_achievement_localizations_create",
            description: "Create a locale entry for an achievement with name and description text.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "achievement_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "before_earned_description": .object(["type": .string("string")]),
                    "after_earned_description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("achievement_id"), .string("locale")]),
            ])
        ),
        Tool(
            name: "gc_achievement_localizations_update",
            description: "Update fields on an achievement locale entry. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "before_earned_description": .object(["type": .string("string")]),
                    "after_earned_description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_achievement_localizations_delete",
            description: "Delete an achievement locale entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Achievement images --------------------------------------------

        Tool(
            name: "gc_achievement_images_list",
            description: "List achievement icon images attached to a per-locale achievement record.",
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
            name: "gc_achievement_images_get",
            description: "Get a gameCenterAchievementImage by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_achievement_images_upload",
            description: "Upload an achievement icon image. Runs the full 3-phase reservation + chunk PUT + checksum confirm flow.",
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
            name: "gc_achievement_images_update",
            description: "PATCH an achievement image's metadata (currently just fileName). Nil fields stay untouched.",
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
            name: "gc_achievement_images_delete",
            description: "Delete an achievement image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Achievement releases ------------------------------------------

        Tool(
            name: "gc_achievement_releases_list",
            description: "List achievement releases (staging records) attached to a gameCenterAppVersion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_version_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_version_id")]),
            ])
        ),
        Tool(
            name: "gc_achievement_releases_get",
            description: "Get a gameCenterAchievementRelease by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_achievement_releases_create",
            description: "Stage an achievement for a specific gameCenterAppVersion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_version_id": .object(["type": .string("string")]),
                    "achievement_id": .object(["type": .string("string")]),
                    "live": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("app_version_id"), .string("achievement_id")]),
            ])
        ),
        Tool(
            name: "gc_achievement_releases_update",
            description: "Flip the `live` flag on a staged achievement release.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "live": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_achievement_releases_delete",
            description: "Detach an achievement from a gameCenterAppVersion staging plan.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Leaderboards --------------------------------------------------

        Tool(
            name: "gc_leaderboards_list",
            description: "List leaderboards for an app, gameCenterDetail, or gameCenterGroup. Supply exactly one of app_id, detail_id, or group_id.",
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
            name: "gc_leaderboards_get",
            description: "Get a gameCenterLeaderboard by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboards_create",
            description: "Create a leaderboard under a gameCenterDetail or a gameCenterGroup.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "detail_id": .object(["type": .string("string")]),
                    "group_id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                    "default_formatter": .object(["type": .string("string")]),
                    "submission_type": .object(["type": .string("string"), "description": .string("BEST_SCORE or MOST_RECENT_SCORE")]),
                    "score_sort_type": .object(["type": .string("string"), "description": .string("ASCENDING or DESCENDING")]),
                    "score_range_start": .object(["type": .string("string")]),
                    "score_range_end": .object(["type": .string("string")]),
                    "recurrence_duration": .object(["type": .string("string")]),
                    "recurrence_rule": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("reference_name"), .string("vendor_identifier")]),
            ])
        ),
        Tool(
            name: "gc_leaderboards_update",
            description: "PATCH a leaderboard. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                    "default_formatter": .object(["type": .string("string")]),
                    "submission_type": .object(["type": .string("string")]),
                    "score_sort_type": .object(["type": .string("string")]),
                    "score_range_start": .object(["type": .string("string")]),
                    "score_range_end": .object(["type": .string("string")]),
                    "recurrence_duration": .object(["type": .string("string")]),
                    "recurrence_rule": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboards_archive",
            description: "Toggle `archived` on a leaderboard.",
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
            name: "gc_leaderboards_delete",
            description: "Delete a leaderboard.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Leaderboard localizations -------------------------------------

        Tool(
            name: "gc_leaderboard_localizations_list",
            description: "List per-locale records for a leaderboard.",
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
            name: "gc_leaderboard_localizations_get",
            description: "Get a gameCenterLeaderboardLocalization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_localizations_create",
            description: "Create a locale entry for a leaderboard.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "leaderboard_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "formatter_override": .object(["type": .string("string")]),
                    "formatter_suffix": .object(["type": .string("string")]),
                    "formatter_suffix_singular": .object(["type": .string("string")]),
                    "score_format": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("leaderboard_id"), .string("locale")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_localizations_update",
            description: "Update a leaderboard locale entry. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "formatter_override": .object(["type": .string("string")]),
                    "formatter_suffix": .object(["type": .string("string")]),
                    "formatter_suffix_singular": .object(["type": .string("string")]),
                    "score_format": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_localizations_delete",
            description: "Delete a leaderboard locale entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Leaderboard images --------------------------------------------

        Tool(
            name: "gc_leaderboard_images_list",
            description: "List leaderboard icon images attached to a leaderboard locale entry.",
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
            name: "gc_leaderboard_images_get",
            description: "Get a gameCenterLeaderboardImage by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_images_upload",
            description: "Upload a leaderboard icon. Runs the full 3-phase reservation + chunk PUT + checksum confirm flow.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localization_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("localization_id"), .string("file_path")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_images_update",
            description: "PATCH a leaderboard image's metadata.",
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
            name: "gc_leaderboard_images_delete",
            description: "Delete a leaderboard image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Leaderboard releases ------------------------------------------

        Tool(
            name: "gc_leaderboard_releases_list",
            description: "List leaderboard releases (staging records) attached to a gameCenterAppVersion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_version_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_version_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_releases_get",
            description: "Get a gameCenterLeaderboardRelease by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_releases_create",
            description: "Stage a leaderboard for a specific gameCenterAppVersion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_version_id": .object(["type": .string("string")]),
                    "leaderboard_id": .object(["type": .string("string")]),
                    "live": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("app_version_id"), .string("leaderboard_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_releases_update",
            description: "Flip the `live` flag on a staged leaderboard release.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "live": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_releases_delete",
            description: "Detach a leaderboard from a gameCenterAppVersion staging plan.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Leaderboard sets ---------------------------------------------

        Tool(
            name: "gc_leaderboard_sets_list",
            description: "List leaderboard sets for an app, gameCenterDetail, or gameCenterGroup. Supply exactly one of app_id, detail_id, or group_id.",
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
            name: "gc_leaderboard_sets_get",
            description: "Get a gameCenterLeaderboardSet by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_sets_create",
            description: "Create a leaderboard set under a gameCenterDetail or a gameCenterGroup.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "detail_id": .object(["type": .string("string")]),
                    "group_id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("reference_name"), .string("vendor_identifier")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_sets_update",
            description: "PATCH a leaderboard set. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "vendor_identifier": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_sets_archive",
            description: "Toggle `archived` on a leaderboard set.",
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
            name: "gc_leaderboard_sets_delete",
            description: "Delete a leaderboard set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Leaderboard set localizations --------------------------------

        Tool(
            name: "gc_leaderboard_set_localizations_list",
            description: "List per-locale records for a leaderboard set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "set_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("set_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_localizations_get",
            description: "Get a gameCenterLeaderboardSetLocalization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_localizations_create",
            description: "Create a locale entry for a leaderboard set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "set_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("set_id"), .string("locale"), .string("name")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_localizations_update",
            description: "Update the localized name of a leaderboard set locale entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_localizations_delete",
            description: "Delete a leaderboard set locale entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Leaderboard set images ---------------------------------------

        Tool(
            name: "gc_leaderboard_set_images_list",
            description: "List images attached to a leaderboard set locale entry.",
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
            name: "gc_leaderboard_set_images_get",
            description: "Get a gameCenterLeaderboardSetImage by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_images_upload",
            description: "Upload a leaderboard set image. Runs the full 3-phase reservation + chunk PUT + checksum confirm flow.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localization_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("localization_id"), .string("file_path")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_images_update",
            description: "PATCH a leaderboard set image's metadata.",
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
            name: "gc_leaderboard_set_images_delete",
            description: "Delete a leaderboard set image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Leaderboard set members --------------------------------------

        Tool(
            name: "gc_leaderboard_set_members_list",
            description: "List leaderboards inside a leaderboard set (as member records).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "set_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("set_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_members_get",
            description: "Get a gameCenterLeaderboardSetMember by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_members_create",
            description: "Add a leaderboard to a leaderboard set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "set_id": .object(["type": .string("string")]),
                    "leaderboard_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("set_id"), .string("leaderboard_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_members_delete",
            description: "Remove a member record from a leaderboard set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_members_reorder",
            description: "Rewrite the order of leaderboards inside a set. `leaderboard_ids` is the new ordered list of leaderboard ids.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "set_id": .object(["type": .string("string")]),
                    "leaderboard_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("set_id"), .string("leaderboard_ids")]),
            ])
        ),

        // Leaderboard set member localizations -------------------------

        Tool(
            name: "gc_leaderboard_set_member_localizations_list",
            description: "List per-locale name override entries on a leaderboard set member.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "member_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("member_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_member_localizations_get",
            description: "Get a gameCenterLeaderboardSetMemberLocalization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_member_localizations_create",
            description: "Add a locale name override to a leaderboard set member.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "member_id": .object(["type": .string("string")]),
                    "locale": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("member_id"), .string("locale"), .string("name")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_member_localizations_update",
            description: "Update a member localization's name.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_member_localizations_delete",
            description: "Delete a member localization entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Leaderboard set releases -------------------------------------

        Tool(
            name: "gc_leaderboard_set_releases_list",
            description: "List leaderboard set releases (staging records) attached to a gameCenterAppVersion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_version_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_version_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_releases_get",
            description: "Get a gameCenterLeaderboardSetRelease by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_releases_create",
            description: "Stage a leaderboard set for a specific gameCenterAppVersion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_version_id": .object(["type": .string("string")]),
                    "leaderboard_set_id": .object(["type": .string("string")]),
                    "live": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("app_version_id"), .string("leaderboard_set_id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_releases_update",
            description: "Flip the `live` flag on a staged leaderboard set release.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "live": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_leaderboard_set_releases_delete",
            description: "Detach a leaderboard set from a gameCenterAppVersion staging plan.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Matchmaking queues ------------------------------------------

        Tool(
            name: "gc_matchmaking_queues_list",
            description: "List Game Center matchmaking queues for an app.",
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
            name: "gc_matchmaking_queues_get",
            description: "Get a gameCenterMatchmakingQueue by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_queues_create",
            description: "Create a matchmaking queue on an app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "classic_matchmaking_bundle_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "experiment_rule_set_id": .object(["type": .string("string")]),
                    "experiment_rule_set_traffic_share": .object(["type": .string("integer")]),
                    "rule_set_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id"), .string("reference_name")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_queues_update",
            description: "PATCH a matchmaking queue. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "classic_matchmaking_bundle_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "experiment_rule_set_id": .object(["type": .string("string")]),
                    "experiment_rule_set_traffic_share": .object(["type": .string("integer")]),
                    "rule_set_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_queues_delete",
            description: "Delete a matchmaking queue.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_queues_test_match",
            description: "Submit a JSON DSL payload to the queue-test endpoint. Returns Apple's serialized match-result.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "queue_id": .object(["type": .string("string")]),
                    "matchmaking_requests": .object(["type": .string("string"), "description": .string("Apple's matchmakingRequests JSON DSL, encoded as a string")]),
                ]),
                "required": .array([.string("queue_id"), .string("matchmaking_requests")]),
            ])
        ),

        // Matchmaking rule sets ---------------------------------------

        Tool(
            name: "gc_matchmaking_rule_sets_list",
            description: "List rule sets attached to a matchmaking queue.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "queue_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("queue_id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_rule_sets_get",
            description: "Get a gameCenterMatchmakingRuleSet by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_rule_sets_create",
            description: "Create a rule set attached to a queue.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "queue_id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "rule_language_version": .object(["type": .string("integer")]),
                    "min_players": .object(["type": .string("integer")]),
                    "max_players": .object(["type": .string("integer")]),
                    "teams": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("queue_id"), .string("reference_name")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_rule_sets_update",
            description: "PATCH a rule set. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "rule_language_version": .object(["type": .string("integer")]),
                    "min_players": .object(["type": .string("integer")]),
                    "max_players": .object(["type": .string("integer")]),
                    "teams": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_rule_sets_delete",
            description: "Delete a rule set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_rule_sets_test_match",
            description: "Submit a JSON DSL payload to the rule-set match-test endpoint.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rule_set_id": .object(["type": .string("string")]),
                    "matchmaking_requests": .object(["type": .string("string"), "description": .string("Apple's matchmakingRequests JSON DSL, encoded as a string")]),
                ]),
                "required": .array([.string("rule_set_id"), .string("matchmaking_requests")]),
            ])
        ),

        // Matchmaking rules -------------------------------------------

        Tool(
            name: "gc_matchmaking_rules_list",
            description: "List individual rules attached to a rule set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rule_set_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("rule_set_id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_rules_get",
            description: "Get a gameCenterMatchmakingRule by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_rules_create",
            description: "Create a matchmaking rule on a rule set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rule_set_id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                    "type": .object(["type": .string("string")]),
                    "expression": .object(["type": .string("string"), "description": .string("Apple's rule DSL expression")]),
                    "weight": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("rule_set_id"), .string("reference_name"), .string("type"), .string("expression")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_rules_update",
            description: "PATCH a rule. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                    "type": .object(["type": .string("string")]),
                    "expression": .object(["type": .string("string")]),
                    "weight": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_rules_delete",
            description: "Delete a matchmaking rule.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // Matchmaking team configurations -----------------------------

        Tool(
            name: "gc_matchmaking_team_configurations_list",
            description: "List team configurations attached to a rule set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rule_set_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("rule_set_id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_team_configurations_get",
            description: "Get a gameCenterMatchmakingTeamConfiguration by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_team_configurations_create",
            description: "Create a team configuration on a rule set.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rule_set_id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "min_players": .object(["type": .string("integer")]),
                    "max_players": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("rule_set_id"), .string("reference_name")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_team_configurations_update",
            description: "PATCH a team configuration. Nil fields stay untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "reference_name": .object(["type": .string("string")]),
                    "min_players": .object(["type": .string("integer")]),
                    "max_players": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "gc_matchmaking_team_configurations_delete",
            description: "Delete a team configuration.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
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
        let api = GameCenterAPI(client: client)

        do {
            switch params.name {

            // Details
            case "gc_details_get_for_app":   return try await handleDetailsGetForApp(params, api: api)
            case "gc_details_get":           return try await handleDetailsGet(params, api: api)
            case "gc_details_update":        return try await handleDetailsUpdate(params, api: api)

            // App Versions
            case "gc_app_versions_list":     return try await handleAppVersionsList(params, api: api)
            case "gc_app_versions_get":      return try await handleAppVersionsGet(params, api: api)
            case "gc_app_versions_create":   return try await handleAppVersionsCreate(params, api: api)
            case "gc_app_versions_update":   return try await handleAppVersionsUpdate(params, api: api)
            case "gc_app_versions_delete":   return try await handleAppVersionsDelete(params, api: api)

            // Groups
            case "gc_groups_list":           return try await handleGroupsList(params, api: api)
            case "gc_groups_get":            return try await handleGroupsGet(params, api: api)
            case "gc_groups_create":         return try await handleGroupsCreate(params, api: api)
            case "gc_groups_update":         return try await handleGroupsUpdate(params, api: api)
            case "gc_groups_delete":         return try await handleGroupsDelete(params, api: api)
            case "gc_groups_add_details":    return try await handleGroupsAddDetails(params, api: api)

            // Group localizations
            case "gc_group_localizations_list":   return try await handleGroupLocalizationsList(params, api: api)
            case "gc_group_localizations_get":    return try await handleGroupLocalizationsGet(params, api: api)
            case "gc_group_localizations_create": return try await handleGroupLocalizationsCreate(params, api: api)
            case "gc_group_localizations_update": return try await handleGroupLocalizationsUpdate(params, api: api)
            case "gc_group_localizations_delete": return try await handleGroupLocalizationsDelete(params, api: api)

            // Achievements
            case "gc_achievements_list":     return try await handleAchievementsList(params, api: api)
            case "gc_achievements_get":      return try await handleAchievementsGet(params, api: api)
            case "gc_achievements_create":   return try await handleAchievementsCreate(params, api: api)
            case "gc_achievements_update":   return try await handleAchievementsUpdate(params, api: api)
            case "gc_achievements_archive":  return try await handleAchievementsArchive(params, api: api)
            case "gc_achievements_delete":   return try await handleAchievementsDelete(params, api: api)

            // Achievement localizations
            case "gc_achievement_localizations_list":   return try await handleAchievementLocalizationsList(params, api: api)
            case "gc_achievement_localizations_get":    return try await handleAchievementLocalizationsGet(params, api: api)
            case "gc_achievement_localizations_create": return try await handleAchievementLocalizationsCreate(params, api: api)
            case "gc_achievement_localizations_update": return try await handleAchievementLocalizationsUpdate(params, api: api)
            case "gc_achievement_localizations_delete": return try await handleAchievementLocalizationsDelete(params, api: api)

            // Achievement images
            case "gc_achievement_images_list":   return try await handleAchievementImagesList(params, api: api)
            case "gc_achievement_images_get":    return try await handleAchievementImagesGet(params, api: api)
            case "gc_achievement_images_upload": return try await handleAchievementImagesUpload(params, api: api)
            case "gc_achievement_images_update": return try await handleAchievementImagesUpdate(params, api: api)
            case "gc_achievement_images_delete": return try await handleAchievementImagesDelete(params, api: api)

            // Achievement releases
            case "gc_achievement_releases_list":   return try await handleAchievementReleasesList(params, api: api)
            case "gc_achievement_releases_get":    return try await handleAchievementReleasesGet(params, api: api)
            case "gc_achievement_releases_create": return try await handleAchievementReleasesCreate(params, api: api)
            case "gc_achievement_releases_update": return try await handleAchievementReleasesUpdate(params, api: api)
            case "gc_achievement_releases_delete": return try await handleAchievementReleasesDelete(params, api: api)

            // Leaderboards
            case "gc_leaderboards_list":    return try await handleLeaderboardsList(params, api: api)
            case "gc_leaderboards_get":     return try await handleLeaderboardsGet(params, api: api)
            case "gc_leaderboards_create":  return try await handleLeaderboardsCreate(params, api: api)
            case "gc_leaderboards_update":  return try await handleLeaderboardsUpdate(params, api: api)
            case "gc_leaderboards_archive": return try await handleLeaderboardsArchive(params, api: api)
            case "gc_leaderboards_delete":  return try await handleLeaderboardsDelete(params, api: api)

            // Leaderboard localizations
            case "gc_leaderboard_localizations_list":   return try await handleLeaderboardLocalizationsList(params, api: api)
            case "gc_leaderboard_localizations_get":    return try await handleLeaderboardLocalizationsGet(params, api: api)
            case "gc_leaderboard_localizations_create": return try await handleLeaderboardLocalizationsCreate(params, api: api)
            case "gc_leaderboard_localizations_update": return try await handleLeaderboardLocalizationsUpdate(params, api: api)
            case "gc_leaderboard_localizations_delete": return try await handleLeaderboardLocalizationsDelete(params, api: api)

            // Leaderboard images
            case "gc_leaderboard_images_list":   return try await handleLeaderboardImagesList(params, api: api)
            case "gc_leaderboard_images_get":    return try await handleLeaderboardImagesGet(params, api: api)
            case "gc_leaderboard_images_upload": return try await handleLeaderboardImagesUpload(params, api: api)
            case "gc_leaderboard_images_update": return try await handleLeaderboardImagesUpdate(params, api: api)
            case "gc_leaderboard_images_delete": return try await handleLeaderboardImagesDelete(params, api: api)

            // Leaderboard releases
            case "gc_leaderboard_releases_list":   return try await handleLeaderboardReleasesList(params, api: api)
            case "gc_leaderboard_releases_get":    return try await handleLeaderboardReleasesGet(params, api: api)
            case "gc_leaderboard_releases_create": return try await handleLeaderboardReleasesCreate(params, api: api)
            case "gc_leaderboard_releases_update": return try await handleLeaderboardReleasesUpdate(params, api: api)
            case "gc_leaderboard_releases_delete": return try await handleLeaderboardReleasesDelete(params, api: api)

            // Leaderboard sets
            case "gc_leaderboard_sets_list":    return try await handleLeaderboardSetsList(params, api: api)
            case "gc_leaderboard_sets_get":     return try await handleLeaderboardSetsGet(params, api: api)
            case "gc_leaderboard_sets_create":  return try await handleLeaderboardSetsCreate(params, api: api)
            case "gc_leaderboard_sets_update":  return try await handleLeaderboardSetsUpdate(params, api: api)
            case "gc_leaderboard_sets_archive": return try await handleLeaderboardSetsArchive(params, api: api)
            case "gc_leaderboard_sets_delete":  return try await handleLeaderboardSetsDelete(params, api: api)

            // Leaderboard set localizations
            case "gc_leaderboard_set_localizations_list":   return try await handleLeaderboardSetLocalizationsList(params, api: api)
            case "gc_leaderboard_set_localizations_get":    return try await handleLeaderboardSetLocalizationsGet(params, api: api)
            case "gc_leaderboard_set_localizations_create": return try await handleLeaderboardSetLocalizationsCreate(params, api: api)
            case "gc_leaderboard_set_localizations_update": return try await handleLeaderboardSetLocalizationsUpdate(params, api: api)
            case "gc_leaderboard_set_localizations_delete": return try await handleLeaderboardSetLocalizationsDelete(params, api: api)

            // Leaderboard set images
            case "gc_leaderboard_set_images_list":   return try await handleLeaderboardSetImagesList(params, api: api)
            case "gc_leaderboard_set_images_get":    return try await handleLeaderboardSetImagesGet(params, api: api)
            case "gc_leaderboard_set_images_upload": return try await handleLeaderboardSetImagesUpload(params, api: api)
            case "gc_leaderboard_set_images_update": return try await handleLeaderboardSetImagesUpdate(params, api: api)
            case "gc_leaderboard_set_images_delete": return try await handleLeaderboardSetImagesDelete(params, api: api)

            // Leaderboard set members
            case "gc_leaderboard_set_members_list":    return try await handleLeaderboardSetMembersList(params, api: api)
            case "gc_leaderboard_set_members_get":     return try await handleLeaderboardSetMembersGet(params, api: api)
            case "gc_leaderboard_set_members_create":  return try await handleLeaderboardSetMembersCreate(params, api: api)
            case "gc_leaderboard_set_members_delete":  return try await handleLeaderboardSetMembersDelete(params, api: api)
            case "gc_leaderboard_set_members_reorder": return try await handleLeaderboardSetMembersReorder(params, api: api)

            // Leaderboard set member localizations
            case "gc_leaderboard_set_member_localizations_list":   return try await handleLeaderboardSetMemberLocalizationsList(params, api: api)
            case "gc_leaderboard_set_member_localizations_get":    return try await handleLeaderboardSetMemberLocalizationsGet(params, api: api)
            case "gc_leaderboard_set_member_localizations_create": return try await handleLeaderboardSetMemberLocalizationsCreate(params, api: api)
            case "gc_leaderboard_set_member_localizations_update": return try await handleLeaderboardSetMemberLocalizationsUpdate(params, api: api)
            case "gc_leaderboard_set_member_localizations_delete": return try await handleLeaderboardSetMemberLocalizationsDelete(params, api: api)

            // Leaderboard set releases
            case "gc_leaderboard_set_releases_list":   return try await handleLeaderboardSetReleasesList(params, api: api)
            case "gc_leaderboard_set_releases_get":    return try await handleLeaderboardSetReleasesGet(params, api: api)
            case "gc_leaderboard_set_releases_create": return try await handleLeaderboardSetReleasesCreate(params, api: api)
            case "gc_leaderboard_set_releases_update": return try await handleLeaderboardSetReleasesUpdate(params, api: api)
            case "gc_leaderboard_set_releases_delete": return try await handleLeaderboardSetReleasesDelete(params, api: api)

            // Matchmaking queues
            case "gc_matchmaking_queues_list":       return try await handleMatchmakingQueuesList(params, api: api)
            case "gc_matchmaking_queues_get":        return try await handleMatchmakingQueuesGet(params, api: api)
            case "gc_matchmaking_queues_create":     return try await handleMatchmakingQueuesCreate(params, api: api)
            case "gc_matchmaking_queues_update":     return try await handleMatchmakingQueuesUpdate(params, api: api)
            case "gc_matchmaking_queues_delete":     return try await handleMatchmakingQueuesDelete(params, api: api)
            case "gc_matchmaking_queues_test_match": return try await handleMatchmakingQueuesTestMatch(params, api: api)

            // Matchmaking rule sets
            case "gc_matchmaking_rule_sets_list":       return try await handleMatchmakingRuleSetsList(params, api: api)
            case "gc_matchmaking_rule_sets_get":        return try await handleMatchmakingRuleSetsGet(params, api: api)
            case "gc_matchmaking_rule_sets_create":     return try await handleMatchmakingRuleSetsCreate(params, api: api)
            case "gc_matchmaking_rule_sets_update":     return try await handleMatchmakingRuleSetsUpdate(params, api: api)
            case "gc_matchmaking_rule_sets_delete":     return try await handleMatchmakingRuleSetsDelete(params, api: api)
            case "gc_matchmaking_rule_sets_test_match": return try await handleMatchmakingRuleSetsTestMatch(params, api: api)

            // Matchmaking rules
            case "gc_matchmaking_rules_list":   return try await handleMatchmakingRulesList(params, api: api)
            case "gc_matchmaking_rules_get":    return try await handleMatchmakingRulesGet(params, api: api)
            case "gc_matchmaking_rules_create": return try await handleMatchmakingRulesCreate(params, api: api)
            case "gc_matchmaking_rules_update": return try await handleMatchmakingRulesUpdate(params, api: api)
            case "gc_matchmaking_rules_delete": return try await handleMatchmakingRulesDelete(params, api: api)

            // Matchmaking team configurations
            case "gc_matchmaking_team_configurations_list":   return try await handleMatchmakingTeamConfigurationsList(params, api: api)
            case "gc_matchmaking_team_configurations_get":    return try await handleMatchmakingTeamConfigurationsGet(params, api: api)
            case "gc_matchmaking_team_configurations_create": return try await handleMatchmakingTeamConfigurationsCreate(params, api: api)
            case "gc_matchmaking_team_configurations_update": return try await handleMatchmakingTeamConfigurationsUpdate(params, api: api)
            case "gc_matchmaking_team_configurations_delete": return try await handleMatchmakingTeamConfigurationsDelete(params, api: api)

            default:
                return errorResult("Unknown Game Center tool: \(params.name)")
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
    ) -> [String]? {
        guard let arr = arg(params, key)?.arrayValue else { return nil }
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

    /// Encodable wrapper for paginated responses. Mirrors the shape used by
    /// TestFlight + IAP tools so agents can rely on a stable
    /// `{ data, nextCursor }` envelope regardless of family.
    private struct PageOut<Item: Encodable>: Encodable {
        let data: [Item]
        let nextCursor: String?
    }

    // MARK: - Handlers: Details

    private static func handleDetailsGetForApp(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let detail = try await api.details.getForApp(appID: appID)
        return try jsonText(detail)
    }

    private static func handleDetailsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let detail = try await api.details.get(id: id)
        return try jsonText(detail)
    }

    private static func handleDetailsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let detail = try await api.details.update(
            id: id,
            arcadeEnabled: optionalBool(params, "arcade_enabled"),
            challengeEnabled: optionalBool(params, "challenge_enabled")
        )
        return try jsonText(detail)
    }

    // MARK: - Handlers: AppVersions

    private static func handleAppVersionsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let detailID = try requireString(params, "detail_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.appVersions.list(detailID: detailID, limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleAppVersionsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let appVersion = try await api.appVersions.get(id: id)
        return try jsonText(appVersion)
    }

    private static func handleAppVersionsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let detailID = try requireString(params, "detail_id")
        let asvID = optionalString(params, "app_store_version_id")
        let result = try await api.appVersions.create(detailID: detailID, appStoreVersionID: asvID)
        return try jsonText(result)
    }

    private static func handleAppVersionsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let live = optionalBool(params, "live")
        let result = try await api.appVersions.update(id: id, live: live)
        return try jsonText(result)
    }

    private static func handleAppVersionsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.appVersions.delete(id: id)
        return ackResult("Deleted gameCenterAppVersion \(id)")
    }

    // MARK: - Handlers: Groups

    private static func handleGroupsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.groups.list(limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleGroupsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let group = try await api.groups.get(id: id)
        return try jsonText(group)
    }

    private static func handleGroupsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let referenceName = try requireString(params, "reference_name")
        let groupID = try requireString(params, "group_id")
        let group = try await api.groups.create(referenceName: referenceName, groupID: groupID)
        return try jsonText(group)
    }

    private static func handleGroupsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let referenceName = optionalString(params, "reference_name")
        let group = try await api.groups.update(id: id, referenceName: referenceName)
        return try jsonText(group)
    }

    private static func handleGroupsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.groups.delete(id: id)
        return ackResult("Deleted gameCenterGroup \(id)")
    }

    private static func handleGroupsAddDetails(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let groupID = try requireString(params, "group_id")
        let detailIDs = try requireStringArray(params, "detail_ids")
        try await api.groups.addDetails(groupID: groupID, detailIDs: detailIDs)
        return ackResult("Added \(detailIDs.count) detail(s) to group \(groupID)")
    }

    // MARK: - Handlers: Group localizations

    private static func handleGroupLocalizationsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let groupID = try requireString(params, "group_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.groupLocalizations.list(groupID: groupID, limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleGroupLocalizationsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let loc = try await api.groupLocalizations.get(id: id)
        return try jsonText(loc)
    }

    private static func handleGroupLocalizationsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let groupID = try requireString(params, "group_id")
        let locale = try requireString(params, "locale")
        let name = try requireString(params, "name")
        let loc = try await api.groupLocalizations.create(groupID: groupID, locale: locale, name: name)
        return try jsonText(loc)
    }

    private static func handleGroupLocalizationsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let name = optionalString(params, "name")
        let loc = try await api.groupLocalizations.update(id: id, name: name)
        return try jsonText(loc)
    }

    private static func handleGroupLocalizationsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.groupLocalizations.delete(id: id)
        return ackResult("Deleted gameCenterGroupLocalization \(id)")
    }

    // MARK: - Handlers: Achievements

    private static func handleAchievementsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        if let appID = optionalString(params, "app_id") {
            let page = try await api.achievements.listForApp(appID: appID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let detailID = optionalString(params, "detail_id") {
            let page = try await api.achievements.listForDetail(detailID: detailID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let groupID = optionalString(params, "group_id") {
            let page = try await api.achievements.listForGroup(groupID: groupID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        return errorResult("gc_achievements_list requires one of app_id, detail_id, or group_id")
    }

    private static func handleAchievementsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let result = try await api.achievements.get(id: id)
        return try jsonText(result)
    }

    private static func handleAchievementsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let detailID = optionalString(params, "detail_id")
        let groupID = optionalString(params, "group_id")
        guard detailID != nil || groupID != nil else {
            return errorResult("gc_achievements_create requires either detail_id or group_id")
        }
        let fields = GameCenterAPI.Achievements.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier"),
            points: optionalInt(params, "points"),
            showBeforeEarned: optionalBool(params, "show_before_earned"),
            repeatable: optionalBool(params, "repeatable")
        )
        let result = try await api.achievements.create(detailID: detailID, groupID: groupID, fields: fields)
        return try jsonText(result)
    }

    private static func handleAchievementsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterAPI.Achievements.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier"),
            points: optionalInt(params, "points"),
            showBeforeEarned: optionalBool(params, "show_before_earned"),
            repeatable: optionalBool(params, "repeatable")
        )
        let result = try await api.achievements.update(id: id, fields: fields)
        return try jsonText(result)
    }

    private static func handleAchievementsArchive(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let archived = optionalBool(params, "archived") ?? true
        let result = try await api.achievements.archive(id: id, archived: archived)
        return try jsonText(result)
    }

    private static func handleAchievementsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.achievements.delete(id: id)
        return ackResult("Deleted gameCenterAchievement \(id)")
    }

    // MARK: - Handlers: Achievement localizations

    private static func handleAchievementLocalizationsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let achievementID = try requireString(params, "achievement_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.achievementLocalizations.list(
            achievementID: achievementID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleAchievementLocalizationsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let loc = try await api.achievementLocalizations.get(id: id)
        return try jsonText(loc)
    }

    private static func handleAchievementLocalizationsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let achievementID = try requireString(params, "achievement_id")
        let locale = try requireString(params, "locale")
        let fields = GameCenterAPI.AchievementLocalizations.Fields(
            name: optionalString(params, "name"),
            beforeEarnedDescription: optionalString(params, "before_earned_description"),
            afterEarnedDescription: optionalString(params, "after_earned_description")
        )
        let loc = try await api.achievementLocalizations.create(
            achievementID: achievementID, locale: locale, fields: fields
        )
        return try jsonText(loc)
    }

    private static func handleAchievementLocalizationsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterAPI.AchievementLocalizations.Fields(
            name: optionalString(params, "name"),
            beforeEarnedDescription: optionalString(params, "before_earned_description"),
            afterEarnedDescription: optionalString(params, "after_earned_description")
        )
        let loc = try await api.achievementLocalizations.update(id: id, fields: fields)
        return try jsonText(loc)
    }

    private static func handleAchievementLocalizationsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.achievementLocalizations.delete(id: id)
        return ackResult("Deleted gameCenterAchievementLocalization \(id)")
    }

    // MARK: - Handlers: Achievement images

    private static func handleAchievementImagesList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let limit = optionalInt(params, "limit") ?? 50
        let cursor = optionalString(params, "cursor")
        let page = try await api.achievementImages.list(
            localizationID: localizationID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleAchievementImagesGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let image = try await api.achievementImages.get(id: id)
        return try jsonText(image)
    }

    private static func handleAchievementImagesUpload(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let path = try requireString(params, "file_path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let image = try await api.achievementImages.upload(localizationID: localizationID, fileURL: url)
        return try jsonText(image)
    }

    private static func handleAchievementImagesUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fileName = optionalString(params, "file_name")
        let image = try await api.achievementImages.update(id: id, fileName: fileName)
        return try jsonText(image)
    }

    private static func handleAchievementImagesDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.achievementImages.delete(id: id)
        return ackResult("Deleted gameCenterAchievementImage \(id)")
    }

    // MARK: - Handlers: Achievement releases

    private static func handleAchievementReleasesList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let appVersionID = try requireString(params, "app_version_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.achievementReleases.list(
            appVersionID: appVersionID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleAchievementReleasesGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let release = try await api.achievementReleases.get(id: id)
        return try jsonText(release)
    }

    private static func handleAchievementReleasesCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let appVersionID = try requireString(params, "app_version_id")
        let achievementID = try requireString(params, "achievement_id")
        let live = optionalBool(params, "live")
        let release = try await api.achievementReleases.create(
            appVersionID: appVersionID, achievementID: achievementID, live: live
        )
        return try jsonText(release)
    }

    private static func handleAchievementReleasesUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let live = optionalBool(params, "live")
        let release = try await api.achievementReleases.update(id: id, live: live)
        return try jsonText(release)
    }

    private static func handleAchievementReleasesDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.achievementReleases.delete(id: id)
        return ackResult("Deleted gameCenterAchievementRelease \(id)")
    }

    // MARK: - Handlers: Leaderboards

    private static func handleLeaderboardsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        if let appID = optionalString(params, "app_id") {
            let page = try await api.leaderboards.listForApp(appID: appID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let detailID = optionalString(params, "detail_id") {
            let page = try await api.leaderboards.listForDetail(detailID: detailID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let groupID = optionalString(params, "group_id") {
            let page = try await api.leaderboards.listForGroup(groupID: groupID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        return errorResult("gc_leaderboards_list requires one of app_id, detail_id, or group_id")
    }

    private static func handleLeaderboardsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let leaderboard = try await api.leaderboards.get(id: id)
        return try jsonText(leaderboard)
    }

    private static func handleLeaderboardsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let detailID = optionalString(params, "detail_id")
        let groupID = optionalString(params, "group_id")
        guard detailID != nil || groupID != nil else {
            return errorResult("gc_leaderboards_create requires either detail_id or group_id")
        }
        let fields = GameCenterAPI.Leaderboards.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier"),
            defaultFormatter: optionalString(params, "default_formatter"),
            submissionType: optionalString(params, "submission_type"),
            scoreSortType: optionalString(params, "score_sort_type"),
            scoreRangeStart: optionalString(params, "score_range_start"),
            scoreRangeEnd: optionalString(params, "score_range_end"),
            recurrenceDuration: optionalString(params, "recurrence_duration"),
            recurrenceRule: optionalString(params, "recurrence_rule")
        )
        let result = try await api.leaderboards.create(detailID: detailID, groupID: groupID, fields: fields)
        return try jsonText(result)
    }

    private static func handleLeaderboardsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterAPI.Leaderboards.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier"),
            defaultFormatter: optionalString(params, "default_formatter"),
            submissionType: optionalString(params, "submission_type"),
            scoreSortType: optionalString(params, "score_sort_type"),
            scoreRangeStart: optionalString(params, "score_range_start"),
            scoreRangeEnd: optionalString(params, "score_range_end"),
            recurrenceDuration: optionalString(params, "recurrence_duration"),
            recurrenceRule: optionalString(params, "recurrence_rule")
        )
        let result = try await api.leaderboards.update(id: id, fields: fields)
        return try jsonText(result)
    }

    private static func handleLeaderboardsArchive(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let archived = optionalBool(params, "archived") ?? true
        let result = try await api.leaderboards.archive(id: id, archived: archived)
        return try jsonText(result)
    }

    private static func handleLeaderboardsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboards.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboard \(id)")
    }

    // MARK: - Handlers: Leaderboard localizations

    private static func handleLeaderboardLocalizationsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let leaderboardID = try requireString(params, "leaderboard_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardLocalizations.list(
            leaderboardID: leaderboardID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardLocalizationsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let loc = try await api.leaderboardLocalizations.get(id: id)
        return try jsonText(loc)
    }

    private static func handleLeaderboardLocalizationsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let leaderboardID = try requireString(params, "leaderboard_id")
        let locale = try requireString(params, "locale")
        let fields = GameCenterAPI.LeaderboardLocalizations.Fields(
            name: optionalString(params, "name"),
            formatterOverride: optionalString(params, "formatter_override"),
            formatterSuffix: optionalString(params, "formatter_suffix"),
            formatterSuffixSingular: optionalString(params, "formatter_suffix_singular"),
            scoreFormat: optionalString(params, "score_format")
        )
        let loc = try await api.leaderboardLocalizations.create(
            leaderboardID: leaderboardID, locale: locale, fields: fields
        )
        return try jsonText(loc)
    }

    private static func handleLeaderboardLocalizationsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterAPI.LeaderboardLocalizations.Fields(
            name: optionalString(params, "name"),
            formatterOverride: optionalString(params, "formatter_override"),
            formatterSuffix: optionalString(params, "formatter_suffix"),
            formatterSuffixSingular: optionalString(params, "formatter_suffix_singular"),
            scoreFormat: optionalString(params, "score_format")
        )
        let loc = try await api.leaderboardLocalizations.update(id: id, fields: fields)
        return try jsonText(loc)
    }

    private static func handleLeaderboardLocalizationsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboardLocalizations.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboardLocalization \(id)")
    }

    // MARK: - Handlers: Leaderboard images

    private static func handleLeaderboardImagesList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let limit = optionalInt(params, "limit") ?? 50
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardImages.list(
            localizationID: localizationID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardImagesGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let image = try await api.leaderboardImages.get(id: id)
        return try jsonText(image)
    }

    private static func handleLeaderboardImagesUpload(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let path = try requireString(params, "file_path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let image = try await api.leaderboardImages.upload(localizationID: localizationID, fileURL: url)
        return try jsonText(image)
    }

    private static func handleLeaderboardImagesUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fileName = optionalString(params, "file_name")
        let image = try await api.leaderboardImages.update(id: id, fileName: fileName)
        return try jsonText(image)
    }

    private static func handleLeaderboardImagesDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboardImages.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboardImage \(id)")
    }

    // MARK: - Handlers: Leaderboard releases

    private static func handleLeaderboardReleasesList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let appVersionID = try requireString(params, "app_version_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardReleases.list(
            appVersionID: appVersionID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardReleasesGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let release = try await api.leaderboardReleases.get(id: id)
        return try jsonText(release)
    }

    private static func handleLeaderboardReleasesCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let appVersionID = try requireString(params, "app_version_id")
        let leaderboardID = try requireString(params, "leaderboard_id")
        let live = optionalBool(params, "live")
        let release = try await api.leaderboardReleases.create(
            appVersionID: appVersionID, leaderboardID: leaderboardID, live: live
        )
        return try jsonText(release)
    }

    private static func handleLeaderboardReleasesUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let live = optionalBool(params, "live")
        let release = try await api.leaderboardReleases.update(id: id, live: live)
        return try jsonText(release)
    }

    private static func handleLeaderboardReleasesDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboardReleases.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboardRelease \(id)")
    }

    // MARK: - Handlers: Leaderboard sets

    private static func handleLeaderboardSetsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        if let appID = optionalString(params, "app_id") {
            let page = try await api.leaderboardSets.listForApp(appID: appID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let detailID = optionalString(params, "detail_id") {
            let page = try await api.leaderboardSets.listForDetail(detailID: detailID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        if let groupID = optionalString(params, "group_id") {
            let page = try await api.leaderboardSets.listForGroup(groupID: groupID, limit: limit, cursor: cursor)
            return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
        }
        return errorResult("gc_leaderboard_sets_list requires one of app_id, detail_id, or group_id")
    }

    private static func handleLeaderboardSetsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let result = try await api.leaderboardSets.get(id: id)
        return try jsonText(result)
    }

    private static func handleLeaderboardSetsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let detailID = optionalString(params, "detail_id")
        let groupID = optionalString(params, "group_id")
        guard detailID != nil || groupID != nil else {
            return errorResult("gc_leaderboard_sets_create requires either detail_id or group_id")
        }
        let fields = GameCenterAPI.LeaderboardSets.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier")
        )
        let result = try await api.leaderboardSets.create(detailID: detailID, groupID: groupID, fields: fields)
        return try jsonText(result)
    }

    private static func handleLeaderboardSetsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterAPI.LeaderboardSets.Fields(
            referenceName: optionalString(params, "reference_name"),
            vendorIdentifier: optionalString(params, "vendor_identifier")
        )
        let result = try await api.leaderboardSets.update(id: id, fields: fields)
        return try jsonText(result)
    }

    private static func handleLeaderboardSetsArchive(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let archived = optionalBool(params, "archived") ?? true
        let result = try await api.leaderboardSets.archive(id: id, archived: archived)
        return try jsonText(result)
    }

    private static func handleLeaderboardSetsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboardSets.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboardSet \(id)")
    }

    // MARK: - Handlers: Leaderboard set localizations

    private static func handleLeaderboardSetLocalizationsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let setID = try requireString(params, "set_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardSetLocalizations.list(
            setID: setID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardSetLocalizationsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let loc = try await api.leaderboardSetLocalizations.get(id: id)
        return try jsonText(loc)
    }

    private static func handleLeaderboardSetLocalizationsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let setID = try requireString(params, "set_id")
        let locale = try requireString(params, "locale")
        let name = try requireString(params, "name")
        let loc = try await api.leaderboardSetLocalizations.create(setID: setID, locale: locale, name: name)
        return try jsonText(loc)
    }

    private static func handleLeaderboardSetLocalizationsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let name = optionalString(params, "name")
        let loc = try await api.leaderboardSetLocalizations.update(id: id, name: name)
        return try jsonText(loc)
    }

    private static func handleLeaderboardSetLocalizationsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboardSetLocalizations.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboardSetLocalization \(id)")
    }

    // MARK: - Handlers: Leaderboard set images

    private static func handleLeaderboardSetImagesList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let limit = optionalInt(params, "limit") ?? 50
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardSetImages.list(
            localizationID: localizationID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardSetImagesGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let image = try await api.leaderboardSetImages.get(id: id)
        return try jsonText(image)
    }

    private static func handleLeaderboardSetImagesUpload(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let localizationID = try requireString(params, "localization_id")
        let path = try requireString(params, "file_path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let image = try await api.leaderboardSetImages.upload(localizationID: localizationID, fileURL: url)
        return try jsonText(image)
    }

    private static func handleLeaderboardSetImagesUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fileName = optionalString(params, "file_name")
        let image = try await api.leaderboardSetImages.update(id: id, fileName: fileName)
        return try jsonText(image)
    }

    private static func handleLeaderboardSetImagesDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboardSetImages.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboardSetImage \(id)")
    }

    // MARK: - Handlers: Leaderboard set members

    private static func handleLeaderboardSetMembersList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let setID = try requireString(params, "set_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardSetMembers.list(
            setID: setID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardSetMembersGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let member = try await api.leaderboardSetMembers.get(id: id)
        return try jsonText(member)
    }

    private static func handleLeaderboardSetMembersCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let setID = try requireString(params, "set_id")
        let leaderboardID = try requireString(params, "leaderboard_id")
        let member = try await api.leaderboardSetMembers.create(setID: setID, leaderboardID: leaderboardID)
        return try jsonText(member)
    }

    private static func handleLeaderboardSetMembersDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboardSetMembers.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboardSetMember \(id)")
    }

    private static func handleLeaderboardSetMembersReorder(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let setID = try requireString(params, "set_id")
        let ids = try requireStringArray(params, "leaderboard_ids")
        try await api.leaderboardSetMembers.reorderLeaderboards(setID: setID, leaderboardIDs: ids)
        return ackResult("Reordered \(ids.count) leaderboard(s) inside set \(setID)")
    }

    // MARK: - Handlers: Leaderboard set member localizations

    private static func handleLeaderboardSetMemberLocalizationsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let memberID = try requireString(params, "member_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardSetMemberLocalizations.list(
            memberID: memberID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardSetMemberLocalizationsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let loc = try await api.leaderboardSetMemberLocalizations.get(id: id)
        return try jsonText(loc)
    }

    private static func handleLeaderboardSetMemberLocalizationsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let memberID = try requireString(params, "member_id")
        let locale = try requireString(params, "locale")
        let name = try requireString(params, "name")
        let loc = try await api.leaderboardSetMemberLocalizations.create(
            memberID: memberID, locale: locale, name: name
        )
        return try jsonText(loc)
    }

    private static func handleLeaderboardSetMemberLocalizationsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let name = optionalString(params, "name")
        let loc = try await api.leaderboardSetMemberLocalizations.update(id: id, name: name)
        return try jsonText(loc)
    }

    private static func handleLeaderboardSetMemberLocalizationsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboardSetMemberLocalizations.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboardSetMemberLocalization \(id)")
    }

    // MARK: - Handlers: Leaderboard set releases

    private static func handleLeaderboardSetReleasesList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let appVersionID = try requireString(params, "app_version_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.leaderboardSetReleases.list(
            appVersionID: appVersionID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleLeaderboardSetReleasesGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let release = try await api.leaderboardSetReleases.get(id: id)
        return try jsonText(release)
    }

    private static func handleLeaderboardSetReleasesCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let appVersionID = try requireString(params, "app_version_id")
        let setID = try requireString(params, "leaderboard_set_id")
        let live = optionalBool(params, "live")
        let release = try await api.leaderboardSetReleases.create(
            appVersionID: appVersionID, leaderboardSetID: setID, live: live
        )
        return try jsonText(release)
    }

    private static func handleLeaderboardSetReleasesUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let live = optionalBool(params, "live")
        let release = try await api.leaderboardSetReleases.update(id: id, live: live)
        return try jsonText(release)
    }

    private static func handleLeaderboardSetReleasesDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.leaderboardSetReleases.delete(id: id)
        return ackResult("Deleted gameCenterLeaderboardSetRelease \(id)")
    }

    // MARK: - Handlers: Matchmaking queues

    private static func handleMatchmakingQueuesList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.matchmakingQueues.listForApp(appID: appID, limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleMatchmakingQueuesGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let queue = try await api.matchmakingQueues.get(id: id)
        return try jsonText(queue)
    }

    private static func handleMatchmakingQueuesCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let appID = try requireString(params, "app_id")
        let fields = GameCenterAPI.MatchmakingQueues.Fields(
            referenceName: optionalString(params, "reference_name"),
            classicMatchmakingBundleIDs: optionalStringArray(params, "classic_matchmaking_bundle_ids"),
            experimentRuleSetID: optionalString(params, "experiment_rule_set_id"),
            experimentRuleSetTrafficShare: optionalInt(params, "experiment_rule_set_traffic_share"),
            ruleSetID: optionalString(params, "rule_set_id")
        )
        let queue = try await api.matchmakingQueues.create(appID: appID, fields: fields)
        return try jsonText(queue)
    }

    private static func handleMatchmakingQueuesUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterAPI.MatchmakingQueues.Fields(
            referenceName: optionalString(params, "reference_name"),
            classicMatchmakingBundleIDs: optionalStringArray(params, "classic_matchmaking_bundle_ids"),
            experimentRuleSetID: optionalString(params, "experiment_rule_set_id"),
            experimentRuleSetTrafficShare: optionalInt(params, "experiment_rule_set_traffic_share"),
            ruleSetID: optionalString(params, "rule_set_id")
        )
        let queue = try await api.matchmakingQueues.update(id: id, fields: fields)
        return try jsonText(queue)
    }

    private static func handleMatchmakingQueuesDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.matchmakingQueues.delete(id: id)
        return ackResult("Deleted gameCenterMatchmakingQueue \(id)")
    }

    private static func handleMatchmakingQueuesTestMatch(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let queueID = try requireString(params, "queue_id")
        let payload = try requireString(params, "matchmaking_requests")
        let result = try await api.matchmakingRules.testQueueMatch(
            queueID: queueID, matchmakingRequests: payload
        )
        return try jsonText(result)
    }

    // MARK: - Handlers: Matchmaking rule sets

    private static func handleMatchmakingRuleSetsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let queueID = try requireString(params, "queue_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.matchmakingRuleSets.listForQueue(
            queueID: queueID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleMatchmakingRuleSetsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let ruleSet = try await api.matchmakingRuleSets.get(id: id)
        return try jsonText(ruleSet)
    }

    private static func handleMatchmakingRuleSetsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let queueID = try requireString(params, "queue_id")
        let fields = GameCenterAPI.MatchmakingRuleSets.Fields(
            referenceName: optionalString(params, "reference_name"),
            ruleLanguageVersion: optionalInt(params, "rule_language_version"),
            minPlayers: optionalInt(params, "min_players"),
            maxPlayers: optionalInt(params, "max_players"),
            teams: optionalInt(params, "teams")
        )
        let ruleSet = try await api.matchmakingRuleSets.create(queueID: queueID, fields: fields)
        return try jsonText(ruleSet)
    }

    private static func handleMatchmakingRuleSetsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterAPI.MatchmakingRuleSets.Fields(
            referenceName: optionalString(params, "reference_name"),
            ruleLanguageVersion: optionalInt(params, "rule_language_version"),
            minPlayers: optionalInt(params, "min_players"),
            maxPlayers: optionalInt(params, "max_players"),
            teams: optionalInt(params, "teams")
        )
        let ruleSet = try await api.matchmakingRuleSets.update(id: id, fields: fields)
        return try jsonText(ruleSet)
    }

    private static func handleMatchmakingRuleSetsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.matchmakingRuleSets.delete(id: id)
        return ackResult("Deleted gameCenterMatchmakingRuleSet \(id)")
    }

    private static func handleMatchmakingRuleSetsTestMatch(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let ruleSetID = try requireString(params, "rule_set_id")
        let payload = try requireString(params, "matchmaking_requests")
        let result = try await api.matchmakingRules.testRuleSetMatch(
            ruleSetID: ruleSetID, matchmakingRequests: payload
        )
        return try jsonText(result)
    }

    // MARK: - Handlers: Matchmaking rules

    private static func handleMatchmakingRulesList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let ruleSetID = try requireString(params, "rule_set_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.matchmakingRules.listForRuleSet(
            ruleSetID: ruleSetID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleMatchmakingRulesGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let rule = try await api.matchmakingRules.get(id: id)
        return try jsonText(rule)
    }

    private static func handleMatchmakingRulesCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let ruleSetID = try requireString(params, "rule_set_id")
        let fields = GameCenterAPI.MatchmakingRules.Fields(
            referenceName: optionalString(params, "reference_name"),
            description: optionalString(params, "description"),
            type: optionalString(params, "type"),
            expression: optionalString(params, "expression"),
            weight: optionalDouble(params, "weight")
        )
        let rule = try await api.matchmakingRules.create(ruleSetID: ruleSetID, fields: fields)
        return try jsonText(rule)
    }

    private static func handleMatchmakingRulesUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterAPI.MatchmakingRules.Fields(
            referenceName: optionalString(params, "reference_name"),
            description: optionalString(params, "description"),
            type: optionalString(params, "type"),
            expression: optionalString(params, "expression"),
            weight: optionalDouble(params, "weight")
        )
        let rule = try await api.matchmakingRules.update(id: id, fields: fields)
        return try jsonText(rule)
    }

    private static func handleMatchmakingRulesDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.matchmakingRules.delete(id: id)
        return ackResult("Deleted gameCenterMatchmakingRule \(id)")
    }

    // MARK: - Handlers: Matchmaking team configurations

    private static func handleMatchmakingTeamConfigurationsList(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let ruleSetID = try requireString(params, "rule_set_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.matchmakingTeamConfigurations.listForRuleSet(
            ruleSetID: ruleSetID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.items, nextCursor: page.nextCursor))
    }

    private static func handleMatchmakingTeamConfigurationsGet(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let config = try await api.matchmakingTeamConfigurations.get(id: id)
        return try jsonText(config)
    }

    private static func handleMatchmakingTeamConfigurationsCreate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let ruleSetID = try requireString(params, "rule_set_id")
        let fields = GameCenterAPI.MatchmakingTeamConfigurations.Fields(
            referenceName: optionalString(params, "reference_name"),
            maxPlayers: optionalInt(params, "max_players"),
            minPlayers: optionalInt(params, "min_players")
        )
        let config = try await api.matchmakingTeamConfigurations.create(ruleSetID: ruleSetID, fields: fields)
        return try jsonText(config)
    }

    private static func handleMatchmakingTeamConfigurationsUpdate(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = GameCenterAPI.MatchmakingTeamConfigurations.Fields(
            referenceName: optionalString(params, "reference_name"),
            maxPlayers: optionalInt(params, "max_players"),
            minPlayers: optionalInt(params, "min_players")
        )
        let config = try await api.matchmakingTeamConfigurations.update(id: id, fields: fields)
        return try jsonText(config)
    }

    private static func handleMatchmakingTeamConfigurationsDelete(
        _ params: CallTool.Parameters, api: GameCenterAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.matchmakingTeamConfigurations.delete(id: id)
        return ackResult("Deleted gameCenterMatchmakingTeamConfiguration \(id)")
    }
}
