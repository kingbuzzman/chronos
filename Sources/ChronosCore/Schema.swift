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
    ]

    package struct TooNewError: Error, CustomStringConvertible {
        package let found: Int
        package let supported: Int

        package var description: String {
            "The database is version \(found), but this version of Chronos only understands up to \(supported)."
        }
    }

    /// Brings the database up to the latest version, one step per transaction. Before changing a database that
    /// already has data, copies it next to the original as `<name>.v<version>.sqlite`.
    package static func migrate(_ database: Database, path: String, migrations: [String] = migrations) throws {
        let version = try database.userVersion
        guard version <= migrations.count else { throw TooNewError(found: version, supported: migrations.count) }
        guard version < migrations.count else { return }
        if version > 0, path != ":memory:" { try backUp(database, path: path, version: version) }
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
