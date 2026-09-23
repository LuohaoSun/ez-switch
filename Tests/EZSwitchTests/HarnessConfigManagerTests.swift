import Foundation
import Testing
@testable import EZSwitch

@Suite("Harness configuration backup")
struct HarnessConfigManagerTests {
    private func fixture() throws -> (URL, HarnessConfigManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, HarnessConfigManager(home: root, backupRoot: root.appendingPathComponent("backups")))
    }

    @Test func installAndRestoreOriginalBytes() throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"language\":\"zh\",\"env\":{\"EXTRA\":\"ok\"}}\n".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let plan = try manager.preview(target: .claudeCode, endpoint: "http://127.0.0.1:8788", modelID: "main")
        try manager.install(plan)
        #expect(manager.hasBackup(for: .claudeCode))
        #expect(try Data(contentsOf: file) != original)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(throws: Error.self) { try manager.install(plan) }
        try manager.restore(.claudeCode)
        #expect(try Data(contentsOf: file) == original)
        #expect(!manager.hasBackup(for: .claudeCode))
    }

    @Test func codexInstallAndRestorePreservesUnrelatedTOML() throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("# keep\nmodel = \"old\"\n\n[projects.\"/tmp/demo\"]\ntrust_level = \"trusted\"\n".utf8)
        try original.write(to: file)
        let plan = try manager.preview(target: .codex, endpoint: "http://127.0.0.1:8788/v1", modelID: "main")
        try manager.install(plan)
        let configured = try String(contentsOf: file, encoding: .utf8)
        #expect(configured.contains("[model_providers.ezswitch]"))
        #expect(configured.contains("[projects.\"/tmp/demo\"]"))
        try manager.restore(.codex)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func restoreRefusesLaterEditsAndRetainsBackup() throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try manager.preview(target: .claudeCode, endpoint: "http://127.0.0.1:8788", modelID: "main")
        try manager.install(plan)
        try Data("{\"newer\":true}".utf8).write(to: plan.fileURL, options: .atomic)
        #expect(throws: HarnessConfigError.self) { try manager.restore(.claudeCode) }
        #expect(manager.hasBackup(for: .claudeCode))
        #expect(try Data(contentsOf: plan.fileURL) == Data("{\"newer\":true}".utf8))
    }

    @Test func restoresAbsentFileAndRejectsStalePreview() throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try manager.preview(target: .claudeCode, endpoint: "http://127.0.0.1:8788", modelID: "main")
        try FileManager.default.createDirectory(at: plan.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: plan.fileURL)
        #expect(throws: HarnessConfigError.self) { try manager.install(plan) }
        try FileManager.default.removeItem(at: plan.fileURL)
        let fresh = try manager.preview(target: .claudeCode, endpoint: "http://127.0.0.1:8788", modelID: "main")
        try manager.install(fresh)
        try manager.restore(.claudeCode)
        #expect(!FileManager.default.fileExists(atPath: fresh.fileURL.path))
    }

    @Test func refusesSymlinkWithoutTouchingTarget() throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real.json")
        let original = Data("{}".utf8)
        try original.write(to: real)
        let link = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: HarnessConfigError.self) {
            try manager.preview(target: .claudeCode, endpoint: "http://127.0.0.1:8788", modelID: "main")
        }
        #expect(try Data(contentsOf: real) == original)
    }

    @Test func refusesSymlinkedConfigurationDirectory() throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDir = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".claude"),
                                                   withDestinationURL: realDir)
        #expect(throws: HarnessConfigError.self) {
            try manager.preview(target: .claudeCode, endpoint: "http://127.0.0.1:8788", modelID: "main")
        }
        #expect(!FileManager.default.fileExists(atPath: realDir.appendingPathComponent("settings.json").path))
    }

    @Test func interruptedInstallWithUnchangedOriginalCanBeCleared() throws {
        let (root, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"language\":\"zh\"}".utf8)
        try original.write(to: file)
        let plan = try manager.preview(target: .claudeCode, endpoint: "http://127.0.0.1:8788", modelID: "main")
        try manager.install(plan)
        try original.write(to: file, options: .atomic)
        try manager.restore(.claudeCode)
        #expect(!manager.hasBackup(for: .claudeCode))
        #expect(try Data(contentsOf: file) == original)
    }
}
