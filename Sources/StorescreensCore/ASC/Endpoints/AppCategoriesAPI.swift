import Foundation

/// App Store Connect endpoints for category metadata on the editable
/// `appInfos` resource. The category fields (primary, secondary, and the
/// optional subcategories under each) live as JSON:API relationships on
/// `appInfos`, not as attributes - so the patch shape is
/// `data.relationships.{primaryCategory|secondaryCategory|...}.data` rather
/// than `data.attributes.*`.
///
/// Important quirk we hit while building this: ASC's relationship-only
/// endpoints (e.g. `PATCH /v1/appInfos/{id}/relationships/primaryCategory`)
/// return 403 FORBIDDEN_ERROR with detail "does not allow UPDATE" for these
/// fields. The only path that works programmatically is a single PATCH
/// against the parent `/v1/appInfos/{id}` carrying every relationship
/// update in one body. All six category slots can be set in one request.
///
/// Categories can only be edited while the app's editable AppInfo record is
/// in `PREPARE_FOR_SUBMISSION` (or another editable state). When the only
/// AppInfo is `READY_FOR_SALE`, the PATCH 409s and `submit` skips with the
/// same skip-reason path used for name/subtitle.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/list_all_app_categories
package struct AppCategoriesAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    /// One row from `GET /v1/appCategories`. The id is the canonical Apple
    /// category code, all uppercase with underscores (e.g. "EDUCATION",
    /// "PHOTO_AND_VIDEO"). Subcategory ids share the same shape and are
    /// returned by the parent's `subcategories` relationship.
    package struct Category: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Platforms this category surface applies to ("IOS",
            /// "MAC_OS", etc.). Used to scope listCategories to iOS.
            package let platforms: [String]?
        }
    }

    /// Lists every primary App Store category. Filtered to the iOS platforms
    /// since that's the only surface `submit` ships today. Used to validate
    /// the user's `categories.primary` / `categories.secondary` choice during
    /// `submit --dry-run` so a typo fails before writing.
    ///
    /// `limit=200` returns the full set in one request - Apple ships ~30
    /// primary categories, well under the page size cap.
    package func listCategories(platforms: [String] = ["IOS"]) async throws -> [Category] {
        struct Resp: Decodable { let data: [Category] }
        var query: [String: String] = ["limit": "200"]
        if !platforms.isEmpty {
            query["filter[platforms]"] = platforms.joined(separator: ",")
        }
        let resp: Resp = try await client.get(
            path: "appCategories",
            query: query,
            as: Resp.self
        )
        return resp.data
    }

    /// Patches the editable AppInfo's category relationships. Each field is
    /// tri-state:
    ///
    /// - `nil`           -> omit from PATCH body (leave ASC value untouched)
    /// - `.set(id)`      -> point this slot at the given category id
    /// - `.clear`        -> explicit `data: null`, removes whatever was there
    ///
    /// All six slots can be set in a single PATCH; ASC accepts any subset.
    @discardableResult
    package func updateCategories(
        appInfoID: String,
        primary: CategoryUpdate? = nil,
        secondary: CategoryUpdate? = nil,
        primarySubcategoryOne: CategoryUpdate? = nil,
        primarySubcategoryTwo: CategoryUpdate? = nil,
        secondarySubcategoryOne: CategoryUpdate? = nil,
        secondarySubcategoryTwo: CategoryUpdate? = nil
    ) async throws -> AppsAPI.AppInfo {
        let body = CategoriesPatch(
            data: .init(
                id: appInfoID,
                relationships: .init(
                    primaryCategory: primary,
                    secondaryCategory: secondary,
                    primarySubcategoryOne: primarySubcategoryOne,
                    primarySubcategoryTwo: primarySubcategoryTwo,
                    secondarySubcategoryOne: secondarySubcategoryOne,
                    secondarySubcategoryTwo: secondarySubcategoryTwo
                )
            )
        )
        struct Resp: Decodable { let data: AppsAPI.AppInfo }
        let resp: Resp = try await client.patch(
            path: "appInfos/\(appInfoID)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// Reads the current category relationships off an AppInfo so the
    /// submit flow can diff before patching. Returns nil ids for any
    /// unset slot.
    ///
    /// Categories live as relationships on the appInfos resource. Apple
    /// returns them in the GET response automatically; we don't need a
    /// separate `?include=` query. Each relationship block has shape
    /// `{ data: null | { type, id } }`.
    package func currentCategories(
        appInfoID: String
    ) async throws -> CurrentCategories {
        struct Resp: Decodable {
            struct DataObj: Decodable {
                let id: String
                let relationships: Relationships?
            }
            struct Relationships: Decodable {
                struct Rel: Decodable {
                    struct Ref: Decodable { let id: String? }
                    let data: Ref?
                }
                let primaryCategory: Rel?
                let secondaryCategory: Rel?
                let primarySubcategoryOne: Rel?
                let primarySubcategoryTwo: Rel?
                let secondarySubcategoryOne: Rel?
                let secondarySubcategoryTwo: Rel?
            }
            let data: DataObj
        }
        let resp: Resp = try await client.get(
            path: "appInfos/\(appInfoID)",
            as: Resp.self
        )
        let rels = resp.data.relationships
        return CurrentCategories(
            primary: rels?.primaryCategory?.data?.id,
            secondary: rels?.secondaryCategory?.data?.id,
            primarySubcategoryOne: rels?.primarySubcategoryOne?.data?.id,
            primarySubcategoryTwo: rels?.primarySubcategoryTwo?.data?.id,
            secondarySubcategoryOne: rels?.secondarySubcategoryOne?.data?.id,
            secondarySubcategoryTwo: rels?.secondarySubcategoryTwo?.data?.id
        )
    }

    package struct CurrentCategories: Sendable, Equatable {
        package let primary: String?
        package let secondary: String?
        package let primarySubcategoryOne: String?
        package let primarySubcategoryTwo: String?
        package let secondarySubcategoryOne: String?
        package let secondarySubcategoryTwo: String?
    }

    /// Tri-state intent for one category slot. The wire JSON differs
    /// fundamentally between "leave alone" (omit) and "clear" (data: null),
    /// so we can't model this with `String?` alone.
    package enum CategoryUpdate: Sendable, Equatable {
        case set(String)
        case clear
    }
}

// MARK: - Encoder shapes

/// Top-level body encoder. We can't use the synthesized `Encodable` here
/// because each `CategoryUpdate` field needs to round-trip three states
/// (omit, set, clear) and Swift's default `encodeIfPresent` only models two
/// (omit on nil, otherwise emit). The custom `encode(to:)` below uses
/// `encodeIfPresent` for "omit" and a manual `encodeNil` branch for "clear".
private struct CategoriesPatch: Encodable {
    let data: DataObj

    struct DataObj: Encodable {
        let type = "appInfos"
        let id: String
        let relationships: Relationships
    }

    struct Relationships: Encodable {
        var primaryCategory: AppCategoriesAPI.CategoryUpdate?
        var secondaryCategory: AppCategoriesAPI.CategoryUpdate?
        var primarySubcategoryOne: AppCategoriesAPI.CategoryUpdate?
        var primarySubcategoryTwo: AppCategoriesAPI.CategoryUpdate?
        var secondarySubcategoryOne: AppCategoriesAPI.CategoryUpdate?
        var secondarySubcategoryTwo: AppCategoriesAPI.CategoryUpdate?

        enum CodingKeys: String, CodingKey {
            case primaryCategory, secondaryCategory
            case primarySubcategoryOne, primarySubcategoryTwo
            case secondarySubcategoryOne, secondarySubcategoryTwo
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try Self.encodeSlot(primaryCategory,         to: &c, key: .primaryCategory)
            try Self.encodeSlot(secondaryCategory,       to: &c, key: .secondaryCategory)
            try Self.encodeSlot(primarySubcategoryOne,   to: &c, key: .primarySubcategoryOne)
            try Self.encodeSlot(primarySubcategoryTwo,   to: &c, key: .primarySubcategoryTwo)
            try Self.encodeSlot(secondarySubcategoryOne, to: &c, key: .secondarySubcategoryOne)
            try Self.encodeSlot(secondarySubcategoryTwo, to: &c, key: .secondarySubcategoryTwo)
        }

        /// Encodes one relationship slot with the JSON:API "data: { type,
        /// id } | null" envelope. nil intent omits the slot entirely.
        private static func encodeSlot(
            _ update: AppCategoriesAPI.CategoryUpdate?,
            to container: inout KeyedEncodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws {
            guard let update else { return }
            // Open a nested keyed container { data: ... } so we can choose
            // between encodeNil (clear) and encoding a Ref (set).
            var nested = container.nestedContainer(
                keyedBy: DataKey.self, forKey: key
            )
            switch update {
            case .set(let id):
                try nested.encode(Ref(type: "appCategories", id: id), forKey: .data)
            case .clear:
                try nested.encodeNil(forKey: .data)
            }
        }
    }

    /// Coding key for the `data:` nested member of each relationship slot.
    private enum DataKey: String, CodingKey { case data }

    private struct Ref: Encodable {
        let type: String
        let id: String
    }
}
