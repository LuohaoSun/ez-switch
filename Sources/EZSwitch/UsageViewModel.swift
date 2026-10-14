import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - 区间与格式化

/// 用量页的时间区间预设。页面选择器只用 `pagePresets`
/// （今天 / 近7天 / 近30天 / 自定义）；`thisMonth` 保留给 CLI 的 `period=month`，不进入页面选择器。
enum UsageRangePreset: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case last30Days
    case thisMonth
    case custom

    var id: String { rawValue }

    /// 页面选择器展示的预设与顺序。
    static let pagePresets: [UsageRangePreset] = [.today, .last7Days, .last30Days, .custom]

    var title: String {
        switch self {
        case .today: return "今天"
        case .last7Days: return "近7天"
        case .last30Days: return "近30天"
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
    /// 自定义「近 N 天」上限：由日历可表示范围推导，仅防日期加法溢出，非产品级限制。
    static func maxLastNDays(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.startOfDay(for: Date.distantPast)
        guard let days = calendar.dateComponents([.day], from: earliest, to: today).day else { return 1 }
        return max(1, days + 1)
    }

    /// 解析区间；`customLastNDays` 非空表示「近 N 天（含今天）」，
    /// 为 nil 时保留既有 `customStart`/`customEnd`（含倒置）语义，供 CLI 的 from/to 调用方使用。
    static func resolve(preset: UsageRangePreset,
                        customStart: Date = Date(),
                        customEnd: Date = Date(),
                        customLastNDays: Int? = nil,
                        now: Date = Date(),
                        calendar: Calendar = .current) -> UsageDateRange {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(24 * 60 * 60)

        switch preset {
        case .today:
            return UsageDateRange(from: today, to: tomorrow)
        case .last7Days:
            return daysBackRange(7, today: today, tomorrow: tomorrow, calendar: calendar)
        case .last30Days:
            return daysBackRange(30, today: today, tomorrow: tomorrow, calendar: calendar)
        case .thisMonth:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
            return UsageDateRange(from: start, to: tomorrow)
        case .custom:
            if let requested = customLastNDays {
                let days = min(max(requested, 1), maxLastNDays(now: now, calendar: calendar))
                return daysBackRange(days, today: today, tomorrow: tomorrow, calendar: calendar)
            }
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

    /// `[today - (days - 1), tomorrow)`：含今天共 `days` 个自然日，日历加法保证 DST 自然边界。
    private static func daysBackRange(_ days: Int,
                                      today: Date,
                                      tomorrow: Date,
                                      calendar: Calendar) -> UsageDateRange {
        let count = max(1, days)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        return UsageDateRange(from: start, to: tomorrow)
    }
}

/// 图表 X 轴刻度：只在 `[from, to)` 内取，绝不含排他上界 `to`（避免把次日零点标成今天最后一格）。
enum UsageAxisTicks {
    /// 按天取刻度，锚点落每天正午（避开午夜与 DST 歧义），最多约 `maxTicks` 个。
    static func days(from: Date, to: Date, maxTicks: Int = 7, calendar: Calendar = .current) -> [Date] {
        let total = calendar.dateComponents([.day], from: from, to: to).day ?? 1
        let count = max(1, total)
        let step = max(1, Int(ceil(Double(count) / Double(max(1, maxTicks)))))
        return stride(from: 0, to: count, by: step).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: from) else { return nil }
            guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) else { return nil }
            return noon < to ? noon : nil
        }
    }

    /// 按小时取刻度，偏移量按日历实际小时数计算（23/25 小时日自适应），并用 `to` 过滤。
    static func hours(from: Date, to: Date, stepHours: Int = 3, calendar: Calendar = .current) -> [Date] {
        let totalHours = calendar.dateComponents([.hour], from: from, to: to).hour ?? 24
        let step = max(1, stepHours)
        return stride(from: 0, to: max(1, totalHours), by: step).compactMap { offset in
            guard let date = calendar.date(byAdding: .hour, value: offset, to: from) else { return nil }
            return date < to ? date : nil
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

    private static let axisHourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.setLocalizedDateFormatFromTemplate("Hm")
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
    static func axisHour(_ date: Date) -> String { axisHourFormatter.string(from: date) }
    static func fileDate(_ date: Date) -> String { isoFormatter.string(from: date) }
}

// MARK: - 页面状态

enum UsagePhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

// MARK: - 视图切换与性能排序

/// 用量页内部的两个视图：Token 用量与请求性能。共用同一套时间筛选。
enum UsageSection: String, CaseIterable, Identifiable {
    case usage
    case performance

    var id: String { rawValue }
    var title: String { self == .usage ? "用量" : "性能" }
}

/// 性能比较表的排序字段，与三张平均指标一一对应：
/// 平均 TTFT、平均 TPS（含 TTFT）、平均 TPS（不含 TTFT）。
/// 路由维度取含自动回退的 request 级指标，其余维度取单次上游尝试指标；
/// 不含 TTFT 的 TPS 两个维度共用同一字段。
enum PerformanceSortKey: String, CaseIterable, Identifiable {
    case ttftMean
    case tpsIncludingTTFT
    case tpsExcludingTTFT

    var id: String { rawValue }

    /// 指标名称：三张卡与表头使用同一组名称；路由 / 尝试口径差异只放在 tooltip。
    func title(for grouping: UsageGrouping) -> String {
        switch self {
        case .ttftMean: return "平均TTFT"
        case .tpsIncludingTTFT: return "平均TPS(含TTFT)"
        case .tpsExcludingTTFT: return "平均TPS(不含TTFT)"
        }
    }

    /// 表格表头与卡片同名，保持口径名词唯一。
    func columnTitle(for grouping: UsageGrouping) -> String { title(for: grouping) }
}

/// 排序取值与比较：nil（未测/未知）恒定排在最后，与升降序无关；同值时按标题稳定排序。
enum PerformanceSort {
    static func value(_ key: PerformanceSortKey,
                      row: PerformanceGroupRow,
                      grouping: UsageGrouping) -> Double? {
        let summary = row.summary
        switch key {
        case .ttftMean:
            return grouping == .route ? summary.requestTTFTMeanMS : summary.ttftMeanMS
        case .tpsIncludingTTFT:
            return grouping == .route ? summary.requestTpsIncludingTTFT : summary.tpsIncludingTTFT
        case .tpsExcludingTTFT:
            return summary.tpsExcludingTTFT
        }
    }

    static func sorted(_ rows: [PerformanceGroupRow],
                       by key: PerformanceSortKey,
                       grouping: UsageGrouping,
                       ascending: Bool) -> [PerformanceGroupRow] {
        rows.sorted { lhs, rhs in
            let a = value(key, row: lhs, grouping: grouping)
            let b = value(key, row: rhs, grouping: grouping)
            switch (a, b) {
            case let (x?, y?):
                if x != y { return ascending ? x < y : x > y }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }
}

/// 性能数值显示：nil（未测/未知）一律用 —，绝不填 0。
enum PerformanceFormat {
    static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value < 1000 { return String(format: "%.0f ms", value) }
        return String(format: "%.2f s", value / 1000)
    }

    static func tps(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.1f", value)
    }

    static func samples(_ value: Int) -> String {
        value > 0 ? UsageFormat.compact(value) : "0"
    }
}

// MARK: - ViewModel

/// 用量页的可变状态。全部用 `ObservableObject` + `@Published`，
/// 避免本机 CommandLineTools 环境下 `@State` 宏展开失败。
@MainActor
final class UsageViewModel: ObservableObject {
    @Published var preset: UsageRangePreset = .today
    /// 自定义「近 N 天（含今天）」有效值，恒 >= 1，驱动查询区间与 reloadKey。
    @Published var customLastNDays: Int = 7
    /// 数字输入缓冲；仅合法正整数提交到 `customLastNDays`，非法输入不改变区间。
    @Published var customLastNDaysInput: String = "7"
    @Published var section: UsageSection = .usage
    @Published var grouping: UsageGrouping = .route

    /// 性能视图独立分组（默认按模型 = 供应商 + 模型），与用量表的分组互不影响。
    @Published var performanceGrouping: UsageGrouping = .model
    @Published var performanceSortKey: PerformanceSortKey = .ttftMean
    @Published var performanceSortAscending: Bool = true

    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var phase: UsagePhase = .idle
    /// 最近一次刷新失败（有旧数据时以横幅提示，不覆盖已显示内容）。
    @Published private(set) var lastError: String?
    @Published private(set) var performanceSnapshot = PerformanceSnapshot()
    @Published private(set) var performancePhase: UsagePhase = .idle
    @Published private(set) var performanceLastError: String?
    @Published var confirmClear = false
    @Published var actionError: String?
    @Published private(set) var isExporting = false
    @Published private(set) var isClearing = false

    private var currentRequest = UUID()
    private var hasLoadedSnapshot = false
    private var currentPerformanceRequest = UUID()
    private var hasLoadedPerformance = false
    private let pollInterval: UInt64 = 5 * 1_000_000_000

    /// 入口决定初始视图：用量入口默认用量，性能入口直达性能。
    /// 侧栏两个入口各自持有一个实例（配合稳定视图身份），互不复用，避免导航到性能时仍显示用量。
    init(section: UsageSection = .usage) {
        self.section = section
    }

    /// `.task(id:)` 键：区间/分组/视图变化即重启刷新；近 N 天只在自定义预设下计入。
    var reloadKey: String {
        let custom = preset == .custom ? "\(customLastNDays)" : ""
        return "\(section.rawValue)|\(preset.rawValue)|\(grouping.rawValue)|\(performanceGrouping.rawValue)|\(custom)"
    }

    var range: UsageDateRange {
        UsageRangeResolver.resolve(preset: preset, customLastNDays: customLastNDays)
    }

    /// 自定义天数上限（日历可表示范围，非产品限制）。
    var maxCustomLastNDays: Int { UsageRangeResolver.maxLastNDays() }

    /// 设置有效天数并同步输入缓冲：下限 1，上限由日历范围决定。
    func setCustomLastNDays(_ value: Int) {
        let clamped = min(max(value, 1), maxCustomLastNDays)
        customLastNDays = clamped
        customLastNDaysInput = String(clamped)
    }

    /// 提交输入（回车/失焦）：合法正整数生效；否则回退到当前有效值，不改变区间。
    func commitCustomLastNDaysInput() {
        let trimmed = customLastNDaysInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 1 else {
            customLastNDaysInput = String(customLastNDays)
            return
        }
        setCustomLastNDays(value)
    }

    var isEmpty: Bool { snapshot.totals.attempts == 0 }

    var isInitialLoading: Bool {
        !hasLoadedSnapshot && (phase == .idle || phase == .loading)
    }

    /// 性能表按当前排序字段/方向排列后的行（nil 恒排在最后）。
    var sortedPerformanceGroups: [PerformanceGroupRow] {
        PerformanceSort.sorted(performanceSnapshot.groups,
                               by: performanceSortKey,
                               grouping: performanceGrouping,
                               ascending: performanceSortAscending)
    }

    /// 区间内完全没有转发尝试记录（与"有历史但无性能样本"区分开）。
    var performanceIsEmpty: Bool { performanceSnapshot.summary.attempts == 0 }

    /// 当前性能分组对应的有效 TTFT 样本数：路由维度用含自动回退的 requestTTFT 样本，
    /// 其余维度用单次尝试 TTFT 样本。旧历史没有 requestTTFT 时不会虚报尝试样本。
    var performanceActiveTTFTSamples: Int {
        performanceGrouping == .route
            ? performanceSnapshot.summary.requestTTFTSamples
            : performanceSnapshot.summary.ttftSamples
    }

    /// 有转发尝试，但在当前分组下既没有有效 TTFT 样本、也没有 TPS 样本。
    /// 只要 TPS 仍有可用样本就不进入空态，避免隐藏可用数据。
    var performanceHasNoSamples: Bool {
        performanceSnapshot.summary.attempts > 0
            && performanceActiveTTFTSamples == 0
            && performanceSnapshot.summary.tpsSamples == 0
    }

    var isInitialLoadingPerformance: Bool {
        !hasLoadedPerformance && (performancePhase == .idle || performancePhase == .loading)
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

    /// 刷新当前视图所需的数据。始终更新用量（工具栏的导出/清除依赖它）；
    /// 仅在性能视图可见时才查询性能快照，避免无关查询。
    func refresh(store: UsageStore) async {
        await refreshUsage(store: store)
        if section == .performance {
            await refreshPerformance { [store] from, to, grouping in
                try await store.performanceSnapshot(from: from, to: to, grouping: grouping)
            }
        }
    }

    /// 竞态安全：同时校验取消状态、请求令牌与发起时的 reloadKey，
    /// 避免切区间/分组后旧结果覆盖新筛选。
    func refreshUsage(store: UsageStore) async {
        let token = UUID()
        currentRequest = token
        let requestedKey = reloadKey
        if !hasLoadedSnapshot { phase = .loading }
        let current = range
        // 仅用量页的「今天」需要小时级分桶作图；其余区间与性能页不查小时数据。
        let includeHourly = section == .usage && preset == .today

        do {
            let fresh = try await store.snapshot(from: current.from, to: current.to,
                                                 grouping: grouping, includeHourly: includeHourly)
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

    /// 性能快照加载。与用量相同的竞态策略：取消状态 + 请求令牌 + 发起时 reloadKey。
    /// 用闭包注入查询，便于在测试中替换数据源、验证竞态与排序。
    func refreshPerformance(load: (Date, Date, UsageGrouping) async throws -> PerformanceSnapshot) async {
        let token = UUID()
        currentPerformanceRequest = token
        let requestedKey = reloadKey
        if !hasLoadedPerformance { performancePhase = .loading }
        let current = range
        let grouping = performanceGrouping

        do {
            let fresh = try await load(current.from, current.to, grouping)
            guard !Task.isCancelled, currentPerformanceRequest == token, requestedKey == reloadKey else { return }
            performanceSnapshot = fresh
            performanceLastError = nil
            hasLoadedPerformance = true
            performancePhase = .loaded
        } catch {
            guard !Task.isCancelled, currentPerformanceRequest == token, requestedKey == reloadKey else { return }
            let message = error.localizedDescription
            performanceLastError = message
            performancePhase = hasLoadedPerformance ? .loaded : .failed(message)
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
