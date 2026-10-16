import Darwin
import Dispatch
import Foundation
import Network
import Testing
@testable import EZSwitch

// MARK: - 本地 mock TCP 端点（无真实网络/账号）

/// 最小 POSIX TCP 服务端：接受连接、记录收到的首批字节、可选回写固定响应，然后关闭。
/// 仅绑定 127.0.0.1 的临时端口，用于验证出站代理路径与“失败代理不得回退直连”。
final class MockTCPEndpoint {
    enum MockError: Error { case socket, bind, listen }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var payloads: [Data] = []
    private var accepts = 0
    private var running = true
    private let respond: Data?
    private let readTimeout: TimeInterval

    /// - Parameter respond: 非 nil 时，读到请求后回写该字节（例如一条 HTTP 200 响应）。
    /// - Parameter readTimeout: 单次读取等待上限（秒），用于 TLS 等无 `\r\n\r\n` 终止符的场景。
    init(respond: Data? = nil, readTimeout: TimeInterval = 1.0) throws {
        self.respond = respond
        self.readTimeout = readTimeout

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MockError.socket }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // 让内核分配临时端口
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw MockError.bind }
        guard listen(fd, 16) == 0 else { close(fd); throw MockError.listen }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
        startAcceptLoop()
    }

    deinit { stop() }

    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return accepts
    }

    var receivedPayloads: [Data] {
        lock.lock(); defer { lock.unlock() }
        return payloads
    }

    var firstPayloadText: String? {
        receivedPayloads.first.map { String(decoding: $0, as: UTF8.self) }
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning { close(listenFD) }
    }

    /// 轮询等待至少 `count` 条连接被接受。
    @discardableResult
    func waitForConnections(_ count: Int, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if connectionCount >= count { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return connectionCount >= count
    }

    /// 轮询等待至少 `count` 份请求载荷被记录（TLS/SOCKS 需等读超时，故单独等待）。
    @discardableResult
    func waitForPayloads(_ count: Int, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if receivedPayloads.count >= count { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return receivedPayloads.count >= count
    }

    // MARK: 内部

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func startAcceptLoop() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            while self.isRunning {
                let client = accept(self.listenFD, nil, nil)
                guard client >= 0 else {
                    if !self.isRunning { break }
                    continue
                }
                self.handle(client)
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func handle(_ client: Int32) {
        lock.lock(); accepts += 1; lock.unlock()

        var tv = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while received.count < 64 * 1024 {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
            // 普通 HTTP/CONNECT 请求以空行结束；TLS ClientHello 无终止符，靠读超时退出。
            if received.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }

        lock.lock(); payloads.append(received); lock.unlock()

        if let respond, !respond.isEmpty {
            respond.withUnsafeBytes { raw in
                _ = send(client, raw.baseAddress, respond.count, 0)
            }
        }
        close(client)
    }
}

private let httpOK = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)

// MARK: - 有界请求辅助

private enum TransportTestError: Error { case timedOut }

/// 在 deadline 内发起请求；超时即取消并返回 failure，避免依赖系统默认的 3600s 超时。
private func boundedLoad(_ session: URLSession, _ url: URL,
                         timeout: TimeInterval = 6) async -> Result<Int, Error> {
    await withTaskGroup(of: Result<Int, Error>?.self) { group in
        group.addTask {
            do {
                let (_, response) = try await session.data(from: url)
                return .success((response as? HTTPURLResponse)?.statusCode ?? -1)
            } catch {
                return .failure(error)
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? .failure(TransportTestError.timedOut)
    }
}

// MARK: - 地址校验

@Suite("Outbound proxy URL validation")
struct OutboundProxyValidationTests {
    @Test func acceptsHTTPProxyWithPort() throws {
        let url = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:8080")
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 8080)
        #expect(url.absoluteString == "http://127.0.0.1:8080")
    }

    @Test func acceptsSOCKS5AndTrimsWhitespace() throws {
        let socks = try OutboundPolicy.validatedProxyURL("  socks5://proxy.internal:1080  ")
        #expect(socks.scheme == "socks5")
        #expect(socks.port == 1080)
    }

    /// https 代理（TLS-to-proxy）仅 macOS 14+ 可接受。
    @Test(.enabled(if: OutboundTransport.secureProxyAvailable))
    func acceptsSecureProxyOnModernOS() throws {
        let secure = try OutboundPolicy.validatedProxyURL("https://proxy.internal:8443")
        #expect(secure.scheme == "https")
        #expect(secure.port == 8443)
    }

    /// macOS 13：校验层即拒绝 https 代理，使配置保存时就报错（不能只靠 session 抛）。
    @Test(.enabled(if: !OutboundTransport.secureProxyAvailable))
    func validatorRejectsSecureProxyOnMacOS13() {
        #expect(throws: OutboundTransportError.secureProxyRequiresMacOS14) {
            _ = try OutboundPolicy.validatedProxyURL("https://proxy.internal:8443")
        }
    }

    @Test func normalizesUppercaseScheme() throws {
        let url = try OutboundPolicy.validatedProxyURL("HTTP://Proxy.Example:3128")
        #expect(url.scheme == "http")
        #expect(url.absoluteString.hasPrefix("http://"))
    }

    @Test func acceptsTrailingRootSlash() throws {
        let url = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:8080/")
        #expect(url.port == 8080)
        #expect(url.path.isEmpty || url.path == "/")
    }

    @Test func rejectsEmpty() {
        #expect(throws: OutboundTransportError.emptyProxyURL) {
            _ = try OutboundPolicy.validatedProxyURL("   ")
        }
    }

    @Test func rejectsUnsupportedScheme() {
        #expect(throws: OutboundTransportError.unsupportedScheme("ftp")) {
            _ = try OutboundPolicy.validatedProxyURL("ftp://127.0.0.1:21")
        }
    }

    @Test func rejectsMissingScheme() {
        #expect(throws: OutboundTransportError.unsupportedScheme("")) {
            _ = try OutboundPolicy.validatedProxyURL("//127.0.0.1:8080")
        }
        // 裸 host:port 无法解析为 URL，同样必须拒绝。
        #expect(throws: (any Error).self) {
            _ = try OutboundPolicy.validatedProxyURL("127.0.0.1:8080")
        }
    }

    @Test func rejectsMissingPort() {
        #expect(throws: OutboundTransportError.missingPort) {
            _ = try OutboundPolicy.validatedProxyURL("http://127.0.0.1")
        }
    }

    @Test func rejectsMissingHost() {
        #expect(throws: OutboundTransportError.missingHost) {
            _ = try OutboundPolicy.validatedProxyURL("http://:8080")
        }
    }

    @Test func rejectsPath() {
        #expect(throws: (any Error).self) {
            _ = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:8080/proxy")
        }
    }

    @Test func rejectsQueryAndFragment() {
        #expect(throws: (any Error).self) {
            _ = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:8080/?x=1")
        }
        #expect(throws: (any Error).self) {
            _ = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:8080/#frag")
        }
    }

    @Test func rejectsCredentialsToAvoidPlaintextSecrets() {
        #expect(throws: OutboundTransportError.credentialsUnsupported) {
            _ = try OutboundPolicy.validatedProxyURL("http://user:pass@127.0.0.1:8080")
        }
    }

    @Test func rejectsControlCharacters() {
        #expect(throws: OutboundTransportError.controlCharacters) {
            _ = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:8080\n")
        }
    }

    @Test func transportValidatorMatchesPolicyValidator() throws {
        let viaTransport = try OutboundTransport.validateProxyURL("socks5://127.0.0.1:1080")
        let viaPolicy = try OutboundPolicy.validatedProxyURL("socks5://127.0.0.1:1080")
        #expect(viaTransport == viaPolicy)
    }
}

