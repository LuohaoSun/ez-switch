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
struct UsageDateRange: Equatable, Sendable {
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

    /// 小时桶标签：`5月10日 14:00`。按传入日历的时区显示，与分桶口径一致。
    static func bucketHour(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        return formatter.string(from: date)
    }

    /// 缓存命中率 = 已上报的缓存命中 token ÷ 已上报的输入 token。
    ///
    /// 缓存命中是输入的子集，因此分母用输入、分子用缓存命中。
    /// 任一侧缺失（上游没上报）或输入为 0 时返回 `nil`（界面显示「—」），
    /// 绝不把「没有数据」粉饰成精确的 0%。页面与菜单共用这一公式。
    static func cacheRate(input: Int?, cachedInput: Int?) -> Double? {
        guard let input, let cachedInput, input > 0, cachedInput >= 0 else { return nil }
        return Double(cachedInput) / Double(input)
    }

    /// 缓存命中率的显示文本：常规一位小数百分比；未知为「—」。
    static func cacheRateText(_ rate: Double?) -> String {
        guard let rate, rate.isFinite else { return "—" }
        return String(format: "%.1f%%", rate * 100)
    }
}

// MARK: - 页面状态

/// 缓存命中率的统计口径包装：把「上报计数」翻译成 `UsageFormat.cacheRate` 的可选输入。
///
/// 上报计数为 0 表示该列没有任何记录上报过，区别于「明确上报为 0」；
/// 因此缺项一律按未知处理（`nil` → 显示「—」），不粉饰成精确的 0%。
enum UsageCacheRate {
    /// 命中率（0...1）；nil = 未知（没上报输入 / 没上报缓存 / 输入为 0）。
    static func value(for totals: UsageTotals) -> Double? {
        UsageFormat.cacheRate(input: totals.inputAttempts > 0 ? totals.input : nil,
                              cachedInput: totals.cachedInputAttempts > 0 ? totals.cachedInput : nil)
    }

    /// 命中率不可知的原因；nil 表示命中率已知。
    static func unknownReason(for totals: UsageTotals) -> String? {
        if totals.inputAttempts == 0 { return "上游未上报输入用量" }
        if totals.cachedInputAttempts == 0 { return "上游未上报缓存用量" }
        if totals.input <= 0 { return "区间内没有输入 token" }
        return nil
    }

    /// 缓存上报覆盖不足：只有部分尝试上报了缓存用量。
    /// 此时比值只按已上报部分计算，不代表全部请求的真实命中率。
    static func isPartial(for totals: UsageTotals) -> Bool {
        totals.cachedInputAttempts > 0 && totals.cachedInputAttempts < totals.inputAttempts
    }
}

enum UsagePhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

// MARK: - 视图切换与表格排序

/// 用量页内部的两个视图：Token 用量与请求性能。共用同一套时间筛选。
enum UsageSection: String, CaseIterable, Identifiable {
    case usage
    case performance

    var id: String { rawValue }
    var title: String { self == .usage ? "用量" : "性能" }
}

/// 性能比较表的排序字段：名称、请求数与三张平均指标
/// （平均 TTFT、平均 TPS（含 TTFT）、平均 TPS（不含 TTFT））。
/// 路由维度取含自动回退的 request 级指标，其余维度取单次上游尝试指标；
/// 不含 TTFT 的吞吐两维度共用同一口径（只算生成时长）。
enum PerformanceSortKey: String, CaseIterable, Identifiable {
    case name
    case requests
    case ttftMean
    case tpsIncludingTTFT
    case tpsExcludingTTFT

    var id: String { rawValue }

    /// 指标名称：卡片与表头使用同一组名称；路由 / 尝试口径差异只放在 tooltip。
    func title(for grouping: UsageGrouping) -> String {
        switch self {
        case .name: return "名称"
        case .requests: return "请求"
        case .ttftMean: return "平均TTFT"
        case .tpsIncludingTTFT: return "平均TPS(含TTFT)"
        case .tpsExcludingTTFT: return "平均TPS(不含TTFT)"
        }
    }

