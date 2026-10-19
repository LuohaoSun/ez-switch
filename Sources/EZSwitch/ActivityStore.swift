import Foundation
import Dispatch

// 约束（贯穿本文件与 RouterServer 埋点）：
// - 只存元数据：绝不含请求/响应正文、apiKey、Base URL 或 query。
// - 在途与已完成分离：`active` 不受容量淘汰；只有已完成的快照进入 `recent`（默认 300），
//   超出淘汰最旧的已完成快照。
// - 每次请求恰好一次终结（写入方负责，RouterServer 用 defer 兜底）。
// - `elapsedMS` 用单调时钟实测；`Date` 字段仅用于展示/排序。
// - `reset()` 用于测试隔离。

/// 一次请求的活动状态。`receiving` 表示已开始收到并转发上游响应体，
/// **不代表首字内容已到**（SSE 心跳 / 仅含 role 的帧也算）。
enum ActivityStatus: String, Sendable, Equatable {
    case inFlight
    case receiving
    case succeeded
    case failed
    case cancelled
}

/// 单次上游尝试的结局。
enum ActivityAttemptOutcome: String, Sendable, Equatable {
    case pending
    case success
    /// 上游非 2xx（含可重试状态码）。
    case httpError
    /// 未拿到响应头（DNS/超时/TLS 等）。
    case networkError
    /// 已拿到响应头，响应体传输中途出错。
    case streamError
    case cancelled
    /// 请求在发往上游前被拒（协议转换 / 连接器适配）。
    case clientError
}

/// 一次回退的原因（只带数值/枚举，不带正文）。
enum ActivityFallbackReason: Sendable, Equatable {
    case httpStatus(Int)
    case connectionFailure

    var label: String {
        switch self {
        case .httpStatus(let status): return "HTTP \(status)"
        case .connectionFailure: return "连接失败"
        }
    }
}

struct ActivityAttempt: Sendable, Equatable, Identifiable {
    /// 1-based attempt 序号（同一次请求内唯一）。
    var id: Int
    var remoteID: String
    var provider: String
    var model: String
    /// 展示名（`provider · model`）。
    var label: String
    /// `RemoteSource.rawValue`（如 `api`）。
    var source: String
    /// 本次实际上游协议（Chat 转 Responses 时为 `chat`）。
    var endpoint: String
    var startedAt: Date
    var endedAt: Date?
    /// 单调时钟实测，终结后固定。
    var durationMS: Int?
    var outcome: ActivityAttemptOutcome
    var statusCode: Int?
    /// 短标签原因（如 `HTTP 429`、`NSURLErrorDomain(-1004)`）；无正文/URL/凭据。
    var reason: String?
    var tokens: UsageTokens
    var performance: UsagePerformance?
}

struct ActivityFallback: Sendable, Equatable, Identifiable {
    /// 1-based 事件序号（同一次请求内唯一）。
    var id: Int
    var from: String
    var to: String
    var reason: ActivityFallbackReason
    var at: Date
}

struct ActivityRequest: Sendable, Equatable, Identifiable {
    /// 与 `UsageRecord.requestID` 同源。
    var id: UUID
    /// 客户端请求的 fake model id。
    var route: String
    /// 展示名（displayName；空则回退 fakeModelID）。
    var routeName: String
    /// 入站协议（`EndpointKind.rawValue`）。
    var endpoint: String
    var method: String
    var startedAt: Date
    var endedAt: Date?
    var status: ActivityStatus
    /// 单调时钟实测总耗时；在途请求在每次 `snapshot()` 时按“现在”重算。
    var elapsedMS: Int
    /// 终态口径（与 `UsageRecord.outcome` 一致）；在途为 nil。
    var outcome: String?
    var statusCode: Int?
    var failureReason: String?
    /// 首个上游响应字节开始转发的时刻（含心跳/role 帧），非首字内容。
    var firstResponseAt: Date?
    /// 最终选中的 attempt 序号；nil = 未选中任何候选（失败/纯回退），UI 可退而展示 `attempts.last`。
    var selectedAttempt: Int?
    /// 按 attempt 升序。
    var attempts: [ActivityAttempt]
    /// 按发生顺序。
    var fallbacks: [ActivityFallback]
    /// 选中 attempt 的 token（在途时可能已观测到部分）。
    var tokens: UsageTokens
    var performance: UsagePerformance?
}

/// 一次 `snapshot()` 的结果：在途请求在前，其后是已完成请求，各自内部按最新优先。
struct ActivitySnapshot: Sendable, Equatable {
    var generatedAt: Date
    var activeCount: Int
    var capacity: Int
    var evictedCount: Int
    var requests: [ActivityRequest]
}

struct ActivityRequestStart: Sendable {
    var requestID: UUID
    var route: String
    var routeName: String
    var endpoint: String
    var method: String
    var startedAt: Date
}

struct ActivityAttemptStart: Sendable {
    var requestID: UUID
    var attempt: Int
    var remoteID: String
    var provider: String
    var model: String
    var label: String
    var source: String
    var endpoint: String
    var startedAt: Date
}

