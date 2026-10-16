import Foundation
import Testing
@testable import EZSwitch

private let proxySource = RemoteSource(rawValue: "proxyFixture")
private let plainSource = RemoteSource(rawValue: "plainFixture")

/// 一个声明支持代理（含 policy 闭包）、一个不支持，用于能力闸门与取模型测试。
private func proxyRegistry() -> ExtensionRegistry {
    ExtensionRegistry(connectors: [
        ConnectorDefinition(
            source: proxySource, settingsKey: "proxyFixture", displayName: "ProxyFixture",
            endpoints: [.chat],
            forward: { _ in throw ConnectorUnavailable(source: proxySource) },
            fetchModels: { ["legacy"] },
            supportsOutboundProxy: true,
            fetchModelsWithPolicy: { policy in
                switch policy {
                case .direct: return ["direct"]
                case .proxy(let url): return ["proxy:\(url.host ?? "")"]
                case .invalid(let reason): return ["invalid:\(reason)"]
                }
            }),
        ConnectorDefinition(
            source: plainSource, settingsKey: "plainFixture", displayName: "PlainFixture",
            endpoints: [.chat],
            forward: { _ in throw ConnectorUnavailable(source: plainSource) },
            fetchModels: { ["legacy"] }),
    ])
}

private func nativeRemote(_ provider: String, _ model: String) -> RemoteModel {
    RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "key", model: model,
                extraHeaders: [:], apiEndpoints: .all(baseURL: "https://\(provider.lowercased()).test/v1"))
}

@MainActor
private func makeStore(name: String = "proxy-settings", remotes: [RemoteModel] = [],
                       rawJSON: String? = nil,
                       registry: ExtensionRegistry) throws -> (store: ConfigStore,
                                                                 dir: TempConfigDirectory) {
    let dir = try TempConfigDirectory(name: name)
    let data: Data
    if let rawJSON {
        data = Data(rawJSON.utf8)
    } else {
        data = try JSONEncoder().encode(AppConfig(port: 8788, remotes: remotes, fakes: []))
    }
    try data.write(to: dir.url)
    return (ConfigStore(configURL: dir.url, registry: registry), dir)
}

