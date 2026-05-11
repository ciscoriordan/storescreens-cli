import Foundation

/// App Store Connect reporting endpoints: sales/finance reports (gzipped
/// TSV / CSV file responses) plus the newer App Analytics report-request /
/// report / instance / segment flow (JSON metadata + signed segment URLs
/// that return gzipped CSV). Also exposes a thin wrapper over the
/// `perfPowerMetrics` and `diagnosticSignatures` resources.
///
/// Sales + finance endpoints don't go through ASCClient's JSON path because
/// they stream binary file bodies, not JSON:API envelopes. We mint a JWT
/// via ASCJWTSigner and call URLSession directly, then run the response
/// through gunzip + a small TSV/CSV parser to surface typed row arrays to
/// callers. The analytics + metrics endpoints are plain JSON so they go
/// through ASCClient normally.
///
/// Docs:
///   - https://developer.apple.com/documentation/appstoreconnectapi/download_sales_and_trends_reports
///   - https://developer.apple.com/documentation/appstoreconnectapi/download_finance_reports
///   - https://developer.apple.com/documentation/appstoreconnectapi/app_analytics
///   - https://developer.apple.com/documentation/appstoreconnectapi/performance_metrics_and_diagnostics
package struct ReportsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // Convenience accessors that share the underlying ASCClient + creds.
    package var sales: SalesAPI { SalesAPI(client: client) }
    package var finance: FinanceAPI { FinanceAPI(client: client) }
    package var analytics: AnalyticsAPI { AnalyticsAPI(client: client) }
    package var metrics: MetricsAPI { MetricsAPI(client: client) }
}

// MARK: - Reporting error

package enum ReportsError: Error, CustomStringConvertible {
    case httpFailure(statusCode: Int, body: String)
    case gunzipFailed(stderr: String)
    case parseFailed(reason: String)
    case missingHeader(name: String)

    package var description: String {
        switch self {
        case .httpFailure(let code, let body):
            return "App Store Connect reports HTTP \(code): \(body)"
        case .gunzipFailed(let stderr):
            return "gunzip failed: \(stderr)"
        case .parseFailed(let reason):
            return "report parse failed: \(reason)"
        case .missingHeader(let name):
            return "report response missing expected header \(name)"
        }
    }
}

// MARK: - Sales reports

