import SwiftUI
import AppKit
import Foundation

/// 有界展示上限：流向图不随并发无限增长，超出部分以「剩余数量」提示。
enum ActivityLimits {
    static let graphRequests = 6

    /// 终态节点在图上驻留时长（自真实 `endedAt` 起算，不随刷新延长）：
    /// 已完成请求不立刻消失，保留 5s 让用户看清去向与最终状态。
    static let residentDuration: TimeInterval = 5
}

/// 活动页展示用的入站协议，对应后端 `ActivityRequest.endpoint`（EndpointKind.rawValue）。
enum ActivityProtocolKind: String, Identifiable, CaseIterable {
    case chat, responses, messages, gemini

    var id: String { rawValue }

    var badgeTitle: String {
        switch self {
        case .chat: return "Chat"
        case .responses: return "Responses"
        case .messages: return "Messages"
        case .gemini: return "Gemini"
        }
    }
}

/// 请求级状态，镜像后端 `ActivityStatus`。
/// `.receiving` 表示已开始收到并转发上游响应字节，**不代表首字内容已到**。
enum ActivityPhase: Equatable {
    case inFlight
    case receiving
    case succeeded
    case failed
    case cancelled

    var isActive: Bool { self == .inFlight || self == .receiving }
}

/// 单次上游尝试的结局（UI 侧），镜像后端 `ActivityAttemptOutcome`；单独命名避免同名冲突。
enum ActivityAttemptResult: Equatable {
    case pending
    case success
    case httpError
    case networkError
    case streamError
    case cancelled
    case clientError

    var isFailure: Bool {
        switch self {
        case .success, .pending: return false
        case .httpError, .networkError, .streamError, .cancelled, .clientError: return true
        }
    }
}

/// 状态色调；浅深色由 palette 动态色负责。
enum ActivityTone: Equatable {
    case neutral, ok, warn, fail, active

    var color: Color {
        switch self {
        case .neutral: return Color.secondary
        case .ok: return ActivityPalette.ok
        case .warn: return ActivityPalette.warn
        case .fail: return ActivityPalette.fail
        case .active: return ActivityPalette.active
        }
    }
}

/// 活动页格式化：未报告一律「—」，绝不伪造 0。
enum ActivityFormat {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    static func tokens(_ value: Int?) -> String {
        guard let value else { return "—" }
        return UsageFormat.exact(value)
    }

    /// 表格 token 列：极长数字退化为 compact，避免窄列撑破。
    static func tokenCell(_ value: Int?) -> String {
        guard let value else { return "—" }
        let exact = UsageFormat.exact(value)
        return exact.count <= 7 ? exact : UsageFormat.compact(value)
    }

    static func seconds(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.1f s", value)
    }

    /// 请求表首字列：短等待用毫秒保留精度，超过 1 秒退化为秒。
    static func ttft(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value < 1000 { return String(format: "%.0f ms", value) }
        return String(format: "%.1f s", value / 1000)
    }