    /// 表格表头与卡片同名，保持口径名词唯一。
    func columnTitle(for grouping: UsageGrouping) -> String { title(for: grouping) }

    /// 首次点击该列时的默认方向：按"越好越靠前"取值——
    /// 延迟类（TTFT）越小越好，用升序；吞吐类（TPS）越大越好，用降序；
    /// 名称按自然序升序；请求数越多越靠前，用降序。
    var defaultAscending: Bool {
        switch self {
        case .name, .ttftMean: return true
        case .requests, .tpsIncludingTTFT, .tpsExcludingTTFT: return false
        }
    }
}

/// 排序取值与比较：nil（未测/未知）恒定排在最后，与升降序无关；同值时按标题稳定排序。
/// 名称列按自然序比较（「路由 2」排在「路由 10」前），不走数值路径。
enum PerformanceSort {
    static func value(_ key: PerformanceSortKey,
                      row: PerformanceGroupRow,
                      grouping: UsageGrouping) -> Double? {
        let summary = row.summary
        switch key {
        case .name:
            // 名称由 `sorted` 单独按自然序处理，不参与数值比较。
            return nil
        case .requests:
            // 去重请求数恒有值（0 也是已知值），因此不存在「未知置后」。
            return Double(summary.requests)
        case .ttftMean:
            return grouping == .route ? summary.requestTTFTMeanMS : summary.ttftMeanMS
        case .tpsIncludingTTFT:
            return grouping == .route ? summary.requestTpsIncludingTTFT : summary.tpsIncludingTTFT
        case .tpsExcludingTTFT:
            return summary.tpsExcludingTTFT
        }
    }

    /// 排序专用取值：非有限值（NaN / 无穷）与 nil 同样视为未知。
    /// 否则 NaN 的每次比较都为 false，会破坏严格弱序、让顺序随排序算法内部实现漂移。
    private static func sortableValue(_ key: PerformanceSortKey,
                                      row: PerformanceGroupRow,
                                      grouping: UsageGrouping) -> Double? {
        guard let value = value(key, row: row, grouping: grouping), value.isFinite else { return nil }
        return value
    }

    /// 按列与方向排序：名称按自然序，nil（含非有限值）恒定置后；
    /// 同值按标题、再按 id 稳定 tie-break（与方向无关，反复点列头不会抖动）。
    static func sorted(_ rows: [PerformanceGroupRow],
                       by key: PerformanceSortKey,
                       grouping: UsageGrouping,
                       ascending: Bool) -> [PerformanceGroupRow] {
        rows.sorted { lhs, rhs in
            if key == .name {
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame {
                    return ascending ? order == .orderedAscending : order == .orderedDescending
                }
                return lhs.id < rhs.id
            }
            let a = sortableValue(key, row: lhs, grouping: grouping)
            let b = sortableValue(key, row: rhs, grouping: grouping)
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

/// 用量表（使用明细）的排序列。nil 表示未排序——保持后端默认顺序（总 Token 降序）。
enum UsageSortKey: String, CaseIterable, Identifiable {
    case name
    case input
    case output
    case cached
    case cacheRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .input: return "输入"
        case .output: return "输出"
        case .cached: return "缓存"
        case .cacheRate: return "缓存率"
        }
    }

    /// 首次点击的默认方向：名称按自然序升序，数值列越大越靠前（降序）。
    var defaultAscending: Bool {
        switch self {
        case .name: return true
        case .input, .output, .cached, .cacheRate: return false
        }
    }
}

/// 用量表排序取值与比较：未上报（attempts 计数为 0）视为未知、恒定置后，
/// 与单元格「—」口径一致；名称列按自然序单独处理。
enum UsageSort {
    static func value(_ key: UsageSortKey, row: UsageGroupRow) -> Double? {
        let totals = row.totals
        switch key {
        case .name:
            return nil
        case .input:
            return totals.inputAttempts > 0 ? Double(totals.input) : nil
        case .output:
            return totals.outputAttempts > 0 ? Double(totals.output) : nil
        case .cached:
            return totals.cachedInputAttempts > 0 ? Double(totals.cachedInput) : nil
        case .cacheRate:
            return UsageCacheRate.value(for: totals)
        }
    }

