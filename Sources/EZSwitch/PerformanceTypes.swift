import Foundation

struct UsagePerformance: Codable, Equatable, Sendable {
    var streaming: Bool
    var ttftMS: Double? = nil
    var requestTTFTMS: Double? = nil
    var generationMS: Double? = nil
    var outputDeltaCount: Int = 0

    /// 单条记录的有效吞吐（token/s）：仅在流式、且已观测到有效 TTFT、输出增量与生成时长都足以支撑时给出。
    /// 有效 TTFT 是本方法的硬前提（与统计口径一致：无 TTFT 的尝试不产生样本）。
    /// 仅用于 CSV / 原始观测导出；聚合统计不再使用逐请求速率（见 `PerformanceSummary`）。
    func tps(outputTokens: Int?) -> Double? {
        guard streaming, let ttftMS, ttftMS.isFinite, ttftMS >= 0, outputDeltaCount >= 2,
              let outputTokens, outputTokens >= 2,
              let generationMS, generationMS.isFinite, generationMS > 0 else { return nil }
        let value = Double(outputTokens) * 1000 / generationMS
        return value.isFinite ? value : nil
    }
}

/// 区间性能摘要。吞吐一律是"总输出 token / 总时长"的加权速率，绝不取逐请求速率的算术平均；
/// TTFT 是有效样本的算术平均。缺失 / 无效一律为 `nil`，绝不伪造成 0。
struct PerformanceSummary: Codable, Sendable {
    var attempts: Int = 0
    var successfulStreamingAttempts: Int = 0
    var ttftSamples: Int = 0
    /// 请求级与上游尝试级计时可能独立缺失，分别统计有效样本。
    var requestTTFTSamples: Int = 0
    /// 三个加权吞吐共用同一"TPS 有效队列"的样本数（含尝试 TTFT、请求 TTFT 与合法生成时长）。
    var tpsSamples: Int = 0
    /// 单次尝试首输出（TTFT）有效样本的算术平均。
    var ttftMeanMS: Double? = nil
    /// 请求级总等待（requestTTFT）有效样本的算术平均。
    var requestTTFTMeanMS: Double? = nil
    /// 加权速率：Σ输出 / Σ(尝试TTFT + 生成时长)。
    var tpsIncludingTTFT: Double? = nil
    /// 加权速率：Σ输出 / Σ(请求TTFT + 生成时长)。
    var requestTpsIncludingTTFT: Double? = nil
    /// 加权速率：Σ输出 / Σ生成时长。
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
