import Foundation
import Combine
import AppKit

/// Cursor 连接运行时，@MainActor 单例；生命周期独立于设置页。
///
/// 传输实现是本项目内固定的 CLIProxyAPIPlus sidecar（`CursorSidecarClient`）。登录、退出
/// 与进程都只作用于**本扩展自己的** `extensions/cursor` auth/runtime 目录：不读取、不复制、
/// 不修改系统上其它 Cursor CLI、桌面应用或真实 `~/.cursor` 配置。约束：连接可用 =
/// 已安装 + 运行中 + 已认证 + 有模型 + 无错误；disable/logout 必须立即让 router 不可用并
/// 作废在途 inspect（代次），不得出现“已禁用却短暂可用”。
@MainActor
final class CursorConnectionModel: ObservableObject {
    static let shared = CursorConnectionModel()

    @Published private(set) var status: CursorProxyStatus?
    @Published private(set) var loading = false
    /// 登录流程已授权打开浏览器、正在等待浏览器回调完成。
    @Published private(set) var awaitingBrowser = false
    /// 动作错误（登录/退出失败）；`status.error` 是探测内错误，分开显示。
    @Published private(set) var error: String?

    /// 传输实现只在本扩展内可见；主干与 UI 不接触 sidecar 客户端。
    private let client: any CursorProxyClientProtocol
    private let source: RemoteSource
    private let settingsKey: String

    /// 通用状态信号；连接变化时递增其 revision，供设置页/工作区通用观察。
    private var runtime: ExtensionRuntime?
    /// attach 过的配置存储；目录刷新经它同步 router 就绪。弱引用，不延长生命周期。
    private weak var attachedStore: ConfigStore?

    /// 本扩展独立的 auth/runtime 根目录；每次 configure 都指向它，绝不指向真实 CLI 目录。
    private var rootURL: URL?

    /// enable/disable/disconnect/refresh 各自递增；异步返回时代次不等即丢弃。
    private var generation = 0
    /// disable 触发的异步停止。关闭后立即再打开时，必须先 await 它，避免慢的旧 stop 停掉
    /// 新启动的进程（两个 Task 各停各的）。
    private var pendingStop: Task<Void, Never>?
    private var configCancellable: AnyCancellable?
    private var observedEnabled: Bool?

    init(client: any CursorProxyClientProtocol = CursorSidecarClient.shared) {
        self.client = client
        self.source = CursorExtension.source
        self.settingsKey = CursorExtension.settingsKey
    }

    var authenticated: Bool { status?.authenticated == true }
    var models: [String] { status?.models ?? [] }
    var account: String? { status?.account }
    var version: String? { status?.version }

    /// 连接完整可用。缺任一条件（未安装 / 未运行 / 未登录 / 无模型 / 探测报错）都为 false，
    /// 绝不伪造账号或模型。
    var isConnected: Bool { status?.connected == true }

    /// 可路由 = 扩展已启用且连接完整可用。
    func isReady(in store: ConfigStore) -> Bool {
        store.config.extensions.connectorSettings(for: settingsKey).enabled && isConnected
    }

    enum Presentation: Equatable {
        case loading
        case notInstalled
        case notAuthenticated
        /// 探测报错、组件未运行或模型枚举失败——需重新连接。
        case needsAttention(String)
        case connected
    }

    var presentation: Presentation {
        guard let status else {
            // 状态为空但动作已失败（login/configure 报错且已清 status）：给可重试的
            // needsAttention，而不是让 UI 永远停在 loading、没有重连入口。
            if !loading, let error { return .needsAttention(error) }
            return .loading
        }
        if !status.installed { return .notInstalled }
        if let error = status.error { return .needsAttention(error) }
        if !status.running { return .needsAttention("连接组件未运行，请重新连接") }
        if !status.authenticated { return .notAuthenticated }
        if status.models.isEmpty {
            return .needsAttention("已登录，但未能获取模型列表，请重新连接")
        }
        return .connected
    }

