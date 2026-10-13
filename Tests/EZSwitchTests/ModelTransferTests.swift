import Foundation
import AppKit
import CoreTransferable
import UniformTypeIdentifiers
import Testing
@testable import EZSwitch

/// 测试 fixture 独占临时配置目录，fixture 释放时自动清理，避免残留。
final class TempConfigDirectory {
    let url: URL
    private let directory: URL

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("config.json")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

@Suite("Typed model transfer")
struct ModelTransferTests {
    @Test func cardIdentityIsDistinctFromModelIdentity() throws {
        let id = UUID()
        let cardID = CardReorderID(value: id)
        #expect(AnyHashable(cardID) != AnyHashable(id))
        let data = try JSONEncoder().encode(cardID)
        #expect(try JSONDecoder().decode(CardReorderID<UUID>.self, from: data) == cardID)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ModelDragItem.self, from: data)
        }
    }

    @Test func roundTripExportsOnlyModelID() async throws {
        let id = UUID()
        let provider = NSItemProvider()
        provider.register(ModelDragItem(id: id))
        let item: ModelDragItem = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: ModelDragItem.self) { result in
                continuation.resume(with: result)
            }
        }
        #expect(item.id == id)
        let data = try JSONEncoder().encode(item)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["id": id.uuidString])
    }

    @Test func dragSourceAndDropTargetAgreeOnPayloadType() {
        let provider = ModelDragPayload.makeProvider(ModelDragItem(id: UUID()))
        #expect(ModelDragPayload.accepts(provider))
        #expect(ModelDragPayload.accepts([provider]))
    }

    @Test func dropRejectsEmptyOrUnrelatedPayloads() {
        #expect(!ModelDragPayload.accepts([]))
        #expect(!ModelDragPayload.accepts(NSItemProvider()))
        #expect(!ModelDragPayload.accepts([NSItemProvider()]))
        let unrelated = NSItemProvider(item: Data([0x01]) as NSData, typeIdentifier: UTType.image.identifier)
        #expect(!ModelDragPayload.accepts(unrelated))
    }

    @Test func acceptsRejectsAnyInvalidProviderInAGroup() {
        let valid = ModelDragPayload.makeProvider(ModelDragItem(id: UUID()))
        #expect(ModelDragPayload.accepts([valid]))
        #expect(!ModelDragPayload.accepts([valid, NSItemProvider()]))
        #expect(!ModelDragPayload.accepts([NSItemProvider(), valid]))
    }

    @Test func loadDeliversAllPayloadsInProviderOrder() async {
        let items = (0..<3).map { _ in ModelDragItem(id: UUID()) }
        let providers = items.map(ModelDragPayload.makeProvider)
        let loaded: [ModelDragItem] = await withCheckedContinuation { continuation in
            ModelDragPayload.load(itemsFrom: providers, queue: DispatchQueue(label: "test.load.order")) {
                continuation.resume(returning: $0)
            }
        }
        #expect(loaded.map(\.id) == items.map(\.id))
    }

    @Test func loadSuppressesDeliveryWhenAnyPayloadFails() async throws {
        final class Flag: @unchecked Sendable { var delivered = false }
        let flag = Flag()
        let providers = [ModelDragPayload.makeProvider(ModelDragItem(id: UUID())), NSItemProvider()]
        ModelDragPayload.load(itemsFrom: providers, queue: DispatchQueue(label: "test.load.partial")) { _ in
            flag.delivered = true
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(flag.delivered == false)
    }
}

@Suite("Native model pasteboard payload")
struct NativeModelPasteboardTests {
    /// SwiftUI `onDrag` 与原生表格必须约定同一种粘帖板载荷：
    /// `CodableRepresentation(.plainText)` 导出的就是 ModelDragItem 的 JSON 文本，
    /// 原生解码路径据此解回 ModelDragItem。
    @Test func providerExposesCodablePlainTextJSONThatTheNativeDecoderReads() async throws {
        let id = UUID()
        let provider = ModelDragPayload.makeProvider(ModelDragItem(id: id))
        let loaded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            provider.loadItem(forTypeIdentifier: ModelDragPayload.nativePasteboardType.rawValue, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: item) }
            }
        }
        let text: String
        switch loaded {
        case let string as String: text = string
        case let data as Data: text = try #require(String(data: data, encoding: .utf8))
        case let string as NSString: text = string as String
        default:
            Issue.record("unexpected plain-text item: \(String(describing: loaded))")
            return
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        #expect(object == ["id": id.uuidString])
        // 与原生解码路径一致：同一份 JSON 经字符串粘帖板条目也能解回 ModelDragItem。
        let stringItem = NSPasteboardItem()
        stringItem.setString(text, forType: ModelDragPayload.nativePasteboardType)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ezswitch.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([stringItem])
        #expect(ModelDragPayload.decode(pasteboard: pasteboard)?.map(\.id) == [id])
    }

    /// 原生解码接受数据表示（provider 经 AppKit 写入）与表格自身写入的字符串表示，并保持顺序。
    @Test func nativeDecoderReadsDataAndStringPayloadsInOrder() throws {
        let first = UUID()
        let second = UUID()
        let dataItem = NSPasteboardItem()
        dataItem.setData(try JSONEncoder().encode(ModelDragItem(id: first)),
                         forType: ModelDragPayload.nativePasteboardType)
        let stringItem = NSPasteboardItem()
        stringItem.setString(String(decoding: try JSONEncoder().encode(ModelDragItem(id: second)), as: UTF8.self),
                              forType: ModelDragPayload.nativePasteboardType)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ezswitch.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([dataItem, stringItem])
        #expect(ModelDragPayload.decode(pasteboard: pasteboard)?.map(\.id) == [first, second])
    }

    @Test func nativePasteboardRoundTripsAllItemsInOrder() {
        let items = [ModelDragItem(id: UUID()), ModelDragItem(id: UUID()), ModelDragItem(id: UUID())]
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ezswitch.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(items.compactMap(ModelDragPayload.pasteboardItem))
        let decoded = ModelDragPayload.decode(pasteboard: pasteboard)
        #expect(decoded?.map(\.id) == items.map(\.id))
    }

    @Test func nativePasteboardRejectsMalformedMixedOrWrongTypePayloads() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ezswitch.tests.\(UUID().uuidString)"))

        // 一份合法数据 + 一份非法 JSON → 全部拒绝（全有或全无）。
        let good = NSPasteboardItem()
        good.setData(try JSONEncoder().encode(ModelDragItem(id: UUID())),
                     forType: ModelDragPayload.nativePasteboardType)
        let malformed = NSPasteboardItem()
        malformed.setString("{ not json }", forType: ModelDragPayload.nativePasteboardType)
        pasteboard.clearContents()
        pasteboard.writeObjects([good, malformed])
        #expect(ModelDragPayload.decode(pasteboard: pasteboard) == nil)

        // 类型不符：只有普通字符串、没有 plain-text 载荷。
        let wrongType = NSPasteboardItem()
        wrongType.setString(UUID().uuidString, forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([wrongType])
        #expect(ModelDragPayload.decode(pasteboard: pasteboard) == nil)

        // 空粘帖板。
        pasteboard.clearContents()
        #expect(ModelDragPayload.decode(pasteboard: pasteboard) == nil)
    }
}

