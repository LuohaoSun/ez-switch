import SwiftUI

/// 请求表的列宽：按可用宽度自适应，窄窗口先隐藏 TPS，再隐藏 TTFT、耗时、时间。
/// 「API 类型」「路由」「上游模型」各自独立成列，窄窗口也不合并。
///
/// 剩余宽度的分配：不再让「上游模型」一列独吞（宽窗口会出现中间大片留白、
/// 右侧数字列反而挤在边上），而是按权重摊给真正能吃宽度的列——上游模型 3.5、
/// 状态 1.2、TPS 1.2、输入/输出/TTFT/耗时各 1。时间/API/路由是短标签，定宽不参与伸展。
struct ActivityColumns {
    let showTime: Bool
    let showElapsed: Bool
    /// 请求级首字等待列：比吞吐轻得多，更早出现，中等宽度就能看到。
    let showTTFT: Bool
    /// 请求级吞吐列（TPS 含 TTFT）：最占宽度，最后出现。
    let showTPS: Bool
    let leading: CGFloat
    let timeWidth: CGFloat
    let apiWidth: CGFloat
    let routeWidth: CGFloat
    let upstreamWidth: CGFloat
    let statusWidth: CGFloat
    /// 输入、输出共用同一宽度，两列数值起点才对得齐。
    let tokenWidth: CGFloat
    let elapsedWidth: CGFloat
    let ttftWidth: CGFloat
    let tpsIncludingWidth: CGFloat
    let spacing: CGFloat

    init(width: CGFloat) {
        let w = max(width, 320)
        let narrow = w < 600
        self.spacing = narrow ? 6 : (w >= 1080 ? 12 : 9)
        self.leading = 22
        self.showTime = w >= 720
        self.showElapsed = w >= 820
        // TTFT 只有数字、宽度可控，和「耗时」同档出现；TPS 更宽，等窗口再大一些才加。
        self.showTTFT = w >= 820
        self.showTPS = w >= 960

        // 起始宽度只保证内容放得下；多余宽度按下面的权重分配。
        let timeBase: CGFloat = 56
        let apiBase: CGFloat = narrow ? 60 : 66
        let routeBase: CGFloat = narrow ? 64 : 92
        let upstreamBase: CGFloat = narrow ? 72 : 104
        let statusBase: CGFloat = narrow ? 62 : 70
        let tokenBase: CGFloat = narrow ? 44 : 50
        let ttftBase: CGFloat = narrow ? 48 : 52
        let elapsedBase: CGFloat = narrow ? 46 : 52
        let tpsBase: CGFloat = 60

        // 参与伸展的列：起始宽度只保证内容放得下，多余宽度按权重摊分。
        // 每一列都有上限——宽窗口下让列无限变宽只是把内容拉散，
        // 极端宽的窗口宁可右侧留白，也不拉出一条空荡荡的长行。
        var slots: [(base: CGFloat, weight: CGFloat, cap: CGFloat?)] = [
            (upstreamBase, 3.5, 512),
            (statusBase, 1.2, 96),
            (tokenBase, 1, 84),
            (tokenBase, 1, 84),
        ]
        if self.showTTFT { slots.append((ttftBase, 1, 84)) }
        if self.showElapsed { slots.append((elapsedBase, 1, 84)) }
        if self.showTPS { slots.append((tpsBase, 1.2, 104)) }

        // HStack：leading + 各数据列一共 views 个视图，间隔就是 views-1 段。
        let views = 1 + (self.showTime ? 1 : 0) + 2 + slots.count
        let gapsWidth = CGFloat(views - 1) * self.spacing
        let baseSum = apiBase + routeBase + (self.showTime ? timeBase : 0)
            + slots.reduce(0) { $0 + $1.base }
        var granted = slots.map(\.base)
        var leftover = max(0, w - self.leading - gapsWidth - baseSum)
        // 按权重的比例加水，触顶的列把余量让给还没触顶的列；上游模型无上限，最终兜住全部余量。
        for _ in 0..<4 {
            guard leftover > 0.5 else { break }
            let open = slots.indices.filter { i in
                guard let cap = slots[i].cap else { return true }
                return granted[i] < cap - 0.5
            }
            let weightSum = open.reduce(CGFloat(0)) { $0 + slots[$1].weight }
            guard weightSum > 0 else { break }
            let unit = leftover / weightSum
            var used: CGFloat = 0
            for i in open {
                let want = slots[i].weight * unit
                let room = slots[i].cap.map { max(0, $0 - granted[i]) } ?? want
                let add = min(want, room)
                granted[i] += add
                used += add
            }
            leftover -= used
        }

        self.upstreamWidth = granted[0]
        self.statusWidth = granted[1]
        self.tokenWidth = granted[2]
        var index = 4
        self.ttftWidth = self.showTTFT ? granted[index] : 0
        if self.showTTFT { index += 1 }
        self.elapsedWidth = self.showElapsed ? granted[index] : 0
        if self.showElapsed { index += 1 }
        self.tpsIncludingWidth = self.showTPS ? granted[index] : 0
        self.timeWidth = self.showTime ? timeBase : 0
        self.apiWidth = apiBase
        self.routeWidth = routeBase
    }
}

