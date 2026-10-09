import Darwin
import Foundation
@testable import EZSCLI

/// Minimal one-shot Unix-domain-socket server used to exercise the real
/// `SocketControlClient` against actual bytes. Each instance binds a short
/// path under `/tmp`, accepts a single connection, captures the request line,
/// then writes `response` followed by `\n` (or closes without a response).
final class TestControlServer: @unchecked Sendable {
    let path: String

    private let listenFD: Int32
    private let response: Data
    private let closeWithoutResponse: Bool
    private let appendNewline: Bool
    private let lock = NSLock()
    private var receivedStorage = Data()
    private var closed = false
    private let requestSemaphore = DispatchSemaphore(value: 0)

    init(response: Data, closeWithoutResponse: Bool = false, appendNewline: Bool = true) throws {
        self.response = response
        self.closeWithoutResponse = closeWithoutResponse
        self.appendNewline = appendNewline
        // A short path keeps us well under the sockaddr_un sun_path limit.
        self.path = "/tmp/ezs-cli-\(String(UUID().uuidString.prefix(8)).lowercased()).sock"

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map(UInt8.init)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            Darwin.unlink(path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        listenFD = fd
        Thread.detachNewThread { [self] in serve() }
    }

    /// The raw request line the client wrote (including the trailing newline).
    var receivedRequest: Data {
        lock.lock(); defer { lock.unlock() }
        return receivedStorage
    }

    func waitForRequest(timeout: TimeInterval = 5) -> Data? {
        guard requestSemaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return receivedRequest
    }

    func shutdown() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        Darwin.close(listenFD)
        Darwin.unlink(path)
    }

    deinit { shutdown() }

    private func serve() {
        let connection = Darwin.accept(listenFD, nil, nil)
        guard connection >= 0 else { return }
        defer { Darwin.close(connection) }
        // Writing to a client that stopped reading must not kill the test process.
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var request = Data()
        while request.firstIndex(of: 10) == nil {
            let count = Darwin.read(connection, &buffer, buffer.count)
            if count > 0 {
                request.append(contentsOf: buffer.prefix(count))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        lock.lock(); receivedStorage = request; lock.unlock()
        requestSemaphore.signal()

        guard !closeWithoutResponse else { return }
        var output = response
        if appendNewline { output.append(10) }
        output.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(connection, base.advanced(by: sent), raw.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}
