import Foundation
import Dispatch
import NIOCore
import NIOPosix
import NIOHTTP1

final class RouterServer {
    /// 单连接上允许同时存在的请求上限（1 个在途 + 其余排队）。
    static let defaultMaxPendingRequests = 32

    private let router: Router
    private let recordUsage: UsageRecorder?
    private let onAutoFallback: (@Sendable (AutoFallbackEvent) -> Void)?
    private let session: URLSession
    private let extensionRegistry: ExtensionRegistry
    private let maxPendingRequests: Int
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    /// 生产入口：注入可选 store（nil = 不统计）与上游 URLSession（默认生产单例）。
    /// 测试可改为传 `recordUsage:` + `session:` 的 mock，不触碰全局状态。
    /// `onAutoFallback` 在每次真正开始下一个候选之前回调一次（默认 nil = 不通知）。
    /// `extensionRegistry` 提供已注册的连接器定义（默认为内置扩展），连接器来源经它转发。
    init(router: Router, usageStore: UsageStore? = nil, recordUsage: UsageRecorder? = nil,
         session: URLSession = Forwarder.session,
         extensionRegistry: ExtensionRegistry = .builtIn,
         maxPendingRequests: Int = RouterServer.defaultMaxPendingRequests,
         onAutoFallback: (@Sendable (AutoFallbackEvent) -> Void)? = nil) {
        self.router = router
        if let recordUsage {
            self.recordUsage = recordUsage
        } else if let store = usageStore {
            self.recordUsage = { @Sendable record in store.record(record) }
        } else {
            self.recordUsage = nil
        }
        self.onAutoFallback = onAutoFallback
        self.session = session
        self.extensionRegistry = extensionRegistry
        self.maxPendingRequests = maxPendingRequests
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    func start(port: Int) throws {
        let router = self.router
        let recordUsage = self.recordUsage
        let onAutoFallback = self.onAutoFallback
        let session = self.session
        let extensionRegistry = self.extensionRegistry
        let maxPendingRequests = self.maxPendingRequests
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                // 关闭 NIO pipelining assistance：`HTTPServerPipelineHandler` 在 `.responseEndPending`
                // （请求已收完、响应未写完）期间挂起 read，SSE 长响应时读不到客户端 FIN，
                // 导致 channelInactive 不触发、上游无法取消。串行化改由 ProxyHandler 负责。
                ch.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                    ch.pipeline.addHandler(ProxyHandler(router: router, recordUsage: recordUsage,
                                                        session: session,
                                                        extensionRegistry: extensionRegistry,
                                                        maxPendingRequests: maxPendingRequests,
                                                        onAutoFallback: onAutoFallback))
                }
            }
        channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
    }

    /// 实际绑定的端口（port 传 0 时用于测试）。
    var boundPort: Int? { channel?.localAddress?.port }

    func stop() {
        try? channel?.close().wait()
        channel = nil
        try? group.syncShutdownGracefully()
    }
}

