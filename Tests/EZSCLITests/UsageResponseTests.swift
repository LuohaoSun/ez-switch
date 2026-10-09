import Foundation
import Testing
@testable import EZSCLI

@Suite("Usage response parsing")
struct UsageResponseTests {
    @Test func decodesFullReport() throws {
        let usage = UsageFixture.usageObject(groupCount: 3, truncated: true)
        let parsed = try UsageResponseParser.parse(UsageFixture.envelopeData(usage))

        #expect(parsed.report.range.from == "2026-10-08")
        #expect(parsed.report.range.to == "2026-10-08")
        #expect(parsed.report.range.start == "2026-10-08T00:00:00-07:00")
        #expect(parsed.report.range.endExclusive == "2026-10-08T00:00:00-07:00")
        #expect(parsed.report.range.timeZone == "America/Los_Angeles")
        #expect(parsed.report.grouping == "route")
        #expect(parsed.report.limit == 100)
        #expect(parsed.report.groupCount == 3)
        #expect(parsed.report.truncated)
        #expect(parsed.report.totals.input == 1_200)
        #expect(parsed.report.totals.total == 1_500)
        #expect(parsed.report.totals.coverage == 0.8)
        #expect(parsed.report.days.first?.date == "2026-10-08")
        #expect(parsed.report.groups.first?.title == "main")
    }

    @Test func keepsRawJSONObjectForExactOutput() throws {
        let usage = UsageFixture.usageObject()
        let parsed = try UsageResponseParser.parse(UsageFixture.envelopeData(usage))
        let expected = try JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys])
        let actual = try JSONSerialization.data(withJSONObject: parsed.jsonObject, options: [.sortedKeys])
        #expect(actual == expected)
    }

    @Test func surfacesServerFailureMessage() {
        let data = UsageFixture.envelopeData(nil, ok: false, message: "usage database unavailable")
        #expect(throws: UsageResponseError.server("usage database unavailable")) {
            _ = try UsageResponseParser.parse(data)
        }
    }

    @Test func mapsUnknownCommandToUnsupportedServer() {
        let data = UsageFixture.envelopeData(nil, ok: false, message: "unknown command")
        #expect(throws: UsageResponseError.unsupportedServer) {
            _ = try UsageResponseParser.parse(data)
        }
        #expect(UsageResponseError.unsupportedServer.localizedDescription.contains("update and restart"))
    }

    @Test func missingUsageIsAnErrorNotEmptySuccess() {
        let data = UsageFixture.envelopeData(nil, ok: true)
        #expect(throws: UsageResponseError.invalidResponse("response is missing the usage object")) {
            _ = try UsageResponseParser.parse(data)
        }
    }

    @Test func nonJSONResponseIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try UsageResponseParser.parse(Data("not json".utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try UsageResponseParser.parse(Data())
        }
    }

    @Test func malformedUsageShapeIsRejected() {
        // totals is missing a required field, so the typed decode must fail loudly.
        let usage: [String: Any] = [
            "range": ["from": "2026-10-08", "to": "2026-10-08", "start": "s", "endExclusive": "e",
                      "timeZone": "UTC"],
            "grouping": "route", "limit": 100, "groupCount": 0, "truncated": false,
            "totals": ["input": 1], "days": [], "groups": [],
        ]
        #expect(throws: (any Error).self) {
            _ = try UsageResponseParser.parse(UsageFixture.envelopeData(usage))
        }
    }

    @Test func emptyRangeDecodesAsCompleteZero() throws {
        let usage = UsageFixture.usageObject(totals: UsageFixture.zeroTotals(), days: [], groups: [])
        let parsed = try UsageResponseParser.parse(UsageFixture.envelopeData(usage))
        #expect(parsed.report.totals.attempts == 0)
        #expect(parsed.report.totals.total == 0)
        #expect(parsed.report.days.isEmpty)
        #expect(parsed.report.groups.isEmpty)
    }
}
