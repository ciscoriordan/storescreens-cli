import Foundation

package struct HTMLPreviewGenerator {
    private let localeFlags: [String: String]

    package init(localeFlags: [String: String]? = nil) {
        self.localeFlags = localeFlags ?? [:]
    }

    /// Generates per-device/appearance HTML preview pages and an index linking them all.
    ///
    /// When `framedDir` is non-nil, the per-device pages also show the
    /// rendered (captioned/framed) PNGs alongside the raw captures with a
    /// CSS-only radio toggle at the top of the page. `framedDir` is the
    /// path to the render output directory relative to `outputDir` (so
    /// relative `<img src>`s continue to work). Each screenshot's framed
    /// variant is looked up at `<outputDir>/<framedDir>/<screenshot.filename>`;
    /// screenshots whose framed file is missing silently fall back to
    /// raw-only. When no screenshot has a framed variant the toggle is
    /// omitted and the page reads identically to the raw-only case.
    ///
    /// When `keepOldPreviews` is true, preview pages from earlier runs
    /// (device/appearance combos not in the current manifest) are kept
    /// on the index under a "From older runs" heading with their
    /// original timestamp. Default false: stale `preview_*.html` files
    /// are deleted so the index reflects the latest run only.
    ///
    /// When `screenshotOrder` is non-nil, each device's screenshots are
    /// reordered in the gallery to match the list (same semantics as
    /// `RenderPipeline.render`'s `screenshotOrder`). Without this, the
    /// manifest-on-disk order (alphabetical by filename) wins and the
    /// gallery disagrees with the render's slide sequence - the user
    /// sees their hero slide in some other spot.
    package func generate(
        manifest: CaptureManifest,
        outputDir: String,
        framedDir: String? = nil,
        keepOldPreviews: Bool = false,
        screenshotOrder: [String]? = nil
    ) throws {
        let fm = FileManager.default

        // Snapshot existing preview_*.html files and their mod dates
        // before we overwrite any. Used either to enumerate old pages
        // for the "From older runs" section (keepOldPreviews = true) or
        // to identify files to delete (keepOldPreviews = false).
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
            // Apply the screenshots-list order here so the gallery's
            // slide sequence matches render's. RenderPipeline.applyOrder
            // is the single source of truth for both; the two places
            // where slide order matters (render loop + preview gallery)
            // run through the same helper so they can't drift.
            let captures = pages[key]!.map { dev -> CaptureManifest.DeviceCapture in
                let ordered = RenderPipeline.applyOrder(dev.screenshots, order: screenshotOrder)
                return CaptureManifest.DeviceCapture(
                    deviceType: dev.deviceType,
                    simulatorName: dev.simulatorName,
                    locale: dev.locale,
                    appearance: dev.appearance,
                    screenshots: ordered
                )
            }
            let filename = pageFilename(deviceType: key.deviceType, appearance: key.appearance)
            currentFilenames.insert(filename)
            let html = buildDevicePage(
                appName: manifest.appName,
                deviceType: key.deviceType,
                appearance: key.appearance,
                captures: captures,
                indexFilename: "preview.html",
                framedDir: framedDir,
                outputDirPath: outputDir
            )
            let path = (outputDir as NSString).appendingPathComponent(filename)
            try html.write(toFile: path, atomically: true, encoding: .utf8)
            let count = captures.reduce(0) { $0 + $1.screenshots.count }
            // Prefer the framed variant as the card thumbnail when
            // render has produced one on disk, so the index reflects
            // the final App Store look rather than the bare capture.
            // Falls back to the raw capture when no framed PNG exists
            // for the first slide (render hasn't run, or only ran for
            // some slides) - same graceful-degrade behaviour as the
            // per-device figures.
            let rawThumb = captures.first?.screenshots.first?.filename
            let thumb: String? = {
                guard let rawThumb, let framedDir else { return rawThumb }
                let full = (outputDir as NSString)
                    .appendingPathComponent(framedDir)
                let framedAbs = (full as NSString)
                    .appendingPathComponent(rawThumb)
                if FileManager.default.fileExists(atPath: framedAbs) {
                    return (framedDir as NSString).appendingPathComponent(rawThumb)
                }
                return rawThumb
            }()
            currentPages.append(IndexEntry(
                deviceType: key.deviceType,
                appearance: key.appearance,
                filename: filename,
                screenshotCount: count,
                thumbnail: thumb,
                olderRunDate: nil
            ))
        }

        // Handle old pages (files from previous runs that weren't
        // overwritten this time): keep them as stale cards, or delete
        // them outright so the index reflects only the current run.
        var olderPages: [IndexEntry] = []
        let staleFilenames = oldFiles.keys.filter { !currentFilenames.contains($0) }
        if keepOldPreviews {
            for filename in staleFilenames {
                guard let modDate = oldFiles[filename],
                      let parsed = parsePageFilename(filename) else { continue }
                olderPages.append(IndexEntry(
                    deviceType: parsed.deviceType,
                    appearance: parsed.appearance,
                    filename: filename,
                    screenshotCount: nil,
                    thumbnail: nil,
                    olderRunDate: modDate
                ))
            }
            olderPages.sort {
                if $0.deviceType != $1.deviceType { return $0.deviceType < $1.deviceType }
                return ($0.appearance ?? "") < ($1.appearance ?? "")
            }
        } else {
            // Default: wipe stale preview files. Non-fatal on error so
            // a permissions glitch on one file doesn't block the index
            // from being written.
            for filename in staleFilenames {
                let path = (outputDir as NSString).appendingPathComponent(filename)
                try? fm.removeItem(atPath: path)
            }
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
        indexFilename: String,
        framedDir: String?,
        outputDirPath: String
    ) -> String {
        var title = deviceType
        if let appearance { title += " - \(appearance)" }

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

        // Determine whether any screenshot on this page has a framed
        // variant on disk. When none do, the toggle is omitted entirely
        // so a capture-only flow reads identically to before.
        let fm = FileManager.default
        let anyFramed: Bool
        if let framedDir {
            anyFramed = captures.contains { capture in
                capture.screenshots.contains { shot in
                    let path = (outputDirPath as NSString)
                        .appendingPathComponent(framedDir)
                    let full = (path as NSString)
                        .appendingPathComponent(shot.filename)
                    return fm.fileExists(atPath: full)
                }
            }
        } else {
            anyFramed = false
        }

        var body = ""
        for group in localeGroups {
            if let locale = group.locale {
                let flag = "<img class=\"locale-flag\" src=\"\(flagURL(for: locale))\" alt=\"\" onerror=\"this.style.display='none'\">"
                body += "      <h2 class=\"section\">\(flag)\(escapeHTML(locale))</h2>\n"
            }
            for capture in group.captures {
                body += "        <div class=\"screenshots\">\n"
                for screenshot in capture.screenshots {
                    let rawSrc = escapeHTML(screenshot.filename)
                    // Framed variant path is `<framedDir>/<filename>`,
                    // checked against disk so missing variants fall back
                    // to raw-only figures without a broken <img>.
                    let framedSrc: String? = {
                        guard let framedDir, anyFramed else { return nil }
                        let path = (outputDirPath as NSString)
                            .appendingPathComponent(framedDir)
                        let full = (path as NSString)
                            .appendingPathComponent(screenshot.filename)
                        guard fm.fileExists(atPath: full) else { return nil }
                        return (framedDir as NSString)
                            .appendingPathComponent(screenshot.filename)
                    }()

                    body += "          <figure>\n"
                    if let framedSrc {
                        let framedEsc = escapeHTML(framedSrc)
                        body += "            <a class=\"variant-raw\" href=\"\(rawSrc)\" target=\"_blank\">"
                        body += "<img src=\"\(rawSrc)\" loading=\"lazy\" alt=\"\(escapeHTML(screenshot.name))\">"
                        body += "</a>\n"
                        body += "            <a class=\"variant-framed\" href=\"\(framedEsc)\" target=\"_blank\">"
                        body += "<img src=\"\(framedEsc)\" loading=\"lazy\" alt=\"\(escapeHTML(screenshot.name)) (framed)\">"
                        body += "</a>\n"
                    } else {
                        body += "            <a href=\"\(rawSrc)\" target=\"_blank\">"
                        body += "<img src=\"\(rawSrc)\" loading=\"lazy\" alt=\"\(escapeHTML(screenshot.name))\">"
                        body += "</a>\n"
                    }
                    body += "            <figcaption>\(escapeHTML(screenshot.name))</figcaption>\n"
                    body += "          </figure>\n"
                }
                body += "        </div>\n"
            }
        }

        // CSS-only toggle: two hidden radio inputs at the root of <body>
        // drive visibility of `.variant-raw` / `.variant-framed` via
        // sibling selectors. `framed` is the default checked state
        // because users most often open the preview to inspect the
        // final App Store output; raw is one click away.
        let toggleHTML: String
        if anyFramed {
            toggleHTML = """
                <input type="radio" name="view" id="view-framed" class="view-toggle" checked>
                <input type="radio" name="view" id="view-raw" class="view-toggle">
                <div class="view-picker">
                  <label for="view-framed">Framed</label>
                  <label for="view-raw">Raw</label>
                </div>
            """
        } else {
            toggleHTML = ""
        }

        let isDark = appearance == "dark"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(title)) - \(escapeHTML(appName))</title>
          \(styleTag(darkBackground: isDark))
        </head>
        <body>
        \(toggleHTML)
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
          <title>\(escapeHTML(manifest.appName)) - Screenshot Preview</title>
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

            /* Raw/framed toggle. Hidden radios drive sibling visibility
               so no JS is needed and the choice stays sticky while the
               page is open. */
            .view-toggle { position: absolute; left: -9999px; }
            .view-picker {
              position: sticky; top: 0; z-index: 10;
              width: fit-content; margin: 0 auto 1rem;
              display: flex; gap: 0; padding: 0.25rem;
              background: rgba(20, 20, 20, 0.9); border: 1px solid #2a2a2a;
              border-radius: 8px; backdrop-filter: blur(8px);
            }
            .view-picker label {
              padding: 0.35rem 0.85rem; font-size: 0.75rem; color: #888;
              cursor: pointer; border-radius: 5px;
              transition: background 0.12s, color 0.12s;
            }
            .view-picker label:hover { color: #ccc; }
            #view-framed:checked ~ .view-picker label[for="view-framed"],
            #view-raw:checked    ~ .view-picker label[for="view-raw"] {
              background: #2d2d2d; color: #fff;
            }
            /* Default: framed shown, raw hidden. Flip on when raw is
               selected instead. */
            #view-framed:checked ~ .screenshots .variant-raw { display: none; }
            #view-raw:checked    ~ .screenshots .variant-framed { display: none; }
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

    /// Reverse of pageFilename - extract device type and appearance from a preview filename.
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
        // Built-in map: Xcode locale codes where the svg-flags filename differs.
        let builtin: [String: String] = [
            "en-GB":   "en",
            "es-419":  "es-mx",
            "fr-CA":   "fr-ca-qc",
            "pt-PT":   "pt",
            "zh-Hans": "zh",
            "zh-Hant": "zh",
            "zh-HK":   "zh",
        ]
        // User overrides from config win over built-in on key collisions.
        let merged = builtin.merging(localeFlags) { _, user in user }
        let value = merged[locale] ?? locale.lowercased()
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return value
        }
        let base = "https://raw.githubusercontent.com/ciscoriordan/svg-flags/main/circle/languages"
        return "\(base)/\(value).svg"
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
