import Foundation

/// 一次上游失败应当如何影响路由。
enum FallbackDisposition: Equatable {
    /// 换下一个候选，并让该远端进入冷却（问题出在这个远端身上）。
    case switchAndCool
    /// 换下一个候选，但不冷却、不清首选（这次请求不合它的胃口，远端本身没病）。
    case switchOnly
    /// 不换：已经成功。
    case none
}

/// 自动回退的触发条件。判据只有一句：**只要不是成功，就换下一个候选**。
///
/// 之所以不挑状态码：路由器在客户端这一侧，分不清“这家供应商今天挑剔”还是
/// “这个请求真的写错了”。同一份 body 被 A 家拒绝、被 B 家接受是常态，
/// 分不清时多试一次的成本（几秒 + 一条尝试记录）远小于用户卡住的成本。
///
/// 唯一要分叉的是**谁背锅**，它决定要不要把这个远端暂时拉黑：
/// - 远端侧失败（鉴权、模型不存在、限流、过载、网关错误…）→ 冷却，让它歇一会儿；
/// - 请求侧失败（请求体不合法、太大、媒体类型不支持…）→ 只跳过这一次。
///
/// 后者不冷却的理由很实在：一条超长上下文的请求若让整条路由的候选全部进冷却，
/// 后面几十条正常请求的起点都会被这条坏请求带跑。一条坏请求不该惩罚整条路由。
enum FallbackPolicy {
    /// 请求侧的 4xx：能确定是“这份请求不对”，远端换谁都一样被拒，但也不该被记恨。
    static let requestSideStatusCodes: Set<Int> = [400, 409, 413, 415, 422, 431]

    /// 认证类失败：key 失效、没额度、没权限、地区被拦。回退到备用是路由器该干的事，
    /// 但这种失败一旦被记成新首选，用户修好凭据后路由也不会自动切回去。
    static func isCredentialFailure(_ status: Int) -> Bool {
        status == 401 || status == 403
    }

    static func disposition(forStatus status: Int) -> FallbackDisposition {
        if (200..<300).contains(status) { return .none }
        // 3xx 不由 URLSession 处理掉而漏到这一层，说明这家行为不合预期；
        // 换下一个，但不是它“坏了”，不冷却。
        if (300..<400).contains(status) { return .switchOnly }
        return requestSideStatusCodes.contains(status) ? .switchOnly : .switchAndCool
    }

    /// 没有响应头（DNS／TLS／连接被拒／超时／代理不可达）一律按远端侧处理。
    static let connectionFailure: FallbackDisposition = .switchAndCool

    /// 默认冷却：既没有 Retry-After、也没法解析时用它。
    static let defaultCooldown: TimeInterval = 60
    /// 冷却区间。下限 1 秒防止上游报 0 导致等于没冷却；上限 5 分钟防止
    /// 一个异常大的 Retry-After 把远端锁太久。
    static let cooldownRange: ClosedRange<TimeInterval> = 1...300

    /// 按 `Retry-After` 算冷却时长：支持秒数与 HTTP-date，缺省或不可解析用默认值，
    /// 结果夹在 ``cooldownRange`` 内。
    static func cooldown(retryAfterHeader: String?, now: Date = Date()) -> TimeInterval {
        guard let raw = retryAfterHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return defaultCooldown }
        var seconds: TimeInterval?
        if let value = TimeInterval(raw) {
            seconds = value
        } else if let date = httpDate(raw) {
            seconds = date.timeIntervalSince(now)
        }
        guard let seconds, seconds.isFinite else { return defaultCooldown }
        return min(max(seconds, cooldownRange.lowerBound), cooldownRange.upperBound)
    }

    /// 冷却截止时间；没有响应（连接失败）时用 ``defaultCooldown``。
    static func cooldownDeadline(response: HTTPURLResponse?, now: Date = Date()) -> Date {
        now.addingTimeInterval(cooldown(retryAfterHeader: response?.value(forHTTPHeaderField: "retry-after"),
                                        now: now))
    }

    /// `Retry-After` 的 HTTP-date 形式（RFC 7231 IMF-fixdate）。
    private static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }
}
