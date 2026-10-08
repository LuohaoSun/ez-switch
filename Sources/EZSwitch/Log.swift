import Foundation

/// 线程安全的环形缓冲日志。server 线程和主线程都会写。
final class Log {
    static let shared = Log()

    private let lock = NSLock()
    private var buffer: [String] = []
    private let capacity = 300
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
    }

    func log(_ line: String) {
        lock.lock()
        let ts = formatter.string(from: Date())
        let entry = "\(ts) \(line)"
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()
        // print 放在锁外，避免 stdout 阻塞住其它线程；重定向到管道/文件时 stdout 是块缓冲，手动 flush
        print(entry)
        fflush(stdout)
    }

    func recent() -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer.joined(separator: "\n")
    }

    static func size(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }

    /// "5.4s"
    static func seconds(_ t: TimeInterval) -> String {
        String(format: "%.1fs", t)
    }
}
