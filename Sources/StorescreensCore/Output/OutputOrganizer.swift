import Foundation
import ImageIO

/// Screenshots filed under one App Store size label. A device's capture is
/// normally a single group labeled with the device's own size; a device with
/// two displays can produce a group per display (see
/// `OutputOrganizer.labelSize`). Each group becomes one manifest entry.
package struct LabeledScreenshots: Sendable {
    package let size: AppStoreScreenSize
    package var screenshots: [CaptureManifest.Screenshot]

    package init(size: AppStoreScreenSize, screenshots: [CaptureManifest.Screenshot] = []) {
        self.size = size
        self.screenshots = screenshots
    }
}

extension Array where Element == LabeledScreenshots {
    /// Adds `shot` to the group for `size`, starting a new group the first
    /// time a size appears, so groups keep the order they were first seen in.
    package mutating func append(_ shot: CaptureManifest.Screenshot, labeledAs size: AppStoreScreenSize) {
        if let index = firstIndex(where: { $0.size == size }) {
            self[index].screenshots.append(shot)
        } else {
            append(LabeledScreenshots(size: size, screenshots: [shot]))
        }
    }

    /// Screenshot count across all groups.
    package var screenshotCount: Int {
        reduce(0) { $0 + $1.screenshots.count }
    }
}

