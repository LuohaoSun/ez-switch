import Foundation
import Testing
@testable import EZSwitch

/// `UsageStore.performanceSnapshot` 的数据层语义：
/// 资格口径（成功 + 2xx + 流式）、缺失/失败/取消/非流式的排除、加权吞吐（总 token / 总时长）、
/// TTFT 均值样本的独立性、TPS 有效队列的公共分母、分组身份隔离、跨重开的持久化，
/// 以及空/无效一律为 nil（绝不伪造成 0）。
@Suite("Performance store")
struct PerformanceStoreTests {

    // MARK: - 夹具

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("performance-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.sqlite")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    /// `requestTTFT` 默认 nil：默认记录只进 TTFT 队列、不进 TPS 有效队列（需显式给出请求级计时）。
    private func performance(streaming: Bool = true, ttft: Double? = 100, requestTTFT: Double? = nil,
                             generation: Double? = 1000, deltaCount: Int = 10) -> UsagePerformance {
        UsagePerformance(streaming: streaming, ttftMS: ttft, requestTTFTMS: requestTTFT,
                         generationMS: generation, outputDeltaCount: deltaCount)
    }

    private func record(
        timestamp: Date,
        routeID: String = "route-1",
        routeName: String = "Route One",
        provider: String = "OpenAI",
        model: String = "gpt-4o",
        status: Int? = 200,
        outcome: String = "success",
        input: Int? = 10,
        output: Int? = 20,
        performance: UsagePerformance? = nil
    ) -> UsageRecord {
        UsageRecord(requestID: UUID(), timestamp: timestamp, routeID: routeID, routeName: routeName,
                    remoteID: "remote-1", provider: provider, model: model, endpoint: "chat",
                    attempt: 1, status: status, outcome: outcome, durationMS: 100,
                    tokens: UsageTokens(input: input, output: output), performance: performance)
    }

    private func snapshot(_ store: UsageStore, from: Date, grouping: UsageGrouping = .route)
        async throws -> PerformanceSnapshot {
        try await store.performanceSnapshot(from: from.addingTimeInterval(-1),
                                            to: from.addingTimeInterval(3600), grouping: grouping)
    }

    private func approx(_ value: Double?, _ expected: Double, tolerance: Double = 0.001) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    // MARK: - 原始工具

    @Test
    func nearestRankQuantileMatchesSortedSamples() {
        #expect(nearestRankPercentile([], 0.5) == nil)
        #expect(nearestRankPercentile([50], 0.5) == 50)
        #expect(nearestRankPercentile([50], 0.95) == 50)
        // N=4：p50 → ceil(2)-1=1 号样本；p95 → ceil(3.8)-1=3 号样本。
        #expect(nearestRankPercentile([10, 20, 30, 40], 0.5) == 20)
        #expect(nearestRankPercentile([10, 20, 30, 40], 0.95) == 40)
        // 输入未排序也以排序后的秩取值。
        #expect(nearestRankPercentile([400, 100, 300, 200], 0.5) == 200)
        // 边界：p=0 取最小，p=1 取最大。
        #expect(nearestRankPercentile([10, 20, 30, 40], 0) == 10)
        #expect(nearestRankPercentile([10, 20, 30, 40], 1) == 40)
    }

    // MARK: - 加权吞吐回归（非对称 2 样本）

