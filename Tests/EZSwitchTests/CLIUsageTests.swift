import Foundation
import SQLite3
import Testing
@testable import EZSwitch

@MainActor
@Suite("CLI usage")
struct CLIUsageTests {

    // MARK: - 夹具

    private let calendar = Calendar.current

    private func makeStore() throws -> (ConfigStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 0, remotes: [], fakes: [])).write(to: url)
        return (ConfigStore(configURL: url), directory)
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0,
                     second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute, second: second))!
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

    /// 通过 async dispatch 返回纯字典，便于直接断言；不经过 UDS。
    private func send(_ store: ConfigStore, _ command: [String: Any],
                      now: Date, calendar: Calendar? = nil) async throws -> [String: Any] {
        let calendar = calendar ?? self.calendar
        let data = try JSONSerialization.data(withJSONObject: command)
        return await store.handleCLICommandAsync(data, now: now, calendar: calendar)
    }

    private func usagePayload(_ reply: [String: Any]) throws -> [String: Any] {
        try #require(reply["usage"] as? [String: Any])
    }

    private func totals(_ payload: [String: Any]) throws -> [String: Any] {
        try #require(payload["totals"] as? [String: Any])
    }

    private func range(_ payload: [String: Any]) throws -> [String: Any] {
        try #require(payload["range"] as? [String: Any])
    }

    private func groups(_ payload: [String: Any]) throws -> [[String: Any]] {
        try #require(payload["groups"] as? [[String: Any]])
    }

    private func days(_ payload: [String: Any]) throws -> [[String: Any]] {
        try #require(payload["days"] as? [[String: Any]])
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - 默认与 schema

    @Test
    func defaultRequestReturnsTodayRouteSchema() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let now = day(2026, 5, 10)
        let store1 = store.usageStore
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9),
                             routeID: "r1", routeName: "Alpha", provider: "OpenAI", model: "gpt-4o",
                             input: 100, output: 50))
        store1.record(record(timestamp: day(2026, 5, 10, hour: 10),
                             routeID: "r2", routeName: "Beta", provider: "Anthropic", model: "claude-4",
                             input: 10, output: 5))
        try await store1.flush()

        let reply = try await send(store, ["command": "usage"], now: now)
        #expect(reply["ok"] as? Bool == true)
        let payload = try usagePayload(reply)

        #expect(payload["grouping"] as? String == "route")
        #expect(payload["limit"] as? Int == 100)
        #expect(payload["groupCount"] as? Int == 2)
        #expect(payload["truncated"] as? Bool == false)

        let range = try self.range(payload)
        #expect(range["from"] as? String == "2026-05-10")
        #expect(range["to"] as? String == "2026-05-10")
        #expect((range["timeZone"] as? String)?.isEmpty == false)
        let start = try #require((range["start"] as? String).flatMap(ISO8601DateFormatter.internet.date(from:)))
        let end = try #require((range["endExclusive"] as? String).flatMap(ISO8601DateFormatter.internet.date(from:)))
        #expect(end > start)

        let totals = try self.totals(payload)
        #expect(totals["input"] as? Int == 110)
        #expect(totals["output"] as? Int == 55)
        #expect(totals["total"] as? Int == 165)
        #expect(totals["attempts"] as? Int == 2)
        #expect(totals["requests"] as? Int == 2)
        #expect(totals["failedAttempts"] as? Int == 0)
        #expect(totals["knownAttempts"] as? Int == 2)
        #expect((totals["coverage"] as? Double) == 1.0)

        let days = try self.days(payload)
        #expect(days.count == 1)
        #expect(days[0]["date"] as? String == "2026-05-10")
        #expect(days[0]["input"] as? Int == 110)
        #expect(days[0]["output"] as? Int == 55)

        let groups = try self.groups(payload)
        #expect(groups.count == 2)
        #expect(groups[0]["id"] as? String == "r1")
        #expect(groups[0]["title"] as? String == "Alpha")
        #expect(groups[0]["subtitle"] as? String == "")
        #expect((groups[0]["totals"] as? [String: Any])?["input"] as? Int == 100)

        // 响应必须是合法 JSON（可序列化）。
        #expect((try? JSONSerialization.data(withJSONObject: reply)) != nil)
    }

    @Test
    func periodPresetsResolveLocalCalendarRanges() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let now = day(2026, 5, 10)

        let today = try self.range(try usagePayload(try await send(store, ["command": "usage", "period": "today"], now: now)))
        #expect(today["from"] as? String == "2026-05-10")
        #expect(today["to"] as? String == "2026-05-10")

        let week = try self.range(try usagePayload(try await send(store, ["command": "usage", "period": "7d"], now: now)))
        #expect(week["from"] as? String == "2026-05-04")
        #expect(week["to"] as? String == "2026-05-10")

        let month = try self.range(try usagePayload(try await send(store, ["command": "usage", "period": "month"], now: now)))
        #expect(month["from"] as? String == "2026-05-01")
        #expect(month["to"] as? String == "2026-05-10")
    }

    @Test
    func customRangeNormalizesReversedDatesAndIncludesEndDay() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let store1 = store.usageStore
        // 结束日 12 日晚上的记录必须被包含（end inclusive）。
        store1.record(record(timestamp: day(2026, 5, 12, hour: 23), input: 7, output: 3))
        try await store1.flush()

        let reply = try await send(store, ["command": "usage", "from": "2026-05-12", "to": "2026-05-10"],
                             now: day(2026, 6, 1))
        let payload = try usagePayload(reply)
        let range = try self.range(payload)
        #expect(range["from"] as? String == "2026-05-10")
        #expect(range["to"] as? String == "2026-05-12")
        #expect(try self.totals(payload)["input"] as? Int == 7)
    }

    // MARK: - 参数互斥与类型

    @Test
    func periodAndCustomRangeAreMutuallyExclusive() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let now = day(2026, 5, 10)

        let both = try await send(store, ["command": "usage", "period": "today",
                                    "from": "2026-05-01", "to": "2026-05-10"], now: now)
        #expect(both["ok"] as? Bool == false)
        #expect((both["message"] as? String)?.isEmpty == false)

        let half = try await send(store, ["command": "usage", "from": "2026-05-01"], now: now)
        #expect(half["ok"] as? Bool == false)

        let halfEnd = try await send(store, ["command": "usage", "to": "2026-05-10"], now: now)
        #expect(halfEnd["ok"] as? Bool == false)
    }

    @Test
    func wrongTypesAreRejectedNotTreatedAsOmitted() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let now = day(2026, 5, 10)

        let cases: [[String: Any]] = [
            ["command": "usage", "period": 5],
            ["command": "usage", "period": ["today"]],
            ["command": "usage", "group": 3],
            ["command": "usage", "group": true],
            ["command": "usage", "limit": 100],
            ["command": "usage", "limit": 100.0],
            ["command": "usage", "from": 20260510, "to": "2026-05-10"],
            ["command": "usage", "from": "2026-05-10", "to": 20260510],
        ]
        for command in cases {
            let reply = try await send(store, command, now: now)
            #expect(reply["ok"] as? Bool == false)
            #expect((reply["message"] as? String)?.isEmpty == false)
            #expect(reply["usage"] == nil)
        }
    }

    @Test
    func invalidEnumValuesAreRejected() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let now = day(2026, 5, 10)

        for command in [["command": "usage", "period": "yesterday"],
                        ["command": "usage", "period": "30d"],
                        ["command": "usage", "group": "route-name"],
                        ["command": "usage", "group": ""]] {
            let reply = try await send(store, command, now: now)
            #expect(reply["ok"] as? Bool == false)
        }
    }

    // MARK: - 严格日期

    @Test
    func strictDateValidationRejectsMalformedAndNonexistentDates() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let now = day(2026, 5, 10)

        let bad = [
            "2026-2-3", "2026-02-30", "2026-13-01", "2026-00-10", "2026-01-00",
            "20260203", "2026/02/03", "2026-02-30 ", " abc ", "", "2026-02-31",
            "0000-01-01", "0000-12-31",
        ]
        for value in bad {
            let reply = try await send(store, ["command": "usage", "from": value, "to": "2026-05-10"], now: now)
            #expect(reply["ok"] as? Bool == false)
            // 不得回显原始（可能很长的）请求值。
            #expect((reply["message"] as? String)?.contains(value) == false)
        }

        // 闰年真实日期可用。
        let leap = try await send(store, ["command": "usage", "from": "2024-02-29", "to": "2024-02-29"], now: now)
        #expect(leap["ok"] as? Bool == true)
    }

    @Test
    func injectedCalendarIsUsedForBothParsingAndFormatting() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        // 非公历注入：解析与回显必须使用同一 calendar，否则年份会不一致。
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        let reply = try await send(store, ["command": "usage", "from": "2569-05-10", "to": "2569-05-10"],
                                   now: Date(), calendar: buddhist)
        #expect(reply["ok"] as? Bool == true)
        let range = try self.range(try usagePayload(reply))
        #expect(range["from"] as? String == "2569-05-10")
        #expect(range["to"] as? String == "2569-05-10")
    }

    // MARK: - limit

    @Test
    func limitParsingAndRounding() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let now = day(2026, 5, 10)

        for value in [1, 100, 1000, 7] {
            let reply = try await send(store, ["command": "usage", "limit": "\(value)"], now: now)
            #expect(reply["ok"] as? Bool == true)
            #expect(try usagePayload(reply)["limit"] as? Int == value)
        }
        let padded = try await send(store, ["command": "usage", "limit": "007"], now: now)
        #expect(try usagePayload(padded)["limit"] as? Int == 7)

        for value in ["0", "1001", "-1", "1.5", "abc", "", "10000", "+5", "١٠"] {
            let reply = try await send(store, ["command": "usage", "limit": value], now: now)
            #expect(reply["ok"] as? Bool == false)
        }
    }

    @Test
    func limitTruncatesGroupsButKeepsFullTotalsAndCount() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let store1 = store.usageStore
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9), routeID: "r1", routeName: "A",
                             input: 100, output: 50))
        store1.record(record(timestamp: day(2026, 5, 10, hour: 10), routeID: "r2", routeName: "B",
                             input: 20, output: 10))
        store1.record(record(timestamp: day(2026, 5, 10, hour: 11), routeID: "r3", routeName: "C",
                             input: 1, output: 1))
        try await store1.flush()

        let reply = try await send(store, ["command": "usage", "limit": "2"], now: day(2026, 5, 10))
        let payload = try usagePayload(reply)
        #expect(payload["limit"] as? Int == 2)
        #expect(payload["groupCount"] as? Int == 3)
        #expect(payload["truncated"] as? Bool == true)
        let groups = try self.groups(payload)
        #expect(groups.count == 2)
        #expect(groups.map { $0["id"] as? String } == ["r1", "r2"])
        // totals 是全量，不是被截取分组之和。
        #expect(try self.totals(payload)["total"] as? Int == 182)
        #expect(try self.totals(payload)["input"] as? Int == 121)
    }

    // MARK: - 分组

    @Test
    func groupsByRouteProviderAndModel() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let store1 = store.usageStore
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9), routeID: "route-1",
                             routeName: "Route One", provider: "OpenAI", model: "gpt-4o", input: 100, output: 50))
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9, minute: 1), routeID: "route-1",
                             routeName: "Route One", provider: "OpenAI", model: "gpt-4o", attempt: 2,
                             input: 10, output: 5))
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9, minute: 2), routeID: "route-2",
                             routeName: "Route Two", provider: "Anthropic", model: "claude-4", input: 20, output: 10))
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9, minute: 3), routeID: "route-3",
                             routeName: "Route Three", provider: "Azure", model: "gpt-4o", input: 1, output: 1))
        try await store1.flush()
        let now = day(2026, 5, 10)

        let byRoute = try usagePayload(try await send(store, ["command": "usage", "group": "route"], now: now))
        #expect(byRoute["grouping"] as? String == "route")
        #expect(try self.groups(byRoute).map { $0["id"] as? String } == ["route-1", "route-2", "route-3"])

        let byProvider = try usagePayload(try await send(store, ["command": "usage", "group": "provider"], now: now))
        #expect(byProvider["grouping"] as? String == "provider")
        #expect(try self.groups(byProvider).map { $0["title"] as? String } == ["OpenAI", "Anthropic", "Azure"])

        let byModel = try usagePayload(try await send(store, ["command": "usage", "group": "model"], now: now))
        let modelGroups = try self.groups(byModel)
        #expect(modelGroups.count == 3)
        #expect(modelGroups[0]["title"] as? String == "gpt-4o")
        #expect(modelGroups[0]["subtitle"] as? String == "OpenAI")
        #expect(modelGroups.map { $0["subtitle"] as? String } == ["OpenAI", "Anthropic", "Azure"])
    }

    // MARK: - 未知用量与回退去重

    @Test
    func unknownUsageIsNotFabricatedAndCoverageDistinguishes() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let store1 = store.usageStore
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9), input: 0, output: 0, cachedInput: 0))
        store1.record(record(timestamp: day(2026, 5, 10, hour: 10), status: 502, outcome: "failure",
                             input: nil, output: nil, cachedInput: nil))
        try await store1.flush()

        let payload = try usagePayload(try await send(store, ["command": "usage"], now: day(2026, 5, 10)))
        let totals = try self.totals(payload)
        #expect(totals["input"] as? Int == 0)
        #expect(totals["attempts"] as? Int == 2)
        #expect(totals["knownAttempts"] as? Int == 1)
        #expect(totals["inputAttempts"] as? Int == 1)
        #expect(totals["cachedInputAttempts"] as? Int == 1)
        #expect(totals["failedAttempts"] as? Int == 1)
        #expect((totals["coverage"] as? Double).map { abs($0 - 0.5) < 0.0001 } == true)
    }

    @Test
    func fallbackCountsTwoAttemptsOneRequest() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let store1 = store.usageStore
        let requestID = UUID()
        store1.record(record(requestID: requestID, timestamp: day(2026, 5, 10, hour: 9),
                             provider: "OpenAI", attempt: 1, status: 502, outcome: "failure",
                             input: nil, output: nil))
        store1.record(record(requestID: requestID, timestamp: day(2026, 5, 10, hour: 9, minute: 1),
                             provider: "Azure", attempt: 2, status: 200, outcome: "success",
                             input: 100, output: 40))
        try await store1.flush()

        let payload = try usagePayload(try await send(store, ["command": "usage"], now: day(2026, 5, 10)))
        let totals = try self.totals(payload)
        #expect(totals["requests"] as? Int == 1)
        #expect(totals["attempts"] as? Int == 2)
        #expect(totals["knownAttempts"] as? Int == 1)
        #expect(totals["failedAttempts"] as? Int == 1)
        #expect((totals["coverage"] as? Double).map { abs($0 - 0.5) < 0.0001 } == true)
        #expect(try self.groups(payload).count == 1)
        #expect((try self.groups(payload)[0]["totals"] as? [String: Any])?["attempts"] as? Int == 2)
    }

    @Test
    func emptyDatabaseYieldsZeroAndEmptyArrays() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let reply = try await send(store, ["command": "usage"], now: day(2026, 5, 10))
        #expect(reply["ok"] as? Bool == true)
        let payload = try usagePayload(reply)
        #expect(payload["groupCount"] as? Int == 0)
        #expect(payload["truncated"] as? Bool == false)
        #expect(try self.groups(payload).isEmpty)
        #expect(try self.days(payload).isEmpty)
        let totals = try self.totals(payload)
        #expect(totals["input"] as? Int == 0)
        #expect(totals["output"] as? Int == 0)
        #expect(totals["attempts"] as? Int == 0)
        #expect(totals["requests"] as? Int == 0)
        #expect(totals["total"] as? Int == 0)
        #expect((totals["coverage"] as? Double) == 0)
    }

    // MARK: - 本地日界与 DST

    @Test
    func localDayBoundaryExcludesNextDayRecords() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let store1 = store.usageStore
        store1.record(record(timestamp: day(2026, 5, 10, hour: 23, minute: 59, second: 59),
                             input: 11, output: 1))
        store1.record(record(timestamp: day(2026, 5, 11, hour: 0, minute: 0, second: 1),
                             input: 22, output: 2))
        try await store1.flush()

        let reply = try await send(store, ["command": "usage", "period": "today"], now: day(2026, 5, 10, hour: 23))
        let payload = try usagePayload(reply)
        #expect(try self.totals(payload)["input"] as? Int == 11)
        let days = try self.days(payload)
        #expect(days.count == 1)
        #expect(days[0]["date"] as? String == "2026-05-10")
    }

    @Test
    func dayBucketsRespectDaylightSavingWhenAvailable() async throws {
        guard let transition = TimeZone.autoupdatingCurrent.nextDaylightSavingTimeTransition(after: Date())
        else { return }
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let before = transition.addingTimeInterval(-3 * 3600)
        let after = transition.addingTimeInterval(3 * 3600)
        let from = calendar.startOfDay(for: before)
        let to = calendar.startOfDay(for: after)

        let store1 = store.usageStore
        store1.record(record(timestamp: before, input: 11, output: 1))
        store1.record(record(timestamp: after, input: 22, output: 2))
        try await store1.flush()

        let reply = try await send(store, ["command": "usage", "from": dateString(from), "to": dateString(to)],
                             now: after.addingTimeInterval(24 * 3600))
        let payload = try usagePayload(reply)
        let days = try self.days(payload)
        #expect(Set(days.map { $0["date"] as? String }) == Set([dateString(before), dateString(after)]))
        #expect(try self.totals(payload)["input"] as? Int == 33)
    }

    // MARK: - 只读

    @Test
    func usageQueryIsReadOnly() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let store1 = store.usageStore
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9), input: 5, output: 5))
        try await store1.flush()

        let configURL = directory.appendingPathComponent("config.json")
        let configBefore = try Data(contentsOf: configURL)
        let countBefore = try rawCount(UsageStore.databaseURL(for: configURL))
        let versionBefore = try rawUserVersion(UsageStore.databaseURL(for: configURL))

        let reply = try await send(store, ["command": "usage"], now: day(2026, 5, 10))
        #expect(reply["ok"] as? Bool == true)

        #expect(try Data(contentsOf: configURL) == configBefore)
        #expect(try rawCount(UsageStore.databaseURL(for: configURL)) == countBefore)
        #expect(try rawUserVersion(UsageStore.databaseURL(for: configURL)) == versionBefore)
    }

    // MARK: - 大响应与长字符串

    @Test
    func longButBoundedGroupStringsAreReturned() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let longName = String(repeating: "x", count: 4096)
        let store1 = store.usageStore
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9), routeName: longName, input: 1, output: 1))
        try await store1.flush()

        let reply = try await send(store, ["command": "usage"], now: day(2026, 5, 10))
        #expect(reply["ok"] as? Bool == true)
        #expect(try self.groups(try usagePayload(reply))[0]["title"] as? String == longName)
    }

    @Test
    func oversizedResponseReturnsClearErrorInsteadOfTruncatedJSON() async throws {
        let (store, directory) = try makeStore()
        defer { cleanup(directory) }
        let hugeName = String(repeating: "x", count: 1_500_000)
        let store1 = store.usageStore
        store1.record(record(timestamp: day(2026, 5, 10, hour: 9), routeName: hugeName, input: 1, output: 1))
        try await store1.flush()

        let reply = try await send(store, ["command": "usage"], now: day(2026, 5, 10))
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["usage"] == nil)
        #expect((reply["message"] as? String)?.contains("too large") == true)
    }

    // MARK: - legacy 行为

    @Test
    func asyncDispatchDelegatesLegacyListAndSet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-usage-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let one = RemoteModel(id: UUID(), name: "Alpha · one", apiKey: "secret", model: "one",
                              extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test/v1"))
        let two = RemoteModel(id: UUID(), name: "Beta · two", apiKey: "secret", model: "two",
                              extraHeaders: [:], apiEndpoints: one.apiEndpoints)
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: one.id)
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 0, remotes: [one, two], fakes: [fake])).write(to: url)
        let store = ConfigStore(configURL: url)

        let listReply = try await send(store, ["command": "list"], now: Date())
        #expect(listReply["ok"] as? Bool == true)
        #expect((listReply["providers"] as? [[String: Any]])?.count == 2)

        // 与同步实现返回一致。
        let syncList = store.handleCLICommand(try JSONSerialization.data(withJSONObject: ["command": "list"]))
        #expect((syncList["providers"] as? [[String: Any]])?.count == 2)

        let setReply = try await send(store, ["command": "set", "fakeID": "main",
                                        "provider": "Beta", "model": "two"], now: Date())
        #expect(setReply["ok"] as? Bool == true)
        #expect(store.router.route(fakeModelID: "main")?.remote.id == two.id)

        let unknown = try await send(store, ["command": "nope"], now: Date())
        #expect(unknown["ok"] as? Bool == false)
        #expect(unknown["message"] as? String == "unknown command")
    }

    // MARK: - 原始 sqlite 辅助（仅测试）

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

private extension ISO8601DateFormatter {
    static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
