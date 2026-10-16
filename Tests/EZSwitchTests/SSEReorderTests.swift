import Foundation
import Testing
@testable import EZSwitch

/// SSEReorderer 的行为测试：把交错输出项的流收拢成 Codex 能正确跟踪的顺序。
@Suite("SSE reorder")
struct SSEReorderTests {

    // MARK: helpers

    private func sse(_ type: String, index: Int?, itemId: String?, extra: String = "", ending: String = "\n") -> String {
        var fields = ["\"type\":\"\(type)\""]
        if let index { fields.append("\"output_index\":\(index)") }
        if let itemId { fields.append("\"item_id\":\"\(itemId)\"") }
        fields.append("\"sequence_number\":0")
        if !extra.isEmpty { fields.append(extra) }
        return "event: \(type)\(ending)data: {\(fields.joined(separator: ","))}\(ending)\(ending)"
    }

    private func run(_ payload: String, chunkSize: Int = 1_000_000) -> (events: [String], reorderer: SSEReorderer) {
        let reorderer = SSEReorderer()
        var out = Data()
        let bytes = Array(payload.utf8)
        var i = 0
        while i < bytes.count {
            let end = min(i + chunkSize, bytes.count)
            for block in reorderer.consume(Data(bytes[i..<end])) { out.append(block) }
            i = end
        }
        for block in reorderer.finish() { out.append(block) }
        let text = String(decoding: out, as: UTF8.self)
        let names = text.components(separatedBy: "\n\n").compactMap { block -> String? in
            guard !block.isEmpty else { return nil }
            for line in block.split(separator: "\n") where line.hasPrefix("event: ") {
                return String(line.dropFirst(7))
            }
            return nil
        }
        return (names, reorderer)
    }

    // MARK: 复现上游交错（报告的问题）

    private func interleavedStream(ending: String = "\n") -> String {
        sse("response.created", index: nil, itemId: nil, ending: ending)
            + sse("response.in_progress", index: nil, itemId: nil, ending: ending)
            + sse("response.output_item.added", index: 0, itemId: "rs_1", extra: "\"item\":{\"type\":\"reasoning\"}", ending: ending)
            + sse("response.reasoning.delta", index: 0, itemId: "rs_1", extra: "\"delta\":\"想\"", ending: ending)
            + sse("response.output_item.added", index: 1, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}", ending: ending)
            + sse("response.content_part.added", index: 1, itemId: "msg_1", ending: ending)
            + sse("response.reasoning.done", index: 0, itemId: "rs_1", ending: ending)
            + sse("response.output_item.done", index: 0, itemId: "rs_1", extra: "\"item\":{\"type\":\"reasoning\"}", ending: ending)
            + sse("response.output_text.delta", index: 1, itemId: "msg_1", extra: "\"delta\":\"一\"", ending: ending)
            + sse("response.output_text.done", index: 1, itemId: "msg_1", ending: ending)
            + sse("response.content_part.done", index: 1, itemId: "msg_1", ending: ending)
            + sse("response.output_item.done", index: 1, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}", ending: ending)
            + sse("response.completed", index: nil, itemId: nil, ending: ending)
    }

    /// 交错流重排后的规范顺序（与行结束符无关）。
    private let interleavedExpected = [
        "response.created",
        "response.in_progress",
        "response.output_item.added",      // idx=0 开
        "response.reasoning.delta",
        "response.reasoning.done",
        "response.output_item.done",       // idx=0 收尾 —— 必须早于 idx=1 的开场
        "response.output_item.added",      // idx=1 开
        "response.content_part.added",
        "response.output_text.delta",
        "response.output_text.done",
        "response.content_part.done",
        "response.output_item.done",       // idx=1 收尾
        "response.completed",
    ]

    @Test
    func interleavedBlocksAreCollapsed() {
        let (events, reorderer) = run(interleavedStream())
        #expect(events == interleavedExpected, "交错事件应按输出项收拢为原子块")
        #expect(reorderer.pendingCount == 0, "流结束后不应还有扣住的事件")
    }

