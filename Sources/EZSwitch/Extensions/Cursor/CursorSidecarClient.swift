import Foundation

// Cursor 连接组件客户端：启动/复用**本扩展自有**的固定版本 helper 进程，并通过其
// localhost 管理/API 接口完成 inspect / login / logout。生产实现为 actor 单例
// `CursorSidecarClient.shared`；测试注入 transport（URLProtocol）与进程 supervisor seam。
//
// 边界：
// - 秘密（management secret / client api-key）只存在于受保护的 runtime YAML 与 actor 内存，
//   绝不写入 AppConfig、环境变量或日志。
// - 只终止自己启动的进程；`requestEndpoint()` 不隐式启动/重启，仅在此前 self running 且
//   已 inspect 出认证状态时返回端点（router 只在 connected 时调用）。

// MARK: - HTTP 传输（可注入）

struct CursorProxyHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

protocol CursorProxyTransport: Sendable {
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CursorProxyHTTPResponse
}

/// 生产实现：一次性 ephemeral 会话，禁系统代理 / cookie / 凭据存储，拒绝 HTTP 重定向
/// （防凭据随重定向泄漏），响应字节收敛到 maxBytes。
final class URLSessionCursorProxyTransport: CursorProxyTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate = CursorProxyRedirectRejector()

    init(configuration: URLSessionConfiguration = URLSessionCursorProxyTransport.isolatedConfiguration()) {
        self.session = URLSession(configuration: configuration)
    }

    static func isolatedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]   // 不走系统代理
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }

    func send(_ request: URLRequest, maxBytes: Int) async throws -> CursorProxyHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse else {
            throw CursorProxyError(message: "连接组件返回了非 HTTP 响应")
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length"), let count = Int(length), count > maxBytes {
            throw CursorProxyError(message: "连接组件响应超过上限")
        }
        var body = Data()
        body.reserveCapacity(min(maxBytes, 64 * 1024))
        for try await byte in bytes {
            body.append(byte)
            if body.count > maxBytes { throw CursorProxyError(message: "连接组件响应超过上限") }
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return CursorProxyHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
    }
}

private final class CursorProxyRedirectRejector: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // 绝不跟随重定向
    }
}

// MARK: - 超时（可注入）

struct CursorProxyTimeouts: Sendable {
    var healthStart: TimeInterval = 10
    var login: TimeInterval = 600
    var loginPoll: TimeInterval = 1.5
    var maxManagementBytes: Int = 1 * 1024 * 1024
}

// MARK: - 目录账户解析

/// management `auth-files` 中与 Cursor 相关的一条记录。tokens 不返回，无需读文件。
struct CursorProxyAuthFile: Sendable {
    let name: String
    let provider: String
    let label: String?
    let email: String?
    let disabled: Bool
    let unavailable: Bool
    let statusMessage: String?

    var isCursor: Bool { provider.caseInsensitiveCompare("cursor") == .orderedSame }
    var usable: Bool { !disabled && !unavailable }
}

// MARK: - 客户端

