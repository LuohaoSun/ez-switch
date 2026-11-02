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
            .foregroundStyle(warning ? Color.orange : Color.secondary)
    }
}

/// 统一的原生卡片表面：控制背景 + 连续圆角 + 细描边 + 极轻投影（不投影内容文字）。
extension View {
    func ezsCardSurface(cornerRadius: CGFloat = 12, padding: CGFloat? = nil) -> some View {
        modifier(EZSCardSurface(cornerRadius: cornerRadius, padding: padding))
    }
}

private struct EZSCardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .padding(padding ?? 0)
            .clipShape(shape)
            .background(
                shape
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
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
                .padding(16)
                .ezsCardSurface()
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: store.serverError == nil && store.runningPort != nil ? "network" : "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(store.serverError != nil ? Color.orange : Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.serviceTitle).font(.headline)
                Text(store.connectionURL).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { copyText(store.connectionURL) } label: {
                Label("复制地址", systemImage: "doc.on.doc")
            }
            .disabled(store.runningPort == nil)
        }
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
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity).padding(32)
    }
}