/// 每连接串行处理请求（同一时刻只处理一个），在关闭 NIO pipelining assistance 后仍保证
/// 响应顺序与 keep-alive；积压超限则停止接收并在在途响应结束后关连接。
/// 所有可变状态只在 channel 的 event loop 上访问，故声明 `@unchecked Sendable`。
final class ProxyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct PendingRequest {
        let head: HTTPRequestHead
        let body: ByteBuffer
        let closeAfter: Bool
    }

    private let router: Router
    private let recordUsage: UsageRecorder?
    private let onAutoFallback: (@Sendable (AutoFallbackEvent) -> Void)?
    private let session: URLSession
    private let extensionRegistry: ExtensionRegistry
    private let maxPendingRequests: Int

    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private var queue: [PendingRequest] = []
    private var task: Task<Void, Never>?
    private var closing = false
    private var disconnected = false

    init(router: Router, recordUsage: UsageRecorder?, session: URLSession,
         extensionRegistry: ExtensionRegistry = .builtIn,
         maxPendingRequests: Int = RouterServer.defaultMaxPendingRequests,
         onAutoFallback: (@Sendable (AutoFallbackEvent) -> Void)? = nil) {
        self.router = router
        self.recordUsage = recordUsage
        self.onAutoFallback = onAutoFallback
        self.session = session
        self.extensionRegistry = extensionRegistry
        self.maxPendingRequests = max(1, maxPendingRequests)
    }

    // MARK: ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !disconnected, !closing else { return }
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let h):
            head = h
            body = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            body?.writeBuffer(&chunk)
        case .end:
            guard let h = head, let buf = body else { return }
            head = nil
            body = nil
            enqueue(channel: context.channel, head: h, body: buf)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        tearDown()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        tearDown()
    }

    // MARK: 队列（仅 event loop）

    private func enqueue(channel: Channel, head h: HTTPRequestHead, body buf: ByteBuffer) {
        let outstanding = queue.count + (task == nil ? 0 : 1)
        guard outstanding < maxPendingRequests else {
            Log.shared.log("pipeline: 单连接积压超过 \(maxPendingRequests)，将在响应结束后关闭连接")
            stopAcceptingAndCloseWhenIdle(channel: channel)
            return
        }
        queue.append(PendingRequest(head: h, body: buf, closeAfter: !h.isKeepAlive))
        startNextIfIdle(channel: channel)
    }

    private func startNextIfIdle(channel: Channel) {
        guard !disconnected, !closing, channel.isActive, task == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        task = Task {
            await RequestProcessor.process(channel: channel, head: next.head, body: next.body,
                                           router: router, recordUsage: recordUsage, session: session,
                                           extensionRegistry: extensionRegistry,
                                           onAutoFallback: onAutoFallback)
            // 回到 event loop 串行化下一个请求（连接已关闭则不再调度）。
            guard channel.isActive else { return }
            channel.eventLoop.execute {
                self.task = nil
                if self.disconnected { return }
                if next.closeAfter { self.stopAcceptingAndCloseWhenIdle(channel: channel); return }
                if self.closing { channel.close(promise: nil); return }
                self.startNextIfIdle(channel: channel)
            }
        }
    }

    private func stopAcceptingAndCloseWhenIdle(channel: Channel) {
        closing = true
        queue.removeAll()
        if task == nil { channel.close(promise: nil) }
    }

    private func tearDown() {
        disconnected = true
        closing = true
        queue.removeAll()
        head = nil
        body = nil
        task?.cancel()
        task = nil
    }
}

enum RequestProcessor {

    static func process(channel: Channel, head: HTTPRequestHead, body: ByteBuffer,
                        router: Router, recordUsage: UsageRecorder? = nil,
                        session: URLSession = Forwarder.session,
                        extensionRegistry: ExtensionRegistry = .builtIn,
                        onAutoFallback: (@Sendable (AutoFallbackEvent) -> Void)? = nil) async {
        let rawURI = head.uri
        let split = rawURI.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split[0])
        let query = split.count > 1 ? String(split[1]) : ""
        let lower = path.lowercased()

        // 0. 原生 Gemini 本地路由：严格按路径识别（/v1beta/models… 及显式
        //    /v1/models/{id}:{op}）。绝不按 x-goog-api-key 请求头猜协议，
        //    因为 OpenAI 兼容的 Google 端点也带该头。
        var endpoint: EndpointKind
        var requested: String?
        var isCountTokens = false
        if let gemini = GeminiEndpoint.parse(uri: rawURI, method: head.method) {
            switch gemini {
            case .malformed:
                Log.shared.log("404 Gemini malformed path \(path)")
                await writeGeminiError(channel: channel, status: 404,
                                       message: "unsupported Gemini route \(path)")
                return
            case .list(let pageSize, let pageToken):
                await respondGeminiModelList(channel: channel, router: router,
                                             pageSize: pageSize, pageToken: pageToken)
                return
            case .get(let routeID):
                await respondGeminiModelGet(channel: channel, routeID: routeID, router: router)
                return
            case .badRequest(let message):
                Log.shared.log("400 Gemini bad request at \(path)")
                await writeGeminiError(channel: channel, status: 400, message: message)
                return
            case .operation(let context):
                endpoint = .gemini
                requested = context.routeID
                isCountTokens = context.isCountTokens
            }
        } else {
            // 1. 伪造 /v1/models（OpenAI / Anthropic 按请求头区分）
            if head.method == .GET && lower.hasSuffix("/models") {
                await respondModelList(channel: channel, headers: head.headers, router: router)
                return
            }

            // 2. 路径判定（纯反向代理：入站路径决定上游路径，不预检上游是否支持）
            if lower.hasSuffix("/chat/completions") {
                endpoint = .chat
            } else if lower.hasSuffix("/responses") {
                endpoint = .responses
            } else if lower.hasSuffix("/messages") {
                endpoint = .messages
            } else {
                Log.shared.log("404 \(head.method) \(path)")
                await writeJSON(channel: channel, status: 404,
                                object: ["error": ["message": "no route for path \(path)"]])
                return
            }
        }

