package import Foundation

/// Time spent in one app over a period, and in what ran inside it.
package struct AppTotal: Equatable, Sendable {
    /// Time inside an app: a program in Terminal, a site in a browser, or time when Chronos couldn't tell which.
    package struct Part: Equatable, Sendable {
        package enum Kind: Sendable {
            case program, site, unidentified
        }

        package let name: String
        package let kind: Kind
        package let seconds: Int

        package init(name: String, kind: Kind, seconds: Int) {
            self.name = name
            self.kind = kind
            self.seconds = seconds
        }
    }

    package let bundleID: String
    package let name: String
    package let seconds: Int
    /// How many times focus landed on the app, or moved within it; a slot carried over midnight isn't a new one.
    package let switches: Int
    /// Most first, then any unidentified time, adding up to `seconds`. Empty for apps Chronos can't see into.
    package let parts: [Part]

    package init(bundleID: String, name: String, seconds: Int, switches: Int, parts: [Part] = []) {
        self.bundleID = bundleID
        self.name = name
        self.seconds = seconds
        self.switches = switches
        self.parts = parts
    }
}

package enum Period: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, year

    package var id: Self { self }

    package var title: String { rawValue.capitalized }

    /// The local day, week, month or year containing `date`. Weeks start on the locale's first weekday.
    package func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component =
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        return calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 0)
    }
}

package enum Report {
    /// Time per app in `[from, to)`, most first, each broken down by what ran inside it. Includes the open slot up to
    /// `now`, so totals are live.
    package static func apps(_ database: Database, from: Int, to: Int, now: Int) throws -> [AppTotal] {
        try apps(database, windows: [Schedule.Window(label: nil, start: from, end: to)], now: now)[nil] ?? []
    }

    /// Time per app in each label's windows, by label, with `nil` for unscheduled time. A slot spanning two windows
    /// is cut between them, and counts as a switch only in the one it started in. Labels without time are left out.
    ///
    /// Closed slots never cross midnight, so one overlapping a window starts at most a day before it (25 hours, on
    /// the day the clocks go back): each window reads only that stretch of the index. The open slot can be older, so
    /// it's read on its own.
    package static func apps(_ database: Database, windows: [Schedule.Window], now: Int) throws -> [UUID?: [AppTotal]] {
        let labels = Array(Set(windows.map(\.label)))
        let index = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        let json = "[" + windows.map { "[\(index[$0.label]!),\($0.start),\($0.end)]" }.joined(separator: ",") + "]"
        let rows = try database.rows(
            """
            WITH w(label, start, end) AS (
                SELECT value ->> 0, value ->> 1, value ->> 2 FROM json_each(?1)
            ),
            s AS (
                SELECT w.label, w.start AS w_start, w.end AS w_end, s.* FROM w JOIN slots s
                    ON s.started_at >= w.start - 90000 AND s.started_at < w.end
                   AND s.ended_at IS NOT NULL AND s.ended_at > w.start
                UNION ALL
                SELECT w.label, w.start, w.end, s.* FROM w JOIN slots s
                    ON s.ended_at IS NULL AND s.started_at < w.end AND ?2 > w.start
            )
            SELECT s.label, a.id, a.bundle_id, a.name, p.id IS NOT NULL, COALESCE(p.name, s.domain),
                   SUM(MIN(COALESCE(s.ended_at, ?2), s.w_end) - MAX(s.started_at, s.w_start)),
                   SUM(s.continued = 0 AND s.started_at >= s.w_start)
            FROM s JOIN apps a ON a.id = s.app_id LEFT JOIN apps p ON p.id = s.sub_app_id
            GROUP BY s.label, a.id, s.sub_app_id, s.domain
            """,
            [.text(json), .integer(now)]
        ) { row in
            let kind: AppTotal.Part.Kind = row.int(4) == 1 ? .program : row.text(5).isEmpty ? .unidentified : .site
            return (
                label: labels[row.int(0)], app: row.int(1), bundleID: row.text(2), name: row.text(3),
                part: AppTotal.Part(name: row.text(5), kind: kind, seconds: row.int(6)), switches: row.int(7)
            )
        }
        return Dictionary(grouping: rows, by: \.label).mapValues { rows in
            Dictionary(grouping: rows, by: \.app).values.map { rows in
                // Most first, with time Chronos couldn't place always last, however big.
                let parts = rows.map(\.part).sorted {
                    ($0.kind != .unidentified ? 1 : 0, $0.seconds) > ($1.kind != .unidentified ? 1 : 0, $1.seconds)
                }
                return AppTotal(
                    bundleID: rows[0].bundleID,
                    name: rows[0].name,
                    seconds: parts.reduce(0) { $0 + $1.seconds },
                    switches: rows.reduce(0) { $0 + $1.switches },
                    // Time Chronos couldn't place is only worth a row next to time it could.
                    parts: parts.allSatisfy { $0.kind == .unidentified } ? [] : parts
                )
            }
            .sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }
        }
    }

    package static func apps(
        _ database: Database,
        in period: Period,
        at date: Date,
        calendar: Calendar
    ) throws -> [AppTotal] {
        let interval = period.interval(containing: date, calendar: calendar)
        return try apps(
            database,
            from: Int(interval.start.timeIntervalSince1970),
            to: Int(interval.end.timeIntervalSince1970),
            now: Int(date.timeIntervalSince1970)
        )
    }

    /// Time per app in `period`, split by `schedule`'s labels, with `nil` for unscheduled time.
    package static func apps(
        _ database: Database,
        in period: Period,
        at date: Date,
        by schedule: Schedule,
        calendar: Calendar
    ) throws -> [UUID?: [AppTotal]] {
        let interval = period.interval(containing: date, calendar: calendar)
        let windows = schedule.windows(
            from: Int(interval.start.timeIntervalSince1970),
            to: Int(interval.end.timeIntervalSince1970),
            calendar: calendar
        )
        return try apps(database, windows: windows, now: Int(date.timeIntervalSince1970))
    }
}

/// Everything recorded so far, closed slots only.
package struct Lifetime: Equatable, Sendable {
    /// Unix seconds of the first slot, or nil before anything is recorded.
    package let since: Int?
    package let seconds: Int
    package let apps: Int
    package let switches: Int

    package static func read(_ database: Database) throws -> Lifetime {
        try database.rows(
            """
            SELECT MIN(started_at), COALESCE(SUM(duration), 0), COUNT(DISTINCT app_id), COALESCE(SUM(continued = 0), 0)
            FROM slots
            """
        ) {
            Lifetime(since: $0.isNull(0) ? nil : $0.int(0), seconds: $0.int(1), apps: $0.int(2), switches: $0.int(3))
        }[0]
    }
}

/// One unit, rounded down: `42s` under a minute, `14m` under an hour, then `6h`.
package func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h"
}

/// The same unit as `formatDuration`, with two decimals, for hovering: `1.15m`, `1.15h`. Seconds stay whole: `42s`.
package func formatDurationPrecisely(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return String(format: "%.2fm", Double(seconds) / 60) }
    return String(format: "%.2fh", Double(seconds) / 3600)
}
