package import Foundation

/// What has focus: an app and, where Chronos can tell, what's inside it. At most one of `domain` and `program` is set.
package struct Target: Equatable, Sendable {
    package let bundleID: String
    package let name: String
    /// The current tab's host, for browsers; '' for everything else.
    package let domain: String
    /// The program in front, for terminals, such as `claude`. Stored as an app of its own, which the slot points at.
    package let program: String?

    package init(bundleID: String, name: String, domain: String = "", program: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.domain = domain
        self.program = program
    }
}

package struct StoreError: Error, CustomStringConvertible {
    package let description: String
}

/// The recorder's connection: opens and closes slots. Times are unix seconds, UTC; slots are half-open,
/// `[started_at, ended_at)`, so a closing slot and the next one share the same instant.
package final class Store {
    package let database: Database
    private let calendar: Calendar
    private var apps: [String: (id: Int, name: String)] = [:]

    /// Opens the database, creating or migrating it as needed.
    package init(path: String, calendar: Calendar = .autoupdatingCurrent) throws {
        database = try Database(path: path)
        // Lets the viewer and other tools read while the recorder writes. Not inside a transaction, so before migrating.
        try database.execute("PRAGMA journal_mode = WAL")
        try Schema.migrate(database, path: path)
        self.calendar = calendar
    }

    /// Opens a slot for the target. There must be no open slot: SQLite rejects a second one.
    package func open(_ target: Target, at time: Int) throws {
        // SQLite can't add this check to the existing table without rebuilding it, so it's enforced here.
        guard target.domain.isEmpty || target.program == nil else {
            throw StoreError(description: "\(target.name) has both a domain and a program")
        }
        let app = try appID(bundleID: target.bundleID, name: target.name, kind: "app")
        let program = try target.program.map { try appID(bundleID: $0, name: $0, kind: "program") }
        try database.run(
            "INSERT INTO slots (app_id, sub_app_id, domain, started_at) VALUES (?1, ?2, ?3, ?4)",
            [.integer(app), program.map { .integer($0) } ?? .null, .text(target.domain), .integer(time)]
        )
        CrashClose.cutoff = Days.nextMidnight(after: time, calendar: calendar)
    }

    /// Closes the open slot, if any, cutting it at each local midnight it crosses: the row before a midnight ends at
    /// exactly midnight, and a `continued` row picks up from there.
    package func closeOpen(at time: Int) throws {
        let open = try database.rows(
            "SELECT id, app_id, sub_app_id, domain, started_at FROM slots WHERE ended_at IS NULL"
        ) {
            (
                id: $0.int(0), app: $0.int(1), program: $0.isNull(2) ? SQLValue.null : .integer($0.int(2)),
                domain: $0.text(3), start: $0.int(4)
            )
        }
        guard let open = open.first else { return }
        let end = max(time, open.start)
        let cuts = Days.midnights(after: open.start, before: end, calendar: calendar)
        try database.transaction {
            try database.run(
                "UPDATE slots SET ended_at = ?1 WHERE id = ?2",
                [.integer(cuts.first ?? end), .integer(open.id)]
            )
            for (index, cut) in cuts.enumerated() {
                try database.run(
                    """
                    INSERT INTO slots (app_id, sub_app_id, domain, started_at, ended_at, continued)
                    VALUES (?1, ?2, ?3, ?4, ?5, 1)
                    """,
                    [
                        .integer(open.app), open.program, .text(open.domain), .integer(cut),
                        .integer(index + 1 < cuts.count ? cuts[index + 1] : end),
                    ]
                )
            }
        }
    }

    /// Closes a slot left open by a crash the crash handler couldn't record. Its real end is unknown, so it gets one
    /// second rather than any invented time.
    package func recover() throws {
        try database.run("UPDATE slots SET ended_at = started_at + 1 WHERE ended_at IS NULL")
    }

    /// The app's row, or the program's, created on first sight. Keeps the latest display name, which changes with
    /// updates and language.
    private func appID(bundleID: String, name: String, kind: String) throws -> Int {
        if let app = apps[bundleID], app.name == name { return app.id }
        let id = try database.rows(
            """
            INSERT INTO apps (bundle_id, name, kind) VALUES (?1, ?2, ?3)
            ON CONFLICT (bundle_id) DO UPDATE SET name = excluded.name
            RETURNING id
            """,
            [.text(bundleID), .text(name), .text(kind)]
        ) { $0.int(0) }[0]
        apps[bundleID] = (id, name)
        return id
    }
}
