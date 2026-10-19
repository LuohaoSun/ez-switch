import Foundation

/// 同步编辑与后台排序共享同一条写入队列，旧排序快照不能覆盖后续编辑。
final class ConfigPersistence: @unchecked Sendable {
    enum Result {
        case saved
        case failed(String)
        case changedOnDisk
    }

    private let url: URL
    private let queue = DispatchQueue(label: "local.ezswitch.config-write", qos: .utility)
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var knownData: Data?
    private let writeData: @Sendable (Data, URL) throws -> Void

    init(url: URL, writeData: @escaping @Sendable (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: .atomic)
    }) {
        self.url = url
        self.writeData = writeData
        knownData = try? Data(contentsOf: url)
    }

    private func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        return revision
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == revision
    }

    func save(_ config: AppConfig) -> Result {
        _ = advance()
        return queue.sync { write(config) }
    }

    func enqueue(_ config: AppConfig,
                 completion: @escaping @Sendable (UInt64, Result) -> Void) {
        let value = advance()
        queue.async { [self] in
            guard isCurrent(value) else { return }
            // 外部编辑优先于尚未落盘的排序；由宿主重新加载，不覆盖用户文件。
            let diskData = try? Data(contentsOf: url)
            guard diskData == knownData else {
                completion(value, .changedOnDisk)
                return
            }
            completion(value, write(config))
        }
    }

    func flush() {
        queue.sync {}
    }

    /// 相同字节（含自身写入）在 JSON 解码之前跳过；不同字节取消尚未执行的旧排序。
    func changedData() throws -> Data? {
        try queue.sync {
            let data = try Data(contentsOf: url)
            guard data != knownData else { return nil }
            _ = advance()
            knownData = data
            return data
        }
    }

    private func write(_ config: AppConfig) -> Result {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try writeData(data, url)
            knownData = data
            return .saved
        } catch {
            return .failed(String(describing: error))
        }
    }
}
