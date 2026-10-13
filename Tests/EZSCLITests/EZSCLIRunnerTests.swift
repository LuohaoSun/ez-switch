import Foundation
import Testing
@testable import EZSCLI

@Suite("ezs command runner")
struct EZSCLIRunnerTests {
    private func runner(_ response: [String: Any]) -> (EZSCLIRunner, FakeControlClient) {
        let client = FakeControlClient(response: UsageFixture.data(response))
        return (EZSCLIRunner(client: client), client)
    }

    @Test func helpUsesGeneralAndUsageText() throws {
        let (runner, client) = self.runner([:])
        #expect(try runner.run([]) == EZSCLIHelp.general)
        #expect(try runner.run(["help"]) == EZSCLIHelp.general)
        #expect(try runner.run(["--help"]) == EZSCLIHelp.general)
        #expect(try runner.run(["usage", "--help"]) == EZSCLIHelp.usage)
        #expect(try runner.run(["usage", "-h"]) == EZSCLIHelp.usage)
        #expect(try runner.run(["list", "--help"]) == EZSCLIHelp.general)
        #expect(client.sentPayloads.isEmpty, "help must not touch the socket")
        #expect(EZSCLIHelp.general.contains("local calendar"))
        #expect(EZSCLIHelp.general.contains("--to is inclusive"))
        #expect(EZSCLIHelp.usage.contains("7d covers today and the six"))
    }

