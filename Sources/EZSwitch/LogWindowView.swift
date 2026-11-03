import SwiftUI
import AppKit

/// 活动页局部字型档位：列表、流向图和底部状态共用一套字号，避免各处散落字面量。
/// 图节点的两行文字固定 12/10pt，与 `ActivityRouteGraphGeometry.nodeHeight` 的几何约定一致。
enum ActivityTypeScale {
    /// 卡片内小节标题与状态行（12pt）。
    static let label = Font.system(size: 12)
    static let labelMedium = Font.system(size: 12, weight: .medium)
    /// 表格单元格、表头及辅助说明（11pt）。
    static let cell = Font.system(size: 11)
    /// 数字列：圆角数字，保持等宽对齐。
    static let number = Font.system(.caption, design: .rounded)
    static let tokenNumber = Font.system(.callout, design: .rounded)
    static let compactNumber = Font.system(.caption2, design: .rounded)
    /// 协议徽标（10pt）。
    static let badge = Font.system(size: 10)
    /// 流向图节点：固定两行高度，不改字号以免挤压固定 38pt 节点。
    static let nodeTitle = Font.system(size: 12)
    static let nodeTitleMedium = Font.system(size: 12, weight: .medium)
    static let nodeSubtitle = Font.system(size: 10)
    /// 展开箭头等微型符号。
    static let microSymbol = Font.system(size: 9, weight: .semibold)
}

/// 活动页：顶部实时流向图（请求 → EZSwitch → 上游），下方简洁请求表。
/// 工具栏保留暂停 / 复制，搜索走 `.searchable`；点图节点只高亮，不改动列表内容。
struct LogWindowView: View {
    @StateObject private var model = ActivityViewModel()

    var body: some View {
        GeometryReader { geo in
            let hPad: CGFloat = geo.size.width < 620 ? 12 : 20
            let columns = ActivityColumns(width: max(geo.size.width - hPad * 2, 320))
            VStack(spacing: 0) {
                // 实时流向图固定在顶部：请求表单独滚动，图不会跟着滚出视野。
                graphSection
                    .padding(.horizontal, hPad)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                requestTable(columns: columns)
                    .padding(.horizontal, hPad)

                foot
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // 活动页也作为独立小窗口显示，保留自己的标题；设置窗口内由 SettingsView 提供窗口标题。
        .navigationTitle("活动")
        .searchable(text: $model.query, prompt: "搜索路由、上游模型或 #ID")
        .background(WindowActivator().frame(width: 0, height: 0))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.togglePause()
                } label: {
                    Label(model.paused ? "继续" : "暂停", systemImage: model.paused ? "play" : "pause")
                }
                Button {
                    copyText(model.copyText())
                } label: {
                    Label("复制列表", systemImage: "doc.on.doc")
                }
                .disabled(model.visibleRows.isEmpty)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// 顶部仪表卡：状态行 + 实时流向拓扑 + 溢出说明。
    private var graphSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine
            ActivityRouteGraph(
                rows: model.graphRows,
                activeCount: model.activeCount,
                selection: model.selection,
                colorFor: { model.color(for: $0) },
                isRequestRelated: { model.isRequestRelated($0) },
                isUpstreamRelated: { model.isUpstreamRelated($0) },
                onToggleRequest: { model.toggle(request: $0) },
                onToggleUpstream: { model.toggle(upstream: $0) },
                onClear: { model.clearSelection() }
            )
            .padding(.top, 8)

            if let overflow = model.graphOverflowText {
                Text(overflow)
                    .font(ActivityTypeScale.cell)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .cardSurface(padding: AppDesign.Space.card)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .font(ActivityTypeScale.label)
                .foregroundStyle(.secondary)
            Text(model.statusSummary)
                .font(ActivityTypeScale.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var statusSymbol: String {
        if model.paused { return "pause.circle" }
        return model.activeCount > 0 ? "dot.radiowaves.left.and.right" : "checkmark.circle"
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("最近请求与尝试")
                .font(ActivityTypeScale.labelMedium)
            CountBadge(count: model.visibleRows.count)
                .help("当前显示 \(model.visibleRows.count) 条请求与尝试记录")
            if let highlight = model.highlightLabel {
                Text(highlight)
                    .font(ActivityTypeScale.cell)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.selection != nil {
                Button("取消高亮") { model.clearSelection() }
                    .buttonStyle(.plain)
                    .font(ActivityTypeScale.label)
                    .foregroundStyle(AppDesign.brand)
            }
        }
    }

    /// 请求卡：标题与表头固定，只有数据行在卡内滚动。
    private func requestTable(columns: ActivityColumns) -> some View {
        VStack(spacing: 0) {
            listHeader
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            ActivityListHeader(columns: columns)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.visibleRows.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.visibleRows) { row in
                            ActivityRequestRow(row: row, columns: columns,
                                               accent: model.color(for: row.groupID),
                                               isHighlighted: model.isRowHighlighted(row),
                                               isExpanded: model.isExpanded(row.id),
                                               onToggleExpand: { model.toggleExpanded(row.id) })
                            Divider().opacity(0.65)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 与流向图、统计页共用同一卡片表面；表头与行需要收进圆角，所以这里开启内容裁剪。
        .modifier(CardSurfaceModifier(cornerRadius: AppDesign.Radius.card, clipsContent: true))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(isSearching ? "没有匹配的请求" : "暂无请求记录")
                .font(ActivityTypeScale.label)
                .foregroundStyle(.secondary)
            Text(isSearching ? "尝试更换搜索词。" : "服务启动和转发请求会显示在这里。")
                .font(ActivityTypeScale.cell)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var isSearching: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var foot: some View {
        Text(footText)
            .font(ActivityTypeScale.cell)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footText: String {
        var parts: [String] = []
        parts.append(model.paused ? "显示已暂停 · 恢复后继续更新" : "每秒刷新 · 点击条目查看缓存、首字与回退过程")
        if model.capacity > 0 { parts.append("保留最近 \(model.capacity) 个请求") }
        if model.evictedCount > 0 { parts.append("已超出保留上限 \(model.evictedCount) 个请求") }
        return parts.joined(separator: "　·　")
    }
}
