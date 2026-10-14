import AppKit
import SwiftUI

/// 路由候选列表中的一行：稳定 ID（远端 UUID）+ 展示标签。
/// 列表项顺序与 `FakeModel.orderedRemoteIDs` 一一对应，因此原生表格提出的行下标可直接映射回配置顺序。
struct RouteCandidateItem: Identifiable, Equatable {
    let id: UUID
    let label: String
}

/// 用原生 `NSTableView` 承载单条路由候选：行几何、拖动发起与插入落点（固定 `.above`）都归表格；
/// 行内容是最简 AppKit cell（删除按钮仅悬停/键盘焦点时显现、吞掉自身点击；右键菜单提供同一操作），
/// 表格不自滚动，高度由外层 SwiftUI 滚动视图决定。
struct NativeRouteCandidateList: NSViewRepresentable {
    let items: [RouteCandidateItem]
    let activeRemoteID: UUID?
    let store: ConfigStore
    let fakeID: UUID
    /// 收起时内容不可交互：不参与键盘焦点循环，也不暴露辅助功能元素
    /// （SwiftUI 的裁剪与 `allowsHitTesting` 只作用于 SwiftUI 层，挡不住 Tab 焦点）。
    var isInteractive: Bool = true
    var rowHeight: CGFloat = 34

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CandidateTableContainer {
        let container = CandidateTableContainer(rowHeight: rowHeight)
        wire(container.tableView, coordinator: context.coordinator)
        context.coordinator.apply(items: items, active: activeRemoteID)
        // 空路由时 apply 不会 reload；这里确保末尾占位行从首次显示起就存在。
        container.tableView.reloadData()
        context.coordinator.setInteractive(isInteractive)
        return container
    }

    /// 表格接线（数据源/委托/点击 action/拖放类型/生命周期回调）；makeNSView 与测试共用。
    @MainActor
    func wire(_ tableView: CandidateTableView, coordinator: Coordinator) {
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.target = coordinator
        tableView.action = #selector(Coordinator.tableClicked(_:))
        tableView.registerForDraggedTypes([ModelDragPayload.nativePasteboardType])
        // 本进程内拖动是移动；跨进程（外部来源）只按副本处理，避免破坏性语义。
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.onDraggingStateChange = { [weak coordinator] active in
            coordinator?.draggingActiveChanged(active)
        }
        // 新一次按下清掉上一次拖动遗留的点击抑制；若本次按下随即开始拖动，willBegin 会再抑制。
        tableView.onMouseDown = { [weak coordinator] in coordinator?.newMouseDown() }
        // 原生右键菜单：为非鼠标操作提供“从路由移除”入口（不改动“当前”选中）。
        tableView.contextMenuProvider = { [weak coordinator] row in coordinator?.contextMenu(row: row) }
        coordinator.attach(tableView)
    }

    func updateNSView(_ container: CandidateTableContainer, context: Context) {
        context.coordinator.parent = self
        if container.tableView.rowHeight != rowHeight {
            container.tableView.rowHeight = rowHeight
        }
        context.coordinator.apply(items: items, active: activeRemoteID)
        context.coordinator.setInteractive(isInteractive)
    }

