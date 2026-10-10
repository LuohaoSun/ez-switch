import Foundation
import Testing
@testable import EZSwitch

/// `UsageStore` 的失效通知：仅在成功写入/清除后发布，失败时不发布。
/// 通知本身不携带任何记录/凭证，只用 `object`（store）标识来源。
@Suite("Usage store change notifications")
struct UsageStoreNotificationTests {

    /// 线程安全的通知计数器；回调可能落在 store 的私有队列上。
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var notes: [Notification] = []
        func append(_ note: Notification) { lock.lock(); notes.append(note); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return notes.count }
        var firstObject: Any? { lock.lock(); defer { lock.unlock() }; return notes.first?.object }
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-notif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func record(_ timestamp: Date) -> UsageRecord {
        UsageRecord(requestID: UUID(), timestamp: timestamp, routeID: "route-1", routeName: "Route One",
                    remoteID: "remote-1", provider: "OpenAI", model: "gpt-4o", endpoint: "chat",
                    attempt: 1, status: 200, outcome: "success", durationMS: 10,
                    tokens: UsageTokens(input: 10, output: 5))
    }

    @Test
    func successfulRecordPostsNotification() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = NotificationCenter()
        let recorder = Recorder()
        let token = center.addObserver(forName: UsageStore.didChangeNotification, object: nil, queue: nil) {
            recorder.append($0)
        }
        defer { center.removeObserver(token) }

        let store = UsageStore(url: directory.appendingPathComponent("usage.sqlite"), notificationCenter: center)
        store.record(record(Date()))
        try await store.flush()

        #expect(recorder.count == 1)
        #expect(recorder.firstObject as? UsageStore === store)
    }

    @Test
    func clearPostsNotification() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = NotificationCenter()
        let recorder = Recorder()
        let token = center.addObserver(forName: UsageStore.didChangeNotification, object: nil, queue: nil) {
            recorder.append($0)
        }
        defer { center.removeObserver(token) }

        let store = UsageStore(url: directory.appendingPathComponent("usage.sqlite"), notificationCenter: center)
        store.record(record(Date()))
        try await store.flush()
        #expect(recorder.count == 1)   // record 通知

        try await store.clear()
        #expect(recorder.count == 2)   // clear 通知
    }

    @Test
    func failedOpenDoesNotPostNotification() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 用普通文件占住父路径，使目录无法创建 → 打开失败 → 不应通知。
        let blocker = directory.appendingPathComponent("blocker")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))

        let center = NotificationCenter()
        let recorder = Recorder()
        let token = center.addObserver(forName: UsageStore.didChangeNotification, object: nil, queue: nil) {
            recorder.append($0)
        }
        defer { center.removeObserver(token) }

        let store = UsageStore(url: blocker.appendingPathComponent("usage.sqlite"), notificationCenter: center)
        store.record(record(Date()))

        var threw = false
        do { try await store.flush() } catch { threw = true }
        #expect(threw)
        #expect(recorder.count == 0)
    }
}
