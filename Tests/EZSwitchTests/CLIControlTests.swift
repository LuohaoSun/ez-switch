import Foundation
import Testing
@testable import EZSwitch

@MainActor
@Suite("CLI control")
struct CLIControlTests {
    @Test
    func listAndSetUseTheSameStoreAsMenuSwitching() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CLIControlTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let one = RemoteModel(id: UUID(), name: "Alpha · one", apiKey: "secret", model: "one",
                              extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test/v1"))
        let two = RemoteModel(id: UUID(), name: "Alpha · two", apiKey: "secret", model: "two",
                              extraHeaders: [:], apiEndpoints: one.apiEndpoints)
        let other = RemoteModel(id: UUID(), name: "Beta · two", apiKey: "secret", model: "two",
                                extraHeaders: [:], apiEndpoints: one.apiEndpoints)
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: one.id)
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 0, remotes: [one, two, other], fakes: [fake])).write(to: url)
        let store = ConfigStore(configURL: url)
        func send(_ command: [String: String]) throws -> [String: Any] {
            try store.handleCLICommand(JSONSerialization.data(withJSONObject: command))
        }
        let listed = try send(["command": "list"])
        #expect(listed["ok"] as? Bool == true)
        let routes = try #require(listed["routes"] as? [[String: String]])
        #expect(routes.first?["provider"] == "Alpha")
        let providers = try #require(listed["providers"] as? [[String: Any]])
        #expect(providers.count == 2)
        let changed = try send(["command": "set", "fakeID": "main", "provider": "Beta", "model": "two"])
        #expect(changed["ok"] as? Bool == true)
        #expect(store.router.route(fakeModelID: "main")?.remote.id == other.id)
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.fakes.first?.remoteID == other.id)
        let missing = try send(["command": "set", "fakeID": "unknown", "provider": "Alpha", "model": "two"])
        #expect(missing["ok"] as? Bool == false)
        #expect(store.config.fakes.first?.remoteID == other.id)
        let byID = try send(["command": "set", "fakeID": "main", "remoteID": two.id.uuidString])
        #expect(byID["ok"] as? Bool == true)
        #expect(store.router.route(fakeModelID: "main")?.remote.id == two.id)
    }

    // MARK: - 写盘结果传播（成功 / writeBlocked / I/O 失败）

    /// 成功路径回归：CLI set 命中候选 → selectRouteModel 分支，落盘后 ok:true。
    @Test
    func setPersistsSelectedCandidateAndReportsOk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIControlSaveOK-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let one = RemoteModel(id: UUID(), name: "Alpha · one", apiKey: "secret", model: "one",
                              extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test/v1"))
        let two = RemoteModel(id: UUID(), name: "Alpha · two", apiKey: "secret", model: "two",
                              extraHeaders: [:], apiEndpoints: one.apiEndpoints)
        // two 已是候选 → CLI 走 selectRouteModel（选中候选）分支。
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: one.id, fallbackRemoteIDs: [two.id])
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 0, remotes: [one, two], fakes: [fake])).write(to: url)
        let store = ConfigStore(configURL: url)

        let reply = try store.handleCLICommand(JSONSerialization.data(
            withJSONObject: ["command": "set", "fakeID": "main", "remoteID": two.id.uuidString]))
        #expect(reply["ok"] as? Bool == true)
        #expect(store.router.activeRemoteID(fakeID: fake.id) == two.id)
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.fakes.first?.selectedRemoteID == two.id)
    }

    /// writeBlocked：磁盘配置损坏进入写盘保护后，改动仅内存生效，CLI 必须 ok:false。
    @Test
    func setReportsFailureWhenDiskConfigIsUnreadable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIControlBlocked-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let one = RemoteModel(id: UUID(), name: "Alpha · one", apiKey: "secret", model: "one",
                              extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test/v1"))
        let two = RemoteModel(id: UUID(), name: "Alpha · two", apiKey: "secret", model: "two",
                              extraHeaders: [:], apiEndpoints: one.apiEndpoints)
        // two 不在候选里 → CLI 走 setRoute 分支。
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: one.id)
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 0, remotes: [one, two], fakes: [fake])).write(to: url)
        let store = ConfigStore(configURL: url)

        // 外部把磁盘配置写坏，再触发 reload → 进入写盘保护（内存配置保留）。
        let corrupt = Data("{ not valid json".utf8)
        try corrupt.write(to: url)
        store.reloadFromDisk()
        #expect(store.configLoadError != nil)

        let reply = try store.handleCLICommand(JSONSerialization.data(
            withJSONObject: ["command": "set", "fakeID": "main", "provider": "Alpha", "model": "two"]))
        #expect(reply["ok"] as? Bool == false)
        let message = try #require(reply["message"] as? String)
        #expect(message.contains("memory"))
        // 内存内已生效；原（损坏）文件未被覆盖。
        #expect(store.router.route(fakeModelID: "main")?.remote.id == two.id)
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == corrupt)
    }

    /// I/O 失败：目录不可写导致原子写盘失败，CLI 仍须 ok:false 且改动留在内存。
    @Test
    func setReportsFailureWhenSaveHitsIOError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIControlIO-\(UUID())")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let one = RemoteModel(id: UUID(), name: "Alpha · one", apiKey: "secret", model: "one",
                              extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test/v1"))
        let two = RemoteModel(id: UUID(), name: "Alpha · two", apiKey: "secret", model: "two",
                              extraHeaders: [:], apiEndpoints: one.apiEndpoints)
        // two 是候选 → 走 selectRouteModel 分支。
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: one.id, fallbackRemoteIDs: [two.id])
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 0, remotes: [one, two], fakes: [fake])).write(to: url)
        let store = ConfigStore(configURL: url)

        // 目录只读：原子写盘无法在其中创建临时文件 → I/O 失败。
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)

        let reply = try store.handleCLICommand(JSONSerialization.data(
            withJSONObject: ["command": "set", "fakeID": "main", "remoteID": two.id.uuidString]))
        #expect(reply["ok"] as? Bool == false)
        let message = try #require(reply["message"] as? String)
        #expect(message.contains("memory"))
        // 内存内已生效。
        #expect(store.router.activeRemoteID(fakeID: fake.id) == two.id)
    }
}
