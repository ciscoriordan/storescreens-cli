import XCTest
@testable import StorescreensCore

final class BezelStoreTests: XCTestCase {

    func testCanonicalKey_formats() {
        XCTAssertEqual(
            BezelStore.canonicalKey(productFamily: 1, width: 1320, height: 2868, orientation: .portrait),
            "iPhone_1320x2868_portrait"
        )
        XCTAssertEqual(
            BezelStore.canonicalKey(productFamily: 2, width: 2752, height: 2064, orientation: .landscape),
            "iPad_2752x2064_landscape"
        )
        XCTAssertEqual(
            BezelStore.canonicalKey(productFamily: 6, width: 3456, height: 2234, orientation: .none),
            "MacBook_3456x2234"
        )
    }

    func testLookup_prefersProjectLocalOverUserGlobal() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("storescreens-bezelstore-\(UUID())", isDirectory: true)
        let projectDir = tmp.appendingPathComponent("project/bezels", isDirectory: true)
        let globalDir = tmp.appendingPathComponent("global/bezels", isDirectory: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: globalDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let key = "iPhone_100x200_portrait"
        // Write two different dummy PNGs + JSONs: project version is 1 byte, global is 2 bytes
        let projectPNG = projectDir.appendingPathComponent("\(key).png")
        let projectJSON = projectDir.appendingPathComponent("\(key).json")
        let globalPNG = globalDir.appendingPathComponent("\(key).png")
        let globalJSON = globalDir.appendingPathComponent("\(key).json")
        try Data([0x00]).write(to: projectPNG)
        try Data([0x00, 0x01]).write(to: globalPNG)

        let metadataProject = BezelMetadata(
            canvasWidth: 110, canvasHeight: 210,
            screenX: 5, screenY: 5, screenWidth: 100, screenHeight: 200,
            canonicalKey: key, orientation: .portrait, productFamily: 1,
            sourceFilename: "project.psd"
        )
        let metadataGlobal = BezelMetadata(
            canvasWidth: 120, canvasHeight: 220,
            screenX: 10, screenY: 10, screenWidth: 100, screenHeight: 200,
            canonicalKey: key, orientation: .portrait, productFamily: 1,
            sourceFilename: "global.psd"
        )
        try JSONEncoder().encode(metadataProject).write(to: projectJSON)
        try JSONEncoder().encode(metadataGlobal).write(to: globalJSON)

        let store = BezelStore(projectLocal: projectDir, userGlobal: globalDir)
        let asset = store.lookup(canonicalKey: key)
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.pngURL, projectPNG, "project-local should win")
        XCTAssertEqual(asset?.metadata.sourceFilename, "project.psd")
    }

    func testLookup_returnsNil_whenOnlyPngPresent() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("storescreens-bezelstore-\(UUID())", isDirectory: true)
        let dir = tmp.appendingPathComponent("bezels", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let key = "iPhone_100x200_portrait"
        try Data([0x00]).write(to: dir.appendingPathComponent("\(key).png"))
        // no JSON

        let store = BezelStore(projectLocal: nil, userGlobal: dir)
        XCTAssertNil(store.lookup(canonicalKey: key))
    }

    func testInstalledKeys_listsPairedFiles() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("storescreens-bezelstore-\(UUID())", isDirectory: true)
        let dir = tmp.appendingPathComponent("bezels", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let dummy = BezelMetadata(
            canvasWidth: 1, canvasHeight: 1,
            screenX: 0, screenY: 0, screenWidth: 1, screenHeight: 1,
            canonicalKey: "", orientation: .portrait, productFamily: 1,
            sourceFilename: ""
        )
        let data = try JSONEncoder().encode(dummy)
        for key in ["iPhone_100x200_portrait", "iPad_300x400_landscape"] {
            try Data([0x00]).write(to: dir.appendingPathComponent("\(key).png"))
            try data.write(to: dir.appendingPathComponent("\(key).json"))
        }
        // PNG without JSON — should be excluded
        try Data([0x00]).write(to: dir.appendingPathComponent("Broken_1x1.png"))

        let store = BezelStore(projectLocal: nil, userGlobal: dir)
        let keys = store.installedKeys()
        XCTAssertEqual(keys, ["iPhone_100x200_portrait", "iPad_300x400_landscape"])
    }
}
