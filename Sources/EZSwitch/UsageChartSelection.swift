import Foundation
import Combine

@MainActor
final class UsageChartSelection: ObservableObject {
    @Published var date: Date?

    func toggle(at date: Date, points: [UsageDay], unit: Calendar.Component,
                calendar: Calendar = .current) {
        guard let point = Self.point(at: date, points: points, unit: unit, calendar: calendar),
              point.input > 0 || point.output > 0 else {
            self.date = nil
            return
        }
        self.date = self.date == point.date ? nil : point.date
    }

    static func point(at date: Date, points: [UsageDay], unit: Calendar.Component,
                      calendar: Calendar = .current) -> UsageDay? {
        points.first { point in
            guard let interval = calendar.dateInterval(of: unit, for: point.date) else { return false }
            return date >= interval.start && date < interval.end
        }
    }
}