/// 线程安全、有界的内存活动存储。写入在私有锁下完成（不在热路径做重活）；
/// 任一状态变化后发布 `didChangeNotification`（不带负载），观察者再取 `snapshot()`。
final class ActivityStore: @unchecked Sendable {

    static let shared = ActivityStore()

    static let defaultCapacity = 300

    /// 只发信号，不携带任何记录/正文/凭据；在写入线程同步发出，观察者自行切回主线程。
    static let didChangeNotification = Notification.Name("com.ezswitch.activity-store.did-change")

    /// 防止异常配置无限撑大单个请求的快照。
    static let maxAttempts = 64
    static let maxFallbacks = 64

    private struct Record {
        var request: ActivityRequest
        let startedMonotonic: DispatchTime
        var attemptMonotonic: [Int: DispatchTime]
    }

    private let capacity: Int
    private let clock: @Sendable () -> DispatchTime
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()

    // 仅在 `lock` 上访问。
    private var active: [UUID: Record] = [:]
    private var recent: [Record] = []
    private var evicted = 0

    /// - Parameter capacity: 已完成快照上限（至少 1）。
    /// - Parameter clock: 单调时钟，测试可注入以确定 elapsed。
    init(capacity: Int = ActivityStore.defaultCapacity,
         clock: @escaping @Sendable () -> DispatchTime = { DispatchTime.now() },
         notificationCenter: NotificationCenter = .default) {
        self.capacity = max(1, capacity)
        self.clock = clock
        self.notificationCenter = notificationCenter
    }

    // MARK: - 写入

    /// 开始一次请求。requestID 已在 active 或 recent 中的重复 start 被忽略
    /// （后者避免已完成请求被同 ID 复活；已淘汰的 ID 除外）。
    func start(_ start: ActivityRequestStart) {
        lock.lock()
        let isDuplicate = active[start.requestID] != nil
            || recent.contains { $0.request.id == start.requestID }
        if !isDuplicate {
            let request = ActivityRequest(id: start.requestID,
                                          route: start.route, routeName: start.routeName,
                                          endpoint: start.endpoint, method: start.method,
                                          startedAt: start.startedAt, endedAt: nil,
                                          status: .inFlight, elapsedMS: 0, outcome: nil,
                                          statusCode: nil, failureReason: nil,
                                          firstResponseAt: nil, selectedAttempt: nil,
                                          attempts: [], fallbacks: [],
                                          tokens: UsageTokens(), performance: nil)
            active[start.requestID] = Record(request: request, startedMonotonic: clock(),
                                             attemptMonotonic: [:])
        }
        lock.unlock()
        if !isDuplicate { postDidChange() }
    }

    /// 开始一次上游尝试。重复 attempt 序号或超上限被忽略。
    func startAttempt(_ start: ActivityAttemptStart) {
        lock.lock()
        var changed = false
        if var record = active[start.requestID],
           !record.request.attempts.contains(where: { $0.id == start.attempt }),
           record.request.attempts.count < Self.maxAttempts {
            record.request.attempts.append(ActivityAttempt(id: start.attempt,
                                                          remoteID: start.remoteID,
                                                          provider: start.provider,
                                                          model: start.model, label: start.label,
                                                          source: start.source, endpoint: start.endpoint,
                                                          startedAt: start.startedAt, endedAt: nil,
                                                          durationMS: nil, outcome: .pending,
                                                          statusCode: nil, reason: nil,
                                                          tokens: UsageTokens(), performance: nil))
            record.attemptMonotonic[start.attempt] = clock()
            active[start.requestID] = record
            changed = true
        }
        lock.unlock()
        if changed { postDidChange() }
    }

    /// 终结一次上游尝试。只终结仍为 `pending` 的尝试，重复终结不会覆盖已测时长/结局。
    func finishAttempt(requestID: UUID, attempt: Int, outcome: ActivityAttemptOutcome,
                       statusCode: Int?, reason: String?, tokens: UsageTokens,
                       performance: UsagePerformance?, at: Date) {
        lock.lock()
        var changed = false
        if var record = active[requestID],
           let index = record.request.attempts.firstIndex(where: { $0.id == attempt }),
           record.request.attempts[index].outcome == .pending {
            var updated = record.request.attempts[index]
            updated.outcome = outcome
            updated.statusCode = statusCode
            updated.reason = Self.shortReason(reason)
            updated.tokens = tokens
            updated.performance = performance
            updated.endedAt = at
            if let start = record.attemptMonotonic[attempt] {
                updated.durationMS = Self.elapsedMS(from: start, to: clock())
            }
            record.request.attempts[index] = updated
            active[requestID] = record
            changed = true
        }
        lock.unlock()
        if changed { postDidChange() }
    }

