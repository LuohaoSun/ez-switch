import Combine
import Darwin
import Foundation

// 把已安装应用的 Contents/MacOS/ezs 以符号链接装到 /usr/local/bin/ezs（系统标准 PATH）。
// 只链接 /Applications 或 ~/Applications 中已安装的应用，绝不链接 DMG/临时构建路径。
// 判断基于 lstat、绝不覆盖已有条目；权限不足时走原生管理员授权：命令全为固定常量拼接、
// 路径双重转义、无任何用户输入，不使用 sudo，也不使用已废弃的 AuthorizationExecuteWithPrivileges。

enum CLIInstallError: LocalizedError {
    case appNotInstalled
    case conflict(String)
    case authorizationCancelled
    case authorizationFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .appNotInstalled:
            return "未找到已安装的 EZ Switch。请先把应用拖入“应用程序”文件夹，再安装命令行工具。"
        case .conflict(let reason):
            return reason
        case .authorizationCancelled:
            return "已取消管理员授权，未做任何改动。"
        case .authorizationFailed(let reason):
            return "管理员授权失败：\(reason)"
        case .writeFailed(let reason):
            return "安装命令行工具失败：\(reason)"
        }
    }
}

enum CLIInstallStatus: Equatable {
    case notInstalled
    case installed(linkTarget: String)
    case conflict(reason: String)
}

enum CLIInstallPlan: Equatable {
    case alreadyInstalled
    case createLink
    case refuse(reason: String)
}

enum CLIInstallDefaults {
    static let linkName = "ezs"
    static var destinationDirectory: URL { URL(fileURLWithPath: "/usr/local/bin", isDirectory: true) }
    static var destinationURL: URL { destinationDirectory.appendingPathComponent(linkName) }

    /// 只信任标准应用目录；绝不链接 DMG（/Volumes）或构建产物路径。
    static var searchLocations: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }
}

/// 无特权即可完成的状态检查与链接创建；所有判断用 lstat，绝不跟随、绝不覆盖。
struct CLIInstaller {
    let destinationDirectory: URL
    let linkName: String

    init(destinationDirectory: URL = CLIInstallDefaults.destinationDirectory,
         linkName: String = CLIInstallDefaults.linkName) {
        self.destinationDirectory = destinationDirectory
        self.linkName = linkName
    }

    var destinationURL: URL { destinationDirectory.appendingPathComponent(linkName) }
    var directoryExists: Bool { FileManager.default.fileExists(atPath: destinationDirectory.path) }

    func status(expectedTarget: URL) -> CLIInstallStatus {
        var info = stat()
        guard lstat(destinationURL.path, &info) == 0 else {
            return errno == ENOENT ? .notInstalled : .conflict(reason: "无法检查 \(destinationURL.path)（errno \(errno)）。")
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK {
            guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: destinationURL.path) else {
                return .conflict(reason: "已存在同名符号链接但无法读取：\(destinationURL.path)。")
            }
            let resolved = Self.normalizedPath(link, relativeTo: destinationDirectory)
            guard resolved == expectedTarget.standardizedFileURL.path else {
                return .conflict(reason: "已存在指向其他目标的符号链接：\(destinationURL.path) → \(resolved)，未做修改。")
            }
            return .installed(linkTarget: resolved)
        }
        if type == S_IFREG { return .conflict(reason: "已存在同名普通文件：\(destinationURL.path)，未做修改。") }
        if type == S_IFDIR { return .conflict(reason: "已存在同名目录：\(destinationURL.path)，未做修改。") }
        return .conflict(reason: "已存在同名项目：\(destinationURL.path)，未做修改。")
    }

    func plan(expectedTarget: URL) -> CLIInstallPlan {
        switch status(expectedTarget: expectedTarget) {
        case .notInstalled: return .createLink
        case .installed: return .alreadyInstalled
        case .conflict(let reason): return .refuse(reason: reason)
        }
    }

    /// 目录可写时直接创建链接；目录缺失时一并创建。已有正确链接是无副作用的成功。
    func installUnprivileged(expectedTarget: URL) throws {
        switch plan(expectedTarget: expectedTarget) {
        case .alreadyInstalled: return
        case .refuse(let reason): throw CLIInstallError.conflict(reason)
        case .createLink: break
        }
        if !directoryExists {
            do { try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true) }
            catch { throw CLIInstallError.writeFailed(error.localizedDescription) }
        }
        do { try FileManager.default.createSymbolicLink(at: destinationURL, withDestinationURL: expectedTarget) }
        catch { throw CLIInstallError.writeFailed(error.localizedDescription) }
    }

    static func normalizedPath(_ path: String, relativeTo directory: URL) -> String {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        return directory.appendingPathComponent(path).standardizedFileURL.path
    }
}

enum CLIInstallPrivilege {
    /// 目标目录（或其最近存在的父级）可写则无需授权；`/usr/local/bin` 通常 root:wheel，需要授权。
    static func requiresAuthorization(destinationDirectory: URL) -> Bool {
        var probe = destinationDirectory.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path || parent.path.isEmpty { return true }
            probe = parent
        }
        return access(probe.path, W_OK) != 0
    }
}

enum CLIInstallSource {
    /// 优先「当前应用」（若它已在标准应用目录），否则在标准目录中查找同名 `.app`。
    /// 只接受 `.app` 包，绝不返回 DMG/临时路径或任意候选。
    static func resolve(bundleURL: URL = Bundle.main.bundleURL,
                        searchLocations: [URL] = CLIInstallDefaults.searchLocations) -> URL? {
        for app in candidateApps(bundleURL: bundleURL, searchLocations: searchLocations) {
            let executable = app.appendingPathComponent("Contents/MacOS/\(CLIInstallDefaults.linkName)")
            if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        }
        return nil
    }

