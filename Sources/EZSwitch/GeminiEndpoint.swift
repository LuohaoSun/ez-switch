import Foundation
import NIOHTTP1

/// Native Gemini REST local-route parsing and upstream request shaping.
///
/// Local API semantics: the path carries the local route id and the operation
/// suffix (`:generateContent` / `:streamGenerateContent` / `:countTokens`); the
/// protocol is chosen by path only, never by headers (OpenAI-compatible Google
/// endpoints also send `x-goog-api-key`).
///
/// Constraints:
/// - recognized prefixes are `/v1beta/models` (primary) and `/v1/models/{id}:{op}`
///   (explicit, operations only, so OpenAI `GET /v1/models` stays untouched);
/// - the three operations are POST (native REST);
/// - local model list/get are GET;
/// - the path model id must be a single safe segment.
enum GeminiEndpoint {
    /// Native API base the user configures; the router appends
    /// `/models/{realModel}:{operation}`.
    static let basePrefix = "https://generativelanguage.googleapis.com/v1beta"

    enum Operation: String, CaseIterable {
        case generateContent
        case streamGenerateContent
        case countTokens

        /// generateContent / streamGenerateContent (as opposed to countTokens).
        var isGeneration: Bool { self != .countTokens }
    }

    /// A resolved local generation/count operation.
    struct Context: Equatable {
        let operation: Operation
        /// Local route (fake model) id decoded from the path.
        let routeID: String
        /// Client query with the auth `key` removed; other params (`alt=sse`, ...)
        /// preserved verbatim. Never contains the client API key.
        let query: String
        var isCountTokens: Bool { operation == .countTokens }
    }

    enum Request: Equatable {
        case operation(Context)
        case list(pageSize: Int?, pageToken: String?)
        case get(routeID: String)
        /// Path matched a Gemini prefix but the shape/method is invalid.
        case malformed
        /// Well-formed Gemini route with an invalid parameter (e.g. pageSize).
        case badRequest(String)
    }

    // MARK: - Parsing

    private static let betaPrefix = "/v1beta/models"
    private static let v1Prefix = "/v1/models"

    /// nil = not a Gemini local route (callers use the generic matcher).
    static func parse(uri: String, method: HTTPMethod) -> Request? {
        let split = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(split[0])
        let rawQuery = split.count > 1 ? String(split[1]) : ""

        if rawPath == betaPrefix || rawPath == betaPrefix + "/" {
            return listRequest(rawQuery, method: method)
        }
        if rawPath.hasPrefix(betaPrefix + "/") {
            return modelRequest(String(rawPath.dropFirst(betaPrefix.count + 1)),
                                rawQuery: rawQuery, method: method, allowListAndGet: true)
        }
        // /v1 is limited to `{id}:{op}` so `GET /v1/models` keeps OpenAI semantics.
        if rawPath.hasPrefix(v1Prefix + "/") {
            let tail = String(rawPath.dropFirst(v1Prefix.count + 1))
            guard tail.contains(":") else { return nil }
            return modelRequest(tail, rawQuery: rawQuery, method: method, allowListAndGet: false)
        }
        return nil
    }

    private static func listRequest(_ rawQuery: String, method: HTTPMethod) -> Request {
        guard method == .GET else { return .malformed }
        let q = dissectQuery(rawQuery)
        if q.pageSizeInvalid { return .badRequest("invalid pageSize") }
        return .list(pageSize: q.pageSize, pageToken: q.pageToken)
    }

    private static func modelRequest(_ tail: String, rawQuery: String,
                                     method: HTTPMethod, allowListAndGet: Bool) -> Request {
        // Strict single segment: no extra path components, no trailing slash.
        guard !tail.isEmpty, !tail.contains("/") else { return .malformed }
        let parts = tail.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let rawModel = String(parts[0])
        let rawOperation = parts.count > 1 ? String(parts[1]) : nil

        guard let decoded = rawModel.removingPercentEncoding, let routeID = validatedRouteID(decoded)
        else { return .malformed }

        if let rawOperation {
            guard let operation = Operation(rawValue: rawOperation), method == .POST else { return .malformed }
            return .operation(Context(operation: operation, routeID: routeID,
                                      query: dissectQuery(rawQuery).kept.joined(separator: "&")))
        }
        guard allowListAndGet, method == .GET else { return .malformed }
        return .get(routeID: routeID)
    }

    /// Strips one optional `models/` resource prefix and rejects anything that is
    /// not a safe single path segment (no `/`, `:`, whitespace, control, `..`).
    private static func validatedRouteID(_ decoded: String) -> String? {
        var id = decoded
        if id.hasPrefix("models/") { id = String(id.dropFirst("models/".count)) }
        guard !id.isEmpty, id != ".", id != "..",
              id.unicodeScalars.allSatisfy({ routeIDAllowed.contains($0) }) else { return nil }
        return id
    }

