import Foundation
import Darwin
import NIOCore
import NIOPosix

/// The control socket lives in a private directory, separate from the public model API.
enum CLIControlPath {
    static func directory(for configURL: URL) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("ezs-control", isDirectory: true)
    }

    static func socket(for configURL: URL) -> URL {
        directory(for: configURL).appendingPathComponent("control.sock")
    }
}

final class CLIControlServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let socketURL: URL
    private var channel: Channel?

    init(configURL: URL) {
        socketURL = CLIControlPath.socket(for: configURL)
    }

    func start(store: ConfigStore) throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // A stale socket may remain after a crash. Never remove an active listener.
        if FileManager.default.fileExists(atPath: socketURL.path) {
            var statBuffer = stat()
            guard lstat(socketURL.path, &statBuffer) == 0,
                  (statBuffer.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
            }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if fd >= 0 {
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(socketURL.path.utf8CString)
                guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                    Darwin.close(fd)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
                }
                withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map(UInt8.init)) }
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                    }
                }
                let connectionError = errno
                Darwin.close(fd)
                if connected { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE)) }
                guard connectionError == ECONNREFUSED || connectionError == ENOENT else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(connectionError))
                }
            } else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try FileManager.default.removeItem(at: socketURL)
        }
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(CLIControlHandler(store: store))
            }
        channel = try bootstrap.bind(unixDomainSocketPath: socketURL.path).wait()
        guard chmod(socketURL.path, 0o600) == 0 else {
            try? channel?.close().wait()
            try? FileManager.default.removeItem(at: socketURL)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

private final class CLIControlHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let store: ConfigStore
    private var input = Data()
    private var submitted = false

    init(store: ConfigStore) { self.store = store }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !submitted else { return }
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        input.append(contentsOf: bytes)
        guard input.count <= 64 * 1024 else {
            submitted = true
            respond(["ok": false, "message": "command too large"], context: context)
            return
        }
        guard let newline = input.firstIndex(of: 10) else { return }
        submitted = true
        let line = input.prefix(upTo: newline)
        let channel = context.channel
        Task { @MainActor [store] in
            let reply = store.handleCLICommand(Data(line))
            channel.eventLoop.execute {
                Self.write(reply, to: channel)
            }
        }
    }

    private func respond(_ reply: [String: Any], context: ChannelHandlerContext) {
        Self.write(reply, to: context.channel)
    }

    private static func write(_ reply: [String: Any], to channel: Channel) {
        var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"ok":false,"message":"serialization failed"}"#.utf8)
        data.append(10)
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer).whenComplete { _ in channel.close(promise: nil) }
    }
}

extension ConfigStore {
    func handleCLICommand(_ data: Data) -> [String: Any] {
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = request["command"] as? String else {
            return ["ok": false, "message": "invalid command"]
        }
        switch command {
        case "list":
            let remotes = Dictionary(uniqueKeysWithValues: config.remotes.map { ($0.id, $0) })
            let routes: [[String: String]] = config.fakes.map { fake in
                let remote = fake.remoteID.flatMap { remotes[$0] }
                return ["modelID": fake.fakeModelID,
                        "provider": remote.map { splitProviderModel($0.name).provider } ?? "",
                        "model": remote?.model ?? ""]
            }
            let providers: [[String: Any]] = groupedRemotes().map { group in
                ["name": group.provider,
                 "models": group.remotes.map { ["id": $0.id.uuidString, "model": $0.model] }]
            }
            return ["ok": true, "routes": routes, "providers": providers]
        case "set":
            guard let fakeID = request["fakeID"] as? String,
                  let fake = config.fakes.first(where: { $0.fakeModelID == fakeID }) else {
                return ["ok": false, "message": "route not found"]
            }
            let matches: [RemoteModel]
            if let idString = request["remoteID"] as? String {
                guard let id = UUID(uuidString: idString) else {
                    return ["ok": false, "message": "invalid remote UUID"]
                }
                matches = config.remotes.filter { $0.id == id }
            } else if let provider = request["provider"] as? String,
                      let model = request["model"] as? String {
                matches = config.remotes.filter {
                    splitProviderModel($0.name).provider == provider && $0.model == model
                }
            } else {
                return ["ok": false, "message": "provide --provider and --model, or --remote-id"]
            }
            guard matches.count == 1, let remote = matches.first else {
                return ["ok": false, "message": matches.isEmpty ? "upstream model not found" : "ambiguous upstream model; use --remote-id"]
            }
            setRoute(fakeID: fake.id, remoteID: remote.id)
            return ["ok": true, "message": "\(fakeID) → \(splitProviderModel(remote.name).provider) / \(remote.model)"]
        default:
            return ["ok": false, "message": "unknown command"]
        }
    }
}
