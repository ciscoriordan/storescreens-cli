import Foundation
import StorescreensCore

struct OutputOrganizer {

    /// Organize exported xcresulttool attachments into the final output structure.
    /// Files are saved as: outputDir/[locale]/[appearance]/DevicePrefix_screenshot.png
    func organize(
        attachments: [TestAttachmentDetails],
        rawExportDir: String,
        outputDir: String,
        device: ResolvedDevice,
        locale: String? = nil,
        appearance: String? = nil,
        screenshotFilter: [String]?
    ) throws -> [CaptureManifest.Screenshot] {
        let fm = FileManager.default
        let devicePrefix = device.appStoreSize.filenamePrefix
        let baseDir = qualifiedBaseDir(outputDir: outputDir, locale: locale, appearance: appearance)
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

        // Build a name → attachment lookup so we can emit in filter order.
        var byName: [String: (attachment: Attachment, timestamp: Double?)] = [:]
        for testDetail in attachments {
            for attachment in testDetail.attachments {
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
                let name = Self.cleanAttachmentName(rawName)
                byName[name] = (attachment, attachment.timestamp)
            }
        }

        // Iterate in filter order when a filter is present, else in the
        // order attachments came back from xcresult.
        let orderedNames: [String] = {
            if let filter = screenshotFilter {
                return filter.filter { byName[$0] != nil }
            }
            // No filter: preserve arrival order by rebuilding a flat list
            return attachments.flatMap { $0.attachments }
                .map { Self.cleanAttachmentName($0.suggestedHumanReadableName) }
                .filter { byName[$0] != nil }
        }()

        var screenshots: [CaptureManifest.Screenshot] = []
        for name in orderedNames {
            guard let entry = byName[name] else { continue }
            let srcPath = (rawExportDir as NSString)
                .appendingPathComponent(entry.attachment.exportedFileName)
            guard fm.fileExists(atPath: srcPath) else { continue }

            let destFilename = "\(devicePrefix)_\(name).png"
            let destPath = (baseDir as NSString).appendingPathComponent(destFilename)
            try? fm.removeItem(atPath: destPath)
            try fm.copyItem(atPath: srcPath, toPath: destPath)

            screenshots.append(CaptureManifest.Screenshot(
                name: name,
                filename: relativeFilename(devicePrefix: devicePrefix, screenshotName: name, locale: locale, appearance: appearance),
                capturedAt: entry.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
            ))
        }

        return screenshots
    }

    /// Organize a simple-mode screenshot into the output structure.
    func organizeSimpleScreenshot(
        sourcePath: String,
        name: String,
        outputDir: String,
        device: ResolvedDevice,
        locale: String? = nil,
        appearance: String? = nil
    ) throws -> CaptureManifest.Screenshot {
        let fm = FileManager.default
        let devicePrefix = device.appStoreSize.filenamePrefix
        let baseDir = qualifiedBaseDir(outputDir: outputDir, locale: locale, appearance: appearance)
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

        let destFilename = "\(devicePrefix)_\(name).png"
        let destPath = (baseDir as NSString).appendingPathComponent(destFilename)

        try? fm.removeItem(atPath: destPath)
        try fm.copyItem(atPath: sourcePath, toPath: destPath)

        return CaptureManifest.Screenshot(
            name: name,
            filename: relativeFilename(devicePrefix: devicePrefix, screenshotName: name, locale: locale, appearance: appearance),
            capturedAt: Date()
        )
    }

    /// Collect screenshots written directly to the filesystem by the test code (fastlane-style).
    /// Supports both plain names ("01_Home.png") and the legacy prefixed format
    /// ("iPhone 17 Pro Max-01_Home.png"). Modern tests are expected to write plain
    /// names into a per-simulator subdirectory (the orchestrator passes one via
    /// `screenshotsDir`), which is already namespaced. The prefix form is kept
    /// working for older test templates that prepend the simulator name.
    func organizeFromFilesystem(
        screenshotsDir: String,
        simulatorName: String,
        outputDir: String,
        device: ResolvedDevice,
        locale: String? = nil,
        appearance: String? = nil,
        screenshotFilter: [String]?
    ) throws -> [CaptureManifest.Screenshot] {
        let fm = FileManager.default
        let devicePrefix = device.appStoreSize.filenamePrefix
        let baseDir = qualifiedBaseDir(outputDir: outputDir, locale: locale, appearance: appearance)
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

        // Build a name → filename map so we can iterate in filter order.
        let prefix = "\(simulatorName)-"
        let allFiles = (try? fm.contentsOfDirectory(atPath: screenshotsDir)) ?? []
        var fileByName: [String: String] = [:]
        for filename in allFiles where filename.hasSuffix(".png") {
            let nameWithoutExt = String(filename.dropLast(4))
            let name = nameWithoutExt.hasPrefix(prefix)
                ? String(nameWithoutExt.dropFirst(prefix.count))
                : nameWithoutExt
            fileByName[name] = filename
        }

        // Iterate in filter order when a filter is present; else preserve
        // whatever order the filesystem returned (no alphabetical sort).
        let orderedNames: [String] = {
            if let filter = screenshotFilter {
                return filter.filter { fileByName[$0] != nil }
            }
            return allFiles
                .filter { $0.hasSuffix(".png") }
                .map { f -> String in
                    let nameWithoutExt = String(f.dropLast(4))
                    return nameWithoutExt.hasPrefix(prefix)
                        ? String(nameWithoutExt.dropFirst(prefix.count))
                        : nameWithoutExt
                }
                .filter { fileByName[$0] != nil }
        }()

        var screenshots: [CaptureManifest.Screenshot] = []
        for name in orderedNames {
            guard let filename = fileByName[name] else { continue }
            let srcPath = (screenshotsDir as NSString).appendingPathComponent(filename)
            let destFilename = "\(devicePrefix)_\(name).png"
            let destPath = (baseDir as NSString).appendingPathComponent(destFilename)

            try? fm.removeItem(atPath: destPath)
            try fm.copyItem(atPath: srcPath, toPath: destPath)

            screenshots.append(CaptureManifest.Screenshot(
                name: name,
                filename: relativeFilename(devicePrefix: devicePrefix, screenshotName: name, locale: locale, appearance: appearance),
                capturedAt: Date()
            ))
        }

        return screenshots
    }

    /// Write the final manifest.json.
    func writeManifest(_ manifest: CaptureManifest, to outputDir: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let path = (outputDir as NSString).appendingPathComponent("manifest.json")
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Private

    /// Extract the original attachment name from xcresulttool's suggestedHumanReadableName.
    /// Input format: "01_home_empty_0_E0857E0B-CF5B-4340-BE0F-3D2949AB2FD4.png"
    /// Output: "01_home_empty"
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
    /// Examples: "iPhone_6.9_01_Home.png", "en-US/dark/iPhone_6.9_01_Home.png"
    private func relativeFilename(devicePrefix: String, screenshotName: String, locale: String?, appearance: String?) -> String {
        var components: [String] = []
        if let locale { components.append(locale) }
        if let appearance { components.append(appearance) }
        components.append("\(devicePrefix)_\(screenshotName).png")
        return components.joined(separator: "/")
    }
}
