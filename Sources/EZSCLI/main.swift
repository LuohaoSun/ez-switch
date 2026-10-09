import Foundation
import Darwin

private func configURL() -> URL {
    let env = ProcessInfo.processInfo.environment
    if let path = env["EZSWITCH_CONFIG"] ?? env["MODEL_ROUTER_CONFIG"], !path.isEmpty {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EZSwitch/config.json")
}

let client = SocketControlClient(socketPath: CLIControlLocation.socketPath(forConfig: configURL()))
do {
    let output = try EZSCLIRunner(client: client).run(Array(CommandLine.arguments.dropFirst()))
    if !output.isEmpty { print(output) }
} catch {
    fputs("ezs: \(error.localizedDescription)\n", stderr)
    exit(1)
}
