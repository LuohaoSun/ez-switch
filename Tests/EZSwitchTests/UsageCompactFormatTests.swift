import Foundation
import Testing
@testable import EZSwitch

/// `UsageFormat.compact` 的单位阶梯：1k 以下原样、k / M / B 逐级压缩。
@Suite("Usage compact formatting")
struct UsageCompactFormatTests {
    @Test func smallValuesStayExact() {
        #expect(UsageFormat.compact(0) == "0")
        #expect(UsageFormat.compact(999) == "999")
    }

    @Test func thousandsUseK() {
        #expect(UsageFormat.compact(1_000) == "1.0k")
        #expect(UsageFormat.compact(12_345) == "12.3k")
        #expect(UsageFormat.compact(150_000) == "150k")
    }

    @Test func millionsUseM() {
        #expect(UsageFormat.compact(1_250_000) == "1.2M")
        #expect(UsageFormat.compact(415_000_000) == "415.0M")
        #expect(UsageFormat.compact(999_949_999) == "999.9M")
    }

    /// 超过 1000M 改用 B（十亿），且不出现「1000.0M」这种跨级显示。
    @Test func billionsUseB() {
        #expect(UsageFormat.compact(999_950_000) == "1.0B")
        #expect(UsageFormat.compact(1_000_000_000) == "1.0B")
        #expect(UsageFormat.compact(1_234_567_890) == "1.2B")
        #expect(UsageFormat.compact(12_345_678_901) == "12.3B")
    }

    @Test func negativeValuesKeepSign() {
        #expect(UsageFormat.compact(-1_500) == "-1.5k")
        #expect(UsageFormat.compact(-1_500_000_000) == "-1.5B")
        // Int.min 走 Double 幅值，不应因 abs 溢出崩溃。
        #expect(UsageFormat.compact(.min).hasPrefix("-9"))
    }
}
