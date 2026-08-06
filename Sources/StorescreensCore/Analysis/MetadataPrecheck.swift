import Foundation

/// Scans a `metadata/<locale>/*.txt` tree for the things App Review
/// rejects metadata over, before the upload rather than after.
///
/// This is the client-side counterpart to `PreflightScanner` (which reads
/// Swift source for iPad-unsafe patterns). Nothing here talks to App Store
/// Connect: every rule is text analysis over the same files
/// `storescreens submit` reads, so it runs offline and costs nothing.
/// The one exception is URL reachability, which is a separate opt-in pass
/// (`checkURLs`) because it makes requests to third-party hosts.
///
/// Rules map to the App Review Guidelines they protect against:
///
///   - `other-platform` - 2.3.10, don't mention Android/Google Play etc.
///   - `placeholder-text` - 2.3.8, no lorem ipsum or TODO markers shipped
///   - `future-functionality` - 2.1, don't advertise what isn't in the build
///   - `test-word` - 2.2, no "beta"/"trial" framing on the App Store
///   - `profanity` - 1.1.1, objectionable content
///   - `apple-sentiment` - 3.2.2, don't disparage Apple in your listing
///   - `field-length` - hard ASC limits; a 4001-char description is a 422
///   - `url-format` / `url-unreachable` - 2.3.11, links must work
///   - `empty-file` - storescreens-specific: an empty file blanks the
///     live field rather than leaving it alone
package struct MetadataPrecheck {

    package init() {}

    package enum Severity: String, Sendable {
        case error
        case warning
    }

    package struct Finding: Sendable {
        package let severity: Severity
        /// Stable kebab-case rule id, e.g. "other-platform".
        package let rule: String
        package let message: String
        /// Locale directory the file came from, e.g. "en-US".
        package let locale: String
        /// Filename within the locale directory, e.g. "description.txt".
        package let file: String
        /// 1-indexed line the match landed on. Nil for whole-file rules
        /// (length limits, empty files).
        package let line: Int?
        /// The matched text, for rules where seeing it is the whole point.
        package let excerpt: String?

        package init(
            severity: Severity,
            rule: String,
            message: String,
            locale: String,
            file: String,
            line: Int? = nil,
            excerpt: String? = nil
        ) {
            self.severity = severity
            self.rule = rule
            self.message = message
            self.locale = locale
            self.file = file
            self.line = line
            self.excerpt = excerpt
        }
    }

    package struct Result: Sendable {
        package let findings: [Finding]
        package var errors: [Finding] { findings.filter { $0.severity == .error } }
        package var warnings: [Finding] { findings.filter { $0.severity == .warning } }
        package var hasErrors: Bool { !errors.isEmpty }
        /// Number of `<locale>/` directories that had at least one readable
        /// metadata file. Zero means the scan found nothing to check.
        package let localesScanned: Int

        package init(findings: [Finding], localesScanned: Int = 0) {
            self.findings = findings
            self.localesScanned = localesScanned
        }
    }

    // MARK: - Rule tables

    /// Files whose contents are prose shown to customers or reviewers.
    /// URL files and the review contact fields are excluded: a phone
    /// number can't contain profanity worth flagging, and a support URL
    /// legitimately contains substrings the prose rules would trip on.
    static let proseFiles: Set<String> = [
        "name.txt", "subtitle.txt", "description.txt", "keywords.txt",
        "promotional_text.txt", "release_notes.txt", "review_notes.txt",
    ]

    /// Files holding a single URL, checked for scheme + reachability.
    static let urlFiles: Set<String> = [
        "support_url.txt", "marketing_url.txt", "privacy_url.txt",
        "privacy_choices_url.txt",
    ]

    /// Apple's hard character limits per field. Over these, the PATCH is
    /// a 422 rather than a review rejection.
    static let lengthLimits: [String: Int] = [
        "name.txt": 30,
        "subtitle.txt": 30,
        "keywords.txt": 100,
        "promotional_text.txt": 170,
        "description.txt": 4000,
        "release_notes.txt": 4000,
    ]

    /// (pattern, human label) pairs. Patterns are matched case-insensitively
    /// with word boundaries so "Android" hits but "meander" doesn't.
    static let otherPlatforms: [(String, String)] = [
        ("android", "Android"),
        ("google play", "Google Play"),
        ("play store", "the Play Store"),
        ("blackberry", "BlackBerry"),
        ("windows phone", "Windows Phone"),
        ("windows store", "the Windows Store"),
        ("amazon appstore", "the Amazon Appstore"),
        ("kindle fire", "Kindle Fire"),
    ]

    static let placeholders: [String] = [
        "lorem ipsum", "todo", "fixme", "tbd",
        "insert text here", "your app name here", "placeholder",
    ]

    static let futureFunctionality: [String] = [
        "coming soon", "in a future update", "in a future release",
        "will be added", "not yet implemented", "in the next version",
        "under construction", "stay tuned",
    ]

    static let testWords: [String] = [
        "beta", "trial version", "test version", "demo version",
        "sample app", "pre-release", "prerelease",
    ]

    /// Deliberately small and unambiguous. A precheck that cries wolf gets
    /// muted, and Apple's own bar here is about obviously objectionable
    /// content rather than mild language. Words with a common innocent
    /// reading are left out on purpose - "dick" is a name, and flagging an
    /// author credit as profanity is worse than missing it.
    static let profanity: [String] = [
        "fuck", "shit", "bitch", "asshole", "bastard", "cunt",
        "piss", "whore", "slut",
    ]

    static let appleSentiment: [String] = [
        "apple sucks", "apple is terrible", "apple rejected",
        "blame apple", "stupid apple", "apple's fault",
    ]

    // MARK: - Offline scan

    /// Reads every `<locale>/` subdirectory under `dir` and applies every
    /// offline rule. Unreadable files and unknown filenames are skipped
    /// silently - `MetadataReader` already warns about those during submit,
    /// and duplicating the warning here just doubles the noise.
    package func scan(dir: URL) -> Result {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return Result(findings: [])
        }

        var findings: [Finding] = []
        var locales = 0

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            let locale = child.lastPathComponent
            let files = ((try? fm.contentsOfDirectory(atPath: child.path)) ?? []).sorted()
            var sawFile = false

            for file in files where file.hasSuffix(".txt") {
                guard Self.proseFiles.contains(file) || Self.urlFiles.contains(file) else { continue }
                guard let raw = try? String(contentsOf: child.appendingPathComponent(file), encoding: .utf8) else {
                    continue
                }
                sawFile = true
                findings.append(contentsOf: check(file: file, locale: locale, raw: raw))
            }
            if sawFile { locales += 1 }
        }

        return Result(findings: findings, localesScanned: locales)
    }

    private func check(file: String, locale: String, raw: String) -> [Finding] {
        var findings: [Finding] = []
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty file: submit sends "" and blanks the live field.
        if text.isEmpty {
            return [Finding(
                severity: .warning,
                rule: "empty-file",
                message: "file is empty, which overwrites the live App Store value with an empty string. Delete the file to leave the field untouched.",
                locale: locale,
                file: file
            )]
        }

        if let limit = Self.lengthLimits[file], text.count > limit {
            findings.append(Finding(
                severity: .error,
                rule: "field-length",
                message: "\(text.count) characters, over Apple's \(limit)-character limit for this field",
                locale: locale,
                file: file
            ))
        }

        if Self.urlFiles.contains(file) {
            findings.append(contentsOf: checkURLFormat(file: file, locale: locale, text: text))
            return findings
        }

        let lines = text.components(separatedBy: .newlines)

        findings.append(contentsOf: matchAll(
            Self.otherPlatforms.map(\.0), in: lines, file: file, locale: locale,
            severity: .error, rule: "other-platform"
        ) { matched in
            let label = Self.otherPlatforms.first { $0.0 == matched }?.1 ?? matched
            return "mentions \(label). App Review rejects listings that reference other platforms (guideline 2.3.10)."
        })

        findings.append(contentsOf: matchAll(
            Self.placeholders, in: lines, file: file, locale: locale,
            severity: .error, rule: "placeholder-text"
        ) { "contains placeholder text \"\($0)\"" })

        findings.append(contentsOf: matchAll(
            Self.profanity, in: lines, file: file, locale: locale,
            severity: .error, rule: "profanity"
        ) { _ in "contains profanity, which App Review flags under guideline 1.1.1" })

        findings.append(contentsOf: matchAll(
            Self.futureFunctionality, in: lines, file: file, locale: locale,
            severity: .warning, rule: "future-functionality"
        ) { "promises unreleased functionality (\"\($0)\"). Guideline 2.1 covers describing features the build doesn't ship." })

        findings.append(contentsOf: matchAll(
            Self.testWords, in: lines, file: file, locale: locale,
            severity: .warning, rule: "test-word"
        ) { "reads as pre-release (\"\($0)\"). App Store listings can't present the app as a beta or trial." })

        findings.append(contentsOf: matchAll(
            Self.appleSentiment, in: lines, file: file, locale: locale,
            severity: .warning, rule: "apple-sentiment"
        ) { _ in "disparages Apple, which guideline 3.2.2 prohibits in metadata" })

        if file == "keywords.txt" {
            findings.append(contentsOf: checkKeywords(locale: locale, text: text))
        }

        return findings
    }

    /// Word-boundary, case-insensitive search for each needle across every
    /// line. Returns at most one finding per (needle, file) so a phrase
    /// repeated ten times in a description doesn't produce ten lines.
    private func matchAll(
        _ needles: [String],
        in lines: [String],
        file: String,
        locale: String,
        severity: Severity,
        rule: String,
        message: (String) -> String
    ) -> [Finding] {
        var findings: [Finding] = []
        for needle in needles {
            guard let hit = firstMatch(of: needle, in: lines) else { continue }
            findings.append(Finding(
                severity: severity,
                rule: rule,
                message: message(needle),
                locale: locale,
                file: file,
                line: hit.line,
                excerpt: hit.excerpt
            ))
        }
        return findings
    }

    private func firstMatch(of needle: String, in lines: [String]) -> (line: Int, excerpt: String)? {
        // Latin-letter lookarounds rather than `\b`. Every needle here is
        // Latin script, and `\b` needs a *non-word* character on each side,
        // which unspaced scripts never provide: "Androidにもあります" would
        // slip through in Japanese, where Apple rejects it just as readily
        // as in English. Requiring a non-Latin-alphanumeric neighbor keeps
        // "androgynous" from matching while letting "Androidに" match.
        let boundary = "[A-Za-z0-9]"
        let pattern = "(?<!\(boundary))"
            + NSRegularExpression.escapedPattern(for: needle)
            + "(?!\(boundary))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let matchRange = Range(match.range, in: line) else { continue }
            return (index + 1, excerpt(around: matchRange, in: line))
        }
        return nil
    }

    /// A short window of surrounding text so the operator can see the match
    /// in context without printing a 4000-character description back.
    private func excerpt(around range: Range<String.Index>, in line: String) -> String {
        let padding = 24
        let start = line.index(range.lowerBound, offsetBy: -padding, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(range.upperBound, offsetBy: padding, limitedBy: line.endIndex) ?? line.endIndex
        var snippet = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > line.startIndex { snippet = "…" + snippet }
        if end < line.endIndex { snippet += "…" }
        return snippet
    }

    private func checkKeywords(locale: String, text: String) -> [Finding] {
        var findings: [Finding] = []
        let parts = text.components(separatedBy: ",")

        // Apple counts the whole string including separators against the
        // 100-char budget, so a space after each comma is pure waste.
        if parts.dropFirst().contains(where: { $0.hasPrefix(" ") }) {
            findings.append(Finding(
                severity: .warning,
                rule: "keyword-format",
                message: "has spaces after commas. Apple counts them against the 100-character budget; use \"a,b,c\" not \"a, b, c\".",
                locale: locale,
                file: "keywords.txt"
            ))
        }
        if parts.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            findings.append(Finding(
                severity: .warning,
                rule: "keyword-format",
                message: "has an empty keyword (double comma or a trailing comma)",
                locale: locale,
                file: "keywords.txt"
            ))
        }
        let normalized = parts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let duplicates = Set(normalized.filter { keyword in
            normalized.filter { $0 == keyword }.count > 1
        })
        if !duplicates.isEmpty {
            findings.append(Finding(
                severity: .warning,
                rule: "keyword-format",
                message: "repeats \(duplicates.sorted().map { "\"\($0)\"" }.joined(separator: ", ")). Duplicates spend the budget without adding reach.",
                locale: locale,
                file: "keywords.txt"
            ))
        }
        return findings
    }

    private func checkURLFormat(file: String, locale: String, text: String) -> [Finding] {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              components.host != nil
        else {
            return [Finding(
                severity: .error,
                rule: "url-format",
                message: "\"\(text)\" is not a valid absolute URL",
                locale: locale,
                file: file
            )]
        }
        guard scheme == "http" || scheme == "https" else {
            return [Finding(
                severity: .error,
                rule: "url-format",
                message: "uses the \(scheme):// scheme; App Store Connect requires http or https",
                locale: locale,
                file: file
            )]
        }
        if scheme == "http" {
            return [Finding(
                severity: .warning,
                rule: "url-format",
                message: "uses http://. Apple expects https:// for support and marketing links.",
                locale: locale,
                file: file
            )]
        }
        return []
    }

    // MARK: - Reachability (opt-in, makes network requests)

    /// Requests every URL found under `dir` and reports the ones that don't
    /// answer. Separate from `scan` because it reaches out to third-party
    /// hosts, which nothing else in the submit path does.
    ///
    /// Each unique URL is requested once even when several locales share
    /// it. HEAD first, then GET for the many servers that answer 405 or 403
    /// to a HEAD.
    package func checkURLs(
        dir: URL,
        timeout: TimeInterval = 10,
        session: URLSession = .shared
    ) async -> [Finding] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // url -> the (locale, file) sites that reference it, so one dead
        // link reported once still names every place it appears.
        var sites: [String: [(locale: String, file: String)]] = [:]
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            let locale = child.lastPathComponent
            for file in ((try? fm.contentsOfDirectory(atPath: child.path)) ?? []).sorted()
            where Self.urlFiles.contains(file) {
                guard let raw = try? String(contentsOf: child.appendingPathComponent(file), encoding: .utf8) else {
                    continue
                }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let scheme = URLComponents(string: text)?.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else { continue }  // format rule in `scan` already covers these
                sites[text, default: []].append((locale, file))
            }
        }

        var findings: [Finding] = []
        await withTaskGroup(of: (String, String?).self) { group in
            for url in sites.keys.sorted() {
                group.addTask {
                    (url, await Self.probe(url: url, timeout: timeout, session: session))
                }
            }
            for await (url, failure) in group {
                guard let failure else { continue }
                for site in sites[url] ?? [] {
                    findings.append(Finding(
                        severity: .error,
                        rule: "url-unreachable",
                        message: "\(url) \(failure)",
                        locale: site.locale,
                        file: site.file
                    ))
                }
            }
        }
        return findings.sorted {
            ($0.locale, $0.file) < ($1.locale, $1.file)
        }
    }

    /// Returns nil when the URL answers acceptably, or a human-readable
    /// failure clause otherwise.
    private static func probe(
        url: String,
        timeout: TimeInterval,
        session: URLSession
    ) async -> String? {
        guard let parsed = URL(string: url) else { return "is not a valid URL" }

        // Swift.Result spelled out: the nested `Result` type above wins
        // the bare name inside this type.
        func request(_ method: String) async -> Swift.Result<Int, Error> {
            var req = URLRequest(url: parsed, timeoutInterval: timeout)
            req.httpMethod = method
            // Some hosts 403 anything without a browser-shaped UA.
            req.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) storescreens-precheck",
                forHTTPHeaderField: "User-Agent"
            )
            do {
                let (_, response) = try await session.data(for: req)
                return .success((response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                return .failure(error)
            }
        }

        switch await request("HEAD") {
        case .success(let status) where (200..<400).contains(status):
            return nil
        case .success:
            // Fall through to GET: 4xx/5xx on HEAD is often a server that
            // simply doesn't implement the verb.
            break
        case .failure:
            break
        }

        switch await request("GET") {
        case .success(let status) where (200..<400).contains(status):
            return nil
        case .success(let status):
            return "returned HTTP \(status)"
        case .failure(let error):
            return "could not be reached: \((error as NSError).localizedDescription)"
        }
    }
}
