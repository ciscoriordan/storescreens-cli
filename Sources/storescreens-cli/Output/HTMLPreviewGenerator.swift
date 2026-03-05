import Foundation

struct HTMLPreviewGenerator {

    /// Generates per-device/appearance HTML preview pages and an index linking them all.
    /// Old preview pages from previous runs are preserved and labeled with their timestamp.
    func generate(manifest: CaptureManifest, outputDir: String) throws {
        let fm = FileManager.default

        // Snapshot existing preview_*.html files and their mod dates before we overwrite any
        var oldFiles: [String: Date] = [:] // filename -> modification date
        if let existing = try? fm.contentsOfDirectory(atPath: outputDir) {
            for file in existing where file.hasPrefix("preview_") && file.hasSuffix(".html") {
                let path = (outputDir as NSString).appendingPathComponent(file)
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let modDate = attrs[.modificationDate] as? Date {
                    oldFiles[file] = modDate
                }
            }
        }

        // Build unique (deviceType, appearance) pages, each showing all locales
        var pages: [PageKey: [CaptureManifest.DeviceCapture]] = [:]
        for device in manifest.devices {
            let key = PageKey(deviceType: device.deviceType, appearance: device.appearance)
            pages[key, default: []].append(device)
        }

        let sortedKeys = pages.keys.sorted {
            if $0.deviceType != $1.deviceType { return $0.deviceType < $1.deviceType }
            return ($0.appearance ?? "") < ($1.appearance ?? "")
        }

        // Write current-run pages
        var currentFilenames: Set<String> = []
        var currentPages: [IndexEntry] = []

        for key in sortedKeys {
            let captures = pages[key]!
            let filename = pageFilename(deviceType: key.deviceType, appearance: key.appearance)
            currentFilenames.insert(filename)
            let html = buildDevicePage(
                appName: manifest.appName,
                deviceType: key.deviceType,
                appearance: key.appearance,
                captures: captures,
                indexFilename: "preview.html"
            )
            let path = (outputDir as NSString).appendingPathComponent(filename)
            try html.write(toFile: path, atomically: true, encoding: .utf8)
            let count = captures.reduce(0) { $0 + $1.screenshots.count }
            // Find thumbnail from manifest
            let thumb = captures.first?.screenshots.first?.filename
            currentPages.append(IndexEntry(
                deviceType: key.deviceType,
                appearance: key.appearance,
                filename: filename,
                screenshotCount: count,
                thumbnail: thumb,
                olderRunDate: nil
            ))
        }

        // Collect old pages that weren't overwritten by this run
        var olderPages: [IndexEntry] = []
        for (filename, modDate) in oldFiles where !currentFilenames.contains(filename) {
            // Parse device type and appearance from filename
            if let parsed = parsePageFilename(filename) {
                olderPages.append(IndexEntry(
                    deviceType: parsed.deviceType,
                    appearance: parsed.appearance,
                    filename: filename,
                    screenshotCount: nil,
                    thumbnail: nil,
                    olderRunDate: modDate
                ))
            }
        }
        olderPages.sort {
            if $0.deviceType != $1.deviceType { return $0.deviceType < $1.deviceType }
            return ($0.appearance ?? "") < ($1.appearance ?? "")
        }

        // Generate index with both current and older entries
        let allEntries = currentPages + olderPages
        let indexHTML = buildIndex(manifest: manifest, entries: allEntries)
        let indexPath = (outputDir as NSString).appendingPathComponent("preview.html")
        try indexHTML.write(toFile: indexPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Types

    private struct PageKey: Hashable {
        let deviceType: String
        let appearance: String?
    }

    private struct IndexEntry {
        let deviceType: String
        let appearance: String?
        let filename: String
        let screenshotCount: Int?    // nil for older runs (we don't re-parse the HTML)
        let thumbnail: String?       // nil for older runs
        let olderRunDate: Date?      // non-nil means this is from a previous run
    }

    // MARK: - Per-Device Page

    private func buildDevicePage(
        appName: String,
        deviceType: String,
        appearance: String?,
        captures: [CaptureManifest.DeviceCapture],
        indexFilename: String
    ) -> String {
        var title = deviceType
        if let appearance { title += " — \(appearance)" }

        // Group by locale
        var localeGroups: [(locale: String?, captures: [CaptureManifest.DeviceCapture])] = []
        var seen: [String: Int] = [:]
        for capture in captures {
            let key = capture.locale ?? ""
            if let idx = seen[key] {
                localeGroups[idx].captures.append(capture)
            } else {
                seen[key] = localeGroups.count
                localeGroups.append((locale: capture.locale, captures: [capture]))
            }
        }

        let totalScreenshots = captures.reduce(0) { $0 + $1.screenshots.count }

        var body = ""
        for group in localeGroups {
            if let locale = group.locale {
                let flag = "<img class=\"locale-flag\" src=\"\(flagURL(for: locale))\" alt=\"\" onerror=\"this.style.display='none'\">"
                body += "      <h2 class=\"section\">\(flag)\(escapeHTML(locale))</h2>\n"
            }
            for capture in group.captures {
                body += "        <div class=\"screenshots\">\n"
                for screenshot in capture.screenshots {
                    body += "          <figure>\n"
                    body += "            <a href=\"\(escapeHTML(screenshot.filename))\" target=\"_blank\">"
                    body += "<img src=\"\(escapeHTML(screenshot.filename))\" loading=\"lazy\" alt=\"\(escapeHTML(screenshot.name))\">"
                    body += "</a>\n"
                    body += "            <figcaption>\(escapeHTML(screenshot.name))</figcaption>\n"
                    body += "          </figure>\n"
                }
                body += "        </div>\n"
            }
        }

        let isDark = appearance == "dark"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(title)) — \(escapeHTML(appName))</title>
          \(styleTag(darkBackground: isDark))
        </head>
        <body>
          <header>
            <div>
              <a class="back" href="\(escapeHTML(indexFilename))">&larr; All Devices</a>
              <h1>\(escapeHTML(title))</h1>
            </div>
            <span class="meta">\(totalScreenshots) screenshots</span>
          </header>
        \(body)
          <footer>Flag icons by <a href="https://github.com/ciscoriordan/svg-flags">svg-flags</a></footer>
        </body>
        </html>
        """
    }

    // MARK: - Index Page

    private func buildIndex(manifest: CaptureManifest, entries: [IndexEntry]) -> String {
        let currentEntries = entries.filter { $0.olderRunDate == nil }
        let olderEntries = entries.filter { $0.olderRunDate != nil }
        let totalScreenshots = manifest.devices.reduce(0) { $0 + $1.screenshots.count }
        let dateString = formatDate(manifest.generatedAt)

        var body = ""

        // Current run cards
        body += buildCardGrid(entries: currentEntries)

        // Older run section
        if !olderEntries.isEmpty {
            body += "      <h2 class=\"older-heading\">From older runs</h2>\n"
            body += buildCardGrid(entries: olderEntries)
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(manifest.appName)) — Screenshot Preview</title>
          <style>
            *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
              background: #0a0a0a; color: #e5e5e5;
              padding: 2rem; min-height: 100vh;
            }
            header {
              max-width: 1000px; margin: 0 auto 2.5rem;
              display: flex; align-items: baseline; justify-content: space-between; flex-wrap: wrap; gap: 0.5rem;
            }
            header h1 { font-size: 1.5rem; font-weight: 600; color: #fff; }
            header .meta { font-size: 0.8rem; color: #888; }
            .grid {
              max-width: 1000px; margin: 0 auto;
              display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 1.25rem;
            }
            .card {
              display: flex; flex-direction: column;
              background: #141414; border: 1px solid #222; border-radius: 10px;
              overflow: hidden; text-decoration: none; color: inherit;
              transition: border-color 0.15s ease, transform 0.15s ease;
            }
            .card:hover { border-color: #444; transform: translateY(-2px); }
            .card img {
              width: 100%; height: 280px; object-fit: cover; object-position: top;
              background: #111;
            }
            .placeholder {
              width: 100%; height: 280px; background: #111;
            }
            .card-label { padding: 0.75rem 1rem; }
            .card-device { display: block; font-size: 0.7rem; color: #666; margin-bottom: 0.15rem; }
            .card-title { display: block; font-size: 0.9rem; font-weight: 600; color: #ccc; }
            .card-count { display: block; font-size: 0.7rem; color: #666; margin-top: 0.2rem; }
            .card-stale {
              display: inline-block; font-size: 0.65rem; color: #997a00;
              background: rgba(153, 122, 0, 0.15); padding: 0.15rem 0.4rem;
              border-radius: 3px; margin-top: 0.3rem;
            }
            .card.stale { opacity: 0.6; }
            .card.stale:hover { opacity: 0.85; }
            .older-heading {
              max-width: 1000px; margin: 3rem auto 1.25rem;
              font-size: 0.8rem; font-weight: 500; color: #666;
              text-transform: uppercase; letter-spacing: 0.08em;
              border-top: 1px solid #1a1a1a; padding-top: 1.5rem;
            }
            footer {
              max-width: 1000px; margin: 3rem auto 0; padding-top: 1.5rem;
              border-top: 1px solid #1a1a1a;
              font-size: 0.7rem; color: #555; text-align: center;
            }
            footer a { color: #888; text-decoration: none; }
            footer a:hover { color: #ccc; }
          </style>
        </head>
        <body>
          <header>
            <h1>\(escapeHTML(manifest.appName))</h1>
            <span class="meta">\(totalScreenshots) screenshots · \(escapeHTML(dateString))</span>
          </header>
        \(body)
          <footer>Flag icons by <a href="https://github.com/ciscoriordan/svg-flags">svg-flags</a></footer>
        </body>
        </html>
        """
    }

    private func buildCardGrid(entries: [IndexEntry]) -> String {
        var body = "      <div class=\"grid\">\n"
        for entry in entries {
            let label = entry.appearance ?? entry.deviceType
            let sublabel = entry.appearance != nil ? entry.deviceType : ""
            let staleClass = entry.olderRunDate != nil ? " stale" : ""

            body += "        <a class=\"card\(staleClass)\" href=\"\(escapeHTML(entry.filename))\">\n"
            if let thumb = entry.thumbnail {
                body += "          <img src=\"\(escapeHTML(thumb))\" loading=\"lazy\" alt=\"\">\n"
            } else {
                body += "          <div class=\"placeholder\"></div>\n"
            }
            body += "          <div class=\"card-label\">\n"
            if !sublabel.isEmpty {
                body += "            <span class=\"card-device\">\(escapeHTML(sublabel))</span>\n"
            }
            body += "            <span class=\"card-title\">\(escapeHTML(label))</span>\n"
            if let count = entry.screenshotCount {
                body += "            <span class=\"card-count\">\(count) screenshots</span>\n"
            }
            if let date = entry.olderRunDate {
                body += "            <span class=\"card-stale\">from \(escapeHTML(formatDate(date)))</span>\n"
            }
            body += "          </div>\n"
            body += "        </a>\n"
        }
        body += "      </div>\n"
        return body
    }

    // MARK: - Shared

    private func styleTag(darkBackground: Bool) -> String {
        let bg = darkBackground ? "#000" : "#0a0a0a"
        return """
        <style>
            *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
              background: \(bg); color: #e5e5e5;
              padding: 2rem; min-height: 100vh;
            }
            header {
              max-width: 1400px; margin: 0 auto 2rem;
            }
            header > div { display: flex; align-items: baseline; gap: 1rem; flex-wrap: wrap; }
            header h1 { font-size: 1.5rem; font-weight: 600; color: #fff; }
            header .meta { font-size: 0.8rem; color: #888; margin-top: 0.25rem; }
            .back {
              font-size: 0.8rem; color: #888; text-decoration: none;
              transition: color 0.15s;
            }
            .back:hover { color: #ccc; }
            .section {
              max-width: 1400px; margin: 2.5rem auto 1rem;
              font-size: 0.85rem; font-weight: 500; color: #aaa;
              text-transform: uppercase; letter-spacing: 0.08em;
              border-bottom: 1px solid #222; padding-bottom: 0.4rem;
              display: flex; align-items: center; gap: 0.5em;
            }
            .locale-flag { width: 1.2em; height: 1.2em; border-radius: 50%; flex-shrink: 0; }
            .screenshots {
              max-width: 1400px; margin: 1rem auto;
              display: flex; flex-wrap: wrap; gap: 1rem;
            }
            figure {
              display: flex; flex-direction: column; align-items: center;
            }
            figure a { display: block; }
            figure img {
              height: 420px; width: auto; border-radius: 8px;
              border: 1px solid #222; background: #111;
              transition: transform 0.15s ease;
            }
            figure img:hover { transform: scale(1.02); }
            figcaption {
              margin-top: 0.4rem; font-size: 0.75rem; color: #888;
              max-width: 200px; text-align: center;
              overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
            }
            footer {
              max-width: 1400px; margin: 3rem auto 0; padding-top: 1.5rem;
              border-top: 1px solid #222;
              font-size: 0.7rem; color: #555; text-align: center;
            }
            footer a { color: #888; text-decoration: none; }
            footer a:hover { color: #ccc; }
          </style>
        """
    }

    private func pageFilename(deviceType: String, appearance: String?) -> String {
        var name = deviceType
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: " ", with: "_")
        if let appearance {
            name += "_\(appearance)"
        }
        return "preview_\(name).html"
    }