    /// 核心回归：加权吞吐 = Σ输出 / Σ时长，绝不取逐请求速率的算术平均；
    /// TTFT 是有效样本的算术平均，绝不是中位数。
    /// 样本：100 token / 1s 与 100 token / 9s。
    @Test
    func weightedRatesUseTotalsNotAverageOfPerRequestRates() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)

        // 样本 1：生成 1s、输出 100；样本 2：生成 9s、输出 100。
        store.record(record(timestamp: start, output: 100,
                            performance: performance(ttft: 1000, requestTTFT: 2000, generation: 1000)))
        store.record(record(timestamp: start.addingTimeInterval(1), output: 100,
                            performance: performance(ttft: 3000, requestTTFT: 4000, generation: 9000)))
        try await store.flush()

        let summary = try await snapshot(store, from: start).summary
        #expect(summary.attempts == 2)
        #expect(summary.successfulStreamingAttempts == 2)
        #expect(summary.ttftSamples == 2)
        #expect(summary.requestTTFTSamples == 2)
        #expect(summary.tpsSamples == 2)

        // 加权（排除 TTFT）：Σ输出 200 × 1000 / Σ生成 10000 = 20 tok/s。
        // 逐请求速率的算术平均是 (100 + 11.111) / 2 ≈ 55.56 —— 绝不能出现。
        #expect(approx(summary.tpsExcludingTTFT, 20))
        // 加权（含尝试 TTFT）：200 × 1000 / (2000 + 12000) = 14.2857。
        #expect(approx(summary.tpsIncludingTTFT, 200.0 * 1000 / 14000))
        // 加权（含请求 TTFT）：200 × 1000 / (3000 + 13000) = 12.5。
        #expect(approx(summary.requestTpsIncludingTTFT, 12.5))
        // 含请求级计时的分母显著大于含尝试级，两个速率必须不同（回退请求 vs 单次尝试口径）。
        #expect(summary.requestTpsIncludingTTFT != summary.tpsIncludingTTFT)

        // TTFT 均值：(1000 + 3000) / 2 = 2000；中位数（最近秩 p50）是 1000，绝不能用中位数。
        #expect(approx(summary.ttftMeanMS, 2000))
        #expect(approx(summary.requestTTFTMeanMS, 3000))
        #expect(nearestRankPercentile([1000, 3000], 0.5) == 1000)
    }

    @Test
    func meanQuantilesUseAllSamplesWithoutTruncation() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)

        let ttfts: [Double] = [100, 200, 300, 400]
        for (index, ttft) in ttfts.enumerated() {
            store.record(record(timestamp: start.addingTimeInterval(Double(index)),
                                output: 10 * (index + 1),
                                performance: performance(ttft: ttft,
                                                         requestTTFT: Double(50 * (index + 1)))))
        }
        try await store.flush()

        let summary = try await snapshot(store, from: start).summary
        #expect(summary.attempts == 4)
        #expect(summary.successfulStreamingAttempts == 4)
        #expect(summary.ttftSamples == 4)
        #expect(approx(summary.ttftMeanMS, 250))          // (100+200+300+400)/4
        #expect(summary.requestTTFTSamples == 4)
        #expect(approx(summary.requestTTFTMeanMS, 125))   // (50+100+150+200)/4
        #expect(summary.tpsSamples == 4)
        // 生成均为 1000ms：tpsExcludingTTFT = Σ输出 100 × 1000 / Σ生成 4000 = 25。
        #expect(approx(summary.tpsExcludingTTFT, 25))
        // tpsIncludingTTFT = 100000 / (100+200+300+400 + 4000) = 100000/5000 = 20。
        #expect(approx(summary.tpsIncludingTTFT, 20))
        // requestTpsIncludingTTFT = 100000 / (50+100+150+200 + 4000) = 100000/4500。
        #expect(approx(summary.requestTpsIncludingTTFT, 100000.0 / 4500))
    }

    // MARK: - TPS 公共队列与 TTFT 独立样本

    /// 缺 requestTTFT 的记录从三个 TPS 中一并排除，但仍计入尝试 TTFT 队列。
    @Test
    func missingRequestTTFTExcludedFromAllTpsButStillCountsAttemptTTFT() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)

        // 缺 requestTTFT：计入 ttft 样本，但三个 TPS 都不采纳。
        store.record(record(timestamp: start, output: 100,
                            performance: performance(ttft: 100, requestTTFT: nil, generation: 1000)))
        // 完整记录：进入公共 TPS 队列。
        store.record(record(timestamp: start.addingTimeInterval(1), output: 100,
                            performance: performance(ttft: 100, requestTTFT: 200, generation: 1000)))
        try await store.flush()

        let summary = try await snapshot(store, from: start).summary
        #expect(summary.successfulStreamingAttempts == 2)
        #expect(summary.ttftSamples == 2)
        #expect(summary.requestTTFTSamples == 1)
        #expect(summary.tpsSamples == 1)          // 公共队列只有 1 条
        #expect(approx(summary.ttftMeanMS, 100))  // TTFT 均值独立于 TPS 队列
        #expect(approx(summary.requestTTFTMeanMS, 200))
        // 只有完整记录参与，分母都是它自己的时长。
        #expect(approx(summary.tpsIncludingTTFT, 100000.0 / 1100))
        #expect(approx(summary.requestTpsIncludingTTFT, 100000.0 / 1200))
        #expect(approx(summary.tpsExcludingTTFT, 100))
    }

    // MARK: - 资格与排除

    @Test
    func excludesFailedCancelledNon2xxNonStreamingAndMissingTTFT() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)

        // 合格：成功 + 2xx + 流式 + 有效 ttft 与 requestTTFT。
        store.record(record(timestamp: start,
                            performance: performance(ttft: 100, requestTTFT: 150)))
        // 失败：outcome=failure。
        store.record(record(timestamp: start.addingTimeInterval(1), outcome: "failure",
                            performance: performance(ttft: 110, requestTTFT: 160)))
        // 取消。
        store.record(record(timestamp: start.addingTimeInterval(2), outcome: "cancelled",
                            performance: performance(ttft: 120, requestTTFT: 170)))
        // 非 2xx（即便 outcome=success）。
        store.record(record(timestamp: start.addingTimeInterval(3), status: 500,
                            performance: performance(ttft: 130, requestTTFT: 180)))
        // 非流式。
        store.record(record(timestamp: start.addingTimeInterval(4),
                            performance: performance(streaming: false, ttft: 140, requestTTFT: 190)))
        // 成功流式但缺 ttft → 计入资格分母与 requestTTFT 样本，但不产生 ttft/TPS 样本。
        store.record(record(timestamp: start.addingTimeInterval(5),
                            performance: performance(ttft: nil, requestTTFT: 250)))
        // 旧记录：无性能数据。
        store.record(record(timestamp: start.addingTimeInterval(6), performance: nil))
        try await store.flush()

        let summary = try await snapshot(store, from: start).summary
        #expect(summary.attempts == 7)
        #expect(summary.successfulStreamingAttempts == 2)
        #expect(summary.ttftSamples == 1)
        #expect(approx(summary.ttftMeanMS, 100))
        // 两条成功流式都带 requestTTFT（含缺 ttft 的那条）：独立计数。
        #expect(summary.requestTTFTSamples == 2)
        #expect(approx(summary.requestTTFTMeanMS, 200))
        // 仅合格记录进入公共 TPS 队列。
        #expect(summary.tpsSamples == 1)
        #expect(approx(summary.tpsIncludingTTFT, 20000.0 / 1100))
        #expect(approx(summary.requestTpsIncludingTTFT, 20000.0 / 1150))
        #expect(approx(summary.tpsExcludingTTFT, 20))
    }

    @Test
    func ttftSampleCountsEvenWithoutUsageTokens() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        // 缺 usage（无 output token）仍可出 TTFT；无 generation 故无 TPS。
        store.record(record(timestamp: start, input: nil, output: nil,
                            performance: performance(ttft: 250, requestTTFT: 300,
                                                     generation: nil, deltaCount: 0)))
        try await store.flush()

        let summary = try await snapshot(store, from: start).summary
        #expect(summary.successfulStreamingAttempts == 1)
        #expect(summary.ttftSamples == 1)
        #expect(approx(summary.ttftMeanMS, 250))
        #expect(summary.requestTTFTSamples == 1)
        #expect(approx(summary.requestTTFTMeanMS, 300))
        #expect(summary.tpsSamples == 0)
        #expect(summary.tpsIncludingTTFT == nil)
        #expect(summary.requestTpsIncludingTTFT == nil)
        #expect(summary.tpsExcludingTTFT == nil)
    }

    @Test
    func shortOrInsufficientOutputYieldsNoTPS() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        // outputTokens < 2。
        store.record(record(timestamp: start, output: 1,
                            performance: performance(ttft: 100, requestTTFT: 150)))
        // deltaCount < 2。
        store.record(record(timestamp: start.addingTimeInterval(1), output: 100,
                            performance: performance(ttft: 100, requestTTFT: 150, deltaCount: 1)))
        // generation 非正。
        store.record(record(timestamp: start.addingTimeInterval(2), output: 100,
                            performance: performance(ttft: 100, requestTTFT: 150, generation: 0)))
        // output 未知。
        store.record(record(timestamp: start.addingTimeInterval(3), output: nil,
                            performance: performance(ttft: 100, requestTTFT: 150)))
        try await store.flush()

        let summary = try await snapshot(store, from: start).summary
        #expect(summary.attempts == 4)
        #expect(summary.successfulStreamingAttempts == 4)
        #expect(summary.ttftSamples == 4)
        #expect(summary.tpsSamples == 0)
        #expect(summary.tpsIncludingTTFT == nil)
        #expect(summary.requestTpsIncludingTTFT == nil)
        #expect(summary.tpsExcludingTTFT == nil)
    }

    /// 无效时长（负数 / NaN / 无穷）在读写两侧都被归一为缺失：不进入任何样本，也不污染均值。
    @Test
    func invalidDurationsAreSanitizedAndDropped() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start, performance: performance(ttft: -5,
                                                                       requestTTFT: .infinity,
                                                                       generation: .nan,
                                                                       deltaCount: -3)))
        try await store.flush()

        let summary = try await snapshot(store, from: start).summary
        #expect(summary.attempts == 1)
        #expect(summary.successfulStreamingAttempts == 1)
        #expect(summary.ttftSamples == 0)
        #expect(summary.ttftMeanMS == nil)
        #expect(summary.requestTTFTSamples == 0)
        #expect(summary.requestTTFTMeanMS == nil)
        #expect(summary.tpsSamples == 0)
        #expect(summary.tpsExcludingTTFT == nil)
    }

    // MARK: - 分组身份

    @Test
    func modelGroupingSeparatesProvidersAndAvoidsIDCollisions() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        // 裸字符串拼接下 "a"+"bc" 与 "ab"+"c" 会碰撞；分组 id 必须区分。
        store.record(record(timestamp: start, provider: "a", model: "bc",
                            performance: performance(ttft: 100)))
        store.record(record(timestamp: start.addingTimeInterval(1), provider: "ab", model: "c",
                            performance: performance(ttft: 200)))
        // 同名模型、不同供应商不得合并。
        store.record(record(timestamp: start.addingTimeInterval(2), provider: "OpenAI", model: "gpt",
                            performance: performance(ttft: 300)))
        store.record(record(timestamp: start.addingTimeInterval(3), provider: "Azure", model: "gpt",
                            performance: performance(ttft: 400)))
        // provider/model 本身含旧分隔符 \u{1F}：朴素拼接会碰撞，长度前缀编码不会。
        store.record(record(timestamp: start.addingTimeInterval(4), provider: "x\u{1F}y", model: "z",
                            performance: performance(ttft: 500)))
        store.record(record(timestamp: start.addingTimeInterval(5), provider: "x", model: "y\u{1F}z",
                            performance: performance(ttft: 600)))
        try await store.flush()

        let byModel = try await snapshot(store, from: start, grouping: .model)
        #expect(byModel.groups.count == 6)
        #expect(Set(byModel.groups.map(\.id)).count == 6)
        let gptRows = byModel.groups.filter { $0.title == "gpt" }
        #expect(gptRows.count == 2)
        #expect(Set(gptRows.map(\.subtitle)) == ["OpenAI", "Azure"])
        // 含分隔符的两组保持独立（一个在供应商、一个在模型）。
        let separated = byModel.groups.filter {
            $0.subtitle.contains("\u{1F}") || $0.title.contains("\u{1F}")
        }
        #expect(separated.count == 2)
        #expect(Set(separated.map(\.id)).count == 2)
    }

    @Test
    func routeGroupUsesLatestNameAndAggregatesWeightedPerGroup() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start, routeID: "r1", routeName: "Alpha", output: 100,
                            performance: performance(ttft: 100, requestTTFT: 150, generation: 1000)))
        store.record(record(timestamp: start.addingTimeInterval(1), routeID: "r1", routeName: "Beta",
                            output: 300,
                            performance: performance(ttft: 300, requestTTFT: 350, generation: 3000)))
        // 失败尝试：计入 attempts，不进入任何样本。
        store.record(record(timestamp: start.addingTimeInterval(2), routeID: "r2", routeName: "Gamma",
                            outcome: "failure", performance: performance(ttft: 50, requestTTFT: 80)))
        try await store.flush()

        let byRoute = try await snapshot(store, from: start, grouping: .route)
        #expect(byRoute.groups.count == 2)
        #expect(byRoute.groups.map(\.id) == ["r1", "r2"]) // attempts 降序
        #expect(byRoute.groups[0].title == "Beta")        // 最近一次的名字
        let r1 = byRoute.groups[0].summary
        #expect(r1.attempts == 2)
        #expect(r1.successfulStreamingAttempts == 2)
        #expect(r1.ttftSamples == 2)
        #expect(approx(r1.ttftMeanMS, 200))               // (100+300)/2，不是中位数 100
        #expect(r1.tpsSamples == 2)
        #expect(approx(r1.tpsExcludingTTFT, 400000.0 / 4000))   // Σ输出 400 / Σ生成 4000
        #expect(approx(r1.tpsIncludingTTFT, 400000.0 / 4400))   // Σ(ttft+gen)=4400
        #expect(approx(r1.requestTpsIncludingTTFT, 400000.0 / 4500))
        let r2 = byRoute.groups[1].summary
        #expect(r2.attempts == 1)
        #expect(r2.successfulStreamingAttempts == 0)
        #expect(r2.ttftSamples == 0)
        #expect(r2.tpsExcludingTTFT == nil)
    }

    // MARK: - 区间与持久化

    @Test
    func emptyRangeReturnsEmptySnapshot() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start, performance: performance(ttft: 100, requestTTFT: 150)))
        try await store.flush()

        let snapshot = try await store.performanceSnapshot(from: start, to: start, grouping: .route)
        #expect(snapshot.summary.attempts == 0)
        #expect(snapshot.summary.ttftMeanMS == nil)
        #expect(snapshot.summary.requestTTFTMeanMS == nil)
        #expect(snapshot.summary.tpsIncludingTTFT == nil)
        #expect(snapshot.summary.requestTpsIncludingTTFT == nil)
        #expect(snapshot.summary.tpsExcludingTTFT == nil)
        #expect(snapshot.groups.isEmpty)
    }

    @Test
    func performancePersistsAcrossReopen() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)

        let first = UsageStore(url: url)
        first.record(record(timestamp: start, output: 30,
                            performance: performance(ttft: 123.5, requestTTFT: 45.5,
                                                     generation: 2000, deltaCount: 7)))
        try await first.flush()

        let reopened = UsageStore(url: url)
        let summary = try await snapshot(reopened, from: start).summary
        #expect(summary.attempts == 1)
        #expect(approx(summary.ttftMeanMS, 123.5))
        #expect(approx(summary.requestTTFTMeanMS, 45.5))
        #expect(approx(summary.tpsExcludingTTFT, 15))       // 30 * 1000 / 2000
        #expect(approx(summary.tpsIncludingTTFT, 30000.0 / 2123.5))
        #expect(approx(summary.requestTpsIncludingTTFT, 30000.0 / 2045.5))
    }

    @Test
    func legacyRowsWithoutPerformanceOnlyContributeAttempts() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        // 三条旧式成功记录，全部无性能数据。
        for offset in 0..<3 {
            store.record(record(timestamp: start.addingTimeInterval(Double(offset)), performance: nil))
        }
        try await store.flush()

        let snapshot = try await snapshot(store, from: start)
        #expect(snapshot.summary.attempts == 3)
        #expect(snapshot.summary.successfulStreamingAttempts == 0)
        #expect(snapshot.summary.ttftSamples == 0)
        #expect(snapshot.summary.ttftMeanMS == nil)
        #expect(snapshot.summary.tpsSamples == 0)
        #expect(snapshot.summary.tpsExcludingTTFT == nil)
        #expect(snapshot.groups.count == 1)
        #expect(snapshot.groups[0].summary.attempts == 3)
    }
}
