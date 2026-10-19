import SwiftUI

/// 性能统计视图，嵌在「用量」页内，与用量共用时间区间筛选。
///
/// 顶部三张平均指标卡（平均 TTFT、平均 TPS 含 TTFT、平均 TPS 不含 TTFT，各带独立样本数），
/// 下方是可切换分组（路由 / 供应商 / 模型）的比较表；排序不占控件，直接点击列头：
/// 点击某列按其默认方向排序，再次点击同一列反向，当前排序列显示方向箭头。
/// 路由维度的 TTFT / 含 TTFT 的 TPS 是含自动回退的请求口径；供应商 / 模型维度是单次上游尝试口径；
/// 不含 TTFT 的 TPS 两个维度共用同一字段。顶部总览固定为请求口径（与旧的 overall requestTTFT 一致）。
struct PerformanceView: View {
    @ObservedObject var model: UsageViewModel
    let store: UsageStore

    /// 三列指标与一列样本数；表头与卡片同名，留出足够宽度。
    private let columnWidth: CGFloat = 120

    var body: some View {
        content
    }

    private var summary: PerformanceSummary { model.performanceSnapshot.summary }

    /// 路由维度用含自动回退的请求口径，其余维度用单次上游尝试口径。
    private var isRouteGrouping: Bool { model.performanceGrouping == .route }

    // MARK: - 总览取值（固定请求口径）

    private var summaryTTFTValue: Double? { summary.requestTTFTMeanMS }
    private var summaryTPSIncludingValue: Double? { summary.requestTpsIncludingTTFT }
    private var summaryTPSExcludingValue: Double? { summary.tpsExcludingTTFT }

    /// 当前分组对应的有效 TTFT 样本：路由用 requestTTFT 样本，其余用尝试 TTFT 样本。
    private func ttftSampleCount(_ s: PerformanceSummary) -> Int {
        isRouteGrouping ? s.requestTTFTSamples : s.ttftSamples
    }

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
            // 总览固定请求口径；口径说明只放在各卡片 tooltip，不常驻成行。
            Text("总览").font(.headline)

            HStack(spacing: 12) {
                metricTile(title: "平均TTFT",
                           value: PerformanceFormat.milliseconds(summaryTTFTValue),
                           unit: "总等待",
                           samples: summary.requestTTFTSamples,
                           help: ttftMeanHelp(requestScope: true))
                metricTile(title: "平均TPS(含TTFT)",
                           value: PerformanceFormat.tps(summaryTPSIncludingValue),
                           unit: "Tokens/秒",
                           samples: summary.tpsSamples,
                           help: tpsMeanHelp(includingTTFT: true))
                metricTile(title: "平均TPS(不含TTFT)",
                           value: PerformanceFormat.tps(summaryTPSExcludingValue),
                           unit: "Tokens/秒",
                           samples: summary.tpsSamples,
                           help: tpsMeanHelp(includingTTFT: false))
            }

