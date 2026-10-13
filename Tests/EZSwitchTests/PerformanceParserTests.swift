import Foundation
import Dispatch
import NIOCore
import Testing
@testable import EZSwitch

/// Focused, deterministic tests for the raw-upstream performance parser.
/// Every timestamp is injected, so there is no wall-clock flakiness.
@Suite("Performance parser")
struct PerformanceParserTests {

    // MARK: - Helpers

    private func at(_ nanos: UInt64) -> DispatchTime { DispatchTime(uptimeNanoseconds: nanos) }

    private func sse(_ json: String, crlf: Bool = false) -> Data {
        Data("data: \(json)\(crlf ? "\r\n\r\n" : "\n\n")".utf8)
    }

    private func parser(_ endpoint: EndpointKind,
                        contentType: String? = "text/event-stream",
                        requestStart: UInt64 = 0,
                        attemptStart: UInt64 = 1_000_000) -> PerformanceParser {
        PerformanceParser(endpoint: endpoint, contentType: contentType,
                          requestStart: at(requestStart), attemptStart: at(attemptStart))
    }

    private func approx(_ value: Double?, _ expected: Double, tolerance: Double = 0.001) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    // MARK: - Chat

    @Test func chatContentCountsByEventAndTimesFirstDelta() {
        var p = parser(.chat)
        // role-only first event must not count, and must not start the clock.
        p.ingest(sse(#"{"choices":[{"delta":{"role":"assistant"}}]}"#), at: at(2_000_000))
        p.ingest(sse(#"{"choices":[{"delta":{"content":"Hel"}}]}"#), at: at(5_000_000))
        p.ingest(sse(#"{"choices":[{"delta":{"content":"lo world"}}]}"#), at: at(7_000_000))
        p.finish(at: at(10_000_000))

        let perf = p.makePerformance()
        #expect(perf.streaming)
        #expect(perf.outputDeltaCount == 2) // one per event, not one per token
        #expect(approx(perf.ttftMS, 4))                 // 5ms - 1ms attempt start
        #expect(approx(perf.requestTTFTMS, 5))          // 5ms - 0 request start
        #expect(approx(perf.generationMS, 5))           // 10ms - 5ms first delta
        #expect(approx(perf.tps(outputTokens: 4), 800)) // 4 tokens * 1000 / 5ms
    }

    @Test func chatReasoningAndToolCallArgumentsCountedButNameOnlyIsNot() {
        var p = parser(.chat)
        p.ingest(sse(#"{"choices":[{"delta":{"reasoning_content":"think"}}]}"#), at: at(2_000_000))
        // First tool event carries only id/name — no arguments yet, not a delta.
        p.ingest(sse(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"f","arguments":""}}]}}]}"#), at: at(3_000_000))
        // Empty string content is not a delta either.
        p.ingest(sse(#"{"choices":[{"delta":{"content":""}}]}"#), at: at(3_500_000))
        // Non-empty argument fragment is a delta.
        p.ingest(sse(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\":1}"}}]}}]}"#), at: at(4_000_000))
        p.finish(at: at(9_000_000))

        let perf = p.makePerformance()
        #expect(perf.outputDeltaCount == 2)
        #expect(approx(perf.ttftMS, 1)) // first valid delta at 2ms, attempt start 1ms
        #expect(approx(perf.generationMS, 7))
    }

