import SwiftUI
import AppKit
import Charts

/// 用量统计页。数据全部来自本机 UsageStore；不做费用估算，标签统一是 Token 与缓存命中。
struct UsageView: View {
    let store: UsageStore

    @StateObject private var model: UsageViewModel

    /// 列宽规格：名称列权重最高、其余数值列按权重铺开；表头与数据行共用同一份规格，
    /// 因此逐列严格对齐，且列不会全挤在右侧。
    private let columnLayout = TableRowLayout(minWidths: [120, 72, 72, 72, 72],
                                              weights: [3, 1, 1, 1, 1],
                                              spacing: 12)

    /// `initialSection` 由侧栏入口决定：用量入口传 .usage，性能入口传 .performance。
    /// 在 init 里写入 ViewModel，配合调用方的稳定视图身份，不依赖 onAppear 重置。
    init(store: UsageStore, initialSection: UsageSection = .usage) {
        self.store = store
        _model = StateObject(wrappedValue: UsageViewModel(section: initialSection))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .alert("操作失败", isPresented: actionErrorBinding) {
                    Button("好", role: .cancel) { model.actionError = nil }
                } message: {
                    Text(model.actionError ?? "")
                }
        }
        .navigationTitle(model.section == .usage ? "用量" : "性能")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.refresh(store: store) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("立即刷新统计")

