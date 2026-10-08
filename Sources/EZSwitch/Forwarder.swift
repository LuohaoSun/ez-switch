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
    /// 原始上游 usage 采集器（在 Responses→Chat 翻译之前喂入原始字节）。
    /// nil = 未采集。
    var usage: UsageAccumulator? = nil
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
        let upstreamEndpoint: EndpointKind = endpoint == .responses && remote.apiEndpoints.responsesTransport == .chatCompletions ? .chat : endpoint
        guard remote.apiEndpoints[upstreamEndpoint].enabled else {
            throw ForwarderError.endpointDisabled(upstreamEndpoint)
        }
        guard !remote.apiEndpoints[upstreamEndpoint].baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ForwarderError.missingEndpointBaseURL(endpoint)
        }
        guard let url = upstreamURL(remote: remote, endpoint: upstreamEndpoint, query: query) else {
            throw ForwarderError.badResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = clientHead.method.rawValue
        // 关键：把 fake model id 换成远端真实 model id，其余字段原样保留
        var upstreamBody = rewriteModel(body, to: remote.model)
        // 流式 Chat：请求上游在最后一个 chunk 附带 usage（不改响应，只改这一处请求字段）
        if upstreamEndpoint == .chat {
            upstreamBody = enablingStreamUsage(upstreamBody)
        }
        req.httpBody = upstreamBody

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

        if url.host == "opencode.ai", url.path.hasPrefix("/zen/go/v1/") {
            // Go uses a per-conversation session for routing/cache; a static provider header would mix conversations.
            for name in ["x-opencode-session", "x-opencode-request", "x-opencode-client", "x-opencode-project"] {
                if let value = h.first(name: name) { req.setValue(value, forHTTPHeaderField: name) }
            }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            req.setValue(h.first(name: "user-agent") ?? "EZSwitch/\(version)", forHTTPHeaderField: "user-agent")
        }

        for (k, v) in remote.extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    /// 建请求 → 发出去 → 等第一版响应头 → 返回 (响应, 流, cancel)。
    /// `session` 可注入（测试用 mock），默认走生产单例。
    static func makeRequest(clientHead: HTTPRequestHead, body: Data,
                            endpoint: EndpointKind, remote: RemoteModel,
                            query: String, session: URLSession = Forwarder.session) async throws -> UpstreamResponse {
        let upstreamEndpoint: EndpointKind = endpoint == .responses
            && remote.apiEndpoints.responsesTransport == .chatCompletions ? .chat : endpoint
        var req = try buildRequest(clientHead: clientHead, body: body,
                                   endpoint: endpoint, remote: remote, query: query)
        if endpoint == .responses, remote.apiEndpoints.responsesTransport == .chatCompletions {
            let translator = try ResponseTranslator()
            do {
                let translated = try await translator.prepare(body, model: remote.model)
                req.httpBody = enablingStreamUsage(translated)
                let upstream = try await perform(req, session: session)
                guard (200..<300).contains(upstream.response.statusCode) else {
                    translator.stop()
                    return accumulating(upstream, endpoint: upstreamEndpoint)
                }
                return translatedResponse(accumulating(upstream, endpoint: upstreamEndpoint), translator: translator)
            } catch {
                translator.stop()
                throw error
            }
        }
        return accumulating(try await perform(req, session: session), endpoint: upstreamEndpoint)
    }

    /// 在原始上游字节流上做 usage 采集（先于 Responses→Chat 翻译），每个 chunk
    /// 原样透传，不改变时序、不重复消费。
    private static func accumulating(_ upstream: UpstreamResponse, endpoint: EndpointKind) -> UpstreamResponse {
        let parser = UsageAccumulator(endpoint: endpoint,
                                      contentType: upstream.response.value(forHTTPHeaderField: "content-type"))
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        let producer = Task {
            do {
                for try await chunk in upstream.body {
                    parser.ingest(chunk)
                    continuation.yield(chunk)
                }
                parser.finish()
                continuation.finish()
            } catch {
                parser.finish()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            producer.cancel()
            upstream.cancel()
        }
        return UpstreamResponse(response: upstream.response, body: stream,
                                cancel: { producer.cancel(); upstream.cancel() },
                                usage: parser)
    }

    /// 流式 Chat 请求附带 usage：仅在 body 为 `"stream":true` 且 `stream_options`
    /// 未显式给出 `include_usage` 时补 `include_usage:true`；已有键与显式取值
    /// （含 `false`）一律不覆盖，其他请求行为不变。
    static func enablingStreamUsage(_ body: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["stream"] as? Bool == true else { return body }
        if let options = object["stream_options"] as? [String: Any] {
            guard options["include_usage"] == nil else { return body }
            var merged = options
            merged["include_usage"] = true
            object["stream_options"] = merged
        } else if object["stream_options"] == nil {
            object["stream_options"] = ["include_usage": true]
        } else {
            // stream_options 存在但不是对象：保持原样，别破坏包体
            return body
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? body
    }

    private static func perform(_ req: URLRequest, session: URLSession) async throws -> UpstreamResponse {
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        let bridge = UpstreamBridge(continuation: continuation)
        let task = session.dataTask(with: req)
        task.delegate = bridge
        // 消费端终止（客户端断开 / 提前 break）→ 停掉上游，别白烧 token
        continuation.onTermination = { _ in task.cancel() }
        task.resume()

        // 取消也必须立刻结束这条流：仅 `task.cancel()` 时 URLSession 可能不马上
        // 回调 didComplete，挂起在 next() 的消费端就醒不过来（客户端已断开仍继续
        // 消费/计费）。显式 finish 一次，让上层迭代器立即返回；重复 finish 是 no-op。
        let cancel: @Sendable () -> Void = {
            task.cancel()
            continuation.finish(throwing: CancellationError())
        }

        do {
            let response = try await withTaskCancellationHandler {
                try await bridge.response()
            } onCancel: { task.cancel() }
            return UpstreamResponse(response: response, body: stream, cancel: cancel)
        } catch {
            task.cancel()
            throw error
        }
    }

    private static func translatedResponse(_ upstream: UpstreamResponse, translator: ResponseTranslator) -> UpstreamResponse {
        let isSSE = (upstream.response.value(forHTTPHeaderField: "content-type") ?? "")
            .lowercased().contains("text/event-stream")
        var headers: [String: String] = [:]
        for (key, value) in upstream.response.allHeaderFields {
            guard let name = key as? String, let value = value as? String,
                  !droppedResponseHeaders.contains(name.lowercased()) else { continue }
            headers[name] = value
        }
        for name in headers.keys where name.lowercased() == "content-type" { headers.removeValue(forKey: name) }
        headers["Content-Type"] = isSSE ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: upstream.response.url!, statusCode: upstream.response.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        let producer = Task {
            defer { translator.stop() }
            do {
                var buffered = Data()
                for try await chunk in upstream.body {
                    try Task.checkCancellation()
                    let data = Data(chunk.readableBytesView)
                    if isSSE {
                        for block in try await translator.consume(data) {
                            var buffer = ByteBufferAllocator().buffer(capacity: block.count)
                            buffer.writeBytes(block)
                            continuation.yield(buffer)
                        }
                    } else {
                        buffered.append(data)
                        guard buffered.count <= 64 * 1024 * 1024 else {
                            throw ResponseTranslationError(description: "Chat response too large")
                        }
                    }
                }
                let blocks = isSSE ? try await translator.finish() : [try await translator.response(buffered)]
                for block in blocks {
                    var buffer = ByteBufferAllocator().buffer(capacity: block.count)
                    buffer.writeBytes(block)
                    continuation.yield(buffer)
                }
                continuation.finish()
            } catch {
                upstream.cancel()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            producer.cancel()
            translator.stop()
            upstream.cancel()
        }
        return UpstreamResponse(response: response, body: stream, cancel: {
            producer.cancel()
            translator.stop()
            upstream.cancel()
        }, usage: upstream.usage)
    }

    static let droppedResponseHeaders: Set<String> = [
        "content-length",      // 我们用 chunked 重构
        "content-encoding",    // URLSession 已解压，透传会让客户端二次解压
        "connection", "keep-alive", "transfer-encoding",
        "proxy-connection", "upgrade", "te", "trailer",
    ]
}
