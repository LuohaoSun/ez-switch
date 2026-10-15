import Foundation
import Testing
@testable import EZSwitch

/// 让 `inspect()` 可被挂起的门闩，用于制造“在途探测”场景（stale 代次）。
actor InspectGate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func close() { isOpen = false }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Cursor 运行时控制器（CursorConnectionModel）与目录分支的聚焦测试。
/// 不启动真实 sidecar：注入脚本化 fake 客户端，绝不真正登录/打开浏览器。
@MainActor
@Suite("Cursor connection controller")
struct CursorConnectionModelTests {

    // MARK: 夹具

    /// 脚本化 proxy 客户端：可设定探测结果与登录/退出/停止结果，并记录调用与 configure 根目录。
    final class FakeCursorProxyClient: CursorProxyClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _status: CursorProxyStatus
        private var _configureRoots: [URL] = []
        private var _inspectCount = 0
        private var _loginCount = 0
        private var _logoutCount = 0
        private var _stopCount = 0
        private var _capturedOpenURL: (@Sendable (URL) async throws -> Void)?
        private var _configureError: Error?
        private var _loginError: Error?
        private var _logoutError: Error?

        /// 挂起门；默认打开，inspect 立即返回。
        let inspectGate = InspectGate()

        init(status: CursorProxyStatus) { self._status = status }

        var status: CursorProxyStatus {
            get { lock.lock(); defer { lock.unlock() }; return _status }
            set { lock.lock(); _status = newValue; lock.unlock() }
        }
        var configureRoots: [URL] { lock.lock(); defer { lock.unlock() }; return _configureRoots }
        var inspectCount: Int { lock.lock(); defer { lock.unlock() }; return _inspectCount }
        var loginCount: Int { lock.lock(); defer { lock.unlock() }; return _loginCount }
        var logoutCount: Int { lock.lock(); defer { lock.unlock() }; return _logoutCount }
        var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
        var capturedOpenURL: (@Sendable (URL) async throws -> Void)? {
            lock.lock(); defer { lock.unlock() }; return _capturedOpenURL
        }
        var configureError: Error? {
            get { lock.lock(); defer { lock.unlock() }; return _configureError }
            set { lock.lock(); _configureError = newValue; lock.unlock() }
        }
        var loginError: Error? {
            get { lock.lock(); defer { lock.unlock() }; return _loginError }
            set { lock.lock(); _loginError = newValue; lock.unlock() }
        }
        var logoutError: Error? {
            get { lock.lock(); defer { lock.unlock() }; return _logoutError }
            set { lock.lock(); _logoutError = newValue; lock.unlock() }
        }

        func configure(root: URL) async throws {
            lock.lock(); _configureRoots.append(root); let error = _configureError; lock.unlock()
            if let error { throw error }
        }

        func inspect() async -> CursorProxyStatus {
            lock.lock(); _inspectCount += 1; lock.unlock()
            await inspectGate.wait()
            return status
        }

        func login(openURL: @escaping @Sendable (URL) async throws -> Void) async throws {
            lock.lock(); _loginCount += 1; _capturedOpenURL = openURL; let error = _loginError
            lock.unlock()
            if let error { throw error }
        }

        func logout() async throws {
            lock.lock(); _logoutCount += 1; let error = _logoutError; lock.unlock()
            if let error { throw error }
        }