actor CursorSidecarClient: CursorProxyClientProtocol {
    static let shared = CursorSidecarClient()

    private struct Runtime: Sendable {
        let root: URL
        let configURL: URL
        let authDir: URL
        let homeDir: URL
        let executable: URL
        let port: UInt16
        let managementKey: String
        let apiKey: String
        let process: CursorProxyProcessHandle
        var version: String
        var commit: String?
    }

    private struct Identity: Sendable {
        let version: String
        let commit: String?
    }

    private enum AuthSessionStatus: Sendable {
        case wait
        case ok
        case error(String)
    }

    private let executableURL: URL?
    private let transport: any CursorProxyTransport
    private let supervisor: any CursorProxyProcessSupervising
    private let portProvider: @Sendable () throws -> UInt16
    private let timeouts: CursorProxyTimeouts
    private let supportsCurrentOS: Bool
    private let processRegistry = CursorProxyProcessRegistry()

    private var configuredRoot: URL?
    private var runtime: Runtime?
    private var generation = 0
    private var startTask: Task<Runtime, Error>?
    private var startToken: UUID?
    private var pendingAuthState: String?
    private var lastAuthenticated = false

    init(root: URL? = nil,
         executable: URL? = CursorProxyBinary.discover(),
         transport: any CursorProxyTransport = URLSessionCursorProxyTransport(),
         supervisor: any CursorProxyProcessSupervising = FoundationCursorProxySupervisor(),
         portProvider: @escaping @Sendable () throws -> UInt16 = { try CursorProxyRandom.freePort() },
         timeouts: CursorProxyTimeouts = CursorProxyTimeouts(),
         supportsCurrentOS: Bool = ProcessInfo.processInfo.isOperatingSystemAtLeast(CursorProxyBinary.minimumMacOS)) {
        self.configuredRoot = root?.standardizedFileURL
        self.executableURL = executable
        self.transport = transport
        self.supervisor = supervisor
        self.portProvider = portProvider
        self.timeouts = timeouts
        self.supportsCurrentOS = supportsCurrentOS
    }

    // MARK: 配置

    /// 相同 root 幂等；不同 root 先停掉旧实例，绝不复用旧 config/port/真实账号。
    func configure(root: URL) async throws {
        let standardized = root.standardizedFileURL
        if configuredRoot == standardized { return }
        if configuredRoot != nil { await stop() }
        configuredRoot = standardized
    }

    // MARK: 检查

    func inspect() async -> CursorProxyStatus {
        guard configuredRoot != nil else {
            return status(installed: executableURL != nil, running: false,
                          error: "Cursor 连接组件尚未配置目录。")
        }
        guard supportsCurrentOS else {
            return status(installed: executableURL != nil, running: false,
                          error: "Cursor 连接组件需要 macOS 15 或更高版本。")
        }
        guard executableURL != nil else {
            return status(installed: false, running: false,
                          error: "未找到内置 Cursor 连接组件（\(CursorProxyBinary.bundledName)）。")
        }
        let gen = generation
        do {
            let runtime = try await ensureRunning()
            try await verifyHealthy(runtime)
            if !isCurrent(runtime, gen) { return status(installed: true, running: false, error: nil) }
            let (files, identity) = try await fetchAuthFiles(runtime)
            guard isCurrent(runtime, gen) else { return status(installed: true, running: false, error: nil) }
            if let identity { self.runtime?.version = identity.version; self.runtime?.commit = identity.commit }
            return await evaluate(files: files, runtime: runtime, generation: gen)
        } catch {
            if isCurrentRuntime(gen) { lastAuthenticated = false }
            return status(installed: true, running: runtime?.process.isRunning ?? false,
                          error: Self.shortError(Self.describe(error)))
        }
    }

    private func evaluate(files: [CursorProxyAuthFile], runtime: Runtime, generation gen: Int) async -> CursorProxyStatus {
        let accepted = { self.isCurrent(runtime, gen) }
        let cursorFiles = files.filter { $0.isCursor }
        let usable = cursorFiles.filter { $0.usable }
        let version = runtime.version
        guard !usable.isEmpty else {
            if accepted() { lastAuthenticated = false }
            let error: String?
            if let blocked = cursorFiles.first(where: { !$0.disabled && $0.unavailable }) {
                error = Self.shortError(blocked.statusMessage ?? "") ?? "Cursor 已登录但当前不可用"
            } else {
                error = nil   // 无账户 / 仅 disabled → 明确未登录
            }
            return status(installed: true, running: true, error: error, version: version)
        }
        var models: [String] = []
        var failureMessage: String?
        do {
            models = try await fetchModels(runtime)
            if models.isEmpty { failureMessage = "已登录，但未能获取 Cursor 模型列表。" }
        } catch {
            failureMessage = Self.shortError(Self.describe(error))
        }
        if !accepted() { return status(installed: true, running: false, error: nil) }
        lastAuthenticated = true
        let account = usable.first.flatMap { $0.email ?? $0.label ?? $0.name }
        if failureMessage == nil, !CursorProxyBinary.versionMatchesPinned(version) {
            failureMessage = "连接组件版本为 \(version)，与固定版本 \(CursorProxyBinary.expectedVersion) 不一致。"
        } else if failureMessage == nil, let commit = runtime.commit, !CursorProxyBinary.commitMatchesPinned(commit) {
            failureMessage = "连接组件来源 commit \(commit) 与固定版本不一致。"
        }
        return CursorProxyStatus(installed: true, running: true, authenticated: true, account: account,
                                 models: models, error: failureMessage, version: version)
    }

    // MARK: 端点

    /// 只有在 self running 且已 inspect 出认证状态时返回；绝不隐式启动/重启。
    func requestEndpoint() async throws -> CursorProxyEndpoint {
        guard let runtime, runtime.process.isRunning else {
            throw CursorProxyError(message: "Cursor 连接组件未运行")
        }
        guard lastAuthenticated else { throw CursorProxyError(message: "Cursor 未连接") }
        // health 不足以防端口被他人重绑：再用 management secret 做一次身份校验。
        let identity = try await verifyIdentity(runtime)
        guard CursorProxyBinary.versionMatchesPinned(identity.version) else {
            throw CursorProxyError(message: "连接组件身份校验失败")
        }
        guard runtime.process.isRunning, self.runtime?.process === runtime.process else {
            throw CursorProxyError(message: "Cursor 连接组件已停止")
        }
        return CursorProxyEndpoint(baseURL: Self.baseURL(port: runtime.port), apiKey: runtime.apiKey)
    }

    // MARK: 登录 / 退出

    func login(openURL: @escaping @Sendable (URL) async throws -> Void) async throws {
        try ensureLaunchable()
        let runtime = try await ensureRunning()
        try await verifyHealthy(runtime)
        let gen = generation
        let start = try await requestAuthURL(runtime)
        guard gen == generation, self.runtime?.process === runtime.process else {
            await cancelAuthSession(start.state, runtime)
            throw CancellationError()
        }
        // 拿到 state 后任何分支都必须清理后台 poll（取消/超时/disable/logout）。
        pendingAuthState = start.state
        do {
            guard start.state.hasPrefix("csr-") else { throw CursorProxyError(message: "登录会话状态无效") }
            guard let validated = Self.validatedLoginURL(start.url) else {
                throw CursorProxyError(message: "登录链接校验失败，已拒绝打开")
            }
            try await openURL(validated)
            let deadline = Date().addingTimeInterval(timeouts.login)
            while true {
                try Task.checkCancellation()
                if gen != generation || self.runtime?.process !== runtime.process {
                    throw CancellationError()
                }
                if Date() >= deadline {
                    throw CursorProxyError(message: "登录超时（超过 \(Int(timeouts.login)) 秒），请重试")
                }
                switch try await authStatus(runtime, state: start.state) {
                case .wait:
                    try await Task.sleep(nanoseconds: UInt64(timeouts.loginPoll * 1_000_000_000))
                case .ok:
                    // stop/disable 作废本次登录后，绝不能借 inspect 重启进程“复活”。
                    guard gen == generation, self.runtime?.process === runtime.process else {
                        throw CancellationError()
                    }
                    if pendingAuthState == start.state { pendingAuthState = nil }
                    let status = await inspect()
                    guard status.authenticated, !status.models.isEmpty else {
                        throw CursorProxyError(message: status.error ?? "登录未完成：未检测到 Cursor 账户或模型")
                    }
                    return
                case .error(let message):
                    throw CursorProxyError(message: message)
                }
            }
        } catch {
            if pendingAuthState == start.state { pendingAuthState = nil }
            await cancelAuthSession(start.state, runtime)
            throw error
        }
    }

    /// 只删除本扩展列出的 Cursor 账户（按真实返回文件名），绝不使用 ?all=true。
    func logout() async throws {
        try ensureLaunchable()
        let runtime = try await ensureRunning()
        generation += 1        // 立即作废在途 inspect，避免旧探测把状态“复活”
        lastAuthenticated = false
        if let state = pendingAuthState {
            pendingAuthState = nil
            await cancelAuthSession(state, runtime)
        }
        let listing = try await management(runtime, method: "GET", path: "/v0/management/auth-files")
        guard listing.statusCode == 200 else {
            throw CursorProxyError(message: "读取 Cursor 账户失败（HTTP \(listing.statusCode)）")
        }
        for name in try Self.parseAuthFileListing(from: listing.body).filter({ $0.isCursor }).map(\.name) {
            guard Self.isSafeAuthFileName(name) else {
                throw CursorProxyError(message: "拒绝可疑的凭据文件名")
            }
            let response = try await management(runtime, method: "DELETE", path: "/v0/management/auth-files",
                                                queryItems: [URLQueryItem(name: "name", value: name)])
            guard response.statusCode == 200 || response.statusCode == 404 else {
                throw CursorProxyError(message: "退出 Cursor 登录失败（HTTP \(response.statusCode)）")
            }
        }
        // 不在此处 inspect：由 UI 的 refresh（受 enabled/代次保护）统一刷新，避免与并发 stop 竞争重启。
    }

    // MARK: 停止

    /// 先作废在途 startup / login 并终止自有进程，再尽力取消后台 poll；不阻塞等待长退出。
    func stop() async {
        let state = pendingAuthState
        let runtime = self.runtime
        invalidate()   // 立即：generation++ / 清 runtime / 终止进程，杜绝迟到 auth 保存
        if let state, let runtime {
            await cancelAuthSession(state, runtime)   // best-effort；进程可能正在退出
        }
    }

    /// NSApp 正常退出：同步、有界地终止自有进程（TERM，2 秒后 KILL），不阻塞主线程。
    nonisolated func shutdownImmediately() {
        processRegistry.terminateImmediately()
    }

    private func invalidate() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        startToken = nil
        pendingAuthState = nil
        lastAuthenticated = false
        let runtime = self.runtime
        self.runtime = nil
        if let runtime {
            runtime.process.terminate()
        } else {
            // 仅存在 pending startup（runtime 尚未装回）：登记表里的句柄必须同步终止，绝不留孤儿。
            processRegistry.terminateImmediately()
        }
        processRegistry.set(nil)
    }

    private func isCurrent(_ runtime: Runtime, _ gen: Int) -> Bool {
        generation == gen && self.runtime?.process === runtime.process && runtime.process.isRunning
    }

    private func isCurrentRuntime(_ gen: Int) -> Bool {
        generation == gen && runtime?.process.isRunning == true
    }

    private func ensureLaunchable() throws {
        guard configuredRoot != nil else { throw CursorProxyError(message: "Cursor 连接组件未配置目录") }
        guard supportsCurrentOS else { throw CursorProxyError(message: "Cursor 连接组件需要 macOS 15 或更高版本。") }
        guard executableURL != nil else {
            throw CursorProxyError(message: "未找到内置 Cursor 连接组件（\(CursorProxyBinary.bundledName)）")
        }
    }

    // MARK: 启动（singleflight）

    private func ensureRunning() async throws -> Runtime {
        if let runtime, runtime.process.isRunning { return runtime }
        if let startTask { return try await startTask.value }
        try ensureLaunchable()
        guard let root = configuredRoot, let executable = executableURL else {
            throw CursorProxyError(message: "Cursor 连接组件未配置")
        }
        let layout = CursorProxyLayout(root: root)
        let gen = generation
        let token = UUID()
        let supervisor = self.supervisor
        let transport = self.transport
        let portProvider = self.portProvider
        let timeouts = self.timeouts
        let task = Task<Runtime, Error> {
            try await CursorSidecarClient.launch(layout: layout, executable: executable, supervisor: supervisor,
                                                 transport: transport, portProvider: portProvider,
                                                 timeouts: timeouts, registry: processRegistry)
        }
        startToken = token
        startTask = task
        do {
            let runtime = try await task.value
            if startToken == token { startTask = nil; startToken = nil }
            guard generation == gen else {
                processRegistry.clear(runtime.process)   // stop 已作废：不能把新子进程留下
                runtime.process.terminate()
                throw CursorProxyError(message: "Cursor 连接组件启动已取消")
            }
            self.runtime = runtime
            processRegistry.set(runtime.process)
            return runtime
        } catch {
            if startToken == token { startTask = nil; startToken = nil }
            throw error
        }
    }

    private nonisolated static func launch(layout: CursorProxyLayout, executable: URL,
                                          supervisor: any CursorProxyProcessSupervising,
                                          transport: any CursorProxyTransport,
                                          portProvider: @Sendable () throws -> UInt16,
                                          timeouts: CursorProxyTimeouts,
                                          registry: CursorProxyProcessRegistry) async throws -> Runtime {
        let managementKey = CursorProxyRandom.token()
        let apiKey = CursorProxyRandom.token()
        var lastError: Error = CursorProxyError(message: "Cursor 连接组件启动失败")
        // 端口是 bind(0)+close 后取得的，存在被抢占的竞态：用 health + management secret 认证
        // 确认真是自有进程且身份匹配，失败换端口重试（最多 3 次）。
        for _ in 0..<3 {
            try Task.checkCancellation()
            let port = try portProvider()
            let config = CursorProxyConfig(port: port, managementSecret: managementKey, apiKey: apiKey,
                                           authDir: layout.authDir)
            try layout.writeConfig(config)
            let environment = CursorProxyEnvironment.sanitized(ProcessInfo.processInfo.environment,
                                                               home: layout.homeDir, temp: layout.runtimeDir)
            let spec = CursorProxyLaunchSpec(executableURL: executable,
                                             arguments: ["-config", layout.configURL.path],
                                             environment: environment,
                                             currentDirectoryURL: layout.runtimeDir)
            let handle = try supervisor.launch(spec)
            // 启动即登记：app 在 waitReady 期间退出也能同步终止，绝不留孤儿。
            registry.set(handle)
            do {
                let identity = try await waitReady(port: port, managementKey: managementKey,
                                                   transport: transport, timeout: timeouts.healthStart)
                return Runtime(root: layout.root, configURL: layout.configURL, authDir: layout.authDir,
                               homeDir: layout.homeDir, executable: executable, port: port,
                               managementKey: managementKey, apiKey: apiKey, process: handle,
                               version: identity.version, commit: identity.commit)
            } catch {
                registry.clear(handle)
                handle.terminate()
                lastError = error
                if !handle.isRunning { break }   // 进程已退出：换端口无意义
            }
        }
        throw lastError
    }

    private nonisolated static func waitReady(port: UInt16, managementKey: String,
                                              transport: any CursorProxyTransport,
                                              timeout: TimeInterval) async throws -> Identity {
        var lastError: Error = CursorProxyError(message: "Cursor 连接组件启动超时")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let health = try await transport.send(
                    makeRequest(port: port, path: "/healthz", method: "GET"), maxBytes: 64 * 1024)
                guard health.statusCode == 200 else {
                    lastError = CursorProxyError(message: "连接组件健康检查失败（HTTP \(health.statusCode)）")
                    try await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                let probe = try await transport.send(
                    authorized(makeRequest(port: port, path: "/v0/management/auth-files", method: "GET"),
                               key: managementKey), maxBytes: 1 * 1024 * 1024)
                if probe.statusCode == 200, let identity = identity(from: probe),
                   CursorProxyBinary.versionMatchesPinned(identity.version),
                   CursorProxyBinary.commitMatchesPinned(identity.commit ?? "") {
                    return identity
                }
                lastError = CursorProxyError(message: "连接组件身份校验失败或管理接口未就绪（HTTP \(probe.statusCode)）")
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw lastError
    }

    // MARK: 接口调用

    private func verifyHealthy(_ runtime: Runtime) async throws {
        let response = try await transport.send(
            Self.makeRequest(port: runtime.port, path: "/healthz", method: "GET"), maxBytes: 64 * 1024)
        guard response.statusCode == 200 else {
            throw CursorProxyError(message: "Cursor 连接组件健康检查失败（HTTP \(response.statusCode)）")
        }
    }

    private func verifyIdentity(_ runtime: Runtime) async throws -> Identity {
        try await verifyHealthy(runtime)
        let probe = try await management(runtime, method: "GET", path: "/v0/management/auth-files")
        guard probe.statusCode == 200, let identity = Self.identity(from: probe) else {
            throw CursorProxyError(message: "连接组件管理接口认证失败（HTTP \(probe.statusCode)）")
        }
        return identity
    }

    private func management(_ runtime: Runtime, method: String, path: String,
                            queryItems: [URLQueryItem] = []) async throws -> CursorProxyHTTPResponse {
        let request = Self.authorized(
            Self.makeRequest(port: runtime.port, path: path, method: method, queryItems: queryItems),
            key: runtime.managementKey)
        return try await transport.send(request, maxBytes: timeouts.maxManagementBytes)
    }

    private func fetchAuthFiles(_ runtime: Runtime) async throws -> ([CursorProxyAuthFile], Identity?) {
        let response = try await management(runtime, method: "GET", path: "/v0/management/auth-files")
        guard response.statusCode == 200 else {
            throw CursorProxyError(message: "读取 Cursor 账户失败（HTTP \(response.statusCode)）")
        }
        return (try Self.parseAuthFileListing(from: response.body), Self.identity(from: response))
    }

    private func fetchModels(_ runtime: Runtime) async throws -> [String] {
        let request = Self.authorized(
            Self.makeRequest(port: runtime.port, path: "/v1/models", method: "GET"), key: runtime.apiKey)
        let response = try await transport.send(request, maxBytes: timeouts.maxManagementBytes)
        guard response.statusCode == 200 else {
            throw CursorProxyError(message: "Cursor 模型目录请求失败（HTTP \(response.statusCode)）")
        }
        return Self.parseModelIDs(from: response.body)
    }

    private func requestAuthURL(_ runtime: Runtime) async throws -> (url: String, state: String) {
        let response = try await management(runtime, method: "GET", path: "/v0/management/cursor-auth-url")
        guard response.statusCode == 200 else {
            throw CursorProxyError(message: "无法发起 Cursor 登录（HTTP \(response.statusCode)）")
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              (object["status"] as? String) == "ok",
              let url = object["url"] as? String, !url.isEmpty,
              let state = object["state"] as? String, !state.isEmpty else {
            throw CursorProxyError(message: "无法发起 Cursor 登录：响应无效")
        }
        return (url, state)
    }

    private func authStatus(_ runtime: Runtime, state: String) async throws -> AuthSessionStatus {
        // 无 state 会误判 ok，必须带非空 state。
        guard !state.isEmpty else { throw CursorProxyError(message: "登录会话状态缺失") }
        let response = try await management(runtime, method: "GET", path: "/v0/management/get-auth-status",
                                            queryItems: [URLQueryItem(name: "state", value: state)])
        guard response.statusCode == 200 else {
            throw CursorProxyError(message: "登录状态查询失败（HTTP \(response.statusCode)）")
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let status = object["status"] as? String else {
            throw CursorProxyError(message: "登录状态响应无效")
        }
        switch status {
        case "wait", "pending": return .wait
        case "ok": return .ok
        case "error": return .error(Self.shortError(object["error"] as? String) ?? "Cursor 登录失败")
        default: throw CursorProxyError(message: "登录状态响应无效")
        }
    }

    /// 取消后台 poll。总是尝试 DELETE（独立 unstructured Task，不受调用方取消影响），
    /// 避免 disabled / 取消后迟到保存 auth。
    private func cancelAuthSession(_ state: String, _ runtime: Runtime) async {
        guard !state.isEmpty, runtime.process.isRunning else { return }
        let request = Self.authorized(
            Self.makeRequest(port: runtime.port, path: "/v0/management/oauth-session", method: "DELETE",
                             queryItems: [URLQueryItem(name: "state", value: state)]),
            key: runtime.managementKey)
        let transport = self.transport
        let maxBytes = timeouts.maxManagementBytes
        await Task { _ = try? await transport.send(request, maxBytes: maxBytes) }.value
    }

    // MARK: 纯函数（可测）

    static func baseURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    /// 只接受 https + 精确 host cursor.com + path /loginDeepControl + 无 userinfo。
    static func validatedLoginURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host == "cursor.com",
              components.user == nil, components.password == nil,
              components.path == "/loginDeepControl" else { return nil }
        return url
    }

    private static func identity(from response: CursorProxyHTTPResponse) -> Identity? {
        guard let version = response.headerValue("X-CPA-VERSION")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        let raw = response.headerValue("X-CPA-COMMIT")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Identity(version: version, commit: (raw?.isEmpty ?? true) ? nil : raw)
    }

    /// 严格解析：响应不是含 `files` 数组的对象即报错（登出绝不把无效 listing 当成功）。
    static func parseAuthFileListing(from data: Data) throws -> [CursorProxyAuthFile] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [[String: Any]] else {
            throw CursorProxyError(message: "连接组件账户列表响应无效")
        }
        return files.compactMap { entry in
            let provider = (entry["type"] as? String) ?? (entry["provider"] as? String) ?? ""
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            return CursorProxyAuthFile(
                name: name, provider: provider,
                label: entry["label"] as? String,
                email: entry["email"] as? String,
                disabled: (entry["disabled"] as? Bool) ?? false,
                unavailable: (entry["unavailable"] as? Bool) ?? false,
                statusMessage: entry["status_message"] as? String)
        }
    }

    /// basename 校验：拒绝空、路径分隔、`..`，只允许纯文件名。
    static func isSafeAuthFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent else { return false }
        return !name.contains("/") && !name.contains("\\") && !name.contains("..") && name != "."
    }

    static func parseModelIDs(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var ids: [String] = []
        for entry in entries {
            guard (entry["owned_by"] as? String)?.caseInsensitiveCompare("cursor") == .orderedSame,
                  let id = entry["id"] as? String, !id.isEmpty,
                  seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    static func shortError(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: 请求构造

    private nonisolated static func makeRequest(port: UInt16, path: String, method: String,
                                                queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 10
        return request
    }

    private nonisolated static func authorized(_ request: URLRequest, key: String) -> URLRequest {
        var request = request
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func status(installed: Bool, running: Bool, authenticated: Bool = false,
                        account: String? = nil, models: [String] = [], error: String?,
                        version: String? = nil) -> CursorProxyStatus {
        CursorProxyStatus(installed: installed, running: running, authenticated: authenticated,
                          account: account, models: models, error: error, version: version)
    }
}
