import Foundation
import Dispatch
import NIOCore
import Testing
@testable import EZSwitch

/// Focused tests for native Gemini `usageMetadata` extraction and Gemini SSE
/// semantic-delta / TTFT detection. Constructed via the source enums so the
/// parser behaviour is pinned independently of routing/forwarding.
@Suite("Gemini usage & performance parser")
struct GeminiParserTests {

    // MARK: - Usage helpers

    private func usage(_ text: String, streaming: Bool, chunk: Int = 4096) -> UsageTokens {
        var parser = UsageParser(source: .gemini, streaming: streaming)
        let bytes = Array(text.utf8)
        for start in stride(from: 0, to: bytes.count, by: max(1, chunk)) {
            parser.ingest(Data(bytes[start..<min(start + chunk, bytes.count)]))
        }
        parser.finish()
        return parser.snapshot
    }

    private func sse(_ json: String, crlf: Bool = false) -> String {
        "data: \(json)\(crlf ? "\r\n\r\n" : "\n\n")"
    }

    // MARK: - Usage: mapping

    @Test func nonStreamMapsCachedInputOutputAndThoughts() {
        let tokens = usage(#"{"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":100,"cachedContentTokenCount":40,"candidatesTokenCount":20,"thoughtsTokenCount":5,"totalTokenCount":125}}"#,
                           streaming: false)
        // promptTokenCount already includes the cached part: never add it again.
        #expect(tokens.input == 100)
        // candidates + thoughts are distinct upstream addends of totalTokenCount.
        #expect(tokens.output == 25)
        #expect(tokens.cachedInput == 40)
        #expect(tokens.reasoning == 5)
        #expect(tokens.cacheWrite == nil)
        #expect(tokens.isComplete)
        #expect(tokens.total == 125) // matches the authoritative upstream totalTokenCount
    }

    @Test func toolUsePromptIsFoldedIntoInputSoTotalMatches() {
        // Upstream total = prompt + toolUsePrompt + candidates (+ thoughts). The
        // tool-use prompt is folded into input so the schema total (input+output)
        // equals the authoritative totalTokenCount instead of under-reporting.
        let tokens = usage(#"{"usageMetadata":{"promptTokenCount":100,"toolUsePromptTokenCount":30,"candidatesTokenCount":20,"totalTokenCount":150}}"#,
                           streaming: false)
        #expect(tokens.input == 130)  // prompt + tool-use prompt
        #expect(tokens.output == 20)
        #expect(tokens.reasoning == nil)
        #expect(tokens.total == 150)
    }

    @Test func absentToolUsePromptIsZero() {
        let tokens = usage(#"{"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":20,"totalTokenCount":120}}"#,
                           streaming: false)
        #expect(tokens.input == 100)
        #expect(tokens.output == 20)
        #expect(tokens.total == 120)
    }

    @Test func invalidToolUsePromptIsIgnoredSoInputIsPromptOnly() {
        let tokens = usage(#"{"usageMetadata":{"promptTokenCount":100,"toolUsePromptTokenCount":-5,"candidatesTokenCount":20}}"#,
                           streaming: false)
        #expect(tokens.input == 100) // invalid tool-use never overwrites ⇒ treated as absent/zero
        #expect(tokens.output == 20)
    }

    @Test func overflowingInputSumBecomesUnknown() {
        let tokens = usage(#"{"usageMetadata":{"promptTokenCount":9223372036854775807,"toolUsePromptTokenCount":1,"candidatesTokenCount":2}}"#,
                           streaming: false)
        #expect(tokens.input == nil)
        #expect(tokens.output == 2)
    }