    /// 高度含末尾常驻的占位行（“拖入模型”）。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CandidateTableContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: CGFloat(items.count + 1) * rowHeight)
    }

    /// 仅在行标识变化时 reloadData，且拖动期间绝不重载；落点行号先按显示快照换算成 UUID 锚点，再对当前配置解析。
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeRouteCandidateList
        private weak var tableView: NSTableView?

        /// 表格当前显示的行（拖动落点就按这个快照换算锚点）。
        private var displayedItems: [RouteCandidateItem] = []
        private var displayedActive: UUID?
        /// 拖动期间到达的最新数据；拖动结束后再应用，避免替换显示快照。
        private var latestItems: [RouteCandidateItem] = []
        private var latestActive: UUID?

        private var suppressReload = false
        private var pendingReload = false
        /// 本次拖动结束后短暂抑制行点击，保证拖动不改动“当前”选中模型。
        private var suppressClick = false
        /// 当前是否可交互（收起时否）。
        private var interactive = true
        private let focusShield = NativeTableFocusShield()

        init(_ parent: NativeRouteCandidateList) { self.parent = parent }

        func attach(_ tableView: NSTableView) { self.tableView = tableView }

        /// 收起时只拒绝焦点并禁用表内子控件；不隐藏表格，收起动画的绘制过渡不受影响。
        func setInteractive(_ value: Bool) {
            guard interactive != value else { return }
            interactive = value
            if let tableView { focusShield.apply(value, to: tableView) }
        }

        /// 表格当前显示的行标识；拖动落点即按这个快照换算锚点。
        var displayedIDs: [UUID] { displayedItems.map(\.id) }

        // MARK: 数据源

        /// 候选行 + 1 行末尾占位（空路由时只有占位行）。
        func numberOfRows(in tableView: NSTableView) -> Int { displayedItems.count + 1 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row <= displayedItems.count else { return nil }
            guard row < displayedItems.count else {
                let cell = (tableView.makeView(withIdentifier: RouteCandidatePlaceholderCell.reuseIdentifier, owner: nil)
                            as? RouteCandidatePlaceholderCell) ?? RouteCandidatePlaceholderCell()
                cell.configure(isEmpty: displayedItems.isEmpty)
                return cell
            }
            let item = displayedItems[row]
            let cell = (tableView.makeView(withIdentifier: RouteCandidateCell.reuseIdentifier, owner: nil)
                        as? RouteCandidateCell) ?? RouteCandidateCell()
            cell.configure(item: item, isActive: item.id == displayedActive)
            cell.onRemove = { [weak self] in self?.remove(itemID: item.id) }
            cell.onSelect = { [weak self] in self?.select(itemID: item.id) }
            return cell
        }

        /// 末尾占位行不可选中，因此也不能作为行拖拽的来源。
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            interactive && row >= 0 && row < displayedItems.count
        }

        // MARK: 视图更新（不打断拖动）

        func apply(items: [RouteCandidateItem], active: UUID?) {
            latestItems = items
            latestActive = active
            let identitiesChanged = items.map(\.id) != displayedItems.map(\.id)
            if identitiesChanged {
                guard !suppressReload else {
                    pendingReload = true
                    return
                }
                displayedItems = items
                displayedActive = active
                tableView?.reloadData()
                return
            }
            // 只有标签 / 当前指示变化：就地更新可见 cell，绝不 reload，拖动会话不受影响。
            displayedItems = items
            displayedActive = active
            refreshVisibleCells()
        }

        private func refreshVisibleCells() {
            guard let tableView else { return }
            for row in 0..<min(displayedItems.count, tableView.numberOfRows) {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? RouteCandidateCell else { continue }
                let item = displayedItems[row]
                cell.configure(item: item, isActive: item.id == displayedActive)
            }
        }

        // MARK: 点击选择（拖动不改变选中模型）

        @objc func tableClicked(_ sender: NSTableView) {
            // clickedRow 在 action 派发期间有效；退回 selectedRow 兜底。
            handleClick(row: sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow)
        }

        /// 新一次鼠标按下：清除上一次拖动遗留的点击抑制。
        func newMouseDown() {
            suppressClick = false
        }

        /// 行点击选择模型；拖动结束窗口内返回 false，保证拖动不改动显式选中模型。
        /// 收起态不可交互：不改变“当前”模型。
        @discardableResult
        func handleClick(row: Int) -> Bool {
            guard interactive, !suppressClick, row >= 0, row < displayedItems.count else { return false }
            select(itemID: displayedItems[row].id)
            return true
        }

        private func select(itemID: UUID) {
            guard interactive else { return }
            _ = parent.store.selectRouteModel(fakeID: parent.fakeID, remoteID: itemID)
        }

        private func remove(itemID: UUID) {
            guard interactive else { return }
            guard let current = parent.store.config.fakes.first(where: { $0.id == parent.fakeID }) else { return }
            let remaining = current.orderedRemoteIDs.filter { $0 != itemID }
            guard remaining != current.orderedRemoteIDs else { return }
            _ = parent.store.setRouteTargets(fakeID: current.id, remoteIDs: remaining,
                                            autoFallback: current.autoFallback)
        }

            // MARK: 右键菜单

        func contextMenu(row: Int) -> NSMenu? {
            guard interactive, row >= 0, row < displayedItems.count else { return nil }
            let delete = NSMenuItem(title: "从路由移除", action: #selector(removeMenuItemClicked(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = displayedItems[row].id
            let menu = NSMenu()
            menu.addItem(delete)
            return menu
        }

        @objc func removeMenuItemClicked(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            remove(itemID: id)
        }

        // MARK: 拖动源（标准 NSTableView 行拖动）

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard interactive, row >= 0, row < displayedItems.count else { return nil }
            return ModelDragPayload.pasteboardItem(ModelDragItem(id: displayedItems[row].id))
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            sourceDragWillBegin()
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            sourceDragDidEnd()
        }

        /// 本表格发起行拖动：冻结快照并抑制落点后的点击。
        func sourceDragWillBegin() {
            draggingActiveChanged(true)
            suppressClick = true
        }

        /// 行拖动结束：解冻，并在下一轮 runloop 解除点击抑制。
        func sourceDragDidEnd() {
            draggingActiveChanged(false)
            DispatchQueue.main.async { [weak self] in self?.suppressClick = false }
        }

        /// 冻结 = 不替换显示快照、不 reload，落点行号始终对应用户看到的行；解冻时应用拖动期间积压的数据。
        /// 成功（conclude）/失败（perform 返回 false）/取消（exited/ended）各结束路径都会调用。
        func draggingActiveChanged(_ active: Bool) {
            if active {
                suppressReload = true
                return
            }
            suppressReload = false
            guard pendingReload, let tableView else { return }
            pendingReload = false
            displayedItems = latestItems
            displayedActive = latestActive
            tableView.reloadData()
        }

        // MARK: 落点（原生提出行，固定 .above）

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // 全有或全无：任一条目类型不符或 Codable 解码失败都拒绝；来源身份按当前配置判定。
            guard interactive,
                  let payload = ModelDragPayload.decode(pasteboard: info.draggingPasteboard) else { return [] }
            let valid = Set(parent.store.config.remotes.map(\.id))
            guard !RouteCandidateReorder.sources(payload, validRemoteIDs: valid).isEmpty else { return [] }
            // 始终固定为 .above：末尾占位行（row == count）在系统提出 .on 时也转成末尾插入线。
            let target = max(0, min(row, displayedItems.count))
            tableView.setDropRow(target, dropOperation: .above)
            let mask = info.draggingSourceOperationMask
            if mask.contains(.move) { return .move }
            if mask.contains(.copy) { return .copy }
            return .generic
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard interactive,
                  let payload = ModelDragPayload.decode(pasteboard: info.draggingPasteboard) else { return false }
            // 末尾占位行：row == count（或系统仍给出 .on）都表示追加到末尾。
            if row >= displayedItems.count { return parent.commit(payload, slot: .end) }
            guard dropOperation == .above else { return false }
            // 行的锚点按“显示快照”换算，提交时再对当前配置解析；锚点消失即拒绝。
            let slot = RouteCandidateReorder.slot(row: row, ids: displayedItems.map(\.id))
            return parent.commit(payload, slot: slot)
        }
    }

    /// 提交一次候选重排：来源须为已知远端；落点锚点须仍存在于当前配置。收起态拒绝。
    @MainActor
    func commit(_ payload: [ModelDragItem], slot: RouteCandidateReorder.Slot) -> Bool {
        guard isInteractive else { return false }
        return store.reorderRouteCandidates(fakeID: fakeID, payload: payload, slot: slot)
    }
}

