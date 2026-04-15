import Foundation

/// Summary of test results extracted from an .xcresult bundle. Mirrors the
/// equivalent type in StorescreensCore so the CLI path can produce the same
/// loud-on-failure messages as the MCP path.
struct XCTestSummaryCLI {
    let totalTests: Int
    let passedTests: Int
    let failedTests: Int
    let skippedTests: Int
    let failures: [Failure]

    struct Failure {
        let testName: String
        let targetName: String
        let failureText: String
    }

    var hasFailures: Bool { failedTests > 0 }
}

struct XCResultParser {
    private let shell = ShellRunner()

    /// Extract pass/fail/skip counts plus failure details from an xcresult bundle
    /// using `xcresulttool get test-results summary`. Returns nil on parse failure.
    func extractTestSummary(resultBundlePath: String) async -> XCTestSummaryCLI? {
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

        var failures: [XCTestSummaryCLI.Failure] = []
        if let failureList = json["testFailures"] as? [[String: Any]] {
            for entry in failureList {
                let name = entry["testName"] as? String ?? "unknown test"
                let target = entry["targetName"] as? String ?? ""
                let text = entry["failureText"] as? String ?? "unknown failure"
                failures.append(.init(testName: name, targetName: target, failureText: text))
            }
        }

        return XCTestSummaryCLI(
            totalTests: total,
            passedTests: passed,
            failedTests: failed,
            skippedTests: skipped,
            failures: failures
        )
    }

    /// Extract legacy per-failure summaries (message + file:line) from an xcresult
    /// using the deprecated object-graph API. Returns an empty array on any error.
    func extractFailureSummaries(resultBundlePath: String) async -> [String] {
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
