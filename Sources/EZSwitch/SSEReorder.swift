import Foundation

/// OpenAI Responses API 的 SSE 事件顺序规范化器。
///
/// 背景：Codex 解析流时只跟踪"当前活跃输出项"——`response.output_item.added` 开一项，
/// 后续 `response.output_text.delta` 等按 item 累加，`response.output_item.done` 收尾。
/// 部分中转上游（实测 deepseek/* 经中转站）在**开启推理**时会交错发出：
///
///     82 response.output_item.added   idx=1 (message)   ← 推理项 idx=0 还没 done
///     83 response.content_part.added  idx=1
///     84 response.reasoning.done      idx=0             ← 迟到的收尾
///     85 response.output_item.done    idx=0
///     86 response.output_text.delta   idx=1             ← 活跃项已错位 → Codex 丢弃增量
///
/// Codex 报 `OutputTextDelta without active item` 并丢弃这些增量，表现为流式渲染缺字。
/// 本组件把每个输出项的 added…done 区间收拢成原子块再按序放出：某项未收尾前，它后面
/// 的事件一律扣住。事件流本就规范时（无交错）输入 = 输出，是恒等变换。
///
/// 只用于 `/v1/responses` 的 text/event-stream 响应；chat / messages 端点不经过这里。
/// 重排会让上游 `sequence_number` 乱序，因此写出的每个事件按输出顺序统一重编号。
final class SSEReorderer {
    private struct Event {
        let raw: Data           // data: 行的 JSON 字节（原始内容）
        let name: String?       // event: 名（原样回写，不信任 data.type）
        let index: Int?         // payload.output_index
        let opensItem: Bool     // payload.type == response.output_item.added
        let closesItem: Bool    // payload.type == response.output_item.done
    }

    private var pending: [Event] = []
    private var knownIndexes: Set<Int> = []     // 见过的输出项（含已收尾的）
    private var openIndexes: Set<Int> = []      // 尚未收到 output_item.done 的
    private var buffer = Data()                 // 尚未凑出空行（事件边界）的字节
    private var emittedCount = 0

    private(set) var stats = Stats()

    struct Stats {
        var emitted = 0
        var heldEvents = 0        // 入队等待的事件数
        var releasedAtFinish = 0  // 流结束时仍被扣住的（异常流兜底）
        var overflowFlushes = 0   // 超过上限强制放行的次数
        var parseFailures = 0
    }

    /// 扣住事件数的上限：上游流不完整时不至于无限增长（超出即强制按序放行）。
    private let maxHeld = 2000

    // MARK: 入口

    /// 喂入上游字节，返回按规范顺序可写出的 SSE 块。
    ///
    /// 事件边界按 SSE 规范识别：空行（两个连续行结束符）结束一个事件，行结束符可以是
    /// LF、CRLF 或单独的 CR——上游有的用 `\n\n`，有的用 `\r\n\r\n`，不能只认 LF。
    /// 与字节切分的交互：chunk 末尾的单个 CR 可能是尚未到达的 CRLF 的前半，必须留到下一
    /// 个 chunk 再判定，否则 `...\r` + `\n\r\n` 会被误当成"CR 结束空行 + LF 结束空行"。
    func consume(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var ready: [Event] = []
        for block in extractBlocks() {
            guard let event = parse(block) else { continue }
            enqueue(event, into: &ready)
        }
        return serialize(ready)
    }

    /// 流结束：仅放出被扣住的**完整**事件（不吞事件），返回追加字节。
    ///
    /// SSE 规范要求 EOF 时丢弃尚未以空行结束的不完整尾部，因此这里不做"把残余字节当完整
    /// 事件"的处理；只有仍停留在缓冲区、但在 EOF 处恰好构成完整事件（例如以 `\r\r` 收尾）
    /// 的字节才会被识别。不完整尾部随连接结束一起丢弃。
    func finish() -> [Data] {
        var ready: [Event] = []
        for block in extractBlocks(atEOF: true) {
            guard let event = parse(block) else { continue }
            enqueue(event, into: &ready)
        }
        let rest = pending
        pending.removeAll()
        openIndexes.removeAll()
        stats.releasedAtFinish += rest.count
        ready.append(contentsOf: rest)
        buffer.removeAll()
        return serialize(ready)
    }

