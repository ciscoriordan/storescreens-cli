import XCTest
import Foundation
@testable import StorescreensCore

/// Verifies that `CaptureOrchestrator.cleanScreenshotCache` removes the
/// screenshot cache directories and breadcrumb file. This is the cleanup
/// hook called at the start of every capture run (and at the end of
/// successful runs) so `~/.storescreens-cache` and `<cwd>/.storescreens-cache`
/// don't accumulate stale device subdirs, named pipes, and old PNGs.
final class CacheCleanupTests: XCTestCase {

    private var sandbox: URL!
    private var cwdCache: URL!
    private var homeCache: URL!
    private var breadcrumb: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-cleanup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        cwdCache = sandbox.appendingPathComponent(".storescreens-cache", isDirectory: true)
        homeCache = sandbox.appendingPathComponent("home-storescreens-cache", isDirectory: true)
        breadcrumb = sandbox.appendingPathComponent(".storescreens-cache-dir")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Removes a populated cwd cache

    func testCleanScreenshotCache_removesPopulatedCwdCache() throws {
        let device1 = cwdCache.appendingPathComponent("iPhone 16 Pro Max", isDirectory: true)
        let device2 = cwdCache.appendingPathComponent("iPad Pro 13-inch (M4)", isDirectory: true)
        try FileManager.default.createDirectory(at: device1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: device2, withIntermediateDirectories: true)
        // Simulate captured PNGs and a leftover named pipe path entry
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: device1.appendingPathComponent("Home.png"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: device2.appendingPathComponent("Home.png"))
        try "stale".write(
            to: cwdCache.appendingPathComponent("storescreens-iPhone 16 Pro Max.pipe"),
            atomically: true, encoding: .utf8
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: cwdCache.path))

        CaptureOrchestrator.cleanScreenshotCache(
            cacheDir: cwdCache,
            homeFilterDir: homeCache,
            breadcrumb: breadcrumb
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cwdCache.path),
            "cwd cache directory should be removed"
        )
    }

    // MARK: - Removes home filter cache

    func testCleanScreenshotCache_removesHomeFilterCache() throws {
        try FileManager.default.createDirectory(at: homeCache, withIntermediateDirectories: true)
        try "Home\nSearch".write(
            to: homeCache.appendingPathComponent("screenshot-filter.txt"),
            atomically: true, encoding: .utf8
        )

        CaptureOrchestrator.cleanScreenshotCache(
            cacheDir: cwdCache,
            homeFilterDir: homeCache,
            breadcrumb: breadcrumb
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: homeCache.path),
            "home filter cache directory should be removed (not just its contents)"
        )
    }

    // MARK: - Removes breadcrumb file

    func testCleanScreenshotCache_removesBreadcrumb() throws {
        try cwdCache.path.write(to: breadcrumb, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: breadcrumb.path))

        CaptureOrchestrator.cleanScreenshotCache(
            cacheDir: cwdCache,
            homeFilterDir: homeCache,
            breadcrumb: breadcrumb
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: breadcrumb.path))
    }

    // MARK: - All three at once

    func testCleanScreenshotCache_removesAllInOneCall() throws {
        let deviceDir = cwdCache.appendingPathComponent("iPhone 16", isDirectory: true)
        try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)
        try Data([0x89]).write(to: deviceDir.appendingPathComponent("a.png"))
        try FileManager.default.createDirectory(at: homeCache, withIntermediateDirectories: true)
        try "x".write(
            to: homeCache.appendingPathComponent("screenshot-filter.txt"),
            atomically: true, encoding: .utf8
        )
        try cwdCache.path.write(to: breadcrumb, atomically: true, encoding: .utf8)

        CaptureOrchestrator.cleanScreenshotCache(
            cacheDir: cwdCache,
            homeFilterDir: homeCache,
            breadcrumb: breadcrumb
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: cwdCache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeCache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: breadcrumb.path))
    }

    // MARK: - No-op when nothing exists

    func testCleanScreenshotCache_noopWhenAbsent() {
        // None of the paths exist. Helper must not throw and must remain a no-op.
        CaptureOrchestrator.cleanScreenshotCache(
            cacheDir: cwdCache,
            homeFilterDir: homeCache,
            breadcrumb: breadcrumb
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: cwdCache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeCache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: breadcrumb.path))
    }

    // MARK: - Production paths point at the right places

    func testProductionPaths_areAsExpected() {
        // Sanity: the static paths the helper defaults to are the
        // locations the rest of the codebase reads/writes.
        XCTAssertEqual(
            CaptureOrchestrator.screenshotsCacheDir.lastPathComponent,
            ".storescreens-cache"
        )
        XCTAssertEqual(
            CaptureOrchestrator.homeFilterCacheDir.lastPathComponent,
            ".storescreens-cache"
        )
        XCTAssertEqual(
            CaptureOrchestrator.breadcrumbFile.lastPathComponent,
            ".storescreens-cache-dir"
        )
        // The home filter cache parent must be HOME, not cwd.
        XCTAssertEqual(
            CaptureOrchestrator.homeFilterCacheDir.deletingLastPathComponent().standardizedFileURL,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        )
    }
}
