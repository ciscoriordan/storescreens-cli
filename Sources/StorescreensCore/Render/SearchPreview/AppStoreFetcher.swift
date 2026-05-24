import Foundation

/// Pulls App Store metadata for an existing app and turns it into a
/// fully-resolved `SearchPreviewInput` so `storescreens search-preview`
/// can render a shipped app without any local config.
///
/// Data source: Apple's public iTunes Lookup API
/// (`https://itunes.apple.com/lookup?id=<id>`). It covers everything
/// the search-row + detail-page mockups need (name, icon, screenshots,
/// rating, reviews, developer, categories, age rating, version, release
/// notes, description, supported devices). The one notable gap is the
/// app's marketing subtitle - that's only on the App Store web page,
/// so we scrape it from the HTML when the user wants it.
package struct AppStoreFetcher {

    package enum FetchError: Error, CustomStringConvertible {
        case invalidURL(String)
        case noResults
        case networkError(String)
        case missingField(String)

        package var description: String {
            switch self {
            case .invalidURL(let s):
                return "could not extract App Store app id from \"\(s)\" - expected an id like \"id123456789\" or a numeric value"
            case .noResults:
                return "iTunes Lookup returned no results for the given app id (was the app removed, or is the id wrong?)"
            case .networkError(let s):
                return "network error: \(s)"
            case .missingField(let f):
                return "iTunes Lookup response missing required field: \(f)"
            }
        }
    }

    package init() {}

    /// Extracts the numeric app id from any App Store URL or returns the
    /// input unchanged if it's already a bare numeric id.
    ///
    /// Accepts:
    /// - `https://apps.apple.com/us/app/foo/id123456789`
    /// - `https://apps.apple.com/us/app/id123456789`
    /// - `apps.apple.com/.../id123456789?mt=8`
    /// - `123456789` (bare numeric id)
    package static func extractAppID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bare numeric id.
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }) {
            return trimmed
        }
        // /idNNN pattern in a URL.
        let pattern = #"id(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let r = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[r])
    }

    /// Bundle of values pulled from iTunes Lookup, ready to drive a
    /// `SearchPreviewInput`. All paths are remote `https://...`; the
    /// resolver downloads them to a local cache before rendering.
    package struct FetchedApp: Sendable {
        package let appID: String
        package let name: String
        package let subtitle: String?
        package let description: String
        package let releaseNotes: String?
        package let iconURL: URL
        package let screenshotURLs: [URL]
        package let categories: [String]
        package let developer: String
        package let rating: Double
        package let reviewCount: Int
        package let ageRating: String
        package let version: String
        /// ISO-8601 string like `2026-04-24`. Empty when iTunes had no
        /// `currentVersionReleaseDate`.
        package let releaseDateISO: String
        /// Lowercase short names: `iphone`, `ipad`, etc. Drives the
        /// detail-page Compatibility row.
        package let supportedDevices: [String]
    }

    /// Fetches iTunes Lookup for the given app id and, optionally, scrapes
    /// the App Store web page for the subtitle (not exposed in the JSON
    /// endpoint). `country` is the 2-letter region code used in the
    /// `apps.apple.com/<cc>/...` URL; defaults to `us`.
    package func fetch(
        appID: String,
        country: String = "us",
        fetchSubtitle: Bool = true
    ) async throws -> FetchedApp {
        guard let lookupURL = URL(
            string: "https://itunes.apple.com/lookup?id=\(appID)&country=\(country)"
        ) else {
            throw FetchError.invalidURL(appID)
        }

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: lookupURL)
        } catch {
            throw FetchError.networkError("iTunes Lookup: \(error.localizedDescription)")
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]],
            let r = results.first
        else {
            throw FetchError.noResults
        }

        guard let name = r["trackName"] as? String else {
            throw FetchError.missingField("trackName")
        }
        let description = (r["description"] as? String) ?? ""
        let releaseNotes = r["releaseNotes"] as? String
        let iconURLStr = (r["artworkUrl512"] as? String)
            ?? (r["artworkUrl100"] as? String)
            ?? ""
        guard let iconURL = URL(string: iconURLStr) else {
            throw FetchError.missingField("artworkUrl512 / artworkUrl100")
        }
        let screenshotURLs = (r["screenshotUrls"] as? [String])?
            .compactMap { URL(string: $0) } ?? []
        let categories = (r["genres"] as? [String]) ?? []
        let developer = (r["artistName"] as? String) ?? ""
        let rating = (r["averageUserRating"] as? Double) ?? 0
        let reviewCount = (r["userRatingCount"] as? Int) ?? 0
        let ageRating = (r["trackContentRating"] as? String) ?? ""
        let version = (r["version"] as? String) ?? ""
        let releaseDateRaw = (r["currentVersionReleaseDate"] as? String) ?? ""
        // Trim the time portion: iTunes returns `2026-04-24T06:30:29Z`,
        // we only want the date for the relative-time formatter.
        let releaseDateISO = String(releaseDateRaw.prefix(10))

        // Supported devices: prefer `features` for the canonical
        // ["iosUniversal"] signal; fall back to inspecting the per-model
        // supportedDevices array if that's empty.
        let features = (r["features"] as? [String]) ?? []
        let supportedDeviceStrs = (r["supportedDevices"] as? [String]) ?? []
        var supportedDevices: [String] = []
        let hasIPhone = features.contains("iosUniversal")
            || supportedDeviceStrs.contains { $0.contains("iPhone") || $0.contains("iPod") }
        let hasIPad = features.contains("iosUniversal")
            || supportedDeviceStrs.contains { $0.contains("iPad") }
        if hasIPhone { supportedDevices.append("iphone") }
        if hasIPad { supportedDevices.append("ipad") }
        if supportedDevices.isEmpty { supportedDevices = ["iphone"] }

        // Subtitle isn't exposed in the JSON endpoint, so we (optionally)
        // grab the App Store web page and pull it out of the rendered
        // HTML. Network failure here is non-fatal - the render just goes
        // without a subtitle.
        var subtitle: String?
        if fetchSubtitle {
            subtitle = try? await scrapeSubtitle(appID: appID, country: country)
        }

        return FetchedApp(
            appID: appID,
            name: name,
            subtitle: subtitle,
            description: description,
            releaseNotes: releaseNotes,
            iconURL: iconURL,
            screenshotURLs: screenshotURLs,
            categories: categories,
            developer: developer,
            rating: rating,
            reviewCount: reviewCount,
            ageRating: ageRating,
            version: version,
            releaseDateISO: releaseDateISO,
            supportedDevices: supportedDevices
        )
    }

    /// Downloads remote `urls` to `dir`, naming files `<basename>-<i>.<ext>`.
    /// Returns the local file URLs in the same order as `urls`. Failed
    /// downloads are dropped from the returned list and surfaced as a
    /// warning string in the second tuple element.
    package func downloadImages(
        _ urls: [URL],
        to dir: URL,
        basename: String
    ) async throws -> (locals: [URL], warnings: [String]) {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        var locals: [URL] = []
        var warnings: [String] = []
        for (i, url) in urls.enumerated() {
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            let local = dir.appendingPathComponent("\(basename)-\(i).\(ext)")
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: local)
                locals.append(local)
            } catch {
                warnings.append("failed to download \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (locals, warnings)
    }

    // MARK: - Private

    private func scrapeSubtitle(appID: String, country: String) async throws -> String? {
        guard let pageURL = URL(
            string: "https://apps.apple.com/\(country)/app/id\(appID)"
        ) else { return nil }
        var request = URLRequest(url: pageURL)
        // Apple serves a thin shell to known bot UAs; the real markup
        // (with the subtitle) only renders for browser-style UAs.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        // The subtitle ships in a JSON-LD blob: `"subtitle":"<value>"`.
        // Fall back to the rendered `<h2 class="product-header__subtitle">`
        // if the JSON isn't present.
        if let match = html.range(
            of: #""subtitle"\s*:\s*"([^"]+)""#,
            options: .regularExpression
        ) {
            let snippet = String(html[match])
            if let valueMatch = snippet.range(
                of: #":\s*"([^"]+)""#,
                options: .regularExpression
            ) {
                let value = snippet[valueMatch]
                    .replacingOccurrences(of: ":", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return value
            }
        }
        // Fallback: visible subtitle in product header.
        if let match = html.range(
            of: #"product-header__subtitle[^>]*>\s*([^<]+)<"#,
            options: .regularExpression
        ) {
            let snippet = String(html[match])
            let cleaned = snippet
                .replacingOccurrences(of: #"product-header__subtitle[^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "<", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }
}