    /// 尚未放行的事件数（流正常结束时应为 0）
    var pendingCount: Int { pending.count }

    // MARK: 状态机

    private func enqueue(_ event: Event, into ready: inout [Event]) {
        if let idx = event.index {
            knownIndexes.insert(idx)
            if event.opensItem { openIndexes.insert(idx) }
            if event.closesItem { openIndexes.remove(idx) }
        }
        pending.append(event)
        stats.heldEvents += 1

        drain(into: &ready)

        if pending.count > maxHeld {   // 兜底：流不完整时强制按序放行，避免无限扣住
            stats.overflowFlushes += 1
            ready.append(contentsOf: pending)
            pending.removeAll()
            openIndexes.removeAll()
        }
    }

    /// 按输出项分组后放行（组内保持插入序，组间按首次出现序）。
    ///
    /// 只放行"已收尾的连续前缀"：遇到第一个仍在进行中的输出项就停住，它之后的一切都不越过。
    /// 无归属事件（created/in_progress/completed 等）不属任何组，只要没被未收尾的组挡住就按其
    /// 插入位置出队——因此规范流（无交错）是恒等变换。
    ///
    /// 上游交错时（推理项的收尾事件被插在 message 开场之后）两组的成员会交错入队，
    /// 这里按组重组，使每个输出项的 added…done 输出为连续块。
    private func drain(into ready: inout [Event]) {
        guard pending.contains(where: { $0.index != nil }) else {
            ready.append(contentsOf: pending)
            pending.removeAll()
            return
        }

        var groups: [Int: [Event]] = [:]       // 输出项 → 该组事件（插入序）
        var groupOrder: [Int] = []             // 组首次出现的顺序

        for ev in pending {
            guard let idx = ev.index else { continue }
            if groups[idx] == nil { groups[idx] = []; groupOrder.append(idx) }
            groups[idx]?.append(ev)
        }

        // 已收尾的连续前缀（组序）；遇到第一个未收尾的组即停
        var releasable: [Int] = []
        for idx in groupOrder {
            let closed = knownIndexes.contains(idx) && !openIndexes.contains(idx)
            guard closed else { break }
            releasable.append(idx)
        }
        let releasableSet = Set(releasable)

        // 已收尾组之前不存在未收尾组时，这些组连同其前面的无归属事件可以整体出队
        var out: [Event] = []
        var remaining: [Event] = []
        var emittedGroups: Set<Int> = []
        var blocked = false
        for ev in pending {
            if let idx = ev.index {
                if releasableSet.contains(idx) {
                    if !emittedGroups.contains(idx) {
                        out.append(contentsOf: groups[idx] ?? [])
                        emittedGroups.insert(idx)
                    }
                } else {
                    blocked = true
                    remaining.append(ev)
                }
            } else if blocked {
                remaining.append(ev)          // 未收尾组之后的无归属事件：留在原位
            } else {
                out.append(ev)                // 未收尾组之前的无归属事件：原位透传
            }
        }
        // 交错造成的迟到件：已收尾组若仍有事件在后面，按组补到末尾
        for idx in releasable where !emittedGroups.contains(idx) {
            out.append(contentsOf: groups[idx] ?? [])
            emittedGroups.insert(idx)
        }
        pending = remaining
        ready.append(contentsOf: out)
    }

    // MARK: 解析 / 序列化

