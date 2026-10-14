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

    // MARK: - 近 30 天

    @Test func last30DaysIncludesTodayAndTwentyNinePrecedingDates() {
        let now = date(2026, 5, 31, hour: 12)
        let range = UsageRangeResolver.resolve(preset: .last30Days, customStart: now, customEnd: now,
                                               now: now, calendar: calendar)
        #expect(range.from == date(2026, 5, 2))
        #expect(range.to == date(2026, 6, 1))
        #expect(calendar.dateComponents([.day], from: range.from, to: range.to).day == 30)
    }

    // MARK: - 自定义「近 N 天」

    @Test func customLastNDaysCountsTodayInclusive() {
        let now = date(2026, 4, 20, hour: 9)
        let seven = UsageRangeResolver.resolve(preset: .custom, customLastNDays: 7,
                                               now: now, calendar: calendar)
        #expect(seven.from == date(2026, 4, 14))
        #expect(seven.to == date(2026, 4, 21))

        // N = 1 只含今天，半开区间为 [今天, 明天)。
        let one = UsageRangeResolver.resolve(preset: .custom, customLastNDays: 1,
                                             now: now, calendar: calendar)
        #expect(one.from == date(2026, 4, 20))
        #expect(one.to == date(2026, 4, 21))
    }

    @Test func customLastNDaysClampsInvalidValuesToAtLeastOne() {
        let now = date(2026, 4, 20, hour: 9)
        for value in [0, -5, Int.min] {
            let range = UsageRangeResolver.resolve(preset: .custom, customLastNDays: value,
                                                   now: now, calendar: calendar)
            #expect(range.from == date(2026, 4, 20), "N=\(value) 应回退到 1 天")
            #expect(range.to == date(2026, 4, 21))
        }
    }

    @Test func customLastNDaysSpansDSTWithNaturalDayBoundaries() {
        // 2026-03-08 是春季 DST 转换日；跨过它的 7 天区间应比 7×24h 少 1 小时。
        let now = date(2026, 3, 10, hour: 12)
        let range = UsageRangeResolver.resolve(preset: .custom, customLastNDays: 7,
                                               now: now, calendar: calendar)
        #expect(range.from == date(2026, 3, 4))
        #expect(range.to == date(2026, 3, 11))
        #expect(range.to.timeIntervalSince(range.from) == 167 * 60 * 60)
    }

    @Test func customLastNDaysTakesPrecedenceOverLegacyCustomDates() {
        let now = date(2026, 4, 20, hour: 9)
        let range = UsageRangeResolver.resolve(preset: .custom,
                                               customStart: date(2020, 1, 1),
                                               customEnd: date(2020, 1, 3),
                                               customLastNDays: 3,
                                               now: now, calendar: calendar)
        #expect(range.from == date(2026, 4, 18))
        #expect(range.to == date(2026, 4, 21))
    }

    // MARK: - 页面预设

    @Test func pagePresetsAreTodaySevenThirtyAndCustomOnly() {
        #expect(UsageRangePreset.pagePresets == [.today, .last7Days, .last30Days, .custom])
        #expect(!UsageRangePreset.pagePresets.contains(.thisMonth))
        #expect(UsageRangePreset.pagePresets.map(\.title) == ["今天", "近7天", "近30天", "自定义"])
    }

    // MARK: - 轴刻度（避免把次日零点标进当天）

    @Test func axisHourTicksStayInsideTheDayAndExcludeNextMidnight() {
        let now = date(2026, 3, 8, hour: 12) // 春季转换日：只有 23 小时
        let range = UsageRangeResolver.resolve(preset: .today, customStart: now, customEnd: now,
                                               now: now, calendar: calendar)
        let ticks = UsageAxisTicks.hours(from: range.from, to: range.to, stepHours: 1, calendar: calendar)
        #expect(!ticks.isEmpty)
        #expect(ticks.allSatisfy { $0 >= range.from && $0 < range.to })
        #expect(ticks.count == 23)
    }

    @Test func axisDayTicksStayInsideTheRangeExcludingExclusiveEnd() {
        let now = date(2026, 5, 31, hour: 12)
        let range = UsageRangeResolver.resolve(preset: .last30Days, customStart: now, customEnd: now,
                                               now: now, calendar: calendar)
        let ticks = UsageAxisTicks.days(from: range.from, to: range.to, maxTicks: 7, calendar: calendar)
        #expect(!ticks.isEmpty)
        #expect(ticks.allSatisfy { $0 >= range.from && $0 < range.to })
    }

    @Test func axisHourFormatsHourWithinTheDay() {
        // 用宿主时区构造，与 UsageFormat 的 .current 时区一致；断言 HH:mm 形态而非固定数字。
        let morning = Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 20, hour: 9))!
        let text = UsageFormat.axisHour(morning)
        #expect(text.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil)
        #expect(!text.contains("2026"))
    }
}