/// `GET /v1/salesReports` — returns a gzipped TSV body. Apple groups its
/// reporting endpoints under "Sales and Trends Reports"; in their data model
/// `vendorNumber` is the team identifier you can grab from the Payments and
/// Financial Reports section in App Store Connect.
package struct SalesAPI {
    package let client: ASCClient

    package init(client: ASCClient) { self.client = client }

    /// Frequencies Apple's sales reports support. `DAILY` / `WEEKLY` use
    /// `YYYY-MM-DD`, `MONTHLY` uses `YYYY-MM`, `YEARLY` uses `YYYY`.
    package enum Frequency: String, Sendable, CaseIterable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    /// Sales report-type categories Apple exposes. `SALES` is the default
    /// per-line-item report; the other values describe other reporting
    /// surfaces (pre-order spikes, subscription mechanics, etc.).
    package enum ReportType: String, Sendable, CaseIterable {
        case sales = "SALES"
        case preOrder = "PRE_ORDER"
        case newsstand = "NEWSSTAND"
        case subscription = "SUBSCRIPTION"
        case subscriptionEvent = "SUBSCRIPTION_EVENT"
        case subscriber = "SUBSCRIBER"
        case subscriptionOfferCodeRedemption = "SUBSCRIPTION_OFFER_CODE_REDEMPTION"
        case installs = "INSTALLS"
        case firstAnnual = "FIRST_ANNUAL"
        case winBackEligibility = "WIN_BACK_ELIGIBILITY"
    }

    /// `SUMMARY` is one row per (sku, country); `DETAILED` is one row per
    /// transaction. Different report types accept different sub-types; Apple
    /// documents the matrix.
    package enum ReportSubType: String, Sendable, CaseIterable {
        case summary = "SUMMARY"
        case detailed = "DETAILED"
    }

    /// A single parsed row from the TSV body. Apple's reports use different
    /// column sets per (reportType, subType, version) tuple, so we model the
    /// rows as `[header: value]` dictionaries — that lets the same call site
    /// handle sales, installs, subscription, etc. without bespoke models per
    /// shape.
    package struct SalesRow: Sendable, Codable {
        package let fields: [String: String]
        package init(fields: [String: String]) { self.fields = fields }
    }

    /// Result envelope returned from `getReport`. `headers` preserves the
    /// column order Apple emitted so callers that need a deterministic
    /// printout can iterate the headers rather than the unordered dict.
    package struct SalesReport: Sendable, Codable {
        package let headers: [String]
        package let rows: [SalesRow]
        package let rawBytes: Int

        /// True when the report came back empty (no rows after the header).
        /// Apple still returns 200 with just the header line on quiet days,
        /// so absence-of-rows is a normal outcome and not an error.
        package var isEmpty: Bool { rows.isEmpty }
    }

    /// Hits `GET /v1/salesReports` with the supplied filters. Decompresses
    /// the gzipped TSV body and returns parsed rows. `version` is optional;
    /// Apple's docs use values like `"1_0"`, `"1_2"`, etc. depending on the
    /// reportType / subType combination.
    package func getReport(
        frequency: Frequency,
        reportType: ReportType,
        reportSubType: ReportSubType,
        reportDate: String,
        vendorNumber: String,
        version: String? = nil
    ) async throws -> SalesReport {
        var query: [String: String] = [
            "filter[frequency]": frequency.rawValue,
            "filter[reportType]": reportType.rawValue,
            "filter[reportSubType]": reportSubType.rawValue,
            "filter[reportDate]": reportDate,
            "filter[vendorNumber]": vendorNumber,
        ]
        if let version, !version.isEmpty {
            query["filter[version]"] = version
        }
        let body = try await ReportsHTTP.fetchBinary(
            client: client,
            relativePath: "salesReports",
            query: query
        )
        let decoded = try ReportsHTTP.gunzip(body)
        guard let tsv = String(data: decoded, encoding: .utf8) else {
            throw ReportsError.parseFailed(reason: "sales report is not utf-8")
        }
        let (headers, rows) = ReportsHTTP.parseDelimited(tsv, delimiter: "\t")
        let salesRows = rows.map { record -> SalesRow in
            var dict: [String: String] = [:]
            for (i, h) in headers.enumerated() where i < record.count {
                dict[h] = record[i]
            }
            return SalesRow(fields: dict)
        }
        return SalesReport(headers: headers, rows: salesRows, rawBytes: body.count)
    }
}

// MARK: - Finance reports

/// `GET /v1/financeReports` — returns a gzipped CSV body keyed by region.
/// One report covers one calendar month per region; Apple aggregates revenue
/// across all apps tied to that vendorNumber.
package struct FinanceAPI {
    package let client: ASCClient

    package init(client: ASCClient) { self.client = client }

    package enum ReportType: String, Sendable, CaseIterable {
        case financial = "FINANCIAL"
        case financeDetail = "FINANCE_DETAIL"
    }

    package struct FinanceRow: Sendable, Codable {
        package let fields: [String: String]
        package init(fields: [String: String]) { self.fields = fields }
    }

    package struct FinanceReport: Sendable, Codable {
        package let headers: [String]
        package let rows: [FinanceRow]
        package let rawBytes: Int
        package var isEmpty: Bool { rows.isEmpty }
    }

    /// Hits `GET /v1/financeReports`. `regionCode` is the Apple-defined
    /// market region (e.g. `"US"`, `"EU"`, `"JP"`, `"ZZ"`), `reportDate`
    /// is `YYYY-MM`, and `reportType` defaults to financial.
    package func getReport(
        regionCode: String,
        reportDate: String,
        vendorNumber: String,
        reportType: ReportType = .financial
    ) async throws -> FinanceReport {
        let query: [String: String] = [
            "filter[regionCode]": regionCode,
            "filter[reportDate]": reportDate,
            "filter[reportType]": reportType.rawValue,
            "filter[vendorNumber]": vendorNumber,
        ]
        let body = try await ReportsHTTP.fetchBinary(
            client: client,
            relativePath: "financeReports",
            query: query
        )
        let decoded = try ReportsHTTP.gunzip(body)
        guard let csv = String(data: decoded, encoding: .utf8) else {
            throw ReportsError.parseFailed(reason: "finance report is not utf-8")
        }
        let (headers, rows) = ReportsHTTP.parseDelimited(csv, delimiter: ",")
        let financeRows = rows.map { record -> FinanceRow in
            var dict: [String: String] = [:]
            for (i, h) in headers.enumerated() where i < record.count {
                dict[h] = record[i]
            }
            return FinanceRow(fields: dict)
        }
        return FinanceReport(headers: headers, rows: financeRows, rawBytes: body.count)
    }
}

