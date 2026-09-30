import Foundation
import NIOCore
import Testing
@testable import EZSwitch

@Suite("Fallback diagnostics")
struct FallbackDiagnosticsTests {
    private var remote: RemoteModel {
        RemoteModel(id: UUID(), name: "Test · model", apiKey: "secret-token", model: "model",
                    extraHeaders: ["x-key": "header-secret"], apiEndpoints: .all(baseURL: "https://example.test"))
    }

    @Test func extractsErrorDetailsAndRedactsCredentials() throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://example.test")!,
            statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60", "x-request-id": "request-123"]))
        let data = Data(#"{"error":{"type":"quota_exceeded","code":"limit","message":"secret-token header-secret exhausted"}}"#.utf8)
        let summary = FallbackDiagnostics.summary(response: response, body: data, remote: remote)
        #expect(summary.contains("429"))
        #expect(summary.contains("quota_exceeded"))
        #expect(summary.contains("limit"))
        #expect(summary.contains("request-123"))
        #expect(summary.contains("retry-after=60"))
        #expect(!summary.contains("secret-token"))
        #expect(!summary.contains("header-secret"))
    }

    @Test func boundsAndFlattensPlainTextErrors() throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://example.test")!,
            statusCode: 503, httpVersion: nil, headerFields: nil))
        let summary = FallbackDiagnostics.summary(response: response,
            body: Data(("unavailable\n" + String(repeating: "a", count: 5000)).utf8), remote: remote)
        #expect(summary.count <= 400)
        #expect(!summary.contains("\n"))
        #expect(summary.contains("unavailable"))
    }

    @Test func stalledErrorBodyDoesNotBlockFallback() async throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://example.test")!,
            statusCode: 429, httpVersion: nil, headerFields: nil))
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        defer { continuation.finish() }
        let started = Date()
        let data = await FallbackDiagnostics.readErrorBody(UpstreamResponse(response: response, body: stream, cancel: {}))
        #expect(data.isEmpty)
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
