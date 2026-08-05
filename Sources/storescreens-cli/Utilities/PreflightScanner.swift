import StorescreensCore
import Foundation

/// Scans Swift source files for iPad-unsafe patterns and device-assumption issues.
struct PreflightScanner {

    enum Severity: String {
        case error
        case warning
    }

    struct Finding {
        let severity: Severity
        let rule: String
        let message: String
        let filePath: String
        let lineNumber: Int
        let lineContent: String
    }

    struct ScanResult {
        let findings: [Finding]
        var errors: [Finding] { findings.filter { $0.severity == .error } }
        var warnings: [Finding] { findings.filter { $0.severity == .warning } }
        var hasErrors: Bool { !errors.isEmpty }
    }

    struct DeviceContext {
        let hasIPad: Bool
        let hasIPhone: Bool
        let hasMultipleLocales: Bool

        init(hasIPad: Bool, hasIPhone: Bool, hasMultipleLocales: Bool = false) {
            self.hasIPad = hasIPad
            self.hasIPhone = hasIPhone
            self.hasMultipleLocales = hasMultipleLocales
        }
    }

    // MARK: - Public

    func scan(directory: String, deviceContext: DeviceContext) -> ScanResult {
        let files = findSwiftFiles(in: directory)
        var findings: [Finding] = []

        for file in files {
            guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let lines = contents.components(separatedBy: .newlines)
            findings.append(contentsOf: checkFile(lines: lines, filePath: file, deviceContext: deviceContext))
        }

        return ScanResult(findings: findings)
    }

    static func printFindings(_ result: ScanResult, logger: Logger, projectDir: String) {
        let resolvedDir = (projectDir as NSString).standardizingPath

        for finding in result.findings {
            let relativePath = finding.filePath.hasPrefix(resolvedDir)
                ? String(finding.filePath.dropFirst(resolvedDir.count + 1))
                : finding.filePath

            let level: Logger.Level = finding.severity == .error ? .error : .warning
            logger.log("\(relativePath):\(finding.lineNumber)  [\(finding.rule)]", level: level)
            logger.log("  \(finding.message)", level: .info)
        }

        if result.findings.isEmpty { return }

        let summary = "\(result.errors.count) error\(result.errors.count == 1 ? "" : "s"), \(result.warnings.count) warning\(result.warnings.count == 1 ? "" : "s") found"
        print("")
        if result.hasErrors {
            logger.log(summary, level: .error)
            logger.log("Errors block capture. Use --skip-check to bypass.", level: .info)
        } else {
            logger.log(summary, level: .warning)
        }
    }

    // MARK: - File Discovery

    private func findSwiftFiles(in directory: String) -> [String] {
        let skipDirs: Set<String> = [
            ".build", "Build", "DerivedData", "Pods", ".swiftpm",
            "Carthage", "Packages", "SourcePackages", "node_modules",
            ".git",
        ]

        let fm = FileManager.default
        var files: [String] = []
        guard let enumerator = fm.enumerator(atPath: directory) else { return [] }

        while let path = enumerator.nextObject() as? String {
            let components = path.split(separator: "/")

            if components.contains(where: { skipDirs.contains(String($0)) }) {
                continue
            }

            // Skip test files
            if path.contains("Tests/") || path.contains("UITests/") {
                continue
            }

            if path.hasSuffix(".swift") {
                files.append((directory as NSString).appendingPathComponent(path))
            }
        }
        return files
    }

    // MARK: - Rule Checking

    private func checkFile(
        lines: [String],
        filePath: String,
        deviceContext: DeviceContext
    ) -> [Finding] {
        var findings: [Finding] = []

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                continue
            }

            // Warning: UIScreen.main.bounds (deprecated, doesn't handle split view)
            if line.contains("UIScreen.main.bounds") {
                findings.append(Finding(
                    severity: .warning,
                    rule: "uiscreen-main-bounds",
                    message: "UIScreen.main.bounds is deprecated - doesn't handle iPad split view or multiple scenes",
                    filePath: filePath,
                    lineNumber: lineNumber,
                    lineContent: trimmed
                ))
            }