    @Test func totalRecoversSingleMissingSideWithGuards() {
        // Missing input: derived from total - output.
        let missingInput = usage(#"{"usageMetadata":{"candidatesTokenCount":20,"totalTokenCount":50}}"#, streaming: false)
        #expect(missingInput.input == 30)
        #expect(missingInput.output == 20)

        // Missing output: derived from total - input.
        let missingOutput = usage(#"{"usageMetadata":{"promptTokenCount":20,"totalTokenCount":50}}"#, streaming: false)
        #expect(missingOutput.input == 20)
        #expect(missingOutput.output == 30)

        // Never invent a negative value.
        let negative = usage(#"{"usageMetadata":{"candidatesTokenCount":20,"totalTokenCount":10}}"#, streaming: false)
        #expect(negative.input == nil)
        #expect(negative.output == 20)

        // Never overwrite a determined component.
        let inconsistent = usage(#"{"usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":20,"totalTokenCount":999}}"#,
                                 streaming: false)
        #expect(inconsistent.input == 20)
        #expect(inconsistent.output == 20)
    }

    @Test func absentThoughtsIsZeroForOutputButReasoningStaysUnknown() {
        let tokens = usage(#"{"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":7,"totalTokenCount":17}}"#,
                           streaming: false)
        #expect(tokens.input == 10)
        #expect(tokens.output == 7) // no thoughts reported ⇒ output is the candidates
        #expect(tokens.reasoning == nil)
    }

    @Test func explicitZerosAreKnownCounts() {
        let tokens = usage(#"{"usageMetadata":{"promptTokenCount":0,"cachedContentTokenCount":0,"candidatesTokenCount":0,"thoughtsTokenCount":0,"totalTokenCount":0}}"#,
                           streaming: false)
        #expect(tokens.input == 0)
        #expect(tokens.output == 0)
        #expect(tokens.cachedInput == 0)
        #expect(tokens.reasoning == 0)
        #expect(tokens.isComplete)
    }

    @Test func missingUsageMetadataStaysUnknown() {
        #expect(usage(#"{"candidates":[{"content":{"parts":[{"text":"hi"}]}}]}"#, streaming: false) == UsageTokens())
        #expect(usage(#"{"usageMetadata":{}}"#, streaming: false) == UsageTokens())
    }

    @Test func countTokensResponseIsNotGenerationUsage() {
        // `:countTokens` reports only `totalTokens` (an input estimate); it must
        // not be mistaken for generation usage.
        #expect(usage(#"{"totalTokens":123}"#, streaming: false) == UsageTokens())
        #expect(usage(#"{"totalTokens":123,"promptTokensDetails":[{"modality":"TEXT","tokenCount":123}]}"#,
                      streaming: false) == UsageTokens())
    }

    // MARK: - Usage: invalid / hostile numbers

    @Test func invalidNumbersAreIgnoredNotTruncated() {
        let tokens = usage(#"{"usageMetadata":{"promptTokenCount":-3,"cachedContentTokenCount":"12","candidatesTokenCount":true,"thoughtsTokenCount":1.5}}"#,
                           streaming: false)
        #expect(tokens.input == nil)
        #expect(tokens.cachedInput == nil)
        #expect(tokens.output == nil)
        #expect(tokens.reasoning == nil)
    }

    @Test func invalidThoughtsDoesNotOverwriteAndCountsAsUnreported() {
        let tokens = usage(#"{"usageMetadata":{"candidatesTokenCount":5,"thoughtsTokenCount":-1}}"#, streaming: false)
        #expect(tokens.output == 5)   // invalid thoughts is ignored and never seen ⇒ 0
        #expect(tokens.reasoning == nil)
    }

    @Test func overflowingOutputSumBecomesUnknown() {
        let tokens = usage(#"{"usageMetadata":{"candidatesTokenCount":9223372036854775807,"thoughtsTokenCount":1}}"#,
                           streaming: false)
        #expect(tokens.output == nil)
        #expect(tokens.reasoning == 1)
    }

    // MARK: - Usage: streaming snapshots

    @Test func sseCumulativeSnapshotsAreOverwrittenNotSummed() {
        let body = sse(#"{"candidates":[{"content":{"parts":[{"text":"a"}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1}}"#)
            + sse(#"{"candidates":[{"content":{"parts":[{"text":"b"}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":7,"thoughtsTokenCount":2}}"#)
            + "data: [DONE]\n\n"
        let tokens = usage(body, streaming: true, chunk: 5)
        #expect(tokens.input == 10)
        #expect(tokens.output == 9)  // final snapshot, never 1 + 7 + 2
        #expect(tokens.reasoning == 2)
    }

    @Test func partialSnapshotsRetainReportedOptionalComponents() {
        // A cumulative snapshot may omit an already-reported optional field; its
        // earlier value must stay in the sum rather than dropping out.
        let dropThoughts = usage(sse(#"{"usageMetadata":{"candidatesTokenCount":5,"thoughtsTokenCount":2}}"#)
            + sse(#"{"usageMetadata":{"candidatesTokenCount":6}}"#)
            + "data: [DONE]\n\n", streaming: true)
        #expect(dropThoughts.output == 8) // candidates 6 + retained thoughts 2, not 6
        #expect(dropThoughts.reasoning == 2)

        let dropCandidates = usage(sse(#"{"usageMetadata":{"candidatesTokenCount":5,"thoughtsTokenCount":2}}"#)
            + sse(#"{"usageMetadata":{"thoughtsTokenCount":3}}"#)
            + "data: [DONE]\n\n", streaming: true)
        #expect(dropCandidates.output == 8) // retained candidates 5 + thoughts 3, not 7
        #expect(dropCandidates.reasoning == 3)

        // Explicit 0 resets; an invalid update keeps the last valid value.
        let explicitZero = usage(sse(#"{"usageMetadata":{"candidatesTokenCount":5,"thoughtsTokenCount":2}}"#)
            + sse(#"{"usageMetadata":{"candidatesTokenCount":5,"thoughtsTokenCount":0}}"#), streaming: true)
        #expect(explicitZero.output == 5)
        #expect(explicitZero.reasoning == 0)

        let invalidAfter = usage(sse(#"{"usageMetadata":{"candidatesTokenCount":5,"thoughtsTokenCount":2}}"#)
            + sse(#"{"usageMetadata":{"candidatesTokenCount":6,"thoughtsTokenCount":-1}}"#), streaming: true)
        #expect(invalidAfter.output == 8) // retained thoughts 2
        #expect(invalidAfter.reasoning == 2)
    }

    @Test func sseFinalUsageEventWinsAfterDeltas() {
        let body = sse(#"{"candidates":[{"content":{"parts":[{"text":"Hel"}]}}]}"#)
            + sse(#"{"candidates":[{"content":{"parts":[{"text":"lo"}]}}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":3,"thoughtsTokenCount":1}}"#)
        let tokens = usage(body, streaming: true)
        #expect(tokens.input == 8)
        #expect(tokens.output == 4)
        #expect(tokens.reasoning == 1)
    }

    @Test func fragmentedCRLFSSEIsParsed() {
        let body = "data: {\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":2}}\r\n\r\n"
            + "data: [DONE]\r\n\r\n"
        let tokens = usage(body, streaming: true, chunk: 4)
        #expect(tokens.input == 3)
        #expect(tokens.output == 2)
    }

    @Test func multilineSSEEventJoinsDataLines() {
        let body = """
        data: {"usageMetadata":
        data: {"promptTokenCount":11,"candidatesTokenCount":4}}

        """
        let tokens = usage(body, streaming: true, chunk: 5)
        #expect(tokens.input == 11)
        #expect(tokens.output == 4)
    }

    @Test func nativeJSONArrayStreamingCapturesLastSnapshot() {
        let array = #"[{"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":1}},{"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":9,"thoughtsTokenCount":3}}]"#
        // Non-SSE streaming is delivered with an application/json content type,
        // so the parser buffers it as a non-streaming body.
        let buffered = usage(array, streaming: false)
        #expect(buffered.input == 5)
        #expect(buffered.output == 12)
        #expect(buffered.reasoning == 3)
        // Same body mislabeled as SSE still resolves the array (no data: framing).
        let framed = usage(array, streaming: true)
        #expect(framed.input == 5)
        #expect(framed.output == 12)
    }

    @Test func oversizedNonStreamBodyStaysUnknown() {
        var parser = UsageParser(source: .gemini, streaming: false)
        parser.ingest(Data(count: (16 << 20) + 1))
        parser.ingest(Data(#"{"usageMetadata":{"promptTokenCount":1}}"#.utf8))
        parser.finish()
        #expect(parser.snapshot.input == nil)
    }

    // MARK: - Usage: accumulator endpoint mapping

    @Test func accumulatorMapsGeminiEndpointAndContentType() {
        let streaming = UsageAccumulator(endpoint: .gemini, contentType: "text/event-stream; charset=utf-8")
        streaming.ingest(Data(sse(#"{"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":3}}"#).utf8))
        streaming.finish()
        #expect(streaming.tokens.input == 8)
        #expect(streaming.tokens.output == 3)

        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        buffer.writeString(#"{"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":1}}"#)
        let json = UsageAccumulator(endpoint: .gemini, contentType: "application/json")
        json.ingest(buffer)
        json.finish()
        #expect(json.tokens.input == 4)
        #expect(json.tokens.output == 1)
    }

    // MARK: - Performance helpers

    private func at(_ nanos: UInt64) -> DispatchTime { DispatchTime(uptimeNanoseconds: nanos) }

    private func performanceParser(_ contentType: String? = "text/event-stream",
                                   requestStart: UInt64 = 0,
                                   attemptStart: UInt64 = 1_000_000) -> PerformanceParser {
        PerformanceParser(source: .gemini, streaming: (contentType ?? "").contains("text/event-stream"),
                          requestStart: at(requestStart), attemptStart: at(attemptStart))
    }

    private func sseData(_ json: String, crlf: Bool = false) -> Data {
        Data("data: \(json)\(crlf ? "\r\n\r\n" : "\n\n")".utf8)
    }

    private func approx(_ value: Double?, _ expected: Double, tolerance: Double = 0.001) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    // MARK: - Performance: semantic deltas

    @Test func textDeltaCountsAndLifecycleIsExcluded() {
        var p = performanceParser()
        // role-only candidate must not count nor start the clock.
        p.ingest(sseData(#"{"candidates":[{"content":{"role":"model"},"index":0}]}"#), at: at(1_500_000))
        // empty text part is not output.
        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"text":""}]}}]}"#), at: at(1_800_000))
        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"text":"Hel"}]}}]}"#), at: at(2_000_000))
        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"text":"lo world"}]}}]}"#), at: at(3_000_000))
        p.finish(at: at(6_000_000))

        let perf = p.makePerformance()
        #expect(perf.streaming)
        #expect(perf.outputDeltaCount == 2)
        #expect(approx(perf.ttftMS, 1))         // first text at 2ms, attempt start 1ms
        #expect(approx(perf.requestTTFTMS, 2))  // 2ms - 0
        #expect(approx(perf.generationMS, 4))   // 6ms - 2ms
    }

    @Test func thoughtTextCounts() {
        var p = performanceParser()
        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"text":"pondering","thought":true}]}}]}"#), at: at(2_000_000))
        p.finish(at: at(5_000_000))
        #expect(p.outputDeltaCount == 1)
        #expect(approx(p.makePerformance().ttftMS, 1))
    }

    @Test func functionCallWithNonEmptyNameCountsIncludingZeroArg() {
        // Zero-arg tool: a name with no args is a legal, meaningful call.
        var noArgs = performanceParser()
        noArgs.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"list_files"}}]}}]}"#), at: at(1_500_000))
        noArgs.finish(at: at(3_000_000))
        #expect(noArgs.outputDeltaCount == 1)
        #expect(approx(noArgs.makePerformance().ttftMS, 0.5))

        // Explicit empty args also counts.
        var emptyArgs = performanceParser()
        emptyArgs.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"noop","args":{}}}]}}]}"#), at: at(2_000_000))
        emptyArgs.finish(at: at(3_000_000))
        #expect(emptyArgs.outputDeltaCount == 1)

        // A call with args still counts.
        var withArgs = performanceParser()
        withArgs.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{"city":"SF"}}}]}}]}"#), at: at(2_000_000))
        withArgs.finish(at: at(3_000_000))
        #expect(withArgs.outputDeltaCount == 1)

        // Empty name is not a function call.
        var unnamed = performanceParser()
        unnamed.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"","args":{"a":1}}}]}}]}"#), at: at(2_000_000))
        unnamed.finish(at: at(3_000_000))
        #expect(unnamed.outputDeltaCount == 0)
        #expect(unnamed.makePerformance().ttftMS == nil)
    }

    @Test func inlineMultimodalDataCountsWhenValid() {
        var p = performanceParser()
        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"iVBORw0KGgo="}}]}}]}"#), at: at(2_000_000))
        p.finish(at: at(3_000_000))
        #expect(p.outputDeltaCount == 1)

        var bad = performanceParser()
        // Missing payload / mime type is not a valid multimodal result.
        bad.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":""}}]}}]}"#), at: at(2_000_000))
        bad.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"inlineData":{"data":"abc"}}]}}]}"#), at: at(2_500_000))
        bad.finish(at: at(3_000_000))
        #expect(bad.outputDeltaCount == 0)
    }

    @Test func signatureOnlyEmptyAndMetadataEventsAreIgnored() {
        var p = performanceParser()
        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"thoughtSignature":"c2lnbmF0dXJl"}]}}]}"#), at: at(1_200_000))
        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{}]}}]}"#), at: at(1_400_000))
        p.ingest(sseData(#"{"candidates":[{"finishReason":"STOP","safetyRatings":[{"category":"HARM_CATEGORY_HATE_SPEECH"}]}]}"#), at: at(1_600_000))
        p.ingest(sseData(#"{"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":4,"totalTokenCount":9}}"#), at: at(1_800_000))
        p.finish(at: at(3_000_000))

        let perf = p.makePerformance()
        #expect(perf.outputDeltaCount == 0)
        #expect(perf.ttftMS == nil)
        #expect(perf.generationMS == nil)
    }

    @Test func singleEventWithMultiplePartsCountsOnce() {
        var p = performanceParser()
        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"text":"a"},{"text":"b","thought":true},{"functionCall":{"name":"f","args":{"x":1}}}]}}]}"#),
                 at: at(1_000_000))
        p.finish(at: at(2_000_000))
        let perf = p.makePerformance()
        #expect(perf.outputDeltaCount == 1)
    }

    @Test func chunksSplittingLinesAndCRLFAreSafe() {
        var p = performanceParser()
        let full = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hello\"}]}}]}\r\n\r\n".utf8)
        p.ingest(Data(full.prefix(14)), at: at(2_000_000))
        p.ingest(Data(full.dropFirst(14).prefix(10)), at: at(2_100_000))
        p.ingest(Data(full.dropFirst(24)), at: at(2_200_000))
        #expect(p.outputDeltaCount == 1)
        #expect(approx(p.makePerformance().ttftMS, 1.2)) // pinned to the completing chunk

        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"text":"!"}]}}]}"#), at: at(3_000_000))
        p.finish(at: at(4_000_000))
        #expect(p.outputDeltaCount == 2)
    }

    @Test func nonSSEJSONArrayYieldsNoPerformanceSamples() {
        var p = performanceParser("application/json")
        p.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}"#), at: at(2_000_000))
        p.finish(at: at(3_000_000))
        let perf = p.makePerformance()
        #expect(!perf.streaming)
        #expect(perf.outputDeltaCount == 0)
        #expect(perf.ttftMS == nil)
        #expect(perf.generationMS == nil)
    }

    @Test func accumulatorMapsGeminiPerformanceEndpoint() {
        let accumulator = PerformanceAccumulator(
            endpoint: .gemini, contentType: "text/event-stream",
            requestStart: at(0), attemptStart: at(1_000_000))
        accumulator.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}"#))
        accumulator.ingest(sseData(#"{"candidates":[{"content":{"parts":[{"text":"!"}]}}]}"#))
        let partial = accumulator.performance
        #expect(partial.streaming)
        #expect(partial.outputDeltaCount == 2)
        #expect(partial.ttftMS != nil)
        #expect(partial.generationMS == nil) // body has not ended yet
    }
}
