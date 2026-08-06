import XCTest
import Yams
@testable import StorescreensCore

/// Unit tests for the `app_store_connect:` YAML config parsing.
/// Covers the categories / age_rating / review_info sections that were
/// added on top of the original submit/pricing/availability/upload-build
/// blocks, plus a smoke check that the existing pricing/availability
/// shapes still parse alongside the new fields.
final class AppStoreConnectConfigTests: XCTestCase {

    // MARK: - Helpers

    private func decode(_ yaml: String) throws -> AppStoreConnectConfig {
        let decoder = YAMLDecoder()
        return try decoder.decode(AppStoreConnectConfig.self, from: yaml)
    }

    // MARK: - Categories

    func testCategoriesConfig_primaryAndSecondary() throws {
        let yaml = """
        bundle_id: com.example.app
        categories:
          primary: EDUCATION
          secondary: REFERENCE
        """
        let config = try decode(yaml)
        XCTAssertEqual(config.categories?.primary, "EDUCATION")
        XCTAssertEqual(config.categories?.secondary, "REFERENCE")
        XCTAssertNil(config.categories?.primarySubcategoryOne)
    }

    func testCategoriesConfig_subcategories() throws {
        let yaml = """
        bundle_id: com.example.app
        categories:
          primary: GAMES
          primary_subcategory_one: GAMES_ACTION
          primary_subcategory_two: GAMES_ADVENTURE
        """
        let config = try decode(yaml)
        XCTAssertEqual(config.categories?.primary, "GAMES")
        XCTAssertEqual(config.categories?.primarySubcategoryOne, "GAMES_ACTION")
        XCTAssertEqual(config.categories?.primarySubcategoryTwo, "GAMES_ADVENTURE")
    }

    func testCategoriesConfig_clearWithNone() throws {
        // The literal string "none" is the explicit-clear sigil. Decode
        // it as-is; the orchestrator translates to a JSON:API
        // `{ data: null }` patch.
        let yaml = """
        bundle_id: com.example.app
        categories:
          primary: EDUCATION
          secondary: none
        """
        let config = try decode(yaml)
        XCTAssertEqual(config.categories?.secondary, "none")
    }

    // MARK: - Age rating

    func testAgeRatingConfig_allFrequenciesAndBooleans() throws {
        let yaml = """
        bundle_id: com.example.app
        age_rating:
          cartoon_or_fantasy_violence: NONE
          realistic_violence: INFREQUENT_OR_MILD
          profanity_or_crude_humor: FREQUENT_OR_INTENSE
          gambling: false
          unrestricted_web_access: true
          kids_age_band: NONE
        """
        let config = try decode(yaml)
        let ar = try XCTUnwrap(config.ageRating)
        // Spell `Frequency.none` out fully so the optional-vs-enum
        // disambiguation lands on the enum case (otherwise `.none` is
        // parsed as `Optional.none` -> nil).
        XCTAssertEqual(ar.cartoonOrFantasyViolence, AgeRatingConfig.Frequency.none)
        XCTAssertEqual(ar.realisticViolence, AgeRatingConfig.Frequency.infrequentOrMild)
        XCTAssertEqual(ar.profanityOrCrudeHumor, AgeRatingConfig.Frequency.frequentOrIntense)
        XCTAssertEqual(ar.gambling, false)
        XCTAssertEqual(ar.unrestrictedWebAccess, true)
        XCTAssertEqual(ar.kidsAgeBand, AgeRatingConfig.KidsAgeBand.none)
    }

    func testAgeRatingConfig_kidsAgeBandValues() throws {
        // Each non-NONE band parses; the rest of the doc is silent on
        // them, so just round-trip through Codable.
        for band in AgeRatingDeclarationsAPI.KidsAgeBand.allCases {
            let yaml = """
            bundle_id: com.example.app
            age_rating:
              kids_age_band: \(band.rawValue)
            """
            let config = try decode(yaml)
            XCTAssertEqual(config.ageRating?.kidsAgeBand, band, "for \(band.rawValue)")
        }
    }

