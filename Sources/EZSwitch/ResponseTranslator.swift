import Foundation
import Darwin

struct ResponseTranslationError: Error, CustomStringConvertible {
    let description: String
    var clientError = false
}

/// One helper process per request: state and pipes are never shared across conversations.
/// The helper receives bodies only. API keys and network connections remain in Swift.
final class ResponseTranslator: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "EZSwitch.response-translator")
    private let lock = NSLock()
    private var stopped = false
    private var pending = Data()

    static func executableURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["EZSWITCH_TRANSLATOR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ezs-responses-bridge")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ResponseTranslationError(description: "Responses translator missing from this app build")
        }
        return url
    }

    init(executable: URL? = nil) throws {
        process.executableURL = try executable ?? Self.executableURL()
        process.standardInput = input
        process.standardOutput = output
        // Avoid leaking request bodies into application logs on helper failure.
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin"]
        // A cancelled helper may close its pipe while an exchange is writing.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        // Closing stdin after ongoing exchange completes lets a healthy helper exit too.
        queue.async { [input, output] in
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
    }

    func exchange(_ frame: [String: Any]) async throws -> [String: Any] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        lock.lock(); let isStopped = stopped; lock.unlock()
                        if isStopped { throw CancellationError() }
                        var data = try JSONSerialization.data(withJSONObject: frame)
                        data.append(10)
                        // A stalled helper cannot hold a request indefinitely.
                        let timeout = DispatchWorkItem { [weak self] in self?.stop() }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
                        defer { timeout.cancel() }
                        try input.fileHandleForWriting.write(contentsOf: data)
                        while pending.count < 64 * 1024 * 1024 {
                            if let newline = pending.firstIndex(of: 10) {
                                let line = Data(pending.prefix(upTo: newline))
                                pending.removeSubrange(...newline)
                                guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                                    throw ResponseTranslationError(description: "invalid translator reply")
                                }
                                guard reply["ok"] as? Bool == true else {
                                    throw ResponseTranslationError(description: reply["error"] as? String ?? "translation failed",
                                                                   clientError: frame["op"] as? String == "request")
                                }
                                continuation.resume(returning: reply)
                                return
                            }
                            var bytes = [UInt8](repeating: 0, count: 4096)
                            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                            if count == -1 && errno == EINTR { continue }
                            guard count > 0 else {
                                throw ResponseTranslationError(description: "Responses translator exited before replying")
                            }
                            pending.append(contentsOf: bytes.prefix(count))
                        }
                        throw ResponseTranslationError(description: "translator reply too large")
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { stop() }
    }

    func prepare(_ body: Data, model: String) async throws -> Data {
        let original = try JSONSerialization.jsonObject(with: body)
        let reply = try await exchange(["op": "request", "model": model, "body": original])
        guard let translated = reply["body"] as? [String: Any] else {
            throw ResponseTranslationError(description: "translator returned no request body")
        }
        return try JSONSerialization.data(withJSONObject: translated)
    }

    func consume(_ data: Data) async throws -> [Data] {
        try await blocks(exchange(["op": "chunk", "data": data.base64EncodedString()]))
    }

    func finish() async throws -> [Data] {
        try await blocks(exchange(["op": "finish"]))
    }

    private func blocks(_ reply: [String: Any]) throws -> [Data] {
        guard let values = reply["blocks"] as? [String] else { return [] }
        return try values.map {
            guard let data = Data(base64Encoded: $0) else {
                throw ResponseTranslationError(description: "invalid translator stream block")
            }
            return data
        }
    }

    func response(_ data: Data) async throws -> Data {
        let reply = try await exchange(["op": "response", "data": data.base64EncodedString()])
        guard let body = reply["body"] as? [String: Any] else {
            throw ResponseTranslationError(description: "translator returned no response body")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}