@Suite("Route candidate reorder")
struct RouteCandidateReorderTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()
    private let e = UUID()

    /// 与原生表格 accept 路径一致：原生提出行 → 锚点 → 对当前列表解析 → 重排。
    private func commit(_ ids: [UUID], source: UUID, row: Int) -> [UUID] {
        let slot = RouteCandidateReorder.slot(row: row, ids: ids)
        guard let index = RouteCandidateReorder.insertionIndex(for: slot, in: ids) else { return ids }
        return RouteCandidateReorder.reorder(original: ids, sources: [source], before: index)
    }

    @Test func nativeRowMapsToStableSlot() {
        let ids = [a, b, c, d, e]
        #expect(RouteCandidateReorder.slot(row: 0, ids: ids) == .before(a))
        #expect(RouteCandidateReorder.slot(row: 2, ids: ids) == .before(c))
        #expect(RouteCandidateReorder.slot(row: 4, ids: ids) == .before(e))
        // 最后一行下方（原生提出的 count）与越界都表示追加到末尾。
        #expect(RouteCandidateReorder.slot(row: 5, ids: ids) == .end)
        #expect(RouteCandidateReorder.slot(row: 99, ids: ids) == .end)
        #expect(RouteCandidateReorder.slot(row: 0, ids: []) == .end)
    }

    @Test func movesFifthItemToEveryIndex() {
        let ids = [a, b, c, d, e]
        #expect(commit(ids, source: e, row: 0) == [e, a, b, c, d])
        #expect(commit(ids, source: e, row: 1) == [a, e, b, c, d])
        #expect(commit(ids, source: e, row: 2) == [a, b, e, c, d])
        #expect(commit(ids, source: e, row: 3) == [a, b, c, e, d])
        #expect(commit(ids, source: e, row: 4) == [a, b, c, d, e])
        #expect(commit(ids, source: e, row: 5) == [a, b, c, d, e])
    }

    @Test func movesFirstItemToEveryIndex() {
        let ids = [a, b, c, d, e]
        #expect(commit(ids, source: a, row: 0) == [a, b, c, d, e])
        #expect(commit(ids, source: a, row: 1) == [a, b, c, d, e])
        #expect(commit(ids, source: a, row: 2) == [b, a, c, d, e])
        #expect(commit(ids, source: a, row: 3) == [b, c, a, d, e])
        #expect(commit(ids, source: a, row: 4) == [b, c, d, a, e])
        #expect(commit(ids, source: a, row: 5) == [b, c, d, e, a])
    }

    @Test func adjacentUpAndDownMovesMatchOnePositionChanges() {
        let ids = [a, b, c, d, e]
        // 向下相邻一位：把第二项拖到第三行 d 之前。
        #expect(commit(ids, source: b, row: 3) == [a, c, b, d, e])
        // 向上相邻一位：把第二项拖到第一行之前。
        #expect(commit(ids, source: b, row: 0) == [b, a, c, d, e])
        // 第一项落到第二行下半（原生提出 row 2）→ 后移一位。
        #expect(commit(ids, source: a, row: 2) == [b, a, c, d, e])
    }

    @Test func insertsNewModelFromSupplierPanel() {
        // 路由里还没有的已知模型：从左侧拖入，插到原生提出的行。
        #expect(commit([a, b], source: e, row: 0) == [e, a, b])
        #expect(commit([a, b], source: e, row: 1) == [a, e, b])
        #expect(commit([a, b], source: e, row: 2) == [a, b, e])
        // 空路由的末尾落点。
        #expect(commit([], source: e, row: 0) == [e])
    }

    @Test func supportsMultipleSourcesInPayloadOrder() {
        #expect(RouteCandidateReorder.reorder(original: [a, b, c, d, e], sources: [e, c], before: 0) == [e, c, a, b, d])
        #expect(RouteCandidateReorder.reorder(original: [a, b, c, d, e], sources: [b, e], before: 5) == [a, c, d, b, e])
        #expect(RouteCandidateReorder.reorder(original: [a, b, c], sources: [], before: 0) == [a, b, c])
    }

    @Test func acceptsOnlyKnownRemoteIDs() {
        let items = [ModelDragItem(id: a), ModelDragItem(id: b)]
        #expect(RouteCandidateReorder.sources(items, validRemoteIDs: [a, b]) == [a, b])
        #expect(RouteCandidateReorder.sources([ModelDragItem(id: a), ModelDragItem(id: a), ModelDragItem(id: b)],
                                             validRemoteIDs: [a, b]) == [a, b])
        // 未知来源 → 整个落点拒绝。
        #expect(RouteCandidateReorder.sources(items, validRemoteIDs: [a]) == [])
        #expect(RouteCandidateReorder.sources([], validRemoteIDs: [a, b]) == [])
        // 已知但尚未加入该路由的模型仍然被接受（外部拖入）。
        #expect(RouteCandidateReorder.sources([ModelDragItem(id: e)], validRemoteIDs: [a, b, c, d, e]) == [e])
    }

    @Test func resolvesAnchorAgainstFreshConfigAndRejectsVanishedAnchor() throws {
        // 拖动时显示 [a,b,c,d,e]，原生提出 row 2 → 锚点 c。
        let slot = RouteCandidateReorder.slot(row: 2, ids: [a, b, c, d, e])
        #expect(slot == .before(c))
        // 期间配置被异步改成 [c,a,b,d,e]：锚点解析到它“当前”的位置，而不是旧行号。
        let fresh = [c, a, b, d, e]
        let index = try #require(RouteCandidateReorder.insertionIndex(for: slot, in: fresh))
        #expect(index == 0)
        #expect(RouteCandidateReorder.reorder(original: fresh, sources: [a], before: index) == [a, c, b, d, e])
        // 锚点行消失 → 拒绝这次落点。
        #expect(RouteCandidateReorder.insertionIndex(for: .before(b), in: [a, c, d, e]) == nil)
    }
}

@MainActor
@Suite("Route candidate commit against store")
struct RouteCandidateCommitTests {
    @MainActor
    private struct Fixture {
        let store: ConfigStore
        let route: FakeModel
        let ids: [UUID]
        let directory: TempConfigDirectory

        var order: [UUID] { store.config.fakes[0].orderedRemoteIDs }
        var selected: UUID? { store.config.fakes[0].selectedRemoteID }
        var autoFallback: Bool { store.config.fakes[0].autoFallback }
    }

    private func remote(_ model: String, provider: String = "P") -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "k", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
    }

    /// 5 条候选，第 5 条为显式选中（“当前”）模型。
    private func makeFixture(extra: RemoteModel? = nil) throws -> Fixture {
        let remotes = [remote("m1"), remote("m2"), remote("m3"), remote("m4"), remote("m5")]
        let all = remotes + (extra.map { [$0] } ?? [])
        let route = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                              remoteID: remotes[0].id,
                              fallbackRemoteIDs: Array(remotes.dropFirst().map(\.id)))
        let directory = try TempConfigDirectory(name: "commit")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: all, fakes: [route])).write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let ids = store.config.fakes[0].orderedRemoteIDs
        #expect(store.selectRouteModel(fakeID: route.id, remoteID: ids[4]))
        return Fixture(store: store, route: route, ids: ids, directory: directory)
    }

    @Test func movesFifthToTopAndPreservesExplicitSelection() throws {
        let f = try makeFixture()
        let fifth = f.ids[4]
        let slot = RouteCandidateReorder.slot(row: 0, ids: f.ids)
        #expect(f.store.reorderRouteCandidates(fakeID: f.route.id,
                                               payload: [ModelDragItem(id: fifth)], slot: slot))
        #expect(f.order == [fifth, f.ids[0], f.ids[1], f.ids[2], f.ids[3]])
        // 拖动不改动显式选中模型，也不动 autoFallback。
        #expect(f.selected == fifth)
        #expect(f.autoFallback == true)
    }

    @Test func movedToEndKeepsSelection() throws {
        let f = try makeFixture()
        let slot = RouteCandidateReorder.slot(row: 5, ids: f.ids)
        #expect(f.store.reorderRouteCandidates(fakeID: f.route.id,
                                               payload: [ModelDragItem(id: f.ids[0])], slot: slot))
        #expect(f.order == [f.ids[1], f.ids[2], f.ids[3], f.ids[4], f.ids[0]])
        #expect(f.selected == f.ids[4])
    }

    @Test func unknownSourceRejectsWholePayload() throws {
        let f = try makeFixture()
        let slot = RouteCandidateReorder.slot(row: 0, ids: f.ids)
        // 一项已知 + 一项未知 → 全部拒绝，顺序不变。
        let payload = [ModelDragItem(id: f.ids[1]), ModelDragItem(id: UUID())]
        #expect(f.store.reorderRouteCandidates(fakeID: f.route.id, payload: payload, slot: slot) == false)
        #expect(f.order == f.ids)
    }

    @Test func unknownSourceInFirstPositionAlsoRejects() throws {
        let f = try makeFixture()
        let slot = RouteCandidateReorder.slot(row: 0, ids: f.ids)
        let payload = [ModelDragItem(id: UUID()), ModelDragItem(id: f.ids[3])]
        #expect(f.store.reorderRouteCandidates(fakeID: f.route.id, payload: payload, slot: slot) == false)
        #expect(f.order == f.ids)
    }

    @Test func multipleKnownSourcesKeepPayloadOrder() throws {
        let f = try makeFixture()
        let moved = [f.ids[4], f.ids[2]]
        let slot = RouteCandidateReorder.slot(row: 0, ids: f.ids)
        #expect(f.store.reorderRouteCandidates(fakeID: f.route.id,
                                               payload: moved.map { ModelDragItem(id: $0) }, slot: slot))
        #expect(f.order == [f.ids[4], f.ids[2], f.ids[0], f.ids[1], f.ids[3]])
    }

    @Test func addsKnownModelNotYetInRouteAtNativeRow() throws {
        let extra = remote("m6", provider: "Q")
        let f = try makeFixture(extra: extra)
        let slot = RouteCandidateReorder.slot(row: 2, ids: f.ids)
        #expect(f.store.reorderRouteCandidates(fakeID: f.route.id,
                                               payload: [ModelDragItem(id: extra.id)], slot: slot))
        #expect(f.order == [f.ids[0], f.ids[1], extra.id, f.ids[2], f.ids[3], f.ids[4]])
    }

    @Test func vanishedAnchorIsRejected() throws {
        let f = try makeFixture()
        let slot = RouteCandidateReorder.Slot.before(UUID())
        #expect(f.store.reorderRouteCandidates(fakeID: f.route.id,
                                               payload: [ModelDragItem(id: f.ids[0])], slot: slot) == false)
        #expect(f.order == f.ids)
    }

    @Test func reorderIsNoOpWhenNothingChanges() throws {
        let f = try makeFixture()
        let slot = RouteCandidateReorder.slot(row: 0, ids: f.ids)
        #expect(f.store.reorderRouteCandidates(fakeID: f.route.id,
                                               payload: [ModelDragItem(id: f.ids[0])], slot: slot))
        #expect(f.order == f.ids)
        #expect(f.selected == f.ids[4])
    }
}

