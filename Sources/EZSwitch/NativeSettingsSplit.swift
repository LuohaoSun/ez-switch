import AppKit
import SwiftUI

struct NativeSettingsSplit<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    @Binding var isSidebarVisible: Bool
    let sidebar: Sidebar
    let detail: Detail

    func makeNSViewController(context: Context) -> SettingsSplitContainerViewController<Sidebar, Detail> {
        SettingsSplitContainerViewController(isSidebarVisible: $isSidebarVisible,
                                             sidebar: sidebar,
                                             detail: detail)
    }

    func updateNSViewController(_ controller: SettingsSplitContainerViewController<Sidebar, Detail>,
                                context: Context) {
        controller.sidebarHost.rootView = sidebar
        controller.detailHost.rootView = detail
        controller.syncSidebarVisibility($isSidebarVisible)
    }
}

final class SettingsSplitContainerViewController<Sidebar: View, Detail: View>: NSViewController {
    let sidebarHost: NSHostingController<Sidebar>
    let detailHost: NSHostingController<Detail>

    private let splitViewController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private let detailItem: NSSplitViewItem

    private var sidebarVisibility: Binding<Bool>
    private var collapseObservation: NSKeyValueObservation?
    private var didPlaceInitialPosition = false

    init(isSidebarVisible: Binding<Bool>, sidebar: Sidebar, detail: Detail) {
        self.sidebarVisibility = isSidebarVisible

        let sidebarHost = NSHostingController(rootView: sidebar)
        let detailHost = NSHostingController(rootView: detail)
        // 内容不发布固有尺寸，避免撑大外层 split 与窗口。
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []
        if #available(macOS 14.0, *) {
            detailHost.sceneBridgingOptions = .all
            sidebarHost.sceneBridgingOptions = []
        }
        self.sidebarHost = sidebarHost
        self.detailHost = detailHost

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView  // 折叠时保持 split 固定几何
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(450)

        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 640
        detailItem.holdingPriority = .defaultLow
        if #available(macOS 26.0, *) {
            detailItem.automaticallyAdjustsSafeAreaInsets = true
        }
        self.sidebarItem = sidebarItem
        self.detailItem = detailItem

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = SettingsSplitContainerView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)

        addChild(splitViewController)
        let splitView = splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 原生折叠（分隔条/菜单）异步回写，避免在 SwiftUI 更新中改状态。
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let visible = !item.isCollapsed
            DispatchQueue.main.async {
                guard let self, self.sidebarVisibility.wrappedValue != visible else { return }
                self.sidebarVisibility.wrappedValue = visible
            }
        }

        applySidebarVisibility(animated: false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didPlaceInitialPosition else { return }
        let splitView = splitViewController.splitView
        let divider = splitView.dividerThickness
        let required = sidebarItem.minimumThickness + detailItem.minimumThickness + divider
        guard splitView.bounds.width >= required else { return }
        didPlaceInitialPosition = true
        let ideal = min(190, splitView.bounds.width - detailItem.minimumThickness - divider)
        splitView.setPosition(ideal, ofDividerAt: 0)
    }

    func syncSidebarVisibility(_ binding: Binding<Bool>) {
        sidebarVisibility = binding
        applySidebarVisibility(animated: true)
    }

    private func applySidebarVisibility(animated: Bool) {
        let collapsed = !sidebarVisibility.wrappedValue
        guard sidebarItem.isCollapsed != collapsed else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sidebarItem.animator().isCollapsed = collapsed
        } else {
            sidebarItem.isCollapsed = collapsed
        }
    }
}

private final class SettingsSplitContainerView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
