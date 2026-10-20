import Foundation

/// 图表里被选中的柱：一个时间桶（小时或自然日）及其半开区间。
///
/// 选中只改变总览卡片与下方明细表的数据源；图表本身始终绘制整个区间的序列，
/// 因此选中某根柱之后，其余柱依然可以点选。
struct UsageChartSelection: Equatable {
    /// 柱起点：小时桶是该小时的第一分钟，天桶是该日零点。
    var date: Date
    var unit: Calendar.Component
    /// 该柱覆盖的半开区间 `[from, to)`。
    var range: UsageDateRange

    /// 点击命中哪根柱：按粒度区间匹配点击位置；未命中任何柱返回 nil。
    static func point(at date: Date, points: [UsageDay], unit: Calendar.Component,
                      calendar: Calendar = .current) -> UsageDay? {
        points.first { point in
            guard let interval = calendar.dateInterval(of: unit, for: point.date) else { return false }
            return date >= interval.start && date < interval.end
        }
    }

    /// 由柱构造选中项；区间按本机日历推导，与分桶口径一致。
    static func bucket(for point: UsageDay, unit: Calendar.Component,
                       calendar: Calendar = .current) -> UsageChartSelection? {
        guard let interval = calendar.dateInterval(of: unit, for: point.date) else { return nil }
        return UsageChartSelection(date: point.date, unit: unit,
                                   range: UsageDateRange(from: interval.start, to: interval.end))
    }

    /// 展示标签：小时桶到分钟，天桶到日。
    func label(calendar: Calendar = .current) -> String {
        switch unit {
        case .hour:
            return UsageFormat.bucketHour(date, calendar: calendar)
        default:
            return UsageFormat.day(date)
        }
    }
}

/// 图表选中态：已提交的柱及其数据，以及正在取数的目标柱。
///
/// 整体一次赋值，`bucket` 与 `snapshot` 同时生效：视图不会观察到
/// 「已选中但数据未就绪」的中间态，卡片与明细也就不会中途塌陷。
struct UsageSelectionState {
    /// 已提交的柱；nil 表示展示整个区间。
    var bucket: UsageChartSelection?
    /// `bucket` 对应的统计快照，与 `bucket` 同时提交。
    var snapshot: UsageSnapshot?
    /// 最近一次所选时段加载失败的信息；失败时保留上一次提交的 scope。
    var error: String?
    /// 取数中的目标柱；成功后才提升为 `bucket`。
    var pending: UsageChartSelection?

    static let empty = UsageSelectionState()

    /// 图表高亮的柱：取数中的目标优先，点击后立即有反馈。
    var activeBucket: UsageChartSelection? { pending ?? bucket }

    var isLoading: Bool { pending != nil }
}
