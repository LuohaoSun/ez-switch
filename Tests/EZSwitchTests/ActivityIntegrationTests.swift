import Darwin
import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

/// Canned upstream for the injected `Forwarder` session. File-private so it never
/// collides with other suites' helpers.
private final class ActivityMockURLProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var chunks: [Data] = []
        var headDelay: TimeInterval = 0
        var chunkDelay: TimeInterval = 0
        var finishDelay: TimeInterval = 0
        var error: URLError?
    }

    private static let handlerLock = NSLock()
    private static var storedHandler: ((URLRequest) -> Reply)?
    static var handler: ((URLRequest) -> Reply)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return storedHandler }
        set { handlerLock.lock(); storedHandler = newValue; handlerLock.unlock() }
    }

    private let stateLock = NSLock()
    private var stopped = false
    private let sender = DispatchQueue(label: "ActivityMockURLProtocol.sender")

    private var cancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = ActivityMockURLProtocol.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = handler(request)
        sender.asyncAfter(deadline: .now() + reply.headDelay) { [weak self] in
            guard let self, !self.cancelled else { return }
            if let error = reply.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.send(reply, index: 0)
        }
    }

    private func send(_ reply: Reply, index: Int) {
        guard !cancelled else { return }
        if index >= reply.chunks.count {
            sender.asyncAfter(deadline: .now() + reply.finishDelay) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        let delay = index == 0 ? 0 : reply.chunkDelay
        sender.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.cancelled else { return }
            self.client?.urlProtocol(self, didLoad: reply.chunks[index])
            self.send(reply, index: index + 1)
        }
    }

    override func stopLoading() {
        stateLock.lock(); stopped = true; stateLock.unlock()
    }
}

/// Raw TCP client: closing the socket is a real FIN, so the proxy's `channelInactive`
/// fires deterministically (used for the client-cancel boundary).
private final class ActivitySocketClient {
    private var fd: Int32 = -1

    init?(port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { close(descriptor); return nil }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = descriptor
    }

    func send(_ data: Data) {
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    func readUntil(_ marker: String, timeout: TimeInterval) -> Bool {
        guard fd >= 0 else { return false }
        let needle = Data(marker.utf8)
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                received.append(contentsOf: chunk[0..<count])
                if received.range(of: needle) != nil { return true }
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                continue
            } else {
                return false
            }
        }
        return false
    }

    func closeSocket() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    deinit { closeSocket() }
}

