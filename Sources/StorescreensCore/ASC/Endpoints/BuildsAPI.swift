import Foundation

/// App Store Connect `/v1/builds` endpoint.
///
/// A build in ASC terms is a single upload with a specific build number
/// (`attributes.version`) that hangs off a "pre-release version" / "train"
/// identified by the marketing version string. When you upload build 3 for
/// marketing version 1.2.0, ASC creates (or reuses) the 1.2.0 pre-release
/// train and attaches a build with `version: "3"` to it.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/list_builds
package struct BuildsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    package struct Build: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Build number (e.g. "1", "42"). ASC stores this as a string.
            package let version: String?
            package let uploadedDate: Date?
            package let expired: Bool?
            /// "PROCESSING", "FAILED", "INVALID", "VALID".
            package let processingState: String?
        }
    }

    /// Lists all builds for `appID` whose pre-release version matches
    /// `marketingVersion`, regardless of processing state. The returned list
    /// is sorted newest-first by ASC.
    ///
    /// Returns an empty array when no builds exist for that train yet.
    package func listBuilds(
        appID: String,
        marketingVersion: String,
        platform: String = "IOS"
    ) async throws -> [Build] {
        struct Resp: Decodable { let data: [Build] }
        let resp: Resp = try await client.get(
            path: "builds",
            query: [
                "filter[app]": appID,
                "filter[preReleaseVersion.version]": marketingVersion,
                "filter[preReleaseVersion.platform]": platform,
                "sort": "-version",
                "limit": "200",
            ],
            as: Resp.self
        )
        return resp.data
    }

    /// Returns the highest build number (as an Int) for `marketingVersion`,
    /// or nil if no builds exist or none parse as an integer. ASC build
    /// numbers are typically dotted strings ("1", "1.0", "42") - we parse
    /// the first integer component so "1.5" -> 1, "42" -> 42, "3.14" -> 3.
    /// Good enough for the common case where teams use plain integers.
    package func highestBuildNumber(
        appID: String,
        marketingVersion: String,
        platform: String = "IOS"
    ) async throws -> Int? {
        let builds = try await listBuilds(
            appID: appID, marketingVersion: marketingVersion, platform: platform
        )
        let numbers = builds.compactMap { build -> Int? in
            guard let raw = build.attributes?.version else { return nil }
            // Apple's docs say build numbers are version strings, but in
            // practice apps overwhelmingly use plain integers. Parse the
            // first numeric component.
            let firstChunk = raw.split(separator: ".").first.map(String.init) ?? raw
            return Int(firstChunk)
        }
        return numbers.max()
    }

    /// Newest processed, "VALID" build for the marketing-version train
    /// - the one `submit` should attach to the App Store version.
    /// Apple's processing is async and can take several minutes; when
    /// nothing has finished processing yet this returns nil.
    package func latestValidBuild(
        appID: String,
        marketingVersion: String,
        platform: String = "IOS"
    ) async throws -> Build? {
        let builds = try await listBuilds(
            appID: appID, marketingVersion: marketingVersion, platform: platform
        )
        return builds.first { $0.attributes?.processingState == "VALID" }
    }

    /// PATCH `/v1/builds/{id}` to answer App Store Connect's export
    /// compliance question (`usesNonExemptEncryption`). Most apps ship
    /// with `false`: they only use the standard iOS cryptography
    /// covered by Apple's exemption (HTTPS via URLSession, keychain,
    /// signing, etc.). A build without this answer set can't be
    /// submitted for review or distributed through TestFlight, so ASC
    /// shows it as "Missing Compliance" until the question is answered.
    package func setExportCompliance(
        buildID: String,
        usesNonExemptEncryption: Bool
    ) async throws {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "builds"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                let usesNonExemptEncryption: Bool
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: buildID,
            attributes: .init(usesNonExemptEncryption: usesNonExemptEncryption)
        ))
        struct Resp: Decodable { let data: Build }
        _ = try await client.patch(
            path: "builds/\(buildID)",
            body: body,
            as: Resp.self
        )
    }
}
