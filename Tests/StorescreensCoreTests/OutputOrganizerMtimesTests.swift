import XCTest
import Foundation
@testable import StorescreensCore

/// Verifies that `OutputOrganizer.stampMtimes` rewrites the mtime and
/// creationDate of each on-disk PNG so `ls -t` / Finder "Date Created"
/// sort matches the configured `screenshots:` order.
final class OutputOrganizerMtimesTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stamp-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - No-op when order is nil/empty

    func testStampMtimes_noop_whenOrderIsNil() throws {
        let manifest = makeManifest(names: ["Home", "Search", "Detail"])
        try writePNGs(for: manifest)

        let before = try modificationDates(for: manifest)
        OutputOrganizer().stampMtimes(manifest: manifest, outputDir: tmp.path, order: nil)
        let after = try modificationDates(for: manifest)

        for (name, date) in before {
            XCTAssertEqual(
                date.timeIntervalSince1970,
                after[name]!.timeIntervalSince1970,
                accuracy: 0.001,
                "mtime for '\(name)' should be unchanged when order is nil"
            )
        }
    }

    func testStampMtimes_noop_whenOrderIsEmpty() throws {
        let manifest = makeManifest(names: ["Home", "Search"])
        try writePNGs(for: manifest)

        let before = try modificationDates(for: manifest)
        OutputOrganizer().stampMtimes(manifest: manifest, outputDir: tmp.path, order: [])
        let after = try modificationDates(for: manifest)

        for (name, date) in before {
            XCTAssertEqual(
                date.timeIntervalSince1970,
                after[name]!.timeIntervalSince1970,
                accuracy: 0.001
            )
        }
    }

    // MARK: - Order matches config

    /// First name in order gets the most recent mtime; each subsequent entry
    /// is progressively older. `ls -t` shows them in config order.
    func testStampMtimes_listedNamesAreOrderedNewestFirst() throws {
        let manifest = makeManifest(names: ["Home", "Search", "Detail", "Settings"])
        try writePNGs(for: manifest)

        let order = ["Home", "Search", "Detail", "Settings"]
        OutputOrganizer().stampMtimes(manifest: manifest, outputDir: tmp.path, order: order)

        let mtimes = try modificationDates(for: manifest)
        // Each consecutive pair: earlier-listed entry has strictly greater mtime.
        for i in 0..<(order.count - 1) {
            let earlier = mtimes[order[i]]!
            let later = mtimes[order[i + 1]]!
            XCTAssertGreaterThan(
                earlier.timeIntervalSince1970, later.timeIntervalSince1970,
                "'\(order[i])' (index \(i)) must have a newer mtime than '\(order[i + 1])'"
            )
        }
    }

    func testStampMtimes_unlistedNamesSortAfterListed() throws {
        // Home and Detail are in order; Search is not.
        let manifest = makeManifest(names: ["Home", "Search", "Detail"])
        try writePNGs(for: manifest)

        OutputOrganizer().stampMtimes(
            manifest: manifest, outputDir: tmp.path,
            order: ["Home", "Detail"]
        )

        let mtimes = try modificationDates(for: manifest)
        XCTAssertGreaterThan(mtimes["Home"]!, mtimes["Detail"]!)
        XCTAssertGreaterThan(mtimes["Detail"]!, mtimes["Search"]!,
            "unlisted 'Search' must sort after listed entries")
    }

    // MARK: - creationDate parity

    /// Finder's "Date Created" reads `creationDate`. Verify we set it too.
    func testStampMtimes_setsCreationDate() throws {
        let manifest = makeManifest(names: ["Home", "Search"])
        try writePNGs(for: manifest)

        OutputOrganizer().stampMtimes(
            manifest: manifest, outputDir: tmp.path,
            order: ["Home", "Search"]
        )

        for shot in manifest.devices[0].screenshots {
            let path = tmp.appendingPathComponent(shot.filename).path
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let modDate = attrs[.modificationDate] as! Date
            let creationDate = attrs[.creationDate] as! Date
            XCTAssertEqual(
                modDate.timeIntervalSince1970,
                creationDate.timeIntervalSince1970,
                accuracy: 0.001,
                "\(shot.name): creationDate should match modificationDate"
            )
        }
    }

    // MARK: - Helpers

    private func makeManifest(names: [String]) -> CaptureManifest {
        let shots = names.map {
            CaptureManifest.Screenshot(
                name: $0,
                filename: "iPhone_6.9_\($0).png",
                capturedAt: Date()
            )
        }
        let device = CaptureManifest.DeviceCapture(
            deviceType: "iPhone 6.9\"",
            simulatorName: "iPhone 17 Pro Max",
            locale: nil,
            appearance: nil,
            screenshots: shots
        )
        return CaptureManifest(
            version: 2,
            generatedAt: Date(),
            generatedBy: "test",
            appName: "Test",
            displayName: "Test",
            scheme: "Test",
            devices: [device]
        )
    }

    private func writePNGs(for manifest: CaptureManifest) throws {
        for device in manifest.devices {
            for shot in device.screenshots {
                let url = tmp.appendingPathComponent(shot.filename)
                // Minimal 1x1 PNG; just need a real file on disk for attribute ops.
                try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: url)
            }
        }
    }

    private func modificationDates(for manifest: CaptureManifest) throws -> [String: Date] {
        var out: [String: Date] = [:]
        for device in manifest.devices {
            for shot in device.screenshots {
                let path = tmp.appendingPathComponent(shot.filename).path
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                out[shot.name] = attrs[.modificationDate] as? Date
            }
        }
        return out
    }
}
