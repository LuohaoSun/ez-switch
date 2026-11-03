import SwiftUI
import Charts

/// 性能统计视图，嵌在「用量」页内，与用量共用时间区间筛选。
///
/// 顶部五张指标卡（请求数、尝试失败率、平均 TTFT、平均 TPS 含 / 不含 TTFT，各带独立样本数），
/// 其下是请求数柱状图（今天按小时、其余区间按天）；点击柱子会把指标卡与性能明细收敛到该时段，
/// 图表本身保留整个区间，再次点击同一根柱或点清除按钮回到整段。
/// 再往下是可切换分组（路由 / 供应商 / 模型）的比较表；
/// 全部六列（名称、失败率、三个指标、请求）都可排序，排序不占控件，直接点击列头：
/// 点击某列按其默认方向排序，再次点击同一列反向，当前排序列显示方向箭头。
/// 路由维度的 TTFT / 含 TTFT 的 TPS 是含自动回退的请求口径；供应商 / 模型维度是单次上游尝试口径。
/// 失败率始终是上游尝试口径：失败尝试 / 全部尝试，取消也计入。
/// 不含 TTFT 的 TPS 只算生成时长，两维度共用，仅作对照。
/// 顶部总览固定为请求口径（与旧的 overall requestTTFT 一致）。
struct PerformanceView: View {
    @ObservedObject var model: UsageViewModel
    let store: UsageStore

    /// 列宽规格：与用量明细共用同一套权重和间距，性能表多一列失败率；
    /// 名称列 3 份、五个数值列各 1 份，表头与数据行逐列严格对齐。
    private let columnLayout = TableRowLayout.performanceDetail

    var body: some View {
        content
    }