/// 性能列的 help / accessibility 口径说明（表头与数据行共用，避免两处口径漂移）。
enum ActivityPerformanceHelp {
    static let ttft = "TTFT（首字等待）：本次上游尝试从开始到首个有效输出片段，不含之前的回退等待。"
    static let tpsIncluding = "TPS（含 TTFT）= 本次尝试输出 tokens × 1000 /（本次尝试 TTFT + 生成时长）；分母覆盖该次尝试的整个响应期。"
    static let validity = "仅成功完成的流式尝试显示最终值；已回退、进行中、非流式、失败或数据不足显示 —。"
}

/// 表头：与请求行同列宽。
struct ActivityListHeader: View {
    let columns: ActivityColumns

    var body: some View {
        HStack(spacing: columns.spacing) {
            Color.clear.frame(width: columns.leading, height: 1)
            if columns.showTime {
                Text("时间").frame(width: columns.timeWidth, alignment: .leading)
            }
            Text("API 类型")
                .lineLimit(1)
                .frame(width: columns.apiWidth, alignment: .leading)
            Text("路由")
                .lineLimit(1)
                .frame(width: columns.routeWidth, alignment: .leading)
            Text("上游模型")
                .lineLimit(1)
                .frame(width: columns.upstreamWidth, alignment: .leading)
            Text("状态").frame(width: columns.statusWidth, alignment: .leading)
            Text("输入").frame(width: columns.tokenWidth, alignment: .trailing)
            Text("输出").frame(width: columns.tokenWidth, alignment: .trailing)
            if columns.showTTFT {
                Text("TTFT")
                    .lineLimit(1)
                    .frame(width: columns.ttftWidth, alignment: .trailing)
                    .help("\(ActivityPerformanceHelp.ttft)\n\(ActivityPerformanceHelp.validity)")
                    .accessibilityLabel("TTFT（首字等待）")
            }
            if columns.showElapsed {
                Text("耗时").frame(width: columns.elapsedWidth, alignment: .trailing)
            }
            if columns.showTPS {
                Text("TPS 含 TTFT")
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: columns.tpsIncludingWidth, alignment: .trailing)
                    .help("\(ActivityPerformanceHelp.tpsIncluding)\n\(ActivityPerformanceHelp.validity)")
                    .accessibilityLabel("TPS（含 TTFT）")
            }
        }
        .font(ActivityTypeScale.cell)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(AppDesign.inset)
    }
}

