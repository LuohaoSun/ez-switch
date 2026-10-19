import Foundation
import Testing
import SwiftUI
@testable import EZSwitch

/// 活动页 UI 模型：状态文案 / 色调、token 不伪造、回退链与用量覆盖、
/// palette 颜色稳定性、图 → 表高亮（不改动列表）、有界展示、搜索与排序。
///
/// 数据经 `ingest(rows:...)` 注入，不依赖后端 `ActivityStore`，因此可离线覆盖边界。
@MainActor
@Suite("Activity view model")
struct ActivityViewModelTests {

    // MARK: - 夹具

    private func attempt(_ n: Int,
                         provider: String = "OpenAI",
                         model: String = "gpt-5",
                         status: Int? = 200,
                         outcome: ActivityAttemptResult = .success,
                         durationMS: Int? = 800,
                         tokens: UsageTokens = UsageTokens(),
                         ttftMS: Double? = nil,
                         reason: String? = nil) -> ActivityAttemptModel {
        ActivityAttemptModel(attempt: n, provider: provider, model: model,
                             label: "\(provider) · \(model)", statusCode: status,
                             outcome: outcome, durationMS: durationMS,
                             tokens: tokens, ttftMS: ttftMS, reason: reason)
    }

    private func row(id: UUID = UUID(),
                     shortID: String = "ABCD",
                     startedAt: Date = Date(),
                     endedAt: Date? = nil,
                     protocolKind: ActivityProtocolKind = .chat,
                     routeName: String = "main",
                     phase: ActivityPhase = .succeeded,
                     upstream: (String, String)? = ("OpenAI", "gpt-5"),
                     selectedAttempt: Int? = nil,
                     attempts: [ActivityAttemptModel] = [],
                     didFallback: Bool = false,
                     tokens: UsageTokens = UsageTokens(),
                     performance: UsagePerformance? = nil,
                     failureReason: String? = nil,
                     elapsedMS: Int = 1000) -> ActivityRowModel {
        ActivityRowModel(id: id, shortID: shortID, startedAt: startedAt, endedAt: endedAt,
                         protocolKind: protocolKind, routeName: routeName, phase: phase,
                         upstreamProvider: upstream?.0, upstreamModel: upstream?.1,
                         selectedAttempt: selectedAttempt, attempts: attempts,
                         didFallback: didFallback, tokens: tokens, performance: performance,
                         failureReason: failureReason, elapsedMS: elapsedMS)
    }

    /// 后端 `ActivityRequest` 夹具：用于覆盖 `apply(_:)` 快照接入缝（含 `generatedAt` 计时）。
    private func request(id: UUID,
                         status: ActivityStatus,
                         startedAt: Date,
                         endedAt: Date?) -> ActivityRequest {
        ActivityRequest(id: id, route: "main", routeName: "main", endpoint: "chat", method: "POST",
                        startedAt: startedAt, endedAt: endedAt, status: status, elapsedMS: 1_200,
                        outcome: nil, statusCode: 200, failureReason: nil, firstResponseAt: nil,
                        selectedAttempt: nil, attempts: [], fallbacks: [],
                        tokens: UsageTokens(), performance: nil)
    }

    // MARK: - 状态文案与色调

    @Test("状态文案与色调")
    func statusTextAndTone() {
        #expect(row(phase: .inFlight).statusText == "等待响应")
        #expect(row(phase: .inFlight).tone == .neutral)

        #expect(row(phase: .receiving).statusText == "接收响应")
        #expect(row(phase: .receiving).tone == .active)

        #expect(row(phase: .succeeded).statusText == "✓ 已完成")
        #expect(row(phase: .succeeded).tone == .ok)

        #expect(row(phase: .succeeded, didFallback: true).statusText == "✓ 回退成功")
        #expect(row(phase: .succeeded, didFallback: true).tone == .warn)

        #expect(row(phase: .failed).statusText == "! 失败")
        #expect(row(phase: .failed).tone == .fail)

        #expect(row(phase: .cancelled).statusText == "已取消")
        #expect(row(phase: .cancelled).tone == .neutral)
    }

