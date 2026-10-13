import Darwin
import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

/// Canned upstream for the injected `Forwarder` session. File-private so it never
/// collides with other suites' helpers.
private final class PerfMockURLProtocol: URLProtocol {
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
    private let sender = DispatchQueue(label: "PerfMockURLProtocol.sender")

    private var cancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = PerfMockURLProtocol.handler, let url = request.url else {
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

private final class PerfRecordSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UsageRecord] = []
    func record(_ record: UsageRecord) {
        lock.lock(); storage.append(record); lock.unlock()
    }
    var records: [UsageRecord] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

/// Minimal raw TCP HTTP client: closing the socket is a real FIN, so the proxy's
/// `channelInactive` fires deterministically.
private final class PerfSocketClient {
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

@Suite("Performance integration", .serialized)
struct PerformanceIntegrationTests {
    private func remote(_ provider: String, _ model: String, baseURL: String,
                        transport: ResponsesTransport = .native) -> RemoteModel {
        var settings = APIEndpointSettings.all(baseURL: baseURL)
        settings.responsesTransport = transport
        return RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "test-key", model: model,
                           extraHeaders: [:], apiEndpoints: settings)
    }

    private func providerRemote(_ provider: String, _ model: String, baseURL: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: provider, apiKey: "test-key", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: baseURL))
    }

    private func mockSession(_ handler: @escaping (URLRequest) -> PerfMockURLProtocol.Reply) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PerfMockURLProtocol.self]
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 7200
        PerfMockURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    private func waitFor(_ spy: PerfRecordSpy, count: Int, timeout: TimeInterval = 5) async -> [UsageRecord] {
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

    private func chatDelta(_ text: String) -> Data {
        Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n".utf8)
    }

    private func start(_ remote: [RemoteModel], fakeModels: [FakeModel], spy: PerfRecordSpy,
                       session: URLSession) throws -> RouterServer {
        let router = Router()
        router.update(AppConfig(port: 0, remotes: remote, fakes: fakeModels))
        let server = RouterServer(router: router, recordUsage: { spy.record($0) }, session: session)
        try server.start(port: 0)
        return server
    }

    // MARK: Streaming success

    @Test func streamingChatSuccessRecordsTTFTAndGeneration() async throws {
        let sse = [
            Data("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n".utf8),
            chatDelta("Hi"),
            chatDelta(" there"),
            Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3}}\n\n".utf8),
            Data("data: [DONE]\n\n".utf8),
        ]
        let upstream = mockSession { _ in
            PerfMockURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: sse)
        }
        defer { PerfMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let spy = PerfRecordSpy()
        let server = try start([only], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        _ = try await post(client, port: port, path: "/v1/chat/completions",
                           body: #"{"model":"main","stream":true}"#)

        let records = await waitFor(spy, count: 1)
        let record = try #require(records.first)
        #expect(record.outcome == "success")
        let perf = try #require(record.performance)
        #expect(perf.streaming)
        #expect(perf.outputDeltaCount == 2) // role-only + usage-only excluded
        #expect(perf.ttftMS != nil)
        #expect(perf.requestTTFTMS != nil)
        #expect(perf.generationMS != nil)
        #expect(perf.requestTTFTMS! >= perf.ttftMS! - 0.001)
        #expect(perf.tps(outputTokens: 3) != nil)
    }

    @Test func nonStreamingSuccessRecordsNonStreamingPerformance() async throws {
        let upstream = mockSession { _ in
            PerfMockURLProtocol.Reply(status: 200, headers: ["Content-Type": "application/json"],
                chunks: [Data(#"{"choices":[{"message":{"content":"Hi"}}],"usage":{"prompt_tokens":4,"completion_tokens":2}}"#.utf8)])
        }
        defer { PerfMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let spy = PerfRecordSpy()
        let server = try start([only], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        _ = try await post(client, port: port, path: "/v1/chat/completions",
                           body: #"{"model":"main","stream":false}"#)

        let records = await waitFor(spy, count: 1)
        let perf = try #require(records.first?.performance)
        #expect(!perf.streaming)
        #expect(perf.outputDeltaCount == 0)
        #expect(perf.ttftMS == nil)
        #expect(perf.generationMS == nil)
        #expect(perf.tps(outputTokens: 100) == nil)
    }

    // MARK: Fallback

    /// Second attempt starts its own TTFT clock, but the request-level TTFT still
    /// includes the time spent waiting on the first (503) attempt.
    @Test func fallbackKeepsPerAttemptTTFTButRequestTTFTIncludesFirstWait() async throws {
        let upstream = mockSession { request in
            if request.url?.host == "fail.test" {
                return PerfMockURLProtocol.Reply(status: 503,
                    headers: ["Content-Type": "application/json"],
                    chunks: [Data(#"{"error":{"message":"busy"}}"#.utf8)],
                    headDelay: 0.3)
            }
            return PerfMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [chatDelta("Hi"), chatDelta(" there")])
        }
        defer { PerfMockURLProtocol.handler = nil }

        let first = providerRemote("FailCo", "model-a", baseURL: "https://fail.test/v1")
        let second = providerRemote("GoodCo", "model-b", baseURL: "https://good.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: first.id, fallbackRemoteIDs: [second.id])
        let spy = PerfRecordSpy()
        let server = try start([first, second], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        _ = try await post(client, port: port, path: "/v1/chat/completions",
                           body: #"{"model":"main","stream":true}"#)

        let records = await waitFor(spy, count: 2)
        #expect(records.map(\.outcome) == ["httpError", "success"])

        let failed = try #require(records[0].performance)
        #expect(!failed.streaming) // 503 JSON error body, not SSE
        #expect(failed.ttftMS == nil)

        let succeeded = try #require(records[1].performance)
        #expect(succeeded.streaming)
        #expect(succeeded.outputDeltaCount == 2)
        #expect(succeeded.ttftMS != nil)
        #expect(succeeded.requestTTFTMS != nil)
        // The first attempt's ~0.3s wait is inside requestTTFT but not inside the
        // second attempt's own TTFT.
        #expect(succeeded.requestTTFTMS! >= succeeded.ttftMS! + 100)
    }

    // MARK: Header/heartbeat

    @Test func heartbeatBeforeFirstDeltaDoesNotStartTTFT() async throws {
        let upstream = mockSession { _ in
            PerfMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [Data(": keep-alive\n\n".utf8), chatDelta("Hi"), chatDelta("!")],
                chunkDelay: 0.3)
        }
        defer { PerfMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let spy = PerfRecordSpy()
        let server = try start([only], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        _ = try await post(client, port: port, path: "/v1/chat/completions",
                           body: #"{"model":"main","stream":true}"#)

        let perf = try #require(await waitFor(spy, count: 1).first?.performance)
        #expect(perf.outputDeltaCount == 2) // heartbeat is not a delta
        // TTFT reflects the delayed first delta, not the immediate heartbeat.
        #expect(perf.ttftMS! >= 200)
    }

    // MARK: First output delayed

    @Test func delayedFirstOutputShowsInTTFT() async throws {
        let upstream = mockSession { _ in
            PerfMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [chatDelta("Hi"), chatDelta("!")],
                headDelay: 0.3)
        }
        defer { PerfMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let spy = PerfRecordSpy()
        let server = try start([only], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        _ = try await post(client, port: port, path: "/v1/chat/completions",
                           body: #"{"model":"main","stream":true}"#)

        let perf = try #require(await waitFor(spy, count: 1).first?.performance)
        #expect(perf.ttftMS! >= 200)
        #expect(perf.requestTTFTMS! >= perf.ttftMS! - 0.001)
        #expect(perf.generationMS != nil)
    }

    // MARK: Cancel

    @Test func cancelledStreamRecordsPartialPerformanceWithoutGeneration() async throws {
        let upstream = mockSession { _ in
            PerfMockURLProtocol.Reply(status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [chatDelta("tok1") + chatDelta("tok2"), chatDelta("late")],
                chunkDelay: 10,
                finishDelay: 10)
        }
        defer { PerfMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let spy = PerfRecordSpy()
        let server = try start([only], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = try #require(PerfSocketClient(port: port))
        let body = #"{"model":"main","stream":true}"#
        let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(Data(body.utf8).count)\r\n\r\n" + body
        client.send(Data(request.utf8))
        #expect(client.readUntil("tok2", timeout: 5))
        client.closeSocket()

        let records = await waitFor(spy, count: 1, timeout: 8)
        let record = try #require(records.first)
        #expect(record.outcome == "cancelled")
        let perf = try #require(record.performance)
        #expect(perf.streaming)
        #expect(perf.outputDeltaCount == 2)
        #expect(perf.ttftMS != nil)
        #expect(perf.generationMS == nil) // body never ended normally
        #expect(perf.tps(outputTokens: 2) == nil)
    }

    // MARK: Other protocols

    @Test func responsesNativeStreamingCountsOutputTextDeltas() async throws {
        let sse = [
            Data("data: {\"type\":\"response.created\"}\n\n".utf8),
            Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n".utf8),
            Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\" there\"}\n\n".utf8),
            Data("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}}\n\n".utf8),
        ]
        let upstream = mockSession { _ in
            PerfMockURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: sse)
        }
        defer { PerfMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let spy = PerfRecordSpy()
        let server = try start([only], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        _ = try await post(client, port: port, path: "/v1/responses",
                           body: #"{"model":"main","input":"Hi","stream":true}"#)

        let perf = try #require(await waitFor(spy, count: 1).first?.performance)
        #expect(perf.streaming)
        #expect(perf.outputDeltaCount == 2)
        #expect(perf.ttftMS != nil)
        #expect(perf.generationMS != nil)
    }

    @Test func anthropicMessagesStreamingCountsTextDeltas() async throws {
        let sse = [
            Data("data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3}}}\n\n".utf8),
            Data("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n".utf8),
            Data("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" there\"}}\n\n".utf8),
            Data("data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":2}}\n\n".utf8),
        ]
        let upstream = mockSession { _ in
            PerfMockURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: sse)
        }
        defer { PerfMockURLProtocol.handler = nil }

        let only = remote("Solo", "solo", baseURL: "https://solo.test")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let spy = PerfRecordSpy()
        let server = try start([only], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        _ = try await post(client, port: port, path: "/v1/messages",
                           body: #"{"model":"main","stream":true}"#)

        let perf = try #require(await waitFor(spy, count: 1).first?.performance)
        #expect(perf.streaming)
        #expect(perf.outputDeltaCount == 2)
        #expect(perf.ttftMS != nil)
    }

    // MARK: Responses→Chat bridge

    /// The bridge rewrites a Chat upstream into a Responses stream. Performance
    /// must be measured on the *raw Chat* deltas before translation, exactly like
    /// the raw usage collector.
    @Test(.enabled(if: BridgeTestExecutable.available, "Run ./Scripts/build-translator.sh to enable bridge integration"))
    func bridgePreservesRawChatPerformance() async throws {
        setenv("EZSWITCH_TRANSLATOR", BridgeTestExecutable.url.path, 1)
        defer { unsetenv("EZSWITCH_TRANSLATOR") }
        let chatSSE = """
        data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"real","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

        data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"real","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

        data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"real","choices":[{"index":0,"delta":{"content":" there"},"finish_reason":null}]}

        data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"real","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":3}}

        data: [DONE]

        """
        let upstream = mockSession { _ in
            PerfMockURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/event-stream"],
                                      chunks: [Data(chatSSE.utf8)])
        }
        defer { PerfMockURLProtocol.handler = nil }

        let bridged = remote("Bridge", "real", baseURL: "https://bridge.test/v1", transport: .chatCompletions)
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: bridged.id)
        let spy = PerfRecordSpy()
        let server = try start([bridged], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        let response = try await post(client, port: port, path: "/v1/responses",
                                      body: #"{"model":"main","input":"Hi","stream":true}"#)
        #expect(response.statusCode == 200)

        let record = try #require(await waitFor(spy, count: 1).first)
        #expect(record.outcome == "success")
        #expect(record.tokens.input == 9) // raw Chat usage still captured
        let perf = try #require(record.performance)
        #expect(perf.streaming)
        #expect(perf.outputDeltaCount == 2) // raw Chat content deltas, not translated output
        #expect(perf.ttftMS != nil)
        #expect(perf.generationMS != nil)
    }

    // MARK: Network failure

    @Test func networkFailureRecordsNilPerformance() async throws {
        let upstream = mockSession { _ in
            PerfMockURLProtocol.Reply(error: URLError(.cannotConnectToHost))
        }
        defer { PerfMockURLProtocol.handler = nil }

        let only = providerRemote("Solo", "solo", baseURL: "https://solo.test/v1")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: only.id)
        let spy = PerfRecordSpy()
        let server = try start([only], fakeModels: [fake], spy: spy, session: upstream)
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let client = URLSession(configuration: .ephemeral)
        let response = try await post(client, port: port, path: "/v1/chat/completions",
                                      body: #"{"model":"main","stream":true}"#)
        #expect(response.statusCode == 502)

        let record = try #require(await waitFor(spy, count: 1).first)
        #expect(record.outcome == "networkError")
        #expect(record.performance == nil)
    }
}