        let isGemini = endpoint == .gemini
        // countTokens 不做用量/性能记账，也不改首选与冷却。
        let account = !isCountTokens

        // 3. body 里的 model（= fake model id）。Gemini 的 model 在路径里，不解析 body。
        let bodyData = body.getBytes(at: body.readerIndex, length: body.readableBytes).map { Data($0) } ?? Data()
        if !isGemini {
            let parsed: Any? = try? JSONSerialization.jsonObject(with: bodyData)
            requested = (parsed as? [String: Any])?["model"] as? String
        }

        // 请求开始时的权威代次快照：完成成功时若代次已变（手动选择或更晚的一次成功），
        // 迟到的完成不得覆盖新的首选。
        let selectionEpoch = requested.map { router.requestEpoch(fakeModelID: $0) }

        guard let route = router.routedCandidates(fakeModelID: requested, endpoint: endpoint) else {
            // 无兜底：id 不存在 → 404（附 known_models）；存在但未绑可用远端 → 502
            if let req = requested, router.hasFake(fakeModelID: req) {
                Log.shared.log("502 [\(endpoint.rawValue)] model=\(req) 未绑定可用远端")
                let message = "model '\(req)' has no usable remote (bind one via menu bar)"
                if isGemini {
                    await writeGeminiError(channel: channel, status: 502, message: message)
                } else {
                    await writeJSON(channel: channel, status: 502,
                                    object: ["error": ["message": message,
                                                       "type": "router_error",
                                                       "fake_model_id": req]])
                }
            } else {
                let known = router.fakeIDs()
                Log.shared.log("404 [\(endpoint.rawValue)] unknown model=\(requested ?? "(nil)") known=\(known)")
                let message = "unknown model id '\(requested ?? "")'"
                if isGemini {
                    await writeGeminiError(channel: channel, status: 404, message: message)
                } else {
                    await writeJSON(channel: channel, status: 404,
                                    object: ["error": ["message": message,
                                                       "type": "router_error",
                                                       "known_models": known]])
                }
            }
            return
        }

        let fake = route.fake
        let compatible = route.candidates
        guard !compatible.isEmpty else {
            // 未绑定任何远端，或候选都不支持该入站协议（含选中转换但 Chat 不可用 → 直接无效）。
            let unbound = fake.orderedRemoteIDs.isEmpty
            let message = unbound
                ? "model '\(fake.fakeModelID)' has no usable remote (bind one via menu bar)"
                : "model '\(fake.fakeModelID)' 的候选模型均未启用 \(endpoint.displayName)"
            Log.shared.log("502 [\(endpoint.rawValue)] model=\(fake.fakeModelID) 无可用上游")
            if isGemini {
                await writeGeminiError(channel: channel, status: 502, message: message)
            } else {
                await writeJSON(channel: channel, status: 502,
                                object: ["error": ["message": message,
                                                   "type": "router_error",
                                                   "fake_model_id": fake.fakeModelID,
                                                   "endpoint": endpoint.rawValue]])
            }
            return
        }

