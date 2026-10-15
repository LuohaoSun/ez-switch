import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

// MARK: - Loopback sidecar stub (URLProtocol): no real network, account or proxy.

private struct StubReply {
    var status: Int
    var headers: [String: String]
    var body: Data
}

private struct CapturedRequest {
    let request: URLRequest
    let body: Data
}

private final class CursorSidecarStub: URLProtocol {
    private static let lock = NSLock()
    private static var handler: (@Sendable (URLRequest) -> StubReply)?
    private static var recorded: [CapturedRequest] = []

    static func install(_ handler: @escaping @Sendable (URLRequest) -> StubReply) {
        lock.lock(); self.handler = handler; recorded = []; lock.unlock()
    }
    static func uninstall() { lock.lock(); handler = nil; recorded = []; lock.unlock() }
    static var captured: [CapturedRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CursorSidecarStub.self]
        cfg.connectionProxyDictionary = [:]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Body may only be readable here; capture it before the test observes it.
        let body = Self.body(of: request)
        Self.lock.lock(); Self.recorded.append(CapturedRequest(request: request, body: body)); let handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let reply = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
}

private func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// Cursor 代理转发：全部用 loopback URLProtocol stub，绝不连接真实 sidecar / 账号。
/// `.serialized` 串行，保证 stub 的静态录制不串扰。
@Suite("Cursor proxy forwarder", .serialized)
struct CursorProxyForwarderTests {

    // MARK: - Fixtures

