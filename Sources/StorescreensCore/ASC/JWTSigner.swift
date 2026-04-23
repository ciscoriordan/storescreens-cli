import Foundation
import CryptoKit

/// Mints JWTs for the App Store Connect API. Tokens are signed with ES256
/// (ECDSA on P-256 + SHA-256) using the .p8 private key Apple issues from
/// https://appstoreconnect.apple.com/access/api.
///
/// Spec: https://developer.apple.com/documentation/appstoreconnectapi/generating_tokens_for_api_requests
package struct ASCJWTSigner {

    /// Audience Apple requires in the JWT claims.
    package static let audience = "appstoreconnect-v1"

    /// Apple accepts tokens with up to 20-minute expiry. We default to 19
    /// minutes so we can cache the token with a small safety margin.
    package static let defaultLifetime: TimeInterval = 60 * 19

    package enum SignError: Error, CustomStringConvertible {
        case invalidPEM(underlying: Error)

        package var description: String {
            switch self {
            case .invalidPEM(let e):
                return "could not parse .p8 private key: \(e)"
            }
        }
    }

    /// Returns a fully-assembled `header.payload.signature` JWT string.
    /// Callers just hand it to the Authorization header as `Bearer <token>`.
    package static func sign(
        credentials: ASCCredentials,
        issuedAt: Date = Date(),
        lifetime: TimeInterval = defaultLifetime
    ) throws -> String {
        let header: [String: String] = [
            "alg": "ES256",
            "kid": credentials.keyID,
            "typ": "JWT",
        ]
        let claims: [String: Any] = [
            "iss": credentials.issuerID,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(issuedAt.addingTimeInterval(lifetime).timeIntervalSince1970),
            "aud": audience,
        ]

        let headerPart = try base64URL(jsonEncode(header))
        let claimsPart = try base64URL(jsonEncode(claims))
        let signingInput = "\(headerPart).\(claimsPart)"
        let signingInputData = Data(signingInput.utf8)

        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
        } catch {
            throw SignError.invalidPEM(underlying: error)
        }

        // ES256: ECDSA signature, raw r||s concatenation (64 bytes for P-256).
        // CryptoKit's .rawRepresentation on ECDSASignature returns exactly
        // that, which is the JWT-standard format.
        let digest = SHA256.hash(data: signingInputData)
        let signature = try privateKey.signature(for: digest)
        let signaturePart = base64URLEncode(signature.rawRepresentation)

        return "\(signingInput).\(signaturePart)"
    }

    // MARK: - Encoding helpers

    private static func jsonEncode(_ value: Any) throws -> Data {
        // JSONSerialization gives us deterministic, compact JSON. We sort
        // keys for stable output (makes tests predictable).
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func base64URL(_ data: Data) -> String {
        base64URLEncode(data)
    }

    /// Standard JWT base64url: standard base64, minus padding, +/ replaced
    /// with -_.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4.
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
