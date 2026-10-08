import Foundation
import Darwin
import SQLite3

/// SQLite 持久化的本地 token 用量历史。
///
/// 约束：
/// - 所有数据库访问都在一条私有串行 utility 队列上；连接懒加载。
/// - `record(_:)` 面向代理热路径，永不抛错；写入失败会置 `writeError`，由 snapshot/exportCSV/flush 抛出。
/// - 只记录请求元数据与 token 计数，不记录 prompt、响应正文或密钥。
/// - `user_version` 高于当前版本时安全拒绝，绝不破坏性重建。
final class UsageStore: @unchecked Sendable {

    /// 当前 schema 版本；升级时必须写迁移，且不得清空已有数据。
    static let schemaVersion: Int32 = 1

    /// 打开失败后的重试冷却；避免热路径上反复尝试并刷日志。
    private static let openRetryCooldown: TimeInterval = 5

    private let url: URL
    private let queue = DispatchQueue(label: "com.ezswitch.usage-store", qos: .utility)

    // 以下成员仅在 `queue` 上访问（init/deinit 除外）。
    private var db: OpaquePointer?
    private var openError: Error?
    private var lastOpenAttempt: Date?
    private var writeError: Error?

    init(url: URL) {
        self.url = url
    }

    deinit {
        // 捕获 self 的异步任务都持有强引用，deinit 时不会仍有任务在用连接。
        if let db { sqlite3_close_v2(db) }
    }

