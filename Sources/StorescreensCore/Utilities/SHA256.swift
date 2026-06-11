import Foundation
import CryptoKit

extension String {
    /// Lowercase hex SHA-256 of the UTF-8 bytes. Used to fingerprint base text
    /// and machine-translated output so the translator can tell an untouched
    /// machine translation (output hash still matches) from one a human edited,
    /// and a fresh base from a changed one.
    package var sha256Hex: String {
        let digest = SHA256.hash(data: Data(utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