@MainActor
@Suite("Native route candidate table lifecycle")
struct NativeRouteCandidateTableTests {
    private struct Setup {
        let directory: TempConfigDirectory
        let store: ConfigStore
        let coordinator: NativeRouteCandidateList.Coordinator
        let table: CandidateTableView
        let six: [RouteCandidateItem]
        let seven: [RouteCandidateItem]
    }

    /// 6 条候选，另有第 7 个已知远端尚未加入，用于模拟落点期间列表从 6 变 7。
    private func makeSetup() throws -> Setup {
        let remotes = (0..<7).map { index in
            RemoteModel(id: UUID(), name: "P · m\(index)", apiKey: "k", model: "m\(index)",
                        extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
        }
        let route = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                              remoteID: remotes[0].id,
                              fallbackRemoteIDs: Array(remotes[1...5].map(\.id)))
        let directory = try TempConfigDirectory(name: "table")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: remotes, fakes: [route])).write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let ids = store.config.fakes[0].orderedRemoteIDs
        let six = ids.map { RouteCandidateItem(id: $0, label: "P · m") }
        let seven = (ids + [remotes[6].id]).map { RouteCandidateItem(id: $0, label: "P · m") }
        let list = NativeRouteCandidateList(items: six, activeRemoteID: nil, store: store, fakeID: route.id)
        let coordinator = list.makeCoordinator()
        let table = CandidateTableView()
        list.wire(table, coordinator: coordinator)
        coordinator.apply(items: six, active: nil)
        return Setup(directory: directory, store: store, coordinator: coordinator, table: table,
                     six: six, seven: seven)
    }

    /// 空路由：表格只有末尾占位行。
    private func makeEmptySetup() throws -> (directory: TempConfigDirectory,
                                             store: ConfigStore,
                                             coordinator: NativeRouteCandidateList.Coordinator,
                                             table: CandidateTableView) {
        let remote = RemoteModel(id: UUID(), name: "P · m0", apiKey: "k", model: "m0",
                                 extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
        let route = FakeModel(id: UUID(), fakeModelID: "empty", displayName: "empty", remoteID: nil)
        let directory = try TempConfigDirectory(name: "empty")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [remote], fakes: [route])).write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let list = NativeRouteCandidateList(items: [], activeRemoteID: nil, store: store, fakeID: route.id)
        let coordinator = list.makeCoordinator()
        let table = CandidateTableView()
        list.wire(table, coordinator: coordinator)
        coordinator.apply(items: [], active: nil)
        return (directory, store, coordinator, table)
    }

    @Test func tableControlIsWiredToTheCoordinatorAction() throws {
        let setup = try makeSetup()
        #expect(setup.table.target === setup.coordinator)
        #expect(setup.table.action == #selector(NativeRouteCandidateList.Coordinator.tableClicked(_:)))
        #expect(setup.table.delegate === setup.coordinator)
        #expect(setup.table.dataSource === setup.coordinator)
    }

    // 行数含末尾常驻占位行。
    @Test func identityChangeReloadsImmediatelyWhenNoDragIsActive() throws {
        let setup = try makeSetup()
        #expect(setup.coordinator.numberOfRows(in: setup.table) == 7)
        setup.coordinator.apply(items: setup.seven, active: nil)
        #expect(setup.coordinator.numberOfRows(in: setup.table) == 8)
        #expect(setup.coordinator.displayedIDs == setup.seven.map(\.id))
    }

    /// 复现“跨路由成功后目标表格仍显示旧 6 项且高度多出 34”的缺口：
    /// 成功落点只由 concludeDragOperation 结束，必须在该路径解冻并应用积压刷新。
    @Test func crossTableSuccessAppliesDeferredReloadAtDestinationCompletion() throws {
        let setup = try makeSetup()
        setup.coordinator.draggingActiveChanged(true)                  // draggingEntered
        setup.coordinator.apply(items: setup.seven, active: nil)       // 落点期间 6 → 7
        #expect(setup.coordinator.numberOfRows(in: setup.table) == 7)  // 冻结：不破坏显示快照
        #expect(setup.coordinator.displayedIDs == setup.six.map(\.id))
        setup.coordinator.draggingActiveChanged(false)                 // concludeDragOperation
        #expect(setup.coordinator.numberOfRows(in: setup.table) == 8)
        #expect(setup.coordinator.displayedIDs == setup.seven.map(\.id))
    }

    @Test func cancelledDestinationDropUnfreezes() throws {
        let setup = try makeSetup()
        setup.coordinator.draggingActiveChanged(true)
        setup.coordinator.apply(items: setup.seven, active: nil)
        setup.coordinator.draggingActiveChanged(false)                 // draggingExited / draggingEnded
        #expect(setup.coordinator.numberOfRows(in: setup.table) == 8)
    }

    @Test func freezeKeepsDisplayedSnapshotForAnchorMapping() throws {
        let setup = try makeSetup()
        setup.coordinator.draggingActiveChanged(true)
        setup.coordinator.apply(items: setup.seven, active: nil)
        #expect(RouteCandidateReorder.slot(row: 2, ids: setup.coordinator.displayedIDs)
                == .before(setup.six[2].id))
        setup.coordinator.draggingActiveChanged(false)
    }

    @Test func destinationFinishPathsNotifyCoordinator() {
        let table = CandidateTableView()
        var events: [Bool] = []
        table.onDraggingStateChange = { events.append($0) }
        table.draggingExited(nil)
        table.concludeDragOperation(nil)
        #expect(events == [false, false])
    }

    @Test func clickSelectsModelAndIsSuppressedAfterDragStarts() throws {
        let setup = try makeSetup()
        #expect(setup.coordinator.handleClick(row: 1))
        #expect(setup.store.config.fakes[0].selectedRemoteID == setup.six[1].id)
        setup.coordinator.sourceDragWillBegin()
        #expect(setup.coordinator.handleClick(row: 2) == false)   // 拖动结束的 mouseUp 不能选
        #expect(setup.store.config.fakes[0].selectedRemoteID == setup.six[1].id)
        // 下一次独立按下清掉上次拖动遗留的抑制 → 普通点击恢复。
        setup.coordinator.newMouseDown()
        #expect(setup.coordinator.handleClick(row: 2))
        #expect(setup.store.config.fakes[0].selectedRemoteID == setup.six[2].id)
    }

    /// action 派发可在 clickedRow 不可用时用 selectedRow 兜底（测试进程没有真实点击）。
    @Test func actionHandlerSelectsViaSelection() throws {
        let setup = try makeSetup()
        setup.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        setup.coordinator.tableClicked(setup.table)
        #expect(setup.store.config.fakes[0].selectedRemoteID == setup.six[1].id)
    }

    /// 末尾占位行不可拖、不可点选。
    @Test func placeholderRowIsNotADragOrClickTarget() throws {
        let setup = try makeSetup()
        let placeholder = setup.six.count
        #expect(setup.coordinator.numberOfRows(in: setup.table) == placeholder + 1)
        #expect(setup.coordinator.tableView(setup.table, pasteboardWriterForRow: placeholder) == nil)
        #expect(setup.coordinator.tableView(setup.table, shouldSelectRow: placeholder) == false)
        #expect(setup.coordinator.handleClick(row: placeholder) == false)
        #expect(setup.store.config.fakes[0].selectedRemoteID == nil)
    }

    /// 空路由只有占位行，同样不是拖拽/点击来源。
    @Test func emptyRouteExposesOnlyThePlaceholderRow() throws {
        let setup = try makeEmptySetup()
        #expect(setup.coordinator.numberOfRows(in: setup.table) == 1)
        #expect(setup.coordinator.tableView(setup.table, pasteboardWriterForRow: 0) == nil)
        #expect(setup.coordinator.tableView(setup.table, shouldSelectRow: 0) == false)
        #expect(setup.coordinator.handleClick(row: 0) == false)
    }
}

