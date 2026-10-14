import Foundation

/// 供应商模型列表查询。启用原生 Gemini 时优先 `{base}/models`（base 已含版本前缀，如 `/v1beta`），
/// 否则沿用 Chat / Responses / Messages 的 `/models`（Messages 补 `/v1`）。
struct ProviderModelCatalog {
    enum CatalogError: LocalizedError {
        case noEndpoint
        case invalidURL
        case badResponse(Int)
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .noEndpoint: return "供应商未配置可查询的接口地址"
            case .invalidURL: return "模型列表地址无效"
            case .badResponse(let status): return "获取模型列表失败（HTTP \(status)）"
            case .invalidPayload: return "接口未返回可识别的模型列表"
            }
        }
    }

    /// 分页上限，防止上游 `nextPageToken` 循环或无限分页。
    static let maxPages = 50

    static func catalogKind(for remote: RemoteModel) -> EndpointKind {
        if remote.supports(.gemini) { return .gemini }
        if remote.apiEndpoints.chat.enabled { return .chat }
        if remote.apiEndpoints.responses.enabled { return .responses }
        return .messages
    }

    static func request(for remote: RemoteModel) throws -> URLRequest {
        let kind = catalogKind(for: remote)
        let base = remote.apiEndpoints[kind].baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote.apiEndpoints[kind].enabled, !base.isEmpty else { throw CatalogError.noEndpoint }
        let prefix = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Gemini 的 base 已是版本前缀（/v1beta），只拼 /models；Messages 的 base 不含版本段。
        let path = kind == .messages && !prefix.hasSuffix("/v1") ? "/v1/models" : "/models"
        guard let url = URL(string: prefix + path),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw CatalogError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "accept")
        switch kind {
        case .messages:
            request.setValue(remote.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(remote.apiKey, forHTTPHeaderField: "x-goog-api-key")
        default:
            request.setValue("Bearer \(remote.apiKey)", forHTTPHeaderField: "authorization")
        }
        for (key, value) in remote.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    /// `session` 可注入（测试用 mock），默认走生产单例 `Forwarder.session`。
    static func fetch(for remote: RemoteModel, session: URLSession = Forwarder.session) async throws -> [String] {
        if catalogKind(for: remote) == .gemini {
            return try await fetchGemini(for: remote, session: session)
        }
        let json = try await perform(try request(for: remote), session: session)
        guard let entries = json["data"] as? [[String: Any]] else { throw CatalogError.invalidPayload }
        return normalized(entries.compactMap { $0["id"] as? String })
    }

    private static func fetchGemini(for remote: RemoteModel, session: URLSession) async throws -> [String] {
        let base = try request(for: remote)
        var names: [String] = []
        var pageToken: String?
        var requestedTokens = Set<String>()
        var pages = 0
        repeat {
            if let token = pageToken, !requestedTokens.insert(token).inserted { break }
            let json = try await perform(paged(base, pageToken: pageToken), session: session)
            guard let models = json["models"] as? [[String: Any]] else { throw CatalogError.invalidPayload }
            for entry in models {
                guard let name = geminiModelName(entry["name"] as? String),
                      let methods = entry["supportedGenerationMethods"] as? [String],
                      methods.contains("generateContent") else { continue }
                names.append(name)
            }
            pages += 1
            let next = (json["nextPageToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // 只认 token，绝不跟随响应里的任意 URL；空 token / 达上限 / 已见过即停止。
            pageToken = (next?.isEmpty == false && pages < maxPages) ? next : nil
        } while pageToken != nil
        return normalized(names)
    }

    /// 在已校验的列表 URL 上追加 `pageToken`，不采用上游返回的 URL。
    private static func paged(_ request: URLRequest, pageToken: String?) throws -> URLRequest {
        guard let token = pageToken else { return request }
        guard let url = request.url,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CatalogError.invalidURL
        }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "pageToken", value: token)]
        guard let pagedURL = comps.url else { throw CatalogError.invalidURL }
        var copy = request
        copy.url = pagedURL
        return copy
    }

    /// 去掉单层 `models/` 前缀；拒绝空名、仍含分隔符 / `:` / 空白的非法名称。
    static func geminiModelName(_ raw: String?) -> String? {
        raw.flatMap(GeminiEndpoint.normalizedModelResource)
    }

    private static func normalized(_ names: [String]) -> [String] {
        Array(Set(names.filter { !$0.isEmpty })).sorted()
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CatalogError.invalidPayload }
        guard (200..<300).contains(response.statusCode) else { throw CatalogError.badResponse(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.invalidPayload
        }
        return json
    }
}