    @Test("receiving 视为进行中，终态不再活跃")
    func isActiveReflectsPhase() {
        #expect(row(phase: .inFlight).isActive)
        #expect(row(phase: .receiving).isActive)
        #expect(!row(phase: .succeeded).isActive)
        #expect(!row(phase: .failed).isActive)
        #expect(!row(phase: .cancelled).isActive)
    }

    // MARK: - 流向图请求节点：状态 + 耗时

    @Test("图上状态只陈述快照证据：回退加「回退后」前缀，不声称正在切换")
    func graphStatusTextFollowsSnapshotEvidence() {
        #expect(row(phase: .inFlight).graphStatusText == "等待响应")
        #expect(row(phase: .receiving).graphStatusText == "接收响应")
        #expect(row(phase: .inFlight, didFallback: true).graphStatusText == "回退后等待")
        #expect(row(phase: .receiving, didFallback: true).graphStatusText == "回退后接收")
        // 快照没有「切换中」这一阶段，任何文案都不应出现「切换」。
        for phase in [ActivityPhase.inFlight, .receiving] {
            #expect(!row(phase: phase, didFallback: true).graphStatusText.contains("切换"))
        }
    }

    @Test("图节点第二行 = #短ID · 状态 · 耗时，耗时沿用 elapsedMS")
    func graphNodeSubtitleUsesSnapshotDuration() {
        #expect(row(shortID: "AB12", phase: .receiving, elapsedMS: 2_400)
            .graphNodeSubtitle == "#AB12 · 接收响应 · 2.4 s")
        #expect(row(shortID: "CD34", phase: .inFlight, didFallback: true, elapsedMS: 12_000)
            .graphNodeSubtitle == "#CD34 · 回退后等待 · 12.0 s")
        // 超过 1 分钟沿用现有 m:ss 格式。
        #expect(row(shortID: "EF56", phase: .inFlight, elapsedMS: 65_000)
            .graphNodeSubtitle == "#EF56 · 等待响应 · 1:05")
    }

    // MARK: - token 不伪造

    @Test("未报告 token 显示 —，已报告用千分位")
    func tokenCellNeverFabricates() {
        #expect(ActivityFormat.tokenCell(nil) == "—")
        #expect(ActivityFormat.tokens(nil) == "—")
        #expect(ActivityFormat.tokenCell(620) == "620")
        #expect(ActivityFormat.tokenCell(12_480) == "12,480")
        #expect(ActivityFormat.seconds(nil) == "—")
        #expect(ActivityFormat.seconds(nil as Double?) == "—")
    }

    @Test("超长 token 退化为 compact，不撑破窄列")
    func tokenCellCompactsLargeValues() {
        #expect(ActivityFormat.tokenCell(1_234_567) == "1.2M")
    }

    // MARK: - 状态短语（outcome 优先）

    @Test("outcome 优先于状态码：2xx + 传输中断不显示成功")
    func statusPhrasePrefersOutcome() {
        #expect(ActivityStatusPhrase.phrase(statusCode: 200, outcome: .streamError) == "传输中断")
        #expect(ActivityStatusPhrase.phrase(statusCode: 200, outcome: .cancelled) == "已取消")
        #expect(ActivityStatusPhrase.phrase(statusCode: 200, outcome: .success) == "成功")
        #expect(ActivityStatusPhrase.phrase(statusCode: nil, outcome: .networkError) == "连接失败")
        #expect(ActivityStatusPhrase.phrase(statusCode: 429, outcome: .httpError) == "限流")
        #expect(ActivityStatusPhrase.phrase(statusCode: 503, outcome: .httpError) == "服务不可用")
    }

    // MARK: - 回退链与用量覆盖

    @Test("回退链按尝试顺序拼接")
    func fallbackChain() {
        let model = row(phase: .succeeded, selectedAttempt: 2, attempts: [
            attempt(1, provider: "OpenAI", status: 429, outcome: .httpError, durationMS: 800),
            attempt(2, provider: "DeepSeek", durationMS: 8400),
        ], didFallback: true)
        #expect(model.attemptChainText == "OpenAI 限流（429，0.8 s） → DeepSeek 成功（200，8.4 s）")
    }

    @Test("单次尝试没有回退链")
    func singleAttemptHasNoChain() {
        let model = row(attempts: [attempt(1)])
        #expect(model.attemptChainText == nil)
    }

    @Test("用量覆盖说明指明 token 来自哪次尝试")
    func coverageNoteFromSelectedAttempt() {
        let model = row(phase: .succeeded, selectedAttempt: 2, attempts: [
            attempt(1, status: 429, outcome: .httpError, durationMS: 800),
            attempt(2, provider: "DeepSeek", durationMS: 8400,
                    tokens: UsageTokens(input: 8_920, output: 936)),
        ], didFallback: true, tokens: UsageTokens(input: 8_920, output: 936))
        #expect(model.coverageNote == "第 1 次尝试未报告用量；表中 token 来自第 2 次尝试。")
    }

    @Test("失败请求不伪造 token，并提示未报告")
    func failedRequestDoesNotFakeTokens() {
        let model = row(phase: .failed, upstream: ("Anthropic", "claude-sonnet-4"),
                        attempts: [attempt(1, provider: "Anthropic", status: nil,
                                           outcome: .networkError, durationMS: 200)],
                        failureReason: "connect: connection refused")
        #expect(model.tokens.input == nil)
        #expect(model.tokens.output == nil)
        let lines = model.detailLines.joined(separator: "\n")
        #expect(lines.contains("connect: connection refused"))
        #expect(lines.contains("未收到上游用量报告。"))
    }

    @Test("TTFT 只用 performance 度量，不用首字节时刻")
    func ttftComesFromPerformanceOnly() {
        let withTTFT = row(phase: .receiving,
                           performance: UsagePerformance(streaming: true, ttftMS: 700))
        #expect(withTTFT.detailLines.joined(separator: "\n").contains("首字 0.7 s"))

        let without = row(phase: .receiving, performance: nil)
        #expect(!without.detailLines.joined(separator: "\n").contains("首字"))
    }

    // MARK: - palette 颜色稳定性

    @Test("同一请求跨刷新同色，不同请求在容量内异色，且与数组下标无关")
    func colorsAreStableAndDistinct() {
        let model = ActivityViewModel()
        let a = UUID(), b = UUID()

        model.ingest(rows: [row(id: a, shortID: "A", phase: .receiving),
                            row(id: b, shortID: "B", phase: .receiving)], activeCount: 2)
        let colorA = model.color(for: a)
        let colorB = model.color(for: b)
        #expect(colorA != colorB)

        // 顺序颠倒后颜色不变（不按 index 取色）。
        model.ingest(rows: [row(id: b, shortID: "B", phase: .receiving),
                            row(id: a, shortID: "A", phase: .receiving)], activeCount: 2)
        #expect(model.color(for: a) == colorA)
        #expect(model.color(for: b) == colorB)

        // a 结束后 b 保持颜色，新请求拿到不同颜色。
        let c = UUID()
        model.ingest(rows: [row(id: b, shortID: "B", phase: .receiving),
                            row(id: c, shortID: "C", phase: .receiving)], activeCount: 2)
        #expect(model.color(for: b) == colorB)
        #expect(model.color(for: c) != colorB)
    }

    // MARK: - 图 → 表高亮（只高亮，不过滤）

    @Test("选中请求只高亮，不改变列表数量，可取消")
    func requestSelectionHighlightsWithoutFilteringList() {
        let model = ActivityViewModel()
        let first = row(shortID: "AAAA", upstream: ("OpenAI", "gpt-5"))
        let second = row(shortID: "BBBB", upstream: ("DeepSeek", "deepseek-chat"))
        model.ingest(rows: [first, second], activeCount: 0)
        #expect(model.visibleRows.count == 2)

        model.toggle(request: first.id)
        #expect(model.visibleRows.count == 2)
        #expect(Set(model.visibleRows.map(\.id)) == [first.id, second.id])
        #expect(model.highlightLabel == "· 已高亮 请求 #AAAA")
        #expect(model.isRowHighlighted(first))
        #expect(!model.isRowHighlighted(second))

        model.clearSelection()
        #expect(model.visibleRows.count == 2)
        #expect(model.highlightLabel == nil)
        #expect(!model.isRowHighlighted(first))
    }

    @Test("选中上游高亮关联行，不改变列表数量，再次点选取消")
    func upstreamSelectionHighlightsWithoutFilteringList() {
        let model = ActivityViewModel()
        let first = row(shortID: "AAAA", upstream: ("OpenAI", "gpt-5"))
        let second = row(shortID: "BBBB", upstream: ("DeepSeek", "deepseek-chat"))
        model.ingest(rows: [first, second], activeCount: 0)

        model.toggle(upstream: second.upstreamKey!)
        #expect(model.visibleRows.count == 2)
        #expect(model.highlightLabel == "· 已高亮 DeepSeek · deepseek-chat")
        #expect(model.isRowHighlighted(second))
        #expect(!model.isRowHighlighted(first))

        // 上游高亮时，该上游节点及其相关请求不被灰化。
        #expect(model.isUpstreamRelated(second.upstreamKey!))
        #expect(!model.isUpstreamRelated(first.upstreamKey!))
        #expect(model.isRequestRelated(second))
        #expect(!model.isRequestRelated(first))

        // 再次点击同一节点取消高亮（不残留）。
        model.toggle(upstream: second.upstreamKey!)
        #expect(model.selection == nil)
        #expect(model.highlightLabel == nil)
        #expect(!model.isRowHighlighted(second))
    }

    @Test("高亮期间搜索仍独立过滤列表")
    func searchFiltersIndependentlyOfHighlight() {
        let model = ActivityViewModel()
        let first = row(shortID: "AB12", upstream: ("OpenAI", "gpt-5"))
        let second = row(shortID: "CD34", upstream: ("DeepSeek", "deepseek-chat"))
        model.ingest(rows: [first, second], activeCount: 0)

        model.toggle(upstream: second.upstreamKey!)
        #expect(model.visibleRows.count == 2)

        model.query = "AB12"
        #expect(model.visibleRows.map(\.id) == [first.id])
        // 清除搜索后仍保留高亮，且恢复全部行。
        model.query = ""
        #expect(model.visibleRows.count == 2)
        #expect(model.isRowHighlighted(second))
    }

    // MARK: - 表列宽自适应

    @Test("窄窗口下 API 类型 / 路由 / 上游模型三列各自有下限，不合并")
    func columnsKeepThreeDistinctWidths() {
        let narrow = ActivityColumns(width: 420)
        #expect(narrow.apiWidth > 0)
        #expect(narrow.routeMinWidth > 0)
        #expect(narrow.upstreamMinWidth > 0)
        #expect(!narrow.showTime)
        #expect(!narrow.showElapsed)

        let wide = ActivityColumns(width: 1000)
        #expect(wide.showTime)
        #expect(wide.showElapsed)
        #expect(wide.apiWidth >= narrow.apiWidth)
        #expect(wide.routeMinWidth >= narrow.routeMinWidth)
        #expect(wide.upstreamMinWidth >= narrow.upstreamMinWidth)
    }

    // MARK: - 有界展示

    @Test("进行中请求超出图上限时给出剩余数量，图高度有界")
    func graphIsBounded() {
        let model = ActivityViewModel()
        let rows = (0..<10).map { index in
            row(shortID: "R\(index)", startedAt: Date(timeIntervalSince1970: Double(index)),
                phase: .receiving)
        }
        model.ingest(rows: rows, activeCount: 10)
        #expect(model.graphOverflowCount == 10 - ActivityLimits.graphRequests)
        #expect(model.activeRows.count == 10)

        let capped = ActivityRouteGraph.height(forNodeCount: ActivityLimits.graphRequests)
        #expect(ActivityRouteGraph.height(forNodeCount: 40) == capped)
        #expect(ActivityRouteGraph.height(forNodeCount: 0) > 0)
    }

    // MARK: - 排序 / 搜索 / 复制

    @Test("列表最新在前，图按开始时间升序稳定")
    func ordering() {
        let model = ActivityViewModel()
        let older = row(shortID: "OLD", startedAt: Date(timeIntervalSince1970: 100), phase: .receiving)
        let newer = row(shortID: "NEW", startedAt: Date(timeIntervalSince1970: 200), phase: .receiving)
        model.ingest(rows: [older, newer], activeCount: 2)

        #expect(model.rows.map(\.id) == [newer.id, older.id])
        #expect(model.activeRows.map(\.id) == [older.id, newer.id])
    }

    @Test("搜索匹配路由、上游、协议与短 ID")
    func searchMatches() {
        let model = ActivityViewModel()
        let first = row(shortID: "AB12", routeName: "main", upstream: ("OpenAI", "gpt-5"))
        let second = row(shortID: "CD34", routeName: "coding", upstream: ("DeepSeek", "deepseek-chat"))
        model.ingest(rows: [first, second], activeCount: 0)

        model.query = "deepseek"
        #expect(model.visibleRows.map(\.id) == [second.id])
        model.query = "AB12"
        #expect(model.visibleRows.map(\.id) == [first.id])
        model.query = "responses"
        #expect(model.visibleRows.isEmpty)
    }

    @Test("复制文本含短 ID 与状态，不含正文")
    func copyText() {
        let model = ActivityViewModel()
        model.ingest(rows: [row(shortID: "AB12", routeName: "main", phase: .succeeded,
                                tokens: UsageTokens(input: 100, output: 20))], activeCount: 0)
        let text = model.copyText()
        #expect(text.contains("main"))
        #expect(text.contains("✓ 已完成"))
        #expect(text.contains("100/20"))
    }

    @Test("暂停冻结展示，恢复读取最新快照")
    func pauseFreezesDisplay() {
        let model = ActivityViewModel()
        model.ingest(rows: [row(shortID: "AB12")], activeCount: 0)
        model.paused = true
        #expect(model.statusSummary == "显示已暂停")
        model.paused = false
        #expect(model.statusSummary.contains("最近 1 条"))
    }

    @Test("展开状态由视图模型持有并可切换")
    func expansionToggle() {
        let model = ActivityViewModel()
        let entry = row(shortID: "AB12")
        model.ingest(rows: [entry], activeCount: 0)

        #expect(!model.isExpanded(entry.id))
        model.toggleExpanded(entry.id)
        #expect(model.isExpanded(entry.id))
        model.toggleExpanded(entry.id)
        #expect(!model.isExpanded(entry.id))
    }

    // MARK: - 终态驻留（完成节点保留 5s）

    @Test("终态驻留按真实 endedAt 计时：不足 5s 保留，恰好 5s 起移出，列表不删历史")
    func terminalResidencyUsesRealEndedAt() {
        let model = ActivityViewModel()
        let t0 = Date(timeIntervalSince1970: 10_000)
        let done = row(shortID: "DONE", endedAt: t0, phase: .succeeded)

        model.ingest(rows: [done], activeCount: 0, generatedAt: t0)
        #expect(model.graphRows.map(\.id) == [done.id])

        model.ingest(rows: [done], activeCount: 0, generatedAt: t0.addingTimeInterval(4.999))
        #expect(model.graphRows.map(\.id) == [done.id])

        // 边界：命中 5s 即移出图（`< residentDuration`）。
        model.ingest(rows: [done], activeCount: 0, generatedAt: t0.addingTimeInterval(5))
        #expect(model.graphRows.isEmpty)

        model.ingest(rows: [done], activeCount: 0, generatedAt: t0.addingTimeInterval(5.001))
        #expect(model.graphRows.isEmpty)

        // 图外列表不改：历史行仍在。
        #expect(model.rows.map(\.id) == [done.id])
    }

    @Test("反复刷新不延长驻留：同一 endedAt 随时间推进终会移出")
    func residencyNotExtendedByRefresh() {
        let model = ActivityViewModel()
        let t0 = Date(timeIntervalSince1970: 20_000)
        let done = row(shortID: "DONE", endedAt: t0, phase: .failed)

        for offset in [0.5, 2.0, 4.0] {
            model.ingest(rows: [done], activeCount: 0, generatedAt: t0.addingTimeInterval(offset))
            #expect(model.graphRows.map(\.id) == [done.id])
        }
        model.ingest(rows: [done], activeCount: 0, generatedAt: t0.addingTimeInterval(5.5))
        #expect(model.graphRows.isEmpty)
    }

    @Test("未终结（endedAt 为空）的终态不会被误判为驻留")
    func terminalWithoutEndedAtIsNotResident() {
        let model = ActivityViewModel()
        let t0 = Date(timeIntervalSince1970: 25_000)
        model.ingest(rows: [row(shortID: "DONE", endedAt: nil, phase: .succeeded)],
                     activeCount: 0, generatedAt: t0)
        #expect(model.graphRows.isEmpty)
    }

    @Test("请求 active → terminal 驻留期间颜色不变，新请求拿到不同颜色")
    func colorStableAcrossResidency() {
        let model = ActivityViewModel()
        let t0 = Date(timeIntervalSince1970: 30_000)
        let a = UUID()

        model.ingest(rows: [row(id: a, shortID: "A", startedAt: t0, phase: .receiving)],
                     activeCount: 1, generatedAt: t0)
        let activeColor = model.color(for: a)

        // 同一请求转为终态并驻留：ID 不变 → 颜色不跳变，仍在图上。
        model.ingest(rows: [row(id: a, shortID: "A", startedAt: t0, endedAt: t0, phase: .succeeded)],
                     activeCount: 0, generatedAt: t0.addingTimeInterval(1))
        #expect(model.graphRows.map(\.id) == [a])
        #expect(model.color(for: a) == activeColor)

        // 新请求拿到不同颜色，驻留请求仍保持原色。
        let b = UUID()
        let rows = [row(id: a, shortID: "A", startedAt: t0, endedAt: t0, phase: .succeeded),
                    row(id: b, shortID: "B", startedAt: t0.addingTimeInterval(1), phase: .receiving)]
        model.ingest(rows: rows, activeCount: 1, generatedAt: t0.addingTimeInterval(1.5))
        #expect(model.color(for: a) == activeColor)
        #expect(model.color(for: b) != activeColor)

        // 驻留到期后 a 移出图，但列表仍保留两条历史。
        model.ingest(rows: rows, activeCount: 1, generatedAt: t0.addingTimeInterval(6))
        #expect(model.graphRows.map(\.id) == [b])
        #expect(model.rows.count == 2)
    }

    @Test("activeCount 只算在途：驻留终态出现在图上但不计入运行数")
    func activeCountIgnoresResidents() {
        let model = ActivityViewModel()
        let t0 = Date(timeIntervalSince1970: 40_000)
        let done = row(shortID: "DONE", endedAt: t0, phase: .succeeded)

        model.ingest(rows: [done], activeCount: 0, generatedAt: t0)
        #expect(model.graphRows.count == 1)
        #expect(model.activeCount == 0)
        #expect(model.activeRows.isEmpty)
        #expect(model.statusSummary == "当前没有进行中的请求 · 最近 1 条")
        // 图上只有驻留终态时没有溢出。
        #expect(model.graphOverflowCount == 0)
        #expect(model.graphOverflowText == nil)
    }

    @Test("上限内按开始时间升序位置稳定；超限时在途优先，溢出文案区分在途/刚结束")
    func graphCapPrefersActiveAndDistinguishesOverflow() {
        let model = ActivityViewModel()
        let base = Date(timeIntervalSince1970: 50_000)

        func active(_ i: Int) -> ActivityRowModel {
            row(shortID: "A\(i)", startedAt: base.addingTimeInterval(Double(i)), phase: .receiving)
        }
        func resident(_ i: Int) -> ActivityRowModel {
            row(shortID: "D\(i)", startedAt: base.addingTimeInterval(Double(i) + 10),
                endedAt: base, phase: .succeeded)
        }

        // 恰好 6 个候选：全部展示，按开始时间升序（active→terminal 不改位置）。
        var rows = (0..<3).map(active) + (0..<3).map(resident)
        model.ingest(rows: rows, activeCount: 3, generatedAt: base.addingTimeInterval(1))
        #expect(model.graphRows.map(\.shortID) == ["A0", "A1", "A2", "D0", "D1", "D2"])
        #expect(model.graphOverflowCount == 0)

        // 扩到 5 在途 + 5 刚结束：前 6 个展示节点全是优先的在途，溢出全为驻留终态。
        rows = (0..<5).map(active) + (0..<5).map(resident)
        model.ingest(rows: rows, activeCount: 5, generatedAt: base.addingTimeInterval(1))
        #expect(model.graphRows.count == 10)
        #expect(model.graphShownRows.count == ActivityLimits.graphRequests)
        #expect(model.graphShownRows.filter { $0.isActive }.count == 5)
        #expect(model.graphOverflowCount == 4)
        #expect(model.graphOverflowText == "另有 4 条刚结束的请求未在图中展示。")
    }

    @Test("溢出只含在途 / 混合时文案分别措辞")
    func overflowTextDistinguishesActiveAndResident() {
        let model = ActivityViewModel()
        let base = Date(timeIntervalSince1970: 60_000)

        // 8 在途：溢出 2 条全在途。
        let actives = (0..<8).map {
            row(shortID: "R\($0)", startedAt: base.addingTimeInterval(Double($0)), phase: .receiving)
        }
        model.ingest(rows: actives, activeCount: 8, generatedAt: base)
        #expect(model.graphOverflowText == "另有 2 条在途请求未在图中展示。")

        // 7 在途 + 2 刚结束：展示 6 在途，溢出 1 在途 + 2 刚结束 → 混合措辞。
        let mixed = (0..<7).map {
            row(shortID: "R\($0)", startedAt: base.addingTimeInterval(Double($0)), phase: .receiving)
        } + (0..<2).map {
            row(shortID: "D\($0)", startedAt: base.addingTimeInterval(Double($0) + 20),
                endedAt: base, phase: .failed)
        }
        model.ingest(rows: mixed, activeCount: 7, generatedAt: base)
        #expect(model.graphOverflowText == "另有 3 条请求未在图中展示（1 在途，2 刚结束）。")
    }

    @Test("暂停期间驻留节点冻结，不因时间推进消失")
    func residencyFrozenWhilePaused() {
        let model = ActivityViewModel()
        let t0 = Date(timeIntervalSince1970: 70_000)
        let done = row(shortID: "DONE", endedAt: t0, phase: .cancelled)

        model.ingest(rows: [done], activeCount: 0, generatedAt: t0)
        model.paused = true
        model.refresh() // 暂停：no-op，快照时刻冻结
        #expect(model.graphRows.map(\.id) == [done.id])
        #expect(model.statusSummary == "显示已暂停")
    }

    @Test("apply 以快照 generatedAt 计时：新快照到期即移出，列表仍保留历史")
    func applyUsesSnapshotGeneratedAt() {
        let model = ActivityViewModel()
        let t0 = Date(timeIntervalSince1970: 80_000)
        let id = UUID()
        let entry = request(id: id, status: .succeeded,
                            startedAt: t0.addingTimeInterval(-2), endedAt: t0)

        model.apply(ActivitySnapshot(generatedAt: t0, activeCount: 0, capacity: 300,
                                     evictedCount: 0, requests: [entry]))
        #expect(model.graphRows.map(\.id) == [id])
        #expect(model.activeCount == 0)

        model.apply(ActivitySnapshot(generatedAt: t0.addingTimeInterval(5.5), activeCount: 0,
                                     capacity: 300, evictedCount: 0, requests: [entry]))
        #expect(model.graphRows.isEmpty)
        #expect(model.rows.map(\.id) == [id])
    }
}
