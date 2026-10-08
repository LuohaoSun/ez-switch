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
    let suppliers: NSHostingView<Suppliers>
    let routes: NSHostingView<Routes>
    let splitView = NSSplitView()
    private var placedDivider = false

    init(suppliers: Suppliers, routes: Routes) {
        self.suppliers = NSHostingView(rootView: suppliers)
        self.routes = NSHostingView(rootView: routes)
        super.init(frame: .zero)
        // Pane content must not push its fitting size back into the surrounding navigation split.
        self.suppliers.sizingOptions = []
        self.routes.sizingOptions = []
        self.suppliers.frame = NSRect(x: 0, y: 0, width: 280, height: 640)
        self.routes.frame = NSRect(x: 281, y: 0, width: 519, height: 640)
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
        // 外层侧栏或标题栏可能与详情区域重叠，内部 split 按安全区约束。
        let safeArea = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            self.suppliers.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            self.suppliers.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            self.routes.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard !placedDivider, splitView.bounds.width >= 581 else { return }
        placedDivider = true
        splitView.setPosition(min(280, splitView.bounds.width - 360 - splitView.dividerThickness), ofDividerAt: 0)
    }
}
