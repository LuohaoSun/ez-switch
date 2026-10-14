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
    /// v2：追加流式性能列（streaming/ttft_ms/request_ttft_ms/generation_ms/output_delta_count），
    /// 全部为 nullable，旧记录保持 NULL，一律不重建表。
    static let schemaVersion: Int32 = 2

    /// 成功写入或清除后发布，作为"今日用量"等派生视图的失效信号。
    /// 只发信号，不携带任何记录、token 数值、路径或凭证。
    static let didChangeNotification = Notification.Name("com.ezswitch.usage-store.did-change")

    /// 打开失败后的重试冷却；避免热路径上反复尝试并刷日志。
    private static let openRetryCooldown: TimeInterval = 5

    private let url: URL
    private let notificationCenter: NotificationCenter
    /// 小时分桶使用的日历（含时区）；默认 `.current`。
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "com.ezswitch.usage-store", qos: .utility)

    // 以下成员仅在 `queue` 上访问（init/deinit 除外）。
    private var db: OpaquePointer?
    private var openError: Error?
    private var lastOpenAttempt: Date?
    private var writeError: Error?

    init(url: URL, notificationCenter: NotificationCenter = .default,
         calendar: Calendar = .current) {
        self.url = url
        self.notificationCenter = notificationCenter
        self.calendar = calendar
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
    /// 仅在真正写入成功后发出失效通知；打开/写入失败不通知（避免误导观察者认为有新数据）。
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
                postDidChange()
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
    /// `includeHourly` 为 true 时额外按本地日历小时分桶（`hours`）；默认 false，不执行小时查询。
    func snapshot(from: Date, to: Date, grouping: UsageGrouping,
                  includeHourly: Bool = false) async throws -> UsageSnapshot {
        try await onQueue { [self] in
            let db = try requireDB(force: true)
            try throwPendingWriteError()
            return try snapshot(db, from: from, to: to, grouping: grouping, includeHourly: includeHourly)
        }
    }

    /// 统计 `[from, to)` 内的流式性能（TTFT / TPS），按 `grouping` 分组。
    /// 独立于 `snapshot`：菜单/用量视图不触发性能查询，性能视图也不连带聚合 token。
    /// 采样与分位数在 store 的 utility 队列上完成，不阻塞主线程。
    func performanceSnapshot(from: Date, to: Date, grouping: UsageGrouping) async throws -> PerformanceSnapshot {
        try await onQueue { [self] in
            let db = try requireDB(force: true)
            try throwPendingWriteError()
            return try performanceSnapshot(db, from: from, to: to, grouping: grouping)
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
            postDidChange()
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

    /// 在 `queue` 上发出失效信号（NotificationCenter 线程安全）。通知不携带任何数据。
    private func postDidChange() {
        notificationCenter.post(name: Self.didChangeNotification, object: self)
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
    /// 各版本迁移步骤按序追加：只对“旧于该版本”的库执行，已是最新的库不再触碰。
    private func migrate(_ handle: OpaquePointer, from version: Int32) throws {
        try execute(handle, "BEGIN IMMEDIATE;")
        do {
            // 全新库直接建出完整 v2 表；已存在的表此句为 no-op（不会补列，故下面按需 ALTER）。
            try execute(handle, Self.schemaSQL)
            // v2：仅补齐缺失的 nullable 性能列。用 table_info 探测而非盲目 ALTER，
            // 兼容 v0/v1 或被外部手工建过的旧表（可能已含部分新列），避免 duplicate column。
            if version < 2 {
                try ensurePerformanceColumns(handle)
            }
            if version < Self.schemaVersion {
                try execute(handle, "PRAGMA user_version = \(Self.schemaVersion);")
            }
            try execute(handle, "COMMIT;")
        } catch {
            try? execute(handle, "ROLLBACK;")
            throw error
        }
    }

    /// 逐列探测 `usage_records`，只为缺失的性能列执行 `ALTER TABLE ... ADD COLUMN`（nullable）。
    /// 旧行在这些列上保持 NULL，不重写、不重建表。
    private func ensurePerformanceColumns(_ handle: OpaquePointer) throws {
        let existing = try Set(tableColumns(handle, table: "usage_records"))
        for column in Self.performanceColumns where !existing.contains(column.name) {
            try execute(handle, "ALTER TABLE usage_records ADD COLUMN \(column.name) \(column.definition);")
        }
    }

    private func tableColumns(_ handle: OpaquePointer, table: String) throws -> [String] {
        // table 为静态字面量，非用户输入。
        let statement = try prepare(handle, "PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw UsageStoreError.sqlite(message: lastErrorMessage(handle), code: sqlite3_errcode(handle))
            }
            if let name = text(statement, 1) { columns.append(name) }
        }
        return columns
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
           cached_input_tokens, cache_write_tokens, reasoning_tokens,
           streaming, ttft_ms, request_ttft_ms, generation_ms, output_delta_count)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
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
        bindPerformance(statement, startingAt: 19, record.performance)
        try stepToDone(db, statement)
    }

    /// 性能列整体落盘：`performance == nil` 时全写 NULL（旧/非流式记录无性能数据）。
    /// 时长先做合法性归一：非有限或负数一律归 NULL，避免污染后续分位数。
    private func bindPerformance(_ statement: OpaquePointer, startingAt index: Int32,
                                 _ performance: UsagePerformance?) {
        guard let performance else {
            for offset in 0..<5 { sqlite3_bind_null(statement, index + Int32(offset)) }
            return
        }
        sqlite3_bind_int(statement, index, performance.streaming ? 1 : 0)
        bindOptionalDouble(statement, index + 1, Self.sanitizedDuration(performance.ttftMS))
        bindOptionalDouble(statement, index + 2, Self.sanitizedDuration(performance.requestTTFTMS))
        bindOptionalDouble(statement, index + 3, Self.sanitizedDuration(performance.generationMS))
        sqlite3_bind_int64(statement, index + 4, Int64(max(0, performance.outputDeltaCount)))
    }

    /// 非有限或负数时长视为无效 → NULL；`nil` 保持 `nil`。
    private static func sanitizedDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    // MARK: - 查询实现

    private func snapshot(_ db: OpaquePointer, from: Date, to: Date,
                          grouping: UsageGrouping, includeHourly: Bool = false) throws -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        guard from < to else { return snapshot }
        let lo = from.timeIntervalSince1970
        let hi = to.timeIntervalSince1970
        snapshot.totals = try totals(db, lo: lo, hi: hi)
        snapshot.days = try days(db, lo: lo, hi: hi)
        snapshot.groups = try groups(db, lo: lo, hi: hi, grouping: grouping)
        if includeHourly {
            snapshot.hours = try hours(db, lo: lo, hi: hi)
        }
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

    /// 按本地日历小时分桶（半开区间 `[from, to)`）。
    /// 逐行用 `calendar.dateInterval(of: .hour, for:)` 求桶起点，正确处理 DST 重复/缺失小时
    /// 与半小时偏移时区（不按 epoch/3600 或本地时间字符串分组）；NULL token 计为 0、
    /// 某小时无记录不补桶，求和沿用饱和约定。
    private func hours(_ db: OpaquePointer, lo: Double, hi: Double) throws -> [UsageDay] {
        let sql = """
        SELECT ts, input_tokens, output_tokens
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        ORDER BY ts ASC;
        """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, lo)
        sqlite3_bind_double(statement, 2, hi)

        var buckets: [Date: (input: Int, output: Int)] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw UsageStoreError.sqlite(message: lastErrorMessage(db), code: sqlite3_errcode(db))
            }
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            // DST 回退时同一墙钟小时的两个真实起点不同，自然分成两个桶。
            guard let start = calendar.dateInterval(of: .hour, for: timestamp)?.start else { continue }
            let input = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? 0 : Int(sqlite3_column_int64(statement, 1))
            let output = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? 0 : Int(sqlite3_column_int64(statement, 2))
            let existing = buckets[start] ?? (0, 0)
            buckets[start] = (Self.saturatingAdd(existing.input, input),
                              Self.saturatingAdd(existing.output, output))
        }
        return buckets.keys.sorted().map {
            let bucket = buckets[$0] ?? (0, 0)
            return UsageDay(date: $0, input: bucket.input, output: bucket.output)
        }
    }

    /// 饱和求和：与 `UsageTotals.total` 同一约定，溢出钳到 `Int.max`。
    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
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

    // MARK: - 性能聚合

    /// 单趟扫描区间内所有记录，同时聚合成总览与分组。
    ///
    /// - `attempts` 统计全部记录（含失败 / 取消 / 非流式）。
    /// - `successfulStreamingAttempts` = `outcome=success` 且 HTTP 2xx 且流式的尝试数，
    ///   是 TTFT 的资格分母（无论是否带 usage）。
    /// - TTFT 均值样本：成功流式且有合法 attempt TTFT（`ttftMeanMS`）/ 合法 request TTFT
    ///   （`requestTTFTMeanMS`）；两者独立计数，缺 usage 不影响 TTFT。
    /// - TPS 有效队列（三个加权速率共用，保证可比）：成功流式 + 有限非负 attempt TTFT +
    ///   有限非负 request TTFT + 有限正 generation + outputTokens≥2 + deltaCount≥2。
    ///   三个速率均为 Σ输出 / Σ时长，绝不取逐请求速率的算术平均：
    ///   `tpsIncludingTTFT` = Σ输出×1000 / Σ(ttft+generation)，
    ///   `requestTpsIncludingTTFT` = Σ输出×1000 / Σ(requestttft+generation)，
    ///   `tpsExcludingTTFT` = Σ输出×1000 / Σgeneration。
    ///   缺 request TTFT 的记录从三者中一并排除，避免不同分母混用。
    /// - output 求和用 Double 累加避免 Int 溢出；任一求和非有限（上溢）时相应速率为 `nil`。
    /// - 失败 / 取消保留在 `attempts` 中，但不进入任何样本。
    /// - 队列为空或总时长为 0 时速率为 `nil`，不伪造 0。
    private func performanceSnapshot(_ db: OpaquePointer, from: Date, to: Date,
                                     grouping: UsageGrouping) throws -> PerformanceSnapshot {
        var snapshot = PerformanceSnapshot()
        guard from < to else { return snapshot }
        let sql = """
        SELECT route_id, route_name, provider, model, outcome, status, output_tokens,
               streaming, ttft_ms, request_ttft_ms, generation_ms, output_delta_count
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        ORDER BY ts ASC, id ASC;
        """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)

        let overall = PerformanceAggregator()
        var grouped: [String: PerformanceAggregator] = [:]

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw UsageStoreError.sqlite(message: lastErrorMessage(db), code: sqlite3_errcode(db))
            }
            let routeID = text(statement, 0) ?? ""
            let routeName = text(statement, 1) ?? routeID
            let provider = text(statement, 2) ?? ""
            let model = text(statement, 3) ?? ""
            let outcome = text(statement, 4) ?? ""
            let status = optionalInt(statement, 5)
            let outputTokens = optionalInt(statement, 6)
            let performance = readPerformance(statement, streamingIndex: 7)

            overall.add(outcome: outcome, status: status, outputTokens: outputTokens, performance: performance)

            let key: String
            let title: String
            let subtitle: String
            switch grouping {
            case .route:
                // 记录按 ts 升序，末次写入即最近一次的名字。
                key = routeID
                title = routeName
                subtitle = ""
            case .provider:
                key = provider
                title = provider
                subtitle = ""
            case .model:
                // 供应商 + 模型共同构成身份，避免不同供应商的同名模型被合并。
                // 用长度前缀编码（`<utf8字节数>:<provider><model>`），即便 provider/model 含分隔符也无碰撞。
                key = "\(provider.utf8.count):\(provider)\(model)"
                title = model
                subtitle = provider
            }
            let aggregator: PerformanceAggregator
            if let existing = grouped[key] {
                aggregator = existing
                aggregator.title = title
                aggregator.subtitle = subtitle
            } else {
                aggregator = PerformanceAggregator(title: title, subtitle: subtitle)
                grouped[key] = aggregator
            }
            aggregator.add(outcome: outcome, status: status, outputTokens: outputTokens,
                           performance: performance)
        }

        snapshot.summary = overall.summary()
        snapshot.groups = grouped
            .map { PerformanceGroupRow(id: $0.key, title: $0.value.title,
                                       subtitle: $0.value.subtitle, summary: $0.value.summary()) }
            .sorted { lhs, rhs in
                if lhs.summary.attempts != rhs.summary.attempts {
                    return lhs.summary.attempts > rhs.summary.attempts
                }
                return lhs.id < rhs.id
            }
        return snapshot
    }

    /// 单组/总览的性能累加器（引用类型：字典内原地累加，避免逐行复制样本数组）。
    /// 求和量一律用 `Double`，既避免 Int 溢出，也让加权速率的分母/分子全程保持浮点。
    private final class PerformanceAggregator {
        var title: String
        var subtitle: String
        private var attempts = 0
        private var successfulStreamingAttempts = 0
        // TTFT 均值样本（独立队列）。
        private var ttftSum = 0.0
        private var ttftCount = 0
        private var requestTTFTSum = 0.0
        private var requestTTFTCount = 0
        // TPS 有效队列（三个加权速率共用）。
        private var tpsCount = 0
        private var tpsOutputSum = 0.0
        private var tpsTTFTSum = 0.0
        private var tpsRequestTTFTSum = 0.0
        private var tpsGenerationSum = 0.0

        init(title: String = "", subtitle: String = "") {
            self.title = title
            self.subtitle = subtitle
        }

        func add(outcome: String, status: Int?, outputTokens: Int?, performance: UsagePerformance?) {
            attempts += 1
            guard let performance, performance.streaming,
                  outcome.lowercased() == "success",
                  let status, (200...299).contains(status) else { return }
            successfulStreamingAttempts += 1
            // 读取时已做非有限/负数归一，这里仍显式校验，保证样本口径自洽。
            let ttft = Self.validDuration(performance.ttftMS)
            let requestTTFT = Self.validDuration(performance.requestTTFTMS)
            if let ttft {
                ttftSum += ttft
                ttftCount += 1
            }
            if let requestTTFT {
                requestTTFTSum += requestTTFT
                requestTTFTCount += 1
            }
            // TPS 有效队列：三个加权速率共用同一分母口径（含 request TTFT），缺一即整体排除。
            guard let ttft, let requestTTFT,
                  let generation = performance.generationMS, generation.isFinite, generation > 0,
                  let outputTokens, outputTokens >= 2,
                  performance.outputDeltaCount >= 2 else { return }
            tpsCount += 1
            tpsOutputSum += Double(outputTokens)
            tpsTTFTSum += ttft
            tpsRequestTTFTSum += requestTTFT
            tpsGenerationSum += generation
        }

        func summary() -> PerformanceSummary {
            var summary = PerformanceSummary()
            summary.attempts = attempts
            summary.successfulStreamingAttempts = successfulStreamingAttempts
            summary.ttftSamples = ttftCount
            summary.requestTTFTSamples = requestTTFTCount
            summary.tpsSamples = tpsCount
            summary.ttftMeanMS = Self.mean(sum: ttftSum, count: ttftCount)
            summary.requestTTFTMeanMS = Self.mean(sum: requestTTFTSum, count: requestTTFTCount)
            summary.tpsIncludingTTFT = Self.rate(outputSum: tpsOutputSum,
                                                 timeSumMS: tpsTTFTSum + tpsGenerationSum, count: tpsCount)
            summary.requestTpsIncludingTTFT = Self.rate(outputSum: tpsOutputSum,
                                                        timeSumMS: tpsRequestTTFTSum + tpsGenerationSum,
                                                        count: tpsCount)
            summary.tpsExcludingTTFT = Self.rate(outputSum: tpsOutputSum,
                                                 timeSumMS: tpsGenerationSum, count: tpsCount)
            return summary
        }

        /// 有限非负时长视为有效样本；否则视为缺失。
        private static func validDuration(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }

        /// 算术平均：空样本或非有限求和返回 `nil`（不伪造 0）。
        private static func mean(sum: Double, count: Int) -> Double? {
            guard count > 0, sum.isFinite else { return nil }
            let value = sum / Double(count)
            return value.isFinite ? value : nil
        }

        /// 加权速率 = Σ输出×1000 / Σ时长(ms)：空队列、零/非有限时长或非有限求和返回 `nil`。
        private static func rate(outputSum: Double, timeSumMS: Double, count: Int) -> Double? {
            guard count > 0, outputSum.isFinite, timeSumMS.isFinite, timeSumMS > 0 else { return nil }
            let value = outputSum * 1000 / timeSumMS
            return value.isFinite ? value : nil
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
               cache_write_tokens, reasoning_tokens,
               streaming, ttft_ms, request_ttft_ms, generation_ms, output_delta_count
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
            let outputTokens = optionalInt(statement, 12)
            let performance = readPerformance(statement, streamingIndex: 16)
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
                outputTokens.map(String.init) ?? "",
                optionalInt(statement, 13).map(String.init) ?? "",
                optionalInt(statement, 14).map(String.init) ?? "",
                optionalInt(statement, 15).map(String.init) ?? "",
                // 性能列：无性能数据（旧记录 / 非流式）留空；无效值也留空，不写成 0。
                // CSV 是原始观测导出：失败/取消行若确有采样也会保留其 tps，但这些行不进入分位数。
                performance.map { $0.streaming ? "true" : "false" } ?? "",
                Self.csvNumber(performance?.ttftMS),
                Self.csvNumber(performance?.requestTTFTMS),
                Self.csvNumber(performance?.generationMS),
                performance.map { String($0.outputDeltaCount) } ?? "",
                Self.csvNumber(performance?.tps(outputTokens: outputTokens)),
            ]
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// 数值单元格格式化：`nil` 或非有限值输出空串（不写成 0，避免把“无数据”误当“零”）。
    /// 固定 en_US_POSIX + 3 位小数，避免受系统区域设置影响（如逗号小数点）。
    private static func csvNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), arguments: [value])
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

    private func bindOptionalDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(statement, index, value) }
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

    /// 读取时长列并对磁盘上的历史值再做一次防御性归一：非有限或负数归 `nil`。
    private func sanitizedDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Self.sanitizedDuration(sqlite3_column_double(statement, index))
    }

    /// 从 `streaming` 起始列读取一条性能采样；`streaming IS NULL` 表示该记录无性能数据。
    /// 其后四列依序为 ttft_ms、request_ttft_ms、generation_ms、output_delta_count。
    private func readPerformance(_ statement: OpaquePointer, streamingIndex: Int32) -> UsagePerformance? {
        guard sqlite3_column_type(statement, streamingIndex) != SQLITE_NULL else { return nil }
        return UsagePerformance(streaming: sqlite3_column_int(statement, streamingIndex) != 0,
                                ttftMS: sanitizedDouble(statement, streamingIndex + 1),
                                requestTTFTMS: sanitizedDouble(statement, streamingIndex + 2),
                                generationMS: sanitizedDouble(statement, streamingIndex + 3),
                                outputDeltaCount: Int(sqlite3_column_int64(statement, streamingIndex + 4)))
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
        reasoning_tokens INTEGER,
        streaming INTEGER,
        ttft_ms REAL,
        request_ttft_ms REAL,
        generation_ms REAL,
        output_delta_count INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_records(ts);
    CREATE INDEX IF NOT EXISTS idx_usage_request ON usage_records(request_id);
    CREATE INDEX IF NOT EXISTS idx_usage_route ON usage_records(route_id);
    CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage_records(provider);
    CREATE INDEX IF NOT EXISTS idx_usage_model ON usage_records(provider, model);
    """

    /// v2 追加的 nullable 性能列（列名 + 定义）。迁移时按 table_info 只补缺失项。
    /// 列顺序：streaming、ttft_ms、request_ttft_ms、generation_ms、output_delta_count。
    private static let performanceColumns: [(name: String, definition: String)] = [
        ("streaming", "INTEGER"),
        ("ttft_ms", "REAL"),
        ("request_ttft_ms", "REAL"),
        ("generation_ms", "REAL"),
        ("output_delta_count", "INTEGER"),
    ]

    private static let csvHeader = "timestamp,requestID,routeID,routeName,provider,model,endpoint,attempt,status,outcome,durationMS,inputTokens,outputTokens,cachedInputTokens,cacheWriteTokens,reasoningTokens,streaming,ttftMS,requestTTFTMS,generationMS,outputDeltaCount,tps"
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