    @Test func singleEventWithMultipleChoicesAndFieldsCountsOnce() {
        var p = parser(.chat)
        // One JSON event carrying two choices (content + tool arguments) is still a
        // single valid SSE event; a one-shot output must not look like many deltas.
        p.ingest(sse(#"{"choices":[{"delta":{"content":"a"}},{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}"#),
                 at: at(1_000_000))
        p.finish(at: at(2_000_000))
        let perf = p.makePerformance()
        #expect(perf.outputDeltaCount == 1)
        #expect(perf.ttftMS != nil)
        #expect(perf.tps(outputTokens: 100) == nil) // needs >= 2 valid events
    }

    @Test func contentAndReasoningInSameDeltaCountOnce() {
        var p = parser(.chat)
        p.ingest(sse(#"{"choices":[{"delta":{"content":"a","reasoning_content":"b"}}]}"#), at: at(1_000_000))
        p.finish(at: at(2_000_000))
        #expect(p.outputDeltaCount == 1)
    }

    // MARK: - Responses

    @Test func responsesDeltaTypesRecognisedAndCreatedExcluded() {
        var p = parser(.responses)
        p.ingest(sse(#"{"type":"response.created"}"#), at: at(1_000_000))
        p.ingest(sse(#"{"type":"response.output_item.added","item":{"type":"function_call","name":"f"}}"#), at: at(1_500_000))
        p.ingest(sse(#"{"type":"response.output_text.delta","delta":""}"#), at: at(1_800_000))
        p.ingest(sse(#"{"type":"response.output_text.delta","delta":"Hi"}"#), at: at(2_000_000))
        p.ingest(sse(#"{"type":"response.reasoning_text.delta","delta":"why"}"#), at: at(3_000_000))
        p.ingest(sse(#"{"type":"response.reasoning_summary_text.delta","delta":"sum"}"#), at: at(4_000_000))
        p.ingest(sse(#"{"type":"response.function_call_arguments.delta","delta":"{\"x\":"}"#), at: at(5_000_000))
        p.finish(at: at(6_000_000))

        let perf = p.makePerformance()
        #expect(perf.outputDeltaCount == 4)
        #expect(approx(perf.ttftMS, 1)) // first output_text.delta at 2ms, attempt start 1ms
    }

    // MARK: - Anthropic Messages

    @Test func anthropicBlockDeltasCountedAndLifecycleExcluded() {
        var p = parser(.messages)
        p.ingest(sse(#"{"type":"message_start","message":{"usage":{"input_tokens":3}}}"#), at: at(1_000_000))
        p.ingest(sse(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#), at: at(1_200_000))
        p.ingest(sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}"#), at: at(1_400_000))
        p.ingest(sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"He"}}"#), at: at(2_000_000))
        p.ingest(sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#), at: at(3_000_000))
        p.ingest(sse(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}"#), at: at(3_500_000))
        p.ingest(sse(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\":1}"}}"#), at: at(4_000_000))
        p.ingest(sse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#), at: at(5_000_000))
        p.finish(at: at(6_000_000))

        let perf = p.makePerformance()
        #expect(perf.outputDeltaCount == 3)
        #expect(approx(perf.ttftMS, 1)) // text "He" at 2ms
        #expect(approx(perf.generationMS, 4))
    }

    // MARK: - Exclusion / terminal events

    @Test func heartbeatUsageOnlyAndDoneAreExcluded() {
        var p = parser(.chat)
        p.ingest(Data(": ping\n\n".utf8), at: at(1_000_000))
        p.ingest(sse(#"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":9}}"#), at: at(2_000_000))
        p.ingest(Data("data: [DONE]\n\n".utf8), at: at(3_000_000))
        p.finish(at: at(4_000_000))

        let perf = p.makePerformance()
        #expect(perf.streaming)
        #expect(perf.outputDeltaCount == 0)
        #expect(perf.ttftMS == nil)
        #expect(perf.generationMS == nil)
        #expect(perf.tps(outputTokens: 9) == nil)
    }

    // MARK: - Boundary safety

    @Test func chunksSplittingLinesAndCRLFAreSafe() {
        var p = parser(.chat)
        // First event deliberately split mid-JSON across three chunks, CRLF framing.
        let full = Data("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\r\n\r\n".utf8)
        let a = full.prefix(12)
        let b = full.dropFirst(12).prefix(9)
        let c = full.dropFirst(21)
        p.ingest(Data(a), at: at(2_000_000))
        p.ingest(Data(b), at: at(2_100_000))
        p.ingest(Data(c), at: at(2_200_000))
        #expect(p.outputDeltaCount == 1)

        p.ingest(sse(#"{"choices":[{"delta":{"content":"!"}}]}"#), at: at(3_000_000))
        p.finish(at: at(4_000_000))
        #expect(p.outputDeltaCount == 2)
        // TTFT is pinned to the chunk that completed the first event (2.2ms).
        #expect(approx(p.makePerformance().ttftMS, 1.2))
    }

    @Test func finishFlushesTailEventWithoutTrailingBlankLine() {
        var p = parser(.chat)
        // First valid delta, then a final event with no trailing blank separator.
        p.ingest(sse(#"{"choices":[{"delta":{"content":"a"}}]}"#), at: at(2_000_000))
        p.ingest(Data("data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}".utf8), at: at(3_000_000))
        p.finish(at: at(4_000_000))
        #expect(p.outputDeltaCount == 2)
        #expect(approx(p.makePerformance().generationMS, 2))
    }

    // MARK: - Non-streaming

    @Test func nonStreamingHasNoTimingOrCount() {
        var p = parser(.chat, contentType: "application/json")
        p.ingest(Data(#"{"choices":[{"delta":{"content":"x"}}]}"#.utf8), at: at(2_000_000))
        p.finish(at: at(3_000_000))
        let perf = p.makePerformance()
        #expect(!perf.streaming)
        #expect(perf.outputDeltaCount == 0)
        #expect(perf.ttftMS == nil)
        #expect(perf.generationMS == nil)
        #expect(perf.tps(outputTokens: 100) == nil)
    }

    // MARK: - Short stream / TPS guard

    @Test func singleDeltaStreamHasNoTPS() {
        var p = parser(.chat)
        p.ingest(sse(#"{"choices":[{"delta":{"content":"only"}}]}"#), at: at(2_000_000))
        p.finish(at: at(50_000_000))
        let perf = p.makePerformance()
        #expect(perf.outputDeltaCount == 1)
        #expect(perf.ttftMS != nil)
        #expect(perf.generationMS != nil)
        #expect(perf.tps(outputTokens: 50) == nil) // needs >= 2 deltas
        #expect(perf.tps(outputTokens: 1) == nil)  // needs >= 2 tokens
    }

    // MARK: - Overflow / bounded parsing

    @Test func overflowBeforeFirstDeltaSuppressesTiming() {
        var p = parser(.chat)
        // A line larger than the cap must be dropped, and the first delta is never
        // reliably located → TTFT/generation (and TPS) stay unknown.
        let huge = "data: {\"choices\":[{\"delta\":{\"content\":\"" + String(repeating: "x", count: PerformanceParser.maxEventBytes + 16) + "\"}}]}"
        p.ingest(Data((huge + "\n\n").utf8), at: at(2_000_000))
        p.ingest(sse(#"{"choices":[{"delta":{"content":"hi"}}]}"#), at: at(3_000_000))
        p.finish(at: at(4_000_000))

        let perf = p.makePerformance()
        #expect(perf.ttftMS == nil)
        #expect(perf.generationMS == nil)
        #expect(perf.tps(outputTokens: 100) == nil)
    }

    @Test func emptyDataLineAndDoneAreNotLosses() {
        var p = parser(.chat)
        p.ingest(Data("data: \n\n".utf8), at: at(1_000_000))    // keep-alive with no payload
        p.ingest(sse(#"{"choices":[{"delta":{"content":"a"}}]}"#), at: at(2_000_000))
        p.ingest(Data("data: [DONE]\n\n".utf8), at: at(3_000_000))
        p.finish(at: at(4_000_000))
        let perf = p.makePerformance()
        #expect(perf.outputDeltaCount == 1)
        #expect(perf.generationMS != nil) // no parsing loss occurred
    }

    @Test func nonJSONPayloadAfterFirstDeltaDropsGenerationButKeepsTTFT() {
        var p = parser(.chat)
        p.ingest(sse(#"{"choices":[{"delta":{"content":"a"}}]}"#), at: at(2_000_000))
        // A non-[DONE] data payload that is not JSON is treated conservatively.
        p.ingest(sse("[ERROR]"), at: at(3_000_000))
        p.finish(at: at(4_000_000))
        let perf = p.makePerformance()
        #expect(perf.outputDeltaCount == 1)
        #expect(approx(perf.ttftMS, 1)) // first delta still known
        #expect(perf.generationMS == nil) // count/timing no longer trustworthy
        #expect(perf.tps(outputTokens: 100) == nil)
    }

    @Test func overflowAfterFirstDeltaKeepsTTFTButDropsGeneration() {
        var p = parser(.chat)
        p.ingest(sse(#"{"choices":[{"delta":{"content":"a"}}]}"#), at: at(2_000_000))
        let huge = "data: {\"choices\":[{\"delta\":{\"content\":\"" + String(repeating: "y", count: PerformanceParser.maxEventBytes + 16) + "\"}}]}"
        p.ingest(Data((huge + "\n\n").utf8), at: at(3_000_000))
        p.ingest(sse(#"{"choices":[{"delta":{"content":"b"}}]}"#), at: at(4_000_000))
        p.finish(at: at(5_000_000))

        let perf = p.makePerformance()
        #expect(approx(perf.ttftMS, 1))     // first delta at 2ms, attempt start 1ms
        #expect(perf.generationMS == nil)   // parse loss ⇒ generation unknown
        #expect(perf.outputDeltaCount == 2) // kept events still counted exactly
    }

    // MARK: - Accumulator (thread-safe wrapper)

    @Test func accumulatorSnapshotWithoutFinishHasNoGeneration() {
        let accumulator = PerformanceAccumulator(
            endpoint: .chat, contentType: "text/event-stream",
            requestStart: at(0), attemptStart: at(1_000_000))
        accumulator.ingest(sse(#"{"choices":[{"delta":{"content":"Hi"}}]}"#))
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        buffer.writeBytes(Array(sse(#"{"choices":[{"delta":{"content":"!"}}]}"#)))
        accumulator.ingest(buffer)

        let partial = accumulator.performance
        #expect(partial.streaming)
        #expect(partial.outputDeltaCount == 2)
        #expect(partial.ttftMS != nil)
        #expect(partial.generationMS == nil) // body has not ended yet
        #expect(partial.tps(outputTokens: 8) == nil)
    }
}
