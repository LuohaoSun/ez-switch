import SwiftUI
import AppKit
import Charts

// MARK: - 用量 / 性能页共用卡片样式

extension View {
    /// 轻量卡片：低对比背景、细描边、统一内边距，右边缘留白。
    func cardSurface() -> some View {
        self
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            .padding(.trailing, 2)
    }

    /// 图表卡片外壳：标题、内容间距与图高在两页保持一致。
    func statsChartCard(title: String, height: CGFloat = 180) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            self.frame(height: height)
        }
        .cardSurface()
    }

    /// 图表坐标轴：左侧 compact 数值，底部按天或按小时刻度。
    func statsChartAxes(isHourly: Bool, dates: [Date]) -> some View {
        self
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Int.self) {
                            Text(UsageFormat.compact(number))
                        } else if let number = value.as(Double.self) {
                            Text(UsageFormat.compact(Int(number)))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: dates) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(isHourly ? UsageFormat.axisHour(date) : UsageFormat.axisDay(date))
                        }
                    }
                }
            }
    }
}

/// 顶部总览的单个指标块：标题 / 主值 / 说明三行，用量页与性能页共用同一组字号与间距。
struct StatTile: View {
    let title: String
    let value: String
    let caption: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

/// 表格行布局：按权重把可用宽度分给各列，并给每列一个最小宽度兜底。
/// 表头与数据行使用同一份规格（相同权重/最小宽度/间距），所以逐列严格对齐；
/// 名称列权重高、占剩余宽度的大头，数值列按各自权重铺开，避免全挤在右侧。
///
/// 分配规则：先按权重分（扣除列间距），低于最小宽度的列锁定为最小宽度，
/// 剩余空间在未锁定的列间按权重再分一轮；多轮后仍不够时保持最小宽度（由外层裁剪）。
struct TableRowLayout: Layout {
    var minWidths: [CGFloat]
    var weights: [CGFloat]
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 0
        let widths = resolvedWidths(total: total, count: subviews.count)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let fit = subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil))
            height = max(height, fit.height)
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = resolvedWidths(total: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: widths[index], height: bounds.height))
            x += widths[index] + spacing
        }
    }

    private func resolvedWidths(total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let available = max(0, total - spacing * CGFloat(count - 1))
        var widths = [CGFloat](repeating: 0, count: count)
        var locked = [Bool](repeating: false, count: count)
        let weightAt = { (index: Int) in index < self.weights.count ? self.weights[index] : 0 }
        let minAt = { (index: Int) in index < self.minWidths.count ? self.minWidths[index] : 0 }

        // 多轮：把分不到最小宽度的列锁到最小宽度，其余列重新按权重分配剩余空间。
        for _ in 0..<count {
            let used = (0..<count).reduce(CGFloat(0)) { $0 + (locked[$1] ? widths[$1] : 0) }
            let freeWeight = (0..<count).filter { !locked[$0] }.reduce(CGFloat(0)) { $0 + weightAt($1) }
            if freeWeight <= 0 { break }
            var changed = false
            for index in 0..<count where !locked[index] {
                let share = (available - used) * weightAt(index) / freeWeight
                if share < minAt(index) {
                    widths[index] = minAt(index)
                    locked[index] = true
                    changed = true
                }
            }
            if !changed {
                for index in 0..<count where !locked[index] {
                    widths[index] = (available - used) * weightAt(index) / freeWeight
                }
                break
            }
        }
        return widths
    }
}
