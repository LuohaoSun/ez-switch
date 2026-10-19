import Foundation
import Testing
@testable import EZSwitch

/// `ActivityStore` 的数据层语义：在途/已完成分离与有界容量、在途不被误淘汰、回退不提前终结、
/// 早期失败不永久在途、恰好一次终结、单调时钟实测 elapsed、pending 尝试的兜底终结、
/// 只存短标签（空原因归一为 nil、超长裁剪），以及 reset 的测试隔离。
@Suite("Activity store")
struct ActivityStoreTests {

    // MARK: - 夹具

    /// 可推进的单调时钟，让 elapsed 断言确定。
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanos: UInt64

        init(startNanos: UInt64 = 0) { self.nanos = startNanos }

        func advance(ms: Int) {
            lock.lock()
            nanos += UInt64(ms) * 1_000_000
            lock.unlock()
        }

        func now() -> DispatchTime {
            lock.lock()
            defer { lock.unlock() }
            return DispatchTime(uptimeNanoseconds: nanos)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeStore(capacity: Int = ActivityStore.defaultCapacity,
                           clock: TestClock = TestClock(),
                           notificationCenter: NotificationCenter = NotificationCenter())
        -> ActivityStore {
        ActivityStore(capacity: capacity, clock: { clock.now() },
                      notificationCenter: notificationCenter)
    }

    private func requestStart(_ id: UUID, route: String = "gpt-fake",
                              startedAt: Date = Date()) -> ActivityRequestStart {
        ActivityRequestStart(requestID: id, route: route, routeName: route,
                             endpoint: "chat", method: "POST", startedAt: startedAt)
    }

    private func attemptStart(_ id: UUID, attempt: Int = 1,
                              remoteID: UUID = UUID()) -> ActivityAttemptStart {
        ActivityAttemptStart(requestID: id, attempt: attempt, remoteID: remoteID.uuidString,
                             provider: "openai", model: "gpt-4o", label: "openai · gpt-4o",
                             source: "api", endpoint: "chat", startedAt: Date())
    }

    private func request(_ snapshot: ActivitySnapshot, _ id: UUID) -> ActivityRequest? {
        snapshot.requests.first { $0.id == id }
    }

    // MARK: - 开始 / elapsed

    @Test func startBeginsAnInFlightRequest() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id))

        let snapshot = store.snapshot()
        #expect(snapshot.activeCount == 1)
        let entry = request(snapshot, id)
        #expect(entry?.status == .inFlight)
        #expect(entry?.route == "gpt-fake")
        #expect(entry?.attempts.isEmpty == true)
        #expect(entry?.endedAt == nil)
    }

    @Test func elapsedUsesMonotonicClockForInFlightRequests() {
        let id = UUID()
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.start(requestStart(id))

        clock.advance(ms: 1500)
        #expect(request(store.snapshot(), id)?.elapsedMS == 1500)

        // 再次推进按“现在”重算，不是缓存值。
        clock.advance(ms: 500)
        #expect(request(store.snapshot(), id)?.elapsedMS == 2000)
    }

    @Test func elapsedIsFrozenAtCompletion() {
        let id = UUID()
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.start(requestStart(id))
        clock.advance(ms: 1000)
        store.finish(requestID: id, status: .succeeded, outcome: "success", statusCode: 200,
                     reason: nil, selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())

        clock.advance(ms: 5000)
        #expect(request(store.snapshot(), id)?.elapsedMS == 1000)
    }

    // MARK: - 尝试

    @Test func startAndFinishAttemptRecordsOutcomeAndDuration() {
        let id = UUID()
        let remoteID = UUID()
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.start(requestStart(id))
        store.startAttempt(attemptStart(id, attempt: 1, remoteID: remoteID))
        #expect(request(store.snapshot(), id)?.attempts.first?.outcome == .pending)

        clock.advance(ms: 320)
        store.finishAttempt(requestID: id, attempt: 1, outcome: .httpError, statusCode: 429,
                            reason: "HTTP 429", tokens: UsageTokens(input: 12, output: 0),
                            performance: nil, at: Date())

        let attempt = request(store.snapshot(), id)?.attempts.first
        #expect(attempt?.remoteID == remoteID.uuidString)
        #expect(attempt?.outcome == .httpError)
        #expect(attempt?.statusCode == 429)
        #expect(attempt?.reason == "HTTP 429")
        #expect(attempt?.durationMS == 320)
    }

    @Test func finishAttemptOnlyFinalizesPendingAttempts() {
        let id = UUID()
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.start(requestStart(id))
        store.startAttempt(attemptStart(id, attempt: 1))
        clock.advance(ms: 100)
        store.finishAttempt(requestID: id, attempt: 1, outcome: .success, statusCode: 200,
                            reason: nil, tokens: UsageTokens(input: 1, output: 1),
                            performance: nil, at: Date())

        // 重复终结不得覆盖已测时长/结局/计数。
        clock.advance(ms: 900)
        store.finishAttempt(requestID: id, attempt: 1, outcome: .networkError, statusCode: nil,
                            reason: "overwrite", tokens: UsageTokens(), performance: nil, at: Date())

        let attempt = request(store.snapshot(), id)?.attempts.first
        #expect(attempt?.outcome == .success)
        #expect(attempt?.durationMS == 100)
        #expect(attempt?.statusCode == 200)
        #expect(attempt?.tokens == UsageTokens(input: 1, output: 1))
    }

    @Test func finishPendingAttemptsFinalizesLeftoverPendingAttempts() {
        let id = UUID()
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.start(requestStart(id))
        store.startAttempt(attemptStart(id, attempt: 1))
        clock.advance(ms: 250)
        store.finishPendingAttempts(requestID: id, outcome: .cancelled, at: Date())

        let attempt = request(store.snapshot(), id)?.attempts.first
        #expect(attempt?.outcome == .cancelled)
        #expect(attempt?.durationMS == 250)
    }

    // MARK: - 首个响应字节

    @Test func responseStartedMovesToReceivingOnce() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id))
        let first = Date()
        store.responseStarted(requestID: id, at: first)
        store.responseStarted(requestID: id, at: Date(timeIntervalSinceNow: 10))

        let entry = request(store.snapshot(), id)
        #expect(entry?.status == .receiving)
        #expect(entry?.firstResponseAt == first)
    }

    // MARK: - 回退

    @Test func fallbackKeepsRequestInFlight() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id))
        store.startAttempt(attemptStart(id, attempt: 1))
        store.finishAttempt(requestID: id, attempt: 1, outcome: .httpError, statusCode: 503,
                            reason: "HTTP 503", tokens: UsageTokens(), performance: nil, at: Date())
        store.fallback(requestID: id, from: "openai · gpt-4o", to: "anthropic · claude",
                       reason: .httpStatus(503), at: Date())

        let snapshot = store.snapshot()
        #expect(snapshot.activeCount == 1)
        let entry = request(snapshot, id)
        #expect(entry?.status == .inFlight)
        #expect(entry?.endedAt == nil)
        #expect(entry?.fallbacks.count == 1)
        #expect(entry?.fallbacks.first?.reason == ActivityFallbackReason.httpStatus(503))
        #expect(entry?.fallbacks.first?.to == "anthropic · claude")
    }

    // MARK: - 终结

    @Test func finishMovesRequestToCompletedList() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id))
        store.finish(requestID: id, status: .succeeded, outcome: "success", statusCode: 200,
                     reason: nil, selectedAttempt: 1,
                     tokens: UsageTokens(input: 10, output: 20), performance: nil, at: Date())

        let snapshot = store.snapshot()
        #expect(snapshot.activeCount == 0)
        let entry = request(snapshot, id)
        #expect(entry?.status == .succeeded)
        #expect(entry?.outcome == "success")
        #expect(entry?.selectedAttempt == 1)
        #expect(entry?.tokens == UsageTokens(input: 10, output: 20))
        #expect(entry?.endedAt != nil)
    }

    @Test func finishRejectsNonTerminalStatus() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id))
        store.finish(requestID: id, status: .receiving, outcome: nil, statusCode: nil,
                     reason: nil, selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())
        store.finish(requestID: id, status: .inFlight, outcome: nil, statusCode: nil,
                     reason: nil, selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())

        let snapshot = store.snapshot()
        #expect(snapshot.activeCount == 1)
        #expect(snapshot.requests.count == 1)
        #expect(request(snapshot, id)?.status == .inFlight)
    }

    @Test func duplicateFinishIsIgnored() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id))
        store.finish(requestID: id, status: .failed, outcome: "httpError", statusCode: 502,
                     reason: nil, selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())
        store.finish(requestID: id, status: .succeeded, outcome: "success", statusCode: 200,
                     reason: nil, selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())

        let snapshot = store.snapshot()
        #expect(snapshot.requests.count == 1)
        #expect(request(snapshot, id)?.status == .failed)
    }

    @Test func duplicateStartAfterCompletionIsIgnored() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id))
        store.finish(requestID: id, status: .succeeded, outcome: "success", statusCode: 200,
                     reason: nil, selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())
        store.start(requestStart(id))

        let snapshot = store.snapshot()
        #expect(snapshot.activeCount == 0)
        #expect(snapshot.requests.count == 1)
    }

    @Test func earlyFailureDoesNotRemainInFlight() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id, route: "unknown"))
        store.finish(requestID: id, status: .failed, outcome: "routerError", statusCode: 404,
                     reason: "unknown model", selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())

        let snapshot = store.snapshot()
        #expect(snapshot.activeCount == 0)
        #expect(request(snapshot, id)?.failureReason == "unknown model")
        #expect(request(snapshot, id)?.statusCode == 404)
    }

    // MARK: - 容量与在途隔离

    @Test func capacityEvictsOnlyCompletedAndNeverInFlight() {
        let store = makeStore(capacity: 2)
        let liveID = UUID()
        store.start(requestStart(liveID, route: "live"))

        for index in 0..<4 {
            let id = UUID()
            store.start(requestStart(id, route: "done-\(index)",
                                     startedAt: Date(timeIntervalSince1970: Double(index))))
            store.finish(requestID: id, status: .succeeded, outcome: "success", statusCode: 200,
                         reason: nil, selectedAttempt: nil, tokens: UsageTokens(),
                         performance: nil, at: Date())
        }

        let snapshot = store.snapshot()
        #expect(snapshot.activeCount == 1)
        #expect(snapshot.capacity == 2)
        #expect(snapshot.evictedCount == 2)
        // 在途请求永远保留，且排在已完成之前。
        #expect(snapshot.requests.first?.id == liveID)
        #expect(snapshot.requests.filter { $0.id != liveID }.count == 2)
        // 最近完成的两个保留（done-2、done-3）。
        let done = snapshot.requests.filter { $0.id != liveID }.map(\.route)
        #expect(Set(done) == Set(["done-2", "done-3"]))
    }

    // MARK: - 原因裁剪

    @Test func reasonIsTrimmedAndLengthBounded() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id))
        let long = String(repeating: "x", count: 900)
        store.finish(requestID: id, status: .failed, outcome: "httpError", statusCode: nil,
                     reason: "  \(long)  ", selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())

        let reason = request(store.snapshot(), id)?.failureReason
        #expect(reason?.count == 400)
    }

    @Test func blankReasonBecomesNil() {
        let id = UUID()
        let store = makeStore()
        store.start(requestStart(id))
        store.finish(requestID: id, status: .failed, outcome: "httpError", statusCode: nil,
                     reason: "   \n ", selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())
        #expect(request(store.snapshot(), id)?.failureReason == nil)
    }

    // MARK: - reset / 通知

    @Test func resetClearsEverything() {
        let store = makeStore(capacity: 1)
        let live = UUID()
        store.start(requestStart(live))
        let done = UUID()
        store.start(requestStart(done, route: "done"))
        store.finish(requestID: done, status: .succeeded, outcome: "success", statusCode: 200,
                     reason: nil, selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())
        let extra = UUID()
        store.start(requestStart(extra, route: "extra"))
        store.finish(requestID: extra, status: .succeeded, outcome: "success", statusCode: 200,
                     reason: nil, selectedAttempt: nil, tokens: UsageTokens(),
                     performance: nil, at: Date())

        store.reset()
        let snapshot = store.snapshot()
        #expect(snapshot.requests.isEmpty)
        #expect(snapshot.activeCount == 0)
        #expect(snapshot.evictedCount == 0)
    }

    @Test func changesPostInvalidationNotification() {
        let center = NotificationCenter()
        let store = makeStore(notificationCenter: center)
        let counter = Counter()
        let token = center.addObserver(forName: ActivityStore.didChangeNotification,
                                       object: store, queue: nil) { _ in counter.increment() }
        defer { center.removeObserver(token) }

        let id = UUID()
        store.start(requestStart(id))
        store.startAttempt(attemptStart(id, attempt: 1))
        store.responseStarted(requestID: id, at: Date())
        store.finish(requestID: id, status: .succeeded, outcome: "success", statusCode: 200,
                     reason: nil, selectedAttempt: 1, tokens: UsageTokens(),
                     performance: nil, at: Date())

        #expect(counter.read() >= 4)
    }

    // MARK: - 并发

    @Test func concurrentWritesRemainConsistent() {
        let store = makeStore(capacity: 300)
        let iterations = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let id = UUID()
            store.start(ActivityRequestStart(requestID: id, route: "route-\(index)",
                                             routeName: "route-\(index)", endpoint: "chat",
                                             method: "POST", startedAt: Date()))
            store.startAttempt(ActivityAttemptStart(requestID: id, attempt: 1,
                                                    remoteID: UUID().uuidString,
                                                    provider: "p", model: "m", label: "p · m",
                                                    source: "api", endpoint: "chat",
                                                    startedAt: Date()))
            store.finishAttempt(requestID: id, attempt: 1, outcome: .success, statusCode: 200,
                                reason: nil, tokens: UsageTokens(input: 1, output: 1),
                                performance: nil, at: Date())
            store.finish(requestID: id, status: .succeeded, outcome: "success", statusCode: 200,
                         reason: nil, selectedAttempt: 1, tokens: UsageTokens(input: 1, output: 1),
                         performance: nil, at: Date())
        }

        let snapshot = store.snapshot()
        #expect(snapshot.activeCount == 0)
        #expect(snapshot.requests.count == iterations)
        #expect(snapshot.evictedCount == 0)
    }
}
