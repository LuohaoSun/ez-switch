import Foundation
import Dispatch
import NIOCore

/// Which raw upstream protocol produced a streaming body. Performance is always
/// measured on the *raw upstream* bytes (before Responses→Chat translation, before
/// reorder).
enum PerformanceSource: Sendable {
    case chat
    case responses
    case messages

    init(endpoint: EndpointKind) {
        switch endpoint {
        case .chat: self = .chat
        case .responses: self = .responses
        case .messages: self = .messages
        }
    }
}

/// Incremental first-output / generation timing for one upstream attempt.
///
/// Key constraints (v1, raw upstream arrival — no client-outbound timing):
/// - `ttftMS` = attemptStart → first valid semantic delta (connect + request build
///   + bridge preparation included).
/// - `requestTTFTMS` = router started handling the fully-received request → first
///   valid semantic delta; includes earlier fallback waits.
/// - `generationMS` = first valid semantic delta → upstream body normal end
///   (conservatively including the flushed tail). Not real internal decode speed.
/// - `outputDeltaCount` = number of valid semantic SSE *events* (each event counts
///   at most once, never per choice/field/token). Persisted/shown, so it is never
///   capped.
///
/// Valid semantic content: Chat `content` / `reasoning_content` / non-empty
/// `tool_calls[].function.arguments`; Responses `output_text`, `reasoning_text`,
/// `reasoning_summary_text`, `function_call_arguments` deltas; Anthropic
/// `content_block_delta` with `text_delta` / `thinking_delta` / `input_json_delta`.
/// Heartbeats, `role`-only deltas, `created`/lifecycle events, empty deltas, the
/// terminal usage-only event and non-text metadata are excluded. Text fields must
/// be non-empty Strings; Chat `content` arrays are non-standard for streaming
/// deltas and are not counted.
///
/// Any parsing loss (oversized line/event, or a non-`[DONE]` payload that is not
/// valid JSON) means the output can no longer be fully counted: `generationMS`
/// (and therefore TPS) becomes `nil` rather than falsely precise. A loss before
/// the first delta also drops `ttftMS`/`requestTTFTMS`. Parsing stays bounded by
/// `maxEventBytes`.
struct PerformanceParser {
    /// Largest single SSE line / event kept in memory. Longer ones are dropped.
    static let maxEventBytes = 1 << 20

    private static let dataPrefix = Data("data:".utf8)
    private static let doneMarker = Data("[DONE]".utf8)
    private static let responsesDeltaTypes: Set<String> = [
        "response.output_text.delta",
        "response.reasoning_text.delta",
        "response.reasoning_summary_text.delta",
        "response.function_call_arguments.delta",
    ]

    let source: PerformanceSource
    let streaming: Bool
    let requestStart: DispatchTime?
    let attemptStart: DispatchTime?

    private var lineBuffer = Data()
    private var discardingLongLine = false

    private var eventData = Data()
    private var eventHasData = false
    private var eventOverflowed = false

    private var firstDeltaNanos: UInt64?
    private var endNanos: UInt64?
    private(set) var outputDeltaCount = 0
    /// Any parse loss makes the delta count unreliable from then on.
    private var parseLost = false
    /// A parse loss before the first delta makes the timing itself unreliable.
    private var lostBeforeFirstDelta = false

    init(source: PerformanceSource, streaming: Bool,
         requestStart: DispatchTime? = nil, attemptStart: DispatchTime? = nil) {
        self.source = source
        self.streaming = streaming
        self.requestStart = requestStart
        self.attemptStart = attemptStart
    }

    init(endpoint: EndpointKind, contentType: String?,
         requestStart: DispatchTime? = nil, attemptStart: DispatchTime? = nil) {
        let streaming = (contentType ?? "").lowercased().contains("text/event-stream")
        self.init(source: PerformanceSource(endpoint: endpoint), streaming: streaming,
                  requestStart: requestStart, attemptStart: attemptStart)
    }

