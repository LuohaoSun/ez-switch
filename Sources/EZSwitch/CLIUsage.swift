import Foundation

/// `usage` 命令的校验错误。message 面向 CLI 用户，只说明期望取值，
/// 绝不回显原始请求、密钥或用户自定义的长字符串。
struct CLIUsageError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// CLI `usage` 命令：严格解析请求、复用 GUI 的区间解析与 UsageStore 聚合，构造 JSON 响应。
///
/// 契约要点：
/// - 只读：仅调用 `UsageStore.snapshot`，不写数据库、不改配置。
/// - `period` 与 `from`/`to` 互斥；`from`/`to` 必须成对，严格 `YYYY-MM-DD` 且为真实本地日历日期。
/// - 起止倒置沿用 GUI 语义（交换后 end inclusive），时区用注入 calendar 的本地时区。
/// - `limit` 只截取 `groups`，`totals`/`days`/`groupCount` 始终是全范围统计，不截总量。
/// - 响应超过 1 MiB（含换行）时返回明确错误，绝不截断 JSON。
enum CLIUsage {
    /// UDS 响应上限（字节，含结尾换行）。
    static let maxResponseBytes = 1_048_576

    static let supportedPeriods = ["today", "7d", "month"]

    struct Request {
        var range: UsageDateRange
        var grouping: UsageGrouping
        var limit: Int
    }

    // MARK: - 解析

    static func parse(_ request: [String: Any], now: Date, calendar: Calendar) throws -> Request {
        // 键存在即视为显式提供并强制校验类型：`as? String` 失败一律报错，绝不当作省略。
        let period = try optionalString(request, "period") ?? "today"
        guard supportedPeriods.contains(period) else {
            throw CLIUsageError("invalid period: expected one of today, 7d, month")
        }
        let group = try optionalString(request, "group") ?? "route"
        guard let grouping = UsageGrouping(rawValue: group) else {
            throw CLIUsageError("invalid group: expected one of route, provider, model")
        }
        let limit = try parseLimit(try optionalString(request, "limit"))

        let hasFrom = request["from"] != nil
        let hasTo = request["to"] != nil
        if request["period"] != nil, hasFrom || hasTo {
            throw CLIUsageError("period cannot be combined with from/to")
        }
        if hasFrom != hasTo {
            throw CLIUsageError("from and to must be provided together")
        }

        let range: UsageDateRange
        if hasFrom {
            let from = try requiredString(request, "from")
            let to = try requiredString(request, "to")
            let start = try parseDate(from, calendar: calendar)
            let end = try parseDate(to, calendar: calendar)
            // 倒置起止交给 GUI 的 resolver 交换，结束日整天包含（end inclusive）。
            range = UsageRangeResolver.resolve(preset: .custom, customStart: start, customEnd: end,
                                               now: now, calendar: calendar)
        } else {
            let preset: UsageRangePreset
            switch period {
            case "today": preset = .today
            case "7d": preset = .last7Days
            case "month": preset = .thisMonth
            default: throw CLIUsageError("invalid period: expected one of today, 7d, month")
            }
            range = UsageRangeResolver.resolve(preset: preset, customStart: now, customEnd: now,
                                               now: now, calendar: calendar)
        }
        return Request(range: range, grouping: grouping, limit: limit)
    }

    /// 可选字符串：缺失返回 nil，存在但非字符串报错。
    private static func optionalString(_ request: [String: Any], _ key: String) throws -> String? {
        guard let raw = request[key] else { return nil }
        guard let value = raw as? String else {
            throw CLIUsageError("invalid \(key): expected a string")
        }
        return value
    }

    /// 必填字符串：键已确认存在，非字符串报错。
    private static func requiredString(_ request: [String: Any], _ key: String) throws -> String {
        guard let value = try optionalString(request, key) else {
            throw CLIUsageError("invalid \(key): expected a string")
        }
        return value
    }

    /// `limit` 为十进制字符串，取值 1...1000。
    private static func parseLimit(_ value: String?) throws -> Int {
        let raw = value ?? "100"
        guard !raw.isEmpty, raw.count <= 4,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let limit = Int(raw), (1...1000).contains(limit) else {
            throw CLIUsageError("invalid limit: expected an integer between 1 and 1000")
        }
        return limit
    }

