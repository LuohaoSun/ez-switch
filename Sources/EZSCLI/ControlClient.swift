import Foundation
import Darwin

/// Where the app's private control socket lives, relative to its config file.
enum CLIControlLocation {
    static func socketPath(forConfig configURL: URL) -> String {
        configURL.deletingLastPathComponent()
            .appendingPathComponent("ezs-control/control.sock").path
    }
}

/// Transport used to talk to a running EZ Switch instance.
///
/// Kept as a protocol so the command runner can be exercised without a socket,
/// and so the real socket client can be tested against a local listener.
protocol ControlClient {
    /// Sends one JSON request and returns the raw response line (without the
    /// trailing newline). Throws if the app cannot be reached or the response is
    /// missing/too large — it never turns a broken connection into empty success.
    func send(_ payload: [String: String]) throws -> Data
}

enum ControlClientError: Error, LocalizedError, Equatable {
    case pathTooLong
    /// errno from `socket()`, `connect()`, `read()` or `write()`.
    case socket(Int32)
    case responseTooLarge
    case responseMissing

    var errorDescription: String? {
        switch self {
        case .pathTooLong:
            return "control socket path is too long"
        case .socket(let code):
            let reason = String(cString: strerror(code))
            return "cannot reach EZ Switch (\(reason)); make sure the app is running"
        case .responseTooLarge:
            return "control response exceeded 1 MiB"
        case .responseMissing:
            return "the EZ Switch control socket closed without a response"
        }
    }
}

/// One-shot Unix-domain-socket client. Matches the framing used by the app:
/// a single JSON object followed by `\n`, and a single JSON line in reply.
struct SocketControlClient: ControlClient {
    let socketPath: String
    var timeout: TimeInterval = 5
    /// Maximum accepted response frame, excluding the trailing newline.
    var responseLimit: Int = 1_048_576

    func send(_ payload: [String: String]) throws -> Data {
        let bytes = Array(socketPath.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlClientError.pathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map(UInt8.init)) }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlClientError.socket(errno) }
        defer { Darwin.close(fd) }

        // A peer that closes while we write must surface as an error, not SIGPIPE.
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var timeoutValue = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = withUnsafePointer(to: &timeoutValue) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ControlClientError.socket(errno) }

        var request = try JSONSerialization.data(withJSONObject: payload)
        request.append(10)
        try request.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ControlClientError.socket(errno) }
                sent += count
            }
        }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = reply.firstIndex(of: 10) {
                // Frame length is the byte distance to the newline; it must fit.
                guard newline <= responseLimit else { throw ControlClientError.responseTooLarge }
                return Data(reply[..<newline])
            }
            guard reply.count <= responseLimit else { throw ControlClientError.responseTooLarge }
            let readCount = Darwin.read(fd, &buffer, buffer.count)
            if readCount > 0 {
                reply.append(contentsOf: buffer.prefix(readCount))
            } else if readCount < 0 && errno == EINTR {
                continue
            } else if readCount < 0 {
                throw ControlClientError.socket(errno)
            } else {
                throw ControlClientError.responseMissing
            }
        }
    }
}
