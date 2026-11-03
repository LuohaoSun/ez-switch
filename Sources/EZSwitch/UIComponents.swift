import SwiftUI
import AppKit

func copyText(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

extension RemoteModel {
    var routeLabel: String { "\(splitProviderModel(name).provider) · \(model)" }
    var needsCredentials: Bool { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == "sk-REPLACE-ME" }
}

/// View-free transition logic behind `EndpointSettingsEditor`. Declared next to the
/// view so tests exercise the exact production behavior instead of a UI mirror.
enum EndpointSettingsEditorLogic {
    /// Native protocol switch. Only touches the targeted protocol.
    static func setEndpointEnabled(_ enabled: Bool, _ kind: EndpointKind, _ settings: inout APIEndpointSettings) {
        settings[kind].enabled = enabled
    }

    /// Base URL placeholder per protocol. Gemini native stops at `/v1beta`; the
    /// router appends `/models/{model}:generateContent`.
    static func exampleBaseURL(for kind: EndpointKind) -> String {
        switch kind {
        case .chat, .responses: return "https://api.example.com/v1"
        case .messages: return "https://api.example.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }
}

struct EndpointSettingsEditor: View {
    @Binding var settings: APIEndpointSettings

    var body: some View {
        ForEach(EndpointKind.allCases, id: \.self) { kind in
            VStack(alignment: .leading, spacing: 6) {
                Toggle(kind.displayName, isOn: enabledBinding(kind))
                    .toggleStyle(.switch)
                    .help(helpText(for: kind))
                nativeURLField(kind)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func enabledBinding(_ kind: EndpointKind) -> Binding<Bool> {
        Binding(
            get: { settings[kind].enabled },
            set: { EndpointSettingsEditorLogic.setEndpointEnabled($0, kind, &settings) }
        )
    }

    private func baseURLBinding(_ kind: EndpointKind) -> Binding<String> {
        Binding(
            get: { settings[kind].baseURL },
            set: { settings[kind].baseURL = $0 }
        )
    }

    /// Base URL 输入框：禁用时只读，提示用协议示例。
    private func nativeURLField(_ kind: EndpointKind) -> some View {
        TextField("Base URL", text: baseURLBinding(kind),
                  prompt: Text(verbatim: EndpointSettingsEditorLogic.exampleBaseURL(for: kind)))
            .font(.system(.body, design: .monospaced))
            .disabled(!settings[kind].enabled)
    }

    private func helpText(for kind: EndpointKind) -> String {
        switch kind {
        case .gemini:
            return "开启原生 Gemini 转发；Base URL 到 /v1beta，路由器追加 /models/{model}:generateContent。"
        case .responses:
            return "开启原生 Responses 转发；Base URL 到 /v1，路由器追加 /responses。"
        default:
            return "开启 \(kind.displayName) 转发；Base URL 填完整前缀，路由器只追加协议相对路径。"
        }
    }
}

extension ConfigStore {
    var serviceTitle: String {
        if serverError != nil { return "启动失败" }
        return runningPort == nil ? "服务未运行" : "服务运行中"
    }
    var connectionURL: String { "http://127.0.0.1:\(runningPort ?? config.port)" }
    func routeRemote(_ fake: FakeModel) -> RemoteModel? {
        config.remotes.first { $0.id == fake.remoteID }
    }
}

struct StatusLabel: View {
    let title: String
    var warning = false
    var body: some View {
        Label(title, systemImage: warning ? "exclamationmark.circle.fill" : "checkmark.circle")
            .font(.caption)
            .foregroundStyle(warning ? AppDesign.warning : Color.secondary)
    }
}

/// 统一的原生卡片表面：表面色 + 连续圆角 + 细描边 + 极轻投影（不投影内容文字）。
/// 生产实现只有 `CardSurfaceModifier` 一处，这里仅保留既有签名。
extension View {
    /// 保留既有的内容裁剪：扩展卡与供应商卡片依赖它把内容收进圆角。
    /// `cardSurface` 则不裁剪，避免收窄原生表格的绘制余量。
    func ezsCardSurface(cornerRadius: CGFloat = AppDesign.Radius.card, padding: CGFloat? = nil) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius,
                                     padding: padding ?? 0,
                                     clipsContent: true))
    }
}

struct ServiceSummary: View {
    @ObservedObject var store: ConfigStore
    /// 嵌在 `.formStyle(.grouped)` 的 Form 行里时不再套独立卡片，避免“框中框”。
    var embeddedInForm = false

    var body: some View {
        if embeddedInForm {
            content
        } else {
            content
                .padding(AppDesign.Space.card)
                .ezsCardSurface()
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 40, height: 40)
                .background(statusColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: AppDesign.Radius.inset, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(store.serviceTitle).font(.headline)
                Text(store.connectionURL)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        AppDesign.inset,
                        in: RoundedRectangle(cornerRadius: AppDesign.Radius.row, style: .continuous)
                    )
            }
            Spacer(minLength: 12)
            Button { copyText(store.connectionURL) } label: {
                Label("复制地址", systemImage: "doc.on.doc")
            }
            .disabled(store.runningPort == nil)
            .help("复制本机服务地址")
        }
    }

    /// 运行 / 未运行 / 启动失败三态共用一枚语义色图标，不再用品牌色冒充运行状态。
    private var statusSymbol: String {
        if store.serverError != nil { return "exclamationmark.triangle.fill" }
        return "network"
    }

    private var statusColor: Color {
        if store.serverError != nil { return AppDesign.danger }
        return store.runningPort != nil ? AppDesign.success : Color.secondary
    }
}

struct NativeListRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .listRowSeparator(.hidden)
    }
}

struct EmptyState: View {
    let title: String
    let detail: String
    let symbol: String
    /// 空状态里的就地操作（例如“添加供应商”），避免用户再去工具栏找加号。
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(
                    AppDesign.inset,
                    in: RoundedRectangle(cornerRadius: AppDesign.Radius.inset, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(AppDesign.brand)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .accessibilityElement(children: .contain)
    }
}
