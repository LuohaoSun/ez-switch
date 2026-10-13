import Foundation

struct UsagePerformance: Codable, Equatable, Sendable {
    var streaming: Bool
    var ttftMS: Double? = nil
    var requestTTFTMS: Double? = nil
    var generationMS: Double? = nil
    var outputDeltaCount: Int = 0

    /// 有效吞吐（token/s）：仅在流式、且已观测到有效 TTFT、输出增量与生成时长都足以支撑时给出。
    /// 有效 TTFT 是本方法的硬前提（与统计口径一致：无 TTFT 的尝试不产生 TPS 样本）。
    func tps(outputTokens: Int?) -> Double? {
        guard streaming, let ttftMS, ttftMS.isFinite, ttftMS >= 0, outputDeltaCount >= 2,
              let outputTokens, outputTokens >= 2,
              let generationMS, generationMS.isFinite, generationMS > 0 else { return nil }
        let value = Double(outputTokens) * 1000 / generationMS
        return value.isFinite ? value : nil
    }
}

struct PerformanceSummary: Codable, Sendable {
    var attempts: Int = 0
    var successfulStreamingAttempts: Int = 0
    var ttftSamples: Int = 0
    /// 请求级与上游尝试级计时可能独立缺失，分别统计有效样本。
    var requestTTFTSamples: Int = 0
    var tpsSamples: Int = 0
    var ttftP50MS: Double? = nil
    var ttftP95MS: Double? = nil
    var requestTTFTP50MS: Double? = nil
    var requestTTFTP95MS: Double? = nil
    var tpsP50: Double? = nil
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
internal func nearestRankPercentile(_ samples: [Double], _ p: Double) -> Double? {
    guard !samples.isEmpty else { return nil }
    let sorted = samples.sorted()
    let clamped = min(max(p, 0), 1)
    let rank = Int((clamped * Double(sorted.count)).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
}
