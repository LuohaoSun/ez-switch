import SwiftUI
import AppKit

/// 活动页：顶部实时流向图（请求 → EZSwitch → 上游），下方简洁请求表。
/// 工具栏保留暂停 / 复制，搜索走 `.searchable`；点图节点只高亮，不改动列表内容。
struct LogWindowView: View {
    @StateObject private var model = ActivityViewModel()

    var body: some View {
        GeometryReader { geo in
            let hPad: CGFloat = geo.size.width < 620 ? 12 : 20
            let columns = ActivityColumns(width: max(geo.size.width - hPad * 2, 320))
            ScrollView {
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
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }

                    Divider().padding(.top, 10)
                    listHeader
                    requestTable(columns: columns)
                    foot
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(model.statusSummary)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var statusSymbol: String {
        if model.paused { return "pause.circle" }
        return model.activeCount > 0 ? "dot.radiowaves.left.and.right" : "checkmark.circle"
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            Text("最近请求").font(.system(size: 12, weight: .medium))
            if let highlight = model.highlightLabel {
                Text(highlight).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.selection != nil {
                Button("取消高亮") { model.clearSelection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func requestTable(columns: ActivityColumns) -> some View {
        VStack(spacing: 0) {
            ActivityListHeader(columns: columns)
            Divider()
            if model.visibleRows.isEmpty {
                emptyState
            } else {
                ForEach(model.visibleRows) { row in
                    ActivityRequestRow(row: row, columns: columns,
                                       accent: model.color(for: row.id),
                                       isHighlighted: model.isRowHighlighted(row),
                                       isExpanded: model.isExpanded(row.id),
                                       onToggleExpand: { model.toggleExpanded(row.id) })
                    Divider().opacity(0.5)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(isSearching ? "没有匹配的请求" : "暂无请求记录")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(isSearching ? "尝试更换搜索词。" : "服务启动和转发请求会显示在这里。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var isSearching: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var foot: some View {
        Text(footText)
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
    }

    private var footText: String {
        var parts: [String] = []
        parts.append(model.paused ? "显示已暂停 · 恢复后继续更新" : "每秒刷新 · 点击请求查看缓存、首字与回退过程")
        if model.capacity > 0 { parts.append("保留最近 \(model.capacity) 条") }
        if model.evictedCount > 0 { parts.append("已超出保留上限 \(model.evictedCount) 条") }
        return parts.joined(separator: "　·　")
    }
}
