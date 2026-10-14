import Foundation
import Testing
@testable import EZSwitch

/// Canned upstream for the injected `ProviderModelCatalog` session. File-private so it
/// never collides with other suites' helpers; the global `Forwarder.session` is untouched.
private final class GeminiMockURLProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data(#"{"models":[]}"#.utf8)
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
        guard let handler = GeminiMockURLProtocol.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Gemini provider preset and catalog", .serialized)
struct GeminiProviderTests {
    // MARK: - Helpers

    private func geminiRemote(apiKey: String = "g-key",
                              extraHeaders: [String: String] = [:]) -> RemoteModel {
        RemoteModel(id: UUID(), name: "Gemini · model", apiKey: apiKey, model: "model",
                    extraHeaders: extraHeaders,
                    apiEndpoints: APIEndpointSettings(
                        chat: EndpointSetting(enabled: true,
                                              baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
                        responses: .disabled,
                        messages: .disabled,
                        gemini: EndpointSetting(enabled: true,
                                                baseURL: "https://generativelanguage.googleapis.com/v1beta")))
    }

    private func chatOnlyRemote() -> RemoteModel {
        RemoteModel(id: UUID(), name: "OpenAI · model", apiKey: "o-key", model: "model",
                    extraHeaders: [:],
                    apiEndpoints: APIEndpointSettings(
                        chat: EndpointSetting(enabled: true, baseURL: "https://api.openai.com/v1"),
                        responses: .disabled, messages: .disabled))
    }

    private func mockSession(_ handler: @escaping (URLRequest) -> GeminiMockURLProtocol.Reply) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiMockURLProtocol.self]
        GeminiMockURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    private func pageToken(_ request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "pageToken" }?.value
    }

    private static func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Preset

    @Test func geminiPresetKeepsIdentityAndAddsNativeEndpoint() throws {
        let preset = try #require(ProviderPreset.all.first { $0.id == "gemini" })
        #expect(preset.name == "Gemini")
        #expect(preset.iconName == "google")
        // OpenAI 兼容 chat 前缀保持不变。
        #expect(preset.endpoints.chat == EndpointSetting(
            enabled: true, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"))
        // 新增原生 gemini，base 只到 /v1beta。
        #expect(preset.endpoints.gemini == EndpointSetting(
            enabled: true, baseURL: "https://generativelanguage.googleapis.com/v1beta"))
        #expect(!preset.endpoints.responses.enabled)
        #expect(!preset.endpoints.messages.enabled)
    }

    @Test func onlyGeminiPresetEnablesNativeGemini() {
        let others = ProviderPreset.all.filter { $0.id != "gemini" }
        #expect(others.allSatisfy { !$0.endpoints.gemini.enabled })
    }

    // MARK: - Catalog kind selection

    @Test func catalogPrefersNativeGeminiWhenEnabled() {
        #expect(ProviderModelCatalog.catalogKind(for: geminiRemote()) == .gemini)
        #expect(ProviderModelCatalog.catalogKind(for: chatOnlyRemote()) == .chat)
        // Gemini 关闭后回落到 chat。
        var remote = geminiRemote()
        remote.apiEndpoints.gemini.enabled = false
        #expect(ProviderModelCatalog.catalogKind(for: remote) == .chat)
    }

    @Test func geminiListRequestUsesNativeBaseAndGoogKey() throws {
        let remote = geminiRemote(extraHeaders: ["x-provider": "custom"])
        let request = try ProviderModelCatalog.request(for: remote)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-provider") == "custom")
    }

    // MARK: - Native name parsing

    @Test func geminiModelNameStripsSinglePrefixAndRejectsInvalid() {
        #expect(ProviderModelCatalog.geminiModelName("models/gemini-2.0-pro") == "gemini-2.0-pro")
        #expect(ProviderModelCatalog.geminiModelName("  models/gemini-2.0-flash  ") == "gemini-2.0-flash")
        #expect(ProviderModelCatalog.geminiModelName("gemini-2.0-pro") == "gemini-2.0-pro")
        #expect(ProviderModelCatalog.geminiModelName(nil) == nil)
        #expect(ProviderModelCatalog.geminiModelName("") == nil)
        #expect(ProviderModelCatalog.geminiModelName("models/") == nil)
        #expect(ProviderModelCatalog.geminiModelName("tunedModels/foo") == nil)
        #expect(ProviderModelCatalog.geminiModelName("models/gemini:generateContent") == nil)
        #expect(ProviderModelCatalog.geminiModelName("gemini 2.0") == nil)
        for name in ["..", "models/../escape", "models/x?key=bad", "models/x#fragment", "models/x%2Fescape"] {
            #expect(ProviderModelCatalog.geminiModelName(name) == nil)
        }
    }

    // MARK: - Pagination (injected mock session)

    @Test func geminiFetchPaginatesFiltersAndDedupes() async throws {
        let session = mockSession { request in
            switch self.pageToken(request) {
            case .none:
                return GeminiMockURLProtocol.Reply(body: GeminiProviderTests.body("""
                {"models":[
                  {"name":"models/gemini-2.0-pro","supportedGenerationMethods":["generateContent","countTokens"]},
                  {"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]}
                ],"nextPageToken":"T1"}
                """))
            case "T1":
                return GeminiMockURLProtocol.Reply(body: GeminiProviderTests.body("""
                {"models":[
                  {"name":"models/gemini-2.0-flash","supportedGenerationMethods":["generateContent"]},
                  {"name":"models/gemini-2.0-pro","supportedGenerationMethods":["generateContent"]}
                ]}
                """))
            default:
                return GeminiMockURLProtocol.Reply(body: GeminiProviderTests.body(#"{"models":[]}"#))
            }
        }
        defer {
            session.invalidateAndCancel()
            GeminiMockURLProtocol.handler = nil
        }

        let models = try await ProviderModelCatalog.fetch(for: geminiRemote(), session: session)
        // embedding 被过滤，重复项去重，结果排序。
        #expect(models == ["gemini-2.0-flash", "gemini-2.0-pro"])
    }

    @Test func geminiFetchStopsOnRepeatedPageToken() async throws {
        var pages = 0
        let session = mockSession { _ in
            pages += 1
            return GeminiMockURLProtocol.Reply(body: GeminiProviderTests.body("""
            {"models":[{"name":"models/gemini-loop","supportedGenerationMethods":["generateContent"]}],
             "nextPageToken":"LOOP"}
            """))
        }
        defer {
            session.invalidateAndCancel()
            GeminiMockURLProtocol.handler = nil
        }

        let models = try await ProviderModelCatalog.fetch(for: geminiRemote(), session: session)
        #expect(models == ["gemini-loop"])
        // 第二次拿到已见过的 token 即停止，不会无限分页。
        #expect(pages == 2)
    }

    @Test func geminiFetchSurfacesHTTPStatus() async {
        let session = mockSession { _ in GeminiMockURLProtocol.Reply(status: 403) }
        defer {
            session.invalidateAndCancel()
            GeminiMockURLProtocol.handler = nil
        }
        await #expect(throws: ProviderModelCatalog.CatalogError.self) {
            _ = try await ProviderModelCatalog.fetch(for: geminiRemote(), session: session)
        }
    }

    @Test func chatOnlyFetchStillUsesOpenAIListShape() async throws {
        let session = mockSession { _ in
            GeminiMockURLProtocol.Reply(body: GeminiProviderTests.body(#"{"data":[{"id":"gpt-x"},{"id":"gpt-x"},{"id":"gpt-a"}]}"#))
        }
        defer {
            session.invalidateAndCancel()
            GeminiMockURLProtocol.handler = nil
        }
        let models = try await ProviderModelCatalog.fetch(for: chatOnlyRemote(), session: session)
        #expect(models == ["gpt-a", "gpt-x"])
    }

    // MARK: - UI

    @Test func geminiIsTheFourthProtocolWithNativeExampleBase() {
        #expect(EndpointKind.allCases == [.chat, .responses, .messages, .gemini])
        #expect(EndpointSettingsEditorLogic.exampleBaseURL(for: .gemini)
                == "https://generativelanguage.googleapis.com/v1beta")
        // 原生 Gemini 没有 transport：默认禁用，开关直接落到 enabled。
        var settings = APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled)
        #expect(!settings.gemini.enabled)
        settings[.gemini] = EndpointSetting(enabled: true,
                                            baseURL: "https://generativelanguage.googleapis.com/v1beta")
        #expect(settings.gemini.enabled)
        #expect(settings[.gemini].baseURL == "https://generativelanguage.googleapis.com/v1beta")
    }
}
