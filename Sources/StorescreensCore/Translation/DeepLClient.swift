import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstracts the actual translation call so the orchestrator can be unit
/// tested with a stub. `DeepLClient` is the production conformer.
package protocol Translator: Sendable {
    /// Translate a batch of strings. `source`/`target` are DeepL language
    /// codes (EN, DE, PT-BR, ...). Output order matches input order.
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String]
}

/// Minimal DeepL v2 client: just the `/v2/translate` and `/v2/usage` calls the
/// metadata translator needs. Picks the free vs paid host from the key suffix
/// (see `DeepLCredentials.apiBaseURL`).
package struct DeepLClient: Translator {

    package let credentials: DeepLCredentials
    /// Optional DeepL formality ("more", "less", "prefer_more", "prefer_less").
    /// Ignored by DeepL for languages that do not support it.
    package let formality: String?
    private let session: URLSession

    package init(
        credentials: DeepLCredentials,
        formality: String? = nil,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.formality = formality
        self.session = session
    }

    package enum DeepLError: Error, CustomStringConvertible {
        case http(status: Int, body: String)
        case decode(underlying: Error)
        case countMismatch(sent: Int, got: Int)

        package var description: String {
            switch self {
            case .http(let status, let body):
                let hint: String
                switch status {
                case 403: hint = " (auth failed - check the API key)"
                case 429: hint = " (rate limited - retry shortly)"
                case 456: hint = " (quota exceeded for this billing period)"
                default:  hint = ""
                }
                return "DeepL HTTP \(status)\(hint): \(body)"
            case .decode(let underlying):
                return "could not decode DeepL response: \(underlying)"
            case .countMismatch(let sent, let got):
                return "DeepL returned \(got) translations for \(sent) inputs"
            }
        }
    }

    // MARK: - Translate

    private struct TranslateResponse: Decodable {
        struct T: Decodable { let text: String }
        let translations: [T]
    }

    package func translate(
        _ texts: [String],
        from source: String,
        to target: String
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        var fields: [(String, String)] = []
        for t in texts { fields.append(("text", t)) }
        fields.append(("source_lang", source))
        fields.append(("target_lang", target))
        fields.append(("preserve_formatting", "1"))
        if let formality, !formality.isEmpty {
            fields.append(("formality", formality))
        }

        let data = try await post(path: "/v2/translate", form: fields)
        let decoded: TranslateResponse
        do {
            decoded = try JSONDecoder().decode(TranslateResponse.self, from: data)
        } catch {
            throw DeepLError.decode(underlying: error)
        }
        guard decoded.translations.count == texts.count else {
            throw DeepLError.countMismatch(sent: texts.count, got: decoded.translations.count)
        }
        return decoded.translations.map(\.text)
    }

    // MARK: - Usage

    package struct Usage: Decodable, Sendable {
        package let characterCount: Int
        package let characterLimit: Int
        enum CodingKeys: String, CodingKey {
            case characterCount = "character_count"
            case characterLimit = "character_limit"
        }
    }

    /// Hits `/v2/usage` to verify the key works and report remaining quota.
    package func usage() async throws -> Usage {
        let url = credentials.apiBaseURL.appendingPathComponent("v2/usage")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("DeepL-Auth-Key \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data)
        do {
            return try JSONDecoder().decode(Usage.self, from: data)
        } catch {
            throw DeepLError.decode(underlying: error)
        }
    }

    // MARK: - HTTP

    private func post(path: String, form: [(String, String)]) async throws -> Data {
        let url = credentials.apiBaseURL.appendingPathComponent(String(path.dropFirst()))
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("DeepL-Auth-Key \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.encodeForm(form).data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        try Self.check(response, data)
        return data
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepLError.http(status: http.statusCode, body: String(body.prefix(500)))
        }
    }

    /// application/x-www-form-urlencoded body. Percent-encodes values
    /// conservatively (alphanumerics only) so newlines, commas, and reserved
    /// characters in descriptions survive intact.
    private static func encodeForm(_ fields: [(String, String)]) -> String {
        fields.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return "\(key)=\(v)"
        }.joined(separator: "&")
    }
}
