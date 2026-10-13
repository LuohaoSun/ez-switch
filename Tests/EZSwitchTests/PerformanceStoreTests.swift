import Foundation
import Testing
@testable import EZSwitch

/// `UsageStore.performanceSnapshot` 的数据层语义：
/// 资格口径（成功 + 2xx + 流式）、缺失/失败/取消/非流式的排除、最近秩分位数、
/// 分组身份隔离、短输出 TPS 归零（nil），以及跨重开的持久化。
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

    // MARK: - 分位数算法

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

    @Test
    func summaryQuantilesUseAllSamplesWithoutTruncation() async throws {
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

        let snapshot = try await snapshot(store, from: start)
        #expect(snapshot.summary.attempts == 4)
        #expect(snapshot.summary.successfulStreamingAttempts == 4)
        #expect(snapshot.summary.ttftSamples == 4)
        #expect(snapshot.summary.ttftP50MS == 200)
        #expect(snapshot.summary.ttftP95MS == 400)
        // requestTTFT 样本 [50,100,150,200]，独立计数。
        #expect(snapshot.summary.requestTTFTSamples == 4)
        #expect(snapshot.summary.requestTTFTP50MS == 100)
        #expect(snapshot.summary.requestTTFTP95MS == 200)
        // tps = output * 1000 / generation = [10,20,30,40]。
        #expect(snapshot.summary.tpsSamples == 4)
        #expect(snapshot.summary.tpsP50 == 20)
    }

    // MARK: - 资格与排除

    @Test
    func excludesFailedCancelledNon2xxNonStreamingAndMissingTTFT() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)

        // 合格：成功 + 2xx + 流式 + 有效 ttft。
        store.record(record(timestamp: start, performance: performance(ttft: 100)))
        // 失败：outcome=failure。
        store.record(record(timestamp: start.addingTimeInterval(1), outcome: "failure",
                            performance: performance(ttft: 110)))
        // 取消。
        store.record(record(timestamp: start.addingTimeInterval(2), outcome: "cancelled",
                            performance: performance(ttft: 120)))
        // 非 2xx（即便 outcome=success）。
        store.record(record(timestamp: start.addingTimeInterval(3), status: 500,
                            performance: performance(ttft: 130)))
        // 非流式。
        store.record(record(timestamp: start.addingTimeInterval(4),
                            performance: performance(streaming: false, ttft: 140)))
        // 成功流式但缺 ttft → 计入资格分母，但不产生 ttft/tps 样本。
        store.record(record(timestamp: start.addingTimeInterval(5), performance: performance(ttft: nil)))
        // 旧记录：无性能数据。
        store.record(record(timestamp: start.addingTimeInterval(6), performance: nil))
        try await store.flush()

        let snapshot = try await snapshot(store, from: start)
        #expect(snapshot.summary.attempts == 7)
        #expect(snapshot.summary.successfulStreamingAttempts == 2)
        #expect(snapshot.summary.ttftSamples == 1)
        #expect(snapshot.summary.ttftP50MS == 100)
        #expect(snapshot.summary.ttftP95MS == 100)
        // 无任何 request TTFT 采样；不应被 ttftSamples 虚报。
        #expect(snapshot.summary.requestTTFTSamples == 0)
        #expect(snapshot.summary.tpsSamples == 1)
    }

    @Test
    func ttftSampleCountsEvenWithoutUsageTokens() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        // 缺 usage（无 output token）仍可出 TTFT；无 generation 故无 TPS。
        store.record(record(timestamp: start, input: nil, output: nil,
                            performance: performance(ttft: 250, generation: nil, deltaCount: 0)))
        try await store.flush()

        let snapshot = try await snapshot(store, from: start)
        #expect(snapshot.summary.successfulStreamingAttempts == 1)
        #expect(snapshot.summary.ttftSamples == 1)
        #expect(snapshot.summary.ttftP50MS == 250)
        #expect(snapshot.summary.requestTTFTSamples == 0)
        #expect(snapshot.summary.tpsSamples == 0)
        #expect(snapshot.summary.tpsP50 == nil)
    }

    @Test
    func shortOrInsufficientOutputYieldsNoTPS() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        // outputTokens < 2。
        store.record(record(timestamp: start, output: 1, performance: performance()))
        // deltaCount < 2。
        store.record(record(timestamp: start.addingTimeInterval(1), output: 100,
                            performance: performance(deltaCount: 1)))
        // generation 非正。
        store.record(record(timestamp: start.addingTimeInterval(2), output: 100,
                            performance: performance(generation: 0)))
        // output 未知。
        store.record(record(timestamp: start.addingTimeInterval(3), output: nil,
                            performance: performance()))
        try await store.flush()

        let snapshot = try await snapshot(store, from: start)
        #expect(snapshot.summary.attempts == 4)
        #expect(snapshot.summary.successfulStreamingAttempts == 4)
        #expect(snapshot.summary.ttftSamples == 4)
        #expect(snapshot.summary.tpsSamples == 0)
        #expect(snapshot.summary.tpsP50 == nil)
    }

    @Test
    func invalidDurationsAreSanitizedAndDropped() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        // 负数 / NaN / 无穷全部无效 → 不进入任何分位数样本；负 deltaCount 归 0。
        store.record(record(timestamp: start, performance: performance(ttft: -5,
                                                                       requestTTFT: .infinity,
                                                                       generation: .nan,
                                                                       deltaCount: -3)))
        try await store.flush()

        let snapshot = try await snapshot(store, from: start)
        #expect(snapshot.summary.attempts == 1)
        #expect(snapshot.summary.successfulStreamingAttempts == 1)
        #expect(snapshot.summary.ttftSamples == 0)
        #expect(snapshot.summary.ttftP50MS == nil)
        #expect(snapshot.summary.requestTTFTP50MS == nil)
        #expect(snapshot.summary.tpsSamples == 0)
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
    func routeGroupUsesLatestNameAndAggregatesPerGroup() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start, routeID: "r1", routeName: "Alpha",
                            performance: performance(ttft: 100)))
        store.record(record(timestamp: start.addingTimeInterval(1), routeID: "r1", routeName: "Beta",
                            performance: performance(ttft: 300)))
        // 失败尝试：计入 attempts，不进入分位数。
        store.record(record(timestamp: start.addingTimeInterval(2), routeID: "r2", routeName: "Gamma",
                            outcome: "failure", performance: performance(ttft: 50)))
        try await store.flush()

        let byRoute = try await snapshot(store, from: start, grouping: .route)
        #expect(byRoute.groups.count == 2)
        #expect(byRoute.groups.map(\.id) == ["r1", "r2"]) // attempts 降序
        #expect(byRoute.groups[0].title == "Beta")        // 最近一次的名字
        #expect(byRoute.groups[0].summary.attempts == 2)
        #expect(byRoute.groups[0].summary.successfulStreamingAttempts == 2)
        #expect(byRoute.groups[0].summary.ttftSamples == 2)
        #expect(byRoute.groups[0].summary.ttftP50MS == 100) // [100,300] 最近秩 p50 → 100
        #expect(byRoute.groups[1].summary.attempts == 1)
        #expect(byRoute.groups[1].summary.successfulStreamingAttempts == 0)
        #expect(byRoute.groups[1].summary.ttftSamples == 0)
    }

    // MARK: - 区间与持久化

    @Test
    func emptyRangeReturnsEmptySnapshot() async throws {
        let url = try makeDatabaseURL()
        defer { cleanup(url) }
        let start = day(2026, 5, 10)
        let store = UsageStore(url: url)
        store.record(record(timestamp: start, performance: performance()))
        try await store.flush()

        let snapshot = try await store.performanceSnapshot(from: start, to: start, grouping: .route)
        #expect(snapshot.summary.attempts == 0)
        #expect(snapshot.summary.ttftP50MS == nil)
        #expect(snapshot.summary.tpsP50 == nil)
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
        let snapshot = try await snapshot(reopened, from: start)
        #expect(snapshot.summary.attempts == 1)
        #expect(snapshot.summary.ttftP50MS == 123.5)
        #expect(snapshot.summary.requestTTFTP50MS == 45.5)
        #expect(snapshot.summary.tpsP50 == 15) // 30 * 1000 / 2000
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
        #expect(snapshot.summary.ttftP50MS == nil)
        #expect(snapshot.summary.tpsSamples == 0)
        #expect(snapshot.groups.count == 1)
        #expect(snapshot.groups[0].summary.attempts == 3)
    }
}
