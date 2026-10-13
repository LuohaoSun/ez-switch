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

    // MARK: 自动回退成功后的粘性首选（运行期状态）

    /// 一次“已完成的成功”才把回退目标提升为首选；首选失败即回到持久起始。
    @Test
    func completedFallbackSuccessBecomesPreferredAndReversesOnFailure() throws {
        let a = remote("A", "one"), b = remote("B", "two")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: a.id, fallbackRemoteIDs: [b.id])
        let router = Router()
        router.update(AppConfig(port: 8788, remotes: [a, b], fakes: [fake]))
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [a.id, b.id])

        // a 失败（冷却已过期，仅用于观察顺序）；b 在同一请求内完成成功 → 成为首选。
        let epoch = router.requestEpoch(fakeModelID: "main")
        router.recordFailure(remoteID: a.id, retryAfter: Date().addingTimeInterval(-1))
        router.recordSuccess(fakeID: fake.id, remoteID: b.id, epoch: epoch)
        #expect(router.activeRemoteID(fakeID: fake.id) == b.id)
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [b.id, a.id])

        // 首选失败 → 回到持久起始。
        router.recordFailure(remoteID: b.id, retryAfter: Date().addingTimeInterval(-1))
        #expect(router.activeRemoteID(fakeID: fake.id) == a.id)
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [a.id, b.id])
    }

    /// 手动选择发生在在途请求拿到响应头之前：迟到的完成不得覆盖它。
    @Test
    func manualSelectionIsNotOverriddenByStaleCompletion() throws {
        let a = remote("A", "one"), b = remote("B", "two")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: a.id, fallbackRemoteIDs: [b.id])
        let router = Router()
        router.update(AppConfig(port: 8788, remotes: [a, b], fakes: [fake]))

        let staleEpoch = router.requestEpoch(fakeModelID: "main")   // 旧计划 a → b 的开始代次
        router.selectRemote(fakeID: fake.id, remoteID: a.id)        // 用户手动选回 a
        router.recordSuccess(fakeID: fake.id, remoteID: b.id, epoch: staleEpoch)

        #expect(router.activeRemoteID(fakeID: fake.id) == a.id)
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [a.id, b.id])
    }

    /// 同一代次的更早完成迟到时，不得撤销更晚的一次成功提升。
    @Test
    func delayedSameGenerationOlderSuccessDoesNotUndoNewerFallback() throws {
        let a = remote("A", "one"), b = remote("B", "two"), c = remote("C", "three")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: a.id, fallbackRemoteIDs: [b.id, c.id])
        let router = Router()
        router.update(AppConfig(port: 8788, remotes: [a, b, c], fakes: [fake]))

        let epoch = router.requestEpoch(fakeModelID: "main")        // 两个请求同代次开始
        router.recordSuccess(fakeID: fake.id, remoteID: b.id, epoch: epoch)
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [b.id, c.id, a.id])

        // 请求2（同代次的旧计划）迟到完成：c 成功 → 忽略。
        router.recordSuccess(fakeID: fake.id, remoteID: c.id, epoch: epoch)
        #expect(router.activeRemoteID(fakeID: fake.id) == b.id)
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [b.id, c.id, a.id])
    }

    /// 同目标重复成功保留代次；新代次请求前进到下一目标仍可提升。
    @Test
    func repeatedSuccessSameTargetRetainsEpochAndAllowsForwardPromotion() throws {
        let a = remote("A", "one"), b = remote("B", "two"), c = remote("C", "three")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: a.id, fallbackRemoteIDs: [b.id, c.id])
        let router = Router()
        router.update(AppConfig(port: 8788, remotes: [a, b, c], fakes: [fake]))

        let epoch0 = router.requestEpoch(fakeModelID: "main")
        // 对持久起始的成功：有效首选未变，不提升代次（避免作废并发的其它计划）。
        router.recordSuccess(fakeID: fake.id, remoteID: a.id, epoch: epoch0)
        #expect(router.requestEpoch(fakeModelID: "main") == epoch0)
        #expect(router.activeRemoteID(fakeID: fake.id) == a.id)

        router.recordSuccess(fakeID: fake.id, remoteID: b.id, epoch: epoch0)   // 有效首选 a → b
        let epoch1 = router.requestEpoch(fakeModelID: "main")
        #expect(epoch1 == epoch0 + 1)

        router.recordSuccess(fakeID: fake.id, remoteID: b.id, epoch: epoch1)   // 同目标，重复成功
        #expect(router.requestEpoch(fakeModelID: "main") == epoch1)            // 代次保持
        #expect(router.activeRemoteID(fakeID: fake.id) == b.id)

        router.recordSuccess(fakeID: fake.id, remoteID: c.id, epoch: epoch1)   // 新代次前进
        #expect(router.activeRemoteID(fakeID: fake.id) == c.id)
    }

    /// 关闭自动回退时忽略运行期首选，保留手动/持久起始目标。
    @Test
    func disabledAutoFallbackKeepsManualTargetIgnoringRuntimePreference() throws {
        let a = remote("A", "one"), b = remote("B", "two")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: a.id, fallbackRemoteIDs: [b.id])
        let router = Router()
        router.update(AppConfig(port: 8788, remotes: [a, b], fakes: [fake]))

        let epoch = router.requestEpoch(fakeModelID: "main")
        router.recordSuccess(fakeID: fake.id, remoteID: b.id, epoch: epoch)
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [b.id, a.id])

        var off = fake
        off.autoFallback = false
        router.update(AppConfig(port: 8788, remotes: [a, b], fakes: [off]))
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [a.id])
        #expect(router.activeRemoteID(fakeID: fake.id) == a.id)
    }

    /// 首选失败后，同一在途请求按已生成的顺序继续前进到下一个候选并提升它。
    @Test
    func preferredRemoteProgressesForwardWhenItFails() throws {
        let a = remote("A", "one"), b = remote("B", "two"), c = remote("C", "three")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: a.id, fallbackRemoteIDs: [b.id, c.id])
        let router = Router()
        router.update(AppConfig(port: 8788, remotes: [a, b, c], fakes: [fake]))

        let epoch0 = router.requestEpoch(fakeModelID: "main")
        router.recordSuccess(fakeID: fake.id, remoteID: b.id, epoch: epoch0)
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [b.id, c.id, a.id])

        // 下一次请求从 b 开始；b 失败后候选已按 b → c → a 生成，继续到 c 成功。
        let epoch = router.requestEpoch(fakeModelID: "main")
        router.recordFailure(remoteID: b.id)
        router.recordSuccess(fakeID: fake.id, remoteID: c.id, epoch: epoch)
        #expect(router.activeRemoteID(fakeID: fake.id) == c.id)
        #expect(router.candidates(fakeModelID: "main")?.remotes.map(\.id) == [c.id, a.id])
    }
}
