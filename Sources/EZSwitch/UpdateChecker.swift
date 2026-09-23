import AppKit
import Combine
import CryptoKit
import Foundation

struct UpdateAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct UpdateRelease: Decodable, Equatable {
    let tagName: String
    let htmlURL: URL
    let body: String?
    let assets: [UpdateAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }

    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    var diskImage: UpdateAsset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    var checksum: UpdateAsset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg.sha256") }
    }
}

enum UpdateVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(candidate)
        let right = components(current)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    static func checksum(from text: String) -> String? {
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first else {
            return nil
        }
        let value = token.lowercased()
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }

    private static func components(_ value: String) -> [Int] {
        let trimmed = value.hasPrefix("v") ? String(value.dropFirst()) : value
        return trimmed.split(separator: ".").map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
}

enum AutomaticUpdatePolicy {
    static let interval: TimeInterval = 24 * 60 * 60

    static func shouldCheck(lastCheckedAt: Date?, lastCheckedVersion: String?,
                            currentVersion: String, now: Date) -> Bool {
        guard let lastCheckedAt, lastCheckedVersion == currentVersion else { return true }
        let elapsed = now.timeIntervalSince(lastCheckedAt)
        return elapsed < 0 || elapsed >= interval
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading
        case verifying
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var availableRelease: UpdateRelease?
    @Published private(set) var automaticallyChecksForUpdates: Bool

    private let currentVersion: String
    private let session: URLSession
    private let defaults: UserDefaults
    private var automaticCheckTimer: Timer?

    private static let automaticChecksKey = "automaticallyChecksForUpdates"
    private static let lastCheckedAtKey = "lastUpdateCheckDate"
    private static let lastCheckedVersionKey = "lastUpdateCheckVersion"

    init(currentVersion: String? = nil, defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        self.defaults = defaults
        self.automaticallyChecksForUpdates = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        self.session = session ?? URLSession(configuration: configuration)
    }

    func startAutomaticChecks() {
        guard automaticallyChecksForUpdates, automaticCheckTimer == nil else { return }
        automaticCheckTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkAutomaticallyIfDue() }
        }
        // Always refresh at launch so an available release is visible after reopening the app.
        Task {
            if automaticallyChecksForUpdates { await check(silently: true) }
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard automaticallyChecksForUpdates != enabled else { return }
        automaticallyChecksForUpdates = enabled
        defaults.set(enabled, forKey: Self.automaticChecksKey)
        if enabled {
            startAutomaticChecks()
        } else {
            automaticCheckTimer?.invalidate()
            automaticCheckTimer = nil
        }
    }

    private func checkAutomaticallyIfDue() async {
        guard automaticallyChecksForUpdates,
              AutomaticUpdatePolicy.shouldCheck(
                lastCheckedAt: defaults.object(forKey: Self.lastCheckedAtKey) as? Date,
                lastCheckedVersion: defaults.string(forKey: Self.lastCheckedVersionKey),
                currentVersion: currentVersion, now: Date()
              ) else { return }
        await check(silently: true)
    }

    func check(silently: Bool = false) async {
        guard state != .checking && state != .downloading && state != .verifying else { return }
        let previousState = state
        state = .checking
        do {
            let release: UpdateRelease = try await request(
                URL(string: "https://api.github.com/repos/LuohaoSun/ez-switch/releases/latest")!
            )
            availableRelease = UpdateVersion.isNewer(release.version, than: currentVersion) ? release : nil
            state = availableRelease.map(State.available) ?? .upToDate
            defaults.set(Date(), forKey: Self.lastCheckedAtKey)
            defaults.set(currentVersion, forKey: Self.lastCheckedVersionKey)
        } catch {
            state = silently ? (previousState == .checking ? .idle : previousState)
                : .failed("检查更新失败：\(error.localizedDescription)")
        }
    }

    func downloadAndOpen(_ release: UpdateRelease) async {
        do {
            let localURL = try await downloadVerified(release)
            guard NSWorkspace.shared.open(localURL) else { throw UpdateError.cannotOpen }
            state = .ready(localURL.lastPathComponent)
        } catch {
            state = .failed("下载更新失败：\(error.localizedDescription)")
        }
    }

    func downloadVerified(_ release: UpdateRelease) async throws -> URL {
        guard let diskImage = release.diskImage, let checksumAsset = release.checksum else {
            throw UpdateError.missingAsset
        }

        state = .downloading
        async let diskImageData = download(diskImage.browserDownloadURL)
        async let checksumData = download(checksumAsset.browserDownloadURL)
        let (dmgData, checksumTextData) = try await (diskImageData, checksumData)

        state = .verifying
        guard let checksumText = String(data: checksumTextData, encoding: .utf8),
              let expected = UpdateVersion.checksum(from: checksumText) else {
            throw UpdateError.invalidChecksum
        }
        let actual = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch }

        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(diskImage.name)
        try dmgData.write(to: localURL, options: .atomic)
        return localURL
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("EZSwitch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("EZSwitch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.invalidResponse
        }
    }
}

enum UpdateError: LocalizedError {
    case missingAsset
    case invalidResponse
    case invalidChecksum
    case checksumMismatch
    case cannotOpen

    var errorDescription: String? {
        switch self {
        case .missingAsset: return "这个 Release 缺少 DMG 或 SHA-256 文件。"
        case .invalidResponse: return "更新服务器返回了无效响应。"
        case .invalidChecksum: return "SHA-256 文件格式无效。"
        case .checksumMismatch: return "DMG 校验失败，文件可能不完整。"
        case .cannotOpen: return "无法打开下载的 DMG。"
        }
    }
}
