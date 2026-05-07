import Foundation

/// App Store Connect endpoints for the age-rating questionnaire (the
/// "Age Rating" panel in the ASC web UI).
///
/// Each editable AppInfo has exactly one auto-created `ageRatingDeclarations`
/// resource attached. The questionnaire has ~20 multi-state attributes
/// (cartoonOrFantasyViolence, realisticViolence, sexualContentGraphicAndNudity,
/// etc.) that each take one of `NONE` / `INFREQUENT_OR_MILD` /
/// `FREQUENT_OR_INTENSE`, plus a few booleans (gambling, unrestrictedWebAccess,
/// gamblingAndContests) and an enum kidsAgeBand. ASC computes the final
/// rating (4+, 9+, etc.) from these answers automatically.
///
/// PATCH against `/v1/ageRatingDeclarations/{id}` with JSON:API attributes.
/// Resource id is fetched once via the AppInfo's
/// `ageRatingDeclaration` relationship - the orchestrator caches that.
///
/// Apple sometimes adds new attribute fields (most recently `ageRatingOverride`,
/// `loginRequired`). The decoder is permissive: any attribute we don't know
/// about decodes into an opaque dictionary so a forward-compatible read +
/// diff still works without a code change.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/age_rating_declaration
package struct AgeRatingDeclarationsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    /// Per-attribute three-state for "how present is this content?"
    /// Apple represents NONE as the literal string "NONE" rather than null.
    package enum Frequency: String, Codable, Sendable, CaseIterable {
        case none = "NONE"
        case infrequentOrMild = "INFREQUENT_OR_MILD"
        case frequentOrIntense = "FREQUENT_OR_INTENSE"
    }

    /// Used for the kids-section banner. NONE marks the app as not
    /// targeting kids. ASC also accepts `FIVE_AND_UNDER`, `SIX_TO_EIGHT`,
    /// `NINE_TO_ELEVEN`. The schema validates the value server-side, so
    /// we round-trip raw strings to stay forward-compatible if Apple adds
    /// new bands.
    package enum KidsAgeBand: String, Codable, Sendable, CaseIterable {
        case none = "NONE"
        case fiveAndUnder = "FIVE_AND_UNDER"
        case sixToEight = "SIX_TO_EIGHT"
        case nineToEleven = "NINE_TO_ELEVEN"
    }

    /// Strongly-typed view of the declaration's current answers. Every
    /// field is optional because the resource starts blank on a fresh
    /// AppInfo (Apple defaults each frequency to `.none` server-side
    /// after the first GET, but a never-touched record returns nil).
    package struct Declaration: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            // Frequencies (NONE | INFREQUENT_OR_MILD | FREQUENT_OR_INTENSE)
            package var alcoholTobaccoOrDrugUseOrReferences: Frequency?
            package var contests: Frequency?
            package var gamblingSimulated: Frequency?
            package var medicalOrTreatmentInformation: Frequency?
            package var profanityOrCrudeHumor: Frequency?
            package var sexualContentGraphicAndNudity: Frequency?
            package var sexualContentOrNudity: Frequency?
            package var horrorOrFearThemes: Frequency?
            package var matureOrSuggestiveThemes: Frequency?
            package var unrestrictedWebAccess: Bool?
            package var gambling: Bool?
            package var violenceCartoonOrFantasy: Frequency?
            package var violenceRealistic: Frequency?
            package var violenceRealisticProlongedGraphicOrSadistic: Frequency?
            package var violenceProlongedGraphicOrSadistic: Frequency?
            package var ageRatingOverride: String?
            package var kidsAgeBand: KidsAgeBand?
            package var seventeenPlus: Bool?
            // Newer fields (Apple adds these without warning):
            package var loginRequirement: String?
        }
    }

    /// Reads the age-rating declaration linked to an AppInfo via the
    /// `ageRatingDeclaration` relationship. Apple auto-creates a blank
    /// declaration when the AppInfo is created, so this should always
    /// return a record for an editable AppInfo. Returns nil only if Apple
    /// hasn't materialized one yet (rare; normally only on a brand-new
    /// app whose first AppInfo is freshly minted and ASC is still
    /// catching up).
    package func getForAppInfo(appInfoID: String) async throws -> Declaration? {
        struct Resp: Decodable {
            struct DataObj: Decodable {
                let id: String
                let attributes: Declaration.Attributes?
            }
            let data: DataObj?
        }
        do {
            let resp: Resp = try await client.get(
                path: "appInfos/\(appInfoID)/ageRatingDeclaration",
                as: Resp.self
            )
            guard let d = resp.data else { return nil }
            return Declaration(id: d.id, attributes: d.attributes)
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    /// PATCHes the declaration with any non-nil fields. Nil fields stay
    /// untouched. ASC rejects PATCHes whose body is empty (no attributes
    /// changed), so callers must pre-diff and skip the call entirely
    /// when nothing differs.
    @discardableResult
    package func update(
        id: String,
        fields: Declaration.Attributes
    ) async throws -> Declaration {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "ageRatingDeclarations"
                let id: String
                let attributes: Declaration.Attributes
            }
            let data: Data
        }
        let body = Body(data: .init(id: id, attributes: fields))
        struct Resp: Decodable { let data: Declaration }
        let resp: Resp = try await client.patch(
            path: "ageRatingDeclarations/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }
}