    private func cursorRemote(_ model: String = "auto") -> RemoteModel {
        RemoteModel(id: UUID(), name: "Cursor · \(model)", apiKey: "", model: model, extraHeaders: [:],
                    apiEndpoints: APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled),
                    source: .cursorProxy)
    }

    private func head(_ endpoint: EndpointKind, headers: HTTPHeaders = HTTPHeaders()) -> HTTPRequestHead {
        let uri: String
        switch endpoint {
        case .chat: uri = "/v1/chat/completions"
        case .responses: uri = "/v1/responses"
        case .messages: uri = "/v1/messages"
        case .gemini: uri = "/v1beta/models/main:generateContent"
        }
        return HTTPRequestHead(version: .http1_1, method: .POST, uri: uri, headers: headers)
    }

    private func connectorRequest(_ endpoint: EndpointKind, body: String, query: String = "",
                                  headers: HTTPHeaders = HTTPHeaders()) -> ConnectorRequest {
        ConnectorRequest(clientHead: head(endpoint, headers: headers), body: Data(body.utf8),
                         endpoint: endpoint, remote: cursorRemote(), query: query,
                         requestStart: nil, attemptStart: nil)
    }

    private func endpoint(_ base: String = "http://127.0.0.1:8317/v1", key: String = "sidecar-key") -> CursorProxyEndpoint {
        CursorProxyEndpoint(baseURL: URL(string: base)!, apiKey: key)
    }

    private func reply(_ status: Int = 200, _ body: String, contentType: String = "application/json") -> StubReply {
        StubReply(status: status, headers: ["Content-Type": contentType], body: Data(body.utf8))
    }

    private func forward(_ request: ConnectorRequest, session: URLSession,
                         endpoint ep: CursorProxyEndpoint? = nil) async throws -> UpstreamResponse {
        try await CursorForwarder.makeRequest(request, endpoint: ep ?? endpoint(), session: session)
    }

    private func collect(_ upstream: UpstreamResponse) async throws -> Data {
        var data = Data()
        for try await chunk in upstream.body { data.append(Data(chunk.readableBytesView)) }
        return data
    }

    private func expectRejected(_ request: ConnectorRequest, endpoint ep: CursorProxyEndpoint,
                                session: URLSession, clientError: Bool) async {
        do {
            _ = try await CursorForwarder.makeRequest(request, endpoint: ep, session: session)
            Issue.record("expected an error for \(ep.baseURL)")
        } catch let error as CursorProxyRequestError {
            #expect(clientError, "gemini rejection is a client error")
            #expect(error.clientError)
        } catch {
            #expect(!clientError, "endpoint config errors must stay fallback-eligible, got client error")
            #expect((error as? any ClientRequestFailure) == nil)
        }
        #expect(CursorSidecarStub.captured.isEmpty, "rejected request must not reach the sidecar")
    }

    // MARK: - Boundary

    @Test func geminiIsRejectedAsClientError() async {
        let session = CursorSidecarStub.session()
        CursorSidecarStub.install { _ in reply(200, "{}") }
        defer { CursorSidecarStub.uninstall() }
        await expectRejected(connectorRequest(.gemini, body: #"{"contents":[]}"#),
                             endpoint: endpoint(), session: session, clientError: true)
    }

    @Test func unsafeEndpointsAreRejectedAsBackendErrors() async {
        let session = CursorSidecarStub.session()
        CursorSidecarStub.install { _ in reply(200, "{}") }
        defer { CursorSidecarStub.uninstall() }
        let body = #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#
        let cases: [CursorProxyEndpoint] = [
            endpoint("https://127.0.0.1:8317/v1"),           // scheme must be http
            endpoint("ftp://127.0.0.1:8317/v1"),
            endpoint("http://evil.example.com:8317/v1"),     // host must be loopback
            endpoint("http://127.0.0.1.evil.example:8317/v1"),
            endpoint("http://127.0.0.1:8317/v2"),            // path must be exactly /v1
            endpoint("http://127.0.0.1:8317/v1/chat"),
            endpoint("http://127.0.0.1:8317//v1//"),
            endpoint("http://user:pass@127.0.0.1:8317/v1"),  // no userinfo
            endpoint("http://127.0.0.1:8317/v1?x=1"),        // no query
            endpoint("http://127.0.0.1:8317/v1#frag"),       // no fragment
            endpoint("http://127.0.0.1/v1"),                 // port required
            endpoint("http://127.0.0.1:0/v1"),
            endpoint("http://127.0.0.1:8317/v1", key: ""),   // key required
        ]
        for ep in cases {
            await expectRejected(connectorRequest(.chat, body: body), endpoint: ep,
                                 session: session, clientError: false)
        }
    }

    // MARK: - Verbatim passthrough (tools / tool results / server state / unknown fields)

    @Test func chatToolsToolResultsAndUnknownFieldsAreForwardedVerbatim() async throws {
        let session = CursorSidecarStub.session()
        let upstreamBody = #"{"id":"c1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
        CursorSidecarStub.install { _ in reply(200, upstreamBody) }
        defer { CursorSidecarStub.uninstall() }

        let body = #"{"model":"main","stream":false,"tool_choice":"auto","unknown_future_field":{"x":1},"tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object"}}}],"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_1","content":"sunny"}]}"#
        let upstream = try await forward(connectorRequest(.chat, body: body, query: "beta=true"), session: session)
        #expect(upstream.response.statusCode == 200)
        #expect(try await collect(upstream) == Data(upstreamBody.utf8))   // passed through, not synthesized

        let sent = try #require(CursorSidecarStub.captured.first)
        #expect(sent.request.url?.host == "127.0.0.1")
        #expect(sent.request.url?.path == "/v1/chat/completions")
        #expect(sent.request.url?.query == "beta=true")
        #expect(sent.request.value(forHTTPHeaderField: "authorization") == "Bearer sidecar-key")

        let payload = jsonObject(sent.body)
        #expect(payload["model"] as? String == "auto")                    // rewritten to the remote model
        #expect(payload["unknown_future_field"] != nil)
        let tools = payload["tools"] as? [[String: Any]]
        #expect(((tools?.first?["function"]) as? [String: Any])?["name"] as? String == "get_weather")
        let messages = payload["messages"] as? [[String: Any]]
        #expect(messages?.count == 3)
        let toolCalls = messages?[1]["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.first?["id"] as? String == "call_1")
        #expect(messages?[2]["role"] as? String == "tool")
        #expect(messages?[2]["tool_call_id"] as? String == "call_1")
        #expect(messages?[2]["content"] as? String == "sunny")
    }

    @Test func responsesServerStateAndToolOutputAreForwardedVerbatim() async throws {
        let session = CursorSidecarStub.session()
        CursorSidecarStub.install { _ in reply(200, #"{"object":"response","status":"completed"}"#) }
        defer { CursorSidecarStub.uninstall() }

        let body = #"{"model":"main","previous_response_id":"resp_1","store":true,"input":[{"type":"function_call_output","call_id":"call_9","output":"42"},{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}"#
        _ = try await forward(connectorRequest(.responses, body: body), session: session)

        let sent = try #require(CursorSidecarStub.captured.first)
        #expect(sent.request.url?.path == "/v1/responses")
        let payload = jsonObject(sent.body)
        #expect(payload["previous_response_id"] as? String == "resp_1")
        #expect(payload["store"] as? Bool == true)
        #expect(payload["model"] as? String == "auto")
        let input = payload["input"] as? [[String: Any]]
        #expect(input?.first?["type"] as? String == "function_call_output")
        #expect(input?.first?["call_id"] as? String == "call_9")
        #expect(input?.first?["output"] as? String == "42")
    }

    // MARK: - Auth isolation & Messages (x-api-key)

    @Test func clientCredentialsAreReplacedAndMessagesUsesApiKey() async throws {
        let session = CursorSidecarStub.session()
        CursorSidecarStub.install { _ in reply(200, #"{"ok":true}"#) }
        defer { CursorSidecarStub.uninstall() }

        var headers = HTTPHeaders()
        headers.add(name: "authorization", value: "Bearer client-token")
        headers.add(name: "x-api-key", value: "client-key")
        headers.add(name: "api-key", value: "client-key-2")
        headers.add(name: "x-goog-api-key", value: "client-google")
        headers.add(name: "anthropic-version", value: "2024-02-01")

        _ = try await forward(connectorRequest(.chat, body: #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#, headers: headers), session: session)
        let chat = try #require(CursorSidecarStub.captured.first)
        #expect(chat.request.value(forHTTPHeaderField: "authorization") == "Bearer sidecar-key")
        for stripped in ["x-api-key", "api-key", "x-goog-api-key"] {
            #expect(chat.request.value(forHTTPHeaderField: stripped) == nil, "client \(stripped) must not leak")
        }

        let toolBody = #"{"model":"m","max_tokens":16,"tools":[{"name":"t","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"hi"}]}"#
        _ = try await forward(connectorRequest(.messages, body: toolBody, headers: headers), session: session)
        let messages = try #require(CursorSidecarStub.captured.last)
        #expect(messages.request.url?.path == "/v1/messages")
        #expect(messages.request.value(forHTTPHeaderField: "x-api-key") == "sidecar-key")
        #expect(messages.request.value(forHTTPHeaderField: "authorization") == nil)
        #expect(messages.request.value(forHTTPHeaderField: "anthropic-version") == "2024-02-01")
        let payload = jsonObject(messages.body)
        #expect(payload["model"] as? String == "auto")
        #expect(payload["max_tokens"] as? Int == 16)
        #expect(((payload["tools"] as? [[String: Any]])?.first?["name"] as? String) == "t")
    }

    // MARK: - Usage / status / streaming

    @Test func reportedUsageFlowsThroughGenericAccumulator() async throws {
        let session = CursorSidecarStub.session()
        let usageBody = #"{"id":"c","object":"chat.completion","usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},"choices":[]}"#
        CursorSidecarStub.install { _ in reply(200, usageBody) }
        defer { CursorSidecarStub.uninstall() }

        let upstream = try await forward(connectorRequest(.chat, body: #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#), session: session)
        #expect(try await collect(upstream) == Data(usageBody.utf8))
        #expect(upstream.usage?.tokens == UsageTokens(input: 5, output: 3))
    }

    @Test func streamingSSEIsPassedThroughUnchanged() async throws {
        let session = CursorSidecarStub.session()
        let sse = "data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}\n\ndata: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1}}\n\ndata: [DONE]\n\n"
        CursorSidecarStub.install { _ in reply(200, sse, contentType: "text/event-stream") }
        defer { CursorSidecarStub.uninstall() }

        let upstream = try await forward(connectorRequest(.chat, body: #"{"model":"m","stream":true,"messages":[{"role":"user","content":"hi"}]}"#), session: session)
        #expect(upstream.response.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        #expect(try await collect(upstream) == Data(sse.utf8))
        #expect(upstream.usage?.tokens == UsageTokens(input: 2, output: 1))
    }

    @Test func non2xxStatusAndBodyArePreserved() async throws {
        let session = CursorSidecarStub.session()
        let errorBody = #"{"error":{"message":"rate limited"}}"#
        CursorSidecarStub.install { _ in StubReply(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "5"], body: Data(errorBody.utf8)) }
        defer { CursorSidecarStub.uninstall() }

        let upstream = try await forward(connectorRequest(.chat, body: #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#), session: session)
        #expect(upstream.response.statusCode == 429)
        #expect(upstream.response.value(forHTTPHeaderField: "Retry-After") == "5")
        #expect(try await collect(upstream) == Data(errorBody.utf8))
        #expect(upstream.usage?.tokens.input == nil)
    }

    // MARK: - RouterServer integration: tool outbound + continued turn, not synthesized

    private func cursorRemoteRecord() -> RemoteModel { cursorRemote("auto") }

    private func boundExtensions() -> ExtensionSettings {
        var settings = ExtensionSettings()
        settings.cursorConnector = CursorConnectorSettings(enabled: true, providerName: "Cursor", providerAdded: true)
        return settings
    }

    private func post(port: Int, path: String, body: String) async throws -> (Int, Data) {
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    @Test func toolTurnAndContinuationAreForwardedNotSynthesized() async throws {
        let fixture = endpoint("http://127.0.0.1:19191/v1", key: "sidecar-key")
        let session = CursorSidecarStub.session()
        let turn = LockedBox(0)
        CursorSidecarStub.install { _ in
            let index = turn.get(); turn.set(index + 1)
            let body: String
            if index == 0 {
                body = #"{"id":"c1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
            } else {
                body = #"{"id":"c2","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"sunny"},"finish_reason":"stop"}]}"#
            }
            return StubReply(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
        defer { CursorSidecarStub.uninstall() }

        let registry = ExtensionRegistry(connectors: [
            CursorExtension.connector(endpoint: { fixture }, session: session, models: { ["auto"] }),
        ])
        let cursor = cursorRemoteRecord()
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: cursor.id)
        var config = AppConfig(port: 0, remotes: [cursor], fakes: [fake])
        config.extensions = boundExtensions()
        let router = Router(registry: registry)
        router.update(config)
        router.setConnectorAvailable(source: .cursorProxy, available: true)
        let server = RouterServer(router: router, session: CursorSidecarStub.session(), extensionRegistry: registry)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let tools = #"[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object"}}}]"#
        let (status1, data1) = try await post(port: port, path: "/v1/chat/completions",
            body: #"{"model":"main","tools":\#(tools),"messages":[{"role":"user","content":"weather?"}]}"#)
        #expect(status1 == 200)
        #expect(String(decoding: data1, as: UTF8.self).contains("call_1"))

        let first = try #require(CursorSidecarStub.captured.first)
        #expect(first.request.url?.path == "/v1/chat/completions")
        let sent1 = jsonObject(first.body)
        #expect(sent1["model"] as? String == "auto")
        #expect(((sent1["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String == "get_weather")

        let (status2, data2) = try await post(port: port, path: "/v1/chat/completions",
            body: #"{"model":"main","messages":[{"role":"user","content":"weather?"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_1","content":"sunny"}]}"#)
        #expect(status2 == 200)
        #expect(String(decoding: data2, as: UTF8.self).contains("sunny"))

        #expect(CursorSidecarStub.captured.count == 2)
        let sent2 = jsonObject(try #require(CursorSidecarStub.captured.last).body)
        let messages = sent2["messages"] as? [[String: Any]]
        #expect(messages?.last?["role"] as? String == "tool")
        #expect(messages?.last?["tool_call_id"] as? String == "call_1")
        #expect(messages?.last?["content"] as? String == "sunny")
    }
}
