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

private final class FallbackSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AutoFallbackEvent] = []
    func record(_ event: AutoFallbackEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [AutoFallbackEvent] { lock.lock(); defer { lock.unlock() }; return storage }
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

    // MARK: RouterServer fallback (no implicit direct)

    private func proxySettings(provider: String, address: String) -> ExtensionSettings {
        var settings = ExtensionSettings()
        settings.outboundProxy = OutboundProxySettings(enabled: true, address: address,
                                                       providerNames: [provider])
        return settings
    }

    private func startServer(remotes: [RemoteModel], fake: FakeModel, settings: ExtensionSettings,
                             upstream: URLSession, events: FallbackSpy?)
        async throws -> (RouterServer, Int) {
        let router = Router()
        router.update(AppConfig(port: 0, remotes: remotes, fakes: [fake], extensions: settings))
        let notifier: (@Sendable (AutoFallbackEvent) -> Void)? = events.map { spy in
            { @Sendable (event: AutoFallbackEvent) in spy.record(event) }
        }
        let server = RouterServer(router: router, session: upstream, onAutoFallback: notifier)
        try server.start(port: 0)
        return (server, try #require(server.boundPort))
    }

    private func send(port: Int, path: String, body: String) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    /// 首选候选是 `.invalid` 代理：属后端错误 → 回退到下一个候选，绝不隐式直连首选。
    @Test func invalidPolicyCandidateFallsBackWithoutImplicitDirect() async throws {
        let a = apiRemote("A", "one", host: "a.test")
        let b = apiRemote("B", "two", host: "b.test")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: a.id, fallbackRemoteIDs: [b.id])
        let spy = RequestSpy()
        let events = FallbackSpy()
        let injected = mockSession { request in
            spy.store(request)
            return .init(chunks: [Data(#"{"ok":true}"#.utf8)])
        }
        defer { ProxyRoutingURLProtocol.handler = nil }

        let (server, port) = try await startServer(
            remotes: [a, b], fake: fake,
            settings: proxySettings(provider: "A", address: "http://127.0.0.1"),
            upstream: injected, events: events)
        defer { server.stop() }

        let (_, response) = try await send(port: port, path: "/v1/chat/completions",
                                           body: #"{"model":"main","stream":false}"#)
        #expect(response.statusCode == 200)
        // 注入的直连会话只被回退后的 B 使用；A 从未隐式直连。
        #expect(spy.requests.count == 1)
        #expect(spy.requests.first?.url?.host == "b.test")
        #expect(events.events.first?.from == "A · one")
        #expect(events.events.first?.to == "B · two")
    }

    /// 唯一候选是 `.invalid` 代理：后端错误应为 502（可回退语义），而不是客户端 400。
    @Test func invalidProxyLastCandidateReturnsBackend502NotClient400() async throws {
        let a = apiRemote("A", "one", host: "a.test")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: a.id)
        let spy = RequestSpy()
        let injected = mockSession { request in spy.store(request); return .init() }
        defer { ProxyRoutingURLProtocol.handler = nil }

        let (server, port) = try await startServer(
            remotes: [a], fake: fake,
            settings: proxySettings(provider: "A", address: "ftp://127.0.0.1:21"),
            upstream: injected, events: nil)
        defer { server.stop() }

        let (_, response) = try await send(port: port, path: "/v1/chat/completions",
                                           body: #"{"model":"main","stream":false}"#)
        #expect(response.statusCode == 502)
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

    @Test func catalogProxyToLoopbackProviderIsRejectedWithoutTouchingInjectedSession() async throws {
        let spy = RequestSpy()
        let injected = mockSession { request in spy.store(request); return .init() }
        defer { ProxyRoutingURLProtocol.handler = nil }
        let loopback = RemoteModel(id: UUID(), name: "L · one", apiKey: "key", model: "one",
                                   extraHeaders: [:],
                                   apiEndpoints: .enabled([.chat], baseURL: "http://127.0.0.1:8080/v1"))

        do {
            _ = try await ProviderModelCatalog.fetch(for: loopback,
                                                      settings: proxySettings(provider: "L",
                                                                              address: "http://127.0.0.1:7890"),
                                                      session: injected)
            Issue.record("catalog proxy to a loopback provider unexpectedly proceeded")
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
