import Foundation
import Testing
@testable import EZSwitch

/// Gemini 协议在配置层的语义：默认禁用、工厂/迁移不静默启用、参与校验/去重/摘要。
@MainActor
@Suite("Gemini endpoint config")
struct GeminiEndpointConfigTests {

    private func remote(_ name: String = "P · m", model: String = "m",
                        endpoints: APIEndpointSettings, id: UUID = UUID()) -> RemoteModel {
        RemoteModel(id: id, name: name, apiKey: "k", model: model,
                    extraHeaders: [:], apiEndpoints: endpoints)
    }

    @Test func endpointKindIdentityAndDisplayName() {
        #expect(EndpointKind.gemini.rawValue == "gemini")
        #expect(EndpointKind.gemini.displayName == "Gemini")
        #expect(EndpointKind.allCases.contains(.gemini))
    }

    @Test func decodingSettingsWithoutGeminiLeavesItDisabled() throws {
        let json = #"{"chat":{"enabled":true,"baseURL":"https://x.example/v1"}}"#
        let settings = try JSONDecoder().decode(APIEndpointSettings.self, from: Data(json.utf8))
        #expect(settings.chat.enabled)
        #expect(settings.gemini == .disabled)
        #expect(settings.responses == .disabled)
        #expect(settings.messages == .disabled)
    }

    @Test func historicalAllFactoryNeverEnablesGemini() {
        let all = APIEndpointSettings.all(baseURL: "https://x.example/v1")
        #expect(all.gemini == .disabled)
        #expect(all.enabledKinds == [.chat, .responses, .messages])
    }

    @Test func enabledFactorySupportsGeminiExplicitly() {
        let onlyGemini = APIEndpointSettings.enabled([.gemini], baseURL: "https://g.example/v1beta")
        #expect(onlyGemini.gemini.enabled)
        #expect(onlyGemini.gemini.baseURL == "https://g.example/v1beta")
        #expect(!onlyGemini.chat.enabled && !onlyGemini.responses.enabled && !onlyGemini.messages.enabled)
        #expect(onlyGemini.enabledKinds == [.gemini])

        let mixed = APIEndpointSettings.enabled([.chat, .gemini], baseURL: "https://m.example/v1")
        #expect(mixed.chat.enabled && mixed.gemini.enabled && !mixed.responses.enabled)
        #expect(mixed.enabledKinds == [.chat, .gemini])
    }

    @Test func legacyRemoteFieldMigrationDoesNotEnableGemini() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Alpha · one","baseURL":"https://alpha.example",
         "apiKey":"a","model":"one","extraHeaders":{}}
        """
        let remote = try JSONDecoder().decode(RemoteModel.self, from: Data(json.utf8))
        #expect(remote.supports(.chat))
        #expect(remote.supports(.responses))
        #expect(remote.supports(.messages))
        #expect(!remote.supports(.gemini))
        #expect(remote.apiEndpoints.gemini == .disabled)
    }

    @Test func validationIncludesGemini() {
        let missing = APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled,
                                          gemini: EndpointSetting(enabled: true, baseURL: ""))
        #expect(ConfigStore.validateEndpoints(missing) == "Gemini 已启用，请填写 Base URL")

        let bad = APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled,
                                      gemini: EndpointSetting(enabled: true, baseURL: "ftp://g.example"))
        #expect(ConfigStore.validateEndpoints(bad) != nil)

        let valid = APIEndpointSettings.enabled([.gemini], baseURL: "https://generativelanguage.googleapis.com/v1beta")
        #expect(ConfigStore.validateEndpoints(valid) == nil)
    }

    @Test func summaryIncludesGemini() {
        let gemini = remote(endpoints: .enabled([.gemini], baseURL: "https://g.example/v1beta"))
        #expect(gemini.endpointSummary == "Gemini")
        #expect(gemini.endpointBaseURLs == ["https://g.example/v1beta"])

        let chatAndGemini = remote(endpoints: .enabled([.chat, .gemini], baseURL: "https://x.example/v1"))
        #expect(chatAndGemini.endpointSummary == "Chat Completions / Gemini")
    }

    @Test func dedupeDistinguishesGeminiSettings() {
        let a = remote("P · m", model: "m", endpoints: .enabled([.chat], baseURL: "https://x.example/v1"))
        var b = remote("P · m", model: "m", endpoints: .enabled([.chat], baseURL: "https://x.example/v1"))
        b.apiEndpoints.gemini = EndpointSetting(enabled: true, baseURL: "https://g.example/v1beta")

        let (distinct, distinctChanged) = ConfigStore.mergeDuplicateRemotes(
            AppConfig(port: 8788, remotes: [a, b], fakes: []))
        #expect(!distinctChanged)
        #expect(distinct.remotes.count == 2)

        b.apiEndpoints.gemini = a.apiEndpoints.gemini
        let (merged, mergedChanged) = ConfigStore.mergeDuplicateRemotes(
            AppConfig(port: 8788, remotes: [a, b], fakes: []))
        #expect(mergedChanged)
        #expect(merged.remotes.count == 1)
    }

    @Test func routerFakesSupportingGeminiFilters() {
        let geminiRemote = remote(endpoints: .enabled([.gemini], baseURL: "https://g.example/v1beta"))
        let chatRemote = remote("C · c", model: "c", endpoints: .enabled([.chat], baseURL: "https://c.example/v1"))
        let geminiFake = FakeModel(id: UUID(), fakeModelID: "g-fake", displayName: "g-fake",
                                   remoteID: geminiRemote.id)
        let chatFake = FakeModel(id: UUID(), fakeModelID: "c-fake", displayName: "c-fake",
                                 remoteID: chatRemote.id)
        let router = Router()
        router.update(AppConfig(port: 0, remotes: [geminiRemote, chatRemote], fakes: [geminiFake, chatFake]))

        #expect(router.fakes(supporting: .gemini).map(\.fakeModelID) == ["g-fake"])
        #expect(router.fakes(supporting: .chat).map(\.fakeModelID) == ["c-fake"])
        #expect(router.fakes(supporting: .responses).isEmpty)
    }
}
