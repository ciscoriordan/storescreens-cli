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

    func testFilenameParser_duoPoseNamesOrientation() throws {
        let inner = try FilenameParser.parse(filename: "iPhone Duo - Night Sky - Inner Open Landscape.psd")
        XCTAssertEqual(inner.model, "iPhone Duo")
        XCTAssertEqual(inner.colorway, "Night Sky")
        XCTAssertEqual(inner.orientation, .landscape)
        XCTAssertEqual(inner.productFamily, 1)

        let outer = try FilenameParser.parse(filename: "iPhone Duo - Star White - Outer Closed Portrait.psd")
        XCTAssertEqual(outer.colorway, "Star White")
        XCTAssertEqual(outer.orientation, .portrait)

        // No orientation word: left to the Screen layer's box.
        let open = try FilenameParser.parse(filename: "iPhone Duo - Night Sky - Outer Open.psd")
        XCTAssertNil(open.orientation)
    }

    func testFilenameParser_orientationWordIsCaseInsensitiveWholeWord() {
        XCTAssertEqual(FilenameParser.orientation(inPose: "LANDSCAPE"), .landscape)
        XCTAssertEqual(FilenameParser.orientation(inPose: "Outer Closed portrait"), .portrait)
        XCTAssertNil(FilenameParser.orientation(inPose: "Outer Open"))
        XCTAssertNil(FilenameParser.orientation(inPose: "Portraiture"))
        XCTAssertNil(FilenameParser.orientation(inPose: "Portrait and Landscape"))
    }

    func testResolveOrientation_withoutWordUsesScreenBoxNotCanvas() throws {
        // "Outer Open": a 3056x2194 landscape canvas around a portrait
        // 1398x2034 outer display.
        let parsed = try FilenameParser.parse(filename: "iPhone Duo - Night Sky - Outer Open.psd")
        let orientation = BezelImporter.resolveOrientation(
            parsed: parsed,
            screenBBox: CGRect(x: 1570, y: 80, width: 1398, height: 2034)
        )
        XCTAssertEqual(orientation, .portrait)
        XCTAssertEqual(
            BezelImporter.makeCanonicalKey(productFamily: 1, screenBBox: CGRect(x: 1570, y: 80, width: 1398, height: 2034), orientation: orientation),
            "iPhone_1398x2034_portrait"
        )

        // A stated orientation still wins over the box.
        let stated = try FilenameParser.parse(filename: "iPhone 18 Pro - Black - Landscape.psd")
        XCTAssertEqual(
            BezelImporter.resolveOrientation(parsed: stated, screenBBox: CGRect(x: 0, y: 0, width: 10, height: 20)),
            .landscape
        )
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

    private func candidate(_ filename: String, screen: CGSize = CGSize(width: 1398, height: 2034)) throws -> BezelCandidate {
        let parsed = try FilenameParser.parse(filename: filename)
        let bbox = CGRect(origin: CGPoint(x: 80, y: 80), size: screen)
        let orientation = BezelImporter.resolveOrientation(parsed: parsed, screenBBox: bbox)
        return BezelCandidate(
            sourceURL: URL(fileURLWithPath: "/Volumes/test/\(filename)"),
            filename: filename,
            modelName: parsed.model,
            colorway: parsed.colorway,
            orientation: orientation,
            orientationIsExplicit: parsed.orientation != nil,
            productFamily: parsed.productFamily,
            canvasSize: CGSize(width: screen.width + 160, height: screen.height + 160),
            screenBBox: bbox,
            canonicalKey: BezelImporter.makeCanonicalKey(productFamily: parsed.productFamily, screenBBox: bbox, orientation: orientation)
        )
    }

    func testRanking_statedOrientationBeatsDerived() throws {
        // Same key (iPhone_1398x2034_portrait). "Outer Open" has the
        // preferred colorway, but only the other one says it is portrait.
        let group = [
            try candidate("iPhone Duo - Night Sky - Outer Open.psd"),
            try candidate("iPhone Duo - Star White - Outer Closed Portrait.psd"),
        ]
        XCTAssertEqual(Set(group.map(\.canonicalKey)), ["iPhone_1398x2034_portrait"])
        let winner = BezelImporter.pickBest(from: group, preferences: .defaults)
        XCTAssertEqual(winner.filename, "iPhone Duo - Star White - Outer Closed Portrait.psd")
    }

    func testRanking_duoDefaultsToDarkColorway() throws {
        let group = [
            try candidate("iPhone Duo - Star White - Outer Closed Portrait.psd"),
            try candidate("iPhone Duo - Night Sky - Outer Closed Portrait.psd"),
            try candidate("iPhone Duo - Night Sky - Outer Open.psd"),
        ]
        let winner = BezelImporter.pickBest(from: group, preferences: .defaults)
        XCTAssertEqual(winner.filename, "iPhone Duo - Night Sky - Outer Closed Portrait.psd")
        // By preference, not by the alphabetical fallback.
        let order = BezelPreferences.defaults.colorwayOrder
        XCTAssertLessThan(BezelImporter.rank(value: "Night Sky", in: order), BezelImporter.rank(value: "Star White", in: order))
    }

    func testRanking_iPhone18ProDefaultsToBlack() throws {
        let screen = CGSize(width: 1206, height: 2622)
        let group = try ["Silver", "Glacier", "Burgundy", "Black"].map {
            try candidate("iPhone 18 Pro - \($0) - Portrait.psd", screen: screen)
        }
        XCTAssertEqual(BezelImporter.pickBest(from: group, preferences: .defaults).colorway, "Black")
    }

    func testRanking_newerGenerationWinsWithinModelLine() throws {
        let screen = CGSize(width: 1320, height: 2868)
        // The 17 Pro Max offers the better-ranked colorway ("Silver"); the
        // newer generation still wins.
        let group = [
            try candidate("iPhone 17 Pro Max - Silver - Portrait.psd", screen: screen),
            try candidate("iPhone 18 Pro Max - Glacier - Portrait.psd", screen: screen),
            try candidate("iPhone 18 Pro Max - Burgundy - Portrait.psd", screen: screen),
        ]
        let winner = BezelImporter.pickBest(from: group, preferences: .defaults)
        XCTAssertEqual(winner.modelName, "iPhone 18 Pro Max")
        XCTAssertEqual(winner.colorway, "Burgundy") // neither ranked: alphabetical

        // An explicit model preference still outranks the generation.
        let prefs = BezelPreferences(modelOrder: ["iPhone 17 Pro Max", ""], colorwayOrder: [])
        XCTAssertEqual(BezelImporter.pickBest(from: group, preferences: prefs).modelName, "iPhone 17 Pro Max")
    }

    func testGeneration_parsesIPhoneNumbersOnly() {
        XCTAssertEqual(BezelImporter.generation(of: "iPhone 18 Pro Max"), 18)
        XCTAssertEqual(BezelImporter.generation(of: "iPhone 17"), 17)
        XCTAssertEqual(BezelImporter.generation(of: "iPhone 16e"), 16)
        XCTAssertNil(BezelImporter.generation(of: "iPhone Duo"))
        XCTAssertNil(BezelImporter.generation(of: "iPhone Air"))
        XCTAssertNil(BezelImporter.generation(of: "iPad Pro (M5) 13\""))
        XCTAssertNil(BezelImporter.generation(of: "MacBook Pro M5 14-inch"))
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

        // iPhone 18 Pro / Pro Max: dark finish by default, and the newer
        // generation when the iPhone 17 DMG is mounted as well.
        if candidates.contains(where: { $0.modelName == "iPhone 18 Pro Max" }) {
            XCTAssertEqual(winners["iPhone_1320x2868_portrait"]?.modelName, "iPhone 18 Pro Max")
            XCTAssertEqual(winners["iPhone_1320x2868_portrait"]?.colorway, "Black")
        }
        if candidates.contains(where: { $0.modelName == "iPhone 18 Pro" }) {
            XCTAssertEqual(winners["iPhone_1206x2622_portrait"]?.filename, "iPhone 18 Pro - Black - Portrait.psd")
            XCTAssertEqual(winners["iPhone_2622x1206_landscape"]?.filename, "iPhone 18 Pro - Black - Landscape.psd")
        }

        // iPhone Duo: one winner per display and orientation, and the open
        // phone ("Outer Open") never claims a key of its own.
        if candidates.contains(where: { $0.modelName == "iPhone Duo" }) {
            let expected = [
                "iPhone_1398x2034_portrait": "iPhone Duo - Night Sky - Outer Closed Portrait.psd",
                "iPhone_2034x1398_landscape": "iPhone Duo - Night Sky - Outer Closed Landscape.psd",
                "iPhone_2007x2853_portrait": "iPhone Duo - Night Sky - Inner Open Portrait.psd",
                "iPhone_2853x2007_landscape": "iPhone Duo - Night Sky - Inner Open Landscape.psd",
            ]
            for (key, filename) in expected {
                XCTAssertEqual(winners[key]?.filename, filename, "winner for \(key)")
            }
            XCTAssertNil(winners["iPhone_1398x2034_landscape"])
            let outerOpen = candidates.filter { $0.filename.hasSuffix("Outer Open.psd") }
            XCTAssertFalse(outerOpen.isEmpty)
            XCTAssertTrue(outerOpen.allSatisfy { $0.canonicalKey == "iPhone_1398x2034_portrait" && !$0.orientationIsExplicit })
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
