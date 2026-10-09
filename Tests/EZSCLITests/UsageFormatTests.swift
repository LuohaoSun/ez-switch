import Foundation
import Testing
@testable import EZSCLI

@Suite("Usage formatting")
struct UsageFormatTests {
    private func report(_ usage: [String: Any]) throws -> UsageReport {
        try UsageResponseParser.parse(UsageFixture.envelopeData(usage)).report
    }

    @Test func emptyRangePrintsNoUsageRecorded() throws {
        let usage = UsageFixture.usageObject(totals: UsageFixture.zeroTotals(), days: [], groups: [])
        let text = UsageTextFormatter.render(try report(usage), options: UsageOptions())
        #expect(text == """
        Usage from 2026-10-08 to 2026-10-08 (today)
        Time zone: America/Los_Angeles

        No usage recorded from 2026-10-08 to 2026-10-08.
        """)
    }

    @Test func fullTextReportMatchesExpectedLayout() throws {
        let text = UsageTextFormatter.render(try report(UsageFixture.usageObject()), options: UsageOptions())
        #expect(text == """
        Usage from 2026-10-08 to 2026-10-08 (today)
        Time zone: America/Los_Angeles

        Totals
          Input: 1,200
          Output: 300
          Total: 1,500
          Cached input: 100
          Cache write: 20
          Reasoning: 10
          Requests: 8
          Attempts: 10
          Failed attempts: 2
          Coverage: 8/10 attempts (80.0%)
            input reported 8/10, output reported 8/10, cached input reported 3/10
            Partial: some attempts reported no usage; reported totals cover known values only and are not an estimate.

        Days
          2026-10-08  input 100  output 40

        Groups (route)
          main
            Input 1,200  Output 300  Total 1,500
            Requests 8  Attempts 10  Failed 2  Coverage 8/10 attempts (80.0%)
        """)
    }

    @Test func cacheAndReasoningAreNotAddedIntoTotal() throws {
        // total is authoritative (1,500) and never recomputed as input+output+cache+reasoning.
        let usage = UsageFixture.usageObject(
            totals: UsageFixture.totals(input: 1_000, output: 200, cachedInput: 800,
                                        cacheWrite: 50, reasoning: 60, total: 1_200))
        let text = UsageTextFormatter.render(try report(usage), options: UsageOptions())
        #expect(text.contains("  Total: 1,200\n"))
        #expect(text.contains("  Cached input: 800\n"))
        #expect(text.contains("  Reasoning: 60\n"))
    }

    @Test func completeCoverageOmitsPartialNote() throws {
        let usage = UsageFixture.usageObject(
            totals: UsageFixture.totals(attempts: 10, knownAttempts: 10, inputAttempts: 10,
                                        outputAttempts: 10, cachedInputAttempts: 10, coverage: 1.0))
        let text = UsageTextFormatter.render(try report(usage), options: UsageOptions())
        #expect(text.contains("Coverage: 10/10 attempts (100.0%)"))
        #expect(!text.contains("Partial:"))
    }

    @Test func truncatedGroupsAreAnnouncedWithLimitHint() throws {
        let usage = UsageFixture.usageObject(groupCount: 5, truncated: true)
        let text = UsageTextFormatter.render(try report(usage), options: UsageOptions())
        #expect(text.contains("Groups (route) — showing 1 of 5 groups; raise --limit to see more"))
    }

    @Test func controlCharactersInNamesAreEscaped() throws {
        let groups: [[String: Any]] = [[
            "id": "x", "title": "evil\u{1B}[31mred", "subtitle": "sub\nline",
            "totals": UsageFixture.totals(),
        ]]
        let usage = UsageFixture.usageObject(groups: groups)
        let text = UsageTextFormatter.render(try report(usage), options: UsageOptions())
        #expect(text.contains("evil\\u{1B}[31mred"))
        #expect(text.contains("(sub\\nline)"))
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("evil\u{1B}"))
    }

    @Test func customRangeLabelIsCustom() throws {
        var options = UsageOptions()
        options.from = "2026-10-01"
        options.to = "2026-10-08"
        let text = UsageTextFormatter.render(try report(UsageFixture.usageObject()), options: options)
        #expect(text.hasPrefix("Usage from 2026-10-08 to 2026-10-08 (custom)\n"))
    }

    @Test func jsonOutputIsSortedPrettyUsageObjectWithoutEnvelope() throws {
        let usage = UsageFixture.usageObject()
        let text = try UsageTextFormatter.renderJSON(usage)
        #expect(!text.contains("\"ok\""))
        #expect(!text.contains("\"message\""))
        #expect(text.contains("\n  \"totals\""))
        // Sorted keys: the top-level "limit" key precedes "range" (both appear once).
        let limitIndex = try #require(text.range(of: "\"limit\""))
        let rangeIndex = try #require(text.range(of: "\"range\""))
        #expect(limitIndex.lowerBound < rangeIndex.lowerBound)

        let reference = String(decoding: try JSONSerialization.data(
            withJSONObject: usage, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        #expect(text == reference)
    }

    @Test func jsonOutputKeepsEveryTotalsField() throws {
        let usage = UsageFixture.usageObject()
        let text = try UsageTextFormatter.renderJSON(usage)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let totals = try #require(object["totals"] as? [String: Any])
        let expectedKeys: Set<String> = [
            "input", "output", "cachedInput", "cacheWrite", "reasoning", "requests",
            "attempts", "knownAttempts", "inputAttempts", "outputAttempts",
            "cachedInputAttempts", "failedAttempts", "total", "coverage",
        ]
        #expect(Set(totals.keys) == expectedKeys)
        #expect(totals["coverage"] as? Double == 0.8)
        #expect(totals["total"] as? Int == 1_500)
    }

    @Test func percentAndCountHelpers() {
        #expect(UsageTextFormatter.percent(2.0 / 3.0) == "66.7%")
        #expect(UsageTextFormatter.percent(0) == "0.0%")
        #expect(UsageTextFormatter.count(1_234_567) == "1,234,567")
        #expect(UsageTextFormatter.sanitize("a\tb") == "a\\tb")
    }
}
