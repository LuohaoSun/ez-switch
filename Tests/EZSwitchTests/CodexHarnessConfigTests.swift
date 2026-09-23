import Foundation
import Testing
@testable import EZSwitch

@Suite("Codex harness config")
struct CodexHarnessConfigTests {
    private let endpoint = "http://127.0.0.1:8788/v1"

    private func render(_ original: String?) throws -> String {
        try configure(original.map { Data($0.utf8) })
    }

    private func configure(_ original: Data?) throws -> String {
        let data = try CodexHarnessConfig.configure(original, endpoint: endpoint, modelID: "main")
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test
    func missingFileCreatesOnlyTheRequiredCodexConfig() throws {
        #expect(try render(nil) == """
        model = "main"
        model_provider = "ezswitch"

        [model_providers.ezswitch]
        name = "EZ Switch"
        base_url = "http://127.0.0.1:8788/v1"
        wire_api = "responses"
        experimental_bearer_token = "ez-switch-local"

        """)
    }

    @Test
    func emptyDataMatchesMissingFile() throws {
        #expect(try configure(Data()) == (try render(nil)))
    }

    @Test
    func topLevelKeysAreInsertedBeforeTheFirstTable() throws {
        let original = """
        # retained header
        approval_policy = "never"

        [features]
        fast_mode = true
        """

        let output = try render(original)

        #expect(output.contains("# retained header"))
        #expect(output.contains("approval_policy = \"never\""))
        #expect(output.contains("[features]\nfast_mode = true"))
        let model = try #require(output.range(of: "model = \"main\""))
        let table = try #require(output.range(of: "[features]"))
        #expect(model.lowerBound < table.lowerBound)
    }

    @Test
    func existingKeysAndProviderFieldsAreUpdatedWithoutLosingCommentsOrUnknownFields() throws {
        let original = """
        model = "old" # model comment
        model_provider = 'old-provider' # provider comment
        unrelated = "keep"

        [other]
        value = 1 # unrelated comment

        [model_providers.ezswitch] # table comment
        name = "Old Name" # name comment
        base_url = "http://old.example/v1"
        wire_api = "chat" # wire comment
        experimental_bearer_token = "old-token"
        extra_query_params = { channel = "stable" }

        # trailing comment
        """

        let output = try render(original)

        #expect(output.contains("model = \"main\" # model comment"))
        #expect(output.contains("model_provider = \"ezswitch\" # provider comment"))
        #expect(output.contains("unrelated = \"keep\""))
        #expect(output.contains("value = 1 # unrelated comment"))
        #expect(output.contains("[model_providers.ezswitch] # table comment"))
        #expect(output.contains("name = \"EZ Switch\" # name comment"))
        #expect(output.contains("base_url = \"http://127.0.0.1:8788/v1\""))
        #expect(output.contains("wire_api = \"responses\" # wire comment"))
        #expect(output.contains("experimental_bearer_token = \"ez-switch-local\""))
        #expect(output.contains("extra_query_params = { channel = \"stable\" }"))
        #expect(output.hasSuffix("# trailing comment\n"))
    }

    @Test
    func emptyExistingProviderTableGetsFieldsBeforeTheNextTable() throws {
        let original = """
        [model_providers.ezswitch]
        # keep this note

        [other]
        value = 1
        """

        let output = try render(original)

        #expect(output.contains("# keep this note"))
        let end = try #require(output.range(of: "[other]"))
        for field in ["name =", "base_url =", "wire_api =", "experimental_bearer_token ="] {
            let range = try #require(output.range(of: field))
            #expect(range.lowerBound < end.lowerBound)
        }
    }

    @Test
    func providerTableIsAppendedWhenAbsent() throws {
        let original = """
        model = "main"
        model_provider = "ezswitch"

        [features]
        fast_mode = true
        """

        let output = try render(original)

        #expect(output.contains("[features]\nfast_mode = true"))
        #expect(output.contains("\n[model_providers.ezswitch]\nname = \"EZ Switch\""))
        #expect(output.hasSuffix("experimental_bearer_token = \"ez-switch-local\"\n"))
    }

    @Test
    func outputIsIdempotent() throws {
        let original = """
        # keep
        model = "old"
        model_provider = "old"

        [model_providers.ezswitch]
        name = "old" # keep me
        extra_query_params = { channel = "stable" }

        [other]
        value = [1, 2, 3]
        """

        let first = try render(original)
        let second = try render(first)

        #expect(first == second)
    }

    @Test
    func duplicateTopLevelKeysAreRejected() {
        let original = """
        model = "one"
        model = "two"
        """
        #expect(throws: CodexHarnessConfigError.self) { try render(original) }
    }

    @Test
    func duplicateProviderTablesAreRejected() {
        let original = """
        [model_providers.ezswitch]
        name = "one"

        [model_providers.ezswitch]
        name = "two"
        """
        #expect(throws: CodexHarnessConfigError.self) { try render(original) }
    }

    @Test
    func duplicateProviderFieldsAreRejected() {
        let original = """
        [model_providers.ezswitch]
        name = "one"
        name = "two"
        """
        #expect(throws: CodexHarnessConfigError.self) { try render(original) }
    }

    @Test
    func existingProviderAuthSourceIsRejected() {
        #expect(throws: CodexHarnessConfigError.self) {
            try render("[model_providers.ezswitch]\nenv_key = \"EXISTING_KEY\"\n")
        }
        #expect(throws: CodexHarnessConfigError.self) {
            try render("[model_providers.ezswitch]\nrequires_openai_auth = true\n")
        }
        #expect(throws: CodexHarnessConfigError.self) {
            try render("[model_providers.ezswitch]\nauth = { command = \"token-helper\" }\n")
        }
    }

    @Test
    func arrayOfTablesIsRejectedConservatively() {
        let original = """
        [[mcp_servers]]
        command = "server"
        """
        #expect(throws: CodexHarnessConfigError.self) { try render(original) }
    }

    @Test
    func dottedAssignmentIsRejectedConservatively() {
        #expect(throws: CodexHarnessConfigError.self) {
            try render("model.value = \"main\"\n")
        }
    }

    @Test
    func complexTargetValuesAreRejected() {
        #expect(throws: CodexHarnessConfigError.self) {
            try render("model = [\"main\"]\n")
        }
        #expect(throws: CodexHarnessConfigError.self) {
            try render("[model_providers.ezswitch]\nname = { value = \"EZ\" }\n")
        }
    }

    @Test
    func multilineStringsAreRejectedConservatively() {
        #expect(throws: CodexHarnessConfigError.self) {
            try render("instructions = \"\"\"hello\"\"\"\n")
        }
    }

    @Test
    func generatedStringsEscapeTOMLSpecialCharacters() throws {
        let data = try CodexHarnessConfig.configure(
            nil,
            endpoint: "http://127.0.0.1:8788/v1?x=\"quoted\"\\path\nnext",
            modelID: "main\"\\line\nnext"
        )
        let output = try #require(String(data: data, encoding: .utf8))

        #expect(output.contains("model = \"main\\\"\\\\line\\nnext\""))
        #expect(output.contains("base_url = \"http://127.0.0.1:8788/v1?x=\\\"quoted\\\"\\\\path\\nnext\""))
    }

    @Test
    func invalidUTF8IsRejected() {
        #expect(throws: CodexHarnessConfigError.self) {
            try configure(Data([0xFF, 0xFE, 0xFD]))
        }
    }

    @Test
    func generatedConfigPassesCodexStrictConfigWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["RUN_CODEX_STRICT_CONFIG_TESTS"] == "1" else {
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarnessConfigTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let original = "# keep\napproval_policy = \"never\"\n\n[features]\nfast_mode = true\n"
        let generated = try CodexHarnessConfig.configure(
            Data(original.utf8),
            endpoint: endpoint,
            modelID: "main"
        )
        try generated.write(to: root.appendingPathComponent("config.toml"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "codex", "exec", "--strict-config", "resume",
            "00000000-0000-0000-0000-000000000000", "config check",
            "--skip-git-repo-check",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = root.path
        environment["HOME"] = root.path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(!output.contains("Error loading config.toml"), "codex --strict-config 失败：\n\(output)")
        #expect(output.contains("no rollout found"), "未到达预期的隔离 resume 校验路径：\n\(output)")
    }
}
