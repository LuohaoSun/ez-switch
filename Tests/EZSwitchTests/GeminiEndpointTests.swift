import Foundation
import NIOHTTP1
import Testing
@testable import EZSwitch

/// GeminiEndpoint 纯函数：严格路径解析、query `key` 清理、上游 URL/body 塑形、本地载荷。
@Suite("Gemini endpoint parsing")
struct GeminiEndpointTests {

    private func operation(_ uri: String, _ method: HTTPMethod = .POST) throws -> GeminiEndpoint.Context {
        let request = try #require(GeminiEndpoint.parse(uri: uri, method: method))
        guard case .operation(let context) = request else {
            Issue.record("expected an operation, got \(request)")
            throw TestError.notAnOperation
        }
        return context
    }

    private enum TestError: Error { case notAnOperation }

    // MARK: 路径与操作

    @Test func parsesTheThreeSupportedOperations() throws {
        let generate = try operation("/v1beta/models/main:generateContent")
        #expect(generate.operation == .generateContent)
        #expect(generate.routeID == "main")
        #expect(!generate.isCountTokens)

        let stream = try operation("/v1beta/models/main:streamGenerateContent")
        #expect(stream.operation == .streamGenerateContent)

        let count = try operation("/v1beta/models/main:countTokens")
        #expect(count.operation == .countTokens)
        #expect(count.isCountTokens)
    }

    @Test func listAndGetUsePathNotHeaders() throws {
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models", method: .GET) == .list(pageSize: nil, pageToken: nil))
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/", method: .GET) == .list(pageSize: nil, pageToken: nil))
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main", method: .GET) == .get(routeID: "main"))
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main?key=SECRET", method: .GET) == .get(routeID: "main"))
    }