        // 一次客户端模型请求 = 一个 requestID；所有 attempt 记录共用请求开始时间，
        // 保证按时间分组时同一次请求的多次尝试归到同一桶。
        // requestStartMonotonic 是「完整请求已收到、路由器开始处理」的单调起点，
        // 用于 requestTTFT（含 fallback 等待）；不是客户端发起请求的瞬间。
        let requestID = UUID()
        let requestStarted = Date()
        let requestStartMonotonic = DispatchTime.now()
        var headWritten = false
        var selected: (remote: RemoteModel, upstream: UpstreamResponse)?
        var selectedAdapter: ProtocolAdapter = .passthrough
        var selectedAttempt = 0
        var selectedStarted = requestStarted
        var lastError: Error?
        // 上一次 attempt 失败留下的回退：正式开始下一个候选前发事件，避免取消/候选耗尽误报。
        var pendingFallback: (from: String, reason: AutoFallbackEvent.Reason)?
        for (index, candidate) in compatible.enumerated() {
            let remote = candidate.remote
            let adapter = candidate.adapter
            if let pending = pendingFallback {
                pendingFallback = nil
                // 连接已取消/断开就不再启动下一个候选，也不通知。
                guard !Task.isCancelled, channel.isActive else { return }
                onAutoFallback?(AutoFallbackEvent(requestID: requestID, route: fake.fakeModelID,
                                                  from: pending.from,
                                                  to: remote.routeLabel,
                                                  reason: pending.reason))
            }
            let attempt = index + 1
            let attemptStarted = Date()
            // 单调起点在建请求之前捕获：TTFT 覆盖连接/建包/桥接准备，且不会
            // 因上游 body 被 URLSession 后台预读而失真。
            let attemptStartMonotonic = DispatchTime.now()
            let endpointBaseURL = remote.endpointSetting(for: adapter == .chatToResponses ? .chat : endpoint).baseURL
            Log.shared.log("[\(endpoint.rawValue)] \(head.method) \(path) model=\(fake.fakeModelID) → \(remote.name) \(hostOf(endpointBaseURL))/\(remote.model)")
            do {
                let upstream = try await Forwarder.makeRequest(clientHead: head, body: bodyData,
                                                               endpoint: endpoint, remote: remote,
                                                               adapter: adapter, query: query,
                                                               session: session,
                                                               outboundPolicy: candidate.outboundPolicy,
                                                               requestStart: requestStartMonotonic,
                                                               attemptStart: attemptStartMonotonic,
                                                               extensionRegistry: extensionRegistry)
                let status = upstream.response.statusCode
                if index < compatible.count - 1 && (status == 429 || [500, 502, 503, 504].contains(status)) {
                    let body = await FallbackDiagnostics.readErrorBody(upstream)
                    let reason = FallbackDiagnostics.summary(response: upstream.response, body: body, remote: remote)
                    Log.shared.log("fallback: [\(endpoint.rawValue)] route=\(fake.fakeModelID) attempt=\(attempt)/\(compatible.count) failed=\(remote.name) reason=\(reason) → next=\(compatible[index + 1].remote.name)")
                    // countTokens：复用回退但绝不记账 / 冷却，也不发通知。
                    if account {
                        router.recordFailure(remoteID: remote.id)
                        recordAttempt(recordUsage, requestID: requestID, timestamp: requestStarted,
                                      fake: fake, remote: remote, endpoint: endpoint,
                                      attempt: attempt, status: status, outcome: "httpError",
                                      started: attemptStarted, tokens: upstream.usage?.tokens,
                                      performance: upstream.performance?.performance)
                    }
                    upstream.cancel()
                    if Task.isCancelled { return }
                    if account {
                        pendingFallback = (from: remote.routeLabel,
                                           reason: .httpStatus(status))
                    }
                    continue
                }
                selected = (remote, upstream)
                selectedAdapter = adapter
                selectedAttempt = attempt
                selectedStarted = attemptStarted
                break
            } catch {
                lastError = error
                // 请求本身在发往上游前就被拒绝（Responses 转换 / 连接器适配）：没有
                // HTTP attempt，不算可计费，直接返回客户端错误，不回退。
                if isClientError(error) { break }
                if Task.isCancelled || error is CancellationError {
                    // 取消不再 fallback 到下一个供应商，只记录这一次尝试
                    if account {
                        recordAttempt(recordUsage, requestID: requestID, timestamp: requestStarted,
                                      fake: fake, remote: remote, endpoint: endpoint,
                                      attempt: attempt, status: nil, outcome: "cancelled",
                                      started: attemptStarted, tokens: nil, performance: nil)
                    }
                    return
                }
                let nsError = error as NSError
                let reason = FallbackDiagnostics.clean("\(nsError.domain)(\(nsError.code)): \(error)", remote: remote)
                let next = index + 1 < compatible.count ? "next=\(compatible[index + 1].remote.name)" : "候选耗尽"
                Log.shared.log("fallback: [\(endpoint.rawValue)] route=\(fake.fakeModelID) attempt=\(attempt)/\(compatible.count) failed=\(remote.name) reason=\(reason) → \(next)")
                // countTokens：继续尝试下一个候选，但不冷却 / 不记账 / 不通知。
                if account {
                    router.recordFailure(remoteID: remote.id)
                    // 连接失败（没有响应头）也必须记录，且只记一次
                    recordAttempt(recordUsage, requestID: requestID, timestamp: requestStarted,
                                  fake: fake, remote: remote, endpoint: endpoint,
                                  attempt: attempt, status: nil, outcome: "networkError",
                                  started: attemptStarted, tokens: nil, performance: nil)
                    // 仅当确实还有下一个候选要开始时，才留下回退事件。
                    if index + 1 < compatible.count {
                        pendingFallback = (from: remote.routeLabel,
                                           reason: .connectionFailure)
                    }
                }
            }
        }
        guard let (remote, upstream) = selected else {
            let status = isClientError(lastError) ? 400 : 502
            let message = "upstream: \(lastError.map(String.init(describing:)) ?? "no usable remote")"
            if isGemini {
                await writeGeminiError(channel: channel, status: status, message: message)
            } else {
                await writeJSON(channel: channel, status: status,
                                object: ["error": ["message": message]])
            }
            return
        }
        var errorBody = Data()
        let retryableFailure = upstream.response.statusCode == 429 || [500, 502, 503, 504].contains(upstream.response.statusCode)
        if retryableFailure, account {
            router.recordFailure(remoteID: remote.id)
        }

