import Foundation
import Testing
@testable import EZSwitch

/// 已存在供应商的品牌图标判定：优先按启用的 API Base URL host 精确识别，
/// 识别不到再用供应商名严格匹配；相似域名、短词、混用/冲突配置都不冒认。
@Suite("Provider brand resolution")
struct ProviderBrandTests {

    // MARK: - URL 优先：改名仍准确

    @Test func resolvesRenamedProviderByEndpointHost() {
        // 名称被用户改掉，但 URL 仍精确指向品牌。
        #expect(resolve("我的自建网关", chat: "https://api.deepseek.com/v1") == .known("deepseek"))
        // 智谱 / Z.AI 靠 URL host 区分，不依赖名称里硬写品牌词。
        #expect(resolve("随便叫", chat: "https://api.z.ai/api/coding/paas/v4") == .known("zai"))
        #expect(resolve("别名", chat: "https://open.bigmodel.cn/api/coding/paas/v4") == .known("zhipu"))
        #expect(resolve("x", chat: "https://opencode.ai/zen/go/v1") == .known("opencode"))
    }

    @Test func hostLookupIsCaseInsensitive() {
        #expect(resolve("x", chat: "HTTPS://API.OpenAI.COM/v1") == .known("openai"))
    }

    @Test func endpointsSharingOneHostResolveToSingleBrand() {
        // 同一品牌的多个协议（百炼同一 host 两个路径）仍算单一品牌。
        let r = remote("x", chat: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                       messages: "https://dashscope.aliyuncs.com/apps/anthropic")
        #expect(ProviderBrandResolver.resolve(group("x", [r])) == .known("alibaba"))
    }

    // MARK: - 名称兜底：仅整串、受控

    @Test func resolvesByStrictProviderNameWhenURLIsUnknown() {
        #expect(resolve("OpenAI", chat: "https://my-gateway.example/v1") == .known("openai"))
        #expect(resolve("Z.AI Coding", chat: "https://proxy.local/v1") == .known("zai"))
        #expect(resolve("moonshot", chat: "https://proxy.local/v1") == .known("kimi"))
    }

    @Test func substringsOfBrandWordsAreNotMatchedByName() {
        // go / or / cmd 等短词，以及含品牌词的词组，都不应被名称命中。
        for name in ["Go", "or", "cmd", "zen", "Google Cloud", "OpenAI Compatible", "prompt"] {
            #expect(resolve(name, chat: "https://unknown.example/v1") == .unknown,
                    "名称 '\(name)' 不应命中品牌")
        }
    }

    @Test func ambiguousBrandNamesAreNotGuessed() {
        // 别名 "z.ai" 同时属于 zhipu 与 zai → 不猜。
        #expect(resolve("z.ai", chat: "https://unknown.example/v1") == .unknown)
        #expect(resolve("glm", chat: "https://unknown.example/v1") == .unknown)
    }

    // MARK: - 相似域名不冒认

    @Test func similarDomainsDoNotImpersonate() {
        let lookalikes = [
            "https://api.deepseek.com.evil.example/v1",
            "https://api.deepseek.com.cn/v1",
            "https://notdeepseek.example/v1",
            "https://api.openai.com.attacker.example/v1",
            "https://openrouter.ai.evil.example/api/v1",
            "https://xapi.deepseek.com/v1",
        ]
        for host in lookalikes {
            #expect(resolve("Custom", chat: host) == .unknown, "相似域名不应冒认品牌：\(host)")
        }
    }

    // MARK: - 自定义 / 空

    @Test func customProviderWithoutRecognizableSignalIsUnknown() {
        #expect(resolve("本地网关", chat: "https://10.0.0.5:8080/v1") == .unknown)
        #expect(ProviderBrandResolver.resolve(group("本地网关", [])) == .unknown)
        #expect(ProviderBrandResolver.resolve(group("", [])) == .unknown)
    }

    // MARK: - 混用 / 冲突不猜测

    @Test func conflictingBrandEndpointsAreNotGuessed() {
        // 同一供应商的模型分别指向两个不同品牌 → 不猜，即使名称自称 OpenAI。
        let mixed = [remote("OpenAI", chat: "https://api.openai.com/v1", model: "a"),
                     remote("OpenAI", messages: "https://api.anthropic.com", model: "b")]
        #expect(ProviderBrandResolver.resolve(group("OpenAI", mixed)) == .unknown)

        // 单个模型的不同协议跨品牌，同样不猜。
        let crossProtocol = remote("Gateway", chat: "https://api.openai.com/v1",
                                   messages: "https://open.bigmodel.cn/api/anthropic")
        #expect(ProviderBrandResolver.resolve(group("Gateway", [crossProtocol])) == .unknown)
    }

    @Test func knownAndUnknownHostsMixedAreNotGuessed() {
        let mixed = remote("Gateway", chat: "https://api.deepseek.com/v1",
                           messages: "https://internal.example/anthropic")
        #expect(ProviderBrandResolver.resolve(group("Gateway", [mixed])) == .unknown)
    }

    // MARK: - 禁用 / 空地址不计

    @Test func disabledAndEmptyEndpointsAreIgnored() {
        var settings = allDisabled()
        settings.chat = EndpointSetting(enabled: false, baseURL: "https://api.openai.com/v1")
        settings.messages = EndpointSetting(enabled: true, baseURL: "https://api.deepseek.com/anthropic")
        #expect(ProviderBrandResolver.resolve(group("X", [makeModel("X", settings)])) == .known("deepseek"))

        var empty = allDisabled()
        empty.chat = EndpointSetting(enabled: true, baseURL: "")
        #expect(ProviderBrandResolver.resolve(group("Y", [makeModel("Y", empty)])) == .unknown)
    }

    // MARK: - 结果类型

    @Test func knownBrandExposesIconKeyOnly() {
        #expect(ProviderBrand.known("zai").iconName == "zai")
        #expect(ProviderBrand.unknown.iconName == nil)
    }

    // MARK: - helpers

    private func resolve(_ provider: String, chat: String? = nil,
                         responses: String? = nil, messages: String? = nil) -> ProviderBrand {
        ProviderBrandResolver.resolve(group(provider, [remote(provider, chat: chat,
                                                               responses: responses,
                                                               messages: messages)]))
    }

    private func group(_ provider: String, _ remotes: [RemoteModel]) -> RemoteGroup {
        RemoteGroup(provider: provider, remotes: remotes)
    }

    private func allDisabled() -> APIEndpointSettings {
        APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled)
    }

    private func setting(_ url: String?) -> EndpointSetting {
        guard let url else { return .disabled }
        return EndpointSetting(enabled: true, baseURL: url)
    }

    private func remote(_ provider: String, chat: String? = nil,
                        responses: String? = nil, messages: String? = nil,
                        model modelID: String = "m") -> RemoteModel {
        var settings = allDisabled()
        settings.chat = setting(chat)
        settings.responses = setting(responses)
        settings.messages = setting(messages)
        return makeModel(provider, settings, model: modelID)
    }

    private func makeModel(_ provider: String, _ settings: APIEndpointSettings,
                           model: String = "m") -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "k",
                    model: model, extraHeaders: [:], apiEndpoints: settings)
    }
}
