import Foundation
import Testing
@testable import EZSwitch

/// 图表选中的纯逻辑：点击命中哪根柱、柱对应的时间桶区间。
@MainActor
struct UsageChartSelectionTests {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func pointMatchesByBucketBoundaries() throws {
        let calendar = utcCalendar()
        let start = Date(timeIntervalSince1970: 1_728_950_400)
        let points = [UsageDay(date: start, input: 10, output: 5),
                      UsageDay(date: start.addingTimeInterval(7200), input: 2, output: 3)]

        let first = try #require(UsageChartSelection.point(at: start.addingTimeInterval(1800),
                                                           points: points, unit: .hour, calendar: calendar))
        #expect(first.date == start)
        // 落在两桶之间（该小时没有柱）时不命中任何柱。
        #expect(UsageChartSelection.point(at: start.addingTimeInterval(3600),
                                          points: points, unit: .hour, calendar: calendar) == nil)
        let second = try #require(UsageChartSelection.point(at: start.addingTimeInterval(7200),
                                                            points: points, unit: .hour, calendar: calendar))
        #expect(second.date == points[1].date)
    }

    @Test func bucketCoversTheWholeCalendarBucket() throws {
        let calendar = utcCalendar()
        let start = Date(timeIntervalSince1970: 1_728_950_400)
        let point = UsageDay(date: start, input: 10, output: 5)

        let hour = try #require(UsageChartSelection.bucket(for: point, unit: .hour, calendar: calendar))
        #expect(hour.date == start)
        #expect(hour.range.from == start)
        #expect(hour.range.to == start.addingTimeInterval(3600))

        let day = try #require(UsageChartSelection.bucket(for: point, unit: .day, calendar: calendar))
        #expect(day.date == start)
        #expect(day.range.from <= day.date)
        #expect(day.range.to == day.range.from.addingTimeInterval(86400))
    }

    @Test func bucketLabelDistinguishesHourAndDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_728_950_400)
        let point = UsageDay(date: start, input: 1, output: 1)
        let hour = try #require(UsageChartSelection.bucket(for: point, unit: .hour, calendar: calendar))
        let day = try #require(UsageChartSelection.bucket(for: point, unit: .day, calendar: calendar))
        #expect(hour.label(calendar: calendar) != day.label(calendar: calendar))
        #expect(!hour.label(calendar: calendar).isEmpty)
        #expect(!day.label(calendar: calendar).isEmpty)
    }
}
