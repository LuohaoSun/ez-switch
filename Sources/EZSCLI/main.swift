import Foundation
import Darwin

private struct Route: Decodable {
    let modelID: String
    let provider: String
    let model: String
}
private struct Upstream: Decodable {
    let id: String
    let model: String
}
private struct Provider: Decodable {
    let name: String
    let models: [Upstream]
}
private struct Reply: Decodable {
    let ok: Bool
    let message: String?
    let routes: [Route]?
    let providers: [Provider]?
}

private func configURL() -> URL {
    let env = ProcessInfo.processInfo.environment
    if let path = env["EZSWITCH_CONFIG"] ?? env["MODEL_ROUTER_CONFIG"], !path.isEmpty {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EZSwitch/config.json")
}

private func request(_ object: [String: String]) throws -> Reply {
    let path = configURL().deletingLastPathComponent().appendingPathComponent("ezs-control/control.sock").path
    let bytes = Array(path.utf8CString)
    var address = sockaddr_un()
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map(UInt8.init)) }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var payload = try JSONSerialization.data(withJSONObject: object)
    payload.append(10)
    try payload.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < raw.count {
            let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            sent += count
        }
    }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while reply.count < 1_048_576 {
        let readCount = Darwin.read(fd, &buffer, buffer.count)
        guard readCount > 0 else { break }
        reply.append(contentsOf: buffer.prefix(readCount))
        if let end = reply.firstIndex(of: 10) {
            return try JSONDecoder().decode(Reply.self, from: Data(reply[..<end]))
        }
    }
    throw NSError(domain: "ezs", code: 1, userInfo: [NSLocalizedDescriptionKey: "control response missing or too large"])
}

private let helpText = """
Usage:
  ezs list
  ezs set <model-id> --provider <name> --model <upstream-model>
  ezs set <model-id> --remote-id <UUID>
  ezs help | -h | --help

Commands:
  list    Show current routes and models grouped by provider.
  set     Switch a route to an upstream model and save it in EZ Switch.

Options:
  -h, --help    Show this help.

EZ Switch must be running. Provider names or model IDs containing spaces should be quoted.
"""

private func run(_ args: [String]) throws {
    if args.isEmpty || args == ["help"] || args == ["-h"] || args == ["--help"] ||
       (args.count == 2 && ["list", "set"].contains(args[0]) && ["-h", "--help"].contains(args[1])) {
        print(helpText)
        return
    }
    let command: [String: String]
    switch args.first {
    case "list" where args.count == 1:
        command = ["command": "list"]
    case "set" where args.count >= 2:
        var values: [String: String] = ["command": "set", "fakeID": args[1]]
        var index = 2
        while index < args.count {
            guard index + 1 < args.count, ["--provider", "--model", "--remote-id"].contains(args[index]),
                  values[args[index]] == nil else { throw CLIError.usage }
            values[args[index]] = args[index + 1]
            index += 2
        }
        if let id = values["--remote-id"] {
            guard UUID(uuidString: id) != nil, values["--provider"] == nil, values["--model"] == nil else { throw CLIError.usage }
            values["remoteID"] = id
        } else {
            guard let provider = values["--provider"], let model = values["--model"] else { throw CLIError.usage }
            values["provider"] = provider
            values["model"] = model
        }
        command = values.filter { !$0.key.hasPrefix("--") }
    default:
        throw CLIError.usage
    }
    let reply = try request(command)
    guard reply.ok else { throw CLIError.server(reply.message ?? "command failed") }
    if command["command"] == "set" {
        print(reply.message ?? "route updated")
    } else {
        print("Routes")
        for route in reply.routes ?? [] {
            print("  \(route.modelID)  → \(route.provider.isEmpty ? "未绑定" : "\(route.provider) / \(route.model)")")
        }
        print("\nProviders")
        for provider in reply.providers ?? [] {
            print("  \(provider.name)")
            for model in provider.models { print("    \(model.model)") }
        }
    }
}

private enum CLIError: Error, LocalizedError {
    case usage
    case server(String)
    var errorDescription: String? {
        switch self {
        case .usage: return "Invalid arguments. Run ezs --help for usage."
        case .server(let message): return message
        }
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("ezs: \(error.localizedDescription)\n", stderr)
    exit(1)
}
