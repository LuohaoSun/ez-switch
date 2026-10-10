import AppKit
import Foundation
import Testing
@testable import EZSwitch

/// `MenuUsageSummary` 的合并、失效来源、并发去陈旧与跨天行为。
@MainActor
@Suite("Menu usage summary")
struct MenuUsageSummaryTests {

    /// 线程安全的加载记录器（loader 可能在非主执行器上运行）。
    private final class Recorder: @unchecked Sendable {
        struct Call { var value: Int; var from: Date; var to: Date }
        private let lock = NSLock()
        private var calls: [Call] = []
        func append(_ value: Int, from: Date, to: Date) {
            lock.lock(); calls.append(Call(value: value, from: from, to: to)); lock.unlock()
        }
        var all: [Call] { lock.lock(); defer { lock.unlock() }; return calls }
        var count: Int { all.count }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    private struct Boom: Error {}

    /// 递增式 loader：记录每次调用的区间，并返回调用序号作为 token 数。
    private func countingLoader(_ recorder: Recorder) -> MenuUsageSummary.Loader {
        { from, to in
            let next = recorder.count + 1
            recorder.append(next, from: from, to: to)
            return .init(tokens: next, isCompleteCoverage: true)
        }
    }

    /// 等待条件成立（只让出调度、不 sleep）。用于等待"通知已被处理"这类异步交接。
    private func waitUntil(limit: Int = 5000, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<limit {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    /// 让出若干轮次；用于断言"某事未发生"时给异步交接留出机会（有界，不做保证）。
    private func settle(_ rounds: Int = 64) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return Calendar.current.date(from: components)!
    }

    // MARK: - 合并

    @Test
    func coalescesBurstIntoOneRefresh() async {
        let recorder = Recorder()
        let summary = MenuUsageSummary(load: countingLoader(recorder),
                                       coalesceInterval: 0.02, notificationCenter: NotificationCenter())

        // 同步连发 10 次失效：应合并成一次读取。
        for _ in 0..<10 { summary.invalidate() }
        await summary.waitForIdle()

        #expect(recorder.count == 1)
        #expect(summary.todayTokens == 1)
        #expect(summary.isAvailable)
    }

    /// 持续、高频失效（间隔短于合并窗口）在 storm 尚未结束时也应至少刷新一次：
    /// 这正是"固定窗口"与"重置式 debounce"的区别所在。带 deadline，失败则报错而非挂起。
    @Test
    func refreshesDuringSustainedTraffic() async {
        let recorder = Recorder()
        let stormActive = Flag(false)
        let refreshedDuringStorm = Flag(false)
        let summary = MenuUsageSummary(load: { from, to in
            let next = recorder.count + 1
            recorder.append(next, from: from, to: to)
            if stormActive.isSet { refreshedDuringStorm.set(true) }
            return .init(tokens: next, isCompleteCoverage: true)
        }, coalesceInterval: 0.01, notificationCenter: NotificationCenter())

        let storm = Task { @MainActor in
            stormActive.set(true)
            let deadline = Date().addingTimeInterval(1)
            // 每 2ms 失效一次（< 10ms 窗口），直到已观察到多次刷新或超时。
            while Date() < deadline && recorder.count < 3 {
                summary.invalidate()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            stormActive.set(false)
        }
        await storm.value
        await summary.waitForIdle()

        #expect(recorder.count >= 1)
        #expect(refreshedDuringStorm.isSet)   // storm 尚未结束就已读取过
    }

    // MARK: - 并发：在途刷新期间的新变化不丢失

    @Test
    func changeDuringRefreshIsNotLost() async {
        let recorder = Recorder()
        final class WeakBox: @unchecked Sendable { weak var summary: MenuUsageSummary? }
        let box = WeakBox()

        let summary = MenuUsageSummary(load: { from, to in
            let next = recorder.count + 1
            recorder.append(next, from: from, to: to)
            if next == 1 {
                // 第一次读取在途时又有一次写入 → 必须再刷一轮，且以最新结果收尾。
                await MainActor.run { box.summary?.invalidate() }
            }
            return .init(tokens: next, isCompleteCoverage: true)
        }, coalesceInterval: 0, notificationCenter: NotificationCenter())
        box.summary = summary

        summary.invalidate()
        await summary.waitForIdle()

        #expect(recorder.count == 2)
        #expect(summary.todayTokens == 2)   // 未被旧快照覆盖
    }

    // MARK: - 跨天

    @Test
    func daySwitchRecomputesRange() async {
        let recorder = Recorder()
        var now = day(2026, 5, 10, hour: 23, minute: 59)
        let calendar = Calendar.current
        let startOfFirstDay = calendar.startOfDay(for: now)

        let summary = MenuUsageSummary(load: countingLoader(recorder), calendar: calendar,
                                       now: { now }, coalesceInterval: 0,
                                       notificationCenter: NotificationCenter())

        summary.invalidate()
        await summary.waitForIdle()
        #expect(recorder.all.first?.from == startOfFirstDay)
        #expect(recorder.all.first?.to == calendar.date(byAdding: .day, value: 1, to: startOfFirstDay))

        // 跨天：区间应重算到新的一天。
        now = calendar.date(byAdding: .day, value: 1, to: now)!
        summary.invalidate()
        await summary.waitForIdle()

        #expect(recorder.count == 2)
        #expect(recorder.all[1].from == calendar.startOfDay(for: now))
        #expect(recorder.all[1].from != recorder.all[0].from)
    }

    // MARK: - 失效来源与过滤

    @Test
    func storeNotificationTriggersRefresh() async {
        let recorder = Recorder()
        let center = NotificationCenter()
        let summary = MenuUsageSummary(load: countingLoader(recorder),
                                       coalesceInterval: 0, notificationCenter: center)

        center.post(name: UsageStore.didChangeNotification, object: nil)
        #expect(await waitUntil { summary.todayTokens == 1 })
        await summary.waitForIdle()
        #expect(recorder.count == 1)
    }

    @Test
    func calendarDayChangedTriggersRefresh() async {
        let recorder = Recorder()
        let center = NotificationCenter()
        let summary = MenuUsageSummary(load: countingLoader(recorder),
                                       coalesceInterval: 0, notificationCenter: center)

        center.post(name: Notification.Name.NSCalendarDayChanged, object: nil)
        #expect(await waitUntil { summary.todayTokens == 1 })
        await summary.waitForIdle()
        #expect(recorder.count == 1)
    }

    /// 只响应注入的失效来源；其他对象的写入通知不应触发本摘要。
    @Test
    func onlyChangeSourceTriggersRefresh() async {
        let recorder = Recorder()
        let center = NotificationCenter()
        let mine = NSObject()
        let other = NSObject()
        let summary = MenuUsageSummary(load: countingLoader(recorder), changeSource: mine,
                                       coalesceInterval: 0, notificationCenter: center)

        center.post(name: UsageStore.didChangeNotification, object: other)
        await settle()
        #expect(recorder.count == 0)

        center.post(name: UsageStore.didChangeNotification, object: mine)
        #expect(await waitUntil { summary.todayTokens == 1 })
        await summary.waitForIdle()
        #expect(recorder.count == 1)
    }

    // MARK: - 真实链路（UsageStore → MenuUsageSummary）

    /// 走生产入口 `MenuUsageSummary(store:)` 与同一个私有 NotificationCenter：
    /// 验证通知的对象过滤对真实的 `UsageStore`（纯 Swift 类）确实生效，record 与 clear 都能更新摘要。
    @Test
    func realStoreRecordAndClearUpdateSummary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = NotificationCenter()
        let store = UsageStore(url: directory.appendingPathComponent("usage.sqlite"),
                               notificationCenter: center)
        let summary = MenuUsageSummary(store: store, coalesceInterval: 0, notificationCenter: center)

        summary.invalidate()
        await summary.waitForIdle()
        #expect(summary.todayTokens == 0)

        store.record(UsageRecord(requestID: UUID(), timestamp: Date(), routeID: "r1", routeName: "R1",
                                 remoteID: "m1", provider: "OpenAI", model: "gpt-4o", endpoint: "chat",
                                 attempt: 1, status: 200, outcome: "success", durationMS: 5,
                                 tokens: UsageTokens(input: 10, output: 5)))
        try await store.flush()
        #expect(await waitUntil { summary.todayTokens == 15 })

        try await store.clear()
        #expect(await waitUntil { summary.todayTokens == 0 })
    }

    // MARK: - 菜单打开过滤

    @Test
    func menuFilterKeepsRootOnly() {
        #expect(MenuUsageSummary.shouldRefreshForMenu(NSMenu(title: "root")))

        let parentMenu = NSMenu(title: "parent")
        let item = NSMenuItem(title: "models", action: nil, keyEquivalent: "")
        parentMenu.addItem(item)
        let submenu = NSMenu(title: "sub")
        parentMenu.setSubmenu(submenu, for: item)
        #expect(!MenuUsageSummary.shouldRefreshForMenu(submenu))

        #expect(!MenuUsageSummary.shouldRefreshForMenu(nil))
        #expect(!MenuUsageSummary.shouldRefreshForMenu("not a menu"))
    }

    @Test
    func rootMenuTrackingTriggersRefresh() async {
        let recorder = Recorder()
        let center = NotificationCenter()
        let summary = MenuUsageSummary(load: countingLoader(recorder),
                                       coalesceInterval: 0, notificationCenter: center)

        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu(title: "root"))
        #expect(await waitUntil { summary.todayTokens == 1 })
        await summary.waitForIdle()
        #expect(recorder.count == 1)
    }

    // MARK: - 失败与恢复

    @Test
    func failureShowsUnavailableThenRecovers() async {
        let recorder = Recorder()
        let failing = Flag(true)
        let summary = MenuUsageSummary(load: { from, to in
            let next = recorder.count + 1
            recorder.append(next, from: from, to: to)
            if failing.isSet { throw Boom() }
            return .init(tokens: next, isCompleteCoverage: false)
        }, coalesceInterval: 0, notificationCenter: NotificationCenter())

        summary.invalidate()
        await summary.waitForIdle()
        #expect(summary.isAvailable == false)
        #expect(summary.todayTokens == nil)
        #expect(summary.menuTitle.contains("暂不可用"))

        failing.set(false)
        summary.invalidate()
        await summary.waitForIdle()
        #expect(summary.isAvailable)
        #expect(summary.todayTokens == 2)
        #expect(summary.isCompleteCoverage == false)
        #expect(summary.menuTitle.contains("已知"))   // 覆盖不完整时的后缀
    }
}
