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

        // iTunes Lookup's `screenshotUrls` is usually empty even for apps
        // that have visible screenshots on the App Store web page, and the
        // marketing subtitle isn't exposed at all. Grab both off the
        // public web page in one HTTP call when requested. Failures are
        // non-fatal - the render falls back to what iTunes Lookup gave us.
        var subtitle: String?
        var finalScreenshots = screenshotURLs
        if fetchSubtitle {
            if let scrape = try? await scrapePage(appID: appID, country: country) {
                subtitle = scrape.subtitle
                if !scrape.screenshots.isEmpty {
                    finalScreenshots = scrape.screenshots
                }
            }
        }

        return FetchedApp(
            appID: appID,
            name: name,
            subtitle: subtitle,
            description: description,
            releaseNotes: releaseNotes,
            iconURL: iconURL,
            screenshotURLs: finalScreenshots,
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

    /// One HTTP fetch + two regex passes: pulls the marketing subtitle and
    /// the iPhone screenshot URLs out of the App Store web page HTML.
    /// Both are nil/empty on parse failure; callers fall back to iTunes
    /// Lookup data.
    private func scrapePage(
        appID: String,
        country: String
    ) async throws -> (subtitle: String?, screenshots: [URL]) {
        guard let pageURL = URL(
            string: "https://apps.apple.com/\(country)/app/id\(appID)"
        ) else { return (nil, []) }
        var request = URLRequest(url: pageURL)
        // Apple serves a thin shell to known bot UAs; the real markup
        // (with subtitle + screenshot picture elements) only renders for
        // browser-style UAs.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            return (nil, [])
        }
        return (scrapeSubtitle(html: html), scrapeScreenshots(html: html))
    }

    private func scrapeSubtitle(html: String) -> String? {
        // The subtitle ships in a JSON blob: `"subtitle":"<value>"`.
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

    /// Pull iPhone screenshot URLs out of the App Store page HTML. Apple
    /// renders each screenshot as a `<picture>` with multiple
    /// `<source srcset="...">` variants. Each URL has the shape
    /// `.../WIDTHxHEIGHTbb[-QUALITY].<ext>` (e.g. `600x1300bb-60.jpg` is
    /// 60% JPEG quality; `600x1300bb.webp` is lossless). Detail-page hero
    /// images use a similar shape but with an extra `SCS.ApDPCS01` token
    /// before the quality suffix, which this pattern excludes. We filter
    /// to portrait, hi-res images and dedupe by the base path so each
    /// screenshot only appears once.
    private func scrapeScreenshots(html: String) -> [URL] {
        let pattern = #"https://is\d+-ssl\.mzstatic\.com/image/thumb/[^"\s\\]+?/(\d{3,4})x(\d{3,4})bb(?:-\d+)?\.(?:png|jpg|webp|jpeg)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let nsHtml = html as NSString
        let range = NSRange(location: 0, length: nsHtml.length)
        let matches = regex.matches(in: html, range: range)

        /// One variant of one screenshot. We track the first occurrence
        /// order so the final list preserves screenshot order from the
        /// page; within each screenshot we keep the largest pixel-width
        /// variant.
        struct Variant {
            let firstSeenAt: Int
            let width: Int
            let url: URL
        }
        var byBase: [String: Variant] = [:]

        for (matchIndex, match) in matches.enumerated() {
            guard
                let urlR = Range(match.range, in: html),
                let wR = Range(match.range(at: 1), in: html),
                let hR = Range(match.range(at: 2), in: html),
                let width = Int(html[wR]),
                let height = Int(html[hR])
            else { continue }
            // Portrait only. Excludes square icons and the
            // detail-page hero/landscape preview frames.
            guard height > width, width >= 200 else { continue }
            let urlString = String(html[urlR])
            // Dedupe by the URL minus the size suffix so multiple
            // <source srcset> variants of the same screenshot collapse
            // to a single entry.
            let base = urlString.replacingOccurrences(
                of: #"/\d{3,4}x\d{3,4}bb(?:-\d+)?\.(?:png|jpg|webp|jpeg)$"#,
                with: "",
                options: .regularExpression
            )
            guard let url = URL(string: urlString) else { continue }
            if let existing = byBase[base] {
                if width > existing.width {
                    byBase[base] = Variant(
                        firstSeenAt: existing.firstSeenAt,
                        width: width,
                        url: url
                    )
                }
            } else {
                byBase[base] = Variant(
                    firstSeenAt: matchIndex,
                    width: width,
                    url: url
                )
            }
        }

        return byBase.values
            .sorted { $0.firstSeenAt < $1.firstSeenAt }
            .map { $0.url }
    }
}
