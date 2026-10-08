import Foundation
import NIOCore
import Testing
@testable import EZSwitch

@Suite("Usage parser")
struct UsageParserTests {
    private func parse(_ text: String, source: UsageSource, streaming: Bool, chunk: Int = 4096) -> UsageTokens {
        var parser = UsageParser(source: source, streaming: streaming)
        let bytes = Array(text.utf8)
        for start in stride(from: 0, to: bytes.count, by: max(1, chunk)) {
            parser.ingest(Data(bytes[start..<min(start + chunk, bytes.count)]))
        }
        parser.finish()
        return parser.snapshot
    }

    // MARK: OpenAI Chat Completions

    @Test func chatJSONExtractsAllCounts() {
        let tokens = parse(#"{"usage":{"prompt_tokens":12,"completion_tokens":7,"total_tokens":19,"prompt_tokens_details":{"cached_tokens":3},"completion_tokens_details":{"reasoning_tokens":2}}}"#,
                           source: .chat, streaming: false)
        #expect(tokens.input == 12)
        #expect(tokens.output == 7)
        #expect(tokens.cachedInput == 3)
        #expect(tokens.reasoning == 2)
        #expect(tokens.cacheWrite == nil)
        #expect(tokens.isComplete)
    }

    @Test func chatDeepSeekCacheHitFallsBackWithoutDoubleCounting() {
        let tokens = parse(#"{"usage":{"prompt_tokens":100,"completion_tokens":10,"prompt_cache_hit_tokens":80,"prompt_cache_miss_tokens":20}}"#,
                           source: .chat, streaming: false)
        #expect(tokens.input == 100)         // prompt_tokens is already the total
        #expect(tokens.output == 10)
        #expect(tokens.cachedInput == 80)    // prompt_cache_hit_tokens fallback
    }

    @Test func chatDetailCachedTokensWinsOverDeepSeekField() {
        let tokens = parse(#"{"usage":{"prompt_tokens":100,"completion_tokens":10,"prompt_cache_hit_tokens":80,"prompt_tokens_details":{"cached_tokens":12}}}"#,
                           source: .chat, streaming: false)
        #expect(tokens.input == 100)
        #expect(tokens.cachedInput == 12)
    }

