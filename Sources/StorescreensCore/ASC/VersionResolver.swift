import Foundation

/// Given the current Xcode project state and the live App Store Connect
/// state, compute the next legal `(marketingVersion, buildNumber)` tuple.
///
/// Rules:
/// - If the marketing version is already shipped (READY_FOR_SALE etc.):
///   bump the patch component (`1.1.7` -> `1.1.8`), build = `1`.
/// - Else if the marketing version has existing builds in TestFlight /
///   pre-release: marketing stays, build = max(existing) + 1.
/// - Else (fresh marketing version, no builds): marketing stays, build = `1`.
///   If the current build is already `1`, this is a no-op.
///
/// A user-provided `override` short-circuits the ASC lookup logic while
/// still running the build-number collision check.
package actor VersionResolver {
    package let appsAPI: AppsAPI
    package let buildsAPI: BuildsAPI
    package let platform: String

    package init(
        appsAPI: AppsAPI,
        buildsAPI: BuildsAPI,
        platform: String = "IOS"
    ) {
        self.appsAPI = appsAPI
        self.buildsAPI = buildsAPI
        self.platform = platform
    }

    /// The next (version, build) we'll archive against, plus a human-readable
    /// reason explaining why.
    package struct Resolution: Sendable {
        package let marketingVersion: String
        package let buildNumber: String
        package let reason: String
        /// True when the resolver changed either field relative to the
        /// current Xcode state. The caller decides whether to write.
        package let changed: Bool
    }

    /// App Store Connect states that mean "the marketing version has been
    /// published / is being published and is no longer editable". Uploading
    /// a new build under the same marketing string to these will be rejected
    /// by Apple, so the resolver bumps the version.
    private static let shippedStates: Set<String> = [
        "READY_FOR_SALE",
        "PROCESSING_FOR_APP_STORE",
        "PENDING_APPLE_RELEASE",
        "PENDING_DEVELOPER_RELEASE",
        "REPLACED_WITH_NEW_VERSION",
        "REMOVED_FROM_SALE",
    ]

    package func resolve(
        appID: String,
        current: XcodeVersion.State,
        override: Override? = nil
    ) async throws -> Resolution {
        if let override, let v = override.marketingVersion, let b = override.buildNumber {
            return Resolution(
                marketingVersion: v,
                buildNumber: b,
                reason: "explicit override: --marketing-version + --build",
                changed: v != current.marketingVersion || b != current.buildNumber
            )
        }

        // Either no override, or partial override. Look at ASC.
        let targetMarketing = override?.marketingVersion ?? current.marketingVersion

        // 1. Is this marketing version shipped?
        let versions = try await appsAPI.listVersions(appID: appID, platform: platform)
        let match = versions.first { $0.attributes?.versionString == targetMarketing }
        let state = match?.attributes?.appStoreState ?? ""
        let isShipped = Self.shippedStates.contains(state)

        // 2. What build numbers exist on this train?
        let highestBuild = try await buildsAPI.highestBuildNumber(
            appID: appID, marketingVersion: targetMarketing, platform: platform
        )

        // 3. Decide.
        if isShipped && override?.marketingVersion == nil {
            // Auto-bump patch version, reset build to 1.
            let bumped = Self.bumpPatch(targetMarketing)
            // Still check if the bumped version has any builds (rare but
            // possible if you've already uploaded test builds under the new
            // version number).
            let bumpedHigh = try await buildsAPI.highestBuildNumber(
                appID: appID, marketingVersion: bumped, platform: platform
            )
            let buildNumber = override?.buildNumber ?? String((bumpedHigh ?? 0) + 1)
            return Resolution(
                marketingVersion: bumped,
                buildNumber: buildNumber,
                reason: "marketing version \(targetMarketing) is \(state); bumped to \(bumped)",
                changed: bumped != current.marketingVersion || buildNumber != current.buildNumber
            )
        }

        // Not shipped (or user locked the marketing version with an override).
        let buildNumber: String
        let reason: String
        if let override = override?.buildNumber {
            buildNumber = override
            reason = "explicit --build override"
        } else if let highest = highestBuild {
            // Current Xcode build wins if it's already higher than what's in
            // TestFlight; otherwise bump past the highest existing.
            let currentInt = Int(current.buildNumber.split(separator: ".").first.map(String.init) ?? current.buildNumber)
            if let c = currentInt, c > highest {
                buildNumber = current.buildNumber
                reason = "current build \(c) already exceeds max TestFlight build (\(highest))"
            } else {
                buildNumber = String(highest + 1)
                reason = "build \(current.buildNumber) collides with TestFlight; bumped to \(highest + 1)"
            }
        } else {
            // Fresh train, no builds yet. If the Xcode project already has a
            // sensible integer build number, keep it. Otherwise reset to 1.
            if Int(current.buildNumber) != nil {
                buildNumber = current.buildNumber
                reason = "fresh version \(targetMarketing); keeping build \(current.buildNumber)"
            } else {
                buildNumber = "1"
                reason = "fresh version \(targetMarketing); resetting build to 1"
            }
        }

        return Resolution(
            marketingVersion: targetMarketing,
            buildNumber: buildNumber,
            reason: reason,
            changed: targetMarketing != current.marketingVersion || buildNumber != current.buildNumber
        )
    }

    // MARK: - Helpers

    /// Bump the last numeric component. `"1.1.7"` -> `"1.1.8"`. Non-numeric
    /// tails get `.1` appended.
    package static func bumpPatch(_ version: String) -> String {
        let parts = version.split(separator: ".").map(String.init)
        guard let last = parts.last, let n = Int(last) else {
            return version + ".1"
        }
        var bumped = parts
        bumped[bumped.count - 1] = String(n + 1)
        return bumped.joined(separator: ".")
    }

    package struct Override: Sendable {
        package let marketingVersion: String?
        package let buildNumber: String?
        package init(marketingVersion: String? = nil, buildNumber: String? = nil) {
            self.marketingVersion = marketingVersion
            self.buildNumber = buildNumber
        }
    }
}
