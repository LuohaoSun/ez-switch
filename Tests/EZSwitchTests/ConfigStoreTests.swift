import Combine
import Foundation
import NIOHTTP1
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
        store.flushPendingConfigWrites()
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
    func addProviderWithoutModelsCreatesSelectableProxyShell() throws {
        let store = try makeStore(remotes: [], fakes: [])
        let endpoints = APIEndpointSettings.enabled([.chat, .responses],
                                                    baseURL: "https://proxy.example/v1")

        let error = store.addProvider(name: "ProxyOnly", modelIDs: [], apiKey: "secret",
                                      extraHeaders: ["X-Test": "yes"], apiEndpoints: endpoints)

        #expect(error == nil)
        #expect(store.config.remotes.count == 1)
        let shell = try #require(store.config.remotes.first)
        #expect(shell.name == "ProxyOnly · ")
        #expect(shell.model == "")
        #expect(shell.isProviderShell)
        #expect(shell.apiKey == "secret")
        #expect(shell.extraHeaders == ["X-Test": "yes"])
        #expect(shell.apiEndpoints == ConfigStore.normalizedEndpoints(endpoints))

        let group = try #require(store.groupedRemotes().first)
        #expect(group.provider == "ProxyOnly")
        #expect(group.modelRemotes.isEmpty)

        // 空壳供应商已存在于 groupedRemotes，因此可以在出站代理名单里勾选。
        #expect(store.setOutboundProxyProvider("ProxyOnly", selected: true) == nil)
        #expect(store.config.extensions.outboundProxy.providerNames == ["ProxyOnly"])

        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: store.configURL))
        #expect(persisted.remotes.map(\.name) == ["ProxyOnly · "])
        #expect(persisted.remotes.first?.isProviderShell == true)
    }

    @Test
    func providerShellIsExcludedFromModelRemotes() throws {
        let shell = RemoteModel(id: UUID(), name: "P · ", apiKey: "a", model: "  ",
                                extraHeaders: [:], apiEndpoints: .all(baseURL: "https://p.example"))
        let real = makeRemote(name: "P · one", model: "one", apiKey: "a",
                              baseURL: "https://p.example")

        #expect(shell.isProviderShell)
        #expect(!real.isProviderShell)
        #expect(RemoteGroup(provider: "P", remotes: [shell, real]).modelRemotes.map(\.id) == [real.id])
    }

    @Test
    func addModelReplacesProviderShellUsingItsConnection() throws {
        let store = try makeStore(remotes: [], fakes: [])
        let endpoints = APIEndpointSettings.enabled([.chat, .messages],
                                                    baseURL: "https://proxy.example/v1")
        #expect(store.addProvider(name: "ProxyOnly", modelIDs: [], apiKey: "secret",
                                  extraHeaders: ["X-Test": "yes"], apiEndpoints: endpoints) == nil)
        let shellID = try #require(store.config.remotes.first?.id)

        #expect(store.addModel(provider: "ProxyOnly", model: "m1") == nil)

        #expect(store.config.remotes.map(\.model) == ["m1"])
        let added = try #require(store.config.remotes.first)
        #expect(added.id != shellID)
        #expect(added.name == "ProxyOnly · m1")
        #expect(added.apiKey == "secret")
        #expect(added.extraHeaders == ["X-Test": "yes"])
        #expect(added.apiEndpoints == ConfigStore.normalizedEndpoints(endpoints))
        #expect(!added.isProviderShell)
        #expect(store.groupedRemotes().first?.modelRemotes.map(\.model) == ["m1"])
    }

    @Test
    func catalogSelectionOnProviderShellAddsModelsAndDropsShell() throws {
        let store = try makeStore(remotes: [], fakes: [])
        let endpoints = APIEndpointSettings.enabled([.chat], baseURL: "https://proxy.example/v1")
        #expect(store.addProvider(name: "ProxyOnly", modelIDs: [], apiKey: "secret",
                                  extraHeaders: ["X-Test": "yes"], apiEndpoints: endpoints) == nil)

        let error = store.applyModelCatalogSelection(provider: "ProxyOnly",
                                                     choices: ["one", "two"], selected: ["two"])

        #expect(error == nil)
        #expect(store.config.remotes.map(\.model) == ["two"])
        let added = try #require(store.config.remotes.first)
        #expect(added.apiKey == "secret")
        #expect(added.extraHeaders == ["X-Test": "yes"])
        #expect(added.apiEndpoints == ConfigStore.normalizedEndpoints(endpoints))
        #expect(!added.isProviderShell)
    }

    @Test
    func catalogSelectionKeepsProviderShellWhenOnlyExistingModelsChange() throws {
        let shell = RemoteModel(id: UUID(), name: "Alpha · ", apiKey: "a", model: "",
                                extraHeaders: [:], apiEndpoints: .all(baseURL: "https://alpha.example"))
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                             baseURL: "https://alpha.example")
        let two = makeRemote(name: "Alpha · two", model: "two", apiKey: "a",
                             baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [shell, one, two], fakes: [])

        let error = store.applyModelCatalogSelection(provider: "Alpha",
                                                     choices: ["one", "two"], selected: ["one"])

        #expect(error == nil)
        #expect(store.config.remotes.map(\.id) == [shell.id, one.id])
        #expect(store.config.remotes.first?.isProviderShell == true)
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

        #expect(config.remotes.map(\.name) == ["DeepSeek官方 · deepseek-flash"])
        #expect(config.remotes.map(\.model) == ["deepseek-flash"])
        #expect(config.remotes.allSatisfy { $0.extraHeaders.isEmpty })
        #expect(config.remotes[0].apiEndpoints ==
                .enabled([.chat], baseURL: "https://api.deepseek.com/v1"))
        #expect(Forwarder.upstreamURL(remote: config.remotes[0], endpoint: .chat, query: "")?.absoluteString ==
                "https://api.deepseek.com/v1/chat/completions")
        #expect(config.fakes.map(\.fakeModelID) == ["main"])
        #expect(config.fakes[0].remoteID == config.remotes[0].id)
    }

    @Test
    func openCodeGoForwardsConversationHeadersWithoutStaticSession() throws {
        let remote = RemoteModel(
            id: UUID(), name: "OpenCode Go · deepseek-v4.1-flash",
            apiKey: "sk-REPLACE-ME", model: "deepseek-v4.1-flash", extraHeaders: [:],
            apiEndpoints: .enabled([.chat], baseURL: "https://opencode.ai/zen/go/v1")
        )
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions",
                                   headers: HTTPHeaders([
                                    ("x-opencode-session", "conversation-1"),
                                    ("x-opencode-client", "opencode"),
                                    ("user-agent", "opencode/1.0"),
                                    ("authorization", "Bearer local-placeholder")
                                   ]))
        let request = try Forwarder.buildRequest(clientHead: head, body: Data("{\"model\":\"main\"}".utf8),
                                                 endpoint: .chat, remote: remote, query: "")

        #expect(request.url?.absoluteString == "https://opencode.ai/zen/go/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "x-opencode-session") == "conversation-1")
        #expect(request.value(forHTTPHeaderField: "x-opencode-client") == "opencode")
        #expect(request.value(forHTTPHeaderField: "user-agent") == "opencode/1.0")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-REPLACE-ME")
        let requestBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: String])
        #expect(body["model"] == "deepseek-v4.1-flash")

        let withoutSession = try Forwarder.buildRequest(
            clientHead: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions"),
            body: Data(), endpoint: .chat, remote: remote, query: "")
        #expect(withoutSession.value(forHTTPHeaderField: "x-opencode-session") == nil)
        #expect(withoutSession.value(forHTTPHeaderField: "user-agent")?.hasPrefix("EZSwitch/") == true)
    }

    @Test
    func catalogSelectionReconcilesOnlyChosenProvider() throws {
        let alphaOne = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                                  baseURL: "https://alpha.example")
        let alphaTwo = makeRemote(name: "Alpha · two", model: "two", apiKey: "a",
                                  baseURL: "https://alpha.example")
        let beta = makeRemote(name: "Beta · one", model: "one", apiKey: "b",
                              baseURL: "https://beta.example")
        let store = try makeStore(remotes: [alphaOne, alphaTwo, beta], fakes: [])

        store.applyModelCatalogSelection(provider: "Alpha",
                                         choices: ["one", "two", "three"],
                                         selected: ["one", "three"])

        // Alpha 保留勾选的 one、移除未勾选的 two、补建 three（追加末尾）；Beta 不受影响。
        #expect(store.config.remotes.map(\.model) == ["one", "one", "three"])
        #expect(store.config.remotes.map { splitProviderModel($0.name).provider } ==
                ["Alpha", "Beta", "Alpha"])
        #expect(store.config.remotes[0].id == alphaOne.id)
        #expect(store.config.remotes[1] == beta)
        #expect(!store.config.remotes.contains { $0.id == alphaTwo.id })
        let added = try #require(store.config.remotes.first { $0.model == "three" })
        #expect(added.name == "Alpha · three")
        #expect(added.apiKey == alphaOne.apiKey)
        #expect(added.apiEndpoints == alphaOne.apiEndpoints)

        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: store.configURL))
        #expect(persisted.remotes.map(\.model) == ["one", "one", "three"])
    }

    @Test
    func catalogSelectionPreservesModelsOutsideChoices() throws {
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                             baseURL: "https://alpha.example")
        let two = makeRemote(name: "Alpha · two", model: "two", apiKey: "a",
                             baseURL: "https://alpha.example")
        let legacy = makeRemote(name: "Alpha · legacy", model: "legacy", apiKey: "a",
                                baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [one, two, legacy], fakes: [])

        store.applyModelCatalogSelection(provider: "Alpha",
                                         choices: ["one", "two"],
                                         selected: ["one"])

        // legacy 不在 choices 内必须保留；two 未勾选被移除；one 保持原 UUID。
        #expect(store.config.remotes.map(\.model) == ["one", "legacy"])
        #expect(store.config.remotes[0].id == one.id)
        #expect(store.config.remotes[1].id == legacy.id)
    }

    @Test
    func catalogSelectionIgnoresSelectedOutsideChoices() throws {
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                             baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [one], fakes: [])

        store.applyModelCatalogSelection(provider: "Alpha",
                                         choices: ["one"],
                                         selected: ["one", "ghost"])

        // ghost 在 selected 但不在 choices 内，既不新增也不删除。
        #expect(store.config.remotes.map(\.model) == ["one"])
        #expect(store.config.remotes[0].id == one.id)
    }

    @Test
    func catalogSelectionCleansRouteReferencesOnRemoval() throws {
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                             baseURL: "https://alpha.example")
        let two = makeRemote(name: "Alpha · two", model: "two", apiKey: "a",
                             baseURL: "https://alpha.example")
        var route = FakeModel(id: UUID(), fakeModelID: "chat", displayName: "chat",
                              remoteID: two.id, fallbackRemoteIDs: [one.id])
        route.selectedRemoteID = two.id
        let store = try makeStore(remotes: [one, two], fakes: [route])

        store.applyModelCatalogSelection(provider: "Alpha",
                                         choices: ["one", "two"],
                                         selected: ["one"])

        // two 被移除后，路由落到剩余的 one，fallback 与 selected 一并清理。
        let fake = try #require(store.config.fakes.first)
        #expect(fake.remoteID == one.id)
        #expect(fake.fallbackRemoteIDs.isEmpty)
        #expect(fake.selectedRemoteID == nil)
        #expect(store.router.route(fakeModelID: "chat")?.remote.id == one.id)
    }

    @Test
    func catalogSelectionIsIdempotent() throws {
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                             baseURL: "https://alpha.example")
        let two = makeRemote(name: "Alpha · two", model: "two", apiKey: "a",
                             baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [one, two], fakes: [])

        store.applyModelCatalogSelection(provider: "Alpha",
                                         choices: ["one", "three"],
                                         selected: ["one", "three"])
        let first = store.config

        store.applyModelCatalogSelection(provider: "Alpha",
                                         choices: ["one", "three"],
                                         selected: ["one", "three"])

        #expect(store.config.remotes == first.remotes)
        #expect(store.config.fakes == first.fakes)
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: store.configURL))
        #expect(persisted.remotes == first.remotes)
    }

    @Test
    func catalogSelectionWithEmptyChoicesIsNoOp() throws {
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                             baseURL: "https://alpha.example")
        let two = makeRemote(name: "Alpha · two", model: "two", apiKey: "a",
                             baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [one, two], fakes: [])
        let before = store.config

        store.applyModelCatalogSelection(provider: "Alpha", choices: [], selected: ["one", "ghost"])

        #expect(store.config.remotes == before.remotes)
        #expect(store.config.remotes.map(\.model) == ["one", "two"])
    }

    @Test
    func catalogSelectionReplacesAllProviderModels() throws {
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "secret",
                             baseURL: "https://alpha.example", extraHeaders: ["X-Test": "yes"])
        let two = makeRemote(name: "Alpha · two", model: "two", apiKey: "secret",
                             baseURL: "https://alpha.example", extraHeaders: ["X-Test": "yes"])
        var route = FakeModel(id: UUID(), fakeModelID: "chat", displayName: "chat",
                              remoteID: two.id, fallbackRemoteIDs: [one.id])
        route.selectedRemoteID = two.id
        let store = try makeStore(remotes: [one, two], fakes: [route])

        // 清空全部现存模型后新增，必须仍能成功（模板在删除前已捕获）。
        let error = store.applyModelCatalogSelection(provider: "Alpha",
                                                     choices: ["one", "two", "three"],
                                                     selected: ["three"])

        #expect(error == nil)
        #expect(store.config.remotes.map(\.model) == ["three"])
        let added = try #require(store.config.remotes.first)
        #expect(added.name == "Alpha · three")
        #expect(added.apiKey == "secret")
        #expect(added.extraHeaders == ["X-Test": "yes"])
        #expect(added.apiEndpoints == one.apiEndpoints)
        let fake = try #require(store.config.fakes.first)
        #expect(fake.remoteID == nil)
        #expect(fake.fallbackRemoteIDs.isEmpty)
        #expect(fake.selectedRemoteID == nil)
        #expect(store.router.route(fakeModelID: "chat") == nil)
    }

    @Test
    func catalogSelectionFailsWithoutMutationOnInconsistentProvider() throws {
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "one",
                             baseURL: "https://alpha.example")
        let two = makeRemote(name: "Alpha · two", model: "two", apiKey: "different",
                             baseURL: "https://alpha.example")
        let route = FakeModel(id: UUID(), fakeModelID: "chat", displayName: "chat", remoteID: one.id)
        let store = try makeStore(remotes: [one, two], fakes: [route])
        let before = store.config

        let error = store.applyModelCatalogSelection(provider: "Alpha",
                                                     choices: ["one", "two", "three"],
                                                     selected: ["three"])

        #expect(error == "该供应商的 API Key 不一致，请先在供应商设置中统一")
        #expect(store.config.remotes == before.remotes)
        #expect(store.config.fakes == before.fakes)
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: store.configURL))
        #expect(persisted.remotes == before.remotes)
    }

    @Test
    func catalogSelectionRejectsNormalizedDuplicateWithoutMutation() throws {
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                             baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [one], fakes: [])
        let before = store.config

        // 两个选择 trim 后同为 "new"：必须在新增任何模型前整体拒绝。
        let error = store.applyModelCatalogSelection(provider: "Alpha",
                                                     choices: [" new ", "new"],
                                                     selected: [" new ", "new"])

        #expect(error == "模型 ID 重复")
        #expect(store.config.remotes == before.remotes)
        #expect(store.config.remotes.map(\.model) == ["one"])
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: store.configURL))
        #expect(persisted.remotes == before.remotes)
    }

    @Test
    func catalogSelectionTreatsUntrimmedChoiceMatchingExistingAsPresent() throws {
        let one = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                             baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [one], fakes: [])

        // choices/selected 带空格但 trim 后等于现存 "one"：视为已存在，不新增也不重复报错。
        let error = store.applyModelCatalogSelection(provider: "Alpha",
                                                     choices: [" one "],
                                                     selected: [" one "])

        #expect(error == nil)
        #expect(store.config.remotes.map(\.model) == ["one"])
    }

    @Test
    func reloadFromDiskSkipsRedundantSelfWriteButLoadsExternalEdit() throws {
        let alpha = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                               baseURL: "https://alpha.example")
        let beta = makeRemote(name: "Beta · one", model: "one", apiKey: "b",
                              baseURL: "https://beta.example")
        let route = FakeModel(id: UUID(), fakeModelID: "chat", displayName: "chat", remoteID: alpha.id)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [alpha, beta], fakes: [route])).write(to: url)

        let store = ConfigStore(configURL: url)
        var publishes = 0
        let token = store.objectWillChange.sink { _ in publishes += 1 }
        defer { token.cancel() }

        store.moveProviders(sources: ["Alpha"], before: nil)   // 排序并写盘（等价 drop 的 save）
        let afterMove = publishes
        #expect(afterMove >= 1)

        store.reloadFromDisk()                                 // watcher 路径：内容与内存一致
        #expect(publishes == afterMove)

        var external = store.config
        external.port = 9999
        try JSONEncoder().encode(external).write(to: url, options: .atomic)
        store.reloadFromDisk()                                 // 真实外部修改：必须加载
        #expect(publishes == afterMove + 1)
        #expect(store.config.port == 9999)
    }

    /// 真实 file watcher 端到端：自写盘不重发布；外部写入必须被加载（证明监控确实在跑）。
    @Test
    func fileWatcherIgnoresSelfWriteButLoadsExternalEdit() async throws {
        let alpha = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                               baseURL: "https://alpha.example")
        let beta = makeRemote(name: "Beta · one", model: "one", apiKey: "b",
                              baseURL: "https://beta.example")
        let route = FakeModel(id: UUID(), fakeModelID: "chat", displayName: "chat", remoteID: alpha.id)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [alpha, beta], fakes: [route])).write(to: url)

        let store = ConfigStore(configURL: url, startsWatching: true)
        var publishes = 0
        let token = store.objectWillChange.sink { _ in publishes += 1 }
        defer { token.cancel() }

        store.moveProviders(sources: ["Alpha"], before: nil)   // 自写盘 → watcher 事件
        let afterMove = publishes
        try await Task.sleep(nanoseconds: 800_000_000)          // > 500ms reload debounce
        #expect(publishes == afterMove)

        var external = store.config
        external.port = 9999
        try JSONEncoder().encode(external).write(to: url, options: .atomic)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(publishes > afterMove)
        #expect(store.config.port == 9999)
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
