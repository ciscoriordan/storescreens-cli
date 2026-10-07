import Foundation

package struct CaptureManifest: Codable, Sendable {
    package let version: Int
    package let generatedAt: Date
    package let generatedBy: String
    package let appName: String
    package let displayName: String?
    package let scheme: String
    package let devices: [DeviceCapture]

    package init(version: Int, generatedAt: Date, generatedBy: String, appName: String, displayName: String?, scheme: String, devices: [DeviceCapture]) {
        self.version = version
        self.generatedAt = generatedAt
        self.generatedBy = generatedBy
        self.appName = appName
        self.displayName = displayName
        self.scheme = scheme
        self.devices = devices
    }

    package struct DeviceCapture: Codable, Sendable {
        package let deviceType: String
        package let simulatorName: String
        package let locale: String?
        package let appearance: String?
        package let screenshots: [Screenshot]

        package init(deviceType: String, simulatorName: String, locale: String?, appearance: String?, screenshots: [Screenshot]) {
            self.deviceType = deviceType
            self.simulatorName = simulatorName
            self.locale = locale
            self.appearance = appearance
            self.screenshots = screenshots
        }
    }

    package struct Screenshot: Codable, Sendable {
        package let name: String
        package let filename: String
        package let capturedAt: Date
        /// Per-slide appearance override. When set, the renderer pulls the
        /// matching `{ light:, dark: }` variant for every chrome field
        /// regardless of `DeviceCapture.appearance`. nil means inherit
        /// from the device's appearance (legacy multiplier path).
        package let appearance: String?

        package init(name: String, filename: String, capturedAt: Date, appearance: String? = nil) {
            self.name = name
            self.filename = filename
            self.capturedAt = capturedAt
            self.appearance = appearance
        }
    }
}

/// What a capture run set out to capture, as narrowed by the CLI flags
/// `--locale`, `--appearance` and `--only`. A run that none of them narrowed
/// covers everything the config lists.
package struct CaptureScope: Sendable, Equatable {
    /// Locales the run was limited to (`--locale`); nil when it captured
    /// the config's `locales:`.
    package var locales: [String]?
    /// Appearances the run was limited to (`--appearance`); nil when it
    /// captured the config's `appearances:`.
    package var appearances: [String]?
    /// True when `--only` limited the run to some screenshot names, so each
    /// entry it wrote holds only part of that device's screenshots.
    package var someScreenshotsOnly: Bool

    package init(locales: [String]? = nil, appearances: [String]? = nil, someScreenshotsOnly: Bool = false) {
        self.locales = (locales?.isEmpty ?? true) ? nil : locales
        self.appearances = (appearances?.isEmpty ?? true) ? nil : appearances
        self.someScreenshotsOnly = someScreenshotsOnly
    }

    package static let full = CaptureScope()

    package var isFull: Bool { locales == nil && appearances == nil && !someScreenshotsOnly }

    /// True when `entry` is one the run set out to capture: its locale and
    /// appearance are inside the run's limits. An entry with no appearance
    /// (per-slide appearance mode) counts as inside an appearance limit.
    package func covers(_ entry: CaptureManifest.DeviceCapture) -> Bool {
        if let locales, !locales.contains(where: { $0 == entry.locale }) { return false }
        if let appearances, let appearance = entry.appearance, !appearances.contains(appearance) { return false }
        return true
    }
}

extension CaptureManifest {
    /// Reads `manifest.json` from a capture output directory. Nil when the
    /// file does not exist; throws when it exists but cannot be decoded.
    package static func load(fromOutputDir outputDir: String) throws -> CaptureManifest? {
        let path = (outputDir as NSString).appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CaptureManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// The manifest a capture run writes, given the manifest already in the
    /// output directory. `self` holds what this run captured.
    ///
    /// A run that covered the whole config (`scope.isFull`) replaces the
    /// existing manifest, so a device or locale taken out of the config
    /// leaves it. A narrowed run replaces only what it captured, the same
    /// way the capture's files replace only the files it wrote:
    ///
    ///   - An existing entry for the same device, locale and appearance as
    ///     one of this run's entries is replaced by it, in place. Under
    ///     `--only` the two are merged by screenshot name instead: a name
    ///     captured again takes the new screenshot, the others stay.
    ///   - Any other existing entry inside the run's scope is dropped, since
    ///     the run captured that locale and appearance on every configured
    ///     device and this device was not among them. Under `--only` it is
    ///     kept, because the run did not set out to replace it.
    ///   - Existing entries outside the scope (other locales, other
    ///     appearances) are kept as they are.
    ///   - Entries for a device, locale and appearance the existing manifest
    ///     did not have are added at the end.
    ///
    /// Before this, a `capture --locale da` run wrote a manifest.json with
    /// only the `da` entries, and the next `submit` uploaded only Danish
    /// screenshots.
    package func merged(over existing: CaptureManifest?, scope: CaptureScope) -> CaptureManifest {
        guard let existing, !scope.isFull else { return self }

        struct Key: Hashable {
            let deviceType: String
            let simulatorName: String
            let locale: String?
            let appearance: String?
            init(_ entry: DeviceCapture) {
                deviceType = entry.deviceType
                simulatorName = entry.simulatorName
                locale = entry.locale
                appearance = entry.appearance
            }
        }

        var captured: [Key: DeviceCapture] = [:]
        for entry in devices { captured[Key(entry)] = entry }

        var result: [DeviceCapture] = []
        var placed: Set<Key> = []
        for old in existing.devices {
            let key = Key(old)
            if let new = captured[key] {
                guard placed.insert(key).inserted else { continue }
                result.append(scope.someScreenshotsOnly ? Self.mergeByName(old: old, new: new) : new)
            } else if scope.someScreenshotsOnly || !scope.covers(old) {
                result.append(old)
            }
        }
        for entry in devices where placed.insert(Key(entry)).inserted {
            result.append(entry)
        }

        return CaptureManifest(
            version: max(version, existing.version),
            generatedAt: generatedAt,
            generatedBy: generatedBy,
            appName: appName,
            displayName: displayName ?? existing.displayName,
            scheme: scheme,
            devices: result
        )
    }

    /// `old`'s screenshots with each one `new` captured again replaced in
    /// place, then `new`'s other screenshots in their own order.
    private static func mergeByName(old: DeviceCapture, new: DeviceCapture) -> DeviceCapture {
        let newByName = Dictionary(new.screenshots.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        var shots = old.screenshots.map { newByName[$0.name] ?? $0 }
        let oldNames = Set(old.screenshots.map(\.name))
        shots.append(contentsOf: new.screenshots.filter { !oldNames.contains($0.name) })
        return DeviceCapture(
            deviceType: new.deviceType,
            simulatorName: new.simulatorName,
            locale: new.locale,
            appearance: new.appearance,
            screenshots: shots
        )
    }
}
