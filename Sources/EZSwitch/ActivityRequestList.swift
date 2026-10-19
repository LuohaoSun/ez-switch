import SwiftUI

/// 请求表的列宽：按可用宽度自适应，窄窗口先隐藏「耗时」「时间」。
/// 「API 类型」「路由」「上游模型」各自独立成列（各有下限），窄窗口也不合并。
struct ActivityColumns {
    let showTime: Bool
    let showElapsed: Bool
    let leading: CGFloat
    let timeWidth: CGFloat
    let apiWidth: CGFloat
    let routeMinWidth: CGFloat
    let upstreamMinWidth: CGFloat
    let statusWidth: CGFloat
    let tokenWidth: CGFloat
    let elapsedWidth: CGFloat
    let spacing: CGFloat

    init(width: CGFloat) {
        let w = max(width, 320)
        let narrow = w < 600
        self.spacing = narrow ? 6 : 8
        self.leading = 22
        self.showTime = w >= 720
        self.showElapsed = w >= 820
        self.timeWidth = self.showTime ? 58 : 0
        self.elapsedWidth = self.showElapsed ? 56 : 0
        self.apiWidth = narrow ? 60 : 68
        self.statusWidth = narrow ? 66 : 74
        self.tokenWidth = narrow ? 48 : 54
        // 路由 / 上游模型两列在剩余宽度内平分，且各自有下限。
        self.routeMinWidth = narrow ? 60 : 82
        self.upstreamMinWidth = narrow ? 72 : 96
    }
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
                .frame(minWidth: columns.routeMinWidth, maxWidth: .infinity, alignment: .leading)
            Text("上游模型")
                .lineLimit(1)
                .frame(minWidth: columns.upstreamMinWidth, maxWidth: .infinity, alignment: .leading)
            Text("状态").frame(width: columns.statusWidth, alignment: .leading)
            Text("输入").frame(width: columns.tokenWidth, alignment: .trailing)
            Text("输出").frame(width: columns.tokenWidth, alignment: .trailing)
            if columns.showElapsed {
                Text("耗时").frame(width: columns.elapsedWidth, alignment: .trailing)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isExpanded { detail }
        }
        .background(isHighlighted ? ActivityPalette.active.opacity(0.08) : Color.clear)
    }

    private var summary: some View {
        HStack(spacing: columns.spacing) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Circle().fill(row.isActive ? accent : Color.clear).frame(width: 6, height: 6)
            }
            .frame(width: columns.leading, alignment: .leading)

            if columns.showTime {
                Text(ActivityFormat.time(row.startedAt))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: columns.timeWidth, alignment: .leading)
            }

            apiCell

            Text(row.routeName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: columns.routeMinWidth, maxWidth: .infinity, alignment: .leading)
                .help(row.routeName)

            upstreamCell

            Text(row.statusText)
                .font(.system(size: 11)).foregroundStyle(row.tone.color)
                .lineLimit(1)
                .frame(width: columns.statusWidth, alignment: .leading)

            Text(ActivityFormat.tokenCell(row.tokens.input))
                .font(.system(size: 12)).monospacedDigit()
                .frame(width: columns.tokenWidth, alignment: .trailing)
            Text(ActivityFormat.tokenCell(row.tokens.output))
                .font(.system(size: 12)).monospacedDigit()
                .frame(width: columns.tokenWidth, alignment: .trailing)

            if columns.showElapsed {
                Text(row.durationText)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: columns.elapsedWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.12)) { onToggleExpand() }
        }
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
                    .font(.system(size: 11))
                    .lineLimit(1).truncationMode(.middle)
            }
            if let model = row.upstreamModel, !model.isEmpty {
                Text(model)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !row.hasUpstream {
                Text("未绑定上游")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: columns.upstreamMinWidth, maxWidth: .infinity, alignment: .leading)
        .help(row.identityModelText)
    }

    private var protocolBadge: some View {
        Text(row.protocolKind.badgeTitle)
            .font(.system(size: 10))
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
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(row.detailLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("#\(row.shortID) · 耗时 \(row.durationText)")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
