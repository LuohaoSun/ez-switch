import Foundation
import AppKit
import Testing
@testable import EZSwitch

/// 收起态的 AppKit 行为：焦点/AX/子控件禁用与恢复、native 回调按目标状态拒绝输入、高度回调的实测值与去重。
/// 全部离屏（borderless 窗口，不 order front），不启动 UI。
@MainActor
@Suite("Collapsible native table interaction")
struct CollapsibleTableInteractionTests {
    private final class HeightBox { var heights: [CGFloat] = [] }

    private func remote(_ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "Alpha · \(model)", apiKey: "k", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test"))
    }

    /// 离屏窗口：焦点/编辑/行视图需要窗口坐标，但不启动、不显示 UI。
    private func offscreenWindow(_ content: NSView, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        return window
    }

    /// 表子树内的 `NSControl`（行内按钮 / 文本域）；不跨出本表。
    private func controls(in root: NSView) -> [NSControl] {
        var result: [NSControl] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let control = view as? NSControl, control !== root { result.append(control) }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    @Test func routeTableRefusesInputWhenCollapsedAndRestoresAfterwards() throws {
        let remotes = [remote("m0"), remote("m1")]
        let route = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                              remoteID: remotes[0].id, fallbackRemoteIDs: [remotes[1].id])
        let directory = try TempConfigDirectory(name: "collapse-route")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: remotes, fakes: [route]))
            .write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let ids = store.config.fakes[0].orderedRemoteIDs
        let items = ids.map { RouteCandidateItem(id: $0, label: "Alpha · m") }
        var list = NativeRouteCandidateList(items: items, activeRemoteID: nil, store: store, fakeID: route.id)
        let coordinator = list.makeCoordinator()
        let container = CandidateTableContainer(rowHeight: 34)
        list.wire(container.tableView, coordinator: coordinator)
        coordinator.apply(items: items, active: nil)
        let window = offscreenWindow(container, height: 200)
        container.layoutSubtreeIfNeeded()
        // 建出真实行视图，让行内删除按钮成为本表子控件。
        _ = container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        let children = controls(in: container.tableView)
        #expect(!children.isEmpty)

        #expect(coordinator.handleClick(row: 0))
        #expect(coordinator.contextMenu(row: 0) != nil)
        #expect(coordinator.tableView(container.tableView, pasteboardWriterForRow: 0) != nil)

        coordinator.setInteractive(false)
        // 收起不得隐藏表格：否则收起动画的内容会瞬间消失。
        #expect(container.tableView.isHidden == false)
        #expect(container.tableView.refusesFirstResponder)
        #expect(container.tableView.isAccessibilityHidden())
        #expect(children.allSatisfy { !$0.isEnabled })
        #expect(children.allSatisfy { $0.refusesFirstResponder })
        #expect(coordinator.handleClick(row: 0) == false)
        #expect(coordinator.contextMenu(row: 0) == nil)
        #expect(coordinator.tableView(container.tableView, pasteboardWriterForRow: 0) == nil)
        list.isInteractive = false
        #expect(list.commit([ModelDragItem(id: ids[0])], slot: .end) == false)

        coordinator.setInteractive(true)
        #expect(container.tableView.refusesFirstResponder == false)
        #expect(container.tableView.isAccessibilityHidden() == false)
        #expect(children.allSatisfy { $0.isEnabled })
        #expect(coordinator.handleClick(row: 0))
        #expect(coordinator.contextMenu(row: 0) != nil)
        #expect(container.window === window)
    }

    @Test func supplierTableReportsRealTightHeightOnceAndRefusesInputWhenCollapsed() async throws {
        let models = [remote("one"), remote("two"), remote("three")]
        let directory = try TempConfigDirectory(name: "collapse-supplier")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: models, fakes: []))
            .write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        let box = HeightBox()
        let items = models.map { SupplierModelItem(id: $0.id, label: $0.model, needsCredentials: false) }
        let list = NativeSupplierModelList(items: items, provider: "Alpha", sortEnabled: true,
                                           store: store, onRename: { _, _ in nil },
                                           onContentHeightChange: { box.heights.append($0) })
        let coordinator = list.makeCoordinator()
        let container = SupplierModelTableContainer(rowHeight: 24)
        list.wire(container.tableView, coordinator: coordinator)
        coordinator.apply(items: items)
        let window = offscreenWindow(container, height: 200)
        container.layoutSubtreeIfNeeded()
        _ = container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        let children = controls(in: container.tableView)
        #expect(!children.isEmpty)

        // 上报值必须是容器实测的行区净高（不是按行数推算的公式值），且变化才上报。
        let measured = container.tightContentHeight
        #expect(measured > 0)
        coordinator.reportContentHeight(measured)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(box.heights == [measured])
        coordinator.reportContentHeight(measured)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(box.heights == [measured])
        coordinator.reportContentHeight(measured + 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(box.heights == [measured, measured + 1])

        #expect(coordinator.commitDrop(row: 0, payload: [ModelDragItem(id: models[0].id)]))
        coordinator.setInteractive(false)
        // 收起不得隐藏表格：否则收起动画的内容会瞬间消失。
        #expect(container.tableView.isHidden == false)
        #expect(container.tableView.refusesFirstResponder)
        #expect(container.tableView.isAccessibilityHidden())
        #expect(children.allSatisfy { !$0.isEnabled })
        #expect(coordinator.contextMenu(row: 0) == nil)
        #expect(coordinator.beginEditing(row: 0) == false)
        #expect(coordinator.tableView(container.tableView, pasteboardWriterForRow: 0) == nil)
        let order = store.config.remotes.map(\.id)
        #expect(coordinator.commitDrop(row: 1, payload: [ModelDragItem(id: models[0].id)]) == false)
        #expect(store.config.remotes.map(\.id) == order)

        coordinator.setInteractive(true)
        #expect(container.tableView.refusesFirstResponder == false)
        #expect(container.tableView.isAccessibilityHidden() == false)
        #expect(children.allSatisfy { $0.isEnabled })
        #expect(coordinator.contextMenu(row: 0) != nil)
        #expect(container.window === window)
    }
}
