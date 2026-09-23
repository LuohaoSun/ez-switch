import Foundation
import Testing
@testable import EZSwitch

@Suite("Claude harness configuration")
struct ClaudeHarnessConfigTests {
    private func root(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func environment(_ data: Data) throws -> [String: Any] {
        let object = try root(data)
        return try #require(object["env"] as? [String: Any])
    }

    @Test
    func createsConfigurationWhenFileIsMissing() throws {
        let data = try ClaudeHarnessConfig.configure(
            nil,
            endpoint: "http://127.0.0.1:8788",
            modelID: "main"
        )
        let env = try environment(data)

        #expect(env["ANTHROPIC_BASE_URL"] as? String == "http://127.0.0.1:8788")
        #expect(env["ANTHROPIC_AUTH_TOKEN"] as? String == "ez-switch-local")
        #expect(env["ANTHROPIC_MODEL"] as? String == "main")
        #expect(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String == "main")
        #expect(env["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String == "main")
        #expect(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String == "main")
        #expect(env["ANTHROPIC_SMALL_FAST_MODEL"] as? String == "main")
    }

    @Test
    func preservesUnknownFieldsAndReplacesExistingSecrets() throws {
        let original = Data("""
        {
          "model": "opus",
          "permissions": { "allow": ["Bash(git status)"] },
          "env": {
            "KEEP_ME": "yes",
            "NESTED": { "enabled": true, "count": 2 },
            "ANTHROPIC_BASE_URL": "https://old.example",
            "ANTHROPIC_AUTH_TOKEN": "old-secret",
            "ANTHROPIC_MODEL": "old-model"
          }
        }
        """.utf8)

        let data = try ClaudeHarnessConfig.configure(
            original,
            endpoint: "http://127.0.0.1:8788",
            modelID: "main"
        )
        let object = try root(data)
        let env = try environment(data)

        #expect(object["model"] as? String == "opus")
        let permissions = try #require(object["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Bash(git status)"])
        #expect(env["KEEP_ME"] as? String == "yes")
        let nested = try #require(env["NESTED"] as? [String: Any])
        #expect(nested["enabled"] as? Bool == true)
        #expect(nested["count"] as? Int == 2)
        #expect(env["ANTHROPIC_BASE_URL"] as? String == "http://127.0.0.1:8788")
        #expect(env["ANTHROPIC_AUTH_TOKEN"] as? String == "ez-switch-local")
        #expect(env["ANTHROPIC_MODEL"] as? String == "main")
        #expect(!String(decoding: data, as: UTF8.self).contains("old-secret"))
    }

    @Test
    func overridesEveryExistingModelRoutingVariable() throws {
        let original = Data("""
        {
          "env": {
            "KEEP_ME": "yes",
            "ANTHROPIC_DEFAULT_MODEL": "legacy-default",
            "ANTHROPIC_DEFAULT_FABLE_MODEL": "legacy-fable",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "legacy-opus",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "legacy-sonnet",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "legacy-haiku",
            "ANTHROPIC_SMALL_FAST_MODEL": "legacy-small-fast",
            "CLAUDE_CODE_SUBAGENT_MODEL": "legacy-subagent"
          }
        }
        """.utf8)

        let env = try environment(ClaudeHarnessConfig.configure(
            original,
            endpoint: "http://127.0.0.1:8788",
            modelID: "main"
        ))

        for key in [
            "ANTHROPIC_DEFAULT_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "CLAUDE_CODE_SUBAGENT_MODEL",
        ] {
            #expect(env[key] as? String == "main")
        }
        #expect(env["KEEP_ME"] as? String == "yes")
    }

    @Test
    func isIdempotent() throws {
        let original = Data(#"{"env":{"KEEP_ME":"yes","ANTHROPIC_MODEL":"old"}}"#.utf8)
        let once = try ClaudeHarnessConfig.configure(
            original,
            endpoint: "http://127.0.0.1:8788",
            modelID: "main"
        )
        let twice = try ClaudeHarnessConfig.configure(
            once,
            endpoint: "http://127.0.0.1:8788",
            modelID: "main"
        )

        #expect(once == twice)
    }

    @Test
    func rejectsInvalidJSON() {
        #expect(throws: ClaudeHarnessConfigError.self) {
            try ClaudeHarnessConfig.configure(
                Data(#"{"env":"#.utf8),
                endpoint: "http://127.0.0.1:8788",
                modelID: "main"
            )
        }
        #expect(throws: ClaudeHarnessConfigError.self) {
            try ClaudeHarnessConfig.configure(
                Data(),
                endpoint: "http://127.0.0.1:8788",
                modelID: "main"
            )
        }
    }

    @Test
    func rejectsNonObjectRoot() {
        #expect(throws: ClaudeHarnessConfigError.self) {
            try ClaudeHarnessConfig.configure(
                Data(#"["not", "an", "object"]"#.utf8),
                endpoint: "http://127.0.0.1:8788",
                modelID: "main"
            )
        }
    }

    @Test
    func rejectsNonObjectEnvironment() {
        #expect(throws: ClaudeHarnessConfigError.self) {
            try ClaudeHarnessConfig.configure(
                Data(#"{"env":["not","an","object"]}"#.utf8),
                endpoint: "http://127.0.0.1:8788",
                modelID: "main"
            )
        }
        #expect(throws: ClaudeHarnessConfigError.self) {
            try ClaudeHarnessConfig.configure(
                Data(#"{"env":null}"#.utf8),
                endpoint: "http://127.0.0.1:8788",
                modelID: "main"
            )
        }
    }
}
