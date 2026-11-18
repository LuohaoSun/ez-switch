import Foundation
import NIOCore
import NIOHTTP1
import Testing
@testable import EZSwitch

/// Canned upstream for the injected (direct) session. File-private so it never collides
/// with other suites' mock protocol classes.
private final class ProxyRoutingURLProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var chunks: [Data] = []
        var error: URLError?
    }

    private static let handlerLock = NSLock()
    private static var storedHandler: ((URLRequest) -> Reply)?
    static var handler: ((URLRequest) -> Reply)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return storedHandler }
        set { handlerLock.lock(); storedHandler = newValue; handlerLock.unlock() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = ProxyRoutingURLProtocol.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = handler(request)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RequestSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    func store(_ request: URLRequest) { lock.lock(); storage.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
}

private actor PolicyRecorder {
    private(set) var policies: [OutboundPolicy] = []
    func record(_ policy: OutboundPolicy) { policies.append(policy) }
}

@Suite("Outbound policy routing", .serialized)
struct ProxyRoutingTests {
    private let connectorSource = RemoteSource(rawValue: "policyFixture")

    // MARK: fixtures

    private func apiRemote(_ provider: String, _ model: String, host: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "key", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://\(host)/v1"))
    }

    private func connectorRemote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "", model: model,
                    extraHeaders: [:],
                    apiEndpoints: APIEndpointSettings(chat: .disabled, responses: .disabled,
                                                      messages: .disabled),
                    source: connectorSource)
    }

    private func head(_ path: String) -> HTTPRequestHead {
        HTTPRequestHead(version: .http1_1, method: .POST, uri: path)
    }

    private func mockSession(handler: @escaping (URLRequest) -> ProxyRoutingURLProtocol.Reply) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProxyRoutingURLProtocol.self]
        config.connectionProxyDictionary = [:]
        ProxyRoutingURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    private func connectorRegistry(recorder: PolicyRecorder,
                                   supportsProxy: Bool = true) -> ExtensionRegistry {
        ExtensionRegistry(connectors: [ConnectorDefinition(
            source: connectorSource, settingsKey: "policyFixture", displayName: "Fixture",
            endpoints: [.chat],
            forward: { request in
                await recorder.record(request.outboundPolicy)
                return UpstreamResponse(response: HTTPURLResponse(url: URL(string: "http://localhost/c")!,
                                                                  statusCode: 200, httpVersion: "HTTP/1.1",
                                                                  headerFields: ["content-type": "text/plain"])!,
                                        body: AsyncThrowingStream { $0.finish() }, cancel: {})
            },
            fetchModels: { [] },
            supportsOutboundProxy: supportsProxy)])
    }

    // MARK: session selection

    @Test func directPolicyPreservesInjectedSession() throws {
        let injected = URLSession(configuration: .ephemeral)
        #expect(try Forwarder.resolvedSession(for: .direct, injected: injected) === injected)
    }

    @Test func proxyPolicyUsesFactorySessionInsteadOfInjected() throws {
        let proxy = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:7890")
        let injected = URLSession(configuration: .ephemeral)
        let resolved = try Forwarder.resolvedSession(for: .proxy(proxy), injected: injected)
        #expect(resolved !== injected)
        #expect(resolved === (try OutboundTransport.session(for: .proxy(proxy))))
    }

    @Test func invalidPolicyIsBackendErrorNotClientFailure() throws {
        let injected = URLSession(configuration: .ephemeral)
        do {
            _ = try Forwarder.resolvedSession(for: .invalid("http://127.0.0.1"), injected: injected)
            Issue.record("invalid policy unexpectedly resolved a session")
        } catch {
            #expect((error as? OutboundTransportError) == .invalidPolicy("http://127.0.0.1"))
            #expect((error as? any ClientRequestFailure) == nil)
        }
    }

    // MARK: connector policy pass-through

    @Test func connectorReceivesProxyPolicyAndKeepsOwnTransport() async throws {
        let recorder = PolicyRecorder()
        let registry = connectorRegistry(recorder: recorder)
        let spy = RequestSpy()
        let injected = mockSession { request in spy.store(request); return .init() }
        defer { ProxyRoutingURLProtocol.handler = nil }

        let proxy = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:7890")
        _ = try await Forwarder.makeRequest(clientHead: head("/v1/chat/completions"),
                                            body: Data(#"{"model":"main"}"#.utf8),
                                            endpoint: .chat, remote: connectorRemote("Fixture", "m"),
                                            query: "", session: injected,
                                            outboundPolicy: .proxy(proxy),
                                            extensionRegistry: registry)

        #expect(await recorder.policies == [.proxy(proxy)])
        // 连接器自带本地 loopback 通道，绝不套用代理会话。
        #expect(spy.requests.isEmpty)
    }

    @Test func connectorDefaultPolicyIsDirect() async throws {
        let recorder = PolicyRecorder()
        let registry = connectorRegistry(recorder: recorder)
        _ = try await Forwarder.makeRequest(clientHead: head("/v1/chat/completions"),
                                            body: Data(#"{"model":"main"}"#.utf8),
                                            endpoint: .chat, remote: connectorRemote("Fixture", "m"),
                                            query: "", extensionRegistry: registry)
        #expect(await recorder.policies == [.direct])
    }

    @Test func invalidPolicyRejectedBeforeConnectorForward() async throws {
        let recorder = PolicyRecorder()
        let registry = connectorRegistry(recorder: recorder)
        do {
            _ = try await Forwarder.makeRequest(clientHead: head("/v1/chat/completions"),
                                                body: Data(#"{"model":"main"}"#.utf8),
                                                endpoint: .chat, remote: connectorRemote("Fixture", "m"),
                                                query: "",
                                                outboundPolicy: .invalid("http://127.0.0.1"),
                                                extensionRegistry: registry)
            Issue.record("invalid policy unexpectedly reached the connector")
        } catch {
            #expect((error as? OutboundTransportError) == .invalidPolicy("http://127.0.0.1"))
            #expect((error as? any ClientRequestFailure) == nil)
        }
        #expect(await recorder.policies.isEmpty)
    }

    // MARK: native direct keeps injected session / invalid never touches it

    @Test func nativeDirectUsesInjectedSession() async throws {
        let spy = RequestSpy()
        let injected = mockSession { request in
            spy.store(request)
            return .init(chunks: [Data(#"{"ok":true}"#.utf8)])
        }
        defer { ProxyRoutingURLProtocol.handler = nil }

        let upstream = try await Forwarder.makeRequest(clientHead: head("/v1/chat/completions"),
                                                       body: Data(#"{"model":"main"}"#.utf8),
                                                       endpoint: .chat,
                                                       remote: apiRemote("A", "one", host: "a.test"),
                                                       query: "", session: injected)
        #expect(upstream.response.statusCode == 200)
        #expect(spy.requests.count == 1)
        #expect(spy.requests.first?.url?.host == "a.test")
    }

    @Test func invalidPolicyRejectedBeforeInjectedSession() async throws {
        let spy = RequestSpy()
        let injected = mockSession { request in spy.store(request); return .init() }
        defer { ProxyRoutingURLProtocol.handler = nil }
        do {
            _ = try await Forwarder.makeRequest(clientHead: head("/v1/chat/completions"),
                                                body: Data(#"{"model":"main"}"#.utf8),
                                                endpoint: .chat,
                                                remote: apiRemote("A", "one", host: "a.test"),
                                                query: "",
                                                session: injected,
                                                outboundPolicy: .invalid("http://127.0.0.1"))
            Issue.record("invalid policy unexpectedly reached the upstream session")
        } catch {
            #expect((error as? OutboundTransportError) == .invalidPolicy("http://127.0.0.1"))
            #expect((error as? any ClientRequestFailure) == nil)
        }
        #expect(spy.requests.isEmpty)
    }

    // MARK: system proxy policy

    /// 跟随系统代理的候选也用出站工厂会话：注入的直连 mock 不会被拿去发上游请求。
    @Test func systemPolicyUsesFactorySessionInsteadOfInjected() throws {
        let injected = URLSession(configuration: .ephemeral)
        let resolved = try Forwarder.resolvedSession(for: .system, injected: injected)
        #expect(resolved !== injected)
        #expect(resolved === (try OutboundTransport.session(for: .system)))
    }

    /// `.system` 交给连接器时同样保持非直连语义，连接器自带本地通道不受影响。
    @Test func connectorReceivesSystemPolicyAndKeepsOwnTransport() async throws {
        let recorder = PolicyRecorder()
        let registry = connectorRegistry(recorder: recorder)
        let spy = RequestSpy()
        let injected = mockSession { request in spy.store(request); return .init() }
        defer { ProxyRoutingURLProtocol.handler = nil }

        _ = try await Forwarder.makeRequest(clientHead: head("/v1/chat/completions"),
                                            body: Data(#"{"model":"main"}"#.utf8),
                                            endpoint: .chat, remote: connectorRemote("Fixture", "m"),
                                            query: "", session: injected,
                                            outboundPolicy: .system,
                                            extensionRegistry: registry)

        #expect(await recorder.policies == [.system])
        #expect(spy.requests.isEmpty)
    }

    // MARK: proxy + loopback upstream is rejected, never silently direct

    @Test func proxyPolicyToLoopbackUpstreamIsRejectedWithoutTouchingInjectedSession() async throws {
        let spy = RequestSpy()
        let injected = mockSession { request in spy.store(request); return .init() }
        defer { ProxyRoutingURLProtocol.handler = nil }
        let proxy = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:7890")
        let loopback = RemoteModel(id: UUID(), name: "L · one", apiKey: "key", model: "one",
                                   extraHeaders: [:],
                                   apiEndpoints: .enabled([.chat], baseURL: "http://127.0.0.1:8080/v1"))

        do {
            _ = try await Forwarder.makeRequest(clientHead: head("/v1/chat/completions"),
                                                body: Data(#"{"model":"main"}"#.utf8),
                                                endpoint: .chat, remote: loopback,
                                                query: "", session: injected,
                                                outboundPolicy: .proxy(proxy))
            Issue.record("proxy to a loopback upstream unexpectedly proceeded")
        } catch {
            #expect(isLoopbackProxyRejection(error))
        }
        #expect(spy.requests.isEmpty)
    }

    /// 回环 + 显式代理必须是后端 `invalidPolicy`（可回退），绝不是客户端错误。
    private func isLoopbackProxyRejection(_ error: Error) -> Bool {
        guard case .invalidPolicy(let reason)? = error as? OutboundTransportError else { return false }
        return reason.contains("回环")
    }
}
