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
}
