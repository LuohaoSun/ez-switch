import Testing
@testable import EZSwitch

@Suite("Harness prompt")
struct HarnessPromptTests {
    @Test
    func promptContainsDynamicEndpointAndModel() {
        let prompt = HarnessPrompt.make(
            harness: .codex,
            endpoint: "http://127.0.0.1:8799/v1",
            modelIDs: ["main", "ultra", "sub"]
        )

        #expect(prompt.contains("请帮我配置 Codex 供应商："))
        #expect(prompt.contains("- 端点：http://127.0.0.1:8799/v1"))
        #expect(prompt.contains("- 密钥：任意占位符（例如 ez-switch-local）"))
        #expect(prompt.contains("- 模型：main、ultra、sub"))
        #expect(prompt.contains("请修改 Codex 的配置文件"))
        #expect(!prompt.contains("当前 harness"))
        #expect(!prompt.contains("EZ Switch"))
    }

    @Test
    func promptUsesPlaceholderWhenNoModelIsAvailable() {
        let prompt = HarnessPrompt.make(
            harness: .claudeCode,
            endpoint: "http://127.0.0.1:8788",
            modelIDs: []
        )

        #expect(prompt.contains("请帮我配置 Claude Code 供应商："))
        #expect(prompt.contains("- 模型：<model-id>"))
        #expect(prompt.contains("请修改 Claude Code 的配置文件"))
    }

    @Test
    func promptNamesOpenCodeDirectly() {
        let prompt = HarnessPrompt.make(
            harness: .opencode,
            endpoint: "http://127.0.0.1:8788/v1",
            modelIDs: ["main"]
        )

        #expect(prompt.contains("请帮我配置 OpenCode 供应商："))
        #expect(prompt.contains("请修改 OpenCode 的配置文件"))
        #expect(!prompt.contains("当前 harness"))
    }
}
