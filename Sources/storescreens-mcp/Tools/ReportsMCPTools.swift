import Foundation
import MCP
import StorescreensCore

/// MCP tool surface for App Store Connect reporting endpoints: sales,
/// finance, and the App Analytics report-request flow. Wraps
/// `ReportsAPI` so an AI agent can pull revenue and download data without
/// constructing the gzipped TSV/CSV plumbing by hand.
///
/// All tools resolve credentials through `ASCCredentialResolver.resolve()`
/// (env vars first, then `~/.storescreens/asc-credentials.yml`) and return
/// pretty-printed JSON in a single `.text` content block, with
/// `isError: true` on failures.
///
/// Note: this file is loaded into the same MCP target as `Main.swift`.
/// `Main.swift` owns the actual server bootstrap and tool registration; per
/// the task constraints we do not edit `Main.swift` here, so the dispatch
/// glue stays unused until a wiring step plugs `ReportsMCPTools.tools` into
/// `StorescreensMCP.tools` and `ReportsMCPTools.handle(_:)` into the
/// dispatch switch.
package enum ReportsMCPTools {

    // MARK: - Tool catalog

    package static let tools: [Tool] = [

        // ─── Sales reports ────────────────────────────────────────────

        Tool(
            name: "reports_sales_get",
            description: """
            Pull a Sales and Trends report from App Store Connect. \
            Returns parsed rows from Apple's gzipped TSV, optionally \
            summarized. Use frequency=DAILY|WEEKLY|MONTHLY|YEARLY and \
            an appropriately-shaped report_date (YYYY-MM-DD for daily \
            / weekly, YYYY-MM for monthly, YYYY for yearly). \
            vendor_number is the team identifier shown on the App \
            Store Connect Payments and Financial Reports page.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "frequency": .object([
                        "type": .string("string"),
                        "description": .string("DAILY | WEEKLY | MONTHLY | YEARLY (default DAILY)."),
                    ]),
                    "report_date": .object([
                        "type": .string("string"),
                        "description": .string("YYYY-MM-DD (daily/weekly), YYYY-MM (monthly), or YYYY (yearly)."),
                    ]),
                    "report_type": .object([
                        "type": .string("string"),
                        "description": .string("SALES (default), PRE_ORDER, NEWSSTAND, SUBSCRIPTION, SUBSCRIPTION_EVENT, SUBSCRIBER, SUBSCRIPTION_OFFER_CODE_REDEMPTION, INSTALLS, FIRST_ANNUAL, WIN_BACK_ELIGIBILITY."),
                    ]),
                    "report_sub_type": .object([
                        "type": .string("string"),
                        "description": .string("SUMMARY (default) or DETAILED."),
                    ]),
                    "vendor_number": .object([
                        "type": .string("string"),
                        "description": .string("Vendor number from App Store Connect Payments and Financial Reports."),
                    ]),
                    "version": .object([
                        "type": .string("string"),
                        "description": .string("Optional report-format version (e.g. \"1_0\", \"1_2\")."),
                    ]),
                    "summary_only": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, return aggregate counts/totals only, not every row. Default false."),
                    ]),
                ]),
                "required": .array([.string("report_date"), .string("vendor_number")]),
            ])
        ),

        // ─── Finance reports ──────────────────────────────────────────

        Tool(
            name: "reports_finance_get",
            description: """
            Pull a Finance Report (gzipped CSV) from App Store Connect. \
            Finance reports group revenue per region per calendar month \
            across every app under a vendor. region is the Apple-defined \
            market code (US, EU, JP, AU, …); report_date is YYYY-MM; \
            report_type defaults to FINANCIAL.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "region": .object([
                        "type": .string("string"),
                        "description": .string("Apple region code: US, EU, JP, AU, etc."),
                    ]),
                    "report_date": .object([
                        "type": .string("string"),
                        "description": .string("YYYY-MM (one calendar month)."),
                    ]),
                    "vendor_number": .object([
                        "type": .string("string"),
                        "description": .string("Vendor number from App Store Connect Payments and Financial Reports."),
                    ]),
                    "report_type": .object([
                        "type": .string("string"),
                        "description": .string("FINANCIAL (default) or FINANCE_DETAIL."),
                    ]),
                    "summary_only": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, return aggregate counts/totals only, not every row. Default false."),
                    ]),
                ]),
                "required": .array([.string("region"), .string("report_date"), .string("vendor_number")]),
            ])
        ),

        // ─── App Analytics: report requests ───────────────────────────

        Tool(
            name: "reports_analytics_request_create",
            description: """
            Create an `analyticsReportRequest` for an app. \
            access_type=ONE_TIME_SNAPSHOT pins a one-shot report set tied \
            to the creation date; access_type=ONGOING emits a fresh \
            instance each granularity period until the request is deleted. \
            Returns the request id, which feeds into reports_analytics_reports_list.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id (numeric string)."),
                    ]),
                    "access_type": .object([
                        "type": .string("string"),
                        "description": .string("ONE_TIME_SNAPSHOT (default) or ONGOING."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "reports_analytics_request_list",
            description: "List analyticsReportRequests already attached to an app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id."),
                    ]),
                ]),
                "required": .array([.string("app_id")]),
            ])
        ),

        Tool(
            name: "reports_analytics_request_delete",
            description: "Delete an analyticsReportRequest (stops Apple from emitting fresh instances for ONGOING requests).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "request_id": .object([
                        "type": .string("string"),
                        "description": .string("The analyticsReportRequest id to delete."),
                    ]),
                ]),
                "required": .array([.string("request_id")]),
            ])
        ),

        // ─── App Analytics: reports / instances / segments ────────────

        Tool(
            name: "reports_analytics_reports_list",
            description: """
            List the analyticsReports a request gives access to. Each \
            report represents a category (engagement, downloads, etc.). \
            Use the report id from this call as input to reports_analytics_instances_list.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "request_id": .object([
                        "type": .string("string"),
                        "description": .string("The analyticsReportRequest id."),
                    ]),
                ]),
                "required": .array([.string("request_id")]),
            ])
        ),

        Tool(
            name: "reports_analytics_instances_list",
            description: """
            List analyticsReportInstances for a given report. Each instance \
            is a date-windowed snapshot Apple has assembled. Filter by \
            granularity (DAILY / WEEKLY / MONTHLY) and/or processing date \
            after listing.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "report_id": .object([
                        "type": .string("string"),
                        "description": .string("The analyticsReport id."),
                    ]),
                ]),
                "required": .array([.string("report_id")]),
            ])
        ),

        Tool(
            name: "reports_analytics_segments_list",
            description: """
            List analyticsReportSegments for an instance. Each segment is a \
            chunk of gzipped CSV with its own signed download URL. Pass the \
            segment URL to reports_analytics_segment_download to fetch and \
            parse it.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "instance_id": .object([
                        "type": .string("string"),
                        "description": .string("The analyticsReportInstance id."),
                    ]),
                ]),
                "required": .array([.string("instance_id")]),
            ])
        ),

        Tool(
            name: "reports_analytics_segment_download",
            description: """
            Download a single analytics segment from its signed URL, \
            gunzip the body, and return parsed CSV rows. Pass either the \
            full segment_url from reports_analytics_segments_list, or a \
            segment_id (we'll fetch the URL ourselves). summary_only=true \
            returns row count + bytes only.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "segment_url": .object([
                        "type": .string("string"),
                        "description": .string("Signed segment URL from reports_analytics_segments_list."),
                    ]),
                    "segment_id": .object([
                        "type": .string("string"),
                        "description": .string("Segment id (we'll look up its current signed URL). Alternative to segment_url."),
                    ]),
                    "summary_only": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, return only row count + bytes summary. Default false."),
                    ]),
                ]),
            ])
        ),

        // ─── Performance + diagnostics ────────────────────────────────

        Tool(
            name: "reports_metrics_perfpower_list",
            description: "List perfPowerMetrics snapshots for an app or build (xor app_id and build_id).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id. Mutually exclusive with build_id."),
                    ]),
                    "build_id": .object([
                        "type": .string("string"),
                        "description": .string("Build id (overrides app_id when set)."),
                    ]),
                ]),
            ])
        ),

        Tool(
            name: "reports_metrics_diagnostics_list",
            description: "List diagnosticSignatures for a given build.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_id": .object([
                        "type": .string("string"),
                        "description": .string("Build id."),
                    ]),
                ]),
                "required": .array([.string("build_id")]),
            ])
        ),

        Tool(
            name: "reports_metrics_diagnostics_get",
            description: "Fetch one diagnostic signature by id. include_logs=true also pulls the related diagnosticLogs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "signature_id": .object([
                        "type": .string("string"),
                        "description": .string("Diagnostic signature id."),
                    ]),
                    "include_logs": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, pulls related diagnosticLogs alongside the signature attributes. Default false."),
                    ]),
                ]),
                "required": .array([.string("signature_id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Top-level handler. `Main.swift` will route any tool whose name starts
    /// with `reports_` here once wired.
    package static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        switch params.name {
        case "reports_sales_get":
            return try await handleSalesGet(params)
        case "reports_finance_get":
            return try await handleFinanceGet(params)
        case "reports_analytics_request_create":
            return try await handleAnalyticsRequestCreate(params)
        case "reports_analytics_request_list":
            return try await handleAnalyticsRequestList(params)
        case "reports_analytics_request_delete":
            return try await handleAnalyticsRequestDelete(params)
        case "reports_analytics_reports_list":
            return try await handleAnalyticsReportsList(params)
        case "reports_analytics_instances_list":
            return try await handleAnalyticsInstancesList(params)
        case "reports_analytics_segments_list":
            return try await handleAnalyticsSegmentsList(params)
        case "reports_analytics_segment_download":
            return try await handleAnalyticsSegmentDownload(params)
        case "reports_metrics_perfpower_list":
            return try await handleMetricsPerfPowerList(params)
        case "reports_metrics_diagnostics_list":
            return try await handleMetricsDiagnosticsList(params)
        case "reports_metrics_diagnostics_get":
            return try await handleMetricsDiagnosticsGet(params)
        default:
            return .init(content: [.text("Unknown reports tool: \(params.name)")], isError: true)
        }
    }

    // MARK: - Sales

    private static func handleSalesGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let args = params.arguments ?? [:]
        guard let reportDate = args["report_date"]?.stringValue, !reportDate.isEmpty else {
            return .init(content: [.text("Missing required parameter: report_date")], isError: true)
        }
        guard let vendor = args["vendor_number"]?.stringValue, !vendor.isEmpty else {
            return .init(content: [.text("Missing required parameter: vendor_number")], isError: true)
        }
        let frequency = SalesAPI.Frequency(rawValue: args["frequency"]?.stringValue ?? "DAILY") ?? .daily
        let reportType = SalesAPI.ReportType(rawValue: args["report_type"]?.stringValue ?? "SALES") ?? .sales
        let subType = SalesAPI.ReportSubType(rawValue: args["report_sub_type"]?.stringValue ?? "SUMMARY") ?? .summary
        let version = args["version"]?.stringValue
        let summaryOnly = args["summary_only"]?.boolValue ?? false

        let api = try makeReports()
        let report: SalesAPI.SalesReport
        do {
            report = try await api.sales.getReport(
                frequency: frequency,
                reportType: reportType,
                reportSubType: subType,
                reportDate: reportDate,
                vendorNumber: vendor,
                version: version
            )
        } catch {
            return errorResult(error)
        }

        if summaryOnly {
            let summary = summarizeSales(report)
            return .init(content: [.text(try prettyJSON(summary))], isError: false)
        }
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
        return .init(content: [.text(try prettyJSON(out))], isError: false)
    }

    // MARK: - Finance

    private static func handleFinanceGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let args = params.arguments ?? [:]
        guard let region = args["region"]?.stringValue, !region.isEmpty else {
            return .init(content: [.text("Missing required parameter: region")], isError: true)
        }
        guard let reportDate = args["report_date"]?.stringValue, !reportDate.isEmpty else {
            return .init(content: [.text("Missing required parameter: report_date")], isError: true)
        }
        guard let vendor = args["vendor_number"]?.stringValue, !vendor.isEmpty else {
            return .init(content: [.text("Missing required parameter: vendor_number")], isError: true)
        }
        let reportType = FinanceAPI.ReportType(rawValue: args["report_type"]?.stringValue ?? "FINANCIAL") ?? .financial
        let summaryOnly = args["summary_only"]?.boolValue ?? false

        let api = try makeReports()
        let report: FinanceAPI.FinanceReport
        do {
            report = try await api.finance.getReport(
                regionCode: region,
                reportDate: reportDate,
                vendorNumber: vendor,
                reportType: reportType
            )
        } catch {
            return errorResult(error)
        }

        if summaryOnly {
            let summary = summarizeFinance(report)
            return .init(content: [.text(try prettyJSON(summary))], isError: false)
        }
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
        return .init(content: [.text(try prettyJSON(out))], isError: false)
    }

    // MARK: - Analytics

    private static func handleAnalyticsRequestCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let args = params.arguments ?? [:]
        guard let appID = args["app_id"]?.stringValue, !appID.isEmpty else {
            return .init(content: [.text("Missing required parameter: app_id")], isError: true)
        }
        let accessRaw = args["access_type"]?.stringValue ?? "ONE_TIME_SNAPSHOT"
        let access = AnalyticsAPI.AccessType(rawValue: accessRaw) ?? .oneTimeSnapshot

        let api = try makeReports()
        do {
            let req = try await api.analytics.createReportRequest(appID: appID, accessType: access)
            return .init(content: [.text(try prettyJSON(req))], isError: false)
        } catch {
            return errorResult(error)
        }
    }

    private static func handleAnalyticsRequestList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let appID = params.arguments?["app_id"]?.stringValue, !appID.isEmpty else {
            return .init(content: [.text("Missing required parameter: app_id")], isError: true)
        }
        let api = try makeReports()
        do {
            let list = try await api.analytics.listReportRequests(appID: appID)
            return .init(content: [.text(try prettyJSON(list))], isError: false)
        } catch {
            return errorResult(error)
        }
    }

    private static func handleAnalyticsRequestDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["request_id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text("Missing required parameter: request_id")], isError: true)
        }
        let api = try makeReports()
        do {
            try await api.analytics.deleteReportRequest(id: id)
            return .init(content: [.text("Deleted analyticsReportRequest \(id)")], isError: false)
        } catch {
            return errorResult(error)
        }
    }

    private static func handleAnalyticsReportsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["request_id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text("Missing required parameter: request_id")], isError: true)
        }
        let api = try makeReports()
        do {
            let reports = try await api.analytics.listReports(requestID: id)
            return .init(content: [.text(try prettyJSON(reports))], isError: false)
        } catch {
            return errorResult(error)
        }
    }

    private static func handleAnalyticsInstancesList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["report_id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text("Missing required parameter: report_id")], isError: true)
        }
        let api = try makeReports()
        do {
            let instances = try await api.analytics.listInstances(reportID: id)
            return .init(content: [.text(try prettyJSON(instances))], isError: false)
        } catch {
            return errorResult(error)
        }
    }

    private static func handleAnalyticsSegmentsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["instance_id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text("Missing required parameter: instance_id")], isError: true)
        }
        let api = try makeReports()
        do {
            let segments = try await api.analytics.listSegments(instanceID: id)
            return .init(content: [.text(try prettyJSON(segments))], isError: false)
        } catch {
            return errorResult(error)
        }
    }

    private static func handleAnalyticsSegmentDownload(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let args = params.arguments ?? [:]
        let summaryOnly = args["summary_only"]?.boolValue ?? false

        // Resolve the signed segment URL. Either the caller gives it to us
        // directly (cheap) or hands us a segment id (one extra GET to look
        // up the current signed URL - useful when the prior URL has expired).
        let url: String
        let api = try makeReports()
        if let direct = args["segment_url"]?.stringValue, !direct.isEmpty {
            url = direct
        } else if let segID = args["segment_id"]?.stringValue, !segID.isEmpty {
            do {
                let segment = try await api.analytics.getSegment(id: segID)
                guard let resolved = segment.attributes?.url else {
                    return .init(content: [.text("Segment \(segID) has no url attribute")], isError: true)
                }
                url = resolved
            } catch {
                return errorResult(error)
            }
        } else {
            return .init(content: [.text("Provide either segment_url or segment_id")], isError: true)
        }

        let data: AnalyticsAPI.SegmentData
        do {
            data = try await api.analytics.downloadSegment(url: url)
        } catch {
            return errorResult(error)
        }

        if summaryOnly {
            struct Out: Encodable {
                let row_count: Int
                let raw_bytes: Int
                let headers: [String]
            }
            let out = Out(
                row_count: data.rows.count,
                raw_bytes: data.rawBytes,
                headers: data.headers
            )
            return .init(content: [.text(try prettyJSON(out))], isError: false)
        }
        struct Out: Encodable {
            let headers: [String]
            let rows: [[String: String]]
            let row_count: Int
            let raw_bytes: Int
        }
        let out = Out(
            headers: data.headers,
            rows: data.rows,
            row_count: data.rows.count,
            raw_bytes: data.rawBytes
        )
        return .init(content: [.text(try prettyJSON(out))], isError: false)
    }

    // MARK: - Metrics

    private static func handleMetricsPerfPowerList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let args = params.arguments ?? [:]
        let api = try makeReports()
        do {
            if let buildID = args["build_id"]?.stringValue, !buildID.isEmpty {
                let list = try await api.metrics.listPerfPowerMetricsForBuild(buildID: buildID)
                return .init(content: [.text(try prettyJSON(list))], isError: false)
            }
            if let appID = args["app_id"]?.stringValue, !appID.isEmpty {
                let list = try await api.metrics.listPerfPowerMetricsForApp(appID: appID)
                return .init(content: [.text(try prettyJSON(list))], isError: false)
            }
            return .init(content: [.text("Provide either app_id or build_id")], isError: true)
        } catch {
            return errorResult(error)
        }
    }

    private static func handleMetricsDiagnosticsList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["build_id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text("Missing required parameter: build_id")], isError: true)
        }
        let api = try makeReports()
        do {
            let list = try await api.metrics.listDiagnosticSignatures(buildID: id)
            return .init(content: [.text(try prettyJSON(list))], isError: false)
        } catch {
            return errorResult(error)
        }
    }

    private static func handleMetricsDiagnosticsGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let id = params.arguments?["signature_id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text("Missing required parameter: signature_id")], isError: true)
        }
        let includeLogs = params.arguments?["include_logs"]?.boolValue ?? false
        let api = try makeReports()
        do {
            let detail = try await api.metrics.getDiagnosticSignature(id: id, includeLogs: includeLogs)
            return .init(content: [.text(try prettyJSON(detail))], isError: false)
        } catch {
            return errorResult(error)
        }
    }

    // MARK: - Helpers

    /// Resolves credentials and builds a ReportsAPI bound to a fresh
    /// ASCClient. Cheap to recreate per call: ASCClient caches its JWT
    /// internally, but the cost of constructing a new client is negligible.
    private static func makeReports() throws -> ReportsAPI {
        let creds = try ASCCredentialResolver.resolve()
        return ReportsAPI(client: ASCClient(credentials: creds))
    }

    /// Builds a `.text` result wrapping a thrown error. Mirrors the pattern
    /// `Main.swift` uses elsewhere so error formatting stays consistent.
    private static func errorResult(_ error: Error) -> CallTool.Result {
        if let api = error as? ASCClient.APIError {
            return .init(content: [.text("App Store Connect error: \(api.description)")], isError: true)
        }
        return .init(content: [.text("Error: \(error.localizedDescription)")], isError: true)
    }

    private static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Summaries

    /// Reduces a sales report to row count + per-numeric-column totals.
    /// Apple's sales columns include `Units`, `Developer Proceeds`, etc.
    /// We sum every column whose values parse as Doubles. Skips columns
    /// where no values parse (typically text columns like SKU / Title).
    private static func summarizeSales(_ report: SalesAPI.SalesReport) -> [String: AnyEncodableValue] {
        var summary: [String: AnyEncodableValue] = [:]
        summary["row_count"] = .int(report.rows.count)
        summary["raw_bytes"] = .int(report.rawBytes)
        summary["headers"] = .stringArray(report.headers)
        summary["totals"] = .doubleDict(numericTotals(headers: report.headers, rows: report.rows.map(\.fields)))
        return summary
    }

    private static func summarizeFinance(_ report: FinanceAPI.FinanceReport) -> [String: AnyEncodableValue] {
        var summary: [String: AnyEncodableValue] = [:]
        summary["row_count"] = .int(report.rows.count)
        summary["raw_bytes"] = .int(report.rawBytes)
        summary["headers"] = .stringArray(report.headers)
        summary["totals"] = .doubleDict(numericTotals(headers: report.headers, rows: report.rows.map(\.fields)))
        return summary
    }

    /// For each header whose values look numeric, return the sum. Skips
    /// columns whose values don't parse as Double (text columns like SKU).
    private static func numericTotals(headers: [String], rows: [[String: String]]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for header in headers {
            var sum = 0.0
            var hadAny = false
            for row in rows {
                guard let raw = row[header] else { continue }
                let cleaned = raw.replacingOccurrences(of: ",", with: "")
                if let v = Double(cleaned.trimmingCharacters(in: .whitespaces)) {
                    sum += v
                    hadAny = true
                }
            }
            if hadAny {
                totals[header] = sum
            }
        }
        return totals
    }
}

// MARK: - Tiny encodable wrapper

/// Heterogeneous summary values. We can't put `Int`, `[String]`, and
/// `[String: Double]` into a single `[String: Encodable]` dict without
/// erasing the type, so this enum covers exactly the shapes the
/// summarizers emit.
package enum AnyEncodableValue: Encodable {
    case int(Int)
    case stringArray([String])
    case doubleDict([String: Double])

    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let v): try c.encode(v)
        case .stringArray(let v): try c.encode(v)
        case .doubleDict(let v): try c.encode(v)
        }
    }
}
