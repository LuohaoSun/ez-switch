import Foundation

struct CursorProxyStatus: Sendable, Equatable {
    var installed: Bool
    var running: Bool
    var authenticated: Bool
    var account: String?
    var models: [String]
    var error: String?
    var version: String?

    var connected: Bool { installed && running && authenticated && !models.isEmpty && error == nil }
}

struct CursorProxyEndpoint: Sendable {
    let baseURL: URL
    let apiKey: String
}

protocol CursorProxyClientProtocol: Sendable {
    func configure(root: URL) async throws
    func inspect() async -> CursorProxyStatus
    func login(openURL: @escaping @Sendable (URL) async throws -> Void) async throws
    func logout() async throws
    func stop() async
}

struct CursorProxyError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