@MainActor
@Suite("Outbound proxy settings")
struct ProxySettingsTests {
    @Test func defaultsAreDirect() throws {
        let (store, directory) = try makeStore(remotes: [nativeRemote("Alpha", "m")],
                                               registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        #expect(store.config.extensions.outboundProxy == OutboundProxySettings())
        #expect(ProxyExtension.policy(provider: "Alpha", settings: store.config.extensions) == .direct)
        #expect(ProxyExtension.policy(source: proxySource, settings: store.config.extensions) == .direct)
        let remote = try #require(store.config.remotes.first)
        #expect(ProxyExtension.policy(remote: remote, settings: store.config.extensions) == .direct)
    }

    @Test func enableRequiresValidAddressAndAddressValidationIsAtomic() throws {
        let (store, directory) = try makeStore(registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        #expect(store.setOutboundProxyEnabled(true) != nil)             // 无地址
        #expect(!store.config.extensions.outboundProxy.enabled)
        #expect(store.setOutboundProxyAddress("http://127.0.0.1") != nil) // 缺端口
        #expect(store.config.extensions.outboundProxy.address.isEmpty)
        #expect(store.setOutboundProxyAddress("http://127.0.0.1:7890") == nil)
        #expect(store.setOutboundProxyEnabled(true) == nil)
        #expect(store.config.extensions.outboundProxy.enabled)
        #expect(store.setOutboundProxyAddress("http://127.0.0.1:7890\n") != nil) // 尾换行拒绝
        #expect(store.setOutboundProxyAddress("\nhttp://127.0.0.1:7890") != nil) // 首换行拒绝
        #expect(store.config.extensions.outboundProxy.address == "http://127.0.0.1:7890")
        #expect(store.setOutboundProxyAddress("") != nil)               // 启用中不能清空
        #expect(store.config.extensions.outboundProxy.address == "http://127.0.0.1:7890")
        #expect(store.setOutboundProxyEnabled(false) == nil)
        #expect(store.setOutboundProxyAddress("") == nil)               // 关闭后可清空
        #expect(store.config.extensions.outboundProxy.address.isEmpty)
    }

    @Test func selectedNativeProviderCarriesProxyPolicyIntoRoutedCandidate() throws {
        let (store, directory) = try makeStore(remotes: [nativeRemote("Alpha", "m")],
                                               registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        let record = try #require(store.config.remotes.first)
        #expect(store.addFake(fakeModelID: "main", remoteID: record.id))
        #expect(store.setOutboundProxyAddress("http://127.0.0.1:7890") == nil)
        #expect(store.setOutboundProxyEnabled(true) == nil)

        let before = try #require(store.router.routedCandidates(fakeModelID: "main", endpoint: .chat))
        #expect(before.candidates.first?.outboundPolicy == .direct)

        #expect(store.setOutboundProxyProvider("Alpha", selected: true) == nil)
        let after = try #require(store.router.routedCandidates(fakeModelID: "main", endpoint: .chat))
        guard case .proxy(let url) = try #require(after.candidates.first?.outboundPolicy) else {
            Issue.record("expected proxy policy"); return
        }
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 7890)
    }

    @Test func connectorSelectionRequiresSupportAndDeselectionAlwaysWorks() throws {
        let (store, directory) = try makeStore(registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        #expect(store.setOutboundProxyConnector(plainSource, selected: true) != nil)
        #expect(store.config.extensions.outboundProxy.connectorSources.isEmpty)
        #expect(store.setOutboundProxyConnector(proxySource, selected: true) == nil)
        #expect(store.config.extensions.outboundProxy.connectorSources == [proxySource.rawValue])
        #expect(store.setOutboundProxyConnector(plainSource, selected: false) == nil)
        #expect(store.setOutboundProxyConnector(proxySource, selected: false) == nil)
        #expect(store.config.extensions.outboundProxy.connectorSources.isEmpty)
    }

    @Test func malformedEnabledNodeStaysInvalidNotDirect() throws {
        let nativeID = UUID()
        let json = """
        {"port":8788,"remotes":[{"id":"\(nativeID.uuidString)","name":"Alpha · m","apiKey":"k",\
        "model":"m","extraHeaders":{},"apiEndpoints":{"chat":{"enabled":true,"baseURL":"https://alpha.test/v1"},\
        "responses":{"enabled":true,"baseURL":"https://alpha.test/v1"},\
        "messages":{"enabled":true,"baseURL":"https://alpha.test/v1"}},"source":"api"}],"fakes":[],\
        "extensions":{"outboundProxy":{"enabled":true,"address":"http://127.0.0.1",\
        "providerNames":["Alpha"],"connectorSources":["proxyFixture"]}}}
        """
        let (store, directory) = try makeStore(rawJSON: json, registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        guard case .invalid = ProxyExtension.policy(provider: "Alpha", settings: store.config.extensions) else {
            Issue.record("native: expected invalid, not direct"); return
        }
        guard case .invalid = ProxyExtension.policy(source: proxySource, settings: store.config.extensions) else {
            Issue.record("connector: expected invalid, not direct"); return
        }
    }

    @Test func rawSelectionSurvivesTypedDecodeFailure() throws {
        // connectorSources 类型损坏使译文解码失败；raw 仍读出 enabled + providerNames，不降级直连。
        let json = """
        {"port":8788,"remotes":[],"fakes":[],"extensions":{"outboundProxy":{"enabled":true,\
        "address":"http://127.0.0.1:7890","providerNames":["Alpha"],"connectorSources":5}}}
        """
        let (store, directory) = try makeStore(rawJSON: json, registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        guard case .proxy = ProxyExtension.policy(provider: "Alpha", settings: store.config.extensions) else {
            Issue.record("expected proxy from raw selection"); return
        }
    }

    @Test func renameRemovalAndInitPruneMaintainNativeNames() throws {
        let (store, directory) = try makeStore(remotes: [nativeRemote("Alpha", "m"),
                                                         nativeRemote("Beta", "m")],
                                               registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        #expect(store.setOutboundProxyProvider("Alpha", selected: true) == nil)
        #expect(store.setOutboundProxyProvider("Beta", selected: true) == nil)
        #expect(store.setOutboundProxyProvider("Ghost", selected: true) != nil) // 非现存原生

        #expect(store.updateProvider("Alpha", name: "Alpha Prime", apiEndpoints: nil,
                                     apiKey: nil, extraHeaders: nil) == nil)
        #expect(store.config.extensions.outboundProxy.providerNames == ["Alpha Prime", "Beta"])

        #expect(store.removeProvider("Beta").isEmpty)
        #expect(store.config.extensions.outboundProxy.providerNames == ["Alpha Prime"])

        // 外部编辑留下悬空名字：init 时清理。
        let ghost = """
        {"port":8788,"remotes":[],"fakes":[],"extensions":{"outboundProxy":{"enabled":true,\
        "address":"http://127.0.0.1:7890","providerNames":["Ghost"]}}}
        """
        let (reloaded, reloadedDirectory) = try makeStore(name: "proxy-settings-reload",
                                                          rawJSON: ghost, registry: proxyRegistry())
        defer { withExtendedLifetime(reloadedDirectory) {} }
        #expect(reloaded.config.extensions.outboundProxy.providerNames.isEmpty)
    }

    @Test func unknownNodeAndExtensionFieldsSurviveResave() throws {
        let json = """
        {"port":8788,"remotes":[],"fakes":[],"extensions":{"outboundProxy":{"enabled":false,\
        "address":"","providerNames":[],"connectorSources":[],"futureField":{"n":1}},\
        "otherExtension":{"anything":[1,2]}}}
        """
        let (store, directory) = try makeStore(rawJSON: json, registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        #expect(store.setOutboundProxyAddress("http://127.0.0.1:7890") == nil)
        let root = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.configURL)) as? [String: Any])
        let extensions = try #require(root["extensions"] as? [String: Any])
        let node = try #require(extensions["outboundProxy"] as? [String: Any])
        #expect(node["address"] as? String == "http://127.0.0.1:7890")
        #expect(node["futureField"] != nil)
        #expect(extensions["otherExtension"] != nil)
    }

    /// 损坏节点（connectorSources 类型非法）在有效 enabled/address/providerNames/未知字段下，
    /// 保存地址、勾选/取消名单、开启一律拒绝：原始 JSON 与策略都不变。
    @Test func corruptNodeRejectsFieldWritesAndPreservesRawAndPolicy() throws {
        let nativeID = UUID()
        let json = """
        {"port":8788,"remotes":[{"id":"\(nativeID.uuidString)","name":"Alpha · m","apiKey":"k",\
        "model":"m","extraHeaders":{},"apiEndpoints":{"chat":{"enabled":true,"baseURL":"https://alpha.test/v1"},\
        "responses":{"enabled":true,"baseURL":"https://alpha.test/v1"},\
        "messages":{"enabled":true,"baseURL":"https://alpha.test/v1"}},"source":"api"}],"fakes":[],\
        "extensions":{"outboundProxy":{"enabled":true,"address":"http://127.0.0.1:7890",\
        "providerNames":["Alpha"],"connectorSources":5,"futureField":{"n":1}}}}
        """
        let (store, directory) = try makeStore(rawJSON: json, registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        let before = try Data(contentsOf: store.configURL)
        guard case .proxy = ProxyExtension.policy(provider: "Alpha", settings: store.config.extensions) else {
            Issue.record("precondition: expected proxy policy"); return
        }

        #expect(store.setOutboundProxyAddress("http://127.0.0.1:9999") != nil)
        #expect(store.setOutboundProxyProvider("Alpha", selected: false) != nil)
        #expect(store.setOutboundProxyProvider("Alpha", selected: true) != nil)
        #expect(store.setOutboundProxyConnector(proxySource, selected: true) != nil)
        #expect(store.setOutboundProxyConnector(proxySource, selected: false) != nil)
        #expect(store.setOutboundProxyEnabled(true) != nil)

        // 文件字节未变；raw 节点各字段原样保留。
        #expect(try Data(contentsOf: store.configURL) == before)
        let root = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.configURL)) as? [String: Any])
        let extensions = try #require(root["extensions"] as? [String: Any])
        let node = try #require(extensions["outboundProxy"] as? [String: Any])
        #expect(node["enabled"] as? Bool == true)
        #expect(node["address"] as? String == "http://127.0.0.1:7890")
        #expect((node["providerNames"] as? [String]) == ["Alpha"])
        #expect(node["connectorSources"] as? Int == 5)          // 未改写成数组
        #expect((node["futureField"] as? [String: Any])?["n"] as? Int == 1)
        guard case .proxy = ProxyExtension.policy(provider: "Alpha", settings: store.config.extensions) else {
            Issue.record("policy changed after rejected writes"); return
        }
    }

    /// 显式关闭是损坏 object 节点的恢复操作：只改 enabled=false，保留地址/名单/未知字段。
    @Test func explicitDisableRecoversCorruptObjectNodeKeepingFields() throws {
        let json = """
        {"port":8788,"remotes":[],"fakes":[],"extensions":{"outboundProxy":{"enabled":true,\
        "address":"http://127.0.0.1:7890","providerNames":["Alpha"],"connectorSources":5,\
        "futureField":{"n":1}}}}
        """
        let (store, directory) = try makeStore(rawJSON: json, registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        #expect(store.setOutboundProxyEnabled(false) == nil)

        let root = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.configURL)) as? [String: Any])
        let extensions = try #require(root["extensions"] as? [String: Any])
        let node = try #require(extensions["outboundProxy"] as? [String: Any])
        #expect(node["enabled"] as? Bool == false)
        #expect(node["address"] as? String == "http://127.0.0.1:7890")
        #expect((node["providerNames"] as? [String]) == ["Alpha"])
        #expect(node["connectorSources"] as? Int == 5)
        #expect((node["futureField"] as? [String: Any])?["n"] as? Int == 1)
        #expect(ProxyExtension.policy(provider: "Alpha", settings: store.config.extensions) == .direct)
    }

    /// 非 object 的损坏节点：开启/字段写入拒绝；显式关闭可恢复成规范禁用节点并可继续编辑。
    @Test func explicitDisableRecoversCorruptNonObjectNode() throws {
        let json = """
        {"port":8788,"remotes":[],"fakes":[],"extensions":{"outboundProxy":5}}
        """
        let (store, directory) = try makeStore(rawJSON: json, registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        #expect(store.setOutboundProxyEnabled(true) != nil)
        #expect(store.setOutboundProxyAddress("http://127.0.0.1:7890") != nil)

        #expect(store.setOutboundProxyEnabled(false) == nil)
        let root = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.configURL)) as? [String: Any])
        let extensions = try #require(root["extensions"] as? [String: Any])
        let node = try #require(extensions["outboundProxy"] as? [String: Any])
        #expect(node["enabled"] as? Bool == false)

        // 恢复后节点有效，可正常编辑。
        #expect(store.setOutboundProxyAddress("http://127.0.0.1:7890") == nil)
        #expect(store.setOutboundProxyEnabled(true) == nil)
        #expect(store.config.extensions.outboundProxy.address == "http://127.0.0.1:7890")
        #expect(store.config.extensions.outboundProxy.enabled)
    }

    /// 正常有效节点：勾选供应商/连接器仍保留未识别字段与其它已知字段。
    @Test func validNodeEditsPreserveUnknownFields() throws {
        let nativeID = UUID()
        let json = """
        {"port":8788,"remotes":[{"id":"\(nativeID.uuidString)","name":"Alpha · m","apiKey":"k",\
        "model":"m","extraHeaders":{},"apiEndpoints":{"chat":{"enabled":true,"baseURL":"https://alpha.test/v1"},\
        "responses":{"enabled":true,"baseURL":"https://alpha.test/v1"},\
        "messages":{"enabled":true,"baseURL":"https://alpha.test/v1"}},"source":"api"}],"fakes":[],\
        "extensions":{"outboundProxy":{"enabled":true,"address":"http://127.0.0.1:7890",\
        "providerNames":["Alpha"],"connectorSources":[],"futureField":{"n":1}}}}
        """
        let (store, directory) = try makeStore(rawJSON: json, registry: proxyRegistry())
        defer { withExtendedLifetime(directory) {} }
        #expect(store.setOutboundProxyConnector(proxySource, selected: true) == nil)
        #expect(store.setOutboundProxyProvider("Alpha", selected: false) == nil)

        let root = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.configURL)) as? [String: Any])
        let extensions = try #require(root["extensions"] as? [String: Any])
        let node = try #require(extensions["outboundProxy"] as? [String: Any])
        #expect(node["enabled"] as? Bool == true)
        #expect(node["address"] as? String == "http://127.0.0.1:7890")
        #expect((node["connectorSources"] as? [String]) == [proxySource.rawValue])
        #expect((node["providerNames"] as? [String])?.isEmpty == true)
        #expect((node["futureField"] as? [String: Any])?["n"] as? Int == 1)
    }

    @Test func registryFetchModelsHonorsPolicy() async throws {
        let registry = proxyRegistry()
        // direct 也交给 policy 闭包，避免闭包读取全局策略而非本次快照。
        #expect(try await registry.fetchModels(source: proxySource) == ["direct"])
        let url = try OutboundPolicy.validatedProxyURL("http://127.0.0.1:7890")
        #expect(try await registry.fetchModels(source: proxySource, outboundPolicy: .proxy(url))
            == ["proxy:127.0.0.1"])
        await #expect(throws: ConnectorProxyUnsupported.self) {
            try await registry.fetchModels(source: plainSource, outboundPolicy: .proxy(url))
        }
        await #expect(throws: OutboundTransportError.self) {
            try await registry.fetchModels(source: proxySource, outboundPolicy: .invalid("boom"))
        }
    }
}