    private static func candidateApps(bundleURL: URL, searchLocations: [URL]) -> [URL] {
        var apps: [URL] = []
        let runningParent = bundleURL.deletingLastPathComponent().standardizedFileURL
        if bundleURL.pathExtension == "app",
           searchLocations.contains(where: { $0.standardizedFileURL.path == runningParent.path }) {
            apps.append(bundleURL)
        }
        let name = bundleURL.lastPathComponent
        let appName = name.hasSuffix(".app") ? name : "EZSwitch.app"
        for location in searchLocations {
            let candidate = location.appendingPathComponent(appName)
            if !apps.contains(where: { $0.standardizedFileURL.path == candidate.standardizedFileURL.path }) {
                apps.append(candidate)
            }
        }
        return apps
    }
}

enum CLIInstallCommand {
    /// 单引号包裹，内部单引号按 `'\''` 转义；仅用于固定的绝对路径，不接受用户输入。
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 固定工具 + 绝对路径。创建前再次拒绝任何已存在条目（`-e` 覆盖文件/目录/有效链接，
    /// `-L` 覆盖悬空链接）；`ln -sh` 不跟随已有符号链接，且不带 `-f`，因此永不覆盖。
    static func symlinkCommand(createDirectory: Bool, linkTarget: URL, destinationURL: URL) -> String {
        let destination = shellQuote(destinationURL.path)
        var parts: [String] = []
        if createDirectory {
            parts.append("/bin/mkdir -p " + shellQuote(destinationURL.deletingLastPathComponent().path))
        }
        parts.append("[ ! -e \(destination) ]")
        parts.append("[ ! -L \(destination) ]")
        parts.append("/bin/ln -sh " + shellQuote(linkTarget.path) + " " + destination)
        return parts.joined(separator: " && ")
    }

    /// 第二重转义：把 shell 命令安全嵌入 AppleScript 字符串字面量。
    static func appleScriptLiteral(forShellCommand command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func administratorShellScript(forShellCommand command: String) -> String {
        "do shell script \(appleScriptLiteral(forShellCommand: command)) with administrator privileges"
    }
}

/// 原生管理员授权执行，由系统弹出授权对话框，不收集密码。仅由 UI 在主线程调用。
@MainActor
enum CLIInstallAuthorizer {
    static func runWithAdministratorPrivileges(_ shellCommand: String) throws {
        let source = CLIInstallCommand.administratorShellScript(forShellCommand: shellCommand)
        guard let script = NSAppleScript(source: source) else {
            throw CLIInstallError.authorizationFailed("无法创建授权脚本。")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "未知错误"
        if code == -128 { throw CLIInstallError.authorizationCancelled }
        throw CLIInstallError.authorizationFailed(message)
    }
}

@MainActor
final class CLIInstallModel: ObservableObject {
    enum Phase: Equatable {
        case appMissing
        case notInstalled
        case installed
        case conflict(String)
        case working
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notInstalled
    @Published private(set) var detail: String?

    let installer: CLIInstaller
    private let resolveSource: () -> URL?

    init(installer: CLIInstaller = CLIInstaller(),
         resolveSource: @escaping () -> URL? = { CLIInstallSource.resolve() }) {
        self.installer = installer
        self.resolveSource = resolveSource
    }

    var destinationPath: String { installer.destinationURL.path }
    var canInstall: Bool {
        if case .failed = phase { return true }
        return phase == .notInstalled
    }

    func refresh() {
        // 不要覆盖仍需阅读的反馈（授权对话框关闭会让应用立刻重新激活）。
        if case .failed = phase { return }
        guard let source = resolveSource() else {
            phase = .appMissing
            detail = "请先将 EZ Switch 拖入“应用程序”文件夹，再安装命令行工具。"
            return
        }
        switch installer.status(expectedTarget: source) {
        case .installed:
            phase = .installed
            detail = "已安装，并指向当前应用。"
        case .notInstalled:
            phase = .notInstalled
            detail = CLIInstallPrivilege.requiresAuthorization(destinationDirectory: installer.destinationDirectory)
                ? "需要管理员授权才能在 \(installer.destinationDirectory.path) 创建链接。"
                : nil
        case .conflict(let reason):
            phase = .conflict(reason)
            detail = nil
        }
    }

    func install() {
        guard let source = resolveSource() else {
            phase = .appMissing
            detail = "请先将 EZ Switch 拖入“应用程序”文件夹，再安装命令行工具。"
            return
        }
        switch installer.status(expectedTarget: source) {
        case .installed:
            refresh()
            return
        case .conflict(let reason):
            phase = .conflict(reason)
            detail = nil
            return
        case .notInstalled:
            break
        }

        phase = .working
        detail = nil
        do {
            if CLIInstallPrivilege.requiresAuthorization(destinationDirectory: installer.destinationDirectory) {
                try CLIInstallAuthorizer.runWithAdministratorPrivileges(
                    CLIInstallCommand.symlinkCommand(createDirectory: !installer.directoryExists,
                                                     linkTarget: source,
                                                     destinationURL: installer.destinationURL))
            } else {
                try installer.installUnprivileged(expectedTarget: source)
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        finish(afterWriting: source)
    }

    private func finish(afterWriting source: URL) {
        switch installer.status(expectedTarget: source) {
        case .installed:
            phase = .installed
            detail = "已安装到 \(installer.destinationURL.path)。"
        case .conflict(let reason):
            phase = .conflict(reason)
            detail = nil
        case .notInstalled:
            phase = .failed("写入后未检测到链接，请重试。")
            detail = nil
        }
    }
}
