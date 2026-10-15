import Darwin
import Foundation

// Cursor 连接组件的进程/身份/配置职责。只处理本扩展自有 sidecar（固定版本 CLIProxyAPI
// Plus，打包名 ezs-cursor-proxy）：发现可执行文件、生成隔离 YAML、构造最小环境、启动与
// 终止自有进程。不含 HTTP 调用与连接状态机（见 CursorSidecarClient）。

// MARK: - 固定版本身份

/// 固定的 helper 身份。版本以 management 头 X-CPA-VERSION 的真实值为准展示，绝不自报编造。
enum CursorProxyBinary {
    /// ThirdParty/cursor-proxy/manifest.json 记录并冻结的版本。
    static let expectedVersion = CursorExtension.proxyVersion
    /// 打包进 .app/Contents/MacOS 的名称。
    static let bundledName = "ezs-cursor-proxy"
    static let minimumMacOS = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    /// 只认内置 helper：环境覆盖（绝对路径，失效即 nil）、主可执行文件同目录的 bundled 名，
    /// DEBUG 构建才允许工程根 .build 回退。绝不沿 PATH 查找陌生同名 binary。
    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment,
                         bundle: Bundle = .main,
                         fileManager: FileManager = .default) -> URL? {
        if let override = environment["EZSWITCH_CURSOR_PROXY"], !override.isEmpty {
            guard override.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: override)
            return isExecutable(url, fileManager: fileManager) ? url : nil
        }
        if let executable = bundle.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent(bundledName)
            if isExecutable(sibling, fileManager: fileManager) { return sibling }
        }
        #if DEBUG
        if let root = debugProjectRoot() {
            let candidate = root.appendingPathComponent(".build/\(bundledName)")
            if isExecutable(candidate, fileManager: fileManager) { return candidate }
        }
        #endif
        return nil
    }

    static func isExecutable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    #if DEBUG
    /// 本文件路径向上 5 级即工程根，仅在 DEBUG 允许 .build 回退（开发/测试便利）。
    private static func debugProjectRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
    #endif

    /// 固定 release 的短 commit 前缀（manifest 记录）。
    static let expectedCommitPrefix = "67eadafb4"

    /// 精确匹配固定版本：trim 后允许可选前缀 v，其余必须完全相等（避免 8.0.28-20 误匹配）。
    static func versionMatchesPinned(_ raw: String) -> Bool {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        return value == expectedVersion
    }

    /// commit 身份：非空时必须以固定短 commit 为前缀（大小写不敏感）。
    static func commitMatchesPinned(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return true }
        return value.hasPrefix(expectedCommitPrefix)
    }
}

// MARK: - 随机秘密 / 空闲端口

enum CursorProxyRandom {
    static func token(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }

    /// 绑定 127.0.0.1:0 取得系统分配的空闲端口后立即关闭。存在被抢注的竞态，调用方必须
    /// 在启动后用 health + management secret 认证确认真的是自有进程，失败换端口重试。
    static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CursorProxyError(message: "无法创建本地套接字") }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw CursorProxyError(message: "无法绑定本地端口") }

        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw CursorProxyError(message: "无法读取本地端口") }
        return UInt16(bigEndian: name.sin_port)
    }
}

// MARK: - 配置

/// 每次启动写入的隔离 YAML（v8 canonical 布局）。秘密只出现在受保护的 runtime YAML 与
/// actor 内存，绝不进入 AppConfig、环境变量、stdout/error 日志。
struct CursorProxyConfig: Equatable {
    var host = "127.0.0.1"
    var port: UInt16
    var managementSecret: String
    var apiKey: String
    var authDir: URL
    /// request-log 关闭时仍可能写错误请求体文件；给小上限而非 0（0 = 不清理，不是关闭记录）。
    var errorLogsMaxFiles = 2

    var yaml: String {
        """
        config-version: 8
        server:
          host: \(Self.scalar(host))
          port: \(port)
        management:
          allow-remote: false
          secret-key: \(Self.scalar(managementSecret))
          disable-control-panel: true
          disable-auto-update-panel: true
        access:
          api-keys:
            - \(Self.scalar(apiKey))
        oauth:
          auth-dir: \(Self.scalar(authDir.path))
        observability:
          logs:
            debug: false
            logging-to-file: false
            request-log: false
            request-log-success-body: false
            error-logs-max-files: \(errorLogsMaxFiles)
            detailed-api-error-body-log-limit: 0

        """
    }

    /// 用 JSON 字符串作为 YAML 双引号 scalar：正确处理引号、反斜杠、换行与控制符。
    private static func scalar(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let quoted = String(data: data, encoding: .utf8) else { return "\"\"" }
        return quoted
    }
}

// MARK: - 进程抽象（可注入）

struct CursorProxyLaunchSpec: Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var currentDirectoryURL: URL
}

/// 自有进程句柄：只终止自己启动的进程，绝不按名字/全局 kill。
final class CursorProxyProcessHandle: @unchecked Sendable {
    let processIdentifier: Int32
    private let process: Process
    private let lock = NSLock()
    private var terminated = false

