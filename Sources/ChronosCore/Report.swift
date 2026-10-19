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
    /// `now`, so totals are live. Closed slots never cross midnight, so clipping to the period only ever trims the open
    /// one.
    package static func apps(_ database: Database, from: Int, to: Int, now: Int) throws -> [AppTotal] {
        let rows = try database.rows(
            """
            SELECT a.id, a.bundle_id, a.name, p.id IS NOT NULL, COALESCE(p.name, s.domain),
                   SUM(MIN(COALESCE(s.ended_at, ?3), ?2) - MAX(s.started_at, ?1)),
                   SUM(s.continued = 0 AND s.started_at >= ?1)
            FROM slots s JOIN apps a ON a.id = s.app_id LEFT JOIN apps p ON p.id = s.sub_app_id
            WHERE ((s.started_at >= ?1 AND s.started_at < ?2) OR s.ended_at IS NULL)
              AND s.started_at < ?2 AND COALESCE(s.ended_at, ?3) > ?1
            GROUP BY a.id, s.sub_app_id, s.domain
            """,
            [.integer(from), .integer(to), .integer(now)]
        ) { row in
            let kind: AppTotal.Part.Kind = row.int(3) == 1 ? .program : row.text(4).isEmpty ? .unidentified : .site
            return (
                app: row.int(0), bundleID: row.text(1), name: row.text(2),
                part: AppTotal.Part(name: row.text(4), kind: kind, seconds: row.int(5)), switches: row.int(6)
            )
        }
        return Dictionary(grouping: rows, by: \.app).values.map { rows in
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