// MARK: - 会话工厂

@Suite("Outbound transport session factory")
struct OutboundTransportSessionTests {
    @Test func directSessionBypassesSystemProxy() throws {
        let session = try OutboundTransport.session(for: .direct)
        let dictionary = session.configuration.connectionProxyDictionary
        #expect(dictionary != nil, "direct 必须显式设 connectionProxyDictionary 以绕开系统代理")
        #expect(dictionary?.isEmpty == true, "direct 的代理字典应为空字典，而非 nil")
    }

    @Test func directSessionRoundTripsOverLoopback() async throws {
        let target = try MockTCPEndpoint(respond: httpOK)
        defer { target.stop() }
        let session = try OutboundTransport.session(for: .direct)
        let result = await boundedLoad(session, URL(string: "http://127.0.0.1:\(target.port)/")!)
        let status = try result.get()
        #expect(status == 200)
    }

    @Test func samePolicyReusesSameSession() throws {
        let first = try OutboundTransport.session(for: .direct)
        let second = try OutboundTransport.session(for: .direct)
        #expect(first === second)

        let proxyA = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("socks5://127.0.0.1:1080")))
        let proxyB = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("socks5://127.0.0.1:1080")))
        #expect(proxyA === proxyB)
        #expect(proxyA !== first)
    }

    @Test func invalidPolicyThrowsBackendErrorNotClientFailure() throws {
        do {
            _ = try OutboundTransport.session(for: .invalid("坏地址"))
            Issue.record("invalid policy must throw, never silently fall back to direct")
        } catch {
            #expect((error as? OutboundTransportError) == .invalidPolicy("坏地址"))
            #expect((error as? any ClientRequestFailure) == nil,
                    "代理配置错误是后端故障，不应被当作客户端请求失败")
        }
    }

    /// 手工构造的 `.proxy(URL)` 也必须过校验：userinfo 不能绕过策略进入会话。
    @Test func handBuiltProxyURLWithCredentialsIsRejected() {
        let url = URL(string: "http://user:pass@127.0.0.1:8080")!
        #expect(throws: OutboundTransportError.credentialsUnsupported) {
            _ = try OutboundTransport.session(for: .proxy(url))
        }
    }

    @Test func httpProxySessionConfiguresBothHTTPAndHTTPSProxyKeys() throws {
        let session = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("http://127.0.0.1:8080")))
        let dictionary = session.configuration.connectionProxyDictionary
        #expect(dictionary?[kCFNetworkProxiesHTTPProxy as String] as? String == "127.0.0.1")
        #expect(dictionary?[kCFNetworkProxiesHTTPSProxy as String] as? String == "127.0.0.1",
                "https 目标必须走 HTTPSProxy 键，否则会静默直连")
        #expect(dictionary?[kCFNetworkProxiesHTTPPort as String] as? Int == 8080)
        #expect(dictionary?[kCFNetworkProxiesHTTPSPort as String] as? Int == 8080)
    }

    @Test func socksSessionConfiguresSOCKSKeys() throws {
        let session = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("socks5://127.0.0.1:1080")))
        let dictionary = session.configuration.connectionProxyDictionary
        #expect(dictionary?[kCFNetworkProxiesSOCKSProxy as String] as? String == "127.0.0.1")
        #expect(dictionary?[kCFNetworkProxiesSOCKSPort as String] as? Int == 1080)
    }

    /// macOS 14+：https 代理走 proxyConfigurations，且绝不能同时设 connectionProxyDictionary
    /// （非 nil 空字典会让 proxyConfigurations 失效并静默直连）。
    @Test(.enabled(if: OutboundTransport.secureProxyAvailable))
    func secureProxySessionUsesProxyConfigurationsOnlyOnModernOS() throws {
        let session = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("https://127.0.0.1:8443")))
        #expect(session.configuration.connectionProxyDictionary == nil,
                "https 代理会话不得设置 connectionProxyDictionary，否则会静默直连")
        if #available(macOS 14.0, *) {
            #expect(session.configuration.proxyConfigurations.isEmpty == false)
        }
    }

    /// macOS 13：无 TLS-to-proxy 能力，session 工厂必须明确拒绝，绝不假装支持或退回直连。
    @Test(.enabled(if: !OutboundTransport.secureProxyAvailable))
    func secureProxyRejectedOnMacOS13() {
        let url = URL(string: "https://127.0.0.1:8443")!
        #expect(throws: OutboundTransportError.secureProxyRequiresMacOS14) {
            _ = try OutboundTransport.session(for: .proxy(url))
        }
    }
}

