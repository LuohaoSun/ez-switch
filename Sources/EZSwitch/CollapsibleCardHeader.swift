import SwiftUI

/// 可折叠卡片的标题栏：整条标题栏是一个按钮（箭头在内，点箭头等同点标题）；
/// 尾部 `accessory` 是标题按钮的兄弟视图，独立命中，不触发展开/折叠。
/// 排序拖动仍由调用方经 `NativeCardDragHandle` 挂在标题按钮上。
struct CollapsibleCardHeader<DragID: Hashable & Codable & Sendable, Title: View, Accessory: View>: View {
    let dragID: DragID
    var dragEnabled = true
    let isExpanded: Bool
    let toggle: () -> Void
    let accessibilityLabel: String
    let help: String
    @ViewBuilder let title: () -> Title
    @ViewBuilder let accessory: () -> Accessory
    /// 与展开体高度同一节奏地转动箭头；“减少运动”时直接切换。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    title()
                }
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(NativeCardDragHandle(id: dragID, enabled: dragEnabled))
            .help(help)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            // 箭头与展开体共用同一时长/曲线，收起与展开时两处过渡一致。
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)

            accessory()
        }
    }
}
