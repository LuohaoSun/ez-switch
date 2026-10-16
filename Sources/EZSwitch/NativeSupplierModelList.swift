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
/// 外层 SwiftUI 滚动视图负责滚动；表格高度取原生 `.inset` 的真实内容高度（含样式顶部内缩），
/// 容器可视高度只取行区净高，并把顶部内缩滚出可视区，使首行贴近分隔线、末行连同圆角完整可见。
struct NativeSupplierModelList: NSViewRepresentable {
    let items: [SupplierModelItem]
    let provider: String
    /// 筛选供应商/模型时禁用内部排序；拖动源不受影响，模型仍可拖出到路由。
    let sortEnabled: Bool
    let store: ConfigStore
    /// 内联重命名的提交闭包：返回 nil 表示写入成功，返回文案表示校验失败。
    /// 协调器在 Return / 回车提交时调用；失败时保持编辑并就地展示该校验文案（无模态重命名面板）。
    let onRename: (UUID, String) -> String?
    /// 删除模型（右键菜单“删除”）；按稳定 UUID 精确清理。
    var onDelete: (UUID) -> Void = { _ in }
    /// 工作区共享的单选模型：跨卡片唯一选中的真源；本表据此显示/清除选中。
    var selectedModelID: UUID? = nil
    /// 用户在本表改变选中时回写工作区共享选中；程序化/同步选中不触发（避免回环）。
    var onSelectionChange: (UUID?) -> Void = { _ in }
    /// 外部可插值高度容器（`CollapsibleBody`）的展开高度来源：真实行区净高变化时回调。
    /// 表格始终挂载（identity 稳定），因此收起状态下也持续上报，展开动画才有准确目标高度。
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    /// 收起时内容不可交互：不参与键盘焦点循环，也不暴露辅助功能元素
    /// （SwiftUI 的裁剪与 `allowsHitTesting` 只作用于 SwiftUI 层，挡不住 Tab 焦点）。
    var isInteractive: Bool = true
    /// 紧凑行高（约 系统字号 + 11）：圆角内缩选中更贴合单行文本。
    var rowHeight: CGFloat = 24

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SupplierModelTableContainer {
        let container = SupplierModelTableContainer(rowHeight: rowHeight)
        wire(container.tableView, coordinator: context.coordinator)
        context.coordinator.apply(items: items)
        container.tableView.reloadData()
        context.coordinator.applySelectedModelID(selectedModelID)
        context.coordinator.setInteractive(isInteractive)
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
        // Return / Enter：对选中行开始原生就地重命名；无有效选中交回默认按键处理。
        tableView.onReturnKey = { [weak coordinator] in
            coordinator?.activateSelectedRow() ?? false
        }
        // 编辑中的行不允许同一行的按下顺带发起拖动（该按下用于结束编辑）。
        tableView.editingRowProvider = { [weak coordinator] in coordinator?.editingRow }
        coordinator.attach(tableView)
    }

    func updateNSView(_ container: SupplierModelTableContainer, context: Context) {
        context.coordinator.parent = self
        if container.tableView.rowHeight != rowHeight {
            container.tableView.rowHeight = rowHeight
        }
        context.coordinator.apply(items: items)
        context.coordinator.applySelectedModelID(selectedModelID)
        context.coordinator.setInteractive(isInteractive)
    }

