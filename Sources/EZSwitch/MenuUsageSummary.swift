import AppKit
import Foundation

/// 菜单栏"今日用量"摘要。由 `RouterApp` 常驻持有，独立于菜单内容视图的出现/消失，
/// 因此 SwiftUI 原生菜单生命周期不会阻断刷新触发。
///
/// 失效来源：`UsageStore` 成功写入/清除、系统日历日变化、根级菜单每次打开。
/// 连续失效按固定窗口合并；同一时刻至多一个读取在途，`needsRefresh` 保证在途期间
/// 到达的新变化不会被丢弃。
@MainActor
final class MenuUsageSummary: ObservableObject {
    struct TodaySummary: Equatable {
        var tokens: Int
        var isCompleteCoverage: Bool
        /// 缓存命中率；`nil` = 上游未上报缓存用量或输入为 0。
        var cacheRate: Double? = nil
        /// 缓存上报覆盖不足：只有部分尝试上报了缓存用量。
        var isCacheCoveragePartial: Bool = false
    }

    typealias Loader = (_ from: Date, _ to: Date) async throws -> TodaySummary

    /// 合并窗口：从每轮刷新开始计时的固定短窗口（非重置式 debounce），
    /// 持续流量下仍按窗口周期刷新，不会被不断重置而饿死。
    nonisolated static let defaultCoalesceInterval: TimeInterval = 1

    @Published private(set) var todayTokens: Int?
    @Published private(set) var isAvailable = true
    /// 覆盖完整（已知用量 == 上游尝试数）；只描述 input / output，不代表缓存覆盖。
    @Published private(set) var isCompleteCoverage = true
    /// 缓存上报覆盖不足：只有部分尝试上报了缓存用量。
    @Published private(set) var isCacheCoveragePartial = false
    /// 缓存命中率；`nil` = 上游未上报缓存用量或输入为 0。
    @Published private(set) var cacheRate: Double?

    private let load: Loader
    private let calendar: Calendar
    private let now: () -> Date
    private let coalesceInterval: TimeInterval
    private let center: NotificationCenter

    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var needsRefresh = false

    /// 生产入口：只响应本 store 的失效通知。
    convenience init(store: UsageStore,
                     calendar: Calendar = .autoupdatingCurrent,
                     now: @escaping () -> Date = Date.init,
                     coalesceInterval: TimeInterval = MenuUsageSummary.defaultCoalesceInterval,
                     notificationCenter: NotificationCenter = .default) {
        self.init(load: { from, to in
            let snapshot = try await store.snapshot(from: from, to: to, grouping: .route)
            let totals = snapshot.totals
            return TodaySummary(tokens: totals.total,
                                isCompleteCoverage: totals.knownAttempts >= totals.attempts,
                                cacheRate: UsageCacheRate.value(for: totals),
                                isCacheCoveragePartial: UsageCacheRate.isPartial(for: totals))
        },
        changeSource: store, calendar: calendar, now: now,
        coalesceInterval: coalesceInterval, notificationCenter: notificationCenter)
    }

    /// 测试入口：注入 loader、失效来源、日历、时钟与通知中心。
    init(load: @escaping Loader,
         changeSource: AnyObject? = nil,
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping () -> Date = Date.init,
         coalesceInterval: TimeInterval = MenuUsageSummary.defaultCoalesceInterval,
         notificationCenter: NotificationCenter = .default) {
        self.load = load
        self.calendar = calendar
        self.now = now
        self.coalesceInterval = coalesceInterval
        self.center = notificationCenter
        observe(UsageStore.didChangeNotification, object: changeSource)
        observe(Notification.Name.NSCalendarDayChanged, object: nil)
        observe(NSMenu.didBeginTrackingNotification, object: nil)
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
        refreshTask?.cancel()
    }

    var menuTitle: String {
        guard isAvailable else { return "今日用量: 暂不可用" }
        guard let tokens = todayTokens else { return "今日用量: 读取中…" }
        return "今日用量: \(UsageFormat.compact(tokens)) Tokens · 缓存率 \(UsageFormat.cacheRateText(cacheRate))"
    }

    /// 菜单项的补充说明：缓存率是已上报字段之间的比值，各字段覆盖可能不同。
    var menuHelp: String {
        var lines = ["打开用量统计，查看今日与本机历史 Token 用量",
                     "缓存率 = 已上报的缓存命中输入 ÷ 已上报的输入 token"]
        if cacheRate == nil {
            lines.append("上游未上报缓存用量或输入为 0，缓存率显示 —")
        }
        if isCacheCoveragePartial {
            lines.append("部分记录未上报缓存用量，缓存率为已上报部分的比率")
        }
        if !isCompleteCoverage {
            lines.append("部分上游尝试未上报用量，各字段覆盖可能不同")
        }
        return lines.joined(separator: "\n")
    }

    /// 标记数据可能已失效并合并刷新。
    func invalidate() {
        needsRefresh = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.drain()
        }
    }

    /// 等待已排入的在途刷新结束（测试用）。等待"通知已被处理"请改用条件轮询。
    func waitForIdle() async {
        while let task = refreshTask {
            _ = await task.value
        }
    }

    // MARK: 观察

    private func observe(_ name: Notification.Name, object: AnyObject?) {
        // queue: nil 在发布线程回调；再跳主 actor（macOS 13 无 assumeIsolated）。
        let token = center.addObserver(forName: name, object: object, queue: nil) { [weak self] note in
            Task { @MainActor [weak self] in self?.handle(note) }
        }
        observers.append(token)
    }

    private func handle(_ notification: Notification) {
        switch notification.name {
        case UsageStore.didChangeNotification, Notification.Name.NSCalendarDayChanged:
            invalidate()
        case NSMenu.didBeginTrackingNotification:
            guard Self.shouldRefreshForMenu(notification.object) else { return }
            invalidate()
        default:
            break
        }
    }

    /// 只对根级菜单（状态栏菜单）补刷，排除子菜单（如模型列表）与应用主菜单，
    /// 避免无关菜单触发读库。依据公开的 `NSMenu.supermenu`，不做标题/私有视图结构匹配。
    static func shouldRefreshForMenu(_ object: Any?) -> Bool {
        guard let menu = object as? NSMenu, menu.supermenu == nil else { return false }
        if let mainMenu = NSApp?.mainMenu, menu === mainMenu { return false }
        return true
    }

    // MARK: 刷新

    /// 单一在途刷新循环：先合并一段固定窗口，再读取一次；期间有新变化则再跑一轮。
    /// 串行执行保证没有并发读取，故不存在旧快照覆盖新结果。
    private func drain() async {
        while !Task.isCancelled {
            if coalesceInterval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(coalesceInterval * 1_000_000_000))
            }
            if Task.isCancelled { break }
            needsRefresh = false
            await refreshOnce()
            if !needsRefresh { break }
        }
        refreshTask = nil
    }

    /// 每次读取都按当前日历时区重算"今天"的区间，跨天后自动切到新的一天。
    private func refreshOnce() async {
        let start = calendar.startOfDay(for: now())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        do {
            let summary = try await load(start, end)
            guard !Task.isCancelled else { return }
            todayTokens = summary.tokens
            isCompleteCoverage = summary.isCompleteCoverage
            isCacheCoveragePartial = summary.isCacheCoveragePartial
            cacheRate = summary.cacheRate
            isAvailable = true
        } catch {
            guard !Task.isCancelled else { return }
            todayTokens = nil
            cacheRate = nil
            isAvailable = false
        }
    }
}