@MainActor
extension ConfigStore {
    /// 按当前配置提交候选重排。来源必须都是已知远端（未知 → 全部拒绝）；
    /// 落点锚点在当前列表里消失 → 拒绝；顺序未变化 → 记为已处理但不写盘。
    @discardableResult
    func reorderRouteCandidates(fakeID: UUID, payload: [ModelDragItem], slot: RouteCandidateReorder.Slot) -> Bool {
        guard let current = config.fakes.first(where: { $0.id == fakeID }) else { return false }
        let sources = RouteCandidateReorder.sources(payload, validRemoteIDs: Set(config.remotes.map(\.id)))
        guard !sources.isEmpty else { return false }
        let original = current.orderedRemoteIDs
        guard let index = RouteCandidateReorder.insertionIndex(for: slot, in: original) else { return false }
        let ids = RouteCandidateReorder.reorder(original: original, sources: sources, before: index)
        guard ids != original else { return true }
        return setRouteTargets(fakeID: current.id, remoteIDs: ids, autoFallback: current.autoFallback)
    }
}

// MARK: - 原生表格

/// 原生表格：在 NSDraggingDestination 的全部结束路径上通知协调器解冻。
/// 成功的落点只会走 `concludeDragOperation`（目的表格不收到 `draggingExited`/`draggingEnded`），
/// 被拒绝的落点只走 `performDragOperation` 返回 false。冻结/解冻不含任何指针坐标。
final class CandidateTableView: NSTableView {
    var onDraggingStateChange: ((Bool) -> Void)?
    /// 每次新按下都会回调，用于清除上一次拖动遗留的点击抑制。
    var onMouseDown: (() -> Void)?
    /// 右键时按命中行构造菜单（占位行返回 nil）。
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    /// 右键命中候选行：只弹删除菜单，不改动“当前”选中；占位行/空白不弹菜单。
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return contextMenuProvider?(row)
    }

    /// 进入目的表格：冻结显示快照。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingStateChange?(true)
        return super.draggingEntered(sender)
    }

    /// 取消 / 离开。
    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDraggingStateChange?(false)
        super.draggingExited(sender)
    }

    /// 落点被拒绝：不会走到 conclude。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let handled = super.performDragOperation(sender)
        if !handled { onDraggingStateChange?(false) }
        return handled
    }

    /// 落点成功：acceptDrop 已在 super 内、显示快照仍冻结时执行完毕。
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        super.concludeDragOperation(sender)
        onDraggingStateChange?(false)
    }

    /// 拖动会话结束（源或取消）。
    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDraggingStateChange?(false)
        super.draggingEnded(sender)
    }
}

