import SwiftUI
import AppKit

/// 请求 → EZSwitch → 上游 的实时流向图。
///
/// 布局约束：纯 `GeometryReader` 解析计算（无 PreferenceKey / `@State` / 位移动画）；
/// 左列按开始时间升序、节点位置稳定；左右节点定宽紧凑卡片，连线锚点取节点 frame 边缘；
/// 中间节点高度随连接数伸缩，锚点不越出节点可见高度；同一请求左右连线同色；
/// 只展示前 `ActivityLimits.graphRequests` 个图上节点（在途 + 刚结束驻留）。
/// 请求节点第二行显示 `#短ID · 当前状态 · 耗时`（快照真实字段，窄宽度截断时由 tooltip / 辅助功能补全）。
struct ActivityRouteGraph: View {
    let rows: [ActivityRowModel]
    let activeCount: Int
    let selection: ActivitySelection?
    let colorFor: (UUID) -> Color
    let isRequestRelated: (ActivityRowModel) -> Bool
    let isUpstreamRelated: (String) -> Bool
    let onToggleRequest: (UUID) -> Void
    let onToggleUpstream: (String) -> Void
    let onClear: () -> Void

    /// 无进行中请求时的占位高度（空状态三段文字）。
    private static let idleHeight: CGFloat = 132

    /// 图高度：单节点紧凑、多节点不重叠，展示数量封顶后高度不再增长。
    static func height(forNodeCount count: Int) -> CGFloat {
        guard count > 0 else { return idleHeight }
        let shown = min(count, ActivityLimits.graphRequests)
        let rows = ActivityRouteGraphGeometry.blockHeight(count: shown)
        let mid = ActivityRouteGraphGeometry.midHeight(for: shown)
        return max(rows, mid) + ActivityRouteGraphGeometry.topPad * 2
    }

    var body: some View {
        Group {
            if rows.isEmpty { idleState } else { graph }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height(forNodeCount: rows.count))
    }

    // MARK: 图

