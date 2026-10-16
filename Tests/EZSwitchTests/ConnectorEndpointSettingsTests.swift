import Foundation
import Testing
@testable import EZSwitch

// 通用连接器端点开关：只用 fixture 注册来源，不引用任何具体扩展。
private let fixtureSource = RemoteSource(rawValue: "fixtureConnector")
private let fixtureSettingsKey = "fixtureConnector"
private let fixtureCapabilities: Set<EndpointKind> = [.chat, .responses, .messages]

private func fixtureRegistry(_ endpoints: Set<EndpointKind> = fixtureCapabilities) -> ExtensionRegistry {
    ExtensionRegistry(connectors: [ConnectorDefinition(
        source: fixtureSource, settingsKey: fixtureSettingsKey, displayName: "Fixture",
        endpoints: endpoints,
        forward: { _ in throw ConnectorUnavailable(source: fixtureSource) },
        fetchModels: { [] })])
}

private func connectorRemote(_ provider: String, _ model: String,
                             source: RemoteSource = fixtureSource) -> RemoteModel {
    RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "", model: model,
                extraHeaders: [:],
                apiEndpoints: APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled),
                source: source)
}

/// 持有临时配置目录与 store；测试期间目录对象保持存活，测试结束由 deinit 清理。
private final class ConnectorFixture {
    let config: ConfigStore
    let directory: TempConfigDirectory
    init(config: ConfigStore, directory: TempConfigDirectory) {
        self.config = config
        self.directory = directory
    }
}

@MainActor
@Suite("Connector provider endpoint selection")
struct ConnectorEndpointSettingsTests {
    private func makeStore(remotes: [RemoteModel] = [], rawJSON: String? = nil,
                           registry: ExtensionRegistry) throws -> ConnectorFixture {
        let directory = try TempConfigDirectory(name: "connector-endpoints")
        let data: Data
        if let rawJSON {
            data = Data(rawJSON.utf8)
        } else {
            data = try JSONEncoder().encode(AppConfig(port: 8788, remotes: remotes, fakes: []))
        }
        try data.write(to: directory.url)
        return ConnectorFixture(config: ConfigStore(configURL: directory.url, registry: registry),
                                directory: directory)
    }