    @Test func listStillRendersRoutesAndProviders() throws {
        let response: [String: Any] = [
            "ok": true,
            "routes": [["modelID": "main", "provider": "Alpha", "model": "one"],
                       ["modelID": "fast", "provider": "", "model": ""]],
            "providers": [["name": "Alpha", "models": [["id": UUID().uuidString, "model": "one"]]]],
        ]
        let (runner, client) = self.runner(response)
        let output = try runner.run(["list"])
        #expect(output == """
        Routes
          main  → Alpha / one
          fast  → 未绑定

        Providers
          Alpha
            one
        """)
        #expect(client.sentPayloads == [["command": "list"]])
    }

    @Test func setStillReturnsServerMessage() throws {
        let (runner, client) = self.runner(["ok": true, "message": "main → Alpha / one"])
        let output = try runner.run(["set", "main", "--provider", "Alpha", "--model", "one"])
        #expect(output == "main → Alpha / one")
        #expect(client.sentPayloads == [["command": "set", "fakeID": "main",
                                        "provider": "Alpha", "model": "one"]])
    }

    @Test func setRejectsAmbiguousArguments() {
        let (runner, _) = self.runner(["ok": true])
        #expect(throws: CLIArgumentError.usage) {
            _ = try runner.run(["set", "main", "--provider", "Alpha"])
        }
        #expect(throws: CLIArgumentError.usage) {
            _ = try runner.run(["set", "main", "--remote-id", "not-a-uuid"])
        }
    }

    @Test func usageSendsResolvedDefaultsAndNoJSONFlag() throws {
        let usage = UsageFixture.usageObject()
        let (runner, client) = self.runner(["ok": true, "usage": usage])
        _ = try runner.run(["usage"])
        #expect(client.sentPayloads == [["command": "usage", "period": "today",
                                        "group": "route", "limit": "100"]])
    }

    @Test func usageJSONPrintsOnlyTheUsageObject() throws {
        let usage = UsageFixture.usageObject()
        let (runner, client) = self.runner(["ok": true, "usage": usage])
        let output = try runner.run(["usage", "--json", "--group", "model", "--limit", "5"])
        #expect(!output.contains("\"ok\""))
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(decoded["grouping"] as? String == "route")
        #expect(decoded["totals"] != nil)
        #expect(client.sentPayloads == [["command": "usage", "period": "today",
                                        "group": "model", "limit": "5"]])
    }

    @Test func usageCustomRangeSendsFromTo() throws {
        let (runner, client) = self.runner(["ok": true, "usage": UsageFixture.usageObject()])
        _ = try runner.run(["usage", "--from", "2026-01-01", "--to", "2026-01-31", "--json"])
        #expect(client.sentPayloads == [["command": "usage", "from": "2026-01-01",
                                        "to": "2026-01-31", "group": "route", "limit": "100"]])
    }

    // MARK: - Performance compatibility

    @Test func usageWithoutPerformanceFlagIsUnchanged() throws {
        let (runner, client) = self.runner(["ok": true, "usage": UsageFixture.usageObject()])
        let output = try runner.run(["usage"])
        #expect(client.sentPayloads == [["command": "usage", "period": "today",
                                        "group": "route", "limit": "100"]])
        #expect(client.sentPayloads[0]["performance"] == nil)
        #expect(!output.contains("Performance ("))
    }

    @Test func usagePerformanceSendsFlagAndDefaultsGroupToModel() throws {
        let usage = UsageFixture.usageObject()
        let response: [String: Any] = ["ok": true, "usage": usage,
                                       "performance": UsageFixture.performanceObject(grouping: "model")]
        let (runner, client) = self.runner(response)
        let output = try runner.run(["usage", "--performance"])

        #expect(client.sentPayloads == [["command": "usage", "period": "today",
                                        "group": "model", "limit": "100", "performance": "true"]])
        // The usage report is still printed, followed by the performance section.
        #expect(output.contains("Totals"))
        #expect(output.contains("Performance (model)"))
        #expect(output.contains("TTFT basis: upstream attempt"))
    }

    @Test func usagePerformanceJSONPrintsCombinedObjects() throws {
        let usage = UsageFixture.usageObject()
        let response: [String: Any] = ["ok": true, "usage": usage,
                                       "performance": UsageFixture.performanceObject()]
        let (runner, client) = self.runner(response)
        let output = try runner.run(["usage", "--performance", "--json", "--group", "provider"])

        #expect(client.sentPayloads == [["command": "usage", "period": "today",
                                        "group": "provider", "limit": "100", "performance": "true"]])
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(decoded["usage"] != nil)
        #expect((decoded["performance"] as? [String: Any])?["grouping"] as? String == "model")
        #expect(!output.contains("\"ok\""))
    }

    @Test func usagePerformanceAgainstOldServerGivesUpgradeHint() {
        // Old app answers usage but never returns a performance object.
        let (runner, _) = self.runner(["ok": true, "usage": UsageFixture.usageObject()])
        do {
            _ = try runner.run(["usage", "--performance"])
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("performance"))
            #expect(error.localizedDescription.contains("update and restart"))
        }
    }

    @Test func oldServerUnknownCommandGivesUpgradeHint() {
        let (runner, _) = self.runner(["ok": false, "message": "unknown command"])
        do {
            _ = try runner.run(["usage"])
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("update and restart"))
        }
    }

    @Test func serverFailureMessageIsSurfaced() {
        let (runner, _) = self.runner(["ok": false, "message": "usage database unavailable"])
        do {
            _ = try runner.run(["usage"])
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "usage database unavailable")
        }
    }

    @Test func unknownCommandIsRejected() {
        let (runner, _) = self.runner([:])
        #expect(throws: CLIArgumentError.usage) {
            _ = try runner.run(["bogus"])
        }
    }

    /// End-to-end over a real Unix socket: real args → real bytes → real output.
    @Test func realSocketRoundTripProducesUsageJSON() throws {
        let usage = UsageFixture.usageObject()
        let server = try TestControlServer(response: UsageFixture.envelopeData(usage))
        defer { server.shutdown() }

        let runner = EZSCLIRunner(client: SocketControlClient(socketPath: server.path))
        let output = try runner.run(["usage", "--json", "--group", "provider", "--limit", "3"])

        let expected = try UsageTextFormatter.renderJSON(usage)
        #expect(output == expected)

        let request = try #require(server.waitForRequest())
        let requestObject = try #require(
            try JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any])
        #expect(requestObject["command"] as? String == "usage")
        #expect(requestObject["group"] as? String == "provider")
        #expect(requestObject["limit"] as? String == "3")
        #expect(requestObject["json"] == nil, "the json flag must never be sent to the server")
    }
}
