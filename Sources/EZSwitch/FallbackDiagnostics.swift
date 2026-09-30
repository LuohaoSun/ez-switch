import Foundation

struct FallbackDiagnostics {
    static let bodyLimit = 4096

    static func clean(_ text: String, remote: RemoteModel) -> String {
        var value = text
        for secret in [remote.apiKey] + Array(remote.extraHeaders.values) where !secret.isEmpty {
            value = value.replacingOccurrences(of: secret, with: "[redacted]")
        }
        value = value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return String(value.prefix(400))
    }

    static func summary(response: HTTPURLResponse, body: Data, remote: RemoteModel) -> String {
        var parts = ["HTTP \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))"]
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let error = json["error"] as? [String: Any] ?? json
            for key in ["type", "code", "message"] {
                if let value = error[key], !(value is NSNull) {
                    parts.append("\(key)=\(value)")
                }
            }
            if let error = json["error"] as? String { parts.append("error=\(error)") }
        } else if !body.isEmpty {
            parts.append("body=\(String(decoding: body, as: UTF8.self))")
        }
        for name in ["x-request-id", "request-id", "retry-after"] {
            if let value = response.value(forHTTPHeaderField: name) {
                parts.append("\(name)=\(value)")
            }
        }
        return clean(parts.joined(separator: "; "), remote: remote)
    }

    static func readErrorBody(_ upstream: UpstreamResponse) async -> Data {
        await withTaskGroup(of: Data.self) { group in
            group.addTask {
                var data = Data()
                do {
                    for try await chunk in upstream.body {
                        let count = min(chunk.readableBytes, bodyLimit - data.count)
                        if let bytes = chunk.getBytes(at: chunk.readerIndex, length: count) {
                            data.append(contentsOf: bytes)
                        }
                        if data.count == bodyLimit { break }
                    }
                } catch {}
                return data
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return Data()
            }
            let data = await group.next() ?? Data()
            group.cancelAll()
            return data
        }
    }
}