    /// Reverse of pageFilename — extract device type and appearance from a preview filename.
    private func parsePageFilename(_ filename: String) -> (deviceType: String, appearance: String?)? {
        // Format: preview_{DeviceType}[_{appearance}].html
        guard filename.hasPrefix("preview_") && filename.hasSuffix(".html") else { return nil }
        let stem = String(filename.dropFirst("preview_".count).dropLast(".html".count))

        // Known appearances to check for as a suffix
        let appearances = ["light", "dark"]
        for app in appearances {
            let suffix = "_\(app)"
            if stem.hasSuffix(suffix) {
                let devicePart = String(stem.dropLast(suffix.count))
                    .replacingOccurrences(of: "_", with: " ")
                return (devicePart, app)
            }
        }

        // No appearance suffix
        let devicePart = stem.replacingOccurrences(of: "_", with: " ")
        return (devicePart, nil)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Returns an svg-flags CDN URL for the given Xcode locale code.
    /// Falls back gracefully via onerror in HTML if the image can't be loaded.
    private func flagURL(for locale: String) -> String {
        // Map Xcode locale codes to svg-flags language codes.
        let overrides: [String: String] = [
            "en-GB":   "en",
            "es-419":  "es-mx",
            "fr-CA":   "fr-ca-qc",
            "pt-PT":   "pt",
            "zh-Hans": "zh",
            "zh-Hant": "zh",
            "zh-HK":   "zh",
        ]
        let base = "https://raw.githubusercontent.com/ciscoriordan/svg-flags/main/circle/languages"
        let code = overrides[locale] ?? locale.lowercased()
        return "\(base)/\(code).svg"
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
