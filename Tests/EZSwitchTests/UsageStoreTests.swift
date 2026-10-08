import Foundation
import SQLite3
import Testing
@testable import EZSwitch

@Suite("Usage store")
struct UsageStoreTests {

    // MARK: - 夹具

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.sqlite")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func record(
        id: UUID = UUID(),
        requestID: UUID = UUID(),
        timestamp: Date,
        routeID: String = "route-1",
        routeName: String = "Route One",
        remoteID: String = "remote-1",
        provider: String = "OpenAI",
        model: String = "gpt-4o",
        endpoint: String = "chat",
        attempt: Int = 1,
        status: Int? = 200,
        outcome: String = "success",
        durationMS: Int = 100,
        input: Int? = 10,
        output: Int? = 5,
        cachedInput: Int? = nil,
        cacheWrite: Int? = nil,
        reasoning: Int? = nil
    ) -> UsageRecord {
        UsageRecord(id: id, requestID: requestID, timestamp: timestamp, routeID: routeID,
                    routeName: routeName, remoteID: remoteID, provider: provider, model: model,
                    endpoint: endpoint, attempt: attempt, status: status, outcome: outcome,
                    durationMS: durationMS,
                    tokens: UsageTokens(input: input, output: output, cachedInput: cachedInput,
                                        cacheWrite: cacheWrite, reasoning: reasoning))
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    // MARK: - 位置与持久化

    @Test
    func databaseURLIsSiblingOfConfig() {
        let config = URL(fileURLWithPath: "/tmp/ezswitch/config.json")
        #expect(UsageStore.databaseURL(for: config) == URL(fileURLWithPath: "/tmp/ezswitch/usage.sqlite"))
    }

    @Test
    func persistsAcrossReopen() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)

        let first = UsageStore(url: url)
        first.record(record(timestamp: start, input: 10, output: 5))
        first.record(record(timestamp: start.addingTimeInterval(60), input: 20, output: 8))
        try await first.flush()

        let reopened = UsageStore(url: url)
        let snapshot = try await reopened.snapshot(from: start.addingTimeInterval(-1),
                                                   to: start.addingTimeInterval(3600),
                                                   grouping: .route)
        #expect(snapshot.totals.attempts == 2)
        #expect(snapshot.totals.requests == 2)
        #expect(snapshot.totals.input == 30)
        #expect(snapshot.totals.output == 13)
        #expect(snapshot.totals.total == 43)
    }

    // MARK: - 回退语义

    @Test
    func fallbackCountsTwoAttemptsOneRequest() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let requestID = UUID()
        let store = UsageStore(url: url)

        // 第一次尝试失败且没有 token 统计；第二次尝试成功。
        store.record(record(requestID: requestID, timestamp: start, provider: "OpenAI", model: "gpt-4o",
                            attempt: 1, status: 502, outcome: "failure", input: nil, output: nil))
        store.record(record(requestID: requestID, timestamp: start.addingTimeInterval(2), provider: "Azure",
                            model: "gpt-4o", attempt: 2, status: 200, outcome: "success",
                            input: 100, output: 40))
        try await store.flush()

        let snapshot = try await store.snapshot(from: start.addingTimeInterval(-1),
                                                to: start.addingTimeInterval(3600), grouping: .route)
        #expect(snapshot.totals.requests == 1)
        #expect(snapshot.totals.attempts == 2)
        #expect(snapshot.totals.knownAttempts == 1)
        #expect(snapshot.totals.failedAttempts == 1)
        #expect(abs(snapshot.totals.coverage - 0.5) < 0.0001)
        #expect(snapshot.totals.input == 100)
        #expect(snapshot.groups.count == 1)
        #expect(snapshot.groups[0].totals.attempts == 2)
    }

    @Test
    func http200DoesNotMaskTransportFailure() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        // 200 已写出头，但流中断 / 用户取消：最终 outcome 决定成败。
        store.record(record(timestamp: start, status: 200, outcome: "transport_error", input: 5, output: 5))
        store.record(record(timestamp: start.addingTimeInterval(1), status: 200, outcome: "cancelled",
                            input: 6, output: 6))
        store.record(record(timestamp: start.addingTimeInterval(2), status: 200, outcome: "success",
                            input: 7, output: 7))
        try await store.flush()

        let snapshot = try await store.snapshot(from: start.addingTimeInterval(-1),
                                                to: start.addingTimeInterval(3600), grouping: .route)
        #expect(snapshot.totals.attempts == 3)
        #expect(snapshot.totals.failedAttempts == 2)
        #expect(snapshot.groups[0].totals.failedAttempts == 2)
    }

    // MARK: - 区间

    @Test
    func rangeIsHalfOpen() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start.addingTimeInterval(-1)))   // 越界前，排除
        store.record(record(timestamp: start))                          // 起点，包含
        store.record(record(timestamp: start.addingTimeInterval(3599))) // 上界前，包含
        store.record(record(timestamp: start.addingTimeInterval(3600))) // 上界，排除
        try await store.flush()

        let snapshot = try await store.snapshot(from: start, to: start.addingTimeInterval(3600),
                                                grouping: .route)
        #expect(snapshot.totals.attempts == 2)

        let empty = try await store.snapshot(from: start, to: start, grouping: .route)
        #expect(empty.totals.attempts == 0)
        #expect(empty.days.isEmpty)
        #expect(empty.groups.isEmpty)
    }

    // MARK: - 分组

    @Test
    func groupsByRouteProviderAndModel() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start, routeID: "route-1", routeName: "Route One",
                            provider: "OpenAI", model: "gpt-4o", input: 100, output: 50))
        store.record(record(timestamp: start.addingTimeInterval(1), routeID: "route-1", routeName: "Route One",
                            provider: "OpenAI", model: "gpt-4o", attempt: 2, input: 10, output: 5))
        store.record(record(timestamp: start.addingTimeInterval(2), routeID: "route-2", routeName: "Route Two",
                            provider: "Anthropic", model: "claude-4", input: 20, output: 10))
        store.record(record(timestamp: start.addingTimeInterval(3), routeID: "route-3", routeName: "Route Three",
                            provider: "Azure", model: "gpt-4o", input: 1, output: 1))
        try await store.flush()

        let from = start.addingTimeInterval(-1), to = start.addingTimeInterval(3600)

        let byRoute = try await store.snapshot(from: from, to: to, grouping: .route)
        #expect(byRoute.groups.map(\.id) == ["route-1", "route-2", "route-3"])
        #expect(byRoute.groups.map(\.title) == ["Route One", "Route Two", "Route Three"])
        #expect(byRoute.groups[0].totals.total == 165)
        #expect(byRoute.groups[0].totals.attempts == 2)

        let byProvider = try await store.snapshot(from: from, to: to, grouping: .provider)
        #expect(byProvider.groups.map(\.title) == ["OpenAI", "Anthropic", "Azure"])
        #expect(byProvider.groups.map(\.totals.total) == [165, 30, 2])

        let byModel = try await store.snapshot(from: from, to: to, grouping: .model)
        #expect(byModel.groups.count == 3)
        #expect(byModel.groups[0].title == "gpt-4o")
        #expect(byModel.groups[0].subtitle == "OpenAI")
        #expect(byModel.groups[0].totals.total == 165)
        let gptRows = byModel.groups.filter { $0.title == "gpt-4o" }
        #expect(gptRows.count == 2)
        #expect(Set(gptRows.map(\.subtitle)) == ["OpenAI", "Azure"])
    }

    @Test
    func routeRenameKeepsSingleGroupWithLatestName() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start, routeID: "r1", routeName: "Alpha", input: 1, output: 1))
        store.record(record(timestamp: start.addingTimeInterval(60), routeID: "r1", routeName: "Beta",
                            input: 2, output: 2))
        try await store.flush()

        let snapshot = try await store.snapshot(from: start.addingTimeInterval(-1),
                                                to: start.addingTimeInterval(3600), grouping: .route)
        #expect(snapshot.groups.count == 1)
        #expect(snapshot.groups[0].id == "r1")
        #expect(snapshot.groups[0].title == "Beta")
        #expect(snapshot.groups[0].totals.attempts == 2)
    }

    // MARK: - null / 零值

    @Test
    func nullAndZeroUsageAggregateAccurately() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start, input: 10, output: 20, cachedInput: 5, reasoning: 3))
        store.record(record(timestamp: start.addingTimeInterval(1), input: nil, output: nil,
                            cachedInput: 7, reasoning: nil))
        store.record(record(timestamp: start.addingTimeInterval(2), input: 0, output: 0))
        try await store.flush()

        let snapshot = try await store.snapshot(from: start.addingTimeInterval(-1),
                                                to: start.addingTimeInterval(3600), grouping: .route)
        #expect(snapshot.totals.input == 10)
        #expect(snapshot.totals.output == 20)
        #expect(snapshot.totals.cachedInput == 12)
        #expect(snapshot.totals.cacheWrite == 0)
        #expect(snapshot.totals.reasoning == 3)
        // 缓存/推理是子集，不重复计入 total。
        #expect(snapshot.totals.total == 30)
        #expect(snapshot.totals.attempts == 3)
        #expect(snapshot.totals.knownAttempts == 2)
        #expect(snapshot.totals.failedAttempts == 0)
        // 非 NULL 字段计数：记录 1、3 有 input/output；记录 1、2 有 cachedInput。
        #expect(snapshot.totals.inputAttempts == 2)
        #expect(snapshot.totals.outputAttempts == 2)
        #expect(snapshot.totals.cachedInputAttempts == 2)
    }

    @Test
    func fieldCountsDistinguishUnknownFromZero() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        // 明确写 0：计入字段计数。
        store.record(record(timestamp: start, routeID: "known", routeName: "Known",
                            input: 0, output: 0, cachedInput: 0))
        // 字段缺失（未知）：不计入，UI 应显示 “—”。
        store.record(record(timestamp: start.addingTimeInterval(1), routeID: "unknown", routeName: "Unknown",
                            input: nil, output: nil, cachedInput: nil))
        try await store.flush()

        let snapshot = try await store.snapshot(from: start.addingTimeInterval(-1),
                                                to: start.addingTimeInterval(3600), grouping: .route)
        #expect(snapshot.totals.input == 0)
        #expect(snapshot.totals.inputAttempts == 1)
        #expect(snapshot.totals.outputAttempts == 1)
        #expect(snapshot.totals.cachedInputAttempts == 1)
        #expect(snapshot.totals.knownAttempts == 1)

        let known = snapshot.groups.first { $0.id == "known" }
        let unknown = snapshot.groups.first { $0.id == "unknown" }
        #expect(known?.totals.input == 0)
        #expect(known?.totals.inputAttempts == 1)
        #expect(unknown?.totals.input == 0)
        #expect(unknown?.totals.inputAttempts == 0)
    }

    @Test
    func duplicateIdentifierIsIgnored() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let id = UUID()
        let store = UsageStore(url: url)
        store.record(record(id: id, timestamp: start, input: 1, output: 1))
        store.record(record(id: id, timestamp: start.addingTimeInterval(1), input: 9, output: 9))
        try await store.flush()

        let snapshot = try await store.snapshot(from: start.addingTimeInterval(-1),
                                                to: start.addingTimeInterval(3600), grouping: .route)
        #expect(snapshot.totals.attempts == 1)
        #expect(snapshot.totals.input == 1)
    }

    // MARK: - 日历分桶

    @Test
    func dayBucketsFollowLocalCalendar() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let calendar = Calendar.current
        let first = day(2026, 5, 10, hour: 15)
        let second = calendar.date(byAdding: .day, value: 1, to: first)!
        let third = calendar.date(byAdding: .day, value: 2, to: first)!
        let from = calendar.startOfDay(for: first)
        let to = calendar.date(byAdding: .day, value: 3, to: from)!

        let store = UsageStore(url: url)
        store.record(record(timestamp: first, input: 100, output: 10))
        store.record(record(timestamp: second, input: 200, output: 20))
        store.record(record(timestamp: second.addingTimeInterval(120), input: 50, output: 5))
        store.record(record(timestamp: third, input: 0, output: 0))
        try await store.flush()

        let snapshot = try await store.snapshot(from: from, to: to, grouping: .route)
        #expect(snapshot.days.count == 3)
        #expect(snapshot.days.map(\.date) == [calendar.startOfDay(for: first),
                                              calendar.startOfDay(for: second),
                                              calendar.startOfDay(for: third)])
        #expect(snapshot.days.map(\.input) == [100, 250, 0])
        #expect(snapshot.days.map(\.output) == [10, 25, 0])
    }

    @Test
    func dayBucketsRespectDaylightSavingWhenAvailable() async throws {
        // 本机时区若无下一次 DST 切换（例如 UTC），则跳过。
        guard let transition = TimeZone.autoupdatingCurrent.nextDaylightSavingTimeTransition(after: Date())
        else { return }
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let calendar = Calendar.current
        let before = transition.addingTimeInterval(-3 * 3600)
        let after = transition.addingTimeInterval(3 * 3600)
        let from = calendar.startOfDay(for: before)
        let to = calendar.date(byAdding: .day, value: 3, to: from)!

        let store = UsageStore(url: url)
        store.record(record(timestamp: before, input: 11, output: 1))
        store.record(record(timestamp: after, input: 22, output: 2))
        try await store.flush()

        let snapshot = try await store.snapshot(from: from, to: to, grouping: .route)
        let expected = Set([calendar.startOfDay(for: before), calendar.startOfDay(for: after)])
        #expect(Set(snapshot.days.map(\.date)) == expected)
        #expect(snapshot.days.reduce(0) { $0 + $1.input } == 33)
        #expect(snapshot.days.reduce(0) { $0 + $1.output } == 3)
    }

    // MARK: - CSV

    @Test
    func csvEscapesAndNeutralizesFormulaCells() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start, routeName: "A,B", model: "@SUM(A1)", outcome: "=1+1"))
        store.record(record(timestamp: start.addingTimeInterval(1), routeName: "He said \"hi\", ok",
                            model: "gpt-4o", outcome: "success"))
        try await store.flush()

        let csv = try await store.exportCSV(from: start.addingTimeInterval(-1),
                                            to: start.addingTimeInterval(3600))
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 3) // header + 2 rows
        #expect(lines[0].hasPrefix("timestamp,requestID,routeID"))
        #expect(csv.contains("\"A,B\""))
        #expect(csv.contains("\"He said \"\"hi\"\", ok\""))
        #expect(csv.contains("'@SUM(A1)"))
        #expect(csv.contains("'=1+1"))
        #expect(!csv.contains(",@SUM(A1),"))
    }

    @Test
    func exportEmptyRangeReturnsHeaderOnly() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        let csv = try await store.exportCSV(from: start, to: start.addingTimeInterval(3600))
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("timestamp,requestID"))
    }

    // MARK: - 清理

    @Test
    func clearRemovesAllRows() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start))
        store.record(record(timestamp: start.addingTimeInterval(1)))
        try await store.flush()
        try await store.clear()

        let snapshot = try await store.snapshot(from: start.addingTimeInterval(-1),
                                                to: start.addingTimeInterval(3600), grouping: .route)
        #expect(snapshot.totals.attempts == 0)
        #expect(try rawCount(url) == 0)
    }

    // MARK: - 失败隔离

    @Test
    func futureSchemaIsRejectedWithoutReset() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)

        let store = UsageStore(url: url)
        store.record(record(timestamp: start))
        try await store.flush()

        try rawExec(url, "PRAGMA user_version = 2;")
        #expect(try rawUserVersion(url) == 2)

        let reopened = UsageStore(url: url)
        await #expect(throws: UsageStoreError.futureSchema(found: 2, supported: 1)) {
            _ = try await reopened.snapshot(from: start.addingTimeInterval(-1),
                                            to: start.addingTimeInterval(3600), grouping: .route)
        }
        // 数据与版本均未被破坏性重置。
        #expect(try rawUserVersion(url) == 2)
        #expect(try rawCount(url) == 1)
    }

    @Test
    func invalidPathFailsWithoutCrashingRecord() async throws {
        let url = URL(fileURLWithPath: "/dev/null/usage.sqlite")
        let store = UsageStore(url: url)
        // record 不应抛错、不应崩溃。
        store.record(record(timestamp: day(2026, 5, 10)))
        // 排空队列：flush 暴露缓存的打开错误。
        await #expect(throws: UsageStoreError.self) {
            try await store.flush()
        }

        await #expect(throws: UsageStoreError.self) {
            _ = try await store.snapshot(from: day(2026, 5, 9), to: day(2026, 5, 11), grouping: .route)
        }
        await #expect(throws: UsageStoreError.self) {
            _ = try await store.exportCSV(from: day(2026, 5, 9), to: day(2026, 5, 11))
        }
    }

    @Test
    func recoversAfterRepairingPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 用普通文件顶替父目录，首次打开即失败。
        let blockedParent = root.appendingPathComponent("blocked")
        try Data().write(to: blockedParent)
        let url = blockedParent.appendingPathComponent("usage.sqlite")
        let store = UsageStore(url: url)
        let start = day(2026, 5, 10)

        await #expect(throws: UsageStoreError.self) {
            _ = try await store.snapshot(from: start, to: start.addingTimeInterval(3600), grouping: .route)
        }

        // 修复路径后，snapshot 强制重试应恢复，无需重启。
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        let recovered = try await store.snapshot(from: start, to: start.addingTimeInterval(3600),
                                                 grouping: .route)
        #expect(recovered.totals.attempts == 0)

        store.record(record(timestamp: start))
        try await store.flush()
        let after = try await store.snapshot(from: start, to: start.addingTimeInterval(3600), grouping: .route)
        #expect(after.totals.attempts == 1)
    }

    // MARK: - 原始 sqlite 辅助（仅测试）

    private func rawExec(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close_v2(handle) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorPointer)
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func rawUserVersion(_ url: URL) throws -> Int32 {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "prepare failed"])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "step failed"])
        }
        return sqlite3_column_int(statement, 0)
    }

    private func rawCount(_ url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM usage_records;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "prepare failed"])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "step failed"])
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