    private static let routeIDAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~@-")

    // MARK: - Query hygiene

    private struct QueryParts {
        /// Raw `name=value` pairs with `key` removed.
        let kept: [String]
        let pageSize: Int?
        let pageToken: String?
        let pageSizeInvalid: Bool
    }

    /// Drops the client auth `key` param (decoded name compared case-insensitively,
    /// so `KEY` / `%6Bey` / duplicates are removed) while preserving every other
    /// parameter verbatim. pageToken is percent-decoded; pageSize must be >= 1.
    private static func dissectQuery(_ raw: String) -> QueryParts {
        var kept: [String] = []
        var pageSize: Int?
        var pageToken: String?
        var pageSizeInvalid = false
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let pairString = String(pair)
            let kv = pairString.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawName = String(kv[0])
            let name = (rawName.removingPercentEncoding ?? rawName).lowercased()
            if name == "key" { continue }
            kept.append(pairString)
            guard kv.count > 1 else { continue }
            let value = String(kv[1])
            if name == "pagesize" {
                if let parsed = Int(value), parsed >= 1 { pageSize = parsed } else { pageSizeInvalid = true }
            } else if name == "pagetoken" {
                pageToken = value.removingPercentEncoding ?? value
            }
        }
        return QueryParts(kept: kept, pageSize: pageSize, pageToken: pageToken,
                          pageSizeInvalid: pageSizeInvalid)
    }

    /// Client query with only the auth `key` removed.
    static func sanitizedQuery(_ raw: String) -> String {
        dissectQuery(raw).kept.joined(separator: "&")
    }

    // MARK: - Upstream shaping

    /// `{base}/models/{normalizedModel}:{operation}` + sanitized query. Returns nil
    /// for an empty base or a model that is not a safe single path segment.
    static func upstreamURL(baseURL: String, realModel: String, context: Context) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let model = normalizedModelResource(realModel) else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        var s = base + "/models/" + encodeSegment(model) + ":" + context.operation.rawValue
        if !context.query.isEmpty { s += "?" + context.query }
        return URL(string: s)
    }

    /// Strips one optional `models/` resource prefix (users commonly configure
    /// `models/gemini-X`) and validates the remainder as a single safe segment,
    /// so `models/models%2FX` or `..` path escapes can never be built.
    static func normalizedModelResource(_ realModel: String) -> String? {
        var model = realModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("models/") { model = String(model.dropFirst("models/".count)) }
        guard !model.isEmpty, model != ".", model != "..",
              model.unicodeScalars.allSatisfy({ routeIDAllowed.contains($0) }) else { return nil }
        return model
    }

    /// Percent-encode one path segment (keeps unreserved characters intact).
    static func encodeSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? value
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// countTokens body transform: rewrites `generateContentRequest.model` to
    /// `models/{normalizedModel}` only when it is a present string; otherwise the
    /// original bytes are returned unchanged. Native generation bodies never pass
    /// through here (they are forwarded byte-for-byte).
    static func rewriteCountTokensBody(_ body: Data, realModel: String) -> Data {
        guard let model = normalizedModelResource(realModel),
              !body.isEmpty,
              var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var request = root["generateContentRequest"] as? [String: Any],
              request["model"] is String else { return body }
        let resource = "models/" + model
        if request["model"] as? String == resource { return body }
        request["model"] = resource
        root["generateContentRequest"] = request
        return (try? JSONSerialization.data(withJSONObject: root)) ?? body
    }

    // MARK: - Local responses

    static let supportedGenerationMethods = ["generateContent", "streamGenerateContent", "countTokens"]

    /// Local model entry; no token limits are invented.
    static func modelPayload(id: String) -> [String: Any] {
        ["name": "models/\(id)",
         "displayName": id,
         "supportedGenerationMethods": supportedGenerationMethods]
    }

    static func listPayload(ids: [String]) -> [String: Any] {
        ["models": ids.map(modelPayload(id:))]
    }

    /// Gemini-shaped local error: `{"error":{"code":..,"message":..,"status":".."}}`.
    static func errorPayload(status: Int, message: String) -> [String: Any] {
        ["error": ["code": status, "message": message, "status": statusName(for: status)]]
    }

    static func statusName(for status: Int) -> String {
        switch status {
        case 400: return "INVALID_ARGUMENT"
        case 401: return "UNAUTHENTICATED"
        case 403: return "PERMISSION_DENIED"
        case 404: return "NOT_FOUND"
        case 409: return "ALREADY_EXISTS"
        case 429: return "RESOURCE_EXHAUSTED"
        case 500: return "INTERNAL"
        case 502, 503: return "UNAVAILABLE"
        case 504: return "DEADLINE_EXCEEDED"
        default: return "UNKNOWN"
        }
    }
}
