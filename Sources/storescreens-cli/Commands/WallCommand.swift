import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens wall ...`: submit your app to the Wall of Apps on
/// storescreens.app — a public showcase of apps shipping with StoreScreens.
struct WallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wall",
        abstract: "Submit your app to the storescreens.app Wall of Apps.",
        subcommands: [WallSubmitCommand.self]
    )
}

struct WallSubmitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "Submit an App Store app to the Wall of Apps.",
        discussion: """
            Looks up the app via Apple's public iTunes Lookup API, then \
            POSTs the entry to the storescreens.app submission backend. \
            A successful response means the submission was received; the \
            wall picks up new entries on the next site build.

            Find your numeric App Store ID in the App Store URL, after \
            /id/: https://apps.apple.com/app/id1234567890 -> 1234567890.
            """
    )

    @Option(
        name: .long,
        help: "App Store app ID (e.g. 1234567890) OR full App Store URL (e.g. https://apps.apple.com/us/app/foo/id1234567890)."
    )
    var app: String

    @Flag(name: .long, help: "Confirm submission. Required.")
    var confirm: Bool = false

    @Option(name: .long, help: "Override the submit endpoint URL.")
    var endpoint: String = "https://api.storescreens.app/wall/submit"

    @Flag(name: .long, help: "Verbose output.")
    var verbose: Bool = false

    func run() async throws {
        let logger = Logger(isVerbose: verbose)
        logger.log("storescreens v\(storescreensVersion) wall submit", level: .info)

        // 1. Accept either a bare numeric ID (1234567890) or a full App
        //    Store URL with /id<digits> somewhere in the path. Extract the
        //    digits either way; if neither shape matches, bail with a tip.
        guard let id = Self.extractAppID(app) else {
            logger.log("Could not parse an app ID from: \(app)", level: .error)
            print("  Pass either the numeric ID (1234567890) or the full App Store URL")
            print("  (https://apps.apple.com/us/app/foo/id1234567890).")
            throw ExitCode(1)
        }

        // 2. Guard the network call behind --confirm so a stray invocation
        //    can't silently submit junk to the wall.
        guard confirm else {
            logger.log("Submission requires --confirm.", level: .warning)
            print("  Re-run with --confirm to send your app to the wall.")
            throw ExitCode(1)
        }

        // 3. Resolve metadata via iTunes Lookup so the submission carries
        //    name + dev + icon + canonical store URL.
        logger.log("Looking up app \(id) on the App Store…", level: .info)
        let meta: AppMeta
        do {
            guard let resolved = try await Self.iTunesLookup(id: id) else {
                logger.log("No app found for ID \(id).", level: .error)
                print("  Verify the ID at https://apps.apple.com/app/id\(id)")
                throw ExitCode(1)
            }
            meta = resolved
        } catch let exit as ExitCode {
            throw exit
        } catch {
            logger.log("iTunes Lookup failed: \(error.localizedDescription)", level: .error)
            throw ExitCode(1)
        }

        logger.log("Found: \(meta.name) by \(meta.dev)", level: .success)

        // 4. POST to the submit endpoint. The backend may not exist yet —
        //    if the request fails, tell the user where to file an issue
        //    instead of throwing a raw network error.
        logger.log("Submitting to \(endpoint)…", level: .info)
        do {
            try await Self.submit(endpoint: endpoint, body: meta)
            logger.log(
                "Submitted. Your app will appear on storescreens.app/#wall after the next site build.",
                level: .success
            )
        } catch {
            logger.log("Submit failed: \(error.localizedDescription)", level: .error)
            print("  The endpoint may not be wired up yet. File an issue:")
            print("    https://github.com/ciscoriordan/storescreens-cli/issues/new")
            throw ExitCode(1)
        }
    }

    // MARK: - helpers

    /// Accepts either a bare numeric app ID or an App Store URL containing
    /// `/id<digits>`, returning the digits. Returns nil if neither matches.
    static func extractAppID(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Pure numeric: return as-is.
        if trimmed.allSatisfy({ $0.isNumber }) {
            return trimmed
        }
        // Look for "id" followed by one-or-more digits (App Store URL form,
        // e.g. .../app/foo/id1234567890?mt=8).
        if let range = trimmed.range(of: #"id(\d+)"#, options: .regularExpression) {
            // Strip the leading "id" — the digits are everything after the
            // 2-char prefix in the matched substring.
            let match = trimmed[range]
            return String(match.dropFirst(2))
        }
        return nil
    }

    struct AppMeta: Codable {
        let id: String
        let name: String
        let dev: String
        let icon: String
        let url: String
    }

    static func iTunesLookup(id: String) async throws -> AppMeta? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)&country=us") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("storescreens-cli/\(storescreensVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }

        struct LookupResponse: Decodable {
            struct Result: Decodable {
                let trackName: String?
                let artistName: String?
                let artworkUrl512: String?
                let artworkUrl100: String?
                let trackViewUrl: String?
            }
            let results: [Result]
        }

        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let r = decoded.results.first, let name = r.trackName else {
            return nil
        }
        return AppMeta(
            id: id,
            name: name,
            dev: r.artistName ?? "",
            icon: r.artworkUrl512 ?? r.artworkUrl100 ?? "",
            url: r.trackViewUrl ?? "https://apps.apple.com/app/id\(id)"
        )
    }

    static func submit(endpoint: String, body: AppMeta) async throws {
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("storescreens-cli/\(storescreensVersion)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(
                .badServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "Submit endpoint returned HTTP \(code)"]
            )
        }
    }
}
