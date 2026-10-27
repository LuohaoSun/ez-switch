import Foundation
import Testing
@testable import EZSwitch

/// 性能视图的排序（含列头点击）、格式化、空态判定与刷新竞态。
///
/// 数据源通过闭包注入 `refreshPerformance`，因此无需真实 SQLite 即可覆盖竞态与失败路径。
@MainActor
@Suite("Performance view model")
struct PerformanceViewModelTests {

    // MARK: - 夹具

    private struct LoadFailure: Error, LocalizedError {
        var errorDescription: String? { "查询失败" }
    }

    /// 可控闸门：让一次加载登记后挂起，测试再决定何时放行，用于构造乱序返回。
    private actor StepGate {
        private var arrived = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markArrivedAndWait() async {
            arrived = true
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func waitForArrival() async {
            var spins = 0
            while !arrived && spins < 2000 {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
        }

        func release() {
            released = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    private func makeRow(_ title: String,
                         ttftMean: Double? = nil, requestTTFTMean: Double? = nil,
                         tpsIncluding: Double? = nil, requestTpsIncluding: Double? = nil,
                         tpsExcluding: Double? = nil,
                         ttftSamples: Int = 0, tpsSamples: Int = 0,
                         requestSamples: Int = 0,
                         attempts: Int = 0, requests: Int = 0) -> PerformanceGroupRow {
        var summary = PerformanceSummary()
        summary.attempts = attempts
        summary.requests = requests
        summary.ttftSamples = ttftSamples
        summary.tpsSamples = tpsSamples
        summary.requestTTFTSamples = requestSamples
        summary.ttftMeanMS = ttftMean
        summary.requestTTFTMeanMS = requestTTFTMean
        summary.tpsIncludingTTFT = tpsIncluding
        summary.requestTpsIncludingTTFT = requestTpsIncluding
        summary.tpsExcludingTTFT = tpsExcluding
        return PerformanceGroupRow(id: title, title: title, subtitle: "", summary: summary)
    }

    private func makeSnapshot(attempts: Int,
                              ttftMean: Double? = nil,
                              requestSamples: Int = 0,
                              groups: [PerformanceGroupRow] = []) -> PerformanceSnapshot {
        var summary = PerformanceSummary()
        summary.attempts = attempts
        summary.successfulStreamingAttempts = attempts
        summary.ttftSamples = ttftMean == nil ? 0 : attempts
        summary.requestTTFTSamples = requestSamples
        summary.ttftMeanMS = ttftMean
        return PerformanceSnapshot(summary: summary, groups: groups)
    }

    /// 通过真实刷新路径注入快照（生产代码同一入口，避免为测试开后门）。
    @discardableResult
    private func load(_ snapshot: PerformanceSnapshot, into model: UsageViewModel) async -> UsageViewModel {
        await model.refreshPerformance { _, _, _ in snapshot }
        return model
    }

    /// 等待性能选中取数结束（提交或失败）。
    private func waitForPerformanceSelection(_ model: UsageViewModel,
                                             timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !model.performanceSelectionIsLoading,
               model.performanceSelectionSnapshot != nil || model.performanceSelectionError != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func dayPoint(_ date: Date, requests: Int = 1) -> UsageDay {
        UsageDay(date: date, input: 0, output: 0, requests: requests)
    }

    /// 首个调用慢、其后快：用于复现「旧选中响应迟到」的竞态。
    private final class CallGate: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func isFirstCall() -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls == 1
        }
    }

    // MARK: - 排序

    @Test func sortOrdersByKeyAndKeepsNilLastWhenAscending() {
        let rows = [
            makeRow("c", ttftMean: 300),
            makeRow("none"),
            makeRow("a", ttftMean: 100),
            makeRow("b", ttftMean: 200),
        ]
        let sorted = PerformanceSort.sorted(rows, by: .ttftMean, grouping: .model, ascending: true)
        #expect(sorted.map(\.title) == ["a", "b", "c", "none"])
    }

    @Test func sortKeepsNilLastWhenDescending() {
        let rows = [
            makeRow("c", ttftMean: 300),
            makeRow("none"),
            makeRow("a", ttftMean: 100),
            makeRow("b", ttftMean: 200),
        ]
        let sorted = PerformanceSort.sorted(rows, by: .ttftMean, grouping: .model, ascending: false)
        #expect(sorted.map(\.title) == ["c", "b", "a", "none"])
    }

    /// 路由维度排序取 requestTTFTMean（含 fallback），其余维度取尝试 TTFTMean。
    @Test func sortUsesRequestTTFTMeanForRouteGrouping() {
        let attemptFast = makeRow("attempt-fast", ttftMean: 10, requestTTFTMean: 900)
        let requestFast = makeRow("request-fast", ttftMean: 900, requestTTFTMean: 10)

        let byModel = PerformanceSort.sorted([requestFast, attemptFast], by: .ttftMean,
                                              grouping: .model, ascending: true)
        #expect(byModel.map(\.title) == ["attempt-fast", "request-fast"])

        let byRoute = PerformanceSort.sorted([requestFast, attemptFast], by: .ttftMean,
                                             grouping: .route, ascending: true)
        #expect(byRoute.map(\.title) == ["request-fast", "attempt-fast"])
    }

    @Test func sortIsStableByTitleOnTies() {
        let rows = [makeRow("zeta", ttftMean: 100), makeRow("alpha", ttftMean: 100)]
        let sorted = PerformanceSort.sorted(rows, by: .ttftMean, grouping: .model, ascending: true)
        #expect(sorted.map(\.title) == ["alpha", "zeta"])
    }

    /// 排序跟随所选列：含 TTFT 列在路由 / 模型维度取不同字段。
    @Test func sortByTPSFollowsSelectedColumn() {
        let rows = [
            makeRow("slow", tpsIncluding: 5),
            makeRow("fast", tpsIncluding: 80),
        ]
        let byIncluding = PerformanceSort.sorted(rows, by: .tpsIncludingTTFT, grouping: .model, ascending: false)
        #expect(byIncluding.map(\.title) == ["fast", "slow"])

        let routeRows = [
            makeRow("a", tpsIncluding: 100, requestTpsIncluding: 10),
            makeRow("b", tpsIncluding: 10, requestTpsIncluding: 100),
        ]
        let byRouteIncluding = PerformanceSort.sorted(routeRows, by: .tpsIncludingTTFT,
                                                      grouping: .route, ascending: false)
        #expect(byRouteIncluding.map(\.title) == ["b", "a"])

        // 不含 TTFT 的吞吐两维度共用同一字段；无样本的行恒定置后。
        let excludingRows = [
            makeRow("gen-slow", tpsExcluding: 10),
            makeRow("unmeasured"),
            makeRow("gen-fast", tpsExcluding: 60),
        ]
        for grouping in [UsageGrouping.route, .provider, .model] {
            let sorted = PerformanceSort.sorted(excludingRows, by: .tpsExcludingTTFT,
                                                grouping: grouping, ascending: false)
            #expect(sorted.map(\.title) == ["gen-fast", "gen-slow", "unmeasured"])
        }
    }

    @Test func sortKeyTitlesUseTheMetricNames() {
        #expect(PerformanceSortKey.ttftMean.title(for: .model) == "平均TTFT")
        #expect(PerformanceSortKey.tpsIncludingTTFT.title(for: .route) == "平均TPS(含TTFT)")
        #expect(PerformanceSortKey.tpsExcludingTTFT.title(for: .route) == "平均TPS(不含TTFT)")
    }

    /// 名称列按自然序比较：数字按数值大小而非逐字符（「路由 2」在「路由 10」前），降序只是反转。
    @Test func sortByNameUsesLocalizedNaturalOrder() {
        let rows = [makeRow("路由 10"), makeRow("路由 2")]
        let ascending = PerformanceSort.sorted(rows, by: .name, grouping: .model, ascending: true)
        #expect(ascending.map(\.title) == ["路由 2", "路由 10"])

        let descending = PerformanceSort.sorted(rows, by: .name, grouping: .model, ascending: false)
        #expect(descending.map(\.title) == ["路由 10", "路由 2"])
    }

    /// 名称相同的行按 id 稳定 tie-break，与方向无关。
    @Test func sortByNameBreaksTiesByID() {
        var first = makeRow("dup")
        first.id = "b-id"
        var second = makeRow("dup")
        second.id = "a-id"

        for ascending in [true, false] {
            let sorted = PerformanceSort.sorted([first, second], by: .name,
                                                grouping: .model, ascending: ascending)
            #expect(sorted.map(\.id) == ["a-id", "b-id"])
        }
    }

    /// 请求数走数值路径且恒为已知值：0 请求也参与排序，不会被当成未知置后。
    @Test func sortByRequestsOrdersByDeduplicatedCount() {
        let rows = [makeRow("few", requests: 2), makeRow("many", requests: 50), makeRow("none", requests: 0)]

        let descending = PerformanceSort.sorted(rows, by: .requests, grouping: .model, ascending: false)
        #expect(descending.map(\.title) == ["many", "few", "none"])

        let ascending = PerformanceSort.sorted(rows, by: .requests, grouping: .model, ascending: true)
        #expect(ascending.map(\.title) == ["none", "few", "many"])
    }

    @Test func nameAndRequestColumnsHaveExpectedDefaultsAndTitles() {
        #expect(PerformanceSortKey.name.defaultAscending)
        #expect(!PerformanceSortKey.requests.defaultAscending)
        #expect(PerformanceSortKey.name.title(for: .model) == "名称")
        #expect(PerformanceSortKey.requests.columnTitle(for: .route) == "请求")
    }

    /// 同值 tie-break 与方向无关：先按标题，再按 id；点列头反复切换也不会抖动。
    @Test func tiesBreakByTitleThenIDRegardlessOfDirection() {
        let rows = [makeRow("zeta", tpsIncluding: 50), makeRow("alpha", tpsIncluding: 50)]
        for ascending in [true, false] {
            let sorted = PerformanceSort.sorted(rows, by: .tpsIncludingTTFT,
                                                grouping: .model, ascending: ascending)
            #expect(sorted.map(\.title) == ["alpha", "zeta"])
        }
    }

    @Test func tiesBreakByIDWhenTitlesMatch() {
        var first = makeRow("dup", tpsIncluding: 50)
        first.id = "b-id"
        var second = makeRow("dup", tpsIncluding: 50)
        second.id = "a-id"

        let sorted = PerformanceSort.sorted([first, second], by: .tpsIncludingTTFT,
                                             grouping: .model, ascending: false)
        #expect(sorted.map(\.id) == ["a-id", "b-id"])
    }

    /// 非有限值（NaN / 无穷）与 nil 同样视为未知：既不参与比较，也不随排序算法漂移。
    @Test func nonFiniteValuesSortAsUnknownAndStayLast() {
        let rows = [
            makeRow("nan", tpsIncluding: .nan),
            makeRow("slow", tpsIncluding: 10),
            makeRow("infinite", tpsIncluding: .infinity),
            makeRow("fast", tpsIncluding: 90),
            makeRow("none"),
        ]

        let ascending = PerformanceSort.sorted(rows, by: .tpsIncludingTTFT,
                                               grouping: .model, ascending: true)
        #expect(ascending.map(\.title) == ["slow", "fast", "infinite", "nan", "none"])

        let descending = PerformanceSort.sorted(rows, by: .tpsIncludingTTFT,
                                                grouping: .model, ascending: false)
        #expect(descending.map(\.title) == ["fast", "slow", "infinite", "nan", "none"])
    }

    // MARK: - 列头点击排序

    /// 首次点击某列用该列默认方向：延迟类越小越好（升序），吞吐类越大越好（降序）。
    @Test func columnDefaultsPutTheBetterValueFirst() {
        #expect(PerformanceSortKey.ttftMean.defaultAscending)
        #expect(!PerformanceSortKey.tpsIncludingTTFT.defaultAscending)
        #expect(!PerformanceSortKey.tpsExcludingTTFT.defaultAscending)
    }

    /// 换列用该列默认方向（不沿用上一列方向）；同列再点反向，键保持不变。
    @Test func clickingColumnSwitchesThenReverses() {
        let model = UsageViewModel()
        #expect(model.performanceSortKey == .ttftMean)
        #expect(model.performanceSortAscending)

        model.togglePerformanceSort(.tpsIncludingTTFT)
        #expect(model.performanceSortKey == .tpsIncludingTTFT)
        #expect(!model.performanceSortAscending)          // 吞吐列默认降序

        model.togglePerformanceSort(.tpsIncludingTTFT)
        #expect(model.performanceSortKey == .tpsIncludingTTFT)
        #expect(model.performanceSortAscending)           // 同列再点反向

        model.togglePerformanceSort(.ttftMean)
        #expect(model.performanceSortKey == .ttftMean)
        #expect(model.performanceSortAscending)           // 回到该列默认，而非沿用上一列方向

        model.togglePerformanceSort(.ttftMean)
        #expect(!model.performanceSortAscending)
    }

    @Test func sortActiveFlagFollowsClickedColumn() {
        let model = UsageViewModel()
        #expect(model.isPerformanceSortActive(.ttftMean))
        #expect(!model.isPerformanceSortActive(.tpsIncludingTTFT))

        model.togglePerformanceSort(.tpsIncludingTTFT)
        #expect(model.isPerformanceSortActive(.tpsIncludingTTFT))
        #expect(!model.isPerformanceSortActive(.ttftMean))
    }

    /// 点击列头后的真实行序：TTFT 默认升序、同列再点降序，换 TPS 列用降序默认。
    @Test func sortedPerformanceGroupsFollowHeaderClicks() async {
        let model = UsageViewModel()
        var snapshot = PerformanceSnapshot()
        snapshot.groups = [
            makeRow("slow", ttftMean: 300, tpsIncluding: 90),
            makeRow("fast", ttftMean: 100, tpsIncluding: 10),
        ]
        await load(snapshot, into: model)

        // 默认按平均 TTFT 升序（快者在前，与总览"越小越好"一致）。
        #expect(model.sortedPerformanceGroups.map(\.title) == ["fast", "slow"])

        model.togglePerformanceSort(.ttftMean)
        #expect(model.sortedPerformanceGroups.map(\.title) == ["slow", "fast"])

        model.togglePerformanceSort(.tpsIncludingTTFT)
        #expect(model.sortedPerformanceGroups.map(\.title) == ["slow", "fast"])   // 吞吐默认降序

        model.togglePerformanceSort(.tpsIncludingTTFT)
        #expect(model.sortedPerformanceGroups.map(\.title) == ["fast", "slow"])
    }

    /// 无论点哪一列、朝哪个方向，未测/未知行恒定排在最后（不因降序被顶到前面）。
    @Test func headerClicksKeepUnknownRowsLastInBothDirections() async {
        let model = UsageViewModel()
        var snapshot = PerformanceSnapshot()
        snapshot.groups = [
            makeRow("measured-slow", tpsIncluding: 10),
            makeRow("unknown"),
            makeRow("measured-fast", tpsIncluding: 90),
        ]
        await load(snapshot, into: model)

        model.togglePerformanceSort(.tpsIncludingTTFT)
        #expect(model.sortedPerformanceGroups.map(\.title) == ["measured-fast", "measured-slow", "unknown"])

        model.togglePerformanceSort(.tpsIncludingTTFT)
        #expect(model.sortedPerformanceGroups.map(\.title) == ["measured-slow", "measured-fast", "unknown"])
    }

    /// 点列头排序不改变分组、也不触发重新查询（排序只在本地派生行序）。
    @Test func headerClicksDoNotChangeGroupingOrReloadKey() async {
        let model = UsageViewModel()
        var snapshot = PerformanceSnapshot()
        snapshot.summary.attempts = 4
        snapshot.groups = [makeRow("a", ttftMean: 1), makeRow("b", ttftMean: 2)]
        await load(snapshot, into: model)

        let reloadKey = model.reloadKey
        model.togglePerformanceSort(.tpsIncludingTTFT)
        model.togglePerformanceSort(.tpsIncludingTTFT)

        #expect(model.performanceGrouping == .model)
        #expect(model.reloadKey == reloadKey)
        #expect(model.performanceSnapshot.summary.attempts == 4)
    }

    // MARK: - 格式化

    @Test func millisecondsFormattingUsesDashForUnknownAndScalesUnits() {
        #expect(PerformanceFormat.milliseconds(nil) == "—")
        #expect(PerformanceFormat.milliseconds(.nan) == "—")
        #expect(PerformanceFormat.milliseconds(-1) == "—")
        #expect(PerformanceFormat.milliseconds(250.4) == "250 ms")
        #expect(PerformanceFormat.milliseconds(1500) == "1.50 s")
    }

    @Test func tpsFormattingUsesDashForUnknown() {
        #expect(PerformanceFormat.tps(nil) == "—")
        #expect(PerformanceFormat.tps(-0.1) == "—")
        #expect(PerformanceFormat.tps(12.34) == "12.3")
    }

    @Test func samplesFormattingShowsZero() {
        #expect(PerformanceFormat.samples(0) == "0")
        #expect(PerformanceFormat.samples(1500) == "1.5k")
    }

    // MARK: - 默认值与 reloadKey

    @Test func defaultsPreferModelGroupingAndIndependentFromUsageGrouping() {
        let model = UsageViewModel()
        #expect(model.section == .usage)
        #expect(model.performanceGrouping == .model)
        #expect(model.grouping == .route)
        #expect(model.performanceSortKey == .ttftMean)
        #expect(model.performanceSortAscending)
    }

    /// 侧栏入口通过 init(section:) 决定初始视图：
    /// 性能入口直接以性能 section 起步（reloadKey 区别于用量入口），无需 onAppear 重置。
    @Test func initSectionSelectsEntryView() {
        let usageEntry = UsageViewModel(section: .usage)
        #expect(usageEntry.section == .usage)

        let performanceEntry = UsageViewModel(section: .performance)
        #expect(performanceEntry.section == .performance)
        #expect(performanceEntry.reloadKey != usageEntry.reloadKey)
    }

    @Test func reloadKeyTracksSectionAndPerformanceGrouping() {
        let model = UsageViewModel()
        let base = model.reloadKey

        model.performanceGrouping = .route
        #expect(model.reloadKey != base)

        let afterGrouping = model.reloadKey
        model.section = .performance
        #expect(model.reloadKey != afterGrouping)

        // 改回两者，reloadKey 回到初始值（性能分组与用量分组互不影响）。
        model.section = .usage
        model.performanceGrouping = .model
        #expect(model.reloadKey == base)
    }

    /// 自定义「近 N 天」变化时 reloadKey 必须变化以触发重查；非自定义预设下 N 不影响键。
    @Test func reloadKeyTracksCustomLastNDaysForCustomPreset() {
        let model = UsageViewModel()
        model.preset = .custom
        model.customLastNDays = 7
        let seven = model.reloadKey

        model.customLastNDays = 30
        #expect(model.reloadKey != seven)

        model.customLastNDays = 7
        #expect(model.reloadKey == seven)

        // 非自定义预设区间不含 N，编辑 N 不应触发无谓刷新。
        model.preset = .today
        let todayKey = model.reloadKey
        model.customLastNDays = 30
        #expect(model.reloadKey == todayKey)
    }

    /// 非法输入（空 / 非数字 / <1）不改变有效天数与 reloadKey，提交后回退到有效值。
    @Test func commitCustomLastNDaysInputRejectsInvalidWithoutChangingRange() {
        let model = UsageViewModel()
        model.preset = .custom
        model.customLastNDays = 7
        model.customLastNDaysInput = "7"
        let before = model.reloadKey

        model.customLastNDaysInput = "0"
        model.commitCustomLastNDaysInput()
        #expect(model.customLastNDays == 7)
        #expect(model.reloadKey == before)
        #expect(model.customLastNDaysInput == "7")

        model.customLastNDaysInput = "abc"
        model.commitCustomLastNDaysInput()
        #expect(model.customLastNDays == 7)
        #expect(model.customLastNDaysInput == "7")

        model.customLastNDaysInput = " 30 "
        model.commitCustomLastNDaysInput()
        #expect(model.customLastNDays == 30)
        #expect(model.customLastNDaysInput == "30")
        #expect(model.reloadKey != before)
    }

    @Test func setCustomLastNDaysClampsAndSyncsInput() {
        let model = UsageViewModel()
        model.preset = .custom
        model.setCustomLastNDays(0)
        #expect(model.customLastNDays == 1)
        #expect(model.customLastNDaysInput == "1")

        model.setCustomLastNDays(14)
        #expect(model.customLastNDays == 14)
        #expect(model.customLastNDaysInput == "14")
    }

    // MARK: - 请求数柱选中

    /// 点柱只收敛指标卡与性能明细；图表背后的整段快照保持不变。
    @Test func selectingRequestBarScopesCardsAndTableOnly() async {
        let model = UsageViewModel(section: .performance)
        let whole = makeSnapshot(attempts: 10, ttftMean: 300,
                                 groups: [makeRow("whole", ttftMean: 300, ttftSamples: 10, attempts: 10)])
        await load(whole, into: model)

        var scoped = makeSnapshot(attempts: 3, ttftMean: 120, requestSamples: 3,
                                  groups: [makeRow("scoped", ttftMean: 120, ttftSamples: 3, attempts: 3)])
        scoped.summary.requests = 2
        let day = Calendar.current.startOfDay(for: Date())
        let point = dayPoint(day, requests: 2)

        model.togglePerformanceSelection(at: point.date, points: [point], unit: .day) { _, _, _ in scoped }
        #expect(await waitForPerformanceSelection(model))

        #expect(model.performanceSelectedBucket?.date == point.date)
        #expect(model.scopedPerformanceSummary.attempts == 3)
        #expect(model.scopedPerformanceSummary.requests == 2)
        #expect(model.scopedPerformanceSummary.ttftMeanMS == 120)
        #expect(model.sortedPerformanceGroups.map(\.title) == ["scoped"])
        // 整段快照仍是图表与空态判定的依据。
        #expect(model.performanceSnapshot.summary.attempts == 10)
        #expect(!model.performanceIsEmpty)
    }

    /// 再次点击同一根柱回到整段；清除按钮走同一入口。
    @Test func clickingSelectedRequestBarAgainClearsSelection() async {
        let model = UsageViewModel(section: .performance)
        await load(makeSnapshot(attempts: 10, ttftMean: 300), into: model)
        let day = Calendar.current.startOfDay(for: Date())
        let point = dayPoint(day, requests: 1)
        let scoped = makeSnapshot(attempts: 2, ttftMean: 50)

        model.togglePerformanceSelection(at: point.date, points: [point], unit: .day) { _, _, _ in scoped }
        #expect(await waitForPerformanceSelection(model))
        #expect(model.performanceSelectedBucket != nil)

        model.togglePerformanceSelection(at: point.date, points: [point], unit: .day) { _, _, _ in scoped }
        #expect(model.performanceSelectedBucket == nil)
        #expect(model.performanceSelectionSnapshot == nil)
        #expect(model.scopedPerformanceSummary.attempts == 10)
    }

    /// 请求数为 0 的柱没有可钻取的请求，点击只清空现有选中。
    @Test func requestBarWithoutRequestsIsNotSelectable() {
        let model = UsageViewModel(section: .performance)
        let day = Calendar.current.startOfDay(for: Date())
        let empty = dayPoint(day, requests: 0)

        model.togglePerformanceSelection(at: empty.date, points: [empty], unit: .day) { _, _, _ in
            PerformanceSnapshot()
        }
        #expect(model.performanceSelectedBucket == nil)
        #expect(model.performancePendingBucket == nil)
    }

    /// 换性能分组后选中柱失去意义：回到整段并按新分组重新取数。
    @Test func changingPerformanceGroupingResetsSelection() async {
        let model = UsageViewModel(section: .performance)
        await load(makeSnapshot(attempts: 10, ttftMean: 300), into: model)
        let day = Calendar.current.startOfDay(for: Date())
        let point = dayPoint(day)
        let scoped = makeSnapshot(attempts: 2, ttftMean: 50)

        model.togglePerformanceSelection(at: point.date, points: [point], unit: .day) { _, _, _ in scoped }
        #expect(await waitForPerformanceSelection(model))
        #expect(model.performanceSelectedBucket != nil)

        model.performanceGrouping = .route
        await load(makeSnapshot(attempts: 10, ttftMean: 300), into: model)
        #expect(model.performanceSelectedBucket == nil)
        #expect(model.scopedPerformanceSummary.attempts == 10)
    }

    /// 整段有样本、但所选时段没有样本时，仍保留请求数并给出「暂无样本」提示。
    @Test func selectedBucketWithoutSamplesFlagsNoSamples() async {
        let model = UsageViewModel(section: .performance)
        await load(makeSnapshot(attempts: 10, ttftMean: 300), into: model)
        let day = Calendar.current.startOfDay(for: Date())
        let point = dayPoint(day, requests: 4)
        // 该时段有 4 次请求，但都不是成功流式样本。
        var scoped = makeSnapshot(attempts: 4, ttftMean: nil)
        scoped.summary.requests = 4

        model.togglePerformanceSelection(at: point.date, points: [point], unit: .day) { _, _, _ in scoped }
        #expect(await waitForPerformanceSelection(model))

        #expect(!model.performanceIsEmpty)       // 整段仍有历史
        #expect(model.performanceHasNoSamples)   // 但所选时段没有 TTFT/TPS 样本
        #expect(model.scopedPerformanceSummary.requests == 4)
        #expect(model.scopedPerformanceSummary.attempts == 4)
    }

    /// 迟到的旧选中响应不得覆盖更新的选中柱。
    @Test func lateRequestBarSelectionDoesNotOverrideNewerSelection() async {
        let model = UsageViewModel(section: .performance)
        await load(makeSnapshot(attempts: 10, ttftMean: 300), into: model)
        let calendar = Calendar.current
        let day1 = calendar.startOfDay(for: Date())
        let day2 = calendar.date(byAdding: .day, value: -1, to: day1)!
        let points = [dayPoint(day1), dayPoint(day2)]
        let first = makeSnapshot(attempts: 1, ttftMean: 999)
        let second = makeSnapshot(attempts: 2, ttftMean: 111)
        let gate = CallGate()

        model.togglePerformanceSelection(at: day1, points: points, unit: .day) { _, _, _ in
            if gate.isFirstCall() {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            return first
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        model.togglePerformanceSelection(at: day2, points: points, unit: .day) { _, _, _ in
            if gate.isFirstCall() {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            return second
        }
        #expect(await waitForPerformanceSelection(model))
        #expect(model.performanceSelectedBucket?.date == day2)
        #expect(model.scopedPerformanceSummary.ttftMeanMS == 111)

        // 迟到的旧响应到达后仍是第二次选择的数据。
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(model.performanceSelectedBucket?.date == day2)
        #expect(model.scopedPerformanceSummary.ttftMeanMS == 111)
    }

    /// 轮询刷新整段时，已提交的选中柱按自己的时段静默重取，不丢失也不退回整段。
    @Test func wholeRangeRefreshKeepsCommittedSelectionUpdated() async {
        let model = UsageViewModel(section: .performance)
        model.preset = .last7Days
        await load(makeSnapshot(attempts: 10, ttftMean: 300), into: model)
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -1,
                                to: calendar.startOfDay(for: Date()))!
        let point = dayPoint(day, requests: 1)
        let scoped = makeSnapshot(attempts: 2, ttftMean: 50)

        model.togglePerformanceSelection(at: point.date, points: [point], unit: .day) { _, _, _ in scoped }
        #expect(await waitForPerformanceSelection(model))

        let refreshedScoped = makeSnapshot(attempts: 3, ttftMean: 77)
        await model.refreshPerformance { from, _, _ in
            from == day ? refreshedScoped : makeSnapshot(attempts: 11, ttftMean: 333)
        }

        #expect(model.performanceSelectedBucket?.date == day)
        #expect(model.scopedPerformanceSummary.attempts == 3)
        #expect(model.scopedPerformanceSummary.ttftMeanMS == 77)
        #expect(model.performanceSnapshot.summary.attempts == 11)
    }

    // MARK: - 空态判定

    @Test func emptyPredicatesDistinguishNoHistoryFromNoSamples() async {
        let model = UsageViewModel()
        #expect(model.performanceIsEmpty)
        #expect(!model.performanceHasNoSamples)

        await load(makeSnapshot(attempts: 0), into: model)
        #expect(model.performanceIsEmpty)

        // 有历史但全部是非流式/失败：无有效样本。
        await load(makeSnapshot(attempts: 5, ttftMean: nil), into: model)
        #expect(!model.performanceIsEmpty)
        #expect(model.performanceHasNoSamples)

        // 有样本：两者都不成立。
        await load(makeSnapshot(attempts: 5, ttftMean: 120), into: model)
        #expect(!model.performanceIsEmpty)
        #expect(!model.performanceHasNoSamples)
    }

    @Test func onlyTTFTWithoutTPSSamplesStillHasSamples() async {
        let model = UsageViewModel()
        var snapshot = makeSnapshot(attempts: 3, ttftMean: 200)
        snapshot.summary.tpsSamples = 0
        snapshot.summary.tpsIncludingTTFT = nil
        await load(snapshot, into: model)
        #expect(!model.performanceIsEmpty)
        #expect(!model.performanceHasNoSamples)
    }

    /// 路由维度以 requestTTFT 样本为准：旧历史有尝试 TTFT、但没有含自动回退的 request 样本时，
    /// 路由维度不得虚报样本，也不应显示为空历史。
    @Test func routeSamplesUseRequestTTFTAndDoNotClaimAttemptSamples() async {
        let model = UsageViewModel()
        model.section = .performance
        model.performanceGrouping = .route

        var snapshot = makeSnapshot(attempts: 8, ttftMean: 150, requestSamples: 0)
        snapshot.summary.requestTTFTMeanMS = nil
        await load(snapshot, into: model)

        #expect(!model.performanceIsEmpty)          // 有历史
        #expect(model.performanceHasNoSamples)       // 但路由维度无有效样本
        #expect(model.performanceActiveTTFTSamples == 0)

        // 供应商 / 模型维度仍保留尝试 TTFT 样本。
        model.performanceGrouping = .model
        #expect(!model.performanceHasNoSamples)
        #expect(model.performanceActiveTTFTSamples == 8)
    }

    /// 路由维度无 requestTTFT 样本、但 TPS 仍可用时，不得进入空态掩盖可用 TPS。
    @Test func routeWithoutRequestTTFTButWithTPSSamplesStillShowsData() async {
        let model = UsageViewModel()
        model.section = .performance
        model.performanceGrouping = .route

        var snapshot = makeSnapshot(attempts: 6, ttftMean: 100, requestSamples: 0)
        snapshot.summary.requestTTFTMeanMS = nil
        snapshot.summary.tpsSamples = 6
        snapshot.summary.tpsIncludingTTFT = 42
        await load(snapshot, into: model)

        #expect(!model.performanceIsEmpty)
        #expect(!model.performanceHasNoSamples)      // TPS 可用，仍显示明细表
        #expect(model.performanceActiveTTFTSamples == 0)
    }

    // MARK: - 加载成功 / 失败

    @Test func refreshPerformanceLoadsSnapshotAndMarksLoaded() async {
        let model = UsageViewModel()
        await load(makeSnapshot(attempts: 7, ttftMean: 321), into: model)

        #expect(model.performancePhase == .loaded)
        #expect(model.performanceSnapshot.summary.attempts == 7)
        #expect(model.performanceSnapshot.summary.ttftMeanMS == 321)
        #expect(model.performanceLastError == nil)
    }

    @Test func refreshPerformanceFailureWithoutPriorDataShowsError() async {
        let model = UsageViewModel()
        await model.refreshPerformance { _, _, _ in throw LoadFailure() }

        #expect(model.performanceLastError == "查询失败")
        guard case .failed = model.performancePhase else {
            Issue.record("无旧数据时应进入 failed 态，实际 \(model.performancePhase)")
            return
        }
    }

    @Test func refreshFailureKeepsPreviousSnapshot() async {
        let model = UsageViewModel()
        await load(makeSnapshot(attempts: 4, ttftMean: 100), into: model)
        await model.refreshPerformance { _, _, _ in throw LoadFailure() }

        #expect(model.performancePhase == .loaded)
        #expect(model.performanceSnapshot.summary.attempts == 4)
        #expect(model.performanceLastError == "查询失败")
    }

    // MARK: - 竞态

    /// 旧筛选的慢查询晚到，不得覆盖已切换筛选后的新结果。
    @Test func slowerStaleRefreshDoesNotOverwriteNewerFilter() async {
        let model = UsageViewModel()
        model.section = .performance
        model.performanceGrouping = .model

        let slow = makeSnapshot(attempts: 1, ttftMean: 999)
        let fast = makeSnapshot(attempts: 2, ttftMean: 111)

        let gate = StepGate()
        let stale = Task { @MainActor in
            await model.refreshPerformance { _, _, _ in
                await gate.markArrivedAndWait()
                return slow
            }
        }

        await gate.waitForArrival()

        // 切换性能分组 -> reloadKey 变化；新查询立即返回。
        model.performanceGrouping = .route
        await model.refreshPerformance { _, _, _ in fast }

        await gate.release()
        await stale.value

        #expect(model.performanceSnapshot.summary.attempts == 2)
        #expect(model.performanceSnapshot.summary.ttftMeanMS == 111)
        #expect(model.performancePhase == .loaded)
    }

    /// 同一筛选的两次加载按后到覆盖先到，验证非竞态路径。
    @Test func sequentialRefreshesApplyLatestResult() async {
        let model = UsageViewModel()
        await load(makeSnapshot(attempts: 1), into: model)
        await load(makeSnapshot(attempts: 9), into: model)
        #expect(model.performanceSnapshot.summary.attempts == 9)
    }

    // MARK: - 视图派生

    @Test func sortedPerformanceGroupsUsesCurrentKeyAndDirection() async {
        let model = UsageViewModel()
        var snapshot = PerformanceSnapshot()
        snapshot.groups = [
            makeRow("b", ttftMean: 200, tpsIncluding: 20),
            makeRow("a", ttftMean: 100, tpsIncluding: 50),
        ]
        await load(snapshot, into: model)

        model.performanceSortKey = .tpsIncludingTTFT
        model.performanceSortAscending = false
        #expect(model.sortedPerformanceGroups.map(\.title) == ["a", "b"])

        model.performanceSortAscending = true
        #expect(model.sortedPerformanceGroups.map(\.title) == ["b", "a"])
    }
}
