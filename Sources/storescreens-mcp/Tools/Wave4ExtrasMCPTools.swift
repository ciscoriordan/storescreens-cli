import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for the grab-bag of small App Store Connect resource
/// families covered by `Wave4ExtrasAPI`: subscription additions (intro
/// offers, win-back offers, grace periods, group submissions, the missing
/// price-point GET), customer review summarizations + app review
/// attachments, and the niche late-2025 resources (merchantIds,
/// nominations, appTags, endUserLicenseAgreements, androidToIos mapping,
/// actors, app price points V3, appClipAdvancedExperienceImages,
/// inAppPurchaseAvailabilities, inAppPurchaseContents, territoryAvailabilities).
///
/// Tool names use prefixes that do NOT collide with existing namespaces:
///   - `subext_*`  for subscription extras (avoiding the `subs_*` family)
///   - `revext_*`  for review extras (avoiding the `reviews_*` family)
///   - `ascext_*`  for the misc grab-bag
///
/// All tools resolve credentials through `ASCCredentialResolver.resolve()`
/// (env vars first, then `~/.storescreens/asc-credentials.yml`). Tools
/// return pretty-printed JSON in a single `.text` content block, with
/// `isError: true` set on failures and unknown names.
package enum Wave4ExtrasMCPTools {

    // MARK: - Tool catalog

    package static let tools: [Tool] = [

        // MARK: Subscription extras: intro offers

        Tool(
            name: "subext_intro_offers_create",
            description: """
            Create a subscription introductory offer for NEW subscribers. \
            Distinct from `subs_promotional_offers_*` (which targets \
            existing subscribers). Scoped per-territory; pass the \
            price-point id and the territory id alongside the duration \
            and offer mode.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "subscription_id": .object([
                        "type": .string("string"),
                        "description": .string("Subscription id the offer attaches to."),
                    ]),
                    "territory_id": .object([
                        "type": .string("string"),
                        "description": .string("Territory id (e.g. USA)."),
                    ]),
                    "price_point_id": .object([
                        "type": .string("string"),
                        "description": .string("subscriptionPricePoint id the offer redeems against."),
                    ]),
                    "offer_mode": .object([
                        "type": .string("string"),
                        "description": .string("PAY_AS_YOU_GO | PAY_UP_FRONT | FREE_TRIAL."),
                    ]),
                    "duration": .object([
                        "type": .string("string"),
                        "description": .string("Apple duration enum (e.g. ONE_MONTH, THREE_MONTHS)."),
                    ]),
                    "number_of_periods": .object([
                        "type": .string("integer"),
                        "description": .string("Number of periods the offer covers."),
                    ]),
                    "start_date": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO 8601 start date."),
                    ]),
                    "end_date": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO 8601 end date."),
                    ]),
                ]),
                "required": .array([
                    .string("subscription_id"),
                    .string("territory_id"),
                    .string("price_point_id"),
                    .string("offer_mode"),
                    .string("duration"),
                    .string("number_of_periods"),
                ]),
            ])
        ),
        Tool(
            name: "subext_intro_offers_update",
            description: "Update an intro offer's date range. Only startDate / endDate are mutable.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Intro offer id.")]),
                    "start_date": .object(["type": .string("string"), "description": .string("Optional ISO 8601.")]),
                    "end_date": .object(["type": .string("string"), "description": .string("Optional ISO 8601.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "subext_intro_offers_delete",
            description: "Delete an intro offer by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: Subscription extras: win-back offers

        Tool(
            name: "subext_winback_offers_list",
            description: "List win-back offers for a subscription. Paginated.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "subscription_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("subscription_id")]),
            ])
        ),
        Tool(
            name: "subext_winback_offers_get",
            description: "Fetch a single win-back offer by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "subext_winback_offers_create",
            description: "Create a new win-back offer for lapsed subscribers.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "subscription_id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "offer_code": .object(["type": .string("string")]),
                    "offer_mode": .object(["type": .string("string"), "description": .string("PAY_AS_YOU_GO | PAY_UP_FRONT | FREE_TRIAL.")]),
                    "duration": .object(["type": .string("string")]),
                    "number_of_periods": .object(["type": .string("integer")]),
                    "start_date": .object(["type": .string("string")]),
                    "end_date": .object(["type": .string("string")]),
                ]),
                "required": .array([
                    .string("subscription_id"), .string("name"), .string("offer_code"),
                    .string("offer_mode"), .string("duration"), .string("number_of_periods"),
                ]),
            ])
        ),
        Tool(
            name: "subext_winback_offers_update",
            description: "Update an existing win-back offer's name or date range.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "start_date": .object(["type": .string("string")]),
                    "end_date": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "subext_winback_offers_delete",
            description: "Delete a win-back offer by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "subext_winback_offer_prices_list",
            description: "List per-territory prices for a win-back offer.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "offer_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("offer_id")]),
            ])
        ),
        Tool(
            name: "subext_winback_offer_prices_create",
            description: "Attach a (territory, price-point) tuple to a win-back offer.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "offer_id": .object(["type": .string("string")]),
                    "territory_id": .object(["type": .string("string")]),
                    "price_point_id": .object(["type": .string("string"), "description": .string("subscriptionPricePoint id.")]),
                ]),
                "required": .array([.string("offer_id"), .string("territory_id"), .string("price_point_id")]),
            ])
        ),

        // MARK: Subscription extras: grace periods

        Tool(
            name: "subext_grace_period_get",
            description: "Fetch the billing grace-period config for a subscription group.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_id": .object(["type": .string("string"), "description": .string("subscriptionGroup id.")]),
                ]),
                "required": .array([.string("group_id")]),
            ])
        ),
        Tool(
            name: "subext_grace_period_update",
            description: "Update a grace-period record. Toggle opt-in and choose Apple's renewalType (SIX_DAYS, SIXTEEN_DAYS, THIRTY_DAYS).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("subscriptionGracePeriod record id.")]),
                    "opt_in": .object(["type": .string("boolean")]),
                    "renewal_type": .object(["type": .string("string"), "description": .string("SIX_DAYS | SIXTEEN_DAYS | THIRTY_DAYS.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: Subscription extras: group submissions

        Tool(
            name: "subext_group_submission_create",
            description: "Submit an entire subscription group for App Review at once. Sibling of subs_submissions_create (which submits a single subscription).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("group_id")]),
            ])
        ),

        // MARK: Subscription extras: price point GET by id

        Tool(
            name: "subext_price_point_get",
            description: "Fetch a single subscriptionPricePoint by id. Complements subs_price_points_list (which scopes to a subscription).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("subscriptionPricePoint id.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: Review extras: summarizations

        Tool(
            name: "revext_summarizations_list_for_app",
            description: "List Apple Intelligence customer review summarizations for an app. Read-only.",
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
            name: "revext_summarizations_get",
            description: "Fetch a single customer review summarization by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: Review extras: attachments

        Tool(
            name: "revext_attachments_list",
            description: "List supporting attachments on an App Store review-detail record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "review_detail_id": .object(["type": .string("string"), "description": .string("appStoreReviewDetail id.")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("review_detail_id")]),
            ])
        ),
        Tool(
            name: "revext_attachments_get",
            description: "Fetch a single review attachment record by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "revext_attachments_create",
            description: """
            Phase 1 of the 3-phase upload: reserve a new attachment slot. \
            Returns the record with `uploadOperations` you PUT the chunks \
            to. Most callers should use `revext_attachments_upload` to run \
            all three phases in one call.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "review_detail_id": .object(["type": .string("string")]),
                    "file_name": .object(["type": .string("string")]),
                    "file_size": .object(["type": .string("integer")]),
                ]),
                "required": .array([
                    .string("review_detail_id"), .string("file_name"), .string("file_size"),
                ]),
            ])
        ),
        Tool(
            name: "revext_attachments_update",
            description: "Phase 3 of the 3-phase upload: PATCH uploaded:true + sourceFileChecksum.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "uploaded": .object(["type": .string("boolean")]),
                    "source_file_checksum": .object(["type": .string("string"), "description": .string("Hex MD5 of the file.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "revext_attachments_delete",
            description: "Delete a review attachment by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "revext_attachments_upload",
            description: """
            Convenience: run all three phases of the attachment upload \
            (reserve, PUT chunks, finalize) in a single call. Reads bytes \
            from a local file path.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "review_detail_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string"), "description": .string("Local path to the file to upload.")]),
                ]),
                "required": .array([.string("review_detail_id"), .string("file_path")]),
            ])
        ),

        // MARK: ASC extras: merchant IDs

        Tool(
            name: "ascext_merchant_ids_list",
            description: "List Apple Pay merchant identifiers on the team. Distinct from `applepay_merchant_domains_*`.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "ascext_merchant_ids_get",
            description: "Fetch a single merchant id by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_merchant_ids_create",
            description: "Register a new merchant id (e.g. merchant.com.example).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "identifier": .object(["type": .string("string"), "description": .string("Dotted reverse-DNS merchant id.")]),
                    "name": .object(["type": .string("string"), "description": .string("Display name in the developer portal.")]),
                ]),
                "required": .array([.string("identifier"), .string("name")]),
            ])
        ),
        Tool(
            name: "ascext_merchant_ids_update",
            description: "Rename a merchant id's display label. The dotted identifier itself is immutable.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id"), .string("name")]),
            ])
        ),
        Tool(
            name: "ascext_merchant_ids_delete",
            description: "Delete a merchant id. Apple blocks deletion when active certificates still reference it.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_merchant_ids_certificates_list",
            description: "List merchant id certificates attached to a merchant id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "merchant_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("merchant_id")]),
            ])
        ),

        // MARK: ASC extras: nominations

        Tool(
            name: "ascext_nominations_list",
            description: "List App Store editorial nominations on an app.",
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
            name: "ascext_nominations_get",
            description: "Fetch a single nomination by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_nominations_create",
            description: "Submit a new editorial feature nomination for an app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string"), "description": .string("Headline for the nomination.")]),
                    "description": .object(["type": .string("string"), "description": .string("Long-form pitch.")]),
                ]),
                "required": .array([.string("app_id"), .string("title"), .string("description")]),
            ])
        ),
        Tool(
            name: "ascext_nominations_update",
            description: "Update a nomination's title or description.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_nominations_delete",
            description: "Delete a nomination by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: ASC extras: app tags

        Tool(
            name: "ascext_app_tags_update",
            description: """
            Replace an app's per-territory tag list. Apple treats the \
            payload as the new exhaustive set of tags for the territory.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "territory_id": .object(["type": .string("string")]),
                    "tag_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Apple's appTag ids to attach. Pass [] to clear."),
                    ]),
                ]),
                "required": .array([.string("app_id"), .string("territory_id"), .string("tag_ids")]),
            ])
        ),

        // MARK: ASC extras: end-user license agreements

        Tool(
            name: "ascext_eulas_list",
            description: "List custom EULAs configured on an app.",
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
            name: "ascext_eulas_get",
            description: "Fetch a single custom EULA by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_eulas_create",
            description: "Create a new custom EULA for an app, scoped to one or more territories.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "agreement_text": .object(["type": .string("string")]),
                    "territory_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("app_id"), .string("agreement_text"), .string("territory_ids")]),
            ])
        ),
        Tool(
            name: "ascext_eulas_update",
            description: "Update an EULA's agreement text or territory list. Nil fields leave existing values alone.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "agreement_text": .object(["type": .string("string")]),
                    "territory_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_eulas_delete",
            description: "Delete a custom EULA by id. Apple's default EULA continues to apply.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: ASC extras: android-to-ios mapping

        Tool(
            name: "ascext_android_to_ios_get",
            description: "Fetch the Android-to-iOS migration mapping configured on an app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),
        Tool(
            name: "ascext_android_to_ios_create",
            description: "Create a new Android-to-iOS migration mapping for an app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "android_package": .object(["type": .string("string"), "description": .string("Google Play package id (com.example.app).")]),
                    "migration_description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("app_id"), .string("android_package")]),
            ])
        ),
        Tool(
            name: "ascext_android_to_ios_update",
            description: "Update an Android-to-iOS mapping's package name or description.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "android_package": .object(["type": .string("string")]),
                    "migration_description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_android_to_ios_delete",
            description: "Delete an Android-to-iOS mapping by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: ASC extras: actors

        Tool(
            name: "ascext_actors_list",
            description: "List in-app actors. Read-only registry; niche to games.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "ascext_actors_get",
            description: "Fetch a single actor record by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: ASC extras: app price points V3

        Tool(
            name: "ascext_app_price_points_v3_get",
            description: """
            Fetch a single app price point through Apple's V3 endpoint. \
            Complements the V2 list endpoint already exposed by \
            PricingAvailabilityAPI.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_app_price_points_v3_equalizations",
            description: """
            List equalization records for a price point. Each record \
            describes the equivalent price point in another territory.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Price point id.")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: ASC extras: app clip advanced experience images

        Tool(
            name: "ascext_app_clip_advanced_experience_images_get",
            description: "Fetch a single app clip advanced experience image by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_app_clip_advanced_experience_images_create",
            description: "Phase 1 of the 3-phase upload: reserve an image slot on an advanced experience.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "advanced_experience_id": .object(["type": .string("string")]),
                    "file_name": .object(["type": .string("string")]),
                    "file_size": .object(["type": .string("integer")]),
                ]),
                "required": .array([
                    .string("advanced_experience_id"), .string("file_name"), .string("file_size"),
                ]),
            ])
        ),
        Tool(
            name: "ascext_app_clip_advanced_experience_images_update",
            description: "Phase 3 of the 3-phase upload: PATCH uploaded:true + sourceFileChecksum.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "uploaded": .object(["type": .string("boolean")]),
                    "source_file_checksum": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "ascext_app_clip_advanced_experience_images_upload",
            description: "Run all three phases of an image upload in a single call.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "advanced_experience_id": .object(["type": .string("string")]),
                    "file_path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("advanced_experience_id"), .string("file_path")]),
            ])
        ),

        // MARK: ASC extras: IAP availabilities

        Tool(
            name: "ascext_iap_availabilities_get",
            description: "Fetch the per-territory availability record for a one-time IAP.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("iap_id")]),
            ])
        ),
        Tool(
            name: "ascext_iap_availabilities_create",
            description: """
            Replace an IAP's availability with a new territory list. Pass \
            the full set of allowed territory ids; Apple treats this as \
            the new exhaustive list.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "iap_id": .object(["type": .string("string")]),
                    "territory_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "available_in_new_territories": .object(["type": .string("boolean")]),
                ]),
                "required": .array([
                    .string("iap_id"), .string("territory_ids"), .string("available_in_new_territories"),
                ]),
            ])
        ),

        // MARK: ASC extras: IAP contents

        Tool(
            name: "ascext_iap_contents_get",
            description: "Fetch the Apple-hosted content metadata record for an IAP.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("inAppPurchaseContent id.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // MARK: ASC extras: territory availabilities

        Tool(
            name: "ascext_territory_availabilities_update",
            description: """
            Flip a single (app, territory) pair on or off. Apple processes \
            the update synchronously; the new state is visible on the \
            next read of the app's availability.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string")]),
                    "territory_id": .object(["type": .string("string")]),
                    "available": .object(["type": .string("boolean")]),
                ]),
                "required": .array([
                    .string("app_id"), .string("territory_id"), .string("available"),
                ]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Routes a `CallTool.Parameters` whose name belongs to this namespace
    /// to the right handler. Returns an error result for unknown names so
    /// `Main.swift` can route through this whole family with a single
    /// `tools.contains(where:)` prefix check.
    package static func handle(
        _ params: CallTool.Parameters
    ) async throws -> CallTool.Result {
        switch params.name {
        // Subscription extras: intro offers
        case "subext_intro_offers_create": return try await handleIntroOffersCreate(params)
        case "subext_intro_offers_update": return try await handleIntroOffersUpdate(params)
        case "subext_intro_offers_delete": return try await handleIntroOffersDelete(params)
        // Subscription extras: win-back offers
        case "subext_winback_offers_list":   return try await handleWinBackOffersList(params)
        case "subext_winback_offers_get":    return try await handleWinBackOffersGet(params)
        case "subext_winback_offers_create": return try await handleWinBackOffersCreate(params)
        case "subext_winback_offers_update": return try await handleWinBackOffersUpdate(params)
        case "subext_winback_offers_delete": return try await handleWinBackOffersDelete(params)
        case "subext_winback_offer_prices_list":   return try await handleWinBackPricesList(params)
        case "subext_winback_offer_prices_create": return try await handleWinBackPricesCreate(params)
        // Subscription extras: grace periods
        case "subext_grace_period_get":    return try await handleGracePeriodGet(params)
        case "subext_grace_period_update": return try await handleGracePeriodUpdate(params)
        // Subscription extras: group submissions
        case "subext_group_submission_create": return try await handleGroupSubmissionCreate(params)
        // Subscription extras: price point GET
        case "subext_price_point_get": return try await handlePricePointGet(params)
        // Review extras: summarizations
        case "revext_summarizations_list_for_app": return try await handleSummarizationsList(params)
        case "revext_summarizations_get":          return try await handleSummarizationsGet(params)
        // Review extras: attachments
        case "revext_attachments_list":   return try await handleAttachmentsList(params)
        case "revext_attachments_get":    return try await handleAttachmentsGet(params)
        case "revext_attachments_create": return try await handleAttachmentsCreate(params)
        case "revext_attachments_update": return try await handleAttachmentsUpdate(params)
        case "revext_attachments_delete": return try await handleAttachmentsDelete(params)
        case "revext_attachments_upload": return try await handleAttachmentsUpload(params)
        // ASC extras: merchant ids
        case "ascext_merchant_ids_list":   return try await handleMerchantIDsList(params)
        case "ascext_merchant_ids_get":    return try await handleMerchantIDsGet(params)
        case "ascext_merchant_ids_create": return try await handleMerchantIDsCreate(params)
        case "ascext_merchant_ids_update": return try await handleMerchantIDsUpdate(params)
        case "ascext_merchant_ids_delete": return try await handleMerchantIDsDelete(params)
        case "ascext_merchant_ids_certificates_list": return try await handleMerchantCertsList(params)
        // ASC extras: nominations
        case "ascext_nominations_list":   return try await handleNominationsList(params)
        case "ascext_nominations_get":    return try await handleNominationsGet(params)
        case "ascext_nominations_create": return try await handleNominationsCreate(params)
        case "ascext_nominations_update": return try await handleNominationsUpdate(params)
        case "ascext_nominations_delete": return try await handleNominationsDelete(params)
        // ASC extras: app tags
        case "ascext_app_tags_update": return try await handleAppTagsUpdate(params)
        // ASC extras: EULAs
        case "ascext_eulas_list":   return try await handleEulasList(params)
        case "ascext_eulas_get":    return try await handleEulasGet(params)
        case "ascext_eulas_create": return try await handleEulasCreate(params)
        case "ascext_eulas_update": return try await handleEulasUpdate(params)
        case "ascext_eulas_delete": return try await handleEulasDelete(params)
        // ASC extras: Android-to-iOS mapping
        case "ascext_android_to_ios_get":    return try await handleAndroidGet(params)
        case "ascext_android_to_ios_create": return try await handleAndroidCreate(params)
        case "ascext_android_to_ios_update": return try await handleAndroidUpdate(params)
        case "ascext_android_to_ios_delete": return try await handleAndroidDelete(params)
        // ASC extras: actors
        case "ascext_actors_list": return try await handleActorsList(params)
        case "ascext_actors_get":  return try await handleActorsGet(params)
        // ASC extras: app price points V3
        case "ascext_app_price_points_v3_get":           return try await handleAppPricePointsV3Get(params)
        case "ascext_app_price_points_v3_equalizations": return try await handleAppPricePointsV3Equalizations(params)
        // ASC extras: app clip advanced experience images
        case "ascext_app_clip_advanced_experience_images_get":    return try await handleAppClipImagesGet(params)
        case "ascext_app_clip_advanced_experience_images_create": return try await handleAppClipImagesCreate(params)
        case "ascext_app_clip_advanced_experience_images_update": return try await handleAppClipImagesUpdate(params)
        case "ascext_app_clip_advanced_experience_images_upload": return try await handleAppClipImagesUpload(params)
        // ASC extras: IAP availabilities
        case "ascext_iap_availabilities_get":    return try await handleIAPAvailabilitiesGet(params)
        case "ascext_iap_availabilities_create": return try await handleIAPAvailabilitiesCreate(params)
        // ASC extras: IAP contents
        case "ascext_iap_contents_get": return try await handleIAPContentsGet(params)
        // ASC extras: territory availabilities
        case "ascext_territory_availabilities_update": return try await handleTerritoryAvailabilitiesUpdate(params)
        default:
            return errorResult("Unknown tool: \(params.name)")
        }
    }

    // MARK: - Subscription extras handlers

    static func handleIntroOffersCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let subID = params.arguments?["subscription_id"]?.stringValue, !subID.isEmpty else {
            return errorResult("Missing required parameter: subscription_id")
        }
        guard let terID = params.arguments?["territory_id"]?.stringValue, !terID.isEmpty else {
            return errorResult("Missing required parameter: territory_id")
        }
        guard let ppID = params.arguments?["price_point_id"]?.stringValue, !ppID.isEmpty else {
            return errorResult("Missing required parameter: price_point_id")
        }
        guard let mode = params.arguments?["offer_mode"]?.stringValue, !mode.isEmpty else {
            return errorResult("Missing required parameter: offer_mode")
        }
        guard let duration = params.arguments?["duration"]?.stringValue, !duration.isEmpty else {
            return errorResult("Missing required parameter: duration")
        }
        guard let periods = readInt(params, "number_of_periods") else {
            return errorResult("Missing required parameter: number_of_periods")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            let offer = try await api.createIntroductoryOffer(
                subscriptionID: subID,
                territoryID: terID,
                pricePointID: ppID,
                offerMode: mode,
                duration: duration,
                numberOfPeriods: periods,
                startDate: readDate(params, "start_date"),
                endDate: readDate(params, "end_date")
            )
            return jsonResult(IntroductoryOfferJSON(offer))
        } catch {
            return errorResult("subext_intro_offers_create failed: \(error)")
        }
    }

    static func handleIntroOffersUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            let offer = try await api.updateIntroductoryOffer(
                id: id,
                startDate: readDate(params, "start_date"),
                endDate: readDate(params, "end_date")
            )
            return jsonResult(IntroductoryOfferJSON(offer))
        } catch {
            return errorResult("subext_intro_offers_update failed: \(error)")
        }
    }

    static func handleIntroOffersDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            try await api.deleteIntroductoryOffer(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "subscriptionIntroductoryOffer"))
        } catch {
            return errorResult("subext_intro_offers_delete failed: \(error)")
        }
    }

    static func handleWinBackOffersList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let subID = params.arguments?["subscription_id"]?.stringValue, !subID.isEmpty else {
            return errorResult("Missing required parameter: subscription_id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            let page = try await api.listWinBackOffers(
                subscriptionID: subID,
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map(WinBackOfferJSON.init),
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("subext_winback_offers_list failed: \(error)")
        }
    }

    static func handleWinBackOffersGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            guard let offer = try await api.getWinBackOffer(id: id) else {
                return errorResult("No win-back offer with id \(id)")
            }
            return jsonResult(WinBackOfferJSON(offer))
        } catch {
            return errorResult("subext_winback_offers_get failed: \(error)")
        }
    }

    static func handleWinBackOffersCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let subID = params.arguments?["subscription_id"]?.stringValue, !subID.isEmpty else {
            return errorResult("Missing required parameter: subscription_id")
        }
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("Missing required parameter: name")
        }
        guard let code = params.arguments?["offer_code"]?.stringValue, !code.isEmpty else {
            return errorResult("Missing required parameter: offer_code")
        }
        guard let mode = params.arguments?["offer_mode"]?.stringValue, !mode.isEmpty else {
            return errorResult("Missing required parameter: offer_mode")
        }
        guard let duration = params.arguments?["duration"]?.stringValue, !duration.isEmpty else {
            return errorResult("Missing required parameter: duration")
        }
        guard let periods = readInt(params, "number_of_periods") else {
            return errorResult("Missing required parameter: number_of_periods")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            let offer = try await api.createWinBackOffer(
                subscriptionID: subID,
                name: name,
                offerCode: code,
                offerMode: mode,
                duration: duration,
                numberOfPeriods: periods,
                startDate: readDate(params, "start_date"),
                endDate: readDate(params, "end_date")
            )
            return jsonResult(WinBackOfferJSON(offer))
        } catch {
            return errorResult("subext_winback_offers_create failed: \(error)")
        }
    }

    static func handleWinBackOffersUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            let offer = try await api.updateWinBackOffer(
                id: id,
                name: params.arguments?["name"]?.stringValue,
                startDate: readDate(params, "start_date"),
                endDate: readDate(params, "end_date")
            )
            return jsonResult(WinBackOfferJSON(offer))
        } catch {
            return errorResult("subext_winback_offers_update failed: \(error)")
        }
    }

    static func handleWinBackOffersDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            try await api.deleteWinBackOffer(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "winBackOffer"))
        } catch {
            return errorResult("subext_winback_offers_delete failed: \(error)")
        }
    }

    static func handleWinBackPricesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let offerID = params.arguments?["offer_id"]?.stringValue, !offerID.isEmpty else {
            return errorResult("Missing required parameter: offer_id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            let page = try await api.listWinBackOfferPrices(
                offerID: offerID,
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map { WinBackOfferPriceJSON(id: $0.id) },
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("subext_winback_offer_prices_list failed: \(error)")
        }
    }

    static func handleWinBackPricesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let offerID = params.arguments?["offer_id"]?.stringValue, !offerID.isEmpty else {
            return errorResult("Missing required parameter: offer_id")
        }
        guard let terID = params.arguments?["territory_id"]?.stringValue, !terID.isEmpty else {
            return errorResult("Missing required parameter: territory_id")
        }
        guard let ppID = params.arguments?["price_point_id"]?.stringValue, !ppID.isEmpty else {
            return errorResult("Missing required parameter: price_point_id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            let price = try await api.createWinBackOfferPrice(
                offerID: offerID, territoryID: terID, pricePointID: ppID
            )
            return jsonResult(WinBackOfferPriceJSON(id: price.id))
        } catch {
            return errorResult("subext_winback_offer_prices_create failed: \(error)")
        }
    }

    static func handleGracePeriodGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let groupID = params.arguments?["group_id"]?.stringValue, !groupID.isEmpty else {
            return errorResult("Missing required parameter: group_id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            guard let gp = try await api.getGracePeriod(groupID: groupID) else {
                return errorResult("No grace period configured for group \(groupID)")
            }
            return jsonResult(GracePeriodJSON(gp))
        } catch {
            return errorResult("subext_grace_period_get failed: \(error)")
        }
    }

    static func handleGracePeriodUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            let gp = try await api.updateGracePeriod(
                id: id,
                optIn: params.arguments?["opt_in"]?.boolValue,
                renewalType: params.arguments?["renewal_type"]?.stringValue
            )
            return jsonResult(GracePeriodJSON(gp))
        } catch {
            return errorResult("subext_grace_period_update failed: \(error)")
        }
    }

    static func handleGroupSubmissionCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let groupID = params.arguments?["group_id"]?.stringValue, !groupID.isEmpty else {
            return errorResult("Missing required parameter: group_id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            let submission = try await api.createGroupSubmission(groupID: groupID)
            return jsonResult(GroupSubmissionJSON(submission))
        } catch {
            return errorResult("subext_group_submission_create failed: \(error)")
        }
    }

    static func handlePricePointGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().subscriptionExtras
            guard let pp = try await api.getPricePoint(id: id) else {
                return errorResult("No subscriptionPricePoint with id \(id)")
            }
            return jsonResult(SubsPricePointJSON(pp))
        } catch {
            return errorResult("subext_price_point_get failed: \(error)")
        }
    }

    // MARK: - Review extras handlers

    static func handleSummarizationsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        do {
            let api = try makeAPI().customerReviewExtras
            let page = try await api.listSummarizationsForApp(
                appID: appID,
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map(SummarizationJSON.init),
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("revext_summarizations_list_for_app failed: \(error)")
        }
    }

    static func handleSummarizationsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().customerReviewExtras
            guard let s = try await api.getSummarization(id: id) else {
                return errorResult("No summarization with id \(id)")
            }
            return jsonResult(SummarizationJSON(s))
        } catch {
            return errorResult("revext_summarizations_get failed: \(error)")
        }
    }

    static func handleAttachmentsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let rdID = params.arguments?["review_detail_id"]?.stringValue, !rdID.isEmpty else {
            return errorResult("Missing required parameter: review_detail_id")
        }
        do {
            let api = try makeAPI().customerReviewExtras
            let page = try await api.listAttachments(
                reviewDetailID: rdID,
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map(ReviewAttachmentJSON.init),
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("revext_attachments_list failed: \(error)")
        }
    }

    static func handleAttachmentsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().customerReviewExtras
            guard let a = try await api.getAttachment(id: id) else {
                return errorResult("No review attachment with id \(id)")
            }
            return jsonResult(ReviewAttachmentJSON(a))
        } catch {
            return errorResult("revext_attachments_get failed: \(error)")
        }
    }

    static func handleAttachmentsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let rdID = params.arguments?["review_detail_id"]?.stringValue, !rdID.isEmpty else {
            return errorResult("Missing required parameter: review_detail_id")
        }
        guard let fileName = params.arguments?["file_name"]?.stringValue, !fileName.isEmpty else {
            return errorResult("Missing required parameter: file_name")
        }
        guard let fileSize = readInt(params, "file_size") else {
            return errorResult("Missing required parameter: file_size")
        }
        do {
            let api = try makeAPI().customerReviewExtras
            let a = try await api.createAttachment(
                reviewDetailID: rdID, fileName: fileName, fileSize: fileSize
            )
            return jsonResult(ReviewAttachmentJSON(a))
        } catch {
            return errorResult("revext_attachments_create failed: \(error)")
        }
    }

    static func handleAttachmentsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().customerReviewExtras
            let a = try await api.updateAttachment(
                id: id,
                uploaded: params.arguments?["uploaded"]?.boolValue,
                sourceFileChecksum: params.arguments?["source_file_checksum"]?.stringValue
            )
            return jsonResult(ReviewAttachmentJSON(a))
        } catch {
            return errorResult("revext_attachments_update failed: \(error)")
        }
    }

    static func handleAttachmentsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().customerReviewExtras
            try await api.deleteAttachment(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "appStoreReviewAttachment"))
        } catch {
            return errorResult("revext_attachments_delete failed: \(error)")
        }
    }

    static func handleAttachmentsUpload(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let rdID = params.arguments?["review_detail_id"]?.stringValue, !rdID.isEmpty else {
            return errorResult("Missing required parameter: review_detail_id")
        }
        guard let path = params.arguments?["file_path"]?.stringValue, !path.isEmpty else {
            return errorResult("Missing required parameter: file_path")
        }
        do {
            let api = try makeAPI().customerReviewExtras
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let a = try await api.uploadAttachment(reviewDetailID: rdID, fileURL: url)
            return jsonResult(ReviewAttachmentJSON(a))
        } catch {
            return errorResult("revext_attachments_upload failed: \(error)")
        }
    }

    // MARK: - Merchant IDs handlers

    static func handleMerchantIDsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeAPI().merchant
            let page = try await api.listMerchantIDs(
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map(MerchantIDJSON.init),
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("ascext_merchant_ids_list failed: \(error)")
        }
    }

    static func handleMerchantIDsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().merchant
            guard let m = try await api.getMerchantID(id: id) else {
                return errorResult("No merchant id with id \(id)")
            }
            return jsonResult(MerchantIDJSON(m))
        } catch {
            return errorResult("ascext_merchant_ids_get failed: \(error)")
        }
    }

    static func handleMerchantIDsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let identifier = params.arguments?["identifier"]?.stringValue, !identifier.isEmpty else {
            return errorResult("Missing required parameter: identifier")
        }
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("Missing required parameter: name")
        }
        do {
            let api = try makeAPI().merchant
            let m = try await api.createMerchantID(identifier: identifier, name: name)
            return jsonResult(MerchantIDJSON(m))
        } catch {
            return errorResult("ascext_merchant_ids_create failed: \(error)")
        }
    }

    static func handleMerchantIDsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return errorResult("Missing required parameter: name")
        }
        do {
            let api = try makeAPI().merchant
            let m = try await api.updateMerchantID(id: id, name: name)
            return jsonResult(MerchantIDJSON(m))
        } catch {
            return errorResult("ascext_merchant_ids_update failed: \(error)")
        }
    }

    static func handleMerchantIDsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().merchant
            try await api.deleteMerchantID(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "merchantId"))
        } catch {
            return errorResult("ascext_merchant_ids_delete failed: \(error)")
        }
    }

    static func handleMerchantCertsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let merchantID = params.arguments?["merchant_id"]?.stringValue, !merchantID.isEmpty else {
            return errorResult("Missing required parameter: merchant_id")
        }
        do {
            let api = try makeAPI().merchant
            let page = try await api.listMerchantCertificates(
                merchantIDID: merchantID,
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map(MerchantCertJSON.init),
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("ascext_merchant_ids_certificates_list failed: \(error)")
        }
    }

    // MARK: - Nominations handlers

    static func handleNominationsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        do {
            let api = try makeAPI().nominations
            let page = try await api.listNominations(
                appID: appID,
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map(NominationJSON.init),
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("ascext_nominations_list failed: \(error)")
        }
    }

    static func handleNominationsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().nominations
            guard let n = try await api.getNomination(id: id) else {
                return errorResult("No nomination with id \(id)")
            }
            return jsonResult(NominationJSON(n))
        } catch {
            return errorResult("ascext_nominations_get failed: \(error)")
        }
    }

    static func handleNominationsCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        guard let title = params.arguments?["title"]?.stringValue, !title.isEmpty else {
            return errorResult("Missing required parameter: title")
        }
        guard let description = params.arguments?["description"]?.stringValue, !description.isEmpty else {
            return errorResult("Missing required parameter: description")
        }
        do {
            let api = try makeAPI().nominations
            let n = try await api.createNomination(
                appID: appID, title: title, description: description
            )
            return jsonResult(NominationJSON(n))
        } catch {
            return errorResult("ascext_nominations_create failed: \(error)")
        }
    }

    static func handleNominationsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().nominations
            let n = try await api.updateNomination(
                id: id,
                title: params.arguments?["title"]?.stringValue,
                description: params.arguments?["description"]?.stringValue
            )
            return jsonResult(NominationJSON(n))
        } catch {
            return errorResult("ascext_nominations_update failed: \(error)")
        }
    }

    static func handleNominationsDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().nominations
            try await api.deleteNomination(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "nomination"))
        } catch {
            return errorResult("ascext_nominations_delete failed: \(error)")
        }
    }

    // MARK: - App tags handler

    static func handleAppTagsUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        guard let terID = params.arguments?["territory_id"]?.stringValue, !terID.isEmpty else {
            return errorResult("Missing required parameter: territory_id")
        }
        guard let tagsArr = params.arguments?["tag_ids"]?.arrayValue else {
            return errorResult("Missing required parameter: tag_ids")
        }
        let tagIDs = tagsArr.compactMap { $0.stringValue }
        do {
            let api = try makeAPI().appTags
            let tags = try await api.updateAppTags(
                appID: appID, territoryID: terID, tagIDs: tagIDs
            )
            return jsonResult(AppTagsPayload(tags: tags.map(AppTagJSON.init)))
        } catch {
            return errorResult("ascext_app_tags_update failed: \(error)")
        }
    }

    // MARK: - EULA handlers

    static func handleEulasList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        do {
            let api = try makeAPI().eulas
            let page = try await api.listEULAs(
                appID: appID,
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map(EULAJSON.init),
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("ascext_eulas_list failed: \(error)")
        }
    }

    static func handleEulasGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().eulas
            guard let e = try await api.getEULA(id: id) else {
                return errorResult("No EULA with id \(id)")
            }
            return jsonResult(EULAJSON(e))
        } catch {
            return errorResult("ascext_eulas_get failed: \(error)")
        }
    }

    static func handleEulasCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        guard let text = params.arguments?["agreement_text"]?.stringValue, !text.isEmpty else {
            return errorResult("Missing required parameter: agreement_text")
        }
        guard let terArr = params.arguments?["territory_ids"]?.arrayValue else {
            return errorResult("Missing required parameter: territory_ids")
        }
        let terIDs = terArr.compactMap { $0.stringValue }
        do {
            let api = try makeAPI().eulas
            let e = try await api.createEULA(
                appID: appID, agreementText: text, territoryIDs: terIDs
            )
            return jsonResult(EULAJSON(e))
        } catch {
            return errorResult("ascext_eulas_create failed: \(error)")
        }
    }

    static func handleEulasUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        let terIDs: [String]? = (params.arguments?["territory_ids"]?.arrayValue).map { arr in
            arr.compactMap { $0.stringValue }
        }
        do {
            let api = try makeAPI().eulas
            let e = try await api.updateEULA(
                id: id,
                agreementText: params.arguments?["agreement_text"]?.stringValue,
                territoryIDs: terIDs
            )
            return jsonResult(EULAJSON(e))
        } catch {
            return errorResult("ascext_eulas_update failed: \(error)")
        }
    }

    static func handleEulasDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().eulas
            try await api.deleteEULA(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "endUserLicenseAgreement"))
        } catch {
            return errorResult("ascext_eulas_delete failed: \(error)")
        }
    }

    // MARK: - Android-to-iOS handlers

    static func handleAndroidGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        do {
            let api = try makeAPI().androidMapping
            guard let m = try await api.getMapping(appID: appID) else {
                return errorResult("No mapping configured for app \(appID)")
            }
            return jsonResult(AndroidMappingJSON(m))
        } catch {
            return errorResult("ascext_android_to_ios_get failed: \(error)")
        }
    }

    static func handleAndroidCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        guard let pkg = params.arguments?["android_package"]?.stringValue, !pkg.isEmpty else {
            return errorResult("Missing required parameter: android_package")
        }
        do {
            let api = try makeAPI().androidMapping
            let m = try await api.createMapping(
                appID: appID,
                androidAppPackageName: pkg,
                migrationDescription: params.arguments?["migration_description"]?.stringValue
            )
            return jsonResult(AndroidMappingJSON(m))
        } catch {
            return errorResult("ascext_android_to_ios_create failed: \(error)")
        }
    }

    static func handleAndroidUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().androidMapping
            let m = try await api.updateMapping(
                id: id,
                androidAppPackageName: params.arguments?["android_package"]?.stringValue,
                migrationDescription: params.arguments?["migration_description"]?.stringValue
            )
            return jsonResult(AndroidMappingJSON(m))
        } catch {
            return errorResult("ascext_android_to_ios_update failed: \(error)")
        }
    }

    static func handleAndroidDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().androidMapping
            try await api.deleteMapping(id: id)
            return jsonResult(DeleteAck(deletedID: id, kind: "androidToIosAppMappingDetail"))
        } catch {
            return errorResult("ascext_android_to_ios_delete failed: \(error)")
        }
    }

    // MARK: - Actors handlers

    static func handleActorsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            let api = try makeAPI().actors
            let page = try await api.listActors(
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map(ActorJSON.init),
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("ascext_actors_list failed: \(error)")
        }
    }

    static func handleActorsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().actors
            guard let a = try await api.getActor(id: id) else {
                return errorResult("No actor with id \(id)")
            }
            return jsonResult(ActorJSON(a))
        } catch {
            return errorResult("ascext_actors_get failed: \(error)")
        }
    }

    // MARK: - App price points V3 handlers

    static func handleAppPricePointsV3Get(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().pricePointsV3
            guard let p = try await api.getPricePoint(id: id) else {
                return errorResult("No app price point with id \(id)")
            }
            return jsonResult(AppPricePointV3JSON(p))
        } catch {
            return errorResult("ascext_app_price_points_v3_get failed: \(error)")
        }
    }

    static func handleAppPricePointsV3Equalizations(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().pricePointsV3
            let page = try await api.listEqualizations(
                pricePointID: id,
                limit: readInt(params, "limit") ?? 200,
                cursor: params.arguments?["cursor"]?.stringValue
            )
            return jsonResult(PagePayload(
                items: page.items.map(EqualizationJSON.init),
                cursor: page.nextCursor
            ))
        } catch {
            return errorResult("ascext_app_price_points_v3_equalizations failed: \(error)")
        }
    }

    // MARK: - App clip advanced experience image handlers

    static func handleAppClipImagesGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().appClipAdvancedImages
            guard let img = try await api.getImage(id: id) else {
                return errorResult("No advanced image with id \(id)")
            }
            return jsonResult(AdvancedImageJSON(img))
        } catch {
            return errorResult("ascext_app_clip_advanced_experience_images_get failed: \(error)")
        }
    }

    static func handleAppClipImagesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let aeID = params.arguments?["advanced_experience_id"]?.stringValue, !aeID.isEmpty else {
            return errorResult("Missing required parameter: advanced_experience_id")
        }
        guard let fileName = params.arguments?["file_name"]?.stringValue, !fileName.isEmpty else {
            return errorResult("Missing required parameter: file_name")
        }
        guard let fileSize = readInt(params, "file_size") else {
            return errorResult("Missing required parameter: file_size")
        }
        do {
            let api = try makeAPI().appClipAdvancedImages
            let img = try await api.createImage(
                advancedExperienceID: aeID, fileName: fileName, fileSize: fileSize
            )
            return jsonResult(AdvancedImageJSON(img))
        } catch {
            return errorResult("ascext_app_clip_advanced_experience_images_create failed: \(error)")
        }
    }

    static func handleAppClipImagesUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().appClipAdvancedImages
            let img = try await api.updateImage(
                id: id,
                uploaded: params.arguments?["uploaded"]?.boolValue,
                sourceFileChecksum: params.arguments?["source_file_checksum"]?.stringValue
            )
            return jsonResult(AdvancedImageJSON(img))
        } catch {
            return errorResult("ascext_app_clip_advanced_experience_images_update failed: \(error)")
        }
    }

    static func handleAppClipImagesUpload(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let aeID = params.arguments?["advanced_experience_id"]?.stringValue, !aeID.isEmpty else {
            return errorResult("Missing required parameter: advanced_experience_id")
        }
        guard let path = params.arguments?["file_path"]?.stringValue, !path.isEmpty else {
            return errorResult("Missing required parameter: file_path")
        }
        do {
            let api = try makeAPI().appClipAdvancedImages
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let img = try await api.uploadImage(advancedExperienceID: aeID, fileURL: url)
            return jsonResult(AdvancedImageJSON(img))
        } catch {
            return errorResult("ascext_app_clip_advanced_experience_images_upload failed: \(error)")
        }
    }

    // MARK: - IAP availabilities handlers

    static func handleIAPAvailabilitiesGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue, !iapID.isEmpty else {
            return errorResult("Missing required parameter: iap_id")
        }
        do {
            let api = try makeAPI().iapAvailabilities
            guard let av = try await api.getAvailability(iapID: iapID) else {
                return errorResult("No availability record for IAP \(iapID)")
            }
            return jsonResult(IAPAvailabilityJSON(av))
        } catch {
            return errorResult("ascext_iap_availabilities_get failed: \(error)")
        }
    }

    static func handleIAPAvailabilitiesCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let iapID = params.arguments?["iap_id"]?.stringValue, !iapID.isEmpty else {
            return errorResult("Missing required parameter: iap_id")
        }
        guard let terArr = params.arguments?["territory_ids"]?.arrayValue else {
            return errorResult("Missing required parameter: territory_ids")
        }
        guard let avail = params.arguments?["available_in_new_territories"]?.boolValue else {
            return errorResult("Missing required parameter: available_in_new_territories")
        }
        let terIDs = terArr.compactMap { $0.stringValue }
        do {
            let api = try makeAPI().iapAvailabilities
            let av = try await api.createAvailability(
                iapID: iapID, territoryIDs: terIDs, availableInNewTerritories: avail
            )
            return jsonResult(IAPAvailabilityJSON(av))
        } catch {
            return errorResult("ascext_iap_availabilities_create failed: \(error)")
        }
    }

    static func handleIAPContentsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty else {
            return errorResult("Missing required parameter: id")
        }
        do {
            let api = try makeAPI().iapContents
            guard let c = try await api.getContent(id: id) else {
                return errorResult("No IAP content with id \(id)")
            }
            return jsonResult(IAPContentJSON(c))
        } catch {
            return errorResult("ascext_iap_contents_get failed: \(error)")
        }
    }

    // MARK: - Territory availabilities handler

    static func handleTerritoryAvailabilitiesUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return errorResult("Missing required parameter: app_id")
        }
        guard let terID = params.arguments?["territory_id"]?.stringValue, !terID.isEmpty else {
            return errorResult("Missing required parameter: territory_id")
        }
        guard let available = params.arguments?["available"]?.boolValue else {
            return errorResult("Missing required parameter: available")
        }
        do {
            let api = try makeAPI().territoryAvailabilities
            let av = try await api.updateAvailability(
                appID: appID, territoryID: terID, available: available
            )
            return jsonResult(TerritoryAvailabilityJSON(av))
        } catch {
            return errorResult("ascext_territory_availabilities_update failed: \(error)")
        }
    }

    // MARK: - JSON shapes (stable wire format)

    struct PagePayload<Item: Encodable>: Encodable {
        let items: [Item]
        let cursor: String?
    }

    struct AppTagsPayload: Encodable {
        let tags: [AppTagJSON]
    }

    struct IntroductoryOfferJSON: Encodable {
        let id: String
        let offerMode: String?
        let duration: String?
        let numberOfPeriods: Int?
        let startDate: Date?
        let endDate: Date?
        let territory: String?

        init(_ o: Wave4ExtrasAPI.SubscriptionExtras.IntroductoryOffer) {
            self.id = o.id
            self.offerMode = o.attributes?.offerMode
            self.duration = o.attributes?.duration
            self.numberOfPeriods = o.attributes?.numberOfPeriods
            self.startDate = o.attributes?.startDate
            self.endDate = o.attributes?.endDate
            self.territory = o.attributes?.territory
        }
    }

    struct WinBackOfferJSON: Encodable {
        let id: String
        let name: String?
        let offerCode: String?
        let offerMode: String?
        let duration: String?
        let numberOfPeriods: Int?
        let startDate: Date?
        let endDate: Date?
        let state: String?

        init(_ o: Wave4ExtrasAPI.SubscriptionExtras.WinBackOffer) {
            self.id = o.id
            self.name = o.attributes?.name
            self.offerCode = o.attributes?.offerCode
            self.offerMode = o.attributes?.offerMode
            self.duration = o.attributes?.duration
            self.numberOfPeriods = o.attributes?.numberOfPeriods
            self.startDate = o.attributes?.startDate
            self.endDate = o.attributes?.endDate
            self.state = o.attributes?.state
        }
    }

    struct WinBackOfferPriceJSON: Encodable {
        let id: String
    }

    struct GracePeriodJSON: Encodable {
        let id: String
        let optIn: Bool?
        let renewalType: String?
        let duration: Int?

        init(_ g: Wave4ExtrasAPI.SubscriptionExtras.GracePeriod) {
            self.id = g.id
            self.optIn = g.attributes?.optIn
            self.renewalType = g.attributes?.renewalType
            self.duration = g.attributes?.duration
        }
    }

    struct GroupSubmissionJSON: Encodable {
        let id: String
        let state: String?
        let submittedDate: Date?

        init(_ s: Wave4ExtrasAPI.SubscriptionExtras.GroupSubmission) {
            self.id = s.id
            self.state = s.attributes?.state
            self.submittedDate = s.attributes?.submittedDate
        }
    }

    struct SubsPricePointJSON: Encodable {
        let id: String
        let customerPrice: String?
        let proceeds: String?

        init(_ p: Wave4ExtrasAPI.SubscriptionExtras.PricePoint) {
            self.id = p.id
            self.customerPrice = p.attributes?.customerPrice
            self.proceeds = p.attributes?.proceeds
        }
    }

    struct SummarizationJSON: Encodable {
        let id: String
        let locale: String?
        let territory: String?
        let summary: String?
        let positiveHighlights: [String]?
        let negativeHighlights: [String]?
        let lastModifiedDate: Date?

        init(_ s: Wave4ExtrasAPI.CustomerReviewExtras.ReviewSummarization) {
            self.id = s.id
            self.locale = s.attributes?.locale
            self.territory = s.attributes?.territory
            self.summary = s.attributes?.summary
            self.positiveHighlights = s.attributes?.positiveHighlights
            self.negativeHighlights = s.attributes?.negativeHighlights
            self.lastModifiedDate = s.attributes?.lastModifiedDate
        }
    }

    struct ReviewAttachmentJSON: Encodable {
        let id: String
        let fileName: String?
        let fileSize: Int?
        let sourceFileChecksum: String?
        let assetDeliveryState: String?

        init(_ a: Wave4ExtrasAPI.CustomerReviewExtras.ReviewAttachment) {
            self.id = a.id
            self.fileName = a.attributes?.fileName
            self.fileSize = a.attributes?.fileSize
            self.sourceFileChecksum = a.attributes?.sourceFileChecksum
            self.assetDeliveryState = a.attributes?.assetDeliveryState?.state
        }
    }

    struct MerchantIDJSON: Encodable {
        let id: String
        let identifier: String?
        let name: String?

        init(_ m: Wave4ExtrasAPI.Merchant.MerchantID) {
            self.id = m.id
            self.identifier = m.attributes?.identifier
            self.name = m.attributes?.name
        }
    }

    struct MerchantCertJSON: Encodable {
        let id: String
        let displayName: String?
        let serialNumber: String?
        let expirationDate: Date?

        init(_ c: Wave4ExtrasAPI.Merchant.MerchantCertificate) {
            self.id = c.id
            self.displayName = c.attributes?.displayName
            self.serialNumber = c.attributes?.serialNumber
            self.expirationDate = c.attributes?.expirationDate
        }
    }

    struct NominationJSON: Encodable {
        let id: String
        let title: String?
        let description: String?
        let state: String?
        let lastModifiedDate: Date?

        init(_ n: Wave4ExtrasAPI.Nominations.Nomination) {
            self.id = n.id
            self.title = n.attributes?.title
            self.description = n.attributes?.description
            self.state = n.attributes?.state
            self.lastModifiedDate = n.attributes?.lastModifiedDate
        }
    }

    struct AppTagJSON: Encodable {
        let id: String
        let tag: String?
        let displayName: String?

        init(_ t: Wave4ExtrasAPI.AppTags.AppTag) {
            self.id = t.id
            self.tag = t.attributes?.tag
            self.displayName = t.attributes?.displayName
        }
    }

    struct EULAJSON: Encodable {
        let id: String
        let agreementText: String?

        init(_ e: Wave4ExtrasAPI.EULAs.EULA) {
            self.id = e.id
            self.agreementText = e.attributes?.agreementText
        }
    }

    struct AndroidMappingJSON: Encodable {
        let id: String
        let androidAppPackageName: String?
        let migrationDescription: String?

        init(_ m: Wave4ExtrasAPI.AndroidMapping.AndroidToIos) {
            self.id = m.id
            self.androidAppPackageName = m.attributes?.androidAppPackageName
            self.migrationDescription = m.attributes?.migrationDescription
        }
    }

    struct ActorJSON: Encodable {
        let id: String
        let name: String?
        let role: String?

        init(_ a: Wave4ExtrasAPI.Actors.Actor) {
            self.id = a.id
            self.name = a.attributes?.name
            self.role = a.attributes?.role
        }
    }

    struct AppPricePointV3JSON: Encodable {
        let id: String
        let customerPrice: String?
        let proceeds: String?
        let priceTier: String?
        let territory: String?

        init(_ p: Wave4ExtrasAPI.PricePointsV3.PricePoint) {
            self.id = p.id
            self.customerPrice = p.attributes?.customerPrice
            self.proceeds = p.attributes?.proceeds
            self.priceTier = p.attributes?.priceTier
            self.territory = p.attributes?.territory
        }
    }

    struct EqualizationJSON: Encodable {
        let id: String
        let territory: String?
        let customerPrice: String?

        init(_ e: Wave4ExtrasAPI.PricePointsV3.Equalization) {
            self.id = e.id
            self.territory = e.attributes?.territory
            self.customerPrice = e.attributes?.customerPrice
        }
    }

    struct AdvancedImageJSON: Encodable {
        let id: String
        let fileName: String?
        let fileSize: Int?
        let sourceFileChecksum: String?
        let assetDeliveryState: String?

        init(_ i: Wave4ExtrasAPI.AppClipAdvancedImages.AdvancedImage) {
            self.id = i.id
            self.fileName = i.attributes?.fileName
            self.fileSize = i.attributes?.fileSize
            self.sourceFileChecksum = i.attributes?.sourceFileChecksum
            self.assetDeliveryState = i.attributes?.assetDeliveryState?.state
        }
    }

    struct IAPAvailabilityJSON: Encodable {
        let id: String
        let availableInNewTerritories: Bool?

        init(_ a: Wave4ExtrasAPI.IAPAvailabilities.Availability) {
            self.id = a.id
            self.availableInNewTerritories = a.attributes?.availableInNewTerritories
        }
    }

    struct IAPContentJSON: Encodable {
        let id: String
        let fileName: String?
        let fileSize: Int?
        let lastModifiedDate: Date?

        init(_ c: Wave4ExtrasAPI.IAPContents.IAPContent) {
            self.id = c.id
            self.fileName = c.attributes?.fileName
            self.fileSize = c.attributes?.fileSize
            self.lastModifiedDate = c.attributes?.lastModifiedDate
        }
    }

    struct TerritoryAvailabilityJSON: Encodable {
        let id: String
        let availableInNewTerritories: Bool?

        init(_ a: Wave4ExtrasAPI.TerritoryAvailabilities.Availability) {
            self.id = a.id
            self.availableInNewTerritories = a.attributes?.availableInNewTerritories
        }
    }

    struct DeleteAck: Encodable {
        let deletedID: String
        let kind: String
    }

    // MARK: - Helpers

    static func makeAPI() throws -> Wave4ExtrasAPI {
        let creds = try ASCCredentialResolver.resolve()
        let client = ASCClient(credentials: creds)
        return Wave4ExtrasAPI(client: client)
    }

    /// Reads an int from arguments, accepting both numeric and string
    /// representations (some MCP clients quote integers).
    static func readInt(_ params: CallTool.Parameters, _ key: String) -> Int? {
        if let i = params.arguments?[key]?.intValue { return i }
        if let s = params.arguments?[key]?.stringValue { return Int(s) }
        return nil
    }

    /// Parses a permissive ISO 8601 date string. Returns nil when missing
    /// or unparseable; callers treat nil as "do not set this field".
    static func readDate(_ params: CallTool.Parameters, _ key: String) -> Date? {
        guard let str = params.arguments?[key]?.stringValue, !str.isEmpty else {
            return nil
        }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: str) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: str)
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
