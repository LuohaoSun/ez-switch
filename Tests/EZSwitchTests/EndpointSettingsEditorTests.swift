import Foundation
import Testing
@testable import EZSwitch

/// Exercises the pure transitions behind `EndpointSettingsEditor` directly, so the
/// editor's native switch semantics are covered without mirroring UI wiring.
@MainActor
@Suite("Endpoint settings editor")
struct EndpointSettingsEditorTests {
    private func settings(chat: Bool = true, chatURL: String = "https://chat.test/v1",
                          responses: Bool = true, responsesURL: String = "https://responses.test/v1") -> APIEndpointSettings {
        APIEndpointSettings(
            chat: EndpointSetting(enabled: chat, baseURL: chatURL),
            responses: EndpointSetting(enabled: responses, baseURL: responsesURL),
            messages: .disabled)
    }

    private func remote(_ settings: APIEndpointSettings) -> RemoteModel {
        RemoteModel(id: UUID(), name: "P · m", apiKey: "", model: "m",
                    extraHeaders: [:], apiEndpoints: settings)
    }

    @Test
    func enablingResponsesLeavesChatUntouched() {
        var s = settings(chat: false)
        EndpointSettingsEditorLogic.setEndpointEnabled(true, .responses, &s)
        #expect(s.responses.enabled)
        #expect(!s.chat.enabled)
        #expect(s.chat.baseURL == "https://chat.test/v1")
    }

    @Test
    func disablingChatLeavesNativeResponsesUntouched() {
        var s = settings()
        EndpointSettingsEditorLogic.setEndpointEnabled(false, .chat, &s)
        #expect(!s.chat.enabled)
        #expect(s.responses.enabled)
        #expect(s.responses.baseURL == "https://responses.test/v1")
        #expect(ConfigStore.validateEndpoints(s) == nil)
    }

    @Test
    func togglingResponsesKeepsBothURLs() {
        var s = settings()
        EndpointSettingsEditorLogic.setEndpointEnabled(false, .responses, &s)
        #expect(!s.responses.enabled)
        #expect(s.responses.baseURL == "https://responses.test/v1")
        #expect(s.chat.enabled)
        #expect(s.chat.baseURL == "https://chat.test/v1")

        EndpointSettingsEditorLogic.setEndpointEnabled(true, .responses, &s)
        #expect(s.responses.enabled)
        #expect(s.responses.baseURL == "https://responses.test/v1")
        #expect(s.chat.enabled)
        #expect(s.chat.baseURL == "https://chat.test/v1")
    }

    @Test
    func nativeProtocolsAreIndependent() {
        var s = settings()
        EndpointSettingsEditorLogic.setEndpointEnabled(true, .messages, &s)
        s.messages.baseURL = "https://messages.test"
        EndpointSettingsEditorLogic.setEndpointEnabled(true, .gemini, &s)
        s.gemini.baseURL = "https://gemini.test/v1beta"
        #expect(s.chat.enabled && s.responses.enabled && s.messages.enabled && s.gemini.enabled)

        EndpointSettingsEditorLogic.setEndpointEnabled(false, .messages, &s)
        #expect(!s.messages.enabled)
        #expect(s.chat.enabled && s.responses.enabled && s.gemini.enabled)
        #expect(s.messages.baseURL == "https://messages.test")
    }

    /// `supports(.responses)` must follow the native Responses switch alone.
    @Test
    func responsesSupportFollowsNativeSwitchOnly() {
        #expect(!remote(settings(responses: false)).supports(.responses))
        #expect(remote(settings()).supports(.responses))

        var s = settings()
        EndpointSettingsEditorLogic.setEndpointEnabled(false, .responses, &s)
        #expect(!remote(s).supports(.responses))
        #expect(remote(s).supports(.chat))
    }

    @Test
    func exampleBaseURLsStayProtocolSpecific() {
        #expect(EndpointSettingsEditorLogic.exampleBaseURL(for: .chat) == "https://api.example.com/v1")
        #expect(EndpointSettingsEditorLogic.exampleBaseURL(for: .responses) == "https://api.example.com/v1")
        #expect(EndpointSettingsEditorLogic.exampleBaseURL(for: .messages) == "https://api.example.com")
        #expect(EndpointSettingsEditorLogic.exampleBaseURL(for: .gemini) == "https://generativelanguage.googleapis.com/v1beta")
    }
}
