import SwiftUI
import AppKit

/// Cursor 扩展页区块自身的可变 UI 状态（退出确认、添加供应商错误）。
@MainActor
final class CursorSettingsDraft: ObservableObject {
    /// 退出本扩展 Cursor 登录的二次确认。
    @Published var confirmLogout = false
    /// “添加到供应商”失败原因。
    @Published var addError: String?
}

/// 扩展页的 Cursor 订阅连接区块。由 `BuiltinExtensions.panes` 动态挂载，
/// 原扩展页不引用任何 Cursor 类型、字面量或专用状态。
struct CursorSettingsSection: View {
    @ObservedObject var store: ConfigStore
    /// 长驻连接运行时；连接状态变化由 runtime 统一广播。
    @ObservedObject private var connection = CursorConnectionModel.shared
    /// 添加到供应商成功后跳到“供应商与路由”页；由容器（扩展页）提供。
    var onOpenSuppliers: () -> Void

    @StateObject private var draft = CursorSettingsDraft()

    private var enabled: Bool { store.config.extensions.cursorConnector.enabled }
    private var added: Bool { store.config.extensions.cursorConnector.providerAdded }

    var body: some View {
        Section {
            Toggle("启用", isOn: Binding(
                get: { enabled },
                set: { connection.setEnabled($0, store: store) }
            ))
            .toggleStyle(.switch)

            Text("由 CLIProxyAPIPlus 提供连接。")
                .font(.caption).foregroundStyle(.secondary)

            if enabled {
                statusRow
                actions
                compatibilityDisclosure
            }
        } header: {
            Text("Cursor 订阅连接")
        } footer: {
            Text(enabled
                 ? "关闭开关不会删除已添加的 Cursor 供应商、模型或路由绑定。"
                 : "需先启用才能连接、同步模型并添加到供应商。")
        }
        .alert("退出本扩展的 Cursor 登录？", isPresented: $draft.confirmLogout) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) {
                Task { await connection.disconnect(store: store) }
            }
        } message: {
            Text("只会删除本扩展保存的 Cursor 登录凭据，不影响系统上其它工具；Cursor 供应商、模型与路由绑定会保留。")
        }
    }

    // MARK: 状态

    @ViewBuilder
    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if connection.loading {
                ProgressView().controlSize(.small)
            }
            Label {
                Text(statusText)
            } icon: {
                Image(systemName: statusSymbol)
            }
            .foregroundStyle(statusColor)
        }

        // needsAttention 已把探测/动作错误并入状态文本；其余情况才单列，避免重复。
        if let inspectError = connection.status?.error, !statusTextCarriesError {
            Text(inspectError).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }

        if let error = connection.error, !statusTextCarriesError {
            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }

        if connection.presentation == .connected {
            if let account = connection.account, !account.isEmpty {
                Text("账号：\(account)").font(.caption).foregroundStyle(.secondary)
            }
            Text("可用模型 \(connection.models.count) 个\(versionSuffix)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("重新检测") {
                    Task { await connection.refresh(store: store) }
                }
                .disabled(connection.loading)

                primaryAction
                logoutAction
            }
            if let error = draft.addError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch connection.presentation {
        case .notInstalled:
            Button("打开项目说明") { openProjectDocs() }
        case .notAuthenticated:
            Button("连接 Cursor") {
                draft.addError = nil
                Task { await connection.connect(store: store) }
            }
            .disabled(connection.loading)
        case .needsAttention:
            Button("重新连接 Cursor") {
                draft.addError = nil
                Task { await connection.connect(store: store) }
            }
            .disabled(connection.loading)
        case .connected:
            if added {
                Button("前往供应商") { onOpenSuppliers() }
                Button("同步模型") { syncModels() }
                    .disabled(connection.loading)
            } else {
                Button("添加到供应商") { addProvider() }
                    .disabled(connection.loading)
            }
        case .loading:
            EmptyView()
        }
    }

    /// 只要真实登录态为已认证，就允许退出；标签明确这是本扩展自己的登录。
    @ViewBuilder
    private var logoutAction: some View {
        if connection.authenticated {
            Button("退出 Cursor 登录", role: .destructive) { draft.confirmLogout = true }
                .disabled(connection.loading)
        }
    }

    @ViewBuilder
    private var compatibilityDisclosure: some View {
        DisclosureGroup("兼容范围") {
            Text("支持文本 Chat / Responses / Messages（含工具调用与跨工具回合历史），由项目内固定的 CLIProxyAPIPlus 实现；跨工具回合在代理进程内保持状态，进程重启会中断未完成的工具会话。无法承诺全部 Responses 特性与完整图像支持。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 文案

    private var statusText: String {
        switch connection.presentation {
        case .loading:
            return connection.awaitingBrowser
                ? "正在连接 / 等待浏览器登录…"
                : "正在检测连接组件…"
        case .notInstalled: return "应用扩展组件未安装或构建异常"
        case .notAuthenticated: return "尚未登录 Cursor"
        case .needsAttention(let message): return message
        case .connected: return "已连接"
        }
    }

    private var statusSymbol: String {
        switch connection.presentation {
        case .loading: return "hourglass"
        case .notInstalled: return "puzzlepiece.extension"
        case .notAuthenticated: return "person.crop.circle"
        case .needsAttention: return "exclamationmark.triangle"
        case .connected: return "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch connection.presentation {
        case .connected: return .green
        case .notInstalled, .needsAttention: return .orange
        case .notAuthenticated, .loading: return .secondary
        }
    }

    private var versionSuffix: String {
        guard let version = connection.version, !version.isEmpty else { return "" }
        return " · 组件 \(version)"
    }

    /// needsAttention 已把错误并入状态文本，避免重复展示。
    private var statusTextCarriesError: Bool {
        if case .needsAttention = connection.presentation { return true }
        return false
    }

    // MARK: 动作

    private func addProvider() {
        draft.addError = connection.addProvider(store: store)
        if draft.addError == nil { onOpenSuppliers() }
    }

    /// 已添加到供应商后同步模型：先真实刷新，再走 store 的幂等补齐（保留既有模型 ID 与绑定）。
    private func syncModels() {
        draft.addError = nil
        Task {
            await connection.refresh(store: store)
            guard connection.isConnected else { return }
            draft.addError = connection.addProvider(store: store)
        }
    }

    /// 组件缺失/构建异常时指向项目说明，而不是官方 CLI 安装。
    private func openProjectDocs() {
        guard let url = URL(string: "https://github.com/LuohaoSun/ez-switch") else { return }
        NSWorkspace.shared.open(url)
    }
}
