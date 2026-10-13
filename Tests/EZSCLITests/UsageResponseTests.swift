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

    // MARK: - Performance

    @Test func decodesPerformanceWhenExpected() throws {
        let performance = UsageFixture.performanceObject(grouping: "model", groupCount: 2, truncated: true)
        let parsed = try UsageResponseParser.parse(
            UsageFixture.envelope(usage: UsageFixture.usageObject(), performance: performance),
            expectPerformance: true)

        // The existing usage contract is untouched.
        #expect(parsed.report.totals.total == 1_500)
        let report = try #require(parsed.performance)
        #expect(report.grouping == "model")
        #expect(report.limit == 100)
        #expect(report.groupCount == 2)
        #expect(report.truncated)
        #expect(report.summary.attempts == 10)
        #expect(report.summary.successfulStreamingAttempts == 5)
        #expect(report.summary.ttftSamples == 4)
        #expect(report.summary.requestTTFTSamples == 4)
        #expect(report.summary.tpsSamples == 3)
        #expect(report.summary.ttftP50MS == 1200)
        #expect(report.summary.ttftP95MS == 2100)
        #expect(report.summary.requestTTFTP50MS == 1500)
        #expect(report.summary.requestTTFTP95MS == 2400)
        #expect(report.summary.tpsP50 == 42.3)
        #expect(report.groups.first?.title == "gpt-4o")
        #expect(report.groups.first?.subtitle == "OpenAI")
        #expect(report.groups.first?.summary.tpsP50 == 42.3)
        #expect(parsed.performanceJSONObject != nil)
    }

    @Test func nullPerformanceStatsDecodeAsNil() throws {
        let summary = UsageFixture.performanceSummary(ttftSamples: 0, requestTTFTSamples: 0, tpsSamples: 0,
                                                      ttftP50MS: nil, ttftP95MS: nil,
                                                      requestTTFTP50MS: nil, requestTTFTP95MS: nil,
                                                      tpsP50: nil)
        let performance = UsageFixture.performanceObject(summary: summary)
        // Serialised as JSON null, not omitted.
        let data = UsageFixture.envelope(usage: UsageFixture.usageObject(), performance: performance)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawSummary = try #require((object["performance"] as? [String: Any])?["summary"] as? [String: Any])
        #expect(rawSummary["ttftP50MS"] is NSNull)

        let parsed = try UsageResponseParser.parse(data, expectPerformance: true)
        let report = try #require(parsed.performance)
        #expect(report.summary.ttftSamples == 0)
        #expect(report.summary.requestTTFTSamples == 0)
        #expect(report.summary.ttftP50MS == nil)
        #expect(report.summary.ttftP95MS == nil)
        #expect(report.summary.requestTTFTP50MS == nil)
        #expect(report.summary.requestTTFTP95MS == nil)
        #expect(report.summary.tpsP50 == nil)
    }

    @Test func missingRequestTTFSamplesDecodesAsNilNotUpstreamCount() throws {
        // Payload predating the requestTTFTSamples field.
        var summary = UsageFixture.performanceSummary(ttftSamples: 7)
        summary.removeValue(forKey: "requestTTFTSamples")
        let parsed = try UsageResponseParser.parse(
            UsageFixture.envelope(usage: UsageFixture.usageObject(),
                                  performance: UsageFixture.performanceObject(summary: summary)),
            expectPerformance: true)
        let report = try #require(parsed.performance)
        #expect(report.summary.requestTTFTSamples == nil)
        #expect(report.summary.ttftSamples == 7)
    }

    @Test func requestingPerformanceFromOldServerIsUnsupported() {
        let data = UsageFixture.envelope(usage: UsageFixture.usageObject())
        #expect(throws: UsageResponseError.performanceUnsupported) {
            _ = try UsageResponseParser.parse(data, expectPerformance: true)
        }
        #expect(UsageResponseError.performanceUnsupported.localizedDescription.contains("update and restart"))
    }

    @Test func unrequestedPerformanceObjectIsIgnored() throws {
        let data = UsageFixture.envelope(usage: UsageFixture.usageObject(),
                                         performance: UsageFixture.performanceObject())
        let parsed = try UsageResponseParser.parse(data)
        #expect(parsed.performance == nil)
        #expect(parsed.performanceJSONObject == nil)
        #expect(parsed.report.totals.total == 1_500)
    }

    @Test func malformedPerformanceShapeIsRejected() {
        let bad: [String: Any] = [
            "grouping": "model", "limit": 100, "groupCount": 0, "truncated": false,
            "summary": ["attempts": 1], "groups": [],
        ]
        #expect(throws: (any Error).self) {
            _ = try UsageResponseParser.parse(
                UsageFixture.envelope(usage: UsageFixture.usageObject(), performance: bad),
                expectPerformance: true)
        }
    }
}
