import Foundation
import Testing
@testable import EZSwitch

private final class ResponsesStreamGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var tailSent = false
    private var received = Data()
    private var completed = false

    func release() { lock.lock(); released = true; lock.unlock() }
    func mayFinish() -> Bool { lock.lock(); defer { lock.unlock() }; return released }
    func markTailSent() { lock.lock(); tailSent = true; lock.unlock() }
    func append(_ data: Data) { lock.lock(); received.append(data); lock.unlock() }
    func finish() { lock.lock(); completed = true; lock.unlock() }
    func snapshot() -> (text: String, tailSent: Bool, completed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: received, as: UTF8.self), tailSent, completed)
    }
}

private final class GatedResponsesProtocol: URLProtocol {
    static let gateLock = NSLock()
    private static var currentGate: ResponsesStreamGate?
    static func install(_ gate: ResponsesStreamGate?) {
        gateLock.lock(); currentGate = gate; gateLock.unlock()
    }
    private var sender: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.gateLock.lock(); let gate = Self.currentGate; Self.gateLock.unlock()
        guard let gate, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        emit(#"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_test","type":"message","role":"assistant","content":[]}}"#)
        emit(#"{"type":"response.output_text.delta","output_index":0,"item_id":"msg_test","content_index":0,"delta":"early-stream-marker"}"#)
        sender = Task { [weak self] in
            let deadline = Date().addingTimeInterval(5)
            while !gate.mayFinish(), Date() < deadline {
                do { try await Task.sleep(nanoseconds: 10_000_000) }
                catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            gate.markTailSent()
            self.emit(#"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg_test","type":"message","status":"completed"}}"#)
            self.emit(#"{"type":"response.completed","response":{"id":"resp_test","status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}"#)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func emit(_ payload: String) {
        client?.urlProtocol(self, didLoad: Data("data: \(payload)\n\n".utf8))
    }

    override func stopLoading() { sender?.cancel() }
}

private final class ResponsesStreamingClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let gate: ResponsesStreamGate
    init(gate: ResponsesStreamGate) { self.gate = gate }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        gate.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        gate.finish()
    }
}

@Suite("Responses streaming integration", .serialized)
struct ResponsesStreamingIntegrationTests {
    @Test func nativeResponsesReachClientBeforeOutputItemDone() async throws {
        let gate = ResponsesStreamGate()
        GatedResponsesProtocol.install(gate)
        defer { gate.release(); GatedResponsesProtocol.install(nil) }
        let upstreamConfig = URLSessionConfiguration.ephemeral
        upstreamConfig.protocolClasses = [GatedResponsesProtocol.self]
        upstreamConfig.connectionProxyDictionary = [:]
        let upstream = URLSession(configuration: upstreamConfig)
        defer { upstream.invalidateAndCancel() }
        let remote = RemoteModel(id: UUID(), name: "Test · responses", apiKey: "test-only",
                                 model: "test-model", extraHeaders: [:],
                                 apiEndpoints: .all(baseURL: "https://responses.example.test/v1"))
        let route = FakeModel(id: UUID(), fakeModelID: "test-route", displayName: "Test",
                              remoteID: remote.id)
        let router = Router()
        router.update(AppConfig(port: 0, remotes: [remote], fakes: [route]))
        let server = RouterServer(router: router, recordUsage: nil,
                                  activityStore: ActivityStore(), session: upstream)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try #require(server.boundPort)
        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.connectionProxyDictionary = [:]
        let delegate = ResponsesStreamingClient(gate: gate)
        let client = URLSession(configuration: clientConfig, delegate: delegate, delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"model":"test-route","input":"hello","stream":true}"#.utf8)
        client.dataTask(with: request).resume()
        let deadline = Date().addingTimeInterval(3)
        while !gate.snapshot().text.contains("early-stream-marker"), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let first = gate.snapshot()
        #expect(first.text.contains("early-stream-marker"), "Text must reach the client before upstream closes its item")
        #expect(!first.tailSent, "The test upstream must still be withholding output_item.done")
        #expect(!first.completed)
        gate.release()
        let finishDeadline = Date().addingTimeInterval(3)
        while !gate.snapshot().completed, Date() < finishDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let final = gate.snapshot()
        #expect(final.completed)
        #expect(final.text.contains("response.output_item.done"))
        #expect(final.text.contains("response.completed"))
    }
}
