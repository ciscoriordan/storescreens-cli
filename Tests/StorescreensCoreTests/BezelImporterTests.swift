import XCTest
@testable import StorescreensCore

final class BezelImporterTests: XCTestCase {

    // MARK: - Filename parser

    func testFilenameParser_iPhone_portrait() throws {
        let p = try FilenameParser.parse(filename: "iPhone 17 Pro Max - Silver - Portrait.psd")
        XCTAssertEqual(p.model, "iPhone 17 Pro Max")
        XCTAssertEqual(p.colorway, "Silver")
        XCTAssertEqual(p.orientation, .portrait)
        XCTAssertEqual(p.productFamily, 1)
    }

    func testFilenameParser_iPad_withParens_andInches() throws {
        let p = try FilenameParser.parse(filename: "iPad Pro (M5) 13\" - Silver - Landscape.psd")
        XCTAssertEqual(p.model, "iPad Pro (M5) 13\"")
        XCTAssertEqual(p.colorway, "Silver")
        XCTAssertEqual(p.orientation, .landscape)
        XCTAssertEqual(p.productFamily, 2)
    }

    func testFilenameParser_iPadMini() throws {
        let p = try FilenameParser.parse(filename: "iPad mini (A17 Pro) - Blue - Portrait.psd")
        XCTAssertEqual(p.model, "iPad mini (A17 Pro)")
        XCTAssertEqual(p.colorway, "Blue")
        XCTAssertEqual(p.orientation, .portrait)
    }

    func testFilenameParser_MacBook_noDelimiter() throws {
        let p = try FilenameParser.parse(filename: "MacBook Pro M5 14-inch Silver.psd")
        XCTAssertEqual(p.model, "MacBook Pro M5 14-inch")
        XCTAssertEqual(p.colorway, "Silver")
        XCTAssertNil(p.orientation)
        XCTAssertEqual(p.productFamily, 6)
    }

    func testFilenameParser_MacBook_multiwordColorway() throws {
        let p = try FilenameParser.parse(filename: "MacBook Pro M5 16-inch Space Black.psd")
        XCTAssertEqual(p.model, "MacBook Pro M5 16-inch")
        XCTAssertEqual(p.colorway, "Space Black")
    }

    func testFilenameParser_unknownFamily_throws() {
        XCTAssertThrowsError(try FilenameParser.parse(filename: "Pixel 8 - Obsidian.psd"))
    }

    // MARK: - Preference ranking

    func testRanking_prefersEarlierListEntry() {
        let prefs = BezelPreferences(modelOrder: ["Pro Max", "Pro", ""], colorwayOrder: ["Black", "Silver"])
        XCTAssertEqual(BezelImporter.rank(value: "iPhone 17 Pro Max", in: prefs.modelOrder), 0)
        XCTAssertEqual(BezelImporter.rank(value: "iPhone 17 Pro", in: prefs.modelOrder), 1)
        XCTAssertEqual(BezelImporter.rank(value: "iPhone 17", in: prefs.modelOrder), 2) // catchall ""
        XCTAssertEqual(BezelImporter.rank(value: "Silver", in: prefs.colorwayOrder), 1)
        XCTAssertEqual(BezelImporter.rank(value: "Cosmic Orange", in: prefs.colorwayOrder), 2)
    }

    // MARK: - End-to-end against mounted DMGs

    /// Runs the full discover → selectWinners pipeline against whatever DMGs
    /// are mounted under /Volumes. Validates that specific (canonicalKey,
    /// winner) pairs come out correct given the default preferences. Skips if
    /// no DMGs mounted.
    func testEndToEnd_mountedDMGs() throws {
        let volumes = VolumeScanner.findAppleDesignResourceVolumes()
        if volumes.isEmpty {
            print("BezelImporterTests: no DMGs mounted — skipping end-to-end test")
            return
        }

        var warnings: [String] = []
        let candidates = BezelImporter.discover(in: volumes) { warnings.append($0) }
        XCTAssertFalse(candidates.isEmpty, "expected at least one candidate from \(volumes.count) volume(s)")

        let winners = BezelImporter.selectWinners(candidates: candidates)

        // Every canonicalKey should have exactly one winner
        for (key, winner) in winners {
            XCTAssertEqual(winner.canonicalKey, key)
        }

        // Spot-check specific known outcomes
        if candidates.contains(where: { $0.filename.hasPrefix("iPhone 17 Pro Max") && $0.orientation == .portrait }) {
            let key = "iPhone_1320x2868_portrait"
            let winner = winners[key]
            XCTAssertNotNil(winner, "expected winner for \(key)")
            XCTAssertTrue(winner?.modelName.contains("Pro Max") ?? false,
                          "expected 'Pro Max' winner, got \(winner?.modelName ?? "nil")")
        }

        if candidates.contains(where: { $0.filename.hasPrefix("iPad Pro (M5) 13\"") && $0.orientation == .landscape }) {
            let key = "iPad_2752x2064_landscape"
            XCTAssertNotNil(winners[key], "expected winner for \(key)")
        }

        if candidates.contains(where: { $0.filename.hasPrefix("MacBook Pro M5 16-inch") }) {
            let key = "MacBook_3456x2234"
            let winner = winners[key]
            XCTAssertNotNil(winner, "expected winner for \(key)")
            XCTAssertEqual(winner?.orientation, BezelOrientation.none)
            XCTAssertTrue(winner?.modelName.contains("16-inch") ?? false)
        }

        // Default colorway preference favors "Space Black"; check applied
        if let macWinner = winners["MacBook_3456x2234"] {
            XCTAssertEqual(macWinner.colorway, "Space Black")
        }

        // Sanity: print what we selected so failures are easy to diagnose
        for (key, w) in winners.sorted(by: { $0.key < $1.key }) {
            print("  \(key) ← \(w.filename)")
        }
        for msg in warnings {
            print("  warn: \(msg)")
        }
    }
}
