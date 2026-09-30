import Foundation
import Testing
@testable import EZSwitch

@MainActor
@Suite("Route fallback")
struct RouteFallbackTests {
    private func remote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "test-key", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.test/v1"))
    }

    @Test
    func legacyBindingDecodesAsSingleCandidate() throws {
        let id = UUID(), remoteID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString, "fakeModelID": "main", "displayName": "main",
            "remoteID": remoteID.uuidString
        ])
        let fake = try JSONDecoder().decode(FakeModel.self, from: data)
        #expect(fake.orderedRemoteIDs == [remoteID])
        #expect(fake.autoFallback)
        #expect(fake.startingRemoteID == remoteID)
    }

    @Test
    func routeOrderPersistsAndDeletionPromotesBackup() throws {
        let first = remote("A", "one"), second = remote("B", "two"), third = remote("C", "three")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: first.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [first, second, third], fakes: [fake])).write(to: url)
        let store = ConfigStore(configURL: url)

        #expect(store.setRouteTargets(fakeID: fake.id, remoteIDs: [first.id, second.id, third.id], autoFallback: true))
        #expect(!store.setRouteTargets(fakeID: fake.id, remoteIDs: [first.id, first.id], autoFallback: true))
        #expect(store.router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [first.id, second.id, third.id])
        store.removeRemote(id: first.id)
        #expect(store.config.fakes[0].orderedRemoteIDs == [second.id, third.id])
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.fakes[0].orderedRemoteIDs == [second.id, third.id])
    }

    @Test
    func cooldownSkipsFailedPrimaryButManualModeKeepsPrimary() throws {
        let first = remote("A", "one"), second = remote("B", "two")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: first.id, fallbackRemoteIDs: [second.id])
        let router = Router()
        router.update(AppConfig(port: 8788, remotes: [first, second], fakes: [fake]))
        router.recordFailure(remoteID: first.id, retryAfter: Date().addingTimeInterval(60))
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [second.id])
        var manual = fake
        manual.autoFallback = false
        router.update(AppConfig(port: 8788, remotes: [first, second], fakes: [manual]))
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [first.id])
    }

    @Test
    func selectingCurrentModelPersistsWithoutChangingFallbackOrder() throws {
        let first = remote("A", "one"), second = remote("B", "two"), third = remote("C", "three")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: first.id, fallbackRemoteIDs: [second.id, third.id])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [first, second, third], fakes: [fake])).write(to: url)
        let store = ConfigStore(configURL: url)

        #expect(store.selectRouteModel(fakeID: fake.id, remoteID: second.id))
        #expect(!store.selectRouteModel(fakeID: fake.id, remoteID: UUID()))
        #expect(store.config.fakes[0].orderedRemoteIDs == [first.id, second.id, third.id])
        #expect(store.router.activeRemoteID(fakeID: fake.id) == second.id)
        #expect(store.router.candidates(fakeModelID: "main")?.remotes.map(\.id) ==
                [second.id, third.id, first.id])
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.fakes[0].selectedRemoteID == second.id)

        #expect(store.setRouteTargets(fakeID: fake.id, remoteIDs: [first.id, second.id, third.id],
                                      autoFallback: false))
        #expect(store.router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [second.id])
        store.removeRemote(id: second.id)
        #expect(store.config.fakes[0].selectedRemoteID == nil)
        #expect(store.router.activeRemoteID(fakeID: fake.id) == first.id)
    }

    @Test
    func providerCreationImportsSelectedModelsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [], fakes: [])).write(to: url)
        let store = ConfigStore(configURL: url)
        let endpoints = APIEndpointSettings.all(baseURL: "https://example.test/v1/")
        #expect(store.addProvider(name: "Test", modelIDs: [], apiKey: "key", extraHeaders: [:], apiEndpoints: endpoints) != nil)
        #expect(store.config.remotes.isEmpty)
        #expect(store.addProvider(name: "Test", modelIDs: ["one", "two"], apiKey: "key",
                                  extraHeaders: ["x-test": "value"], apiEndpoints: endpoints) == nil)
        #expect(store.config.remotes.map(\.model) == ["one", "two"])
        #expect(store.config.remotes.allSatisfy { $0.apiKey == "key" && $0.extraHeaders["x-test"] == "value" })
        #expect(store.addProvider(name: "Test", modelIDs: ["three"], apiKey: "other", extraHeaders: [:], apiEndpoints: endpoints) != nil)
        #expect(store.config.remotes.count == 2)
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.remotes.map(\.model) == ["one", "two"])
    }

    @Test
    func cardReorderingPersistsWithoutChangingRouteSelections() throws {
        let a = remote("A", "one"), b = remote("B", "two"), c = remote("C", "three")
        var first = FakeModel(id: UUID(), fakeModelID: "first", displayName: "first",
                              remoteID: a.id, fallbackRemoteIDs: [b.id])
        first.selectedRemoteID = b.id
        let second = FakeModel(id: UUID(), fakeModelID: "second", displayName: "second", remoteID: c.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: [a, b, c], fakes: [first, second])).write(to: url)
        let store = ConfigStore(configURL: url)
        store.moveProviders(sources: ["A"], before: nil)
        #expect(store.groupedRemotes().map(\.provider) == ["B", "C", "A"])
        store.moveProviders(sources: ["A"], before: "B")
        store.moveFakes(sources: [first.id], before: nil)
        #expect(store.config.fakes.map(\.id) == [second.id, first.id])
        store.moveFakes(sources: [first.id], before: second.id)
        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(persisted.remotes.map(\.id) == [a.id, b.id, c.id])
        #expect(persisted.fakes.map(\.id) == [first.id, second.id])
        #expect(persisted.fakes[0].orderedRemoteIDs == [a.id, b.id])
        #expect(persisted.fakes[0].selectedRemoteID == b.id)
        #expect(store.router.activeRemoteID(fakeID: first.id) == b.id)
    }

    @Test
    func modelCatalogUsesConfiguredEndpointAndCredentials() throws {
        var model = remote("A", "one")
        model.extraHeaders = ["x-provider": "custom"]
        let openAI = try ProviderModelCatalog.request(for: model)
        #expect(openAI.url?.absoluteString == "https://example.test/v1/models")
        #expect(openAI.value(forHTTPHeaderField: "authorization") == "Bearer test-key")
        #expect(openAI.value(forHTTPHeaderField: "x-provider") == "custom")

        model.apiEndpoints = .enabled([.messages], baseURL: "https://api.anthropic.com")
        let anthropic = try ProviderModelCatalog.request(for: model)
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "test-key")
        model.apiEndpoints = .enabled([.messages], baseURL: "https://api.anthropic.com/v1")
        #expect(try ProviderModelCatalog.request(for: model).url?.absoluteString ==
                "https://api.anthropic.com/v1/models")
    }
}
