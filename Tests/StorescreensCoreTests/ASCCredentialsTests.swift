import XCTest
@testable import StorescreensCore

final class ASCCredentialsTests: XCTestCase {

    /// Writes a fake .p8 file to a temp location and returns its path.
    private func writeFakeKey(tmp: URL) throws -> String {
        let url = tmp.appendingPathComponent("AuthKey_FAKE.p8")
        let pem = "-----BEGIN PRIVATE KEY-----\nFAKEPEM\n-----END PRIVATE KEY-----\n"
        try pem.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func makeTmp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("asc-creds-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - File source

    func testWriteAndResolveFromFile() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let keyPath = try writeFakeKey(tmp: tmp)
        let credsPath = tmp.appendingPathComponent("creds.yml").path

        try ASCCredentialResolver.write(
            keyID: "TESTKEY123",
            issuerID: "69abc000-0000-0000-0000-000000000000",
            keyPath: keyPath,
            to: credsPath
        )

        // Ensure file got 0600 perms.
        let attrs = try FileManager.default.attributesOfItem(atPath: credsPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600)

        let creds = try ASCCredentialResolver.resolve(filePath: credsPath)
        XCTAssertEqual(creds.keyID, "TESTKEY123")
        XCTAssertEqual(creds.issuerID, "69abc000-0000-0000-0000-000000000000")
        XCTAssertTrue(creds.privateKeyPEM.contains("BEGIN PRIVATE KEY"))
        XCTAssertEqual(creds.source, .file)
    }

    func testDeleteStoredFile_isIdempotent() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let credsPath = tmp.appendingPathComponent("creds.yml").path
        // Deleting non-existent is OK.
        try ASCCredentialResolver.deleteStoredFile(filePath: credsPath)

        try "key_id: X\nissuer_id: Y\nkey_path: /tmp/z\n".write(
            toFile: credsPath, atomically: true, encoding: .utf8
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: credsPath))
        try ASCCredentialResolver.deleteStoredFile(filePath: credsPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credsPath))
    }

    // MARK: - Missing-field errors

    func testFile_missingField_throws() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let credsPath = tmp.appendingPathComponent("creds.yml").path
        try "key_id: ABC\nissuer_id: XYZ\n".write(
            toFile: credsPath, atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(try ASCCredentialResolver.resolve(filePath: credsPath)) { error in
            if case ASCCredentialError.missingField(let field, _) = error {
                XCTAssertEqual(field, "key_path")
            } else {
                XCTFail("expected missingField(key_path); got \(error)")
            }
        }
    }

    func testFile_missingKeyFile_throws() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let credsPath = tmp.appendingPathComponent("creds.yml").path
        try "key_id: K\nissuer_id: I\nkey_path: /nonexistent/nope.p8\n".write(
            toFile: credsPath, atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(try ASCCredentialResolver.resolve(filePath: credsPath)) { error in
            if case ASCCredentialError.cannotReadKeyFile = error { return }
            XCTFail("expected cannotReadKeyFile; got \(error)")
        }
    }

    // MARK: - Not configured

    func testNotConfigured_throws() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let missing = tmp.appendingPathComponent("does-not-exist.yml").path
        XCTAssertThrowsError(try ASCCredentialResolver.resolve(filePath: missing)) { error in
            if case ASCCredentialError.notConfigured = error { return }
            XCTFail("expected notConfigured; got \(error)")
        }
    }

    func testIsConfigured_reflectsFileExistence() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let credsPath = tmp.appendingPathComponent("creds.yml").path
        XCTAssertFalse(ASCCredentialResolver.isConfigured(filePath: credsPath))
        try "x: y\n".write(toFile: credsPath, atomically: true, encoding: .utf8)
        XCTAssertTrue(ASCCredentialResolver.isConfigured(filePath: credsPath))
    }
}
