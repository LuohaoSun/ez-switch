import Foundation
import Testing
@testable import EZSwitch

/// `FallbackPolicy` 的两问：要不要换下一个候选、要不要把这个远端拉黑一会儿。
@Suite("Fallback policy")
struct FallbackPolicyTests {
    // MARK: 换不换

    @Test func successNeverFallsBack() {
        #expect(FallbackPolicy.disposition(forStatus: 200) == .none)
        #expect(FallbackPolicy.disposition(forStatus: 204) == .none)
        #expect(FallbackPolicy.disposition(forStatus: 299) == .none)
    }

    /// 除成功外一律换下一个候选，包括以前被排除的 4xx。
    @Test func everyFailureFallsBack() {
        let statuses = [301, 400, 401, 402, 403, 404, 405, 408, 409, 413, 415, 422,
                        429, 431, 451, 500, 502, 503, 504, 505, 529]
        for status in statuses {
            #expect(FallbackPolicy.disposition(forStatus: status) != .none, "status \(status)")
        }
    }

    // MARK: 谁背锅

    /// 请求侧：这份请求不合它胃口，远端本身没病 → 只跳过这一次，不冷却。
    @Test func requestSideFailuresSkipWithoutCooldown() {
        for status in FallbackPolicy.requestSideStatusCodes {
            #expect(FallbackPolicy.disposition(forStatus: status) == .switchOnly, "status \(status)")
        }
    }

    /// 远端侧：key 死了、模型下线、限流、过载、网关坏了 → 换人并让它歇一会儿。
    @Test func remoteSideFailuresCoolTheRemote() {
        let statuses = [401, 402, 403, 404, 405, 408, 429, 451,
                        500, 502, 503, 504, 505, 529, 599]
        for status in statuses {
            #expect(FallbackPolicy.disposition(forStatus: status) == .switchAndCool, "status \(status)")
        }
    }

    @Test func redirectsAreSkippedButNotBlamed() {
        #expect(FallbackPolicy.disposition(forStatus: 302) == .switchOnly)
    }

    @Test func credentialFailuresAreIdentified() {
        #expect(FallbackPolicy.isCredentialFailure(401))
        #expect(FallbackPolicy.isCredentialFailure(403))
        #expect(!FallbackPolicy.isCredentialFailure(402))
        #expect(!FallbackPolicy.isCredentialFailure(404))
        #expect(!FallbackPolicy.isCredentialFailure(429))
        #expect(!FallbackPolicy.isCredentialFailure(500))
    }

    // MARK: 冷却时长

    @Test func missingRetryAfterUsesDefault() {
        #expect(FallbackPolicy.cooldown(retryAfterHeader: nil) == 60)
        #expect(FallbackPolicy.cooldown(retryAfterHeader: "") == 60)
        #expect(FallbackPolicy.cooldown(retryAfterHeader: "  ") == 60)
        #expect(FallbackPolicy.cooldown(retryAfterHeader: "soon") == 60)
    }

    @Test func retryAfterSecondsIsHonored() {
        #expect(FallbackPolicy.cooldown(retryAfterHeader: "120") == 120)
        #expect(FallbackPolicy.cooldown(retryAfterHeader: " 30 ") == 30)
    }

    /// 夹在 1–300 秒：0 等于没冷却，异常大的值会把远端锁太久。
    @Test func retryAfterIsClamped() {
        #expect(FallbackPolicy.cooldown(retryAfterHeader: "0") == 1)
        #expect(FallbackPolicy.cooldown(retryAfterHeader: "-30") == 1)
        #expect(FallbackPolicy.cooldown(retryAfterHeader: "3600") == 300)
    }

    @Test func retryAfterHTTPDateIsConverted() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // now + 90 秒的 IMF-fixdate 形式。
        let target = Date(timeIntervalSince1970: 1_700_000_090)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: target)
        #expect(FallbackPolicy.cooldown(retryAfterHeader: header, now: now) == 90)
        // 已经过去的时间同样被夹到下限。
        #expect(FallbackPolicy.cooldown(retryAfterHeader: header,
                                        now: target.addingTimeInterval(600)) == 1)
    }

    @Test func cooldownDeadlineReadsResponseHeader() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://fail.test/v1/chat/completions")!
        let limited = HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1",
                                      headerFields: ["Retry-After": "45"])!
        #expect(FallbackPolicy.cooldownDeadline(response: limited, now: now) == now.addingTimeInterval(45))

        let plain = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1",
                                    headerFields: [:])!
        #expect(FallbackPolicy.cooldownDeadline(response: plain, now: now) == now.addingTimeInterval(60))
        #expect(FallbackPolicy.cooldownDeadline(response: nil, now: now) == now.addingTimeInterval(60))
    }
}
