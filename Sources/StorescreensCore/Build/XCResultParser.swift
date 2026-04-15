import Foundation

/// Summary of test results extracted from an .xcresult bundle.
/// Counts plus human-readable failure details, suitable for surfacing to the user.
package struct XCTestSummary: Sendable {
    package let totalTests: Int
    package let passedTests: Int
    package let failedTests: Int
    package let skippedTests: Int
    package let failures: [Failure]

    package struct Failure: Sendable {
        /// Full test identifier, e.g. "MyAppUITests/ScreenshotTests/testPolytonicLayer()"
        package let testName: String
        /// Target name, e.g. "MyAppUITests"
        package let targetName: String
        /// Assertion message plus source location if available.
        package let failureText: String
    }

    /// True when xcresulttool reported at least one non-passed, non-skipped test.
    package var hasFailures: Bool { failedTests > 0 }
}

package struct XCResultParser {
    private let shell = ShellRunner()

    package init() {}

    /// Extract a high level test summary (pass/fail/skip counts plus failures) from a result bundle.
    /// Uses `xcresulttool get test-results summary --path <bundle>`, which is the modern
    /// (Xcode 16+) replacement for the legacy object graph. Returns nil if xcresulttool
    /// fails or the JSON cannot be decoded.
    package func extractTestSummary(resultBundlePath: String) async -> XCTestSummary? {
        guard let result = try? await shell.xcrun("xcresulttool", arguments: [
            "get", "test-results", "summary",
            "--path", resultBundlePath,
            "--compact",
        ]),
        result.succeeded,
        let data = result.stdout.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let total = json["totalTestCount"] as? Int ?? 0
        let passed = json["passedTests"] as? Int ?? 0
        let failed = json["failedTests"] as? Int ?? 0
        let skipped = json["skippedTests"] as? Int ?? 0

        var failures: [XCTestSummary.Failure] = []
        if let failureList = json["testFailures"] as? [[String: Any]] {
            for entry in failureList {
                let name = entry["testName"] as? String ?? "unknown test"
                let target = entry["targetName"] as? String ?? ""
                let text = entry["failureText"] as? String ?? "unknown failure"
                failures.append(.init(testName: name, targetName: target, failureText: text))
            }
        }

        return XCTestSummary(
            totalTests: total,
            passedTests: passed,
            failedTests: failed,
            skippedTests: skipped,
            failures: failures
        )
    }

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