    /// 关键断言：文本增量必须落在它所属项的 added 之后、done 之前，
    /// 否则 Codex 会报 "OutputTextDelta without active item" 并丢字。
    @Test
    func textDeltaSitsInsideItsItemBlock() throws {
        let (events, _) = run(interleavedStream())
        // 第一个 output_item.done（idx=0 推理项）必须早于 message 的开场
        let done0 = try #require(events.firstIndex(of: "response.output_item.done"))
        let added1 = try #require(events.firstIndex(of: "response.output_item.added", after: done0 + 1))
        let delta = try #require(events.firstIndex(of: "response.output_text.delta"))
        let done1 = try #require(events.lastIndex(of: "response.output_item.done"))
        try #require(done0 < added1, "前一项必须先收尾，后一项才开场")
        try #require(added1 < delta, "idx=1 的 added 必须先于它的 delta")
        try #require(delta < done1, "delta 必须落在自身项的收尾之前")
        // 该项区间内不应夹带前一项的收尾事件（交错的特征）
        let slice = Array(events[added1...done1])
        #expect(slice.filter { $0 == "response.reasoning.done" }.count == 0,
                "message 块内不应再出现推理项的收尾事件")
    }

    // MARK: 规范流应当是恒等变换

    @Test
    func wellFormedStreamIsUnchanged() {
        let stream = sse("response.created", index: nil, itemId: nil)
            + sse("response.output_item.added", index: 0, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}")
            + sse("response.content_part.added", index: 0, itemId: "msg_1")
            + sse("response.output_text.delta", index: 0, itemId: "msg_1", extra: "\"delta\":\"甲\"")
            + sse("response.output_text.delta", index: 0, itemId: "msg_1", extra: "\"delta\":\"乙\"")
            + sse("response.output_text.done", index: 0, itemId: "msg_1")
            + sse("response.content_part.done", index: 0, itemId: "msg_1")
            + sse("response.output_item.done", index: 0, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}")
            + sse("response.completed", index: nil, itemId: nil)
        let (events, reorderer) = run(stream)
        #expect(events == [
            "response.created",
            "response.output_item.added",
            "response.content_part.added",
            "response.output_text.delta",
            "response.output_text.delta",
            "response.output_text.done",
            "response.content_part.done",
            "response.output_item.done",
            "response.completed",
        ])
        #expect(reorderer.pendingCount == 0)
    }

    /// 字节被任意切分（真实网络行为）不应影响结果
    @Test
    func chunkBoundariesDoNotMatter() {
        let whole = run(interleavedStream(), chunkSize: 1_000_000).events
        for size in [1, 3, 7, 64] {
            #expect(run(interleavedStream(), chunkSize: size).events == whole,
                    "按 \(size) 字节切分时结果应与整块一致")
        }
    }

    // MARK: 行结束符：LF / CRLF / CR
    //
    // 报告的问题：consume 只按 `\n\n` 分帧，用 CRLF/CR 分帧的合法 SSE 全部滞留到 finish
    // 才被放出（且相对顺序/分帧语义丢失）。以下用例覆盖三种行结束符、跨 chunk 的 CRLF
    // 边界，以及混合行结束符。

    private func endingName(_ ending: String) -> String {
        switch ending {
        case "\r\n": return "CRLF"
        case "\r":   return "CR"
        default:     return "LF"
        }
    }

    /// 同样的 JSON 事件，无论用 LF、CRLF 还是单独的 CR 分帧，重排结果都必须一致，
    /// 且不允许有任何事件只因分帧符不同而滞留到 finish 才放行。
    @Test
    func lineEndingsProduceIdenticalReordering() {
        for ending in ["\n", "\r\n", "\r"] {
            let (events, reorderer) = run(interleavedStream(ending: ending))
            #expect(events == interleavedExpected, "\(endingName(ending)) 分帧下重排结果应与 LF 一致")
            #expect(reorderer.pendingCount == 0, "\(endingName(ending)) 分帧下流结束不应还有扣住的事件")
            #expect(reorderer.stats.releasedAtFinish == 0,
                    "\(endingName(ending)) 分帧下事件应在流内被识别，而不是靠 finish 兜底")
        }
    }

    /// CRLF 被逐字节切分时必然出现 `\r` 与 `\n` 分处两个 chunk 的边界，
    /// 二者必须合起来算一个行结束符，不能被误当成"CR 结束空行 + LF 结束空行"。
    @Test
    func crlfSplitAcrossChunkBoundaryIsOneTerminator() {
        let whole = run(interleavedStream(ending: "\r\n")).events
        #expect(whole == interleavedExpected)
        for size in [1, 2, 3, 5, 7, 64] {
            #expect(run(interleavedStream(ending: "\r\n"), chunkSize: size).events == whole,
                    "CRLF 流按 \(size) 字节切分（含 \\r|\\n 边界）结果应与整块一致")
        }
    }

    /// 只用 CR 分帧的流逐字节喂入同样成立。
    @Test
    func crOnlyStreamChunkedByteByByte() {
        let whole = run(interleavedStream(ending: "\r")).events
        #expect(whole == interleavedExpected)
        for size in [1, 2, 3, 5, 7, 64] {
            #expect(run(interleavedStream(ending: "\r"), chunkSize: size).events == whole,
                    "CR 流按 \(size) 字节切分结果应与整块一致")
        }
    }

    /// 同一条流里混用不同行结束符（中转偶发），仍要正确分帧并按输出项重排。
    @Test
    func mixedLineEndingsStillReorder() {
        let stream = sse("response.created", index: nil, itemId: nil, ending: "\r\n")
            + sse("response.output_item.added", index: 0, itemId: "rs_1", extra: "\"item\":{\"type\":\"reasoning\"}", ending: "\n")
            + sse("response.output_item.added", index: 1, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}", ending: "\r")
            + sse("response.reasoning.done", index: 0, itemId: "rs_1", ending: "\r\n")
            + sse("response.output_item.done", index: 0, itemId: "rs_1", extra: "\"item\":{\"type\":\"reasoning\"}", ending: "\n")
            + sse("response.output_text.delta", index: 1, itemId: "msg_1", extra: "\"delta\":\"一\"", ending: "\r")
            + sse("response.output_item.done", index: 1, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}", ending: "\r\n")
            + sse("response.completed", index: nil, itemId: nil, ending: "\n")
        let (events, reorderer) = run(stream)
        #expect(events == [
            "response.created",
            "response.output_item.added",   // reasoning
            "response.reasoning.done",
            "response.output_item.done",
            "response.output_item.added",   // message
            "response.output_text.delta",
            "response.output_item.done",
            "response.completed",
        ])
        #expect(reorderer.pendingCount == 0)
    }

    // MARK: EOF 语义（SSE 规范：不完整尾部不得当作完整事件）

    /// 末尾缺少空行的事件没有结束，EOF 时按规范丢弃，不写进下游。
    @Test
    func incompleteTailAtEOFIsDiscarded() {
        let complete = sse("response.created", index: nil, itemId: nil)
        let trailing = "data: {\"type\":\"response.in_progress\",\"sequence_number\":0}"   // 无行结束符
        let (events, _) = run(complete + trailing)
        #expect(events == ["response.created"], "未以空行结束的尾部不得当成完整事件写出")
    }

    /// 只有行结束符、没有空行的单行数据同样不构成完整事件。
    @Test
    func trailingCRWithoutBlankLineIsDiscarded() {
        let (events, _) = run("data: {\"type\":\"response.created\",\"sequence_number\":0}\r")
        #expect(events.isEmpty, "缺少空行的事件在 EOF 时应被丢弃")
    }

    /// 以 `\r\r` 收尾时，EOF 恰好补齐了空行，该事件是完整的，必须写出。
    @Test
    func eventTerminatedAtEOFByCRCRIsEmitted() {
        let stream = sse("response.created", index: nil, itemId: nil, ending: "\r")
        let (events, reorderer) = run(stream)
        #expect(events == ["response.created"])
        #expect(reorderer.pendingCount == 0)
    }

    // MARK: 异常流兜底

    @Test
    func unclosedItemIsReleasedAtFinish() {
        let stream = sse("response.output_item.added", index: 0, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}")
            + sse("response.output_text.delta", index: 0, itemId: "msg_1", extra: "\"delta\":\"甲\"")
        let (events, reorderer) = run(stream)   // 上游没发 done 就断了
        #expect(events == ["response.output_item.added", "response.output_text.delta"],
                "不完整流也不能吞事件")
        #expect(reorderer.stats.releasedAtFinish == 2)
    }

    // MARK: 三个输出项（推理 + 文本 + 工具调用）

    @Test
    func threeItemsWithToolCallStayOrdered() {
        let stream = sse("response.output_item.added", index: 0, itemId: "rs_1", extra: "\"item\":{\"type\":\"reasoning\"}")
            + sse("response.reasoning.delta", index: 0, itemId: "rs_1", extra: "\"delta\":\"想\"")
            + sse("response.output_item.added", index: 1, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}")
            + sse("response.reasoning.done", index: 0, itemId: "rs_1")
            + sse("response.output_item.done", index: 0, itemId: "rs_1", extra: "\"item\":{\"type\":\"reasoning\"}")
            + sse("response.output_text.delta", index: 1, itemId: "msg_1", extra: "\"delta\":\"甲\"")
            + sse("response.output_item.added", index: 2, itemId: "fc_1", extra: "\"item\":{\"type\":\"function_call\"}")
            + sse("response.output_text.done", index: 1, itemId: "msg_1")
            + sse("response.output_item.done", index: 1, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}")
            + sse("response.function_call_arguments.delta", index: 2, itemId: "fc_1", extra: "\"delta\":\"{}\"")
            + sse("response.output_item.done", index: 2, itemId: "fc_1", extra: "\"item\":{\"type\":\"function_call\"}")
            + sse("response.completed", index: nil, itemId: nil)
        let (events, reorderer) = run(stream)
        #expect(events == [
            "response.output_item.added",             // reasoning
            "response.reasoning.delta",
            "response.reasoning.done",
            "response.output_item.done",
            "response.output_item.added",             // message
            "response.output_text.delta",
            "response.output_text.done",
            "response.output_item.done",
            "response.output_item.added",             // function_call
            "response.function_call_arguments.delta",
            "response.output_item.done",
            "response.completed",
        ])
        #expect(reorderer.pendingCount == 0)
    }

    /// sequence_number 重排后应保持严格单调
    @Test
    func sequenceNumbersAreRenumberedMonotonically() {
        let reorderer = SSEReorderer()
        var out = Data()
        for block in reorderer.consume(Data(interleavedStream().utf8)) { out.append(block) }
        for block in reorderer.finish() { out.append(block) }
        var seen: [Int] = []
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
            let json = String(line.dropFirst(6))
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let seq = obj["sequence_number"] as? Int {
                seen.append(seq)
            }
        }
        #expect(seen == Array(0..<seen.count), "重编号后应是从 0 起的连续序号")
    }
}

private extension Array where Element == String {
    /// 返回 from 之后第一次出现的下标
    func firstIndex(of value: String, after start: Int) -> Int? {
        guard start < count else { return nil }
        for i in start..<count where self[i] == value { return i }
        return nil
    }

    /// 最后一次出现的下标
    func lastIndex(of value: String) -> Int? {
        for i in stride(from: count - 1, through: 0, by: -1) where self[i] == value { return i }
        return nil
    }
}