    /// 指标卡与性能明细跟随选中的柱；未选中时是整个区间。
    private var summary: PerformanceSummary { model.scopedPerformanceSummary }

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
        } else {
            // 有转发记录就始终展示请求数与图表；无性能样本时仅以提示条说明 TTFT / TPS 为「—」。
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.performanceLastError {
                        warningBanner(error)
                    }
                    if model.performanceHasNoSamples {
                        noSamplesBanner
                    }
                    metricsCard
                    requestChartCard
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

    /// 请求数是主指标（品牌色放大），其余四项为次指标。
    /// 宽窗口五列同排；最小窗口回落成「主指标一行 + 2×2」，
    /// 标题与数值不靠压缩字号硬塞。
    private var metricsCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                requestCountTile.frame(minWidth: 150)
                failureRateTile.frame(minWidth: 150)
                ttftTile.frame(minWidth: 150)
                tpsIncludingTile.frame(minWidth: 150)
                tpsExcludingTile.frame(minWidth: 150)
            }
            VStack(spacing: 10) {
                requestCountTile
                HStack(spacing: 10) {
                    failureRateTile
                    ttftTile
                }
                HStack(spacing: 10) {
                    tpsIncludingTile
                    tpsExcludingTile
                }
            }
        }
        .cardSurface()
    }

    private var requestCountTile: some View {
        StatTile(title: "请求数",
                 value: UsageFormat.compact(summary.requests),
                 caption: "次 · 尝试 \(PerformanceFormat.samples(summary.attempts))",
                 help: requestCountHelp,
                 primary: true)
    }

    private var failureRateTile: some View {
        StatTile(title: "尝试失败率",
                 value: PerformanceFormat.failureRate(summary.failureRate),
                 caption: "失败 \(UsageFormat.compact(summary.failedAttempts)) / \(UsageFormat.compact(summary.attempts)) 次",
                 help: attemptFailureHelp)
    }

    private var ttftTile: some View {
        metricTile(title: "平均TTFT",
                   value: PerformanceFormat.milliseconds(summaryTTFTValue),
                   unit: "总等待",
                   samples: summary.requestTTFTSamples,
                   help: "\(ttftMeanHelp(requestScope: true))\n\(coverageHelp)")
    }

    private var tpsIncludingTile: some View {
        metricTile(title: "平均TPS(含TTFT)",
                   value: PerformanceFormat.tps(summaryTPSIncludingValue),
                   unit: "Tokens/秒",
                   samples: summary.tpsSamples,
                   help: "\(tpsMeanHelp(includingTTFT: true))\n\(coverageHelp)")
    }

    private var tpsExcludingTile: some View {
        metricTile(title: "平均TPS(不含TTFT)",
                   value: PerformanceFormat.tps(summaryTPSExcludingValue),
                   unit: "Tokens/秒",
                   samples: summary.tpsSamples,
                   help: "\(tpsMeanHelp(includingTTFT: false))\n\(coverageHelp)")
    }

    /// 请求数口径：去重计数与尝试数并列给出，说明自动回退只计一次。
    private var requestCountHelp: String {
        "请求数：按 request_id 去重，同一请求的多次自动回退尝试只计一次。\n" +
        "区间内共 \(summary.attempts) 次转发尝试（含失败 / 取消 / 非流式，均计入请求数）。"
    }

    /// 尝试失败率口径：分母是尝试数，不是请求数；取消也计入失败。
    private var attemptFailureHelp: String {
        guard summary.attempts > 0 else {
            return "区间内没有上游尝试，因此失败率未知。"
        }
        return "尝试失败率 = 失败尝试 ÷ 全部上游尝试。\n" +
        "失败 = outcome 不是 success，取消也计入（本区间取消 \(UsageFormat.exact(summary.cancelledAttempts)) 次）。\n" +
        "自动回退的每次尝试各自计入；路由前失败的请求没有写入 usage.sqlite，因此不计入。"
    }

    private func metricTile(title: String, value: String, unit: String,
                            samples: Int, help: String) -> some View {
        StatTile(title: title,
                 value: value,
                 caption: samples > 0 ? "\(unit) · 样本 \(PerformanceFormat.samples(samples))" : "暂无样本",
                 help: help)
    }

    private func ttftMeanHelp(requestScope: Bool) -> String {
        requestScope
            ? "平均首输出延迟：含自动回退的请求总等待（从请求进入路由器到首个有效输出片段）的平均值，按样本逐条平均。"
            : "平均首输出延迟：单次上游尝试首输出（不含自动回退等待）的平均值。"
    }

    /// 含 TTFT 的吞吐分母覆盖整个响应期，攒批一次性下发也不失真；
    /// 不含 TTFT 的版本只算生成时长，作为服务端"纯生成速度"的对照，攒批下发时会偏高。
    private func tpsMeanHelp(includingTTFT: Bool) -> String {
        includingTTFT
            ? "平均输出吞吐（含 TTFT，请求口径）：同一批有效样本的上游输出 token 总量 ÷（请求总等待 + 生成时长）总量，按总时长加权，不是逐请求速率的平均；输出 token 含推理 token。"
            : "平均输出吞吐（不含 TTFT）：同一批有效样本的上游输出 token 总量 ÷ 生成时长总量（首分片到响应结束，不含首字等待），按生成时长加权，不是逐请求速率的平均；输出 token 含推理 token。攒批一次性下发的上游会低估生成时长、让该值偏高，请与含 TTFT 的版本对照着看。"
    }

    /// 分母解释：只统计成功流式请求，以及包含升级前无性能数据的全部尝试历史。
    private var coverageHelp: String {
        let s = summary
        guard s.attempts > 0 else { return "区间内没有转发尝试，因此没有可统计的性能样本。" }
        return "TTFT / TPS 只统计成功完成的流式请求：区间内共 \(s.attempts) 次转发尝试，其中 \(s.successfulStreamingAttempts) 次为成功流式、进入有效样本；缺少计时字段的尝试仍可能没有样本。升级前的历史未采集性能数据，也可能计入尝试却没有有效样本。"
    }

    // MARK: - 请求数图表

    /// 图表粒度与用量页一致：今天按小时，其余区间按天。
    private var isHourlyChart: Bool { model.chartUnit == .hour }

    /// 请求数柱状图：展示整个区间的去重请求数序列；点击柱子收敛指标卡与明细，图表本身不裁剪。
    private var requestChartCard: some View {
        Chart(model.chartPoints) { point in
            BarMark(
                x: .value(isHourlyChart ? "时间" : "日期", point.date, unit: model.chartUnit),
                y: .value("请求数", point.requests)
            )
            .foregroundStyle(AppDesign.chartInput)
            .cornerRadius(4)
            .opacity(model.performanceActiveBucket == nil
                     || model.performanceActiveBucket?.date == point.date ? 1 : 0.35)
        }
        // 固定 X 轴为当前区间，与用量图表一致，避免只有零星柱时被压缩。
        .chartXScale(domain: model.range.from...model.range.to)
        .statsChartAxes(isHourly: isHourlyChart,
                        dates: isHourlyChart ? model.chartHours : model.chartDates)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        let plot = geometry[proxy.plotAreaFrame]
                        guard plot.contains(location),
                              let date: Date = proxy.value(atX: location.x - plot.minX) else {
                            model.clearPerformanceSelection()
                            return
                        }
                        model.togglePerformanceSelection(
                            at: date, points: model.chartPoints, unit: model.chartUnit
                        ) { from, to, grouping in
                            try await store.performanceSnapshot(from: from, to: to, grouping: grouping)
                        }
                    }
            }
        }
        .statsChartCard(title: isHourlyChart ? "每小时请求数" : "每日请求数")
    }

    // MARK: - 比较表

    private var comparisonCard: some View {
        let rows = model.sortedPerformanceGroups
        return VStack(alignment: .leading, spacing: 0) {
            // 与用量明细同一层级：标题、分组 segmented 紧邻；排序不再占用控件，改为点击列头。
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("性能明细")
                        .font(.headline)
                        .help("数值悬停可查看该分组的有效样本数；顶部卡片显示所选范围的总样本数。")
                    CountBadge(count: rows.count)
                }

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
            }
            .padding(.bottom, 10)

            tableHeader
            Divider()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HoverableTableRow {
                        groupRow(row)
                    }
                    if row.id != rows.last?.id {
                        Divider().opacity(0.65)
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
        columnLayout {
            headerCell(.name)
            headerCell(.failureRate)
            headerCell(.ttftMean)
            headerCell(.tpsIncludingTTFT)
            headerCell(.tpsExcludingTTFT)
            headerCell(.requests)
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
            SortHeaderLabel(title: key.columnTitle(for: model.performanceGrouping),
                            leading: key == .name,
                            isActive: isActive,
                            ascending: model.performanceSortAscending)
        }
        .buttonStyle(.plain)
        .help(headerHelp(key))
        .accessibilityLabel("按\(key.columnTitle(for: model.performanceGrouping))排序")
        .accessibilityValue(isActive
                            ? (model.performanceSortAscending ? "已按升序排列" : "已按降序排列")
                            : "未排序")
    }

    /// 列口径 + 点击排序提示（当前方向 / 新列默认方向）合成一个 tooltip。
    /// 「未测/未知恒定置后」只对指标列与失败率列有意义：名称总有值，请求数恒为已知值。
    private func headerHelp(_ key: PerformanceSortKey) -> String {
        let sortHint: String
        if model.isPerformanceSortActive(key) {
            sortHint = model.performanceSortAscending
                ? "当前升序（小值在前），点击改为降序"
                : "当前降序（大值在前），点击改为升序"
        } else if key == .failureRate {
            sortHint = "点击排序，默认降序（失败率高的在前）"
        } else {
            sortHint = key.defaultAscending
                ? "点击排序，默认升序（小值在前）"
                : "点击排序，默认降序（大值在前）"
        }
        let base = "\(columnHelp(key))\n\(sortHint)"
        switch key {
        case .failureRate, .ttftMean, .tpsIncludingTTFT, .tpsExcludingTTFT:
            return "\(base)；未测/未知恒定置后。"
        case .name, .requests:
            return "\(base)。"
        }
    }

    /// 列口径进入表头 tooltip，替代原先独立的分组说明行。
    private func columnHelp(_ key: PerformanceSortKey) -> String {
        switch key {
        case .name:
            return "名称：当前分组（路由/供应商/模型）的显示名。"
        case .failureRate:
            return "失败率：失败尝试 ÷ 全部上游尝试；失败 = outcome 不是 success，取消也计入。自动回退的每次尝试各自计入，分母不是请求数；路由前失败未入库，不计入。"
        case .requests:
            return "请求数：按 request_id 去重；同一请求的自动回退尝试只计一次。"
        case .ttftMean:
            return isRouteGrouping
                ? "路由维度：含自动回退的请求总等待（从请求进入路由器到首个有效输出片段）的平均值。"
                : "供应商 / 模型维度：单次上游尝试首输出（不含自动回退等待）的平均值。"
        case .tpsIncludingTTFT:
            return isRouteGrouping
                ? "含 TTFT 的平均吞吐：请求口径下按（总等待 + 生成时长）总量加权，输出 token 含推理。"
                : "含 TTFT 的平均吞吐：按（上游首输出 + 生成时长）总量加权，输出 token 含推理。"
        case .tpsExcludingTTFT:
            return "不含 TTFT 的平均吞吐：按生成时长（首分片到响应结束）总量加权，不含首字等待；两维度共用同一口径，攒批下发会让它偏高，请与含 TTFT 的版本对照。"
        }
    }

    private func groupRow(_ row: PerformanceGroupRow) -> some View {
        let s = row.summary
        let ttft = PerformanceFormat.milliseconds(isRouteGrouping ? s.requestTTFTMeanMS : s.ttftMeanMS)
        let tpsIncluding = PerformanceFormat.tps(isRouteGrouping ? s.requestTpsIncludingTTFT : s.tpsIncludingTTFT)
        let tpsExcluding = PerformanceFormat.tps(s.tpsExcludingTTFT)
        let sampleCount = ttftSampleCount(s)

        return columnLayout {
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

            failureRateCell(s)
            valueCell(ttft, help: "\(PerformanceSortKey.ttftMean.columnTitle(for: model.performanceGrouping))：\(sampleCount) 个 TTFT 样本")
            valueCell(tpsIncluding, help: "\(PerformanceSortKey.tpsIncludingTTFT.columnTitle(for: model.performanceGrouping))：\(s.tpsSamples) 个 TPS 样本")
            valueCell(tpsExcluding, help: "\(PerformanceSortKey.tpsExcludingTTFT.columnTitle(for: model.performanceGrouping))：\(s.tpsSamples) 个 TPS 样本")
            requestsCell(s)
        }
        .padding(.vertical, 7)
    }

    private func valueCell(_ text: String, help: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .rounded))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(text == "—" ? "未测或样本不足\n\(help)" : help)
    }

    /// 尝试失败率：分母是该分组的上游尝试数，不是请求数；取消也计入失败。
    private func failureRateCell(_ s: PerformanceSummary) -> some View {
        let help = s.attempts > 0
            ? "失败 \(UsageFormat.exact(s.failedAttempts)) / \(UsageFormat.exact(s.attempts)) 次尝试，其中取消 \(UsageFormat.exact(s.cancelledAttempts)) 次。\n失败 = outcome 不是 success；自动回退的每次尝试各自计入。"
            : "该分组没有上游尝试，失败率未知。"
        return Text(PerformanceFormat.failureRate(s.failureRate))
            .font(.system(.callout, design: .rounded))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(help)
    }

    private func requestsCell(_ s: PerformanceSummary) -> some View {
        Text(UsageFormat.compact(s.requests))
            .font(.system(.callout, design: .rounded))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help("请求数：\(UsageFormat.exact(s.requests))（按 request_id 去重）\n转发尝试：\(UsageFormat.exact(s.attempts)) 次")
    }

    // MARK: - 空 / 错误 / 加载

    private var noHistoryState: some View {
        VStack(spacing: 0) {
            AppPageState(title: "当前区间暂无记录",
                         detail: "把客户端指向本机地址并成功转发一次请求，或切换到其他时间区间查看历史性能；这里会统计请求数与流式请求的平均首输出延迟、平均吞吐。转发本身不受影响。",
                         symbol: "speedometer")
            Spacer(minLength: 0)
        }
    }

    /// 有转发记录但无 TTFT / TPS 样本：请求数与图表照常展示，仅提示延迟 / 吞吐不可用。
    private var noSamplesBanner: some View {
        StatusBanner(tone: .info,
                     systemImage: "info.circle",
                     message: noSamplesBannerText)
    }

    /// 选中柱时点名所选时段，避免把「这一小时没样本」误读成「整个区间没样本」。
    private var noSamplesBannerText: String {
        let scope = model.performanceSelectedBucket.map { "所选时段（\($0.label())）" } ?? "当前区间"
        return "\(scope)有转发记录，但暂无 TTFT / TPS 样本：仅成功完成的流式请求参与性能统计；请求数仍统计全部转发尝试。"
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            AppPageState(title: "性能统计不可用",
                         detail: "\(message)\n请求转发不受影响；统计恢复后会继续记录。",
                         symbol: "exclamationmark.triangle")
            Button {
                Task { await model.refresh(store: store) }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        StatusBanner(tone: .warning,
                     systemImage: "exclamationmark.triangle.fill",
                     message: "刷新失败：\(message)（显示上次成功的数据；转发不受影响。）")
    }
}
