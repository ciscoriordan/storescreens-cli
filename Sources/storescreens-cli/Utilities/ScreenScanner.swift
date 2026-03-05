import Foundation

/// Scans Swift source files to discover app screens from navigation patterns.
struct ScreenScanner {

    struct DiscoveredScreen: Hashable {
        let name: String
        let source: ScreenSource
    }

    enum ScreenSource: String, Hashable {
        case tab = "TabView"
        case navigationLink = "NavigationLink"
        case sheet = "sheet"
        case fullScreenCover = "fullScreenCover"
        case navigatorRoute = "Navigator route"
        case viewStruct = "View struct"
    }

    /// Scan Swift files under `directory`, skipping test/build/dependency directories.
    func scan(directory: String) -> [DiscoveredScreen] {
        let fm = FileManager.default
        let swiftFiles = findSwiftFiles(in: directory, fileManager: fm)

        var screens: [DiscoveredScreen] = []
        for file in swiftFiles {
            guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            screens.append(contentsOf: scanFile(contents))
        }

        // Deduplicate, preserving first occurrence order
        var seen = Set<String>()
        return screens.filter { seen.insert($0.name).inserted }
    }

    // MARK: - File Discovery

    private func findSwiftFiles(in directory: String, fileManager fm: FileManager) -> [String] {
        let skipDirs: Set<String> = [
            ".build", "Build", "DerivedData", "Pods", ".swiftpm",
            "Carthage", "Packages", "SourcePackages", "node_modules",
            ".git"
        ]

        var files: [String] = []
        guard let enumerator = fm.enumerator(atPath: directory) else { return [] }

        while let path = enumerator.nextObject() as? String {
            let components = path.split(separator: "/")

            // Skip dependency/build directories
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

    // MARK: - Pattern Matching

    private func scanFile(_ source: String) -> [DiscoveredScreen] {
        var screens: [DiscoveredScreen] = []
        screens.append(contentsOf: findTabs(in: source))
        screens.append(contentsOf: findNavigationLinks(in: source))
        screens.append(contentsOf: findSheets(in: source))
        screens.append(contentsOf: findNavigatorRoutes(in: source))
        screens.append(contentsOf: findViewStructs(in: source))
        return screens
    }

    /// Tab("Title", ...) or .tabItem { Label("Title", ...) } or .tabItem { Text("Title") }
    private func findTabs(in source: String) -> [DiscoveredScreen] {
        var results: [DiscoveredScreen] = []

        // Tab("Title", ...)  — SwiftUI 5+ Tab syntax
        for match in matches(for: #"Tab\(\s*"([^"]+)""#, in: source) {
            results.append(DiscoveredScreen(name: match, source: .tab))
        }

        // .tabItem { Label("Title", ...) }
        for match in matches(for: #"\.tabItem\s*\{[^}]*Label\(\s*"([^"]+)""#, in: source) {
            results.append(DiscoveredScreen(name: match, source: .tab))
        }

        // .tabItem { Text("Title") }
        for match in matches(for: #"\.tabItem\s*\{[^}]*Text\(\s*"([^"]+)""#, in: source) {
            results.append(DiscoveredScreen(name: match, source: .tab))
        }

        return results
    }

    /// NavigationLink("Title", ...) or NavigationLink { } label: { Text("Title") }
    private func findNavigationLinks(in source: String) -> [DiscoveredScreen] {
        var results: [DiscoveredScreen] = []

        // NavigationLink("Title", ...)
        for match in matches(for: #"NavigationLink\(\s*"([^"]+)""#, in: source) {
            results.append(DiscoveredScreen(name: match, source: .navigationLink))
        }

        // NavigationLink { ... } label: { ... Text("Title") ... }
        for match in matches(for: #"NavigationLink\s*\{[^}]*\}\s*label:\s*\{[^}]*Text\(\s*"([^"]+)""#, in: source) {
            results.append(DiscoveredScreen(name: match, source: .navigationLink))
        }

        return results
    }

    /// .sheet { SomeView() } or .fullScreenCover { SomeView() }
    /// Extracts the View name from the closure.
    private func findSheets(in source: String) -> [DiscoveredScreen] {
        var results: [DiscoveredScreen] = []

        // .sheet(... { SomeView( or .sheet(... { SomeView(
        for match in matches(for: #"\.(sheet|fullScreenCover)\([^)]*\)\s*\{[^}]*?(\b[A-Z]\w*View)\b"#, in: source, group: 2) {
            let name = humanize(viewName: match)
            let sourceType: ScreenSource = source.contains(".fullScreenCover") ? .fullScreenCover : .sheet
            results.append(DiscoveredScreen(name: name, source: sourceType))
        }

        return results
    }

    /// Navigator route enum cases: case home, case settings, case profile
    /// Looks for enums used with Navigator/NavigatorView patterns.
    private func findNavigatorRoutes(in source: String) -> [DiscoveredScreen] {
        var results: [DiscoveredScreen] = []

        // Check if this file uses Navigator
        guard source.contains("Navigator") || source.contains("NavigatorView") else {
            return results
        }

        // Find enum cases that look like routes
        // Match: case someName (possibly with associated values)
        let enumBlockPattern = #"enum\s+\w+[^{]*\{([^}]*)\}"#
        guard let enumRegex = try? NSRegularExpression(pattern: enumBlockPattern, options: [.dotMatchesLineSeparators]) else {
            return results
        }

        let nsSource = source as NSString
        let enumMatches = enumRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        for enumMatch in enumMatches {
            let body = nsSource.substring(with: enumMatch.range(at: 1))
            for caseMatch in matches(for: #"case\s+([a-z]\w*)"#, in: body) {
                let name = caseMatch.prefix(1).uppercased() + caseMatch.dropFirst()
                results.append(DiscoveredScreen(name: name, source: .navigatorRoute))
            }
        }

        return results
    }

    /// struct SomeView: View — fallback, finds all View-conforming structs.
    /// Filters out common non-screen patterns.
    private func findViewStructs(in source: String) -> [DiscoveredScreen] {
        var results: [DiscoveredScreen] = []

        for match in matches(for: #"struct\s+(\w+)\s*:\s*[^{]*\bView\b"#, in: source) {
            // Skip common non-screen views
            let lower = match.lowercased()
            let skipSuffixes = ["button", "cell", "row", "item", "header", "footer",
                                "modifier", "style", "shape", "preview", "wrapper",
                                "container", "overlay", "badge", "indicator", "icon",
                                "label", "tag", "chip", "divider", "separator"]
            if skipSuffixes.contains(where: { lower.hasSuffix($0) }) { continue }
            if lower.hasPrefix("preview") { continue }

            let name = humanize(viewName: match)
            results.append(DiscoveredScreen(name: name, source: .viewStruct))
        }

        return results
    }

    // MARK: - Helpers

    private func matches(for pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group else { return nil }
            let groupRange = match.range(at: group)
            guard groupRange.location != NSNotFound else { return nil }
            return nsText.substring(with: groupRange)
        }
    }

    /// "SettingsView" → "Settings", "SearchResultsView" → "Search Results"
    private func humanize(viewName: String) -> String {
        var name = viewName
        // Strip common suffixes
        for suffix in ["View", "Screen", "Page"] {
            if name.hasSuffix(suffix) && name.count > suffix.count {
                name = String(name.dropLast(suffix.count))
            }
        }
        // Split camelCase: "SearchResults" → "Search Results"
        var result = ""
        for char in name {
            if char.isUppercase && !result.isEmpty {
                result += " "
            }
            result.append(char)
        }
        return result
    }
}
