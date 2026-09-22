import XCTest
@testable import EZSwitch

@MainActor
final class ConfigStoreTests: XCTestCase {
    func testRemoveProviderRemovesAllModelsAndUnbindsRoutes() throws {
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

        XCTAssertEqual(unbound, ["router-chat", "router-responses"])
        XCTAssertEqual(store.config.remotes.map(\.id), [beta.id])
        XCTAssertNil(store.config.fakes[0].remoteID)
        XCTAssertNil(store.config.fakes[1].remoteID)
        XCTAssertEqual(store.config.fakes[2].remoteID, beta.id)

        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted.remotes.map(\.id), [beta.id])
        XCTAssertEqual(persisted.fakes.compactMap(\.remoteID), [beta.id])
    }

    func testRemoveUnknownProviderIsNoOp() throws {
        let remote = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                                baseURL: "https://alpha.example")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [remote], fakes: [])).write(to: url)

        let store = ConfigStore(configURL: url)

        XCTAssertEqual(store.removeProvider("Missing"), [])
        XCTAssertEqual(store.config.remotes, [remote])
    }

    func testUpdateModelPreservesProviderConnection() throws {
        let oldRemote = makeRemote(name: "Alpha · one", model: "one", apiKey: "secret",
                                   baseURL: "https://alpha.example/",
                                   extraHeaders: ["X-Test": "yes"])
        let chat = FakeModel(id: UUID(), fakeModelID: "router-chat",
                             displayName: "router-chat", remoteID: oldRemote.id)
        let responses = FakeModel(id: UUID(), fakeModelID: "router-responses",
                                  displayName: "router-responses", remoteID: oldRemote.id)
        let store = try makeStore(remotes: [oldRemote], fakes: [chat, responses])

        XCTAssertNil(store.updateModel(id: oldRemote.id, model: "two"))

        let updated = try XCTUnwrap(store.config.remotes.first)
        XCTAssertEqual(updated.name, "Alpha · two")
        XCTAssertEqual(updated.model, "two")
        XCTAssertEqual(updated.apiKey, "secret")
        XCTAssertEqual(updated.extraHeaders, ["X-Test": "yes"])
        XCTAssertEqual(updated.apiEndpoints, oldRemote.apiEndpoints)
        XCTAssertEqual(store.config.fakes[0].remoteID, oldRemote.id)
        XCTAssertEqual(store.config.fakes[1].remoteID, oldRemote.id)
    }

    func testAddModelCopiesUnifiedProviderConnection() throws {
        let first = makeRemote(name: "Alpha · one", model: "one", apiKey: "secret",
                               baseURL: "https://alpha.example",
                               extraHeaders: ["X-Test": "yes"])
        let store = try makeStore(remotes: [first], fakes: [])

        XCTAssertNil(store.addModel(provider: "Alpha", model: "two"))

        let added = try XCTUnwrap(store.config.remotes.first { $0.model == "two" })
        XCTAssertEqual(added.name, "Alpha · two")
        XCTAssertEqual(added.apiKey, first.apiKey)
        XCTAssertEqual(added.extraHeaders, first.extraHeaders)
        XCTAssertEqual(added.apiEndpoints, first.apiEndpoints)
    }

    func testAddModelRejectsMixedProviderConnection() throws {
        let first = makeRemote(name: "Alpha · one", model: "one", apiKey: "one",
                               baseURL: "https://alpha.example")
        let second = makeRemote(name: "Alpha · two", model: "two", apiKey: "two",
                                baseURL: "https://alpha.example")
        let store = try makeStore(remotes: [first, second], fakes: [])

        let error = store.addModel(provider: "Alpha", model: "three")

        XCTAssertEqual(error, "该供应商的 API Key 不一致，请先在供应商设置中统一")
        XCTAssertEqual(store.config.remotes.map(\.model), ["one", "two"])
    }

    func testFakeRouteIsSharedAcrossAPIFormats() throws {
        let remote = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                                baseURL: "https://alpha.example")
        let route = FakeModel(id: UUID(), fakeModelID: "router", displayName: "router",
                              remoteID: remote.id)
        let store = try makeStore(remotes: [remote], fakes: [route])

        XCTAssertEqual(store.router.route(fakeModelID: "router")?.remote.id, remote.id)
        XCTAssertEqual(store.router.route(fakeModelID: "missing")?.remote.id, nil)
    }

    func testLegacyEndpointFieldsMigrateToExplicitProtocols() throws {
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

        XCTAssertEqual(config.remotes.first?.name, "Alpha · one")
        XCTAssertEqual(config.fakes.first?.fakeModelID, "router")
        XCTAssertTrue(config.remotes.first?.supports(.chat) == true)
        XCTAssertTrue(config.remotes.first?.supports(.responses) == true)
        XCTAssertFalse(config.remotes.first?.supports(.messages) == true)
        XCTAssertEqual(config.remotes.first?.apiEndpoints.chat.baseURL, "https://alpha.example/v1")
        XCTAssertEqual(config.remotes.first?.apiEndpoints.responses.baseURL, "https://alpha.example/v1")
    }

    func testGLMAnthropicLegacyConfigMigratesToThreeEndpointURLs() throws {
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
        let remote = try XCTUnwrap(config.remotes.first)

        XCTAssertEqual(remote.apiEndpoints.chat.baseURL,
                       "https://open.bigmodel.cn/api/coding/paas/v4")
        XCTAssertEqual(remote.apiEndpoints.responses.baseURL,
                       "https://open.bigmodel.cn/api/v1")
        XCTAssertEqual(remote.apiEndpoints.messages.baseURL,
                       "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(Forwarder.upstreamURL(remote: remote, endpoint: .chat, query: "")?.absoluteString,
                       "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions")
        XCTAssertEqual(Forwarder.upstreamURL(remote: remote, endpoint: .responses, query: "")?.absoluteString,
                       "https://open.bigmodel.cn/api/v1/responses")
        XCTAssertEqual(Forwarder.upstreamURL(remote: remote, endpoint: .messages, query: "")?.absoluteString,
                       "https://open.bigmodel.cn/api/anthropic/v1/messages")
    }

    func testNormalizeFakesMergesDuplicateModelIDs() {
        let firstRemote = UUID()
        let secondRemote = UUID()
        let first = FakeModel(id: UUID(), fakeModelID: "router", displayName: "router",
                              remoteID: firstRemote)
        let duplicate = FakeModel(id: UUID(), fakeModelID: "router", displayName: "router",
                                  remoteID: secondRemote)

        let (config, changed) = ConfigStore.normalizeFakes(
            AppConfig(port: 8788, remotes: [], fakes: [first, duplicate])
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(config.fakes.count, 1)
        XCTAssertEqual(config.fakes.first?.remoteID, firstRemote)
    }

    func testNormalizeFakesPrefersResolvableRemote() {
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

        XCTAssertTrue(changed)
        XCTAssertEqual(config.fakes.count, 1)
        XCTAssertEqual(config.fakes.first?.remoteID, validRemote)
    }

    func testNormalizeBaseURLsOnlyTrimsTrailingSlash() {
        let remote = makeRemote(name: "Alpha · one", model: "one", apiKey: "a",
                                baseURL: "https://alpha.example/v1/")

        let (config, changed) = ConfigStore.normalizeBaseURLs(
            AppConfig(port: 8788, remotes: [remote], fakes: [])
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(config.remotes.first?.apiEndpoints.chat.baseURL, "https://alpha.example/v1")
        XCTAssertEqual(config.remotes.first?.apiEndpoints.responses.baseURL, "https://alpha.example/v1")
        XCTAssertEqual(config.remotes.first?.apiEndpoints.messages.baseURL, "https://alpha.example/v1")
    }

    func testEndpointSpecificBaseURLsAreUsedIndependently() {
        let remote = RemoteModel(
            id: UUID(), name: "Provider · model", apiKey: "a", model: "real", extraHeaders: [:],
            apiEndpoints: APIEndpointSettings(
                chat: EndpointSetting(enabled: true, baseURL: "https://chat.example/v1"),
                responses: EndpointSetting(enabled: true, baseURL: "https://responses.example"),
                messages: .disabled
            )
        )

        XCTAssertEqual(Forwarder.upstreamURL(remote: remote, endpoint: .chat, query: "")?.absoluteString,
                       "https://chat.example/v1/chat/completions")
        XCTAssertEqual(Forwarder.upstreamURL(remote: remote, endpoint: .responses, query: "x=1")?.absoluteString,
                       "https://responses.example/responses?x=1")
        XCTAssertNil(Forwarder.upstreamURL(remote: remote, endpoint: .messages, query: ""))
    }

    func testEndpointSettingsRequireOneEnabledValidURL() {
        let none = APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled)
        let missingURL = APIEndpointSettings(
            chat: EndpointSetting(enabled: true, baseURL: ""),
            responses: .disabled, messages: .disabled)
        let valid = APIEndpointSettings.enabled([.responses], baseURL: "https://example.com")

        XCTAssertEqual(ConfigStore.validateEndpoints(none), "至少启用一种接口协议")
        XCTAssertEqual(ConfigStore.validateEndpoints(missingURL), "Chat Completions 已启用，请填写 Base URL")
        XCTAssertNil(ConfigStore.validateEndpoints(valid))
    }

    func testExampleUsesOfficialProviderDefaults() {
        let config = AppConfig.example()

        XCTAssertEqual(config.remotes.map(\.name), [
            "DeepSeek官方 · deepseek-chat",
            "OpenAI官方 · gpt-5.2"
        ])
        XCTAssertEqual(config.remotes[0].apiEndpoints,
                       .enabled([.chat], baseURL: "https://api.deepseek.com/v1"))
        XCTAssertEqual(config.remotes[1].apiEndpoints,
                       .enabled([.chat, .responses], baseURL: "https://api.openai.com/v1"))
        XCTAssertEqual(config.fakes.map(\.fakeModelID), ["router-chat", "router-responses"])
        XCTAssertEqual(config.fakes[0].remoteID, config.remotes[0].id)
        XCTAssertEqual(config.fakes[1].remoteID, config.remotes[1].id)
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
