import Foundation
import Testing
@testable import EZSwitch

/// 用量表（使用明细）的列头排序：名称自然序、数值列降序默认、
/// 未上报项恒定置后，以及 ViewModel 的排序状态机与真实取数后的行序。
@MainActor
@Suite("Usage table sorting")
struct UsageSortTests {

    // MARK: - 夹具

    private func makeRow(_ title: String,
                         input: Int = 0, inputAttempts: Int = 0,
                         output: Int = 0, outputAttempts: Int = 0,
                         cached: Int = 0, cachedAttempts: Int = 0,
                         attempts: Int = 1) -> UsageGroupRow {
        var totals = UsageTotals()
        totals.attempts = attempts
        totals.input = input
        totals.inputAttempts = inputAttempts
        totals.output = output
        totals.outputAttempts = outputAttempts
        totals.cachedInput = cached
        totals.cachedInputAttempts = cachedAttempts
        return UsageGroupRow(id: title, title: title, subtitle: "", totals: totals)
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-sort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.sqlite")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func record(routeID: String, routeName: String,
                        input: Int, output: Int) -> UsageRecord {
        UsageRecord(id: UUID(), requestID: UUID(), timestamp: Date().addingTimeInterval(-60),
                    routeID: routeID, routeName: routeName, remoteID: "remote-1",
                    provider: "OpenAI", model: "gpt-4o", endpoint: "chat", attempt: 1,
                    status: 200, outcome: "success", durationMS: 100,
                    tokens: UsageTokens(input: input, output: output), performance: nil)
    }

    // MARK: - 纯排序

    /// 名称按自然序：数字按数值大小而非逐字符（「路由 2」在「路由 10」前）。
    @Test func sortByNameUsesLocalizedNaturalOrder() {
        let rows = [makeRow("路由 10"), makeRow("路由 2")]

        let ascending = UsageSort.sorted(rows, by: .name, ascending: true)
        #expect(ascending.map(\.title) == ["路由 2", "路由 10"])

        let descending = UsageSort.sorted(rows, by: .name, ascending: false)
        #expect(descending.map(\.title) == ["路由 10", "路由 2"])
    }

    /// 输入 token 降序；未上报输入（inputAttempts == 0）即使数值更大也恒定置后。
    @Test func sortByInputPutsUnreportedRowsLast() {
        let rows = [
            makeRow("small", input: 100, inputAttempts: 1),
            makeRow("large", input: 500, inputAttempts: 1),
            makeRow("unknown", input: 9_999, inputAttempts: 0),
        ]

        let descending = UsageSort.sorted(rows, by: .input, ascending: false)
        #expect(descending.map(\.title) == ["large", "small", "unknown"])

        // 升序同样把未知行留在最后，不因方向翻转被顶到前面。
        let ascending = UsageSort.sorted(rows, by: .input, ascending: true)
        #expect(ascending.map(\.title) == ["small", "large", "unknown"])
    }

    @Test func sortByCachedPutsUnreportedRowsLast() {
        let rows = [
            makeRow("low", cached: 10, cachedAttempts: 1),
            makeRow("high", cached: 50, cachedAttempts: 1),
            makeRow("unknown", cached: 999, cachedAttempts: 0),
        ]

        let sorted = UsageSort.sorted(rows, by: .cached, ascending: false)
        #expect(sorted.map(\.title) == ["high", "low", "unknown"])
    }

    /// 缓存率未知（分母缺输入或缓存未上报）按 nil 置后；已知值按命中率降序。
    @Test func sortByCacheRatePutsUnknownRowsLast() {
        let rows = [
            makeRow("half", input: 100, inputAttempts: 5, cached: 50, cachedAttempts: 5),
            makeRow("most", input: 100, inputAttempts: 5, cached: 80, cachedAttempts: 5),
            makeRow("unknown", input: 100, inputAttempts: 5, cached: 0, cachedAttempts: 0),
        ]

        let sorted = UsageSort.sorted(rows, by: .cacheRate, ascending: false)
        #expect(sorted.map(\.title) == ["most", "half", "unknown"])
    }

