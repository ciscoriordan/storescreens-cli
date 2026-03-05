import Foundation

struct XCResultParser {
    private let shell = ShellRunner()

    /// Export all screenshot attachments from a result bundle.
    /// Uses: xcrun xcresulttool export attachments
    /// Returns parsed attachment details.
    func exportAttachments(
        resultBundlePath: String,
        outputPath: String
    ) async throws -> [TestAttachmentDetails] {
        let fm = FileManager.default
        try fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

        let result = try await shell.xcrun("xcresulttool", arguments: [
            "export", "attachments",
            "--path", resultBundlePath,
            "--output-path", outputPath,
        ])

        guard result.succeeded else {
            throw CLIError.screenshotExtractionFailed(reason: result.stderr)
        }

        // xcresulttool writes a manifest.json in the output directory
        let manifestPath = (outputPath as NSString).appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestPath) else {
            throw CLIError.screenshotExtractionFailed(reason: "No manifest.json produced by xcresulttool")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        return try JSONDecoder().decode([TestAttachmentDetails].self, from: data)
    }
}

// MARK: - xcresulttool manifest models

struct TestAttachmentDetails: Codable, Sendable {
    let testIdentifier: String
    let testIdentifierURL: String?
    let attachments: [Attachment]
}

struct Attachment: Codable, Sendable {
    let exportedFileName: String
    let suggestedHumanReadableName: String
    let isAssociatedWithFailure: Bool
    let timestamp: Double?
    let configurationName: String
    let deviceName: String
    let deviceId: String
    let repetitionNumber: Int?
}