                Button {
                    Task { await model.exportCSV(store: store) }
                } label: {
                    Label("导出 CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(model.isEmpty || model.isExporting)
                .help("导出当前区间为 CSV")

                Button {
                    model.confirmClear = true
                } label: {
                    Label("清除历史", systemImage: "trash")
                }
                .disabled(model.isEmpty || model.isClearing)
                .help("清除本机用量历史（不可恢复）")
            }
        }
        .alert("清除用量历史？", isPresented: $model.confirmClear) {
            Button("取消", role: .cancel) {}
            Button("永久清除", role: .destructive) {
                Task { await model.clearHistory(store: store) }
            }
        } message: {
            Text("将永久删除全部本机用量记录，无法恢复。路由和供应商配置不受影响。")
        }
        .task(id: model.reloadKey) {
            await model.runRefreshLoop(store: store)
        }
    }

    // MARK: - 顶部区间控制

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(sectionTitle).font(.title2.bold())
                if let pending = model.shownPendingBucket {
                    selectionLoadingIndicator(pending)
                } else if let error = model.shownSelectionError {
                    selectionErrorIndicator(error)
                } else if let bucket = model.shownSelectedBucket {
                    selectionIndicator(bucket)
                }
                Spacer(minLength: 8)
                if model.isExporting || model.isClearing {
                    ProgressView().controlSize(.small)
                }
            }
            // 状态 chip 的出现/消失不改变标题行高度。
            .frame(minHeight: 28, alignment: .leading)

            // 单行只放区间选择器；自定义天数输入另起一行，避免在最小宽度下撑宽布局。
            Picker("时间区间", selection: $model.preset) {
                ForEach(UsageRangePreset.pagePresets) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("时间区间")

            if model.preset == .custom {
                HStack(spacing: 6) {
                    Text("近")
                    TextField("", text: customDaysBinding, onEditingChanged: { editing in
                        if !editing { model.commitCustomLastNDaysInput() }
                    })
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 52)
                    .multilineTextAlignment(.center)
                    .onSubmit { model.commitCustomLastNDaysInput() }
                    .accessibilityLabel("最近天数")
                    .help("输入正整数天数，回车或失焦生效")
                    Text("天")
                }
            }

            Text(rangeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var sectionTitle: String {
        model.section == .usage ? "用量统计" : "性能统计"
    }

    private var rangeSummary: String {
        let range = model.range
        return "\(UsageFormat.day(range.from)) – \(UsageFormat.day(range.inclusiveEnd))"
    }

    /// 已选柱的时段指示与清除入口。
    private func selectionIndicator(_ bucket: UsageChartSelection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
            Text("已选 \(bucket.label())")
            Button { model.clearShownSelection() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清除所选时段")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    /// 取数中的目标：点击立即有反馈，已展示数据保持到提交。
    private func selectionLoadingIndicator(_ bucket: UsageChartSelection) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("正在加载 \(bucket.label())…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    /// 加载失败：保留上一个 scope，仅就地提示，不改变布局。
    private func selectionErrorIndicator(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text("所选时段加载失败")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.1), in: Capsule())
        .help(message)
        .accessibilityElement(children: .combine)
    }

    /// 仅合法正整数即时生效；非法输入只改缓冲，提交时回退，避免瞬时错误范围。
    private var customDaysBinding: Binding<String> {
        Binding(
            get: { model.customLastNDaysInput },
            set: { newValue in
                model.customLastNDaysInput = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Int(trimmed), value >= 1 {
                    model.customLastNDays = min(value, model.maxCustomLastNDays)
                }
            }
        )
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )
    }

    // MARK: - 主体分派

    @ViewBuilder
    private var content: some View {
        if model.section == .performance {
            PerformanceView(model: model, store: store)
        } else {
            usageContent
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        switch model.phase {
        case .failed(let message):
            errorState(message)
        case .idle, .loading:
            if model.isInitialLoading {
                loadingState
            } else {
                loadedContent
            }
        case .loaded:
            loadedContent
        }
    }

    /// 单一滚动区：总览 + 完整图表 + 明细表头与行都在同一 ScrollView 内，
    /// 避免上下两个滚动区互相争高。明细行用 LazyVStack（无需选中/交互）。
    @ViewBuilder
    private var loadedContent: some View {
        if model.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.lastError {
                        warningBanner(error)
                    }
                    overviewCard
                    chartCard
                    detailsCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 总览

    /// 卡片与明细都跟随图表选择；取数期间保持上一个 scope 的结构与数据，
    /// 由标题旁的 chip 标明当前状态。
    private var overviewCard: some View {
        let totals = model.scopedTotals
        return HStack(spacing: 12) {
            metricTile(title: "输入", value: totals.input, reported: totals.inputAttempts,
                       attempts: totals.attempts, unit: "Tokens", helpNote: coverageSummary)
            metricTile(title: "输出", value: totals.output, reported: totals.outputAttempts,
                       attempts: totals.attempts, unit: "Tokens")
            metricTile(title: "缓存命中", value: totals.cachedInput, reported: totals.cachedInputAttempts,
                       attempts: totals.attempts, unit: "Tokens", helpNote: "输入的子集")
            cacheRateTile
        }
        .cardSurface()
    }

    /// 缓存命中率卡：上游没上报缓存/输入或输入为 0 时显示「—」，不用精确的 0% 冒充缺失。
    private var cacheRateTile: some View {
        StatTile(title: "缓存命中率",
                 value: UsageFormat.cacheRateText(model.cacheHitRate),
                 caption: model.cacheRateCaption,
                 help: model.cacheRateHelp)
    }

    private func metricTile(title: String, value: Int, reported: Int, attempts: Int, unit: String,
                            helpNote: String? = nil) -> some View {
        let missing = attempts > 0 && reported == 0
        let base = missing ? "\(title)：本区间未上报（—）"
                           : "\(title)：\(UsageFormat.exact(value)) \(unit)"
        return StatTile(title: title,
                        value: missing ? "—" : UsageFormat.compact(value),
                        caption: missing ? "未上报" : unit,
                        help: [base, helpNote].compactMap { $0 }.joined(separator: "\n"))
    }

    /// 上游尝试用量的覆盖情况；仅在存在尝试时有意义，作为输入指标卡的 tooltip 补充。
    private var coverageSummary: String? {
        let totals = model.scopedTotals
        guard totals.attempts > 0 else { return nil }
        let unknown = max(0, totals.attempts - totals.knownAttempts)
        var text = "已获取 \(totals.knownAttempts)/\(totals.attempts) 次上游尝试用量"
        if unknown > 0 {
            text += "（\(unknown) 次未知或部分）"
        }
        return text
    }

    // MARK: - 图表

    /// 图表粒度：今天按小时，其余区间按天。
    private var isHourlyChart: Bool { model.chartUnit == .hour }

    /// X 轴单位：今天用小时，其余用天。
    private var chartUnit: Calendar.Component { model.chartUnit }

    private var chartCard: some View {
        Chart(model.chartPoints) { point in
            BarMark(
                x: .value(isHourlyChart ? "时间" : "日期", point.date, unit: chartUnit),
                y: .value("输入", point.input)
            )
            .foregroundStyle(by: .value("类型", "输入"))
            .cornerRadius(3)
            .opacity(model.activeBucket == nil || model.activeBucket?.date == point.date ? 1 : 0.35)

            BarMark(
                x: .value(isHourlyChart ? "时间" : "日期", point.date, unit: chartUnit),
                y: .value("输出", point.output)
            )
            .foregroundStyle(by: .value("类型", "输出"))
            .cornerRadius(3)
            .opacity(model.activeBucket == nil || model.activeBucket?.date == point.date ? 1 : 0.35)
        }
        .chartForegroundStyleScale(["输入": Color.accentColor, "输出": Color.teal])
        .chartLegend(position: .top, alignment: .trailing)
        .statsChartAxes(isHourly: isHourlyChart,
                        dates: isHourlyChart ? model.chartHours : model.chartDates)
        // 固定 X 轴为当前区间，避免「近 7 天只有一天有数据」时被压成今日外观。
        .chartXScale(domain: model.range.from...model.range.to)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        let plot = geometry[proxy.plotAreaFrame]
                        guard plot.contains(location),
                              let date: Date = proxy.value(atX: location.x - plot.minX) else {
                            model.clearSelection()
                            return
                        }
                        model.toggleSelection(at: date, points: model.chartPoints, unit: chartUnit) { from, to, grouping in
                            try await store.snapshot(from: from, to: to, grouping: grouping)
                        }
                    }
            }
        }
        .statsChartCard(title: isHourlyChart ? "每小时 Token" : "每日 Token")
    }

    // MARK: - 明细

    private var detailsCard: some View {
        let groups = model.sortedUsageGroups
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("使用明细").font(.headline)
                Picker("分组", selection: $model.grouping) {
                    ForEach(UsageGrouping.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("按分组查看用量")

                Spacer(minLength: 8)
                Text("\(groups.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            tableHeader
            Divider()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { row in
                    groupRow(row)
                    if row.id != groups.last?.id {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .cardSurface()
    }

    private var tableHeader: some View {
        columnLayout {
            headerCell(.name)
            headerCell(.input)
            headerCell(.output)
            headerCell(.cached)
            headerCell(.cacheRate)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    /// 列头即排序入口：点击按该列排序，再次点击反向；当前排序列右侧显示方向箭头。
    /// 与性能表列头同款，箭头隐藏时保留同宽占位，避免列表横向跳动。
    private func headerCell(_ key: UsageSortKey) -> some View {
        let isActive = model.isUsageSortActive(key)
        return Button {
            model.toggleUsageSort(key)
        } label: {
            columnLabel(title: key.title, arrow: sortArrow(for: key), leading: key == .name)
        }
        .buttonStyle(.plain)
        .help(headerHelp(key))
        .accessibilityLabel("按\(key.title)列排序")
        .accessibilityValue(isActive
                            ? (model.usageSortAscending ? "已按升序排列" : "已按降序排列")
                            : "未排序")
    }

    /// 列头文字与箭头：名称列左对齐、箭头在文字后（文字左边缘不动）；
    /// 数值列右对齐、箭头在文字前——文字右边缘与下方数值严格齐平，
    /// 箭头显隐都不改变任何文字的位置。宽度由 `TableRowLayout` 统一分配。
    private func columnLabel(title: String, arrow: some View, leading: Bool) -> some View {
        let text = Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        return Group {
            if leading {
                HStack(spacing: 4) {
                    text
                    arrow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    arrow
                    text
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
    }

    /// 排序箭头只标当前排序列；未排序时方向值无意义，箭头保持透明的同宽占位。
    private func sortArrow(for key: UsageSortKey) -> some View {
        let isActive = model.isUsageSortActive(key)
        return Image(systemName: model.usageSortAscending ? "arrow.up" : "arrow.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isActive ? Color.primary : Color.clear)
            .frame(width: 9)
            .accessibilityHidden(true)
    }

    /// 列口径 + 点击排序提示合成一个 tooltip；「未上报/未知恒定置后」只对数值列有意义。
    private func headerHelp(_ key: UsageSortKey) -> String {
        let sortHint: String
        if model.isUsageSortActive(key) {
            sortHint = model.usageSortAscending
                ? "当前升序（小值在前），点击改为降序"
                : "当前降序（大值在前），点击改为升序"
        } else {
            sortHint = key.defaultAscending
                ? "点击排序，默认升序（小值在前）"
                : "点击排序，默认降序（大值在前）"
        }
        let base = "\(columnHelp(key))\n\(sortHint)"
        switch key {
        case .name:
            return "\(base)。"
        case .input, .output, .cached, .cacheRate:
            return "\(base)；未上报/未知恒定置后。"
        }
    }

    /// 各列统计口径；输入 / 缓存 / 缓存率的措辞与单元格 tooltip 保持一致。
    private func columnHelp(_ key: UsageSortKey) -> String {
        switch key {
        case .name:
            return "名称：当前分组（路由/供应商/模型）的显示名。"
        case .input:
            return "输入 token 总量（含缓存命中）。"
        case .output:
            return "输出 token 总量。"
        case .cached:
            return "缓存命中 token，是输入的子集。"
        case .cacheRate:
            return "缓存命中率 = 已上报缓存 ÷ 已上报输入；未上报或无输入时未知。"
        }
    }

    private func groupRow(_ row: UsageGroupRow) -> some View {
        let totals = row.totals
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
                if isPartial(totals) {
                    Text("部分尝试未上报")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .help(row.subtitle.isEmpty ? row.title : "\(row.title)\n\(row.subtitle)")

            numberCell(value: totals.input, reported: totals.inputAttempts, attempts: totals.attempts)
            numberCell(value: totals.output, reported: totals.outputAttempts, attempts: totals.attempts)
            numberCell(value: totals.cachedInput, reported: totals.cachedInputAttempts, attempts: totals.attempts)
            cacheRateCell(totals)
        }
        .padding(.vertical, 7)
    }

    private func isPartial(_ totals: UsageTotals) -> Bool {
        guard totals.attempts > 0 else { return false }
        return totals.inputAttempts < totals.attempts || totals.outputAttempts < totals.attempts
    }

    private func numberCell(value: Int, reported: Int, attempts: Int) -> some View {
        let missing = attempts > 0 && reported == 0
        return Text(missing ? "—" : UsageFormat.compact(value))
            .font(.system(.callout, design: .rounded))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(missing ? "未上报" : "精确值：\(UsageFormat.exact(value))")
    }

    private func cacheRateCell(_ totals: UsageTotals) -> some View {
        Text(UsageFormat.cacheRateText(UsageCacheRate.value(for: totals)))
            .font(.system(.callout, design: .rounded))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(cacheRateHelp(totals))
    }

    private func cacheRateHelp(_ totals: UsageTotals) -> String {
        if let reason = UsageCacheRate.unknownReason(for: totals) {
            return "\(reason)，缓存率未知"
        }
        var text = "缓存率 = 已上报缓存 \(UsageFormat.exact(totals.cachedInput)) ÷ 已上报输入 \(UsageFormat.exact(totals.input))"
        if UsageCacheRate.isPartial(for: totals) {
            text += "\n仅 \(totals.cachedInputAttempts)/\(totals.inputAttempts) 次上游尝试上报了缓存用量，比值只按已上报部分计算"
        }
        return text
    }

    // MARK: - 空 / 错误 / 加载

    private var emptyState: some View {
        VStack(spacing: 14) {
            EmptyState(title: "当前区间暂无记录",
                       detail: "把客户端指向本机地址并成功转发一次请求，或切换到其他时间区间查看历史用量；这里会按天汇总 Token 用量。",
                       symbol: "chart.bar.xaxis")
            Text("转发本身不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("统计不可用").font(.headline)
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
            Text("正在读取本机用量…")
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
