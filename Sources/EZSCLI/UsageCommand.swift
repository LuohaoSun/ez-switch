import Foundation

// MARK: - Options

/// `--period` presets. `7d` covers today and the six preceding local calendar days.
enum UsagePeriod: String, CaseIterable, Equatable {
    case today
    case last7Days = "7d"
    case month

    var label: String { rawValue }
}

/// `--group` values.
enum UsageGrouping: String, CaseIterable, Equatable {
    case route
    case provider
    case model

    var label: String { rawValue }
}

struct UsageOptions: Equatable {
    var period: UsagePeriod = .today
    var group: UsageGrouping = .route
    var limit: Int = 100
    var from: String? = nil
    var to: String? = nil
    var json: Bool = false
    /// `--performance` adds TTFT/TPS statistics to the request.
    var performance: Bool = false
    /// Whether `--group` was given explicitly; drives the performance default.
    var groupExplicitlySet: Bool = false

    var usesCustomRange: Bool { from != nil && to != nil }
    /// Human label for the header; the concrete dates always come from the server.
    var rangeLabel: String { usesCustomRange ? "custom" : period.label }

    /// Performance stats default to per-model grouping; the plain usage report keeps
    /// its route default. An explicit `--group` always wins.
    var effectiveGroup: UsageGrouping {
        groupExplicitlySet ? group : (performance ? .model : group)
    }
}

// MARK: - Argument parsing

enum UsageArgumentError: Error, LocalizedError, Equatable {
    case unknownOption(String)
    case missingValue(String)
    case duplicateOption(String)
    case invalidValue(option: String, value: String, expected: String)
    case incompleteRange
    case periodAndRangeConflict
    case unexpectedArgument(String)

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option):
            return "unknown option '\(option)' for usage. Run ezs usage --help."
        case .missingValue(let option):
            return "option '\(option)' requires a value. Run ezs usage --help."
        case .duplicateOption(let option):
            return "option '\(option)' was given more than once. Run ezs usage --help."
        case .invalidValue(let option, let value, let expected):
            return "invalid value '\(value)' for \(option); expected \(expected). Run ezs usage --help."
        case .incompleteRange:
            return "--from and --to must be provided together. Run ezs usage --help."
        case .periodAndRangeConflict:
            return "--period cannot be combined with --from/--to. Run ezs usage --help."
        case .unexpectedArgument(let argument):
            return "unexpected argument '\(argument)'. Run ezs usage --help."
        }
    }
}

enum UsageArgumentParser {
    private static let dateShape = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    private static let digitShape = "^[0-9]+$"

    static let limitRange = 1...1000

    /// Strict shape check only (`YYYY-MM-DD`); the server is authoritative for
    /// whether the date actually exists, so the CLI never applies different rules.
    static func isValidDateShape(_ value: String) -> Bool {
        value.range(of: dateShape, options: .regularExpression) != nil
    }

