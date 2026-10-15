import Foundation
import Testing
@testable import EZSwitch

@Suite("Pinned Cursor sidecar acceptance")
struct CursorSidecarAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZSWITCH_CURSOR_PROXY_ACCEPTANCE"] == "1"))
    func publishedHelperAcceptsConfigurationWithoutAnAccount() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["EZSWITCH_CURSOR_PROXY"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZSwitchProxyAcceptance-\(UUID().uuidString).noindex", isDirectory: true)
        let client = CursorSidecarClient(executable: URL(fileURLWithPath: binary))
        do {
            try await client.configure(root: root)
            #expect(!FileManager.default.fileExists(atPath: root.path))
            let first = await client.inspect()
            #expect(first.installed)
            #expect(first.running)
            #expect(!first.authenticated)
            #expect(first.models.isEmpty)
            #expect(first.error == nil)
            #expect(first.version == CursorExtension.proxyVersion)
            let config = root.appendingPathComponent("runtime/config.yaml")
            let attributes = try FileManager.default.attributesOfItem(atPath: config.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("auth").path).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/static/management.html").path))
            do {
                _ = try await client.requestEndpoint()
                Issue.record("Unauthenticated helper exposed an inference endpoint")
            } catch {}
            await client.stop()
            let restarted = await client.inspect()
            #expect(restarted.running)
            #expect(!restarted.authenticated)
            #expect(restarted.error == nil)
            await client.stop()
        } catch {
            await client.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        // stop sends TERM immediately; no request or OAuth login is made by this acceptance test.
        try? FileManager.default.removeItem(at: root)
    }
}
