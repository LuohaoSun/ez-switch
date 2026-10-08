import Foundation
import Testing
@testable import EZSwitch

@Suite("Usage date ranges")
struct UsageDateRangeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func todayUsesCalendarBoundaryAcrossSpringDST() {
        let now = date(2026, 3, 8, hour: 12)
        let range = UsageRangeResolver.resolve(preset: .today, customStart: now, customEnd: now,
                                               now: now, calendar: calendar)
        #expect(range.from == date(2026, 3, 8))
        #expect(range.to == date(2026, 3, 9))
        #expect(range.to.timeIntervalSince(range.from) == 23 * 60 * 60)
    }

    @Test func sevenDaysIncludesTodayAndSixPrecedingDates() {
        let now = date(2026, 3, 10, hour: 12)
        let range = UsageRangeResolver.resolve(preset: .last7Days, customStart: now, customEnd: now,
                                               now: now, calendar: calendar)
        #expect(range.from == date(2026, 3, 4))
        #expect(range.to == date(2026, 3, 11))
    }

    @Test func customEndIncludesWholeDayAndAcceptsReversedDates() {
        let range = UsageRangeResolver.resolve(preset: .custom,
                                               customStart: date(2026, 11, 2, hour: 12),
                                               customEnd: date(2026, 11, 1, hour: 12),
                                               calendar: calendar)
        #expect(range.from == date(2026, 11, 1))
        #expect(range.to == date(2026, 11, 3))
        #expect(range.to.timeIntervalSince(range.from) == 49 * 60 * 60)
    }
}