/// 收起态键盘焦点屏蔽（路由候选表与供应商模型表共用）：只动自己这张表及其子控件，不跨卡片。
/// 不隐藏表格（隐藏会让收起动画的内容瞬间消失）；只拒绝焦点、禁用子控件并隐藏 AX，绘制保持。
final class NativeTableFocusShield {
    private var disabledControls: [NSControl] = []

    func apply(_ interactive: Bool, to table: NSTableView) {
        if interactive {
            for control in disabledControls {
                control.isEnabled = true
                control.refusesFirstResponder = false
            }
            disabledControls = []
        } else {
            // 只禁用本表子树里原本可用的子控件（行内按钮 / 文本域），表格自身不动以保持绘制。
            disabledControls = Self.controls(in: table).filter { $0 !== table && $0.isEnabled }
            for control in disabledControls {
                control.isEnabled = false
                control.refusesFirstResponder = true
            }
        }
        table.refusesFirstResponder = !interactive
        table.setAccessibilityHidden(!interactive)
        if !interactive, let window = table.window,
           let responder = window.firstResponder as? NSView, responder.isDescendant(of: table) {
            window.makeFirstResponder(nil)
        }
    }

    private static func controls(in root: NSView) -> [NSControl] {
        var result: [NSControl] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let control = view as? NSControl { result.append(control) }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }
}