    /// 从缓冲区中切出所有已由空行结束的完整事件块，并移除已消费的前缀。
    ///
    /// 行结束符：CRLF / LF / CR 均视为一行结束；空行（长度为 0 的行）处即事件边界。
    /// - Parameter atEOF: EOF 模式。此时缓冲区末尾不会再追加字节，单个尾部 CR 可以确定
    ///   就是行结束符（不存在"CR 后面还会来 LF"的可能），据此识别像 `\r\r` 这样恰好在
    ///   EOF 处才凑齐的空行。非 EOF 模式下末尾的孤立 CR 一律留待下一个 chunk 判定。
    private func extractBlocks(atEOF: Bool = false) -> [Data] {
        let base = buffer.startIndex
        let n = buffer.count
        var blocks: [Data] = []
        var blockStart = 0        // 当前块的起点偏移（相对 base）
        var lineStart = 0         // 当前行的起点偏移
        var i = 0
        while i < n {
            let byte = buffer[base + i]
            if byte == 0x0D {                                  // CR
                var termEnd = i + 1
                if i + 1 >= n {
                    guard atEOF else { break }                 // 可能要来 LF，先等下一个 chunk
                } else if buffer[base + i + 1] == 0x0A {       // CRLF
                    termEnd = i + 2
                }
                if i == lineStart {                            // 空行 → 事件边界
                    blocks.append(buffer.subdata(in: (base + blockStart)..<(base + lineStart)))
                    blockStart = termEnd
                }
                lineStart = termEnd
                i = termEnd
            } else if byte == 0x0A {                           // LF
                let termEnd = i + 1
                if i == lineStart {
                    blocks.append(buffer.subdata(in: (base + blockStart)..<(base + lineStart)))
                    blockStart = termEnd
                }
                lineStart = termEnd
                i = termEnd
            } else {
                i += 1
            }
        }
        if blockStart > 0 {
            buffer.removeSubrange((base + 0)..<(base + blockStart))
        }
        return blocks
    }

    /// 把事件块按行拆分（CRLF / LF / CR 均作行结束符），返回的行不含行结束符。
    private func splitLines(_ block: Data) -> [Data] {
        let base = block.startIndex
        let n = block.count
        var lines: [Data] = []
        var lineStart = 0
        var i = 0
        while i < n {
            let byte = block[base + i]
            if byte == 0x0D {
                var termEnd = i + 1
                if termEnd < n && block[base + termEnd] == 0x0A { termEnd += 1 }
                lines.append(block.subdata(in: (base + lineStart)..<(base + i)))
                lineStart = termEnd
                i = termEnd
            } else if byte == 0x0A {
                lines.append(block.subdata(in: (base + lineStart)..<(base + i)))
                lineStart = i + 1
                i += 1
            } else {
                i += 1
            }
        }
        if lineStart < n { lines.append(block.subdata(in: (base + lineStart)..<(base + n))) }
        return lines
    }

    private func parse(_ block: Data) -> Event? {
        var name: String?
        var dataLines: [Data] = []
        for line in splitLines(block) where !line.isEmpty {
            if line.starts(with: Data("event:".utf8)) {
                let rest = line.dropFirst(6).drop { $0 == 0x20 }
                name = String(decoding: rest, as: UTF8.self)
            } else if line.starts(with: Data("data:".utf8)) {
                var payload = Data(line.dropFirst(5))
                if payload.first == 0x20 { payload.removeFirst() }
                dataLines.append(payload)
            }
        }
        guard !dataLines.isEmpty else { return nil }
        var json = Data()
        for (i, d) in dataLines.enumerated() {
            if i > 0 { json.append(0x0A) }
            json.append(d)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            stats.parseFailures += 1
            return nil
        }
        let type = obj["type"] as? String
        return Event(raw: json,
                     name: name,
                     index: obj["output_index"] as? Int,
                     opensItem: type == "response.output_item.added",
                     closesItem: type == "response.output_item.done")
    }

    /// 重编 sequence_number（重排后保持单调），其余字段原样保留；按 SSE 规范回写。
    private func serialize(_ events: [Event]) -> [Data] {
        var out: [Data] = []
        out.reserveCapacity(events.count)
        for ev in events {
            var payload = ev.raw
            if let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
               obj["sequence_number"] != nil {
                var mutable = obj
                mutable["sequence_number"] = emittedCount
                if let redone = try? JSONSerialization.data(withJSONObject: mutable) {
                    payload = redone
                }
            }
            var block = Data()
            if let name = ev.name {
                block.append(Data("event: ".utf8))
                block.append(Data(name.utf8))
                block.append(0x0A)
            }
            block.append(Data("data: ".utf8))
            block.append(payload)
            block.append(0x0A)
            block.append(0x0A)
            out.append(block)
            emittedCount += 1
            stats.emitted += 1
        }
        return out
    }
}
