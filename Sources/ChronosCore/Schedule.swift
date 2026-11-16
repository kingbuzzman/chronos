package import Foundation

/// Named parts of the week, such as Work from 9 to 5 on weekdays, for splitting reports, and the allowances, which can
/// count only during one of them. Time outside every label is unscheduled. Nothing in the database refers to a
/// schedule: it changes how time is shown, and when to say an allowance is used up, never what's recorded.
package struct Schedule: Codable, Equatable, Sendable {
    package var labels: [Label]
    package var allowances: [Allowance]

    package init(labels: [Label] = [], allowances: [Allowance] = []) {
        self.labels = labels
        self.allowances = allowances
    }

    private enum CodingKeys: String, CodingKey {
        case labels, allowances
    }

    /// Schedules saved before allowances existed have none.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labels = try container.decode([Label].self, forKey: .labels)
        allowances = try container.decodeIfPresent([Allowance].self, forKey: .allowances) ?? []
    }

    /// Minutes in a day, and in a week.
    package static let day = 1440
    package static let week = 7 * day

    /// Every pair of hours that cover the same time, in either label or the same one. A schedule with any can't be
    /// saved: each moment belongs to one label at most.
    package var conflicts: [Conflict] {
        let all = labels.flatMap { label in label.hours.map { (label: label, hours: $0) } }
        var conflicts: [Conflict] = []
        for (index, first) in all.enumerated() {
            for second in all[(index + 1)...] {
                guard let overlap = Self.overlap(first.hours.spans, second.hours.spans) else { continue }
                conflicts.append(Conflict(first: first.label.name, second: second.label.name, overlap: overlap))
            }
        }
        return conflicts
    }

    /// The first stretch of the week both cover, in minutes after Sunday's midnight. A stretch running past
    /// Saturday's midnight is split in two, so the week wraps.
    private static func overlap(_ first: [Range<Int>], _ second: [Range<Int>]) -> Range<Int>? {
        let wrapped = { (spans: [Range<Int>]) in
            spans.flatMap { span in
                span.upperBound <= week
                    ? [span] : [span.lowerBound..<week, 0..<(span.upperBound - week)]
            }
        }
        let overlaps = wrapped(first).flatMap { a in
            wrapped(second).compactMap { b -> Range<Int>? in
                let lower = max(a.lowerBound, b.lowerBound)
                let upper = min(a.upperBound, b.upperBound)
                return lower < upper ? lower..<upper : nil
            }
        }
        return overlaps.min { $0.lowerBound < $1.lowerBound }
    }

    /// Splits `[from, to)` into consecutive windows, one per stretch of a label and one per stretch between them
    /// (`nil`, unscheduled), in local time. Together they cover the interval exactly once, so the totals of every
    /// label and of unscheduled time add up to the whole. Days with a clock change keep their wall-clock hours: 9 to 5
    /// is 9 to 5, even on a 23-hour day.
    package func windows(from: Int, to: Int, calendar: Calendar) -> [Window] {
        guard from < to else { return [] }
        var labeled: [Window] = []
        // From the day before, for hours that run past midnight into the period.
        var day = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(from)))
        )!
        while Int(day.timeIntervalSince1970) < to {
            let weekday = calendar.component(.weekday, from: day)
            for label in labels {
                for hours in label.hours where hours.days.contains(weekday) {
                    let start = time(minute: hours.start, of: day, calendar: calendar)
                    let end = time(minute: hours.start + hours.length, of: day, calendar: calendar)
                    let window = Window(label: label.id, start: max(start, from), end: min(end, to))
                    if window.start < window.end { labeled.append(window) }
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        var windows: [Window] = []
        var cursor = from
        for window in labeled.sorted(by: { $0.start < $1.start }) {
            // A clock change can make hours that don't overlap in the week overlap on the day; the earlier one wins.
            let start = max(window.start, cursor)
            guard start < window.end else { continue }
            if cursor < start { windows.append(Window(label: nil, start: cursor, end: start)) }
            windows.append(Window(label: window.label, start: start, end: window.end))
            cursor = window.end
        }
        if cursor < to { windows.append(Window(label: nil, start: cursor, end: to)) }
        return windows
    }

    /// Unix seconds for `minute` minutes into the local day starting at `day`, by the clock on the wall: a minute
    /// past 1440 is on the next day, and a time skipped by a clock change moves forward to the next that exists.
    private func time(minute: Int, of day: Date, calendar: Calendar) -> Int {
        let date = calendar.date(byAdding: .day, value: minute / Schedule.day, to: day)!
        let minute = minute % Schedule.day
        let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date) ?? date
        return Int(time.timeIntervalSince1970)
    }
}

