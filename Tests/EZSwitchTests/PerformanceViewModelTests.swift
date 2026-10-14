import Foundation
import Testing
@testable import EZSwitch

/// 性能视图的排序、格式化、空态判定与刷新竞态。
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
                         attempts: Int = 0) -> PerformanceGroupRow {
        var summary = PerformanceSummary()
        summary.attempts = attempts
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

    /// 排序跟随所选列：含 TTFT 列在路由 / 模型维度取不同字段，不含 TTFT 列两维度共用。
    @Test func sortByTPSFollowsSelectedColumn() {
        let rows = [
            makeRow("slow", tpsIncluding: 5, tpsExcluding: 90),
            makeRow("fast", tpsIncluding: 80, tpsExcluding: 10),
        ]
        let byIncluding = PerformanceSort.sorted(rows, by: .tpsIncludingTTFT, grouping: .model, ascending: false)
        #expect(byIncluding.map(\.title) == ["fast", "slow"])

        let byExcluding = PerformanceSort.sorted(rows, by: .tpsExcludingTTFT, grouping: .model, ascending: false)
        #expect(byExcluding.map(\.title) == ["slow", "fast"])

        let routeRows = [
            makeRow("a", tpsIncluding: 100, requestTpsIncluding: 10),
            makeRow("b", tpsIncluding: 10, requestTpsIncluding: 100),
        ]
        let byRouteIncluding = PerformanceSort.sorted(routeRows, by: .tpsIncludingTTFT,
                                                      grouping: .route, ascending: false)
        #expect(byRouteIncluding.map(\.title) == ["b", "a"])
    }

    @Test func sortKeyTitlesUseTheThreeMetricNames() {
        #expect(PerformanceSortKey.ttftMean.title(for: .model) == "平均TTFT")
        #expect(PerformanceSortKey.tpsIncludingTTFT.title(for: .route) == "平均TPS(含TTFT)")
        #expect(PerformanceSortKey.tpsExcludingTTFT.columnTitle(for: .model) == "平均TPS(不含TTFT)")
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
            makeRow("b", ttftMean: 200, tpsExcluding: 20),
            makeRow("a", ttftMean: 100, tpsExcluding: 50),
        ]
        await load(snapshot, into: model)

        model.performanceSortKey = .tpsExcludingTTFT
        model.performanceSortAscending = false
        #expect(model.sortedPerformanceGroups.map(\.title) == ["a", "b"])

        model.performanceSortAscending = true
        #expect(model.sortedPerformanceGroups.map(\.title) == ["b", "a"])
    }
}
