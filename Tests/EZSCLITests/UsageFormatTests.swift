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

    // MARK: - Performance

    private func performance(_ object: [String: Any]) throws -> PerformanceReport {
        let parsed = try UsageResponseParser.parse(
            UsageFixture.envelope(usage: UsageFixture.usageObject(), performance: object),
            expectPerformance: true)
        return try #require(parsed.performance)
    }

    @Test func routeGroupingReportsRequestTTFTWithFallback() throws {
        let report = try performance(UsageFixture.performanceObject(grouping: "route"))
        let text = UsageTextFormatter.renderPerformance(report, options: UsageOptions())
        #expect(text.hasPrefix("Performance (route)\nTTFT basis: request (includes fallback)\n"))
        // Request-level values (1500/2400 ms) are shown, not the attempt-level 1200/2100 ms.
        #expect(text.contains("TTFT P50: 1.50 s  TTFT P95: 2.40 s"))
        #expect(!text.contains("TTFT P50: 1.20 s"))
        #expect(text.contains("Successful streaming: 5/10 attempts"))
        #expect(text.contains("TTFT samples: 4  TPS samples: 3"))
        #expect(text.contains("TPS P50: 42.3 tok/s"))
    }

    @Test func nonRouteGroupingReportsUpstreamAttemptTTFT() throws {
        let report = try performance(UsageFixture.performanceObject(grouping: "model"))
        let text = UsageTextFormatter.renderPerformance(report, options: UsageOptions())
        #expect(text.hasPrefix("Performance (model)\nTTFT basis: upstream attempt\n"))
        #expect(text.contains("TTFT P50: 1.20 s  TTFT P95: 2.10 s"))
        #expect(!text.contains("TTFT P50: 1.50 s"))
    }

    @Test func durationAndRateHelpersUseExplicitUnits() {
        #expect(UsageTextFormatter.duration(850) == "850 ms")
        #expect(UsageTextFormatter.duration(999) == "999 ms")
        #expect(UsageTextFormatter.duration(1200) == "1.20 s")
        #expect(UsageTextFormatter.duration(nil) == "—")
        #expect(UsageTextFormatter.duration(Double.nan) == "—")
        #expect(UsageTextFormatter.duration(Double.infinity) == "—")
        #expect(UsageTextFormatter.duration(-1) == "—")
        #expect(UsageTextFormatter.rate(42.34) == "42.3 tok/s")
        #expect(UsageTextFormatter.rate(nil) == "—")
        #expect(UsageTextFormatter.rate(Double.nan) == "—")
        #expect(UsageTextFormatter.rate(-2) == "—")
    }

    @Test func noSamplesShowDashesAndANote() throws {
        let summary = UsageFixture.performanceSummary(attempts: 0, successfulStreamingAttempts: 0,
                                                      ttftSamples: 0, requestTTFTSamples: 0, tpsSamples: 0,
                                                      ttftP50MS: nil, ttftP95MS: nil,
                                                      requestTTFTP50MS: nil, requestTTFTP95MS: nil,
                                                      tpsP50: nil)
        let report = try performance(UsageFixture.performanceObject(groupCount: 0, summary: summary, groups: []))
        let text = UsageTextFormatter.renderPerformance(report, options: UsageOptions())
        #expect(text.contains("No performance data recorded."))
        #expect(text.contains("TTFT P50: —  TTFT P95: —"))
        #expect(text.contains("TPS P50: —"))
    }

    @Test func routeGroupingUsesRequestTTFSampleCount() throws {
        let summary = UsageFixture.performanceSummary(ttftSamples: 9, requestTTFTSamples: 4, tpsSamples: 3)
        let report = try performance(UsageFixture.performanceObject(grouping: "route", summary: summary))
        let text = UsageTextFormatter.renderPerformance(report, options: UsageOptions())
        // Route grouping shows requestTTFTSamples (4), not ttftSamples (9).
        #expect(text.contains("TTFT samples: 4  TPS samples: 3"))
        #expect(!text.contains("TTFT samples: 9"))
    }

    @Test func routeGroupingWithoutRequestTTFTWarnsAndDoesNotSubstituteUpstream() throws {
        let summary = UsageFixture.performanceSummary(ttftSamples: 5, requestTTFTSamples: nil,
                                                      requestTTFTP50MS: nil, requestTTFTP95MS: nil)
        let route = try performance(UsageFixture.performanceObject(grouping: "route", summary: summary))
        let routeText = UsageTextFormatter.renderPerformance(route, options: UsageOptions())
        #expect(routeText.contains("TTFT samples: 0  TPS samples: 3"))
        #expect(routeText.contains("Warning: no request-level TTFT samples"))
        #expect(routeText.contains("TTFT P50: —"))

        // The same summary under model grouping uses the upstream attempt count.
        let model = try performance(UsageFixture.performanceObject(grouping: "model", summary: summary))
        let modelText = UsageTextFormatter.renderPerformance(model, options: UsageOptions())
        #expect(modelText.contains("TTFT samples: 5"))
        #expect(!modelText.contains("Warning:"))
        #expect(modelText.contains("TTFT P50: 1.20 s"))
    }

    @Test func truncatedPerformanceGroupsAreAnnounced() throws {
        let report = try performance(UsageFixture.performanceObject(groupCount: 5, truncated: true))
        let text = UsageTextFormatter.renderPerformance(report, options: UsageOptions())
        #expect(text.contains("Groups — showing 1 of 5 groups; raise --limit to see more"))
    }

    @Test func performanceGroupTitlesAreSanitized() throws {
        let groups: [[String: Any]] = [[
            "id": "x", "title": "evil\u{1B}[31m", "subtitle": "sub\nline",
            "summary": UsageFixture.performanceSummary(),
        ]]
        let report = try performance(UsageFixture.performanceObject(groups: groups))
        let text = UsageTextFormatter.renderPerformance(report, options: UsageOptions())
        #expect(text.contains("evil\\u{1B}[31m"))
        #expect(text.contains("(sub\\nline)"))
        #expect(!text.contains("\u{1B}"))
    }

    @Test func combinedJSONKeepsUsageAndPerformanceObjectsSeparate() throws {
        let usage = UsageFixture.usageObject()
        let performance = UsageFixture.performanceObject()
        let text = try UsageTextFormatter.renderCombinedJSON(usage: usage, performance: performance)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["usage"] != nil)
        let perf = try #require(object["performance"] as? [String: Any])
        #expect(perf["grouping"] as? String == "model")
        #expect((perf["summary"] as? [String: Any])?["attempts"] as? Int == 10)
        #expect(Set(object.keys) == ["usage", "performance"])
    }
}
