import Foundation
import Testing
@testable import EZSwitch

/// 小时分桶（`UsageSnapshot.hours` / `snapshot(includeHourly:)`）的聚焦测试。
/// 只使用临时目录数据库，不触碰真实配置或用户数据。
@Suite("Usage hourly buckets")
struct UsageHourlyTests {

    // MARK: - 夹具

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-hourly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.sqlite")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func calendar(timeZone identifier: String) -> Calendar? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func date(_ calendar: Calendar, year: Int, month: Int, day: Int,
                      hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute, second: second))!
    }

    private func record(
        id: UUID = UUID(),
        requestID: UUID = UUID(),
        timestamp: Date,
        routeID: String = "route-1",
        routeName: String = "Route One",
        input: Int? = 10,
        output: Int? = 5
    ) -> UsageRecord {
        UsageRecord(id: id, requestID: requestID, timestamp: timestamp, routeID: routeID,
                    routeName: routeName, remoteID: "remote-1", provider: "OpenAI", model: "gpt-4o",
                    endpoint: "chat", attempt: 1, status: 200, outcome: "success", durationMS: 100,
                    tokens: UsageTokens(input: input, output: output), performance: nil)
    }

    // MARK: - 聚合与缺失值语义

    @Test
    func hourlyAggregatesRequestsAndTreatsMissingUsageAsZero() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let utc = utcCalendar()
        let base = date(utc, year: 2026, month: 5, day: 10, hour: 14)
        let store = UsageStore(url: url, calendar: utc)

        // 同一小时的两条记录属于同一请求（含一条缺 output）；另一条请求进入下一小时。
        let firstRequest = UUID()
        store.record(record(requestID: firstRequest, timestamp: base.addingTimeInterval(5 * 60),
                            input: 10, output: 20))
        store.record(record(requestID: firstRequest, timestamp: base.addingTimeInterval(50 * 60),
                            input: 5, output: nil))
        store.record(record(timestamp: base.addingTimeInterval(70 * 60), input: 1, output: 1))
        try await store.flush()

        let snapshot = try await store.snapshot(from: base, to: base.addingTimeInterval(3 * 3600),
                                                grouping: .route, includeHourly: true)

        #expect(snapshot.hours.count == 2)
        #expect(snapshot.hours.map(\.date) == [date(utc, year: 2026, month: 5, day: 10, hour: 14),
                                               date(utc, year: 2026, month: 5, day: 10, hour: 15)])
        // 缺失 output 与 days 查询的 COALESCE 语义一致：计为 0。
        #expect(snapshot.hours.map(\.input) == [15, 1])
        #expect(snapshot.hours.map(\.output) == [20, 1])
        // 按桶去重：14 点两条尝试合并为一个请求；15 点另一请求。
        #expect(snapshot.hours.map(\.requests) == [1, 1])
        #expect(snapshot.days[0].requests == 2)
        #expect(snapshot.totals.requests == 2)

        // 日聚合与分组在 includeHourly 下保持不变。
        #expect(snapshot.days.count == 1)
        #expect(snapshot.days[0].input == 16)
        #expect(snapshot.days[0].output == 21)
        #expect(snapshot.totals.input == 16)
        #expect(snapshot.groups.count == 1)
    }

    @Test
    func hoursDefaultToEmptyAndDailyCompatibilityIsPreserved() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let utc = utcCalendar()
        let base = date(utc, year: 2026, month: 5, day: 10, hour: 14)
        let store = UsageStore(url: url, calendar: utc)
        store.record(record(timestamp: base, input: 7, output: 3))
        try await store.flush()

        // 默认调用：不执行小时查询，hours 为空；日聚合照常。
        let snapshot = try await store.snapshot(from: base, to: base.addingTimeInterval(3600),
                                                grouping: .route)
        #expect(snapshot.hours.isEmpty)
        #expect(snapshot.days.count == 1)
        #expect(snapshot.totals.input == 7)
    }

    // MARK: - 半开区间与边界

    @Test
    func hourlyRangeIsHalfOpenAtHourBoundaries() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let utc = utcCalendar()
        let from = date(utc, year: 2026, month: 5, day: 10, hour: 14)
        let to = date(utc, year: 2026, month: 5, day: 10, hour: 16)
        let store = UsageStore(url: url, calendar: utc)

        store.record(record(timestamp: from.addingTimeInterval(-1), input: 100, output: 100)) // 越界前
        store.record(record(timestamp: from, input: 1, output: 1))                          // 起点，包含
        store.record(record(timestamp: to.addingTimeInterval(-1), input: 2, output: 2))     // 上界前，包含
        store.record(record(timestamp: to, input: 200, output: 200))                        // 上界，排除
        try await store.flush()

        let snapshot = try await store.snapshot(from: from, to: to, grouping: .route, includeHourly: true)
        #expect(snapshot.hours.count == 2)
        #expect(snapshot.hours.map(\.date) == [from, date(utc, year: 2026, month: 5, day: 10, hour: 15)])
        #expect(snapshot.hours.map(\.input) == [1, 2])
        #expect(snapshot.totals.input == 3)
    }

    // MARK: - 非 UTC / 半小时偏移时区

    @Test
    func hourlyUsesLocalCalendarHoursInHalfHourOffsetTimeZone() async throws {
        guard let kolkata = calendar(timeZone: "Asia/Kolkata") else { return } // +05:30
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let from = date(kolkata, year: 2026, month: 5, day: 10, hour: 0)
        let to = date(kolkata, year: 2026, month: 5, day: 10, hour: 3)
        let store = UsageStore(url: url, calendar: kolkata)

        // 两条落在当地 01 点（间隔 40 分钟），一条落在 02 点。
        store.record(record(timestamp: date(kolkata, year: 2026, month: 5, day: 10, hour: 1, minute: 10),
                            input: 10, output: 1))
        store.record(record(timestamp: date(kolkata, year: 2026, month: 5, day: 10, hour: 1, minute: 50),
                            input: 5, output: 2))
        store.record(record(timestamp: date(kolkata, year: 2026, month: 5, day: 10, hour: 2, minute: 5),
                            input: 2, output: 3))
        try await store.flush()

        let snapshot = try await store.snapshot(from: from, to: to, grouping: .route, includeHourly: true)
        // 桶起点是半整数偏移下的真实当地整点（01:00 IST == 19:30Z 前一日）。
        #expect(snapshot.hours.count == 2)
        #expect(snapshot.hours.map(\.date) == [date(kolkata, year: 2026, month: 5, day: 10, hour: 1),
                                               date(kolkata, year: 2026, month: 5, day: 10, hour: 2)])
        #expect(snapshot.hours.map(\.input) == [15, 2])
        #expect(snapshot.hours.map(\.output) == [3, 3])
    }

    // MARK: - DST 重复小时区分

    @Test
    func hourlyDistinguishesRepeatedDSTHourWhenAvailable() async throws {
        // 美国 2026 年夏令时回退：2026-11-01 02:00 EDT → 01:00 EST，当地 01 点出现两次。
        guard let zone = TimeZone(identifier: "America/New_York") else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let utc = utcCalendar()
        let first = date(utc, year: 2026, month: 11, day: 1, hour: 5, minute: 30)   // 01:30 EDT
        let second = first.addingTimeInterval(3600)                                  // 01:30 EST
        // 两次偏移不同才说明确实跨越了 DST 切换；否则跳过（避免依赖本地环境）。
        guard zone.secondsFromGMT(for: first) != zone.secondsFromGMT(for: second) else { return }
        #expect(calendar.component(.hour, from: first) == 1)
        #expect(calendar.component(.hour, from: second) == 1)

        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url, calendar: calendar)
        store.record(record(timestamp: first, input: 11, output: 1))
        store.record(record(timestamp: second, input: 22, output: 2))
        try await store.flush()

        let snapshot = try await store.snapshot(from: first.addingTimeInterval(-3600),
                                                to: second.addingTimeInterval(3600),
                                                grouping: .route, includeHourly: true)
        // 同一个墙钟小时出现两次 → 两个不同起点、按时间先后排序的两个桶（不合并）。
        #expect(snapshot.hours.count == 2)
        #expect(Set(snapshot.hours.map(\.date)).count == 2)
        #expect(snapshot.hours[0].date < snapshot.hours[1].date)
        #expect(snapshot.hours.map { calendar.component(.hour, from: $0.date) } == [1, 1])
        #expect(snapshot.hours.reduce(0) { $0 + $1.input } == 33)
        #expect(snapshot.hours.reduce(0) { $0 + $1.output } == 3)
    }
}
