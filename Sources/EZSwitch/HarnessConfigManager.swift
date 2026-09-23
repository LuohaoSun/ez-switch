import CryptoKit
import Darwin
import Foundation

enum HarnessConfigError: LocalizedError {
    case unsafeFile(String)
    case changed
    case noBackup
    case alreadyConfigured
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .unsafeFile(let reason): return "无法安全修改配置文件：\(reason)"
        case .changed: return "配置文件在预览后发生变化；请重新预览。恢复时若另有修改，请手动参考备份合并。"
        case .noBackup: return "没有可恢复的 EZ Switch 备份。"
        case .alreadyConfigured: return "已有一份 EZ Switch 配置备份，请先恢复后再重新配置。"
        case .invalidBackup: return "备份不完整或内容不匹配，已停止写入。"
        }
    }
}

struct HarnessConfigPlan {
    let target: HarnessTarget
    let fileURL: URL
    let original: Data?
    let proposed: Data
    let modelID: String
}

private struct HarnessBackupRecord: Codable {
    let filePath: String
    let existed: Bool
    let originalHash: String?
    let installedHash: String
    let backupName: String?
    let originalMode: UInt16
}

struct HarnessConfigManager {
    let home: URL
    let backupRoot: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         backupRoot: URL? = nil) {
        self.home = home
        self.backupRoot = backupRoot ?? home.appendingPathComponent("Library/Application Support/EZSwitch/HarnessBackups")
    }

    func fileURL(for target: HarnessTarget) -> URL? {
        switch target {
        case .codex:
            let root = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                ?? home.appendingPathComponent(".codex")
            return root.appendingPathComponent("config.toml")
        case .claudeCode:
            let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
                .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                ?? home.appendingPathComponent(".claude")
            return root.appendingPathComponent("settings.json")
        case .opencode: return nil
        }
    }

    func hasBackup(for target: HarnessTarget) -> Bool {
        FileManager.default.fileExists(atPath: recordURL(for: target).path)
    }

    func backupLocation(for target: HarnessTarget) -> URL { backupRoot.appendingPathComponent(target.rawValue) }

    func preview(target: HarnessTarget, endpoint: String, modelID: String) throws -> HarnessConfigPlan {
        guard let fileURL = fileURL(for: target) else { throw HarnessConfigError.unsafeFile("不支持这个工具") }
        try checkPath(fileURL)
        let original = try readIfExists(fileURL)
        let proposed: Data
        switch target {
        case .codex: proposed = try CodexHarnessConfig.configure(original, endpoint: endpoint, modelID: modelID)
        case .claudeCode: proposed = try ClaudeHarnessConfig.configure(original, endpoint: endpoint, modelID: modelID)
        case .opencode: throw HarnessConfigError.unsafeFile("不支持这个工具")
        }
        return HarnessConfigPlan(target: target, fileURL: fileURL, original: original,
                                 proposed: proposed, modelID: modelID)
    }

    func install(_ plan: HarnessConfigPlan) throws {
        try checkPath(plan.fileURL)
        guard plan.fileURL == fileURL(for: plan.target) else { throw HarnessConfigError.changed }
        guard !hasBackup(for: plan.target) else { throw HarnessConfigError.alreadyConfigured }
        guard try readIfExists(plan.fileURL) == plan.original else { throw HarnessConfigError.changed }
        guard plan.original != plan.proposed else { return }

        let originalMode = try mode(of: plan.fileURL) ?? 0o600
        let backupDir = backupLocation(for: plan.target)
        try createPrivateDirectory(backupDir)
        let backupName = plan.original == nil ? nil : "original-\(UUID().uuidString).backup"
        if let original = plan.original, let backupName {
            try writeAtomically(original, to: backupDir.appendingPathComponent(backupName), mode: 0o600)
        }
        let record = HarnessBackupRecord(filePath: plan.fileURL.path, existed: plan.original != nil,
                                         originalHash: plan.original.map(hash), installedHash: hash(plan.proposed),
                                         backupName: backupName, originalMode: originalMode)
        let manifest = try JSONEncoder().encode(record)
        // The marker precedes the replacement, so an interruption never leaves an untracked edit.
        try writeAtomically(manifest, to: recordURL(for: plan.target), mode: 0o600)
        do {
            guard try readIfExists(plan.fileURL) == plan.original else { throw HarnessConfigError.changed }
            try writeAtomically(plan.proposed, to: plan.fileURL, mode: originalMode,
                                expected: .some(plan.original))
        } catch {
            // Keep the backup and marker for manual recovery if replacement partially succeeded.
            throw error
        }
    }

    func restore(_ target: HarnessTarget) throws {
        let recordData = try readIfExists(recordURL(for: target))
        guard let recordData else { throw HarnessConfigError.noBackup }
        let record = try JSONDecoder().decode(HarnessBackupRecord.self, from: recordData)
        guard let fileURL = fileURL(for: target), fileURL.path == record.filePath else {
            throw HarnessConfigError.invalidBackup
        }
        try checkPath(fileURL)
        let current = try readIfExists(fileURL)
        // A crash between writing the marker and replacing the target leaves the original intact.
        if current.map(hash) == record.originalHash {
            try FileManager.default.removeItem(at: recordURL(for: target))
            return
        }
        guard let current, hash(current) == record.installedHash else { throw HarnessConfigError.changed }
        if record.existed {
            guard let name = record.backupName, !name.contains("/"),
                  let original = try readIfExists(backupLocation(for: target).appendingPathComponent(name)),
                  hash(original) == record.originalHash else { throw HarnessConfigError.invalidBackup }
            try writeAtomically(original, to: fileURL, mode: record.originalMode,
                                expected: .some(current))
        } else {
            guard try readIfExists(fileURL) == current else { throw HarnessConfigError.changed }
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.removeItem(at: recordURL(for: target))
    }

    private func recordURL(for target: HarnessTarget) -> URL {
        backupLocation(for: target).appendingPathComponent("active.json")
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func checkPath(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try checkDirectoryOrAbsent(parent)
        var st = stat()
        if lstat(url.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw HarnessConfigError.unsafeFile("只支持普通文件，不会替换符号链接")
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func checkDirectoryOrAbsent(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                throw HarnessConfigError.unsafeFile("目录路径不是普通目录或是符号链接：\(url.path)")
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func readIfExists(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private func mode(of url: URL) throws -> UInt16? {
        var st = stat()
        if lstat(url.path, &st) == 0 { return UInt16(st.st_mode & 0o777) }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try checkDirectoryOrAbsent(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeAtomically(_ data: Data, to url: URL, mode: UInt16,
                                 expected: Data?? = nil) throws {
        let parent = url.deletingLastPathComponent()
        try checkPath(url)
        if !FileManager.default.fileExists(atPath: parent.path) { try createPrivateDirectory(parent) }
        let temp = parent.appendingPathComponent(".ezswitch-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var renamed = false
        defer {
            close(fd)
            if !renamed { try? FileManager.default.removeItem(at: temp) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fchmod(fd, mode_t(mode)) == 0, fsync(fd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let expected {
            try checkPath(url)
            guard try readIfExists(url) == expected else { throw HarnessConfigError.changed }
        }
        guard rename(temp.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renamed = true
        let directoryFD = open(parent.path, O_RDONLY)
        if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
    }
}