            Label(coverageText, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(coverageHelp)
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

    private func ttftMeanHelp(requestScope: Bool) -> String {
        requestScope
            ? "平均首输出延迟：含自动回退的请求总等待（从请求进入路由器到首个有效输出片段）的平均值，按样本逐条平均。"
            : "平均首输出延迟：单次上游尝试首输出（不含自动回退等待）的平均值。"
    }

    private func tpsMeanHelp(includingTTFT: Bool) -> String {
        includingTTFT
            ? "平均输出吞吐（含 TTFT，请求口径）：同一批有效样本的上游输出 token 总量 ÷（请求总等待 + 生成时长）总量，按总时长加权，不是逐请求速率的平均；输出 token 含推理 token。"
            : "平均输出吞吐（不含 TTFT，请求口径）：同一批有效样本的上游输出 token 总量 ÷ 生成时长总量（不含 TTFT），按生成时长加权；输出 token 含推理 token。"
    }

    /// 中性样本覆盖行：只报告各指标的有效样本数，不把旧历史中的失败尝试渲染成警告。
    private var coverageText: String {
        let s = summary
        guard s.attempts > 0 else { return "区间内暂无转发尝试" }
        return "有效样本：TTFT \(PerformanceFormat.samples(s.requestTTFTSamples)) · TPS \(PerformanceFormat.samples(s.tpsSamples))"
    }

    /// 分母解释：只统计成功流式请求，以及包含升级前无性能数据的全部尝试历史。
    private var coverageHelp: String {
        let s = summary
        guard s.attempts > 0 else { return "区间内没有转发尝试，因此没有可统计的性能样本。" }
        return "TTFT / TPS 只统计成功完成的流式请求：区间内共 \(s.attempts) 次转发尝试，其中 \(s.successfulStreamingAttempts) 次为成功流式、进入有效样本。升级前的历史未采集性能数据，可能计入尝试却没有有效样本。"
    }

    // MARK: - 比较表

    private var comparisonCard: some View {
        let rows = model.sortedPerformanceGroups
        return VStack(alignment: .leading, spacing: 0) {
            // 与用量明细同一层级：标题、分组 segmented 紧邻；排序不再占用控件，改为点击列头。
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

                Text("点击列头排序").font(.caption).foregroundStyle(.tertiary)
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
            ? "按路由分组：TTFT 与含 TTFT 的 TPS 为含自动回退的请求口径（从请求进入路由器到首个输出片段）。"
            : "按供应商 / 模型分组：TTFT 与含 TTFT 的 TPS 为单次上游尝试口径（不含自动回退等待）。"
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            headerCell(.ttftMean)
            headerCell(.tpsIncludingTTFT)
            headerCell(.tpsExcludingTTFT)
            Text("TTFT / TPS").frame(width: columnWidth, alignment: .trailing)
                .help("有效样本数：TTFT 样本 / TPS 样本（两者可能不同）")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    /// 列头即排序入口：点击按该列排序，再次点击反向；当前排序列右侧显示方向箭头。
    private func headerCell(_ key: PerformanceSortKey) -> some View {
        let isActive = model.isPerformanceSortActive(key)
        return Button {
            model.togglePerformanceSort(key)
        } label: {
            HStack(spacing: 4) {
                Text(key.columnTitle(for: model.performanceGrouping))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                sortArrow(for: key)
            }
            .frame(width: columnWidth, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(headerHelp(key))
        .accessibilityLabel("按\(key.columnTitle(for: model.performanceGrouping))排序")
        .accessibilityValue(isActive
                            ? (model.performanceSortAscending ? "已按升序排列" : "已按降序排列")
                            : "未排序")
    }

    /// 简洁排序箭头：只标当前排序列；隐藏时保留同宽占位，避免列表横向跳动。
    private func sortArrow(for key: PerformanceSortKey) -> some View {
        let isActive = model.isPerformanceSortActive(key)
        return Image(systemName: model.performanceSortAscending ? "arrow.up" : "arrow.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isActive ? Color.primary : Color.clear)
            .frame(width: 9)
            .accessibilityHidden(true)
    }

    /// 列口径 + 点击排序提示（当前方向 / 新列默认方向、未测置后）合成一个 tooltip。
    private func headerHelp(_ key: PerformanceSortKey) -> String {
        let sortHint: String
        if model.isPerformanceSortActive(key) {
            sortHint = model.performanceSortAscending
                ? "当前升序（小值在前），点击改为降序"
                : "当前降序（大值在前），点击改为升序"
        } else {
            sortHint = key.defaultAscending
                ? "点击排序，默认升序（小值在前）"
                : "点击排序，默认降序（大值在前）"
        }
        return "\(columnHelp(key))\n\(sortHint)；未测/未知恒定置后。"
    }

    /// 列口径进入表头 tooltip，替代原先独立的分组说明行。
    private func columnHelp(_ key: PerformanceSortKey) -> String {
        switch key {
        case .ttftMean:
            return isRouteGrouping
                ? "路由维度：含自动回退的请求总等待（从请求进入路由器到首个有效输出片段）的平均值。"
                : "供应商 / 模型维度：单次上游尝试首输出（不含自动回退等待）的平均值。"
        case .tpsIncludingTTFT:
            return isRouteGrouping
                ? "含 TTFT 的平均吞吐：请求口径下按（总等待 + 生成时长）总量加权，输出 token 含推理。"
                : "含 TTFT 的平均吞吐：按（上游首输出 + 生成时长）总量加权，输出 token 含推理。"
        case .tpsExcludingTTFT:
            return "不含 TTFT 的平均吞吐：输出 token 总量 ÷ 生成时长总量（不含 TTFT），按生成时长加权，输出 token 含推理。"
        }
    }

    private func groupRow(_ row: PerformanceGroupRow) -> some View {
        let s = row.summary
        let ttft = PerformanceFormat.milliseconds(isRouteGrouping ? s.requestTTFTMeanMS : s.ttftMeanMS)
        let tpsIncluding = PerformanceFormat.tps(isRouteGrouping ? s.requestTpsIncludingTTFT : s.tpsIncludingTTFT)
        let tpsExcluding = PerformanceFormat.tps(s.tpsExcludingTTFT)
        let sampleCount = ttftSampleCount(s)

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
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .help(row.subtitle.isEmpty ? row.title : "\(row.title)\n\(row.subtitle)")

            valueCell(ttft, help: "\(PerformanceSortKey.ttftMean.columnTitle(for: model.performanceGrouping))：\(sampleCount) 个 TTFT 样本")
            valueCell(tpsIncluding, help: "\(PerformanceSortKey.tpsIncludingTTFT.columnTitle(for: model.performanceGrouping))：\(s.tpsSamples) 个 TPS 样本")
            valueCell(tpsExcluding, help: "\(PerformanceSortKey.tpsExcludingTTFT.columnTitle(for: model.performanceGrouping))：\(s.tpsSamples) 个 TPS 样本")
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
                       detail: "把客户端指向本机地址并成功转发一次请求，或切换到其他时间区间查看历史性能；这里会统计流式请求的平均首输出延迟与平均吞吐。",
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
