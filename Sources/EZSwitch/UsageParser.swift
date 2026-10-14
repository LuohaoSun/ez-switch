import Foundation
import CoreFoundation
import NIOCore

/// Which upstream protocol produced a usage payload.
enum UsageSource: Sendable, Equatable {
    case chat
    case responses
    case messages
    case gemini

    init(endpoint: EndpointKind) {
        switch endpoint {
        case .chat: self = .chat
        case .responses: self = .responses
        case .messages: self = .messages
        case .gemini: self = .gemini
        }
    }
}

/// Non-blocking sink for finished attempt records. Injected into the proxy so
/// existing tests (which pass `nil`) never touch a database.
typealias UsageRecorder = @Sendable (UsageRecord) -> Void

/// Incremental token-usage extractor for OpenAI Chat Completions, OpenAI
/// Responses, Anthropic Messages and native Gemini `generateContent` /
/// `streamGenerateContent`, in both plain JSON and SSE form.
///
/// Streaming values are cumulative: a later event overwrites an earlier one
/// rather than accumulating. Missing fields stay `nil`; an explicitly reported
/// `0` is a known zero. Invalid numbers (negative, boolean, fractional, too
/// large to represent exactly) are ignored so they can never masquerade as a
/// real count. Memory stays bounded: a single oversized SSE line is dropped
/// (later events, including the final usage event, are still parsed), and a
/// non-streaming body beyond `maxBodyBytes` is not parsed at all.
///
/// Gemini's `usageMetadata`: `input` = `promptTokenCount` +
/// `toolUsePromptTokenCount` (cached is already inside prompt), `output` =
/// `candidatesTokenCount` + `thoughtsTokenCount`, `cachedInput` =
/// `cachedContentTokenCount`, `reasoning` = `thoughtsTokenCount`. `countTokens`
/// responses are input estimates, not generation usage, and are ignored.
struct UsageParser {
    /// Largest single SSE line kept in memory. Longer lines are discarded.
    static let maxEventBytes = 1 << 20
    /// Largest non-streaming body buffered for parsing.
    static let maxBodyBytes = 16 << 20