    /// 同值按标题、再按 id 稳定 tie-break，与方向无关。
    @Test func sortTiesBreakByTitleThenID() {
        var first = makeRow("dup", input: 100, inputAttempts: 1)
        first.id = "b-id"
        var second = makeRow("dup", input: 100, inputAttempts: 1)
        second.id = "a-id"

        for ascending in [true, false] {
            let sorted = UsageSort.sorted([first, second], by: .input, ascending: ascending)
            #expect(sorted.map(\.id) == ["a-id", "b-id"])
        }
    }

    @Test func sortKeysHaveExpectedTitlesAndDefaults() {
        #expect(UsageSortKey.allCases.map(\.title) == ["名称", "输入", "输出", "缓存", "缓存率"])
        #expect(UsageSortKey.name.defaultAscending)
        #expect(!UsageSortKey.input.defaultAscending)
        #expect(!UsageSortKey.output.defaultAscending)
        #expect(!UsageSortKey.cached.defaultAscending)
        #expect(!UsageSortKey.cacheRate.defaultAscending)
    }

    // MARK: - ViewModel 状态机

    /// 初始不排序；首次点击用该列默认方向，再次点击翻转，换列回到新列默认方向。
    @Test func toggleUsesDefaultDirectionThenReverses() {
        let model = UsageViewModel()
        #expect(model.usageSortKey == nil)
        #expect(!model.usageSortAscending)

        model.toggleUsageSort(.input)
        #expect(model.usageSortKey == .input)
        #expect(!model.usageSortAscending)              // 数值列默认降序

        model.toggleUsageSort(.input)
        #expect(model.usageSortAscending)               // 同列再点反向

        model.toggleUsageSort(.name)
        #expect(model.usageSortKey == .name)
        #expect(model.usageSortAscending)               // 名称列默认升序

        model.toggleUsageSort(.input)
        #expect(!model.usageSortAscending)              // 换回数值列用默认方向
    }

    @Test func sortActiveFlagFollowsClickedColumn() {
        let model = UsageViewModel()
        #expect(!model.isUsageSortActive(.input))

        model.toggleUsageSort(.cacheRate)
        #expect(model.isUsageSortActive(.cacheRate))
        #expect(!model.isUsageSortActive(.name))
    }

    // MARK: - 端到端行序

    /// 未排序时保持后端默认顺序（总 Token 降序）；点击输入列后用输入量降序，且不进 reloadKey。
    @Test func sortedGroupsFollowHeaderClicksWithoutReload() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        // 总 Token：R1 1000 > R2 510 > R3 300；输入量：R2 500 > R3 300 > R1 100。
        store.record(record(routeID: "r1", routeName: "R1", input: 100, output: 900))
        store.record(record(routeID: "r2", routeName: "R2", input: 500, output: 10))
        store.record(record(routeID: "r3", routeName: "R3", input: 300, output: 0))
        try await store.flush()

        let model = UsageViewModel()
        model.preset = .today
        await model.refresh(store: store)

        let defaultOrder = model.scopedSnapshot?.groups.map(\.id) ?? []
        #expect(defaultOrder == ["r1", "r2", "r3"])
        #expect(model.sortedUsageGroups.map(\.id) == defaultOrder)

        let reloadKey = model.reloadKey
        model.toggleUsageSort(.input)
        #expect(model.sortedUsageGroups.map(\.id) == ["r2", "r3", "r1"])
        #expect(model.reloadKey == reloadKey)

        model.toggleUsageSort(.input)
        #expect(model.sortedUsageGroups.map(\.id) == ["r1", "r3", "r2"])

        model.toggleUsageSort(.name)
        #expect(model.sortedUsageGroups.map(\.id) == ["r1", "r2", "r3"])
        #expect(model.reloadKey == reloadKey)
    }
}