package struct OutputOrganizer {
    package init() {}

    // MARK: - Labeling by captured size

    /// The App Store size a screenshot from a device is labeled with, which
    /// sets its filename prefix and its manifest `deviceType`. Normally the
    /// device's own size (`profile`, from its CoreSimulator device type).
    ///
    /// A device with two displays reports only one of them in its profile
    /// (`DeviceMapping.mainDisplay`), but its screenshots show whichever
    /// display is active: the iPhone Duo produces 1398x2034 PNGs when folded
    /// and 2007x2853 when open, and storescreens cannot set the pose. So when
    /// the captured image's size, ignoring orientation, differs from the
    /// profile's and is a size storescreens knows by name, the screenshot is
    /// labeled with the image's own size (in portrait, as profiles are).
    /// Every other mismatch keeps the profile's label, as before: an element
    /// or cropped screenshot, or an image size with no name. Mac sizes come
    /// from the config rather than a device profile, so they are never
    /// relabeled. Pure, so the rule is testable without a simulator.
    package static func labelSize(
        profile: AppStoreScreenSize,
        capturedWidth: Int,
        capturedHeight: Int
    ) -> AppStoreScreenSize {
        guard !profile.isMac else { return profile }
        let captured = AppStoreScreenSize(
            width: min(capturedWidth, capturedHeight),
            height: max(capturedWidth, capturedHeight),
            productFamily: profile.productFamily
        )
        let profileWidth = min(profile.width, profile.height)
        let profileHeight = max(profile.width, profile.height)
        guard captured.width != profileWidth || captured.height != profileHeight else { return profile }
        return captured.hasFriendlyName ? captured : profile
    }

    /// `labelSize` for the PNG at `path`. The device's own size when the
    /// image can't be read or the device is a Mac.
    package static func labelSize(forImageAt path: String, device: ResolvedDevice) -> AppStoreScreenSize {
        guard !device.isMacOS, let pixels = pixelSize(ofImageAt: path) else { return device.appStoreSize }
        return labelSize(profile: device.appStoreSize, capturedWidth: pixels.width, capturedHeight: pixels.height)
    }

    /// Pixel dimensions of the image at `path`, read from its header.
    package static func pixelSize(ofImageAt path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// The log line for a group labeled with something other than its
    /// device's own size, or nil when the group keeps the device's label.
    package static func relabelNote(for group: LabeledScreenshots, device: ResolvedDevice) -> String? {
        let profile = device.appStoreSize
        guard group.size != profile else { return nil }
        return "\(device.simulatorName) screenshots show a \(group.size.width)x\(group.size.height) display, "
            + "not the \(profile.width)x\(profile.height) one its simulator profile lists; "
            + "labeled \"\(group.size.displayName)\" instead of \"\(profile.displayName)\""
    }

    // MARK: - Organizing

    /// Organize exported xcresulttool attachments into the final output structure.
    /// Files are saved as: outputDir/[locale]/[appearance]/DevicePrefix_screenshot.png,
    /// where DevicePrefix comes from each file's `labelSize`; the result is
    /// grouped by that label.
    package func organize(
        attachments: [TestAttachmentDetails],
        rawExportDir: String,
        outputDir: String,
        device: ResolvedDevice,
        locale: String? = nil,
        appearance: String? = nil,
        screenshotFilter: [String]?,
        onScreenshotSaved: ((_ name: String, _ path: String) async -> Void)? = nil
    ) async throws -> [LabeledScreenshots] {
        let fm = FileManager.default
        let baseDir = qualifiedBaseDir(outputDir: outputDir, locale: locale, appearance: appearance)
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

        var groups: [LabeledScreenshots] = []

        for testDetail in attachments {
            for attachment in testDetail.attachments {
                // Skip system-generated attachments (screen recordings, synthesized events, failure artifacts, etc.)
                let rawName = attachment.suggestedHumanReadableName
                if rawName.hasPrefix("Synthesized Event") || rawName.hasPrefix("Screen Recording")
                    || rawName.hasPrefix("kXCTAttachment")
                    || rawName.hasPrefix("Complete Issue Description")
                    || rawName.hasPrefix("App UI hierarchy")
                    || rawName.hasPrefix("UI Snapshot")
                    || rawName.hasPrefix("Debug description")
                    || rawName.hasPrefix("Screenshot") {
                    continue
                }

                // suggestedHumanReadableName format: "<name>_<N>_<UUID>.png"
                // (e.g. "Home_0_E0857E0B-...png"). Strip the _N_UUID.png suffix
                // to get the original attachment name the test code passed.
                let name = Self.cleanAttachmentName(rawName)

                // Filter by name if specified
                if let filter = screenshotFilter, !filter.contains(name) {
                    continue
                }

                let srcPath = (rawExportDir as NSString)
                    .appendingPathComponent(attachment.exportedFileName)

                guard fm.fileExists(atPath: srcPath) else { continue }

                let size = Self.labelSize(forImageAt: srcPath, device: device)
                let devicePrefix = size.filenamePrefix
                let destFilename = "\(devicePrefix)_\(name).png"
                let destPath = (baseDir as NSString).appendingPathComponent(destFilename)

                // Remove existing file if present
                try? fm.removeItem(atPath: destPath)
                try fm.copyItem(atPath: srcPath, toPath: destPath)

                let shot = CaptureManifest.Screenshot(
                    name: name,
                    filename: relativeFilename(devicePrefix: devicePrefix, screenshotName: name, locale: locale, appearance: appearance),
                    capturedAt: attachment.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
                )
                groups.append(shot, labeledAs: size)
                await onScreenshotSaved?(name, destPath)
            }
        }

        return groups
    }

    /// Organize a simple-mode screenshot into the output structure. Returns
    /// the screenshot and the size it is labeled with (see `labelSize`).
    package func organizeSimpleScreenshot(
        sourcePath: String,
        name: String,
        outputDir: String,
        device: ResolvedDevice,
        locale: String? = nil,
        appearance: String? = nil
    ) throws -> (screenshot: CaptureManifest.Screenshot, size: AppStoreScreenSize) {
        let fm = FileManager.default
        let size = Self.labelSize(forImageAt: sourcePath, device: device)
        let devicePrefix = size.filenamePrefix
        let baseDir = qualifiedBaseDir(outputDir: outputDir, locale: locale, appearance: appearance)
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

        let destFilename = "\(devicePrefix)_\(name).png"
        let destPath = (baseDir as NSString).appendingPathComponent(destFilename)

        try? fm.removeItem(atPath: destPath)
        try fm.copyItem(atPath: sourcePath, toPath: destPath)

        let screenshot = CaptureManifest.Screenshot(
            name: name,
            filename: relativeFilename(devicePrefix: devicePrefix, screenshotName: name, locale: locale, appearance: appearance),
            capturedAt: Date()
        )
        return (screenshot, size)
    }

    /// Collect screenshots written directly to the filesystem by the test code (fastlane-style).
    /// Files are named "{SimulatorName}-{screenshotName}.png". Grouped by each
    /// file's `labelSize`, like `organize`.
    package func organizeFromFilesystem(
        screenshotsDir: String,
        simulatorName: String,
        outputDir: String,
        device: ResolvedDevice,
        locale: String? = nil,
        appearance: String? = nil,
        screenshotFilter: [String]?,
        onScreenshotSaved: ((_ name: String, _ path: String) async -> Void)? = nil
    ) async throws -> [LabeledScreenshots] {
        let fm = FileManager.default
        let baseDir = qualifiedBaseDir(outputDir: outputDir, locale: locale, appearance: appearance)
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

        var groups: [LabeledScreenshots] = []

        // Find all PNG files in the device-specific directory.
        // Supports both plain names ("Home.png") and the legacy prefixed format
        // ("iPhone 18 Pro Max-Home.png") where the simulator name is prepended.
        let prefix = "\(simulatorName)-"
        let allFiles = (try? fm.contentsOfDirectory(atPath: screenshotsDir)) ?? []
        let matchingFiles = allFiles
            .filter { $0.hasSuffix(".png") }
            .sorted()

        for filename in matchingFiles {
            // Strip the optional "SimulatorName-" prefix, then ".png"
            let nameWithoutExt = String(filename.dropLast(4)) // remove .png
            let name = nameWithoutExt.hasPrefix(prefix)
                ? String(nameWithoutExt.dropFirst(prefix.count))
                : nameWithoutExt

            // Filter by name if specified
            if let filter = screenshotFilter, !filter.contains(name) {
                continue
            }

            let srcPath = (screenshotsDir as NSString).appendingPathComponent(filename)
            let size = Self.labelSize(forImageAt: srcPath, device: device)
            let devicePrefix = size.filenamePrefix
            let destFilename = "\(devicePrefix)_\(name).png"
            let destPath = (baseDir as NSString).appendingPathComponent(destFilename)

            try? fm.removeItem(atPath: destPath)
            try fm.copyItem(atPath: srcPath, toPath: destPath)

            groups.append(CaptureManifest.Screenshot(
                name: name,
                filename: relativeFilename(devicePrefix: devicePrefix, screenshotName: name, locale: locale, appearance: appearance),
                capturedAt: Date()
            ), labeledAs: size)
            await onScreenshotSaved?(name, destPath)
        }

        return groups
    }

    /// Write the final manifest.json.
    package func writeManifest(_ manifest: CaptureManifest, to outputDir: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let path = (outputDir as NSString).appendingPathComponent("manifest.json")
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Stamp each screenshot PNG's modificationDate and creationDate so that
    /// sorting by "date modified" (ls -t) or Finder's "Date Created" shows
    /// them in `order`. The first name in `order` gets the most recent
    /// timestamp; each subsequent entry is 1 ms older. Screenshots whose
    /// names aren't in `order` get a much older timestamp so they sort
    /// after all listed entries.
    ///
    /// No-op when `order` is nil or empty: legacy configs that relied on
    /// alphabetical filename ordering keep their capture-time mtimes.
    package func stampMtimes(
        manifest: CaptureManifest,
        outputDir: String,
        order: [String]?
    ) {
        guard let order, !order.isEmpty else { return }
        let fm = FileManager.default
        let ordinal: [String: Int] = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) }
        )
        let base = Date()
        let step: TimeInterval = 0.001
        let unlistedOffset: TimeInterval = -3600

        for device in manifest.devices {
            for shot in device.screenshots {
                let abs = (outputDir as NSString).appendingPathComponent(shot.filename)
                guard fm.fileExists(atPath: abs) else { continue }
                let ts: Date
                if let idx = ordinal[shot.name] {
                    ts = base.addingTimeInterval(-step * Double(idx))
                } else {
                    ts = base.addingTimeInterval(unlistedOffset)
                }
                try? fm.setAttributes([
                    .modificationDate: ts,
                    .creationDate: ts,
                ], ofItemAtPath: abs)
            }
        }
    }

    // MARK: - Private

    /// Extract the original attachment name from xcresulttool's suggestedHumanReadableName.
    /// Input format: "Home_0_E0857E0B-CF5B-4340-BE0F-3D2949AB2FD4.png"
    /// Output: "Home"
    private static func cleanAttachmentName(_ suggestedName: String) -> String {
        // Remove .png extension if present
        var name = suggestedName
        if name.hasSuffix(".png") {
            name = String(name.dropLast(4))
        }

        // XCTest appends "_N_UUID" where N is the repetition number and UUID is a GUID.
        // Pattern: _\d+_[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}
        // Try to strip this suffix.
        if let range = name.range(of: #"_\d+_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) {
            name = String(name[name.startIndex..<range.lowerBound])
        }

        return name
    }

    /// Returns outputDir with locale and/or appearance subdirectories appended.
    /// Structure: outputDir / locale / appearance / ...
    private func qualifiedBaseDir(outputDir: String, locale: String?, appearance: String?) -> String {
        var path = outputDir
        if let locale {
            path = (path as NSString).appendingPathComponent(locale)
        }
        if let appearance {
            path = (path as NSString).appendingPathComponent(appearance)
        }
        return path
    }

    /// Returns the relative filename for the manifest.
    /// Examples: "iPhone_6.9_Home.png", "en-US/dark/iPhone_6.9_Home.png"
    private func relativeFilename(devicePrefix: String, screenshotName: String, locale: String?, appearance: String?) -> String {
        var components: [String] = []
        if let locale { components.append(locale) }
        if let appearance { components.append(appearance) }
        components.append("\(devicePrefix)_\(screenshotName).png")
        return components.joined(separator: "/")
    }
}
