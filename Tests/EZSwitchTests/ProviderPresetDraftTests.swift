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

    // MARK: OpenCode 会话头：每个新草稿独立、草稿内稳定

    @Test
    func newOpenCodeDraftsEachGenerateUniqueSession() throws {
        let zen = try #require(ProviderPreset.all.first { $0.id == "opencode-zen" })
        let go = try #require(ProviderPreset.all.first { $0.id == "opencode-go" })

        let zenDraft = RemoteEditDraft(source: nil, preset: zen)
        let anotherZenDraft = RemoteEditDraft(source: nil, preset: zen)
        let goDraft = RemoteEditDraft(source: nil, preset: go)

        let sessions = [zenDraft, anotherZenDraft, goDraft].compactMap(session)
        #expect(sessions.count == 3)
        #expect(Set(sessions).count == 3, "每个新供应商草稿必须生成独立 UUID")
        for value in sessions {
            #expect(UUID(uuidString: value) != nil)
        }
        // 不再预填 x-opencode-client。
        for draft in [zenDraft, anotherZenDraft, goDraft] {
            #expect(draft.headers.contains { $0.key.lowercased() == "x-opencode-client" } == false)
        }
    }

    @Test
    func openCodeDraftSessionStaysStableAcrossEdits() throws {
        let preset = try #require(ProviderPreset.all.first { $0.id == "opencode-go" })
        let draft = RemoteEditDraft(source: nil, preset: preset)
        let original = try #require(session(draft))

        // 同一草稿内反复编辑（名称 / key / 模型 / 额外头）不得重新生成。
        draft.providerName = "OpenCode Go 2"
        draft.apiKey = "new-key"
        draft.model = "new-model"
        draft.headers.append(HeaderRow(key: "X-Extra", value: "1"))

        #expect(session(draft) == original)
        #expect(draft.headers.filter { $0.key.lowercased() == "x-opencode-session" }.count == 1)
    }

    @Test
    func addingModelDraftInheritsPersistedOpenCodeSession() {
        let persisted = remote("OpenCode Go", "m1",
                               headers: ["x-opencode-session": "0f8fad5b-d9cb-469f-a165-70867728950e",
                                         "x-opencode-client": "legacy-client"])

        // “添加模型”复用供应商的已持久化配置（RemoteEditSheet 以 template 作为 source）。
        let draft = RemoteEditDraft(source: persisted)

        #expect(session(draft) == "0f8fad5b-d9cb-469f-a165-70867728950e")
        #expect(draft.headers.contains { $0.key == "x-opencode-client" && $0.value == "legacy-client" })
    }

    @Test
    func editingExistingProviderLeavesCustomHeadersUntouched() {
        let existing = remote("OpenCode Go", "m1",
                              headers: ["x-opencode-client": "ezswitch"])

        let draft = RemoteEditDraft(source: existing)

        // 已有供应商不生成新 UUID，也不改写既有头。
        #expect(draft.headers.map(\.key) == ["x-opencode-client"])
        #expect(draft.headers.first?.value == "ezswitch")
        #expect(session(draft) == nil)
    }

    private func session(_ draft: RemoteEditDraft) -> String? {
        draft.headers.first { $0.key.lowercased() == "x-opencode-session" }?.value
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
