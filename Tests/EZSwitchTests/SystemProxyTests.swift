import Foundation
import Testing
@testable import EZSwitch

/// 系统代理快照的解析与指纹：只读 `CFNetworkCopySystemProxySettings()` 的字典形状，
/// 不依赖测试机当前的代理设置，也不改动任何系统状态。
@Suite("System proxy snapshot")
struct SystemProxySnapshotTests {
    @Test func emptySettingsMeanInactive() {
        let snapshot = SystemProxySnapshot(dictionary: [:])
        #expect(!snapshot.isActive)
        #expect(snapshot.http == nil)
        #expect(snapshot.https == nil)
        #expect(snapshot.socks == nil)
        #expect(snapshot.pacURL == nil)
        #expect(snapshot.fingerprint == "http=-|https=-|socks=-|pac=0:-|wpad=0")
    }

    @Test func httpProxyParsesNumberAndStringValues() {
        let numeric = SystemProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
        ])
        #expect(numeric.http == .init(host: "127.0.0.1", port: 7890))
        #expect(numeric.isActive)

        // 真实设置里也可能是字符串。
        let textual = SystemProxySnapshot(dictionary: [
            "HTTPEnable": "1", "HTTPProxy": " proxy.local ", "HTTPPort": "3128",
        ])
        #expect(textual.http == .init(host: "proxy.local", port: 3128))
    }

    @Test func disabledOrMalformedEntriesAreIgnored() {
        let disabled = SystemProxySnapshot(dictionary: [
            "HTTPEnable": 0, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
        ])
        #expect(disabled.http == nil)
        #expect(!disabled.isActive)

        for port in [0, 70000, -1] as [Any] {
            let snapshot = SystemProxySnapshot(dictionary: [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            ])
            #expect(snapshot.http == nil)
        }

        let garbage = SystemProxySnapshot(dictionary: [
            "HTTPEnable": "yes", "HTTPProxy": "", "HTTPPort": "abc",
        ])
        #expect(garbage.http == nil)
        #expect(!garbage.isActive)
    }

    @Test func socksAndSeparateHTTPSAreRead() {
        let snapshot = SystemProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
            "HTTPSEnable": 1, "HTTPSProxy": "secure.local", "HTTPSPort": 8443,
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1080,
        ])
        #expect(snapshot.https == .init(host: "secure.local", port: 8443))
        #expect(snapshot.socks == .init(host: "127.0.0.1", port: 1080))
    }

    @Test func pacAndAutoDiscoveryAreReportedEvenWithoutScriptURL() {
        let pac = SystemProxySnapshot(dictionary: [
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "http://pac.test/proxy.pac",
        ])
        #expect(pac.pacEnabled)
        #expect(pac.pacURL?.host == "pac.test")
        #expect(pac.isActive)

        let unreadable = SystemProxySnapshot(dictionary: ["ProxyAutoConfigEnable": 1])
        #expect(unreadable.pacEnabled)
        #expect(unreadable.pacURL == nil)
        #expect(unreadable.isActive)

        let wpad = SystemProxySnapshot(dictionary: ["ProxyAutoDiscoveryEnable": 1])
        #expect(wpad.autoDiscovery)
        #expect(wpad.isActive)
    }

    @Test func fingerprintIgnoresKeyOrderAndFollowsEffectiveValues() {
        let first = SystemProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
        ])
        let reordered = SystemProxySnapshot(dictionary: [
            "HTTPPort": 7890, "HTTPProxy": "127.0.0.1", "HTTPEnable": 1,
        ])
        #expect(first.fingerprint == reordered.fingerprint)

        let moved = SystemProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8080,
        ])
        #expect(first.fingerprint != moved.fingerprint)
        #expect(SystemProxySnapshot.empty.fingerprint != first.fingerprint)
    }

    /// 生产入口只要求可读、不崩溃；具体内容取决于测试机设置，不做断言。
    @Test func currentSettingsAreReadable() {
        let snapshot = SystemProxy.current()
        #expect(!snapshot.fingerprint.isEmpty)
    }
}
