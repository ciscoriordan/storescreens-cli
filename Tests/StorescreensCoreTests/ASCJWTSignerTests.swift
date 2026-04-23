import XCTest
import CryptoKit
@testable import StorescreensCore

final class ASCJWTSignerTests: XCTestCase {

    /// Makes real ES256 credentials backed by a freshly-generated P-256 key.
    /// The corresponding public key is returned so tests can verify signatures.
    private func makeCredentials() -> (ASCCredentials, P256.Signing.PublicKey) {
        let privateKey = P256.Signing.PrivateKey()
        let pem = privateKey.pemRepresentation
        let creds = ASCCredentials(
            keyID: "TESTKEY1",
            issuerID: "69abc000-0000-0000-0000-000000000000",
            privateKeyPEM: pem,
            source: .environment
        )
        return (creds, privateKey.publicKey)
    }

    func testSign_producesThreePartToken() throws {
        let (creds, _) = makeCredentials()
        let token = try ASCJWTSigner.sign(credentials: creds)
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3, "JWT should be header.payload.signature")
        XCTAssertFalse(parts.contains(""))
    }

    func testSign_headerHasES256AndKid() throws {
        let (creds, _) = makeCredentials()
        let token = try ASCJWTSigner.sign(credentials: creds)
        let parts = token.split(separator: ".").map(String.init)
        guard let data = ASCJWTSigner.base64URLDecode(parts[0]),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("could not decode header")
        }
        XCTAssertEqual(obj["alg"] as? String, "ES256")
        XCTAssertEqual(obj["kid"] as? String, "TESTKEY1")
        XCTAssertEqual(obj["typ"] as? String, "JWT")
    }

    func testSign_claimsHaveCorrectFields() throws {
        let (creds, _) = makeCredentials()
        let issuedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let token = try ASCJWTSigner.sign(credentials: creds, issuedAt: issuedAt, lifetime: 600)

        let parts = token.split(separator: ".").map(String.init)
        guard let data = ASCJWTSigner.base64URLDecode(parts[1]),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("could not decode claims")
        }
        XCTAssertEqual(obj["iss"] as? String, creds.issuerID)
        XCTAssertEqual(obj["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(obj["iat"] as? Int, 1_770_000_000)
        XCTAssertEqual(obj["exp"] as? Int, 1_770_000_600)
    }

    func testSign_signatureVerifiesAgainstPublicKey() throws {
        let (creds, publicKey) = makeCredentials()
        let token = try ASCJWTSigner.sign(credentials: creds)
        let parts = token.split(separator: ".").map(String.init)

        let signingInput = "\(parts[0]).\(parts[1])"
        let signingInputData = Data(signingInput.utf8)
        let digest = SHA256.hash(data: signingInputData)

        guard let sigData = ASCJWTSigner.base64URLDecode(parts[2]) else {
            return XCTFail("could not decode signature")
        }
        XCTAssertEqual(sigData.count, 64, "ES256 raw signature is 64 bytes for P-256")

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
        XCTAssertTrue(
            publicKey.isValidSignature(signature, for: digest),
            "signature should verify against the public key"
        )
    }

    func testSign_invalidPEM_throws() {
        let bogus = ASCCredentials(
            keyID: "X",
            issuerID: "Y",
            privateKeyPEM: "this is not a PEM key",
            source: .environment
        )
        XCTAssertThrowsError(try ASCJWTSigner.sign(credentials: bogus)) { error in
            if case ASCJWTSigner.SignError.invalidPEM = error { return }
            XCTFail("expected invalidPEM; got \(error)")
        }
    }

    func testBase64URL_roundTrip() {
        let original = Data((0..<40).map { UInt8($0) })
        let encoded = ASCJWTSigner.base64URLEncode(original)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        let decoded = ASCJWTSigner.base64URLDecode(encoded)
        XCTAssertEqual(decoded, original)
    }
}
