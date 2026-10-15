import Foundation
import NIOCore
import NIOHTTP1
import Testing
@testable import EZSwitch

@Suite("Connector registration boundary")
struct ConnectorRegistryTests {
    private let source = RemoteSource(rawValue: "test-connector")

    private func remote() -> RemoteModel {
        RemoteModel(id: UUID(), name: "Fixture · model", apiKey: "",
                    model: "fixture-model", extraHeaders: [:],
                    apiEndpoints: .all(baseURL: "http://127.0.0.1:1/v1"), source: source)
    }

    @Test func registeredConnectorExecutesWithoutHostSpecificBranch() async throws {
        let observation = Observation()
        let definition = ConnectorDefinition(
            source: source, settingsKey: "fixtureSettings", displayName: "Fixture",
            endpoints: [.chat],
            forward: { request in
                await observation.record(model: request.remote.model, body: request.body)
                let response = HTTPURLResponse(url: URL(string: "http://localhost/connector")!,
                                               statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["content-type": "text/plain"])!
                let body = AsyncThrowingStream<ByteBuffer, Error> { continuation in
                    var buffer = ByteBufferAllocator().buffer(capacity: 7)
                    buffer.writeString("fixture")
                    continuation.yield(buffer)
                    continuation.finish()
                }
                return UpstreamResponse(response: response, body: body,
                                        cancel: { observation.cancellation.mark() })
            },
            fetchModels: { ["fixture-model"] })
        let registry = ExtensionRegistry(connectors: [definition])
        let requestBody = Data(#"{"messages":[{"role":"user","content":"hello"}]}"#.utf8)
        let response = try await Forwarder.makeRequest(
            clientHead: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions"),
            body: requestBody, endpoint: .chat, remote: remote(), query: "",
            extensionRegistry: registry)
        var output = Data()
        for try await buffer in response.body { output.append(contentsOf: buffer.readableBytesView) }
        #expect(String(decoding: output, as: UTF8.self) == "fixture")
        #expect(await observation.model == "fixture-model")
        #expect(await observation.body == requestBody)
        #expect(try await registry.fetchModels(source: source) == ["fixture-model"])
        response.cancel()
        #expect(observation.cancellation.value)
    }

    @Test func absentConnectorNeverUsesNativeURL() async throws {
        do {
            _ = try await Forwarder.makeRequest(
                clientHead: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions"),
                body: Data(), endpoint: .chat, remote: remote(), query: "",
                extensionRegistry: ExtensionRegistry())
            Issue.record("Missing connector unexpectedly produced a response")
        } catch let error as ConnectorUnavailable {
            #expect(error.source == source)
        }
        #expect(throws: (any Error).self) {
            try Forwarder.buildRequest(
                clientHead: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions"),
                body: Data(), endpoint: .chat, remote: remote(), query: "")
        }
    }

    private actor Observation {
        var model: String?
        var body: Data?
        nonisolated let cancellation = CancellationFlag()
        func record(model: String, body: Data) { self.model = model; self.body = body }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func mark() { lock.lock(); cancelled = true; lock.unlock() }
    }
}
