import Foundation

/// Minimal HTTP client for the App Store Connect API. Handles the JWT
/// bearer-token lifecycle (mint once, cache until near-expiry, remint) and
/// surfaces ASC's JSON:API error envelope as Swift errors with human-readable
/// messages. Retries 5xx and 429 responses with exponential backoff.
package final class ASCClient: @unchecked Sendable {

    package static let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1")!
    /// Re-mint tokens 60s before the issuer's expiry so we don't race with
    /// clock skew between our machine and Apple's servers.
    package static let tokenRefreshMargin: TimeInterval = 60

    package let credentials: ASCCredentials
    package let session: URLSession
    package let baseURL: URL
    package let tokenLifetime: TimeInterval
    package let maxRetries: Int

    /// Serializes token refreshes.
    private let tokenLock = NSLock()
    private var cachedToken: String?
    private var cachedExpiry: Date?

    package init(
        credentials: ASCCredentials,
        session: URLSession = .shared,
        baseURL: URL = ASCClient.baseURL,
        tokenLifetime: TimeInterval = ASCJWTSigner.defaultLifetime,
        maxRetries: Int = 3
    ) {
        self.credentials = credentials
        self.session = session
        self.baseURL = baseURL
        self.tokenLifetime = tokenLifetime
        self.maxRetries = maxRetries
    }

    // MARK: - Error envelope

    package struct APIError: Error, CustomStringConvertible, Sendable {
        package let statusCode: Int
        package let details: [ErrorDetail]
        package let rawBody: String

        package var description: String {
            if details.isEmpty {
                return "App Store Connect API error \(statusCode): \(rawBody)"
            }
            let lines = details.map { "[\($0.code)] \($0.title): \($0.detail)" }
            return "App Store Connect API error \(statusCode)\n  " + lines.joined(separator: "\n  ")
        }

        /// True when ASC rejected a PATCH because the value the
        /// caller asked for is effectively already in place — either
        /// because the attribute matches what's stored, or because
        /// the target resource has advanced into a state that no
        /// longer accepts this edit (version locked in review,
        /// build already attached, etc.). Apple returns these as 409s
        /// with a few different shapes and the decisive part lives in
        /// the `detail` text rather than the `code`, so we
        /// pattern-match on message fragments. Callers in the submit
        /// flow use this to treat a re-run as a no-op success.
        ///
        /// Real payloads this matches (observed in the wild):
        ///   - `ENTITY_ERROR.ATTRIBUTE.INVALID` + "you cannot update
        ///     when the value is already set" (PATCH
        ///     usesNonExemptEncryption on a build where it was set)
        ///   - `ENTITY_ERROR.RELATIONSHIP.INVALID.INVALID_STATE` +
        ///     "The specified pre-release build could not be added"
        ///     (PATCH build relationship on a version already in
        ///     review)
        ///   - `STATE_ERROR.ENTITY_STATE_INVALID` + "this resource
        ///     cannot be reviewed" (POST reviewSubmissions for a
        ///     version that's already submitted)
        package var isAlreadySetConflict: Bool {
            guard statusCode == 409 else { return false }
            return details.contains { d in
                let msg = d.detail.lowercased()
                let code = d.code
                // Attribute / relationship patches whose target is
                // already what we're asking for.
                if msg.contains("already set")
                    || msg.contains("already attached")
                    || msg.contains("could not be added") {
                    return true
                }
                if code.hasPrefix("ENTITY_ERROR.ATTRIBUTE")
                    && msg.contains("cannot update") {
                    return true
                }
                // Version / resource has advanced past an editable
                // state. For submit's purposes, "version already in
                // review" counts as a success outcome of the step
                // that was trying to put it in review.
                if code == "STATE_ERROR.ENTITY_STATE_INVALID"
                    && (msg.contains("cannot be reviewed")
                        || msg.contains("not in valid state")) {
                    return true
                }
                return false
            }
        }
    }

    package struct ErrorDetail: Codable, Sendable {
        package let id: String?
        package let status: String?
        package let code: String
        package let title: String
        package let detail: String
    }

    package struct ErrorEnvelope: Codable, Sendable {
        package let errors: [ErrorDetail]
    }

    // MARK: - Public API

    package func get<Response: Decodable>(
        path: String,
        query: [String: String] = [:],
        as type: Response.Type
    ) async throws -> Response {
        try await send(method: "GET", path: path, query: query, body: Optional<EmptyBody>.none, as: type)
    }

    package func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        as type: Response.Type
    ) async throws -> Response {
        try await send(method: "POST", path: path, body: body, as: type)
    }

    package func patch<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        as type: Response.Type
    ) async throws -> Response {
        try await send(method: "PATCH", path: path, body: body, as: type)
    }

    package func delete(path: String) async throws {
        try await send(method: "DELETE", path: path, body: Optional<EmptyBody>.none, as: EmptyBody.self)
    }

    /// Raw binary PUT — used for screenshot chunk uploads to the URLs Apple
    /// hands back in `uploadOperations`. Note these URLs are NOT on our
    /// baseURL — they're pre-signed S3-style URLs, so we use them verbatim
    /// and apply only the headers Apple instructs.
    package func putBinary(
        absoluteURL: URL,
        headers: [String: String],
        body: Data
    ) async throws {
        var req = URLRequest(url: absoluteURL)
        req.httpMethod = "PUT"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ASCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "no HTTPURLResponse"])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(
                statusCode: http.statusCode,
                details: [],
                rawBody: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    // MARK: - Private

    /// Body type to use when no body is being sent. Decoding returns an
    /// instance even for empty responses (204 No Content handled specially).
    package struct EmptyBody: Codable, Sendable {
        package init() {}
    }

    /// All-in-one request machinery: URL building, bearer token, JSON
    /// encode/decode, retry.
    private func send<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Body?,
        as type: Response.Type
    ) async throws -> Response {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await sendOnce(method: method, path: path, query: query, body: body, as: type)
            } catch let e as APIError where shouldRetry(statusCode: e.statusCode) && attempt < maxRetries {
                lastError = e
                let backoff = pow(2.0, Double(attempt)) * 0.5
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                continue
            } catch {
                throw error
            }
        }
        throw lastError ?? NSError(domain: "ASCClient", code: -1)
    }

    private func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || (500..<600).contains(statusCode)
    }

    private func sendOnce<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        query: [String: String],
        body: Body?,
        as type: Response.Type
    ) async throws -> Response {
        let url = try buildURL(path: path, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body, !(body is EmptyBody) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            req.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ASCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "no HTTPURLResponse"])
        }

        // No content — synthesize an EmptyBody if caller asked for one.
        if http.statusCode == 204, type == EmptyBody.self, let empty = EmptyBody() as? Response {
            return empty
        }

        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw APIError(
                statusCode: http.statusCode,
                details: envelope?.errors ?? [],
                rawBody: String(data: data, encoding: .utf8) ?? ""
            )
        }

        if type == EmptyBody.self, let empty = EmptyBody() as? Response {
            return empty
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private func buildURL(path: String, query: [String: String]) throws -> URL {
        // Accept leading slash for ergonomics.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(trimmed), resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "ASCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad URL path \(path)"])
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else {
            throw NSError(domain: "ASCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad URL"])
        }
        return url
    }

    /// Returns a valid bearer token, minting a fresh one if the cached one
    /// is missing or within `tokenRefreshMargin` of expiry.
    private func token() throws -> String {
        tokenLock.lock()
        defer { tokenLock.unlock() }

        if let cached = cachedToken,
           let expiry = cachedExpiry,
           expiry.timeIntervalSinceNow > Self.tokenRefreshMargin {
            return cached
        }
        let now = Date()
        let minted = try ASCJWTSigner.sign(credentials: credentials, issuedAt: now, lifetime: tokenLifetime)
        cachedToken = minted
        cachedExpiry = now.addingTimeInterval(tokenLifetime)
        return minted
    }
}
