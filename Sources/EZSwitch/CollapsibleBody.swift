import SwiftUI

/// 折叠卡片几何：展开高度取真实排版值，不做行数估算。
/// 供应商 = 分隔线及其留白 + 原生表格真实行区净高（`tightContentHeight`）；
/// 路由 = 分隔线及留白 + 候选表行几何（候选行 + 末尾占位行）+ 底部留白。
enum CollapsibleMetrics {
    static let separator: CGFloat = 1
    static let supplierSeparatorTop: CGFloat = 6
    static let supplierListTop: CGFloat = 10
    static let supplierSelectionInset: CGFloat = 10

    static let routeSeparatorTop: CGFloat = 6
    static let routeListTop: CGFloat = 4
    static let routeListBottom: CGFloat = 12
    /// 与 `NativeRouteCandidateList.rowHeight` 默认值一致（工作区未覆盖行高）。
    static let routeRowHeight: CGFloat = 34

    static let routeSummaryTop: CGFloat = 10
    static let routeSummaryLine: CGFloat = 18
    static let routeSummaryBottom: CGFloat = 12

    /// 表格高度未量到前返回 0（首帧后回填，回填不触发动画）。
    static func supplierBodyHeight(tableHeight: CGFloat) -> CGFloat {
        guard tableHeight > 0 else { return 0 }
        return separator + supplierSeparatorTop + supplierListTop + tableHeight
    }

    static func routeBodyHeight(candidateCount: Int, rowHeight: CGFloat = CollapsibleMetrics.routeRowHeight) -> CGFloat {
        separator + routeSeparatorTop + routeListTop + CGFloat(candidateCount + 1) * rowHeight + routeListBottom
    }

    static var routeSummaryHeight: CGFloat { routeSummaryTop + routeSummaryLine + routeSummaryBottom }
}

/// 展开/收起容器：两段内容始终挂载（原生表格 identity 稳定），内层固定自然高度，
/// 外层只插值裁剪高度；命中与 AX 按目标 `isExpanded` 切换，不跟随中间帧。
struct CollapsibleBody<Expanded: View, Collapsed: View>: View {
    let isExpanded: Bool
    /// 展开态净高，来自原生表格真实净高 / 行几何。
    let expandedHeight: CGFloat
    /// 收起态净高（摘要占位）；无摘要时为 0。
    var collapsedHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let expanded: () -> Expanded
    @ViewBuilder let collapsed: () -> Collapsed

    var body: some View {
        CollapsibleBodyLayout(progress: isExpanded ? 1 : 0,
                              isExpanded: isExpanded,
                              expandedHeight: expandedHeight,
                              collapsedHeight: collapsedHeight,
                              expanded: expanded(),
                              collapsed: collapsed())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)
    }
}

/// `progress` 0(收起)↔1(展开) 由 SwiftUI 插值；每段先按自然高度定尺寸，再套插值高度的裁剪框。
private struct CollapsibleBodyLayout<Expanded: View, Collapsed: View>: View, Animatable {
    var progress: CGFloat
    let isExpanded: Bool
    let expandedHeight: CGFloat
    let collapsedHeight: CGFloat
    let expanded: Expanded
    let collapsed: Collapsed

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 闭包可能是多子节点的 TupleView（如 Divider + 表格），必须显式纵排后再定高。
            VStack(spacing: 0) { expanded }
                .frame(height: expandedHeight, alignment: .top)
                .frame(height: expandedHeight * progress, alignment: .top)
                .clipped()
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
            VStack(spacing: 0) { collapsed }
                .frame(height: collapsedHeight, alignment: .top)
                .frame(height: collapsedHeight * (1 - progress), alignment: .top)
                .clipped()
                .opacity(Double(1 - progress))
                .allowsHitTesting(!isExpanded)
                .accessibilityHidden(isExpanded)
        }
    }
}