    private static let dataPrefix = Data("data:".utf8)
    private static let usageMarker = Data(#""usage""#.utf8)
    /// Gemini nests usage under `usageMetadata`; the `"usage"` marker above does
    /// not match it, so the pre-filter must be selected per source.
    private static let geminiUsageMarker = Data(#""usageMetadata""#.utf8)

    private let source: UsageSource
    private let streaming: Bool

    private var lineBuffer = Data()
    private var jsonBuffer = Data()
    private var discardingLongLine = false
    private var bodyOverflowed = false

    // One SSE event assembled from consecutive `data:` lines (joined by "\n").
    private var eventData = Data()
    private var eventHasData = false
    private var eventOverflowed = false

    // Raw components, kept per protocol family. `nil` = not reported.
    private var rawInput: Int?
    private var rawOutput: Int?
    private var cached: Int?
    private var cacheWrite: Int?
    private var reasoning: Int?

    // Gemini components tracked independently so a partial cumulative snapshot
    // that omits an already-reported field cannot drop it from the sums.
    private var geminiPrompt: Int?
    private var geminiToolUse: Int?
    private var geminiCandidates: Int?
    private var geminiThoughts: Int?

    init(source: UsageSource, streaming: Bool) {
        self.source = source
        self.streaming = streaming
    }

    init(endpoint: EndpointKind, streaming: Bool) {
        self.init(source: UsageSource(endpoint: endpoint), streaming: streaming)
    }

    /// Feed the next piece of the upstream body (chunk boundaries may split
    /// lines arbitrarily).
    mutating func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        if streaming {
            ingestSSE(data)
        } else {
            ingestJSON(data)
        }
    }

    /// Flush the tail once the body is complete.
    mutating func finish() {
        if streaming {
            defer { lineBuffer.removeAll(keepingCapacity: false) }
            // '{' = plain JSON object despite SSE framing; for Gemini also '[' =
            // the whole native streamGenerateContent JSON-array body (SSE
            // framing absent), whose last cumulative snapshot wins.
            if lineBuffer.first == 0x7B || (source == .gemini && lineBuffer.first == 0x5B) {
                parseUsage(from: lineBuffer)
                lineBuffer.removeAll(keepingCapacity: false)
                return
            }
            if !lineBuffer.isEmpty { handleLine(lineBuffer) }
            flushEvent()
        } else if !bodyOverflowed {
            parseUsage(from: jsonBuffer)
        }
    }

    /// Current best-effort usage. All-`nil` means no usage was reported.
    var snapshot: UsageTokens {
        var tokens = UsageTokens()
        switch source {
        case .chat, .responses, .gemini:
            tokens.input = rawInput
            tokens.output = rawOutput
            tokens.cachedInput = cached
        case .messages:
            // Anthropic `input_tokens` excludes cache buckets; the input total is
            // uncached + cache-read + cache-write, but only when the ordinary
            // input count was actually reported.
            if let rawInput {
                tokens.input = UsageParser.add(rawInput, UsageParser.add(cached, cacheWrite))
            }
            tokens.output = rawOutput
            tokens.cachedInput = cached
            tokens.cacheWrite = cacheWrite
        }
        tokens.reasoning = reasoning
        return tokens
    }

    // MARK: - Ingestion

    private mutating func ingestJSON(_ data: Data) {
        guard !bodyOverflowed else { return }
        if jsonBuffer.count + data.count > UsageParser.maxBodyBytes {
            bodyOverflowed = true
            jsonBuffer.removeAll(keepingCapacity: false)
            return
        }
        jsonBuffer.append(data)
    }

    private mutating func ingestSSE(_ data: Data) {
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
                if lineBuffer.count + remaining.count > UsageParser.maxEventBytes {
                    lineBuffer.removeAll(keepingCapacity: false)
                    discardingLongLine = true
                } else {
                    lineBuffer.append(contentsOf: remaining)
                }
                return
            }
            let segmentCount = data.distance(from: index, to: newline)
            if lineBuffer.count + segmentCount <= UsageParser.maxEventBytes {
                lineBuffer.append(contentsOf: data[index..<newline])
                if lineBuffer.last == 0x0D { lineBuffer.removeLast() } // strip CR of CRLF
                handleLine(lineBuffer)
            }
            lineBuffer.removeAll(keepingCapacity: false)
            index = data.index(after: newline)
        }
    }

    /// Assemble one event from consecutive `data:` lines (SSE joins them with
    /// "\n"); the event is parsed when the blank delimiter line arrives. A
    /// single line and the whole event are each capped, and an oversized event
    /// is dropped so later events (including the final usage event) still parse.
    private mutating func handleLine(_ line: Data) {
        if line.isEmpty {
            flushEvent()
            return
        }
        guard line.starts(with: UsageParser.dataPrefix) else { return }
        guard !eventOverflowed else { return }
        var payload = line.dropFirst(5)
        if payload.first == 0x20 { payload = payload.dropFirst() } // optional single space
        let added = eventHasData ? payload.count + 1 : payload.count
        guard eventData.count + added <= UsageParser.maxEventBytes else {
            eventOverflowed = true
            eventData.removeAll(keepingCapacity: false)
            return
        }
        if eventHasData { eventData.append(0x0A) }
        eventData.append(contentsOf: payload)
        eventHasData = true
    }

    private mutating func flushEvent() {
        defer {
            eventData.removeAll(keepingCapacity: false)
            eventHasData = false
            eventOverflowed = false
        }
        guard eventHasData, !eventOverflowed else { return }
        parseUsage(from: eventData)
    }

    private mutating func parseUsage(from data: Data) {
        // Cheap pre-filter: usage only ever appears under a "usage" key (or
        // "usageMetadata" for Gemini), so most streaming delta events never pay
        // for a full JSON decode.
        let marker = source == .gemini ? UsageParser.geminiUsageMarker : UsageParser.usageMarker
        guard data.range(of: marker) != nil else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return }
        if let dictionary = object as? [String: Any] {
            apply(dictionary)
        } else if source == .gemini, let array = object as? [Any] {
            // Native non-SSE `streamGenerateContent` returns a JSON array; each
            // element carries a cumulative usageMetadata, so later elements
            // overwrite earlier ones (never summed).
            for element in array {
                if let dictionary = element as? [String: Any] { apply(dictionary) }
            }
        }
    }

    private mutating func apply(_ object: [String: Any]) {
        switch source {
        case .chat:
            if let usage = object["usage"] as? [String: Any] { applyOpenAI(usage, responses: false) }
        case .responses:
            var usage = object["usage"] as? [String: Any]
            if usage == nil, let response = object["response"] as? [String: Any] {
                usage = response["usage"] as? [String: Any]
            }
            if let usage { applyOpenAI(usage, responses: true) }
        case .messages:
            var usage = object["usage"] as? [String: Any]
            if usage == nil, let message = object["message"] as? [String: Any] {
                usage = message["usage"] as? [String: Any]
            }
            if let usage { applyAnthropic(usage) }
        case .gemini:
            if let usage = object["usageMetadata"] as? [String: Any] { applyGemini(usage) }
        }
    }

    private mutating func applyOpenAI(_ usage: [String: Any], responses: Bool) {
        let input = UsageParser.integer(usage[responses ? "input_tokens" : "prompt_tokens"])
            ?? UsageParser.integer(usage[responses ? "prompt_tokens" : "input_tokens"])
        let output = UsageParser.integer(usage[responses ? "output_tokens" : "completion_tokens"])
            ?? UsageParser.integer(usage[responses ? "completion_tokens" : "output_tokens"])
        let details = responses ? "input_tokens_details" : "prompt_tokens_details"
        let cachedTokens = (usage[details] as? [String: Any])
            .flatMap { UsageParser.integer($0["cached_tokens"]) }
            ?? (usage["input_tokens_details"] as? [String: Any])
            .flatMap { UsageParser.integer($0["cached_tokens"]) }
            ?? (responses ? nil : UsageParser.integer(usage["prompt_cache_hit_tokens"])) // DeepSeek
        let outputDetails = responses ? "output_tokens_details" : "completion_tokens_details"
        let reasoningTokens = (usage[outputDetails] as? [String: Any])
            .flatMap { UsageParser.integer($0["reasoning_tokens"]) }
            ?? UsageParser.integer(usage["reasoning_tokens"])

        if let input { rawInput = input }
        if let output { rawOutput = output }
        if let cachedTokens { cached = cachedTokens }
        if let reasoningTokens { reasoning = reasoningTokens }
    }

    private mutating func applyAnthropic(_ usage: [String: Any]) {
        let reasoningTokens = (usage["output_tokens_details"] as? [String: Any])
            .flatMap { UsageParser.integer($0["reasoning_tokens"]) }
            ?? UsageParser.integer(usage["reasoning_tokens"])
        if let value = UsageParser.integer(usage["input_tokens"]) { rawInput = value }
        if let value = UsageParser.integer(usage["output_tokens"]) { rawOutput = value }
        if let value = UsageParser.integer(usage["cache_read_input_tokens"]) { cached = value }
        if let value = UsageParser.integer(usage["cache_creation_input_tokens"]) { cacheWrite = value }
        if let reasoningTokens { reasoning = reasoningTokens }
    }

    /// Native Gemini `usageMetadata`: input = prompt + tool-use prompt (cache is
    /// already inside prompt), output = candidates + thoughts, reasoning = thoughts.
    /// Optional components are independently last-valid: omitted after being
    /// reported they keep their value (never drop out of the sum), explicit 0
    /// resets, invalid never overwrites, and unknown sides stay unknown.
    private mutating func applyGemini(_ usage: [String: Any]) {
        if let value = UsageParser.integer(usage["promptTokenCount"]) { geminiPrompt = value }
        if let value = UsageParser.integer(usage["toolUsePromptTokenCount"]) { geminiToolUse = value }
        if let value = UsageParser.integer(usage["cachedContentTokenCount"]) { cached = value }
        if let value = UsageParser.integer(usage["candidatesTokenCount"]) { geminiCandidates = value }
        if let value = UsageParser.integer(usage["thoughtsTokenCount"]) { geminiThoughts = value }

        if let prompt = geminiPrompt {
            rawInput = geminiToolUse == nil ? prompt : UsageParser.add(prompt, geminiToolUse)
        }
        if let candidates = geminiCandidates {
            rawOutput = geminiThoughts == nil ? candidates
                : UsageParser.add(candidates, geminiThoughts)
        }
        reasoning = geminiThoughts

        reconcileGeminiTotal(usage)
    }

    /// Fill only a single side missing from the authoritative `totalTokenCount`
    /// (= input + output): never invent a negative, never overwrite a set side.
    private mutating func reconcileGeminiTotal(_ usage: [String: Any]) {
        guard let total = UsageParser.integer(usage["totalTokenCount"]) else { return }
        if rawInput == nil, let output = rawOutput {
            let (derived, overflow) = total.subtractingReportingOverflow(output)
            if !overflow, derived >= 0 { rawInput = derived }
        } else if rawOutput == nil, let input = rawInput {
            let (derived, overflow) = total.subtractingReportingOverflow(input)
            if !overflow, derived >= 0 { rawOutput = derived }
        }
    }

    // MARK: - Number handling

    /// Accepts only numbers that are non-negative whole integers within `Int`
    /// range. Rejects booleans, negatives, fractions, exponents and overflow.
    ///
    /// Parsing the exact decimal text (rather than `doubleValue`) matters: a JSON
    /// integer above 2^53 such as `9007199254740993` would otherwise round to a
    /// seemingly-valid but wrong value. `Int(_:)` also returns `nil` on overflow,
    /// so huge magnitudes become unknown instead of truncated.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let result = Int(number.stringValue), result >= 0 else { return nil }
        return result
    }

    /// Overflow-safe addition used for Anthropic input totals; overflow yields
    /// `nil` (unknown) rather than a wrapped value.
    static func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (let value?, nil): return value
        case (nil, let value?): return value
        case (let left?, let right?):
            let (sum, overflow) = left.addingReportingOverflow(right)
            return overflow ? nil : sum
        }
    }
}

/// Thread-safe, non-blocking bridge between a byte stream and `UsageParser`.
/// One instance per upstream attempt; the proxy reads `tokens` after the body
/// has been fully forwarded.
final class UsageAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: UsageParser

    init(source: UsageSource, streaming: Bool) {
        parser = UsageParser(source: source, streaming: streaming)
    }

    init(endpoint: EndpointKind, contentType: String?) {
        let streaming = (contentType ?? "").lowercased().contains("text/event-stream")
        parser = UsageParser(endpoint: endpoint, streaming: streaming)
    }

    func ingest(_ data: Data) {
        lock.lock()
        parser.ingest(data)
        lock.unlock()
    }

    func ingest(_ buffer: ByteBuffer) {
        ingest(Data(buffer.readableBytesView))
    }

    func finish() {
        lock.lock()
        parser.finish()
        lock.unlock()
    }

    var tokens: UsageTokens {
        lock.lock()
        defer { lock.unlock() }
        return parser.snapshot
    }
}