    /// 订阅一次 store 配置；启动时若已持久化启用即刷新。幂等。
    /// 仅 enabled 变化才刷新，增删改供应商不重置连接就绪；外部 reload 关闭同样取消在途会话。
    /// `runtime` 传入后，本连接状态变化会递增其 revision（不反向写回本模型，无循环发布）。
    func attach(to store: ConfigStore, runtime: ExtensionRuntime? = nil) {
        if let runtime { self.runtime = runtime }
        attachedStore = store
        rootURL = root(for: store)
        guard configCancellable == nil else { return }
        observedEnabled = store.config.extensions.connectorSettings(for: settingsKey).enabled
        if observedEnabled == true { Task { await refresh(store: store) } }
        configCancellable = store.$config.sink { [weak self] config in
            guard let self else { return }
            // @Published 在 willSet 发新值：用闭包参数，不读 store.config。
            let enabled = config.extensions.connectorSettings(for: self.settingsKey).enabled
            if self.observedEnabled != enabled {
                self.observedEnabled = enabled
                self.handleEnabledChange(enabled, store: store)
            }
            self.syncRouter(enabled: enabled, store: store)
        }
    }

    func refresh(store: ConfigStore) async {
        rootURL = root(for: store)
        // 禁用时绝不 configure/inspect（不启动 helper）：同步为不可用再返回。
        // 这样 off→on→off 后迟到的旧 refresh 不会把已禁用的 helper 拉起来。
        guard store.config.extensions.connectorSettings(for: settingsKey).enabled else {
            syncRouter(enabled: false, store: store)
            return
        }
        await reloadStatus()
        syncRouter(store: store)
    }

    /// 目录刷新入口：只在扩展启用时同步真实连接状态与 router 就绪，再返回模型目录。
    /// 禁用时明确不可用，绝不 configure/inspect（不偷偷启动 sidecar）。
    /// 供通用扩展 seam 的取目录闭包委托，避免“目录取到、连接状态/可用性却过期”；
    /// 通用 UI 只调用 registry，不感知具体连接。
    func catalog() async throws -> [String] {
        guard let store = attachedStore else {
            throw CursorConnectorError(reason: status?.error)
        }
        let enabled = store.config.extensions.connectorSettings(for: settingsKey).enabled
        guard enabled else { throw CursorConnectorError(reason: "扩展未启用") }
        await refresh(store: store)
        guard isReady(in: store) else { throw CursorConnectorError(reason: status?.error) }
        return models
    }

    /// 切换总开关。UI 路径自行同步处理；attach 时由订阅触发，避免重复 inspect。
    func setEnabled(_ enabled: Bool, store: ConfigStore) {
        guard store.config.extensions.connectorSettings(for: settingsKey).enabled != enabled else {
            syncRouter(store: store)
            return
        }
        observedEnabled = enabled   // 订阅将看到无变化，跳过重复处理
        store.setConnectorEnabled(settingsKey: settingsKey, enabled: enabled)
        handleEnabledChange(enabled, store: store)
        syncRouter(enabled: enabled, store: store)
    }

    /// 用户点击「连接」：先清空旧连接，再经 sidecar 完成登录（由 model 提供浏览器打开闭包），
    /// 成功后重新探测。失败不留旧的“已连接”。
    func connect(store: ConfigStore) async {
        generation += 1
        let gen = generation
        loading = true
        error = nil
        status = nil
        awaitingBrowser = false
        syncRouter(store: store)
        let root = self.root(for: store)
        rootURL = root
        do {
            try await client.configure(root: root)
            guard gen == generation else { return }
            // 已授权打开浏览器，进入等待登录回调阶段（UI 用 loading 阶段呈现）。
            awaitingBrowser = true
            try await client.login(openURL: Self.openBrowser)
        } catch {
            guard gen == generation else { return }
            awaitingBrowser = false
            self.error = Self.describe(error)
            loading = false
            return
        }
        guard gen == generation else { return }
        awaitingBrowser = false
        let result = await client.inspect()
        guard gen == generation else { return }
        status = result
        loading = false
        syncRouter(store: store)
    }