    /// 高度只取行区净高：原生 `.inset` 的固定顶部内缩由容器滚出可视区，不占外层布局高度。
    /// 同时把真实净高上报给外层可插值高度容器（收起时表格仍挂载，因此仍能上报）。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView container: SupplierModelTableContainer,
                      context: Context) -> CGSize? {
        let height = container.tightContentHeight
        context.coordinator.reportContentHeight(height)
        return CGSize(width: proposal.width ?? 240, height: height)
    }

    /// 行模型由显示快照驱动：拖动期间不替换快照，落点行号始终对应用户看到的行。
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: NativeSupplierModelList
        private weak var tableView: NSTableView?

        private var displayedItems: [SupplierModelItem] = []
        /// 拖动期间到达的最新数据；拖动结束后再应用。
        private var latestItems: [SupplierModelItem] = []
        private var suppressReload = false
        private var pendingReload = false
        /// 拖动会话进行中；此时不允许开始就地编辑。
        private var draggingActive = false

        /// 当前选中行的稳定 ID：reload / 重排后按 UUID 恢复，行被移除则清空。
        private(set) var selectedID: UUID?
        /// 程序化恢复选中期间抑制选中变化回写（reload 会先清空选中）。
        private var suppressSelectionSync = false

        /// 就地重命名会话：稳定 ID / 行号 / 原名 / 校验文案；`editingID != nil` 即“正在编辑”。
        private(set) var editingID: UUID?
        private(set) var editingRow: Int?
        private(set) var editingError: String?
        private var originalText = ""
        /// 结束编辑期间抑制 `controlTextDidEndEditing` 的二次取消/回写。
        private var isFinalizing = false

        /// 上一次上报给外层的高度，避免每次布局都回写 SwiftUI 状态。
        private var lastReportedHeight: CGFloat?
        /// 当前是否可交互（收起时否）。
        private var interactive = true
        private let focusShield = NativeTableFocusShield()

        init(_ parent: NativeSupplierModelList) { self.parent = parent }

        func attach(_ tableView: NSTableView) { self.tableView = tableView }

        /// 上报真实行区净高：只在变化时异步回写，避免在布局/更新期间改 SwiftUI 状态。
        func reportContentHeight(_ height: CGFloat) {
            guard lastReportedHeight != height else { return }
            lastReportedHeight = height
            let handler = parent.onContentHeightChange
            DispatchQueue.main.async { handler(height) }
        }

        /// 收起时只拒绝焦点并禁用表内子控件；不隐藏表格，收起动画的绘制过渡不受影响。
        func setInteractive(_ value: Bool) {
            guard interactive != value else { return }
            interactive = value
            if let tableView { focusShield.apply(value, to: tableView) }
        }

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
            // 就地编辑的提交/取消由协调器接管字段编辑器回调。
            cell.textField?.delegate = self
            return cell
        }

        // MARK: 选中（单行、可见；工作区共享真源 + 按稳定 ID 跨 reload / 重排保留）

        /// 记录选中行的稳定 ID 并回写工作区共享选中；reload / 同步恢复期间抑制回写。
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionSync else { return }
            let row = tableView?.selectedRow ?? -1
            let id = (row >= 0 && row < displayedItems.count) ? displayedItems[row].id : nil
            selectedID = id
            parent.onSelectionChange(id)
        }

        /// 仅显示行可选中（收起态不可交互）。
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            interactive && row >= 0 && row < displayedItems.count
        }

        /// 选中某行并记录其稳定 ID；行号越界返回 false。
        @discardableResult
        func selectRow(_ row: Int) -> Bool {
            guard let tableView, row >= 0, row < displayedItems.count else { return false }
            let id = displayedItems[row].id
            suppressSelectionSync = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suppressSelectionSync = false
            selectedID = id
            parent.onSelectionChange(id)
            return true
        }

        /// 由 `updateNSView` 推送工作区共享选中：只有变化时才动作，且不触发回写回调。
        /// 共享选中不在本表（属于别的卡片）时清空本表选中，保证任一时刻最多一行被选中。
        func applySelectedModelID(_ id: UUID?) {
            guard let tableView else { selectedID = id; return }
            let targetRow = id.flatMap { target in
                displayedItems.firstIndex(where: { $0.id == target })
            }
            if let targetRow {
                guard selectedID != id || tableView.selectedRow != targetRow else { return }
            } else if selectedID == nil && tableView.selectedRow < 0 {
                return
            }
            suppressSelectionSync = true
            if let targetRow {
                tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
                selectedID = id
            } else {
                tableView.deselectAll(nil)
                selectedID = nil
            }
            suppressSelectionSync = false
        }

        /// reload 会清空选中：按稳定 ID 重新选中同一行；ID 已消失（行被移除）则清空选中。
        private func reloadPreservingSelection() {
            guard let tableView else { return }
            let keep = selectedID
            suppressSelectionSync = true
            tableView.reloadData()
            if let keep, let row = displayedItems.firstIndex(where: { $0.id == keep }) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                selectedID = keep
            } else {
                selectedID = nil
                tableView.deselectAll(nil)
            }
            suppressSelectionSync = false
        }

        // MARK: 就地重命名（原生字段编辑器，无模态面板）

        /// Return / Enter：对当前选中行开始就地重命名；无有效选中行返回 false。
        @discardableResult
        func activateSelectedRow() -> Bool {
            guard let tableView else { return false }
            return beginEditing(row: tableView.selectedRow)
        }

        /// 按稳定 ID 开始就地重命名（右键菜单“重命名”）。
        @discardableResult
        func beginEditing(id: UUID) -> Bool {
            guard let row = displayedItems.firstIndex(where: { $0.id == id }) else { return false }
            return beginEditing(row: row)
        }

        /// 对指定行开始原生就地 `NSTextField` 编辑并预选全部名称；拖动中、收起态或行号越界拒绝。
        @discardableResult
        func beginEditing(row: Int) -> Bool {
            guard let tableView, interactive, !draggingActive,
                  row >= 0, row < displayedItems.count else { return false }
            // 结束可能残留的上一个会话（恢复原值，不写入）。
            if editingID != nil { endEditingSession(restore: true) }
            let item = displayedItems[row]
            editingRow = row
            originalText = item.label
            editingError = nil
            selectRow(row)
            cell(at: row)?.beginEditing()
            tableView.editColumn(0, row: row, with: nil, select: true)
            // 会话在字段编辑器启动之后才生效：`editColumn` 期间若同步派发
            // `controlTextDidEndEditing`（例如宿主窗口尚未成为 key window 时），此时 editingID 仍为 nil，
            // 结束回调会被直接忽略，不会误清刚建立的编辑会话。
            editingID = item.id
            return true
        }

        /// 就地提交：返回 nil 表示成功写入或原文未变；返回文案表示校验失败。
        @discardableResult
        func commitEditing(withText text: String) -> String? {
            guard let id = editingID else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != originalText else { return nil }
            return parent.onRename(id, trimmed)
        }

        /// Return / Enter 提交：成功（或原文未变）结束编辑返回 true；校验失败保持编辑返回 false。
        @discardableResult
        func handleReturn(withText text: String) -> Bool {
            guard editingID != nil else { return false }
            if let error = commitEditing(withText: text) {
                showEditingError(error)
                return false
            }
            endEditingSession(restore: false)
            return true
        }

        /// Escape / 失焦：取消编辑，不写入任何内容。
        func cancelEditing() {
            guard editingID != nil else { return }
            endEditingSession(restore: true)
        }

        /// 校验失败：就地展示文案（仅此时占用额外宽度）并保持编辑。
        private func showEditingError(_ message: String) {
            editingError = message
            guard let row = editingRow else { return }
            cell(at: row)?.setValidation(message)
            setFieldEditorValidationStyle(failed: true, row: row)
        }

        /// 校验文案出现/消失后，把字段编辑器收缩或恢复到文本域上：文案不被遮住，平时也不挤占行宽。
        private func setFieldEditorValidationStyle(failed: Bool, row: Int) {
            guard let editor = tableView?.currentEditor() as? NSTextView else { return }
            editor.textColor = failed ? .systemRed : .labelColor
            guard let cell = cell(at: row), let field = cell.textField,
                  let host = editor.superview else { return }
            cell.layoutSubtreeIfNeeded()
            var frame = host.convert(field.bounds, from: field)
            frame.origin.y = editor.frame.origin.y
            frame.size.height = editor.frame.height
            editor.frame = frame
        }

        /// 结束会话：`restore` 时把原名写回（取消语义）；无论成功/取消都不触碰 store。
        private func endEditingSession(restore: Bool) {
            guard let tableView else { clearEditingSession(); return }
            let row = editingRow
            let text = originalText
            isFinalizing = true
            if let row, let cell = cell(at: row) {
                if restore { cell.textField?.stringValue = text }
                cell.endEditing()
            }
            clearEditingSession()
            if let editor = tableView.currentEditor() {
                if restore { editor.string = text }
                _ = tableView.window?.makeFirstResponder(tableView)
            }
            isFinalizing = false
            applyPendingReloadIfNeeded()
        }

        private func clearEditingSession() {
            editingID = nil
            editingRow = nil
            editingError = nil
            originalText = ""
        }

        private func cell(at row: Int) -> SupplierModelCell? {
            tableView?.view(atColumn: 0, row: row, makeIfNecessary: false) as? SupplierModelCell
        }

        // MARK: NSTextFieldDelegate（字段编辑器）

        /// Return 提交（失败保持编辑），Escape 取消；其余按键交回字段编辑器。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard editingID != nil else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                _ = handleReturn(withText: textView.string)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancelEditing()
                return true
            default:
                return false
            }
        }

        /// 继续输入即清除上一次的校验提示，恢复完整行宽。
        func controlTextDidChange(_ notification: Notification) {
            guard editingID != nil, editingError != nil, let row = editingRow else { return }
            editingError = nil
            cell(at: row)?.clearValidation()
            setFieldEditorValidationStyle(failed: false, row: row)
        }

        /// 失焦 / 切换行结束编辑：视为取消，不写入。
        func controlTextDidEndEditing(_ notification: Notification) {
            guard editingID != nil, !isFinalizing else { return }
            if let field = notification.object as? NSTextField { field.stringValue = originalText }
            if let row = editingRow { cell(at: row)?.endEditing() }
            clearEditingSession()
            applyPendingReloadIfNeeded()
        }

        // MARK: 视图更新（不打断拖动）

        func apply(items: [SupplierModelItem]) {
            latestItems = items
            let identitiesChanged = items.map(\.id) != displayedItems.map(\.id)
            guard identitiesChanged else {
                displayedItems = items
                refreshVisibleCells()
                return
            }
            // 拖动或就地编辑期间冻结显示快照，避免推翻用户正在看的行/正在编辑的文本。
            guard !suppressReload, editingID == nil else {
                pendingReload = true
                return
            }
            displayedItems = items
            reloadPreservingSelection()
        }

        private func refreshVisibleCells() {
            guard let tableView else { return }
            for row in 0..<min(displayedItems.count, tableView.numberOfRows) {
                // 不打断正在编辑的行：字段编辑器持有其文本。
                if row == editingRow { continue }
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? SupplierModelCell else { continue }
                cell.configure(item: displayedItems[row])
            }
        }

        // MARK: 拖动源（原生行拖动，写出与路由候选表相同的载荷）

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard interactive, row >= 0, row < displayedItems.count else { return nil }
            // 编辑期间、或“结束编辑的同一次按下”都不发起拖动，避免拖动与就地编辑互相打断。
            if editingID != nil { return nil }
            if let table = tableView as? SupplierModelTableView,
               table.suppressDragForCurrentInteraction { return nil }
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

        /// 冻结 = 不替换显示快照、不 reload；解冻时应用期间积压的数据。
        /// 成功（conclude）/失败（perform 返回 false）/取消（exited/ended）各路径都会调用。
        func dragStateChanged(_ active: Bool) {
            draggingActive = active
            if active {
                suppressReload = true
                return
            }
            suppressReload = false
            applyPendingReloadIfNeeded()
        }

        /// 会话（拖动/编辑）真正结束后，才把积压的最新行数据落回表格。
        private func applyPendingReloadIfNeeded() {
            guard pendingReload, !suppressReload, editingID == nil else { return }
            pendingReload = false
            displayedItems = latestItems
            reloadPreservingSelection()
        }

        // MARK: 落点（同供应商排序；筛选时禁用）

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // 显式本进程校验：跨进程拖动拿不到 draggingSource。
            guard info.draggingSource != nil,
                  interactive,
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
                  interactive,
                  dropOperation == .above,
                  row >= 0, row <= displayedItems.count,
                  let payload = ModelDragPayload.decode(pasteboard: info.draggingPasteboard) else { return false }
            return commitDrop(row: row, payload: payload)
        }

        /// 已解码载荷的落点提交（测试直接调用）。收起态或筛选时禁用内部排序；
        /// 拖出到路由走的是拖动源路径，不受影响。
        @discardableResult
        func commitDrop(row: Int, payload: [ModelDragItem]) -> Bool {
            guard interactive, parent.sortEnabled,
                  row >= 0, row <= displayedItems.count else { return false }
            let anchor = SupplierModelReorder.anchor(row: row, ids: displayedItems.map(\.id))
            return parent.store.reorderSupplierModels(provider: parent.provider, payload: payload, before: anchor)
        }

        private func remoteLookup() -> [UUID: RemoteModel] {
            Dictionary(uniqueKeysWithValues: parent.store.config.remotes.map { ($0.id, $0) })
        }

        // MARK: 右键菜单（重命名 / 删除）

        func contextMenu(row: Int) -> NSMenu? {
            guard interactive, row >= 0, row < displayedItems.count else { return nil }
            let id = displayedItems[row].id
            let rename = NSMenuItem(title: "重命名", action: #selector(renameMenuItemClicked(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = id
            let delete = NSMenuItem(title: "删除", action: #selector(deleteMenuItemClicked(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = id
            let menu = NSMenu()
            menu.addItem(rename)
            menu.addItem(delete)
            return menu
        }

        @objc func renameMenuItemClicked(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            beginEditing(id: id)
        }

        @objc func deleteMenuItemClicked(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onDelete(id)
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
    /// Return / Enter：返回是否已处理。
    var onReturnKey: (() -> Bool)?
    /// 当前正在就地编辑的行号；同一行的按下用于结束编辑，不能顺带发起拖动。
    var editingRowProvider: (() -> Int?)?
    /// 本次鼠标交互是“落在正在编辑行上的按下”：在抬起前一律抑制拖动发起。
    private(set) var suppressDragForCurrentInteraction = false

    override func mouseDown(with event: NSEvent) {
        if let editingRow = editingRowProvider?(), editingRow >= 0,
           row(at: convert(event.locationInWindow, from: nil)) == editingRow {
            suppressDragForCurrentInteraction = true
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        suppressDragForCurrentInteraction = false
    }

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

    /// Return(36) / Enter(76)：对选中行开始就地重命名，否则交回默认处理。
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), onReturnKey?() == true { return }
        super.keyDown(with: event)
    }

    /// 右键命中行：先选中该行，再按该行构造菜单；未命中行不弹菜单。
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        selectRowForContextMenu(row)
        return contextMenuProvider?(row)
    }

    /// 右键命中行的选择：菜单作用在确切命中行。
    /// 直接走原生选中（非抑制路径），由协调器回写工作区共享选中。
    func selectRowForContextMenu(_ row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

/// 非滚动表格的 clip view：把垂直偏移钉在顶部内缩上；原生选中/重绘在 layout 之外改动 bounds 时同样夹紧。
final class PinnedTopInsetClipView: NSClipView {
    /// 期望的固定垂直偏移（= 顶部内缩）；由容器在 layout 写入。
    var pinnedOffsetY: CGFloat = 0

    override var bounds: NSRect {
        get { super.bounds }
        set { super.bounds = NSRect(x: 0, y: clampedPinnedY(forHeight: newValue.height),
                                    width: newValue.width, height: newValue.height) }
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: clampedPinnedY(forHeight: bounds.height)))
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: clampedPinnedY(forHeight: bounds.height)))
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin = NSPoint(x: 0, y: clampedPinnedY(forHeight: rect.height))
        return rect
    }

    private func clampedPinnedY(forHeight height: CGFloat) -> CGFloat {
        let maxY = max(0, (documentView?.frame.height ?? 0) - height)
        return min(max(0, pinnedOffsetY), maxY)
    }
}