    /// 兜底：把所有仍为 `pending` 的尝试一并终结（取消 / 提前 return 的保护路径），
    /// 避免详情长期停留在 pending。已终结的尝试不受影响。
    func finishPendingAttempts(requestID: UUID, outcome: ActivityAttemptOutcome, at: Date) {
        guard outcome != .pending else { return }
        lock.lock()
        var changed = false
        if var record = active[requestID] {
            let now = clock()
            for index in record.request.attempts.indices
            where record.request.attempts[index].outcome == .pending {
                var updated = record.request.attempts[index]
                updated.outcome = outcome
                updated.endedAt = at
                if let start = record.attemptMonotonic[updated.id] {
                    updated.durationMS = Self.elapsedMS(from: start, to: now)
                }
                record.request.attempts[index] = updated
                changed = true
            }
            if changed { active[requestID] = record }
        }
        lock.unlock()
        if changed { postDidChange() }
    }

    /// 首个上游响应字节开始转发（可能是 SSE 心跳 / 仅 role 帧）。只生效一次。
    func responseStarted(requestID: UUID, at: Date) {
        lock.lock()
        var changed = false
        if var record = active[requestID], record.request.firstResponseAt == nil {
            record.request.firstResponseAt = at
            if record.request.status == .inFlight { record.request.status = .receiving }
            active[requestID] = record
            changed = true
        }
        lock.unlock()
        if changed { postDidChange() }
    }

    /// 记录一次回退，绝不终结请求：请求保持 inFlight/receiving 直到显式 `finish`。
    func fallback(requestID: UUID, from: String, to: String,
                  reason: ActivityFallbackReason, at: Date) {
        lock.lock()
        var changed = false
        if var record = active[requestID], record.request.fallbacks.count < Self.maxFallbacks {
            let id = (record.request.fallbacks.last?.id ?? 0) + 1
            record.request.fallbacks.append(ActivityFallback(id: id, from: from, to: to,
                                                            reason: reason, at: at))
            active[requestID] = record
            changed = true
        }
        lock.unlock()
        if changed { postDidChange() }
    }

    /// 终结一次请求并移入已完成列表。只接受终态（succeeded/failed/cancelled）：
    /// 在途状态一律忽略，防止在途请求被移入 recent。重复终结（已不在 active）忽略。
    func finish(requestID: UUID, status: ActivityStatus, outcome: String?, statusCode: Int?,
                reason: String?, selectedAttempt: Int?, tokens: UsageTokens,
                performance: UsagePerformance?, at: Date) {
        guard Self.isTerminal(status) else { return }
        lock.lock()
        var changed = false
        if var record = active.removeValue(forKey: requestID) {
            record.request.status = status
            record.request.outcome = outcome
            record.request.statusCode = statusCode
            record.request.failureReason = Self.shortReason(reason)
            if let selectedAttempt { record.request.selectedAttempt = selectedAttempt }
            record.request.tokens = tokens
            record.request.performance = performance
            record.request.endedAt = at
            record.request.elapsedMS = Self.elapsedMS(from: record.startedMonotonic, to: clock())
            recent.insert(record, at: 0)
            while recent.count > capacity {
                recent.removeLast()
                evicted += 1
            }
            changed = true
        }
        lock.unlock()
        if changed { postDidChange() }
    }

    // MARK: - 读取

    /// 在途请求的 `elapsedMS` 按调用时刻重算；已完成请求的耗时已固定。
    func snapshot() -> ActivitySnapshot {
        lock.lock()
        let now = clock()
        let activeRequests = active.values.map { record -> ActivityRequest in
            var request = record.request
            request.elapsedMS = Self.elapsedMS(from: record.startedMonotonic, to: now)
            return request
        }
        let recentRequests = recent.map(\.request)
        let activeCount = activeRequests.count
        lock.unlock()

        return ActivitySnapshot(generatedAt: Date(),
                                activeCount: activeCount,
                                capacity: capacity,
                                evictedCount: evicted,
                                requests: Self.newestFirst(activeRequests)
                                    + Self.newestFirst(recentRequests))
    }

    /// 清空全部状态（含淘汰计数）。仅供测试隔离。
    func reset() {
        lock.lock()
        active.removeAll()
        recent.removeAll()
        evicted = 0
        lock.unlock()
        postDidChange()
    }

    // MARK: - 内部

    private static func isTerminal(_ status: ActivityStatus) -> Bool {
        switch status {
        case .succeeded, .failed, .cancelled: return true
        case .inFlight, .receiving: return false
        }
    }

    private static func newestFirst(_ requests: [ActivityRequest]) -> [ActivityRequest] {
        requests.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// 单调时钟实测毫秒；时钟回拨/相等为 0，绝不返回负数或溢出。
    private static func elapsedMS(from start: DispatchTime, to now: DispatchTime) -> Int {
        let startNanos = start.uptimeNanoseconds
        let nowNanos = now.uptimeNanoseconds
        guard nowNanos > startNanos else { return 0 }
        let millis = (nowNanos - startNanos) / 1_000_000
        return millis > UInt64(Int.max) ? Int.max : Int(millis)
    }

    /// 仅裁剪长度与空白：调用方必须只传短标签，不得传正文/URL/凭据。
    private static func shortReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(400))
    }

    private func postDidChange() {
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }
}