    /// 退出登录（调用方先确认）。只删除本扩展自己的 Cursor 登录凭据，保留供应商、模型与
    /// 路由绑定；立即置为不可用，不等 sidecar 退出完成。
    func disconnect(store: ConfigStore) async {
        generation += 1
        let gen = generation
        loading = true
        error = nil
        status = nil
        awaitingBrowser = false
        syncRouter(store: store)
        let root = self.root(for: store)
        rootURL = root
        do {
            try await client.configure(root: root)
            guard gen == generation else { return }
            try await client.logout()
        } catch {
            guard gen == generation else { return }
            self.error = Self.describe(error)
            loading = false
            return
        }
        guard gen == generation else { return }
        await refresh(store: store)
    }

    /// 连接成功且扩展仍启用时把探测到的模型加入供应商名单并绑定；只走通用原子实现。
    /// 用 `isReady` 而非 `isConnected`：禁用后的 stale 合法状态不得再写入供应商。
    @discardableResult
    func addProvider(store: ConfigStore) -> String? {
        guard isReady(in: store) else { return "Cursor 未连接，无法添加供应商" }
        let modelIDs = status?.models ?? []
        guard !modelIDs.isEmpty else { return "未获取到 Cursor 模型" }
        let result = store.addConnectorProvider(source: source, settingsKey: settingsKey,
                                                modelIDs: modelIDs, named: CursorExtension.displayName)
        syncRouter(store: store)
        return result
    }

    private func handleEnabledChange(_ enabled: Bool, store: ConfigStore) {
        if enabled {
            // 先等旧 disable 的停止完成，再刷新（新 generation），避免旧 stop 停掉新进程。
            let prior = pendingStop
            pendingStop = nil
            Task {
                await prior?.value
                // 等待期间可能又被关闭：仅在仍启用时刷新，避免旧 Task 迟到启动已禁用的 helper。
                guard self.observedEnabled == true,
                      store.config.extensions.connectorSettings(for: self.settingsKey).enabled else {
                    self.syncRouter(enabled: false, store: store)
                    return
                }
                await self.refresh(store: store)
            }
        } else {
            // 立即不可用并作废在途结果；停止是异步的，只作用于本扩展自己的 sidecar。
            invalidate()
            status = nil
            error = nil
            let root = rootURL ?? self.root(for: store)
            rootURL = root
            pendingStop = Task { [client] in
                try? await client.configure(root: root)
                await client.stop()
            }
        }
    }

    /// 只做探测并落状态（代次保护），不触碰 router；由 refresh / catalog 复用。
    /// configure 后可被 disable 作废：代次不等则直接返回，绝不继续 inspect（不重启 sidecar）。
    private func reloadStatus() async {
        generation += 1
        let gen = generation
        loading = true
        error = nil
        guard let root = rootURL else {
            loading = false
            return
        }
        do {
            try await client.configure(root: root)
        } catch {
            guard gen == generation else { return }
            self.error = Self.describe(error)
            loading = false
            return
        }
        guard gen == generation else { return }
        let result = await client.inspect()
        guard gen == generation else { return }
        status = result
        loading = false
    }

    /// 使在途异步结果过期。
    private func invalidate() {
        generation += 1
        loading = false
        awaitingBrowser = false
    }

    private func root(for store: ConfigStore) -> URL {
        store.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("extensions/cursor", isDirectory: true)
    }

    private func syncRouter(store: ConfigStore) {
        let enabled = store.config.extensions.connectorSettings(for: settingsKey).enabled
        syncRouter(enabled: enabled, store: store)
    }

    private func syncRouter(enabled: Bool, store: ConfigStore) {
        store.router.setConnectorAvailable(source: source, available: enabled && isConnected)
        // 通用状态信号：设置页/工作区据此重算不可用提示。仅递增 revision，不回调本模型。
        runtime?.connectionChanged()
    }

    /// 由 model 提供的授权浏览器打开闭包：登录时由 client 调用。
    /// 只接受 https 地址（client 另有主机允许列表校验，这里再挡一层）；绝不自动打开，
    /// 只在用户点击「连接」后由 login 触发。
    private static let openBrowser: @Sendable (URL) async throws -> Void = { url in
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw CursorProxyError(message: "登录链接不是有效的 https 地址，已拒绝打开")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            throw CursorProxyError(message: "无法打开浏览器完成登录，请重试")
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