        // Codex 的 Responses 流若被上游交错输出项事件，Codex 会丢弃 output_text.delta
        // （见 SSEReorder.swift）。这里按事件收拢后再写出；规范流是恒等变换。
        let isSSE = (upstream.response.value(forHTTPHeaderField: "content-type") ?? "")
            .lowercased().contains("text/event-stream")
        let isSuccess = (200..<300).contains(upstream.response.statusCode)
        let converting = selectedAdapter == .chatToResponses
        let reorderer: SSEReorderer? = (endpoint == .responses && isSuccess && isSSE && !converting) ? SSEReorderer() : nil

        func write(_ chunk: ByteBuffer) async throws -> Int {
            guard let reorderer else {
                try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(chunk))).get()
                return chunk.readableBytes
            }
            var written = 0
            let raw = chunk.getBytes(at: chunk.readerIndex, length: chunk.readableBytes).map { Data($0) } ?? Data()
            for block in reorderer.consume(raw) {
                var buf = channel.allocator.buffer(capacity: block.count)
                buf.writeBytes(block)
                try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf))).get()
                written += block.count
            }
            return written
        }

        var outcome = isSuccess ? "success" : "httpError"
        let cancelUpstream = upstream.cancel
        do {
            // 客户端断开（ProxyHandler.channelInactive）会取消本任务；但流式迭代器
            // 在挂起等待上游 chunk 时不一定因此返回，所以这里显式取消上游，让迭代器
            // 结束，避免客户端已断开还继续消费/计费。
            try await withTaskCancellationHandler {
                try await writeUpstreamHead(channel: channel, response: upstream.response)
                headWritten = true

                var bytes = 0
                var iterator = upstream.body.makeAsyncIterator()
                while let chunk = try await iterator.next() {
                    if Task.isCancelled { break }
                    if retryableFailure, errorBody.count < FallbackDiagnostics.bodyLimit {
                        let count = min(chunk.readableBytes, FallbackDiagnostics.bodyLimit - errorBody.count)
                        if let data = chunk.getBytes(at: chunk.readerIndex, length: count) {
                            errorBody.append(contentsOf: data)
                        }
                    }
                    bytes += try await write(chunk)
                }
                if let reorderer {
                    for block in reorderer.finish() {
                        var buf = channel.allocator.buffer(capacity: block.count)
                        buf.writeBytes(block)
                        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf))).get()
                        bytes += block.count
                    }
                    let s = reorderer.stats
                    if s.releasedAtFinish > 0 || s.overflowFlushes > 0 {
                        Log.shared.log("[\(endpoint.rawValue)] SSE reorder: 流结束时仍有 \(s.releasedAtFinish) 个事件被扣住（上游流不完整），强制放行 \(s.overflowFlushes) 次")
                    }
                }
                if Task.isCancelled {
                    outcome = "cancelled"
                    upstream.cancel()
                } else {
                    try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
                    if isSuccess, account {
                        router.recordSuccess(fakeID: fake.id, remoteID: remote.id, epoch: selectionEpoch)
                    }
                    outcome = isSuccess ? "success" : "httpError"
                }
                if retryableFailure {
                    let reason = FallbackDiagnostics.summary(response: upstream.response, body: errorBody, remote: remote)
                    Log.shared.log("fallback: [\(endpoint.rawValue)] route=\(fake.fakeModelID) failed=\(remote.name) reason=\(reason)；无后续候选，返回上游错误")
                }
                Log.shared.log("[\(endpoint.rawValue)] \(fake.fakeModelID) \(upstream.response.statusCode) \(Log.size(bytes)) \(Log.seconds(Date().timeIntervalSince(requestStarted)))")
            } onCancel: {
                cancelUpstream()
            }
        } catch {
            outcome = Task.isCancelled ? "cancelled" : "streamError"
            if headWritten {
                // 头已写出，不能中途换壳：只 log + 关连接
                Log.shared.log("[\(endpoint.rawValue)] stream error after head: \(error)")
                upstream.cancel()
                try? await channel.close().get()
            } else {
                Log.shared.log("[\(endpoint.rawValue)] upstream error: \(error)")
                upstream.cancel()
                let message = "upstream: \(error)"
                if isGemini {
                    await writeGeminiError(channel: channel, status: 502, message: message)
                } else {
                    await writeJSON(channel: channel, status: 502,
                                    object: ["error": ["message": message]])
                }
            }
        }
        // 选中的那次尝试在“结束时”恰好记一次（含取消 / 流中途错误 / body 错误）。
        // countTokens 不记账。
        if account {
            recordAttempt(recordUsage, requestID: requestID, timestamp: requestStarted,
                          fake: fake, remote: remote, endpoint: endpoint,
                          attempt: selectedAttempt, status: upstream.response.statusCode, outcome: outcome,
                          started: selectedStarted, tokens: upstream.usage?.tokens,
                          performance: upstream.performance?.performance)
        }
    }

    /// 请求级客户端错误：请求体本身不被适配器接受，应在发往上游前返回 400 且不回退。
    /// 连接器适配器以 `ClientRequestFailure.clientError` 标记这一语义；Responses 转换器
    /// 的 `ResponseTranslationError` 同样以 `clientError` 标记（它不是本类型族成员，
    /// 故专门判断）。
    private static func isClientError(_ error: Error?) -> Bool {
        if let failure = error as? any ClientRequestFailure { return failure.clientError }
        if let error = error as? ResponseTranslationError { return error.clientError }
        return false
    }

    /// 记录一次上游尝试。record 非阻塞、不抛错；null-ish 计数字段保持 nil（不猜）。
    private static func recordAttempt(_ recordUsage: UsageRecorder?, requestID: UUID, timestamp: Date,
                                      fake: FakeModel, remote: RemoteModel, endpoint: EndpointKind,
                                      attempt: Int, status: Int?, outcome: String,
                                      started: Date, tokens: UsageTokens?,
                                      performance: UsagePerformance? = nil) {
        guard let recordUsage else { return }
        var record = UsageRecord(requestID: requestID,
                                 timestamp: timestamp,
                                 routeID: fake.id.uuidString,
                                 routeName: fake.displayName.isEmpty ? fake.fakeModelID : fake.displayName,
                                 remoteID: remote.id.uuidString,
                                 provider: splitProviderModel(remote.name).provider,
                                 model: remote.model,
                                 endpoint: endpoint.rawValue,
                                 attempt: attempt,
                                 status: status,
                                 outcome: outcome,
                                 durationMS: max(0, Int(Date().timeIntervalSince(started) * 1000)),
                                 tokens: tokens ?? UsageTokens())
        // 成功 / 失败 / 取消都记可观测的性能字段；统计层自行排除失败与取消。
        record.performance = performance
        recordUsage(record)
    }

    // MARK: 响应写出

    private static func hostOf(_ baseURL: String) -> String {
        var s = baseURL
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(of: "/") { s = String(s[..<i]) }
        return s
    }

    private static func writeJSON(channel: Channel, status: Int, object: [String: Any]) async {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: "\(data.count)")
        headers.add(name: "connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1,
                                    status: HTTPResponseStatus(statusCode: status),
                                    headers: headers)
        do {
            try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
            var buf = channel.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            // swift-nio 2.103: HTTPServerResponsePart.body 收的是 IOData
            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf))).get()
            try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
            try? await channel.close().get()
        } catch {
            // 客户端可能已经走了
        }
    }

    /// headers 含 x-api-key / anthropic-version → Anthropic 格式，否则 OpenAI 格式
    private static func respondModelList(channel: Channel, headers: HTTPHeaders, router: Router) async {
        let anthropic = headers.contains(name: "x-api-key") || headers.contains(name: "anthropic-version")
        let fakes = router.fakes()
        var payload: [String: Any]
        if anthropic {
            payload = [
                "data": fakes.map { ["id": $0.fakeModelID, "type": "model", "display_name": $0.fakeModelID] },
                "has_more": false,
            ]
        } else {
            payload = [
                "object": "list",
                "data": fakes.map { ["id": $0.fakeModelID, "object": "model", "owned_by": "router"] },
            ]
        }
        Log.shared.log("models: \(anthropic ? "anthropic" : "openai") format, \(fakes.count) fakes")
        await writeJSON(channel: channel, status: 200, object: payload)
    }

    // MARK: Gemini 本地模型目录 / 错误

    /// Gemini `models.list` 默认每页条数与上限（Google REST 语义）。
    static let geminiDefaultPageSize = 50
    static let geminiMaxPageSize = 1000

    /// 只列出「Gemini 兼容」的本地路由（至少一个已绑定远端启用了 Gemini），
    /// 返回原生 Gemini 结构，不编造 token 上限。pageToken 为不透明偏移量。
    private static func respondGeminiModelList(channel: Channel, router: Router,
                                               pageSize: Int?, pageToken: String?) async {
        let ids = router.fakes(supporting: .gemini).map(\.fakeModelID)
        let offset: Int
        if let pageToken {
            guard let value = Int(pageToken), value >= 0 else {
                await writeGeminiError(channel: channel, status: 400, message: "invalid pageToken")
                return
            }
            offset = value
        } else {
            offset = 0
        }
        let size = min(max(pageSize ?? geminiDefaultPageSize, 1), geminiMaxPageSize)
        let start = min(offset, ids.count)
        let slice = Array(ids[start..<min(start + size, ids.count)])
        var payload = GeminiEndpoint.listPayload(ids: slice)
        let next = start + slice.count
        if next < ids.count { payload["nextPageToken"] = String(next) }
        Log.shared.log("models: gemini format, \(slice.count)/\(ids.count) fakes")
        await writeJSON(channel: channel, status: 200, object: payload)
    }

    private static func respondGeminiModelGet(channel: Channel, routeID: String, router: Router) async {
        let ids = router.fakes(supporting: .gemini).map(\.fakeModelID)
        guard ids.contains(routeID) else {
            await writeGeminiError(channel: channel, status: 404,
                                   message: "model '\(routeID)' not found")
            return
        }
        Log.shared.log("models: gemini get \(routeID)")
        await writeJSON(channel: channel, status: 200, object: GeminiEndpoint.modelPayload(id: routeID))
    }

    private static func writeGeminiError(channel: Channel, status: Int, message: String) async {
        await writeJSON(channel: channel, status: status,
                        object: GeminiEndpoint.errorPayload(status: status, message: message))
    }

    /// 透传上游头：丢 hop-by-hop / content-length / content-encoding，改 chunked
    private static func writeUpstreamHead(channel: Channel, response: HTTPURLResponse) async throws {
        var headers = HTTPHeaders()
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            if Forwarder.droppedResponseHeaders.contains(name.lowercased()) { continue }
            headers.add(name: name, value: text)
        }
        headers.replaceOrAdd(name: "transfer-encoding", value: "chunked")
        let head = HTTPResponseHead(version: .http1_1,
                                    status: HTTPResponseStatus(statusCode: response.statusCode),
                                    headers: headers)
        try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
    }
}