@Suite("Supplier model reorder rules")
struct SupplierModelReorderRulesTests {
    private func remote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "k", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
    }

    @Test func acceptsOnlySameProviderKnownModels() {
        let a = remote("Alpha", "one")
        let b = remote("Beta", "one")
        let lookup = [a.id: a, b.id: b]
        #expect(SupplierModelReorder.sources([ModelDragItem(id: a.id)], provider: "Alpha", remotesByID: lookup)
                == [a.id])
        // 去重。
        #expect(SupplierModelReorder.sources([ModelDragItem(id: a.id), ModelDragItem(id: a.id)],
                                             provider: "Alpha", remotesByID: lookup) == [a.id])
        // 跨供应商 / 未知来源 / 空载荷 → 整体拒绝（供应商排序不允许把模型搬进别的供应商）。
        #expect(SupplierModelReorder.sources([ModelDragItem(id: a.id), ModelDragItem(id: b.id)],
                                             provider: "Alpha", remotesByID: lookup) == [])
        #expect(SupplierModelReorder.sources([ModelDragItem(id: UUID())], provider: "Alpha", remotesByID: lookup) == [])
        #expect(SupplierModelReorder.sources([], provider: "Alpha", remotesByID: lookup) == [])
    }

    @Test func rowMapsToAnchorOrEnd() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(SupplierModelReorder.anchor(row: 0, ids: ids) == ids[0])
        #expect(SupplierModelReorder.anchor(row: 2, ids: ids) == ids[2])
        // row == count（或越界）表示追加到末尾。
        #expect(SupplierModelReorder.anchor(row: 3, ids: ids) == nil)
        #expect(SupplierModelReorder.anchor(row: 99, ids: ids) == nil)
        #expect(SupplierModelReorder.anchor(row: 0, ids: []) == nil)
    }
}

@MainActor
@Suite("Supplier model commit against store")
struct SupplierModelCommitTests {
    private func remote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "k", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
    }

    private struct Fixture {
        let store: ConfigStore
        let directory: TempConfigDirectory
        let alpha: [RemoteModel]
        let beta: RemoteModel
    }

    private func makeFixture() throws -> Fixture {
        let aOne = remote("Alpha", "one")
        let beta = remote("Beta", "one")
        let aTwo = remote("Alpha", "two")
        let aThree = remote("Alpha", "three")
        let directory = try TempConfigDirectory(name: "supplier-commit")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [aOne, beta, aTwo, aThree], fakes: []))
            .write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        return Fixture(store: store, directory: directory, alpha: [aOne, aTwo, aThree], beta: beta)
    }

    @Test func reordersWithinProviderAndPersists() throws {
        let f = try makeFixture()
        let anchor = SupplierModelReorder.anchor(row: 2, ids: f.alpha.map(\.id))
        #expect(anchor == f.alpha[2].id)
        #expect(f.store.reorderSupplierModels(provider: "Alpha",
                                              payload: [ModelDragItem(id: f.alpha[0].id)],
                                              before: anchor))
        // Alpha 块内部重排，模型被移到 Alpha.three 之前；Beta 位置不动。
        #expect(f.store.config.remotes.map(\.id) == [f.alpha[1].id, f.beta.id, f.alpha[0].id, f.alpha[2].id])
        #expect(f.store.config.remotes[1].id == f.beta.id)
        let reloaded = ConfigStore(configURL: f.store.configURL)
        #expect(reloaded.config.remotes.map(\.id) == f.store.config.remotes.map(\.id))
    }

    @Test func anchorOnSourceItselfIsANoOpButAccepted() throws {
        let f = try makeFixture()
        let before = f.store.config.remotes.map(\.id)
        #expect(f.store.reorderSupplierModels(provider: "Alpha",
                                              payload: [ModelDragItem(id: f.alpha[0].id)],
                                              before: f.alpha[0].id))
        #expect(f.store.config.remotes.map(\.id) == before)
    }

    @Test func rejectsCrossProviderAndUnknownPayloads() throws {
        let f = try makeFixture()
        let before = f.store.config.remotes.map(\.id)
        #expect(f.store.reorderSupplierModels(provider: "Alpha",
                                              payload: [ModelDragItem(id: f.beta.id)], before: nil) == false)
        #expect(f.store.reorderSupplierModels(provider: "Alpha",
                                              payload: [ModelDragItem(id: f.alpha[0].id), ModelDragItem(id: f.beta.id)],
                                              before: nil) == false)
        #expect(f.store.reorderSupplierModels(provider: "Alpha",
                                              payload: [ModelDragItem(id: UUID())], before: nil) == false)
        #expect(f.store.reorderSupplierModels(provider: "Alpha", payload: [], before: nil) == false)
        #expect(f.store.config.remotes.map(\.id) == before)
    }

    /// 落点锚点必须是当前仍存在的同供应商模型：消失或属于别的供应商都拒绝，
    /// 不能被 `moveModels` 的静默 no-op 掩盖成成功。
    @Test func rejectsVanishedOrWrongProviderAnchor() throws {
        let f = try makeFixture()
        let before = f.store.config.remotes.map(\.id)
        #expect(f.store.reorderSupplierModels(provider: "Alpha",
                                              payload: [ModelDragItem(id: f.alpha[0].id)],
                                              before: UUID()) == false)
        #expect(f.store.reorderSupplierModels(provider: "Alpha",
                                              payload: [ModelDragItem(id: f.alpha[0].id)],
                                              before: f.beta.id) == false)
        #expect(f.store.config.remotes.map(\.id) == before)
    }

    /// 从供应商把模型拖出到路由只改路由候选，不改动供应商记录（顺序与条目）。
    @Test func dragOutToRouteLeavesSupplierRecordsUnchanged() throws {
        let aOne = remote("Alpha", "one")
        let aTwo = remote("Alpha", "two")
        let route = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: aOne.id)
        let directory = try TempConfigDirectory(name: "supplier-dragout")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [aOne, aTwo], fakes: [route])).write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let before = store.config.remotes.map(\.id)
        let slot = RouteCandidateReorder.slot(row: 1, ids: store.config.fakes[0].orderedRemoteIDs)
        #expect(store.reorderRouteCandidates(fakeID: route.id, payload: [ModelDragItem(id: aTwo.id)], slot: slot))
        #expect(store.config.fakes[0].orderedRemoteIDs == [aOne.id, aTwo.id])
        #expect(store.config.remotes.map(\.id) == before)
    }
}

@MainActor
@Suite("Native supplier model table lifecycle")
struct NativeSupplierModelTableTests {
    private struct Setup {
        let directory: TempConfigDirectory
        let store: ConfigStore
        let coordinator: NativeSupplierModelList.Coordinator
        let table: SupplierModelTableView
        let alpha: [RemoteModel]
        let beta: RemoteModel
    }

