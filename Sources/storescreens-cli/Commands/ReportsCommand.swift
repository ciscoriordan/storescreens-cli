import ArgumentParser
import Foundation
import StorescreensCore

/// `storescreens reports` — top-level parent command grouping all of
/// Apple's reporting endpoints (sales, finance, analytics, metrics) under
/// one CLI surface. Read-only; every subcommand resolves ASC credentials
/// via `ASCCredentialResolver` and either prints a brief human-readable
/// summary or emits a structured JSON payload when `--json` is set.
///
/// Note: this file is loaded into the same CLI target as `Main.swift`.
/// `Main.swift` owns the actual subcommand list; per the task constraints we
/// do not edit `Main.swift` here. ReportsCommand will be wired in by a
/// separate step that appends it to the `StoreScreensCLI` subcommands array.
struct ReportsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reports",
        abstract: "Pull sales, finance, and analytics reports from App Store Connect.",
        discussion: """
            All subcommands require App Store Connect API credentials. \
            Run `storescreens auth login` once to store them, then use \
            `--json` for machine-readable output. Sales and finance \
            reports come back as gzipped TSV/CSV — we gunzip and parse \
            them into rows so callers don't have to.
            """,
        subcommands: [
            ReportsSalesCommand.self,
            ReportsFinanceCommand.self,
            ReportsAnalyticsCommand.self,
            ReportsMetricsCommand.self,
        ]
    )
}

// MARK: - Sales

struct ReportsSalesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sales",
        abstract: "Download a Sales and Trends report."
    )

    @Option(name: .long, help: "Frequency: DAILY, WEEKLY, MONTHLY, YEARLY.")
    var frequency: String = "DAILY"

    @Option(name: .long, help: "Report date — YYYY-MM-DD (daily/weekly), YYYY-MM (monthly), YYYY (yearly).")
    var date: String

    @Option(name: .long, help: "SALES, PRE_ORDER, NEWSSTAND, SUBSCRIPTION, SUBSCRIPTION_EVENT, SUBSCRIBER, SUBSCRIPTION_OFFER_CODE_REDEMPTION, INSTALLS, FIRST_ANNUAL, WIN_BACK_ELIGIBILITY.")
    var reportType: String = "SALES"

    @Option(name: .long, help: "SUMMARY or DETAILED.")
    var reportSubType: String = "SUMMARY"

    @Option(name: .long, help: "Vendor number from App Store Connect Payments and Financial Reports.")
    var vendor: String

    @Option(name: .long, help: "Optional Apple report-format version (e.g. \"1_0\", \"1_2\").")
    var version: String?

    @Flag(name: .long, help: "Print only row count + per-column totals, not every row.")
    var summary: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))

        guard let freq = SalesAPI.Frequency(rawValue: frequency.uppercased()) else {
            logger.log("invalid --frequency: \(frequency)", level: .error)
            throw ExitCode(1)
        }
        guard let rt = SalesAPI.ReportType(rawValue: reportType.uppercased()) else {
            logger.log("invalid --report-type: \(reportType)", level: .error)
            throw ExitCode(1)
        }
        guard let rst = SalesAPI.ReportSubType(rawValue: reportSubType.uppercased()) else {
            logger.log("invalid --report-sub-type: \(reportSubType)", level: .error)
            throw ExitCode(1)
        }

        let report: SalesAPI.SalesReport
        do {
            report = try await api.sales.getReport(
                frequency: freq,
                reportType: rt,
                reportSubType: rst,
                reportDate: date,
                vendorNumber: vendor,
                version: version
            )
        } catch {
            logger.log("sales report failed: \(error)", level: .error)
            throw ExitCode(1)
        }

        if json {
            try emitSalesJSON(report)
            return
        }
        printSalesHuman(report, logger: logger)
    }

    private func emitSalesJSON(_ report: SalesAPI.SalesReport) throws {
        struct Out: Encodable {
            let headers: [String]
            let rows: [[String: String]]
            let row_count: Int
            let raw_bytes: Int
        }
        let out = Out(
            headers: report.headers,
            rows: report.rows.map { $0.fields },
            row_count: report.rows.count,
            raw_bytes: report.rawBytes
        )
        try printJSON(out)
    }

    private func printSalesHuman(_ report: SalesAPI.SalesReport, logger: Logger) {
        logger.header("Sales report")
        print("  frequency:  \(frequency.uppercased())")
        print("  date:       \(date)")
        print("  type:       \(reportType.uppercased()) / \(reportSubType.uppercased())")
        print("  rows:       \(report.rows.count)")
        print("  bytes:      \(report.rawBytes)")
        if report.rows.isEmpty {
            print("  (empty — Apple returned the header but no data rows for this filter)")
            return
        }
        if summary {
            let totals = numericTotals(headers: report.headers, rows: report.rows.map(\.fields))
            if totals.isEmpty {
                print("  (no numeric columns to summarize)")
            } else {
                print("")
                print("  Numeric totals:")
                for (k, v) in totals.sorted(by: { $0.key < $1.key }) {
                    print("    \(k): \(v)")
                }
            }
        } else {
            print("")
            printPreviewTable(headers: report.headers, rows: report.rows.map(\.fields))
        }
    }
}

