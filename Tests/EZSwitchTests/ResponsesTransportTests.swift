import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

enum BridgeTestExecutable {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/ezs-responses-bridge")
    static var available: Bool { FileManager.default.isExecutableFile(atPath: url.path) }
}

@MainActor
@Suite("Responses transport")
struct ResponsesTransportTests {
    private func remote(provider: String, chat: EndpointSetting, responses: EndpointSetting) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · model", apiKey: "test-secret", model: "real-model",
                    extraHeaders: [:], apiEndpoints: APIEndpointSettings(chat: chat, responses: responses,
                                                                        messages: .disabled))
    }

    /// 旧的 responsesTransport 字段不再参与编码；解码仍然被 AppConfig 一次性迁移读取。
    @Test
    func legacyTransportFieldDecodesButIsNotEncoded() throws {
        let json = #"{"chat":{"enabled":true,"baseURL":"https://chat.test/v1"},"responses":{"enabled":false,"baseURL":""},"messages":{"enabled":false,"baseURL":""},"responsesTransport":"chatCompletions"}"#
        let settings = try JSONDecoder().decode(APIEndpointSettings.self, from: Data(json.utf8))
        #expect(settings.chat.enabled)
        #expect(!settings.responses.enabled)
        let encoded = try JSONEncoder().encode(settings)
        #expect(String(data: encoded, encoding: .utf8)?.contains("responsesTransport") == false)
    }

    /// adapter == .chatToResponses 时复用 Chat 地址与 Bearer 鉴权，忽略 native Responses URL。
    @Test
    func chatToResponsesAdapterUsesChatURLAndAuth() throws {
        let remote = remote(provider: "Alpha",
                            chat: EndpointSetting(enabled: true, baseURL: "https://chat.test/v1"),
                            responses: EndpointSetting(enabled: true, baseURL: "https://responses.test/v1"))
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/responses")
        let request = try Forwarder.buildRequest(clientHead: head, body: Data(#"{"model":"main","input":"Hello"}"#.utf8),
                                                 endpoint: .responses, remote: remote,
                                                 adapter: .chatToResponses, query: "x=1")
        #expect(request.url?.absoluteString == "https://chat.test/v1/chat/completions?x=1")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer test-secret")
    }

    /// 默认 adapter == .passthrough 走 native Responses 地址，不被 Chat 配置影响。
    @Test
    func passthroughUsesNativeResponsesURL() throws {
        let remote = remote(provider: "Alpha",
                            chat: EndpointSetting(enabled: true, baseURL: "https://chat.test/v1"),
                            responses: EndpointSetting(enabled: true, baseURL: "https://responses.test/v1"))
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/responses")
        let request = try Forwarder.buildRequest(clientHead: head, body: Data(#"{"model":"main","input":"Hello"}"#.utf8),
                                                 endpoint: .responses, remote: remote, query: "")
        #expect(request.url?.absoluteString == "https://responses.test/v1/responses")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer test-secret")
    }
}

@Suite("Responses translator process", .enabled(if: BridgeTestExecutable.available,
      "Run ./Scripts/build-translator.sh to enable bridge process tests"))
struct ResponseTranslatorTests {
    private var executable: URL { BridgeTestExecutable.url }
    @Test
    func processRoundTripAndStateIsolation() async throws {
        let translator = try ResponseTranslator(executable: executable)
        defer { translator.stop() }
        let chat = try await translator.prepare(Data(#"{"model":"main","input":"Hello","stream":false}"#.utf8), model: "real")
        let parsed = try #require(JSONSerialization.jsonObject(with: chat) as? [String: Any])
        #expect(parsed["model"] as? String == "real")
        #expect(parsed["messages"] != nil)
        let converted = try await translator.response(Data(#"{"id":"chatcmpl_1","object":"chat.completion","created":1,"model":"real","choices":[{"index":0,"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}"#.utf8))
        let reply = try #require(JSONSerialization.jsonObject(with: converted) as? [String: Any])
        #expect(reply["object"] as? String == "response")
        #expect(reply["status"] as? String == "completed")
        #expect(String(data: converted, encoding: .utf8)?.contains("OK") == true)
    }
    @Test
    func unsupportedHistoryReferenceFailsBeforeUpstream() async throws {
        let translator = try ResponseTranslator(executable: executable)
        defer { translator.stop() }
        do {
            _ = try await translator.prepare(Data(#"{"model":"main","input":"Hi","previous_response_id":"resp_old"}"#.utf8), model: "real")
            Issue.record("unsupported reference was accepted")
        } catch let error as ResponseTranslationError {
            #expect(error.clientError)
            #expect(error.description.contains("previous_response_id"))
        }
    }
}