    /// 默认数据库位置：与配置文件同级的 `usage.sqlite`。
    static func databaseURL(for configURL: URL) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("usage.sqlite")
    }

    // MARK: - 写入

    /// 异步落盘，不抛错。打开/插入失败分别记入 `openError`/`writeError`。
    /// 打开失败已由查询路径暴露，故不重复登记。只记录首个写错误，避免日志风暴；
    /// 恢复策略：任意一次成功写入即清除 `writeError`（瞬时错误如 BUSY/FULL 解除后自动恢复）。
    func record(_ record: UsageRecord) {
        queue.async { [self] in
            let db: OpaquePointer
            do {
                db = try requireDB()
            } catch {
                return
            }
            do {
                try insert(db, record)
                writeError = nil
            } catch {
                if writeError == nil {
                    writeError = error
                    Log.shared.log("usage: record write failed; further write errors suppressed until recovery: \(error)")
                }
            }
        }
    }

    // MARK: - 查询

    /// 统计 `[from, to)` 内的用量，按本地日历天分桶（含 DST）。
    func snapshot(from: Date, to: Date, grouping: UsageGrouping) async throws -> UsageSnapshot {
        try await onQueue { [self] in
            let db = try requireDB(force: true)
            try throwPendingWriteError()
            return try snapshot(db, from: from, to: to, grouping: grouping)
        }
    }

    /// 导出 `[from, to)` 内的原始记录为 CSV（RFC 4180，CRLF）。
    func exportCSV(from: Date, to: Date) async throws -> String {
        try await onQueue { [self] in
            let db = try requireDB(force: true)
            try throwPendingWriteError()
            return try exportCSV(db, from: from, to: to)
        }
    }

    /// 删除全部记录（保留 schema 与文件）；成功即视为一次成功写入，清除 `writeError`。
    func clear() async throws {
        try await onQueue { [self] in
            let db = try requireDB(force: true)
            try execute(db, "DELETE FROM usage_records;")
            writeError = nil
        }
    }

    /// 等待队列上已排队的写入完成，并暴露已缓存的打开/写入错误。仅供测试。
    func flush() async throws {
        try await onQueue { [self] in
            if let openError { throw openError }
            try throwPendingWriteError()
        }
    }

    // MARK: - 队列桥接

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func throwPendingWriteError() throws {
        if let writeError { throw writeError }
    }

    // MARK: - 连接与 schema

    private func requireDB(force: Bool = false) throws -> OpaquePointer {
        try openIfNeeded(force: force)
        guard let db else {
            throw UsageStoreError.openFailed(code: 0, message: "database unavailable")
        }
        return db
    }

    /// 懒打开。打开失败会被缓存以防刷日志；`force`（用户触发的查询）可立即重试以支持 UI 修复后恢复，
    /// 否则需等待冷却。未来版本属永久拒绝：任何情况下都不重试、不重建。
    private func openIfNeeded(force: Bool = false) throws {
        if db != nil { return }
        if let error = openError {
            if case UsageStoreError.futureSchema = error { throw error }
            if !force, let last = lastOpenAttempt, Date().timeIntervalSince(last) < Self.openRetryCooldown {
                throw error
            }
        }
        do {
            try openDatabase()
            openError = nil
            lastOpenAttempt = nil
        } catch {
            openError = error
            lastOpenAttempt = Date()
            throw error
        }
    }

    private func openDatabase() throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw UsageStoreError.openFailed(code: 0,
                                                 message: "cannot create \(directory.path): \(error)")
            }
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle { sqlite3_close_v2(handle) }
            throw UsageStoreError.openFailed(code: result, message: message)
        }

        do {
            // 先读版本：未来版本必须在任何写操作（含 journal_mode 切换）前拒绝并保持原样。
            let version = try userVersion(handle)
            guard version <= Self.schemaVersion else {
                throw UsageStoreError.futureSchema(found: version, supported: Self.schemaVersion)
            }
            try configure(handle)
            try migrate(handle, from: version)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }

        db = handle
        applyPrivatePermissions()
    }

    private func configure(_ handle: OpaquePointer) throws {
        // WAL + busy_timeout：并发读与瞬时写锁不阻塞代理。
        try execute(handle, "PRAGMA journal_mode=WAL;")
        try execute(handle, "PRAGMA busy_timeout=5000;")
        try execute(handle, "PRAGMA synchronous=NORMAL;")
    }

    /// schema 与 user_version 在同一事务内提交；失败回滚，已存在的库保持原样。
    private func migrate(_ handle: OpaquePointer, from version: Int32) throws {
        try execute(handle, "BEGIN IMMEDIATE;")
        do {
            try execute(handle, Self.schemaSQL)
            if version < Self.schemaVersion {
                try execute(handle, "PRAGMA user_version = \(Self.schemaVersion);")
            }
            try execute(handle, "COMMIT;")
        } catch {
            try? execute(handle, "ROLLBACK;")
            throw error
        }
    }

    private func userVersion(_ handle: OpaquePointer) throws -> Int32 {
        let statement = try prepare(handle, "PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageStoreError.sqlite(message: lastErrorMessage(handle), code: sqlite3_errcode(handle))
        }
        return sqlite3_column_int(statement, 0)
    }

    /// db 及 WAL/SHM 文件设为仅属主可读写（尽力而为）。
    private func applyPrivatePermissions() {
        for path in [url.path, url.path + "-wal", url.path + "-shm"]
        where FileManager.default.fileExists(atPath: path) {
            _ = chmod(path, 0o600)
        }
    }

    // MARK: - 写入实现

    private func insert(_ db: OpaquePointer, _ record: UsageRecord) throws {
        let sql = """
        INSERT OR IGNORE INTO usage_records
          (id, request_id, ts, route_id, route_name, remote_id, provider, model, endpoint,
           attempt, status, outcome, duration_ms, input_tokens, output_tokens,
           cached_input_tokens, cache_write_tokens, reasoning_tokens)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, record.id.uuidString)
        bindText(statement, 2, record.requestID.uuidString)
        sqlite3_bind_double(statement, 3, record.timestamp.timeIntervalSince1970)
        bindText(statement, 4, record.routeID)
        bindText(statement, 5, record.routeName)
        bindText(statement, 6, record.remoteID)
        bindText(statement, 7, record.provider)
        bindText(statement, 8, record.model)
        bindText(statement, 9, record.endpoint)
        sqlite3_bind_int64(statement, 10, Int64(record.attempt))
        bindOptionalInt(statement, 11, record.status)
        bindText(statement, 12, record.outcome)
        sqlite3_bind_int64(statement, 13, Int64(record.durationMS))
        bindOptionalInt(statement, 14, record.tokens.input)
        bindOptionalInt(statement, 15, record.tokens.output)
        bindOptionalInt(statement, 16, record.tokens.cachedInput)
        bindOptionalInt(statement, 17, record.tokens.cacheWrite)
        bindOptionalInt(statement, 18, record.tokens.reasoning)
        try stepToDone(db, statement)
    }

    // MARK: - 查询实现

    private func snapshot(_ db: OpaquePointer, from: Date, to: Date,
                          grouping: UsageGrouping) throws -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        guard from < to else { return snapshot }
        let lo = from.timeIntervalSince1970
        let hi = to.timeIntervalSince1970
        snapshot.totals = try totals(db, lo: lo, hi: hi)
        snapshot.days = try days(db, lo: lo, hi: hi)
        snapshot.groups = try groups(db, lo: lo, hi: hi, grouping: grouping)
        return snapshot
    }

    private func totals(_ db: OpaquePointer, lo: Double, hi: Double) throws -> UsageTotals {
        let sql = """
        SELECT \(Self.aggregateColumns)
        FROM usage_records
        WHERE ts >= ? AND ts < ?;
        """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, lo)
        sqlite3_bind_double(statement, 2, hi)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageStoreError.sqlite(message: lastErrorMessage(db), code: sqlite3_errcode(db))
        }
        return readTotals(statement, offset: 0)
    }

    /// 按本地日历天分桶；SQLite `localtime` 逐行套用系统时区的 DST 偏移。
    private func days(_ db: OpaquePointer, lo: Double, hi: Double) throws -> [UsageDay] {
        // DateFormatter 非线程安全且会缓存时区，故按次创建，避免跨 store 队列共享。
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .autoupdatingCurrent
        parser.dateFormat = "yyyy-MM-dd"
        let sql = """
        SELECT date(ts, 'unixepoch', 'localtime') AS day,
               COALESCE(SUM(input_tokens), 0),
               COALESCE(SUM(output_tokens), 0)
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        GROUP BY day
        HAVING day IS NOT NULL
        ORDER BY day ASC;
        """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, lo)
        sqlite3_bind_double(statement, 2, hi)
        var result: [UsageDay] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw UsageStoreError.sqlite(message: lastErrorMessage(db), code: sqlite3_errcode(db))
            }
            guard let raw = text(statement, 0), let date = parser.date(from: raw) else { continue }
            result.append(UsageDay(date: date,
                                   input: Int(sqlite3_column_int64(statement, 1)),
                                   output: Int(sqlite3_column_int64(statement, 2))))
        }
        return result
    }

    private func groups(_ db: OpaquePointer, lo: Double, hi: Double,
                        grouping: UsageGrouping) throws -> [UsageGroupRow] {
        switch grouping {
        case .route:
            // routeID 不可变，是分组身份；MAX(ts) 让裸列 route_name 取最近一条记录的名字。
            let sql = """
            SELECT route_id, route_name, MAX(ts), \(Self.aggregateColumns)
            FROM usage_records
            WHERE ts >= ? AND ts < ?
            GROUP BY route_id
            ORDER BY (COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0)) DESC, route_id ASC;
            """
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, lo)
            sqlite3_bind_double(statement, 2, hi)
            var rows: [UsageGroupRow] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw UsageStoreError.sqlite(message: lastErrorMessage(db), code: sqlite3_errcode(db))
                }
                let id = text(statement, 0) ?? ""
                let title = text(statement, 1) ?? id
                rows.append(UsageGroupRow(id: id, title: title, subtitle: "",
                                          totals: readTotals(statement, offset: 3)))
            }
            return rows

        case .provider:
            let sql = """
            SELECT provider, \(Self.aggregateColumns)
            FROM usage_records
            WHERE ts >= ? AND ts < ?
            GROUP BY provider
            ORDER BY (COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0)) DESC, provider ASC;
            """
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, lo)
            sqlite3_bind_double(statement, 2, hi)
            var rows: [UsageGroupRow] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw UsageStoreError.sqlite(message: lastErrorMessage(db), code: sqlite3_errcode(db))
                }
                let provider = text(statement, 0) ?? ""
                rows.append(UsageGroupRow(id: provider, title: provider, subtitle: "",
                                          totals: readTotals(statement, offset: 1)))
            }
            return rows

        case .model:
            // 按 (provider, model) 分组；标题为模型名，副标题为供应商。
            let sql = """
            SELECT provider, model, \(Self.aggregateColumns)
            FROM usage_records
            WHERE ts >= ? AND ts < ?
            GROUP BY provider, model
            ORDER BY (COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0)) DESC,
                     provider ASC, model ASC;
            """
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, lo)
            sqlite3_bind_double(statement, 2, hi)
            var rows: [UsageGroupRow] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw UsageStoreError.sqlite(message: lastErrorMessage(db), code: sqlite3_errcode(db))
                }
                let provider = text(statement, 0) ?? ""
                let model = text(statement, 1) ?? ""
                rows.append(UsageGroupRow(id: provider + "\u{1F}" + model, title: model,
                                          subtitle: provider, totals: readTotals(statement, offset: 2)))
            }
            return rows
        }
    }

    // MARK: - CSV

    private func exportCSV(_ db: OpaquePointer, from: Date, to: Date) throws -> String {
        var lines: [String] = [Self.csvHeader]
        guard from < to else { return lines.joined(separator: "\r\n") + "\r\n" }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone(identifier: "UTC")

        let sql = """
        SELECT ts, request_id, route_id, route_name, provider, model, endpoint, attempt, status,
               outcome, duration_ms, input_tokens, output_tokens, cached_input_tokens,
               cache_write_tokens, reasoning_tokens
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        ORDER BY ts ASC, id ASC;
        """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw UsageStoreError.sqlite(message: lastErrorMessage(db), code: sqlite3_errcode(db))
            }
            let timestamp = iso.string(from: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)))
            let fields: [String] = [
                timestamp,
                text(statement, 1) ?? "",
                text(statement, 2) ?? "",
                text(statement, 3) ?? "",
                text(statement, 4) ?? "",
                text(statement, 5) ?? "",
                text(statement, 6) ?? "",
                String(sqlite3_column_int64(statement, 7)),
                optionalInt(statement, 8).map(String.init) ?? "",
                text(statement, 9) ?? "",
                String(sqlite3_column_int64(statement, 10)),
                optionalInt(statement, 11).map(String.init) ?? "",
                optionalInt(statement, 12).map(String.init) ?? "",
                optionalInt(statement, 13).map(String.init) ?? "",
                optionalInt(statement, 14).map(String.init) ?? "",
                optionalInt(statement, 15).map(String.init) ?? "",
            ]
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// 中和公式注入：字符串单元格若以 `=` `+` `-` `@` / TAB / CR 开头则加前导单引号。
    private static func neutralize(_ value: String) -> String {
        guard let first = value.first, "=+-@\t\r".contains(first) else { return value }
        return "'" + value
    }

    /// RFC 4180 转义：先中和公式，再按需加引号并转义内部引号。
    private static func csvField(_ value: String) -> String {
        let neutralized = neutralize(value)
        guard neutralized.contains(",") || neutralized.contains("\"")
                || neutralized.contains("\n") || neutralized.contains("\r") else {
            return neutralized
        }
        return "\"" + neutralized.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - SQLite 辅助

    private func execute(_ handle: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage(handle)
            sqlite3_free(errorPointer)
            throw UsageStoreError.sqlite(message: message, code: sqlite3_errcode(handle))
        }
    }

    private func prepare(_ handle: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageStoreError.sqlite(message: lastErrorMessage(handle), code: sqlite3_errcode(handle))
        }
        return statement
    }

    private func stepToDone(_ handle: OpaquePointer, _ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UsageStoreError.sqlite(message: lastErrorMessage(handle), code: sqlite3_errcode(handle))
        }
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bindOptionalInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(statement, index, Int64(value)) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func readTotals(_ statement: OpaquePointer, offset: Int32) -> UsageTotals {
        var totals = UsageTotals()
        totals.input = Int(sqlite3_column_int64(statement, offset + 0))
        totals.output = Int(sqlite3_column_int64(statement, offset + 1))
        totals.cachedInput = Int(sqlite3_column_int64(statement, offset + 2))
        totals.cacheWrite = Int(sqlite3_column_int64(statement, offset + 3))
        totals.reasoning = Int(sqlite3_column_int64(statement, offset + 4))
        totals.attempts = Int(sqlite3_column_int64(statement, offset + 5))
        totals.requests = Int(sqlite3_column_int64(statement, offset + 6))
        totals.knownAttempts = Int(sqlite3_column_int64(statement, offset + 7))
        totals.failedAttempts = Int(sqlite3_column_int64(statement, offset + 8))
        // 非 NULL 记录数：让 UI 区分“未知”(count 0) 与“明确为 0”(count > 0)。
        totals.inputAttempts = Int(sqlite3_column_int64(statement, offset + 9))
        totals.outputAttempts = Int(sqlite3_column_int64(statement, offset + 10))
        totals.cachedInputAttempts = Int(sqlite3_column_int64(statement, offset + 11))
        return totals
    }

    private func lastErrorMessage(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 缓存/推理 token 是 in/out 的子集，只单独求和，不计入 `total`。
    /// `knownAttempts` 仅在 input 与 output 均存在时计数。
    /// 成功与否以最终 `outcome` 为准（HTTP 200 也可能因流中断/取消/翻译失败而失败），
    /// 因此转发侧必须对成功尝试写入 `outcome = "success"`，其余一律视为失败尝试。
    private static let successPredicate = "lower(outcome) = 'success'"

    private static let aggregateColumns = """
    COALESCE(SUM(input_tokens), 0),
             COALESCE(SUM(output_tokens), 0),
             COALESCE(SUM(cached_input_tokens), 0),
             COALESCE(SUM(cache_write_tokens), 0),
             COALESCE(SUM(reasoning_tokens), 0),
             COUNT(*),
             COUNT(DISTINCT request_id),
             COALESCE(SUM(CASE WHEN input_tokens IS NOT NULL AND output_tokens IS NOT NULL THEN 1 ELSE 0 END), 0),
             COALESCE(SUM(CASE WHEN \(successPredicate) THEN 0 ELSE 1 END), 0),
             COUNT(input_tokens),
             COUNT(output_tokens),
             COUNT(cached_input_tokens)
    """

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS usage_records (
        id TEXT PRIMARY KEY NOT NULL,
        request_id TEXT NOT NULL,
        ts REAL NOT NULL,
        route_id TEXT NOT NULL,
        route_name TEXT NOT NULL,
        remote_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        endpoint TEXT NOT NULL,
        attempt INTEGER NOT NULL,
        status INTEGER,
        outcome TEXT NOT NULL,
        duration_ms INTEGER NOT NULL,
        input_tokens INTEGER,
        output_tokens INTEGER,
        cached_input_tokens INTEGER,
        cache_write_tokens INTEGER,
        reasoning_tokens INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_records(ts);
    CREATE INDEX IF NOT EXISTS idx_usage_request ON usage_records(request_id);
    CREATE INDEX IF NOT EXISTS idx_usage_route ON usage_records(route_id);
    CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage_records(provider);
    CREATE INDEX IF NOT EXISTS idx_usage_model ON usage_records(provider, model);
    """

    private static let csvHeader = "timestamp,requestID,routeID,routeName,provider,model,endpoint,attempt,status,outcome,durationMS,inputTokens,outputTokens,cachedInputTokens,cacheWriteTokens,reasoningTokens"
}

// MARK: - 错误

enum UsageStoreError: Error, LocalizedError, Equatable {
    /// 打开数据库失败（路径不可写、目录无法创建等）。
    case openFailed(code: Int32, message: String)
    /// 磁盘上的 schema 版本高于本程序支持的版本；拒绝打开以避免破坏数据。
    case futureSchema(found: Int32, supported: Int32)
    /// SQLite 执行错误。
    case sqlite(message: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .openFailed(_, let message):
            return "无法打开用量数据库：\(message)"
        case .futureSchema(let found, let supported):
            return "用量数据库版本 \(found) 高于本程序支持的 \(supported)，已停止使用以避免损坏数据。"
        case .sqlite(let message, _):
            return "用量数据库错误：\(message)"
        }
    }
}
