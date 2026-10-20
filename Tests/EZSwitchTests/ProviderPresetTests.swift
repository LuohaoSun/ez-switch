import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

@MainActor
@Suite("Provider presets")
struct ProviderPresetTests {
    private func remote(_ preset: ProviderPreset, apiKey: String = "test-key",
                        headers: [String: String]? = nil) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(preset.name) · model", apiKey: apiKey, model: "model",
                    extraHeaders: headers ?? preset.extraHeaders, apiEndpoints: preset.endpoints)
    }

    private func newDraft(for preset: ProviderPreset) -> RemoteEditDraft {
        RemoteEditDraft(source: nil, preset: preset, existingProviders: [])
    }

    private func headerValues(_ draft: RemoteEditDraft) -> [String: String] {
        Dictionary(uniqueKeysWithValues: draft.headers.map { ($0.key, $0.value) })
    }

    private func head(_ path: String, _ headers: [(String, String)]) -> HTTPRequestHead {
        HTTPRequestHead(version: .http1_1, method: .POST, uri: path, headers: HTTPHeaders(headers))
    }

    // MARK: 目录本身必须可用

    @Test func allPresetsAreUsableAndUnique() {
        let all = ProviderPreset.all
        #expect(!all.isEmpty)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.name)).count == all.count)
        for preset in all {
            #expect(!preset.id.isEmpty)
            #expect(!preset.name.isEmpty)
            // addProvider 以 " · " 拆分“供应商 · 模型”，预设名不能带该分隔符。
            #expect(!preset.name.contains(" · "))
            #expect(!preset.iconName.isEmpty)
            // Base URL 不应带尾部斜杠，否则路由器会拼出双斜杠前缀。
            #expect(ConfigStore.normalizedEndpoints(preset.endpoints) == preset.endpoints,
                    "\(preset.id) 的 Base URL 不应带尾部斜杠")
            // 通过新增供应商时同一套校验。
            #expect(ConfigStore.validateEndpoints(preset.endpoints) == nil,
                    "\(preset.id) 预设未通过接口校验")
            #expect(!preset.endpoints.enabledKinds.isEmpty, "\(preset.id) 未启用任何协议")
        }
    }

    @Test func presetsCarryNoCredentials() {
        let forbidden = ["sk-", "bearer", "api-key", "api_key", "apikey", "authorization", "token"]
        for preset in ProviderPreset.all {
            var strings = [preset.id, preset.name, preset.iconName] + preset.aliases
            for kind in EndpointKind.allCases { strings.append(preset.endpoints[kind].baseURL) }
            for (key, value) in preset.extraHeaders {
                strings.append(key)
                strings.append(value)
            }
            for string in strings {
                let lower = string.lowercased()
                for fragment in forbidden {
                    #expect(!lower.contains(fragment),
                            "\(preset.id) 含疑似凭据片段 '\(fragment)'：\(string)")
                }
            }
            #expect(preset.extraHeaders["authorization"] == nil)
        }
    }

    // MARK: 协议 URL 拼接

    @Test func enabledEndpointsJoinBaseWithProtocolPath() {
        for preset in ProviderPreset.all {
            let r = remote(preset)
            for kind in preset.endpoints.enabledKinds {
                let base = ConfigStore.normalizeBaseURL(preset.endpoints[kind].baseURL)
                if kind == .gemini {
                    let request = try? Forwarder.buildRequest(
                        clientHead: head("/v1beta/models/main:generateContent", []),
                        body: Data(#"{"contents":[]}"#.utf8), endpoint: kind, remote: r, query: "")
                    #expect(request?.url?.absoluteString == base + "/models/model:generateContent")
                } else {
                    let url = Forwarder.upstreamURL(remote: r, endpoint: kind, query: "")?.absoluteString
                    #expect(url == base + kind.upstreamPath, "\(preset.id) \(kind.rawValue) 拼接错误")
                }
            }
        }
    }

    @Test func messagesBaseURLsNeverDoubleTheVersionSegment() throws {
        for preset in ProviderPreset.all where preset.endpoints.messages.enabled {
            let url = try #require(Forwarder.upstreamURL(remote: remote(preset),
                                                         endpoint: .messages, query: ""))
            #expect(url.path.hasSuffix("/v1/messages"), "\(preset.id) → \(url.path)")
            #expect(!url.path.contains("/v1/v1"), "\(preset.id) 出现重复版本段 → \(url.path)")
            let base = ConfigStore.normalizeBaseURL(preset.endpoints.messages.baseURL)
            #expect(url.absoluteString == base + "/v1/messages")
        }
    }

    @Test func commandCodeSeparatesMessagesFromVersionedProtocols() throws {
        let preset = try #require(ProviderPreset.all.first { $0.id == "commandcode" })
        let r = remote(preset)
        #expect(Forwarder.upstreamURL(remote: r, endpoint: .chat, query: "")?.absoluteString
                == "https://api.commandcode.ai/provider/v1/chat/completions")
        #expect(Forwarder.upstreamURL(remote: r, endpoint: .responses, query: "")?.absoluteString
                == "https://api.commandcode.ai/provider/v1/responses")
        // messages 的 Base URL 不含 /v1，路由器的 /v1/messages 才是唯一版本段。
        #expect(Forwarder.upstreamURL(remote: r, endpoint: .messages, query: "")?.absoluteString
                == "https://api.commandcode.ai/provider/v1/messages")
    }

    @Test func openCodeEndpointURLsMatchOfficialBases() throws {
        func url(_ id: String, _ kind: EndpointKind) throws -> String? {
            let preset = try #require(ProviderPreset.all.first { $0.id == id })
            return Forwarder.upstreamURL(remote: remote(preset), endpoint: kind, query: "")?.absoluteString
        }
        // Zen 使用官方 /inference/v1，含 chat / responses / messages。
        #expect(try url("opencode-zen", .chat) == "https://opencode.ai/inference/v1/chat/completions")
        #expect(try url("opencode-zen", .responses) == "https://opencode.ai/inference/v1/responses")
        #expect(try url("opencode-zen", .messages) == "https://opencode.ai/inference/v1/messages")
        // Go 使用 /zen/go/v1，仅 chat 与 messages。
        #expect(try url("opencode-go", .chat) == "https://opencode.ai/zen/go/v1/chat/completions")
        #expect(try url("opencode-go", .messages) == "https://opencode.ai/zen/go/v1/messages")
    }

    // MARK: OpenCode：会话 ID 由每个新草稿生成

    @Test func openCodeCatalogMarksGeneratedSessionWithoutStaticValue() throws {
        for id in ["opencode-zen", "opencode-go"] {
            let preset = try #require(ProviderPreset.all.first { $0.id == id })
            #expect(preset.generatesOpenCodeSession)
            // 静态目录保持稳定：随机 UUID 只在新建草稿时生成，不固化在这里。
            #expect(preset.extraHeaders.isEmpty)
            #expect(preset.extraHeaders["x-opencode-client"] == nil)
            #expect(preset.extraHeaders["x-opencode-session"] == nil)
            for value in preset.extraHeaders.values {
                #expect(value.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"#,
                                    options: .regularExpression) == nil)
            }
        }
        for preset in ProviderPreset.all where !["opencode-zen", "opencode-go"].contains(preset.id) {
            #expect(!preset.generatesOpenCodeSession)
            #expect(preset.extraHeaders["x-opencode-session"] == nil)
        }
    }

    @Test func openCodeForwardingOverridesInboundSessionWithDraftHeader() throws {
        let preset = try #require(ProviderPreset.all.first { $0.id == "opencode-go" })
        let headers = headerValues(newDraft(for: preset))
        let session = try #require(headers["x-opencode-session"])
        #expect(UUID(uuidString: session) != nil)

        let request = try Forwarder.buildRequest(
            clientHead: head("/zen/go/v1/chat/completions", [
                // 大小写与预置头不同，仍必须被远端 extraHeaders 覆盖。
                ("X-OpenCode-Session", "sess-dynamic"),
                ("x-opencode-project", "proj-dynamic"),
                ("x-opencode-request", "req-dynamic"),
                ("x-opencode-client", "opencode"),
            ]),
            body: Data(#"{"model":"main"}"#.utf8), endpoint: .chat,
            remote: remote(preset, headers: headers), query: "")

        // remote.extraHeaders 最后应用：同名入站会话头被草稿持久化的 UUID 覆盖。
        #expect(request.value(forHTTPHeaderField: "x-opencode-session") == session)
        #expect(request.value(forHTTPHeaderField: "X-OPENCODE-SESSION") == session)
        // 其它逐会话头与客户端自称值原样透传；不再强制 x-opencode-client。
        #expect(request.value(forHTTPHeaderField: "x-opencode-project") == "proj-dynamic")
        #expect(request.value(forHTTPHeaderField: "x-opencode-request") == "req-dynamic")
        #expect(request.value(forHTTPHeaderField: "x-opencode-client") == "opencode")
        #expect(request.url?.absoluteString == "https://opencode.ai/zen/go/v1/chat/completions")
    }

    // MARK: preset → addProvider 持久化 / 模型列表 / 转发链

    @Test func presetConfigRoundTripsThroughAddProvider() throws {
        let preset = try #require(ProviderPreset.all.first { $0.id == "opencode-go" })
        let draft = newDraft(for: preset)
        let headers = headerValues(draft)
        let session = try #require(headers["x-opencode-session"])
        #expect(UUID(uuidString: session) != nil)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchPresetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [], fakes: [])).write(to: url)

        let store = ConfigStore(configURL: url)
        let endpoints = ConfigStore.normalizedEndpoints(preset.endpoints)
        let error = store.addProvider(name: preset.name, modelIDs: ["m1", "m2"], apiKey: "",
                                      extraHeaders: headers, apiEndpoints: endpoints)
        #expect(error == nil)

        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.remotes.map(\.name) == ["OpenCode Go · m1", "OpenCode Go · m2"])
        for r in persisted.remotes {
            #expect(r.extraHeaders == headers)
            #expect(r.extraHeaders["x-opencode-session"] == session)
            #expect(r.apiEndpoints == endpoints)
            #expect(r.apiKey.isEmpty)
        }

        // 后续给同一供应商加模型时复制已持久化的会话头，不生成新的 UUID。
        #expect(store.addModel(provider: preset.name, model: "m3") == nil)
        let withModel = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        let added = try #require(withModel.remotes.first { $0.model == "m3" })
        #expect(added.extraHeaders == headers)
        #expect(added.extraHeaders["x-opencode-session"] == session)
    }

    @Test func modelCatalogRequestRebuildsPresetURLAndHeaders() throws {
        // chat 优先：OpenCode Go 走 /models。
        let go = try #require(ProviderPreset.all.first { $0.id == "opencode-go" })
        let goHeaders = headerValues(newDraft(for: go))
        let goRequest = try ProviderModelCatalog.request(for: remote(go, apiKey: "go-key",
                                                                    headers: goHeaders))
        #expect(goRequest.url?.absoluteString == "https://opencode.ai/zen/go/v1/models")
        #expect(goRequest.value(forHTTPHeaderField: "authorization") == "Bearer go-key")
        #expect(goRequest.value(forHTTPHeaderField: "x-opencode-session")
                == goHeaders["x-opencode-session"])

        // 仅 messages 的预设用 /v1/models 且走 Anthropic 鉴权头。
        let anthropic = try #require(ProviderPreset.all.first { $0.id == "anthropic" })
        let anthropicRequest = try ProviderModelCatalog.request(for: remote(anthropic, apiKey: "a-key"))
        #expect(anthropicRequest.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(anthropicRequest.value(forHTTPHeaderField: "x-api-key") == "a-key")
        #expect(anthropicRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func forwarderBuildsPresetEndpointsWithCorrectAuth() throws {
        let deepseek = try #require(ProviderPreset.all.first { $0.id == "deepseek" })
        let messagesRequest = try Forwarder.buildRequest(
            clientHead: head("/v1/messages", [("anthropic-version", "2023-06-01")]),
            body: Data(), endpoint: .messages, remote: remote(deepseek, apiKey: "ds-key"), query: "")
        #expect(messagesRequest.url?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages")
        #expect(messagesRequest.value(forHTTPHeaderField: "x-api-key") == "ds-key")
        #expect(messagesRequest.value(forHTTPHeaderField: "authorization") == nil)

        let gemini = try #require(ProviderPreset.all.first { $0.id == "gemini" })
        let chatRequest = try Forwarder.buildRequest(
            clientHead: head("/v1/chat/completions", []),
            body: Data(#"{"model":"main"}"#.utf8), endpoint: .chat, remote: remote(gemini, apiKey: "g-key"),
            query: "")
        #expect(chatRequest.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        #expect(chatRequest.value(forHTTPHeaderField: "authorization") == "Bearer g-key")
    }

    // MARK: 搜索

    @Test func matchesQueryByNameIdAndAliases() {
        func ids(_ query: String) -> Set<String> {
            Set(ProviderPreset.all.filter { $0.matches(query: query) }.map(\.id))
        }
        // 空查询匹配全部（UI 搜索框为空时展示完整目录）。
        #expect(ids("").count == ProviderPreset.all.count)
        #expect(ids("zcode").isSuperset(of: ["zhipu-coding", "zai-coding"]))
        #expect(ids("智谱").contains("zhipu-coding"))
        #expect(ids("google").contains("gemini"))
        #expect(ids("moonshot").contains("kimi"))
        #expect(ids("不存在的品牌").isEmpty)
    }
}