extension Schedule {
    /// A name for some hours of the week, and the color it's shown in.
    package struct Label: Codable, Equatable, Identifiable, Sendable {
        package var id: UUID
        package var name: String
        package var color: Tint
        package var hours: [Hours]

        package init(id: UUID = UUID(), name: String, color: Tint, hours: [Hours]) {
            self.id = id
            self.name = name
            self.color = color
            self.hours = hours
        }
    }

    /// The same hours on some days of the week, such as 9:00 to 17:00 on weekdays.
    package struct Hours: Codable, Equatable, Identifiable, Sendable {
        package var id: UUID
        /// `Calendar` weekdays: 1 is Sunday, 7 is Saturday, whatever day the week starts on.
        package var days: Set<Int>
        /// Minutes after midnight, from 0 to 1439.
        package var start: Int
        /// Minutes after midnight, from 0 to 1439. At or before `start`, the hours run past midnight into the next
        /// day: 22:00 to 02:00. The same as `start` is a whole day; 0 is midnight.
        package var end: Int

        package init(id: UUID = UUID(), days: Set<Int>, start: Int, end: Int) {
            self.id = id
            self.days = days
            self.start = start
            self.end = end
        }

        /// Minutes from start to end, from 1 to 1440.
        package var length: Int {
            let length = (end - start) % Schedule.day
            return length <= 0 ? length + Schedule.day : length
        }

        /// The stretches of the week these hours cover, in minutes after Sunday's midnight. One that runs past
        /// Saturday's midnight ends past `Schedule.week`.
        var spans: [Range<Int>] {
            days.sorted().map { day in
                let start = (day - 1) * Schedule.day + self.start
                return start..<(start + length)
            }
        }
    }

    /// The colors a label can be shown in, by name, so the file stays readable and the viewer picks the shade.
    package enum Tint: String, Codable, CaseIterable, Sendable {
        case blue, purple, pink, red, orange, yellow, green, teal, graphite
    }

    /// Two hours that cover the same time, by their labels' names, and the first stretch they share, in minutes
    /// after Sunday's midnight.
    package struct Conflict: Equatable, Sendable {
        package let first: String
        package let second: String
        package let overlap: Range<Int>

        package init(first: String, second: String, overlap: Range<Int>) {
            self.first = first
            self.second = second
            self.overlap = overlap
        }
    }

    /// `[start, end)` in unix seconds, in a label, or unscheduled when `label` is nil.
    package struct Window: Equatable, Sendable {
        package let label: UUID?
        package let start: Int
        package let end: Int

        package init(label: UUID?, start: Int, end: Int) {
            self.label = label
            self.start = start
            self.end = end
        }
    }
}

extension Schedule {
    /// The schedule saved at `path`, or an empty one if there's none yet.
    package static func load(from path: String) throws -> Schedule {
        guard FileManager.default.fileExists(atPath: path) else { return Schedule() }
        return try JSONDecoder().decode(Schedule.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Writes the schedule to `path` whole, so a reader never sees half of it. Refuses one with conflicts.
    package func save(to path: String) throws {
        guard conflicts.isEmpty else { throw ConflictError() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    package struct ConflictError: Error, CustomStringConvertible {
        package var description: String { "Labels can't overlap: each moment belongs to one label at most." }
    }
}
