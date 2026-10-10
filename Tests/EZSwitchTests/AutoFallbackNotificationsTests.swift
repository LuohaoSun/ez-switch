import Foundation
import Testing
@testable import EZSwitch

/// 记录一次投递的最小结构（跨 actor 边界用，避免裸元组）。
private struct DeliveredNotification: Sendable, Equatable {
    let title: String
    let body: String
    let identifier: String
}

/// 可注入的通知 client；绝不触碰 `UNUserNotificationCenter.current()`。
private actor FakeNotificationClient: AutoFallbackNotificationClient {
    private var status: NotificationAuthorization
    private var statusAfterRequest: NotificationAuthorization
    private var deliveredNotifications: [DeliveredNotification] = []
    private var requestCount = 0
    private var deliverError: Error?
    private var gated = false
    private var gate: CheckedContinuation<Void, Never>?
    private var requestStarted = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var statusGated = false
    private var statusGate: CheckedContinuation<Void, Never>?
    private var statusStarted = false
    private var statusStartedWaiter: CheckedContinuation<Void, Never>?

    init(status: NotificationAuthorization, statusAfterRequest: NotificationAuthorization? = nil) {
        self.status = status
        self.statusAfterRequest = statusAfterRequest ?? status
    }

    func setStatus(_ value: NotificationAuthorization) { status = value }
    func setDeliverError(_ error: Error?) { deliverError = error }
    /// 让下一次 `requestAuthorization` 挂起，便于测“请求返回前已关闭开关”的竞态。
    func gateNextRequest() { gated = true }
    /// 让下一次 `authorizationStatus` 挂起，便于测切开关期间旧事件的状态查询。
    func gateNextStatusQuery() { statusGated = true }

    func authorizationStatus() async -> NotificationAuthorization {
        statusStarted = true
        statusStartedWaiter?.resume()
        statusStartedWaiter = nil
        if statusGated {
            await withCheckedContinuation { statusGate = $0 }
        }
        return status
    }

    func releaseStatusQuery() {
        statusGated = false
        statusGate?.resume()
        statusGate = nil
    }

    func waitUntilStatusQueryStarted() async {
        if statusStarted { return }
        await withCheckedContinuation { statusStartedWaiter = $0 }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        requestCount += 1
        requestStarted = true
        startedWaiter?.resume()
        startedWaiter = nil
        if gated {
            await withCheckedContinuation { gate = $0 }
        }
        return statusAfterRequest
    }

    func releaseRequest() {
        gated = false
        gate?.resume()
        gate = nil
    }

    func waitUntilRequestStarted() async {
        if requestStarted { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func deliver(title: String, body: String, identifier: String) async throws {
        if let deliverError { throw deliverError }
        deliveredNotifications.append(DeliveredNotification(title: title, body: body, identifier: identifier))
    }

    var delivered: [DeliveredNotification] { deliveredNotifications }
    var authorizationRequestCount: Int { requestCount }
}

@Suite("Auto fallback notifications")
@MainActor
struct AutoFallbackNotificationsTests {
    private let key = AutoFallbackNotificationService.preferenceKey

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "AutoFallbackNotificationsTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func event(_ requestID: UUID = UUID(), route: String = "main",
                       from: String = "A · a", to: String = "B · b",
                       reason: AutoFallbackEvent.Reason = .httpStatus(429)) -> AutoFallbackEvent {
        AutoFallbackEvent(requestID: requestID, route: route, from: from, to: to, reason: reason)
    }

    @Test("默认关闭")
    func disabledByDefault() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AutoFallbackNotificationService(defaults: defaults,
                                                      client: FakeNotificationClient(status: .authorized))
        #expect(service.isEnabled == false)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test("开启后写入 UserDefaults 并可跨实例恢复")
    func preferencePersists() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AutoFallbackNotificationService(defaults: defaults,
                                                      client: FakeNotificationClient(status: .authorized))
        service.setEnabled(true)
        await service.waitForOutstandingWork()
        #expect(defaults.object(forKey: key) as? Bool == true)

        let reloaded = AutoFallbackNotificationService(defaults: defaults,
                                                      client: FakeNotificationClient(status: .authorized))
        #expect(reloaded.isEnabled)
    }

    @Test("授权请求只由用户开启开关触发")
    func authorizationPromptOnlyOnUserAction() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeNotificationClient(status: .notDetermined, statusAfterRequest: .authorized)
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)

        var count = await client.authorizationRequestCount
        #expect(count == 0)

        service.setEnabled(true)
        await service.waitForOutstandingWork()
        count = await client.authorizationRequestCount
        #expect(count == 1)

        // 启动 / 面板刷新只查询状态，不再请求授权
        service.activate()
        await service.waitForOutstandingWork()
        await service.refreshAuthorization()
        count = await client.authorizationRequestCount
        #expect(count == 1)
    }

    @Test("已授权：每次真实切换投递一条，identifier 用事件 requestID（不做 route 覆盖）")
    func authorizedDeliversUniqueNotifications() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeNotificationClient(status: .authorized)
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)
        service.setEnabled(true)
        await service.waitForOutstandingWork()

        let first = event(to: "B · b", reason: .httpStatus(429))
        let second = event(to: "C · c", reason: .connectionFailure)   // 同 route，不同 requestID
        service.receive(first)
        service.receive(second)
        await service.waitForOutstandingWork()

        let delivered = await client.delivered
        #expect(delivered.count == 2)
        #expect(delivered[0].identifier != delivered[1].identifier)
        #expect(delivered[0].identifier.hasPrefix(first.requestID.uuidString))
        #expect(delivered[1].identifier.hasPrefix(second.requestID.uuidString))
    }

    @Test("同一 requestID 的连续两次切换各投递一条，identifier 不同（不被系统替换）")
    func sameRequestDeliversDistinctNotifications() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeNotificationClient(status: .authorized)
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)
        service.setEnabled(true)
        await service.waitForOutstandingWork()

        let requestID = UUID()
        service.receive(event(requestID, to: "B · b", reason: .httpStatus(429)))
        service.receive(event(requestID, to: "C · c", reason: .httpStatus(500)))
        await service.waitForOutstandingWork()

        let delivered = await client.delivered
        #expect(delivered.count == 2)
        #expect(delivered[0].identifier != delivered[1].identifier)
        #expect(delivered.allSatisfy { $0.identifier.hasPrefix(requestID.uuidString) })
    }

    @Test("切开关前后在途的旧事件不投递（enable generation）")
    func staleEventAfterRapidToggleIsDropped() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: key)
        let client = FakeNotificationClient(status: .authorized)
        await client.gateNextStatusQuery()
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)

        service.receive(event())                 // 缓存未就绪 → 挂起在 settings 查询
        await client.waitUntilStatusQueryStarted()
        service.setEnabled(false)
        service.setEnabled(true)
        await client.releaseStatusQuery()
        await service.waitForOutstandingWork()

        let delivered = await client.delivered
        #expect(delivered.isEmpty)
        #expect(service.isEnabled)
    }

    @Test("同步 on→off→on 只发起一次授权请求（generation 在入队时捕获）")
    func rapidToggleRequestsAuthorizationOnce() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeNotificationClient(status: .notDetermined, statusAfterRequest: .authorized)
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)

        service.setEnabled(true)
        service.setEnabled(false)
        service.setEnabled(true)
        await service.waitForOutstandingWork()

        let count = await client.authorizationRequestCount
        #expect(count == 1)
        #expect(service.isEnabled)
    }

    @Test("系统拒绝：不投递")
    func deniedDoesNotDeliver() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeNotificationClient(status: .notDetermined, statusAfterRequest: .denied)
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)
        service.setEnabled(true)
        await service.waitForOutstandingWork()

        service.receive(event())
        await service.waitForOutstandingWork()

        #expect(service.authorization == .denied)
        let delivered = await client.delivered
        #expect(delivered.isEmpty)
    }

    @Test("请求授权返回前关闭开关：偏好不被旧任务反转、不投递")
    func disablingDuringAuthorizationDoesNotFlipPreference() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeNotificationClient(status: .notDetermined, statusAfterRequest: .authorized)
        await client.gateNextRequest()
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)

        service.setEnabled(true)
        await client.waitUntilRequestStarted()
        service.setEnabled(false)
        await client.releaseRequest()
        await service.waitForOutstandingWork()

        #expect(service.isEnabled == false)
        #expect(defaults.object(forKey: key) as? Bool == false)
        let delivered = await client.delivered
        #expect(delivered.isEmpty)
    }

    @Test("关闭立即抑制后续事件，且不取消已显示通知（不调用 remove*）")
    func disablingStopsFutureDelivery() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeNotificationClient(status: .authorized)
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)
        service.setEnabled(true)
        await service.waitForOutstandingWork()

        service.receive(event())
        await service.waitForOutstandingWork()
        var delivered = await client.delivered
        #expect(delivered.count == 1)

        service.setEnabled(false)
        service.receive(event())
        await service.waitForOutstandingWork()
        delivered = await client.delivered
        #expect(delivered.count == 1)
    }

    @Test("启动即开启偏好：首个切换事件不会被静默丢弃（补一次状态查询）")
    func firstEventAfterLaunchBootstrapsStatus() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: key)
        let client = FakeNotificationClient(status: .authorized)
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)
        #expect(service.isEnabled)

        // 缓存尚未加载就到达事件
        service.receive(event())
        await service.waitForOutstandingWork()

        let delivered = await client.delivered
        #expect(delivered.count == 1)
        #expect(service.authorization == .authorized)
    }

    @Test("系统设置恢复授权后刷新即可再次投递")
    func refreshPicksUpRecoveredPermission() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeNotificationClient(status: .denied)
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)
        service.setEnabled(true)
        await service.waitForOutstandingWork()

        service.receive(event())
        await service.waitForOutstandingWork()
        var delivered = await client.delivered
        #expect(delivered.isEmpty)

        await client.setStatus(.authorized)
        await service.refreshAuthorization()
        #expect(service.authorization == .authorized)

        service.receive(event())
        await service.waitForOutstandingWork()
        delivered = await client.delivered
        #expect(delivered.count == 1)
    }

    @Test("投递失败清晰暴露，不静默")
    func deliveryFailureIsSurfaced() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeNotificationClient(status: .authorized)
        let service = AutoFallbackNotificationService(defaults: defaults, client: client)
        service.setEnabled(true)
        await service.waitForOutstandingWork()
        await client.setDeliverError(URLError(.notConnectedToInternet))

        service.receive(event())
        await service.waitForOutstandingWork()

        #expect(service.deliveryError != nil)
    }

    @Test("文案：标题、正在尝试措辞、原因数值化、控制字符过滤")
    func contentIsDescriptiveAndPrivate() {
        let sample = event(route: "main", from: "OpenAI · gpt\n4", to: "Anthropic · claude-3",
                           reason: .httpStatus(429))
        let body = AutoFallbackNotificationContent.body(for: sample)
        #expect(AutoFallbackNotificationContent.title == "模型自动切换")
        #expect(body.hasPrefix("main："))
        #expect(body.contains("OpenAI · gpt4 → Anthropic · claude-3"))
        #expect(body.contains("HTTP 429"))
        #expect(body.contains("正在尝试 Anthropic · claude-3"))
        #expect(!body.contains("成功"))
        // 正文里唯一的换行只是“正在尝试”前的分隔，from/to 内的换行被清掉
        #expect(body.split(separator: "\n", omittingEmptySubsequences: false).count == 2)
        #expect(!body.contains("\u{0007}"))
    }

    @Test("文案：连接失败原因与字段清洗/截断")
    func contentReasonAndSanitize() {
        #expect(AutoFallbackNotificationContent.reasonText(.httpStatus(503)) == "HTTP 503")
        #expect(AutoFallbackNotificationContent.reasonText(.connectionFailure) == "连接失败")
        #expect(AutoFallbackNotificationContent.sanitize("a\nb\u{0007}c\td") == "abcd")
        #expect(AutoFallbackNotificationContent.sanitize("   ") == "—")

        let truncated = AutoFallbackNotificationContent.sanitize(String(repeating: "x", count: 200), limit: 40)
        #expect(truncated.count == 41)
        #expect(truncated.hasSuffix("…"))

        let body = AutoFallbackNotificationContent.body(for: event(reason: .connectionFailure))
        #expect(body.contains("连接失败"))
    }
}
