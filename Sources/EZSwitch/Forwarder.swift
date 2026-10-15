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

/// 非原生 HTTP 来源（扩展连接器或未知来源）不得走 HTTP 上游，即便配置里填了 URL。
/// 归类为客户端错误：请求本身无法被适配，应直接返回 400 且不回退。
struct ConnectorRoutingError: ClientRequestFailure, CustomStringConvertible {
    let source: RemoteSource
    var clientError: Bool { true }
    var description: String { "source '\(source.rawValue)' has no HTTP upstream" }
}

/// 上游响应：状态行/头 + 字节流 + 主动取消入口
struct UpstreamResponse {
    let response: HTTPURLResponse
    let body: AsyncThrowingStream<ByteBuffer, Error>
    let cancel: @Sendable () -> Void
    /// 原始上游 usage 采集器（在 Responses→Chat 翻译之前喂入原始字节）。
    /// nil = 未采集。
    var usage: UsageAccumulator? = nil
    /// 原始上游性能采集器（TTFT / generation / 语义 delta 计数），同样在翻译
    /// 之前的原始字节上喂入。nil = 未采集。
    var performance: PerformanceAccumulator? = nil
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

    /// 上游 URL：供应商为当前协议配置的完整 Base URL 前缀 + 协议相对路径 + 原 query。
    /// Gemini 的路径是 `{base}/models/{model}:{operation}`（见 `GeminiEndpoint`），
    /// 不存在静态后缀，故这里直接返回 nil，由 `buildRequest` 的 Gemini 分支处理。
    static func upstreamURL(remote: RemoteModel, endpoint: EndpointKind, query: String) -> URL? {
        guard endpoint != .gemini else { return nil }
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

    /// 客户端请求头里不应原样转发的名字（小写）：
    /// - hop-by-hop：连接层字段，逐跳有效，不属于端到端语义。
    /// - Host / Content-Length：URLSession 会依据真实 URL 与重写后的 body 重新生成，
    ///   转发客户端旧值会导致长度不符（body 我们改过 model / stream_options）。
    /// - 供应商鉴权头：客户端凭据（本机 harness 占位 token 等）不能泄露给上游，
    ///   必须由路由器按端点替换成远端 apiKey。
    /// - Accept-Encoding：URLSession 负责协商与透明解压（响应侧已丢弃 Content-Encoding），
    ///   手动设置会破坏其自动解压，故不转发。
    static let excludedRequestHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade",
        "host", "content-length",
        "authorization", "x-api-key", "api-key", "x-goog-api-key",
        "accept-encoding",
    ]

    /// Connection 头里逐个声明的字段同样是 hop-by-hop，需一并排除。
    static func hopByHopTokens(in headers: HTTPHeaders) -> Set<String> {
        var tokens: Set<String> = []
        for value in headers[canonicalForm: "connection"] {
            for token in value.split(separator: ",") {
                let name = token.trimmingCharacters(in: .whitespaces).lowercased()
                if !name.isEmpty { tokens.insert(name) }
            }
        }
        return tokens
    }

