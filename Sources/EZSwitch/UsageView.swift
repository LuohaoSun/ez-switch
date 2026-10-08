import SwiftUI
import AppKit
import Charts

/// 用量统计页。数据全部来自本机 UsageStore；不做费用估算，标签统一是 Token 与请求次数。
struct UsageView: View {
    let store: UsageStore

    @StateObject private var model = UsageViewModel()

    private let columnWidth: CGFloat = 72

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
        .navigationTitle("用量")
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("用量统计").font(.title2.bold())
                    Text("仅统计本机转发的 Token 与请求数，不含费用估算，数据只保存在本机。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.isExporting || model.isClearing {
                    ProgressView().controlSize(.small)
                }
            }

            // 单行只放区间选择器；日期控件另起一行，避免在最小宽度下撑宽布局。
            Picker("时间区间", selection: $model.preset) {
                ForEach(UsageRangePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .accessibilityLabel("时间区间")

            if model.preset == .custom {
                HStack(spacing: 12) {
                    DatePicker("开始", selection: $model.customStart, displayedComponents: .date)
                        .fixedSize()
                        .help("起始日期（含当天）")
                    DatePicker("结束", selection: $model.customEnd, displayedComponents: .date)
                        .fixedSize()
                        .help("结束日期（含当天）")
                    Spacer(minLength: 0)
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

    private var rangeSummary: String {
        let range = model.range
        return "\(UsageFormat.day(range.from)) – \(UsageFormat.day(range.inclusiveEnd))（含结束日）"
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

    private var overviewCard: some View {
        let totals = model.snapshot.totals
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                metricTile(title: "输入", value: totals.input, reported: totals.inputAttempts,
                           attempts: totals.attempts, unit: "Tokens")
                metricTile(title: "输出", value: totals.output, reported: totals.outputAttempts,
                           attempts: totals.attempts, unit: "Tokens")
                metricTile(title: "缓存命中", value: totals.cachedInput, reported: totals.cachedInputAttempts,
                           attempts: totals.attempts, unit: "Tokens")
                metricTile(title: "请求数", value: totals.requests, reported: totals.requests,
                           attempts: 0, unit: "次")
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(coverageText, systemImage: coverageIcon)
                    .font(.caption)
                    .foregroundStyle(coverageColor)
                Spacer(minLength: 8)
                Text("缓存命中是输入的子集；推理量是输出的子集。— = 未上报")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .cardSurface()
    }

    private func metricTile(title: String, value: Int, reported: Int, attempts: Int, unit: String) -> some View {
        let missing = attempts > 0 && reported == 0
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(missing ? "—" : UsageFormat.compact(value))
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(missing ? "未上报" : unit).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .help(missing ? "\(title)：本区间未上报" : "\(title)：\(UsageFormat.exact(value)) \(unit)")
        .accessibilityElement(children: .combine)
    }

    private var coverageText: String {
        let totals = model.snapshot.totals
        guard totals.attempts > 0 else { return "暂无上游尝试记录" }
        let unknown = max(0, totals.attempts - totals.knownAttempts)
        var text = "已获取 \(totals.knownAttempts)/\(totals.attempts) 次上游尝试用量"
        if unknown > 0 {
            text += "（\(unknown) 次未知或部分）"
        }
        return text
    }

    private var coverageIcon: String {
        let totals = model.snapshot.totals
        if totals.attempts > 0, totals.knownAttempts < totals.attempts {
            return "exclamationmark.circle"
        }
        return "checkmark.circle"
    }

    private var coverageColor: Color {
        let totals = model.snapshot.totals
        if totals.attempts > 0, totals.knownAttempts < totals.attempts {
            return .orange
        }
        return .secondary
    }

    // MARK: - 图表

    private var chartDates: [Date] {
        let calendar = Calendar.current
        let range = model.range
        let days = max(1, calendar.dateComponents([.day], from: range.from, to: range.to).day ?? 1)
        let step = max(1, Int(ceil(Double(days) / 7)))
        return stride(from: 0, to: days, by: step).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: range.from) else { return nil }
            return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("每日 Token").font(.headline)
                Spacer(minLength: 8)
                Text("输入 / 输出堆叠，单位 Token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(model.snapshot.days) { day in
                BarMark(
                    x: .value("日期", day.date, unit: .day),
                    y: .value("输入", day.input)
                )
                .foregroundStyle(by: .value("类型", "输入"))
                .cornerRadius(3)

                BarMark(
                    x: .value("日期", day.date, unit: .day),
                    y: .value("输出", day.output)
                )
                .foregroundStyle(by: .value("类型", "输出"))
                .cornerRadius(3)
            }
            .chartForegroundStyleScale(["输入": Color.accentColor, "输出": Color.teal])
            .chartLegend(position: .top, alignment: .trailing)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Int.self) {
                            Text(UsageFormat.compact(number))
                        } else if let number = value.as(Double.self) {
                            Text(UsageFormat.compact(Int(number)))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: chartDates) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(UsageFormat.axisDay(date))
                        }
                    }
                }
            }
            // 固定 X 轴为当前区间，避免"近 7 天只有一天有数据"时被压成今日外观。
            .chartXScale(domain: model.range.from...model.range.to)
            .frame(height: 180)
        }
        .cardSurface()
    }

    // MARK: - 明细

    private var detailsCard: some View {
        let groups = model.snapshot.groups
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
        HStack(spacing: 12) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("输入").frame(width: columnWidth, alignment: .trailing)
            Text("输出").frame(width: columnWidth, alignment: .trailing)
            Text("缓存").frame(width: columnWidth, alignment: .trailing)
            Text("请求").frame(width: columnWidth, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    private func groupRow(_ row: UsageGroupRow) -> some View {
        let totals = row.totals
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
            numberCell(value: totals.requests, reported: totals.requests, attempts: 0)
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
            .frame(width: columnWidth, alignment: .trailing)
            .help(missing ? "未上报" : "精确值：\(UsageFormat.exact(value))")
    }

    // MARK: - 空 / 错误 / 加载

    private var emptyState: some View {
        VStack(spacing: 14) {
            EmptyState(title: "当前区间暂无记录",
                       detail: "把客户端指向本机地址并成功转发一次请求，或切换到其他时间区间查看历史用量；这里会按天汇总 Token 与请求数。",
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

// MARK: - 卡片外观

private extension View {
    /// 轻量卡片：低对比背景、细描边、统一内边距，右边缘留白。
    func cardSurface() -> some View {
        self
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            .padding(.trailing, 2)
    }
}
