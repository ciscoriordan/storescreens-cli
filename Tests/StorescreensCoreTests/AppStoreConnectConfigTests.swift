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
}