    static func buildRequest(clientHead: HTTPRequestHead, body: Data,
                             endpoint: EndpointKind, remote: RemoteModel,
                             adapter: ProtocolAdapter = .passthrough,
                             query: String) throws -> URLRequest {
        // 连接器请求没有 HTTP 上游（扩展自行构造响应），绝不能进入建 URL 路径。
        if case .connector(let source) = adapter {
            throw ConnectorRoutingError(source: source)
        }
        // 兜底：非原生 HTTP 来源即便调用方按默认 .passthrough 传入，也绝不用其 URL
        // 发起 HTTP —— 未知来源不会因“恰好有 URL”而变成 HTTP 上游。
        guard remote.source.isAPI else {
            throw ConnectorRoutingError(source: remote.source)
        }
        // Native Gemini has its own path/body/auth shaping derived from the client
        // URI; the generic base+suffix flow does not apply.
        if endpoint == .gemini {
            return try buildGeminiRequest(clientHead: clientHead, body: body, remote: remote)
        }
        let upstreamEndpoint: EndpointKind = adapter == .chatToResponses ? .chat : endpoint
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

        applyForwardedHeaders(&req, from: clientHead)

        switch endpoint {
        case .chat, .responses:
            req.setValue("Bearer \(remote.apiKey)", forHTTPHeaderField: "authorization")
        case .messages:
            req.setValue(remote.apiKey, forHTTPHeaderField: "x-api-key")
            // anthropic 默认版本：客户端显式带则原样透传，否则补默认值
            if req.value(forHTTPHeaderField: "anthropic-version") == nil {
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        case .gemini:
            break // 已在上方 Gemini 分支处理
        }

        if url.host == "opencode.ai", url.path.hasPrefix("/zen/go/v1/") {
            // Go uses a per-conversation session for routing/cache; 客户端会话头已在
            // 上方透传，这里只在客户端未提供 user-agent 时补 EZSwitch 默认值，
            // 绝不生成固定 session（否则会把不同会话混在一起）。
            if req.value(forHTTPHeaderField: "user-agent") == nil {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                req.setValue("EZSwitch/\(version)", forHTTPHeaderField: "user-agent")
            }
        }

        for (k, v) in remote.extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    /// 端到端透传客户端请求头：普通头（SDK/会话/自定义头…）原样转发，只剔除
    /// hop-by-hop、URLSession 接管的 Host/Content-Length/Accept-Encoding，以及必须
    /// 按端点替换的供应商鉴权头。重复出现的头由 URLRequest 逐值追加重建。
    private static func applyForwardedHeaders(_ req: inout URLRequest, from clientHead: HTTPRequestHead) {
        let h = clientHead.headers
        let excluded = excludedRequestHeaders.union(hopByHopTokens(in: h))
        for (name, value) in h {
            guard !excluded.contains(name.lowercased()) else { continue }
            req.addValue(value, forHTTPHeaderField: name)
        }
        if req.value(forHTTPHeaderField: "content-type") == nil {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        }
    }

    /// Gemini 原生请求：从 clientHead.uri 解析本地路由与操作，路径改写为真实模型，
    /// 生成类 body 逐字节透传（不重排、不 strip），countTokens 仅改写嵌套
    /// `generateContentRequest.model`；客户端 query 里的 `key` 已在解析时剔除，
    /// 上游鉴权一律用 `x-goog-api-key`（供应商 key）。
    private static func buildGeminiRequest(clientHead: HTTPRequestHead, body: Data,
                                           remote: RemoteModel) throws -> URLRequest {
        guard case .operation(let context)? = GeminiEndpoint.parse(uri: clientHead.uri, method: clientHead.method) else {
            throw ForwarderError.badResponse
        }
        guard remote.apiEndpoints[.gemini].enabled else {
            throw ForwarderError.endpointDisabled(.gemini)
        }
        let base = remote.apiEndpoints[.gemini].baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw ForwarderError.missingEndpointBaseURL(.gemini)
        }
        guard let url = GeminiEndpoint.upstreamURL(baseURL: base, realModel: remote.model, context: context) else {
            throw ForwarderError.badResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = clientHead.method.rawValue
        req.httpBody = context.isCountTokens
            ? GeminiEndpoint.rewriteCountTokensBody(body, realModel: remote.model)
            : body
        applyForwardedHeaders(&req, from: clientHead)
        // 客户端 x-goog-api-key 已在 excludedRequestHeaders 中剔除，这里替换为供应商 key。
        req.setValue(remote.apiKey, forHTTPHeaderField: "x-goog-api-key")
        for (k, v) in remote.extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    /// 建请求 → 发出去 → 等第一版响应头 → 返回 (响应, 流, cancel)。
    /// `session` 可注入（测试用 mock），默认走生产单例。
    /// `requestStart`/`attemptStart` 为路由器侧的单调起点（记录在最终 record
    /// 时换算成 ttft/requestTTFT）；nil = 不测 TTFT。
    /// `extensionRegistry` 提供已注册的连接器定义；非原生 HTTP 来源一律经它转发。
    static func makeRequest(clientHead: HTTPRequestHead, body: Data,
                            endpoint: EndpointKind, remote: RemoteModel,
                            adapter: ProtocolAdapter = .passthrough,
                            query: String, session: URLSession = Forwarder.session,
                            requestStart: DispatchTime? = nil,
                            attemptStart: DispatchTime? = nil,
                            extensionRegistry: ExtensionRegistry = .builtIn) async throws -> UpstreamResponse {
        // 连接器来源：无 HTTP 请求，交由 registry 中的扩展处理（校验/子进程/响应合成）。
        // 来源以 adapter 为准，但 adapter 与 remote.source 必须一致；若调用方省略 adapter
        // （默认 .passthrough）而远端是非 .api 来源，则按 source 委托，绝不掉进原生 HTTP。
        let connectorSource: RemoteSource?
        switch adapter {
        case .connector(let source):
            guard source == remote.source else { throw ConnectorRoutingError(source: source) }
            connectorSource = source
        case .passthrough, .chatToResponses:
            connectorSource = remote.source.isAPI ? nil : remote.source
        }
        if let source = connectorSource {
            return try await extensionRegistry.forward(
                ConnectorRequest(clientHead: clientHead, body: body, endpoint: endpoint,
                                 remote: remote, query: query,
                                 requestStart: requestStart, attemptStart: attemptStart),
                source: source)
        }
        let upstreamEndpoint: EndpointKind = adapter == .chatToResponses ? .chat : endpoint
        var req = try buildRequest(clientHead: clientHead, body: body,
                                   endpoint: endpoint, remote: remote, adapter: adapter, query: query)
        // countTokens 不做 usage/performance 采集：直接返回原始响应，不包 accumulating，
        // 使 upstream.usage/performance 保持 nil（Router 侧也零记账）。
        if endpoint == .gemini,
           case .operation(let context)? = GeminiEndpoint.parse(uri: clientHead.uri, method: clientHead.method),
           context.isCountTokens {
            return try await perform(req, session: session)
        }
        if adapter == .chatToResponses {
            let translator = try ResponseTranslator()
            do {
                let translated = try await translator.prepare(body, model: remote.model)
                req.httpBody = enablingStreamUsage(translated)
                let upstream = try await perform(req, session: session)
                guard (200..<300).contains(upstream.response.statusCode) else {
                    translator.stop()
                    return accumulating(upstream, endpoint: upstreamEndpoint,
                                        requestStart: requestStart, attemptStart: attemptStart)
                }
                return translatedResponse(accumulating(upstream, endpoint: upstreamEndpoint,
                                                       requestStart: requestStart, attemptStart: attemptStart),
                                          translator: translator)
            } catch {
                translator.stop()
                throw error
            }
        }
        return accumulating(try await perform(req, session: session), endpoint: upstreamEndpoint,
                            requestStart: requestStart, attemptStart: attemptStart)
    }

    /// 在原始上游字节流上做 usage + 性能采集（先于 Responses→Chat 翻译），每个
    /// chunk 原样透传，不改变时序、不重复消费。
    private static func accumulating(_ upstream: UpstreamResponse, endpoint: EndpointKind,
                                     requestStart: DispatchTime? = nil,
                                     attemptStart: DispatchTime? = nil) -> UpstreamResponse {
        let parser = UsageAccumulator(endpoint: endpoint,
                                      contentType: upstream.response.value(forHTTPHeaderField: "content-type"))
        let performance = PerformanceAccumulator(endpoint: endpoint,
                                                 contentType: upstream.response.value(forHTTPHeaderField: "content-type"),
                                                 requestStart: requestStart,
                                                 attemptStart: attemptStart)
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        let producer = Task {
            do {
                for try await chunk in upstream.body {
                    // 一到就取单调时间，避免把 usage 的 JSON 解析耗时算进 TTFT。
                    let arrived = DispatchTime.now()
                    parser.ingest(chunk)
                    performance.ingest(chunk, at: arrived)
                    continuation.yield(chunk)
                }
                let ended = DispatchTime.now()
                parser.finish()
                // 正常 for 结束也要排除「因取消而自然结束」：那不是正常 body 结束，
                // 不能生成 generation 窗口。
                if !Task.isCancelled { performance.finish(at: ended) }
                continuation.finish()
            } catch {
                parser.finish()
                // streamError / cancelled：保留已观测到的 TTFT，但绝不补一个正常结束
                // 时间（generation 保持 nil）。
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            producer.cancel()
            upstream.cancel()
        }
        return UpstreamResponse(response: upstream.response, body: stream,
                                cancel: { producer.cancel(); upstream.cancel() },
                                usage: parser, performance: performance)
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
        }, usage: upstream.usage, performance: upstream.performance)
    }

    static let droppedResponseHeaders: Set<String> = [
        "content-length",      // 我们用 chunked 重构
        "content-encoding",    // URLSession 已解压，透传会让客户端二次解压
        "connection", "keep-alive", "transfer-encoding",
        "proxy-connection", "upgrade", "te", "trailer",
    ]
}
