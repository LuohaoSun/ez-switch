import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

final class RouterServer {
    private let router: Router
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    init(router: Router) {
        self.router = router
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    func start(port: Int) throws {
        let router = self.router
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                // NOTE: swift-nio 2.103 里 addHTTPServerPipeline() 已改名为 configureHTTPServerPipeline()
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(ProxyHandler(router: router))
                }
            }
        channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
    }
}

/// 收完一个请求（head+body+end）就交给 RequestProcessor；连接断开则取消上游。
final class ProxyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private var task: Task<Void, Never>?

    init(router: Router) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let h):
            head = h
            body = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            body?.writeBuffer(&chunk)
        case .end:
            guard let h = head, let buf = body else { return }
            let channel = context.channel
            let router = self.router
            task = Task {
                await RequestProcessor.process(channel: channel, head: h, body: buf, router: router)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        task?.cancel()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        task?.cancel()
    }
}

enum RequestProcessor {

    static func process(channel: Channel, head: HTTPRequestHead, body: ByteBuffer, router: Router) async {
        let rawURI = head.uri
        let split = rawURI.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split[0])
        let query = split.count > 1 ? String(split[1]) : ""
        let lower = path.lowercased()

        // 1. 伪造 /v1/models
        if head.method == .GET && lower.hasSuffix("/models") {
            await respondModelList(channel: channel, headers: head.headers, router: router)
            return
        }

        // 2. 路径判定（纯反向代理：入站路径决定上游路径，不预检上游是否支持）
        var matched: EndpointKind?
        if lower.hasSuffix("/chat/completions") {
            matched = .chat
        } else if lower.hasSuffix("/responses") {
            matched = .responses
        } else if lower.hasSuffix("/messages") {
            matched = .messages
        }
        guard let endpoint = matched else {
            Log.shared.log("404 \(head.method) \(path)")
            await writeJSON(channel: channel, status: 404,
                            object: ["error": ["message": "no route for path \(path)"]])
            return
        }

        // 3. 先解析 body 里的 model（= fake model id）；路由只按模型 ID，入站路径决定上游格式
        let bodyData = body.getBytes(at: body.readerIndex, length: body.readableBytes).map { Data($0) } ?? Data()
        let parsed: Any? = try? JSONSerialization.jsonObject(with: bodyData)
        let requested: String? = (parsed as? [String: Any])?["model"] as? String

        guard let (fake, remote) = router.route(fakeModelID: requested) else {
            // 无兜底：id 不存在 → 404（附 known_models）；存在但未绑可用远端 → 502
            if let req = requested, router.hasFake(fakeModelID: req) {
                Log.shared.log("502 [\(endpoint.rawValue)] model=\(req) 未绑定可用远端")
                await writeJSON(channel: channel, status: 502,
                                object: ["error": ["message": "model '\(req)' has no usable remote (bind one via menu bar)",
                                                   "type": "router_error",
                                                   "fake_model_id": req]])
            } else {
                let known = router.fakeIDs()
                Log.shared.log("404 [\(endpoint.rawValue)] unknown model=\(requested ?? "(nil)") known=\(known)")
                await writeJSON(channel: channel, status: 404,
                                object: ["error": ["message": "unknown model id '\(requested ?? "")'",
                                                   "type": "router_error",
                                                   "known_models": known]])
            }
            return
        }

        guard remote.supports(endpoint) else {
            let message = "model '\(fake.fakeModelID)' 的供应商未启用 \(endpoint.displayName)"
            Log.shared.log("502 [\(endpoint.rawValue)] model=\(fake.fakeModelID) → \(remote.name) 未启用")
            await writeJSON(channel: channel, status: 502,
                            object: ["error": ["message": message,
                                               "type": "router_error",
                                               "fake_model_id": fake.fakeModelID,
                                               "endpoint": endpoint.rawValue]])
            return
        }

        let endpointBaseURL = remote.endpointSetting(for: endpoint).baseURL
        Log.shared.log("[\(endpoint.rawValue)] \(head.method) \(path) model=\(fake.fakeModelID) → \(remote.name) \(hostOf(endpointBaseURL))/\(remote.model)")

        let started = Date()
        var headWritten = false
        let upstream: UpstreamResponse
        do {
            upstream = try await Forwarder.makeRequest(clientHead: head, body: bodyData,
                                                       endpoint: endpoint, remote: remote, query: query)
        } catch {
            Log.shared.log("[\(endpoint.rawValue)] upstream failed: \(error)")
            await writeJSON(channel: channel, status: 502,
                            object: ["error": ["message": "upstream: \(error)"]])
            return
        }

        // Codex 的 Responses 流若被上游交错输出项事件，Codex 会丢弃 output_text.delta
        // （见 SSEReorder.swift）。这里按事件收拢后再写出；规范流是恒等变换。
        let isSSE = (upstream.response.value(forHTTPHeaderField: "content-type") ?? "")
            .lowercased().contains("text/event-stream")
        let isSuccess = (200..<300).contains(upstream.response.statusCode)
        let reorderer: SSEReorderer? = (endpoint == .responses && isSuccess && isSSE) ? SSEReorderer() : nil

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

        do {
            try await writeUpstreamHead(channel: channel, response: upstream.response)
            headWritten = true

            var bytes = 0
            var iterator = upstream.body.makeAsyncIterator()
            while let chunk = try await iterator.next() {
                if Task.isCancelled { break }
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
                upstream.cancel()
            } else {
                try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
            }
            Log.shared.log("[\(endpoint.rawValue)] \(fake.fakeModelID) \(upstream.response.statusCode) \(Log.size(bytes)) \(Log.seconds(Date().timeIntervalSince(started)))")
        } catch {
            if headWritten {
                // 头已写出，不能中途换壳：只 log + 关连接
                Log.shared.log("[\(endpoint.rawValue)] stream error after head: \(error)")
                upstream.cancel()
                try? await channel.close().get()
            } else {
                Log.shared.log("[\(endpoint.rawValue)] upstream error: \(error)")
                upstream.cancel()
                await writeJSON(channel: channel, status: 502,
                                object: ["error": ["message": "upstream: \(error)"]])
            }
        }
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
