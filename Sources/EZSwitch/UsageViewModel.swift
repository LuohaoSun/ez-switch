import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - 区间与格式化

/// 用量页的时间区间预设。`custom` 的两个日期都用原生 DatePicker 选择。
enum UsageRangePreset: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case thisMonth
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今日"
        case .last7Days: return "近 7 天"
        case .thisMonth: return "本月"
        case .custom: return "自定义"
        }
    }
}

/// 半开区间 [from, to)：`to` 是选中结束日的次日零点，保证结束日整天都被包含。
struct UsageDateRange: Equatable {
    var from: Date
    /// 排他上界（结束日的次日零点）
    var to: Date

    var inclusiveEnd: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: to) ?? to
    }
}

enum UsageRangeResolver {
    static func resolve(preset: UsageRangePreset,
                        customStart: Date,
                        customEnd: Date,
                        now: Date = Date(),
                        calendar: Calendar = .current) -> UsageDateRange {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(24 * 60 * 60)

        switch preset {
        case .today:
            return UsageDateRange(from: today, to: tomorrow)
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            return UsageDateRange(from: start, to: tomorrow)
        case .thisMonth:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
            return UsageDateRange(from: start, to: tomorrow)
        case .custom:
            // 允许用户把两个日期选反；取较小值作为起点，较大值作为结束日。
            let a = calendar.startOfDay(for: customStart)
            let b = calendar.startOfDay(for: customEnd)
            let start = min(a, b)
            let last = max(a, b)
            let end = calendar.date(byAdding: .day, value: 1, to: last)
                ?? last.addingTimeInterval(24 * 60 * 60)
            return UsageDateRange(from: start, to: end)
        }
    }
}

/// 数字与日期显示：图表与总览用 compact，tooltip/detail 用 exact。
enum UsageFormat {
    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        return f
    }()

    static func compact(_ value: Int) -> String {
        // 用 Double 取幅值，避免 Int.min 上 abs 溢出陷阱。
        let magnitude = abs(Double(value))
        let sign = value < 0 ? "-" : ""
        switch magnitude {
        case 0..<1_000:
            return "\(value)"
        case 1_000..<100_000:
            return sign + String(format: "%.1fk", magnitude / 1_000)
        case 100_000..<1_000_000:
            return sign + String(format: "%.0fk", magnitude / 1_000)
        default:
            return sign + String(format: "%.1fM", magnitude / 1_000_000)
        }
    }

    static func exact(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func axisDay(_ date: Date) -> String { axisFormatter.string(from: date) }
    static func fileDate(_ date: Date) -> String { isoFormatter.string(from: date) }
}

// MARK: - 页面状态

enum UsagePhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

// MARK: - ViewModel

/// 用量页的可变状态。全部用 `ObservableObject` + `@Published`，
/// 避免本机 CommandLineTools 环境下 `@State` 宏展开失败。
@MainActor
final class UsageViewModel: ObservableObject {
    @Published var preset: UsageRangePreset = .today
    @Published var customStart: Date = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @Published var customEnd: Date = Date()
    @Published var grouping: UsageGrouping = .route

    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var phase: UsagePhase = .idle
    /// 最近一次刷新失败（有旧数据时以横幅提示，不覆盖已显示内容）。
    @Published private(set) var lastError: String?
    @Published var confirmClear = false
    @Published var actionError: String?
    @Published private(set) var isExporting = false
    @Published private(set) var isClearing = false

    private var currentRequest = UUID()
    private var hasLoadedSnapshot = false
    private let pollInterval: UInt64 = 5 * 1_000_000_000

    /// `.task(id:)` 的键：区间或分组变化时重启刷新循环，立即拉取新数据。
    var reloadKey: String {
        "\(preset.rawValue)|\(grouping.rawValue)|\(customStart.timeIntervalSince1970)|\(customEnd.timeIntervalSince1970)"
    }

    var range: UsageDateRange {
        UsageRangeResolver.resolve(preset: preset, customStart: customStart, customEnd: customEnd)
    }

    var isEmpty: Bool { snapshot.totals.attempts == 0 }

    var isInitialLoading: Bool {
        !hasLoadedSnapshot && (phase == .idle || phase == .loading)
    }

    /// 仅在页面可见时运行（`.task` 在视图消失时自动取消）。5 秒轮询 + 工具栏手动刷新。
    func runRefreshLoop(store: UsageStore) async {
        await refresh(store: store)
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: pollInterval)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await refresh(store: store)
        }
    }

    /// 竞态安全：同时校验取消状态、请求令牌与发起时的 reloadKey，
    /// 避免切区间/分组后旧结果覆盖新筛选。
    func refresh(store: UsageStore) async {
        let token = UUID()
        currentRequest = token
        let requestedKey = reloadKey
        if !hasLoadedSnapshot { phase = .loading }
        let current = range

        do {
            let fresh = try await store.snapshot(from: current.from, to: current.to, grouping: grouping)
            guard !Task.isCancelled, currentRequest == token, requestedKey == reloadKey else { return }
            snapshot = fresh
            lastError = nil
            hasLoadedSnapshot = true
            phase = .loaded
        } catch {
            guard !Task.isCancelled, currentRequest == token, requestedKey == reloadKey else { return }
            let message = error.localizedDescription
            lastError = message
            phase = hasLoadedSnapshot ? .loaded : .failed(message)
        }
    }

    func exportCSV(store: UsageStore) async {
        guard !isEmpty, !isExporting else { return }
        isExporting = true
        defer { isExporting = false }

        let current = range
        do {
            let csv = try await store.exportCSV(from: current.from, to: current.to)
            presentSavePanel(csv: csv, suggestedName: suggestedFileName(current))
        } catch {
            actionError = "导出失败：\(error.localizedDescription)"
        }
    }

    func clearHistory(store: UsageStore) async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await store.clear()
            await refresh(store: store)
        } catch {
            actionError = "清除失败：\(error.localizedDescription)"
        }
    }

    // MARK: 私有

    private func suggestedFileName(_ range: UsageDateRange) -> String {
        let from = UsageFormat.fileDate(range.from)
        let end = UsageFormat.fileDate(range.inclusiveEnd)
        return from == end ? "usage-\(from).csv" : "usage-\(from)_to_\(end).csv"
    }

    /// 原生保存面板；写盘放到后台线程，避免大历史阻塞主线程。
    private func presentSavePanel(csv: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task.detached(priority: .utility) {
                do {
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        self.actionError = "写入文件失败：\(message)"
                    }
                }
            }
        }
    }
}