    func testAgeRatingConfig_unknownFrequencyRejected() {
        // Codable raises on a typo. Keeps a misnamed enum from silently
        // becoming a NONE.
        let yaml = """
        bundle_id: com.example.app
        age_rating:
          cartoon_or_fantasy_violence: SOMETIMES
        """
        XCTAssertThrowsError(try decode(yaml))
    }

    // MARK: - Review info

    func testReviewInfoConfig_minimalContact() throws {
        let yaml = """
        bundle_id: com.example.app
        review_info:
          first_name: Jane
          last_name: Doe
          phone_number: "+1 555 123 4567"
          email_address: jane@example.com
        """
        let config = try decode(yaml)
        let r = try XCTUnwrap(config.reviewInfo)
        XCTAssertEqual(r.firstName, "Jane")
        XCTAssertEqual(r.lastName, "Doe")
        XCTAssertEqual(r.phoneNumber, "+1 555 123 4567")
        XCTAssertEqual(r.emailAddress, "jane@example.com")
        XCTAssertNil(r.demoAccountRequired)
    }

    func testReviewInfoConfig_demoAccountAutoEnable() throws {
        // Supplying demo_account_name implies demo_account_required: true
        // unless the user explicitly says otherwise.
        let yaml = """
        bundle_id: com.example.app
        review_info:
          demo_account_name: tester@example.com
          demo_account_password: hunter2
        """
        let config = try decode(yaml)
        let fields = try XCTUnwrap(config.reviewInfo).asReviewDetailFields
        XCTAssertEqual(fields.demoAccountRequired, true)
        XCTAssertEqual(fields.demoAccountName, "tester@example.com")
    }

    func testReviewInfoConfig_explicitDemoNotRequired() throws {
        // Even with demo creds present, an explicit `false` wins.
        let yaml = """
        bundle_id: com.example.app
        review_info:
          demo_account_required: false
          demo_account_name: tester@example.com
        """
        let config = try decode(yaml)
        let fields = try XCTUnwrap(config.reviewInfo).asReviewDetailFields
        XCTAssertEqual(fields.demoAccountRequired, false)
    }

    func testReviewInfoConfig_multilineNotes() throws {
        // YAML pipe literal: keep the multi-line shape verbatim except
        // the final trailing newline strip handled at PATCH time.
        let yaml = """
        bundle_id: com.example.app
        review_info:
          notes: |
            Line one.
            Line two.
        """
        let config = try decode(yaml)
        let n = try XCTUnwrap(config.reviewInfo?.notes)
        XCTAssertTrue(n.contains("Line one."))
        XCTAssertTrue(n.contains("Line two."))
    }

    // MARK: - Coexistence with existing blocks

    func testFullConfig_oldAndNewBlocksCoexist() throws {
        let yaml = """
        bundle_id: com.example.app
        metadata_dir: ./metadata

        submit:
          create_version: "1.0"
          screenshots: true

        pricing:
          free: true

        availability:
          territories: all

        categories:
          primary: EDUCATION
          secondary: REFERENCE

        age_rating:
          cartoon_or_fantasy_violence: NONE
          gambling: false

        review_info:
          first_name: Jane
          last_name: Doe
          email_address: jane@example.com
          notes: Test notes
        """
        let config = try decode(yaml)
        XCTAssertEqual(config.bundleID, "com.example.app")
        XCTAssertEqual(config.submit?.createVersion, "1.0")
        XCTAssertEqual(config.pricing?.free, true)
        XCTAssertEqual(config.availability?.territories, .all)
        XCTAssertEqual(config.categories?.primary, "EDUCATION")
        XCTAssertEqual(config.ageRating?.gambling, false)
        XCTAssertEqual(config.reviewInfo?.firstName, "Jane")
    }

    // MARK: - Pricing (paid + per-territory)

