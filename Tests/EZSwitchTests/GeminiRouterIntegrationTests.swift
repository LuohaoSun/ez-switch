import Dispatch
import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

/// Canned Gemini upstream. File-private so it never collides with other suites.
private final class GeminiMockURLProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var chunks: [Data] = []
        /// Fail the load before any response head (simulates a connection failure).
        var error: URLError?
    }

    private static let handlerLock = NSLock()
    private static var storedHandler: ((URLRequest) -> Reply)?
    static var handler: ((URLRequest) -> Reply)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return storedHandler }
        set { handlerLock.lock(); storedHandler = newValue; handlerLock.unlock() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = GeminiMockURLProtocol.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = handler(request)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RequestSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    func store(_ request: URLRequest) { lock.lock(); storage.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class UsageSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UsageRecord] = []
    func record(_ record: UsageRecord) { lock.lock(); storage.append(record); lock.unlock() }
    var records: [UsageRecord] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class FallbackSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AutoFallbackEvent] = []
    func record(_ event: AutoFallbackEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [AutoFallbackEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func uptimeDeadline(_ timeout: TimeInterval) -> DispatchTime {
    DispatchTime.now() + .milliseconds(Int((timeout * 1000).rounded()))
}

private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer[0..<count])
    }
    return data
}

@Suite("Gemini router integration", .serialized)
struct GeminiRouterIntegrationTests {
    private let clientKey = "CLIENT_SECRET_KEY"

    private func geminiRemote(_ model: String, baseURL: String, apiKey: String = "supplier-key") -> RemoteModel {
        RemoteModel(id: UUID(), name: "GeminiCo · \(model)", apiKey: apiKey, model: model,
                    extraHeaders: [:], apiEndpoints: .enabled([.gemini], baseURL: baseURL))
    }