    private func remote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "k", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
    }

    private func makeSetup(sortEnabled: Bool = true) throws -> Setup {
        let aOne = remote("Alpha", "one")
        let beta = remote("Beta", "one")
        let aTwo = remote("Alpha", "two")
        let aThree = remote("Alpha", "three")
        let directory = try TempConfigDirectory(name: "supplier-table")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [aOne, beta, aTwo, aThree], fakes: []))
            .write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let alpha = [aOne, aTwo, aThree]
        let items = alpha.map { SupplierModelItem(id: $0.id, label: $0.model, needsCredentials: false) }
        let list = NativeSupplierModelList(items: items, provider: "Alpha", sortEnabled: sortEnabled,
                                           store: store, onRename: { _, _ in nil })
        let coordinator = list.makeCoordinator()
        let table = SupplierModelTableView()
        list.wire(table, coordinator: coordinator)
        coordinator.apply(items: items)
        return Setup(directory: directory, store: store, coordinator: coordinator, table: table,
                     alpha: alpha, beta: beta)
    }

    @Test func tableWiresNativeDragTypesAndRowMenu() throws {
        let s = try makeSetup()
        #expect(s.table.delegate === s.coordinator)
        #expect(s.table.dataSource === s.coordinator)
        #expect(s.table.registeredDraggedTypes.contains(ModelDragPayload.nativePasteboardType))
        #expect(s.coordinator.numberOfRows(in: s.table) == 3)
        #expect(s.coordinator.displayedIDs == s.alpha.map(\.id))
        // 右键菜单只对真实行提供：重命名 / 删除两项（重命名能力保留）。
        #expect(s.coordinator.contextMenu(row: 0)?.items.map(\.title) == ["重命名", "删除"])
        #expect(s.coordinator.contextMenu(row: 3) == nil)
    }

    @Test func wholeRowWritesDecodableModelPayload() throws {
        let s = try makeSetup()
        let writer = s.coordinator.tableView(s.table, pasteboardWriterForRow: 0)
        let item = try #require(writer as? NSPasteboardItem)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ezswitch.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        #expect(ModelDragPayload.decode(pasteboard: pasteboard)?.map(\.id) == [s.alpha[0].id])
        // 越界行不是拖拽来源。
        #expect(s.coordinator.tableView(s.table, pasteboardWriterForRow: 3) == nil)
    }

    @Test func dropCommitsSameProviderReorder() throws {
        let s = try makeSetup()
        #expect(s.coordinator.commitDrop(row: 2, payload: [ModelDragItem(id: s.alpha[0].id)]))
        #expect(s.store.config.remotes.map(\.id) == [s.alpha[1].id, s.beta.id, s.alpha[0].id, s.alpha[2].id])
    }

    /// 行下标必须在 [0, count]：越界拒绝，row == count 才是合法的末尾追加。
    @Test func commitDropRejectsRowsOutsideValidRange() throws {
        let s = try makeSetup()
        let payload = [ModelDragItem(id: s.alpha[0].id)]
        #expect(s.coordinator.commitDrop(row: -1, payload: payload) == false)
        #expect(s.coordinator.commitDrop(row: 4, payload: payload) == false)
        #expect(s.store.config.remotes.map(\.id) == [s.alpha[0].id, s.beta.id, s.alpha[1].id, s.alpha[2].id])
        #expect(s.coordinator.commitDrop(row: 3, payload: payload))
        #expect(s.store.config.remotes.map(\.id) == [s.alpha[1].id, s.beta.id, s.alpha[2].id, s.alpha[0].id])
    }

    /// 筛选时禁用供应商内部排序，但拖动源不受影响：模型仍可拖出到路由。
    @Test func sortDisabledRejectsDropButRowStillDraggable() throws {
        let s = try makeSetup(sortEnabled: false)
        let before = s.store.config.remotes.map(\.id)
        #expect(s.coordinator.commitDrop(row: 2, payload: [ModelDragItem(id: s.alpha[0].id)]) == false)
        #expect(s.store.config.remotes.map(\.id) == before)
        #expect(s.coordinator.tableView(s.table, pasteboardWriterForRow: 1) != nil)
    }

    @Test func dropRejectsCrossProviderEvenWhenEnabled() throws {
        let s = try makeSetup()
        let before = s.store.config.remotes.map(\.id)
        #expect(s.coordinator.commitDrop(row: 0, payload: [ModelDragItem(id: s.beta.id)]) == false)
        #expect(s.store.config.remotes.map(\.id) == before)
    }

    @Test func freezeKeepsDisplayedSnapshotWhileDragging() throws {
        let s = try makeSetup()
        s.coordinator.dragStateChanged(true)
        let rotated = [s.alpha[1], s.alpha[2], s.alpha[0]].map {
            SupplierModelItem(id: $0.id, label: $0.model, needsCredentials: false)
        }
        s.coordinator.apply(items: rotated)
        #expect(s.coordinator.displayedIDs == s.alpha.map(\.id))
        s.coordinator.dragStateChanged(false)
        #expect(s.coordinator.displayedIDs == rotated.map(\.id))
    }
}

/// 供应商原生表格的可见单行选中、原生就地重命名与右键菜单回调。
@MainActor
@Suite("Native supplier model interactions")
struct NativeSupplierInteractionTests {
    /// 记录内联重命名提交（稳定 ID + 提交文本）与删除回调。
    private final class Recorder {
        var renamed: [(id: UUID, text: String)] = []
        var deleted: [UUID] = []
    }

    private struct Setup {
        let directory: TempConfigDirectory
        let store: ConfigStore
        let coordinator: NativeSupplierModelList.Coordinator
        let table: SupplierModelTableView
        let container: SupplierModelTableContainer
        let window: NSWindow
        let alpha: [RemoteModel]
        let recorder: Recorder
    }

    private func remote(_ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "Alpha · \(model)", apiKey: "k", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
    }

    private func items(_ models: [RemoteModel]) -> [SupplierModelItem] {
        models.map { SupplierModelItem(id: $0.id, label: $0.model, needsCredentials: false) }
    }

