import Foundation
import Testing
@testable import EZSwitch

@MainActor
@Suite("Automatic update checker", .serialized)
struct AutomaticUpdateCheckerTests {
    @Test
    func silentAutomaticCheckPublishesAvailableRelease() async throws {
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let session = makeSession { _ in
            (httpResponse(statusCode: 200), releaseData(version: "0.2.0"))
        }
        defer { MockURLProtocol.reset() }

        let checker = UpdateChecker(currentVersion: "0.1.4", defaults: defaults, session: session)
        checker.startAutomaticChecks()

        let completed = await eventually {
            checker.availableRelease?.version == "0.2.0"
        }

        try #require(completed)
        let release = try #require(checker.availableRelease)
        #expect(release.version == "0.2.0")
        #expect(checker.state == .available(release))
        #expect(MockURLProtocol.requestCount == 1)
    }

    @Test
    func automaticChecksDefaultToEnabledAndDisablePersists() async {
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let session = makeSession { _ in
            (httpResponse(statusCode: 200), releaseData(version: "0.2.0"))
        }
        defer { MockURLProtocol.reset() }

        let checker = UpdateChecker(currentVersion: "0.1.4", defaults: defaults, session: session)
        #expect(checker.automaticallyChecksForUpdates)

        checker.setAutomaticallyChecksForUpdates(false)
        #expect(!checker.automaticallyChecksForUpdates)
        #expect(defaults.object(forKey: "automaticallyChecksForUpdates") as? Bool == false)

        let reloaded = UpdateChecker(currentVersion: "0.1.4", defaults: defaults, session: session)
        #expect(!reloaded.automaticallyChecksForUpdates)

        reloaded.startAutomaticChecks()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(MockURLProtocol.requestCount == 0)
    }

    @Test
    func enablingChecksImmediatelyEvenAfterRecentCheck() async {
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(false, forKey: "automaticallyChecksForUpdates")
        defaults.set(Date(), forKey: "lastUpdateCheckDate")
        defaults.set("0.1.4", forKey: "lastUpdateCheckVersion")

        let session = makeSession { _ in
            (httpResponse(statusCode: 200), releaseData(version: "0.2.0"))
        }
        defer { MockURLProtocol.reset() }

        let checker = UpdateChecker(currentVersion: "0.1.4", defaults: defaults, session: session)
        checker.startAutomaticChecks()
        #expect(MockURLProtocol.requestCount == 0)

        checker.setAutomaticallyChecksForUpdates(true)
        let completed = await eventually { checker.availableRelease?.version == "0.2.0" }
        #expect(completed)
        #expect(MockURLProtocol.requestCount == 1)
    }

    @Test
    func silentFailureRemainsIdle() async {
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let session = makeSession { _ in
            (httpResponse(statusCode: 500), Data())
        }
        defer { MockURLProtocol.reset() }

        let checker = UpdateChecker(currentVersion: "0.1.4", defaults: defaults, session: session)
        checker.startAutomaticChecks()

        let completed = await eventually {
            MockURLProtocol.requestCount == 1 && checker.state == .idle
        }

        #expect(completed)
        #expect(checker.availableRelease == nil)
        #expect(checker.state == .idle)
    }

    @Test
    func successfulCheckRecordsTimestampAndVersion() async {
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let session = makeSession { _ in
            (httpResponse(statusCode: 200), releaseData(version: "0.1.4"))
        }
        defer { MockURLProtocol.reset() }

        let checker = UpdateChecker(currentVersion: "0.1.4", defaults: defaults, session: session)
        let before = Date()
        await checker.check(silently: true)
        let after = Date()

        let checkedAt = defaults.object(forKey: "lastUpdateCheckDate") as? Date
        #expect(checkedAt.map { $0 >= before && $0 <= after } == true)
        #expect(defaults.string(forKey: "lastUpdateCheckVersion") == "0.1.4")
        #expect(checker.availableRelease == nil)
        #expect(checker.state == .upToDate)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "AutomaticUpdateCheckerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func makeSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.reset()
        MockURLProtocol.handler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func eventually(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private func releaseData(version: String) -> Data {
    Data("""
    {
      "tag_name": "v\(version)",
      "html_url": "https://github.com/LuohaoSun/ez-switch/releases/tag/v\(version)",
      "body": "Release notes",
      "assets": []
    }
    """.utf8)
}

private func httpResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.github.com/repos/LuohaoSun/ez-switch/releases/latest")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
}

private final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var storedRequestCount = 0

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    static var requestCount: Int { lock.withLock { storedRequestCount } }

    static func reset() {
        lock.withLock {
            storedHandler = nil
            storedRequestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.storedRequestCount += 1 }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