    private var graph: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)
            let shown = Array(rows.prefix(ActivityLimits.graphRequests))
            let upstreams = upstreamNodes(shown)
            let layout = ActivityRouteGraphGeometry(width: width, height: height,
                                                    requestCount: shown.count,
                                                    upstreamCount: upstreams.count)
            ZStack {
                lines(shown: shown, upstreams: upstreams, layout: layout)
                requestNodes(shown, layout)
                routerNode(layout)
                upstreamNodes(upstreams, shown, layout)
            }
            .frame(width: width, height: height)
        }
    }

    /// 连线：端点取节点 frame 的边缘锚点。
    private func lines(shown: [ActivityRowModel], upstreams: [UpstreamNode],
                       layout: ActivityRouteGraphGeometry) -> some View {
        Canvas { ctx, _ in
            for (index, row) in shown.enumerated() {
                guard let key = row.upstreamKey,
                      let upstreamIndex = upstreams.firstIndex(where: { $0.key == key }) else { continue }
                let color = colorFor(row.id)
                let opacity: Double = isRequestRelated(row) ? 1 : 0.15
                let lineWidth: CGFloat = isSelected(request: row.id) ? 2.2 : 1.6
                let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                ctx.stroke(curve(from: layout.leftAnchor(index), to: layout.midLeftAnchor(index)),
                           with: .color(color.opacity(opacity)), style: style)
                ctx.stroke(curve(from: layout.midRightAnchor(index), to: layout.rightAnchor(upstreamIndex)),
                           with: .color(color.opacity(opacity)), style: style)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func requestNodes(_ shown: [ActivityRowModel], _ layout: ActivityRouteGraphGeometry) -> some View {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
            requestNode(row, layout: layout)
                .frame(width: layout.sideWidth, height: ActivityRouteGraphGeometry.nodeHeight)
                .position(x: layout.leftX, y: layout.requestCenterY(index))
        }
    }

    @ViewBuilder
    private func upstreamNodes(_ upstreams: [UpstreamNode], _ shown: [ActivityRowModel],
                               _ layout: ActivityRouteGraphGeometry) -> some View {
        ForEach(Array(upstreams.enumerated()), id: \.element.key) { index, node in
            upstreamNode(node, in: shown, layout: layout)
                .frame(width: layout.sideWidth, height: ActivityRouteGraphGeometry.nodeHeight)
                .position(x: layout.rightX, y: layout.upstreamCenterY(index))
        }
    }

    // MARK: 节点

    private func requestNode(_ row: ActivityRowModel, layout: ActivityRouteGraphGeometry) -> some View {
        let color = colorFor(row.id)
        let selected = isSelected(request: row.id)
        let related = isRequestRelated(row)
        let title = "\(row.protocolKind.badgeTitle) · \(row.routeName)"
        // 第二行取快照字段：短 ID · 状态 · 耗时；窄宽度截断，完整信息走 help 与辅助功能。
        let detail = row.graphNodeSubtitle
        return Button { onToggleRequest(row.id) } label: {
            RouteNodeFace(width: layout.sideWidth, height: ActivityRouteGraphGeometry.nodeHeight,
                          color: color, selected: selected) {
                nodeLabel(title: title, dot: color) {
                    Text(detail)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(related ? 1 : 0.3)
        .help("请求 #\(row.shortID) · \(row.routeName) · \(row.graphStatusText) · 耗时 \(row.durationText) · 点击高亮该请求，再次点击取消高亮")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("请求 #\(row.shortID)，路由 \(row.routeName)，协议 \(row.protocolKind.badgeTitle)")
        .accessibilityValue("\(row.graphStatusText)，耗时 \(row.durationText)，\(selected ? "已高亮" : "未高亮")")
        .accessibilityHint("点击高亮该请求，再次点击取消高亮")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func upstreamNode(_ node: UpstreamNode, in shown: [ActivityRowModel],
                              layout: ActivityRouteGraphGeometry) -> some View {
        let color = nodeColor(node, in: shown)
        let selected = isUpstreamSelected(node.key)
        let related = isUpstreamRelated(node.key)
        let title = node.provider.isEmpty ? node.model : node.provider
        return Button { onToggleUpstream(node.key) } label: {
            RouteNodeFace(width: layout.sideWidth, height: ActivityRouteGraphGeometry.nodeHeight,
                          color: color, selected: selected) {
                nodeLabel(title: title, subtitle: node.model, dot: color)
            }
        }
        .buttonStyle(.plain)
        .opacity(related ? 1 : 0.3)
        .help("上游 \(node.provider) · \(node.model) · 点击高亮走该上游的请求，再次点击取消高亮")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("上游 \(node.provider.isEmpty ? node.model : node.provider)，模型 \(node.model)")
        .accessibilityValue(selected ? "已高亮" : "未高亮")
        .accessibilityHint("点击高亮走该上游的请求，再次点击取消高亮")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 节点两行文字：主标题 + 自定义第二行（请求节点放状态详情，上游节点放模型）。
    private func nodeLabel<Subtitle: View>(title: String, dot: Color,
                                           @ViewBuilder subtitle: () -> Subtitle) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                subtitle()
            }
            Spacer(minLength: 0)
        }
    }

    /// 纯文本第二行（上游节点模型名）。
    private func nodeLabel(title: String, subtitle: String, dot: Color) -> some View {
        nodeLabel(title: title, dot: dot) {
            Text(subtitle)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// 中间 EZSwitch 节点（点击清除高亮）。
    private func routerNode(_ layout: ActivityRouteGraphGeometry) -> some View {
        Button { onClear() } label: {
            VStack(spacing: 3) {
                Text("EZSwitch").font(.system(size: 12, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(routerSubtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: layout.midWidth, height: layout.midHeight)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selection == nil ? Color.primary.opacity(0.14) : ActivityPalette.active,
                              lineWidth: selection == nil ? 1 : 1.6))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .position(x: layout.midX, y: layout.midCenterY)
        .help(selection == nil ? "EZSwitch 路由 · \(routerSubtitle)"
                               : "已高亮 · 点击清除高亮")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("EZSwitch 路由，\(routerSubtitle)")
        .accessibilityValue(selection == nil ? "未高亮" : "已高亮")
        .accessibilityHint(selection == nil ? "当前没有高亮对象" : "点击清除高亮")
    }

    /// 图中驻留终态数量（仅统计实际展示的前 `graphRequests` 个节点）。
    private var residentShownCount: Int {
        rows.prefix(ActivityLimits.graphRequests).filter { !$0.isActive }.count
    }

    /// 中间节点文案：在途数只算进行中；有刚结束驻留节点时补充说明，避免把驻留终态误报为进行中。
    private var routerSubtitle: String {
        let residents = residentShownCount
        if activeCount > 0 && residents > 0 { return "\(activeCount) 条在途 · \(residents) 条刚结束" }
        if activeCount > 0 { return "\(activeCount) 条在途" }
        if residents > 0 { return "\(residents) 条刚结束" }
        return "0 条在途"
    }

    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("当前没有进行中的请求")
                .font(.callout).foregroundStyle(.secondary)
            Text("客户端发起请求后，这里会实时显示「请求 → EZSwitch → 上游」的流向。")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: 辅助

    private struct UpstreamNode: Equatable {
        let key: String
        let provider: String
        let model: String
    }

    /// 右列节点：按左列出现顺序去重（稳定顺序，不随刷新重排）。
    private func upstreamNodes(_ shown: [ActivityRowModel]) -> [UpstreamNode] {
        var seen = Set<String>()
        var result: [UpstreamNode] = []
        for row in shown {
            guard let key = row.upstreamKey, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(UpstreamNode(key: key,
                                       provider: row.upstreamProvider ?? "",
                                       model: row.upstreamModel ?? ""))
        }
        return result
    }

    /// 上游节点取用它的第一条（或选中请求的）连线颜色，保持左右同色。
    private func nodeColor(_ node: UpstreamNode, in shown: [ActivityRowModel]) -> Color {
        if case .request(let id) = selection,
           let row = shown.first(where: { $0.id == id }), row.upstreamKey == node.key {
            return colorFor(id)
        }
        if let row = shown.first(where: { $0.upstreamKey == node.key }) {
            return colorFor(row.id)
        }
        return Color.secondary
    }

    private func isSelected(request id: UUID) -> Bool {
        if case .request(let selected) = selection { return selected == id }
        return false
    }

    private func isUpstreamSelected(_ key: String) -> Bool {
        if case .upstream(let selected) = selection { return selected == key }
        return false
    }

    private func curve(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        let midX = (a.x + b.x) / 2
        path.move(to: a)
        path.addCurve(to: b,
                      control1: CGPoint(x: midX, y: a.y),
                      control2: CGPoint(x: midX, y: b.y))
        return path
    }
}

// MARK: - 几何

/// 节点卡片：固定宽度即边框宽度，圆角矩形覆盖整个 `frame`。
private struct RouteNodeFace<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let color: Color
    let selected: Bool
    let content: Content

    init(width: CGFloat, height: CGFloat, color: Color, selected: Bool,
         @ViewBuilder content: () -> Content) {
        self.width = width
        self.height = height
        self.color = color
        self.selected = selected
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ActivityRouteGraphGeometry.cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .padding(.horizontal, 8)
            .frame(width: width, height: height, alignment: .leading)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: selected ? 1.8 : 1))
            .contentShape(shape)
    }

    private var background: Color {
        selected ? color.opacity(0.18) : Color(nsColor: .controlBackgroundColor)
    }

    private var border: Color {
        selected ? color : Color.primary.opacity(0.14)
    }
}

/// 三列布局几何（解析计算，可直接单测）。
///
/// 列宽随窗口收缩；`sideWidth` 封顶 `maxSideWidth`，宽窗口多余空间留在两侧外边距。
/// 连线锚点由节点 `frame` 边缘 / 中心派生。
struct ActivityRouteGraphGeometry {
    /// 两行文字（主标题 + 状态/模型）留出呼吸空间，正常窗口下不挤压；窄宽度靠截断 + tooltip。
    static let nodeHeight: CGFloat = 38
    static let rowGap: CGFloat = 10
    static let topPad: CGFloat = 12
    static let cornerRadius: CGFloat = 8
    static let anchorMargin: CGFloat = 12

    static let minSideWidth: CGFloat = 88
    static let maxSideWidth: CGFloat = 200
    static let minMidWidth: CGFloat = 64
    static let maxMidWidth: CGFloat = 104
    static let minGap: CGFloat = 14
    static let maxGap: CGFloat = 60

    let width: CGFloat
    let height: CGFloat
    let sideWidth: CGFloat
    let midWidth: CGFloat
    let midHeight: CGFloat
    let leftX: CGFloat
    let midX: CGFloat
    let rightX: CGFloat
    let requestCount: Int
    let upstreamCount: Int

    private let usableHeight: CGFloat
    private let rowsHeight: CGFloat
    private let upstreamRowsHeight: CGFloat

    /// 一列节点块（含行距）的总高度；0 个节点时为 0。
    static func blockHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * nodeHeight + CGFloat(count - 1) * rowGap
    }

    /// 中间节点高度：随连接数伸缩，但锚点始终留在节点面内。
    static func midHeight(for count: Int) -> CGFloat {
        let n = max(count, 1)
        return min(max(44, 24 + CGFloat(n - 1) * 12), 104)
    }

    init(width: CGFloat, height: CGFloat, requestCount: Int, upstreamCount: Int) {
        let w = max(width, 1)
        let h = max(height, 1)
        self.width = w
        self.height = h
        self.requestCount = max(requestCount, 0)
        self.upstreamCount = max(upstreamCount, 0)

        let midWidth = min(max(w * 0.18, Self.minMidWidth), Self.maxMidWidth)
        let gap = min(max(w * 0.07, Self.minGap), Self.maxGap)
        let sideWidth = min(max((w - midWidth - gap * 2) / 2, Self.minSideWidth), Self.maxSideWidth)
        self.midWidth = midWidth
        self.sideWidth = sideWidth

        let total = sideWidth * 2 + midWidth + gap * 2
        let inset = max(w - total, 0) / 2
        self.leftX = inset + sideWidth / 2
        self.midX = inset + sideWidth + gap + midWidth / 2
        self.rightX = inset + sideWidth + gap + midWidth + gap + sideWidth / 2

        self.midHeight = Self.midHeight(for: self.requestCount)
        self.usableHeight = max(h - Self.topPad * 2, 1)
        self.rowsHeight = Self.blockHeight(count: self.requestCount)
        self.upstreamRowsHeight = Self.blockHeight(count: self.upstreamCount)
    }

    // MARK: 竖直位置

    var midCenterY: CGFloat { Self.topPad + usableHeight / 2 }

    /// 第 i 个请求节点的中心 y（整块在可用高度内居中）。
    func requestCenterY(_ index: Int) -> CGFloat {
        let top = Self.topPad + max((usableHeight - rowsHeight) / 2, 0)
        return top + Self.nodeHeight / 2 + CGFloat(index) * (Self.nodeHeight + Self.rowGap)
    }

    /// 第 i 个上游节点的中心 y（整块在可用高度内居中）。
    func upstreamCenterY(_ index: Int) -> CGFloat {
        let top = Self.topPad + max((usableHeight - upstreamRowsHeight) / 2, 0)
        return top + Self.nodeHeight / 2 + CGFloat(index) * (Self.nodeHeight + Self.rowGap)
    }

    /// 第 i 条连线在中间节点面上的锚点 y：在节点可见高度内等距错开。
    func midAnchorY(_ index: Int) -> CGFloat {
        let n = max(requestCount, 1)
        guard n > 1 else { return midCenterY }
        let span = max(midHeight - Self.anchorMargin * 2, 0)
        let spacing = span / CGFloat(n - 1)
        return midCenterY + (CGFloat(index) - CGFloat(n - 1) / 2) * spacing
    }

    // MARK: 节点 frame

    var routerNodeFrame: CGRect {
        CGRect(x: midX - midWidth / 2, y: midCenterY - midHeight / 2,
               width: midWidth, height: midHeight)
    }

    func requestNodeFrame(_ index: Int) -> CGRect {
        CGRect(x: leftX - sideWidth / 2, y: requestCenterY(index) - Self.nodeHeight / 2,
               width: sideWidth, height: Self.nodeHeight)
    }

    func upstreamNodeFrame(_ index: Int) -> CGRect {
        CGRect(x: rightX - sideWidth / 2, y: upstreamCenterY(index) - Self.nodeHeight / 2,
               width: sideWidth, height: Self.nodeHeight)
    }

    // MARK: 连线锚点（取自节点可见边框）

    /// 请求节点右边缘中点。
    func leftAnchor(_ index: Int) -> CGPoint {
        let frame = requestNodeFrame(index)
        return CGPoint(x: frame.maxX, y: frame.midY)
    }

    /// 中间节点左边缘中点。
    func midLeftAnchor(_ index: Int) -> CGPoint {
        CGPoint(x: routerNodeFrame.minX, y: midAnchorY(index))
    }

    /// 中间节点右边缘中点。
    func midRightAnchor(_ index: Int) -> CGPoint {
        CGPoint(x: routerNodeFrame.maxX, y: midAnchorY(index))
    }

    /// 上游节点左边缘中点。
    func rightAnchor(_ index: Int) -> CGPoint {
        let frame = upstreamNodeFrame(index)
        return CGPoint(x: frame.minX, y: frame.midY)
    }
}