// MARK: - Finance

struct ReportsFinanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finance",
        abstract: "Download a Finance Report (monthly, region-scoped)."
    )

    @Option(name: .long, help: "Apple region code: US, EU, JP, AU, etc.")
    var region: String

    @Option(name: .long, help: "Report date — YYYY-MM.")
    var date: String

    @Option(name: .long, help: "Vendor number from App Store Connect Payments and Financial Reports.")
    var vendor: String

    @Option(name: .long, help: "FINANCIAL or FINANCE_DETAIL.")
    var reportType: String = "FINANCIAL"

    @Flag(name: .long, help: "Print only row count + per-column totals, not every row.")
    var summary: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))

        guard let rt = FinanceAPI.ReportType(rawValue: reportType.uppercased()) else {
            logger.log("invalid --report-type: \(reportType)", level: .error)
            throw ExitCode(1)
        }

        let report: FinanceAPI.FinanceReport
        do {
            report = try await api.finance.getReport(
                regionCode: region,
                reportDate: date,
                vendorNumber: vendor,
                reportType: rt
            )
        } catch {
            logger.log("finance report failed: \(error)", level: .error)
            throw ExitCode(1)
        }

        if json {
            try emitFinanceJSON(report)
            return
        }
        printFinanceHuman(report, logger: logger)
    }

    private func emitFinanceJSON(_ report: FinanceAPI.FinanceReport) throws {
        struct Out: Encodable {
            let headers: [String]
            let rows: [[String: String]]
            let row_count: Int
            let raw_bytes: Int
        }
        let out = Out(
            headers: report.headers,
            rows: report.rows.map { $0.fields },
            row_count: report.rows.count,
            raw_bytes: report.rawBytes
        )
        try printJSON(out)
    }

    private func printFinanceHuman(_ report: FinanceAPI.FinanceReport, logger: Logger) {
        logger.header("Finance report")
        print("  region:     \(region.uppercased())")
        print("  date:       \(date)")
        print("  type:       \(reportType.uppercased())")
        print("  rows:       \(report.rows.count)")
        print("  bytes:      \(report.rawBytes)")
        if report.rows.isEmpty {
            print("  (empty — Apple returned the header but no data rows for this filter)")
            return
        }
        if summary {
            let totals = numericTotals(headers: report.headers, rows: report.rows.map(\.fields))
            if totals.isEmpty {
                print("  (no numeric columns to summarize)")
            } else {
                print("")
                print("  Numeric totals:")
                for (k, v) in totals.sorted(by: { $0.key < $1.key }) {
                    print("    \(k): \(v)")
                }
            }
        } else {
            print("")
            printPreviewTable(headers: report.headers, rows: report.rows.map(\.fields))
        }
    }
}

// MARK: - Analytics (parent + nested)

struct ReportsAnalyticsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analytics",
        abstract: "App Analytics report-request / report / instance / segment flow.",
        subcommands: [
            ReportsAnalyticsRequestCommand.self,
            ReportsAnalyticsReportsCommand.self,
            ReportsAnalyticsInstancesCommand.self,
            ReportsAnalyticsSegmentsCommand.self,
            ReportsAnalyticsSegmentCommand.self,
        ]
    )
}

struct ReportsAnalyticsRequestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "request",
        abstract: "Create or manage an analyticsReportRequest."
    )

    @Option(name: .long, help: "App Store Connect app id.")
    var appId: String

    @Option(name: .long, help: "ONE_TIME_SNAPSHOT or ONGOING.")
    var accessType: String = "ONE_TIME_SNAPSHOT"

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))

        guard let access = AnalyticsAPI.AccessType(rawValue: accessType.uppercased()) else {
            logger.log("invalid --access-type: \(accessType)", level: .error)
            throw ExitCode(1)
        }
        let req: AnalyticsAPI.ReportRequest
        do {
            req = try await api.analytics.createReportRequest(appID: appId, accessType: access)
        } catch {
            logger.log("create request failed: \(error)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try printJSON(req)
            return
        }
        logger.header("Analytics report request")
        print("  id:         \(req.id)")
        print("  access:     \(req.attributes?.accessType ?? "(unknown)")")
    }
}

struct ReportsAnalyticsReportsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reports",
        abstract: "List reports exposed by an analyticsReportRequest.",
        subcommands: [ReportsAnalyticsReportsListCommand.self],
        defaultSubcommand: ReportsAnalyticsReportsListCommand.self
    )
}

struct ReportsAnalyticsReportsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List reports exposed by a report-request."
    )

    @Option(name: .long, help: "analyticsReportRequest id.")
    var requestId: String

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))
        let reports: [AnalyticsAPI.Report]
        do {
            reports = try await api.analytics.listReports(requestID: requestId)
        } catch {
            logger.log("list reports failed: \(error)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try printJSON(reports)
            return
        }
        logger.header("Analytics reports")
        if reports.isEmpty { print("  (none)") ; return }
        for r in reports {
            let name = r.attributes?.name ?? "(no name)"
            let cat = r.attributes?.category ?? "(no category)"
            print("  \(r.id)  \(name)  [\(cat)]")
        }
    }
}

struct ReportsAnalyticsInstancesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "instances",
        abstract: "List analyticsReportInstances for a given report.",
        subcommands: [ReportsAnalyticsInstancesListCommand.self],
        defaultSubcommand: ReportsAnalyticsInstancesListCommand.self
    )
}

struct ReportsAnalyticsInstancesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List instances for a report."
    )

    @Option(name: .long, help: "analyticsReport id.")
    var reportId: String

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))
        let instances: [AnalyticsAPI.ReportInstance]
        do {
            instances = try await api.analytics.listInstances(reportID: reportId)
        } catch {
            logger.log("list instances failed: \(error)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try printJSON(instances)
            return
        }
        logger.header("Analytics report instances")
        if instances.isEmpty { print("  (none)") ; return }
        for inst in instances {
            let g = inst.attributes?.granularity ?? "?"
            let d = inst.attributes?.processingDate ?? "?"
            print("  \(inst.id)  \(g)  \(d)")
        }
    }
}

struct ReportsAnalyticsSegmentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "segments",
        abstract: "List analyticsReportSegments for a given instance.",
        subcommands: [ReportsAnalyticsSegmentsListCommand.self],
        defaultSubcommand: ReportsAnalyticsSegmentsListCommand.self
    )
}

struct ReportsAnalyticsSegmentsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List segments for an instance."
    )

    @Option(name: .long, help: "analyticsReportInstance id.")
    var instanceId: String

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))
        let segments: [AnalyticsAPI.Segment]
        do {
            segments = try await api.analytics.listSegments(instanceID: instanceId)
        } catch {
            logger.log("list segments failed: \(error)", level: .error)
            throw ExitCode(1)
        }
        if json {
            try printJSON(segments)
            return
        }
        logger.header("Analytics report segments")
        if segments.isEmpty { print("  (none)") ; return }
        for s in segments {
            let bytes = s.attributes?.sizeInBytes.map(String.init) ?? "?"
            let url = s.attributes?.url ?? "(no url)"
            print("  \(s.id)  \(bytes) bytes")
            print("    url: \(url)")
        }
    }
}

struct ReportsAnalyticsSegmentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "segment",
        abstract: "Download a single segment.",
        subcommands: [ReportsAnalyticsSegmentDownloadCommand.self],
        defaultSubcommand: ReportsAnalyticsSegmentDownloadCommand.self
    )
}

struct ReportsAnalyticsSegmentDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download + decompress + parse a segment by id or url."
    )

    @Option(name: .long, help: "Signed segment URL (from `analytics segments list`).")
    var segmentUrl: String?

    @Option(name: .long, help: "Segment id (we'll look up the current signed URL).")
    var segmentId: String?

    @Option(name: .long, help: "Optional output file. If set, writes the decompressed CSV bytes to disk.")
    var output: String?

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))

        let url: String
        if let direct = segmentUrl, !direct.isEmpty {
            url = direct
        } else if let id = segmentId, !id.isEmpty {
            do {
                let segment = try await api.analytics.getSegment(id: id)
                guard let resolved = segment.attributes?.url else {
                    logger.log("segment \(id) has no url attribute", level: .error)
                    throw ExitCode(1)
                }
                url = resolved
            } catch {
                logger.log("segment lookup failed: \(error)", level: .error)
                throw ExitCode(1)
            }
        } else {
            logger.log("provide --segment-url or --segment-id", level: .error)
            throw ExitCode(1)
        }

        let data: AnalyticsAPI.SegmentData
        do {
            data = try await api.analytics.downloadSegment(url: url)
        } catch {
            logger.log("segment download failed: \(error)", level: .error)
            throw ExitCode(1)
        }

        if let path = output {
            // Reconstruct a CSV representation of the parsed rows so the
            // caller can pipe the result into their own tooling. We don't
            // emit Apple's raw gzip — that's lossy to the caller.
            let header = data.headers.map(csvEscape).joined(separator: ",")
            let lines = data.rows.map { row -> String in
                data.headers.map { csvEscape(row[$0] ?? "") }.joined(separator: ",")
            }
            let csv = ([header] + lines).joined(separator: "\n")
            try csv.write(toFile: path, atomically: true, encoding: .utf8)
            logger.log("wrote \(data.rows.count) rows to \(path)", level: .success)
            return
        }

        if json {
            struct Out: Encodable {
                let headers: [String]
                let rows: [[String: String]]
                let row_count: Int
                let raw_bytes: Int
            }
            try printJSON(Out(
                headers: data.headers,
                rows: data.rows,
                row_count: data.rows.count,
                raw_bytes: data.rawBytes
            ))
            return
        }

        logger.header("Analytics segment")
        print("  rows:       \(data.rows.count)")
        print("  bytes:      \(data.rawBytes)")
        if data.rows.isEmpty { return }
        print("")
        printPreviewTable(headers: data.headers, rows: data.rows)
    }
}

// MARK: - Metrics

struct ReportsMetricsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metrics",
        abstract: "Performance + diagnostic metrics endpoints.",
        subcommands: [
            ReportsMetricsPerfPowerCommand.self,
            ReportsMetricsDiagnosticsCommand.self,
        ]
    )
}

struct ReportsMetricsPerfPowerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "perf-power",
        abstract: "List perfPowerMetrics snapshots for an app or build."
    )

    @Option(name: .long, help: "App Store Connect app id.")
    var appId: String?

    @Option(name: .long, help: "Build id (overrides --app-id when both are given).")
    var buildId: String?

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))

        let list: [MetricsAPI.PerfPowerMetric]
        if let buildId, !buildId.isEmpty {
            list = try await api.metrics.listPerfPowerMetricsForBuild(buildID: buildId)
        } else if let appId, !appId.isEmpty {
            list = try await api.metrics.listPerfPowerMetricsForApp(appID: appId)
        } else {
            logger.log("provide --app-id or --build-id", level: .error)
            throw ExitCode(1)
        }
        if json {
            try printJSON(list)
            return
        }
        logger.header("Performance / power metrics")
        if list.isEmpty { print("  (none)") ; return }
        for m in list {
            let p = m.attributes?.platform ?? "?"
            let c = m.attributes?.metricCategory ?? "?"
            print("  \(m.id)  \(p)  \(c)")
        }
    }
}

struct ReportsMetricsDiagnosticsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostics",
        abstract: "List or fetch diagnostic signatures for a build.",
        subcommands: [
            ReportsMetricsDiagnosticsListCommand.self,
            ReportsMetricsDiagnosticsGetCommand.self,
        ]
    )
}

struct ReportsMetricsDiagnosticsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List diagnosticSignatures for a build."
    )

    @Option(name: .long, help: "Build id.")
    var buildId: String

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))
        let list = try await api.metrics.listDiagnosticSignatures(buildID: buildId)
        if json {
            try printJSON(list)
            return
        }
        logger.header("Diagnostic signatures")
        if list.isEmpty { print("  (none)") ; return }
        for d in list {
            let dt = d.attributes?.diagnosticType ?? "?"
            let w = d.attributes?.weight.map { String(format: "%.2f", $0) } ?? "?"
            let s = d.attributes?.signature ?? "(no signature)"
            print("  \(d.id)  \(dt)  w=\(w)  \(s)")
        }
    }
}

struct ReportsMetricsDiagnosticsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch a diagnostic signature by id."
    )

    @Option(name: .long, help: "Diagnostic signature id.")
    var signatureId: String

    @Flag(name: .long, help: "Include related diagnosticLogs.")
    var includeLogs: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let creds = try resolveCreds(logger: logger)
        let api = ReportsAPI(client: ASCClient(credentials: creds))
        let detail = try await api.metrics.getDiagnosticSignature(id: signatureId, includeLogs: includeLogs)
        if json {
            try printJSON(detail)
            return
        }
        logger.header("Diagnostic signature")
        print("  id:         \(detail.id)")
        print("  type:       \(detail.attributes?.diagnosticType ?? "?")")
        print("  weight:     \(detail.attributes?.weight.map { String(format: "%.4f", $0) } ?? "?")")
        print("  signature:  \(detail.attributes?.signature ?? "(none)")")
    }
}

// MARK: - File-private helpers

/// Resolves ASC credentials and surfaces a stable error message when they
/// aren't configured. Shared across every reports subcommand.
private func resolveCreds(logger: Logger) throws -> ASCCredentials {
    do {
        return try ASCCredentialResolver.resolve()
    } catch {
        logger.log("App Store Connect credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
}

/// Pretty-prints any Encodable as JSON to stdout. Identical to the helper
/// used in StatusCommand (we duplicate the small body rather than depend on
/// a shared utility because each command keeps its own encoder config).
private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

/// Sums each header whose values parse as Doubles. Skips columns whose
/// values don't (text columns like SKU / Title / Provider).
private func numericTotals(headers: [String], rows: [[String: String]]) -> [String: Double] {
    var totals: [String: Double] = [:]
    for header in headers {
        var sum = 0.0
        var hadAny = false
        for row in rows {
            guard let raw = row[header] else { continue }
            // Strip thousands separators before parsing — Apple reports
            // sometimes format proceeds with embedded commas inside
            // quoted fields (we already de-quoted them in the parser).
            let cleaned = raw.replacingOccurrences(of: ",", with: "")
            if let v = Double(cleaned.trimmingCharacters(in: .whitespaces)) {
                sum += v
                hadAny = true
            }
        }
        if hadAny { totals[header] = sum }
    }
    return totals
}

/// Renders a small fixed-width preview of the first ~10 rows so the human
/// output isn't a wall of comma-separated text. Truncates long cell values
/// to keep the table from wrapping on a typical 100-col terminal.
private func printPreviewTable(headers: [String], rows: [[String: String]]) {
    let maxRows = min(10, rows.count)
    let maxColWidth = 18
    let visibleHeaders = Array(headers.prefix(6))
    // Compute per-column widths.
    var widths: [Int] = visibleHeaders.map { min(maxColWidth, $0.count) }
    for i in 0..<maxRows {
        for (j, h) in visibleHeaders.enumerated() {
            let v = truncate(rows[i][h] ?? "", to: maxColWidth)
            widths[j] = max(widths[j], v.count)
        }
    }
    // Header
    let headerLine = zip(visibleHeaders, widths)
        .map { pad(truncate($0.0, to: maxColWidth), to: $0.1) }
        .joined(separator: "  ")
    print("  \(headerLine)")
    let divider = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")
    print("  \(divider)")
    // Body
    for i in 0..<maxRows {
        let line = zip(visibleHeaders, widths).map { (h, w) -> String in
            pad(truncate(rows[i][h] ?? "", to: maxColWidth), to: w)
        }.joined(separator: "  ")
        print("  \(line)")
    }
    if rows.count > maxRows {
        print("  … (\(rows.count - maxRows) more rows)")
    }
    if headers.count > visibleHeaders.count {
        print("  (showing \(visibleHeaders.count) of \(headers.count) columns; use --json for the full payload)")
    }
}

/// Truncates with an ellipsis once `s.count` exceeds `n`. Keeps strings
/// fixed-width for the preview table.
private func truncate(_ s: String, to n: Int) -> String {
    if s.count <= n { return s }
    return String(s.prefix(max(0, n - 1))) + "…"
}

/// Pads on the right with spaces to a target width. Used for column
/// alignment in the preview table.
private func pad(_ s: String, to n: Int) -> String {
    if s.count >= n { return s }
    return s + String(repeating: " ", count: n - s.count)
}

/// CSV-escapes a value. Quotes the field if it contains a comma, quote,
/// or newline; doubles embedded quotes per RFC 4180.
private func csvEscape(_ s: String) -> String {
    let needsQuotes = s.contains(",") || s.contains("\"") || s.contains("\n")
    if !needsQuotes { return s }
    let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
    return "\"\(escaped)\""
}
