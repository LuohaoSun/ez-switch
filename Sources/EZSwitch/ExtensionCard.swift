import SwiftUI
import AppKit

/// 扩展页统一卡片：标题折叠按钮与启用开关分开，避免点击开关触发折叠。
struct ExtensionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let summary: String
    @Binding var isEnabled: Bool
    private let content: Content

    @StateObject private var state: ExtensionCardState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, systemImage: String, summary: String,
         isEnabled: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.summary = summary
        self._isEnabled = isEnabled
        self.content = content()
        self._state = StateObject(wrappedValue: ExtensionCardState(expanded: isEnabled.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if state.expanded {
                Divider()
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .onChange(of: isEnabled) { enabled in
            withAnimation(expandAnimation) { state.expanded = enabled }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: toggleExpanded) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(state.expanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.expanded ? "收起" : "展开")
            .accessibilityLabel(title)
            .accessibilityValue(state.expanded ? "已展开" : "已收起")

            Toggle("", isOn: enableBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(isEnabled ? "停用" : "启用")
                .accessibilityLabel("启用\(title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(expandAnimation, value: state.expanded)
    }

    /// 启用时先展开，即使写入被拒也能看到错误与设置；停用仍按正常路径收起。
    private var enableBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                if newValue { withAnimation(expandAnimation) { state.expanded = true } }
                isEnabled = newValue
            }
        )
    }

    private var expandAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private func toggleExpanded() {
        withAnimation(expandAnimation) { state.expanded.toggle() }
    }
}

final class ExtensionCardState: ObservableObject {
    @Published var expanded: Bool
    init(expanded: Bool) { self.expanded = expanded }
}
