import Testing
@testable import EZSwitch

@Suite("Usage totals")
struct UsageTypesTests {
    @Test func oversizedUpstreamCountsCannotOverflowDisplay() {
        let tokens = UsageTokens(input: Int.max, output: 1)
        #expect(tokens.total == Int.max)
        var totals = UsageTotals()
        totals.input = Int.max
        totals.output = Int.max
        #expect(totals.total == Int.max)
    }
}