// MARK: - 真实本地 mock proxy 出站路径

@Suite("Outbound transport live proxy paths")
struct OutboundTransportLiveProxyTests {
    /// http 代理 + https 目标：CFNetwork 必须向代理发 CONNECT（而不是绕过代理）。
    @Test func httpProxyTunnelsHTTPSViaCONNECT() async throws {
        let proxy = try MockTCPEndpoint(respond: nil)
        defer { proxy.stop() }
        let session = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("http://127.0.0.1:\(proxy.port)")))

        let result = await boundedLoad(session, URL(string: "https://upstream.invalid/")!)
        guard case .failure = result else {
            Issue.record("CONNECT 代理被 mock 关闭，请求本应失败，实际成功：\(result)")
            return
        }
        #expect(proxy.waitForPayloads(1))
        let line = proxy.firstPayloadText ?? ""
        #expect(line.hasPrefix("CONNECT upstream.invalid:443"),
                "https 目标应经 CONNECT 到达代理，实际首行：\(line.prefix(80))")
    }

    /// http 代理 + http 目标：代理收到绝对形式请求行 GET http://host[:port]/...
    @Test func httpProxyUsesAbsoluteFormForHTTPTarget() async throws {
        let proxy = try MockTCPEndpoint(respond: nil)
        defer { proxy.stop() }
        let session = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("http://127.0.0.1:\(proxy.port)")))

        let result = await boundedLoad(session, URL(string: "http://upstream.invalid/")!)
        guard case .failure = result else {
            Issue.record("代理被 mock 关闭，请求本应失败，实际成功：\(result)")
            return
        }
        #expect(proxy.waitForPayloads(1))
        let line = proxy.firstPayloadText ?? ""
        #expect(line.hasPrefix("GET http://upstream.invalid/") ||
                line.hasPrefix("GET http://upstream.invalid:80/"),
                "http 目标应经绝对形式请求到达代理，实际首行：\(line.prefix(80))")
    }

    /// 失败代理不得静默回退直连：代理拒连后请求必须失败，且本地目标端点一次都不能被触达。
    @Test func failingProxyNeverFallsBackToTarget() async throws {
        let proxy = try MockTCPEndpoint(respond: nil) // 读到请求即关闭，模拟坏代理
        let target = try MockTCPEndpoint(respond: httpOK) // 若发生静默直连，这里会被命中
        defer { proxy.stop(); target.stop() }

        let session = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("http://127.0.0.1:\(proxy.port)")))
        let result = await boundedLoad(session, URL(string: "http://127.0.0.1:\(target.port)/")!)

        guard case .failure = result else {
            Issue.record("坏代理下请求本应失败，实际成功：\(result)")
            return
        }
        #expect(proxy.waitForConnections(1), "请求应到达代理")
        // 给潜在的直连回退一点时间暴露出来。
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(target.connectionCount == 0, "坏代理不得静默回退直连触达上游目标")
    }

    /// 代理返回 302 时必须原样透出 302，绝不跟随重定向打到本地目标（防 catalog 302 → local 直连）。
    @Test func proxyRedirectIsNotFollowedToLocalTarget() async throws {
        let target = try MockTCPEndpoint(respond: httpOK) // 若重定向被跟随，这里会被命中
        let location = "http://127.0.0.1:\(target.port)/"
        let redirect = Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        let proxy = try MockTCPEndpoint(respond: redirect)
        defer { proxy.stop(); target.stop() }

        let session = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("http://127.0.0.1:\(proxy.port)")))
        let result = await boundedLoad(session, URL(string: "http://upstream.invalid/")!)

        let status = try result.get()
        #expect(status == 302, "重定向应原样透出 302，而非被跟随后的结果")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(proxy.connectionCount == 1, "重定向不得被跟随（不应产生第二次代理请求）")
        #expect(target.connectionCount == 0, "重定向不得打到本地目标")
    }

    /// socks5：代理收到 SOCKS5 greeting（0x05 0x01 0x00）。
    @Test func socks5SendsGreetingToProxy() async throws {
        let proxy = try MockTCPEndpoint(respond: nil)
        defer { proxy.stop() }
        let session = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("socks5://127.0.0.1:\(proxy.port)")))

        let result = await boundedLoad(session, URL(string: "https://upstream.invalid/")!)
        guard case .failure = result else {
            Issue.record("SOCKS 代理被 mock 关闭，请求本应失败，实际成功：\(result)")
            return
        }
        #expect(proxy.waitForPayloads(1, timeout: 4))
        let payload = proxy.receivedPayloads.first ?? Data()
        #expect(Array(payload.prefix(3)) == [0x05, 0x01, 0x00],
                "SOCKS5 首个报文应为 greeting，实际：\(Array(payload.prefix(8)))")
    }

    /// https 代理（macOS 14+）：与代理之间必须先做 TLS 握手（首字节 0x16 record）。
    @Test(.enabled(if: OutboundTransport.secureProxyAvailable))
    func secureProxyPerformsTLSHandshake() async throws {
        let proxy = try MockTCPEndpoint(respond: nil, readTimeout: 1.0)
        defer { proxy.stop() }
        let session = try OutboundTransport.session(for: .proxy(try OutboundTransport.validateProxyURL("https://127.0.0.1:\(proxy.port)")))

        let result = await boundedLoad(session, URL(string: "https://upstream.invalid/")!)
        guard case .failure = result else {
            Issue.record("TLS 代理被 mock 关闭，请求本应失败，实际成功：\(result)")
            return
        }
        #expect(proxy.waitForPayloads(1, timeout: 4), "TLS-to-proxy 应先连到代理")
        let first = proxy.receivedPayloads.first ?? Data()
        #expect(first.first == 0x16, "https 代理首字节应为 TLS handshake record(0x16)，实际：\(first.first.map { String(format: "0x%02x", $0) } ?? "nil")")
    }
}