            // Error: .toolbarVisibility(.hidden, for: .tabBar) without iPad guard (iPad only)
            if deviceContext.hasIPad {
                if matchesToolbarTabBarHidden(line) && !hasIPadGuard(lines: lines, at: index) {
                    findings.append(Finding(
                        severity: .error,
                        rule: "toolbar-tabbar-hidden",
                        message: ".toolbarVisibility(.hidden, for: .tabBar) without iPad guard - may crash on iPad",
                        filePath: filePath,
                        lineNumber: lineNumber,
                        lineContent: trimmed
                    ))
                }

                // Warning: .navigationViewStyle(.stack) (iPad only)
                if line.contains(".navigationViewStyle") && line.contains(".stack") {
                    findings.append(Finding(
                        severity: .warning,
                        rule: "navigation-view-stack",
                        message: ".navigationViewStyle(.stack) forces stack navigation on iPad - consider .automatic for sidebar support",
                        filePath: filePath,
                        lineNumber: lineNumber,
                        lineContent: trimmed
                    ))
                }
            }

            // Error: Unguarded CloudKit usage - crashes in simulator without iCloud entitlement/account
            if matchesCloudKitUsage(line) && !hasCloudKitGuard(lines: lines, at: index) {
                findings.append(Finding(
                    severity: .error,
                    rule: "unguarded-cloudkit",
                    message: "CKContainer/CKDatabase usage without availability guard - crashes in simulator without iCloud account",
                    filePath: filePath,
                    lineNumber: lineNumber,
                    lineContent: trimmed
                ))
            }

            // Warning: AppStore.requestReview / SKStoreReviewController - can show system alert during tests
            if (line.contains("requestReview") || line.contains("SKStoreReviewController"))
                && !hasUITestingGuard(lines: lines, at: index) {
                findings.append(Finding(
                    severity: .warning,
                    rule: "unguarded-review-prompt",
                    message: "App Store review prompt without --uitesting guard - system alert will block screenshot tests. Guard with: if !ProcessInfo.processInfo.arguments.contains(\"--uitesting\")",
                    filePath: filePath,
                    lineNumber: lineNumber,
                    lineContent: trimmed
                ))
            }

            // Warning: Hardcoded iPhone screen dimensions in layout context
            if let dimensionFinding = checkHardcodedDimensions(line: line, trimmed: trimmed, filePath: filePath, lineNumber: lineNumber) {
                findings.append(dimensionFinding)
            }