    static func parse(_ arguments: [String]) throws -> UsageOptions {
        var options = UsageOptions()
        var sawPeriod = false
        var sawGroup = false
        var sawLimit = false
        var sawFrom = false
        var sawTo = false
        var sawPerformance = false

        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            switch token {
            case "--json":
                guard !options.json else { throw UsageArgumentError.duplicateOption(token) }
                options.json = true
                index += 1

            case "--performance":
                guard !sawPerformance else { throw UsageArgumentError.duplicateOption(token) }
                sawPerformance = true
                options.performance = true
                index += 1

            case "--period", "--group", "--limit", "--from", "--to":
                guard index + 1 < arguments.count else {
                    throw UsageArgumentError.missingValue(token)
                }
                let value = arguments[index + 1]
                switch token {
                case "--period":
                    guard !sawPeriod else { throw UsageArgumentError.duplicateOption(token) }
                    sawPeriod = true
                    guard let period = UsagePeriod(rawValue: value) else {
                        throw UsageArgumentError.invalidValue(option: token, value: value,
                                                              expected: "today, 7d or month")
                    }
                    options.period = period

                case "--group":
                    guard !sawGroup else { throw UsageArgumentError.duplicateOption(token) }
                    sawGroup = true
                    guard let group = UsageGrouping(rawValue: value) else {
                        throw UsageArgumentError.invalidValue(option: token, value: value,
                                                              expected: "route, provider or model")
                    }
                    options.group = group
                    options.groupExplicitlySet = true

                case "--limit":
                    guard !sawLimit else { throw UsageArgumentError.duplicateOption(token) }
                    sawLimit = true
                    guard value.range(of: digitShape, options: .regularExpression) != nil,
                          let limit = Int(value), limitRange.contains(limit) else {
                        throw UsageArgumentError.invalidValue(option: token, value: value,
                                                              expected: "an integer \(limitRange.lowerBound)–\(limitRange.upperBound)")
                    }
                    options.limit = limit

                case "--from":
                    guard !sawFrom else { throw UsageArgumentError.duplicateOption(token) }
                    sawFrom = true
                    guard isValidDateShape(value) else {
                        throw UsageArgumentError.invalidValue(option: token, value: value,
                                                              expected: "a date like YYYY-MM-DD")
                    }
                    options.from = value

                case "--to":
                    guard !sawTo else { throw UsageArgumentError.duplicateOption(token) }
                    sawTo = true
                    guard isValidDateShape(value) else {
                        throw UsageArgumentError.invalidValue(option: token, value: value,
                                                              expected: "a date like YYYY-MM-DD")
                    }
                    options.to = value

                default:
                    throw UsageArgumentError.unknownOption(token)
                }
                index += 2

            default:
                if token.hasPrefix("--") {
                    throw UsageArgumentError.unknownOption(token)
                }
                throw UsageArgumentError.unexpectedArgument(token)
            }
        }

        if (options.from == nil) != (options.to == nil) {
            throw UsageArgumentError.incompleteRange
        }
        if sawPeriod && options.usesCustomRange {
            throw UsageArgumentError.periodAndRangeConflict
        }
        return options
    }

    /// Request payload for the `usage` command. `json` is a local-only flag and is
    /// deliberately never sent; values are strings per the control protocol.
    /// `performance` is sent only when requested, so older apps keep replying with
    /// the unchanged usage payload.
    static func requestPayload(_ options: UsageOptions) -> [String: String] {
        var payload: [String: String] = [
            "command": "usage",
            "group": options.effectiveGroup.rawValue,
            "limit": String(options.limit),
        ]
        if let from = options.from, let to = options.to {
            payload["from"] = from
            payload["to"] = to
        } else {
            payload["period"] = options.period.rawValue
        }
        if options.performance {
            payload["performance"] = "true"
        }
        return payload
    }
}

// MARK: - Response models

struct UsageReportRange: Decodable, Equatable {
    var from: String
    var to: String
    var start: String
    var endExclusive: String
    var timeZone: String
}

struct UsageReportTotals: Decodable, Equatable {
    var input: Int
    var output: Int
    var cachedInput: Int
    var cacheWrite: Int
    var reasoning: Int
    var requests: Int
    var attempts: Int
    var knownAttempts: Int
    var inputAttempts: Int
    var outputAttempts: Int
    var cachedInputAttempts: Int
    var failedAttempts: Int
    var total: Int
    var coverage: Double
}

struct UsageReportDay: Decodable, Equatable {
    var date: String
    var input: Int
    var output: Int
}

struct UsageReportGroup: Decodable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var totals: UsageReportTotals
}

struct UsageReport: Decodable, Equatable {
    var range: UsageReportRange
    var grouping: String
    var limit: Int
    var groupCount: Int
    var truncated: Bool
    var totals: UsageReportTotals
    var days: [UsageReportDay]
    var groups: [UsageReportGroup]
}

// MARK: - Performance report models

/// The optional `performance` object returned alongside `usage` when it is requested.
///
/// Metrics are averages (not percentiles). Older payloads predate the mean fields
/// entirely and are rejected up-front by key presence, so a present-but-null value
/// here always means "measured, no valid sample" rather than "old server".
struct PerformanceReportSummary: Decodable, Equatable {
    var attempts: Int
    var successfulStreamingAttempts: Int
    var ttftSamples: Int
    /// Optional so a payload that omits it still decodes; a missing value is never
    /// substituted with the upstream attempt sample count.
    var requestTTFTSamples: Int?
    var tpsSamples: Int
    /// Average first-output latency (ms) of upstream attempts.
    var ttftMeanMS: Double?
    /// Average request-level first-output latency (ms), including fallback waiting.
    var requestTTFTMeanMS: Double?
    /// Average output throughput (tok/s) counting TTFT in the window.
    var tpsIncludingTTFT: Double?
    /// Request-scope variant of `tpsIncludingTTFT`, including fallback waiting.
    var requestTpsIncludingTTFT: Double?
    /// Average output throughput (tok/s) over generation time only, excluding TTFT.
    var tpsExcludingTTFT: Double?
}

