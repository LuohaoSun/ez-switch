import AppKit
import CoreTransferable
import UniformTypeIdentifiers

struct ModelDragItem: Identifiable, Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .plainText)
            .visibility(.ownProcess)
    }
}

/// 拖拽源与落点必须约定同一个 content type，否则落点不会命中。
enum ModelDragPayload {
    static let contentType = UTType.plainText

    /// 原生 AppKit 拖放使用的粘帖板类型：与 `CodableRepresentation(.plainText)` 导出的类型一致。
    /// 供应商模型行与路由候选行都用它发起行拖动，因此二者可以互相接收落点。
    static let nativePasteboardType = NSPasteboard.PasteboardType(contentType.identifier)

    /// 拖拽源：ownProcess 的 typed CoreTransferable 注册（跨进程不暴露载荷）。
    /// 现由 provider 契约测试覆盖；原生行拖动走 `pasteboardItem`。
    static func makeProvider(_ item: ModelDragItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.register(item)
        return provider
    }

    static func accepts(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(contentType.identifier)
    }

    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        !providers.isEmpty && providers.allSatisfy(accepts)
    }

    /// 依次解码全部 provider，只有全部成功才按 provider 顺序回调一次。
    /// 任一项类型不符或解码失败就静默放弃，避免多选拖拽提交部分载荷。
    static func load(itemsFrom providers: [NSItemProvider],
                     queue: DispatchQueue = .main,
                     completion: @escaping ([ModelDragItem]) -> Void) {
        guard !providers.isEmpty else { return }
        let collector = DropPayloadCollector()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadTransferable(type: ModelDragItem.self) { result in
                if case .success(let item) = result { collector.store(item, at: index) }
                group.leave()
            }
        }
        group.notify(queue: queue) {
            let items = collector.ordered()
            guard items.count == providers.count else { return }
            completion(items)
        }
    }

    /// 原生拖拽源写入粘帖板：与 `CodableRepresentation(contentType: .plainText)` 相同的 JSON 文本。
    /// 用 Codable/JSONEncoder 编码，不做 UUID 字符串拼装。
    static func pasteboardItem(_ item: ModelDragItem) -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(item),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(text, forType: nativePasteboardType)
        return pasteboardItem
    }

    /// 从 AppKit 拖拽粘帖板解码全部载荷；任一条目类型不符或 Codable 解码失败即返回 nil（全有或全无），
    /// 成功时保持粘帖板条目顺序。空粘帖板返回 nil。
    /// 条目可能是数据表示（provider 经 AppKit 写入），也可能是表格自身 `setString` 写入的字符串，两种都接受。
    static func decode(pasteboard: NSPasteboard) -> [ModelDragItem]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var decoded: [ModelDragItem] = []
        for pasteboardItem in items {
            guard let model = decode(pasteboardItem) else { return nil }
            decoded.append(model)
        }
        return decoded
    }

    private static func decode(_ pasteboardItem: NSPasteboardItem) -> ModelDragItem? {
        let decoder = JSONDecoder()
        if let data = pasteboardItem.data(forType: nativePasteboardType),
           let model = try? decoder.decode(ModelDragItem.self, from: data) {
            return model
        }
        if let text = pasteboardItem.string(forType: nativePasteboardType),
           let model = try? decoder.decode(ModelDragItem.self, from: Data(text.utf8)) {
            return model
        }
        return nil
    }
}

/// 路由候选项的重排：来源筛选 + 按落点重排。
/// 落点由原生 NSTableView 的 `validateDrop`/`acceptDrop`（固定 `.above`）提出的行下标给出，
/// 先换算成“当时显示的列表”里的稳定锚点，再在提交时对“当前”配置重新解析；
/// 拖动期间列表若被异步改动，锚点消失就拒绝，不会把行下标错套到新列表上。
enum RouteCandidateReorder {
    /// 规范化落点：插入到某个远端之前，或追加到末尾。
    enum Slot: Equatable {
        case before(UUID)
        case end
    }

    /// 把原生表格提出的插入行下标换算成锚点。`row` 是“当时显示列表”的插入下标，
    /// `row == ids.count`（或越界）表示追加到末尾。
    static func slot(row: Int, ids: [UUID]) -> Slot {
        guard row >= 0, row < ids.count else { return .end }
        return .before(ids[row])
    }

    /// 提交时把锚点解析成当前列表的插入下标（等于 `ids.count` 表示追加末尾）。
    /// 锚点行在拖动期间被删除时返回 nil，由调用方拒绝这次落点。
    static func insertionIndex(for slot: Slot, in ids: [UUID]) -> Int? {
        switch slot {
        case .end:
            return ids.count
        case .before(let anchor):
            return ids.firstIndex(of: anchor)
        }
    }

    /// 从拖拽载荷里筛出有效来源：去重、且必须都是当前已知的远端模型。
    /// 只要有任意一项未知就返回空数组（表示拒绝这次拖放）。
    /// 注意：已知但尚未加入该路由的模型也算有效来源（从左侧供应商面板拖入）。
    static func sources(_ items: [ModelDragItem], validRemoteIDs: Set<UUID>) -> [UUID] {
        guard !items.isEmpty else { return [] }
        let ids = items.map(\.id)
        guard ids.allSatisfy(validRemoteIDs.contains) else { return [] }
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// 把 `sources` 移动到 `before` 之前。`before` 是“移动前”列表里的下标，
    /// `before == original.count` 表示追加到末尾。
    /// 已在列表中的来源被移动；不在列表中的合法来源（从左侧拖入的新模型）被插入。
    static func reorder(original: [UUID], sources: [UUID], before index: Int) -> [UUID] {
        var seen = Set<UUID>()
        let moving = sources.filter { seen.insert($0).inserted }
        guard !moving.isEmpty else { return original }
        let movingSet = Set(moving)
        var ids = original.filter { !movingSet.contains($0) }
        let removedBefore = original.prefix(max(0, index)).filter { movingSet.contains($0) }.count
        let insertion = max(0, min(index - removedBefore, ids.count))
        ids.insert(contentsOf: moving, at: insertion)
        return ids
    }
}

/// 顺序收集异步解码出的拖拽载荷（保留 provider 顺序）。
private final class DropPayloadCollector {
    private let lock = NSLock()
    private var items: [Int: ModelDragItem] = [:]

    func store(_ item: ModelDragItem, at index: Int) {
        lock.lock(); items[index] = item; lock.unlock()
    }

    func ordered() -> [ModelDragItem] {
        lock.lock(); defer { lock.unlock() }
        return items.keys.sorted().compactMap { items[$0] }
    }
}