            // Warning: TipKit Tips.configure() without --uitesting guard - tips can overlay screenshots
            if line.contains("Tips.configure") && !hasUITestingGuard(lines: lines, at: index) {
                findings.append(Finding(
                    severity: .warning,
                    rule: "unguarded-tipkit",
                    message: "Tips.configure() without --uitesting guard - TipKit popovers will overlay screenshots. Guard with: if !ProcessInfo.processInfo.arguments.contains(\"--uitesting\")",
                    filePath: filePath,
                    lineNumber: lineNumber,
                    lineContent: trimmed
                ))
            }
        }

        return findings
    }

    // MARK: - Rule Helpers

    private static let toolbarTabBarPattern = try! NSRegularExpression(
        pattern: #"\.toolbarVisibility\s*\(\s*\.hidden\s*,\s*for:\s*\.tabBar"#
    )

    private func matchesToolbarTabBarHidden(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return Self.toolbarTabBarPattern.firstMatch(in: line, range: range) != nil
    }

    /// Check if lines above the match contain an iPad guard (UIDevice check, #if, etc.)
    private func hasIPadGuard(lines: [String], at index: Int) -> Bool {
        let guardKeywords = ["UIDevice", "userInterfaceIdiom", ".phone", ".pad", "#if", "canImport"]
        let startIndex = max(0, index - 10)
        for i in startIndex..<index {
            let line = lines[i]
            if guardKeywords.contains(where: { line.contains($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - CloudKit

    /// Matches CloudKit API types used in code (not in strings or comments).
    private static let cloudKitCodePattern = try! NSRegularExpression(
        pattern: #"(?<!["\w])(CKContainer|CKDatabase|CKRecord|CKQuery|CKSubscription|CKRecordZone|CKModifyRecordsOperation|CKQueryOperation|CKFetchRecordsOperation|CKFetchRecordZoneChangesOperation)(?!["\w])"#
    )

    private func matchesCloudKitUsage(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Skip import statements
        if trimmed.hasPrefix("import ") { return false }
        // Skip lines that are just string literals (print statements, etc.)
        if isInsideStringLiteral(keyword: "CK", in: line) { return false }

        let range = NSRange(location: 0, length: (line as NSString).length)
        return Self.cloudKitCodePattern.firstMatch(in: line, range: range) != nil
    }

    /// Rough check: if every occurrence of a keyword prefix on the line is inside quotes, skip it.
    private func isInsideStringLiteral(keyword: String, in line: String) -> Bool {
        // Find all quote-delimited regions and check if all keyword occurrences fall within them
        var inString = false
        var stringRanges: [(Int, Int)] = []
        var start = 0
        for (i, ch) in line.enumerated() {
            if ch == "\"" {
                if inString {
                    stringRanges.append((start, i))
                    inString = false
                } else {
                    inString = true
                    start = i
                }
            }
        }

        // Find all positions of the keyword
        var keywordPositions: [Int] = []
        var searchStart = line.startIndex
        while let range = line.range(of: keyword, range: searchStart..<line.endIndex) {
            keywordPositions.append(line.distance(from: line.startIndex, to: range.lowerBound))
            searchStart = range.upperBound
        }

        guard !keywordPositions.isEmpty else { return false }

        // If ALL keyword occurrences are inside string ranges, it's a string literal
        return keywordPositions.allSatisfy { pos in
            stringRanges.contains { start, end in pos > start && pos < end }
        }
    }

    /// Check if the file contains guards around CloudKit usage.
    /// Checks the whole file for file-level guards (isUITesting property, screenshotMode),
    /// and nearby lines for local guards (try/catch, accountStatus).
    private func hasCloudKitGuard(lines: [String], at index: Int) -> Bool {
        // File-level guards - if present anywhere in the file, all CloudKit usage is considered guarded
        let fileLevelKeywords = [
            "isUITesting",              // Property-based UI testing guard
            "screenshotMode",           // Launch argument guard for testing
            "--uitesting",              // Common UI test launch argument in strings
            "accountStatus",            // CKContainer.accountStatus() check
            "ubiquityIdentityToken",    // iCloud availability check
        ]
        for line in lines {
            if fileLevelKeywords.contains(where: { line.contains($0) }) {
                return true
            }
        }

        // Local guards - check nearby lines for error handling
        let localKeywords = [
            "#if",                      // Conditional compilation
            "canImport",               // Conditional import check
            "do {",                     // try/catch block
            "try await",               // Async error handling
            "try ",                    // Sync error handling
            "catch",                   // Error handling
            "ProcessInfo",             // Launch argument checks
        ]
        let startIndex = max(0, index - 15)
        let endIndex = min(lines.count - 1, index + 5)
        for i in startIndex...endIndex {
            let line = lines[i]
            if localKeywords.contains(where: { line.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Check if the requestReview call is guarded by a UI testing check.
    private func hasUITestingGuard(lines: [String], at index: Int) -> Bool {
        let guardKeywords = [
            "--uitesting",
            "isUITesting",
            "screenshotMode",
            "#if DEBUG",
            "ProcessInfo",
        ]
        let startIndex = max(0, index - 15)
        let endIndex = min(lines.count - 1, index + 3)
        for i in startIndex...endIndex {
            let line = lines[i]
            if guardKeywords.contains(where: { line.contains($0) }) {
                return true
            }
        }
        return false
    }

    private static let layoutKeywords: Set<String> = [
        "width", "height", "frame", "CGSize", "CGRect",
        "offset", "padding", "inset", "spacing", "bounds",
        "minWidth", "maxWidth", "minHeight", "maxHeight",
    ]

    /// Known iPhone screen dimensions (points) that suggest hardcoded device assumptions.
    private static let suspiciousScreenDimensions: Set<String> = [
        "390", "393", "414", "428", "430",  // iPhone widths
        "844", "852", "926", "932", "956",  // iPhone heights
    ]

    private static let dimensionPattern = try! NSRegularExpression(
        pattern: #"\b(\d{3,4})\b"#
    )

    private func checkHardcodedDimensions(
        line: String,
        trimmed: String,
        filePath: String,
        lineNumber: Int
    ) -> Finding? {
        // Only check lines with layout context
        let lowered = line.lowercased()
        guard Self.layoutKeywords.contains(where: { lowered.contains($0.lowercased()) }) else {
            return nil
        }

        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        let matches = Self.dimensionPattern.matches(in: line, range: range)

        for match in matches {
            let value = nsLine.substring(with: match.range(at: 1))
            if Self.suspiciousScreenDimensions.contains(value) {
                return Finding(
                    severity: .warning,
                    rule: "hardcoded-screen-dimensions",
                    message: "Possible hardcoded iPhone screen dimension (\(value)) - use GeometryReader or relative layout instead",
                    filePath: filePath,
                    lineNumber: lineNumber,
                    lineContent: trimmed
                )
            }
        }

        return nil
    }
}
