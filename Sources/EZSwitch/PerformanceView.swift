import SwiftUI

/// 性能统计视图，嵌在「用量」页内，与用量共用时间区间筛选。
///
/// 顶部三张指标卡（TTFT P50 / P95、TPS P50，各带独立样本数），
/// 下方是可切换分组（路由 / 供应商 / 模型）与排序字段的比较表。
/// 路由维度的 TTFT 是含自动回退的请求总等待；供应商 / 模型维度是单次尝试 TTFT。
struct PerformanceView: View {
    @ObservedObject var model: UsageViewModel
    let store: UsageStore

    private let columnWidth: CGFloat = 96
    /// 样本少于此值时提示 P95 仅供参考。
    private let lowSampleThreshold = 20

    var body: some View {
        content
    }

    private var summary: PerformanceSummary { model.performanceSnapshot.summary }

    /// 路由维度用含自动回退的请求总等待，其余维度用单次尝试首输出。
    private var isRouteGrouping: Bool { model.performanceGrouping == .route }

    private var ttftLabelSuffix: String { isRouteGrouping ? "（总等待）" : "" }

    private var ttftUnit: String { isRouteGrouping ? "总等待" : "首输出" }

    private var ttftP50Value: Double? {
        isRouteGrouping ? summary.requestTTFTP50MS : summary.ttftP50MS
    }

    private var ttftP95Value: Double? {
        isRouteGrouping ? summary.requestTTFTP95MS : summary.ttftP95MS
    }

    /// 当前分组对应的有效 TTFT 样本：路由用 requestTTFT 样本，其余用尝试 TTFT 样本。
    private func ttftSampleCount(_ s: PerformanceSummary) -> Int {
        isRouteGrouping ? s.requestTTFTSamples : s.ttftSamples
    }

    private var activeTTFTSamples: Int { ttftSampleCount(summary) }

    // MARK: - 主体分派

