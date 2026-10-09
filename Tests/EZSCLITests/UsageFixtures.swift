import Foundation
@testable import EZSCLI

/// Builders for server-shaped usage payloads used across the CLI tests.
enum UsageFixture {
    static func totals(input: Int = 1_200, output: Int = 300, cachedInput: Int = 100,
                       cacheWrite: Int = 20, reasoning: Int = 10, requests: Int = 8,
                       attempts: Int = 10, knownAttempts: Int = 8, inputAttempts: Int = 8,
                       outputAttempts: Int = 8, cachedInputAttempts: Int = 3,
                       failedAttempts: Int = 2, total: Int = 1_500, coverage: Double = 0.8) -> [String: Any] {
        [
            "input": input, "output": output, "cachedInput": cachedInput, "cacheWrite": cacheWrite,
            "reasoning": reasoning, "requests": requests, "attempts": attempts,
            "knownAttempts": knownAttempts, "inputAttempts": inputAttempts,
            "outputAttempts": outputAttempts, "cachedInputAttempts": cachedInputAttempts,
            "failedAttempts": failedAttempts, "total": total, "coverage": coverage,
        ]
    }

    static func zeroTotals() -> [String: Any] {
        totals(input: 0, output: 0, cachedInput: 0, cacheWrite: 0, reasoning: 0, requests: 0,
               attempts: 0, knownAttempts: 0, inputAttempts: 0, outputAttempts: 0,
               cachedInputAttempts: 0, failedAttempts: 0, total: 0, coverage: 0)
    }

    static func usageObject(from: String = "2026-10-08", to: String = "2026-10-08",
                            timeZone: String = "America/Los_Angeles", grouping: String = "route",
                            limit: Int = 100, groupCount: Int = 1, truncated: Bool = false,
                            totals: [String: Any]? = nil,
                            days: [[String: Any]] = [["date": "2026-10-08", "input": 100, "output": 40]],
                            groups: [[String: Any]]? = nil) -> [String: Any] {
        let resolvedGroups = groups
            ?? [["id": "main", "title": "main", "subtitle": "", "totals": totals ?? Self.totals()]]
        return [
            "range": ["from": from, "to": to,
                      "start": "\(from)T00:00:00-07:00",
                      "endExclusive": "\(to)T00:00:00-07:00",
                      "timeZone": timeZone],
            "grouping": grouping,
            "limit": limit,
            "groupCount": groupCount,
            "truncated": truncated,
            "totals": totals ?? Self.totals(),
            "days": days,
            "groups": resolvedGroups,
        ]
    }

    static func envelopeData(_ usage: [String: Any]?, ok: Bool = true, message: String? = nil) -> Data {
        var object: [String: Any] = ["ok": ok]
        if let message { object["message"] = message }
        if let usage { object["usage"] = usage }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

/// Records every payload it is asked to send and returns a canned response.
final class FakeControlClient: ControlClient {
    var response: Data
    private(set) var sentPayloads: [[String: String]] = []

    init(response: Data) { self.response = response }

    func send(_ payload: [String: String]) throws -> Data {
        sentPayloads.append(payload)
        return response
    }
}
