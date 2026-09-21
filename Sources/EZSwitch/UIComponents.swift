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

struct EndpointSettingsEditor: View {
    @Binding var settings: APIEndpointSettings

    var body: some View {
        ForEach(EndpointKind.allCases, id: \.self) { kind in
            VStack(alignment: .leading, spacing: 6) {
                Toggle(kind.displayName, isOn: enabledBinding(kind))
                TextField("Base URL", text: baseURLBinding(kind),
                          prompt: Text(verbatim: exampleURL(kind)))
                    .font(.system(.body, design: .monospaced))
                    .disabled(!settings[kind].enabled)
            }
        }
    }

    private func enabledBinding(_ kind: EndpointKind) -> Binding<Bool> {
        Binding(
            get: { settings[kind].enabled },
            set: { settings[kind].enabled = $0 }
        )
    }

    private func baseURLBinding(_ kind: EndpointKind) -> Binding<String> {
        Binding(
            get: { settings[kind].baseURL },
            set: { settings[kind].baseURL = $0 }
        )
    }

    private func exampleURL(_ kind: EndpointKind) -> String {
        switch kind {
        case .chat: return "https://api.example.com/v1"
        case .responses: return "https://api.example.com/v1"
        case .messages: return "https://api.example.com"
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
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct SourceListScrollAppearance: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }

        func configure() {
            guard let scroll = enclosingScrollView else { return }
            // AppKit-backed sidebar lists can ignore SwiftUI's scrollIndicators setting.
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.drawsBackground = false
        }
    }

    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) {
        DispatchQueue.main.async { view.configure() }
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