    private func mockSession(_ handler: @escaping (URLRequest) -> GeminiMockURLProtocol.Reply) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiMockURLProtocol.self]
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 7200
        GeminiMockURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    /// Starts a router with the given remotes/fakes and returns (server, port).
    private func startRouter(remotes: [RemoteModel], fakes: [FakeModel], upstream: URLSession,
                             usage: UsageSpy? = nil, events: FallbackSpy? = nil)
        async throws -> (RouterServer, Int, Router) {
        let router = Router()
        router.update(AppConfig(port: 0, remotes: remotes, fakes: fakes))
        let recorder: UsageRecorder? = usage.map { spy in
            { @Sendable (record: UsageRecord) in spy.record(record) }
        }
        let notifier: (@Sendable (AutoFallbackEvent) -> Void)? = events.map { spy in
            { @Sendable (event: AutoFallbackEvent) in spy.record(event) }
        }
        let server = RouterServer(router: router, recordUsage: recorder, session: upstream,
                                  onAutoFallback: notifier)
        try server.start(port: 0)
        let port = try #require(server.boundPort)
        return (server, port, router)
    }

    private func send(port: Int, path: String, method: String = "POST",
                      body: String? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = Data(body.utf8) }
        let (data, response) = try await session.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    private func waitFor(_ spy: UsageSpy, count: Int, timeout: TimeInterval = 5) async -> [UsageRecord] {
        let deadline = uptimeDeadline(timeout)
        while DispatchTime.now() < deadline {
            if spy.records.count >= count { return spy.records }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return spy.records
    }

    // MARK: generateContent

    @Test func generateContentSubstitutesPathModelStripsKeyAndPreservesBodyBytes() async throws {
        let captured = RequestSpy()
        let upstream = mockSession { request in
            captured.store(request)
            return GeminiMockURLProtocol.Reply(chunks: [Data(#"{"candidates":[]}"#.utf8)])
        }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        let (server, port, _) = try await startRouter(remotes: [remote], fakes: [fake], upstream: upstream)
        defer { server.stop() }

        let body = #"{"contents":[{"parts":[{"text":"hi"}]}],"unknownField":{"keep":1},"generationConfig":{"temperature":0.5}}"#
        let (_, response) = try await send(port: port,
            path: "/v1beta/models/main:generateContent?key=\(clientKey)&alt=sse",
            body: body,
            headers: ["content-type": "application/json", "x-goog-api-key": clientKey])
        #expect(response.statusCode == 200)

        let seen = try #require(captured.requests.first)
        #expect(seen.url?.absoluteString == "https://gemini.test/v1beta/models/gemini-real:generateContent?alt=sse")
        #expect(seen.url?.absoluteString.contains(clientKey) == false)
        #expect(seen.value(forHTTPHeaderField: "x-goog-api-key") == "supplier-key")
        // 原生生成 body 逐字节透传（未知字段不被 strip / 重排）。
        #expect(requestBody(seen) == Data(body.utf8))
    }

    @Test func streamGenerateContentKeepsNativeJsonArrayWhenAltUnspecified() async throws {
        let array = Data("[{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a\"}]}}]},{\"candidates\":[]}]".utf8)
        let upstream = mockSession { _ in
            GeminiMockURLProtocol.Reply(headers: ["Content-Type": "application/json"], chunks: [array])
        }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        let (server, port, _) = try await startRouter(remotes: [remote], fakes: [fake], upstream: upstream)
        defer { server.stop() }

        let (data, response) = try await send(port: port,
            path: "/v1beta/models/main:streamGenerateContent?key=\(clientKey)",
            body: #"{"contents":[]}"#,
            headers: ["content-type": "application/json"])
        #expect(response.statusCode == 200)
        // alt 未指定 → 不强制 SSE，原生 application/json 数组原样返回。
        #expect(response.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(data == array)
    }

    @Test func streamGenerateContentPassesThroughSSEWithAlt() async throws {
        let sse = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a\"}]}}]}\n\n".utf8)
        let upstream = mockSession { _ in
            GeminiMockURLProtocol.Reply(headers: ["Content-Type": "text/event-stream"], chunks: [sse])
        }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        let (server, port, _) = try await startRouter(remotes: [remote], fakes: [fake], upstream: upstream)
        defer { server.stop() }

        let (data, response) = try await send(port: port,
            path: "/v1beta/models/main:streamGenerateContent?key=\(clientKey)&alt=sse",
            body: #"{"contents":[]}"#,
            headers: ["content-type": "application/json"])
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "content-type") == "text/event-stream")
        #expect(data == sse)
    }

    // MARK: local models (path-based, not header-based)

    @Test func localModelListAndGetAreGeminiFormatFilteringCompatibleRoutes() async throws {
        let upstream = mockSession { _ in GeminiMockURLProtocol.Reply(chunks: []) }
        defer { GeminiMockURLProtocol.handler = nil }

        let gemini = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let chat = RemoteModel(id: UUID(), name: "OpenAI · gpt", apiKey: "k", model: "gpt",
                               extraHeaders: [:], apiEndpoints: .enabled([.chat], baseURL: "https://openai.test/v1"))
        let geminiFake = FakeModel(id: UUID(), fakeModelID: "g-fake", displayName: "g-fake", remoteID: gemini.id)
        let chatFake = FakeModel(id: UUID(), fakeModelID: "c-fake", displayName: "c-fake", remoteID: chat.id)
        let (server, port, _) = try await startRouter(remotes: [gemini, chat],
                                                      fakes: [geminiFake, chatFake], upstream: upstream)
        defer { server.stop() }

        let (listData, listResponse) = try await send(port: port, path: "/v1beta/models", method: "GET")
        #expect(listResponse.statusCode == 200)
        let listObject = try #require(try JSONSerialization.jsonObject(with: listData) as? [String: Any])
        let models = try #require(listObject["models"] as? [[String: Any]])
        #expect(models.compactMap { $0["name"] as? String } == ["models/g-fake"])
        #expect(models.first?["inputTokenLimit"] == nil)
        #expect(models.first?["outputTokenLimit"] == nil)

        let (getData, getResponse) = try await send(port: port, path: "/v1beta/models/g-fake", method: "GET")
        #expect(getResponse.statusCode == 200)
        #expect((try JSONSerialization.jsonObject(with: getData) as? [String: Any])?["name"] as? String
                == "models/g-fake")

        let (missingData, missing) = try await send(port: port, path: "/v1beta/models/c-fake", method: "GET")
        #expect(missing.statusCode == 404)
        let missingError = try #require((try JSONSerialization.jsonObject(with: missingData) as? [String: Any])?["error"] as? [String: Any])
        #expect(missingError["code"] as? Int == 404)
        #expect(missingError["status"] as? String == "NOT_FOUND")
    }

    @Test func openAIModelListStaysUnchanged() async throws {
        let upstream = mockSession { _ in GeminiMockURLProtocol.Reply(chunks: []) }
        defer { GeminiMockURLProtocol.handler = nil }

        let chat = RemoteModel(id: UUID(), name: "OpenAI · gpt", apiKey: "k", model: "gpt",
                               extraHeaders: [:], apiEndpoints: .enabled([.chat], baseURL: "https://openai.test/v1"))
        let fake = FakeModel(id: UUID(), fakeModelID: "c-fake", displayName: "c-fake", remoteID: chat.id)
        let (server, port, _) = try await startRouter(remotes: [chat], fakes: [fake], upstream: upstream)
        defer { server.stop() }

        let (data, response) = try await send(port: port, path: "/v1/models", method: "GET")
        #expect(response.statusCode == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["object"] as? String == "list")
        #expect(object["models"] == nil)
    }

    // MARK: local errors

    @Test func unknownRouteReturnsGeminiFormat404() async throws {
        let upstream = mockSession { _ in GeminiMockURLProtocol.Reply(chunks: []) }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        let (server, port, _) = try await startRouter(remotes: [remote], fakes: [fake], upstream: upstream)
        defer { server.stop() }

        let (data, response) = try await send(port: port,
            path: "/v1beta/models/ghost:generateContent?key=\(clientKey)", body: #"{"contents":[]}"#)
        #expect(response.statusCode == 404)
        let error = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])
        #expect(error["code"] as? Int == 404)
        #expect(error["status"] as? String == "NOT_FOUND")
        #expect((error["message"] as? String)?.contains(clientKey) == false)
    }

    @Test func malformedGeminiPathReturnsGeminiFormat404() async throws {
        let upstream = mockSession { _ in GeminiMockURLProtocol.Reply(chunks: []) }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        let (server, port, _) = try await startRouter(remotes: [remote], fakes: [fake], upstream: upstream)
        defer { server.stop() }

        for path in ["/v1beta/models/main:bogusOperation", "/v1beta/models/%2F:generateContent"] {
            let (data, response) = try await send(port: port, path: path, body: #"{"contents":[]}"#)
            #expect(response.statusCode == 404)
            let error = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any],
                                     "expected a Gemini-shaped error for \(path)")
            #expect(error["status"] as? String == "NOT_FOUND")
        }
    }

    // MARK: countTokens exclusion

    @Test func countTokensRewritesNestedModelAndHasNoAccountingOrPromotion() async throws {
        let captured = RequestSpy()
        let upstream = mockSession { request in
            captured.store(request)
            return GeminiMockURLProtocol.Reply(chunks: [Data(#"{"totalTokens":7}"#.utf8)])
        }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        let usage = UsageSpy()
        let events = FallbackSpy()
        let (server, port, router) = try await startRouter(remotes: [remote], fakes: [fake], upstream: upstream,
                                                          usage: usage, events: events)
        defer { server.stop() }

        let (data, response) = try await send(port: port,
            path: "/v1beta/models/main:countTokens?key=\(clientKey)",
            body: #"{"generateContentRequest":{"model":"models/main","contents":[]}}"#,
            headers: ["content-type": "application/json"])
        #expect(response.statusCode == 200)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["totalTokens"] as? Int == 7)

        let seen = try #require(captured.requests.first)
        #expect(seen.url?.absoluteString == "https://gemini.test/v1beta/models/gemini-real:countTokens")
        let nested = (try JSONSerialization.jsonObject(with: requestBody(seen)) as? [String: Any])
            .flatMap { $0["generateContentRequest"] as? [String: Any] }?["model"] as? String
        #expect(nested == "models/gemini-real")

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(usage.records.isEmpty)                 // 零记账
        #expect(events.events.isEmpty)                 // 零通知
        #expect(router.activeRemoteID(fakeID: fake.id) == remote.id) // 首选不变
    }

    @Test func countTokensFallsBackAcrossGeminiCandidatesWithoutState() async throws {
        let hosts = RequestSpy()
        let upstream = mockSession { request in
            hosts.store(request)
            if request.url?.host == "fail.test" {
                return GeminiMockURLProtocol.Reply(status: 429, chunks: [Data(#"{"error":"busy"}"#.utf8)])
            }
            return GeminiMockURLProtocol.Reply(chunks: [Data(#"{"totalTokens":3}"#.utf8)])
        }
        defer { GeminiMockURLProtocol.handler = nil }

        let first = geminiRemote("gemini-a", baseURL: "https://fail.test/v1beta")
        let second = geminiRemote("gemini-b", baseURL: "https://good.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: first.id, fallbackRemoteIDs: [second.id])
        let usage = UsageSpy()
        let events = FallbackSpy()
        let (server, port, router) = try await startRouter(remotes: [first, second], fakes: [fake],
                                                          upstream: upstream, usage: usage, events: events)
        defer { server.stop() }

        let (_, response) = try await send(port: port,
            path: "/v1beta/models/main:countTokens?key=\(clientKey)",
            body: #"{"contents":[]}"#, headers: ["content-type": "application/json"])
        #expect(response.statusCode == 200)
        #expect(hosts.requests.compactMap { $0.url?.host } == ["fail.test", "good.test"])

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(usage.records.isEmpty)
        #expect(events.events.isEmpty)
        #expect(router.activeRemoteID(fakeID: fake.id) == first.id) // 不提升、不冷却
    }

    @Test func countTokensFailureRecordsNothing() async throws {
        let upstream = mockSession { _ in GeminiMockURLProtocol.Reply(error: URLError(.cannotConnectToHost)) }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://fail.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        let usage = UsageSpy()
        let events = FallbackSpy()
        let (server, port, router) = try await startRouter(remotes: [remote], fakes: [fake], upstream: upstream,
                                                          usage: usage, events: events)
        defer { server.stop() }

        let (data, response) = try await send(port: port,
            path: "/v1beta/models/main:countTokens?key=\(clientKey)",
            body: #"{"contents":[]}"#, headers: ["content-type": "application/json"])
        #expect(response.statusCode == 502)
        let error = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])
        #expect(error["status"] as? String == "UNAVAILABLE")

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(usage.records.isEmpty)
        #expect(events.events.isEmpty)
        #expect(router.activeRemoteID(fakeID: fake.id) == remote.id)
    }

    // MARK: generation fallback on compatible Gemini remotes

    @Test func generationFallsBackAcrossGeminiRemotesWithRecordsAndEvent() async throws {
        let upstream = mockSession { request in
            if request.url?.host == "fail.test" {
                return GeminiMockURLProtocol.Reply(status: 503, chunks: [Data(#"{"error":"busy"}"#.utf8)])
            }
            return GeminiMockURLProtocol.Reply(chunks: [Data(#"{"candidates":[]}"#.utf8)])
        }
        defer { GeminiMockURLProtocol.handler = nil }

        let first = geminiRemote("gemini-a", baseURL: "https://fail.test/v1beta")
        let second = geminiRemote("gemini-b", baseURL: "https://good.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: first.id, fallbackRemoteIDs: [second.id])
        let usage = UsageSpy()
        let events = FallbackSpy()
        let (server, port, _) = try await startRouter(remotes: [first, second], fakes: [fake],
                                                      upstream: upstream, usage: usage, events: events)
        defer { server.stop() }

        let (_, response) = try await send(port: port,
            path: "/v1beta/models/main:generateContent?key=\(clientKey)",
            body: #"{"contents":[]}"#, headers: ["content-type": "application/json"])
        #expect(response.statusCode == 200)

        let records = await waitFor(usage, count: 2)
        #expect(records.count == 2)
        #expect(Set(records.map(\.requestID)).count == 1)
        #expect(records.map(\.outcome) == ["httpError", "success"])
        #expect(records.allSatisfy { $0.endpoint == "gemini" })
        #expect(records.map(\.model) == ["gemini-a", "gemini-b"])

        let drained = uptimeDeadline(2)
        while events.events.isEmpty, DispatchTime.now() < drained { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(events.events.count == 1)
    }

    // MARK: pagination

    @Test func localModelListPaginatesAndRejectsBadPageSize() async throws {
        let upstream = mockSession { _ in GeminiMockURLProtocol.Reply(chunks: []) }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let a = FakeModel(id: UUID(), fakeModelID: "a", displayName: "a", remoteID: remote.id)
        let b = FakeModel(id: UUID(), fakeModelID: "b", displayName: "b", remoteID: remote.id)
        let (server, port, _) = try await startRouter(remotes: [remote], fakes: [a, b], upstream: upstream)
        defer { server.stop() }

        let (firstData, firstResponse) = try await send(port: port, path: "/v1beta/models?pageSize=1", method: "GET")
        #expect(firstResponse.statusCode == 200)
        let first = try #require(try JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        #expect((first["models"] as? [[String: Any]])?.count == 1)
        let token = try #require(first["nextPageToken"] as? String)

        let (secondData, secondResponse) = try await send(
            port: port, path: "/v1beta/models?pageSize=1&pageToken=\(token)", method: "GET")
        #expect(secondResponse.statusCode == 200)
        let second = try #require(try JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        #expect((second["models"] as? [[String: Any]])?.first?["name"] as? String == "models/b")
        #expect(second["nextPageToken"] == nil)

        let (_, bad) = try await send(port: port, path: "/v1beta/models?pageSize=abc", method: "GET")
        #expect(bad.statusCode == 400)
    }

    // MARK: countTokens skips the Forwarder accumulators

    @Test func countTokensReturnsRawUpstreamWithoutAccumulators() async throws {
        let upstream = mockSession { _ in
            // A payload that would be parsed as usage if an accumulator were attached.
            GeminiMockURLProtocol.Reply(chunks: [Data(#"{"totalTokens":5,"usageMetadata":{"promptTokenCount":5}}"#.utf8)])
        }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let countHead = HTTPRequestHead(version: .http1_1, method: .POST,
                                        uri: "/v1beta/models/main:countTokens")
        let count = try await Forwarder.makeRequest(clientHead: countHead, body: Data(#"{"contents":[]}"#.utf8),
                                                    endpoint: .gemini, remote: remote, query: "", session: upstream)
        #expect(count.usage == nil)          // 零 usage 采集
        #expect(count.performance == nil)    // 零性能采集
        count.cancel()

        // Generation still attaches the accumulators for comparison.
        let genHead = HTTPRequestHead(version: .http1_1, method: .POST,
                                      uri: "/v1beta/models/main:generateContent")
        let gen = try await Forwarder.makeRequest(clientHead: genHead, body: Data(#"{"contents":[]}"#.utf8),
                                                  endpoint: .gemini, remote: remote, query: "", session: upstream)
        #expect(gen.usage != nil)
        #expect(gen.performance != nil)
        gen.cancel()
    }

    // MARK: real SSE usage capture

    @Test func streamGenerateContentSSERecordsCacheAndThinkingUsageWithTTFT() async throws {
        // Two real SSE chunks; the final event carries cumulative usageMetadata with
        // cache + thinking counts.
        let firstChunk = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hel\"}]}}]}\n\n".utf8)
        let finalChunk = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"lo\"}]}}],\"usageMetadata\":{\"promptTokenCount\":10,\"toolUsePromptTokenCount\":2,\"candidatesTokenCount\":6,\"thoughtsTokenCount\":4,\"cachedContentTokenCount\":3,\"totalTokenCount\":22}}\n\n".utf8)
        let upstream = mockSession { _ in
            GeminiMockURLProtocol.Reply(headers: ["Content-Type": "text/event-stream"],
                                        chunks: [firstChunk, finalChunk])
        }
        defer { GeminiMockURLProtocol.handler = nil }

        let remote = geminiRemote("gemini-real", baseURL: "https://gemini.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main", remoteID: remote.id)
        let usage = UsageSpy()
        let (server, port, _) = try await startRouter(remotes: [remote], fakes: [fake], upstream: upstream,
                                                      usage: usage)
        defer { server.stop() }

        let (_, response) = try await send(port: port,
            path: "/v1beta/models/main:streamGenerateContent?key=\(clientKey)&alt=sse",
            body: #"{"contents":[]}"#, headers: ["content-type": "application/json"])
        #expect(response.statusCode == 200)

        let records = await waitFor(usage, count: 1)
        let record = try #require(records.first)
        #expect(record.outcome == "success")
        #expect(record.endpoint == "gemini")
        // input = promptTokenCount + toolUsePromptTokenCount; output = candidates + thoughts.
        #expect(record.tokens.input == 12)
        #expect(record.tokens.output == 10)
        #expect(record.tokens.cachedInput == 3)
        #expect(record.tokens.reasoning == 4)
        #expect(record.performance?.streaming == true)
        #expect(record.performance?.ttftMS != nil)
        #expect(record.performance?.generationMS != nil)
        #expect((record.performance?.outputDeltaCount ?? 0) >= 1)
    }

    // MARK: sticky fallback (same fixture, second request)

    @Test func generationFallbackSuccessIsStickyAndSecondRequestSkipsFirst() async throws {
        let hosts = RequestSpy()
        let upstream = mockSession { request in
            hosts.store(request)
            if request.url?.host == "fail.test" {
                return GeminiMockURLProtocol.Reply(status: 503, chunks: [Data(#"{"error":"busy"}"#.utf8)])
            }
            return GeminiMockURLProtocol.Reply(chunks: [Data(#"{"candidates":[]}"#.utf8)])
        }
        defer { GeminiMockURLProtocol.handler = nil }

        let first = geminiRemote("gemini-a", baseURL: "https://fail.test/v1beta")
        let second = geminiRemote("gemini-b", baseURL: "https://good.test/v1beta")
        let fake = FakeModel(id: UUID(), fakeModelID: "main", displayName: "main",
                             remoteID: first.id, fallbackRemoteIDs: [second.id])
        let usage = UsageSpy()
        let (server, port, router) = try await startRouter(remotes: [first, second], fakes: [fake],
                                                          upstream: upstream, usage: usage)
        defer { server.stop() }

        let path = "/v1beta/models/main:generateContent?key=\(clientKey)"
        let (_, firstResponse) = try await send(port: port, path: path, body: #"{"contents":[]}"#,
                                                headers: ["content-type": "application/json"])
        #expect(firstResponse.statusCode == 200)

        // Wait for the completed success to promote good.test as the preferred remote.
        let deadline = uptimeDeadline(5)
        while router.activeRemoteID(fakeID: fake.id) != second.id, DispatchTime.now() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(router.activeRemoteID(fakeID: fake.id) == second.id)

        let (_, secondResponse) = try await send(port: port, path: path, body: #"{"contents":[]}"#,
                                                 headers: ["content-type": "application/json"])
        #expect(secondResponse.statusCode == 200)

        // Second request went straight to the promoted remote; the failed one was skipped.
        let seenHosts = hosts.requests.compactMap { $0.url?.host }
        #expect(seenHosts.filter { $0 == "fail.test" }.count == 1)
        #expect(seenHosts.filter { $0 == "good.test" }.count == 2)
    }
}
