import Foundation
import Testing
@testable import EZSCLI

@Suite("Control socket client")
struct SocketControlClientTests {
    @Test func sendsOneJSONLineAndReturnsResponseWithoutNewline() throws {
        let usage = UsageFixture.usageObject()
        let server = try TestControlServer(response: UsageFixture.envelopeData(usage))
        defer { server.shutdown() }

        let client = SocketControlClient(socketPath: server.path)
        let reply = try client.send(["command": "usage", "period": "today"])
        let decoded = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(decoded["ok"] as? Bool == true)

        let request = try #require(server.waitForRequest())
        #expect(request.last == 10)
        let requestObject = try #require(
            try JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any])
        #expect(requestObject["command"] as? String == "usage")
        #expect(requestObject["period"] as? String == "today")
    }

    @Test func closedSocketWithoutResponseThrowsInsteadOfEmptySuccess() throws {
        let server = try TestControlServer(response: Data(), closeWithoutResponse: true)
        defer { server.shutdown() }

        let client = SocketControlClient(socketPath: server.path)
        #expect(throws: ControlClientError.responseMissing) {
            _ = try client.send(["command": "usage"])
        }
    }

    @Test func missingSocketReportsAppNotRunning() {
        let client = SocketControlClient(socketPath: "/tmp/ezs-cli-does-not-exist-\(UUID().uuidString).sock")
        #expect(throws: (any Error).self) {
            _ = try client.send(["command": "usage"])
        }
        do {
            _ = try client.send(["command": "usage"])
            Issue.record("expected the send to fail")
        } catch {
            #expect(error.localizedDescription.contains("make sure the app is running"))
        }
    }

    @Test func frameExactlyAtLimitIsAccepted() throws {
        let limit = 64
        let server = try TestControlServer(response: Data(repeating: 0x61, count: limit))
        defer { server.shutdown() }
        var client = SocketControlClient(socketPath: server.path)
        client.responseLimit = limit
        let reply = try client.send(["command": "usage"])
        #expect(reply.count == limit)
    }

    @Test func frameOverLimitWithTrailingNewlineIsRejected() throws {
        let limit = 64
        // 65 payload bytes; the terminating newline lands one byte past the limit.
        let server = try TestControlServer(response: Data(repeating: 0x61, count: limit + 1))
        defer { server.shutdown() }
        var client = SocketControlClient(socketPath: server.path)
        client.responseLimit = limit
        #expect(throws: ControlClientError.responseTooLarge) {
            _ = try client.send(["command": "usage"])
        }
    }

    @Test func oversizedFrameWithoutNewlineIsRejected() throws {
        let limit = 64
        let server = try TestControlServer(response: Data(repeating: 0x61, count: limit + 4096),
                                           appendNewline: false)
        defer { server.shutdown() }
        var client = SocketControlClient(socketPath: server.path)
        client.responseLimit = limit
        #expect(throws: ControlClientError.responseTooLarge) {
            _ = try client.send(["command": "usage"])
        }
    }
}
