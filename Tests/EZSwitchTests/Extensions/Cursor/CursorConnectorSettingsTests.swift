import Foundation
import Testing
@testable import EZSwitch

/// Cursor 连接器扩展：连接身份、配置默认/编解码、原子创建、启停保留、生命周期
/// 清理与路由（就绪）快照。只覆盖配置/lifecycle 层，不涉及 CLI 执行或转发。
/// 本文件与 Cursor 扩展同目录，仅在含 Cursor 扩展的构建中编译。
@MainActor
@Suite("Cursor connector extension")
struct CursorConnectorSettingsTests {
    private func disabledEndpoints() -> APIEndpointSettings {
        APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled)
    }

    private func cursorRemote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "", model: model,
                    extraHeaders: [:], apiEndpoints: disabledEndpoints(), source: .cursorProxy)
    }

    private func chatRemote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "key", model: model,
                    extraHeaders: [:],
                    apiEndpoints: .enabled([.chat], baseURL: "https://\(provider.lowercased()).test/v1"))
    }

    private func bound(_ provider: String, enabled: Bool = true, added: Bool = true) -> ExtensionSettings {
        var settings = ExtensionSettings()
        settings.cursorConnector = CursorConnectorSettings(
            enabled: enabled, providerName: provider, providerAdded: added)
        return settings
    }

    private func makeStore(remotes: [RemoteModel] = [], fakes: [FakeModel] = []) throws -> ConfigStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: remotes, fakes: fakes)).write(to: url)
        return ConfigStore(configURL: url)
    }

    private func cursorMembers(_ store: ConfigStore, _ provider: String) -> [RemoteModel] {
        store.config.remotes.filter { splitProviderModel($0.name).provider == provider }
    }

    // MARK: 连接身份与向后兼容

    @Test
    func legacyRemoteDecodesToAPIAndCursorSourceRoundTrips() throws {
        let id = UUID()
        let legacy = """
        {"port":8788,"remotes":[{"id":"\(id.uuidString)","name":"P · a","apiKey":"k","model":"a",
          "extraHeaders":{},"apiEndpoints":{"chat":{"enabled":true,"baseURL":"https://p.test/v1"},
          "responses":{"enabled":false,"baseURL":""},"messages":{"enabled":false,"baseURL":""}}}],"fakes":[]}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        #expect(config.remotes.first?.source == .api)

        let cursor = cursorRemote("Cursor", "auto")
        let data = try JSONEncoder().encode(cursor)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["source"] as? String == "cursorCLI")
    }

    @Test
    func defaultsAreDisabledAndUnbound() throws {
        let config = AppConfig()
        #expect(!config.extensions.cursorConnector.enabled)
        #expect(config.extensions.cursorConnector.providerName == nil)
        #expect(!config.extensions.cursorConnector.providerAdded)

        let legacy = try JSONDecoder().decode(
            AppConfig.self, from: Data(#"{"port":8788,"remotes":[],"fakes":[]}"#.utf8))
        #expect(!legacy.extensions.cursorConnector.enabled)
        #expect(legacy.extensions.cursorConnector.providerName == nil)
        #expect(!legacy.extensions.chatToResponses.enabled)
    }

    @Test
    func encodesAndDecodesCursorSettingsWithoutTokens() throws {
        var config = AppConfig(port: 8788, remotes: [], fakes: [])
        config.extensions = bound("Cursor")
        let data = try JSONEncoder().encode(config)

        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let extensions = try #require(root["extensions"] as? [String: Any])
        let cursor = try #require(extensions["cursorConnector"] as? [String: Any])
        #expect(cursor["enabled"] as? Bool == true)
        #expect(cursor["providerName"] as? String == "Cursor")
        #expect(cursor["providerAdded"] as? Bool == true)
        for key in ["token", "apiKey", "accessToken", "refreshToken"] {
            #expect(cursor[key] == nil)
        }
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.extensions == config.extensions)
    }

    @Test
    func partialCursorSettingsDecodeWithDefaults() throws {
        let json = #"{"extensions":{"cursorConnector":{"providerName":"Cursor"}}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(!config.extensions.cursorConnector.enabled)
        #expect(config.extensions.cursorConnector.providerName == "Cursor")
        #expect(!config.extensions.cursorConnector.providerAdded)
    }

    // MARK: 原子创建与幂等

    @Test
    func addCreatesCursorRecordsWithBlankKeyDisabledEndpoints() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["a", "b"], named: "Cursor") == nil)

        let members = cursorMembers(store, "Cursor")
        #expect(members.count == 2)
        for record in members {
            #expect(record.source == .cursorProxy)
            #expect(record.apiKey.isEmpty)
            #expect(record.apiEndpoints == disabledEndpoints())
            #expect(record.apiEndpoints.enabledKinds.isEmpty)
        }
        #expect(store.config.extensions.cursorConnector.providerName == "Cursor")
        #expect(store.config.extensions.cursorConnector.providerAdded)
    }

    @Test
    func addIsIdempotentAndMergesNewModels() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["a"], named: "Cursor") == nil)
        #expect(store.addCursorProvider(modelIDs: ["a"], named: "Cursor") == nil)
        #expect(cursorMembers(store, "Cursor").count == 1)

        #expect(store.addCursorProvider(modelIDs: ["a", "b"], named: "Cursor") == nil)
        #expect(cursorMembers(store, "Cursor").map(\.model).sorted() == ["a", "b"])
    }

    @Test
    func addRejectsInvalidInput() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: [], named: "Cursor") != nil)
        #expect(store.addCursorProvider(modelIDs: [" "], named: "Cursor") != nil)
        #expect(store.addCursorProvider(modelIDs: ["a", "a"], named: "Cursor") != nil)
        #expect(store.addCursorProvider(modelIDs: ["a"], named: "  ") != nil)
        #expect(store.config.remotes.isEmpty)
    }

    @Test
    func nameCollisionPicksUniqueNameWithoutHijacking() throws {
        let native = chatRemote("Cursor", "m")
        let store = try makeStore(remotes: [native])
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)

        #expect(store.config.extensions.cursorConnector.providerName == "Cursor 2")
        #expect(store.config.remotes.contains(where: { $0.id == native.id }))
        // 原普通 API 供应商不被改写。
        let untouched = try #require(store.config.remotes.first { $0.id == native.id })
        #expect(untouched.source == .api)
        #expect(untouched.apiKey == "key")
        #expect(untouched.apiEndpoints.chat.enabled)
        // 第二次调用复用已绑定的 Cursor 供应商，不再新建。
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)
        #expect(store.config.extensions.cursorConnector.providerName == "Cursor 2")
        #expect(cursorMembers(store, "Cursor 2").count == 1)
    }

    // MARK: 适配解析（身份恒为 connector(source)，可用性受限）

    @Test
    func cursorAdapterIdentityIsStableEvenWhenDisabled() {
        let cursor = cursorRemote("Cursor", "auto")
        var config = AppConfig(port: 0, remotes: [cursor], fakes: [])
        config.extensions = bound("Cursor", enabled: false)

        // 身份恒为 .connector(.cursorProxy)，绝不回退 native。
        #expect(config.adapter(for: cursor, endpoint: .chat) == .connector(.cursorProxy))
        #expect(config.adapter(for: cursor, endpoint: .responses) == .connector(.cursorProxy))
        #expect(config.adapter(for: cursor, endpoint: .messages) == .connector(.cursorProxy))
        // 关闭时不具备可用性。
        #expect(!config.supports(.chat, remote: cursor))
        #expect(!config.supports(.responses, remote: cursor))
    }

    @Test
    func cursorSupportsChatResponsesMessagesWhenEnabledAndBound() {
        let cursor = cursorRemote("Cursor", "auto")
        let other = chatRemote("Other", "m")
        var config = AppConfig(port: 0, remotes: [cursor, other], fakes: [])
        config.extensions = bound("Cursor")

        #expect(config.supports(.chat, remote: cursor))
        #expect(config.supports(.responses, remote: cursor))
        #expect(config.supports(.messages, remote: cursor))
        #expect(!config.supports(.gemini, remote: cursor))
        // 未绑定供应商不受影响。
        #expect(config.adapter(for: other, endpoint: .chat) == .passthrough)

        // 解除绑定 → 不可用，但身份不变。
        config.extensions.cursorConnector.providerName = nil
        config.extensions.cursorConnector.providerAdded = false
        #expect(!config.supports(.responses, remote: cursor))
        #expect(config.adapter(for: cursor, endpoint: .responses) == .connector(.cursorProxy))
    }

    // MARK: 启停保留

    @Test
    func togglePreservesBindingAndRecords() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)
        let records = cursorMembers(store, "Cursor")

        store.setCursorConnectorEnabled(true)
        store.setCursorConnectorEnabled(false)
        #expect(!store.config.extensions.cursorConnector.enabled)
        #expect(store.config.extensions.cursorConnector.providerName == "Cursor")
        #expect(store.config.extensions.cursorConnector.providerAdded)
        #expect(cursorMembers(store, "Cursor") == records)
    }

    // MARK: 生命周期

    @Test
    func removeBindingKeepsRecordsButMakesThemUnusable() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)
        store.setCursorConnectorEnabled(true)

        store.removeCursorProvider()
        #expect(store.config.extensions.cursorConnector.providerName == nil)
        #expect(!store.config.extensions.cursorConnector.providerAdded)
        let record = try #require(cursorMembers(store, "Cursor").first)
        #expect(store.config.extensions.cursorConnector.enabled)
        #expect(!store.config.supports(.responses, remote: record))
        #expect(store.config.adapter(for: record, endpoint: .responses) == .connector(.cursorProxy))
    }

    @Test
    func deletingLastRecordClearsIdentityBinding() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)
        store.setCursorConnectorEnabled(true)
        let record = try #require(cursorMembers(store, "Cursor").first)

        store.removeRemote(id: record.id)
        #expect(store.config.extensions.cursorConnector.providerName == nil)
        #expect(!store.config.extensions.cursorConnector.providerAdded)
    }

    @Test
    func newNativeSameNameDoesNotInherit() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)
        let record = try #require(cursorMembers(store, "Cursor").first)
        store.removeRemote(id: record.id)

        // 重新添加同名普通 API 供应商：不继承绑定，也不被当成 Cursor。
        let native = chatRemote("Cursor", "m")
        #expect(store.addProvider(name: "Cursor", modelIDs: ["m"], apiKey: "key",
                                  extraHeaders: [:], apiEndpoints: native.apiEndpoints) == nil)
        #expect(store.config.extensions.cursorConnector.providerName == nil)
        let added = try #require(store.config.remotes.first)
        #expect(store.config.adapter(for: added, endpoint: .chat) == .passthrough)
    }

    @Test
    func renameMigratesCursorBinding() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)
        #expect(store.updateProvider("Cursor", name: "Cursor Pro", apiEndpoints: nil,
                                     apiKey: nil, extraHeaders: nil) == nil)
        #expect(store.config.extensions.cursorConnector.providerName == "Cursor Pro")
        #expect(store.config.extensions.cursorConnector.providerAdded)
        #expect(cursorMembers(store, "Cursor Pro").count == 1)
    }

    @Test
    func loadPrunesBindingWhenNameIsNotCursorProvider() throws {
        // 绑定的名字存在，但只是普通 API 供应商 → 视为悬空绑定清理。
        let native = chatRemote("Cursor", "m")
        var config = AppConfig(port: 8788, remotes: [native], fakes: [])
        config.extensions = bound("Cursor")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try JSONEncoder().encode(config).write(to: url)

        let store = ConfigStore(configURL: url)
        #expect(store.config.extensions.cursorConnector.providerName == nil)
        #expect(!store.config.extensions.cursorConnector.providerAdded)
        #expect(store.config.extensions.cursorConnector.enabled)
    }

    @Test
    func pruneResetsInconsistentAddedWithoutName() {
        var config = AppConfig(port: 8788, remotes: [], fakes: [])
        config.extensions.cursorConnector =
            CursorConnectorSettings(enabled: true, providerName: nil, providerAdded: true)
        let (pruned, changed) = ConfigStore.pruneConnectorBindings(config, registry: .builtIn)
        #expect(changed)
        #expect(pruned.extensions.cursorConnector.providerName == nil)
        #expect(!pruned.extensions.cursorConnector.providerAdded)
        #expect(pruned.extensions.cursorConnector.enabled)
    }

    // MARK: addModel / updateProvider 的 Cursor 约束

    @Test
    func addModelClonesCursorSource() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)
        #expect(store.addModel(provider: "Cursor", model: "auto-mini") == nil)
        let added = try #require(store.config.remotes.first { $0.model == "auto-mini" })
        #expect(added.source == .cursorProxy)
        #expect(added.apiKey.isEmpty)
        #expect(added.apiEndpoints == disabledEndpoints())
    }

    @Test
    func updateProviderForCursorAllowsRenameOnly() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)

        #expect(store.updateProvider("Cursor", name: "Cursor Pro", apiEndpoints: nil,
                                     apiKey: nil, extraHeaders: nil) == nil)
        #expect(store.updateProvider("Cursor Pro", name: "Cursor Pro", apiEndpoints: nil,
                                     apiKey: "leak", extraHeaders: nil) != nil)
        #expect(store.updateProvider("Cursor Pro", name: "Cursor Pro", apiEndpoints: .all(baseURL: "https://x.test"),
                                     apiKey: nil, extraHeaders: nil) != nil)
        #expect(store.updateProvider("Cursor Pro", name: "Cursor Pro", apiEndpoints: nil,
                                     apiKey: nil, extraHeaders: ["a": "b"]) != nil)
        let record = try #require(cursorMembers(store, "Cursor Pro").first)
        #expect(record.apiKey.isEmpty)
        #expect(record.apiEndpoints == disabledEndpoints())
    }

    @Test
    func unifiedProviderConfigRejectsMixedSource() throws {
        let api = chatRemote("Mixed", "a")
        let cursor = cursorRemote("Mixed", "b")
        let store = try makeStore(remotes: [api, cursor])
        #expect(store.addModel(provider: "Mixed", model: "c") != nil)
    }

    // MARK: 路由快照与运行时就绪

    @Test
    func routerGatesCursorCandidatesOnRuntimeReadiness() throws {
        let store = try makeStore()
        #expect(store.addCursorProvider(modelIDs: ["auto"], named: "Cursor") == nil)
        store.setCursorConnectorEnabled(true)
        let record = try #require(cursorMembers(store, "Cursor").first)
        #expect(store.addFake(fakeModelID: "main", remoteID: record.id))

        // 未就绪（默认 false）→ 候选被过滤。
        #expect(store.router.routedCandidates(fakeModelID: "main", endpoint: .responses)?.candidates.isEmpty == true)

        store.router.setConnectorAvailable(source: .cursorProxy, available: true)
        #expect(store.router.connectorAvailable(source: .cursorProxy))
        let ready = store.router.routedCandidates(fakeModelID: "main", endpoint: .responses)
        #expect(ready?.candidates.first?.adapter == .connector(.cursorProxy))
        #expect(ready?.candidates.map(\.remote.id) == [record.id])
        // Cursor 支持三种编码客户端协议，不支持原生 Gemini。
        #expect(store.router.routedCandidates(fakeModelID: "main", endpoint: .messages)?.candidates.map(\.remote.id) == [record.id])
        #expect(store.router.routedCandidates(fakeModelID: "main", endpoint: .gemini)?.candidates.isEmpty == true)

        // update(config) 不重置就绪；只有控制方显式置 false。
        store.setCursorConnectorEnabled(false)
        #expect(store.router.connectorAvailable(source: .cursorProxy))
        #expect(store.router.routedCandidates(fakeModelID: "main", endpoint: .responses)?.candidates.isEmpty == true)
        store.router.setConnectorAvailable(source: .cursorProxy, available: false)
        #expect(!store.router.connectorAvailable(source: .cursorProxy))
    }
}
