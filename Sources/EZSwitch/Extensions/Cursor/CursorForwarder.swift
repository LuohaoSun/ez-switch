import Foundation

/// 入站协议不受支持（仅 Gemini）：客户端错误 → 400 且不回退。端点配置错误不是此类，
/// 它们抛 `CursorProxyError`，按后端失败参与回退。
struct CursorProxyRequestError: ClientRequestFailure, LocalizedError {
    let description: String
    var clientError: Bool { true }
    var errorDescription: String? { description }
}

/// 第三方 sidecar 传输：只校验 loopback 端点并把连接器远端重挂到内部 `.api` 远端，
/// 再原样交给 `Forwarder` 复用其鉴权剔除、model 改写、透传、流式、usage/perf、取消与回退。
/// 工具/图像/服务端状态/未知字段一律不动，协议兼容由 sidecar 负责。
enum CursorForwarder {

    /// sidecar 专用隔离会话：ephemeral + 空代理字典（禁用系统代理）。
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 3600
        cfg.timeoutIntervalForResource = 7200
        return URLSession(configuration: cfg)
    }()

    static func makeRequest(_ request: ConnectorRequest, endpoint: CursorProxyEndpoint,
                            session: URLSession = CursorForwarder.session) async throws -> UpstreamResponse {
        guard request.endpoint != .gemini else {
            throw CursorProxyRequestError(description: "Cursor 连接器不支持 Gemini（仅 Chat / Responses / Messages）")
        }
        let base = try validatedBaseURL(endpoint)
        return try await Forwarder.makeRequest(
            clientHead: request.clientHead, body: request.body, endpoint: request.endpoint,
            remote: httpRemote(request.remote, apiKey: endpoint.apiKey, base: base),
            adapter: .passthrough, query: request.query, session: session,
            requestStart: request.requestStart, attemptStart: request.attemptStart)
    }

    /// 只允许 http、host 恰为 `127.0.0.1`、path 恰为 `/v1`、无 userinfo/query/fragment、
    /// 端口存在、key 非空；失败按后端错误抛出（可回退），不当作 400。
    private static func validatedBaseURL(_ endpoint: CursorProxyEndpoint) throws -> URL {
        let url = endpoint.baseURL
        func invalid(_ reason: String) -> CursorProxyError {
            CursorProxyError(message: "Cursor 代理地址无效：\(reason)")
        }
        guard !endpoint.apiKey.isEmpty else { throw invalid("缺少 API key") }
        guard url.scheme?.lowercased() == "http" else { throw invalid("必须使用 http") }
        guard url.user == nil, url.password == nil else { throw invalid("不得包含用户信息") }
        guard url.fragment == nil, url.query == nil else { throw invalid("不得包含 query 或 fragment") }
        guard url.host == "127.0.0.1" else { throw invalid("host 必须是 127.0.0.1") }
        guard let port = url.port, (1...65535).contains(port) else { throw invalid("端口必须在 1...65535") }
        guard url.path == "/v1" else { throw invalid("路径必须是 /v1") }
        return url
    }

    /// 重挂为内部 `.api` 远端（来源 `.api` ⇒ 绝不走 registry/外网，凭据换 sidecar key）。
    /// Chat/Responses 路径相对 `/v1` 前缀，而 Messages 路径自带 `/v1`，故 Messages 用 sidecar
    /// 根地址，最终分别命中 /v1/chat/completions、/v1/responses、/v1/messages。
    private static func httpRemote(_ remote: RemoteModel, apiKey: String, base: URL) -> RemoteModel {
        var http = remote
        http.source = .api
        http.apiKey = apiKey
        http.extraHeaders = [:]
        http.apiEndpoints = APIEndpointSettings(
            chat: EndpointSetting(enabled: true, baseURL: base.absoluteString),
            responses: EndpointSetting(enabled: true, baseURL: base.absoluteString),
            messages: EndpointSetting(enabled: true, baseURL: base.deletingLastPathComponent().absoluteString))
        return http
    }
}