    /// Feed the next piece of the raw upstream body; chunk boundaries may split
    /// lines or events arbitrarily.
    mutating func ingest(_ data: Data, at now: DispatchTime = .now()) {
        guard streaming, !data.isEmpty else { return }
        ingestSSE(data, nowNanos: now.uptimeNanoseconds)
    }

    /// Flush the tail once the upstream body is complete (normal end).
    mutating func finish(at now: DispatchTime = .now()) {
        if streaming {
            if !lineBuffer.isEmpty { handleLine(lineBuffer, nowNanos: now.uptimeNanoseconds) }
            flushEvent(nowNanos: now.uptimeNanoseconds)
            lineBuffer.removeAll(keepingCapacity: false)
        }
        endNanos = now.uptimeNanoseconds
    }

    /// Snapshot for the attempt's usage record. Safe after `finish`; for a
    /// cancelled/partial attempt `generationMS` is nil because the body never
    /// ended normally.
    func makePerformance() -> UsagePerformance {
        var performance = UsagePerformance(streaming: streaming)
        performance.outputDeltaCount = outputDeltaCount
        guard streaming, !lostBeforeFirstDelta, let first = firstDeltaNanos else { return performance }
        if let attemptStart {
            performance.ttftMS = PerformanceParser.milliseconds(first, since: attemptStart.uptimeNanoseconds)
        }
        if let requestStart {
            performance.requestTTFTMS = PerformanceParser.milliseconds(first, since: requestStart.uptimeNanoseconds)
        }
        if !parseLost, let end = endNanos {
            performance.generationMS = PerformanceParser.milliseconds(end, since: first)
        }
        return performance
    }

    // MARK: - SSE ingestion

    private mutating func ingestSSE(_ data: Data, nowNanos: UInt64) {
        var index = data.startIndex
        let end = data.endIndex
        while index < end {
            if discardingLongLine {
                guard let newline = data[index...].firstIndex(of: 0x0A) else { return }
                discardingLongLine = false
                index = data.index(after: newline)
                continue
            }
            guard let newline = data[index...].firstIndex(of: 0x0A) else {
                let remaining = data[index..<end]
                if lineBuffer.count + remaining.count > PerformanceParser.maxEventBytes {
                    lineBuffer.removeAll(keepingCapacity: false)
                    discardingLongLine = true
                    noteParsingLoss()
                } else {
                    lineBuffer.append(contentsOf: remaining)
                }
                return
            }
            let segmentCount = data.distance(from: index, to: newline)
            if lineBuffer.count + segmentCount <= PerformanceParser.maxEventBytes {
                lineBuffer.append(contentsOf: data[index..<newline])
                if lineBuffer.last == 0x0D { lineBuffer.removeLast() } // strip CR of CRLF
                handleLine(lineBuffer, nowNanos: nowNanos)
            } else {
                noteParsingLoss()
            }
            lineBuffer.removeAll(keepingCapacity: false)
            index = data.index(after: newline)
        }
    }

    /// Assemble one event from consecutive `data:` lines (SSE joins them with
    /// "\n"); parsed when the blank delimiter line arrives.
    private mutating func handleLine(_ line: Data, nowNanos: UInt64) {
        if line.isEmpty { flushEvent(nowNanos: nowNanos); return }
        guard line.starts(with: PerformanceParser.dataPrefix) else { return }
        guard !eventOverflowed else { return }
        var payload = line.dropFirst(5)
        if payload.first == 0x20 { payload = payload.dropFirst() } // optional single space
        let added = eventHasData ? payload.count + 1 : payload.count
        guard eventData.count + added <= PerformanceParser.maxEventBytes else {
            eventOverflowed = true
            eventData.removeAll(keepingCapacity: false)
            noteParsingLoss()
            return
        }
        if eventHasData { eventData.append(0x0A) }
        eventData.append(contentsOf: payload)
        eventHasData = true
    }