    /// 严格 `YYYY-MM-DD`：固定宽度、全数字、且是真实本地日历日期（roundtrip 校验拒绝回退/归一化）。
    static func parseDate(_ value: String, calendar: Calendar) throws -> Date {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ part in part.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), year >= 1,
              let month = Int(parts[1]), let day = Int(parts[2]) else {
            throw CLIUsageError("invalid date: expected YYYY-MM-DD")
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            throw CLIUsageError("invalid date: expected YYYY-MM-DD")
        }
        // roundtrip：若被归一化（如 2026-02-30 → 3 月）或不存在，则拒绝。
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            throw CLIUsageError("invalid date: expected YYYY-MM-DD")
        }
        return calendar.startOfDay(for: date)
    }

    // MARK: - 响应

    static func makeReply(request: [String: Any], store: UsageStore,
                          now: Date = Date(), calendar: Calendar = .current) async -> [String: Any] {
        let parsed: Request
        do {
            parsed = try parse(request, now: now, calendar: calendar)
        } catch let error as CLIUsageError {
            return ["ok": false, "message": error.message]
        } catch {
            return ["ok": false, "message": "invalid usage request"]
        }

        let snapshot: UsageSnapshot
        do {
            snapshot = try await store.snapshot(from: parsed.range.from, to: parsed.range.to,
                                                grouping: parsed.grouping)
        } catch {
            return ["ok": false, "message": "usage query failed: \(error.localizedDescription)"]
        }

        let reply: [String: Any] = [
            "ok": true,
            "usage": payload(snapshot: snapshot, request: parsed, calendar: calendar),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else {
            return ["ok": false, "message": "usage response could not be encoded"]
        }
        if data.count + 1 > maxResponseBytes {
            return ["ok": false, "message": "usage response too large; reduce limit or narrow the date range"]
        }
        return reply
    }

    private static func payload(snapshot: UsageSnapshot, request: Request, calendar: Calendar) -> [String: Any] {
        let formatter = dayFormatter(calendar)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = calendar.timeZone

        let range: [String: Any] = [
            "from": formatter.string(from: request.range.from),
            "to": formatter.string(from: request.range.inclusiveEnd),
            "start": iso.string(from: request.range.from),
            "endExclusive": iso.string(from: request.range.to),
            "timeZone": calendar.timeZone.identifier,
        ]

        let days: [[String: Any]] = snapshot.days.map {
            ["date": formatter.string(from: $0.date), "input": $0.input, "output": $0.output]
        }

        // 只有 groups 按 limit 截取；groupCount/truncated 反映全量，totals/days 也是全量。
        let groupCount = snapshot.groups.count
        let groups: [[String: Any]] = snapshot.groups.prefix(request.limit).map {
            ["id": $0.id, "title": $0.title, "subtitle": $0.subtitle, "totals": totalsPayload($0.totals)]
        }

        return [
            "range": range,
            "grouping": request.grouping.rawValue,
            "limit": request.limit,
            "groupCount": groupCount,
            "truncated": groupCount > request.limit,
            "totals": totalsPayload(snapshot.totals),
            "days": days,
            "groups": groups,
        ]
    }

    private static func totalsPayload(_ totals: UsageTotals) -> [String: Any] {
        [
            "input": totals.input,
            "output": totals.output,
            "cachedInput": totals.cachedInput,
            "cacheWrite": totals.cacheWrite,
            "reasoning": totals.reasoning,
            "requests": totals.requests,
            "attempts": totals.attempts,
            "knownAttempts": totals.knownAttempts,
            "inputAttempts": totals.inputAttempts,
            "outputAttempts": totals.outputAttempts,
            "cachedInputAttempts": totals.cachedInputAttempts,
            "failedAttempts": totals.failedAttempts,
            "total": totals.total,
            "coverage": totals.coverage,
        ]
    }

    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

extension ConfigStore {
    /// 异步 CLI 调度：`usage` 需要 await snapshot（非阻塞地挂起，不占用主线程）；
    /// 其余 legacy 命令（list/set）仍走同步 `handleCLICommand`，保持既有行为。
    func handleCLICommandAsync(_ data: Data, now: Date = Date(),
                               calendar: Calendar = .current) async -> [String: Any] {
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = request["command"] as? String else {
            return ["ok": false, "message": "invalid command"]
        }
        if command == "usage" {
            return await CLIUsage.makeReply(request: request, store: usageStore,
                                            now: now, calendar: calendar)
        }
        return handleCLICommand(data)
    }
}
