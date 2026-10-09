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

    var usesCustomRange: Bool { from != nil && to != nil }
    /// Human label for the header; the concrete dates always come from the server.
    var rangeLabel: String { usesCustomRange ? "custom" : period.label }
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

        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            switch token {
            case "--json":
                guard !options.json else { throw UsageArgumentError.duplicateOption(token) }
                options.json = true
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
    static func requestPayload(_ options: UsageOptions) -> [String: String] {
        var payload: [String: String] = [
            "command": "usage",
            "group": options.group.rawValue,
            "limit": String(options.limit),
        ]
        if let from = options.from, let to = options.to {
            payload["from"] = from
            payload["to"] = to
        } else {
            payload["period"] = options.period.rawValue
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

// MARK: - Response parsing

enum UsageResponseError: Error, LocalizedError, Equatable {
    /// The running app predates the `usage` command (old handler replies "unknown command").
    case unsupportedServer
    case server(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedServer:
            return "the running EZ Switch does not support usage; update and restart the app, then try again"
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
}

enum UsageResponseParser {
    static func parse(_ data: Data) throws -> ParsedUsage {
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
        do {
            let report = try JSONDecoder().decode(UsageReport.self, from: usageData)
            return ParsedUsage(report: report, jsonObject: usage)
        } catch {
            throw UsageResponseError.invalidResponse("unexpected usage shape")
        }
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
                [--group route|provider|model] [--limit N] [--json]
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
      --json                           Print the raw usage object as JSON.

    Dates use the local calendar; --to is inclusive. 7d covers today and the six
    preceding days. EZ Switch must be running. Provider names or model IDs
    containing spaces should be quoted.
    """

    static let usage = """
    Usage:
      ezs usage [--period today|7d|month] [--from YYYY-MM-DD --to YYYY-MM-DD]
                [--group route|provider|model] [--limit N] [--json]

    Show token usage recorded by EZ Switch for a time range.

    Options:
      --period <today|7d|month>        Time range preset. Default: today.
      --from <YYYY-MM-DD>              Custom start date (inclusive).
      --to <YYYY-MM-DD>                Custom end date (inclusive).
      --group <route|provider|model>   How to group results. Default: route.
      --limit <1-1000>                 Maximum groups to show. Default: 100.
      --json                           Print the raw usage object as JSON.
      -h, --help                       Show this help.

    --from and --to must be provided together and cannot be combined with --period.
    Dates use the local calendar; --to is inclusive. 7d covers today and the six
    preceding days. EZ Switch must be running.
    """
}