struct PerformanceReportGroup: Decodable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var summary: PerformanceReportSummary
}

struct PerformanceReport: Decodable, Equatable {
    var grouping: String
    var limit: Int
    var groupCount: Int
    var truncated: Bool
    var summary: PerformanceReportSummary
    var groups: [PerformanceReportGroup]
}

// MARK: - Response parsing

enum UsageResponseError: Error, LocalizedError, Equatable {
    /// The running app predates the `usage` command (old handler replies "unknown command").
    case unsupportedServer
    /// The running app answered `usage` but ignores `performance`, so it predates
    /// performance stats. We say so rather than reporting zeros.
    case performanceUnsupported
    /// The running app returns a `performance` object but only the old percentile
    /// fields, so it predates the average metrics. Reported as an update hint instead
    /// of decoding every new field as silently nil.
    case performanceStatsUnsupported
    case server(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedServer:
            return "the running EZ Switch does not support usage; update and restart the app, then try again"
        case .performanceUnsupported:
            return "the running EZ Switch does not support performance stats; update and restart the app, then try again"
        case .performanceStatsUnsupported:
            return "the running EZ Switch does not report average performance metrics; update and restart the app, then try again"
        case .server(let message):
            return message
        case .invalidResponse(let detail):
            return "invalid usage response from EZ Switch: \(detail)"
        }
    }
}

struct ParsedUsage {
    /// Typed view for the text renderer.
    var report: UsageReport
    /// Raw `usage` object, re-encoded verbatim for `--json`.
    var jsonObject: Any
    /// Typed performance view; only present when `--performance` was requested and the
    /// server returned it.
    var performance: PerformanceReport?
    /// Raw `performance` object, re-encoded verbatim for `--json`.
    var performanceJSONObject: Any?
}

enum UsageResponseParser {
    /// - Parameter expectPerformance: when true (the CLI sent `--performance`), a
    ///   response without a `performance` object means the app is too old to know it,
    ///   which is surfaced as `performanceUnsupported` rather than silent zeros.
    static func parse(_ data: Data, expectPerformance: Bool = false) throws -> ParsedUsage {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageResponseError.invalidResponse("response is not a JSON object")
        }
        let ok = (object["ok"] as? Bool) ?? false
        guard ok else {
            let message = (object["message"] as? String) ?? "usage request failed"
            if message.lowercased().contains("unknown command") {
                throw UsageResponseError.unsupportedServer
            }
            throw UsageResponseError.server(message)
        }
        guard let usage = object["usage"] as? [String: Any] else {
            throw UsageResponseError.invalidResponse("response is missing the usage object")
        }
        let usageData: Data
        do {
            usageData = try JSONSerialization.data(withJSONObject: usage)
        } catch {
            throw UsageResponseError.invalidResponse("usage object is not serializable")
        }
        let report: UsageReport
        do {
            report = try JSONDecoder().decode(UsageReport.self, from: usageData)
        } catch {
            throw UsageResponseError.invalidResponse("unexpected usage shape")
        }