    private mutating func flushEvent(nowNanos: UInt64) {
        defer {
            eventData.removeAll(keepingCapacity: false)
            eventHasData = false
            eventOverflowed = false
        }
        guard eventHasData, !eventOverflowed else { return }
        guard !eventData.isEmpty else { return } // `data:` with no payload (keep-alive)
        guard eventData != PerformanceParser.doneMarker else { return } // normal terminator
        guard let object = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            // A non-[DONE] payload that does not decode is suspicious; treat as a
            // loss so timing/count stay conservative instead of silently wrong.
            noteParsingLoss()
            return
        }
        guard hasSemanticDelta(in: object) else { return }
        if firstDeltaNanos == nil { firstDeltaNanos = nowNanos }
        outputDeltaCount += 1 // one valid event = one delta, regardless of fields
    }

    private mutating func noteParsingLoss() {
        parseLost = true
        if firstDeltaNanos == nil { lostBeforeFirstDelta = true }
    }

    // MARK: - Semantic delta detection (per event, boolean)

    private func hasSemanticDelta(in object: [String: Any]) -> Bool {
        switch source {
        case .chat: return chatHasDelta(object)
        case .responses: return responsesHasDelta(object)
        case .messages: return messagesHasDelta(object)
        }
    }

    private func chatHasDelta(_ object: [String: Any]) -> Bool {
        guard let choices = object["choices"] as? [[String: Any]] else { return false }
        for choice in choices {
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if PerformanceParser.hasText(delta["content"]) { return true }
            if PerformanceParser.hasText(delta["reasoning_content"]) { return true }
            guard let calls = delta["tool_calls"] as? [[String: Any]] else { continue }
            for call in calls {
                // A first tool event often carries only id/name; only a non-empty
                // arguments fragment is a real delta.
                guard let function = call["function"] as? [String: Any] else { continue }
                if PerformanceParser.hasText(function["arguments"]) { return true }
            }
        }
        return false
    }

    private func responsesHasDelta(_ object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String,
              PerformanceParser.responsesDeltaTypes.contains(type) else { return false }
        return PerformanceParser.hasText(object["delta"])
    }

    private func messagesHasDelta(_ object: [String: Any]) -> Bool {
        guard object["type"] as? String == "content_block_delta",
              let delta = object["delta"] as? [String: Any],
              let type = delta["type"] as? String else { return false }
        switch type {
        case "text_delta": return PerformanceParser.hasText(delta["text"])
        case "thinking_delta": return PerformanceParser.hasText(delta["thinking"])
        case "input_json_delta": return PerformanceParser.hasText(delta["partial_json"])
        default: return false
        }
    }

    /// Only a non-empty String counts as real output content (non-text metadata
    /// such as `[{"type":"text","text":""}]` is not output).
    private static func hasText(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.isEmpty
    }

    private static func milliseconds(_ later: UInt64, since earlier: UInt64) -> Double? {
        guard later >= earlier else { return nil }
        return Double(later - earlier) / 1_000_000
    }
}

/// Thread-safe, non-blocking bridge between the raw upstream byte stream and
/// `PerformanceParser`. One instance per upstream attempt; the proxy reads
/// `performance` after the body has been forwarded (or on cancel).
final class PerformanceAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: PerformanceParser

    init(source: PerformanceSource, streaming: Bool,
         requestStart: DispatchTime? = nil, attemptStart: DispatchTime? = nil) {
        parser = PerformanceParser(source: source, streaming: streaming,
                                   requestStart: requestStart, attemptStart: attemptStart)
    }

    init(endpoint: EndpointKind, contentType: String?,
         requestStart: DispatchTime? = nil, attemptStart: DispatchTime? = nil) {
        parser = PerformanceParser(endpoint: endpoint, contentType: contentType,
                                   requestStart: requestStart, attemptStart: attemptStart)
    }

    func ingest(_ data: Data, at now: DispatchTime = .now()) {
        lock.lock()
        parser.ingest(data, at: now)
        lock.unlock()
    }

    func ingest(_ buffer: ByteBuffer, at now: DispatchTime = .now()) {
        ingest(Data(buffer.readableBytesView), at: now)
    }

    func finish(at now: DispatchTime = .now()) {
        lock.lock()
        parser.finish(at: now)
        lock.unlock()
    }

    var performance: UsagePerformance {
        lock.lock()
        defer { lock.unlock() }
        return parser.makePerformance()
    }
}
