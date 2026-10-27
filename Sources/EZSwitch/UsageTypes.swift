import Foundation

// 上游计数不可信；超出显示范围时饱和，不能让统计页面整数溢出崩溃。
private func usageTotal(_ input: Int, _ output: Int) -> Int {
    let (sum, overflow) = input.addingReportingOverflow(output)
    return overflow ? Int.max : sum
}

struct UsageTokens: Codable, Equatable, Sendable {
    var input: Int? = nil
    var output: Int? = nil
    var cachedInput: Int? = nil
    var cacheWrite: Int? = nil
    var reasoning: Int? = nil

    var isComplete: Bool { input != nil && output != nil }
    var total: Int { usageTotal(input ?? 0, output ?? 0) }
}

struct UsageRecord: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var requestID: UUID
    var timestamp: Date
    var routeID: String
    var routeName: String
    var remoteID: String
    var provider: String
    var model: String
    var endpoint: String
    var attempt: Int
    var status: Int?
    var outcome: String
    var durationMS: Int
    var tokens: UsageTokens

    /// 可选的流式性能采样（TTFT、生成时长、输出增量计数）。
    /// 旧的构造点与历史解码记录没有该字段；保持 `nil`，旧记录全部视为无性能数据。
    var performance: UsagePerformance? = nil
}

enum UsageGrouping: String, CaseIterable, Identifiable, Sendable {
    case route, provider, model
    var id: String { rawValue }
    var title: String {
        switch self {
        case .route: return "路由"
        case .provider: return "供应商"
        case .model: return "模型"
        }
    }
}

struct UsageTotals: Sendable {
    var input: Int = 0
    var output: Int = 0
    var cachedInput: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0
    var requests: Int = 0
    var attempts: Int = 0
    var knownAttempts: Int = 0
    var inputAttempts: Int = 0
    var outputAttempts: Int = 0
    var cachedInputAttempts: Int = 0
    var failedAttempts: Int = 0
    var total: Int { usageTotal(input, output) }
    var coverage: Double { attempts == 0 ? 0 : Double(knownAttempts) / Double(attempts) }
}

struct UsageDay: Identifiable, Sendable {
    var date: Date
    var input: Int
    var output: Int
    /// 该分桶内去重后的请求数（同一请求的多次回退尝试只计一次）。
    var requests: Int = 0
    var id: Date { date }
}

struct UsageGroupRow: Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var totals: UsageTotals
}

struct UsageSnapshot: Sendable {
    var totals = UsageTotals()
    var days: [UsageDay] = []
    /// 本地日历小时分桶；仅在 `snapshot(includeHourly: true)` 时填充。
    var hours: [UsageDay] = []
    var groups: [UsageGroupRow] = []
}
