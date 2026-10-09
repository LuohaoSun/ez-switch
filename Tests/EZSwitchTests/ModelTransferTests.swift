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
                                           store: store, onEdit: { _ in })
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
        // 右键菜单只对真实行提供（编辑模型能力保留）。
        #expect(s.coordinator.contextMenu(row: 0)?.items.first?.title == "编辑模型…")
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