    @ViewBuilder
    private var content: some View {
        switch model.performancePhase {
        case .failed(let message):
            errorState(message)
        case .idle, .loading:
            if model.isInitialLoadingPerformance {
                loadingState
            } else {
                loadedContent
            }
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if model.performanceIsEmpty {
            noHistoryState
        } else if model.performanceHasNoSamples {
            noSamplesState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.performanceLastError {
                        warningBanner(error)
                    }
                    metricsCard
                    comparisonCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 顶部指标

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                metricTile(title: "TTFT P50\(ttftLabelSuffix)",
                           value: PerformanceFormat.milliseconds(ttftP50Value),
                           unit: ttftUnit,
                           samples: activeTTFTSamples,
                           help: isRouteGrouping
                               ? "含自动回退的请求总等待（从请求开始到首个输出片段）的中位数。"
                               : "单次尝试首输出延迟的中位数；含推理/工具产生的有效输出片段。")
                metricTile(title: "TTFT P95\(ttftLabelSuffix)",
                           value: PerformanceFormat.milliseconds(ttftP95Value),
                           unit: ttftUnit,
                           samples: activeTTFTSamples,
                           help: isRouteGrouping
                               ? "含自动回退的请求总等待的 95 分位。样本偏少时波动较大。"
                               : "单次尝试首输出延迟的 95 分位。样本偏少时波动较大。")
                metricTile(title: "TPS P50",
                           value: PerformanceFormat.tps(summary.tpsP50),
                           unit: "Tokens/秒",
                           samples: summary.tpsSamples,
                           help: "上游平均输出吞吐（上游报告的输出 token 数 / 首输出至完成）的中位数；不足 2 个输出片段或 2 个输出 token 不计 TPS。")
            }

            Label(coverageText, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(coverageHelp)

            if activeTTFTSamples > 0 && activeTTFTSamples < lowSampleThreshold {
                Text("有效 TTFT 样本较少（\(activeTTFTSamples) < \(lowSampleThreshold)），P95 波动较大，仅供参考。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }

    private func metricTile(title: String, value: String, unit: String,
                            samples: Int, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(samples > 0 ? "\(unit) · 样本 \(PerformanceFormat.samples(samples))" : "暂无样本")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .help(help)
        .accessibilityElement(children: .combine)
    }

    /// 中性样本覆盖行：只报告各指标的有效样本数，不把旧历史中的失败尝试渲染成警告。
    private var coverageText: String {
        let s = summary
        guard s.attempts > 0 else { return "区间内暂无转发尝试" }
        return "有效样本 TTFT \(ttftSampleCount(s)) · TPS \(s.tpsSamples)"
    }

    /// 分母解释：成功流式的资格口径，以及包含升级前无性能数据的全部尝试历史。
    private var coverageHelp: String {
        let s = summary
        guard s.attempts > 0 else { return "区间内没有转发尝试，因此没有可统计的性能样本。" }
        return "TTFT / TPS 只统计成功完成的流式请求：区间内共 \(s.attempts) 次转发尝试，其中 \(s.successfulStreamingAttempts) 次为成功流式、进入资格分母。升级前的历史未采集性能数据，可能计入尝试却没有有效样本。"
    }

    // MARK: - 比较表

    private var comparisonCard: some View {
        let rows = model.sortedPerformanceGroups
        return VStack(alignment: .leading, spacing: 0) {
            // 与用量明细同一层级：标题、分组 segmented 紧邻，Spacer 后是排序字段/方向与项数。
            HStack(spacing: 12) {
                Text("性能明细").font(.headline)

                Picker("分组", selection: $model.performanceGrouping) {
                    ForEach(UsageGrouping.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("按分组查看性能")
                .help(groupingHelp)

                Spacer(minLength: 8)

                Picker("排序", selection: $model.performanceSortKey) {
                    ForEach(PerformanceSortKey.allCases) { key in
                        Text(key.title(for: model.performanceGrouping)).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("排序字段")
                .help("排序字段：\(model.performanceSortKey.title(for: model.performanceGrouping))")

                Button {
                    model.performanceSortAscending.toggle()
                } label: {
                    Label(model.performanceSortAscending ? "升序" : "降序",
                          systemImage: model.performanceSortAscending ? "arrow.up" : "arrow.down")
                }
                .help(model.performanceSortAscending ? "当前升序：小值在前，未测/未知置后"
                                                     : "当前降序：大值在前，未测/未知置后")

                Text("\(rows.count) 项").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            tableHeader
            Divider()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    groupRow(row)
                    if row.id != rows.last?.id {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .cardSurface()
    }

    /// 分组口径不再单独占说明行，改为分组控件的 tooltip。
    private var groupingHelp: String {
        isRouteGrouping
            ? "按路由分组：TTFT 为含自动回退的请求总等待（从请求开始到首个输出片段）。"
            : "按供应商 / 模型分组：TTFT 为单次尝试首输出（不含自动回退等待）。"
    }

    private var ttftP50Header: String {
        isRouteGrouping ? "总等待 P50" : "首输出 P50"
    }

    private var ttftP95Header: String {
        isRouteGrouping ? "总等待 P95" : "首输出 P95"
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text(ttftP50Header).frame(width: columnWidth, alignment: .trailing)
                .help(ttftHeaderHelp)
            Text(ttftP95Header).frame(width: columnWidth, alignment: .trailing)
                .help(ttftHeaderHelp)
            Text("TPS P50").frame(width: columnWidth, alignment: .trailing)
            Text("TTFT / TPS").frame(width: columnWidth, alignment: .trailing)
                .help("有效样本数：TTFT 样本 / TPS 样本（两者可能不同）")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    /// 列口径进入表头 tooltip，替代原先独立的分组说明行。
    private var ttftHeaderHelp: String {
        isRouteGrouping
            ? "路由维度：含自动回退的请求总等待（从请求开始到首个输出片段，含推理/工具产生的有效输出片段）的分位数。"
            : "供应商 / 模型维度：单次尝试首输出（不含自动回退等待，含推理/工具产生的有效输出片段）的分位数。"
    }

    private func groupRow(_ row: PerformanceGroupRow) -> some View {
        let s = row.summary
        let p50 = PerformanceFormat.milliseconds(isRouteGrouping ? s.requestTTFTP50MS : s.ttftP50MS)
        let p95 = PerformanceFormat.milliseconds(isRouteGrouping ? s.requestTTFTP95MS : s.ttftP95MS)
        let tps = PerformanceFormat.tps(s.tpsP50)
        let sampleCount = ttftSampleCount(s)
        let lowSample = sampleCount > 0 && sampleCount < lowSampleThreshold

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if lowSample {
                    Text("样本较少")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .help(row.subtitle.isEmpty ? row.title : "\(row.title)\n\(row.subtitle)")

            valueCell(p50, help: "\(ttftP50Header)：\(sampleCount) 个 TTFT 样本")
            valueCell(p95, help: "\(ttftP95Header)：\(sampleCount) 个 TTFT 样本")
            valueCell(tps, help: "TPS P50：\(s.tpsSamples) 个 TPS 样本")
            samplesCell(s)
        }
        .padding(.vertical, 7)
    }

    private func valueCell(_ text: String, help: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .rounded))
            .monospacedDigit()
            .frame(width: columnWidth, alignment: .trailing)
            .help(text == "—" ? "未测或样本不足\n\(help)" : help)
    }

    private func samplesCell(_ s: PerformanceSummary) -> some View {
        Text("\(PerformanceFormat.samples(ttftSampleCount(s))) / \(PerformanceFormat.samples(s.tpsSamples))")
            .font(.system(.callout, design: .rounded))
            .monospacedDigit()
            .frame(width: columnWidth, alignment: .trailing)
            .help("有效样本 TTFT / TPS = \(ttftSampleCount(s)) / \(s.tpsSamples)；尝试 \(s.attempts)")
    }

    // MARK: - 空 / 错误 / 加载

    private var noHistoryState: some View {
        VStack(spacing: 14) {
            EmptyState(title: "当前区间暂无记录",
                       detail: "把客户端指向本机地址并成功转发一次请求，或切换到其他时间区间查看历史性能；这里会统计流式请求的首输出延迟与吞吐。",
                       symbol: "speedometer")
            Text("转发本身不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 40)
    }

    private var noSamplesState: some View {
        VStack(spacing: 14) {
            // 分组控件在任何状态都需可达：否则切到无样本的维度后无法切回有样本的维度。
            Picker("分组", selection: $model.performanceGrouping) {
                ForEach(UsageGrouping.allCases) { grouping in
                    Text(grouping.title).tag(grouping)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .accessibilityLabel("按分组查看性能")

            EmptyState(title: "有转发记录，但暂无性能样本",
                       detail: "仅成功完成的流式请求参与 TTFT / TPS 统计；非流式、失败或被取消的请求不会计入。升级前的历史记录没有采集性能数据，因此旧流式历史也可能没有可展示的样本。",
                       symbol: "speedometer")
            Spacer()
        }
        .padding(.top, 40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("性能统计不可用").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("请求转发不受影响；统计恢复后会继续记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await model.refresh(store: store) }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("正在读取性能样本…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("刷新失败：\(message)（显示上次成功的数据；转发不受影响。）")
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 卡片外观

private extension View {
    /// 与用量页一致的轻量卡片外观（file-private，不与 UsageView 的同名扩展冲突）。
    func cardSurface() -> some View {
        self
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            .padding(.trailing, 2)
    }
}
