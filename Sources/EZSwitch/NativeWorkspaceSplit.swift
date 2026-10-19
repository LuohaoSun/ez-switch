import AppKit
import SwiftUI

struct NativeWorkspaceSplit<Suppliers: View, Routes: View>: NSViewRepresentable {
    let suppliers: Suppliers
    let routes: Routes

    func makeNSView(context: Context) -> WorkspaceSplitView<Suppliers, Routes> {
        WorkspaceSplitView(suppliers: suppliers, routes: routes)
    }

    func updateNSView(_ view: WorkspaceSplitView<Suppliers, Routes>, context: Context) {
        view.suppliers.rootView = suppliers
        view.routes.rootView = routes
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceSplitView<Suppliers, Routes>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 640)
    }
}

final class WorkspaceSplitView<Suppliers: View, Routes: View>: NSView {
    private let defaultSupplierWidth: CGFloat = 380
    private let minSupplierWidth: CGFloat = 220
    private let minRouteWidth: CGFloat = 360

    let suppliers: NSHostingView<Suppliers>
    let routes: NSHostingView<Routes>
    let splitView = NSSplitView()
    private var placedDivider = false
    /// 供应商栏上限：动态约束，随可用宽度收紧，避免窄窗口下与路由栏最小宽冲突。
    private var supplierWidthCap: NSLayoutConstraint!

    init(suppliers: Suppliers, routes: Routes) {
        self.suppliers = NSHostingView(rootView: suppliers)
        self.routes = NSHostingView(rootView: routes)
        super.init(frame: .zero)
        // Pane content must not push its fitting size back into the surrounding navigation split.
        self.suppliers.sizingOptions = []
        self.routes.sizingOptions = []
        self.suppliers.frame = NSRect(x: 0, y: 0, width: defaultSupplierWidth, height: 640)
        self.routes.frame = NSRect(x: defaultSupplierWidth + 1, y: 0, width: 519, height: 640)
        self.suppliers.translatesAutoresizingMaskIntoConstraints = false
        self.routes.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(self.suppliers)
        splitView.addArrangedSubview(self.routes)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(450), forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)
        // 供应商栏上限不写死：在 layout() 中按“可用宽度 − 路由栏最小宽度”动态更新，
        // 既允许用户把分隔线拖宽，也不会被内容或可用宽度无限撑开。
        let supplierCap = self.suppliers.widthAnchor.constraint(
            lessThanOrEqualToConstant: minSupplierWidth)
        self.supplierWidthCap = supplierCap
        // 外层侧栏或标题栏可能与详情区域重叠，内部 split 按安全区约束。
        let safeArea = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            self.suppliers.widthAnchor.constraint(greaterThanOrEqualToConstant: minSupplierWidth),
            supplierCap,
            self.routes.widthAnchor.constraint(greaterThanOrEqualToConstant: minRouteWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateSupplierWidthCap()
        guard !placedDivider,
              splitView.bounds.width >= minSupplierWidth + minRouteWidth + splitView.dividerThickness
        else { return }
        placedDivider = true
        // 默认 380pt；可用宽度不足时收窄，始终给路由栏留出最小宽度。
        let maxPosition = splitView.bounds.width - minRouteWidth - splitView.dividerThickness
        splitView.setPosition(min(defaultSupplierWidth, maxPosition), ofDividerAt: 0)
    }

    /// 上限 = 可用宽度 − 路由栏最小宽度；窄窗口自动收紧，避免与路由栏最小宽约束冲突。
    /// 只调整上限，不重置用户拖动后的实际宽度，因此窗口 resize 不会把分隔线弹回默认值。
    private func updateSupplierWidthCap() {
        let available = splitView.bounds.width
        guard available > 0 else { return }
        supplierWidthCap.constant = max(minSupplierWidth,
                                        available - minRouteWidth - splitView.dividerThickness)
    }
}
