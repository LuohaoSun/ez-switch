import Foundation
import Testing
@testable import EZSwitch

@MainActor
struct UsageChartSelectionTests {
    @Test func selectionUsesBucketBoundariesAndToggles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_728_950_400)
        let points = [UsageDay(date: start, input: 10, output: 5),
                      UsageDay(date: start.addingTimeInterval(7200), input: 2, output: 3)]
        let selection = UsageChartSelection()
        selection.toggle(at: start.addingTimeInterval(1800), points: points, unit: .hour, calendar: calendar)
        #expect(selection.date == start)
        selection.toggle(at: start.addingTimeInterval(1800), points: points, unit: .hour, calendar: calendar)
        #expect(selection.date == nil)
        selection.toggle(at: start.addingTimeInterval(3600), points: points, unit: .hour, calendar: calendar)
        #expect(selection.date == nil)
        selection.toggle(at: start.addingTimeInterval(7200), points: points, unit: .hour, calendar: calendar)
        #expect(selection.date == points[1].date)
    }
}
