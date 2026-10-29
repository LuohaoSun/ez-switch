import SwiftUI

/// 请求表的列宽：按可用宽度自适应，窄窗口先隐藏 TPS，再隐藏 TTFT、耗时、时间。
/// 「API 类型」「路由」「上游模型」各自独立成列，窄窗口也不合并；
/// 路由名通常很短，用定宽避免把整段剩余宽度都吃掉，多余空间全部让给上游模型。
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
    let upstreamMinWidth: CGFloat
    let statusWidth: CGFloat
    let attemptsWidth: CGFloat
    let tokenWidth: CGFloat
    let elapsedWidth: CGFloat
    let ttftWidth: CGFloat
    let tpsIncludingWidth: CGFloat
    let spacing: CGFloat

    init(width: CGFloat) {
        let w = max(width, 320)
        let narrow = w < 600
        self.spacing = narrow ? 6 : 8
        self.leading = 22
        self.showTime = w >= 720
        self.showElapsed = w >= 820
        // TTFT 只有数字、宽度可控，和「耗时」同档出现；TPS 更宽，等窗口再大一些才加。
        self.showTTFT = w >= 820
        self.showTPS = w >= 960
        self.timeWidth = self.showTime ? 58 : 0
        self.elapsedWidth = self.showElapsed ? 56 : 0
        self.ttftWidth = self.showTTFT ? 58 : 0
        self.tpsIncludingWidth = self.showTPS ? 84 : 0
        self.apiWidth = narrow ? 60 : 68
        self.statusWidth = narrow ? 66 : 74
        self.attemptsWidth = narrow ? 44 : 52
        self.tokenWidth = narrow ? 48 : 54
        // 路由定宽（长名字中间截断、悬停看全称）；上游模型列吃掉剩余宽度，且有下限。
        self.routeWidth = narrow ? 64 : 96
        self.upstreamMinWidth = narrow ? 72 : 96
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
                .frame(minWidth: columns.upstreamMinWidth, maxWidth: .infinity, alignment: .leading)
            Text("状态").frame(width: columns.statusWidth, alignment: .leading)
            Text("尝试")
                .lineLimit(1)
                .frame(width: columns.attemptsWidth, alignment: .leading)
                .help("尝试序号：显示第 N/M 次尝试；已回退的旧尝试会保留为独立条目。")
                .accessibilityLabel("尝试序号")
            Text("输入").frame(width: columns.tokenWidth, alignment: .trailing)
            Text("输出").frame(width: columns.tokenWidth, alignment: .trailing)
            if columns.showElapsed {
                Text("耗时").frame(width: columns.elapsedWidth, alignment: .trailing)
            }
            if columns.showTTFT {
                Text("TTFT")
                    .lineLimit(1)
                    .frame(width: columns.ttftWidth, alignment: .trailing)
                    .help("\(ActivityPerformanceHelp.ttft)\n\(ActivityPerformanceHelp.validity)")
                    .accessibilityLabel("TTFT（首字等待）")
            }
            if columns.showTPS {
                Text("TPS 含 TTFT")
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: columns.tpsIncludingWidth, alignment: .trailing)
                    .help("\(ActivityPerformanceHelp.tpsIncluding)\n\(ActivityPerformanceHelp.validity)")
                    .accessibilityLabel("TPS（含 TTFT）")
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
                .frame(width: columns.routeWidth, alignment: .leading)
                .help(row.routeName)

            upstreamCell

            Text(row.statusText)
                .font(.system(size: 11)).foregroundStyle(row.tone.color)
                .lineLimit(1)
                .frame(width: columns.statusWidth, alignment: .leading)

            Group {
                if let progress = row.attemptProgressText {
                    Text(progress)
                        .font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(row.phase == .fallenBack ? ActivityPalette.warn : Color.secondary)
                        .help("第 \(row.attemptIndex)/\(row.attemptCount) 次尝试；同一请求的尝试按时间倒序排列。")
                        .accessibilityLabel("第 \(row.attemptIndex) 次，共 \(row.attemptCount) 次尝试")
                } else {
                    Text("—")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: columns.attemptsWidth, alignment: .leading)

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

            if columns.showTTFT {
                Text(row.ttftText)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: columns.ttftWidth, alignment: .trailing)
                    .help("\(ActivityPerformanceHelp.ttft)\n当前：\(row.ttftText)\n\(ActivityPerformanceHelp.validity)")
                    .accessibilityLabel("TTFT（首字等待） \(row.ttftText)")
            }
            if columns.showTPS {
                Text(row.tpsIncludingTTFTText)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
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
            Text(row.detailFooterText)
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