/// End-to-end regression for the structured realtime activity feed.
///
/// Black-box by design: each test injects a **separate** `ActivityStore` (never
/// `.shared`), drives a real loopback `RouterServer` against a canned upstream, and
/// only reads the public `snapshot()` contract. Fake credentials only.
@Suite("Activity integration", .serialized)
struct ActivityIntegrationTests {
    private func remote(_ provider: String, _ model: String, baseURL: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "test-key", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: baseURL))
    }

    /// Provider name doubles as display label, so `splitProviderModel` yields provider == name.
    private func providerRemote(_ provider: String, _ model: String, baseURL: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: provider, apiKey: "test-key", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: baseURL))
    }

    /// Installs the reply closure as the (static) mock handler; never read the static
    /// handler from inside the closure (that would recurse).
    private func mockSession(_ handler: @escaping (URLRequest) -> ActivityMockURLProtocol.Reply) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ActivityMockURLProtocol.self]
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 7200
        ActivityMockURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    private func post(_ session: URLSession, port: Int, path: String, body: String) async throws -> HTTPURLResponse {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(body.utf8)
        let (_, response) = try await session.data(for: request)
        return try #require(response as? HTTPURLResponse)
    }

    private func chatDelta(_ text: String) -> Data {
        Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n".utf8)
    }

    private func usageDelta(_ input: Int, _ output: Int) -> Data {
        Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":\(input),\"completion_tokens\":\(output)}}\n\n".utf8)
    }

    /// Independent store + loopback server with fake credentials; never `.shared`.
    private func start(_ remotes: [RemoteModel], fakeModels: [FakeModel], store: ActivityStore,
                       session: URLSession) throws -> RouterServer {
        let config = AppConfig(port: 0, remotes: remotes, fakes: fakeModels)
        let router = Router()
        router.update(config)
        let server = RouterServer(router: router, recordUsage: nil,
                                  activityStore: store, session: session)
        try server.start(port: 0)
        return server
    }

    private func request(in store: ActivityStore, route: String) -> ActivityRequest? {
        store.snapshot().requests.first { $0.route == route }
    }

    /// Polls the live snapshot until `predicate` holds (or `timeout` elapses).
    @discardableResult
    private func poll(_ store: ActivityStore, timeout: TimeInterval = 10,
                      _ predicate: (ActivitySnapshot) -> Bool) async -> ActivitySnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = store.snapshot()
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return store.snapshot()
    }

    // MARK: Streaming lifecycle

    /// inFlight (waiting for head) → receiving (body bytes flowing) → succeeded + tokens.
    @Test func streamingRequestIsInFlightThenReceivingThenSucceededWithTokens() async throws {
        let sse = [
            Data("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n".utf8),
            chatDelta("Hi"),
            chatDelta(" there"),
            usageDelta(5, 3),
            Data("data: [DONE]\n\n".utf8),
        ]
        defer { ActivityMockURLProtocol.handler = nil }
        // headDelay keeps the inFlight window open; chunkDelay keeps `receiving` observable.
        let upstream = mockSession { _ in
            ActivityMockURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/event-stream"],
                                          chunks: sse, headDelay: 0.4, chunkDelay: 0.4, finishDelay: 0.2)
        }

        let only = remote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let store = ActivityStore()
        let server = try start([only], fakeModels: [fake], store: store, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        async let response = post(client, port: port, path: "/v1/chat/completions",
                                  body: #"{"model":"main","stream":true}"#)

        // Ordered, de-duplicated status transitions sampled live.
        var statuses: [ActivityStatus] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let req = request(in: store, route: "main") {
                if statuses.last != req.status { statuses.append(req.status) }
                if req.status == .succeeded { break }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let http = try await response
        #expect(http.statusCode == 200)

        #expect(statuses.contains(.inFlight), "must be observable as in-flight while waiting: \(statuses)")
        #expect(statuses.contains(.receiving), "must be observable as receiving while streaming: \(statuses)")

        let snapshot = await poll(store) { $0.activeCount == 0 && !$0.requests.isEmpty }
        #expect(snapshot.activeCount == 0)

        let req = try #require(request(in: store, route: "main"))
        #expect(req.status == .succeeded)
        #expect(req.endedAt != nil)
        #expect(req.outcome == "success")
        #expect(req.firstResponseAt != nil)
        #expect(req.endpoint == "chat")
        #expect(req.method == "POST")
        #expect(req.selectedAttempt == 1)
        #expect(req.attempts.count == 1)

        let attempt = try #require(req.attempts.first)
        #expect(attempt.outcome == .success)
        #expect(attempt.statusCode == 200)
        #expect(attempt.provider == "Solo")
        #expect(attempt.model == "solo")
        #expect(attempt.source == "api")
        #expect(attempt.label == "Solo · solo")
        #expect(attempt.endedAt != nil)
        #expect(attempt.durationMS != nil)

        // Token accounting rides on both the request and its winning attempt.
        #expect(req.tokens.input == 5)
        #expect(req.tokens.output == 3)
        #expect(attempt.tokens.input == 5)
        #expect(attempt.tokens.output == 3)
    }

    // MARK: Fallback

    /// One requestID, two attempts. The fallback must not finalize the request: it
    /// stays active while the second candidate runs, and tokens come from the winner.
    @Test func fallbackKeepsOneRequestAcrossTwoAttemptsAndDoesNotFinishEarly() async throws {
        defer { ActivityMockURLProtocol.handler = nil }
        // Branch on the real request host so the first candidate actually fails.
        let upstream = mockSession { request in
            if request.url?.host == "fail.test" {
                return ActivityMockURLProtocol.Reply(status: 503,
                    headers: ["Content-Type": "application/json"],
                    chunks: [Data(#"{"error":{"message":"busy"}}"#.utf8)])
            }
            return ActivityMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [chatDelta("Hi"), chatDelta(" there"), usageDelta(7, 2), Data("data: [DONE]\n\n".utf8)],
                chunkDelay: 1.0, finishDelay: 0.5)
        }

        let first = providerRemote("FailCo", "model-a", baseURL: "https://fail.test/v1")
        let second = providerRemote("GoodCo", "model-b", baseURL: "https://good.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: first.id, fallbackRemoteIDs: [second.id])
        let store = ActivityStore()
        let server = try start([first, second], fakeModels: [fake], store: store, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        async let response = post(client, port: port, path: "/v1/chat/completions",
                                  body: #"{"model":"main","stream":true}"#)

        var sawTwoAttemptsWhileActive = false
        var sawEarlyFinish = false
        var sawDuplicateEntry = false
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let snapshot = store.snapshot()
            if snapshot.requests.filter({ $0.route == "main" }).count > 1 { sawDuplicateEntry = true }
            if let req = request(in: store, route: "main") {
                if req.status == .succeeded { break }
                if req.attempts.count >= 2 {
                    if req.status == .inFlight || req.status == .receiving {
                        sawTwoAttemptsWhileActive = true
                    } else {
                        sawEarlyFinish = true
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let http = try await response
        #expect(http.statusCode == 200)

        let snapshot = await poll(store) { $0.activeCount == 0 && !$0.requests.isEmpty }
        #expect(snapshot.activeCount == 0)
        #expect(!sawDuplicateEntry, "both attempts must share one requestID entry")
        #expect(sawTwoAttemptsWhileActive, "request must stay active while the fallback candidate runs")
        #expect(!sawEarlyFinish, "fallback must not finalize the request before it really ends")

        let req = try #require(request(in: store, route: "main"))
        #expect(req.status == .succeeded)
        #expect(req.outcome == "success")
        #expect(req.selectedAttempt == 2)
        #expect(req.attempts.count == 2)
        #expect(req.fallbacks.count == 1)
        #expect(req.fallbacks.first?.reason == .httpStatus(503))
        #expect(req.fallbacks.first?.from == "FailCo · model-a")
        #expect(req.fallbacks.first?.to == "GoodCo · model-b")

        #expect(req.attempts[0].outcome == .httpError)
        #expect(req.attempts[0].statusCode == 503)
        #expect(req.attempts[0].endedAt != nil)
        #expect(req.attempts[0].tokens.input == nil)
        #expect(req.attempts[1].outcome == .success)
        #expect(req.attempts[1].provider == "GoodCo")
        // Request tokens are the winning attempt's, not the failed one's.
        #expect(req.tokens.input == 7)
        #expect(req.tokens.output == 2)
    }

    // MARK: Upstream failure

    /// Every candidate dies before a response head: the request must reach a terminal
    /// `failed` state instead of lingering forever in-flight.
    @Test func upstreamConnectionFailureFinalizesRequestAsFailed() async throws {
        defer { ActivityMockURLProtocol.handler = nil }
        let upstream = mockSession { _ in
            ActivityMockURLProtocol.Reply(error: URLError(.cannotConnectToHost))
        }

        let only = providerRemote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let store = ActivityStore()
        let server = try start([only], fakeModels: [fake], store: store, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        let http = try await post(client, port: port, path: "/v1/chat/completions",
                                  body: #"{"model":"main","stream":true}"#)
        #expect(http.statusCode == 502)

        let snapshot = await poll(store) { $0.activeCount == 0 && !$0.requests.isEmpty }
        #expect(snapshot.activeCount == 0)
        #expect(snapshot.requests.allSatisfy { $0.status != .inFlight && $0.status != .receiving })

        let req = try #require(request(in: store, route: "main"))
        #expect(req.status == .failed)
        #expect(req.endedAt != nil)
        #expect(req.failureReason != nil)
        #expect(req.attempts.count == 1)
        #expect(req.attempts[0].outcome == .networkError)
        #expect(req.attempts[0].endedAt != nil)
        #expect(req.tokens.input == nil)
        #expect(req.tokens.output == nil)
    }

    // MARK: Client cancel

    @Test func cancelledRequestLeavesNoActiveEntry() async throws {
        defer { ActivityMockURLProtocol.handler = nil }
        let upstream = mockSession { _ in
            ActivityMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [chatDelta("tok1") + chatDelta("tok2"), chatDelta("late")],
                chunkDelay: 10, finishDelay: 10)
        }

        let only = remote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let store = ActivityStore()
        let server = try start([only], fakeModels: [fake], store: store, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = try #require(ActivitySocketClient(port: port))
        let body = #"{"model":"main","stream":true}"#
        let raw = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(Data(body.utf8).count)\r\n\r\n" + body
        client.send(Data(raw.utf8))
        #expect(client.readUntil("tok2", timeout: 5)) // genuinely live before the client goes away
        client.closeSocket()

        let snapshot = await poll(store) { $0.activeCount == 0 && !$0.requests.isEmpty }
        #expect(snapshot.activeCount == 0, "a disconnected client must not leave an active entry")
        #expect(snapshot.requests.allSatisfy { $0.status != .inFlight && $0.status != .receiving })

        let req = try #require(request(in: store, route: "main"))
        #expect(req.status == .cancelled)
        #expect(req.endedAt != nil)
        #expect(req.attempts.count == 1)
        #expect(req.attempts[0].outcome == .cancelled)
        #expect(req.attempts[0].endedAt != nil)
    }

    // MARK: Early failure before any candidate

    /// 502 with no usable candidate and 404 for an unknown route both return before any
    /// upstream attempt; neither may leave a permanently in-flight entry.
    @Test func earlyFailureWithoutCandidateDoesNotStayActive() async throws {
        defer { ActivityMockURLProtocol.handler = nil }
        let upstream = mockSession { _ in
            ActivityMockURLProtocol.Reply(error: URLError(.cannotConnectToHost))
        }

        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: nil)
        let store = ActivityStore()
        let server = try start([], fakeModels: [fake], store: store, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        let unbound = try await post(client, port: port, path: "/v1/chat/completions",
                                     body: #"{"model":"main","stream":true}"#)
        #expect(unbound.statusCode == 502)
        #expect(store.snapshot().activeCount == 0)
        #expect(store.snapshot().requests.allSatisfy { $0.status != .inFlight && $0.status != .receiving })

        let unknown = try await post(client, port: port, path: "/v1/chat/completions",
                                     body: #"{"model":"nope","stream":true}"#)
        #expect(unknown.statusCode == 404)
        #expect(store.snapshot().activeCount == 0)
        #expect(store.snapshot().requests.allSatisfy { $0.status != .inFlight && $0.status != .receiving })

        // Early rejections are recorded as terminally failed with no upstream attempt.
        for route in ["main", "nope"] {
            if let req = request(in: store, route: route) {
                #expect(req.status == .failed)
                #expect(req.endedAt != nil)
                #expect(req.attempts.isEmpty)
            }
        }
    }
}
