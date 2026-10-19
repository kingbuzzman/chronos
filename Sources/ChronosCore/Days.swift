package import Foundation

/// Local day boundaries, where slots are cut so that no row crosses a day.
package enum Days {
    /// The local midnights strictly after `start` and before `end`, both unix seconds.
    package static func midnights(after start: Int, before end: Int, calendar: Calendar) -> [Int] {
        var cuts: [Int] = []
        var cut = nextMidnight(after: start, calendar: calendar)
        while cut < end {
            cuts.append(cut)
            cut = nextMidnight(after: cut, calendar: calendar)
        }
        return cuts
    }

    /// The first local midnight after `time`. Days around clock changes are 23 or 25 hours long, which `Calendar`
    /// accounts for.
    package static func nextMidnight(after time: Int, calendar: Calendar) -> Int {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(time)))
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        return Int(next.timeIntervalSince1970)
    }
}
