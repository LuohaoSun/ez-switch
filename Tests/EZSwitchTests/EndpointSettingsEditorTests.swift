import Testing
@testable import EZSwitch

/// Exercises the pure transitions behind `EndpointSettingsEditor` directly, so the
/// shared editor's switch/menu semantics are covered without mirroring UI wiring.
@MainActor
@Suite("Endpoint settings editor")
struct EndpointSettingsEditorTests {
    private func settings(chat: Bool = true, chatURL: String = "https://chat.test/v1",
                          responses: Bool = true, responsesURL: String = "https://responses.test/v1",
                          transport: ResponsesTransport = .native) -> APIEndpointSettings {
        APIEndpointSettings(
            chat: EndpointSetting(enabled: chat, baseURL: chatURL),
            responses: EndpointSetting(enabled: responses, baseURL: responsesURL),
            messages: .disabled,
            responsesTransport: transport)
    }

    @Test
    func responsesToggleOffOnKeepsURLAndDefaultsNative() {
        var s = settings()
        #expect(s.supportsResponses)

        EndpointSettingsEditorLogic.setResponsesEnabled(false, &s)
        #expect(!s.supportsResponses)
        #expect(s.responsesTransport == .native)
        #expect(s.responsesMode == .disabled)
        #expect(!s.responses.enabled)
        #expect(s.responses.baseURL == "https://responses.test/v1")

        EndpointSettingsEditorLogic.setResponsesEnabled(true, &s)
        #expect(s.supportsResponses)
        #expect(s.responsesTransport == .native)
        #expect(s.responsesMode == .native)
        #expect(s.responses.baseURL == "https://responses.test/v1")
    }

    @Test
    func selectingBridgeEnablesChatAndKeepsSwitchOn() {
        // Chat disabled: bridging must still be usable, so Chat is enabled.
        var s = settings(chat: false)
        EndpointSettingsEditorLogic.setResponsesTransport(.chatCompletions, &s)
        #expect(s.responsesTransport == .chatCompletions)
        #expect(s.chat.enabled)
        #expect(!s.responses.enabled)
        #expect(s.supportsResponses)
        #expect(s.responsesMode == .chatCompletions)
        #expect(ConfigStore.validateEndpoints(s) == nil)
    }

    @Test
    func turningResponsesOffFromBridgeResetsNativeTransport() {
        var s = settings()
        EndpointSettingsEditorLogic.setResponsesTransport(.chatCompletions, &s)
        #expect(s.responsesTransport == .chatCompletions)

        EndpointSettingsEditorLogic.setResponsesEnabled(false, &s)
        #expect(!s.supportsResponses)
        #expect(s.responsesTransport == .native)
        #expect(s.responsesMode == .disabled)

        // Re-enabling starts native again, keeping the stored response URL.
        EndpointSettingsEditorLogic.setResponsesEnabled(true, &s)
        #expect(s.responsesMode == .native)
        #expect(s.responsesTransport == .native)
        #expect(s.responses.baseURL == "https://responses.test/v1")
    }

    @Test
    func disablingChatWhileBridgedClosesResponses() {
        // Prevents a saved bridge config from rendering as an off switch.
        var s = settings()
        EndpointSettingsEditorLogic.setResponsesTransport(.chatCompletions, &s)
        EndpointSettingsEditorLogic.setChatEnabled(false, &s)
        #expect(!s.chat.enabled)
        #expect(s.responsesTransport == .native)
        #expect(!s.supportsResponses)
        #expect(s.responsesMode == .disabled)
    }

    @Test
    func disablingChatLeavesNativeResponsesUntouched() {
        var s = settings()
        EndpointSettingsEditorLogic.setChatEnabled(false, &s)
        #expect(!s.chat.enabled)
        #expect(s.responsesTransport == .native)
        #expect(s.responsesMode == .native)
        #expect(s.supportsResponses)
    }

    @Test
    func switchingTransportKeepsStoredResponsesURL() {
        var s = settings()
        let url = s.responses.baseURL
        EndpointSettingsEditorLogic.setResponsesTransport(.chatCompletions, &s)
        #expect(s.responses.baseURL == url)
        EndpointSettingsEditorLogic.setResponsesTransport(.native, &s)
        #expect(s.responses.baseURL == url)
        #expect(s.responses.enabled)
        #expect(s.responsesTransport == .native)
    }
}
