import Foundation
import Testing
@testable import EZSwitch

@MainActor
@Suite("Chat to Responses extension")
struct ExtensionConfigTests {
    private func chatOnly(_ provider: String, _ model: String, chatURL: String = "https://chat.test/v1",
                          responsesEnabled: Bool = false) -> RemoteModel {
        var settings = APIEndpointSettings.all(baseURL: chatURL)
        settings.responses.enabled = responsesEnabled
        return RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "key", model: model,
                           extraHeaders: [:], apiEndpoints: settings)
    }

    private func dual(_ provider: String, _ model: String,
                      chatURL: String = "https://chat.test/v1",
                      responsesURL: String = "https://responses.test/v1") -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "key", model: model,
                    extraHeaders: [:],
                    apiEndpoints: APIEndpointSettings(chat: EndpointSetting(enabled: true, baseURL: chatURL),
                                                      responses: EndpointSetting(enabled: true, baseURL: responsesURL),
                                                      messages: .disabled))
    }

    private func selecting(_ providers: Set<String>, enabled: Bool = true) -> ExtensionSettings {
        ExtensionSettings(chatToResponses: ChatToResponsesSettings(enabled: enabled, providerNames: providers))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: 解析

    @Test
    func defaultsAreDisabledAndEmpty() throws {
        let config = AppConfig()
        #expect(!config.extensions.chatToResponses.enabled)
        #expect(config.extensions.chatToResponses.providerNames.isEmpty)
        // 无 extensions 字段的旧配置解码后同样是关闭状态。
        let legacy = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"port":8788,"remotes":[],"fakes":[]}"#.utf8))
        #expect(!legacy.extensions.chatToResponses.enabled)
        #expect(legacy.extensions.chatToResponses.providerNames.isEmpty)
    }

    @Test
    func adapterAndSupportsResolveByProvider() {
        let selected = chatOnly("Alpha", "a")
        let other = chatOnly("Beta", "b", responsesEnabled: true)
        var config = AppConfig(port: 0, remotes: [selected, other], fakes: [])
        config.extensions = selecting(["Alpha"])

        #expect(config.adapter(for: selected, endpoint: .responses) == .chatToResponses)
        #expect(config.supports(.responses, remote: selected))
        #expect(config.adapter(for: other, endpoint: .responses) == .passthrough)
        #expect(config.supports(.responses, remote: other))
        // 非 Responses 协议恒为透传。
        #expect(config.adapter(for: selected, endpoint: .chat) == .passthrough)
    }

    /// 选中转换但 Chat 不可用 → 直接无效，绝不静默回退 native。
    @Test
    func selectedProviderWithoutUsableChatIsInvalidNotNativeFallback() {
        var settings = APIEndpointSettings.enabled([.responses], baseURL: "https://responses.test/v1")
        settings.chat = EndpointSetting(enabled: false, baseURL: "")
        let remote = RemoteModel(id: UUID(), name: "Alpha · a", apiKey: "key", model: "a",
                                 extraHeaders: [:], apiEndpoints: settings)
        var config = AppConfig(port: 0, remotes: [remote], fakes: [])
        config.extensions = selecting(["Alpha"])
        #expect(config.adapter(for: remote, endpoint: .responses) == .chatToResponses)
        #expect(!config.supports(.responses, remote: remote))
    }

    /// 只有 Chat、native Responses 关闭的已选供应商，候选筛选不得把它过滤掉。
    @Test
    func routerCandidatesKeepSelectedChatOnlyProvider() {
        let remote = chatOnly("Alpha", "a", responsesEnabled: false)
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        var config = AppConfig(port: 0, remotes: [remote], fakes: [fake])
        config.extensions = selecting(["Alpha"])
        let router = Router()
        router.update(config)
        let routed = router.routedCandidates(fakeModelID: "main", endpoint: .responses)
        #expect(routed?.candidates.map(\.remote.id) == [remote.id])
        #expect(routed?.candidates.first?.adapter == .chatToResponses)
        #expect(router.fakes(supporting: .responses).map(\.fakeModelID) == ["main"])
    }

    // MARK: 一次性迁移

    @Test
    func legacyChatCompletionsMigratesToProviderUnionPreservingNativeFlags() throws {
        let a = UUID(), b = UUID()
        let json = """
        {
          "port": 8788,
          "remotes": [
            {"id":"\(a.uuidString)","name":"P · a","apiKey":"k","model":"a","extraHeaders":{},
             "apiEndpoints":{"chat":{"enabled":true,"baseURL":"https://p.test/v1"},
                             "responses":{"enabled":false,"baseURL":""},
                             "messages":{"enabled":false,"baseURL":""},
                             "responsesTransport":"chatCompletions"}},
            {"id":"\(b.uuidString)","name":"Q · b","apiKey":"k","model":"b","extraHeaders":{},
             "apiEndpoints":{"chat":{"enabled":true,"baseURL":"https://q.test/v1"},
                             "responses":{"enabled":true,"baseURL":"https://q.test/v1"},
                             "messages":{"enabled":false,"baseURL":""},
                             "responsesTransport":"native"}}
          ],
          "fakes": []
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.extensions.chatToResponses.enabled)
        #expect(config.extensions.chatToResponses.providerNames == ["P"])
        // native flag 原样保留，不猜 native 也不改写地址。
        #expect(config.remotes[0].apiEndpoints.responses.enabled == false)
        #expect(config.remotes[1].apiEndpoints.responses.enabled == true)
        #expect(config.remotes[1].apiEndpoints.responses.baseURL == "https://q.test/v1")
    }

    /// 已存在 extensions 字段时原样尊重，reload 不得重新启用旧标记。
    @Test
    func existingExtensionsFieldIsRespectedNotReEnabled() throws {
        let a = UUID()
        let json = """
        {
          "port": 8788,
          "remotes": [
            {"id":"\(a.uuidString)","name":"P · a","apiKey":"k","model":"a","extraHeaders":{},
             "apiEndpoints":{"chat":{"enabled":true,"baseURL":"https://p.test/v1"},
                             "responses":{"enabled":false,"baseURL":""},
                             "messages":{"enabled":false,"baseURL":""},
                             "responsesTransport":"chatCompletions"}}
          ],
          "fakes": [],
          "extensions": {"chatToResponses": {"enabled": false, "providerNames": []}}
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(!config.extensions.chatToResponses.enabled)
        #expect(config.extensions.chatToResponses.providerNames.isEmpty)
    }

    @Test
    func encodingDropsLegacyTransportAndSortsProviderNames() throws {
        let remote = chatOnly("Alpha", "a")
        var config = AppConfig(port: 8788, remotes: [remote], fakes: [])
        config.extensions = selecting(["Beta", "Alpha"])
        let data = try JSONEncoder().encode(config)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let remotes = try #require(root["remotes"] as? [[String: Any]])
        let endpoints = try #require(remotes.first?["apiEndpoints"] as? [String: Any])
        #expect(endpoints["responsesTransport"] == nil)
        let extensions = try #require(root["extensions"] as? [String: Any])
        let chatToResponses = try #require(extensions["chatToResponses"] as? [String: Any])
        #expect(chatToResponses["providerNames"] as? [String] == ["Alpha", "Beta"])
    }

    // MARK: ConfigStore 生命周期

    @Test
    func toggleKeepsNativeConfigAndSelection() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let remote = chatOnly("Alpha", "a")
        var config = AppConfig(port: 8788, remotes: [remote], fakes: [])
        config.extensions = selecting(["Alpha"], enabled: false)
        try JSONEncoder().encode(config).write(to: url)
        let store = ConfigStore(configURL: url)

        store.setChatToResponsesEnabled(true)
        #expect(store.config.extensions.chatToResponses.enabled)
        #expect(store.config.extensions.chatToResponses.providerNames == ["Alpha"])
        store.setChatToResponsesEnabled(false)
        #expect(!store.config.extensions.chatToResponses.enabled)
        #expect(store.config.extensions.chatToResponses.providerNames == ["Alpha"])
        #expect(store.config.remotes.first?.apiEndpoints == remote.apiEndpoints)
    }

    @Test
    func selectingProviderRequiresUsableChatAndDeselectAlwaysAllowed() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        var settings = APIEndpointSettings.enabled([.responses], baseURL: "https://r.test/v1")
        settings.chat = EndpointSetting(enabled: false, baseURL: "")
        let noChat = RemoteModel(id: UUID(), name: "NoChat · m", apiKey: "k", model: "m",
                                 extraHeaders: [:], apiEndpoints: settings)
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [noChat], fakes: [])).write(to: url)
        let store = ConfigStore(configURL: url)

        #expect(store.chatToResponsesUnavailableReason(for: "NoChat") != nil)
        #expect(store.setChatToResponsesProvider("NoChat", selected: true) != nil)
        #expect(store.config.extensions.chatToResponses.providerNames.isEmpty)
        // 取消从未选中/不可选供应商始终允许。
        #expect(store.setChatToResponsesProvider("NoChat", selected: false) == nil)
    }

    @Test
    func renameMigratesSelectionAndRejectsDuplicateName() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let a = chatOnly("Alpha", "a")
        let b = chatOnly("Beta", "b")
        var config = AppConfig(port: 8788, remotes: [a, b], fakes: [])
        config.extensions = selecting(["Alpha"])
        try JSONEncoder().encode(config).write(to: url)
        let store = ConfigStore(configURL: url)

        // 改名到已存在供应商被拒绝，双方数据与选择都不变。
        #expect(store.updateProvider("Alpha", name: "Beta", apiEndpoints: nil, apiKey: nil, extraHeaders: nil) != nil)
        #expect(store.config.extensions.chatToResponses.providerNames == ["Alpha"])
        #expect(store.config.remotes.contains { splitProviderModel($0.name).provider == "Alpha" })
        #expect(store.config.remotes.contains { splitProviderModel($0.name).provider == "Beta" })

        // 合法改名迁移选择。
        #expect(store.updateProvider("Alpha", name: "Gamma", apiEndpoints: nil, apiKey: nil, extraHeaders: nil) == nil)
        #expect(store.config.extensions.chatToResponses.providerNames == ["Gamma"])
    }

    @Test
    func removingLastModelOrProviderClearsSelectionAndReaddDoesNotInherit() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let a = chatOnly("Alpha", "a")
        var config = AppConfig(port: 8788, remotes: [a], fakes: [])
        config.extensions = selecting(["Alpha"])
        try JSONEncoder().encode(config).write(to: url)
        let store = ConfigStore(configURL: url)

        store.removeRemote(id: a.id)
        #expect(store.config.extensions.chatToResponses.providerNames.isEmpty)

        // 重新添加同名供应商不会幽灵继承。
        let readded = chatOnly("Alpha", "a2")
        #expect(store.addProvider(name: "Alpha", modelIDs: ["a2"], apiKey: "key",
                                  extraHeaders: [:], apiEndpoints: readded.apiEndpoints) == nil)
        #expect(store.config.extensions.chatToResponses.providerNames.isEmpty)

        // 删除整个供应商同样清理选择。
        store.setChatToResponsesProvider("Alpha", selected: true)
        #expect(store.config.extensions.chatToResponses.providerNames == ["Alpha"])
        _ = store.removeProvider("Alpha")
        #expect(store.config.extensions.chatToResponses.providerNames.isEmpty)
    }

    @Test
    func addModelInheritsProviderCoverage() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let a = chatOnly("Alpha", "a")
        var config = AppConfig(port: 8788, remotes: [a], fakes: [])
        config.extensions = selecting(["Alpha"])
        try JSONEncoder().encode(config).write(to: url)
        let store = ConfigStore(configURL: url)

        #expect(store.addModel(provider: "Alpha", model: "a2") == nil)
        let added = try #require(store.config.remotes.first { $0.model == "a2" })
        #expect(store.config.supports(.responses, remote: added))
        #expect(store.chatToResponsesUnavailableReason(for: "Alpha") == nil)
    }

    /// 文件迁移写回后，reloadFromDisk 幂等，不会再次迁移或关闭开关。
    @Test
    func reloadAfterLegacyMigrationIsIdempotent() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let a = UUID()
        let json = """
        {
          "port": 8788,
          "remotes": [
            {"id":"\(a.uuidString)","name":"P · a","apiKey":"k","model":"a","extraHeaders":{},
             "apiEndpoints":{"chat":{"enabled":true,"baseURL":"https://p.test/v1"},
                             "responses":{"enabled":false,"baseURL":""},
                             "messages":{"enabled":false,"baseURL":""},
                             "responsesTransport":"chatCompletions"}}
          ],
          "fakes": []
        }
        """
        try Data(json.utf8).write(to: url)
        let store = ConfigStore(configURL: url)
        #expect(store.config.extensions.chatToResponses.enabled)
        #expect(store.config.extensions.chatToResponses.providerNames == ["P"])

        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.extensions.chatToResponses.enabled)
        #expect(persisted.extensions.chatToResponses.providerNames == ["P"])

        store.reloadFromDisk()
        #expect(store.config.extensions.chatToResponses.enabled)
        #expect(store.config.extensions.chatToResponses.providerNames == ["P"])
    }

    /// 外部编辑删除供应商后，加载时把悬空选择与现存供应商求交清理。
    @Test
    func loadPrunesSelectionForMissingProviders() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let a = chatOnly("Alpha", "a")
        var config = AppConfig(port: 8788, remotes: [a], fakes: [])
        config.extensions = selecting(["Alpha", "Gone"])
        try JSONEncoder().encode(config).write(to: url)
        let store = ConfigStore(configURL: url)
        #expect(store.config.extensions.chatToResponses.providerNames == ["Alpha"])
    }

    // MARK: 开关恢复与快照

    /// 同一 remote 同时有 native Responses 独立 URL：开扩展拿 Chat；关开关或取消
    /// 选择后回到 native URL，native 配置不变、选择在关开关时保留。
    @Test
    func toggleOrDeselectRestoresNativeURL() {
        let remote = dual("Alpha", "a", chatURL: "https://chat.test/v1",
                          responsesURL: "https://responses.test/v1")
        var config = AppConfig(port: 0, remotes: [remote], fakes: [])
        config.extensions = selecting(["Alpha"])

        #expect(config.adapter(for: remote, endpoint: .responses) == .chatToResponses)

        config.extensions.chatToResponses.enabled = false
        #expect(config.adapter(for: remote, endpoint: .responses) == .passthrough)
        #expect(config.supports(.responses, remote: remote))
        #expect(config.extensions.chatToResponses.providerNames == ["Alpha"]) // 关开关保留选择

        config.extensions.chatToResponses.enabled = true
        config.extensions.chatToResponses.providerNames = []
        #expect(config.adapter(for: remote, endpoint: .responses) == .passthrough)
        #expect(config.remotes.first?.apiEndpoints.responses.baseURL == "https://responses.test/v1")
        #expect(config.remotes.first?.apiEndpoints.chat.baseURL == "https://chat.test/v1")
    }

    /// 快照取出后 toggle 更新 router：已拿到的 candidate.adapter 不变；下一次 resolve 才更新。
    @Test
    func routedCandidateSnapshotIsStableAcrossToggle() {
        let remote = dual("Alpha", "a")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        var config = AppConfig(port: 0, remotes: [remote], fakes: [fake])
        config.extensions = selecting(["Alpha"])
        let router = Router()
        router.update(config)

        let snapshot = router.routedCandidates(fakeModelID: "main", endpoint: .responses)
        #expect(snapshot?.candidates.first?.adapter == .chatToResponses)

        config.extensions.chatToResponses.enabled = false
        router.update(config)

        #expect(snapshot?.candidates.first?.adapter == .chatToResponses) // 旧快照不变
        #expect(router.routedCandidates(fakeModelID: "main", endpoint: .responses)?.candidates.first?.adapter
                == .passthrough)
    }

    /// 旧配置同供应商多模型（含被去重的重复条）先迁移并集再 normalize，全部模型同一 adapter。
    @Test
    func legacySameProviderUnionSurvivesDedupe() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let a1 = UUID(), a2 = UUID(), dup = UUID(), q = UUID()
        func entry(_ id: UUID, _ name: String, _ model: String, _ chat: String, _ responses: String,
                   _ transport: String) -> String {
            """
            {"id":"\(id.uuidString)","name":"\(name)","apiKey":"k","model":"\(model)","extraHeaders":{},
             "apiEndpoints":{"chat":{"enabled":true,"baseURL":"\(chat)"},
                             "responses":{"enabled":true,"baseURL":"\(responses)"},
                             "messages":{"enabled":false,"baseURL":""},
                             "responsesTransport":"\(transport)"}}
            """
        }
        let json = """
        {"port":8788,"remotes":[
          \(entry(a1, "P · a1", "a1", "https://p.test/v1", "https://p.test/v1", "chatCompletions")),
          \(entry(a2, "P · a2", "a2", "https://p.test/v1", "https://p.test/v1", "native")),
          \(entry(dup, "P · a1", "a1", "https://p.test/v1", "https://p.test/v1", "chatCompletions")),
          \(entry(q, "Q · b", "b", "https://q.test/v1", "https://q.test/v1", "native"))
        ],"fakes":[]}
        """
        try Data(json.utf8).write(to: url)
        let store = ConfigStore(configURL: url)

        // 去重：两条相同 P · a1 合并为一条。
        #expect(store.config.remotes.filter { splitProviderModel($0.name).provider == "P" }.count == 2)
        #expect(store.config.extensions.chatToResponses.providerNames == ["P"])
        for remote in store.config.remotes where splitProviderModel(remote.name).provider == "P" {
            #expect(store.config.adapter(for: remote, endpoint: .responses) == .chatToResponses)
            #expect(store.config.supports(.responses, remote: remote))
        }
        let qRemote = try #require(store.config.remotes.first { splitProviderModel($0.name).provider == "Q" })
        #expect(store.config.adapter(for: qRemote, endpoint: .responses) == .passthrough)
    }
}