    @Test func listPaginationIsParsedFromQuery() throws {
        let request = try #require(GeminiEndpoint.parse(
            uri: "/v1beta/models?key=SECRET&pageSize=10&pageToken=abc%2F20", method: .GET))
        #expect(request == .list(pageSize: 10, pageToken: "abc/20"))

        // 非法 pageSize 明确 400，不静默当 nil。
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models?pageSize=0", method: .GET) == .badRequest("invalid pageSize"))
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models?pageSize=abc", method: .GET) == .badRequest("invalid pageSize"))
    }

    // MARK: query `key` 清理

    @Test func stripsClientKeyInEveryVariant() throws {
        let context = try operation(
            "/v1beta/models/main:generateContent?key=SECRET&alt=sse&Key=dup&%6Bey=encoded&KEY=upper")
        #expect(context.query == "alt=sse")
        #expect(!context.query.contains("SECRET"))

        let noKey = try operation("/v1beta/models/main:generateContent?alt=sse")
        #expect(noKey.query == "alt=sse")

        let empty = try operation("/v1beta/models/main:generateContent?key=SECRET")
        #expect(empty.query.isEmpty)
    }

    // MARK: 严格性

    @Test func rejectsAccidentalSuffixAndForeignPrefixes() {
        #expect(GeminiEndpoint.parse(uri: "/foo/v1beta/models/main:generateContent", method: .POST) == nil)
        #expect(GeminiEndpoint.parse(uri: "/x/v1beta/models", method: .GET) == nil)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/modelss/main:generateContent", method: .POST) == nil)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models", method: .GET) != nil)
    }

    @Test func rejectsMalformedGeminiShapes() {
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main:bogusOperation", method: .POST) == .malformed)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main:generateContent/extra", method: .POST) == .malformed)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/:generateContent", method: .POST) == .malformed)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models", method: .POST) == .malformed)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main", method: .POST) == .malformed)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main:generateContent", method: .DELETE) == .malformed)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main:countTokens", method: .GET) == .malformed)
        // 百分号编码的 `/` 解码后不是安全单段 → 拒绝注入
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/%2F:generateContent", method: .POST) == .malformed)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/bad%zz:generateContent", method: .POST) == .malformed)
    }

    @Test func rejectsGetForOperations() {
        // 官方三个操作都是 POST；GET 生成无证实惯例，一律拒绝。
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main:generateContent", method: .GET) == .malformed)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main:streamGenerateContent", method: .GET) == .malformed)
        #expect(GeminiEndpoint.parse(uri: "/v1beta/models/main:countTokens", method: .GET) == .malformed)
    }

    @Test func v1VersionSupportsColonOperationsOnly() throws {
        // /v1/models 列表保持 OpenAI 语义：Gemini 解析必须返回 nil（交给通用分支）。
        #expect(GeminiEndpoint.parse(uri: "/v1/models", method: .GET) == nil)
        #expect(GeminiEndpoint.parse(uri: "/v1/models/main", method: .GET) == nil)

        let context = try operation("/v1/models/main:generateContent", .POST)
        #expect(context.routeID == "main")
        #expect(context.operation == .generateContent)
        #expect(GeminiEndpoint.parse(uri: "/v1/models/main:generateContent", method: .GET) == .malformed)
    }

    @Test func modelResourcePrefixIsStrippedWhenEncoded() throws {
        let context = try operation("/v1beta/models/models%2Fgemini-pro:generateContent")
        #expect(context.routeID == "gemini-pro")
    }

    // MARK: 上游 URL / body

    @Test func buildsUpstreamURLWithRealModelAndSanitizedQuery() throws {
        let context = try operation("/v1beta/models/main:generateContent?key=SECRET&alt=sse")
        let url = try #require(GeminiEndpoint.upstreamURL(
            baseURL: "https://generativelanguage.googleapis.com/v1beta/",
            realModel: "gemini-1.5-pro", context: context))
        #expect(url.absoluteString ==
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent?alt=sse")
        #expect(!url.absoluteString.contains("SECRET"))
    }

    @Test func missingBaseURLYieldsNil() throws {
        let context = try operation("/v1beta/models/main:generateContent")
        #expect(GeminiEndpoint.upstreamURL(baseURL: "  ", realModel: "m", context: context) == nil)
    }

    @Test func normalizesModelResourceAndRejectsUnsafeModels() throws {
        let context = try operation("/v1beta/models/main:generateContent")
        // 常用写法 `models/gemini-X` 只去一次前缀，绝不拼出 models/models。
        let prefixed = try #require(GeminiEndpoint.upstreamURL(
            baseURL: "https://g.example/v1beta", realModel: "models/gemini-2.0-flash", context: context))
        #expect(prefixed.absoluteString == "https://g.example/v1beta/models/gemini-2.0-flash:generateContent")
        #expect(GeminiEndpoint.normalizedModelResource("models/gemini-pro") == "gemini-pro")
        #expect(GeminiEndpoint.normalizedModelResource("gemini-pro") == "gemini-pro")
        // 路径逃逸 / 多段 → 拒绝。
        #expect(GeminiEndpoint.upstreamURL(baseURL: "https://g.example/v1beta", realModel: "a/b", context: context) == nil)
        #expect(GeminiEndpoint.upstreamURL(baseURL: "https://g.example/v1beta", realModel: "../x", context: context) == nil)
        #expect(GeminiEndpoint.normalizedModelResource("..") == nil)
    }

    @Test func encodesUnsafeModelCharactersIntoOneSegment() {
        #expect(GeminiEndpoint.encodeSegment("a/b:c d") == "a%2Fb%3Ac%20d")
        #expect(GeminiEndpoint.encodeSegment("gemini-1.5-pro") == "gemini-1.5-pro")
    }

    @Test func countTokensRewritesOnlyNestedStringModel() {
        let withModel = Data(#"{"generateContentRequest":{"model":"models/main","contents":[]}}"#.utf8)
        let rewritten = GeminiEndpoint.rewriteCountTokensBody(withModel, realModel: "real")
        let object = try? JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        let nested = (object?["generateContentRequest"] as? [String: Any])?["model"] as? String
        #expect(nested == "models/real")

        // 嵌套缺失 / 非字符串 / 已一致 → 原样返回（不做任何重排）
        let noNested = Data(#"{"contents":[],"unknown":{"x":1}}"#.utf8)
        #expect(GeminiEndpoint.rewriteCountTokensBody(noNested, realModel: "real") == noNested)
        let nonString = Data(#"{"generateContentRequest":{"model":123}}"#.utf8)
        #expect(GeminiEndpoint.rewriteCountTokensBody(nonString, realModel: "real") == nonString)
        let already = Data(#"{"generateContentRequest":{"model":"models/real"}}"#.utf8)
        #expect(GeminiEndpoint.rewriteCountTokensBody(already, realModel: "real") == already)

        // realModel 自带 `models/` 资源前缀时也只去一次前缀。
        let prefixed = GeminiEndpoint.rewriteCountTokensBody(withModel, realModel: "models/real")
        let prefixedNested = (try? JSONSerialization.jsonObject(with: prefixed) as? [String: Any])
            .flatMap { $0["generateContentRequest"] as? [String: Any] }?["model"] as? String
        #expect(prefixedNested == "models/real")
    }

    // MARK: 本地载荷

    @Test func localModelPayloadHasNoInventedTokenLimits() {
        let payload = GeminiEndpoint.modelPayload(id: "main")
        #expect(payload["name"] as? String == "models/main")
        #expect(payload["displayName"] as? String == "main")
        #expect(payload["inputTokenLimit"] == nil)
        #expect(payload["outputTokenLimit"] == nil)
        #expect(payload["supportedGenerationMethods"] as? [String] ==
                ["generateContent", "streamGenerateContent", "countTokens"])
    }

    @Test func errorPayloadUsesGeminiStatusNames() {
        let notFound = GeminiEndpoint.errorPayload(status: 404, message: "nope")
        let error = notFound["error"] as? [String: Any]
        #expect(error?["code"] as? Int == 404)
        #expect(error?["status"] as? String == "NOT_FOUND")
        #expect(error?["message"] as? String == "nope")
        #expect(GeminiEndpoint.statusName(for: 429) == "RESOURCE_EXHAUSTED")
        #expect(GeminiEndpoint.statusName(for: 502) == "UNAVAILABLE")
    }
}
