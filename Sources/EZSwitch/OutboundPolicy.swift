import Foundation
import Darwin
#if canImport(CFNetwork)
import CFNetwork
#endif
#if canImport(Network)
import Network
#endif

/// 出站代理策略。`.invalid` 保留原因、绝不静默退化为直连。
enum OutboundPolicy: Equatable, Sendable {
    case direct
    case proxy(URL)
    case invalid(String)

    /// 严格解析并校验用户填写的代理地址（scheme∈{http,https,socks5}，host+port 必填，
    /// path 仅空或 `/`，禁 query/fragment/userinfo/控制字符）。供 UI / 配置保存校验。
    static func validatedProxyURL(_ text: String) throws -> URL {
        // 控制字符按原始串判断：前后空格可 trim，换行/制表一律拒绝。
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw OutboundTransportError.controlCharacters
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw OutboundTransportError.emptyProxyURL }
        guard let components = URLComponents(string: trimmed) else {
            throw OutboundTransportError.notAURL(trimmed)
        }
        guard let rawScheme = components.scheme, !rawScheme.isEmpty else {
            throw OutboundTransportError.unsupportedScheme("")
        }
        let scheme = rawScheme.lowercased()
        guard let proxyScheme = OutboundProxyScheme(rawValue: scheme) else {
            throw OutboundTransportError.unsupportedScheme(scheme)
        }
        // https 代理（TLS-to-proxy）仅 macOS 14+ 支持，校验层即拒绝，使配置保存时就报错。
        if proxyScheme == .https, !OutboundTransport.secureProxyAvailable {
            throw OutboundTransportError.secureProxyRequiresMacOS14
        }
        guard let host = components.host, !host.isEmpty else {
            throw OutboundTransportError.missingHost
        }
        guard let port = components.port, (1...65535).contains(port) else {
            throw OutboundTransportError.missingPort
        }
        guard components.user == nil, components.password == nil else {
            throw OutboundTransportError.credentialsUnsupported
        }
        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            throw OutboundTransportError.unexpectedURLComponents("代理地址不能带路径：\(path)")
        }
        if components.query != nil {
            throw OutboundTransportError.unexpectedURLComponents("代理地址不能带 query")
        }
        if components.fragment != nil {
            throw OutboundTransportError.unexpectedURLComponents("代理地址不能带 fragment")
        }
        var canonical = URLComponents()
        canonical.scheme = scheme
        canonical.host = host
        canonical.port = port
        guard let url = canonical.url else { throw OutboundTransportError.notAURL(trimmed) }
        return url
    }
}

/// `https` 表示与代理之间走 TLS（TLS-to-proxy），与明文 `http`/`socks5` 区分。
enum OutboundProxyScheme: String, CaseIterable, Sendable {
    case http
    case https
    case socks5
}

/// 出站传输错误。刻意不 conform `ClientRequestFailure`：代理配置故障属后端/配置侧，不应折叠成 4xx。
enum OutboundTransportError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case emptyProxyURL
    case controlCharacters
    case notAURL(String)
    case unsupportedScheme(String)
    case missingHost
    case missingPort
    case unexpectedURLComponents(String)
    case credentialsUnsupported
    case secureProxyRequiresMacOS14
    case invalidPolicy(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .emptyProxyURL:
            return "代理地址为空。"
        case .controlCharacters:
            return "代理地址包含控制字符。"
        case .notAURL:
            return "代理地址格式无效。"
        case .unsupportedScheme(let scheme):
            if scheme.isEmpty { return "代理地址缺少 scheme，应为 http://、https:// 或 socks5://。" }
            return "不支持的代理 scheme“\(scheme)”，仅支持 http、https、socks5。"
        case .missingHost:
            return "代理地址缺少主机名。"
        case .missingPort:
            return "代理地址缺少端口，或端口超出 1...65535。"
        case .unexpectedURLComponents(let reason):
            return reason + "。"
        case .credentialsUnsupported:
            return "暂不支持带用户名/密码的代理；配置会明文保存凭据，请改用无认证代理。"
        case .secureProxyRequiresMacOS14:
            return "https:// 代理（TLS 到代理）需要 macOS 14 或更高版本；当前系统不受支持。"
        case .invalidPolicy(let reason):
            return "出站代理配置无效：\(reason)"
        }
    }
}

