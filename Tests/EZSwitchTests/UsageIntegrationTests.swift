import Darwin
import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

/// Canned upstream used by the injected `Forwarder` session. File-private so it
/// never collides with other suites' helpers.
private final class UsageMockURLProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var chunks: [Data] = []
        /// Delay before *any* bytes (head included) are delivered.
        var headDelay: TimeInterval = 0
        var chunkDelay: TimeInterval = 0
        var finishDelay: TimeInterval = 0
    }

    private static let handlerLock = NSLock()
    private static var storedHandler: ((URLRequest) -> Reply)?
    static var handler: ((URLRequest) -> Reply)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return storedHandler }
        set { handlerLock.lock(); storedHandler = newValue; handlerLock.unlock() }
    }

    private let stateLock = NSLock()
    private var stopped = false
    private let sender = DispatchQueue(label: "UsageMockURLProtocol.sender")

    private var cancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = UsageMockURLProtocol.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = handler(request)
        sender.asyncAfter(deadline: .now() + reply.headDelay) { [weak self] in
            guard let self, !self.cancelled else { return }
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

private final class UsageRecordSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UsageRecord] = []
    func record(_ record: UsageRecord) {
        lock.lock(); storage.append(record); lock.unlock()
    }
    var records: [UsageRecord] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

/// Minimal raw TCP HTTP client. Closing the socket is a real FIN, so the proxy's
/// `channelInactive` fires deterministically (URLSession cancellation can be
/// deferred by connection pooling).
private final class RawSocketClient {
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

    /// Blocks until the received bytes contain `marker` — i.e. the proxy already
    /// forwarded (and ingested) that chunk — or the deadline passes.
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

    /// Reads until both markers have been seen (or the deadline passes), returning
    /// whether `first` appears **before** `second` in the received byte stream.
    /// Used to assert that pipelined responses come back in request order.
    func markersAppearInOrder(first: String, then second: String, timeout: TimeInterval) -> Bool {
        guard fd >= 0 else { return false }
        let firstData = Data(first.utf8)
        let secondData = Data(second.utf8)
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                received.append(contentsOf: chunk[0..<count])
                if let a = received.range(of: firstData), let b = received.range(of: secondData) {
                    return a.lowerBound < b.lowerBound
                }
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                continue
            } else {
                break
            }
        }
        return false
    }

    /// Reads (discarding) until the peer closes the socket (read == 0) or the
    /// deadline passes. Returns true iff EOF / a reset was observed.
    func readToEnd(timeout: TimeInterval) -> Bool {
        guard fd >= 0 else { return true }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 { continue }
            if count == 0 { return true }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            return true // ECONNRESET / EPIPE: connection is gone.
        }
        return false
    }

    deinit { closeSocket() }
}

