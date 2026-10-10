import Foundation

/// 一次自动回退的“即将真正开始下一个候选”事件：上一次 attempt 失败、且确实还有
/// 下一个候选可尝试时发一次；冷却过滤、候选耗尽、取消、客户端错误及已开始响应都不发。
struct AutoFallbackEvent: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// 上游返回可重试的 HTTP 状态码（429 / 5xx），仅带数值。
        case httpStatus(Int)
        /// 连接失败（未拿到响应头）。
        case connectionFailure
    }

    /// 与 usage 记录同源的请求 id，便于把通知和某次请求对应起来。
    let requestID: UUID
    /// 客户端请求的 fake model id（== 路由名）。
    let route: String
    /// 上一个候选的展示名（RemoteModel.routeLabel）。
    let from: String
    /// 下一个候选的展示名（RemoteModel.routeLabel）。
    let to: String
    let reason: Reason
}
