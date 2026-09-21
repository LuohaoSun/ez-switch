import Foundation
import NIOCore
import NIOHTTP1

enum ForwarderError: Error, CustomStringConvertible {
    case badResponse
    case finishedWithoutResponse
    case endpointDisabled(EndpointKind)
    case missingEndpointBaseURL(EndpointKind)

    var description: String {
        switch self {
        case .badResponse: return "upstream returned a non-HTTP response"
        case .finishedWithoutResponse: return "upstream finished before sending a response head"
        case .endpointDisabled(let kind): return "upstream does not enable \(kind.displayName)"
        case .missingEndpointBaseURL(let kind): return "upstream has no Base URL for \(kind.displayName)"
        }
    }
}

/// 上游响应：状态行/头 + 字节流 + 主动取消入口
struct UpstreamResponse {
    let response: HTTPURLResponse
    let body: AsyncThrowingStream<ByteBuffer, Error>
    let cancel: @Sendable () -> Void
}

/// URLSession 数据回调 → AsyncThrowingStream<ByteBuffer> 的桥。
/// 每个上游 chunk 原样 yield，保证逐块 writeAndFlush 的打字机延迟。
final class UpstreamBridge: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var pendingResponse: Result<HTTPURLResponse, Error>?
    private var responseDelivered = false

    init(continuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation) {
        self.continuation = continuation
        super.init()
    }

    /// 等响应头。delegate 可能先于 await 到达 → 用 pendingResponse 兜住。
    func response() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let pending = pendingResponse {
                pendingResponse = nil
                responseDelivered = true
                lock.unlock()
                cont.resume(with: pending)
                return
            }
            responseContinuation = cont
            lock.unlock()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completeResponse(with: .failure(ForwarderError.badResponse))
            completionHandler(.cancel)
            return
        }
        completeResponse(with: .success(http))
        completionHandler(.allow)
    }

    /// 不跟 3xx：保持"纯透传"，别把中间响应头当成最终响应
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var buf = ByteBufferAllocator().buffer(capacity: data.count)
        buf.writeBytes(data)
        continuation.yield(buf)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completeResponse(with: .failure(error))
            continuation.finish(throwing: error)
        } else {
            // 正常结束但没有响应头（理论上不会）
            completeResponse(with: .failure(ForwarderError.finishedWithoutResponse))
            continuation.finish()
        }
    }

    private func completeResponse(with result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        if responseDelivered || pendingResponse != nil {
            lock.unlock()
            return
        }
        if let waiter = responseContinuation {
            responseContinuation = nil
            responseDelivered = true
            lock.unlock()
            waiter.resume(with: result)
        } else {
            pendingResponse = result
            lock.unlock()
        }
    }
}

enum Forwarder {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3600
        cfg.timeoutIntervalForResource = 7200
        // 直连：忽略 macOS 系统代理。本机代理不可达时 URLSession 会 -1004 连不上上游
        cfg.connectionProxyDictionary = [:]
        return URLSession(configuration: cfg)
    }()

    /// 上游 URL：供应商为当前协议配置的完整 Base URL 前缀 + 协议相对路径 + 原 query
    static func upstreamURL(remote: RemoteModel, endpoint: EndpointKind, query: String) -> URL? {
        let setting = remote.apiEndpoints[endpoint]
        guard setting.enabled else { return nil }
        var base = setting.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        var s = base + endpoint.upstreamPath
        if !query.isEmpty { s += "?" + query }
        return URL(string: s)
    }

    /// 只改 model 字段，其它字段靠 JSONSerialization 原样保留（含 harness 自定义字段）
    static func rewriteModel(_ data: Data, to model: String) -> Data {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }
        var mutable = obj
        mutable["model"] = model
        return (try? JSONSerialization.data(withJSONObject: mutable)) ?? data
    }

    static func buildRequest(clientHead: HTTPRequestHead, body: Data,
                             endpoint: EndpointKind, remote: RemoteModel, query: String) throws -> URLRequest {
        guard remote.apiEndpoints[endpoint].enabled else {
            throw ForwarderError.endpointDisabled(endpoint)
        }
        guard !remote.apiEndpoints[endpoint].baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ForwarderError.missingEndpointBaseURL(endpoint)
        }
        guard let url = upstreamURL(remote: remote, endpoint: endpoint, query: query) else {
            throw ForwarderError.badResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = clientHead.method.rawValue
        // 关键：把 fake model id 换成远端真实 model id，其余字段原样保留
        req.httpBody = rewriteModel(body, to: remote.model)

        let h = clientHead.headers
        req.setValue(h.first(name: "content-type") ?? "application/json", forHTTPHeaderField: "content-type")
        if let accept = h.first(name: "accept") {
            req.setValue(accept, forHTTPHeaderField: "accept")
        }

        switch endpoint {
        case .chat, .responses:
            req.setValue("Bearer \(remote.apiKey)", forHTTPHeaderField: "authorization")
        case .messages:
            req.setValue(remote.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue(h.first(name: "anthropic-version") ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
            let betas = h[canonicalForm: "anthropic-beta"]
            if !betas.isEmpty {
                req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
            }
        }

        for (k, v) in remote.extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    /// 建请求 → 发出去 → 等第一版响应头 → 返回 (响应, 流, cancel)
    static func makeRequest(clientHead: HTTPRequestHead, body: Data,
                            endpoint: EndpointKind, remote: RemoteModel,
                            query: String) async throws -> UpstreamResponse {
        let req = try buildRequest(clientHead: clientHead, body: body,
                                   endpoint: endpoint, remote: remote, query: query)
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        let bridge = UpstreamBridge(continuation: continuation)
        let task = session.dataTask(with: req)
        task.delegate = bridge
        // 消费端终止（客户端断开 / 提前 break）→ 停掉上游，别白烧 token
        continuation.onTermination = { _ in task.cancel() }
        task.resume()

        do {
            let response = try await bridge.response()
            return UpstreamResponse(response: response, body: stream, cancel: { task.cancel() })
        } catch {
            task.cancel()
            throw error
        }
    }

    static let droppedResponseHeaders: Set<String> = [
        "content-length",      // 我们用 chunked 重构
        "content-encoding",    // URLSession 已解压，透传会让客户端二次解压
        "connection", "keep-alive", "transfer-encoding",
        "proxy-connection", "upgrade", "te", "trailer",
    ]
}
