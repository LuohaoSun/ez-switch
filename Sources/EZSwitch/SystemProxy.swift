import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

/// macOS 系统代理设置的只读快照。
///
/// 出站「跟随系统代理」不需要把地址抄出来再配给 `URLSession`：只要不设
/// `connectionProxyDictionary`，CFNetwork 就会按系统设置逐连接决定（含 PAC 与例外列表）。
/// 这里读快照只做两件事：给会话缓存算指纹（系统代理一改就换新会话，避免复用按旧设置
/// 建立的连接池），以及让设置页能把「当前到底走没走代理」如实显示出来。
struct SystemProxySnapshot: Equatable, Sendable {
    struct Endpoint: Equatable, Sendable {
        var host: String
        var port: Int
    }

    var http: Endpoint?
    var https: Endpoint?
    var socks: Endpoint?
    /// PAC 已启用（脚本地址可能不可读，故与 `pacURL` 分开记录）。
    var pacEnabled: Bool = false
    /// 已启用 PAC 时的脚本地址。
    var pacURL: URL?
    /// 已启用 WPAD 自动发现。
    var autoDiscovery: Bool = false

    static let empty = SystemProxySnapshot()

    /// 系统当前是否配置了任何出站代理。
    var isActive: Bool {
        http != nil || https != nil || socks != nil || pacEnabled || autoDiscovery
    }

    /// 缓存键指纹：只关心会影响出站路径的字段，且与字典键序无关。
    var fingerprint: String {
        func endpoint(_ value: Endpoint?) -> String {
            guard let value else { return "-" }
            return "\(value.host):\(value.port)"
        }
        return [
            "http=\(endpoint(http))",
            "https=\(endpoint(https))",
            "socks=\(endpoint(socks))",
            "pac=\(pacEnabled ? 1 : 0):\(pacURL?.absoluteString ?? "-")",
            "wpad=\(autoDiscovery ? 1 : 0)",
        ].joined(separator: "|")
    }

    /// 容错解析 `CFNetworkCopySystemProxySettings()` 的字典：值可能是 NSNumber/NSString，
    /// 也可能是缺键、空串或越界端口；任何异常字段都按「未配置」处理，不影响其它字段。
    init(dictionary: [String: Any]) {
        http = Self.endpoint(dictionary, enableKey: "HTTPEnable",
                             hostKey: "HTTPProxy", portKey: "HTTPPort")
        https = Self.endpoint(dictionary, enableKey: "HTTPSEnable",
                              hostKey: "HTTPSProxy", portKey: "HTTPSPort")
        socks = Self.endpoint(dictionary, enableKey: "SOCKSEnable",
                              hostKey: "SOCKSProxy", portKey: "SOCKSPort")
        pacEnabled = Self.flag(dictionary, "ProxyAutoConfigEnable")
        if pacEnabled, let raw = Self.string(dictionary, "ProxyAutoConfigURLString") {
            pacURL = URL(string: raw)
        }
        autoDiscovery = Self.flag(dictionary, "ProxyAutoDiscoveryEnable")
    }

    private init() {}

    // MARK: 字典读取

    private static func flag(_ dictionary: [String: Any], _ key: String) -> Bool {
        if let number = dictionary[key] as? NSNumber { return number.boolValue }
        if let text = dictionary[key] as? String {
            return text == "1" || text.lowercased() == "true"
        }
        return false
    }

    private static func string(_ dictionary: [String: Any], _ key: String) -> String? {
        guard let raw = dictionary[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func portValue(_ dictionary: [String: Any], _ key: String) -> Int? {
        let value: Int?
        if let number = dictionary[key] as? NSNumber {
            value = number.intValue
        } else if let text = dictionary[key] as? String {
            value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
        guard let value, (1...65535).contains(value) else { return nil }
        return value
    }

    private static func endpoint(_ dictionary: [String: Any], enableKey: String,
                                 hostKey: String, portKey: String) -> Endpoint? {
        guard flag(dictionary, enableKey),
              let host = string(dictionary, hostKey),
              let port = portValue(dictionary, portKey) else { return nil }
        return Endpoint(host: host, port: port)
    }
}

enum SystemProxy {
    /// 读取当前系统代理快照。
    static func current() -> SystemProxySnapshot {
        SystemProxySnapshot(dictionary: rawSettings())
    }

    static func rawSettings() -> [String: Any] {
        #if canImport(CFNetwork)
        guard let unmanaged = CFNetworkCopySystemProxySettings() else { return [:] }
        return unmanaged.takeRetainedValue() as? [String: Any] ?? [:]
        #else
        return [:]
        #endif
    }
}