    private static func sortableValue(_ key: UsageSortKey, row: UsageGroupRow) -> Double? {
        guard let value = value(key, row: row), value.isFinite else { return nil }
        return value
    }

    /// 与 `PerformanceSort.sorted` 同构：名称按自然序，nil（未上报/未知）恒定置后，
    /// 同值按标题、再按 id 稳定 tie-break。
    static func sorted(_ rows: [UsageGroupRow],
                       by key: UsageSortKey,
                       ascending: Bool) -> [UsageGroupRow] {
        rows.sorted { lhs, rhs in
            if key == .name {
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame {
                    return ascending ? order == .orderedAscending : order == .orderedDescending
                }
                return lhs.id < rhs.id
            }
            let a = sortableValue(key, row: lhs)
            let b = sortableValue(key, row: rhs)
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

    /// 用量表排序：nil 表示未排序，保持后端默认顺序（总 Token 降序）。
    /// 排序只影响本地派生行序，不进入 `reloadKey`，因此不会触发重新查询。
    @Published var usageSortKey: UsageSortKey?
    @Published var usageSortAscending: Bool = false

    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var phase: UsagePhase = .idle
    /// 最近一次刷新失败（有旧数据时以横幅提示，不覆盖已显示内容）。
    @Published private(set) var lastError: String?
    /// 图表中选中的柱及其数据。整体一次赋值，避免 bucket 与 snapshot 分步更新产生空档。
    @Published private(set) var selection = UsageSelectionState.empty
    /// 性能页的图表选中态；与用量页的 `selection` 相互独立。
    @Published private(set) var performanceSelection = PerformanceSelectionState.empty
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

    /// 选中柱的请求令牌：每次选择/取消都换新，迟到的旧响应据此作废。
    private var selectionRequest = UUID()
    /// 已提交或取数中的选中快照所用的分组；分组变化后需要重取。
    private var selectionGrouping: UsageGrouping?
    /// 选择上下文（视图、区间预设、自定义天数、图表粒度）的上一次取值。
    private var currentSelectionContext: String = ""
    /// 性能页选中柱的请求令牌；与用量页独立。
    private var performanceSelectionRequest = UUID()
    private var currentPerformanceSelectionContext: String = ""

    /// 入口决定初始视图：用量入口默认用量，性能入口直达性能。
    /// 侧栏两个入口各自持有一个实例（配合稳定视图身份），互不复用，避免导航到性能时仍显示用量。
    init(section: UsageSection = .usage) {
        self.section = section
        currentSelectionContext = selectionContext
        currentPerformanceSelectionContext = performanceSelectionContext
    }

    /// `.task(id:)` 键：区间/分组/视图变化即重启刷新；近 N 天只在自定义预设下计入。
    var reloadKey: String {
        let custom = preset == .custom ? "\(customLastNDays)" : ""
        return "\(section.rawValue)|\(preset.rawValue)|\(grouping.rawValue)|\(performanceGrouping.rawValue)|\(custom)"
    }

    var range: UsageDateRange {
        UsageRangeResolver.resolve(preset: preset, customLastNDays: customLastNDays, now: nowProvider())
    }

    /// 区间计算的当前时间；测试可注入以复现跨零点这类时间相关场景。
    var nowProvider: () -> Date = { Date() }

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

    // MARK: 图表选中

    /// 已提交的柱（其数据已就绪）；nil 表示未选中。
    var selectedBucket: UsageChartSelection? { selection.bucket }
    /// 取数中的目标柱；nil 表示没有等待中的选择。
    var pendingBucket: UsageChartSelection? { selection.pending }
    /// 图表高亮的柱：取数中的目标优先。
    var activeBucket: UsageChartSelection? { selection.activeBucket }
    var selectionIsLoading: Bool { selection.isLoading }
    /// 已提交柱的快照（与 `selectedBucket` 同时提交）。
    var selectionSnapshot: UsageSnapshot? { selection.snapshot }
    var selectionError: String? { selection.error }

    /// 图表粒度：今天按小时，其余区间按天。
    var chartUnit: Calendar.Component { preset == .today ? .hour : .day }

    /// 是否需要小时分桶：「今天」的用量与性能页都要画小时柱状图。
    var usesHourlyBuckets: Bool { preset == .today }

    /// 图表序列：今天按小时，其余区间按天。用量 Token 图与性能请求数图共用。
    var chartPoints: [UsageDay] { chartUnit == .hour ? snapshot.hours : snapshot.days }

    /// 图表 X 轴刻度：只标当前区间内的自然日 / 小时。
    var chartDates: [Date] { UsageAxisTicks.days(from: range.from, to: range.to) }
    var chartHours: [Date] { UsageAxisTicks.hours(from: range.from, to: range.to) }

    /// 卡片与明细的数据源：有已提交的柱时用其快照，否则是整个区间。
    /// 取数中的新选择不参与，上一个 scope 保持到原子提交。
    var scopedSnapshot: UsageSnapshot? {
        selection.bucket == nil ? snapshot : selection.snapshot
    }

    var scopedTotals: UsageTotals { scopedSnapshot?.totals ?? UsageTotals() }

    /// 缓存命中率；nil = 未知（上游没上报输入/缓存，或输入为 0）。
    var cacheHitRate: Double? { UsageCacheRate.value(for: scopedTotals) }

    var cacheRateUnknownReason: String? { UsageCacheRate.unknownReason(for: scopedTotals) }

    var cacheRateIsPartial: Bool { UsageCacheRate.isPartial(for: scopedTotals) }

    var cacheRateCaption: String {
        let totals = scopedTotals
        if totals.inputAttempts == 0 || totals.cachedInputAttempts == 0 { return "未上报" }
        if totals.input <= 0 { return "无输入" }
        return cacheRateIsPartial ? "部分上报" : "命中/输入"
    }

    /// 比值只按已上报部分计算，不声称是配对样本。
    var cacheRateHelp: String {
        let totals = scopedTotals
        var lines = ["缓存命中率 = 已上报缓存 token ÷ 已上报输入 token"]
        if let reason = cacheRateUnknownReason {
            lines.append("\(reason)，命中率未知")
            return lines.joined(separator: "\n")
        }
        lines.append("已上报缓存 \(UsageFormat.exact(totals.cachedInput)) / 已上报输入 \(UsageFormat.exact(totals.input))")
        if cacheRateIsPartial {
            lines.append("仅 \(totals.cachedInputAttempts)/\(totals.inputAttempts) 次上游尝试上报了缓存用量，比值只按已上报部分计算")
        }
        return lines.joined(separator: "\n")
    }

    /// 点选图表中的柱：命中已提交的柱再次点击即取消选择；未命中任何柱同样取消。
    /// 新目标的快照就绪前继续展示上一个 scope（整个区间或上一次选中的柱），
    /// 就绪后原子提交，因此内容不会收缩、滚动位置也不会被钳回顶部。
    func toggleSelection(at date: Date, points: [UsageDay], unit: Calendar.Component,
                         calendar: Calendar = .current,
                         load: @escaping @Sendable (Date, Date, UsageGrouping) async throws -> UsageSnapshot) {
        guard let point = UsageChartSelection.point(at: date, points: points, unit: unit, calendar: calendar),
              point.input > 0 || point.output > 0 else {
            clearSelection()
            return
        }
        if let bucket = selection.bucket, bucket.date == point.date, bucket.unit == unit {
            clearSelection()
            return
        }
        // 再点一次取数中的柱：放弃这次取数，回到上一个已提交的 scope。
        if let pending = selection.pending, pending.date == point.date, pending.unit == unit {
            cancelPendingSelection()
            return
        }
        guard let bucket = UsageChartSelection.bucket(for: point, unit: unit, calendar: calendar) else {
            clearSelection()
            return
        }
        startSelectionLoad(bucket, load: load)
    }

    /// 取消选择，回到整个区间；同时作废在途的选中请求。
    func clearSelection() {
        selectionRequest = UUID()
        selectionGrouping = nil
        selection = .empty
    }

    /// 放弃取数中的目标，保留已提交的 scope（图表与卡片回到上一次状态）。
    private func cancelPendingSelection() {
        guard selection.pending != nil else { return }
        selectionRequest = UUID()
        selection = UsageSelectionState(bucket: selection.bucket, snapshot: selection.snapshot,
                                        error: selection.error, pending: nil)
    }

    /// 标记取数目标并异步加载；不改动已提交的 bucket/snapshot。
    private func startSelectionLoad(_ bucket: UsageChartSelection,
                                    load: @escaping @Sendable (Date, Date, UsageGrouping) async throws -> UsageSnapshot) {
        let token = UUID()
        selectionRequest = token
        let grouping = self.grouping
        selectionGrouping = grouping
        selection = UsageSelectionState(bucket: selection.bucket, snapshot: selection.snapshot,
                                        error: nil, pending: bucket)
        Task { [weak self] in
            await self?.loadSelection(bucket: bucket, token: token, grouping: grouping, load: load)
        }
    }

    /// 竞态安全：取消状态 + 请求令牌 + 当前分组 + 待提交目标，
    /// 避免快速切换或改分组时旧响应覆盖新状态。
    private func loadSelection(bucket: UsageChartSelection, token: UUID, grouping: UsageGrouping,
                               load: @escaping @Sendable (Date, Date, UsageGrouping) async throws -> UsageSnapshot) async {
        do {
            let fresh = try await load(bucket.range.from, bucket.range.to, grouping)
            guard isCurrentSelectionLoad(token: token, bucket: bucket, grouping: grouping) else { return }
            // 原子提交：bucket 与 snapshot 同一次赋值，内容不会出现空档。
            selection = UsageSelectionState(bucket: bucket, snapshot: fresh, error: nil, pending: nil)
        } catch {
            guard isCurrentSelectionLoad(token: token, bucket: bucket, grouping: grouping) else { return }
            // 失败保留上一个 scope，只记录错误。
            selection = UsageSelectionState(bucket: selection.bucket, snapshot: selection.snapshot,
                                            error: error.localizedDescription, pending: nil)
        }
    }

    private func isCurrentSelectionLoad(token: UUID, bucket: UsageChartSelection,
                                        grouping: UsageGrouping) -> Bool {
        guard !Task.isCancelled, selectionRequest == token, self.grouping == grouping else { return false }
        return selection.pending?.date == bucket.date && selection.pending?.unit == bucket.unit
    }

    /// 已提交柱的静默重取：轮询/分组变化后更新数据，不进入加载态，失败也不覆盖已显示内容。
    private func refreshCommittedSelection(_ bucket: UsageChartSelection, grouping: UsageGrouping,
                                           store: UsageStore) async {
        let token = selectionRequest
        let requestedKey = reloadKey
        do {
            let fresh = try await store.snapshot(from: bucket.range.from, to: bucket.range.to,
                                                 grouping: grouping)
            guard !Task.isCancelled, selectionRequest == token, reloadKey == requestedKey,
                  selection.pending == nil,
                  selection.bucket?.date == bucket.date, selection.bucket?.unit == bucket.unit else { return }
            selection = UsageSelectionState(bucket: bucket, snapshot: fresh, error: nil, pending: nil)
            selectionGrouping = grouping
        } catch {
            // 静默刷新失败保留已显示数据；全区间刷新错误由横幅提示。
        }
    }

    /// 选择上下文：视图、区间预设、自定义天数与图表粒度。
    /// 任一变化都让已选的柱失去意义，因此必须重置选中态。
    private var selectionContext: String {
        let custom = preset == .custom ? "\(customLastNDays)" : ""
        return "\(section.rawValue)|\(preset.rawValue)|\(custom)|\(chartUnit == .hour ? "hour" : "day")"
    }

    // MARK: 性能图表选中

    /// 已提交的性能选中柱；nil 表示指标卡与明细展示整个区间。
    var performanceSelectedBucket: UsageChartSelection? { performanceSelection.bucket }
    var performancePendingBucket: UsageChartSelection? { performanceSelection.pending }
    var performanceActiveBucket: UsageChartSelection? { performanceSelection.activeBucket }
    var performanceSelectionError: String? { performanceSelection.error }
    var performanceSelectionIsLoading: Bool { performanceSelection.isLoading }
    var performanceSelectionSnapshot: PerformanceSnapshot? { performanceSelection.snapshot }

    /// 指标卡与性能明细的数据源：已提交所选柱时用其性能快照，否则整个区间。
    /// 取数中的新选择不参与，上一个 scope 保持到原子提交。
    var scopedPerformanceSnapshot: PerformanceSnapshot {
        performanceSelection.bucket == nil ? performanceSnapshot : (performanceSelection.snapshot ?? performanceSnapshot)
    }

    var scopedPerformanceSummary: PerformanceSummary { scopedPerformanceSnapshot.summary }

    /// 顶部状态 chip 的 section 分派：用量页看 `selection`，性能页看 `performanceSelection`。
    var shownPendingBucket: UsageChartSelection? {
        section == .performance ? performanceSelection.pending : selection.pending
    }

    var shownSelectedBucket: UsageChartSelection? {
        section == .performance ? performanceSelection.bucket : selection.bucket
    }

    var shownSelectionError: String? {
        section == .performance ? performanceSelection.error : selection.error
    }

    /// 清除当前页面的选中柱（用量页与性能页各自回到整个区间）。
    func clearShownSelection() {
        if section == .performance {
            clearPerformanceSelection()
        } else {
            clearSelection()
        }
    }

    /// 点选性能柱状图：只收敛指标卡与性能明细，图表始终保留整个区间。
    /// 请求数为 0 的柱不可选；再次点击同一根柱取消；再点取数中的柱放弃本次取数。
    func togglePerformanceSelection(
        at date: Date, points: [UsageDay], unit: Calendar.Component,
        calendar: Calendar = .current,
        load: @escaping @Sendable (Date, Date, UsageGrouping) async throws -> PerformanceSnapshot
    ) {
        guard let point = UsageChartSelection.point(at: date, points: points, unit: unit, calendar: calendar),
              point.requests > 0 else {
            clearPerformanceSelection()
            return
        }
        if let bucket = performanceSelection.bucket, bucket.date == point.date, bucket.unit == unit {
            clearPerformanceSelection()
            return
        }
        if let pending = performanceSelection.pending, pending.date == point.date, pending.unit == unit {
            cancelPendingPerformanceSelection()
            return
        }
        guard let bucket = UsageChartSelection.bucket(for: point, unit: unit, calendar: calendar) else {
            clearPerformanceSelection()
            return
        }
        startPerformanceSelectionLoad(bucket, load: load)
    }

    /// 取消性能选中，回到整个区间；同时作废在途的选中请求。
    func clearPerformanceSelection() {
        performanceSelectionRequest = UUID()
        performanceSelection = .empty
    }

    /// 放弃取数中的性能目标，保留已提交的 scope。
    private func cancelPendingPerformanceSelection() {
        guard performanceSelection.pending != nil else { return }
        performanceSelectionRequest = UUID()
        performanceSelection = PerformanceSelectionState(bucket: performanceSelection.bucket,
                                                          snapshot: performanceSelection.snapshot,
                                                          error: performanceSelection.error,
                                                          pending: nil)
    }

    /// 标记性能取数目标并异步加载；不改动已提交的 bucket/snapshot。
    private func startPerformanceSelectionLoad(
        _ bucket: UsageChartSelection,
        load: @escaping @Sendable (Date, Date, UsageGrouping) async throws -> PerformanceSnapshot
    ) {
        let token = UUID()
        performanceSelectionRequest = token
        let grouping = performanceGrouping
        performanceSelection = PerformanceSelectionState(bucket: performanceSelection.bucket,
                                                          snapshot: performanceSelection.snapshot,
                                                          error: nil, pending: bucket)
        Task { [weak self] in
            await self?.loadPerformanceSelection(bucket: bucket, token: token,
                                                 grouping: grouping, load: load)
        }
    }

    /// 竞态安全：请求令牌 + 当前性能分组 + 待提交目标，避免旧响应覆盖新状态。
    private func loadPerformanceSelection(
        bucket: UsageChartSelection, token: UUID, grouping: UsageGrouping,
        load: @escaping @Sendable (Date, Date, UsageGrouping) async throws -> PerformanceSnapshot
    ) async {
        do {
            let fresh = try await load(bucket.range.from, bucket.range.to, grouping)
            guard isCurrentPerformanceSelectionLoad(token: token, bucket: bucket, grouping: grouping) else { return }
            performanceSelection = PerformanceSelectionState(bucket: bucket, snapshot: fresh,
                                                              error: nil, pending: nil)
        } catch {
            guard isCurrentPerformanceSelectionLoad(token: token, bucket: bucket, grouping: grouping) else { return }
            performanceSelection = PerformanceSelectionState(bucket: performanceSelection.bucket,
                                                              snapshot: performanceSelection.snapshot,
                                                              error: error.localizedDescription, pending: nil)
        }
    }

    private func isCurrentPerformanceSelectionLoad(token: UUID, bucket: UsageChartSelection,
                                                   grouping: UsageGrouping) -> Bool {
        guard !Task.isCancelled, performanceSelectionRequest == token,
              performanceGrouping == grouping else { return false }
        return performanceSelection.pending?.date == bucket.date
            && performanceSelection.pending?.unit == bucket.unit
    }

    /// 已提交性能柱的静默重取：轮询/分组变化后更新数据，不进入加载态，失败也不覆盖已显示内容。
    private func refreshCommittedPerformanceSelection(
        _ bucket: UsageChartSelection, grouping: UsageGrouping,
        load: (Date, Date, UsageGrouping) async throws -> PerformanceSnapshot
    ) async {
        let token = performanceSelectionRequest
        let requestedKey = reloadKey
        do {
            let fresh = try await load(bucket.range.from, bucket.range.to, grouping)
            guard !Task.isCancelled, performanceSelectionRequest == token, reloadKey == requestedKey,
                  performanceSelection.pending == nil,
                  performanceSelection.bucket?.date == bucket.date,
                  performanceSelection.bucket?.unit == bucket.unit else { return }
            performanceSelection = PerformanceSelectionState(bucket: bucket, snapshot: fresh,
                                                              error: nil, pending: nil)
        } catch {
            // 静默刷新失败保留已显示数据；整体刷新错误由横幅提示。
        }
    }

    /// 性能选择上下文：区间预设、自定义天数、图表粒度与性能分组。
    private var performanceSelectionContext: String {
        let custom = preset == .custom ? "\(customLastNDays)" : ""
        return "\(preset.rawValue)|\(custom)|\(chartUnit == .hour ? "hour" : "day")|\(performanceGrouping.rawValue)"
    }

    /// 已选的柱是否仍落在当前区间内（例如「今天」跨过午夜后旧小时桶已出界）。
    private func isBucketInCurrentRange(_ bucket: UsageChartSelection) -> Bool {
        let current = range
        return bucket.range.from >= current.from && bucket.range.to <= current.to
    }

    var isInitialLoading: Bool {
        !hasLoadedSnapshot && (phase == .idle || phase == .loading)
    }

    /// 性能表按当前排序字段/方向排列后的行（nil 恒排在最后）。
    /// 有已提交的选中柱时按该时段的性能快照派生。
    var sortedPerformanceGroups: [PerformanceGroupRow] {
        PerformanceSort.sorted(scopedPerformanceSnapshot.groups,
                               by: performanceSortKey,
                               grouping: performanceGrouping,
                               ascending: performanceSortAscending)
    }

    /// 点表头排序：同一列再次点击反向；切换到新列时用该列的默认方向（越大越好者降序，越小越好者升序）。
    func togglePerformanceSort(_ key: PerformanceSortKey) {
        guard performanceSortKey == key else {
            performanceSortKey = key
            performanceSortAscending = key.defaultAscending
            return
        }
        performanceSortAscending.toggle()
    }

    /// 该列当前是否正被用于排序（用于表头箭头显隐）。
    func isPerformanceSortActive(_ key: PerformanceSortKey) -> Bool {
        performanceSortKey == key
    }

    /// 用量表按当前排序列/方向排列后的行；未选择排序列时保持后端默认顺序。
    /// 有已提交的选中柱时按该时段的用量快照派生。
    var sortedUsageGroups: [UsageGroupRow] {
        let rows = scopedSnapshot?.groups ?? []
        guard let key = usageSortKey else { return rows }
        return UsageSort.sorted(rows, by: key, ascending: usageSortAscending)
    }

    /// 点表头排序：同一列再次点击反向；切换到新列时用该列的默认方向。
    func toggleUsageSort(_ key: UsageSortKey) {
        guard usageSortKey == key else {
            usageSortKey = key
            usageSortAscending = key.defaultAscending
            return
        }
        usageSortAscending.toggle()
    }

    /// 该列当前是否正被用于排序（用于表头箭头显隐）。
    func isUsageSortActive(_ key: UsageSortKey) -> Bool {
        usageSortKey == key
    }

    /// 区间内完全没有转发尝试记录（与"有历史但无性能样本"区分开）。
    var performanceIsEmpty: Bool { performanceSnapshot.summary.attempts == 0 }

    /// 当前性能分组对应的有效 TTFT 样本数：路由维度用含自动回退的 requestTTFT 样本，
    /// 其余维度用单次尝试 TTFT 样本。旧历史没有 requestTTFT 时不会虚报尝试样本。
    var performanceActiveTTFTSamples: Int {
        activeTTFTSamples(in: performanceSnapshot.summary)
    }

    /// 按当前分组口径取一份摘要的有效 TTFT 样本数。
    private func activeTTFTSamples(in summary: PerformanceSummary) -> Int {
        performanceGrouping == .route ? summary.requestTTFTSamples : summary.ttftSamples
    }

    /// 有转发尝试，但在当前分组下既没有有效 TTFT 样本、也没有 TPS 样本。
    /// 只要 TPS 仍有可用样本就不进入空态，避免隐藏可用数据。
    /// 选中柱后按该时段判断：整段有样本、但所选的这一小时没有样本时也要提示。
    var performanceHasNoSamples: Bool {
        let summary = scopedPerformanceSummary
        return summary.attempts > 0
            && activeTTFTSamples(in: summary) == 0
            && summary.tpsSamples == 0
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
        // 区间/粒度变化后已选的柱不再有意义：先重置，再取数。
        let context = selectionContext
        if context != currentSelectionContext {
            currentSelectionContext = context
            clearSelection()
        } else if let bucket = selection.activeBucket, !isBucketInCurrentRange(bucket) {
            clearSelection()
        }
        // 仅「今天」需要小时级分桶作图；其余区间不查小时数据。
        let includeHourly = usesHourlyBuckets

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

        // 已提交的选中柱随轮询静默重取（区间内可能有新记录、分组可能已变）；
        // 取数中的目标则只在分组变化时用当前口径重启，避免每轮轮询把它打断。
        if selection.pending == nil, let bucket = selection.bucket {
            await refreshCommittedSelection(bucket, grouping: grouping, store: store)
        } else if let target = selection.pending, selectionGrouping != grouping {
            startSelectionLoad(target) { [store] from, to, grouping in
                try await store.snapshot(from: from, to: to, grouping: grouping)
            }
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

        // 区间/粒度/性能分组变化后，已选的柱不再有意义：先重置，再取数。
        let context = performanceSelectionContext
        if context != currentPerformanceSelectionContext {
            currentPerformanceSelectionContext = context
            clearPerformanceSelection()
        } else if let bucket = performanceSelection.activeBucket, !isBucketInCurrentRange(bucket) {
            clearPerformanceSelection()
        }

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

        // 已提交的性能柱随轮询静默重取；取数中的目标由上下文变化统一重置。
        if performanceSelection.pending == nil, let bucket = performanceSelection.bucket {
            await refreshCommittedPerformanceSelection(bucket, grouping: grouping, load: load)
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
