import Foundation
import Testing
@testable import EZSwitch

// MARK: - 共享夹具（文件级，避免 nested type 调用外层实例方法）

private final class MockURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
    }
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> Reply)?
    private static var storedRequests: [URLRequest] = []
    static var handler: ((URLRequest) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); storedHandler = newValue; lock.unlock() }
    }
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return storedRequests
    }
    static func reset(handler: ((URLRequest) -> Reply)? = nil) {
        lock.lock(); storedHandler = handler; storedRequests = []; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        MockURLProtocol.lock.lock(); MockURLProtocol.storedRequests.append(request)
        MockURLProtocol.lock.unlock()
        guard let handler = MockURLProtocol.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let reply = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockJSON(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
}

private func mockReply(status: Int = 200,
                       headers: [String: String] = ["Content-Type": "application/json"],
                       body: Data = Data()) -> MockURLProtocol.Reply {
    MockURLProtocol.Reply(status: status, headers: headers, body: body)
}

/// Cursor sidecar 客户端：可执行文件发现、隔离 YAML/权限、环境白名单、inspect 账户过滤、
/// 启动竞态重试与身份校验、login 取消/超时/恶意 URL、logout 只删自有账户、stop 作废在途。
/// 注入 URLProtocol 传输与假进程 supervisor（真实 /bin/sleep），不接触真实 helper、不登录。
@Suite("Cursor sidecar client", .serialized)
struct CursorSidecarClientTests {

    final class Ref<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    }

    /// 路由假 helper。auth-files 头携带固定 version/commit，便于身份与竞态测试。
    struct Router {
        var version = "8.0.28-2"
        var commit: String? = "67eadafb4"
        var authFiles: [[String: Any]] = []
        var models: [String] = []
        var authStatuses: [String] = ["wait", "ok"]
        var authStatusError: String?
        var authURL = "https://cursor.com/loginDeepControl?x=1"
        var authState = "csr-abcd"
        var healthStatus = 200
        var managementStatus = 200
        var authFilesBody: Data?
        let statusIndex = Ref(0)

        fileprivate func handle(_ request: URLRequest) -> MockURLProtocol.Reply {
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            switch path {
            case "/healthz":
                return mockReply(status: healthStatus, body: mockJSON(["status": "ok"]))
            case "/v0/management/auth-files":
                if method == "DELETE" { return mockReply(body: mockJSON(["status": "ok"])) }
                var headers = ["Content-Type": "application/json"]
                headers["X-CPA-VERSION"] = version
                if let commit { headers["X-CPA-COMMIT"] = commit }
                return mockReply(status: managementStatus, headers: headers,
                                 body: authFilesBody ?? mockJSON(["files": authFiles]))
            case "/v1/models":
                return mockReply(body: mockJSON(["data": models.map { ["id": $0, "owned_by": "cursor"] }]))
            case "/v0/management/cursor-auth-url":
                return mockReply(body: mockJSON(["status": "ok", "url": authURL, "state": authState, "flow": "device"]))
            case "/v0/management/get-auth-status":
                if let authStatusError { return mockReply(body: mockJSON(["status": "error", "error": authStatusError])) }
                let index = statusIndex.get(); statusIndex.set(index + 1)
                return mockReply(body: mockJSON(["status": authStatuses[min(index, authStatuses.count - 1)]]))
            case "/v0/management/oauth-session":
                return mockReply(body: mockJSON(["status": "ok", "cancelled": true]))
            default:
                return mockReply(status: 404, body: mockJSON(["error": "not found"]))
            }
        }
    }

    final class FakeSupervisor: CursorProxyProcessSupervising, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [CursorProxyLaunchSpec] = []
        private var handles: [CursorProxyProcessHandle] = []
        private var failure: Error?
        var failWith: Error? {
            get { lock.lock(); defer { lock.unlock() }; return failure }
            set { lock.lock(); failure = newValue; lock.unlock() }
        }
        var specs: [CursorProxyLaunchSpec] { lock.lock(); defer { lock.unlock() }; return recorded }
        var launchCount: Int { specs.count }
        var runningCount: Int {
            lock.lock(); defer { lock.unlock() }
            return handles.filter { $0.isRunning }.count
        }

        func launch(_ spec: CursorProxyLaunchSpec) throws -> CursorProxyProcessHandle {
            lock.lock(); recorded.append(spec); let failure = self.failure; lock.unlock()
            if let failure { throw failure }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let handle = CursorProxyProcessHandle(process: process)
            lock.lock(); handles.append(handle); lock.unlock()
            return handle
        }

        func killAll() {
            lock.lock(); let all = handles; handles = []; lock.unlock()
            all.forEach { $0.killImmediately() }
        }
    }

    // MARK: - 辅助

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CursorSidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeClient(supervisor: FakeSupervisor, port: UInt16 = 45678,
                            timeouts: CursorProxyTimeouts = CursorProxyTimeouts(),
                            supportsCurrentOS: Bool = true) -> CursorSidecarClient {
        let configuration = URLSessionCursorProxyTransport.isolatedConfiguration()
        configuration.protocolClasses = [MockURLProtocol.self]
        return CursorSidecarClient(
            executable: URL(fileURLWithPath: "/tmp/ezs-cursor-proxy-under-test"),
            transport: URLSessionCursorProxyTransport(configuration: configuration),
            supervisor: supervisor,
            portProvider: { port },
            timeouts: timeouts,
            supportsCurrentOS: supportsCurrentOS)
    }

    private func setRouter(_ router: Router) { MockURLProtocol.reset(handler: router.handle) }

    private func usableCursorFile(name: String = "cursor-abc.json") -> [String: Any] {
        ["name": name, "type": "cursor", "label": "Cursor", "email": "me@cursor.com",
         "disabled": false, "unavailable": false]
    }

    private func managementRequest(method: String, path: String) -> URLRequest? {
        MockURLProtocol.requests.first { $0.url?.path == path && $0.httpMethod == method }
    }

    /// 轮询等待（进程退出是异步的：stop() 只发信号，不阻塞等待）。
    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: @escaping @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 发现 / 身份 / 环境

    @Test func discoveryFailsClosedOnBrokenOverride() throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("ezs-cursor-proxy")
        try Data("x".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        #expect(CursorProxyBinary.discover(environment: ["EZSWITCH_CURSOR_PROXY": real.path]) == real)
        #expect(CursorProxyBinary.discover(environment: ["EZSWITCH_CURSOR_PROXY": dir.appendingPathComponent("missing").path]) == nil)
        #expect(CursorProxyBinary.discover(environment: ["EZSWITCH_CURSOR_PROXY": "ezs-cursor-proxy"]) == nil)
        let plain = dir.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plain)
        #expect(CursorProxyBinary.discover(environment: ["EZSWITCH_CURSOR_PROXY": plain.path]) == nil)
    }

    @Test func identityRequiresExactVersionAndCommitPrefix() {
        #expect(CursorProxyBinary.versionMatchesPinned("8.0.28-2"))
        #expect(CursorProxyBinary.versionMatchesPinned("v8.0.28-2"))
        #expect(!CursorProxyBinary.versionMatchesPinned("8.0.28-20"))
        #expect(!CursorProxyBinary.versionMatchesPinned("8.0.28-2-plus"))
        #expect(!CursorProxyBinary.versionMatchesPinned(""))
        #expect(CursorProxyBinary.commitMatchesPinned("67eadafb4"))
        #expect(CursorProxyBinary.commitMatchesPinned(""))
        #expect(!CursorProxyBinary.commitMatchesPinned("deadbeef"))
    }

    @Test func environmentDropsHarnessSecretsAndIsolatesHome() {
        let home = URL(fileURLWithPath: "/tmp/iso/home")
        let env = CursorProxyEnvironment.sanitized([
            "HOME": "/Users/real", "USER": "me", "PATH": "/evil", "LC_ALL": "en_US.UTF-8",
            "HTTPS_PROXY": "http://proxy:8080", "SSL_CERT_FILE": "/etc/cert.pem",
            "MANAGEMENT_PASSWORD": "secret", "NODE_OPTIONS": "--require evil",
            "CURSOR_API_KEY": "k", "OPENAI_API_KEY": "o",
        ], home: home, temp: URL(fileURLWithPath: "/tmp/iso/runtime"))
        #expect(env["HOME"] == home.path)
        #expect(env["USER"] == "me")
        #expect(env["HTTPS_PROXY"] == "http://proxy:8080")
        #expect(env["SSL_CERT_FILE"] == "/etc/cert.pem")
        for dropped in ["MANAGEMENT_PASSWORD", "NODE_OPTIONS", "CURSOR_API_KEY", "OPENAI_API_KEY", "LC_ALL"] {
            #expect(env[dropped] == nil)
        }
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func configYamlIsCanonicalAndEscapesScalars() {
        let config = CursorProxyConfig(port: 45999, managementSecret: "m\"x", apiKey: "k\\y",
                                       authDir: URL(fileURLWithPath: "/tmp/root/auth"))
        let yaml = config.yaml
        #expect(yaml.contains("config-version: 8"))
        #expect(yaml.contains("host: \"127.0.0.1\""))
        #expect(yaml.contains("port: 45999"))
        #expect(yaml.contains("allow-remote: false"))
        #expect(yaml.contains("disable-control-panel: true"))
        #expect(yaml.contains("disable-auto-update-panel: true"))
        #expect(yaml.contains("logging-to-file: false"))
        #expect(yaml.contains("request-log: false"))
        #expect(yaml.contains("error-logs-max-files: 2"))
        #expect(yaml.contains("auth-dir: \"/tmp/root/auth\""))
        #expect(yaml.contains("m\\\"x"))
        #expect(yaml.contains("k\\\\y"))
        #expect(!yaml.contains("MANAGEMENT_PASSWORD"))
        #expect(!yaml.lowercased().contains("telemetry"))
    }

    // MARK: - inspect / 启动

    @Test func inspectEmptyAccountIsUnauthenticatedWithoutError() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authFiles: [], models: []))

        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)
        let status = await client.inspect()

        #expect(status.installed)
        #expect(status.running)
        #expect(!status.authenticated)
        #expect(status.error == nil)
        #expect(status.version == "8.0.28-2")
        #expect(status.models.isEmpty)
        #expect(supervisor.launchCount == 1)

        let configPath = try #require(supervisor.specs.first?.arguments.last)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: configPath)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        for sub in ["runtime", "auth", "home"] {
            let path = dir.appendingPathComponent(sub).path
            let dirMode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
            #expect(dirMode.intValue == 0o700)
        }
    }

    @Test func inspectConnectedOnlyWithUsableAccountAndModels() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authFiles: [usableCursorFile()], models: ["composer-2", "grok-4.6"]))

        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)
        let status = await client.inspect()
        #expect(status.connected)
        #expect(status.account == "me@cursor.com")
        #expect(status.models == ["composer-2", "grok-4.6"])
    }

    @Test func inspectUnavailableAccountIsNotAuthenticatedWithRealError() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authFiles: [["name": "cursor-x.json", "type": "cursor",
                                      "disabled": false, "unavailable": true,
                                      "status_message": "token expired, please re-login"]]))

        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)
        let status = await client.inspect()
        #expect(!status.authenticated)
        #expect(!status.connected)
        #expect(status.error?.contains("token expired") == true)
    }

    @Test func nonCursorAccountsAreIgnored() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authFiles: [["name": "codex.json", "type": "codex", "disabled": false,
                                      "unavailable": false]], models: ["m"]))
        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)
        let status = await client.inspect()
        #expect(!status.authenticated)
        #expect(status.error == nil)
    }

    @Test func startupFailsWhenReadinessNeverSatisfied() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(healthStatus: 503))
        var timeouts = CursorProxyTimeouts(); timeouts.healthStart = 0.3

        let client = makeClient(supervisor: supervisor, timeouts: timeouts)
        try await client.configure(root: dir)
        let status = await client.inspect()
        #expect(status.installed)
        #expect(!status.running)
        #expect(status.error != nil)
    }

    @Test func startupRejectsForeignProcessWithoutOurSecret() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(managementStatus: 401))
        var timeouts = CursorProxyTimeouts(); timeouts.healthStart = 0.3

        let client = makeClient(supervisor: supervisor, timeouts: timeouts)
        try await client.configure(root: dir)
        #expect(await client.inspect().error != nil)
    }

    @Test func startupRejectsWrongPinnedVersion() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(version: "9.9.9"))
        var timeouts = CursorProxyTimeouts(); timeouts.healthStart = 0.3

        let client = makeClient(supervisor: supervisor, timeouts: timeouts)
        try await client.configure(root: dir)
        let status = await client.inspect()
        #expect(status.error != nil)
        #expect(status.version == nil)
    }

    @Test func supervisorLaunchFailureSurfacesShortError() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        supervisor.failWith = CursorProxyError(message: "无法启动 Cursor 连接组件：missing")
        setRouter(Router())

        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)
        let status = await client.inspect()
        #expect(!status.running)
        #expect(status.error?.contains("无法启动") == true)
    }

    @Test func unsupportedOSBlocksStartAndLogin() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router())
        let client = makeClient(supervisor: supervisor, supportsCurrentOS: false)
        try await client.configure(root: dir)

        #expect(await client.inspect().error?.contains("macOS 15") == true)
        #expect(supervisor.launchCount == 0)
        await #expect(throws: (any Error).self) { try await client.login(openURL: { _ in }) }
    }

    // MARK: - 端点

    @Test func requestEndpointNeverStartsAndRequiresAuthKnown() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authFiles: [usableCursorFile()], models: ["m"]))

        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)

        await #expect(throws: (any Error).self) { _ = try await client.requestEndpoint() }
        #expect(supervisor.launchCount == 0)

        _ = await client.inspect()
        let endpoint = try await client.requestEndpoint()
        #expect(endpoint.baseURL == URL(string: "http://127.0.0.1:45678/v1"))
        #expect(!endpoint.apiKey.isEmpty)
        _ = try await client.requestEndpoint()
        #expect(supervisor.launchCount == 1)
    }

    // MARK: - login

    @Test func loginOpensValidatedURLAndSucceedsAfterInspect() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authFiles: [usableCursorFile()], models: ["composer-2"],
                         authStatuses: ["wait", "ok"]))
        var timeouts = CursorProxyTimeouts(); timeouts.loginPoll = 0.02; timeouts.login = 5

        let opener = Ref<URL?>(nil)
        let client = makeClient(supervisor: supervisor, timeouts: timeouts)
        try await client.configure(root: dir)
        try await client.login(openURL: { url in opener.set(url) })
        #expect(opener.get() == URL(string: "https://cursor.com/loginDeepControl?x=1"))
    }

    @Test func loginRejectsMaliciousURLAndCancelsSession() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        for bad in ["http://cursor.com/loginDeepControl?x=1",
                    "https://evil.example/loginDeepControl",
                    "https://cursor.com.evil.example/loginDeepControl",
                    "https://cursor.com/other"] {
            setRouter(Router(authURL: bad))
            let opened = Ref(false)
            let client = makeClient(supervisor: supervisor)
            try await client.configure(root: dir)
            await #expect(throws: (any Error).self) {
                try await client.login(openURL: { _ in opened.set(true) })
            }
            #expect(!opened.get(), "恶意 URL 不得打开：\(bad)")
        }
        #expect(managementRequest(method: "DELETE", path: "/v0/management/oauth-session") != nil)
    }

    @Test func loginExpiredStateThrowsAndCancelsSession() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authStatusError: "unknown or expired state"))
        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)
        await #expect(throws: (any Error).self) { try await client.login(openURL: { _ in }) }
        #expect(managementRequest(method: "DELETE", path: "/v0/management/oauth-session") != nil)
    }

    @Test func loginTimeoutCancelsSession() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authStatuses: ["wait"]))
        var timeouts = CursorProxyTimeouts(); timeouts.loginPoll = 0.02; timeouts.login = 0.1
        let client = makeClient(supervisor: supervisor, timeouts: timeouts)
        try await client.configure(root: dir)
        await #expect(throws: (any Error).self) { try await client.login(openURL: { _ in }) }
        #expect(managementRequest(method: "DELETE", path: "/v0/management/oauth-session") != nil)
    }

    @Test func cancelledLoginCancelsSession() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authStatuses: ["wait"]))
        var timeouts = CursorProxyTimeouts(); timeouts.loginPoll = 0.05; timeouts.login = 30
        let client = makeClient(supervisor: supervisor, timeouts: timeouts)
        try await client.configure(root: dir)

        let task = Task { try await client.login(openURL: { _ in }) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        if case .success = await task.result { Issue.record("期望取消") }
        #expect(managementRequest(method: "DELETE", path: "/v0/management/oauth-session") != nil)
    }

    // MARK: - stop / 重入

    @Test func stopTerminatesOwnedProcessAndInvalidates() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authFiles: [usableCursorFile()], models: ["m"]))
        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)
        _ = await client.inspect()
        #expect(supervisor.runningCount == 1)

        await client.stop()
        await waitUntil { supervisor.runningCount == 0 }
        #expect(supervisor.runningCount == 0)
        setRouter(Router(authFiles: [], models: []))
        #expect(!(await client.inspect().authenticated))
    }

    @Test func configureSameRootIsIdempotentDifferentRootStopsOld() async throws {
        MockURLProtocol.reset()
        let first = try tempRoot(); defer { try? FileManager.default.removeItem(at: first) }
        let second = try tempRoot(); defer { try? FileManager.default.removeItem(at: second) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authFiles: [], models: []))
        let client = makeClient(supervisor: supervisor)

        try await client.configure(root: first)
        _ = await client.inspect()
        #expect(supervisor.runningCount == 1)

        try await client.configure(root: first)
        #expect(supervisor.runningCount == 1)

        try await client.configure(root: second)
        await waitUntil { supervisor.runningCount == 0 }
        #expect(supervisor.runningCount == 0)
    }

    /// app 在 launch→waitReady 期间退出：startup 子进程必须已登记，shutdownImmediately 同步终止。
    @Test func shutdownImmediatelyKillsPendingStartupProcess() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(healthStatus: 503))
        var timeouts = CursorProxyTimeouts(); timeouts.healthStart = 5   // 保持 startup 在途

        let client = makeClient(supervisor: supervisor, timeouts: timeouts)
        try await client.configure(root: dir)
        let task = Task { await client.inspect() }
        await waitUntil { supervisor.launchCount >= 1 }
        try await Task.sleep(nanoseconds: 100_000_000)   // 等 registry 登记句柄
        #expect(supervisor.runningCount == 1)

        client.shutdownImmediately()
        await waitUntil { supervisor.runningCount == 0 }
        #expect(supervisor.runningCount == 0, "退出时不得留下 startup 孤儿进程")

        task.cancel()
        _ = await task.value
    }

    // MARK: - logout

    @Test func logoutDeletesOnlyCursorAccounts() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        setRouter(Router(authFiles: [usableCursorFile(name: "cursor-one.json"),
                                     ["name": "codex.json", "type": "codex", "disabled": false,
                                      "unavailable": false],
                                     usableCursorFile(name: "cursor-two.json")],
                         models: ["m"]))
        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)
        try await client.logout()

        let deleted = MockURLProtocol.requests
            .filter { $0.httpMethod == "DELETE" && $0.url?.path == "/v0/management/auth-files" }
            .compactMap { request -> String? in
                guard let url = request.url else { return nil }
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "name" }?.value
            }
        #expect(Set(deleted) == ["cursor-one.json", "cursor-two.json"])
        #expect(!deleted.contains("codex.json"))
        #expect(!MockURLProtocol.requests.contains { $0.url?.query?.contains("all=true") == true })
    }

    @Test func logoutRejectsMalformedListingInsteadOfReportingSuccess() async throws {
        MockURLProtocol.reset()
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let supervisor = FakeSupervisor()
        defer { supervisor.killAll() }
        var router = Router()
        router.authFilesBody = Data("not json".utf8)
        setRouter(router)
        let client = makeClient(supervisor: supervisor)
        try await client.configure(root: dir)
        await #expect(throws: (any Error).self) { try await client.logout() }
    }

    // MARK: - 解析

    @Test func modelIDsFilterCursorOwnerAndDedupe() {
        let body = Data(#"{"data":[{"id":"a","owned_by":"cursor"},{"id":"a","owned_by":"cursor"},{"id":"b","owned_by":"openai"},{"id":"","owned_by":"cursor"},{"id":"c","owned_by":"CURSOR"}]}"#.utf8)
        #expect(CursorSidecarClient.parseModelIDs(from: body) == ["a", "c"])
        #expect(CursorSidecarClient.parseModelIDs(from: Data("oops".utf8)).isEmpty)
    }

    @Test func safeAuthFileNameRejectsTraversal() {
        #expect(CursorSidecarClient.isSafeAuthFileName("cursor-abc.json"))
        for bad in ["", "../evil.json", "a/b.json", "..", "sub\\evil"] {
            #expect(!CursorSidecarClient.isSafeAuthFileName(bad), "不应接受：\(bad)")
        }
    }

    @Test func shortErrorCollapsesAndTruncates() {
        #expect(CursorSidecarClient.shortError("  a\nb  ") == "a b")
        #expect(CursorSidecarClient.shortError("   ") == nil)
        #expect(CursorSidecarClient.shortError(nil) == nil)
        #expect(CursorSidecarClient.shortError(String(repeating: "x", count: 400))?.count == 201)
    }
}
