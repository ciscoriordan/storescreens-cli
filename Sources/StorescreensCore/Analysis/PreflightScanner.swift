import Foundation

/// Scans Swift source files for iPad-unsafe patterns and device-assumption issues.
package struct PreflightScanner {

    package init() {}

    package enum Severity: String {
        case error
        case warning
    }

    package struct Finding {
        package let severity: Severity
        package let rule: String
        package let message: String
        package let filePath: String
        package let lineNumber: Int
        package let lineContent: String

        package init(severity: Severity, rule: String, message: String, filePath: String, lineNumber: Int, lineContent: String) {
            self.severity = severity
            self.rule = rule
            self.message = message
            self.filePath = filePath
            self.lineNumber = lineNumber
            self.lineContent = lineContent
        }
    }

    package struct ScanResult {
        package let findings: [Finding]
        package var errors: [Finding] { findings.filter { $0.severity == .error } }
        package var warnings: [Finding] { findings.filter { $0.severity == .warning } }
        package var hasErrors: Bool { !errors.isEmpty }

        package init(findings: [Finding]) {
            self.findings = findings
        }
    }

    package struct DeviceContext {
        package let hasIPad: Bool
        package let hasIPhone: Bool
        package let hasMultipleLocales: Bool

        package init(hasIPad: Bool, hasIPhone: Bool, hasMultipleLocales: Bool = false) {
            self.hasIPad = hasIPad
            self.hasIPhone = hasIPhone
            self.hasMultipleLocales = hasMultipleLocales
        }
    }

    // MARK: - Public

    package func scan(directory: String, deviceContext: DeviceContext) -> ScanResult {
        let sourceFiles = findSwiftFiles(in: directory)
        let testFiles = findUITestFiles(in: directory)
        var findings: [Finding] = []
        var definedIdentifiers: Set<String> = []

        for file in sourceFiles {
            guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let lines = contents.components(separatedBy: .newlines)
            findings.append(contentsOf: checkFile(lines: lines, filePath: file, deviceContext: deviceContext))
            extractDefinedIdentifiers(from: contents, into: &definedIdentifiers)
        }

        if !testFiles.isEmpty {
            findings.append(contentsOf: checkMissingAccessibilityIdentifiers(
                testFiles: testFiles,
                definedIdentifiers: definedIdentifiers
            ))
            findings.append(contentsOf: checkTestFilePatterns(testFiles: testFiles, deviceContext: deviceContext))
        }

        return ScanResult(findings: findings)
    }

    package static func printFindings(_ result: ScanResult, logger: Logger, projectDir: String) {
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

    // MARK: - UI Test File Discovery

    private func findUITestFiles(in directory: String) -> [String] {
        let skipDirs: Set<String> = [
            ".build", "Build", "DerivedData", "Pods", ".swiftpm",
            "Carthage", "Packages", "SourcePackages", "node_modules", ".git",
        ]
        let fm = FileManager.default
        var files: [String] = []
        guard let enumerator = fm.enumerator(atPath: directory) else { return [] }

        while let path = enumerator.nextObject() as? String {
            let components = path.split(separator: "/")
            if components.contains(where: { skipDirs.contains(String($0)) }) { continue }
            guard path.contains("UITests/") || path.contains("UITest/") else { continue }
            guard path.hasSuffix(".swift") else { continue }
            files.append((directory as NSString).appendingPathComponent(path))
        }
        return files
    }

    // MARK: - Accessibility Identifier Cross-Reference

    /// Matches .accessibilityIdentifier("id") and .accessibilityIdentifier = "id" in app source.
    private static let definedIdentifierPattern = try! NSRegularExpression(
        pattern: #"\.accessibilityIdentifier\s*(?:\(\s*"([^"]+)"\s*\)|=\s*"([^"]+)")"#
    )

    private func extractDefinedIdentifiers(from contents: String, into set: inout Set<String>) {
        let nsContents = contents as NSString
        let range = NSRange(location: 0, length: nsContents.length)
        let matches = Self.definedIdentifierPattern.matches(in: contents, range: range)
        for match in matches {
            for group in 1...2 {
                let groupRange = match.range(at: group)
                if groupRange.location != NSNotFound {
                    set.insert(nsContents.substring(with: groupRange))
                }
            }
        }
    }

    /// waitForElement(id: "identifier") - always an identifier lookup.
    private static let waitForElementPattern = try! NSRegularExpression(
        pattern: #"waitForElement\s*\(\s*id:\s*"([^"]+)""#
    )

    /// app.TYPE["camelCaseId"] - subscript starting lowercase with ≥1 uppercase (camelCase).
    /// Excludes label-like strings ("Save", "OK", "My Screen") which rarely start lowercase.
    private static let elementSubscriptPattern = try! NSRegularExpression(
        pattern: #"app\.\w+\s*\[\s*"([a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*)"\s*\]"#
    )

    private func checkMissingAccessibilityIdentifiers(
        testFiles: [String],
        definedIdentifiers: Set<String>
    ) -> [Finding] {
        var findings: [Finding] = []

        for file in testFiles {
            guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let lines = contents.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }

                let lineNumber = index + 1
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                var referencedIds: [String] = []

                // waitForElement(id: "identifier")
                for match in Self.waitForElementPattern.matches(in: line, range: range) {
                    let r = match.range(at: 1)
                    if r.location != NSNotFound { referencedIds.append(nsLine.substring(with: r)) }
                }

                // app.TYPE["camelCaseIdentifier"]
                for match in Self.elementSubscriptPattern.matches(in: line, range: range) {
                    let r = match.range(at: 1)
                    if r.location != NSNotFound { referencedIds.append(nsLine.substring(with: r)) }
                }

                for id in referencedIds where !definedIdentifiers.contains(id) {
                    findings.append(Finding(
                        severity: .warning,
                        rule: "missing-accessibility-identifier",
                        message: "UI test references '\(id)' but no .accessibilityIdentifier(\"\(id)\") found in app source - add it to the view or the element lookup will fail",
                        filePath: file,
                        lineNumber: lineNumber,
                        lineContent: trimmed
                    ))
                }
            }
        }
        return findings
    }

    // MARK: - Test File Pattern Checks

    /// Matches navigationBars.buttons["LocalizedLabel"] - localized labels break in non-English locales.
    /// Excludes camelCase identifiers (which are locale-agnostic accessibility identifiers).
    private static let localizedNavButtonPattern = try! NSRegularExpression(
        pattern: #"navigationBars\.buttons\s*\[\s*"([A-Z][^"]+)"\s*\]"#
    )

    /// Checks UI test files for patterns that commonly cause screenshot capture failures.
    private func checkTestFilePatterns(testFiles: [String], deviceContext: DeviceContext) -> [Finding] {
        var findings: [Finding] = []

        for file in testFiles {
            guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { continue }

            // Rule: localized-nav-button (only relevant when multiple locales are configured)
            // navigationBars.buttons["Back"] matches by localized label, which changes per locale
            // (e.g. "Atrás" in Spanish). Use element(boundBy: 0) or an accessibility identifier instead.
            if deviceContext.hasMultipleLocales {
                let navLines = contents.components(separatedBy: .newlines)
                for (index, line) in navLines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                    let nsLine = line as NSString
                    let range = NSRange(location: 0, length: nsLine.length)
                    if let match = Self.localizedNavButtonPattern.firstMatch(in: line, range: range) {
                        let label = nsLine.substring(with: match.range(at: 1))
                        findings.append(Finding(
                            severity: .warning,
                            rule: "localized-nav-button",
                            message: "navigationBars.buttons[\"\(label)\"] matches by localized title - breaks in non-English locales. Use element(boundBy: 0) for the system back button, or add an .accessibilityIdentifier to a custom button and query by that.",
                            filePath: file,
                            lineNumber: index + 1,
                            lineContent: trimmed
                        ))
                    }
                }
            }

            // Rule: simulator-clone-device-name
            // xcodebuild clones simulators for parallel test runs, producing names like
            // "Clone 1 of iPhone 17 Pro Max". If the test uses SIMULATOR_DEVICE_NAME raw
            // (without stripping the prefix), screenshots land in the wrong cache directory
            // and storescreens-cli finds 0 screenshots.
            if contents.contains("SIMULATOR_DEVICE_NAME") && !contents.contains("Clone") {
                let lines = contents.components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                    if line.contains("SIMULATOR_DEVICE_NAME") {
                        findings.append(Finding(
                            severity: .warning,
                            rule: "simulator-clone-device-name",
                            message: "SIMULATOR_DEVICE_NAME is used without stripping the \"Clone N of \" prefix - xcodebuild renames simulators during parallel runs, so screenshots will be written to the wrong directory. Add: if let r = deviceName.range(of: #\"^Clone \\d+ of \"#, options: .regularExpression) { deviceName = String(deviceName[r.upperBound...]) }",
                            filePath: file,
                            lineNumber: index + 1,
                            lineContent: trimmed
                        ))
                    }
                }
            }
        }

        return findings
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

            // Warning: Unguarded server sync / data fetch that could interfere with screenshot mode
            if matchesServerSync(line) && !hasUITestingGuard(lines: lines, at: index) {
                findings.append(Finding(
                    severity: .warning,
                    rule: "unguarded-server-sync",
                    message: "Server sync/fetch call without --uitesting guard - may re-download data during screenshot tests. Guard with: if !ProcessInfo.processInfo.arguments.contains(\"--uitesting\")",
                    filePath: filePath,
                    lineNumber: lineNumber,
                    lineContent: trimmed
                ))
            }

            // Warning: Hardcoded iPhone screen dimensions in layout context
            if let dimensionFinding = checkHardcodedDimensions(line: line, trimmed: trimmed, filePath: filePath, lineNumber: lineNumber) {
                findings.append(dimensionFinding)
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

    // MARK: - Server Sync

    /// Matches common server sync / data fetch patterns that could interfere with screenshot mode
    private static let serverSyncPattern = try! NSRegularExpression(
        pattern: #"(?:syncWith|refreshAppData|initializeApp|redownload|fetchFrom(?:Server|API|Backend)|pullFromRemote|loadRemote|downloadPermits|syncPermits|syncData)"#,
        options: .caseInsensitive
    )

    private func matchesServerSync(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Skip import, comments, declarations (func/var/let definitions)
        if trimmed.hasPrefix("import ") { return false }
        if trimmed.hasPrefix("func ") || trimmed.hasPrefix("private func ") || trimmed.hasPrefix("internal func ") { return false }

        let range = NSRange(location: 0, length: (line as NSString).length)
        return Self.serverSyncPattern.firstMatch(in: line, range: range) != nil
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