    private func makeSetup() throws -> Setup {
        let models = [remote("one"), remote("two"), remote("three")]
        let directory = try TempConfigDirectory(name: "supplier-interaction")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: models, fakes: [])).write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let recorder = Recorder()
        let list = NativeSupplierModelList(items: items(models), provider: "Alpha", sortEnabled: true,
                                           store: store,
                                           onRename: { id, text in
                                               recorder.renamed.append((id, text))
                                               return store.updateModel(id: id, model: text)
                                           },
                                           onDelete: { recorder.deleted.append($0) })
        let coordinator = list.makeCoordinator()
        let container = SupplierModelTableContainer(rowHeight: 24)
        // 挂到一个离屏窗口：menu(for:) 的命中换算依赖窗口坐标，无窗口时 convert(from: nil) 会把翻转视图坐标算错。
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 90),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        list.wire(container.tableView, coordinator: coordinator)
        coordinator.apply(items: items(models))
        container.layoutSubtreeIfNeeded()
        return Setup(directory: directory, store: store, coordinator: coordinator,
                     table: container.tableView, container: container, window: window,
                     alpha: models, recorder: recorder)
    }

    private func keyEvent(_ keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\r", charactersIgnoringModifiers: "\r",
                                      isARepeat: false, keyCode: keyCode))
    }

    /// 容器启用可见的单行选中：单选、可空选、有高亮。
    @Test func containerEnablesSingleVisibleSelection() throws {
        let s = try makeSetup()
        #expect(s.container.tableView.allowsMultipleSelection == false)
        #expect(s.container.tableView.allowsEmptySelection == true)
        #expect(s.container.tableView.selectionHighlightStyle != .none)
        #expect(s.coordinator.selectedID == nil)
    }

    /// 采用原生 `.inset` 圆角内缩选中（AppKit 绘制，无手绘蓝色形状），行高保持紧凑 24、行间距归零。
    @Test func containerUsesNativeInsetRoundedSelection() throws {
        let s = try makeSetup()
        #expect(s.container.tableView.style == .inset)
        #expect(s.container.tableView.selectionHighlightStyle == .regular)
        #expect(s.container.tableView.rowHeight == 24)
        #expect(s.container.tableView.intercellSpacing == NSSize(width: 0, height: 0))
    }

    /// 选中记录稳定 ID，且始终是单行；越界行不改变选中。
    @Test func selectionRecordsStableIDAndStaysSingle() throws {
        let s = try makeSetup()
        #expect(s.coordinator.selectRow(1))
        #expect(s.coordinator.selectedID == s.alpha[1].id)
        #expect(s.table.selectedRow == 1)
        #expect(s.table.selectedRowIndexes == IndexSet(integer: 1))
        #expect(s.coordinator.selectRow(2))
        #expect(s.table.selectedRowIndexes == IndexSet(integer: 2))
        #expect(s.coordinator.selectedID == s.alpha[2].id)
        // 越界行拒绝，选中不变。
        #expect(s.coordinator.selectRow(3) == false)
        #expect(s.coordinator.selectedID == s.alpha[2].id)
    }

    /// AppKit 触发的选中变化（用户点击）由委托回写到稳定 ID；空选中清空。
    @Test func userSelectionChangeSyncsStableID() throws {
        let s = try makeSetup()
        let notification = Notification(name: NSTableView.selectionDidChangeNotification, object: s.table)
        s.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        s.coordinator.tableViewSelectionDidChange(notification)
        #expect(s.coordinator.selectedID == s.alpha[2].id)
        s.table.deselectAll(nil)
        s.coordinator.tableViewSelectionDidChange(notification)
        #expect(s.coordinator.selectedID == nil)
    }

    /// reload / 重排后选中跟随稳定 UUID，而不是旧行号。
    @Test func selectionFollowsStableIDAcrossReorder() throws {
        let s = try makeSetup()
        #expect(s.coordinator.selectRow(1))
        let rotated = items([s.alpha[1], s.alpha[0], s.alpha[2]])
        s.coordinator.apply(items: rotated)
        #expect(s.coordinator.displayedIDs == rotated.map(\.id))
        #expect(s.coordinator.selectedID == s.alpha[1].id)
        #expect(s.table.selectedRow == 0)
    }

    /// 选中行被移除时清空选中。
    @Test func selectionClearsWhenSelectedRowIsRemoved() throws {
        let s = try makeSetup()
        #expect(s.coordinator.selectRow(1))
        s.coordinator.apply(items: items([s.alpha[0], s.alpha[2]]))
        #expect(s.coordinator.selectedID == nil)
        #expect(s.table.selectedRow == -1)
    }

    /// 拖动冻结期间显示快照与选中都不变，解冻后积压数据与选中一起应用。
    @Test func selectionSurvivesDragFreezeAndDeferredReload() throws {
        let s = try makeSetup()
        #expect(s.coordinator.selectRow(2))
        s.coordinator.dragStateChanged(true)
        let rotated = items([s.alpha[2], s.alpha[0], s.alpha[1]])
        s.coordinator.apply(items: rotated)
        #expect(s.coordinator.displayedIDs == s.alpha.map(\.id))
        #expect(s.coordinator.selectedID == s.alpha[2].id)
        s.coordinator.dragStateChanged(false)
        #expect(s.coordinator.displayedIDs == rotated.map(\.id))
        #expect(s.coordinator.selectedID == s.alpha[2].id)
        #expect(s.table.selectedRow == 0)
    }

    /// Return / 小键盘 Enter 只对有有效选中的行开始就地编辑；无选中或选中行已移除都不触发。
    @Test func returnAndKeypadEnterStartEditingOnlyWithSelection() throws {
        let s = try makeSetup()
        // 无有效选中：键盘闸门直接拒绝（不进入编辑）。
        #expect(s.table.onReturnKey?() == false)
        #expect(s.coordinator.activateSelectedRow() == false)
        #expect(s.coordinator.editingID == nil)
        // 选中第 2 行：Return 进入就地编辑。
        #expect(s.coordinator.selectRow(1))
        s.table.keyDown(with: try keyEvent(36))
        #expect(s.coordinator.editingID == s.alpha[1].id)
        s.coordinator.cancelEditing()
        // 小键盘 Enter 同样进入就地编辑。
        s.table.keyDown(with: try keyEvent(76))
        #expect(s.coordinator.editingID == s.alpha[1].id)
        // 只是开始编辑，未提交：没有任何写入。
        #expect(s.recorder.renamed.isEmpty)
        s.coordinator.cancelEditing()
        // 选中行被移除后：闸门再次拒绝。
        s.coordinator.apply(items: items([s.alpha[0], s.alpha[2]]))
        #expect(s.coordinator.selectedID == nil)
        #expect(s.table.onReturnKey?() == false)
    }

    /// 右键菜单恰好是“重命名 / 删除”：“重命名”开始就地编辑，“删除”按稳定 UUID 回调。
    @Test func contextMenuOffersRenameAndDeleteWiredToCallbacks() throws {
        let s = try makeSetup()
        let menu = try #require(s.coordinator.contextMenu(row: 1))
        #expect(menu.items.map(\.title) == ["重命名", "删除"])
        // “重命名”改为就地编辑（不再直接写配置、也不弹面板）。
        s.coordinator.renameMenuItemClicked(menu.items[0])
        #expect(s.coordinator.editingID == s.alpha[1].id)
        #expect(s.recorder.renamed.isEmpty)
        s.coordinator.cancelEditing()
        // “删除”仍按稳定 UUID 回调（removeRemote 语义由视图层接线）。
        s.coordinator.deleteMenuItemClicked(menu.items[1])
        #expect(s.recorder.deleted == [s.alpha[1].id])
        // 越界行没有菜单。
        #expect(s.coordinator.contextMenu(row: 3) == nil)
        // 缺失 representedObject 的菜单项不触发任何回调。
        let bare = NSMenuItem(title: "重命名", action: nil, keyEquivalent: "")
        s.coordinator.renameMenuItemClicked(bare)
        s.coordinator.deleteMenuItemClicked(bare)
        #expect(s.coordinator.editingID == nil)
        #expect(s.recorder.deleted == [s.alpha[1].id])
    }

    // MARK: 原生就地重命名（字段编辑器）

    /// Return 对选中行开始原生就地编辑：cell 文本域可编辑，无校验提示，不触碰 store。
    @Test func returnBeginsInPlaceEditingOnSelectedRow() throws {
        let s = try makeSetup()
        #expect(s.coordinator.selectRow(1))
        #expect(s.coordinator.activateSelectedRow())
        #expect(s.coordinator.editingID == s.alpha[1].id)
        #expect(s.coordinator.editingRow == 1)
        let cell = s.table.view(atColumn: 0, row: 1, makeIfNecessary: false) as? SupplierModelCell
        #expect(cell?.isTitleEditable == true)
        #expect(cell?.isShowingValidation == false)
        #expect(s.recorder.renamed.isEmpty)
        #expect(s.store.config.remotes[1].model == "two")
    }

    /// 拖动会话进行中拒绝进入编辑。
    @Test func beginEditingRefusedWhileDragging() throws {
        let s = try makeSetup()
        s.coordinator.dragStateChanged(true)
        #expect(s.coordinator.beginEditing(row: 1) == false)
        #expect(s.coordinator.editingID == nil)
        s.coordinator.dragStateChanged(false)
    }

    /// Return 提交：按稳定 UUID 写入 ConfigStore，结束编辑并保留选中。
    @Test func returnCommitsInlineRenameToStore() throws {
        let s = try makeSetup()
        #expect(s.coordinator.beginEditing(row: 1))
        #expect(s.coordinator.handleReturn(withText: "two-renamed"))
        #expect(s.coordinator.editingID == nil)
        #expect(s.recorder.renamed.map { $0.id } == [s.alpha[1].id])
        #expect(s.recorder.renamed.map { $0.text } == ["two-renamed"])
        #expect(s.store.config.remotes.first { $0.id == s.alpha[1].id }?.model == "two-renamed")
        #expect(s.coordinator.selectedID == s.alpha[1].id)
    }

    /// 原文未变：Return 只结束编辑，不调用提交闭包、不写入。
    @Test func returnWithUnchangedNameEndsWithoutCommit() throws {
        let s = try makeSetup()
        #expect(s.coordinator.beginEditing(row: 0))
        #expect(s.coordinator.handleReturn(withText: "one"))
        #expect(s.coordinator.editingID == nil)
        #expect(s.recorder.renamed.isEmpty)
        #expect(s.store.config.remotes[0].model == "one")
    }

    /// Escape（取消）不写入任何内容并结束编辑。
    @Test func escapeCancelsWithoutWriting() throws {
        let s = try makeSetup()
        #expect(s.coordinator.beginEditing(row: 1))
        s.coordinator.cancelEditing()
        #expect(s.coordinator.editingID == nil)
        #expect(s.recorder.renamed.isEmpty)
        #expect(s.store.config.remotes[1].model == "two")
    }

    /// 空模型 ID：就地展示原生校验文案并保持编辑，不写入。
    @Test func emptyNameKeepsEditingWithInlineValidation() throws {
        let s = try makeSetup()
        #expect(s.coordinator.beginEditing(row: 1))
        #expect(s.coordinator.handleReturn(withText: "   ") == false)
        #expect(s.coordinator.editingID == s.alpha[1].id)
        #expect(s.coordinator.editingError == "模型 ID 不能为空")
        let cell = s.table.view(atColumn: 0, row: 1, makeIfNecessary: false) as? SupplierModelCell
        #expect(cell?.validationMessage == "模型 ID 不能为空")
        #expect(cell?.isShowingValidation == true)
        #expect(s.store.config.remotes[1].model == "two")
        #expect(s.coordinator.selectedID == s.alpha[1].id)
    }

    /// 重复模型 ID：就地展示校验并保持编辑；修正为合法名称后即可提交。
    @Test func duplicateNameKeepsEditingWithInlineValidation() throws {
        let s = try makeSetup()
        #expect(s.coordinator.beginEditing(row: 1))
        #expect(s.coordinator.handleReturn(withText: "three") == false)
        #expect(s.coordinator.editingID == s.alpha[1].id)
        #expect(s.coordinator.editingError == "该供应商下模型 ID 已存在")
        #expect(s.store.config.remotes[1].model == "two")
        #expect(s.coordinator.handleReturn(withText: "two-fixed"))
        #expect(s.coordinator.editingID == nil)
        #expect(s.store.config.remotes[1].model == "two-fixed")
    }

    /// 编辑期间冻结 reload：新行数据积压，编辑结束后再落回，选中仍按稳定 UUID。
    @Test func editingFreezesReloadUntilSessionEnds() throws {
        let s = try makeSetup()
        #expect(s.coordinator.beginEditing(row: 1))
        let rotated = items([s.alpha[2], s.alpha[1], s.alpha[0]])
        s.coordinator.apply(items: rotated)
        #expect(s.coordinator.displayedIDs == s.alpha.map(\.id))
        s.coordinator.cancelEditing()
        #expect(s.coordinator.displayedIDs == rotated.map(\.id))
        #expect(s.coordinator.selectedID == s.alpha[1].id)
    }

    /// 编辑期间不发起拖动；会话结束后恢复可拖动。
    @Test func editingBlocksDragSource() throws {
        let s = try makeSetup()
        #expect(s.coordinator.beginEditing(row: 1))
        #expect(s.coordinator.tableView(s.table, pasteboardWriterForRow: 1) == nil)
        s.coordinator.cancelEditing()
        #expect(s.coordinator.tableView(s.table, pasteboardWriterForRow: 1) != nil)
    }

    /// 字段编辑器委托：Escape 取消、Return 校验失败保持编辑、合法后 Return 提交。
    @Test func fieldEditorDelegateDrivesCommitCancelAndValidation() throws {
        let s = try makeSetup()
        let cell = try #require(s.table.view(atColumn: 0, row: 2, makeIfNecessary: false) as? SupplierModelCell)
        let field = try #require(cell.textField)
        let editor = NSTextView()
        // Escape → 取消，零写入。
        #expect(s.coordinator.beginEditing(row: 2))
        editor.string = "ignored"
        #expect(s.coordinator.control(field, textView: editor,
                                      doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(s.coordinator.editingID == nil)
        #expect(s.recorder.renamed.isEmpty)
        // 空文本 Return → 保持编辑并展示校验。
        #expect(s.coordinator.beginEditing(row: 2))
        editor.string = ""
        #expect(s.coordinator.control(field, textView: editor,
                                      doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(s.coordinator.editingID == s.alpha[2].id)
        #expect(s.recorder.renamed.map { $0.text } == [""])
        // 合法文本 Return → 提交并结束。
        editor.string = "three-fixed"
        #expect(s.coordinator.control(field, textView: editor,
                                      doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(s.coordinator.editingID == nil)
        #expect(s.store.config.remotes[2].model == "three-fixed")
    }

    /// 右键命中行的选择副作用：菜单作用在用户点中的确切行（选中跟随该行稳定 ID）。
    @Test func contextMenuSelectionTargetsExactRow() throws {
        let s = try makeSetup()
        #expect(s.coordinator.selectRow(0))
        s.table.selectRowForContextMenu(1)
        #expect(s.table.selectedRow == 1)
        #expect(s.coordinator.selectedID == s.alpha[1].id)
        // 越界命中不改变选中。
        s.table.selectRowForContextMenu(9)
        #expect(s.table.selectedRow == 1)
    }

    /// 右键命中行触发 menu(for:)：先选中该行，再返回“重命名 / 删除”菜单；命中空白不弹菜单。
    @Test func rightClickSelectsExactTargetRowAndBuildsMenu() throws {
        let s = try makeSetup()
        #expect(s.coordinator.selectRow(0))
        // 命中行用表格坐标定位，再换算成窗口坐标构造事件，与真实右键一致。
        let rowPoint = NSPoint(x: 20, y: s.table.rect(ofRow: 1).midY)
        let windowPoint = s.table.convert(rowPoint, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: windowPoint,
                                                    modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(s.table.menu(for: event))
        #expect(menu.items.map(\.title) == ["重命名", "删除"])
        #expect(s.table.selectedRow == 1)
        #expect(s.coordinator.selectedID == s.alpha[1].id)
        // 命中表格下方空白（无行）不弹菜单，选中不变。
        let blankPoint = s.table.convert(NSPoint(x: 20, y: -10), to: nil)
        let blank = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: blankPoint,
                                                    modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(s.table.menu(for: blank) == nil)
        #expect(s.table.selectedRow == 1)
    }
}

