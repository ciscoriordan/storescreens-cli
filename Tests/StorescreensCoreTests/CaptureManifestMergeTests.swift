import XCTest
@testable import StorescreensCore

/// `CaptureManifest.merged(over:scope:)`: what manifest.json holds after a
/// capture run. A run narrowed by `--locale`, `--appearance` or `--only`
/// used to replace the whole file with its own entries, so the next
/// `submit` uploaded only what that run captured.
final class CaptureManifestMergeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_790_086_400)

    private func entry(
        _ device: String, _ locale: String?, appearance: String? = nil,
        shots: [String], at date: Date
    ) -> CaptureManifest.DeviceCapture {
        let deviceType = device == "iPad" ? "iPad Pro 13\"" : "iPhone 6.9\""
        let simulator = device == "iPad" ? "iPad Pro 13-inch (M5)" : "iPhone 17 Pro Max"
        let prefix = device == "iPad" ? "iPad_Pro_13" : "iPhone_6.9"
        let dir = [locale, appearance].compactMap { $0 }.joined(separator: "/")
        return CaptureManifest.DeviceCapture(
            deviceType: deviceType, simulatorName: simulator,
            locale: locale, appearance: appearance,
            screenshots: shots.map { .init(name: $0, filename: "\(dir)/\(prefix)_\($0).png", capturedAt: date) }
        )
    }

    private func manifest(_ devices: [CaptureManifest.DeviceCapture], at date: Date) -> CaptureManifest {
        CaptureManifest(
            version: 2, generatedAt: date, generatedBy: "storescreens-cli test",
            appName: "App", displayName: "App", scheme: "App", devices: devices
        )
    }

    /// (device, locale, appearance, capture time) per entry, in order.
    private func summary(_ m: CaptureManifest) -> [String] {
        m.devices.map { d in
            let time = d.screenshots.first?.capturedAt == t1 ? "new" : "old"
            return "\(d.simulatorName.hasPrefix("iPad") ? "iPad" : "iPhone") \(d.locale ?? "-") \(d.appearance ?? "-") \(time)"
        }
    }

    private let slides = ["polytonic", "spellcheck", "typeahead"]

    private var existing: CaptureManifest {
        manifest([
            entry("iPhone", "en-US", shots: slides, at: t0),
            entry("iPad", "en-US", shots: slides, at: t0),
            entry("iPhone", "el", shots: slides, at: t0),
            entry("iPad", "el", shots: slides, at: t0),
        ], at: t0)
    }

    func testFullRun_replacesTheManifest() {
        let run = manifest([entry("iPhone", "en-US", shots: slides, at: t1)], at: t1)
        let written = run.merged(over: existing, scope: .full)
        XCTAssertEqual(summary(written), ["iPhone en-US - new"])
    }

    func testNoExistingManifest_writesTheRun() {
        let run = manifest([entry("iPhone", "da", shots: slides, at: t1)], at: t1)
        XCTAssertEqual(summary(run.merged(over: nil, scope: CaptureScope(locales: ["da"]))), ["iPhone da - new"])
    }

    /// The case from issue #1: a new locale captured on its own joins the
    /// manifest instead of replacing it.
    func testLocaleRun_addsANewLocaleAndKeepsTheOthers() {
        let run = manifest([
            entry("iPhone", "da", shots: slides, at: t1),
            entry("iPad", "da", shots: slides, at: t1),
        ], at: t1)
        let written = run.merged(over: existing, scope: CaptureScope(locales: ["da"]))
        XCTAssertEqual(summary(written), [
            "iPhone en-US - old", "iPad en-US - old",
            "iPhone el - old", "iPad el - old",
            "iPhone da - new", "iPad da - new",
        ])
        XCTAssertEqual(written.generatedAt, t1)
        XCTAssertEqual(written.devices.flatMap(\.screenshots).count, 18)
    }

    /// Recapturing a locale replaces its entries where they were, so the
    /// manifest order (which breaks ties between devices at upload) stays.
    func testLocaleRun_replacesThatLocaleInPlace() {
        let run = manifest([
            entry("iPhone", "en-US", shots: slides, at: t1),
            entry("iPad", "en-US", shots: slides, at: t1),
        ], at: t1)
        let written = run.merged(over: existing, scope: CaptureScope(locales: ["en-US"]))
        XCTAssertEqual(summary(written), [
            "iPhone en-US - new", "iPad en-US - new",
            "iPhone el - old", "iPad el - old",
        ])
    }

    /// Inside the run's locales every configured device was captured, so an
    /// old entry for a device the run did not capture (one taken out of the
    /// config) is dropped, while other locales keep theirs.
    func testLocaleRun_dropsADeviceItNoLongerCapturesInThatLocale() {
        let run = manifest([entry("iPhone", "el", shots: slides, at: t1)], at: t1)
        let written = run.merged(over: existing, scope: CaptureScope(locales: ["el"]))
        XCTAssertEqual(summary(written), [
            "iPhone en-US - old", "iPad en-US - old",
            "iPhone el - new",
        ])
    }

    func testAppearanceRun_keepsTheOtherAppearance() {
        let old = manifest([
            entry("iPhone", "en-US", appearance: "light", shots: slides, at: t0),
            entry("iPhone", "en-US", appearance: "dark", shots: slides, at: t0),
        ], at: t0)
        let run = manifest([entry("iPhone", "en-US", appearance: "dark", shots: slides, at: t1)], at: t1)
        let written = run.merged(over: old, scope: CaptureScope(appearances: ["dark"]))
        XCTAssertEqual(summary(written), ["iPhone en-US light old", "iPhone en-US dark new"])
    }

    /// `--only` captures some screenshots of each entry. The others stay,
    /// in their places, and the recaptured ones take the new files.
    func testOnlyRun_mergesScreenshotsByName() {
        let run = manifest([
            entry("iPhone", "en-US", shots: ["typeahead", "trackpad"], at: t1),
        ], at: t1)
        let written = run.merged(over: existing, scope: CaptureScope(someScreenshotsOnly: true))
        XCTAssertEqual(written.devices.count, 4, "entries the run did not touch stay")
        let iPhoneEnUS = written.devices[0]
        XCTAssertEqual(iPhoneEnUS.screenshots.map(\.name), ["polytonic", "spellcheck", "typeahead", "trackpad"])
        XCTAssertEqual(iPhoneEnUS.screenshots.map { $0.capturedAt == t1 }, [false, false, true, true])
        XCTAssertEqual(written.devices[1].screenshots.map(\.capturedAt), [t0, t0, t0], "iPad en-US was not captured")
    }

    func testScope_isFullOnlyWithoutNarrowingFlags() {
        XCTAssertTrue(CaptureScope().isFull)
        XCTAssertTrue(CaptureScope(locales: [], appearances: []).isFull, "an empty flag list is no flag")
        XCTAssertFalse(CaptureScope(locales: ["da"]).isFull)
        XCTAssertFalse(CaptureScope(appearances: ["dark"]).isFull)
        XCTAssertFalse(CaptureScope(someScreenshotsOnly: true).isFull)
    }

    /// Per-slide appearance mode writes entries with no appearance; an
    /// appearance limit cannot place them, so they count as inside it.
    func testScope_coversAnEntryWithoutAppearance() {
        let scope = CaptureScope(locales: ["en-US"], appearances: ["dark"])
        XCTAssertTrue(scope.covers(entry("iPhone", "en-US", shots: slides, at: t0)))
        XCTAssertTrue(scope.covers(entry("iPhone", "en-US", appearance: "dark", shots: slides, at: t0)))
        XCTAssertFalse(scope.covers(entry("iPhone", "en-US", appearance: "light", shots: slides, at: t0)))
        XCTAssertFalse(scope.covers(entry("iPhone", "el", appearance: "dark", shots: slides, at: t0)))
    }

    /// The merge reads the manifest the previous run wrote, in the format
    /// `OutputOrganizer.writeManifest` writes it.
    func testLoad_readsWhatWriteManifestWrote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-load-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(try CaptureManifest.load(fromOutputDir: dir.path))
        try OutputOrganizer().writeManifest(existing, to: dir.path)
        let loaded = try XCTUnwrap(CaptureManifest.load(fromOutputDir: dir.path))
        XCTAssertEqual(summary(loaded), summary(existing))
        XCTAssertEqual(loaded.generatedAt, t0)

        try Data("not json".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try CaptureManifest.load(fromOutputDir: dir.path))
    }
}
