package import Foundation

/// So much time for an app, a site or a Terminal program, a day, week or month, such as youtube.com for 30 minutes a
/// day, optionally counting only during one label, or only Unscheduled time. Going over brings a notification, and
/// that's all: Chronos never closes, blocks or slows anything.
package struct Allowance: Codable, Equatable, Identifiable, Sendable {
    /// What an allowance is for. Browsers have no allowance of their own: their time is split by site.
    package enum Subject: Codable, Hashable, Sendable {
        /// Any app but a browser, by bundle ID, with its name as last seen.
        case app(bundleID: String, name: String)
        /// A site and its subdomains: `google.com` includes `docs.google.com`.
        case site(domain: String)
        /// A program run in Terminal, such as `claude`, by its launch name.
        case program(name: String)

        package var name: String {
            switch self {
            case .app(_, let name): name
            case .site(let domain): domain
            case .program(let name): name
            }
        }

        /// Whether time on `target` counts: the app in front, the site in its tab, or the program in front in it.
        package func matches(_ target: Target) -> Bool {
            switch self {
            case .app(let bundleID, _): target.bundleID == bundleID
            case .site(let domain): target.domain == domain || target.domain.hasSuffix("." + domain)
            case .program(let name): target.program == name
            }
        }
    }

    package enum Unit: String, Codable, CaseIterable, Sendable {
        case minutes, hours
    }

    package enum Per: String, Codable, CaseIterable, Sendable {
        case day, week, month

        package var period: Period {
            switch self {
            case .day: .day
            case .week: .week
            case .month: .month
            }
        }
    }

    /// The part of the week an allowance counts in: one label's hours, or the time outside every label. Saved as the
    /// label's ID, or `unscheduled`.
    package enum During: Codable, Hashable, Sendable {
        case label(UUID)
        case unscheduled

        package init(from decoder: any Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            if text == "unscheduled" {
                self = .unscheduled
            } else if let id = UUID(uuidString: text) {
                self = .label(id)
            } else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Not a label ID or unscheduled: \(text)")
                )
            }
        }

        package func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .label(let id): try container.encode(id.uuidString)
            case .unscheduled: try container.encode("unscheduled")
            }
        }

        package func contains(_ window: Schedule.Window) -> Bool {
            switch self {
            case .label(let id): window.label == id
            case .unscheduled: window.label == nil
            }
        }
    }

    package var id: UUID
    package var subject: Subject
    package var amount: Int
    package var unit: Unit
    package var per: Per
    /// Where time counts; any time when nil.
    package var during: During?

    package init(
        id: UUID = UUID(),
        subject: Subject,
        amount: Int,
        unit: Unit,
        per: Per,
        during: During? = nil
    ) {
        self.id = id
        self.subject = subject
        self.amount = amount
        self.unit = unit
        self.per = per
        self.during = during
    }

    /// The allowance in seconds.
    package var seconds: Int { max(amount, 0) * (unit == .minutes ? 60 : 3600) }

    /// How much of the allowance is used in the period containing `date`, counting the open slot up to `date`.
    package func usage(_ database: Database, schedule: Schedule, at date: Date, calendar: Calendar) throws -> Usage {
        let interval = per.period.interval(containing: date, calendar: calendar)
        let start = Int(interval.start.timeIntervalSince1970)
        let end = Int(interval.end.timeIntervalSince1970)
        let windows =
            during.map { during in
                schedule.windows(from: start, to: end, calendar: calendar).filter(during.contains)
            } ?? [Schedule.Window(label: nil, start: start, end: end)]
        let now = Int(date.timeIntervalSince1970)
        return Usage(
            start: start,
            end: end,
            windows: windows,
            used: try used(database, windows: windows, now: now),
            limit: seconds
        )
    }

    /// Time on the subject inside `windows`, cut at their edges, like `Report.apps(_:windows:now:)`.
    private func used(_ database: Database, windows: [Schedule.Window], now: Int) throws -> Int {
        guard !windows.isEmpty else { return 0 }
        let json = "[" + windows.map { "[\($0.start),\($0.end)]" }.joined(separator: ",") + "]"
        let (filter, key) =
            switch subject {
            case .app(let bundleID, _):
                ("s.app_id = (SELECT id FROM apps WHERE bundle_id = ?3 AND kind = 'app')", bundleID)
            case .program(let name):
                ("s.sub_app_id = (SELECT id FROM apps WHERE bundle_id = ?3 AND kind = 'program')", name)
            case .site(let domain):
                // The site itself, or any subdomain: a suffix of a dot and the site.
                ("(s.domain = ?3 OR substr(s.domain, -length(?3) - 1) = '.' || ?3)", domain)
            }
        return try database.rows(
            """
            WITH w(start, end) AS (
                SELECT value ->> 0, value ->> 1 FROM json_each(?1)
            ),
            s AS (
                SELECT w.start AS w_start, w.end AS w_end, s.* FROM w JOIN slots s
                    ON s.started_at >= w.start - 90000 AND s.started_at < w.end
                   AND s.ended_at IS NOT NULL AND s.ended_at > w.start
                UNION ALL
                SELECT w.start, w.end, s.* FROM w JOIN slots s
                    ON s.ended_at IS NULL AND s.started_at < w.end AND ?2 > w.start
            )
            SELECT COALESCE(SUM(MAX(MIN(COALESCE(s.ended_at, ?2), s.w_end) - MAX(s.started_at, s.w_start), 0)), 0)
            FROM s WHERE \(filter)
            """,
            [.text(json), .integer(now), .text(key)]
        ) { $0.int(0) }[0]
    }
}

