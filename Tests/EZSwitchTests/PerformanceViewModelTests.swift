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
                         ttftP50: Double? = nil, ttftP95: Double? = nil,
                         requestP50: Double? = nil, requestP95: Double? = nil,
                         tpsP50: Double? = nil,
                         ttftSamples: Int = 0, tpsSamples: Int = 0,
                         requestSamples: Int = 0,
                         attempts: Int = 0) -> PerformanceGroupRow {
        var summary = PerformanceSummary()
        summary.attempts = attempts
        summary.ttftSamples = ttftSamples
        summary.tpsSamples = tpsSamples
        summary.requestTTFTSamples = requestSamples
        summary.ttftP50MS = ttftP50
        summary.ttftP95MS = ttftP95
        summary.requestTTFTP50MS = requestP50
        summary.requestTTFTP95MS = requestP95
        summary.tpsP50 = tpsP50
        return PerformanceGroupRow(id: title, title: title, subtitle: "", summary: summary)
    }

    private func makeSnapshot(attempts: Int,
                              ttftP50: Double? = nil,
                              requestSamples: Int = 0,
                              groups: [PerformanceGroupRow] = []) -> PerformanceSnapshot {
        var summary = PerformanceSummary()
        summary.attempts = attempts
        summary.successfulStreamingAttempts = attempts
        summary.ttftSamples = ttftP50 == nil ? 0 : attempts
        summary.requestTTFTSamples = requestSamples
        summary.ttftP50MS = ttftP50
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
            makeRow("c", ttftP50: 300),
            makeRow("none"),
            makeRow("a", ttftP50: 100),
            makeRow("b", ttftP50: 200),
        ]
        let sorted = PerformanceSort.sorted(rows, by: .ttftP50, grouping: .model, ascending: true)
        #expect(sorted.map(\.title) == ["a", "b", "c", "none"])
    }

    @Test func sortKeepsNilLastWhenDescending() {
        let rows = [
            makeRow("c", ttftP50: 300),
            makeRow("none"),
            makeRow("a", ttftP50: 100),
            makeRow("b", ttftP50: 200),
        ]
        let sorted = PerformanceSort.sorted(rows, by: .ttftP50, grouping: .model, ascending: false)
        #expect(sorted.map(\.title) == ["c", "b", "a", "none"])
    }

    /// 路由维度排序取 requestTTFT（含 fallback），其余维度取尝试 TTFT。
    @Test func sortUsesRequestTTFTForRouteGrouping() {
        let attemptFast = makeRow("attempt-fast", ttftP50: 10, requestP50: 900)
        let requestFast = makeRow("request-fast", ttftP50: 900, requestP50: 10)

        let byModel = PerformanceSort.sorted([requestFast, attemptFast], by: .ttftP50,
                                              grouping: .model, ascending: true)
        #expect(byModel.map(\.title) == ["attempt-fast", "request-fast"])

        let byRoute = PerformanceSort.sorted([requestFast, attemptFast], by: .ttftP50,
                                             grouping: .route, ascending: true)
        #expect(byRoute.map(\.title) == ["request-fast", "attempt-fast"])
    }

    @Test func sortIsStableByTitleOnTies() {
        let rows = [makeRow("zeta", ttftP50: 100), makeRow("alpha", ttftP50: 100)]
        let sorted = PerformanceSort.sorted(rows, by: .ttftP50, grouping: .model, ascending: true)
        #expect(sorted.map(\.title) == ["alpha", "zeta"])
    }

    @Test func sortByTPSUsesTPSValue() {
        let rows = [
            makeRow("slow", ttftP50: 100, tpsP50: 5),
            makeRow("fast", ttftP50: 900, tpsP50: 80),
        ]
        let sorted = PerformanceSort.sorted(rows, by: .tpsP50, grouping: .model, ascending: false)
        #expect(sorted.map(\.title) == ["fast", "slow"])
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
        #expect(model.performanceSortKey == .ttftP50)
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

    // MARK: - 空态判定

    @Test func emptyPredicatesDistinguishNoHistoryFromNoSamples() async {
        let model = UsageViewModel()
        #expect(model.performanceIsEmpty)
        #expect(!model.performanceHasNoSamples)

        await load(makeSnapshot(attempts: 0), into: model)
        #expect(model.performanceIsEmpty)

        // 有历史但全部是非流式/失败：无有效样本。
        await load(makeSnapshot(attempts: 5, ttftP50: nil), into: model)
        #expect(!model.performanceIsEmpty)
        #expect(model.performanceHasNoSamples)

        // 有样本：两者都不成立。
        await load(makeSnapshot(attempts: 5, ttftP50: 120), into: model)
        #expect(!model.performanceIsEmpty)
        #expect(!model.performanceHasNoSamples)
    }

    @Test func onlyTTFTWithoutTPSSamplesStillHasSamples() async {
        let model = UsageViewModel()
        var snapshot = makeSnapshot(attempts: 3, ttftP50: 200)
        snapshot.summary.tpsSamples = 0
        snapshot.summary.tpsP50 = nil
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

        var snapshot = makeSnapshot(attempts: 8, ttftP50: 150, requestSamples: 0)
        snapshot.summary.requestTTFTP50MS = nil
        snapshot.summary.requestTTFTP95MS = nil
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

        var snapshot = makeSnapshot(attempts: 6, ttftP50: 100, requestSamples: 0)
        snapshot.summary.requestTTFTP50MS = nil
        snapshot.summary.requestTTFTP95MS = nil
        snapshot.summary.tpsSamples = 6
        snapshot.summary.tpsP50 = 42
        await load(snapshot, into: model)

        #expect(!model.performanceIsEmpty)
        #expect(!model.performanceHasNoSamples)      // TPS 可用，仍显示明细表
        #expect(model.performanceActiveTTFTSamples == 0)
    }

    // MARK: - 加载成功 / 失败

    @Test func refreshPerformanceLoadsSnapshotAndMarksLoaded() async {
        let model = UsageViewModel()
        await load(makeSnapshot(attempts: 7, ttftP50: 321), into: model)

        #expect(model.performancePhase == .loaded)
        #expect(model.performanceSnapshot.summary.attempts == 7)
        #expect(model.performanceSnapshot.summary.ttftP50MS == 321)
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
        await load(makeSnapshot(attempts: 4, ttftP50: 100), into: model)
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

        let slow = makeSnapshot(attempts: 1, ttftP50: 999)
        let fast = makeSnapshot(attempts: 2, ttftP50: 111)

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
        #expect(model.performanceSnapshot.summary.ttftP50MS == 111)
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
            makeRow("b", ttftP50: 200, tpsP50: 20),
            makeRow("a", ttftP50: 100, tpsP50: 50),
        ]
        await load(snapshot, into: model)

        model.performanceSortKey = .tpsP50
        model.performanceSortAscending = false
        #expect(model.sortedPerformanceGroups.map(\.title) == ["a", "b"])

        model.performanceSortAscending = true
        #expect(model.sortedPerformanceGroups.map(\.title) == ["b", "a"])
    }
}
