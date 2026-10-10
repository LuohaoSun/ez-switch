import Combine
import Foundation
import UserNotifications

enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional

    var allowsDelivery: Bool { self == .authorized || self == .provisional }
}

/// 通知投递抽象；测试注入 fake，生产实现包 `UNUserNotificationCenter`。
protocol AutoFallbackNotificationClient: AnyObject {
    func authorizationStatus() async -> NotificationAuthorization
    /// 仅用户开启开关时调用；后台转发不触发授权弹窗。
    func requestAuthorization() async -> NotificationAuthorization
    func deliver(title: String, body: String, identifier: String) async throws
}

/// 生产 client：持有 `UNUserNotificationCenter` 并作为 delegate（前台无声 banner）。
/// 由 service 懒创建，避免 shared/static 初始化触碰系统通知中心。
final class SystemAutoFallbackNotificationClient: NSObject, AutoFallbackNotificationClient,
                                                 UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert])
        return await authorizationStatus()
    }

    func deliver(title: String, body: String, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await center.add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// 通知文案：只暴露 route/from/to 与数值化原因，过滤控制字符并截断。
enum AutoFallbackNotificationContent {
    static let title = "模型自动切换"
    static let fieldLimit = 60

    static func reasonText(_ reason: AutoFallbackEvent.Reason) -> String {
        switch reason {
        case .httpStatus(let code): return "HTTP \(code)"
        case .connectionFailure: return "连接失败"
        }
    }

    static func body(for event: AutoFallbackEvent) -> String {
        let route = sanitize(event.route), from = sanitize(event.from), to = sanitize(event.to)
        // 明确“正在尝试”，避免被读成已成功切换。
        return "\(route)：\(from) → \(to)，\(reasonText(event.reason))\n正在尝试 \(to)"
    }

    static func sanitize(_ raw: String, limit: Int = fieldLimit) -> String {
        let filtered = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
        }
        let collapsed = String(String.UnicodeScalarView(filtered))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return "—" }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

/// 自动切换通知服务：默认关闭，偏好存 `UserDefaults`，只有用户开启才请求授权。
@MainActor
final class AutoFallbackNotificationService: ObservableObject {
    static let shared = AutoFallbackNotificationService()

    static let preferenceKey = "autoFallbackNotificationsEnabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var authorization: NotificationAuthorization = .notDetermined
    @Published private(set) var deliveryError: String?

    private let defaults: UserDefaults
    private let injectedClient: AutoFallbackNotificationClient?
    /// 懒创建：static/shared 初始化不触碰系统通知中心。
    private lazy var client: AutoFallbackNotificationClient = injectedClient ?? SystemAutoFallbackNotificationClient()

    private var authorizationLoaded = false
    private var statusTask: Task<NotificationAuthorization, Never>?
    /// 每次开关变更递增；使切开关前后仍在途的旧任务失效。
    private var enableGeneration = 0
    private var outstanding: [UUID: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard, client: AutoFallbackNotificationClient? = nil) {
        self.defaults = defaults
        self.injectedClient = client
        self.isEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? false
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        enableGeneration &+= 1
        defaults.set(enabled, forKey: Self.preferenceKey)
        Log.shared.log("autoFallbackNotifications: preference \(enabled ? "enabled" : "disabled")")
        if enabled {
            // 在入队时捕获 generation：on→off→on 时首个 on 任务即使晚于 Task 启动才执行，
            // 也会因 generation 过期而失效，不会重复发起授权请求。
            let generation = enableGeneration
            track { [weak self] in await self?.requestAuthorizationIfNeeded(generation: generation) }
        } else {
            deliveryError = nil   // 只抑制后续事件，不撤销系统已显示通知
        }
    }

    /// App 启动/激活时调用；仅开关开启才刷新权限缓存。
    func activate() {
        guard isEnabled else { return }
        track { [weak self] in _ = await self?.currentAuthorization() }
    }

    /// 面板 onAppear/didBecomeActive 调用；只查询状态，不请求授权。
    func refreshAuthorization() async {
        _ = await currentAuthorization()
    }

    /// 由 `RouterServer.onAutoFallback` 经 MainActor 派发；关闭时同步丢弃。
    func receive(_ event: AutoFallbackEvent) {
        guard isEnabled else { return }
        let title = AutoFallbackNotificationContent.title
        let body = AutoFallbackNotificationContent.body(for: event)
        // 每次事件唯一 id：同一 requestID 的连续切换不能让系统互相替换。
        let identifier = "\(event.requestID.uuidString)-\(UUID().uuidString)"
        let needsStatusQuery = !authorizationLoaded
        let generation = enableGeneration
        track { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            let status = needsStatusQuery ? await self.currentAuthorization() : self.authorization
            guard self.isCurrent(generation), status.allowsDelivery else { return }
            do {
                try await self.client.deliver(title: title, body: body, identifier: identifier)
                guard self.isCurrent(generation) else { return }
                self.deliveryError = nil
            } catch {
                Log.shared.log("autoFallbackNotifications: 投递失败: \(error)")
                guard self.isCurrent(generation) else { return }
                self.deliveryError = "通知发送失败：\(error.localizedDescription)"
                await self.refreshAuthorization()
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { isEnabled && generation == enableGeneration }

    /// 合并并发的 settings 查询；绝不请求授权。
    private func currentAuthorization() async -> NotificationAuthorization {
        if let statusTask { return await statusTask.value }
        let task = Task { @MainActor in await self.client.authorizationStatus() }
        statusTask = task
        let status = await task.value
        statusTask = nil
        authorization = status
        authorizationLoaded = true
        return status
    }

    private func requestAuthorizationIfNeeded(generation: Int) async {
        guard isCurrent(generation) else { return }
        var status = await currentAuthorization()
        guard isCurrent(generation) else { return }
        if status == .notDetermined {
            status = await client.requestAuthorization()
            guard isCurrent(generation) else { return }
            authorization = status
            authorizationLoaded = true
        }
        if !status.allowsDelivery {
            Log.shared.log("autoFallbackNotifications: 系统未授权（\(status)），偏好保持开启但不投递")
        }
    }

    private func track(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        let task = Task { @MainActor in
            await operation()
            self.outstanding[id] = nil
        }
        outstanding[id] = task
    }

    /// 测试用：等待全部在途任务结束。
    func waitForOutstandingWork() async {
        while let task = outstanding.values.first { await task.value }
    }
}