    /// 请求表吞吐列：保留一位小数；非有限 / 负数视为未知。
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.1f", value)
    }

    /// 耗时统一取后端单调时钟 `elapsedMS`，不用 Date 差值，避免系统时钟跳变。
    static func elapsed(ms: Int) -> String {
        let interval = Double(max(0, ms)) / 1000
        if interval < 60 { return String(format: "%.1f s", interval) }
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 一次上游尝试（已脱敏，不含正文 / 凭据）。
struct ActivityAttemptModel: Identifiable, Equatable {
    var attempt: Int
    var provider: String
    var model: String
    var label: String
    var statusCode: Int?
    var outcome: ActivityAttemptResult
    var durationMS: Int?
    var tokens: UsageTokens = UsageTokens()
    var ttftMS: Double? = nil
    var reason: String? = nil

    var id: Int { attempt }

    /// 该次尝试是否报告了用量（input 与 output 都已知）。
    var reportedTokens: Bool { tokens.input != nil && tokens.output != nil }

    var displayProvider: String { provider.isEmpty ? label : provider }

    var statusPhrase: String { ActivityStatusPhrase.phrase(statusCode: statusCode, outcome: outcome) }

    var statusLabel: String {
        guard let statusCode else { return outcome == .cancelled ? "已取消" : "无响应" }
        return "\(statusCode)"
    }

    /// 回退链中的一段：如「OpenAI 限流（429，0.8 s）」。
    var chainPhrase: String {
        "\(displayProvider) \(statusPhrase)（\(statusLabel)，\(ActivityFormat.elapsed(ms: durationMS ?? 0))）"
    }
}

/// 尝试结局 / 状态码 → 中文短语。outcome 优先于状态码：响应头 2xx 但传输中断不会被说成成功。
enum ActivityStatusPhrase {
    static func phrase(statusCode: Int?, outcome: ActivityAttemptResult) -> String {
        switch outcome {
        case .cancelled: return "已取消"
        case .streamError: return "传输中断"
        case .networkError: return "连接失败"
        case .clientError: return "请求无效"
        case .pending: return statusCode.map(phrase(for:)) ?? "等待响应"
        case .success, .httpError: break
        }
        if let code = statusCode { return phrase(for: code) }
        return outcome == .success ? "成功" : "无响应"
    }

    private static func phrase(for code: Int) -> String {
        switch code {
        case 200..<300: return "成功"
        case 400: return "请求无效"
        case 401, 403: return "鉴权失败"
        case 404: return "未找到"
        case 408: return "超时"
        case 429: return "限流"
        case 500: return "服务器错误"
        case 502: return "网关错误"
        case 503: return "服务不可用"
        case 504: return "网关超时"
        case 500..<600: return "上游错误"
        case 400..<500: return "被拒绝"
        default: return "异常"
        }
    }
}

/// 活动页请求行（只读 UI 模型），全部派生自后端快照。
struct ActivityRowModel: Identifiable, Equatable {
    var id: UUID
    var shortID: String = ""
    var startedAt: Date
    var endedAt: Date? = nil
    var protocolKind: ActivityProtocolKind
    var routeName: String
    var phase: ActivityPhase
    var upstreamProvider: String? = nil
    var upstreamModel: String? = nil
    var selectedAttempt: Int? = nil
    var attempts: [ActivityAttemptModel] = []
    var didFallback: Bool = false
    var tokens: UsageTokens = UsageTokens()
    var performance: UsagePerformance? = nil
    var failureReason: String? = nil
    var statusCode: Int? = nil
    var outcome: String? = nil
    var elapsedMS: Int = 0

    var isActive: Bool { phase.isActive }

    /// 是否仍在图上驻留的终态：已完成/失败/取消，且 `endedAt` 距参考时刻不足 `window`。
    /// 参考时刻取快照 `generatedAt`，因此驻留时长依真实 `endedAt` 起算、不随刷新延长；
    /// 暂停时快照时间冻结，节点也不会消失。
    func isResidentTerminal(asOf now: Date, within window: TimeInterval) -> Bool {
        guard !isActive, let endedAt else { return false }
        return now.timeIntervalSince(endedAt) < window
    }

    /// 上游去重键（供应商 + 模型），流向图右列按它归并。
    var upstreamKey: String? {
        guard let provider = upstreamProvider, let model = upstreamModel,
              !provider.isEmpty || !model.isEmpty else { return nil }
        return "\(provider)\u{1F}\(model)"
    }

    /// 是否解析到上游（供应商或模型至少一个非空）。
    var hasUpstream: Bool { upstreamKey != nil }

    var statusText: String {
        switch phase {
        case .inFlight: return "等待响应"
        case .receiving: return "接收响应"
        case .succeeded: return didFallback ? "✓ 回退成功" : "✓ 已完成"
        case .failed: return "! 失败"
        case .cancelled: return "已取消"
        }
    }

    var tone: ActivityTone {
        switch phase {
        case .inFlight: return .neutral
        case .receiving: return .active
        case .succeeded: return didFallback ? .warn : .ok
        case .failed: return .fail
        case .cancelled: return .neutral
        }
    }

    var identityModelText: String {
        if let provider = upstreamProvider, let model = upstreamModel, !provider.isEmpty || !model.isEmpty {
            return provider.isEmpty ? model : "\(provider) · \(model)"
        }
        return "未绑定上游"
    }

    var durationText: String { ActivityFormat.elapsed(ms: elapsedMS) }

    /// 请求级性能明细：只有成功完成的请求才展示最终值。
    /// 进行中、失败、取消、非流式或数据不足一律为 nil（表格显示「—」）。
    var requestPerformanceDetail: RequestPerformanceDetail? {
        guard phase == .succeeded else { return nil }
        return performance?.requestDetail(outputTokens: tokens.output)
    }

    var ttftText: String { ActivityFormat.ttft(requestPerformanceDetail?.ttftMS) }
    var tpsIncludingTTFTText: String { ActivityFormat.rate(requestPerformanceDetail?.tpsIncludingTTFT) }

    /// 流向图请求节点状态短语：只是 `statusText` 去掉对勾 / 叹号的紧凑版，同样只陈述快照已观测的阶段。
    /// 命中回退（有回退记录或多次尝试）时明确标注「回退后」；快照没有「正在切换上游」的实时证据，因此不这么写。
    var graphStatusText: String {
        switch phase {
        case .inFlight: return didFallback ? "回退后等待" : "等待响应"
        case .receiving: return didFallback ? "回退后接收" : "接收响应"
        case .succeeded: return didFallback ? "回退成功" : "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    /// 流向图左侧请求节点第二行：`#短ID · 当前状态 · 耗时`。
    /// 耗时沿用后端单调时钟 `elapsedMS`（`durationText`），进行中请求由快照按调用时刻重算。
    var graphNodeSubtitle: String { "#\(shortID) · \(graphStatusText) · \(durationText)" }

    /// 回退链：多次尝试时把每段串起来。
    var attemptChainText: String? {
        guard attempts.count > 1 else { return nil }
        return attempts.map(\.chainPhrase).joined(separator: " → ")
    }

    /// 用量覆盖说明：表中 token 来自哪次尝试、此前哪次未报告。
    var coverageNote: String? {
        guard let selected = selectedAttempt, selected > 1 else { return nil }
        let missing = attempts.filter { $0.attempt < selected && !$0.reportedTokens }.map(\.attempt)
        guard !missing.isEmpty else { return nil }
        return "第 \(missing.map(String.init).joined(separator: "、")) 次尝试未报告用量；表中 token 来自第 \(selected) 次尝试。"
    }

    /// 展开详情文本行；只陈述已观测字段，未报告的不出现。
    var detailLines: [String] {
        var lines: [String] = []
        switch phase {
        case .inFlight:
            lines.append("请求已发送 · 正在等待上游响应。")
        case .receiving:
            lines.append(didFallback
                ? "回退后上游已开始返回响应，正在转发（可能仍是心跳 / 非正文帧）。"
                : "上游已开始返回响应，正在转发（可能仍是心跳 / 非正文帧）。")
        case .succeeded:
            lines.append(attemptChainText ?? "1 次尝试，上游已完成响应。")
        case .failed:
            if didFallback, let chain = attemptChainText {
                lines.append(chain + "；候选耗尽。")
            } else if let reason = failureReason, !reason.isEmpty {
                lines.append("\(reason)；没有可用后备。")
            } else {
                lines.append("上游请求失败，没有可用后备。")
            }
        case .cancelled:
            lines.append("请求已取消。")
        }

        var metrics: [String] = []
        if let cached = tokens.cachedInput, cached > 0 {
            metrics.append("输入中缓存命中 \(ActivityFormat.tokens(cached))")
        }
        if let write = tokens.cacheWrite, write > 0 {
            metrics.append("缓存写入 \(ActivityFormat.tokens(write))")
        }
        if let reasoning = tokens.reasoning, reasoning > 0 {
            metrics.append("输出中 reasoning \(ActivityFormat.tokens(reasoning))")
        }
        // TTFT 只取 performance 的真实首字度量，绝不用 firstResponseAt（首个字节）代替。
        if let ttft = performance?.requestTTFTMS ?? performance?.ttftMS {
            metrics.append("首字 \(ActivityFormat.seconds(ttft / 1000))")
        }
        if attempts.count > 1 { metrics.append("\(attempts.count) 次尝试") }
        if !metrics.isEmpty { lines.append(metrics.joined(separator: " · ")) }

        if let note = coverageNote { lines.append(note) }
        if phase == .failed, tokens.input == nil, tokens.output == nil {
            lines.append("未收到上游用量报告。")
        }
        return lines
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if shortID.localizedCaseInsensitiveContains(needle) { return true }
        if routeName.localizedCaseInsensitiveContains(needle) { return true }
        if protocolKind.badgeTitle.localizedCaseInsensitiveContains(needle) { return true }
        if let provider = upstreamProvider, provider.localizedCaseInsensitiveContains(needle) { return true }
        if let model = upstreamModel, model.localizedCaseInsensitiveContains(needle) { return true }
        return false
    }

    /// 由稳定 UUID 派生 4 位短 ID（同一 requestID 恒定，不随刷新变化）。
    static func shortID(for id: UUID) -> String {
        String(id.uuidString.prefix(4)).uppercased()
    }
}

/// 图 → 表联动高亮：只影响图上强调与列表行底色，不改动列表内容（列表只由搜索词过滤）。
enum ActivitySelection: Equatable {
    case request(UUID)
    case upstream(String)
}

/// 稳定 palette：颜色由请求身份（UUID）决定而非每帧数组下标；
/// 同一请求左右两条连线同色，同时刻的进行中请求在容量内取不同颜色。
enum ActivityPalette {
    static let colors: [Color] = [
        dynamic(0x3069BB, 0x8DB7F0),
        dynamic(0x2F7F73, 0x8FD0C4),
        dynamic(0x7E5CAA, 0xC4A6E9),
        dynamic(0x946214, 0xE5BC7B),
        dynamic(0xA64A78, 0xEBA6C4),
        dynamic(0x3D6B3D, 0x9ECF9E),
        dynamic(0x8A5A2B, 0xD8B48A),
        dynamic(0x4A50A8, 0xA6ABE9),
    ]

    static var count: Int { colors.count }

    static let ok = dynamic(0x397249, 0x95CAA2)
    static let warn = dynamic(0x946214, 0xE5BC7B)
    static let fail = dynamic(0xB74949, 0xEC9999)
    static let active = dynamic(0x3069BB, 0x8DB7F0)

    static func color(forSlot slot: Int) -> Color {
        let n = count
        guard n > 0 else { return .accentColor }
        return colors[((slot % n) + n) % n]
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(activityRGB: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(activityRGB rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

/// 为图上可见请求分配 palette 槽位；同一请求跨刷新保持同色。
/// 传入既包含在途、也包含驻留终态（active → terminal 过渡期间 ID 不变），
/// 因此请求完成驻留时颜色不跳变；只有彻底离开图（驻留到期 / 被淘汰）后才释放槽位供新请求复用。
struct ActivityColorAssigner {
    private(set) var slots: [UUID: Int] = [:]

    mutating func assign(ids: [UUID]) -> [UUID: Int] {
        let wanted = Set(ids)
        slots = slots.filter { wanted.contains($0.key) }
        var used = Set(slots.values)
        for id in ids where slots[id] == nil {
            let slot = (0..<ActivityPalette.count).first { !used.contains($0) }
                ?? (slots.count % max(ActivityPalette.count, 1))
            slots[id] = slot
            used.insert(slot)
        }
        return slots
    }
}

/// 活动页状态。纯轮询快照；暂停时冻结展示。
@MainActor
final class ActivityViewModel: ObservableObject {
    @Published private(set) var rows: [ActivityRowModel] = []
    @Published var query: String = ""
    @Published var paused: Bool = false
    @Published private(set) var selection: ActivitySelection?
    @Published private(set) var activeCount: Int = 0
    @Published private(set) var capacity: Int = 0
    @Published private(set) var evictedCount: Int = 0
    /// 展开详情的请求集合。放在 ObservableObject 上，避开仅 CLT 环境下 `@State` 宏不可用。
    @Published private(set) var expandedIDs: Set<UUID> = []

    private var timer: Timer?
    private var assigner = ActivityColorAssigner()
    private var colorSlots: [UUID: Int] = [:]
    /// 最近一次快照的生成时刻；终态驻留以它为参考（暂停时冻结，恢复后按新快照计算）。
    private var generatedAt: Date = Date()

    private let pollInterval: TimeInterval = 1

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    /// 暂停时只冻结展示，恢复即取到最新数据。
    func refresh() {
        guard !paused else { return }
        refreshFromStore()
    }

    func togglePause() {
        paused.toggle()
        if !paused { refresh() }
    }

    func ingest(rows: [ActivityRowModel], activeCount: Int,
                capacity: Int = 0, evictedCount: Int = 0,
                generatedAt: Date = Date()) {
        let sorted = rows.sorted(by: Self.newestFirst)
        self.rows = sorted
        self.activeCount = activeCount
        self.capacity = capacity
        self.evictedCount = evictedCount
        self.generatedAt = generatedAt
        // 槽位覆盖 active + 驻留终态：请求完成驻留时 ID 不变，颜色不跳变。
        colorSlots = assigner.assign(ids: graphCandidateRows.map(\.id))
    }

    private static func newestFirst(_ a: ActivityRowModel, _ b: ActivityRowModel) -> Bool {
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        return a.id.uuidString > b.id.uuidString
    }

    /// 流向图用：进行中请求按开始时间升序（旧 → 新），新请求追加在下方，位置稳定不抖动。
    var activeRows: [ActivityRowModel] {
        rows.filter { $0.isActive }.sorted(by: Self.oldestFirst)
    }

    private static func oldestFirst(_ a: ActivityRowModel, _ b: ActivityRowModel) -> Bool {
        if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// 图上候选：进行中请求 + 驻留中的终态（`endedAt` 距快照时刻不足 `residentDuration`）。
    /// 统一按开始时间升序，因此请求 active → terminal 时位置不跳变（同一请求开始时间不变）。
    private var graphCandidateRows: [ActivityRowModel] {
        let now = generatedAt
        return rows
            .filter { $0.isActive || $0.isResidentTerminal(asOf: now, within: ActivityLimits.residentDuration) }
            .sorted(by: Self.oldestFirst)
    }

    /// 图上展示顺序：候选不超过上限时按开始时间升序（位置稳定）；
    /// 超过上限时进行中请求优先展示（两段内部仍按开始时间升序），避免终态挤掉在途节点。
    var graphRows: [ActivityRowModel] {
        let candidates = graphCandidateRows
        guard candidates.count > ActivityLimits.graphRequests else { return candidates }
        return candidates.filter { $0.isActive } + candidates.filter { !$0.isActive }
    }

    /// 图上前 `graphRequests` 个节点。
    var graphShownRows: [ActivityRowModel] {
        Array(graphRows.prefix(ActivityLimits.graphRequests))
    }

    /// 未在图中展示的候选（含在途与刚结束）。
    var graphOverflowRows: [ActivityRowModel] {
        Array(graphRows.dropFirst(ActivityLimits.graphRequests))
    }

    /// 图上未展示的数量。
    var graphOverflowCount: Int { graphOverflowRows.count }

    /// 图溢出提示：区分在途 / 刚结束，避免把驻留终态误报为仍在进行。
    var graphOverflowText: String? {
        let overflow = graphOverflowRows
        guard !overflow.isEmpty else { return nil }
        let active = overflow.filter { $0.isActive }.count
        let resident = overflow.count - active
        switch (active, resident) {
        case (let a, 0): return "另有 \(a) 条在途请求未在图中展示。"
        case (0, let r): return "另有 \(r) 条刚结束的请求未在图中展示。"
        default: return "另有 \(active + resident) 条请求未在图中展示（\(active) 在途，\(resident) 刚结束）。"
        }
    }

    /// 列表可见行：只由搜索词决定；图上的高亮不增删行。
    var visibleRows: [ActivityRowModel] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return rows }
        return rows.filter { $0.matches(query) }
    }

    var statusSummary: String {
        if paused { return "显示已暂停" }
        let head = activeCount > 0 ? "\(activeCount) 个请求进行中" : "当前没有进行中的请求"
        return "\(head) · 最近 \(rows.count) 条"
    }

    /// 当前高亮对象说明（仅提示，不改动列表内容）。
    var highlightLabel: String? {
        switch selection {
        case .none:
            return nil
        case .request(let id):
            let short = rows.first(where: { $0.id == id })?.shortID ?? ActivityRowModel.shortID(for: id)
            return "· 已高亮 请求 #\(short)"
        case .upstream(let key):
            let row = rows.first(where: { $0.upstreamKey == key })
            let text = row?.identityModelText ?? ""
            return text.isEmpty ? "· 已高亮上游" : "· 已高亮 \(text)"
        }
    }

    func color(for id: UUID) -> Color {
        if let slot = colorSlots[id] { return ActivityPalette.color(forSlot: slot) }
        return ActivityPalette.color(forSlot: id.hashValue)
    }

    func isUpstreamSelected(_ key: String) -> Bool { selection == .upstream(key) }

    func toggle(request id: UUID) {
        selection = selection == .request(id) ? nil : .request(id)
    }

    func toggle(upstream key: String) {
        selection = selection == .upstream(key) ? nil : .upstream(key)
    }

    func clearSelection() { selection = nil }

    func isExpanded(_ id: UUID) -> Bool { expandedIDs.contains(id) }

    func toggleExpanded(_ id: UUID) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }

    /// 某请求是否与当前选择相关（不被灰化）。
    func isRequestRelated(_ row: ActivityRowModel) -> Bool {
        switch selection {
        case .none: return true
        case .request(let id): return row.id == id
        case .upstream(let key): return row.upstreamKey == key
        }
    }

    /// 列表行是否应加高亮底色：无高亮对象时不加；上游高亮时其关联请求行同样高亮。
    func isRowHighlighted(_ row: ActivityRowModel) -> Bool {
        guard selection != nil else { return false }
        return isRequestRelated(row)
    }

    /// 某上游节点是否与当前选择相关。
    func isUpstreamRelated(_ key: String) -> Bool {
        switch selection {
        case .none: return true
        case .upstream(let selected): return selected == key
        case .request(let id): return rows.first(where: { $0.id == id })?.upstreamKey == key
        }
    }

    /// 复制当前可见列表为纯文本（不含正文 / 凭据）。
    func copyText() -> String {
        visibleRows.map { row in
            [
                ActivityFormat.time(row.startedAt),
                row.protocolKind.badgeTitle,
                row.routeName,
                row.identityModelText,
                row.statusText,
                "\(ActivityFormat.tokenCell(row.tokens.input))/\(ActivityFormat.tokenCell(row.tokens.output))",
                row.durationText,
            ].joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

// MARK: - 后端接入缝（唯一引用 ActivityStore 的地方）

extension ActivityViewModel {
    func refreshFromStore() {
        apply(ActivityStore.shared.snapshot())
    }

    func apply(_ snapshot: ActivitySnapshot) {
        ingest(rows: snapshot.requests.map(ActivityRowModel.init(request:)),
               activeCount: snapshot.activeCount,
               capacity: snapshot.capacity,
               evictedCount: snapshot.evictedCount,
               generatedAt: snapshot.generatedAt)
    }
}

extension ActivityRowModel {
    /// 由后端 `ActivityRequest` 构造 UI 行；只读已观测字段，不做推测。
    init(request: ActivityRequest) {
        let current = request.attempts.last(where: { $0.id == request.selectedAttempt })
            ?? request.attempts.last
        self.init(
            id: request.id,
            shortID: ActivityRowModel.shortID(for: request.id),
            startedAt: request.startedAt,
            endedAt: request.endedAt,
            protocolKind: ActivityProtocolKind(rawValue: request.endpoint) ?? .chat,
            routeName: request.routeName.isEmpty ? request.route : request.routeName,
            phase: ActivityPhase(request.status),
            upstreamProvider: current?.provider,
            upstreamModel: current?.model,
            selectedAttempt: request.selectedAttempt,
            attempts: request.attempts.map(ActivityAttemptModel.init(attempt:)),
            didFallback: !request.fallbacks.isEmpty || request.attempts.count > 1,
            tokens: request.tokens,
            performance: request.performance,
            failureReason: request.failureReason,
            statusCode: request.statusCode,
            outcome: request.outcome,
            elapsedMS: request.elapsedMS
        )
    }
}

extension ActivityPhase {
    init(_ status: ActivityStatus) {
        switch status {
        case .inFlight: self = .inFlight
        case .receiving: self = .receiving
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }
}

extension ActivityAttemptModel {
    init(attempt: ActivityAttempt) {
        self.init(
            attempt: attempt.id,
            provider: attempt.provider,
            model: attempt.model,
            label: attempt.label,
            statusCode: attempt.statusCode,
            outcome: ActivityAttemptResult(attempt.outcome),
            durationMS: attempt.durationMS,
            tokens: attempt.tokens,
            ttftMS: attempt.performance?.ttftMS,
            reason: attempt.reason
        )
    }
}

extension ActivityAttemptResult {
    init(_ outcome: ActivityAttemptOutcome) {
        switch outcome {
        case .pending: self = .pending
        case .success: self = .success
        case .httpError: self = .httpError
        case .networkError: self = .networkError
        case .streamError: self = .streamError
        case .cancelled: self = .cancelled
        case .clientError: self = .clientError
        }
    }
}
