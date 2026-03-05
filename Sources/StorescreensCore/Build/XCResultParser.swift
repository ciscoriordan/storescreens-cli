import Foundation

package struct XCResultParser {
    private let shell = ShellRunner()

    package init() {}

    /// Extract test failure summaries from a result bundle.
    /// Queries `xcresulttool get object --legacy` and parses `testFailureSummaries`.
    /// Returns human-readable failure messages with file:line location, e.g.:
    ///   "XCTAssertTrue failed (ScreenshotTests.swift:185)"
    /// Returns an empty array if the xcresult has no failures or cannot be parsed.
    package func extractFailureSummaries(resultBundlePath: String) async -> [String] {
        guard let result = try? await shell.xcrun("xcresulttool", arguments: [
            "get", "object", "--legacy",
            "--path", resultBundlePath,
            "--format", "json",
        ]),
        let data = result.stdout.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let actionValues = (json["actions"] as? [String: Any])?["_values"] as? [[String: Any]]
        else { return [] }

        var messages: [String] = []
        for action in actionValues {
            guard
                let actionResult = action["actionResult"] as? [String: Any],
                let issues = actionResult["issues"] as? [String: Any],
                let summaryValues = (issues["testFailureSummaries"] as? [String: Any])?["_values"] as? [[String: Any]]
            else { continue }

            for summary in summaryValues {
                var msg = (summary["message"] as? [String: Any])?["_value"] as? String
                    ?? "Unknown failure"
                // Append file:line from the source location URL, e.g.
                // file:///…/ScreenshotTests.swift#EndingLineNumber=184&StartingLineNumber=184
                if let urlStr = ((summary["documentLocationInCreatingWorkspace"] as? [String: Any])?["url"] as? [String: Any])?["_value"] as? String,
                   let fileURL = URL(string: urlStr) {
                    let filename = fileURL.lastPathComponent
                    if let fragment = fileURL.fragment,
                       let lineRange = fragment.range(of: "StartingLineNumber=") {
                        let lineStr = String(fragment[lineRange.upperBound...])
                            .components(separatedBy: "&").first ?? ""
                        msg += " (\(filename):\(lineStr))"
                    } else {
                        msg += " (\(filename))"
                    }
                }
                messages.append(msg)
            }
        }
        return messages
    }

    /// Export all screenshot attachments from a result bundle.
    /// Uses: xcrun xcresulttool export attachments
    /// Returns parsed attachment details.
    package func exportAttachments(
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

package struct TestAttachmentDetails: Codable, Sendable {
    package let testIdentifier: String
    package let testIdentifierURL: String?
    package let attachments: [Attachment]
}

package struct Attachment: Codable, Sendable {
    package let exportedFileName: String
    package let suggestedHumanReadableName: String
    package let isAssociatedWithFailure: Bool
    package let timestamp: Double?
    package let configurationName: String
    package let deviceName: String
    package let deviceId: String
    package let repetitionNumber: Int?
}