/// 原生 `.inset` 表格的真实几何：外层布局高度 = 行区净高（顶部样式内缩被容器滚出可视区），
/// 首行贴顶、末行连同圆角完整可见；命中测试在偏移后仍正确。
@MainActor
@Suite("Native supplier model list geometry")
struct NativeSupplierModelGeometryTests {
    private struct Setup {
        let directory: TempConfigDirectory
        let container: SupplierModelTableContainer
        let coordinator: NativeSupplierModelList.Coordinator
        let rows: Int
    }

    private func remote(_ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "Alpha · \(model)", apiKey: "k", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
    }

    /// 容器可视高度取行区净高（与 `sizeThatFits` 返回值一致），因此窗口内容高度设为 行数 × 行高。
    private func makeSetup(rows: Int) throws -> Setup {
        let models = (0..<rows).map { remote("m\($0)") }
        let directory = try TempConfigDirectory(name: "supplier-geometry")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: models, fakes: [])).write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let items = models.map { SupplierModelItem(id: $0.id, label: $0.model, needsCredentials: false) }
        let list = NativeSupplierModelList(items: items, provider: "Alpha", sortEnabled: true,
                                           store: store, onRename: { _, _ in nil })
        let coordinator = list.makeCoordinator()
        let container = SupplierModelTableContainer(rowHeight: list.rowHeight)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: max(CGFloat(rows) * list.rowHeight, 1)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        list.wire(container.tableView, coordinator: coordinator)
        coordinator.apply(items: items)
        container.tableView.reloadData()
        container.layoutSubtreeIfNeeded()
        container.layout()
        return Setup(directory: directory, container: container, coordinator: coordinator, rows: rows)
    }

    @Test func tightHeightEqualsMeasuredRowArea() throws {
        for rows in [1, 2, 3] {
            let s = try makeSetup(rows: rows)
            let table = s.container.tableView
            let height = CGFloat(rows) * table.rowHeight
            #expect(s.container.tightContentHeight == height)
            #expect(table.rect(ofRow: rows - 1).maxY - table.rect(ofRow: 0).minY == height)
        }
    }

    /// 首行紧贴可视顶部、末行连同圆角完整可见：顶部样式内缩被滚出可视区，底行不再被裁。
    @Test func firstRowAtVisibleTopAndLastRowFullyVisible() throws {
        for rows in [1, 2, 3] {
            let s = try makeSetup(rows: rows)
            let table = s.container.tableView
            let visible = s.container.contentView.bounds
            let inset = table.rect(ofRow: 0).minY
            #expect(inset > 0)                                          // `.inset` 确实加入固定顶部内缩
            #expect(visible.minY == inset)                              // 该内缩被容器滚出可视区
            #expect(table.rect(ofRow: 0).minY == visible.minY)          // 首行贴近分隔线
            #expect(table.rect(ofRow: rows - 1).maxY == visible.maxY)   // 末行完整可见（圆角不被裁）
            #expect(table.frame.height == inset + s.container.tightContentHeight)
        }
    }

    /// 容器可视高度 == `sizeThatFits` 返回值（行区净高）：不再少算顶部内缩。
    @Test func containerVisibleHeightMatchesSizeThatFits() throws {
        for rows in [1, 2, 3] {
            let s = try makeSetup(rows: rows)
            #expect(s.container.contentSize.height == s.container.tightContentHeight)
        }
    }

    /// 偏移后的命中测试仍正确：可视顶 / 底分别命中首行 / 末行。
    @Test func hitTestingSurvivesTopInsetOffset() throws {
        for rows in [2, 3] {
            let s = try makeSetup(rows: rows)
            let visible = s.container.contentView.bounds
            #expect(s.container.tableView.row(at: NSPoint(x: 5, y: visible.minY + 1)) == 0)
            #expect(s.container.tableView.row(at: NSPoint(x: 5, y: visible.maxY - 1)) == rows - 1)
        }
    }

    /// 选中末行 / AppKit 在 layout 之外重置 clip bounds / 再次 layout 后，顶部内缩偏移仍被钉住；
    /// 文档 frame 原点不被 tile 改动。（回归：初次 layout 有效、交互后偏移丢失。）
    @Test func selectionAndResetKeepTopInsetOffset() throws {
        for rows in [1, 2, 3] {
            let s = try makeSetup(rows: rows)
            let table = s.container.tableView
            let clip = s.container.contentView
            let inset = table.rect(ofRow: 0).minY
            #expect(clip.bounds.minY == inset)
            // 选中末行：原生会尝试 scrollRowToVisible。
            s.coordinator.selectRow(rows - 1)
            table.scrollRowToVisible(rows - 1)
            #expect(clip.bounds.minY == inset)
            #expect(table.rect(ofRow: rows - 1).maxY == clip.bounds.maxY)
            #expect(table.frame.origin == .zero)
            // 在 layout 之外直接重置：钉住逻辑立即恢复偏移。
            clip.bounds.origin = .zero
            #expect(clip.bounds.minY == inset)
            clip.scroll(to: .zero)
            #expect(clip.bounds.minY == inset)
            // SwiftUI 更新再 layout 后仍保持。
            s.container.layout()
            #expect(clip.bounds.minY == inset)
            #expect(table.rect(ofRow: 0).minY == clip.bounds.minY)
            #expect(table.rect(ofRow: rows - 1).maxY == clip.bounds.maxY)
        }
    }

    @Test func emptyListHasNoHeightOrOffset() throws {
        let s = try makeSetup(rows: 0)
        #expect(s.container.tightContentHeight == 0)
        #expect(s.container.topInset == 0)
        #expect(s.container.contentView.bounds.minY == 0)
    }
}