extension Allowance {
    /// An allowance's period so far: when it counts, and how much it has used.
    package struct Usage: Equatable, Sendable {
        /// The period, `[start, end)` in unix seconds.
        package let start: Int
        package let end: Int
        /// When time counts in the period: all of it, or a label's windows, or the windows between labels.
        package let windows: [Schedule.Window]
        package let used: Int
        package let limit: Int

        package init(start: Int, end: Int, windows: [Schedule.Window], used: Int, limit: Int) {
            self.start = start
            self.end = end
            self.windows = windows
            self.used = used
            self.limit = limit
        }

        package var isOver: Bool { used >= limit }

        /// Whether time spent at `now` counts.
        package func counts(at now: Int) -> Bool {
            windows.contains { $0.start <= now && now < $0.end }
        }

        /// When `seconds` more counted time will have gone by, starting at `now`, if the period has that much left.
        /// With 0, the first moment from `now` that counts.
        package func instant(after seconds: Int, from now: Int) -> Int? {
            var left = seconds
            for window in windows where window.end > now {
                let start = max(window.start, now)
                if left <= window.end - start { return start + left }
                left -= window.end - start
            }
            return nil
        }

        /// What to do while the allowance's subject is in front: whether to send a notice now, and when to look
        /// again, if it stays in front. Over the allowance, in time that counts, a notice goes out at once, then
        /// every `reminder` seconds; `lastNotice` is when the last one went out. Otherwise, the next look is when the
        /// allowance would run out, or the period ends, when it starts over.
        package func next(now: Int, lastNotice: Int?, reminder: Int) -> (notify: Bool, at: Int) {
            guard isOver, counts(at: now) else {
                return (false, instant(after: max(limit - used, 0), from: now) ?? end)
            }
            // A notice from an earlier period doesn't count.
            guard let lastNotice, lastNotice >= start, now - lastNotice < reminder else {
                return (true, min(now + reminder, end))
            }
            return (false, min(lastNotice + reminder, end))
        }
    }
}

extension Allowance {
    /// Apps, sites and programs used in the last 30 days, each kind most used first, to choose an allowance's
    /// subject from. Browsers aren't offered: their sites are.
    package static func recent(_ database: Database, now: Int, limit: Int = 20) throws -> [Subject] {
        let since = now - 30 * 86_400
        let apps = try database.rows(
            """
            SELECT a.bundle_id, a.name FROM slots s JOIN apps a ON a.id = s.app_id
            WHERE s.started_at >= ?1 AND a.kind = 'app'
            GROUP BY a.id ORDER BY SUM(COALESCE(s.duration, 0)) DESC
            """,
            [.integer(since)]
        ) { Subject.app(bundleID: $0.text(0), name: $0.text(1)) }
        .filter {
            guard case .app(let bundleID, _) = $0 else { return false }
            return !Browsers.all.contains(bundleID) && !bundleID.hasPrefix(BundleID.recorder)
        }
        let sites = try database.rows(
            """
            SELECT domain FROM slots WHERE started_at >= ?1 AND domain != ''
            GROUP BY domain ORDER BY SUM(COALESCE(duration, 0)) DESC LIMIT ?2
            """,
            [.integer(since), .integer(limit)]
        ) { Subject.site(domain: $0.text(0)) }
        let programs = try database.rows(
            """
            SELECT p.bundle_id FROM slots s JOIN apps p ON p.id = s.sub_app_id
            WHERE s.started_at >= ?1 AND p.kind = 'program'
            GROUP BY p.id ORDER BY SUM(COALESCE(s.duration, 0)) DESC LIMIT ?2
            """,
            [.integer(since), .integer(limit)]
        ) { Subject.program(name: $0.text(0)) }
        return Array(apps.prefix(limit)) + sites + programs
    }

    /// "45m", "1h 30m", "2h".
    package static func describe(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return seconds < 60 ? "\(seconds)s" : "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
