import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

/// 主干通用扩展隔离验收：不引用任何具体扩展类型/标识，证明未知来源永不当 HTTP、
/// 未注册扩展的连接器不可路由、未知扩展 JSON 各形态原样保留，以及坏配置的写盘保护。
@MainActor
@Suite("Extension isolation (generic)")
struct ExtensionIsolationTests {
    private let unknownSource = RemoteSource("acme.telemetry")

    private func disabledEndpoints() -> APIEndpointSettings {
        APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled)
    }

    private func unknownRemote(model: String = "m") -> RemoteModel {
        // 故意给「未知来源」配上可用 URL：它仍绝不能被当作 HTTP 上游。
        RemoteModel(id: UUID(), name: "Acme · \(model)", apiKey: "", model: model,
                    extraHeaders: [:], apiEndpoints: .enabled([.chat], baseURL: "http://127.0.0.1:1/v1"),
                    source: unknownSource)
    }

    private func apiRemote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "key", model: model,
                    extraHeaders: [:],
                    apiEndpoints: .enabled([.chat], baseURL: "https://\(provider.lowercased()).test/v1"))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func extensionsObject(_ data: Data) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["extensions"] as? [String: Any])
    }

    /// 合成一个已注册的连接器来源（无任何具体扩展依赖），用于验证新增守卫。
    private func syntheticRegistry() -> ExtensionRegistry {
        let definition = ConnectorDefinition(
            source: unknownSource, settingsKey: "acmeSettings", displayName: "Acme",
            endpoints: [.chat],
            forward: { _ in throw ConnectorUnavailable(source: RemoteSource("acme.telemetry")) },
            fetchModels: { ["m"] })
        return ExtensionRegistry(connectors: [definition])
    }

    // MARK: 未知来源：身份、非 HTTP、不可路由

    @Test
    func unknownSourceRoundTripsAndIsNeverAPI() throws {
        let remote = unknownRemote()
        let data = try JSONEncoder().encode(remote)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["source"] as? String == "acme.telemetry")

        let decoded = try JSONDecoder().decode(RemoteModel.self, from: data)
        #expect(decoded.source == unknownSource)
        #expect(!decoded.source.isAPI)

        let config = AppConfig(port: 0, remotes: [remote], fakes: [])
        // 非 .api 来源恒为 .connector(source)，即便未注册、即便关闭任何扩展。
        #expect(config.adapter(for: remote, endpoint: .chat) == .connector(unknownSource))
        #expect(config.adapter(for: remote, endpoint: .responses) == .connector(unknownSource))
        // 未注册 → 不可用。
        #expect(!config.supports(.chat, remote: remote))

        // 即便有 URL 且调用方按默认 .passthrough，也绝不发 HTTP。
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions")
        #expect(throws: (any Error).self) {
            try Forwarder.buildRequest(clientHead: head, body: Data(), endpoint: .chat,
                                       remote: remote, query: "")
        }
    }

    @Test
    func unregisteredSourceNeverRoutesWhileAPIStillDoes() {
        let other = unknownRemote()
        let api = apiRemote("Api", "a")
        let otherFake = FakeModel(id: UUID(), fakeModelID: "other", displayName: "other",
                                  remoteID: other.id)
        let apiFake = FakeModel(id: UUID(), fakeModelID: "api", displayName: "api", remoteID: api.id)
        var config = AppConfig(port: 0, remotes: [other, api], fakes: [otherFake, apiFake])
        // 即便把该来源标记为「可用」并写好绑定，未注册的连接器仍不参与路由。
        config.extensions.setConnectorSettings(
            ConnectorSettings(enabled: true, providerName: "Acme", providerAdded: true),
            for: "acme.telemetry.settings")

        let router = Router()
        router.update(config)
        router.setConnectorAvailable(source: unknownSource, available: true)

        #expect(router.routedCandidates(fakeModelID: "other", endpoint: .chat)?.candidates.isEmpty == true)
        #expect(router.connectorAvailable(source: unknownSource))
        // 缺失扩展不 route，也绝不回退 native（该远端 native 端点本就没配置）。
        #expect(!config.supports(.chat, remote: other))

        // 原生 .api 路由不受影响。
        let routed = router.routedCandidates(fakeModelID: "api", endpoint: .chat)
        #expect(routed?.candidates.map(\.remote.id) == [api.id])
        #expect(routed?.candidates.first?.adapter == .passthrough)
    }

    // MARK: 未知扩展 JSON 保真

    @Test
    func unknownExtensionKeysRoundTripAllJSONShapes() throws {
        let json = #"""
        {"chatToResponses":{"enabled":true,"providerNames":["P"]},
         "opaqueScalar":42,"opaqueString":"s","opaqueBool":true,"opaqueNull":null,
         "opaqueArray":[1,"a",{"b":2}],"opaqueObject":{"nested":[1,2]}}
        """#
        let settings = try JSONDecoder().decode(ExtensionSettings.self, from: Data(json.utf8))
        #expect(settings.chatToResponses.enabled)
        #expect(settings.extensionKeys == ["opaqueArray", "opaqueBool", "opaqueNull",
                                           "opaqueObject", "opaqueScalar", "opaqueString"])

        let reencoded = try JSONDecoder().decode([String: ExtensionJSONValue].self,
                                                 from: JSONEncoder().encode(settings))
        #expect(reencoded["opaqueScalar"] == .int(42))
        #expect(reencoded["opaqueString"] == .string("s"))
        #expect(reencoded["opaqueBool"] == .bool(true))
        #expect(reencoded["opaqueNull"] == .null)
        #expect(reencoded["opaqueArray"] == .array([.int(1), .string("a"), .object(["b": .int(2)])]))
        #expect(reencoded["opaqueObject"] == .object(["nested": .array([.int(1), .int(2)])]))
    }

    @Test
    func unknownNumericValuesKeepPrecision() throws {
        let json = #"{"extensions":{"big":9223372036854775807,"ubig":18446744073709551615,"dec":1.25}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let reencoded = try JSONDecoder().decode([String: ExtensionJSONValue].self,
                                                 from: JSONEncoder().encode(config.extensions))
        #expect(reencoded["big"] == .int(9223372036854775807))
        #expect(reencoded["ubig"] == .uint(18446744073709551615))
        #expect(reencoded["dec"] == .decimal(Decimal(string: "1.25")!))
    }

    @Test
    func connectorSettingsPreserveUnknownFieldsAndSiblings() throws {
        let json = #"""
        {"chatToResponses":{"enabled":false,"providerNames":[]},"opaque":"keep",
         "conn":{"enabled":true,"providerName":"P","providerAdded":true,"futureFlag":[1,2]}}
        """#
        var settings = try JSONDecoder().decode(ExtensionSettings.self, from: Data(json.utf8))
        var conn = settings.connectorSettings(for: "conn")
        #expect(conn.enabled)
        #expect(conn.providerName == "P")
        #expect(conn.extra["futureFlag"] == .array([.int(1), .int(2)]))

        conn.enabled = false
        settings.setConnectorSettings(conn, for: "conn")
        settings.setConnectorSettings(ConnectorSettings(enabled: true, providerName: "Q",
                                                        providerAdded: true), for: "another")

        let reencoded = try JSONDecoder().decode([String: ExtensionJSONValue].self,
                                                 from: JSONEncoder().encode(settings))
        #expect(reencoded["opaque"] == .string("keep"))
        #expect(reencoded["conn"] == .object([
            "enabled": .bool(false),
            "providerName": .string("P"),
            "providerAdded": .bool(true),
            "futureFlag": .array([.int(1), .int(2)]),
        ]))
        #expect(reencoded["another"] == .object([
            "enabled": .bool(true),
            "providerName": .string("Q"),
            "providerAdded": .bool(true),
        ]))
    }

    // MARK: ConfigStore 保真（不读真实配置）

    @Test
    func configStorePreservesUnknownSourceModelsRoutesAndExtension() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let remoteID = UUID(), fakeID = UUID()
        let json = """
        {"port":8788,
         "remotes":[{"id":"\(remoteID)","name":"Acme · m","apiKey":"","model":"m","extraHeaders":{},
                     "apiEndpoints":{"chat":{"enabled":false,"baseURL":""},
                                     "responses":{"enabled":false,"baseURL":""},
                                     "messages":{"enabled":false,"baseURL":""}},
                     "source":"acme.telemetry"}],
         "fakes":[{"id":"\(fakeID)","fakeModelID":"main","displayName":"main","remoteID":"\(remoteID)"}],
         "extensions":{"chatToResponses":{"enabled":false,"providerNames":[]},
                       "acmeSettings":{"enabled":true,"providerName":"Acme","providerAdded":true,
                                       "customFlag":7,"nested":{"a":[1,2,3]}},
                       "opaqueScalar":"keep","opaqueArray":[1,"two",{"three":3}]}}
        """
        try Data(json.utf8).write(to: url)
        let store = ConfigStore(configURL: url)

        #expect(store.config.remotes.first?.source == unknownSource)
        #expect(!(store.config.remotes.first?.source.isAPI ?? true))
        #expect(store.config.remotes.first?.model == "m")
        #expect(store.config.fakes.first?.remoteID == remoteID)

        // 触发一次写盘，再确认未知扩展与未知来源模型/路由都原样保留。
        store.setPort(8789)
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.port == 8789)
        #expect(persisted.remotes.first?.source == unknownSource)
        #expect(persisted.remotes.first?.model == "m")
        #expect(persisted.fakes.first?.remoteID == remoteID)

        let extensions = try extensionsObject(Data(contentsOf: url))
        #expect(extensions["opaqueScalar"] as? String == "keep")
        #expect((extensions["opaqueArray"] as? [Any])?.count == 3)
        let acme = try #require(extensions["acmeSettings"] as? [String: Any])
        #expect(acme["customFlag"] as? Int == 7)
        #expect(acme["providerName"] as? String == "Acme")
        let nested = acme["nested"] as? [String: Any]
        #expect((nested?["a"] as? [NSNumber])?.map(\.intValue) == [1, 2, 3])
    }

    @Test
    func renamingNativeProviderLeavesUnknownExtensionOpaque() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let id = UUID()
        let json = """
        {"port":8788,
         "remotes":[{"id":"\(id)","name":"Alpha · a","apiKey":"k","model":"a","extraHeaders":{},
                     "apiEndpoints":{"chat":{"enabled":true,"baseURL":"https://a.test/v1"},
                                     "responses":{"enabled":false,"baseURL":""},
                                     "messages":{"enabled":false,"baseURL":""}}}],
         "fakes":[],
         "extensions":{"chatToResponses":{"enabled":false,"providerNames":[]},
                       "ghostConnector":{"enabled":true,"providerName":"Alpha","providerAdded":true}}}
        """
        try Data(json.utf8).write(to: url)
        let store = ConfigStore(configURL: url)

        #expect(store.updateProvider("Alpha", name: "Gamma", apiEndpoints: nil,
                                     apiKey: nil, extraHeaders: nil) == nil)
        let extensions = try extensionsObject(Data(contentsOf: url))
        // 未注册扩展的绑定与内容不得被主干改名/遍历触碰。
        let ghost = try #require(extensions["ghostConnector"] as? [String: Any])
        #expect(ghost["providerName"] as? String == "Alpha")
        #expect(ghost["providerAdded"] as? Bool == true)
    }

    // MARK: 新增连接器记录的来源守卫

    @Test
    func addConnectorProviderRequiresRegisteredMatchingSource() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [], fakes: [])).write(to: url)
        let store = ConfigStore(configURL: url, registry: syntheticRegistry())

        // 保留给原生 HTTP 的来源被拒绝，不创建任何记录。
        #expect(store.addConnectorProvider(source: .api, settingsKey: "acmeSettings",
                                           modelIDs: ["m"], named: "P") != nil)
        #expect(store.config.remotes.isEmpty)
        // 未注册来源被拒绝。
        #expect(store.addConnectorProvider(source: RemoteSource("ghost.source"),
                                           settingsKey: "ghostSettings",
                                           modelIDs: ["m"], named: "P") != nil)
        #expect(store.config.remotes.isEmpty)
        // 已注册来源但设置键不匹配被拒绝。
        #expect(store.addConnectorProvider(source: unknownSource, settingsKey: "wrong",
                                           modelIDs: ["m"], named: "P") != nil)
        #expect(store.config.remotes.isEmpty)
        // 正确组合成功。
        #expect(store.addConnectorProvider(source: unknownSource, settingsKey: "acmeSettings",
                                           modelIDs: ["m"], named: "P") == nil)
        #expect(store.config.remotes.count == 1)
        #expect(store.config.remotes.first?.source == unknownSource)
        #expect(store.config.remotes.first?.apiKey.isEmpty == true)
    }

    // MARK: 坏配置保护与恢复

    @Test
    func malformedConfigIsSafeAndNotOverwrittenThenRecovers() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let malformed = Data("{ this is not json".utf8)
        try malformed.write(to: url)

        let store = ConfigStore(configURL: url)
        // 空安全配置，不呈现任何示例 routes；记录错误。
        #expect(store.configLoadError != nil)
        #expect(store.config.remotes.isEmpty)
        #expect(store.config.fakes.isEmpty)

        // 变更尝试不得覆盖原文件。
        store.setPort(9999)
        #expect(try Data(contentsOf: url) == malformed)

        // 修好文件 → reload 解除保护并可恢复写盘。
        let fixed = try JSONEncoder().encode(AppConfig(port: 1111, remotes: [], fakes: []))
        try fixed.write(to: url)
        store.reloadFromDisk()
        #expect(store.configLoadError == nil)
        #expect(store.config.port == 1111)

        store.setPort(2222)
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.port == 2222)
    }
}
