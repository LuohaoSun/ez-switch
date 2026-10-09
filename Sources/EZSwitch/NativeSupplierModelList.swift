import AppKit
import SwiftUI

/// 供应商面板里的一个模型行：稳定 ID（远端 UUID）+ 展示名 + 凭据提示。
struct SupplierModelItem: Identifiable, Equatable {
    let id: UUID
    let label: String
    let needsCredentials: Bool
}

/// 供应商内部排序规则：只接受属于同一供应商的已知模型；去重；任一项不符即整体拒绝。
/// 与路由候选不同，供应商排序不允许把模型搬进别的供应商，也不改动供应商记录本身。
enum SupplierModelReorder {
    static func sources(_ items: [ModelDragItem], provider: String,
                        remotesByID: [UUID: RemoteModel]) -> [UUID] {
        guard !items.isEmpty else { return [] }
        let ids = items.map(\.id)
        guard ids.allSatisfy({ id in
            guard let remote = remotesByID[id] else { return false }
            return splitProviderModel(remote.name).provider == provider
        }) else { return [] }
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// 原生表格提出的插入行下标 → `moveModels` 的目标锚点：插入到该行之前；`row == ids.count`（或越界）追加末尾。
    /// 锚点落在来源自身时 `moveModels` 判为无效（等同“拖到自己身上”，顺序不变）。
    static func anchor(row: Int, ids: [UUID]) -> UUID? {
        guard row >= 0, row < ids.count else { return nil }
        return ids[row]
    }
}

@MainActor
extension ConfigStore {
    /// 按当前配置提交一次供应商内部排序：来源须都属于该供应商；跨供应商 / 未知来源整体拒绝。
    /// 非 nil 的落点锚点必须仍存在且属于同一供应商，否则拒绝（避免锚点消失时静默 no-op 却报成功）。
    /// 顺序未变化（含拖到自己身上）时也返回 true，表示这次落点被接受。
    @discardableResult
    func reorderSupplierModels(provider: String, payload: [ModelDragItem], before anchor: UUID?) -> Bool {
        let remotesByID = Dictionary(uniqueKeysWithValues: config.remotes.map { ($0.id, $0) })
        let sources = SupplierModelReorder.sources(payload, provider: provider, remotesByID: remotesByID)
        guard !sources.isEmpty else { return false }
        if let anchor {
            guard let remote = remotesByID[anchor],
                  splitProviderModel(remote.name).provider == provider else { return false }
        }
        moveModels(provider: provider, sources: sources, before: anchor)
        return true
    }
}

/// 单个供应商的原生模型行列表。行既是拖动源（写入与路由候选表相同的 `public.plain-text` JSON 载荷），
/// 又是同供应商内部排序的落点；拖动会话、拖动源与插入行几何都由 `NSTableView` 持有。
/// 外层 SwiftUI 滚动视图负责滚动，表格高度等于行数 × 行高。
struct NativeSupplierModelList: NSViewRepresentable {
    let items: [SupplierModelItem]
    let provider: String
    /// 筛选供应商/模型时禁用内部排序；拖动源不受影响，模型仍可拖出到路由。
    let sortEnabled: Bool
    let store: ConfigStore
    let onEdit: (UUID) -> Void
    var rowHeight: CGFloat = 30

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SupplierModelTableContainer {
        let container = SupplierModelTableContainer(rowHeight: rowHeight)
        wire(container.tableView, coordinator: context.coordinator)
        context.coordinator.apply(items: items)
        container.tableView.reloadData()
        return container
    }

    /// 表格接线（数据源/委托/拖放类型/生命周期与右键菜单回调）；makeNSView 与测试共用。
    @MainActor
    func wire(_ tableView: SupplierModelTableView, coordinator: Coordinator) {
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.registerForDraggedTypes([ModelDragPayload.nativePasteboardType])
        // 本进程内拖动是移动；跨进程不提供任何操作，明确拒绝外部应用落点。
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setDraggingSourceOperationMask([], forLocal: false)
        tableView.onDragStateChange = { [weak coordinator] active in
            coordinator?.dragStateChanged(active)
        }
        tableView.contextMenuProvider = { [weak coordinator] row in
            coordinator?.contextMenu(row: row)
        }
        coordinator.attach(tableView)
    }

