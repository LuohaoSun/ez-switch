import Foundation
import Testing
@testable import EZSwitch

@MainActor
@Suite("Config store")
struct ConfigStoreTests {
    @Test
    func removeProviderRemovesAllModelsAndUnbindsRoutes() throws {
        let alphaOne = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                                  baseURL: "https://alpha.example")
        let alphaTwo = makeRemote(name: "Alpha · two", model: "two", apiKey: "a",
                                  baseURL: "https://alpha.example")
        let beta = makeRemote(name: "Beta · one", model: "one", apiKey: "b",
                              baseURL: "https://beta.example")
        let chat = FakeModel(id: UUID(), fakeModelID: "router-chat",
                             displayName: "router-chat", remoteID: alphaOne.id)
        let responses = FakeModel(id: UUID(), fakeModelID: "router-responses",
                                  displayName: "router-responses", remoteID: alphaTwo.id)
        let betaRoute = FakeModel(id: UUID(), fakeModelID: "beta-chat",
                                  displayName: "beta-chat", remoteID: beta.id)
        let config = AppConfig(port: 8788, remotes: [alphaOne, alphaTwo, beta],
                               fakes: [chat, responses, betaRoute])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: url)

        let store = ConfigStore(configURL: url)
        let unbound = store.removeProvider("Alpha")

        #expect(unbound == ["router-chat", "router-responses"])
        #expect(store.config.remotes.map(\.id) == [beta.id])
        #expect(store.config.fakes[0].remoteID == nil)
        #expect(store.config.fakes[1].remoteID == nil)
        #expect(store.config.fakes[2].remoteID == beta.id)

        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.remotes.map(\.id) == [beta.id])
        #expect(persisted.fakes.compactMap(\.remoteID) == [beta.id])
    }

    @Test
    func removeUnknownProviderIsNoOp() throws {
        let remote = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                                baseURL: "https://alpha.example")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [remote], fakes: [])).write(to: url)

        let store = ConfigStore(configURL: url)

        #expect(store.removeProvider("Missing") == [])
        #expect(store.config.remotes == [remote])
    }

    @Test
    func moveProvidersKeepsGroupsTogetherAndPersistsOrder() throws {
        let aOne = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                              baseURL: "https://alpha.example")
        let beta = makeRemote(name: "Beta · one", model: "one", apiKey: "b",
                              baseURL: "https://beta.example")
        let aTwo = makeRemote(name: "Alpha · two", model: "two", apiKey: "a",
                              baseURL: "https://alpha.example")
        let gamma = makeRemote(name: "Gamma · one", model: "one", apiKey: "c",
                               baseURL: "https://gamma.example")
        let store = try makeStore(remotes: [aOne, beta, aTwo, gamma], fakes: [])

        store.moveProviders(sources: ["Alpha"], before: nil)
        #expect(store.config.remotes.map(\.id) == [beta.id, gamma.id, aOne.id, aTwo.id])
        #expect(store.remoteGroups(matching: "").map(\.provider) == ["Beta", "Gamma", "Alpha"])

        store.moveProviders(sources: ["Alpha"], before: "Beta")
        #expect(store.config.remotes.map(\.id) == [aOne.id, aTwo.id, beta.id, gamma.id])
        store.moveProviders(sources: ["Alpha"], before: "Missing")
        store.moveProviders(sources: ["Missing"], before: nil)
        #expect(store.config.remotes.map(\.id) == [aOne.id, aTwo.id, beta.id, gamma.id])
        let reloaded = ConfigStore(configURL: store.configURL)
        #expect(reloaded.config.remotes.map(\.id) == [aOne.id, aTwo.id, beta.id, gamma.id])
        #expect(reloaded.groupedRemotes().map(\.provider) == ["Alpha", "Beta", "Gamma"])
    }

    @Test
    func moveModelsStaysWithinProviderAndPersistsOrder() throws {
        let aOne = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                              baseURL: "https://alpha.example")
        let beta = makeRemote(name: "Beta · one", model: "one", apiKey: "b",
                              baseURL: "https://beta.example")
        let aTwo = makeRemote(name: "Alpha · two", model: "two", apiKey: "a",
                              baseURL: "https://alpha.example")
        let aThree = makeRemote(name: "Alpha · three", model: "three", apiKey: "a",
                                baseURL: "https://alpha.example")
        let route = FakeModel(id: UUID(), fakeModelID: "chat", displayName: "chat", remoteID: aOne.id)
        let store = try makeStore(remotes: [aOne, beta, aTwo, aThree], fakes: [route])

        store.moveModels(provider: "Alpha", sources: [aOne.id], before: aThree.id)
        #expect(store.config.remotes.map(\.id) == [aTwo.id, beta.id, aOne.id, aThree.id])
        store.moveModels(provider: "Alpha", sources: [aTwo.id], before: nil)
        #expect(store.config.remotes.map(\.id) == [aOne.id, beta.id, aThree.id, aTwo.id])
        #expect(store.router.route(fakeModelID: "chat")?.remote.id == aOne.id)

        store.moveModels(provider: "Alpha", sources: [aOne.id], before: beta.id)
        store.moveModels(provider: "Alpha", sources: [beta.id], before: nil)
        #expect(store.config.remotes.map(\.id) == [aOne.id, beta.id, aThree.id, aTwo.id])
        let reloaded = ConfigStore(configURL: store.configURL)
        #expect(reloaded.config.remotes.map(\.id) == [aOne.id, beta.id, aThree.id, aTwo.id])
    }

    @Test
    func updateModelPreservesProviderConnection() throws {
        let oldRemote = makeRemote(name: "Alpha · one", model: "one", apiKey: "secret",
                                   baseURL: "https://alpha.example",
                                   extraHeaders: ["X-Test": "yes"])
        let chat = FakeModel(id: UUID(), fakeModelID: "router-chat",
                             displayName: "router-chat", remoteID: oldRemote.id)
        let responses = FakeModel(id: UUID(), fakeModelID: "router-responses",
                                  displayName: "router-responses", remoteID: oldRemote.id)
        let store = try makeStore(remotes: [oldRemote], fakes: [chat, responses])

        #expect(store.updateModel(id: oldRemote.id, model: "two") == nil)

        let updated = try #require(store.config.remotes.first)
        #expect(updated.name == "Alpha · two")
        #expect(updated.model == "two")
        #expect(updated.apiKey == "secret")
        #expect(updated.extraHeaders == ["X-Test": "yes"])
        #expect(updated.apiEndpoints == oldRemote.apiEndpoints)
        #expect(store.config.fakes[0].remoteID == oldRemote.id)
        #expect(store.config.fakes[1].remoteID == oldRemote.id)
    }

    @Test
    func addModelCopiesUnifiedProviderConnection() throws {
        let first = makeRemote(name: "Alpha · one", model: "one", apiKey: "secret",
                               baseURL: "https://alpha.example",
                               extraHeaders: ["X-Test": "yes"])
        let store = try makeStore(remotes: [first], fakes: [])

        #expect(store.addModel(provider: "Alpha", model: "two") == nil)

        let added = try #require(store.config.remotes.first { $0.model == "two" })
        #expect(added.name == "Alpha · two")
        #expect(added.apiKey == first.apiKey)
        #expect(added.extraHeaders == first.extraHeaders)
        #expect(added.apiEndpoints == first.apiEndpoints)
    }

    @Test
    func addModelRejectsMixedProviderConnection() throws {
        let first = makeRemote(name: "Alpha · one", model: "one", apiKey: "one",
                               baseURL: "https://alpha.example")
        let second = makeRemote(name: "Alpha · two", model: "two", apiKey: "two",
                                baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [first, second], fakes: [])

        let error = store.addModel(provider: "Alpha", model: "three")

        #expect(error == "该供应商的 API Key 不一致，请先在供应商设置中统一")
        #expect(store.config.remotes.map(\.model) == ["one", "two"])
    }

    @Test
    func addRemoteRejectsExistingProviderName() throws {
        let existing = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                                  baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [existing], fakes: [])
        let incoming = makeRemote(name: "Alpha · two", model: "two", apiKey: "b",
                                  baseURL: "https://alpha.example")

        let error = store.addRemote(incoming)

        #expect(error == "该供应商名称已存在")
        #expect(store.config.remotes == [existing])
    }

    @Test
    func addRemoteRejectsEquivalentDuplicateModelWithoutMutation() throws {
        let existing = makeRemote(name: "Alpha", model: "one", apiKey: "a",
                                  baseURL: "https://alpha.example")
        let route = FakeModel(id: UUID(), fakeModelID: "router", displayName: "router",
                              remoteID: existing.id)
        let store = try makeStore(remotes: [existing], fakes: [route])
        let before = store.config
        let incoming = makeRemote(name: "Alpha · one", model: "one", apiKey: "b",
                                  baseURL: "https://alpha.example")

        let error = store.addRemote(incoming)

        #expect(error == "该供应商下模型 ID 已存在")
        #expect(store.config.remotes == before.remotes)
        #expect(store.config.fakes == before.fakes)
        #expect(store.router.route(fakeModelID: "router")?.remote.id == existing.id)

        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: store.configURL))
        #expect(persisted.remotes == before.remotes)
        #expect(persisted.fakes == before.fakes)
    }

    @Test
    func fakeRouteIsSharedAcrossAPIFormats() throws {
        let remote = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                                baseURL: "https://alpha.example")
        let route = FakeModel(id: UUID(), fakeModelID: "router", displayName: "router",
                              remoteID: remote.id)
        let store = try makeStore(remotes: [remote], fakes: [route])

        #expect(store.router.route(fakeModelID: "router")?.remote.id == remote.id)
        #expect(store.router.route(fakeModelID: "missing")?.remote.id == nil)
    }

    @Test
    func legacyEndpointFieldsMigrateToExplicitProtocols() throws {
        let remoteID = UUID()
        let fakeID = UUID()
        let json = """
        {
          "port": 8788,
          "remotes": [{
            "id": "\(remoteID.uuidString)",
            "name": "Alpha · one",
            "endpoints": ["chat", "responses"],
            "baseURL": "https://alpha.example",
            "apiKey": "a",
            "model": "one",
            "extraHeaders": {}
          }],
          "fakes": [{
            "id": "\(fakeID.uuidString)",
            "endpoint": "chat",
            "fakeModelID": "router",
            "displayName": "router",
            "remoteID": "\(remoteID.uuidString)"
          }]
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.remotes.first?.name == "Alpha · one")
        #expect(config.fakes.first?.fakeModelID == "router")
        #expect(config.remotes.first?.supports(.chat) == true)
        #expect(config.remotes.first?.supports(.responses) == true)
        #expect(config.remotes.first?.supports(.messages) == false)
        #expect(config.remotes.first?.apiEndpoints.chat.baseURL == "https://alpha.example/v1")
        #expect(config.remotes.first?.apiEndpoints.responses.baseURL == "https://alpha.example/v1")
    }

    @Test
    func glmAnthropicLegacyConfigMigratesToThreeEndpointURLs() throws {
        let remoteID = UUID()
        let json = """
        {
          "port": 8788,
          "remotes": [{
            "id": "\(remoteID.uuidString)",
            "name": "Coding Plan · GLM-5.3",
            "baseURL": "https://open.bigmodel.cn/api/anthropic",
            "apiKey": "key",
            "model": "GLM-5.3",
            "extraHeaders": {}
          }],
          "fakes": []
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let remote = try #require(config.remotes.first)

        #expect(remote.apiEndpoints.chat.baseURL ==
                "https://open.bigmodel.cn/api/coding/paas/v4")
        #expect(remote.apiEndpoints.responses.baseURL ==
                "https://open.bigmodel.cn/api/v1")
        #expect(remote.apiEndpoints.messages.baseURL ==
                "https://open.bigmodel.cn/api/anthropic")
        #expect(Forwarder.upstreamURL(remote: remote, endpoint: .chat, query: "")?.absoluteString ==
                "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions")
        #expect(Forwarder.upstreamURL(remote: remote, endpoint: .responses, query: "")?.absoluteString ==
                "https://open.bigmodel.cn/api/v1/responses")
        #expect(Forwarder.upstreamURL(remote: remote, endpoint: .messages, query: "")?.absoluteString ==
                "https://open.bigmodel.cn/api/anthropic/v1/messages")
    }

    @Test
    func normalizeFakesMergesDuplicateModelIDs() {
        let firstRemote = UUID()
        let secondRemote = UUID()
        let firstRemoteModel = makeRemote(id: firstRemote, name: "Alpha · one", model: "one",
                                          apiKey: "a", baseURL: "https://alpha.example")
        let secondRemoteModel = makeRemote(id: secondRemote, name: "Beta · one", model: "one",
                                           apiKey: "b", baseURL: "https://beta.example")
        let first = FakeModel(id: UUID(), fakeModelID: "router", displayName: "router",
                              remoteID: firstRemote)
        let duplicate = FakeModel(id: UUID(), fakeModelID: "router", displayName: "router",
                                  remoteID: secondRemote)

        let (config, changed) = ConfigStore.normalizeFakes(
            AppConfig(port: 8788, remotes: [firstRemoteModel, secondRemoteModel],
                      fakes: [first, duplicate])
        )

        #expect(changed)
        #expect(config.fakes.count == 1)
        #expect(config.fakes.first?.remoteID == firstRemote)
    }

    @Test
    func normalizeFakesPrefersResolvableRemote() {
        let invalidRemote = UUID()
        let validRemote = UUID()
        let invalid = FakeModel(id: UUID(), fakeModelID: "router", displayName: "router",
                                remoteID: invalidRemote)
        let valid = FakeModel(id: UUID(), fakeModelID: "router", displayName: "router",
                              remoteID: validRemote)
        let remote = makeRemote(id: validRemote, name: "Alpha · one", model: "one",
                                apiKey: "a", baseURL: "https://alpha.example")

        let (config, changed) = ConfigStore.normalizeFakes(
            AppConfig(port: 8788, remotes: [remote], fakes: [invalid, valid])
        )

        #expect(changed)
        #expect(config.fakes.count == 1)
        #expect(config.fakes.first?.remoteID == validRemote)
    }

    @Test
    func normalizeBaseURLsOnlyTrimsTrailingSlash() {
        let remote = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                                baseURL: "https://alpha.example/v1/")

        let (config, changed) = ConfigStore.normalizeBaseURLs(
            AppConfig(port: 8788, remotes: [remote], fakes: [])
        )

        #expect(changed)
        #expect(config.remotes.first?.apiEndpoints.chat.baseURL == "https://alpha.example/v1")
        #expect(config.remotes.first?.apiEndpoints.responses.baseURL == "https://alpha.example/v1")
        #expect(config.remotes.first?.apiEndpoints.messages.baseURL == "https://alpha.example/v1")
    }

    @Test
    func endpointSpecificBaseURLsAreUsedIndependently() {
        let remote = RemoteModel(
            id: UUID(), name: "Provider · model", apiKey: "a", model: "real", extraHeaders: [:],
            apiEndpoints: APIEndpointSettings(
                chat: EndpointSetting(enabled: true, baseURL: "https://chat.example/v1"),
                responses: EndpointSetting(enabled: true, baseURL: "https://responses.example"),
                messages: .disabled
            )
        )

        #expect(Forwarder.upstreamURL(remote: remote, endpoint: .chat, query: "")?.absoluteString ==
                "https://chat.example/v1/chat/completions")
        #expect(Forwarder.upstreamURL(remote: remote, endpoint: .responses, query: "x=1")?.absoluteString ==
                "https://responses.example/responses?x=1")
        #expect(Forwarder.upstreamURL(remote: remote, endpoint: .messages, query: "") == nil)
    }

    @Test
    func endpointSettingsRequireOneEnabledValidURL() {
        let none = APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled)
        let missingURL = APIEndpointSettings(
            chat: EndpointSetting(enabled: true, baseURL: ""),
            responses: .disabled, messages: .disabled)
        let valid = APIEndpointSettings.enabled([.responses], baseURL: "https://example.com")

        #expect(ConfigStore.validateEndpoints(none) == "至少启用一种接口协议")
        #expect(ConfigStore.validateEndpoints(missingURL) == "Chat Completions 已启用，请填写 Base URL")
        #expect(ConfigStore.validateEndpoints(valid) == nil)
    }

    @Test
    func exampleUsesOfficialProviderDefaults() {
        let config = AppConfig.example()

        #expect(config.remotes.map(\.name) == [
            "DeepSeek官方 · deepseek-chat",
            "OpenAI官方 · gpt-5.2"
        ])
        #expect(config.remotes[0].apiEndpoints ==
                .enabled([.chat], baseURL: "https://api.deepseek.com/v1"))
        #expect(config.remotes[1].apiEndpoints ==
                .enabled([.chat, .responses], baseURL: "https://api.openai.com/v1"))
        #expect(config.fakes.map(\.fakeModelID) == ["main"])
        #expect(config.fakes[0].remoteID == config.remotes[1].id)
    }

    private func makeStore(remotes: [RemoteModel], fakes: [FakeModel]) throws -> ConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: remotes, fakes: fakes)).write(to: url)
        return ConfigStore(configURL: url)
    }

    private func makeRemote(id: UUID = UUID(), name: String, model: String, apiKey: String,
                            baseURL: String, extraHeaders: [String: String] = [:]) -> RemoteModel {
        RemoteModel(id: id, name: name, apiKey: apiKey, model: model,
                    extraHeaders: extraHeaders,
                    apiEndpoints: .all(baseURL: baseURL))
    }
}
