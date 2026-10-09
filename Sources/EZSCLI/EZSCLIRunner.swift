import Foundation

struct Route: Decodable {
    let modelID: String
    let provider: String
    let model: String
}

struct Upstream: Decodable {
    let id: String
    let model: String
}

struct Provider: Decodable {
    let name: String
    let models: [Upstream]
}

struct ControlReply: Decodable {
    let ok: Bool
    let message: String?
    let routes: [Route]?
    let providers: [Provider]?
}

enum CLIArgumentError: Error, LocalizedError, Equatable {
    case usage
    case server(String)

    var errorDescription: String? {
        switch self {
        case .usage: return "Invalid arguments. Run ezs --help for usage."
        case .server(let message): return message
        }
    }
}

/// Dispatches `ezs` subcommands and produces the exact text to print.
/// Socket access goes through `ControlClient`, so the whole arg → output mapping
/// can be exercised without a running app.
struct EZSCLIRunner {
    let client: ControlClient

    func run(_ arguments: [String]) throws -> String {
        if arguments.isEmpty || arguments == ["help"] || arguments == ["-h"] || arguments == ["--help"] {
            return EZSCLIHelp.general
        }
        if arguments == ["usage", "-h"] || arguments == ["usage", "--help"] {
            return EZSCLIHelp.usage
        }
        if arguments.count == 2, ["list", "set"].contains(arguments[0]),
           ["-h", "--help"].contains(arguments[1]) {
            return EZSCLIHelp.general
        }

        switch arguments.first {
        case "list" where arguments.count == 1:
            return try runList()
        case "set" where arguments.count >= 2:
            return try runSet(Array(arguments.dropFirst()))
        case "usage":
            return try runUsage(Array(arguments.dropFirst()))
        default:
            throw CLIArgumentError.usage
        }
    }

    // MARK: Commands

    private func runList() throws -> String {
        let reply = try decodeReply(client.send(["command": "list"]))
        guard reply.ok else {
            throw CLIArgumentError.server(reply.message ?? "command failed")
        }
        var lines = ["Routes"]
        for route in reply.routes ?? [] {
            let target = route.provider.isEmpty ? "未绑定" : "\(route.provider) / \(route.model)"
            lines.append("  \(route.modelID)  → \(target)")
        }
        lines.append("")
        lines.append("Providers")
        for provider in reply.providers ?? [] {
            lines.append("  \(provider.name)")
            for model in provider.models { lines.append("    \(model.model)") }
        }
        return lines.joined(separator: "\n")
    }

    private func runSet(_ args: [String]) throws -> String {
        var values: [String: String] = ["command": "set", "fakeID": args[0]]
        var index = 1
        while index < args.count {
            guard index + 1 < args.count,
                  ["--provider", "--model", "--remote-id"].contains(args[index]),
                  values[args[index]] == nil else { throw CLIArgumentError.usage }
            values[args[index]] = args[index + 1]
            index += 2
        }
        if let id = values["--remote-id"] {
            guard UUID(uuidString: id) != nil, values["--provider"] == nil, values["--model"] == nil else {
                throw CLIArgumentError.usage
            }
            values["remoteID"] = id
        } else {
            guard let provider = values["--provider"], let model = values["--model"] else {
                throw CLIArgumentError.usage
            }
            values["provider"] = provider
            values["model"] = model
        }
        let command = values.filter { !$0.key.hasPrefix("--") }
        let reply = try decodeReply(client.send(command))
        guard reply.ok else {
            throw CLIArgumentError.server(reply.message ?? "command failed")
        }
        return reply.message ?? "route updated"
    }

    private func runUsage(_ args: [String]) throws -> String {
        let options = try UsageArgumentParser.parse(args)
        let payload = UsageArgumentParser.requestPayload(options)
        let parsed = try UsageResponseParser.parse(client.send(payload))
        if options.json {
            return try UsageTextFormatter.renderJSON(parsed.jsonObject)
        }
        return UsageTextFormatter.render(parsed.report, options: options)
    }

    // MARK: Helpers

    private func decodeReply(_ data: Data) throws -> ControlReply {
        guard let reply = try? JSONDecoder().decode(ControlReply.self, from: data) else {
            throw CLIArgumentError.server("unexpected response from EZ Switch; make sure the app is running")
        }
        return reply
    }
}