    func updateNSView(_ container: SupplierModelTableContainer, context: Context) {
        context.coordinator.parent = self
        if container.tableView.rowHeight != rowHeight {
            container.tableView.rowHeight = rowHeight
        }
        context.coordinator.apply(items: items)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SupplierModelTableContainer,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: CGFloat(items.count) * rowHeight)
    }

    /// 行模型由显示快照驱动：拖动期间不替换快照，落点行号始终对应用户看到的行。
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeSupplierModelList
        private weak var tableView: NSTableView?

        private var displayedItems: [SupplierModelItem] = []
        /// 拖动期间到达的最新数据；拖动结束后再应用。
        private var latestItems: [SupplierModelItem] = []
        private var suppressReload = false
        private var pendingReload = false

        init(_ parent: NativeSupplierModelList) { self.parent = parent }

        func attach(_ tableView: NSTableView) { self.tableView = tableView }

        /// 表格当前显示的模型顺序；拖动落点即按这个快照换算锚点。
        var displayedIDs: [UUID] { displayedItems.map(\.id) }

        // MARK: 数据源

        func numberOfRows(in tableView: NSTableView) -> Int { displayedItems.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < displayedItems.count else { return nil }
            let item = displayedItems[row]
            let cell = (tableView.makeView(withIdentifier: SupplierModelCell.reuseIdentifier, owner: nil)
                        as? SupplierModelCell) ?? SupplierModelCell()
            cell.configure(item: item)
            return cell
        }

        // 行选中保留默认行为（无高亮，也无点击动作）：整行可拖由表格的行拖动负责，
        // 不做 `shouldSelectRow` 限制，避免影响行拖动路径。

        // MARK: 视图更新（不打断拖动）

        func apply(items: [SupplierModelItem]) {
            latestItems = items
            let identitiesChanged = items.map(\.id) != displayedItems.map(\.id)
            guard identitiesChanged else {
                displayedItems = items
                refreshVisibleCells()
                return
            }
            guard !suppressReload else {
                pendingReload = true
                return
            }
            displayedItems = items
            tableView?.reloadData()
        }

        private func refreshVisibleCells() {
            guard let tableView else { return }
            for row in 0..<min(displayedItems.count, tableView.numberOfRows) {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? SupplierModelCell else { continue }
                cell.configure(item: displayedItems[row])
            }
        }

