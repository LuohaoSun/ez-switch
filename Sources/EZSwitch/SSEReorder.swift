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
///
/// 本组件只在**真的发生跨项交错**时才暂存：当前活跃输出项（`groupOrder` 中最早的未收尾项）
/// 的 added/delta/done 一律即时放出，首字与增量延迟不被缓冲；只有后一项在前一项收尾之前
/// 提前开场时，它及其后续事件才被扣住。前一项 done 一放出，后一项已到的事件立即随之放出
/// （即使后一项自身还没 done），其后增量继续即时流式。事件流本就规范时（无交错）输入 = 输出，
/// 是恒等变换。
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

    /// 暂存项。无归属事件额外记录"放行前需先完全放出的组数"（到达时已开场的组数），
    /// 以保持它与输出项的先后关系——不这样的话活跃组被扣住时 `completed` 会抢跑到前面。
    private struct Buffered {
        let event: Event
        let requiresGroups: Int
    }

    private var pending: [Buffered] = []
    private var groupOrder: [Int] = []          // 输出项首次出现顺序（= 放行顺序）
    private var knownIndexes: Set<Int> = []     // 见过的输出项索引
    private var openIndexes: Set<Int> = []      // 尚未收到 output_item.done 的
    private var releasedGroups = 0              // groupOrder 前多少个组已完全放出
    private var buffer = Data()                 // 尚未凑出空行（事件边界）的字节
    private var emittedCount = 0

    private(set) var stats = Stats()

    struct Stats {
        var emitted = 0
        var heldEvents = 0        // 入队的事件数
        var releasedAtFinish = 0  // 流结束时仍被扣住、由 finish 兜底放出的（异常流）
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

    /// 流结束：先放出仍被扣住的**完整**事件（不吞事件），返回追加字节。
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
        let rest = forceFlush()
        stats.releasedAtFinish += rest.count
        buffer.removeAll()
        return serialize(ready + rest)
    }

    /// 尚未放行的事件数（流正常结束时应为 0）
    var pendingCount: Int { pending.count }

    // MARK: 状态机

    private func enqueue(_ event: Event, into ready: inout [Event]) {
        if let idx = event.index {
            if knownIndexes.insert(idx).inserted { groupOrder.append(idx) }
            if event.opensItem { openIndexes.insert(idx) }
            if event.closesItem { openIndexes.remove(idx) }
        }
        // 无归属事件到达时已开场的组数：这些组全部放完它才能放行
        let requires = event.index == nil ? groupOrder.count : 0
        pending.append(Buffered(event: event, requiresGroups: requires))
        stats.heldEvents += 1

        drain(into: &ready)

        if pending.count > maxHeld {   // 兜底：流不完整时强制按序放行，避免无限扣住
            stats.overflowFlushes += 1
            ready.append(contentsOf: pending.map { $0.event })
            pending.removeAll()
            openIndexes.removeAll()
            releasedGroups = groupOrder.count
        }
    }

    /// 放出可即时下发的事件，其余留在 pending。
    ///
    /// 放行规则：
    /// 1. `groupOrder` 从前向后，已收到 `output_item.done` 的组视为"完全放出"，直到遇到
    ///    第一个未收尾组为止（`releasedGroups` 即该连续前缀长度）。
    /// 2. 这些已放出组的遗留事件（交错时晚到的收尾件）先按组序输出，保证前一项的 done 一定
    ///    早于后一项的 added。
    /// 3. 紧随其后的第一个未收尾组是当前活跃组，它已到的事件即时放出（流式，不整项缓冲）。
    /// 4. 更靠后的组一律暂存；等它前面的组收尾后，在下一次 drain 里成为活跃组被立即放出。
    /// 5. 无归属事件（created/in_progress/completed 等）在"其出现前已开场的组全部放出"后
    ///    按插入位放出——因此活跃组/后项被扣住时不会抢跑，也不会把 completed 提前。
    private func drain(into ready: inout [Event]) {
        while releasedGroups < groupOrder.count,
              !openIndexes.contains(groupOrder[releasedGroups]) {
            releasedGroups += 1
        }
        guard !pending.isEmpty else { return }

        var position: [Int: Int] = [:]
        position.reserveCapacity(groupOrder.count)
        for (i, g) in groupOrder.enumerated() { position[g] = i }

        // 已放出组的遗留事件，按组序聚合（组内保持插入序）
        var lateByGroup: [Int: [Event]] = [:]
        for b in pending {
            guard let idx = b.event.index, let p = position[idx], p < releasedGroups else { continue }
            lateByGroup[idx, default: []].append(b.event)
        }

        var out: [Event] = []
        var remaining: [Buffered] = []
        for k in 0..<releasedGroups {
            if let evs = lateByGroup[groupOrder[k]] { out.append(contentsOf: evs) }
        }
        for b in pending {
            if let idx = b.event.index {
                guard let p = position[idx] else { remaining.append(b); continue }
                if p < releasedGroups { continue }              // 已在上面放出
                if p == releasedGroups { out.append(b.event) }  // 活跃组：即时流式
                else { remaining.append(b) }                    // 后项：暂存
            } else if b.requiresGroups <= releasedGroups {
                out.append(b.event)
            } else {
                remaining.append(b)
            }
        }
        pending = remaining
        ready.append(contentsOf: out)
    }

    /// 流结束时强制放出所有剩余事件（不吞事件）：视为所有组都已收尾，按组序放出。
    private func forceFlush() -> [Event] {
        guard !pending.isEmpty else { return [] }
        openIndexes.removeAll()
        releasedGroups = groupOrder.count
        var out: [Event] = []
        drain(into: &out)
        if !pending.isEmpty {   // 理论上不会到达：所有组已视为收尾
            out.append(contentsOf: pending.map { $0.event })
            pending.removeAll()
        }
        return out
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
