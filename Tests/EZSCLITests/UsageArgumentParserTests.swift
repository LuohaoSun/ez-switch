import Testing
@testable import EZSCLI

@Suite("Usage argument parsing")
struct UsageArgumentParserTests {
    @Test func defaultsMatchDocumentedBehaviour() throws {
        let options = try UsageArgumentParser.parse([])
        #expect(options == UsageOptions())
        #expect(options.period == .today)
        #expect(options.group == .route)
        #expect(options.limit == 100)
        #expect(options.from == nil && options.to == nil)
        #expect(options.json == false)
    }

    @Test func parsesEveryOption() throws {
        let options = try UsageArgumentParser.parse(
            ["--period", "7d", "--group", "model", "--limit", "1000", "--json"])
        #expect(options.period == .last7Days)
        #expect(options.group == .model)
        #expect(options.limit == 1000)
        #expect(options.json)
        #expect(options.rangeLabel == "7d")
    }

    @Test func parsesMonthAndTodayPeriods() throws {
        #expect(try UsageArgumentParser.parse(["--period", "month"]).period == .month)
        #expect(try UsageArgumentParser.parse(["--period", "today"]).period == .today)
    }

    @Test func parsesCustomRangeAndTreatsItAsCustom() throws {
        let options = try UsageArgumentParser.parse(
            ["--from", "2026-01-01", "--to", "2026-01-31", "--group", "provider"])
        #expect(options.from == "2026-01-01")
        #expect(options.to == "2026-01-31")
        #expect(options.group == .provider)
        #expect(options.usesCustomRange)
        #expect(options.rangeLabel == "custom")
    }

    @Test func acceptsReversedRangeShapeForServerToResolve() throws {
        // The server normalises reversed dates; the CLI only checks the shape.
        let options = try UsageArgumentParser.parse(["--from", "2026-11-02", "--to", "2026-11-01"])
        #expect(options.from == "2026-11-02")
        #expect(options.to == "2026-11-01")
    }

    @Test func rejectsUnknownOptions() {
        #expect(throws: UsageArgumentError.unknownOption("--foo")) {
            _ = try UsageArgumentParser.parse(["--foo"])
        }
        #expect(throws: UsageArgumentError.unknownOption("--moo")) {
            _ = try UsageArgumentParser.parse(["--period", "today", "--moo"])
        }
    }

    @Test func rejectsRepeatedOptions() {
        #expect(throws: UsageArgumentError.duplicateOption("--period")) {
            _ = try UsageArgumentParser.parse(["--period", "today", "--period", "month"])
        }
        #expect(throws: UsageArgumentError.duplicateOption("--group")) {
            _ = try UsageArgumentParser.parse(["--group", "route", "--group", "model"])
        }
        #expect(throws: UsageArgumentError.duplicateOption("--limit")) {
            _ = try UsageArgumentParser.parse(["--limit", "10", "--limit", "20"])
        }
        #expect(throws: UsageArgumentError.duplicateOption("--from")) {
            _ = try UsageArgumentParser.parse(["--from", "2026-01-01", "--from", "2026-01-02",
                                               "--to", "2026-01-03"])
        }
        #expect(throws: UsageArgumentError.duplicateOption("--to")) {
            _ = try UsageArgumentParser.parse(["--from", "2026-01-01", "--to", "2026-01-02",
                                               "--to", "2026-01-03"])
        }
    }

    @Test func rejectsRepeatedJSONFlag() {
        #expect(throws: UsageArgumentError.duplicateOption("--json")) {
            _ = try UsageArgumentParser.parse(["--json", "--json"])
        }
    }

    @Test func jsonIsAFlagNotAKeyValuePair() {
        #expect(throws: UsageArgumentError.unexpectedArgument("true")) {
            _ = try UsageArgumentParser.parse(["--json", "true"])
        }
    }

    @Test func rejectsMissingOptionValues() {
        #expect(throws: UsageArgumentError.missingValue("--period")) {
            _ = try UsageArgumentParser.parse(["--period"])
        }
        #expect(throws: UsageArgumentError.missingValue("--limit")) {
            _ = try UsageArgumentParser.parse(["--limit"])
        }
    }

    @Test func rejectsInvalidPeriodGroupAndLimit() throws {
        #expect(throws: UsageArgumentError.invalidValue(option: "--period", value: "weekly",
                                                        expected: "today, 7d or month")) {
            _ = try UsageArgumentParser.parse(["--period", "weekly"])
        }
        #expect(throws: UsageArgumentError.invalidValue(option: "--group", value: "upstream",
                                                        expected: "route, provider or model")) {
            _ = try UsageArgumentParser.parse(["--group", "upstream"])
        }
        for bad in ["0", "1001", "-5", "abc", "1.5", " 5", "+5"] {
            #expect(throws: (any Error).self) {
                _ = try UsageArgumentParser.parse(["--limit", bad])
            }
        }
        #expect(try UsageArgumentParser.parse(["--limit", "1"]).limit == 1)
        #expect(try UsageArgumentParser.parse(["--limit", "1000"]).limit == 1000)
    }

    @Test func rejectsMalformedDatesButAcceptsShape() throws {
        for bad in ["2026-1-01", "01-01-2026", "2026/01/01", "20260101", "2026-01-1"] {
            #expect(throws: (any Error).self) {
                _ = try UsageArgumentParser.parse(["--from", bad, "--to", "2026-01-31"])
            }
        }
        // Well-shaped but non-existent dates pass the CLI; the server is authoritative.
        #expect(UsageArgumentParser.isValidDateShape("2026-02-30"))
        #expect(try UsageArgumentParser.parse(["--from", "2026-02-30", "--to", "2026-03-01"]).from == "2026-02-30")
    }

    @Test func rejectsUnpairedRange() {
        #expect(throws: UsageArgumentError.incompleteRange) {
            _ = try UsageArgumentParser.parse(["--from", "2026-01-01"])
        }
        #expect(throws: UsageArgumentError.incompleteRange) {
            _ = try UsageArgumentParser.parse(["--to", "2026-01-31"])
        }
    }

    @Test func rejectsPeriodCombinedWithRange() throws {
        #expect(throws: UsageArgumentError.periodAndRangeConflict) {
            _ = try UsageArgumentParser.parse(["--period", "today", "--from", "2026-01-01", "--to", "2026-01-02"])
        }
        // Range without an explicit --period is fine even though period has a default.
        #expect(try UsageArgumentParser.parse(["--from", "2026-01-01", "--to", "2026-01-02"]).usesCustomRange)
    }

    @Test func rejectsStrayPositionalArguments() {
        #expect(throws: UsageArgumentError.unexpectedArgument("extra")) {
            _ = try UsageArgumentParser.parse(["extra"])
        }
    }

    @Test func payloadSendsProvidedFieldsAsStringsAndOmitsJSON() throws {
        let options = try UsageArgumentParser.parse(["--period", "7d", "--group", "model", "--limit", "250"])
        let payload = UsageArgumentParser.requestPayload(options)
        #expect(payload == ["command": "usage", "period": "7d", "group": "model", "limit": "250"])
        #expect(payload["json"] == nil)
    }

    @Test func payloadUsesFromToInsteadOfPeriod() throws {
        let options = try UsageArgumentParser.parse(["--from", "2026-01-01", "--to", "2026-01-31"])
        let payload = UsageArgumentParser.requestPayload(options)
        #expect(payload["from"] == "2026-01-01")
        #expect(payload["to"] == "2026-01-31")
        #expect(payload["period"] == nil)
        #expect(payload["group"] == "route")
        #expect(payload["limit"] == "100")
    }
}