/// 非滚动的 NSScrollView + NSTableView：外层 SwiftUI 滚动视图负责滚动，表格高度等于行数 × 行高。
final class CandidateTableContainer: NSScrollView {
    let tableView = CandidateTableView()

    init(rowHeight: CGFloat) {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        contentView.drawsBackground = false

        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("route-candidate"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        documentView = tableView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = contentSize.width
        tableView.frame = NSRect(x: 0, y: 0, width: width,
                                 height: CGFloat(tableView.numberOfRows) * tableView.rowHeight)
        tableView.sizeLastColumnToFit()
    }
}

/// 单行 cell：拖动手柄、模型名、“当前”指示和按需显示的删除按钮。
/// 删除按钮独立命中，其他内容的点击和拖动交给表格。
final class RouteCandidateCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("RouteCandidateCell")

    private let grip = PassthroughImageView()
    private let title = CandidateTitleField(labelWithString: "")
    private let currentIcon = PassthroughImageView()
    private let currentText = PassthroughTextField(labelWithString: "当前")
    private let currentStack = NSStackView()
    private let removeButton = RouteRemoveButton()
    private let contentStack = NSStackView()
    /// 悬停跟踪区：`.inVisibleRect` 让 AppKit 随尺寸/位置自动更新，无需重建。
    private var hoverTrackingArea: NSTrackingArea?

    var onRemove: (() -> Void)?
    var onSelect: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: RouteCandidateItem, isActive: Bool) {
        title.stringValue = item.label
        title.setAccessibilityTitle(item.label)
        removeButton.setAccessibilityLabel("从路由移除 \(item.label)")
        currentStack.isHidden = !isActive
        // 复用行可能带着上一行的悬停状态：按指针实际位置重算，避免按钮假显。
        isHovering = pointerIsInside()
        updateRemoveButtonVisibility()
    }

    // MARK: 悬停显示删除按钮

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // `.inVisibleRect` 会随视图移动/缩放自动维护矩形，只需创建一次，绝不重复重建。
        guard hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateRemoveButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateRemoveButtonVisibility()
    }

    private var isHovering = false

    /// 悬停时显现删除按钮；直切状态，不做动画。隐藏只清图标，按钮仍留在可访问性树中。
    private func updateRemoveButtonVisibility() {
        removeButton.setRevealed(isHovering)
    }

    /// 指针是否落在本行内（复用/刷新时校准悬停状态）。
    /// 与跟踪区 `.activeInKeyWindow` 语义一致：无非 key 窗口时视为未悬停。
    private func pointerIsInside() -> Bool {
        guard let window, window.isVisible, window.isKeyWindow else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    private func build() {
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动调整尝试顺序")
        grip.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        grip.contentTintColor = .tertiaryLabelColor
        grip.toolTip = "拖动调整尝试顺序"
        grip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grip.widthAnchor.constraint(equalToConstant: 16),
            grip.heightAnchor.constraint(equalToConstant: 22),
        ])

        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        title.textColor = .labelColor
        title.toolTip = "选择此模型用于后续请求；拖动调整尝试顺序"
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.onPress = { [weak self] in self?.onSelect?() }

        currentIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "当前")
        currentIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        currentIcon.contentTintColor = .controlAccentColor
        currentIcon.setContentHuggingPriority(.required, for: .horizontal)

        currentText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        currentText.textColor = .controlAccentColor
        currentText.setContentHuggingPriority(.required, for: .horizontal)

        currentStack.orientation = .horizontal
        currentStack.alignment = .centerY
        currentStack.spacing = 3
        currentStack.setViews([currentIcon, currentText], in: .leading)
        currentStack.setContentHuggingPriority(.required, for: .horizontal)

        removeButton.isBordered = false
        removeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        removeButton.imagePosition = .imageOnly
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = "从路由移除"
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        // 图标仅作显现/隐藏的开关：隐藏时清空图标，view 本身始终留在层次与可访问性树中。
        removeButton.revealImage = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "从路由移除")
        removeButton.setRevealed(false)
        removeButton.setAccessibilityLabel("从路由移除")
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            removeButton.widthAnchor.constraint(equalToConstant: 20),
            removeButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setViews([grip, title, currentStack, removeButton], in: .leading)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),
        ])
    }

    @objc private func removeTapped() { onRemove?() }
}