    @Test func explicitZeroIsAKnownCount() {
        let tokens = parse(#"{"usage":{"prompt_tokens":0,"completion_tokens":0}}"#, source: .chat, streaming: false)
        #expect(tokens.input == 0)
        #expect(tokens.output == 0)
        #expect(tokens.isComplete)
    }

    @Test func missingUsageStaysUnknown() {
        let tokens = parse(#"{"id":"chatcmpl","choices":[{"message":{"content":"hi"}}]}"#, source: .chat, streaming: false)
        #expect(tokens.input == nil)
        #expect(tokens.output == nil)
        #expect(!tokens.isComplete)
    }

    @Test func chatSSEUpdatesAreCumulativeNotAdditive() {
        let sse = """
        data: {"usage":{"prompt_tokens":5,"completion_tokens":1}}

        data: {"usage":{"prompt_tokens":5,"completion_tokens":9}}

        data: [DONE]

        """
        let tokens = parse(sse, source: .chat, streaming: true, chunk: 3)
        #expect(tokens.input == 5)
        #expect(tokens.output == 9)
    }

    @Test func fragmentedCRLFStreamIsParsed() {
        let sse = "data: {\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\r\n\r\ndata: [DONE]\r\n\r\n"
        let tokens = parse(sse, source: .chat, streaming: true, chunk: 4)
        #expect(tokens.input == 3)
        #expect(tokens.output == 2)
    }

    @Test func multilineSSEEventJoinsDataLines() {
        let sse = """
        data: {"usage":
        data: {"prompt_tokens":11,"completion_tokens":4}}

        """
        let tokens = parse(sse, source: .chat, streaming: true, chunk: 5)
        #expect(tokens.input == 11)
        #expect(tokens.output == 4)
    }

    // MARK: OpenAI Responses

    @Test func responsesJSONExtractsCounts() {
        let tokens = parse(#"{"id":"resp_1","usage":{"input_tokens":11,"output_tokens":6,"input_tokens_details":{"cached_tokens":2},"output_tokens_details":{"reasoning_tokens":1}}}"#,
                           source: .responses, streaming: false)
        #expect(tokens.input == 11)
        #expect(tokens.output == 6)
        #expect(tokens.cachedInput == 2)
        #expect(tokens.reasoning == 1)
    }

    @Test func responsesSSECompletedCarriesNestedUsage() {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"hi"}

        data: {"type":"response.completed","response":{"usage":{"input_tokens":20,"output_tokens":9,"input_tokens_details":{"cached_tokens":4},"output_tokens_details":{"reasoning_tokens":3}}}}

        """
        let tokens = parse(sse, source: .responses, streaming: true, chunk: 7)
        #expect(tokens.input == 20)
        #expect(tokens.output == 9)
        #expect(tokens.cachedInput == 4)
        #expect(tokens.reasoning == 3)
    }

    // MARK: Anthropic Messages

    @Test func anthropicJSONTotalsInputWithCache() {
        let tokens = parse(#"{"usage":{"input_tokens":10,"output_tokens":8,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}}"#,
                           source: .messages, streaming: false)
        #expect(tokens.input == 17)          // uncached + cache read + cache write
        #expect(tokens.output == 8)
        #expect(tokens.cachedInput == 5)
        #expect(tokens.cacheWrite == 2)
    }

    @Test func anthropicSSEMergesStartAndDeltaCumulatively() {
        let sse = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":0,"output_tokens":1}}}

        data: {"type":"message_delta","usage":{"output_tokens":20}}

        data: {"type":"message_stop"}

        """
        let tokens = parse(sse, source: .messages, streaming: true, chunk: 6)
        #expect(tokens.input == 15)
        #expect(tokens.output == 20)
        #expect(tokens.cachedInput == 5)
        #expect(tokens.cacheWrite == 0)
        #expect(tokens.isComplete)
    }

    @Test func anthropicCacheWithoutInputLeavesInputUnknown() {
        let tokens = parse(#"{"usage":{"cache_read_input_tokens":30,"output_tokens":4}}"#, source: .messages, streaming: false)
        #expect(tokens.input == nil)         // ordinary input never reported → unknown
        #expect(tokens.cachedInput == 30)
        #expect(tokens.output == 4)
        #expect(!tokens.isComplete)
    }

    // MARK: Invalid / hostile numbers

    @Test func invalidNumbersAreIgnoredNotTruncated() {
        let tokens = parse(#"{"usage":{"prompt_tokens":-3,"completion_tokens":true,"reasoning_tokens":1.5,"cache_read_input_tokens":"12"}}"#,
                           source: .chat, streaming: false)
        #expect(tokens.input == nil)
        #expect(tokens.output == nil)
        #expect(tokens.reasoning == nil)
    }

    @Test func invalidUpdateDoesNotClobberKnownValue() {
        let sse = """
        data: {"usage":{"prompt_tokens":5,"completion_tokens":4}}

        data: {"usage":{"prompt_tokens":-1}}

        data: [DONE]

        """
        let tokens = parse(sse, source: .chat, streaming: true)
        #expect(tokens.input == 5)
        #expect(tokens.output == 4)
    }

    @Test func hugeAndOverflowingNumbersBecomeUnknown() {
        // 2^53 + 1 would round to 2^53 through `doubleValue`; exact parsing keeps it exact.
        let exact = parse(#"{"usage":{"prompt_tokens":9007199254740993}}"#, source: .chat, streaming: false)
        #expect(exact.input == 9_007_199_254_740_993)
        let overflow = parse(#"{"usage":{"prompt_tokens":1000000000000000000000000000000}}"#, source: .chat, streaming: false)
        #expect(overflow.input == nil)
        #expect(UsageParser.integer(NSNumber(value: Int64.max)) == Int.max)
        #expect(UsageParser.integer(NSNumber(value: UInt64.max)) == nil)
        #expect(UsageParser.integer(NSNumber(value: true)) == nil)
        #expect(UsageParser.integer(NSNumber(value: -4)) == nil)
        #expect(UsageParser.integer(NSNumber(value: 1.5)) == nil)
        #expect(UsageParser.integer("12") == nil)
        #expect(UsageParser.integer(nil) == nil)
    }

    @Test func anthropicInputTotalOverflowStaysUnknown() {
        let tokens = parse(#"{"usage":{"input_tokens":9223372036854775807,"cache_read_input_tokens":1}}"#,
                           source: .messages, streaming: false)
        #expect(tokens.input == nil)
        #expect(tokens.cachedInput == 1)
    }

    @Test func addIsOverflowSafe() {
        #expect(UsageParser.add(3, 4) == 7)
        #expect(UsageParser.add(nil, 5) == 5)
        #expect(UsageParser.add(5, nil) == 5)
        #expect(UsageParser.add(nil, nil) == nil)
        #expect(UsageParser.add(Int.max, 1) == nil)
    }

    // MARK: Bounds and recovery

    @Test func oversizedSSEEventRecoversForFinalUsage() {
        let pad = String(repeating: "a", count: 1_200_000)
        let sse = "data: {\"pad\":\"" + pad + "\"}\n\n"
            + "data: {\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2}}\n\n"
        let tokens = parse(sse, source: .chat, streaming: true, chunk: 64 * 1024)
        #expect(tokens.input == 7)
        #expect(tokens.output == 2)
    }

    @Test func oversizedNonStreamBodyIsUnknown() {
        var parser = UsageParser(source: .chat, streaming: false)
        parser.ingest(Data(count: (16 << 20) + 1))
        parser.ingest(Data(#"{"usage":{"prompt_tokens":1}}"#.utf8))
        parser.finish()
        #expect(parser.snapshot.input == nil)
    }

    // MARK: Accumulator plumbing

    @Test func accumulatorDetectsStreamingFromContentType() {
        let sse = "data: {\"usage\":{\"input_tokens\":8,\"output_tokens\":3}}\n\n"
        let streaming = UsageAccumulator(endpoint: .responses, contentType: "text/event-stream; charset=utf-8")
        streaming.ingest(Data(sse.utf8))
        streaming.finish()
        #expect(streaming.tokens.input == 8)
        #expect(streaming.tokens.output == 3)

        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        buffer.writeString(#"{"usage":{"input_tokens":4,"output_tokens":1}}"#)
        let json = UsageAccumulator(endpoint: .responses, contentType: "application/json")
        json.ingest(buffer)
        json.finish()
        #expect(json.tokens.input == 4)
        #expect(json.tokens.output == 1)
    }
}
