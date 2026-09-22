import Foundation
import Testing
@testable import EZSwitch

/// SSEReorderer 的行为测试：把交错输出项的流收拢成 Codex 能正确跟踪的顺序。
@Suite("SSE reorder")
struct SSEReorderTests {

    // MARK: helpers

    private func sse(_ type: String, index: Int?, itemId: String?, extra: String = "") -> String {
        var fields = ["\"type\":\"\(type)\""]
        if let index { fields.append("\"output_index\":\(index)") }
        if let itemId { fields.append("\"item_id\":\"\(itemId)\"") }
        fields.append("\"sequence_number\":0")
        if !extra.isEmpty { fields.append(extra) }
        return "event: \(type)\ndata: {\(fields.joined(separator: ","))}\n\n"
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

    private func interleavedStream() -> String {
        sse("response.created", index: nil, itemId: nil)
            + sse("response.in_progress", index: nil, itemId: nil)
            + sse("response.output_item.added", index: 0, itemId: "rs_1", extra: "\"item\":{\"type\":\"reasoning\"}")
            + sse("response.reasoning.delta", index: 0, itemId: "rs_1", extra: "\"delta\":\"想\"")
            + sse("response.output_item.added", index: 1, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}")
            + sse("response.content_part.added", index: 1, itemId: "msg_1")
            + sse("response.reasoning.done", index: 0, itemId: "rs_1")
            + sse("response.output_item.done", index: 0, itemId: "rs_1", extra: "\"item\":{\"type\":\"reasoning\"}")
            + sse("response.output_text.delta", index: 1, itemId: "msg_1", extra: "\"delta\":\"一\"")
            + sse("response.output_text.done", index: 1, itemId: "msg_1")
            + sse("response.content_part.done", index: 1, itemId: "msg_1")
            + sse("response.output_item.done", index: 1, itemId: "msg_1", extra: "\"item\":{\"type\":\"message\"}")
            + sse("response.completed", index: nil, itemId: nil)
    }

    @Test
    func interleavedBlocksAreCollapsed() {
        let (events, reorderer) = run(interleavedStream())
        let expected = [
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
        #expect(events == expected, "交错事件应按输出项收拢为原子块")
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
