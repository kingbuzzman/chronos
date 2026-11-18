import Foundation

/// The database's versions, kept in `PRAGMA user_version`, and the steps between them.
package enum Schema {
    /// Each step takes the database from version `index` to `index + 1`. Never edit a released step: add a new one
    /// that moves the existing data into the new format.
    package static let migrations: [String] = [
        """
        CREATE TABLE apps (
            id        INTEGER PRIMARY KEY,
            bundle_id TEXT NOT NULL UNIQUE,
            name      TEXT NOT NULL
        );
        CREATE TABLE slots (
            id         INTEGER PRIMARY KEY,
            app_id     INTEGER NOT NULL REFERENCES apps(id),
            domain     TEXT    NOT NULL DEFAULT '',
            started_at INTEGER NOT NULL,
            ended_at   INTEGER CHECK (ended_at IS NULL OR ended_at >= started_at),
            duration   INTEGER GENERATED ALWAYS AS (ended_at - started_at) STORED,
            continued  INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX slots_started_at ON slots(started_at);
        CREATE UNIQUE INDEX slots_one_open ON slots (ended_at IS NULL) WHERE ended_at IS NULL;
        """,
        // 2: the column holds more than browser hosts now, such as the program running in a terminal.
        "ALTER TABLE slots RENAME COLUMN domain TO detail;",
        // 3: a program running in a terminal becomes an app of its own, which the slot points at alongside the app
        // it runs in; the text column goes back to holding only browser hosts. A program's bundle_id is its name.
        """
        ALTER TABLE apps ADD COLUMN kind TEXT NOT NULL DEFAULT 'app' CHECK (kind IN ('app', 'program'));
        ALTER TABLE slots ADD COLUMN sub_app_id INTEGER REFERENCES apps(id);
        INSERT INTO apps (bundle_id, name, kind)
            SELECT DISTINCT s.detail, s.detail, 'program' FROM slots s JOIN apps a ON a.id = s.app_id
            WHERE a.bundle_id = 'com.apple.Terminal' AND s.detail != ''
            ON CONFLICT (bundle_id) DO NOTHING;
        UPDATE slots SET sub_app_id = (SELECT p.id FROM apps p WHERE p.kind = 'program' AND p.bundle_id = slots.detail)
            WHERE detail != '' AND app_id IN (SELECT id FROM apps WHERE bundle_id = 'com.apple.Terminal');
        UPDATE slots SET detail = '' WHERE sub_app_id IS NOT NULL;
        ALTER TABLE slots RENAME COLUMN detail TO domain;
        """,
        // 4: time in front with nobody at it is marked away, and each slot keeps how much input it had. Earlier slots
        // weren't measured: their counts are NULL, not 0.
        """
        ALTER TABLE slots ADD COLUMN away INTEGER NOT NULL DEFAULT 0 CHECK (away IN (0, 1));
        ALTER TABLE slots ADD COLUMN keys INTEGER;
        ALTER TABLE slots ADD COLUMN clicks INTEGER;
        ALTER TABLE slots ADD COLUMN scrolls INTEGER;
        ALTER TABLE slots ADD COLUMN moves INTEGER;
        """,
        // 5: input moves off slots into 5-minute chunks of the clock, per app in front, so a long slot still shows when
        // in it there was input. Chunks without input have no row. Each slot's counts are spread over the chunks it
        // overlaps by its time in each, in whole counts that add up to the slot's. Away goes: Chronos no longer guesses
        // it, and the version 4 backup keeps it.
        """
        CREATE TABLE input (
            id         INTEGER PRIMARY KEY,
            started_at INTEGER NOT NULL CHECK (started_at % 300 = 0),
            app_id     INTEGER NOT NULL REFERENCES apps(id),
            sub_app_id INTEGER REFERENCES apps(id),
            domain     TEXT    NOT NULL DEFAULT '',
            keys       INTEGER NOT NULL,
            clicks     INTEGER NOT NULL,
            scrolls    INTEGER NOT NULL,
            moves      INTEGER NOT NULL
        );
        CREATE INDEX input_started_at ON input(started_at);
        WITH RECURSIVE parts (slot, chunk) AS (
            SELECT id, started_at - started_at % 300 FROM slots WHERE keys IS NOT NULL AND ended_at IS NOT NULL
            UNION ALL
            SELECT p.slot, p.chunk + 300 FROM parts p JOIN slots s ON s.id = p.slot WHERE p.chunk + 300 < s.ended_at
        ),
        -- Seconds of the slot up to the start and the end of each of its chunks, out of its length. A zero-length slot
        -- is all in its one chunk.
        shares AS (
            SELECT s.app_id, s.sub_app_id, s.domain, p.chunk, s.keys, s.clicks, s.scrolls, s.moves,
                max(s.started_at, p.chunk) - s.started_at AS upto,
                CASE WHEN s.duration = 0 THEN 1 ELSE min(s.ended_at, p.chunk + 300) - s.started_at END AS through,
                max(s.duration, 1) AS length
            FROM parts p JOIN slots s ON s.id = p.slot
        ),
        spread AS (
            SELECT chunk, app_id, sub_app_id, domain,
                SUM((keys * through + length / 2) / length - (keys * upto + length / 2) / length) AS keys,
                SUM((clicks * through + length / 2) / length - (clicks * upto + length / 2) / length) AS clicks,
                SUM((scrolls * through + length / 2) / length - (scrolls * upto + length / 2) / length) AS scrolls,
                SUM((moves * through + length / 2) / length - (moves * upto + length / 2) / length) AS moves
            FROM shares GROUP BY chunk, app_id, sub_app_id, domain
        )
        INSERT INTO input (started_at, app_id, sub_app_id, domain, keys, clicks, scrolls, moves)
            SELECT chunk, app_id, sub_app_id, domain, keys, clicks, scrolls, moves FROM spread
            WHERE keys + clicks + scrolls + moves > 0 ORDER BY chunk;
        ALTER TABLE slots DROP COLUMN away;
        ALTER TABLE slots DROP COLUMN keys;
        ALTER TABLE slots DROP COLUMN clicks;
        ALTER TABLE slots DROP COLUMN scrolls;
        ALTER TABLE slots DROP COLUMN moves;
        """,
    ]

    /// For steps whose result can be told from the database's shape, a query that returns 1 once it's there. Before
    /// migrating, the last step that's already there sets the version, and only the steps after it run: a database
    /// whose version is behind its shape, say from being fixed by hand, catches up instead of failing a step.
    package static let alreadyApplied: [Int: String] = [
        // 5: the input table.
        4: "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'input'"
    ]

    package struct TooNewError: Error, CustomStringConvertible {
        package let found: Int
        package let supported: Int

        package var description: String {
            "The database is version \(found), but this version of Chronos only understands up to \(supported)."
        }
    }

    /// Brings the database up to the latest version, one step per transaction. Before changing a database that
    /// already has data, copies it next to the original as `<name>.v<version>.sqlite`. Steps already in the database
    /// (`alreadyApplied`) are counted, not run.
    package static func migrate(_ database: Database, path: String, migrations: [String] = migrations) throws {
        var version = try database.userVersion
        guard version <= migrations.count else { throw TooNewError(found: version, supported: migrations.count) }
        guard version < migrations.count else { return }
        if version > 0, path != ":memory:" { try backUp(database, path: path, version: version) }
        if let done = try (version..<migrations.count).last(where: { try isApplied($0, in: database) }) {
            version = done + 1
            try database.execute("PRAGMA user_version = \(version)")
        }
        for step in version..<migrations.count {
            try database.transaction {
                try database.execute(migrations[step])
                try database.execute("PRAGMA user_version = \(step + 1)")
            }
        }
    }

    /// Throws if the database is newer than this build understands, for readers that can't migrate it.
    package static func checkReadable(_ database: Database) throws {
        let version = try database.userVersion
        guard version <= migrations.count else { throw TooNewError(found: version, supported: migrations.count) }
    }

    private static func isApplied(_ step: Int, in database: Database) throws -> Bool {
        guard let query = alreadyApplied[step] else { return false }
        return try database.rows(query) { $0.int(0) } == [1]
    }

    private static func backUp(_ database: Database, path: String, version: Int) throws {
        let original = URL(fileURLWithPath: path)
        let folder = original.deletingLastPathComponent()
        let name = original.deletingPathExtension().lastPathComponent
        var backup = folder.appendingPathComponent("\(name).v\(version).sqlite")
        // VACUUM INTO refuses to overwrite, and an older backup of the same version is still worth keeping.
        if FileManager.default.fileExists(atPath: backup.path) {
            backup = folder.appendingPathComponent("\(name).v\(version)-\(Int(Date().timeIntervalSince1970)).sqlite")
        }
        try database.run("VACUUM INTO ?1", [.text(backup.path)])
    }
}
