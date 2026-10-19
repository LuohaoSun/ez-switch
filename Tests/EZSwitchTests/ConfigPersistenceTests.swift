import Foundation
import Testing
@testable import EZSwitch

@Suite("Config persistence")
struct ConfigPersistenceTests {
    @Test func backgroundWriteDoesNotBlockCallerAndLatestOrderWins() throws {
        let directory = try TempConfigDirectory(name: "background-order")
        try JSONEncoder().encode(AppConfig()).write(to: directory.url)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = ConfigPersistence(url: directory.url) { data, url in
            #expect(!Thread.isMainThread)
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            if config.port == 9001 {
                entered.signal()
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
            try data.write(to: url, options: .atomic)
        }
        var snapshot = AppConfig()
        snapshot.port = 9001
        writer.enqueue(snapshot) { _, _ in }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        defer { release.signal() }
        snapshot.port = 9002
        writer.enqueue(snapshot) { _, _ in }
        snapshot.port = 9003
        writer.enqueue(snapshot) { _, _ in }
        release.signal()
        writer.flush()
        let disk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: directory.url))
        #expect(disk.port == 9003)
        #expect(try writer.changedData() == nil)
    }

    @Test func synchronousEditSupersedesQueuedOrderSnapshots() throws {
        let directory = try TempConfigDirectory(name: "sync-after-order")
        try JSONEncoder().encode(AppConfig()).write(to: directory.url)
        let writer = ConfigPersistence(url: directory.url)
        for port in 9001...9050 {
            var snapshot = AppConfig()
            snapshot.port = port
            writer.enqueue(snapshot) { _, _ in }
        }
        var edited = AppConfig()
        edited.port = 9999
        guard case .saved = writer.save(edited) else {
            Issue.record("Synchronous edit failed")
            return
        }
        writer.flush()
        let disk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: directory.url))
        #expect(disk.port == 9999)
    }

    @Test func externalEditIsNotOverwrittenByPendingOrder() throws {
        let directory = try TempConfigDirectory(name: "external-before-order")
        try JSONEncoder().encode(AppConfig()).write(to: directory.url)
        let writer = ConfigPersistence(url: directory.url)
        var external = AppConfig()
        external.port = 9999
        let data = try JSONEncoder().encode(external)
        try data.write(to: directory.url, options: .atomic)
        var snapshot = AppConfig()
        snapshot.port = 9001
        writer.enqueue(snapshot) { _, result in
            guard case .changedOnDisk = result else {
                Issue.record("Expected external edit to win")
                return
            }
        }
        writer.flush()
        #expect(try Data(contentsOf: directory.url) == data)
        #expect(try writer.changedData() == data)
        #expect(try writer.changedData() == nil)
    }

    @Test func writeFailureIsReportedWithoutClaimingPersistence() throws {
        let directory = try TempConfigDirectory(name: "order-failure")
        try JSONEncoder().encode(AppConfig()).write(to: directory.url)
        let writer = ConfigPersistence(url: directory.url, writeData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        writer.enqueue(AppConfig()) { _, result in
            guard case .failed = result else {
                Issue.record("Expected write failure")
                return
            }
        }
        writer.flush()
        #expect(try writer.changedData() == nil)
    }
}

@MainActor
@Suite("Background config ordering")
struct BackgroundConfigOrderingTests {
    @Test func repeatedProviderAndRouteMovesSurviveReloadAndLaterEdit() throws {
        let directory = try TempConfigDirectory(name: "store-background-order")
        let remotes = ["Alpha", "Beta", "Gamma"].map { provider in
            makeRemote(name: "\(provider) · model", model: "model", apiKey: "test-only",
                       baseURL: "https://example.test")
        }
        let routes = ["first", "second", "third"].map {
            FakeModel(id: UUID(), fakeModelID: $0, displayName: $0, remoteID: remotes[0].id)
        }
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: remotes, fakes: routes))
            .write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        store.moveProviders(sources: ["Alpha"], before: nil)
        store.moveProviders(sources: ["Beta"], before: nil)
        store.moveFakes(sources: [routes[0].id], before: nil)
        store.moveFakes(sources: [routes[1].id], before: nil)
        let expected = store.config
        store.flushPendingConfigWrites()
        let reloaded = ConfigStore(configURL: directory.url)
        #expect(reloaded.config == expected)
        store.moveProviders(sources: ["Gamma"], before: nil)
        #expect(store.updateFake(id: routes[0].id, fakeModelID: "edited", remoteID: remotes[0].id) == nil)
        store.flushPendingConfigWrites()
        #expect(ConfigStore(configURL: directory.url).config == store.config)
    }

    @Test func blockedOrderReportsVisibleSaveError() throws {
        let directory = try TempConfigDirectory(name: "blocked-order")
        let remotes = ["Alpha", "Beta"].map {
            makeRemote(name: "\($0) · model", model: "model", apiKey: "test-only",
                       baseURL: "https://example.test")
        }
        try JSONEncoder().encode(AppConfig(port: 8788, remotes: remotes, fakes: []))
            .write(to: directory.url)
        let store = ConfigStore(configURL: directory.url)
        try Data("invalid JSON".utf8).write(to: directory.url, options: .atomic)
        store.reloadFromDisk()
        store.moveProviders(sources: ["Alpha"], before: nil)
        #expect(store.configSaveError != nil)
        #expect(try String(contentsOf: directory.url) == "invalid JSON")
    }

    private func makeRemote(name: String, model: String, apiKey: String,
                            baseURL: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: name, apiKey: apiKey, model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: baseURL))
    }
}
