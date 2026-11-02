import SwiftUI
import AppKit
import Charts

// MARK: - 用量 / 性能页共用样式

/// 悬停状态的轻量盒。
/// 该工程的 CLI 工具链下 SwiftUI 的 `@State` 宏不可用，所以统一用 `ObservableObject` + `@StateObject`。
final class HoverState: ObservableObject {
    @Published var isHovered = false
}

/// 卡片与表格行的统一尺寸，集中在一处避免两页各自漂移。
enum UsageCardMetrics {
    static let cardCornerRadius: CGFloat = 12
    static let tileCornerRadius: CGFloat = 10
    static let rowCornerRadius: CGFloat = 6
    static let bannerCornerRadius: CGFloat = 8
}

extension View {
    /// 轻量卡片：低对比背景、细描边、统一内边距，右边缘留白。
    /// `padding` 默认 16，活动页的流向图卡片可传更紧凑的 12。
    func cardSurface(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: UsageCardMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
            }
            .overlay(
                RoundedRectangle(cornerRadius: UsageCardMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09))
            )
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
/// 内部浅浅的底色 + 1pt 细描边，让指标在总览卡里有清晰的结构层次。
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
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: UsageCardMetrics.tileCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UsageCardMetrics.tileCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 表格行 / 列头

/// 明细行悬停底色：只换背景不改变行高与列宽，保证表格逐列对齐。
struct HoverableTableRow<Content: View>: View {
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    private let content: Content

    @StateObject private var hover = HoverState()

    init(horizontalPadding: CGFloat = 0,
         verticalPadding: CGFloat = 0,
         @ViewBuilder content: () -> Content) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                hover.isHovered ? Color.primary.opacity(0.045) : Color.clear,
                in: RoundedRectangle(cornerRadius: UsageCardMetrics.rowCornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: UsageCardMetrics.rowCornerRadius, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { hover.isHovered = hovering }
            }
    }
}

/// 可排序列头：保持文字/箭头的对齐规则不变，悬停时显示淡淡的双向箭头，
/// 当前排序列使用加粗的单向箭头。箭头始终占同宽空间，显隐不会让文字横向跳动。
struct SortHeaderLabel: View {
    let title: String
    let leading: Bool
    let isActive: Bool
    let ascending: Bool

    @StateObject private var hover = HoverState()

    private var arrowName: String {
        if isActive { return ascending ? "chevron.up" : "chevron.down" }
        return "chevron.up.chevron.down"
    }

    private var arrowOpacity: Double {
        if isActive { return 1 }
        return hover.isHovered ? 0.35 : 0
    }

    var body: some View {
        HStack(spacing: 4) {
            if leading {
                text
                arrow
            } else {
                arrow
                text
            }
        }
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hover.isHovered ? Color.primary.opacity(0.045) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hover.isHovered = hovering }
        }
    }

    private var text: some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .allowsTightening(true)
    }

    private var arrow: some View {
        Image(systemName: arrowName)
            .font(.system(size: 8, weight: isActive ? .bold : .semibold))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .opacity(arrowOpacity)
            .frame(width: 12)
            .accessibilityHidden(true)
    }
}

// MARK: - 提示条

/// 统一的提示 / 警告横幅：连续圆角、细描边，用量页与性能页共用同一套观感。
struct StatusBanner: View {
    enum Tone {
        case warning
        case info
    }

    let tone: Tone
    let systemImage: String
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
            Text(message)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(foreground)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            background,
            in: RoundedRectangle(cornerRadius: UsageCardMetrics.bannerCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UsageCardMetrics.bannerCornerRadius, style: .continuous)
                .strokeBorder(border)
        )
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch tone {
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    private var background: Color {
        switch tone {
        case .warning: return Color.orange.opacity(0.10)
        case .info: return Color.primary.opacity(0.04)
        }
    }

    private var border: Color {
        switch tone {
        case .warning: return Color.orange.opacity(0.18)
        case .info: return Color.primary.opacity(0.06)
        }
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

extension TableRowLayout {
    /// 用量明细：名称列 3 份，四个数值列各 1 份。
    static let statsDetail = TableRowLayout(minWidths: [120, 96, 112, 112, 72],
                                            weights: [3, 1, 1, 1, 1],
                                            spacing: 12)

    /// 性能明细：名称列 3 份，五个数值列（失败率 / TTFT / 两个 TPS / 请求）各 1 份。
    /// 与用量明细共用同一套权重与间距，只是多了一列失败率。
    static let performanceDetail = TableRowLayout(minWidths: [120, 80, 96, 112, 112, 72],
                                                  weights: [3, 1, 1, 1, 1, 1],
                                                  spacing: 12)
}