// MARK: - App Analytics

/// The newer App Analytics API. The download flow is four levels deep:
///
///   1. Create or look up an `analyticsReportRequest` for the app
///      (`ONE_TIME_SNAPSHOT` or `ONGOING`).
///   2. List the `analyticsReports` exposed by that request (each one is a
///      report category such as "App Store Engagement").
///   3. List `analyticsReportInstances` per report (each instance is a
///      date-windowed snapshot Apple has finished assembling).
///   4. List `analyticsReportSegments` per instance and download the signed
///      `url` on each segment to get the gzipped CSV payload.
package struct AnalyticsAPI {
    package let client: ASCClient

    package init(client: ASCClient) { self.client = client }

    /// Access mode for an analytics report request. `ONE_TIME_SNAPSHOT`
    /// produces a single snapshot tied to the creation date; `ONGOING`
    /// emits a fresh instance each granularity period.
    package enum AccessType: String, Sendable, CaseIterable {
        case oneTimeSnapshot = "ONE_TIME_SNAPSHOT"
        case ongoing = "ONGOING"
    }

    package struct ReportRequest: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package struct Attributes: Codable, Sendable {
            package let accessType: String?
            package let stoppedDueToInactivity: Bool?
        }
    }

    /// POST `/v1/analyticsReportRequests` to spin up a new report-request
    /// against an app. Returns the request id callers feed into
    /// `listReports`.
    package func createReportRequest(
        appID: String,
        accessType: AccessType
    ) async throws -> ReportRequest {
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "analyticsReportRequests"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable { let accessType: String }
            struct Rels: Encodable {
                struct A: Encodable {
                    struct Data: Encodable { let type = "apps"; let id: String }
                    let data: Data
                }
                let app: A
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(accessType: accessType.rawValue),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: ReportRequest }
        let resp: Resp = try await client.post(
            path: "analyticsReportRequests",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    /// GET a single report-request by id.
    package func getReportRequest(id: String) async throws -> ReportRequest {
        struct Resp: Decodable { let data: ReportRequest }
        let resp: Resp = try await client.get(
            path: "analyticsReportRequests/\(id)",
            as: Resp.self
        )
        return resp.data
    }

    /// List every report-request attached to an app. Useful when callers
    /// want to reuse an existing ONGOING request rather than create a new
    /// snapshot every time.
    package func listReportRequests(appID: String) async throws -> [ReportRequest] {
        struct Resp: Decodable { let data: [ReportRequest] }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/analyticsReportRequests",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    /// DELETE `/v1/analyticsReportRequests/{id}`. Tears down an ongoing
    /// request so Apple stops emitting fresh instances.
    package func deleteReportRequest(id: String) async throws {
        try await client.delete(path: "analyticsReportRequests/\(id)")
    }

    package struct Report: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package struct Attributes: Codable, Sendable {
            package let name: String?
            package let category: String?
        }
    }

    /// Lists reports exposed by a given request. Each report represents a
    /// category of analytics (engagement, downloads, etc.) the request has
    /// access to.
    package func listReports(requestID: String) async throws -> [Report] {
        struct Resp: Decodable { let data: [Report] }
        let resp: Resp = try await client.get(
            path: "analyticsReportRequests/\(requestID)/reports",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    /// GET a single report by id.
    package func getReport(id: String) async throws -> Report {
        struct Resp: Decodable { let data: Report }
        let resp: Resp = try await client.get(
            path: "analyticsReports/\(id)",
            as: Resp.self
        )
        return resp.data
    }

    package struct ReportInstance: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package struct Attributes: Codable, Sendable {
            /// `DAILY`, `WEEKLY`, `MONTHLY` — Apple uses these to bucket
            /// instances by reporting granularity.
            package let granularity: String?
            /// `YYYY-MM-DD` boundary date for the window.
            package let processingDate: String?
        }
    }

    /// Lists instances for a report. Each instance is a finished snapshot
    /// for one date window; callers pick the most recent instance whose
    /// granularity matches what they want to query.
    package func listInstances(reportID: String) async throws -> [ReportInstance] {
        struct Resp: Decodable { let data: [ReportInstance] }
        let resp: Resp = try await client.get(
            path: "analyticsReports/\(reportID)/instances",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    /// GET a single instance by id.
    package func getInstance(id: String) async throws -> ReportInstance {
        struct Resp: Decodable { let data: ReportInstance }
        let resp: Resp = try await client.get(
            path: "analyticsReportInstances/\(id)",
            as: Resp.self
        )
        return resp.data
    }

    package struct Segment: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package struct Attributes: Codable, Sendable {
            /// Pre-signed URL pointing at the gzipped CSV payload. Lives
            /// outside Apple's main API host; do NOT prefix with /v1 or
            /// reuse the JWT auth header against this URL.
            package let url: String?
            package let sizeInBytes: Int?
            package let checksum: String?
        }
    }

    /// Lists segments for an instance. Each segment is a separate gzipped
    /// CSV slice — Apple chunks large reports across multiple segments.
    package func listSegments(instanceID: String) async throws -> [Segment] {
        struct Resp: Decodable { let data: [Segment] }
        let resp: Resp = try await client.get(
            path: "analyticsReportInstances/\(instanceID)/segments",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    /// GET a single segment by id (cheap way to refresh the signed URL
    /// after it's expired without re-listing the whole instance).
    package func getSegment(id: String) async throws -> Segment {
        struct Resp: Decodable { let data: Segment }
        let resp: Resp = try await client.get(
            path: "analyticsReportSegments/\(id)",
            as: Resp.self
        )
        return resp.data
    }

    package struct SegmentData: Sendable, Codable {
        package let headers: [String]
        package let rows: [[String: String]]
        package let rawBytes: Int
    }

    /// Downloads + decompresses + parses a segment given its signed URL.
    /// The URL Apple hands back already carries its own short-lived auth in
    /// the query string, so we use a plain URLSession request without the
    /// JWT header (sending Bearer here would actually cause an HTTP 400 on
    /// some segment hosts).
    package func downloadSegment(url: String) async throws -> SegmentData {
        guard let urlObj = URL(string: url) else {
            throw ReportsError.parseFailed(reason: "invalid segment url: \(url)")
        }
        let req = URLRequest(url: urlObj)
        let (data, response) = try await client.session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ReportsError.httpFailure(statusCode: -1, body: "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReportsError.httpFailure(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let decoded = try ReportsHTTP.gunzip(data)
        guard let csv = String(data: decoded, encoding: .utf8) else {
            throw ReportsError.parseFailed(reason: "segment is not utf-8")
        }
        let (headers, records) = ReportsHTTP.parseDelimited(csv, delimiter: ",")
        let rows = records.map { record -> [String: String] in
            var dict: [String: String] = [:]
            for (i, h) in headers.enumerated() where i < record.count {
                dict[h] = record[i]
            }
            return dict
        }
        return SegmentData(headers: headers, rows: rows, rawBytes: data.count)
    }
}

// MARK: - Performance metrics + diagnostic signatures

/// Thin wrapper over the `perfPowerMetrics` and `diagnosticSignatures`
/// resources. These come back as JSON so they go through ASCClient's normal
/// path — no gunzip needed.
package struct MetricsAPI {
    package let client: ASCClient

    package init(client: ASCClient) { self.client = client }

    package struct PerfPowerMetric: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package struct Attributes: Codable, Sendable {
            package let platform: String?
            package let metricCategory: String?
            package let goalKeys: [String]?
        }
    }

    /// Returns per-build performance + power metric snapshots. Apple
    /// exposes these per build for telemetry diffing across versions.
    package func listPerfPowerMetricsForApp(appID: String) async throws -> [PerfPowerMetric] {
        struct Resp: Decodable { let data: [PerfPowerMetric] }
        let resp: Resp = try await client.get(
            path: "apps/\(appID)/perfPowerMetrics",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    package func listPerfPowerMetricsForBuild(buildID: String) async throws -> [PerfPowerMetric] {
        struct Resp: Decodable { let data: [PerfPowerMetric] }
        let resp: Resp = try await client.get(
            path: "builds/\(buildID)/perfPowerMetrics",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    package struct DiagnosticSignature: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package struct Attributes: Codable, Sendable {
            package let diagnosticType: String?
            package let signature: String?
            package let weight: Double?
        }
    }

    /// Lists diagnostic signatures (crashes, hangs, disk writes, etc.)
    /// rolled up per build. Use `getDiagnosticSignature` with
    /// `includeLogs: true` to pull the raw signature logs for the crash
    /// reporter.
    package func listDiagnosticSignatures(buildID: String) async throws -> [DiagnosticSignature] {
        struct Resp: Decodable { let data: [DiagnosticSignature] }
        let resp: Resp = try await client.get(
            path: "builds/\(buildID)/diagnosticSignatures",
            query: ["limit": "200"],
            as: Resp.self
        )
        return resp.data
    }

    package struct DiagnosticSignatureDetail: Codable, Sendable {
        package let id: String
        package let attributes: DiagnosticSignature.Attributes?
        /// Apple returns related `diagnosticLogs` either inline (with
        /// `include=logs`) or as a separate fetch. When inline they come
        /// back under a top-level `included` array which the consumer of
        /// this struct can pull off ASCClient's JSON envelope. We surface
        /// the parsed attributes here so the common case (just the
        /// signature metadata) needs only one round-trip.
        package init(id: String, attributes: DiagnosticSignature.Attributes?) {
            self.id = id
            self.attributes = attributes
        }
    }

    package func getDiagnosticSignature(
        id: String,
        includeLogs: Bool = false
    ) async throws -> DiagnosticSignatureDetail {
        struct Resp: Decodable {
            struct D: Decodable {
                let id: String
                let attributes: DiagnosticSignature.Attributes?
            }
            let data: D
        }
        var query: [String: String] = [:]
        if includeLogs {
            query["include"] = "logs"
        }
        let resp: Resp = try await client.get(
            path: "diagnosticSignatures/\(id)",
            query: query,
            as: Resp.self
        )
        return DiagnosticSignatureDetail(id: resp.data.id, attributes: resp.data.attributes)
    }
}

// MARK: - HTTP + gzip + delimited parsing helpers

/// Implementation detail shared across SalesAPI / FinanceAPI / AnalyticsAPI.
/// Pulled out so each API namespace stays compact. The binary fetcher mints a
/// JWT through ASCClient's credentials and goes around ASCClient's JSON-only
/// `get(path:as:)` because Apple's reporting endpoints stream a gzipped file
/// body (HTTP `200 OK` with `Content-Encoding: agzip`-style payloads or
/// straight binary), not a JSON:API envelope.
enum ReportsHTTP {

    /// Fetches a binary report body from the v1 host using the credentials
    /// from ASCClient. Returns the raw response data (still gzipped) plus
    /// the HTTP status for callers that want to inspect headers. Surfaces
    /// non-2xx as `ReportsError.httpFailure` with the body for debugging.
    static func fetchBinary(
        client: ASCClient,
        relativePath: String,
        query: [String: String]
    ) async throws -> Data {
        // Build URL by hand. ASCClient.baseURL already ends in /v1, so we
        // append the relative path and tack on query items.
        guard var comps = URLComponents(
            url: client.baseURL.appendingPathComponent(relativePath),
            resolvingAgainstBaseURL: false
        ) else {
            throw ReportsError.parseFailed(reason: "could not build report URL")
        }
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else {
            throw ReportsError.parseFailed(reason: "could not finalize report URL")
        }
        // Mint a one-shot JWT for this request. ASCClient caches one
        // internally but it's private, so we mint a fresh token here. The
        // overhead is negligible compared to the report download itself.
        let token = try ASCJWTSigner.sign(credentials: client.credentials)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Apple sends gzipped content regardless of Accept, so we request
        // the application/a-gzip body explicitly to match their docs.
        req.setValue("application/a-gzip", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ReportsError.httpFailure(statusCode: -1, body: "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReportsError.httpFailure(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<binary>"
            )
        }
        return data
    }

    /// Shells out to `/usr/bin/gunzip -c` over the byte buffer. We prefer
    /// gunzip-via-Process over the Compression framework here because Apple's
    /// reporting payloads are full gzip streams (10-byte header + 8-byte CRC
    /// trailer) and `compression_decode_buffer(..., COMPRESSION_ZLIB)` only
    /// decodes raw deflate — getting it to consume Apple's gzip wrapper
    /// requires stripping the header by hand and ignoring the trailer, which
    /// trades reliability for code volume. gunzip ships on every macOS host
    /// in /usr/bin and handles every variant Apple has emitted.
    static func gunzip(_ data: Data) throws -> Data {
        // Empty input is valid (Apple returns 200 with no body on quiet
        // days). Skip the subprocess overhead.
        guard !data.isEmpty else { return Data() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: data)
        try stdin.fileHandleForWriting.close()
        let decoded = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: errData, encoding: .utf8) ?? "(unknown)"
            throw ReportsError.gunzipFailed(stderr: err)
        }
        return decoded
    }

    /// Minimal RFC 4180-flavored delimited parser. Handles quoted fields,
    /// escaped double-quotes (`""`), and embedded delimiter/newlines inside
    /// quoted values. Apple's reports are well-behaved but the parser stays
    /// strict so a malformed cell doesn't silently splice neighbors together.
    /// Returns the header row plus an array of records.
    static func parseDelimited(_ text: String, delimiter: Character) -> ([String], [[String]]) {
        let rows = parseRecords(text, delimiter: delimiter)
        guard let first = rows.first else { return ([], []) }
        let headers = first.map { $0.trimmingCharacters(in: .whitespaces) }
        let body = Array(rows.dropFirst())
        return (headers, body)
    }

    private static func parseRecords(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false
        // Walk by index so we can look one char ahead without mutating an
        // iterator. Apple's reports are typically <10MB after gunzip; the
        // String.Index walk is fine for those sizes.
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    // Look ahead for an escaped quote ("") inside a quoted
                    // field. If the next char is another quote, it's a
                    // literal quote; otherwise this quote closes the field.
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                } else {
                    field.append(ch)
                    i += 1
                    continue
                }
            }
            switch ch {
            case "\"":
                inQuotes = true
            case delimiter:
                current.append(field)
                field = ""
            case "\n":
                current.append(field)
                field = ""
                // Skip emitting completely blank lines (e.g. trailing \n).
                if !(current.count == 1 && current[0].isEmpty) {
                    rows.append(current)
                }
                current = []
            case "\r":
                // Tolerate \r\n by ignoring the carriage return.
                break
            default:
                field.append(ch)
            }
            i += 1
        }
        // Flush trailing field/record (file may not end with newline).
        if !field.isEmpty || !current.isEmpty {
            current.append(field)
            rows.append(current)
        }
        return rows
    }
}