    init(process: Process) {
        self.process = process
        self.processIdentifier = process.processIdentifier
    }

    var isRunning: Bool { process.isRunning }

    /// SIGTERM，2 秒后仍存活则 SIGKILL。幂等，永不阻塞调用方。
    func terminate() {
        lock.lock()
        if terminated { lock.unlock(); return }
        terminated = true
        lock.unlock()
        guard process.isRunning else { return }
        let target = process
        let pid = target.processIdentifier
        target.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if target.isRunning { kill(pid, SIGKILL) }
        }
    }

    func killImmediately() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

protocol CursorProxyProcessSupervising: Sendable {
    func launch(_ spec: CursorProxyLaunchSpec) throws -> CursorProxyProcessHandle
}

/// 生产实现：Foundation Process，stdout/stderr 接 nullDevice（丢弃，绝不回显可能含秘密的输出）。
struct FoundationCursorProxySupervisor: CursorProxyProcessSupervising {
    func launch(_ spec: CursorProxyLaunchSpec) throws -> CursorProxyProcessHandle {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.currentDirectoryURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CursorProxyError(message: "无法启动 Cursor 连接组件：\(error.localizedDescription)")
        }
        return CursorProxyProcessHandle(process: process)
    }
}

/// 自有进程注册表：给 `shutdownImmediately()`（NSApp 正常退出、非 async 上下文）一个同步、
/// 有界、无阻塞的终止入口。只登记本扩展启动的进程。
final class CursorProxyProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: CursorProxyProcessHandle?

    func set(_ newValue: CursorProxyProcessHandle?) {
        lock.lock(); handle = newValue; lock.unlock()
    }

    /// 仅当当前句柄就是它时才清除，避免慢的旧 startup 抹掉新实例。
    func clear(_ value: CursorProxyProcessHandle) {
        lock.lock(); if handle === value { handle = nil }; lock.unlock()
    }

    /// NSApp 正常退出：同步 SIGKILL 自有进程，保证进程随 app 一起消失（异步 TERM/KILL 在 app
    /// 退出后不会执行）。只作用于本扩展启动的进程。
    func terminateImmediately() {
        lock.lock(); let current = handle; lock.unlock()
        current?.killImmediately()
    }
}

// MARK: - 环境

enum CursorProxyEnvironment {
    /// 只保留运行与网络/证书/代理所需变量。绝不透传 harness 秘密、NODE_OPTIONS、管理密码。
    static let allowedKeys: Set<String> = [
        "USER", "LOGNAME", "PATH", "LANG", "SHELL", "TERM", "TZ",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "no_proxy", "all_proxy",
    ]

    static func sanitized(_ base: [String: String],
                          home: URL,
                          temp: URL) -> [String: String] {
        var environment: [String: String] = [:]
        for (key, value) in base where allowedKeys.contains(key) { environment[key] = value }
        // 隔离 HOME/TMPDIR，避免 helper 落到真实用户默认目录。
        environment["HOME"] = home.path
        environment["TMPDIR"] = temp.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        // 显式剔除任何意外带入的秘密（allowlist 已排除，双保险）。
        for denied in ["MANAGEMENT_PASSWORD", "NODE_OPTIONS", "EZSWITCH_CONFIG", "MODEL_ROUTER_CONFIG"] {
            environment[denied] = nil
        }
        return environment
    }
}

// MARK: - 运行目录

/// 本扩展自有运行目录（全部 0700；config 0600）。
struct CursorProxyLayout: Sendable {
    let root: URL

    var runtimeDir: URL { root.appendingPathComponent("runtime", isDirectory: true) }
    var authDir: URL { root.appendingPathComponent("auth", isDirectory: true) }
    var homeDir: URL { root.appendingPathComponent("home", isDirectory: true) }
    var configURL: URL { runtimeDir.appendingPathComponent("config.yaml") }

    func prepare(fileManager: FileManager = .default) throws {
        for directory in [root, runtimeDir, authDir, homeDir] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // 权限是敏感边界：失败必须抛出，绝不静默。
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// 先以 0600 写入同目录 staging 文件再 rename，避免 .atomic 默认 0644 的短窗口。
    func writeConfig(_ config: CursorProxyConfig, fileManager: FileManager = .default) throws {
        try prepare(fileManager: fileManager)
        guard let data = config.yaml.data(using: .utf8) else {
            throw CursorProxyError(message: "无法生成连接组件配置")
        }
        let staging = runtimeDir.appendingPathComponent(".config-\(UUID().uuidString).yaml")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CursorProxyError(message: "无法创建连接组件配置") }
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if written <= 0 { throw CursorProxyError(message: "写入连接组件配置失败") }
                    offset += written
                }
            }
        } catch {
            close(descriptor)
            try? fileManager.removeItem(at: staging)
            throw error
        }
        close(descriptor)
        guard rename(staging.path, configURL.path) == 0 else {
            try? fileManager.removeItem(at: staging)
            throw CursorProxyError(message: "无法落盘连接组件配置")
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}