        var performance: PerformanceReport?
        var performanceObject: Any?
        if expectPerformance {
            guard let raw = object["performance"] as? [String: Any] else {
                throw UsageResponseError.performanceUnsupported
            }
            // A server that predates the average metrics still returns a `performance`
            // object, but only the old percentile fields; decoding would leave every
            // new field nil. Detect the absent keys on the raw JSON so the old server
            // reads as an update hint, while a new server's all-nil payload (no valid
            // samples) stays valid because its keys are present as null.
            guard hasAverageMetrics(raw) else {
                throw UsageResponseError.performanceStatsUnsupported
            }
            do {
                let performanceData = try JSONSerialization.data(withJSONObject: raw)
                performance = try JSONDecoder().decode(PerformanceReport.self, from: performanceData)
            } catch {
                throw UsageResponseError.invalidResponse("unexpected performance shape")
            }
            performanceObject = raw
        }
        return ParsedUsage(report: report, jsonObject: usage,
                           performance: performance, performanceJSONObject: performanceObject)
    }

    /// Keys introduced with the average metrics. New payloads always include them
    /// (serialised as null when unmeasured), so their presence marks a mean-capable
    /// server; a payload carrying only the old percentile fields does not.
    static let averageMetricKeys = [
        "ttftMeanMS", "requestTTFTMeanMS", "tpsIncludingTTFT",
        "requestTpsIncludingTTFT", "tpsExcludingTTFT",
    ]

    /// True when the summary or any group summary carries at least one average-metric
    /// key. Presence is checked on the raw JSON, not the decoded value.
    static func hasAverageMetrics(_ performance: [String: Any]) -> Bool {
        var summaries: [[String: Any]] = []
        if let summary = performance["summary"] as? [String: Any] { summaries.append(summary) }
        for group in (performance["groups"] as? [[String: Any]]) ?? [] {
            if let summary = group["summary"] as? [String: Any] { summaries.append(summary) }
        }
        for summary in summaries where averageMetricKeys.contains(where: { summary[$0] != nil }) {
            return true
        }
        return false
    }
}

// MARK: - Text / JSON rendering

enum UsageTextFormatter {
    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Percentage with one decimal, clamped to a sane 0–100% for display.
    static func percent(_ coverage: Double) -> String {
        let value = coverage.isFinite ? min(max(coverage, 0), 1) : 0
        return String(format: "%.1f%%", value * 100)
    }

