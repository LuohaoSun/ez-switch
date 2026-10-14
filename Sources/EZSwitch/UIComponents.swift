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
    /// Top-level Responses switch, keyed on `APIEndpointSettings.supportsResponses`.
    /// Turning on always starts native; turning off also resets the transport to
    /// native so an off switch can never carry a bridge transport.
    static func setResponsesEnabled(_ enabled: Bool, _ settings: inout APIEndpointSettings) {
        settings.setResponsesMode(enabled ? .native : .disabled)
    }

    /// Chat Completions switch. A bridged Responses config only counts as supported
    /// while Chat Completions is enabled, so disabling Chat also closes Responses
    /// instead of leaving the switch showing off on a saved bridge.
    static func setChatEnabled(_ enabled: Bool, _ settings: inout APIEndpointSettings) {
        settings.chat.enabled = enabled
        if !enabled, settings.responsesTransport == .chatCompletions {
            settings.setResponsesMode(.disabled)
        }
    }

    /// "接入方式" menu (native / bridge only). Bridging reuses the Chat Completions
    /// URL, so it enables Chat Completions to keep the switch genuinely usable.
    static func setResponsesTransport(_ transport: ResponsesTransport, _ settings: inout APIEndpointSettings) {
        switch transport {
        case .native:
            settings.setResponsesMode(.native)
        case .chatCompletions:
            settings.chat.enabled = true
            settings.setResponsesMode(.chatCompletions)
        }
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
                if kind == .responses {
                    // Same native switch layout as Chat / Messages; mode and URL
                    // only appear once Responses is actually supported.
                    Toggle(kind.displayName, isOn: enabledBinding(kind))
                        .toggleStyle(.switch)
                        .help("开启 Responses 接入；关闭时禁用 Responses 并恢复原生传输。")
                    if settings.supportsResponses {
                        Picker("接入方式", selection: responsesTransportBinding) {
                            Text("原生 Responses").tag(ResponsesTransport.native)
                            Text("转发到 Chat").tag(ResponsesTransport.chatCompletions)
                        }
                        .pickerStyle(.menu)
                        .help("转发到 Chat 复用 Chat Completions 地址并转换协议；需要完整会话历史，不支持远程上下文压缩。")
                        if settings.responsesTransport == .native {
                            TextField("Responses Base URL", text: baseURLBinding(.responses),
                                      prompt: Text(verbatim: EndpointSettingsEditorLogic.exampleBaseURL(for: .responses)))
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                } else if kind == .gemini {
                    // 原生 Gemini 与 Chat / Messages 同样是单个 native 开关 + Base URL。
                    Toggle(kind.displayName, isOn: enabledBinding(kind))
                        .toggleStyle(.switch)
                        .help("开启原生 Gemini 转发；Base URL 到 /v1beta，路由器追加 /models/{model}:generateContent。")
                    nativeURLField(kind)
                } else {
                    Toggle(kind.displayName, isOn: enabledBinding(kind))
                        .toggleStyle(.switch)
                    nativeURLField(kind)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var responsesTransportBinding: Binding<ResponsesTransport> {
        Binding(
            get: { settings.responsesTransport },
            set: { EndpointSettingsEditorLogic.setResponsesTransport($0, &settings) }
        )
    }

    private func enabledBinding(_ kind: EndpointKind) -> Binding<Bool> {
        Binding(
            get: {
                kind == .responses ? settings.supportsResponses : settings[kind].enabled
            },
            set: { value in
                switch kind {
                case .responses:
                    EndpointSettingsEditorLogic.setResponsesEnabled(value, &settings)
                case .chat:
                    EndpointSettingsEditorLogic.setChatEnabled(value, &settings)
                case .messages, .gemini:
                    settings[kind].enabled = value
                }
            }
        )
    }

    private func baseURLBinding(_ kind: EndpointKind) -> Binding<String> {
        Binding(
            get: { settings[kind].baseURL },
            set: { settings[kind].baseURL = $0 }
        )
    }

    /// Chat / Messages / Gemini 共用的 Base URL 输入框：禁用时只读，提示用协议示例。
    private func nativeURLField(_ kind: EndpointKind) -> some View {
        TextField("Base URL", text: baseURLBinding(kind),
                  prompt: Text(verbatim: EndpointSettingsEditorLogic.exampleBaseURL(for: kind)))
            .font(.system(.body, design: .monospaced))
            .disabled(!settings[kind].enabled)
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

struct ServiceSummary: View {
    @ObservedObject var store: ConfigStore
    var body: some View {
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
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
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
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(32)
    }
}
