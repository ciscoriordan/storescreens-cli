import XCTest
@testable import StorescreensCore

/// Unit tests for `RenderPipeline.applyOrder`, which is how the top-level
/// `screenshots:` config key turns into render-time slide order. The
/// manifest still holds every captured slide in capture-time order; this
/// helper reorders the slice passed to the per-slide render loop.
final class RenderOrderingTests: XCTestCase {

    private func shot(_ name: String) -> CaptureManifest.Screenshot {
        CaptureManifest.Screenshot(
            name: name,
            filename: "iPhone_6.9_\(name).png",
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testNilOrderPreservesManifest() {
        let shots = ["01_home", "02_detail", "03_settings"].map(shot)
        let out = RenderPipeline.applyOrder(shots, order: nil)
        XCTAssertEqual(out.map(\.name), ["01_home", "02_detail", "03_settings"])
    }

    func testEmptyOrderPreservesManifest() {
        let shots = ["01_home", "02_detail"].map(shot)
        let out = RenderPipeline.applyOrder(shots, order: [])
        XCTAssertEqual(out.map(\.name), ["01_home", "02_detail"])
    }

    func testReordersToListWhenFullyCovered() {
        let shots = ["01_home", "02_detail", "03_settings"].map(shot)
        let out = RenderPipeline.applyOrder(
            shots,
            order: ["03_settings", "01_home", "02_detail"]
        )
        XCTAssertEqual(out.map(\.name), ["03_settings", "01_home", "02_detail"])
    }

    func testAppendsUnlistedAfterOrderedPrefix() {
        // `04_extra` isn't in the list; keep it, but after the ordered
        // ones, preserving its original manifest position.
        let shots = ["01_home", "02_detail", "03_settings", "04_extra"].map(shot)
        let out = RenderPipeline.applyOrder(
            shots,
            order: ["03_settings", "01_home"]
        )
        XCTAssertEqual(out.map(\.name), ["03_settings", "01_home", "02_detail", "04_extra"])
    }

    func testIgnoresListedNamesMissingFromManifest() {
        // `99_ghost` is in the order list but absent from the manifest.
        // The helper must not fabricate entries for it; it just renders
        // what's present, in list order.
        let shots = ["01_home", "02_detail"].map(shot)
        let out = RenderPipeline.applyOrder(
            shots,
            order: ["02_detail", "99_ghost", "01_home"]
        )
        XCTAssertEqual(out.map(\.name), ["02_detail", "01_home"])
    }

    func testDuplicateNamesInListDoNotDuplicateOutput() {
        // Defensive: a user typo that lists the same slide twice shouldn't
        // render it twice. First occurrence wins.
        let shots = ["01_home", "02_detail"].map(shot)
        let out = RenderPipeline.applyOrder(
            shots,
            order: ["01_home", "01_home", "02_detail"]
        )
        XCTAssertEqual(out.map(\.name), ["01_home", "02_detail"])
    }
}