    /// Escapes control characters (C0/C1 and DEL) so upstream-supplied names can
    /// never inject terminal escape sequences. Visible characters are kept as-is.
    static func sanitize(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
                    output += String(format: "\\u{%02X}", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }

    static func coverageLine(_ totals: UsageReportTotals) -> String {
        "\(count(totals.knownAttempts))/\(count(totals.attempts)) attempts (\(percent(totals.coverage)))"
    }

    static func render(_ report: UsageReport, options: UsageOptions) -> String {
        let from = sanitize(report.range.from)
        let to = sanitize(report.range.to)
        var lines = [
            "Usage from \(from) to \(to) (\(options.rangeLabel))",
            "Time zone: \(sanitize(report.range.timeZone))",
        ]

        // An empty range is a complete, valid zero — not missing data.
        if report.totals.attempts == 0 {
            lines.append("")
            lines.append("No usage recorded from \(from) to \(to).")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append(contentsOf: totalsLines(report.totals))

        if !report.days.isEmpty {
            lines.append("")
            lines.append("Days")
            for day in report.days {
                lines.append("  \(sanitize(day.date))  input \(count(day.input))  output \(count(day.output))")
            }
        }

        lines.append("")
        lines.append(groupsHeading(report))
        if report.groups.isEmpty {
            lines.append("  (none)")
        } else {
            for group in report.groups {
                lines.append(contentsOf: groupLines(group))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func renderJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageResponseError.invalidResponse("usage object is not valid UTF-8")
        }
        return text
    }

    /// `--json --performance` prints both objects so the existing usage contract is
    /// preserved and the optional `performance` object is added alongside it.
    static func renderCombinedJSON(usage: Any, performance: Any) throws -> String {
        let combined: [String: Any] = ["usage": usage, "performance": performance]
        let data = try JSONSerialization.data(withJSONObject: combined, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageResponseError.invalidResponse("usage object is not valid UTF-8")
        }
        return text
    }

    // MARK: Performance rendering

    /// Explicit unit for a millisecond value: sub-second reads in ms, otherwise seconds.
    static func duration(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
        return milliseconds < 1000 ? String(format: "%.0f ms", milliseconds)
                                   : String(format: "%.2f s", milliseconds / 1000)
    }

    static func rate(_ tokensPerSecond: Double?) -> String {
        guard let tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond >= 0 else { return "—" }
        return String(format: "%.1f tok/s", tokensPerSecond)
    }

    // Average metrics. The overall summary is always request scope
    // (requestTTFTMeanMS / requestTpsIncludingTTFT), matching the old overall
    // requestTTFT. Group rows follow the grouping: route -> request scope,
    // provider/model -> upstream attempt. TPS excluding TTFT is a single shared
    // field with no request/attempt distinction.

    private static func requestTTFTMean(_ summary: PerformanceReportSummary) -> Double? {
        summary.requestTTFTMeanMS
    }

    private static func requestTpsIncludingTTFT(_ summary: PerformanceReportSummary) -> Double? {
        summary.requestTpsIncludingTTFT
    }

    private static func groupTTFTMean(_ summary: PerformanceReportSummary, grouping: String) -> Double? {
        grouping == "route" ? summary.requestTTFTMeanMS : summary.ttftMeanMS
    }

    private static func groupTpsIncludingTTFT(_ summary: PerformanceReportSummary, grouping: String) -> Double? {
        grouping == "route" ? summary.requestTpsIncludingTTFT : summary.tpsIncludingTTFT
    }

    private static func tpsExcludingTTFT(_ summary: PerformanceReportSummary) -> Double? {
        summary.tpsExcludingTTFT
    }

    /// The sample count backing the TTFT metric for the active grouping. A missing
    /// `requestTTFTSamples` reads as 0, never as the upstream attempt count.
    private static func ttftSampleCount(_ summary: PerformanceReportSummary, grouping: String) -> Int {
        grouping == "route" ? (summary.requestTTFTSamples ?? 0) : summary.ttftSamples
    }

    private static func groupsBasisLine(grouping: String) -> String {
        grouping == "route" ? "request (includes fallback)" : "upstream attempt"
    }

    static func renderPerformance(_ report: PerformanceReport, options: UsageOptions) -> String {
        let grouping = report.grouping
        var lines = ["Performance (\(sanitize(grouping)))",
                     "Overall basis: request scope (includes fallback)"]

        // Always show the summary (with dashes for missing values) so "no samples" reads
        // as — rather than being hidden.
        lines.append("")
        lines.append("Summary")
        lines.append(contentsOf: performanceSummaryLines(report.summary, indent: "  "))

        if report.summary.attempts == 0 && report.groups.isEmpty {
            lines.append("")
            lines.append("No performance data recorded.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append(performanceGroupsHeading(report, grouping: grouping))
        if report.groups.isEmpty {
            lines.append("  (none)")
        } else {
            for group in report.groups {
                lines.append(contentsOf: performanceGroupLines(group, grouping: grouping))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func performanceSummaryLines(_ summary: PerformanceReportSummary,
                                                indent: String) -> [String] {
        [
            "\(indent)Attempts: \(count(summary.attempts))",
            "\(indent)Successful streaming: \(count(summary.successfulStreamingAttempts))/\(count(summary.attempts)) attempts",
            "\(indent)TTFT samples: \(count(summary.requestTTFTSamples ?? 0))  "
                + "TPS samples: \(count(summary.tpsSamples))",
            "\(indent)Average TTFT: \(duration(requestTTFTMean(summary)))",
            "\(indent)Average TPS (incl TTFT): \(rate(requestTpsIncludingTTFT(summary)))",
            "\(indent)Average TPS (excl TTFT): \(rate(tpsExcludingTTFT(summary)))",
        ]
    }

    private static func performanceGroupsHeading(_ report: PerformanceReport, grouping: String) -> String {
        var heading = "Groups — basis: \(groupsBasisLine(grouping: grouping))"
        if report.truncated {
            heading += " — showing \(report.groups.count) of \(report.groupCount) groups; raise --limit to see more"
        }
        return heading
    }

    private static func performanceGroupLines(_ group: PerformanceReportGroup, grouping: String) -> [String] {
        var header = "  " + sanitize(group.title)
        if !group.subtitle.isEmpty {
            header += " (\(sanitize(group.subtitle)))"
        }
        let summary = group.summary
        return [
            header,
            "    Attempts \(count(summary.attempts))  "
                + "Successful streaming \(count(summary.successfulStreamingAttempts))/\(count(summary.attempts)) attempts",
            "    TTFT samples \(count(ttftSampleCount(summary, grouping: grouping)))  "
                + "TPS samples \(count(summary.tpsSamples))",
            "    Average TTFT \(duration(groupTTFTMean(summary, grouping: grouping)))  "
                + "Average TPS (incl TTFT) \(rate(groupTpsIncludingTTFT(summary, grouping: grouping)))  "
                + "Average TPS (excl TTFT) \(rate(tpsExcludingTTFT(summary)))",
        ]
    }

    // MARK: Section builders

    private static func totalsLines(_ totals: UsageReportTotals) -> [String] {
        var lines = [
            "Totals",
            "  Input: \(count(totals.input))",
            "  Output: \(count(totals.output))",
            "  Total: \(count(totals.total))",
            "  Cached input: \(count(totals.cachedInput))",
            "  Cache write: \(count(totals.cacheWrite))",
            "  Reasoning: \(count(totals.reasoning))",
            "  Requests: \(count(totals.requests))",
            "  Attempts: \(count(totals.attempts))",
            "  Failed attempts: \(count(totals.failedAttempts))",
            "  Coverage: \(coverageLine(totals))",
            "    input reported \(count(totals.inputAttempts))/\(count(totals.attempts)), "
                + "output reported \(count(totals.outputAttempts))/\(count(totals.attempts)), "
                + "cached input reported \(count(totals.cachedInputAttempts))/\(count(totals.attempts))",
        ]
        if totals.knownAttempts < totals.attempts {
            lines.append("    Partial: some attempts reported no usage; "
                + "reported totals cover known values only and are not an estimate.")
        }
        return lines
    }

    private static func groupsHeading(_ report: UsageReport) -> String {
        var heading = "Groups (\(sanitize(report.grouping)))"
        if report.truncated {
            heading += " — showing \(report.groups.count) of \(report.groupCount) groups; raise --limit to see more"
        }
        return heading
    }

    private static func groupLines(_ group: UsageReportGroup) -> [String] {
        var header = "  " + sanitize(group.title)
        if !group.subtitle.isEmpty {
            header += " (\(sanitize(group.subtitle)))"
        }
        let totals = group.totals
        return [
            header,
            "    Input \(count(totals.input))  Output \(count(totals.output))  Total \(count(totals.total))",
            "    Requests \(count(totals.requests))  Attempts \(count(totals.attempts))  "
                + "Failed \(count(totals.failedAttempts))  Coverage \(coverageLine(totals))",
        ]
    }
}

// MARK: - Help

enum EZSCLIHelp {
    static let general = """
    Usage:
      ezs list
      ezs set <model-id> --provider <name> --model <upstream-model>
      ezs set <model-id> --remote-id <UUID>
      ezs usage [--period today|7d|month] [--from YYYY-MM-DD --to YYYY-MM-DD]
                [--group route|provider|model] [--limit N] [--performance] [--json]
      ezs help | -h | --help

    Commands:
      list    Show current routes and models grouped by provider.
      set     Switch a route to an upstream model and save it in EZ Switch.
      usage   Show token usage recorded by EZ Switch.

    Options:
      -h, --help    Show this help.

    Usage options:
      --period <today|7d|month>        Time range preset. Default: today.
      --from <YYYY-MM-DD>              Custom start date (inclusive); requires --to.
      --to <YYYY-MM-DD>                Custom end date (inclusive); requires --from.
      --group <route|provider|model>   How to group results. Default: route.
      --limit <1-1000>                 Maximum groups to show. Default: 100.
      --performance                    Add TTFT/TPS streaming performance stats.
      --json                           Print the raw usage object as JSON.

    Dates use the local calendar; --to is inclusive. 7d covers today and the six
    preceding days. EZ Switch must be running. Provider names or model IDs
    containing spaces should be quoted.
    """

    static let usage = """
    Usage:
      ezs usage [--period today|7d|month] [--from YYYY-MM-DD --to YYYY-MM-DD]
                [--group route|provider|model] [--limit N] [--performance] [--json]

    Show token usage recorded by EZ Switch for a time range.

    Options:
      --period <today|7d|month>        Time range preset. Default: today.
      --from <YYYY-MM-DD>              Custom start date (inclusive).
      --to <YYYY-MM-DD>                Custom end date (inclusive).
      --group <route|provider|model>   How to group results. Default: route.
      --limit <1-1000>                 Maximum groups to show. Default: 100.
      --performance                    Add TTFT/TPS streaming performance stats,
                                       grouped by model unless --group is given.
      --json                           Print the raw usage object as JSON.
      -h, --help                       Show this help.

    --from and --to must be provided together and cannot be combined with --period.
    Dates use the local calendar; --to is inclusive. 7d covers today and the six
    preceding days. EZ Switch must be running.
    """
}