@Suite("Usage integration", .serialized)
struct UsageIntegrationTests {
    private func remote(_ provider: String, _ model: String, baseURL: String,
                        transport: ResponsesTransport = .native) -> RemoteModel {
        var settings = APIEndpointSettings.all(baseURL: baseURL)
        settings.responsesTransport = transport
        return RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "test-key", model: model,
                           extraHeaders: [:], apiEndpoints: settings)
    }

    /// Session scoped to one test, carrying the mock URLProtocol. No global swap.
    private func mockSession(_ handler: @escaping (URLRequest) -> UsageMockURLProtocol.Reply) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UsageMockURLProtocol.self]
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 7200
        UsageMockURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    private func waitFor(_ spy: UsageRecordSpy, count: Int, timeout: TimeInterval = 5) async -> [UsageRecord] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let records = spy.records
            if records.count >= count { return records }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return spy.records
    }

    private func post(_ session: URLSession, port: Int, path: String, body: String) async throws -> HTTPURLResponse {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(body.utf8)
        let (_, response) = try await session.data(for: request)
        return try #require(response as? HTTPURLResponse)
    }

    /// Raw HTTP/1.1 request bytes for the socket client (byte-exact `Content-Length`).
    private func rawRequest(path: String, body: String, extraHeaders: String = "") -> String {
        "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(Data(body.utf8).count)\r\n\(extraHeaders)\r\n" + body
    }

    @Test func fallbackRecordsTwoAttemptsForOneRequest() async throws {
        let upstream = mockSession { request in
            let host = request.url?.host ?? ""
            if host == "fail.test" {
                return UsageMockURLProtocol.Reply(status: 503,
                    headers: ["Content-Type": "application/json"],
                    chunks: [Data(#"{"error":{"message":"busy"}}"#.utf8)])
            }
            return UsageMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "application/json"],
                chunks: [Data(#"{"id":"c","choices":[],"usage":{"prompt_tokens":13,"completion_tokens":6,"prompt_tokens_details":{"cached_tokens":2}}}"#.utf8)])
        }
        defer { UsageMockURLProtocol.handler = nil }

        let first = remote("FailCo", "model-a", baseURL: "https://fail.test/v1")
        let second = remote("GoodCo", "model-b", baseURL: "https://good.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: first.id, fallbackRemoteIDs: [second.id])
        let router = Router()
        router.update(AppConfig(port: 0, remotes: [first, second], fakes: [fake]))

        let spy = UsageRecordSpy()
        let server = RouterServer(router: router, recordUsage: { spy.record($0) }, session: upstream)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let session = URLSession(configuration: .ephemeral)
        let response = try await post(session, port: port, path: "/v1/chat/completions",
                                      body: #"{"model":"main","stream":false}"#)
        #expect(response.statusCode == 200)

        let records = await waitFor(spy, count: 2)
        #expect(records.count == 2)
        #expect(Set(records.map(\.requestID)).count == 1)
        #expect(records.map(\.attempt) == [1, 2])
        #expect(records[0].timestamp == records[1].timestamp)
        #expect(records[0].routeID == fake.id.uuidString)
        #expect(records[0].routeName == "main")
        #expect(records[0].provider == "FailCo")
        #expect(records[0].model == "model-a")
        #expect(records[0].outcome == "httpError")
        #expect(records[0].status == 503)
        #expect(records[0].tokens.input == nil)
        #expect(records[1].provider == "GoodCo")
        #expect(records[1].model == "model-b")
        #expect(records[1].outcome == "success")
        #expect(records[1].status == 200)
        #expect(records[1].tokens.input == 13)
        #expect(records[1].tokens.output == 6)
        #expect(records[1].tokens.cachedInput == 2)
    }

    @Test func singleSuccessRecordsExactlyOnce() async throws {
        let upstream = mockSession { _ in
            UsageMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "application/json"],
                chunks: [Data(#"{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2}}"#.utf8)])
        }
        defer { UsageMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo-model", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let router = Router()
        router.update(AppConfig(port: 0, remotes: [only], fakes: [fake]))

        let spy = UsageRecordSpy()
        let server = RouterServer(router: router, recordUsage: { spy.record($0) }, session: upstream)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let session = URLSession(configuration: .ephemeral)
        _ = try await post(session, port: port, path: "/v1/chat/completions",
                           body: #"{"model":"main","stream":false}"#)

        let records = await waitFor(spy, count: 1)
        #expect(records.count == 1)
        #expect(records[0].outcome == "success")
        #expect(records[0].tokens.input == 4)
        #expect(records[0].tokens.output == 2)
    }

    @Test func cancelledStreamRecordsPartialUsageOnce() async throws {
        let firstChunk = Data("data: {\"usage\":{\"prompt_tokens\":5}}\n\n".utf8)
        let secondChunk = Data("data: {\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":9}}\n\n".utf8)
        let upstream = mockSession { _ in
            UsageMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [firstChunk, secondChunk],
                chunkDelay: 1.0,
                finishDelay: 10)
        }
        defer { UsageMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo-model", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let router = Router()
        router.update(AppConfig(port: 0, remotes: [only], fakes: [fake]))

        let spy = UsageRecordSpy()
        let server = RouterServer(router: router, recordUsage: { spy.record($0) }, session: upstream)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        // Deterministic: read the first (usage-bearing) chunk, then close the TCP
        // socket so the proxy sees a real disconnect before the second chunk.
        let client = try #require(RawSocketClient(port: port))
        let body = #"{"model":"main","stream":true}"#
        let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(Data(body.utf8).count)\r\n\r\n" + body
        client.send(Data(request.utf8))
        #expect(client.readUntil("prompt_tokens", timeout: 5))
        client.closeSocket()

        let records = await waitFor(spy, count: 1, timeout: 8)
        let record = try #require(records.first, "expected the cancelled attempt to be recorded")
        #expect(records.count == 1)
        #expect(record.outcome == "cancelled")
        #expect(record.status == 200)
        #expect(record.tokens.input == 5)
        #expect(record.tokens.output == nil)
    }

    /// Raw-TCP regression: two pipelined requests on one socket must be processed
    /// serially. The first request's upstream is deliberately slow, so if the proxy
    /// answered concurrently the fast (second) response would overtake it. Guarded by
    /// disabling NIO's pipelining assistance + ProxyHandler's own serial queue.
    @Test func pipelinedRequestsAreSerializedAndOrdered() async throws {
        let upstream = mockSession { request in
            let isSlow = request.url?.host == "slow.test"
            return UsageMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [Data("data: {\"marker\":\"\(isSlow ? "slow" : "fast")\",\"usage\":{\"prompt_tokens\":1}}\n\n".utf8)],
                headDelay: isSlow ? 0.4 : 0,
                finishDelay: 0.1)
        }
        defer { UsageMockURLProtocol.handler = nil }

        let slow = remote("Slow", "slow-model", baseURL: "https://slow.test/v1")
        let fast = remote("Fast", "fast-model", baseURL: "https://fast.test/v1")
        let slowFake = FakeModel(id: UUID(), fakeModelID: "slow-fake", displayName: "slow-fake", remoteID: slow.id)
        let fastFake = FakeModel(id: UUID(), fakeModelID: "fast-fake", displayName: "fast-fake", remoteID: fast.id)
        let router = Router()
        router.update(AppConfig(port: 0, remotes: [slow, fast], fakes: [slowFake, fastFake]))

        let spy = UsageRecordSpy()
        let server = RouterServer(router: router, recordUsage: { spy.record($0) }, session: upstream)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = try #require(RawSocketClient(port: port))
        // Both requests are written in one segment => pipelined on the same connection.
        let first = rawRequest(path: "/v1/chat/completions", body: #"{"model":"slow-fake","stream":true}"#)
        let second = rawRequest(path: "/v1/chat/completions", body: #"{"model":"fast-fake","stream":true}"#)
        client.send(Data((first + second).utf8))

        #expect(client.markersAppearInOrder(first: "marker\":\"slow", then: "marker\":\"fast", timeout: 5),
                "second (fast) response overtook the first (slow) one — requests were not serialized")

        // Let both responses finish before closing, otherwise the FIN would cancel the
        // still-streaming second request and its record would be "cancelled".
        let records = await waitFor(spy, count: 2)
        client.closeSocket()

        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.outcome == "success" })
        #expect(records.map(\.provider) == ["Slow", "Fast"])
    }

    /// Raw-TCP regression: pipelining beyond the bounded backlog must stop accepting
    /// work and close the connection once the in-flight response is done, instead of
    /// buffering unboundedly. The single processed request still settles its usage.
    @Test func pipelinedBacklogOverflowClosesConnection() async throws {
        // Slow upstream keeps request #1 in flight while #2/#3 arrive pipelined.
        let upstream = mockSession { _ in
            UsageMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "application/json"],
                chunks: [Data(#"{"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3}}"#.utf8)],
                headDelay: 0.6,
                finishDelay: 0.2)
        }
        defer { UsageMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo-model", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let router = Router()
        router.update(AppConfig(port: 0, remotes: [only], fakes: [fake]))

        let spy = UsageRecordSpy()
        // Backlog limit = 2 outstanding requests: #1 in flight + #2 queued; #3 overflows.
        let server = RouterServer(router: router, recordUsage: { spy.record($0) }, session: upstream,
                                  maxPendingRequests: 2)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = try #require(RawSocketClient(port: port))
        let request = rawRequest(path: "/v1/chat/completions", body: #"{"model":"main","stream":false}"#)
        client.send(Data(Array(repeating: request, count: 3).joined().utf8))

        // Server must close the connection after finishing the in-flight response.
        #expect(client.readToEnd(timeout: 6), "expected the proxy to close the connection on backlog overflow")
        client.closeSocket()

        let records = await waitFor(spy, count: 1)
        #expect(records.count == 1, "only the in-flight request should be processed; queued/overflow ones are dropped")
        #expect(records[0].outcome == "success")
    }

    @Test(.enabled(if: BridgeTestExecutable.available, "Run ./build-translator.sh to enable bridge integration"))
    func translatedResponsesCapturesRawChatUsage() async throws {
        // Route the bundled bridge test binary to ResponseTranslator (env path wins).
        setenv("EZSWITCH_TRANSLATOR", BridgeTestExecutable.url.path, 1)
        defer { unsetenv("EZSWITCH_TRANSLATOR") }
        let chatSSE = """
        data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"real","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

        data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"real","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":3}}

        data: [DONE]

        """
        let upstream = mockSession { _ in
            UsageMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [Data(chatSSE.utf8)])
        }
        defer { UsageMockURLProtocol.handler = nil }

        let bridged = remote("Bridge", "real", baseURL: "https://bridge.test/v1", transport: .chatCompletions)
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: bridged.id)
        let router = Router()
        router.update(AppConfig(port: 0, remotes: [bridged], fakes: [fake]))

        let spy = UsageRecordSpy()
        let server = RouterServer(router: router, recordUsage: { spy.record($0) }, session: upstream)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let session = URLSession(configuration: .ephemeral)
        let response = try await post(session, port: port, path: "/v1/responses",
                                      body: #"{"model":"main","input":"Hi","stream":true}"#)
        #expect(response.statusCode == 200)

        let records = await waitFor(spy, count: 1)
        #expect(records.count == 1)
        #expect(records[0].outcome == "success")
        #expect(records[0].tokens.input == 9)
        #expect(records[0].tokens.output == 3)
    }

    // MARK: stream usage injection (no network)

    @Test func streamUsageInjectionIsConservativeAndPreservesKeys() throws {
        let added = try #require(JSONSerialization.jsonObject(
            with: Forwarder.enablingStreamUsage(Data(#"{"model":"m","stream":true}"#.utf8))) as? [String: Any])
        #expect((added["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)

        let explicitFalse = Data(#"{"model":"m","stream":true,"stream_options":{"include_usage":false,"foo":1}}"#.utf8)
        #expect(Forwarder.enablingStreamUsage(explicitFalse) == explicitFalse)

        let merged = try #require(JSONSerialization.jsonObject(
            with: Forwarder.enablingStreamUsage(Data(#"{"model":"m","stream":true,"stream_options":{"foo":1}}"#.utf8))) as? [String: Any])
        let options = try #require(merged["stream_options"] as? [String: Any])
        #expect(options["include_usage"] as? Bool == true)
        #expect(options["foo"] as? Int == 1)

        let nonStream = Data(#"{"model":"m"}"#.utf8)
        #expect(Forwarder.enablingStreamUsage(nonStream) == nonStream)
    }

    @Test func buildRequestAsksChatUpstreamForStreamUsage() throws {
        let model = remote("P", "real", baseURL: "https://x.test/v1")
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions")
        let request = try Forwarder.buildRequest(clientHead: head,
                                                 body: Data(#"{"model":"main","stream":true}"#.utf8),
                                                 endpoint: .chat, remote: model, query: "")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "real")
        #expect((object["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }
}
