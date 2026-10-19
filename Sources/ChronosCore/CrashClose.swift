import Darwin
import SQLite3

/// A statement prepared at launch, on a connection of its own, that a crash handler runs to close the open slot with
/// the time of the crash. Globals, because signal handlers can't capture anything.
nonisolated(unsafe) private var crashStatement: OpaquePointer?

/// Closing a slot from a crash handler, best effort: the process is in an unknown state, so this may fail, in which
/// case the next launch's `Store.recover()` closes it instead.
package enum CrashClose {
    /// The next local midnight after the open slot started. A crash can't split a slot at midnight, so it ends it there
    /// instead: time after midnight is lost rather than written into the wrong day.
    nonisolated(unsafe) package static var cutoff = Int.max

    package static func prepare(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw SQLiteError(description: "\(path): can't open a connection for crashes")
        }
        // No busy timeout: if the crash came mid-write, the database is locked, and waiting would hang the crash.
        var statement: OpaquePointer?
        let sql = "UPDATE slots SET ended_at = max(started_at, min(?1, ?2)) WHERE ended_at IS NULL"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
        }
        crashStatement = statement
    }

    /// Called from a signal or exception handler.
    package static func run() {
        guard let statement = crashStatement else { return }
        sqlite3_bind_int64(statement, 1, Int64(time(nil)))
        sqlite3_bind_int64(statement, 2, Int64(cutoff))
        sqlite3_step(statement)
        sqlite3_reset(statement)
    }
}
