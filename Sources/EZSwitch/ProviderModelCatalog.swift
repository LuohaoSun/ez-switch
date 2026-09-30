import Foundation

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

    static func request(for remote: RemoteModel) throws -> URLRequest {
        let kind: EndpointKind = remote.apiEndpoints.chat.enabled ? .chat :
            remote.apiEndpoints.responses.enabled ? .responses : .messages
        let base = remote.apiEndpoints[kind].baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote.apiEndpoints[kind].enabled, !base.isEmpty else { throw CatalogError.noEndpoint }
        let prefix = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = kind == .messages && !prefix.hasSuffix("/v1") ? "/v1/models" : "/models"
        guard let url = URL(string: prefix + path),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw CatalogError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if kind == .messages {
            request.setValue(remote.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(remote.apiKey)", forHTTPHeaderField: "authorization")
        }
        for (key, value) in remote.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    static func fetch(for remote: RemoteModel) async throws -> [String] {
        let request = try request(for: remote)
        let (data, response) = try await Forwarder.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CatalogError.invalidPayload }
        guard (200..<300).contains(response.statusCode) else { throw CatalogError.badResponse(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { throw CatalogError.invalidPayload }
        return Array(Set(entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty })).sorted()
    }
}
