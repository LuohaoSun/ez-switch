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
    @Test
    func legacySettingsKeepNativeTransport() throws {
        let json = #"{"chat":{"enabled":true,"baseURL":"https://chat.test/v1"},"responses":{"enabled":false,"baseURL":""},"messages":{"enabled":false,"baseURL":""}}"#
        let settings = try JSONDecoder().decode(APIEndpointSettings.self, from: Data(json.utf8))
        #expect(settings.responsesTransport == .native)
        var translated = settings
        translated.responsesTransport = .chatCompletions
        #expect(try JSONDecoder().decode(APIEndpointSettings.self, from: JSONEncoder().encode(translated)) == translated)
    }

    @Test
    func responsesModesReuseChatURLAndPreserveNativeURL() throws {
        var settings = APIEndpointSettings(
            chat: EndpointSetting(enabled: true, baseURL: "https://chat.test/v1"),
            responses: EndpointSetting(enabled: true, baseURL: "https://responses.test/v1"),
            messages: .disabled)
        #expect(settings.responsesMode == .native)

        settings.setResponsesMode(.chatCompletions)
        #expect(settings.responsesMode == .chatCompletions)
        #expect(settings.supportsResponses)
        #expect(settings.chat.baseURL == "https://chat.test/v1")
        #expect(settings.responses.baseURL == "https://responses.test/v1")
        let remote = RemoteModel(id: UUID(), name: "test · model", apiKey: "", model: "model",
                                 extraHeaders: [:], apiEndpoints: settings)
        #expect(remote.endpointBaseURLs == ["https://chat.test/v1"])
        #expect(ConfigStore.validateEndpoints(settings) == nil)

        settings.setResponsesMode(.native)
        #expect(settings.responsesMode == .native)
        #expect(settings.responses.baseURL == "https://responses.test/v1")

        settings.setResponsesMode(.disabled)
        #expect(settings.responsesMode == .disabled)
        #expect(!settings.supportsResponses)
        settings.setResponsesMode(.chatCompletions)
        settings.setResponsesMode(.disabled)
        #expect(settings.responsesMode == .disabled)
        #expect(settings.responses.baseURL == "https://responses.test/v1")
    }

    @Test
    func translationUsesChatURLAndAuthWithoutNativeResponseURL() throws {
        let settings = APIEndpointSettings(
            chat: EndpointSetting(enabled: true, baseURL: "https://chat.test/v1"),
            responses: .disabled, messages: .disabled, responsesTransport: .chatCompletions)
        let remote = RemoteModel(id: UUID(), name: "Alpha · model", apiKey: "test-secret", model: "real-model",
                                 extraHeaders: [:], apiEndpoints: settings)
        #expect(remote.supports(.responses))
        #expect(ConfigStore.validateEndpoints(settings) == nil)
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/responses")
        let request = try Forwarder.buildRequest(clientHead: head, body: Data(#"{"model":"main","input":"Hello"}"#.utf8),
                                                 endpoint: .responses, remote: remote, query: "x=1")
        #expect(request.url?.absoluteString == "https://chat.test/v1/chat/completions?x=1")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer test-secret")
        var disabled = settings
        disabled.chat.enabled = false
        #expect(ConfigStore.validateEndpoints(disabled) != nil)
    }
}

@Suite("Responses translator process", .enabled(if: BridgeTestExecutable.available,
      "Run ./build-translator.sh to enable bridge process tests"))
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
