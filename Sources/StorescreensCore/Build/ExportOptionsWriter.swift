import Foundation

/// Generates an `ExportOptions.plist` for `xcodebuild -exportArchive`.
///
/// Defaults mirror fastlane `gym`: `method: app-store`, `uploadSymbols: true`,
/// `stripSwiftSymbols: true`, `signingStyle: automatic` unless
/// `provisioningProfiles` is populated (then `manual`).
package enum ExportOptionsWriter {

    package static func write(
        from config: UploadBuildConfig,
        to url: URL
    ) throws {
        var plist: [String: Any] = [:]

        plist["method"] = config.exportMethod ?? "app-store"

        if let teamID = config.teamID, !teamID.isEmpty {
            plist["teamID"] = teamID
        }

        plist["uploadSymbols"] = config.includeSymbols ?? true
        plist["stripSwiftSymbols"] = config.stripSwiftSymbols ?? true

        if let profiles = config.provisioningProfiles, !profiles.isEmpty {
            plist["provisioningProfiles"] = profiles
            plist["signingStyle"] = config.signingStyle ?? "manual"
        } else if let style = config.signingStyle {
            plist["signingStyle"] = style
        }

        // `destination: export` is the default; set explicitly to be robust
        // against xcodebuild behaviour changes.
        plist["destination"] = "export"

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }
}
