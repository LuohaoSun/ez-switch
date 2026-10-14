import Foundation
import Testing
@testable import EZSwitch

@MainActor
@Suite("Provider preset draft")
struct ProviderPresetDraftTests {

    @Test
    func choosingPresetEntersConnectionStageWithSelection() {
        let draft = ProviderPresetDraft()
        draft.choose(preset("Z.AI Coding", id: "zai-coding"))

        #expect(draft.stage == .connection)
        #expect(draft.selectedPreset?.id == "zai-coding")
    }

    @Test
    func customChoiceEntersConnectionStageWithoutPreset() {
        let draft = ProviderPresetDraft()
        draft.choose(preset("OpenCode", id: "opencode"))
        draft.chooseCustom()

        #expect(draft.stage == .connection)
        #expect(draft.selectedPreset == nil)
    }

    @Test
    func backToPresetsDiscardsUncommittedSelection() {
        let draft = ProviderPresetDraft()
        draft.choose(preset("OpenCode", id: "opencode"))
        draft.backToPresets()

        #expect(draft.stage == .presets)
        #expect(draft.selectedPreset == nil)
    }

    @Test
    func searchMatchesNameAndId() {
        let draft = ProviderPresetDraft()
        let all = [
            preset("智谱 Coding", id: "zhipu-coding"),
            preset("Z.AI Coding", id: "zai-coding"),
            preset("OpenCode", id: "opencode"),
        ]

        draft.query = "OPEN"
        #expect(draft.matchingPresets(in: all).map(\.id) == ["opencode"])

        draft.query = "Z.AI"
        #expect(draft.matchingPresets(in: all).map(\.id) == ["zai-coding"])

        draft.query = "coding"
        #expect(draft.matchingPresets(in: all).count == 2)

        draft.query = "   "
        #expect(draft.matchingPresets(in: all).count == all.count)
    }

    /// 别名只参与搜索命中，不参与显示；用 catalog 里真实存在的某条别名验证。
    @Test
    func searchMatchesAliasFromCatalog() {
        let draft = ProviderPresetDraft()
        let candidate = ProviderPreset.all.first { !$0.aliases.isEmpty }
        #expect(candidate != nil, "catalog 应至少有一条预设带 aliases")

        guard let target = candidate,
              let alias = target.aliases.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return }

        draft.query = alias
        #expect(draft.matchingPresets(in: ProviderPreset.all).contains { $0.id == target.id })
    }

    @Test
    func presetPrefillsNameEndpointsAndHeadersButLeavesKeyEmpty() {
        let settings = APIEndpointSettings.enabled([.chat, .messages], baseURL: "https://api.z.ai/v1")
        let draft = RemoteEditDraft(source: nil,
                                    preset: preset("Z.AI Coding", id: "zai-coding",
                                                   endpoints: settings,
                                                   headers: ["X-Api-Key-Name": "zai"]),
                                    existingProviders: [])

        #expect(draft.providerName == "Z.AI Coding")
        #expect(draft.apiKey.isEmpty)
        #expect(draft.endpoints == settings)
        #expect(draft.headers.map(\.key) == ["X-Api-Key-Name"])
        #expect(draft.headers.first?.value == "zai")
    }

    @Test
    func customDraftStartsEmpty() {
        let draft = RemoteEditDraft(source: nil, existingProviders: [])

        #expect(draft.providerName.isEmpty)
        #expect(draft.apiKey.isEmpty)
        #expect(draft.headers.isEmpty)
        #expect(draft.endpoints == APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled))
    }

    @Test
    func editingExistingRemoteKeepsItsFields() {
        let source = remote("Alpha", "one", key: "secret",
                            headers: ["X-Keep": "v"], baseURL: "https://alpha.example/v1")
        let draft = RemoteEditDraft(source: source)

        #expect(draft.providerName == "Alpha")
        #expect(draft.model == "one")
        #expect(draft.apiKey == "secret")
        #expect(draft.headers.map(\.key) == ["X-Keep"])
        #expect(draft.endpoints == source.apiEndpoints)
    }

    @Test
    func presetNameGetsUniqueSuggestionWhenTaken() {
        let existing: Set<String> = ["OpenAI", "OpenAI 2"]

        #expect(ProviderPresetNaming.suggestedName(base: "OpenAI", existing: existing) == "OpenAI 3")
        #expect(ProviderPresetNaming.suggestedName(base: "OpenAI", existing: []) == "OpenAI")

        let draft = RemoteEditDraft(source: nil, preset: preset("OpenAI", id: "openai"),
                                    existingProviders: existing)
        #expect(draft.providerName == "OpenAI 3")
    }

    /// 整条流程只操作草稿，不落到真实 ConfigStore。
    @Test
    func choosingThenBackLeavesStoreUntouched() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchPresetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")

        let original = remote("Z.AI Coding", "glm-4.6", key: "k", baseURL: "https://api.z.ai/v1")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [original], fakes: [])).write(to: url)
        let store = ConfigStore(configURL: url)

        let draft = ProviderPresetDraft()
        draft.choose(preset("Z.AI Coding", id: "zai-coding"))
        draft.backToPresets()

        #expect(store.config.remotes.count == 1)
        #expect(store.config.remotes.first?.id == original.id)
        #expect(store.config.remotes.first?.name == "Z.AI Coding · glm-4.6")
    }

    private func preset(_ name: String, id: String,
                        endpoints: APIEndpointSettings = .all(baseURL: "https://example.com/v1"),
                        headers: [String: String] = [:]) -> ProviderPreset {
        ProviderPreset(id: id, name: name, iconName: id,
                       endpoints: endpoints, extraHeaders: headers)
    }

    private func remote(_ provider: String, _ model: String, key: String = "key",
                        headers: [String: String] = [:],
                        baseURL: String = "https://example.com/v1") -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: key, model: model,
                    extraHeaders: headers, apiEndpoints: .all(baseURL: baseURL))
    }
}
