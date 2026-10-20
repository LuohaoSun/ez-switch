import Foundation
import Testing
@testable import EZSwitch

/// 图表选中与用量页的联动：卡片与明细收敛到所选柱、图表保留整个区间序列、
/// 选择的重置与迟到响应防护、缓存命中率口径。
/// 只使用临时目录数据库，不触碰真实配置或用户数据。
@Suite("Usage selection")
@MainActor
struct UsageSelectionTests {

    // MARK: - 夹具

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.sqlite")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func record(timestamp: Date, routeID: String, routeName: String,
                        input: Int?, output: Int?, cached: Int? = nil) -> UsageRecord {
        UsageRecord(id: UUID(), requestID: UUID(), timestamp: timestamp, routeID: routeID,
                    routeName: routeName, remoteID: "remote-1", provider: "OpenAI", model: "gpt-4o",
                    endpoint: "chat", attempt: 1, status: 200, outcome: "success", durationMS: 100,
                    tokens: UsageTokens(input: input, output: output, cachedInput: cached),
                    performance: nil)
    }

    private func localMidnight(daysAgo: Int, from now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -daysAgo, to: today)!
    }

    private func storeLoader(_ store: UsageStore) -> @Sendable (Date, Date, UsageGrouping) async throws -> UsageSnapshot {
        { from, to, grouping in
            try await store.snapshot(from: from, to: to, grouping: grouping)
        }
    }

    /// 等待选中取数结束（提交或失败）。
    private func waitForSelection(_ model: UsageViewModel, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !model.selectionIsLoading,
               model.selectionSnapshot != nil || model.selectionError != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    /// 让取数停在「进行中」，便于观察提交前的旧 scope。
    private final class LoadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func waitIfHeld() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            released = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    private struct LoadFailure: Error, Sendable {}

    /// 首个调用慢、其后快：用于复现「旧响应迟到」的竞态。
    private final class CallGate: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func isFirstCall() -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls == 1
        }
    }

    // MARK: - 按日选择

    @Test func selectingDayBarScopesSummaryAndGroupsToThatBucket() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        let day1 = localMidnight(daysAgo: 2)
        let day2 = localMidnight(daysAgo: 1)
        store.record(record(timestamp: day1.addingTimeInterval(10 * 3600), routeID: "r1",
                            routeName: "R1", input: 100, output: 10, cached: 40))
        store.record(record(timestamp: day1.addingTimeInterval(11 * 3600), routeID: "r2",
                            routeName: "R2", input: 200, output: 20, cached: 0))
        store.record(record(timestamp: day2.addingTimeInterval(10 * 3600), routeID: "r1",
                            routeName: "R1", input: 500, output: 50, cached: 300))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)

        #expect(model.snapshot.days.count == 2)
        #expect(model.snapshot.totals.input == 800)
        #expect(model.snapshot.groups.count == 2)

        let day2Point = try #require(model.snapshot.days.first { $0.input == 500 })
        model.toggleSelection(at: day2Point.date, points: model.snapshot.days, unit: .day,
                              load: storeLoader(store))
        #expect(await waitForSelection(model))

        // 卡片与明细收敛到所选的那一天。
        #expect(model.scopedSnapshot?.totals.input == 500)
        #expect(model.scopedSnapshot?.totals.output == 50)
        #expect(model.scopedSnapshot?.totals.cachedInput == 300)
        #expect(model.scopedSnapshot?.groups.count == 1)
        #expect(model.scopedSnapshot?.groups.first?.title == "R1")
        // 图表序列仍是整个区间：两根柱都还在，合计不变。
        #expect(model.snapshot.days.count == 2)
        #expect(model.snapshot.totals.input == 800)
    }

    @Test func selectingSameDayBarTwiceClearsBackToFullRange() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        let day1 = localMidnight(daysAgo: 1)
        store.record(record(timestamp: day1.addingTimeInterval(10 * 3600), routeID: "r1",
                            routeName: "R1", input: 100, output: 10))
        store.record(record(timestamp: localMidnight(daysAgo: 2).addingTimeInterval(10 * 3600),
                            routeID: "r2", routeName: "R2", input: 400, output: 40))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)

        let point = try #require(model.snapshot.days.first { $0.input == 100 })
        model.toggleSelection(at: point.date, points: model.snapshot.days, unit: .day,
                              load: storeLoader(store))
        #expect(await waitForSelection(model))
        #expect(model.scopedSnapshot?.totals.input == 100)

        // 再次点击同一根柱 → 回到整个区间。
        model.toggleSelection(at: point.date, points: model.snapshot.days, unit: .day,
                              load: storeLoader(store))
        #expect(model.selectedBucket == nil)
        #expect(model.selectionSnapshot == nil)
        #expect(model.scopedSnapshot?.totals.input == 500)
    }

    @Test func otherBarsRemainSelectableWhileOneIsSelected() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 2).addingTimeInterval(10 * 3600),
                            routeID: "r1", routeName: "R1", input: 300, output: 30))
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(10 * 3600),
                            routeID: "r2", routeName: "R2", input: 500, output: 50))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)
        let days = model.snapshot.days
        #expect(days.count == 2)

        model.toggleSelection(at: days[0].date, points: days, unit: .day, load: storeLoader(store))
        #expect(await waitForSelection(model))
        #expect(model.scopedSnapshot?.totals.input == 300)

        // 选中一根柱不会裁掉序列：另一根柱依然可选，且数据随之切换。
        model.toggleSelection(at: days[1].date, points: days, unit: .day, load: storeLoader(store))
        #expect(await waitForSelection(model))
        #expect(model.scopedSnapshot?.totals.input == 500)
        #expect(model.snapshot.days.count == 2)
    }

    // MARK: - 按小时选择

    @Test func selectingHourBarScopesSummaryAndGroupsToThatHour() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let hourStart = try #require(calendar.dateInterval(of: .hour, for: now)).start
        let previousHour = try #require(calendar.dateInterval(of: .hour, for: now.addingTimeInterval(-3600))).start
        // 上一小时若已跨过零点则不在「今天」区间内，断言相应放宽。
        let previousInRange = previousHour >= todayStart

        store.record(record(timestamp: hourStart.addingTimeInterval(30), routeID: "r1",
                            routeName: "R1", input: 100, output: 10))
        if previousInRange {
            store.record(record(timestamp: previousHour.addingTimeInterval(30), routeID: "r2",
                                routeName: "R2", input: 700, output: 70))
        }
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .today
        await model.refresh(store: store)

        let hourPoint = try #require(model.snapshot.hours.first { $0.input == 100 })
        model.toggleSelection(at: hourPoint.date, points: model.snapshot.hours, unit: .hour,
                              load: storeLoader(store))
        #expect(await waitForSelection(model))

        #expect(model.scopedSnapshot?.totals.input == 100)
        #expect(model.scopedSnapshot?.totals.output == 10)
        #expect(model.scopedSnapshot?.groups.count == 1)
        #expect(model.scopedSnapshot?.groups.first?.title == "R1")
        if previousInRange {
            #expect(model.snapshot.totals.input == 800)
        }
    }

    // MARK: - 原子提交（选中不塌陷）

    @Test func selectingKeepsPreviousScopeUntilNewSnapshotCommits() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 2).addingTimeInterval(3600),
                            routeID: "r1", routeName: "R1", input: 100, output: 10))
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(3600),
                            routeID: "r1", routeName: "R1", input: 500, output: 50))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)

        let point = try #require(model.snapshot.days.first { $0.input == 500 })
        let gate = LoadGate()
        model.toggleSelection(at: point.date, points: model.snapshot.days, unit: .day) { from, to, grouping in
            await gate.waitIfHeld()
            return try await store.snapshot(from: from, to: to, grouping: grouping)
        }

        // 取数未完成：仍展示整个区间，卡片与明细不塌成占位，也不会拿旧数据冒充新选择。
        #expect(model.pendingBucket?.date == point.date)
        #expect(model.selectedBucket == nil)
        #expect(model.selectionSnapshot == nil)
        #expect(model.scopedSnapshot?.totals.input == 600)
        #expect(model.scopedSnapshot?.groups.count == 1)

        gate.release()
        #expect(await waitForSelection(model))
        #expect(model.pendingBucket == nil)
        #expect(model.selectedBucket?.date == point.date)
        #expect(model.scopedSnapshot?.totals.input == 500)
    }

    @Test func changingBarKeepsCommittedScopeUntilNewBucketCommits() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        let day1 = localMidnight(daysAgo: 2)
        let day2 = localMidnight(daysAgo: 1)
        store.record(record(timestamp: day1.addingTimeInterval(3600), routeID: "r1",
                            routeName: "R1", input: 300, output: 30))
        store.record(record(timestamp: day2.addingTimeInterval(3600), routeID: "r2",
                            routeName: "R2", input: 500, output: 50))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)
        let days = model.snapshot.days

        model.toggleSelection(at: days[0].date, points: days, unit: .day, load: storeLoader(store))
        #expect(await waitForSelection(model))
        #expect(model.scopedSnapshot?.totals.input == 300)

        let gate = LoadGate()
        model.toggleSelection(at: days[1].date, points: days, unit: .day) { from, to, grouping in
            await gate.waitIfHeld()
            return try await store.snapshot(from: from, to: to, grouping: grouping)
        }

        // 换柱期间仍是上一根柱的已提交数据；图表高亮已切到新柱。
        #expect(model.selectedBucket?.date == days[0].date)
        #expect(model.pendingBucket?.date == days[1].date)
        #expect(model.activeBucket?.date == days[1].date)
        #expect(model.scopedSnapshot?.totals.input == 300)

        gate.release()
        #expect(await waitForSelection(model))
        #expect(model.selectedBucket?.date == days[1].date)
        #expect(model.scopedSnapshot?.totals.input == 500)
    }

    @Test func cancellingPendingSelectionDropsLateResponseAndKeepsPreviousScope() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 2).addingTimeInterval(3600),
                            routeID: "r1", routeName: "R1", input: 100, output: 10))
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(3600),
                            routeID: "r1", routeName: "R1", input: 500, output: 50))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)
        let days = model.snapshot.days

        let gate = LoadGate()
        let point = try #require(days.first { $0.input == 500 })
        model.toggleSelection(at: point.date, points: days, unit: .day) { from, to, grouping in
            await gate.waitIfHeld()
            return try await store.snapshot(from: from, to: to, grouping: grouping)
        }
        #expect(model.pendingBucket != nil)

        // 再点同一根柱取消取数：立即回到整个区间，不等待旧响应。
        model.toggleSelection(at: point.date, points: days, unit: .day, load: storeLoader(store))
        #expect(model.pendingBucket == nil)
        #expect(model.selectedBucket == nil)
        #expect(model.scopedSnapshot?.totals.input == 600)

        gate.release()
        try? await Task.sleep(nanoseconds: 200_000_000)
        // 迟到响应已被令牌作废，不会写回已取消的选择。
        #expect(model.selectedBucket == nil)
        #expect(model.selectionSnapshot == nil)
        #expect(model.scopedSnapshot?.totals.input == 600)
    }

    @Test func failedSelectionKeepsPreviousScopeAndReportsError() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(3600),
                            routeID: "r1", routeName: "R1", input: 500, output: 50))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)
        let point = try #require(model.snapshot.days.first)

        model.toggleSelection(at: point.date, points: model.snapshot.days, unit: .day) { _, _, _ in
            throw LoadFailure()
        }
        #expect(await waitForSelection(model))

        // 失败不改变已展示的 scope，也不把空快照当成选中柱。
        #expect(model.pendingBucket == nil)
        #expect(model.selectedBucket == nil)
        #expect(model.selectionSnapshot == nil)
        #expect(model.selectionError != nil)
        #expect(model.scopedSnapshot?.totals.input == 500)
    }

    // MARK: - 重置

    @Test func changingPresetResetsSelection() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(10 * 3600),
                            routeID: "r1", routeName: "R1", input: 100, output: 10))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)
        let point = try #require(model.snapshot.days.first)
        model.toggleSelection(at: point.date, points: model.snapshot.days, unit: .day,
                              load: storeLoader(store))
        #expect(await waitForSelection(model))
        #expect(model.selectedBucket != nil)

        // 换区间预设 → 已选的柱不再有意义。
        model.preset = .last30Days
        await model.refresh(store: store)
        #expect(model.selectedBucket == nil)
        #expect(model.selectionSnapshot == nil)
        #expect(model.scopedSnapshot?.totals.input == 100)
    }

    @Test func changingGranularityResetsSelection() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        let now = Date()
        store.record(record(timestamp: now, routeID: "r1", routeName: "R1", input: 100, output: 10))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .today
        await model.refresh(store: store)
        let hourPoint = try #require(model.snapshot.hours.first { $0.input == 100 })
        model.toggleSelection(at: hourPoint.date, points: model.snapshot.hours, unit: .hour,
                              load: storeLoader(store))
        #expect(await waitForSelection(model))
        #expect(model.selectedBucket != nil)

        // 「今天」(小时) → 「近 7 天」(天)：粒度变了，选中态重置。
        model.preset = .last7Days
        await model.refresh(store: store)
        #expect(model.selectedBucket == nil)
        #expect(model.scopedSnapshot?.totals.input == 100)
    }

    @Test func customRangeChangeResetsSelection() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(10 * 3600),
                            routeID: "r1", routeName: "R1", input: 100, output: 10))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .custom
        model.customLastNDays = 7
        await model.refresh(store: store)
        let point = try #require(model.snapshot.days.first)
        model.toggleSelection(at: point.date, points: model.snapshot.days, unit: .day,
                              load: storeLoader(store))
        #expect(await waitForSelection(model))
        #expect(model.selectedBucket != nil)

        model.customLastNDays = 30
        await model.refresh(store: store)
        #expect(model.selectedBucket == nil)
    }

    // MARK: - 竞态

    @Test func selectionOutsideCurrentRangeIsCleared() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let noon = try #require(calendar.date(byAdding: .hour, value: 12, to: today))
        store.record(record(timestamp: noon, routeID: "r1", routeName: "R1", input: 100, output: 10))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .today
        model.nowProvider = { today.addingTimeInterval(13 * 3600) }
        await model.refresh(store: store)

        let hourPoint = try #require(model.snapshot.hours.first { $0.input == 100 })
        model.toggleSelection(at: hourPoint.date, points: model.snapshot.hours, unit: .hour,
                              load: storeLoader(store))
        #expect(await waitForSelection(model))
        #expect(model.selectedBucket != nil)

        // 跨过零点：预设没变，但已选的小时桶已不在「今天」的区间内 → 重置。
        model.nowProvider = { today.addingTimeInterval(24 * 3600) }
        await model.refresh(store: store)
        #expect(model.selectedBucket == nil)
        #expect(model.selectionSnapshot == nil)
    }

    @Test func lateSelectionResponseDoesNotOverrideNewerSelection() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 2).addingTimeInterval(10 * 3600),
                            routeID: "r1", routeName: "R1", input: 300, output: 30))
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(10 * 3600),
                            routeID: "r2", routeName: "R2", input: 500, output: 50))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)
        let days = model.snapshot.days
        #expect(days.count == 2)

        let gate = CallGate()
        // 第一次选择慢，第二次选择快：迟到的第一次响应不得覆盖第二次的结果。
        model.toggleSelection(at: days[0].date, points: days, unit: .day) { from, to, grouping in
            if gate.isFirstCall() {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            return try await store.snapshot(from: from, to: to, grouping: grouping)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        model.toggleSelection(at: days[1].date, points: days, unit: .day) { from, to, grouping in
            if gate.isFirstCall() {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            return try await store.snapshot(from: from, to: to, grouping: grouping)
        }
        #expect(await waitForSelection(model))
        #expect(model.scopedSnapshot?.totals.input == 500)

        // 迟到的旧响应到达后仍然是第二次选择的数据。
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(model.selectedBucket?.date == days[1].date)
        #expect(model.scopedSnapshot?.totals.input == 500)
    }

    // MARK: - 分组刷新

    @Test func groupingChangeRefetchesCommittedSelection() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(3600),
                            routeID: "r1", routeName: "R1", input: 500, output: 50))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)
        let point = try #require(model.snapshot.days.first)
        model.toggleSelection(at: point.date, points: model.snapshot.days, unit: .day,
                              load: storeLoader(store))
        #expect(await waitForSelection(model))
        #expect(model.selectionSnapshot?.groups.first?.title == "R1")

        // 换分组后选中柱按新口径重取，不保留旧分组的行，也不进入加载态。
        model.grouping = .model
        await model.refreshUsage(store: store)
        #expect(model.pendingBucket == nil)
        #expect(model.selectionSnapshot?.groups.first?.title == "gpt-4o")
        #expect(model.selectionSnapshot?.groups.first?.subtitle == "OpenAI")
        #expect(model.scopedSnapshot?.totals.input == 500)
    }

    @Test func groupingChangeDuringPendingSelectionReloadsWithCurrentGrouping() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(3600),
                            routeID: "r1", routeName: "R1", input: 500, output: 50))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)
        let point = try #require(model.snapshot.days.first)

        let gate = LoadGate()
        model.toggleSelection(at: point.date, points: model.snapshot.days, unit: .day) { from, to, grouping in
            if grouping == .route { await gate.waitIfHeld() }
            return try await store.snapshot(from: from, to: to, grouping: grouping)
        }
        #expect(model.pendingBucket != nil)

        // 取数中换分组：按当前分组重启，不永久停在加载态。
        model.grouping = .model
        await model.refreshUsage(store: store)
        #expect(await waitForSelection(model))
        #expect(model.pendingBucket == nil)
        #expect(model.selectedBucket?.date == point.date)
        #expect(model.selectionSnapshot?.groups.first?.title == "gpt-4o")

        // 旧分组的迟到响应被令牌与分组守卫丢弃。
        gate.release()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(model.selectionSnapshot?.groups.first?.title == "gpt-4o")
        #expect(model.pendingBucket == nil)
    }

    // MARK: - 缓存命中率

    @Test func cacheRateFormulaTreatsMissingDataAsUnknown() {
        #expect(UsageFormat.cacheRate(input: 100, cachedInput: 25) == 0.25)
        #expect(UsageFormat.cacheRate(input: 100, cachedInput: 0) == 0)
        #expect(UsageFormat.cacheRate(input: nil, cachedInput: 25) == nil)
        #expect(UsageFormat.cacheRate(input: 100, cachedInput: nil) == nil)
        #expect(UsageFormat.cacheRate(input: 0, cachedInput: 0) == nil)
        #expect(UsageFormat.cacheRate(input: nil, cachedInput: nil) == nil)
        #expect(UsageFormat.cacheRateText(0.25) == "25.0%")
        #expect(UsageFormat.cacheRateText(0) == "0.0%")
        #expect(UsageFormat.cacheRateText(nil) == "—")
    }

    @Test func cacheHitRateIsUnknownWhenUpstreamNeverReportsCached() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(10 * 3600),
                            routeID: "r1", routeName: "R1", input: 100, output: 10, cached: nil))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)

        // 上游从未上报缓存 → 命中率未知，不显示成精确的 0%。
        #expect(model.cacheHitRate == nil)
        #expect(UsageFormat.cacheRateText(model.cacheHitRate) == "—")
        #expect(model.cacheRateCaption == "未上报")
    }

    @Test func cacheHitRateUsesReportedValuesAndFlagsPartialCoverage() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        // 第一条没有缓存字段（未上报），第二条上报了缓存。
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(10 * 3600),
                            routeID: "r1", routeName: "R1", input: 100, output: 10, cached: nil))
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(11 * 3600),
                            routeID: "r1", routeName: "R1", input: 300, output: 30, cached: 100))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)

        // 缓存 100 / 输入 400 = 25%；两条记录里只有一条上报了缓存 → 部分上报。
        #expect(model.cacheHitRate == 0.25)
        #expect(UsageFormat.cacheRateText(model.cacheHitRate) == "25.0%")
        #expect(model.cacheRateIsPartial)
        #expect(model.cacheRateCaption == "部分上报")
    }

    @Test func explicitZeroCachedCountsAsZeroNotAsMissing() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(10 * 3600),
                            routeID: "r1", routeName: "R1", input: 100, output: 10, cached: 0))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)

        // 明确上报 0 与「没上报」不同：前者是真实的 0%。
        #expect(model.cacheHitRate == 0)
        #expect(UsageFormat.cacheRateText(model.cacheHitRate) == "0.0%")
        #expect(!model.cacheRateIsPartial)
    }

    @Test func cacheHitRateFollowsTheSelectedBucket() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let store = UsageStore(url: url)
        store.record(record(timestamp: localMidnight(daysAgo: 2).addingTimeInterval(10 * 3600),
                            routeID: "r1", routeName: "R1", input: 100, output: 10, cached: nil))
        store.record(record(timestamp: localMidnight(daysAgo: 1).addingTimeInterval(10 * 3600),
                            routeID: "r1", routeName: "R1", input: 900, output: 90, cached: 450))
        try await store.flush()

        let model = UsageViewModel(section: .usage)
        model.preset = .last7Days
        await model.refresh(store: store)
        #expect(model.cacheHitRate == 0.45)

        let point = try #require(model.snapshot.days.first { $0.input == 100 })
        model.toggleSelection(at: point.date, points: model.snapshot.days, unit: .day,
                              load: storeLoader(store))
        #expect(await waitForSelection(model))
        // 选中桶没有缓存上报 → 该桶的命中率未知。
        #expect(model.cacheHitRate == nil)
        #expect(UsageFormat.cacheRateText(model.cacheHitRate) == "—")
    }
}