/// 一行请求。点击展开详情（缓存 / TTFT / 回退链），点图节点只高亮本行。
/// 展开状态由 `ActivityViewModel.expandedIDs` 持有，避免 `@State`（仅 CLT 环境不支持其宏）。
struct ActivityRequestRow: View {
    let row: ActivityRowModel
    let columns: ActivityColumns
    let accent: Color
    let isHighlighted: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isExpanded { detail }
        }
        .background(rowBackground)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hover.isHovered = hovering }
        }
    }

    /// 图上高亮优先；没有高亮对象时，悬停给一层极淡的底，帮助扫行且不改变行高。
    private var rowBackground: Color {
        if isHighlighted { return ActivityPalette.active.opacity(0.08) }
        return hover.isHovered ? AppDesign.hover : Color.clear
    }

    private var summary: some View {
        HStack(spacing: columns.spacing) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(ActivityTypeScale.microSymbol)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Circle().fill(row.isActive ? accent : Color.clear).frame(width: 6, height: 6)
            }
            .frame(width: columns.leading, alignment: .leading)

            if columns.showTime {
                Text(ActivityFormat.time(row.startedAt))
                    .font(ActivityTypeScale.number).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: columns.timeWidth, alignment: .leading)
            }

            apiCell

            Text(row.routeName)
                .font(ActivityTypeScale.labelMedium)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: columns.routeWidth, alignment: .leading)
                .help(row.routeName)

            upstreamCell

            Text(row.statusText)
                .font(ActivityTypeScale.labelMedium)
                .foregroundStyle(row.tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(row.tone.color.opacity(0.12), in: Capsule())
                .frame(width: columns.statusWidth, alignment: .leading)
                .help(statusHelp)

            Text(ActivityFormat.tokenCell(row.tokens.input))
                .font(ActivityTypeScale.tokenNumber).monospacedDigit()
                .frame(width: columns.tokenWidth, alignment: .trailing)
            Text(ActivityFormat.tokenCell(row.tokens.output))
                .font(ActivityTypeScale.tokenNumber).monospacedDigit()
                .frame(width: columns.tokenWidth, alignment: .trailing)

            if columns.showTTFT {
                Text(row.ttftText)
                    .font(ActivityTypeScale.number).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: columns.ttftWidth, alignment: .trailing)
                    .help("\(ActivityPerformanceHelp.ttft)\n当前：\(row.ttftText)\n\(ActivityPerformanceHelp.validity)")
                    .accessibilityLabel("TTFT（首字等待） \(row.ttftText)")
            }

            if columns.showElapsed {
                Text(row.durationText)
                    .font(ActivityTypeScale.number).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: columns.elapsedWidth, alignment: .trailing)
            }
            if columns.showTPS {
                Text(row.tpsIncludingTTFTText)
                    .font(ActivityTypeScale.number).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: columns.tpsIncludingWidth, alignment: .trailing)
                    .help("\(ActivityPerformanceHelp.tpsIncluding)\n当前：\(row.tpsIncludingTTFTText)\n\(ActivityPerformanceHelp.validity)")
                    .accessibilityLabel("TPS（含 TTFT） \(row.tpsIncludingTTFTText)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.12)) { onToggleExpand() }
        }
    }

    /// 状态胶囊的悬停说明。多次尝试时在这里补出尝试序号——表格不再单列「尝试」，
    /// 但回退了几次仍然看得到（明细、复制文本里也有）。
    private var statusHelp: String {
        guard row.attemptCount > 1 else { return row.statusText }
        return "\(row.statusText) · 第 \(row.attemptIndex)/\(row.attemptCount) 次尝试"
    }

    private var apiCell: some View {
        protocolBadge
            .frame(width: columns.apiWidth, alignment: .leading)
    }

    /// 上游模型列：provider 与 model 分两行，长文本尾部截断、悬停可看全称。
    private var upstreamCell: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let provider = row.upstreamProvider, !provider.isEmpty {
                Text(provider)
                    .font(ActivityTypeScale.cell)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let model = row.upstreamModel, !model.isEmpty {
                Text(model)
                    .font(ActivityTypeScale.cell).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !row.hasUpstream {
                Text("未绑定上游")
                    .font(ActivityTypeScale.cell).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: columns.upstreamWidth, alignment: .leading)
        .help(row.identityModelText)
    }

    private var protocolBadge: some View {
        Text(row.protocolKind.badgeTitle)
            .font(ActivityTypeScale.badge)
            .foregroundStyle(protocolColor)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(protocolColor.opacity(0.13), in: Capsule())
    }

    private var protocolColor: Color {
        switch row.protocolKind {
        case .chat: return ActivityPalette.color(forSlot: 0)
        case .responses: return ActivityPalette.color(forSlot: 5)
        case .messages: return ActivityPalette.color(forSlot: 2)
        case .gemini: return ActivityPalette.color(forSlot: 1)
        }
    }

    private var detail: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(accent.opacity(0.45))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(row.detailLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(ActivityTypeScale.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(row.detailFooterText)
                    .font(ActivityTypeScale.cell).foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
        .padding(.leading, detailLeading)
        .padding(.trailing, 12)
        .textSelection(.enabled)
    }

    private var detailLeading: CGFloat {
        let base = 12 + columns.leading + columns.spacing
        return columns.showTime ? base + columns.timeWidth + columns.spacing : base
    }
}
