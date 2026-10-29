import Foundation

struct UsagePerformance: Codable, Equatable, Sendable {
    var streaming: Bool
    var ttftMS: Double? = nil
    var requestTTFTMS: Double? = nil
    /// 首分片→流结束的线上到达时间；只作为含 TTFT 速率分母的一部分参与聚合。
    var generationMS: Double? = nil
    var outputDeltaCount: Int = 0
}

/// 单个请求的请求级性能明细（活动页表格用）。
/// 缺失或无效一律为 `nil`，由展示层显示「—」，绝不伪造成 0。
struct RequestPerformanceDetail: Equatable, Sendable {
    /// 首字等待：优先请求级 `requestTTFTMS`，缺失时回退尝试级 `ttftMS`。
    var ttftMS: Double
    /// 输出 tokens × 1000 /（TTFT + 生成时长）。分母覆盖整个响应期，攒批下发也成立。
    var tpsIncludingTTFT: Double
}

extension UsagePerformance {
    /// 合法时长：有限且非负（TTFT 允许 0，表示首个增量立即到达）。
    static func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// 请求级首字等待：优先 `requestTTFTMS`，缺失 / 无效时回退尝试级 `ttftMS`。
    var effectiveTTFTMS: Double? {
        Self.validDuration(requestTTFTMS) ?? Self.validDuration(ttftMS)
    }

    /// 单请求性能明细：仅流式、有效 TTFT、输出 token ≥ 2、生成时长 > 0、输出增量 ≥ 2 时给出；
    /// 任一前提缺失即返回 `nil`（展示为「—」），绝不伪造 0。
    func requestDetail(outputTokens: Int?) -> RequestPerformanceDetail? {
        guard streaming, outputDeltaCount >= 2,
              let ttftMS = effectiveTTFTMS,
              let outputTokens, outputTokens >= 2,
              let generation = Self.validDuration(generationMS), generation > 0 else { return nil }
        let total = ttftMS + generation
        guard total.isFinite, total > 0 else { return nil }
        let including = Double(outputTokens) * 1000 / total
        guard including.isFinite else { return nil }
        return RequestPerformanceDetail(ttftMS: ttftMS,
                                        tpsIncludingTTFT: including)
    }

    /// 单次上游尝试的性能明细（活动页逐次尝试行用）：TTFT 取该次尝试自身，
    /// 不含回退前的等待；其余有效性与请求级口径一致。
    func attemptDetail(outputTokens: Int?) -> RequestPerformanceDetail? {
        guard streaming, outputDeltaCount >= 2,
              let ttftMS = Self.validDuration(ttftMS),
              let outputTokens, outputTokens >= 2,
              let generation = Self.validDuration(generationMS), generation > 0 else { return nil }
        let total = ttftMS + generation
        guard total.isFinite, total > 0 else { return nil }
        let including = Double(outputTokens) * 1000 / total
        guard including.isFinite else { return nil }
        return RequestPerformanceDetail(ttftMS: ttftMS,
                                        tpsIncludingTTFT: including)
    }
}

/// 区间性能摘要。吞吐一律是"总输出 token / 总时长"的加权速率，绝不取逐请求速率的算术平均；
/// TTFT 是有效样本的算术平均。缺失 / 无效一律为 `nil`，绝不伪造成 0。
struct PerformanceSummary: Codable, Sendable {
    var attempts: Int = 0
    /// 去重后的请求数：同一请求的多次自动回退尝试只计一次（与 `attempts` 同一记录口径）。
    var requests: Int = 0
    var successfulStreamingAttempts: Int = 0
    var ttftSamples: Int = 0
    /// 请求级与上游尝试级计时可能独立缺失，分别统计有效样本。
    var requestTTFTSamples: Int = 0
    /// 三个加权速率共用的"TPS 有效队列"样本数（含尝试 TTFT、请求 TTFT 与合法
    /// 生成时长；分母覆盖整个响应期，攒批一次性下发也不失真）。
    var tpsSamples: Int = 0
    /// 单次尝试首输出（TTFT）有效样本的算术平均。
    var ttftMeanMS: Double? = nil
    /// 请求级总等待（requestTTFT）有效样本的算术平均。
    var requestTTFTMeanMS: Double? = nil
    /// 加权速率：Σ输出 / Σ(尝试TTFT + 生成时长)。
    var tpsIncludingTTFT: Double? = nil
    /// 加权速率：Σ输出 / Σ(请求TTFT + 生成时长)。
    var requestTpsIncludingTTFT: Double? = nil
    /// 加权速率：Σ输出 / Σ生成时长（不含首字等待），与含 TTFT 版本共用同一批样本。
    /// 仅作对照：攒批一次性下发的上游会让生成时长偏小、该值偏高，读的时候要和含 TTFT 一起看。
    var tpsExcludingTTFT: Double? = nil
}

struct PerformanceGroupRow: Identifiable, Codable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var summary: PerformanceSummary
}

struct PerformanceSnapshot: Codable, Sendable {
    var summary = PerformanceSummary()
    var groups: [PerformanceGroupRow] = []
}

/// 实际样本的最近秩（nearest-rank）分位数：升序排序后取 `ceil(p * N) - 1` 号样本（1-based 秩），
/// 不做线性插值。性能采样量小，直接排序全量样本；既不截尾，也不把部分样本静默当成全量。
/// 空样本返回 `nil`；`p` 夹到 `[0, 1]`。
///
/// 仅作为原始样本的通用工具保留（CSV / 诊断等未来用途）；区间摘要不再用它，改用加权均值 / 速率。
internal func nearestRankPercentile(_ samples: [Double], _ p: Double) -> Double? {
    guard !samples.isEmpty else { return nil }
    let sorted = samples.sorted()
    let clamped = min(max(p, 0), 1)
    let rank = Int((clamped * Double(sorted.count)).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
}