    func testPricingConfig_paidBasePriceOnly() throws {
        let yaml = """
        bundle_id: com.example.app
        pricing:
          base_territory: USA
          base_price: "4.99"
        """
        let config = try decode(yaml)
        XCTAssertNil(config.pricing?.free)
        XCTAssertEqual(config.pricing?.baseTerritory, "USA")
        XCTAssertEqual(config.pricing?.basePrice, "4.99")
        XCTAssertNil(config.pricing?.territoryPrices)
    }

    func testPricingConfig_perTerritoryOverrides() throws {
        let yaml = """
        bundle_id: com.example.app
        pricing:
          base_price: "4.99"
          territory_prices:
            GBR: "3.99"
            JPN: "600"
        """
        let config = try decode(yaml)
        XCTAssertEqual(config.pricing?.basePrice, "4.99")
        XCTAssertEqual(config.pricing?.territoryPrices?["GBR"], "3.99")
        XCTAssertEqual(config.pricing?.territoryPrices?["JPN"], "600")
        XCTAssertEqual(config.pricing?.territoryPrices?.count, 2)
    }

    // MARK: - Submission info (IDFA + content rights)

    func testSubmissionInfo_bothAnswers() throws {
        let yaml = """
        bundle_id: com.example.app
        submission_info:
          uses_idfa: false
          contains_third_party_content: true
        """
        let config = try decode(yaml)
        XCTAssertEqual(config.submissionInfo?.usesIdfa, false)
        XCTAssertEqual(config.submissionInfo?.containsThirdPartyContent, true)
    }

    func testSubmissionInfo_partialLeavesOtherNil() throws {
        let yaml = """
        bundle_id: com.example.app
        submission_info:
          uses_idfa: true
        """
        let config = try decode(yaml)
        XCTAssertEqual(config.submissionInfo?.usesIdfa, true)
        XCTAssertNil(config.submissionInfo?.containsThirdPartyContent)
    }

    func testContentRightsDeclaration_wireValues() {
        XCTAssertEqual(
            AppsAPI.ContentRightsDeclaration(containsThirdPartyContent: true).rawValue,
            "USES_THIRD_PARTY_CONTENT"
        )
        XCTAssertEqual(
            AppsAPI.ContentRightsDeclaration(containsThirdPartyContent: false).rawValue,
            "DOES_NOT_USE_THIRD_PARTY_CONTENT"
        )
    }

    // MARK: - Release scheduling

    func testRelease_scheduledWithDate() throws {
        let yaml = """
        bundle_id: com.example.app
        release:
          type: scheduled
          earliest_release_date: "2026-08-10T12:00:00-07:00"
        """
        let config = try decode(yaml)
        XCTAssertEqual(config.release?.type, .scheduled)
        XCTAssertEqual(config.release?.earliestReleaseDate, "2026-08-10T12:00:00-07:00")
        XCTAssertEqual(config.release?.type?.wireValue, .scheduled)
    }

    func testRelease_manualAndAfterApprovalWireValues() throws {
        let manual = try decode("""
        bundle_id: com.example.app
        release:
          type: manual
        """)
        XCTAssertEqual(manual.release?.type?.wireValue.rawValue, "MANUAL")
        XCTAssertNil(manual.release?.earliestReleaseDate)

        let auto = try decode("""
        bundle_id: com.example.app
        release:
          type: after_approval
        """)
        XCTAssertEqual(auto.release?.type?.wireValue.rawValue, "AFTER_APPROVAL")
    }

    func testRelease_unknownTypeRejected() {
        let yaml = """
        bundle_id: com.example.app
        release:
          type: whenever
        """
        XCTAssertThrowsError(try decode(yaml))
    }

    /// An unquoted ISO date is a real YAML trap: Yams parses it into a
    /// timestamp scalar rather than a string. Decoding it into our
    /// `String?` field has to keep working, otherwise anyone who forgets
    /// the quotes gets a confusing type error instead of a release date.
    func testRelease_unquotedDateStillDecodes() throws {
        let yaml = """
        bundle_id: com.example.app
        release:
          type: scheduled
          earliest_release_date: 2026-08-10T12:00:00-07:00
        """
        let config = try decode(yaml)
        XCTAssertNotNil(config.release?.earliestReleaseDate)
    }
}
