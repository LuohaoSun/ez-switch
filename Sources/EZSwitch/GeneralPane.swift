import SwiftUI
import AppKit

@MainActor
final class GeneralDraft: ObservableObject {
    @Published var port = ""
}

struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var draft = GeneralDraft()

    private var validPort: Int? {
        guard let port = Int(draft.port), (1...65535).contains(port) else { return nil }
        return port
    }

    var body: some View {
        Form {
            Section("本地服务") {
                ServiceSummary(store: store)
                if let error = store.serverError {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                HStack {
                    TextField("监听端口", text: $draft.port)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { savePort() }
                    Button("保存端口") { savePort() }
                        .disabled(validPort == nil || validPort == store.config.port)
                }
                if validPort == nil {
                    Text("请输入 1–65535 之间的整数端口。").font(.caption).foregroundStyle(.red)
                }
                if let running = store.runningPort, running != store.config.port {
                    Label("当前使用 \(String(running))；已保存的端口 \(String(store.config.port)) 将在重启后生效。", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("修改端口后需要重启应用。路由切换即时生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("启动") {
                Toggle("登录时启动", isOn: Binding(get: { store.loginItemEnabled }, set: { _ in store.toggleLoginItem() }))
            }
            Section("配置文件") {
                Text(store.configURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.configURL]) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
        .onAppear { draft.port = String(store.config.port) }
        .onChange(of: store.config.port) { port in draft.port = String(port) }
    }

    private func savePort() {
        guard let port = validPort, port != store.config.port else { return }
        store.setPort(port)
    }
}