/// 工作区共享选中：跨所有供应商卡片只有一个选中模型；任意卡片显示另一张卡片的选中即清除。
@MainActor
@Suite("Workspace shared model selection")
struct WorkspaceSharedModelSelectionTests {
    private final class Recorder {
        var changes: [UUID?] = []
    }

    private struct Card {
        let directory: TempConfigDirectory
        let coordinator: NativeSupplierModelList.Coordinator
        let table: SupplierModelTableView
        let models: [RemoteModel]
    }

    private func remote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "k", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
    }

    private func items(_ models: [RemoteModel]) -> [SupplierModelItem] {
        models.map { SupplierModelItem(id: $0.id, label: $0.model, needsCredentials: false) }
    }

    private func makeCard(provider: String, models: [RemoteModel], recorder: Recorder) throws -> Card {
        let directory = try TempConfigDirectory(name: "shared-\(provider)")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: models, fakes: [])).write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let list = NativeSupplierModelList(items: items(models), provider: provider, sortEnabled: true,
                                           store: store, onRename: { _, _ in nil },
                                           onSelectionChange: { recorder.changes.append($0) })
        let coordinator = list.makeCoordinator()
        let table = SupplierModelTableView()
        list.wire(table, coordinator: coordinator)
        coordinator.apply(items: items(models))
        return Card(directory: directory, coordinator: coordinator, table: table, models: models)
    }

    /// 选中缓冲卡片后，把共享选中同步到另一张卡片：另一张卡片不显示任何选中 → 全局唯一。
    @Test func onlyOneCardShowsSelectionAcrossWorkspace() throws {
        let recorder = Recorder()
        let alpha = try makeCard(provider: "Alpha",
                                 models: [remote("Alpha", "a1"), remote("Alpha", "a2"), remote("Alpha", "a3")],
                                 recorder: recorder)
        let beta = try makeCard(provider: "Beta",
                                models: [remote("Beta", "b1"), remote("Beta", "b2")],
                                recorder: recorder)
        // 选中 Alpha.a2，同步到 Beta：Beta 无行匹配 → 无选中。
        #expect(alpha.coordinator.selectRow(1))
        beta.coordinator.applySelectedModelID(alpha.coordinator.selectedID)
        #expect(alpha.coordinator.selectedID == alpha.models[1].id)
        #expect(beta.coordinator.selectedID == nil)
        #expect(beta.table.selectedRow == -1)
        // 选中 Beta.b1，同步到 Alpha：Alpha 清除选中 → 全局仍有且仅有一行被选中。
        #expect(beta.coordinator.selectRow(0))
        alpha.coordinator.applySelectedModelID(beta.coordinator.selectedID)
        #expect(alpha.coordinator.selectedID == nil)
        #expect(alpha.table.selectedRow == -1)
        #expect(beta.coordinator.selectedID == beta.models[0].id)
        #expect(beta.table.selectedRow == 0)
        // 两次用户选中都上报工作区（共享真源）。
        #expect(recorder.changes.map { $0 } == [alpha.models[1].id, beta.models[0].id])
    }

    /// 程序化同步共享选中不触发回写回调（避免工作区 ↔ 卡片回环）。
    @Test func applyingSharedSelectionDoesNotFeedback() throws {
        let recorder = Recorder()
        let alpha = try makeCard(provider: "Alpha",
                                 models: [remote("Alpha", "a1"), remote("Alpha", "a2")],
                                 recorder: recorder)
        #expect(alpha.coordinator.selectRow(1))
        let after = recorder.changes.count
        alpha.coordinator.applySelectedModelID(alpha.models[1].id)   // 同值 → 无操作
        alpha.coordinator.applySelectedModelID(alpha.models[0].id)   // 外部改选 → 移动选中
        #expect(recorder.changes.count == after)
        #expect(alpha.coordinator.selectedID == alpha.models[0].id)
        #expect(alpha.table.selectedRow == 0)
    }

    /// 用户原生选中变化（点击 / 右键选中）经委托回写工作区共享选中。
    @Test func userSelectionChangeReportsToWorkspace() throws {
        let recorder = Recorder()
        let alpha = try makeCard(provider: "Alpha",
                                 models: [remote("Alpha", "a1"), remote("Alpha", "a2"), remote("Alpha", "a3")],
                                 recorder: recorder)
        alpha.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        recorder.changes.removeAll()
        alpha.coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: alpha.table))
        #expect(alpha.coordinator.selectedID == alpha.models[2].id)
        #expect(recorder.changes == [alpha.models[2].id])
    }

    /// 共享选中为 nil（工作区已清空 / 模型被移除）时卡片清除选中。
    @Test func externalNilSelectionClearsCard() throws {
        let recorder = Recorder()
        let alpha = try makeCard(provider: "Alpha",
                                 models: [remote("Alpha", "a1"), remote("Alpha", "a2")],
                                 recorder: recorder)
        #expect(alpha.coordinator.selectRow(0))
        alpha.coordinator.applySelectedModelID(nil)
        #expect(alpha.coordinator.selectedID == nil)
        #expect(alpha.table.selectedRow == -1)
    }

    /// 选中行被移除后选中清空（稳定 UUID 失效即清除）。
    @Test func removedSelectedModelClearsSelection() throws {
        let recorder = Recorder()
        let alpha = try makeCard(provider: "Alpha",
                                 models: [remote("Alpha", "a1"), remote("Alpha", "a2"), remote("Alpha", "a3")],
                                 recorder: recorder)
        #expect(alpha.coordinator.selectRow(1))
        alpha.coordinator.apply(items: items([alpha.models[0], alpha.models[2]]))
        #expect(alpha.coordinator.selectedID == nil)
        #expect(alpha.table.selectedRow == -1)
    }
}
