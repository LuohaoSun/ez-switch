import SwiftUI
import AppKit

@MainActor
final class GeneralDraft: ObservableObject {
    @Published var port = ""
    @Published var harness: HarnessTarget = .codex
}

enum HarnessTarget: String, CaseIterable, Identifiable {
    case codex
    case claudeCode
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .opencode: return "OpenCode"
        }
    }

    var endpointPath: String {
        switch self {
        case .codex, .opencode: return "/v1"
        case .claudeCode: return ""
        }
    }
}

enum HarnessPrompt {
    static func make(harness: HarnessTarget, endpoint: String, modelIDs: [String]) -> String {
        let models = modelIDs.isEmpty ? "<model-id>" : modelIDs.joined(separator: "、")
        return """
        请帮我配置 \(harness.displayName) 供应商：

        - 端点：\(endpoint)
        - 密钥：任意占位符（例如 ez-switch-local）
        - 模型：\(models)

        请修改 \(harness.displayName) 的配置文件，并在需要时说明如何重新加载或重启。
        """
    }
}

struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var draft = GeneralDraft()
    @StateObject private var updater = UpdateChecker()

    private var validPort: Int? {
        guard let port = Int(draft.port), (1...65535).contains(port) else { return nil }
        return port
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    private var promptText: String {
        HarnessPrompt.make(
            harness: draft.harness,
            endpoint: store.connectionURL + draft.harness.endpointPath,
            modelIDs: store.config.fakes.map(\.fakeModelID)
        )
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
            Section("Harness 配置提示词") {
                Text("将 EZ Switch 配置为你的 Harness 供应商：选择要接入的工具并复制提示词。")
                    .foregroundStyle(.secondary)
                if store.config.fakes.isEmpty {
                    Text("请先在“模型”页添加一个本机模型 ID。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Harness", selection: $draft.harness) {
                        ForEach(HarnessTarget.allCases) { harness in
                            Text(harness.displayName).tag(harness)
                        }
                    }
                    Text(promptText)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Button {
                        copyText(promptText)
                    } label: {
                        Label("复制提示词", systemImage: "doc.on.doc")
                    }
                }
            }
            Section("应用") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(appVersion).foregroundStyle(.secondary)
                }
                updateContent
            }
            Section("配置文件") {
                Text(store.configURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.configURL]) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
        .onAppear {
            draft.port = String(store.config.port)
        }
        .onChange(of: store.config.port) { port in draft.port = String(port) }
    }

    private func savePort() {
        guard let port = validPort, port != store.config.port else { return }
        store.setPort(port)
    }

    @ViewBuilder
    private var updateContent: some View {
        switch updater.state {
        case .idle:
            Button {
                Task { await updater.check() }
            } label: {
                Label("检查更新", systemImage: "arrow.clockwise")
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查更新…")
            }
        case .upToDate:
            Label("当前已是最新版本", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            Button("再次检查") { Task { await updater.check() } }
        case .available(let release):
            VStack(alignment: .leading, spacing: 10) {
                Label("发现新版本 \(release.version)", systemImage: "arrow.down.circle")
                    .font(.headline)
                if let body = release.body, !body.isEmpty {
                    ScrollView {
                        Text(body)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                HStack {
                    Link("查看 Release", destination: release.htmlURL)
                    Button {
                        Task { await updater.downloadAndOpen(release) }
                    } label: {
                        Label("下载并打开 DMG", systemImage: "arrow.down.doc")
                    }
                }
            }
        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在下载 DMG…")
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在校验 SHA-256…")
            }
        case .ready(let fileName):
            Label("已打开 \(fileName)，请拖入 Applications 完成更新。", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            Button("重新检查") { Task { await updater.check() } }
        }
    }
}