/// 非滚动的 NSScrollView + NSTableView：外层 SwiftUI 滚动视图负责滚动。
/// `.inset` 在首行上方加固定内缩（无公开 API 可改），故文档高度取全高、可视高度只取行区净高，
/// 并把内缩滚出可视区：首行贴近分隔线，末行连同圆角完整可见。
final class SupplierModelTableContainer: NSScrollView {
    let tableView = SupplierModelTableView()
    private let pinnedClip = PinnedTopInsetClipView()

    /// `.inset` 样式在首行上方加入的固定内缩（由 `rect(ofRow:)` 实测得出，而非硬编码）。
    var topInset: CGFloat {
        tableView.numberOfRows > 0 ? tableView.rect(ofRow: 0).minY : 0
    }

    /// 行区净高（不含样式顶部内缩）：由首/末行实测矩形之差得出，外层 SwiftUI 布局高度，保证末行不被裁。
    var tightContentHeight: CGFloat {
        let rows = tableView.numberOfRows
        guard rows > 0 else { return 0 }
        return tableView.rect(ofRow: rows - 1).maxY - tableView.rect(ofRow: 0).minY
    }

    init(rowHeight: CGFloat) {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        // 用钉住偏移的 clip view：选中/重绘在 layout 之外改动 bounds 时也会被重新夹紧。
        pinnedClip.drawsBackground = false
        contentView = pinnedClip

        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = rowHeight
        // 先定样式：`.inset` 由 AppKit 绘制原生圆角内缩选中（macOS 11+），不手绘蓝色矩形。
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        // 归零行间距让行紧贴；`.inset` 样式仍在首行上方保留固定内缩，由容器统一处理。
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("supplier-model"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        documentView = tableView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 内层位置固定，滚轮交给外层处理，避免顶部内缩产生的可滚范围吞掉事件。
    override func scrollWheel(with event: NSEvent) {
        if let outer = enclosingOuterScrollView() {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func enclosingOuterScrollView() -> NSScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? NSScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }

    override func layout() {
        super.layout()
        let width = contentSize.width
        let inset = topInset
        let tight = tightContentHeight
        // 先写回钉住值，再设文档高度，避免文档变化触发的 reflect 用到过期偏移。
        pinnedClip.pinnedOffsetY = inset
        tableView.frame = NSRect(x: 0, y: 0, width: width, height: inset + tight)
        tableView.sizeLastColumnToFit()
        // 夹在文档可滚范围内（容器偏高时不产生额外空白）；写入会经 bounds 覆写被钉住。
        pinnedClip.bounds.origin = NSPoint(x: 0, y: max(0, min(inset, tableView.frame.height - contentSize.height)))
    }
}

/// 单行 cell：模型名（等宽，编辑时就地变成 `NSTextField` 字段编辑器）+ 凭据待配置提示 +
/// 校验文案槽位。文本与图标让出命中测试，让表格统一处理行拖动；右键菜单由表格的 `menu(for:)` 提供。
final class SupplierModelCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SupplierModelCell")

    private let title = SupplierPassthroughTextField(labelWithString: "")
    private let warning = SupplierPassthroughImageView()
    /// 校验文案槽位：仅在校验失败期间显示，平时完全让出宽度给模型名。
    private let validation = SupplierPassthroughTextField(labelWithString: "")
    private let stack = NSStackView()
    private var needsCredentials = false
    private var isEditingRow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: SupplierModelItem) {
        needsCredentials = item.needsCredentials
        title.stringValue = item.label
        title.setAccessibilityTitle(item.label)
        title.setAccessibilityHelp("拖到右侧路由添加模型；在左侧拖到其他模型上方调整顺序")
        title.setAccessibilityIdentifier("supplier-model-\(item.id.uuidString)")
        // 复用中的 cell 可能是上一次编辑的残留外观；正在编辑的行不重置。
        if !isEditingRow {
            title.isEditable = false
            title.textColor = .labelColor
            validation.isHidden = true
            warning.isHidden = !item.needsCredentials
        }
    }

    /// 进入就地编辑：文本域可编辑（预选由 `editColumn(_:row:with:select:)` 完成），不预留校验宽度。
    func beginEditing() {
        isEditingRow = true
        title.isEditable = true
        title.isSelectable = true
        title.textColor = .labelColor
        warning.isHidden = true
        validation.stringValue = ""
        validation.setAccessibilityHelp(nil)
        validation.isHidden = true
    }

    /// 校验失败：显示文案（占必要宽度）并保持编辑。
    func setValidation(_ message: String) {
        validation.stringValue = message
        validation.isHidden = false
        validation.setAccessibilityHelp(message)
    }

    /// 用户继续输入：清掉上一次的校验文案，恢复完整行宽。
    func clearValidation() {
        validation.stringValue = ""
        validation.setAccessibilityHelp(nil)
        validation.isHidden = true
    }

    /// 结束就地编辑：恢复只读外观与凭据提示。
    func endEditing() {
        isEditingRow = false
        title.isEditable = false
        title.textColor = .labelColor
        validation.stringValue = ""
        validation.isHidden = true
        warning.isHidden = !needsCredentials
    }

    /// 当前就地校验文案；无错误时为空串。
    var validationMessage: String { validation.stringValue }

    /// 校验文案当前是否可见。
    var isShowingValidation: Bool { !validation.isHidden }

    /// 文本域当前是否可编辑（正在就地编辑）。
    var isTitleEditable: Bool { title.isEditable }

    private func build() {
        title.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        title.lineBreakMode = .byTruncatingMiddle
        title.textColor = .labelColor
        title.toolTip = "拖到右侧路由添加模型；在左侧拖到其他模型上方调整顺序"
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // NSTableView 的就地编辑取 `textField` 作为字段编辑器宿主。
        textField = title

        warning.image = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                accessibilityDescription: "凭据待配置")
        warning.contentTintColor = .systemOrange
        warning.toolTip = "凭据待配置"
        warning.setContentHuggingPriority(.required, for: .horizontal)

        validation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validation.textColor = .systemRed
        validation.lineBreakMode = .byTruncatingTail
        validation.usesSingleLineMode = true
        validation.maximumNumberOfLines = 1
        validation.isHidden = true
        validation.setContentHuggingPriority(.defaultLow, for: .horizontal)
        validation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([title, warning, validation], in: .leading)
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
    /// 非编辑时命中测试直接让出（点击/拖动落到表格本身）；就地编辑时正常参与命中，
    /// 以便字段编辑器/文本选择照常工作。
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditable ? super.hitTest(point) : nil
    }
}