        // MARK: 拖动源（原生行拖动，写出与路由候选表相同的载荷）

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0, row < displayedItems.count else { return nil }
            return ModelDragPayload.pasteboardItem(ModelDragItem(id: displayedItems[row].id))
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            onDragStateChange(true)
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onDragStateChange(false)
        }

        /// 本表格发起拖动：冻结显示快照，避免拖动期间被异步刷新打断。
        /// 拖出到路由时本表只是源，仍在该结束路径解冻。
        func onDragStateChange(_ active: Bool) { dragStateChanged(active) }

        /// 冻结 = 不替换显示快照、不 reload；解冻时应用拖动期间积压的数据。
        /// 成功（conclude）/失败（perform 返回 false）/取消（exited/ended）各路径都会调用。
        func dragStateChanged(_ active: Bool) {
            if active {
                suppressReload = true
                return
            }
            suppressReload = false
            guard pendingReload, let tableView else { return }
            pendingReload = false
            displayedItems = latestItems
            tableView.reloadData()
        }

        // MARK: 落点（同供应商排序；筛选时禁用）

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // 显式本进程校验：跨进程拖动拿不到 draggingSource。
            guard info.draggingSource != nil,
                  parent.sortEnabled,
                  let payload = ModelDragPayload.decode(pasteboard: info.draggingPasteboard),
                  !SupplierModelReorder.sources(payload, provider: parent.provider,
                                                remotesByID: remoteLookup()).isEmpty
            else { return [] }
            let target = max(0, min(row, displayedItems.count))
            tableView.setDropRow(target, dropOperation: .above)
            let mask = info.draggingSourceOperationMask
            if mask.contains(.move) { return .move }
            if mask.contains(.copy) { return .copy }
            return .generic
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            // 只接受 .above 插入线，且行下标必须在 [0, count]：row == count 表示追加末尾；
            // .on 或越界一律拒绝，避免被当成末尾插入而误报成功。
            guard info.draggingSource != nil,
                  dropOperation == .above,
                  row >= 0, row <= displayedItems.count,
                  let payload = ModelDragPayload.decode(pasteboard: info.draggingPasteboard) else { return false }
            return commitDrop(row: row, payload: payload)
        }

        /// 已解码载荷的落点提交（测试直接调用）。筛选时禁用内部排序；
        /// 拖出到路由走的是拖动源路径，不受影响。
        @discardableResult
        func commitDrop(row: Int, payload: [ModelDragItem]) -> Bool {
            guard parent.sortEnabled,
                  row >= 0, row <= displayedItems.count else { return false }
            let anchor = SupplierModelReorder.anchor(row: row, ids: displayedItems.map(\.id))
            return parent.store.reorderSupplierModels(provider: parent.provider, payload: payload, before: anchor)
        }

        private func remoteLookup() -> [UUID: RemoteModel] {
            Dictionary(uniqueKeysWithValues: parent.store.config.remotes.map { ($0.id, $0) })
        }

        // MARK: 右键菜单（编辑模型）

        func contextMenu(row: Int) -> NSMenu? {
            guard row >= 0, row < displayedItems.count else { return nil }
            let item = NSMenuItem(title: "编辑模型…", action: #selector(editMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = displayedItems[row].id
            let menu = NSMenu()
            menu.addItem(item)
            return menu
        }

        @objc private func editMenuItemClicked(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onEdit(id)
        }
    }
}

// MARK: - 原生表格

/// 原生表格：在 NSDraggingDestination 的全部结束路径上通知协调器解冻。
/// 成功的落点只走 `concludeDragOperation`；被拒绝的落点只走 `performDragOperation` 返回 false。
final class SupplierModelTableView: NSTableView {
    var onDragStateChange: ((Bool) -> Void)?
    /// 右键时按命中行构造菜单。
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragStateChange?(true)
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragStateChange?(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let handled = super.performDragOperation(sender)
        if !handled { onDragStateChange?(false) }
        return handled
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        super.concludeDragOperation(sender)
        onDragStateChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragStateChange?(false)
        super.draggingEnded(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return contextMenuProvider?(row)
    }
}

/// 非滚动的 NSScrollView + NSTableView：外层 SwiftUI 滚动视图负责滚动，表格高度等于行数 × 行高。
final class SupplierModelTableContainer: NSScrollView {
    let tableView = SupplierModelTableView()

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
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("supplier-model"))
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

/// 单行 cell：模型名（等宽）+ 凭据待配置提示。文本与图标让出命中测试，
/// 让表格统一处理行拖动；右键菜单由表格的 `menu(for:)` 提供。
final class SupplierModelCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SupplierModelCell")

    private let title = SupplierPassthroughTextField(labelWithString: "")
    private let warning = SupplierPassthroughImageView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: SupplierModelItem) {
        title.stringValue = item.label
        title.setAccessibilityTitle(item.label)
        title.setAccessibilityHelp("拖到右侧路由添加模型；在左侧拖到其他模型上方调整顺序")
        title.setAccessibilityIdentifier("supplier-model-\(item.id.uuidString)")
        warning.isHidden = !item.needsCredentials
    }

    private func build() {
        title.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        title.lineBreakMode = .byTruncatingMiddle
        title.textColor = .labelColor
        title.toolTip = "拖到右侧路由添加模型；在左侧拖到其他模型上方调整顺序"
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        warning.image = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                accessibilityDescription: "凭据待配置")
        warning.contentTintColor = .systemOrange
        warning.toolTip = "凭据待配置"
        warning.setContentHuggingPriority(.required, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([title, warning], in: .leading)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),
        ])
    }
}

/// 命中测试直接让出，点击/拖动落到表格本身。
private final class SupplierPassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class SupplierPassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