/// 图标隐藏时保留按钮的布局与辅助功能入口，并让出鼠标命中。
private final class RouteRemoveButton: NSButton {
    var revealImage: NSImage?
    private var hovered = false
    private var keyboardFocused = false
    private var isRevealed = true

    func setRevealed(_ revealed: Bool) {
        hovered = revealed
        updateAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        keyboardFocused = true
        updateAppearance()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        keyboardFocused = false
        updateAppearance()
        return true
    }

    private func updateAppearance() {
        let revealed = hovered || keyboardFocused
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        image = revealed ? revealImage : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isRevealed ? super.hitTest(point) : nil
    }

    override func isAccessibilityElement() -> Bool { true }
}

/// 命中测试直接让出，点击/拖动落到表格本身。
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 模型名：命中测试让给表格，但仍作为可访问性按钮暴露 AXPress（选择该模型），
/// 使坐标点击与辅助功能“按下”都能选中模型；拖动仍由表格的行拖动完成。
private final class CandidateTitleField: NSTextField {
    var onPress: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityActionNames() -> [NSAccessibility.Action] { [.press] }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func accessibilityLabel() -> String? { stringValue }
}

/// 末尾常驻占位行“拖入模型”：追加到末尾/空路由拖入的唯一原生落点，保留虚线落点语义。
/// 行高恒为 34pt；仅调整虚线/图标/文字的视觉权重（空路由强调、非空路由弱化），不影响落点与总高。
/// 它不可选中，也不作为拖拽来源（bounds guard 在 pasteboardWriterForRow / shouldSelectRow / handleClick）。
final class RouteCandidatePlaceholderCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("RouteCandidatePlaceholderCell")

    private let slot = DashedSlotView()
    private let content = NSStackView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "拖入模型")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 非空路由：常态弱化虚线/图标/文字，仅保留落点语义；空路由：强调为明确的拖入邀请。
    /// 行高始终为 34pt，因此 `(行数 × rowHeight)` 的总高与落点映射不变。
    func configure(isEmpty: Bool) {
        slot.emphasis = isEmpty ? 1 : 0.45
        let tint: NSColor = isEmpty ? .secondaryLabelColor : .tertiaryLabelColor
        icon.contentTintColor = tint
        label.textColor = tint
        label.stringValue = isEmpty ? "拖入第一个模型" : "拖入模型"
        setAccessibilityLabel(isEmpty ? "拖入第一个模型" : "拖入模型")
    }

    private func build() {
        icon.image = NSImage(systemSymbolName: "plus.circle.dashed", accessibilityDescription: "拖入模型")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setViews([icon, label], in: .leading)

        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(content)
        addSubview(slot)
        NSLayoutConstraint.activate([
            slot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            slot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            slot.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            slot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            content.leadingAnchor.constraint(equalTo: slot.leadingAnchor, constant: 10),
            content.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: slot.trailingAnchor, constant: -10),
        ])
    }
}

/// 只画一个虚线圆角边框，作为占位行背景。
/// `emphasis` 控制线条强度：空路由（1）清晰可辨，非空路由（<1）常态弱化为低调落点提示。
final class DashedSlotView: NSView {
    var emphasis: CGFloat = 1 {
        didSet { if emphasis != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        path.lineWidth = 1
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.labelColor.withAlphaComponent(0.12 * max(0, min(1, emphasis))).setStroke()
        path.stroke()
    }
}
