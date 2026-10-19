import ChronosCore
import Foundation
import Testing

struct SchemaTests {
    @Test func aNewDatabaseIsAtTheLatestVersion() throws {
        let store = try Store()

        #expect(try store.database.userVersion == Schema.migrations.count)
    }

    @Test func refusesADatabaseNewerThanItKnows() throws {
        let database = try Database(path: ":memory:")
        try database.execute("PRAGMA user_version = \(Schema.migrations.count + 1)")

        #expect(throws: Schema.TooNewError.self) { try Schema.migrate(database, path: ":memory:") }
        #expect(throws: Schema.TooNewError.self) { try Schema.checkReadable(database) }
    }

    @Test func migratingBacksUpFirstAndKeepsEveryRow() throws {
        // A file, since the backup is a copy next to it. In the temporary folder, which macOS clears on its own.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chronos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("chronos.sqlite").path
        let store = try Store(path: path, calendar: newYork)
        try store.open(chrome, at: at(2026, 10, 19, 9))
        try store.closeOpen(at: at(2026, 10, 19, 10))
        let next = Schema.migrations + ["ALTER TABLE slots ADD COLUMN note TEXT NOT NULL DEFAULT ''"]

        try Schema.migrate(store.database, path: path, migrations: next)

        #expect(try store.database.userVersion == next.count)
        #expect(try store.slots.map(\.duration) == [3600])
        let version = Schema.migrations.count
        let backup = try Database(
            path: folder.appendingPathComponent("chronos.v\(version).sqlite").path,
            readOnly: true
        )
        #expect(try backup.userVersion == version)
        #expect(try backup.rows("SELECT duration FROM slots") { $0.int(0) } == [3600])
    }

    @Test func browserHostsSurviveEveryVersion() throws {
        let database = try Database(path: ":memory:")
        try Schema.migrate(database, path: ":memory:", migrations: Array(Schema.migrations.prefix(1)))
        try database.execute(
            """
            INSERT INTO apps (bundle_id, name) VALUES ('com.google.Chrome', 'Google Chrome');
            INSERT INTO slots (app_id, domain, started_at, ended_at) VALUES (1, 'github.com', 100, 160);
            """
        )

        try Schema.migrate(database, path: ":memory:")

        #expect(try database.userVersion == Schema.migrations.count)
        #expect(
            try database.rows("SELECT domain, duration FROM slots") { [$0.text(0), "\($0.int(1))"] } == [
                ["github.com", "60"]
            ]
        )
    }

    @Test func version3MovesTerminalProgramsIntoApps() throws {
        let database = try Database(path: ":memory:")
        try Schema.migrate(database, path: ":memory:", migrations: Array(Schema.migrations.prefix(2)))
        try database.execute(
            """
            INSERT INTO apps (bundle_id, name) VALUES ('com.apple.Terminal', 'Terminal'), ('com.google.Chrome', 'Chrome');
            INSERT INTO slots (app_id, detail, started_at, ended_at) VALUES
                (1, 'claude', 100, 160), (1, 'zsh', 160, 200), (1, 'claude', 200, 260), (2, 'github.com', 260, 300),
                (1, '', 300, 310);
            """
        )

        try Schema.migrate(database, path: ":memory:")

        #expect(
            try database.rows("SELECT bundle_id, name, kind FROM apps ORDER BY id") {
                [$0.text(0), $0.text(1), $0.text(2)]
            }
                == [
                    ["com.apple.Terminal", "Terminal", "app"], ["com.google.Chrome", "Chrome", "app"],
                    ["claude", "claude", "program"], ["zsh", "zsh", "program"],
                ]
        )
        #expect(
            try database.rows(
                """
                SELECT a.bundle_id, s.domain, COALESCE(p.bundle_id, '-'), s.duration
                FROM slots s JOIN apps a ON a.id = s.app_id LEFT JOIN apps p ON p.id = s.sub_app_id ORDER BY s.id
                """
            ) { [$0.text(0), $0.text(1), $0.text(2), "\($0.int(3))"] }
                == [
                    ["com.apple.Terminal", "", "claude", "60"], ["com.apple.Terminal", "", "zsh", "40"],
                    ["com.apple.Terminal", "", "claude", "60"], ["com.google.Chrome", "github.com", "-", "40"],
                    ["com.apple.Terminal", "", "-", "10"],
                ]
        )
    }

    @Test func aFailedStepRollsBack() throws {
        let store = try Store()
        let broken = Schema.migrations + ["CREATE TABLE extra (id INTEGER); THIS IS NOT SQL"]

        #expect(throws: SQLiteError.self) { try Schema.migrate(store.database, path: ":memory:", migrations: broken) }
        #expect(try store.database.userVersion == Schema.migrations.count)
        #expect(try store.database.rows("SELECT name FROM sqlite_master WHERE name = 'extra'") { $0.text(0) } == [])
    }
}
