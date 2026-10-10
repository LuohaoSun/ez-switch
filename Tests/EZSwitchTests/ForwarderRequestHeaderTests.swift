import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

@Suite("Forwarder request headers")
struct ForwarderRequestHeaderTests {
    private func remote(baseURL: String = "https://api.example.com/v1",
                        extraHeaders: [String: String] = [:],
                        apiKey: String = "sk-upstream") -> RemoteModel {
        RemoteModel(id: UUID(), name: "Test · model", apiKey: apiKey, model: "real-model",
                    extraHeaders: extraHeaders, apiEndpoints: .all(baseURL: baseURL))
    }

    private func head(_ path: String, _ headers: [(String, String)]) -> HTTPRequestHead {
        HTTPRequestHead(version: .http1_1, method: .POST, uri: path, headers: HTTPHeaders(headers))
    }

    // MARK: 普通端到端头的透传

    @Test
    func forwardsCommonSessionAndCustomHeaders() throws {
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/chat/completions", [
                ("content-type", "application/json"),
                ("accept", "text/event-stream"),
                ("user-agent", "claude-cli/1.0.0"),
                ("x-stainless-lang", "js"),
                ("x-session-id", "sess-123"),
                ("openai-beta", "responses=v1"),
                ("x-custom-trace", "trace-abc"),
            ]),
            body: Data(#"{"model":"main"}"#.utf8), endpoint: .chat, remote: remote(), query: "")

        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "user-agent") == "claude-cli/1.0.0")
        #expect(request.value(forHTTPHeaderField: "x-stainless-lang") == "js")
        #expect(request.value(forHTTPHeaderField: "x-session-id") == "sess-123")
        #expect(request.value(forHTTPHeaderField: "openai-beta") == "responses=v1")
        #expect(request.value(forHTTPHeaderField: "x-custom-trace") == "trace-abc")
        #expect(request.httpMethod == "POST")
    }

    @Test
    func defaultsContentTypeWhenClientOmitsIt() throws {
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/chat/completions", []),
            body: Data(#"{"model":"main"}"#.utf8), endpoint: .chat, remote: remote(), query: "")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    // MARK: 客户端鉴权不泄露 / 正确替换

    @Test
    func replacesVendorAuthAndDoesNotLeakClientCredentials() throws {
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/chat/completions", [
                ("authorization", "Bearer local-harness-token"),
                ("x-api-key", "client-leak"),
            ]),
            body: Data(), endpoint: .chat, remote: remote(apiKey: "sk-upstream"), query: "")

        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-upstream")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test
    func messagesReplacesXApiKeyDropsClientBearerAndDefaultsAnthropicVersion() throws {
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/messages", [
                ("x-api-key", "client-leak"),
                ("authorization", "Bearer client-leak"),
                ("anthropic-version", "2024-01-01"),
                ("anthropic-beta", "prompt-caching-2024-07-31"),
            ]),
            body: Data(), endpoint: .messages, remote: remote(apiKey: "upstream-key"), query: "")

        #expect(request.value(forHTTPHeaderField: "x-api-key") == "upstream-key")
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2024-01-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "prompt-caching-2024-07-31")
    }

    @Test
    func messagesUsesDefaultAnthropicVersionWhenAbsent() throws {
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/messages", []),
            body: Data(), endpoint: .messages, remote: remote(apiKey: "upstream-key"), query: "")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    // MARK: hop-by-hop（含 Connection 声明的动态字段）

    @Test
    func excludesHopByHopAndConnectionDeclaredTokens() throws {
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/chat/completions", [
                ("connection", "keep-alive, x-drop-me"),
                ("keep-alive", "timeout=5"),
                ("transfer-encoding", "chunked"),
                ("proxy-authorization", "Basic secret"),
                ("te", "trailers"),
                ("x-drop-me", "should-not-forward"),
                ("x-keep-me", "forwarded"),
            ]),
            body: Data(), endpoint: .chat, remote: remote(), query: "")

        #expect(request.value(forHTTPHeaderField: "connection") == nil)
        #expect(request.value(forHTTPHeaderField: "keep-alive") == nil)
        #expect(request.value(forHTTPHeaderField: "transfer-encoding") == nil)
        #expect(request.value(forHTTPHeaderField: "proxy-authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "te") == nil)
        #expect(request.value(forHTTPHeaderField: "x-drop-me") == nil)
        #expect(request.value(forHTTPHeaderField: "x-keep-me") == "forwarded")
    }

    @Test
    func excludesTransportManagedHeaders() throws {
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/chat/completions", [
                ("host", "client.invalid"),
                ("content-length", "999"),
                ("accept-encoding", "gzip, br"),
            ]),
            body: Data(#"{"model":"main"}"#.utf8), endpoint: .chat, remote: remote(), query: "")

        #expect(request.value(forHTTPHeaderField: "host") == nil)
        #expect(request.value(forHTTPHeaderField: "content-length") == nil)
        #expect(request.value(forHTTPHeaderField: "accept-encoding") == nil)
    }

    // MARK: 重复头

    @Test
    func preservesRepeatedHeaderValuesInOrder() throws {
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/messages", [
                ("anthropic-beta", "prompt-caching-2024-07-31"),
                ("anthropic-beta", "computer-use-2024-10-22"),
                ("x-session-id", "a"),
                ("x-session-id", "b"),
            ]),
            body: Data(), endpoint: .messages, remote: remote(apiKey: "k"), query: "")

        #expect(request.value(forHTTPHeaderField: "anthropic-beta")
                == "prompt-caching-2024-07-31,computer-use-2024-10-22")
        #expect(request.value(forHTTPHeaderField: "x-session-id") == "a,b")
    }

    // MARK: extraHeaders 最后覆盖

    @Test
    func extraHeadersOverrideClientAndRouterValues() throws {
        let configured = remote(extraHeaders: [
            "authorization": "Bearer custom-auth",
            "x-session-id": "from-config",
            "x-new-header": "1",
        ])
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/chat/completions", [
                ("authorization", "Bearer client"),
                ("x-session-id", "from-client"),
            ]),
            body: Data(), endpoint: .chat, remote: configured, query: "")

        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer custom-auth")
        #expect(request.value(forHTTPHeaderField: "x-session-id") == "from-config")
        #expect(request.value(forHTTPHeaderField: "x-new-header") == "1")
    }

    // MARK: OpenCode Go 现有行为

    @Test
    func openCodeGoForwardsSessionHeadersAndOnlyDefaultsUserAgent() throws {
        let go = RemoteModel(id: UUID(), name: "OpenCode Go", apiKey: "sk-go", model: "m",
                             extraHeaders: [:],
                             apiEndpoints: .enabled([.chat], baseURL: "https://opencode.ai/zen/go/v1"))
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/chat/completions", [
                ("x-opencode-session", "sess-1"),
                ("x-opencode-request", "req-1"),
                ("x-opencode-client", "opencode"),
                ("x-opencode-project", "proj"),
                ("x-opencode-other", "other"),
            ]),
            body: Data(), endpoint: .chat, remote: go, query: "")

        #expect(request.value(forHTTPHeaderField: "x-opencode-session") == "sess-1")
        #expect(request.value(forHTTPHeaderField: "x-opencode-request") == "req-1")
        #expect(request.value(forHTTPHeaderField: "x-opencode-client") == "opencode")
        #expect(request.value(forHTTPHeaderField: "x-opencode-project") == "proj")
        // 无白名单，任何通用会话头都透传
        #expect(request.value(forHTTPHeaderField: "x-opencode-other") == "other")
        // 客户端未带 user-agent → 补 EZSwitch 默认；不是固定 session
        #expect(request.value(forHTTPHeaderField: "user-agent")?.hasPrefix("EZSwitch/") == true)
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-go")
    }

    @Test
    func openCodeGoForwardsClientUserAgentWhenPresent() throws {
        let go = RemoteModel(id: UUID(), name: "OpenCode Go", apiKey: "sk-go", model: "m",
                             extraHeaders: [:],
                             apiEndpoints: .enabled([.chat], baseURL: "https://opencode.ai/zen/go/v1"))
        let request = try Forwarder.buildRequest(
            clientHead: head("/v1/chat/completions", [("user-agent", "opencode/1.2.3")]),
            body: Data(), endpoint: .chat, remote: go, query: "")
        #expect(request.value(forHTTPHeaderField: "user-agent") == "opencode/1.2.3")
    }
}