        func stop() async {
            lock.lock(); _stopCount += 1; lock.unlock()
        }
    }

    private func status(installed: Bool = true, running: Bool = true, authenticated: Bool = true,
                        account: String? = "me@cursor.com", models: [String] = ["gpt-4", "claude"],
                        error: String? = nil, version: String? = "1.2.3") -> CursorProxyStatus {
        CursorProxyStatus(installed: installed, running: running, authenticated: authenticated,
                          account: account, models: models, error: error, version: version)
    }

    private func makeStore(enabled: Bool) throws -> (store: ConfigStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        var config = AppConfig(port: 8788, remotes: [], fakes: [])
        config.extensions.cursorConnector =
            CursorConnectorSettings(enabled: enabled, providerName: nil, providerAdded: false)
        try JSONEncoder().encode(config).write(to: url)
        return (ConfigStore(configURL: url), dir)
    }

    private func cursorRemote(_ provider: String = "Cursor", _ model: String = "gpt-4") -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "", model: model,
                    extraHeaders: [:],
                    apiEndpoints: APIEndpointSettings(chat: .disabled, responses: .disabled,
                                                      messages: .disabled),
                    source: .cursorProxy)
    }

    /// 让步直到条件成立或超时；用于等待模型内部派发的 Task 生效。
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
    }

    /// 通用 Router 就绪读取：测试经通用接口，不依赖任何专有 Router API。
    private func connectorReady(_ store: ConfigStore) -> Bool {
        store.router.connectorAvailable(source: .cursorProxy)
    }

    /// 预期 configure 根目录：config.json 同级的 extensions/cursor（本扩展独立 auth/runtime）。
    /// 与 model 一致用 isDirectory: true；比较时统一走 standardizedFileURL.path，
    /// 消除 URL 目录尾斜杠表示的差异而不放宽路径隔离要求。
    private func expectedRoot(_ store: ConfigStore) -> URL {
        store.configURL.deletingLastPathComponent()
            .appendingPathComponent("extensions/cursor", isDirectory: true)
    }

    /// URL 语义等值：统一标准化路径，忽略目录尾斜杠表示。
    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    /// 注入用连接器定义：只关心取目录闭包，转发闭包不会被调用。
    private func connectorDefinition(
        fetchModels: @escaping @Sendable () async throws -> [String]) -> ConnectorDefinition {
        ConnectorDefinition(
            source: .cursorProxy, settingsKey: "cursorConnector", displayName: "Cursor",
            endpoints: [.chat, .responses],
            forward: { _ in throw CursorConnectorError(reason: "unused in catalog test") },
            fetchModels: fetchModels)
    }

    // MARK: 连接判定

    @Test
    func connectedRequiresAllConditions() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let model = CursorConnectionModel(client: FakeCursorProxyClient(status: status()))
        await model.refresh(store: ctx.store)
        #expect(model.isConnected)

        // 任一条件不满足即不连接。
        let cases: [(String, CursorProxyStatus)] = [
            ("未安装", status(installed: false)),
            ("未运行", status(running: false)),
            ("未认证", status(authenticated: false)),
            ("无模型", status(models: [])),
            ("探测报错", status(error: "model list failed")),
        ]
        for (name, s) in cases {
            let m = CursorConnectionModel(client: FakeCursorProxyClient(status: s))
            await m.refresh(store: ctx.store)
            #expect(!m.isConnected, "应判为未连接：\(name)")
        }
    }

    @Test
    func presentationMapsRealStatesWithoutFabrication() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let store = ctx.store

        let notInstalled = CursorConnectionModel(
            client: FakeCursorProxyClient(status: status(installed: false, running: false,
                                                         authenticated: false, account: nil, models: [])))
        await notInstalled.refresh(store: store)
        #expect(notInstalled.presentation == .notInstalled)

        let notRunning = CursorConnectionModel(
            client: FakeCursorProxyClient(status: status(running: false, authenticated: false, account: nil)))
        await notRunning.refresh(store: store)
        if case .needsAttention = notRunning.presentation {
        } else {
            Issue.record("组件未运行应判为 needsAttention，实际 \(notRunning.presentation)")
        }

        let unauthenticated = CursorConnectionModel(
            client: FakeCursorProxyClient(status: status(authenticated: false, account: nil)))
        await unauthenticated.refresh(store: store)
        #expect(unauthenticated.presentation == .notAuthenticated)

        let erroring = CursorConnectionModel(
            client: FakeCursorProxyClient(status: status(error: "proxy crashed")))
        await erroring.refresh(store: store)
        #expect(erroring.presentation == .needsAttention("proxy crashed"))

        // 已登录但模型枚举失败 → 需重新连接，绝不伪造账号/模型。
        let needsReauth = CursorConnectionModel(
            client: FakeCursorProxyClient(status: status(account: "me@cursor.com", models: [])))
        await needsReauth.refresh(store: store)
        if case .needsAttention = needsReauth.presentation {
        } else {
            Issue.record("空模型列表应判为 needsAttention，实际 \(needsReauth.presentation)")
        }
        #expect(!needsReauth.isConnected)
        #expect(needsReauth.models.isEmpty)

        let connected = CursorConnectionModel(client: FakeCursorProxyClient(status: status()))
        await connected.refresh(store: store)
        #expect(connected.presentation == .connected)
        #expect(connected.account == "me@cursor.com")
        #expect(connected.version == "1.2.3")
    }

    // MARK: router 就绪同步

    @Test
    func refreshSyncsRouterReadinessOnlyWhenEnabled() async throws {
        let enabled = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: enabled.dir) }
        let model = CursorConnectionModel(client: FakeCursorProxyClient(status: status()))
        await model.refresh(store: enabled.store)
        #expect(model.isReady(in: enabled.store))
        #expect(enabled.store.router.connectorAvailable(source: .cursorProxy))

        let disabled = try makeStore(enabled: false)
        defer { try? FileManager.default.removeItem(at: disabled.dir) }
        let disabledFake = FakeCursorProxyClient(status: status())
        let m2 = CursorConnectionModel(client: disabledFake)
        await m2.refresh(store: disabled.store)
        #expect(!m2.isReady(in: disabled.store))
        #expect(!disabled.store.router.connectorAvailable(source: .cursorProxy))
        // 禁用时 refresh 不 configure/inspect：不偷偷启动 helper。
        #expect(disabledFake.inspectCount == 0)
        #expect(disabledFake.configureRoots.isEmpty)
    }

    // MARK: 启停

    @Test
    func disableImmediatelyMakesUnavailableAndStops() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        let model = CursorConnectionModel(client: fake)
        await model.refresh(store: ctx.store)
        #expect(connectorReady(ctx.store))

        model.setEnabled(false, store: ctx.store)
        // 同步可见：立即不可用、状态清空。
        #expect(!ctx.store.config.extensions.cursorConnector.enabled)
        #expect(!connectorReady(ctx.store))
        #expect(model.status == nil)
        #expect(!model.isConnected)
        // 异步停止：只停自有 sidecar，不动正式服务（作用域由 configure 根目录限定）。
        await waitUntil { fake.stopCount == 1 }
        #expect(fake.stopCount == 1)
        #expect(fake.configureRoots.last.map { samePath($0, expectedRoot(ctx.store)) } == true)
    }

    @Test
    func enableTriggersRefreshOnce() async throws {
        let ctx = try makeStore(enabled: false)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        let model = CursorConnectionModel(client: fake)

        model.setEnabled(true, store: ctx.store)
        #expect(ctx.store.config.extensions.cursorConnector.enabled)
        await waitUntil { model.status != nil }
        #expect(model.isConnected)
        #expect(connectorReady(ctx.store))
        #expect(fake.inspectCount == 1)
        #expect(fake.configureRoots.count == 1
                && samePath(fake.configureRoots[0], expectedRoot(ctx.store)))
    }

    /// off→on：先等旧 disable 的停止完成再刷新新代次，避免两个 Task 各停各的。
    @Test
    func reenableWaitsForPriorStopBeforeRefresh() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        let model = CursorConnectionModel(client: fake)

        model.setEnabled(false, store: ctx.store)
        model.setEnabled(true, store: ctx.store)
        await waitUntil { model.isConnected }
        #expect(fake.stopCount == 1)
        #expect(connectorReady(ctx.store))
    }

    /// 禁用时直接 refresh：入口即 guard enabled，不 configure/inspect，helper 不启动。
    @Test
    func refreshOnDisabledStoreDoesNotStartHelper() async throws {
        let ctx = try makeStore(enabled: false)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        let model = CursorConnectionModel(client: fake)

        await model.refresh(store: ctx.store)
        #expect(fake.inspectCount == 0)
        #expect(fake.configureRoots.isEmpty)
        #expect(!model.isConnected)
        #expect(!connectorReady(ctx.store))
    }

    /// off→on→off：启用 Task 等待旧 stop 期间又被关闭，恢复后不得迟到刷新启动 helper。
    @Test
    func rapidOffOnOffDoesNotStartHelper() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        let model = CursorConnectionModel(client: fake)

        model.setEnabled(false, store: ctx.store)
        model.setEnabled(true, store: ctx.store)
        model.setEnabled(false, store: ctx.store)
        for _ in 0..<100 { await Task.yield() }

        #expect(!ctx.store.config.extensions.cursorConnector.enabled)
        #expect(fake.inspectCount == 0)
        #expect(model.status == nil)
        #expect(!connectorReady(ctx.store))
    }

    // MARK: 登录 / 退出

    /// login 失败：清 status、置 error、结束 loading；presentation 必须是可重试的
    /// needsAttention，而不是永远 loading、没有重连按钮。
    @Test
    func connectFailureShowsNeedsAttentionNotLoading() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status(authenticated: false, account: nil))
        fake.loginError = NSError(domain: "test", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "登录被拒"])
        let model = CursorConnectionModel(client: fake)
        await model.refresh(store: ctx.store)

        await model.connect(store: ctx.store)
        #expect(model.status == nil)
        #expect(model.error != nil)
        #expect(!model.loading)
        #expect(model.presentation == .needsAttention("登录被拒"))
        #expect(model.presentation != .loading)
    }

    /// configure 失败（当前运行内）：不得停在误导性的 loading，must 给 needsAttention。
    @Test
    func configureFailureShowsNeedsAttentionNotLoading() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        fake.configureError = CursorProxyError(message: "组件加载失败")
        let model = CursorConnectionModel(client: fake)

        await model.refresh(store: ctx.store)
        #expect(model.status == nil)
        #expect(!model.loading)
        #expect(model.presentation == .needsAttention("组件加载失败"))
    }

    @Test
    func connectFailureClearsOldConnectedState() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        let model = CursorConnectionModel(client: fake)
        await model.refresh(store: ctx.store)
        #expect(model.isConnected)

        fake.loginError = NSError(domain: "test", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "登录被拒"])
        await model.connect(store: ctx.store)
        #expect(!model.isConnected)
        #expect(model.error != nil)
        #expect(!connectorReady(ctx.store))
    }

    @Test
    func connectSuccessRefreshesToConnected() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status(authenticated: false, account: nil))
        let model = CursorConnectionModel(client: fake)
        await model.refresh(store: ctx.store)
        #expect(!model.isConnected)

        fake.status = status()
        await model.connect(store: ctx.store)
        #expect(model.isConnected)
        #expect(connectorReady(ctx.store))
        #expect(fake.loginCount == 1)
        // 登录由 client 经 model 提供的闭包打开浏览器；未成功回调前不自动打开。
        #expect(fake.capturedOpenURL != nil)
    }

    /// model 提供的浏览器打开闭包只接受 https，拒绝非法地址；测试只验证拒绝分支，不打开浏览器。
    @Test
    func loginOpenURLClosureRejectsNonHTTPS() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status(authenticated: false, account: nil))
        let model = CursorConnectionModel(client: fake)
        await model.refresh(store: ctx.store)
        await model.connect(store: ctx.store)

        let opener = try #require(fake.capturedOpenURL)
        await #expect(throws: (any Error).self) {
            try await opener(URL(string: "http://evil.example/login")!)
        }
    }

    @Test
    func disconnectClearsReadyBeforeLogoutCompletes() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        let model = CursorConnectionModel(client: fake)
        await model.refresh(store: ctx.store)
        #expect(model.addProvider(store: ctx.store) == nil)
        #expect(connectorReady(ctx.store))

        fake.status = status(authenticated: false, account: nil, models: [])
        await model.disconnect(store: ctx.store)
        #expect(fake.logoutCount == 1)
        #expect(fake.stopCount == 0)   // 退出登录不停止进程，仅清本扩展 auth。
        #expect(!model.isConnected)
        #expect(!connectorReady(ctx.store))
        // 供应商、模型与路由绑定保留。
        #expect(ctx.store.config.extensions.cursorConnector.providerAdded)
        #expect(!ctx.store.config.remotes.filter { $0.source == .cursorProxy }.isEmpty)
    }

    // MARK: 添加到供应商

    @Test
    func addProviderBindsInspectedModelsAtomically() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let models = ["gpt-4", "claude", "cursor-small"]
        let model = CursorConnectionModel(client: FakeCursorProxyClient(status: status(models: models)))
        await model.refresh(store: ctx.store)

        #expect(model.addProvider(store: ctx.store) == nil)
        #expect(ctx.store.config.extensions.cursorConnector.providerAdded)
        #expect(ctx.store.config.extensions.cursorConnector.providerName == "Cursor")
        let records = ctx.store.config.remotes.filter { $0.source == .cursorProxy }
        #expect(Set(records.map(\.model)) == Set(models))
        // 记录必须是空白 native 配置：无 Key、端点全关（不伪造地址）。
        #expect(records.allSatisfy { $0.apiKey.isEmpty })
        #expect(records.allSatisfy { $0.apiEndpoints.enabledKinds.isEmpty })
        #expect(connectorReady(ctx.store))
    }

    @Test
    func addProviderRejectedWhenNotConnected() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let model = CursorConnectionModel(
            client: FakeCursorProxyClient(status: status(authenticated: false, account: nil)))
        await model.refresh(store: ctx.store)

        #expect(model.addProvider(store: ctx.store) != nil)
        #expect(!ctx.store.config.extensions.cursorConnector.providerAdded)
        #expect(ctx.store.config.remotes.isEmpty)
    }

    /// 禁用后的 stale 合法连接状态不得再写入供应商：复用 isReady(enabled && connected)。
    @Test
    func addProviderRequiresEnabledEvenWithStaleConnectedStatus() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let model = CursorConnectionModel(client: FakeCursorProxyClient(status: status()))
        await model.refresh(store: ctx.store)
        #expect(model.isConnected)

        // 模型未 attach，直接在 store 关闭：status 保留为 stale 已连接。
        ctx.store.setCursorConnectorEnabled(false)
        #expect(model.isConnected)
        #expect(!model.isReady(in: ctx.store))

        #expect(model.addProvider(store: ctx.store) != nil)
        #expect(!ctx.store.config.extensions.cursorConnector.providerAdded)
        #expect(ctx.store.config.remotes.isEmpty)
    }

    @Test
    func catalogRejectsConnectorRequestAndFetchesViaRegistry() async throws {
        let remote = cursorRemote("Cursor", "gpt-4")
        // 连接器记录没有可查询的接口地址：请求解析被拒绝。
        #expect(throws: ProviderModelCatalog.CatalogError.self) {
            try ProviderModelCatalog.request(for: remote)
        }

        // 注册表缺该 source → 明确失败，绝不伪造地址。
        await #expect(throws: (any Error).self) {
            try await ProviderModelCatalog.fetch(for: remote, registry: ExtensionRegistry(connectors: []))
        }

        // 注入连接器（fake 取目录闭包 seam）→ 去重排序后返回。
        let registry = ExtensionRegistry(connectors: [connectorDefinition(fetchModels: { ["b", "a", "a"] })])
        let models = try await ProviderModelCatalog.fetch(for: remote, registry: registry)
        #expect(models == ["a", "b"])

        // 连接器抛错 → 语义透传，不伪造模型。
        let offline = ExtensionRegistry(connectors: [connectorDefinition(fetchModels: {
            throw CursorConnectorError(reason: "offline")
        })])
        await #expect(throws: (any Error).self) {
            try await ProviderModelCatalog.fetch(for: remote, registry: offline)
        }
    }

    // MARK: 目录刷新状态闭环

    /// 禁用时目录明确不可用，且**不** configure/inspect（不偷偷启动 sidecar）。
    @Test
    func catalogDisabledRejectsWithoutStarting() async throws {
        let ctx = try makeStore(enabled: false)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        let model = CursorConnectionModel(client: fake)
        model.attach(to: ctx.store)   // 禁用：不自动刷新
        #expect(!connectorReady(ctx.store))

        await #expect(throws: (any Error).self) { _ = try await model.catalog() }
        #expect(fake.inspectCount == 0)
        #expect(fake.configureRoots.isEmpty)
        #expect(!connectorReady(ctx.store))
    }

    /// 目录刷新入口在启用后必须同步真实连接状态与通用 runtime，并令 router 就绪，
    /// 避免“目录取到、可用性却过期”。
    @Test
    func catalogSyncsConnectionStatusAndRuntimeReadiness() async throws {
        let ctx = try makeStore(enabled: false)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let runtime = ExtensionRuntime()
        let fake = FakeCursorProxyClient(status: status(models: ["b", "a"]))
        let model = CursorConnectionModel(client: fake)
        model.attach(to: ctx.store, runtime: runtime)
        let baselineRevision = runtime.revision
        #expect(!connectorReady(ctx.store))

        model.setEnabled(true, store: ctx.store)
        await waitUntil { model.isConnected }
        let models = try await model.catalog()
        #expect(Set(models) == ["a", "b"])
        #expect(model.isConnected)
        #expect(connectorReady(ctx.store))
        #expect(runtime.revision > baselineRevision)
    }

    // MARK: configure 根目录隔离

    /// 每次 refresh/connect/disconnect/stop 都先 configure 到本扩展独立目录，
    /// 不同 store 得到各自 config.json 同级的 extensions/cursor，绝不指向真实 CLI 目录。
    @Test
    func configureRootIsIsolatedPerStore() async throws {
        let a = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: a.dir) }
        let b = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let fake = FakeCursorProxyClient(status: status())
        let model = CursorConnectionModel(client: fake)

        await model.refresh(store: a.store)
        await model.refresh(store: b.store)

        let roots = fake.configureRoots
        #expect(roots.count == 2)
        #expect(samePath(roots[0], expectedRoot(a.store)))
        #expect(samePath(roots[1], expectedRoot(b.store)))
        #expect(!samePath(roots[0], roots[1]))
        #expect(roots.allSatisfy {
            $0.lastPathComponent == "cursor"
                && $0.deletingLastPathComponent().lastPathComponent == "extensions"
        })
    }

    // MARK: 代次防迟到

    /// 在途 inspect 返回时代次已作废（disable）：绝不覆盖刚清空的不可用状态。
    @Test
    func staleInspectDoesNotOverrideDisable() async throws {
        let ctx = try makeStore(enabled: true)
        defer { try? FileManager.default.removeItem(at: ctx.dir) }
        let fake = FakeCursorProxyClient(status: status())
        await fake.inspectGate.close()   // 挂起 inspect
        let model = CursorConnectionModel(client: fake)

        let task = Task { await model.refresh(store: ctx.store) }
        await waitUntil { fake.inspectCount == 1 }

        model.setEnabled(false, store: ctx.store)
        #expect(model.status == nil)
        #expect(!connectorReady(ctx.store))

        await fake.inspectGate.open()    // 放行迟到的 inspect
        await task.value
        #expect(model.status == nil)
        #expect(!model.isConnected)
        #expect(!connectorReady(ctx.store))
    }
}
