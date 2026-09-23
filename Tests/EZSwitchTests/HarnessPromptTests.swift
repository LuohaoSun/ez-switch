import Foundation
import Testing
@testable import EZSwitch

@Suite("Harness prompt")
struct HarnessPromptTests {
    @Test
    func oneClickHarnessDefaultPrefersCompatibleMainOtherwiseFirst() {
        let first = FakeModel(id: UUID(), fakeModelID: "ultra", displayName: "ultra", remoteID: UUID())
        let main = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: UUID())
        #expect(HarnessTarget.codex.requiredEndpoint == .responses)
        #expect(HarnessTarget.claudeCode.requiredEndpoint == .messages)
        #expect(HarnessTarget.codex.defaultModel(in: [first, main])?.fakeModelID == "main")
        #expect(HarnessTarget.codex.defaultModel(in: [first])?.fakeModelID == "ultra")
        #expect(HarnessTarget.codex.defaultModel(in: []) == nil)
    }

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
        let modelIDs = ["ultra", "main", "sub"]
        let prompt = HarnessPrompt.make(
            harness: .opencode,
            endpoint: "http://127.0.0.1:8788/v1",
            modelIDs: modelIDs
        )

        #expect(prompt.contains("在 OpenCode 中添加 EZ Switch 供应商"))
        #expect(prompt.contains("全部本机模型 ID：ultra、main、sub"))
        for modelID in modelIDs {
            #expect(prompt.contains(modelID))
        }
        #expect(prompt.contains("http://127.0.0.1:8788/v1"))
        #expect(prompt.contains("保留现有供应商和设置，先备份再修改"))
        #expect(prompt.contains("如何在 OpenCode 中切换这些模型"))
    }
}