/// 把 ``OutboundPolicy`` 映射为可复用的 `URLSession`。
///
/// 两条硬约束（实测）：
/// 1. CFNetwork 只对 http:// 目标用 `HTTPProxy` 键，https:// 目标必须用 `HTTPSProxy` 键，故 http 代理两套都设，否则 https 目标会绕过代理直连。
/// 2. 代理会话绝不设 `connectionProxyDictionary`：非 nil 空字典会让 `proxyConfigurations` 失效并静默直连（实测）。
enum OutboundTransport {
    /// 当前系统是否具备 TLS-to-proxy（`https://` 代理）能力，即 macOS 14+。
    static var secureProxyAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    static func validateProxyURL(_ text: String) throws -> URL {
        try OutboundPolicy.validatedProxyURL(text)
    }

    /// 由策略取得可复用的出站会话。相同策略返回同一实例。
    /// `.invalid` 抛 ``OutboundTransportError/invalidPolicy(_:)``（后端错误，非 `ClientRequestFailure`）。
    static func session(for policy: OutboundPolicy) throws -> URLSession {
        switch policy {
        case .direct:
            return try cachedSession(key: .direct) { makeDirectSession() }
        case .invalid(let reason):
            throw OutboundTransportError.invalidPolicy(reason)
        case .proxy(let url):
            return try cachedSession(key: .proxy(url.absoluteString)) { try makeProxySession(for: url) }
        }
    }

    // CFNetwork can bypass explicit proxies for loopback destinations.
    static func validateDestination(_ url: URL, policy: OutboundPolicy) throws {
        guard case .proxy = policy, let rawHost = url.host else { return }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        var loopback = host == "localhost" || host.hasSuffix(".localhost")
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            loopback = loopback || UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            loopback = loopback || (bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1)
            let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
            loopback = loopback || (mapped && bytes[12] == 127)
        }
        if loopback {
            throw OutboundTransportError.invalidPolicy("本机回环上游不支持出站代理，请取消该供应商的代理选择")
        }
    }

    private static func baseConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600
        cfg.timeoutIntervalForResource = 7200
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return cfg
    }

    private static func makeDirectSession() -> URLSession {
        let cfg = baseConfiguration()
        cfg.connectionProxyDictionary = [:] // 绕开 macOS 系统代理
        return URLSession(configuration: cfg)
    }

    private static func makeProxySession(for url: URL) throws -> URLSession {
        // 再次完整校验：防止手工构造的 .proxy 用 userinfo/path/query 绕过策略。
        let validated = try OutboundPolicy.validatedProxyURL(url.absoluteString)
        guard let rawScheme = validated.scheme,
              let scheme = OutboundProxyScheme(rawValue: rawScheme),
              let host = validated.host,
              let port = validated.port else {
            throw OutboundTransportError.notAURL(url.absoluteString)
        }
        let cfg = baseConfiguration()
        switch scheme {
        case .http, .socks5:
            cfg.connectionProxyDictionary = proxyDictionary(scheme: scheme, host: host, port: port)
            return proxySession(configuration: cfg)
        case .https:
            return try makeSecureProxySession(config: cfg, host: host, port: port)
        }
    }

    private static func proxyDictionary(scheme: OutboundProxyScheme,
                                        host: String, port: Int) -> [AnyHashable: Any] {
        switch scheme {
        case .http:
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        case .socks5:
            return [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
            ]
        case .https:
            return [:] // 不可达：https 走 proxyConfigurations。
        }
    }

    private static func makeSecureProxySession(config: URLSessionConfiguration,
                                               host: String, port: Int) throws -> URLSession {
        #if canImport(Network)
        if #available(macOS 14.0, *) {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                throw OutboundTransportError.missingPort
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            // 约束 2：只设 proxyConfigurations，绝不设 connectionProxyDictionary。
            var proxy = ProxyConfiguration(httpCONNECTProxy: endpoint,
                                           tlsOptions: NWProtocolTLS.Options())
            proxy.allowFailover = false
            config.proxyConfigurations = [proxy]
            return proxySession(configuration: config)
        }
        #endif
        throw OutboundTransportError.secureProxyRequiresMacOS14
    }

    private static func proxySession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: ProxyRedirectDelegate(), delegateQueue: nil)
    }

    private final class ProxyRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // A redirect must not turn a proxied catalog request into a local direct request.
            completionHandler(nil)
        }
    }

    private enum CacheKey: Hashable {
        case direct
        case proxy(String)
    }

    private static let cacheLock = NSLock()
    private static var sessionCache: [CacheKey: URLSession] = [:]

    private static func cachedSession(key: CacheKey,
                                      make: () throws -> URLSession) throws -> URLSession {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = sessionCache[key] { return existing }
        let session = try make()
        sessionCache[key] = session
        return session
    }
}