    private func boundStore(_ registry: ExtensionRegistry) throws -> (fixture: ConnectorFixture,
                                                                     record: RemoteModel) {
        let fixture = try makeStore(registry: registry)
        #expect(fixture.config.addConnectorProvider(source: fixtureSource, settingsKey: fixtureSettingsKey,
                                                    modelIDs: ["m"], named: "Fixture") == nil)
        fixture.config.setConnectorEnabled(settingsKey: fixtureSettingsKey, enabled: true)
        let record = try #require(fixture.config.config.remotes.first)
        return (fixture, record)
    }

    private func selection(_ store: ConfigStore) -> Set<EndpointKind>? {
        store.config.extensions.connectorSettings(for: fixtureSettingsKey).enabledEndpoints
    }

    // MARK: 默认 / 空集

    @Test func unconfiguredSelectionInheritsRegistryCapabilities() throws {
        let (fixture, record) = try boundStore(fixtureRegistry())
        let store = fixture.config
        #expect(selection(store) == nil)
        for kind in fixtureCapabilities {
            #expect(store.config.supports(kind, remote: record, registry: store.registry))
        }
        #expect(!store.config.supports(.gemini, remote: record, registry: store.registry))
    }

    @Test func explicitEmptySetDisablesEveryEndpointButKeepsConnectorIdentity() throws {
        let (fixture, record) = try boundStore(fixtureRegistry())
        let store = fixture.config
        #expect(store.updateConnectorProvider("Fixture", name: "Fixture", enabledEndpoints: []) == nil)
        #expect(selection(store) == Set<EndpointKind>())   // 非 nil：与「继承」区分
        for kind in fixtureCapabilities {
            #expect(!store.config.supports(kind, remote: record, registry: store.registry))
        }
        #expect(store.config.adapter(for: record, endpoint: .responses) == .connector(fixtureSource))
    }

    // MARK: 子集约束路由与目录

    @Test func subsetRestrictsRoutingAndCatalog() throws {
        let (fixture, record) = try boundStore(fixtureRegistry())
        let store = fixture.config
        #expect(store.addFake(fakeModelID: "main", remoteID: record.id))
        store.router.setConnectorAvailable(source: fixtureSource, available: true)
        #expect(store.updateConnectorProvider("Fixture", name: "Fixture", enabledEndpoints: [.chat]) == nil)

        #expect(store.router.routedCandidates(fakeModelID: "main", endpoint: .chat)?
            .candidates.map(\.remote.id) == [record.id])
        #expect(store.router.routedCandidates(fakeModelID: "main", endpoint: .responses)?.candidates.isEmpty == true)
        #expect(store.router.routedCandidates(fakeModelID: "main", endpoint: .messages)?.candidates.isEmpty == true)
        #expect(store.router.fakes(supporting: .chat).map(\.fakeModelID) == ["main"])
        #expect(store.router.fakes(supporting: .responses).isEmpty)
    }

    // MARK: 保存 / 改名 / 生命周期

    @Test func selectionPersistsAcrossReload() throws {
        let (fixture, _) = try boundStore(fixtureRegistry())
        #expect(fixture.config.updateConnectorProvider("Fixture", name: "Fixture",
                                                       enabledEndpoints: [.chat, .responses]) == nil)
        let reloaded = ConfigStore(configURL: fixture.config.configURL, registry: fixtureRegistry())
        #expect(reloaded.config.extensions.connectorSettings(for: fixtureSettingsKey).enabledEndpoints
            == Set<EndpointKind>([.chat, .responses]))
    }

    @Test func selectionSurvivesDisableEnableAndResync() throws {
        let fixture = try makeStore(registry: fixtureRegistry())
        let store = fixture.config
        #expect(store.addConnectorProvider(source: fixtureSource, settingsKey: fixtureSettingsKey,
                                           modelIDs: ["m"], named: "Fixture") == nil)
        #expect(store.updateConnectorProvider("Fixture", name: "Fixture", enabledEndpoints: [.chat]) == nil)

        store.setConnectorEnabled(settingsKey: fixtureSettingsKey, enabled: false)
        #expect(selection(store) == Set<EndpointKind>([.chat]))
        store.setConnectorEnabled(settingsKey: fixtureSettingsKey, enabled: true)
        #expect(selection(store) == Set<EndpointKind>([.chat]))

        // 重新 add/sync 补齐模型：选择保持不变。
        #expect(store.addConnectorProvider(source: fixtureSource, settingsKey: fixtureSettingsKey,
                                           modelIDs: ["m", "m2"], named: "Fixture") == nil)
        #expect(selection(store) == Set<EndpointKind>([.chat]))
    }

    @Test func renameKeepsSelectionAndMigratesBinding() throws {
        let (fixture, _) = try boundStore(fixtureRegistry())
        let store = fixture.config
        #expect(store.updateConnectorProvider("Fixture", name: "Fixture Pro",
                                              enabledEndpoints: [.chat]) == nil)
        let settings = store.config.extensions.connectorSettings(for: fixtureSettingsKey)
        #expect(settings.providerName == "Fixture Pro")
        #expect(settings.providerAdded)
        #expect(settings.enabledEndpoints == Set<EndpointKind>([.chat]))
        #expect(store.config.remotes.allSatisfy { splitProviderModel($0.name).provider == "Fixture Pro" })
        let record = try #require(store.config.remotes.first)
        #expect(store.config.supports(.chat, remote: record, registry: store.registry))
        #expect(!store.config.supports(.responses, remote: record, registry: store.registry))
    }

    @Test func plainRenameViaUpdateProviderKeepsSelection() throws {
        let (fixture, _) = try boundStore(fixtureRegistry())
        let store = fixture.config
        #expect(store.updateConnectorProvider("Fixture", name: "Fixture",
                                              enabledEndpoints: [.responses]) == nil)
        #expect(store.updateProvider("Fixture", name: "Fixture Next", apiEndpoints: nil,
                                     apiKey: nil, extraHeaders: nil) == nil)
        let settings = store.config.extensions.connectorSettings(for: fixtureSettingsKey)
        #expect(settings.providerName == "Fixture Next")
        #expect(settings.enabledEndpoints == Set<EndpointKind>([.responses]))
    }

    // MARK: 边界与拒绝（修改前返回错误）

    @Test func unsupportedCapabilityIsRejectedBeforeAnyChange() throws {
        let (fixture, _) = try boundStore(fixtureRegistry([.chat, .responses]))
        let store = fixture.config
        #expect(store.updateConnectorProvider("Fixture", name: "Fixture", enabledEndpoints: [.messages]) != nil)
        #expect(store.updateConnectorProvider("Fixture", name: "Fixture", enabledEndpoints: [.gemini]) != nil)
        #expect(store.updateConnectorProvider("Fixture", name: "Renamed", enabledEndpoints: [.gemini]) != nil)
        #expect(store.config.remotes.allSatisfy { splitProviderModel($0.name).provider == "Fixture" })
        #expect(selection(store) == nil)
    }

    @Test func unregisteredSourceAndNonConnectorAreRejected() throws {
        let ghost = try makeStore(remotes: [connectorRemote("Ghost", "m")], registry: ExtensionRegistry())
        #expect(ghost.config.updateConnectorProvider("Ghost", name: "Ghost", enabledEndpoints: [.chat]) != nil)
        #expect(ghost.config.updateProvider("Ghost", name: "Ghost Two", apiEndpoints: nil,
                                            apiKey: nil, extraHeaders: nil) == nil)

        let native = try makeStore(registry: fixtureRegistry())
        #expect(native.config.addProvider(name: "Native", modelIDs: ["m"], apiKey: "k", extraHeaders: [:],
                                          apiEndpoints: .all(baseURL: "https://n.test/v1")) == nil)
        #expect(native.config.updateConnectorProvider("Native", name: "Native", enabledEndpoints: [.chat]) != nil)
    }

    @Test func connectorProviderStillRejectsNativeCredentialChanges() throws {
        let (fixture, _) = try boundStore(fixtureRegistry())
        let store = fixture.config
        #expect(store.updateProvider("Fixture", name: "Fixture", apiEndpoints: nil,
                                     apiKey: "leak", extraHeaders: nil) != nil)
        #expect(store.updateProvider("Fixture", name: "Fixture",
                                     apiEndpoints: .all(baseURL: "https://x.test"),
                                     apiKey: nil, extraHeaders: nil) != nil)
        let record = try #require(store.config.remotes.first)
        #expect(record.apiKey.isEmpty)
        #expect(record.apiEndpoints.enabledKinds.isEmpty)
    }

    // MARK: 未知值保真

    @Test func unknownEndpointAndExtensionJSONSurviveResave() throws {
        let id = UUID()
        let json = """
        {"port":8788,"remotes":[{"id":"\(id.uuidString)","name":"Fixture · m","apiKey":"","model":"m",
          "extraHeaders":{},"apiEndpoints":{"chat":{"enabled":false,"baseURL":""},
          "responses":{"enabled":false,"baseURL":""},"messages":{"enabled":false,"baseURL":""}},
          "source":"fixtureConnector"}],"fakes":[],"extensions":{
          "\(fixtureSettingsKey)":{"enabled":true,"providerName":"Fixture","providerAdded":true,
            "enabledEndpoints":["chat","futureProtocol"],"futureField":{"n":1}},
          "unknownExtension":{"anything":[1,2,3]}}}
        """
        let fixture = try makeStore(rawJSON: json, registry: fixtureRegistry())
        let store = fixture.config
        let record = try #require(store.config.remotes.first)
        // 未知协议串被忽略但解释器不崩：只按已知能力生效。
        #expect(selection(store) == Set<EndpointKind>([.chat]))
        #expect(store.config.supports(.chat, remote: record, registry: store.registry))
        #expect(!store.config.supports(.responses, remote: record, registry: store.registry))
        #expect(!store.config.supports(.gemini, remote: record, registry: store.registry))

        // 改一次选择后重新编码：未知端点串、未知连接器字段与未知扩展键全部保留。
        #expect(store.updateConnectorProvider("Fixture", name: "Fixture", enabledEndpoints: [.responses]) == nil)
        let root = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.configURL)) as? [String: Any])
        let extensions = try #require(root["extensions"] as? [String: Any])
        let node = try #require(extensions[fixtureSettingsKey] as? [String: Any])
        let endpoints = try #require(node["enabledEndpoints"] as? [String])
        #expect(endpoints.contains("futureProtocol"))
        #expect(endpoints.contains("responses"))
        #expect(node["futureField"] != nil)
        #expect(extensions["unknownExtension"] != nil)
    }

    @Test func malformedEndpointStructureDoesNotSilentlyEnableAll() throws {
        let id = UUID()
        let json = """
        {"port":8788,"remotes":[{"id":"\(id.uuidString)","name":"Fixture · m","apiKey":"","model":"m",
          "extraHeaders":{},"apiEndpoints":{"chat":{"enabled":false,"baseURL":""},
          "responses":{"enabled":false,"baseURL":""},"messages":{"enabled":false,"baseURL":""}},
          "source":"fixtureConnector"}],"fakes":[],"extensions":{
          "\(fixtureSettingsKey)":{"enabled":true,"providerName":"Fixture","providerAdded":true,
            "enabledEndpoints":"chat"}}}
        """
        let fixture = try makeStore(rawJSON: json, registry: fixtureRegistry())
        let store = fixture.config
        let settings = store.config.extensions.connectorSettings(for: fixtureSettingsKey)
        // 结构非法 → 整个节点按 disabled 回退，而不是静默继承全开。
        #expect(!settings.enabled)
        #expect(settings.providerName == nil)
        let record = try #require(store.config.remotes.first)
        #expect(!store.config.supports(.chat, remote: record, registry: store.registry))
        // 原始非法 JSON 仍原样保留。
        let root = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.configURL)) as? [String: Any])
        let node = try #require((root["extensions"] as? [String: Any])?[fixtureSettingsKey] as? [String: Any])
        #expect(node["enabledEndpoints"] as? String == "chat")
    }
}
