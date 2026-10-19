import SQLite3

/// An error from SQLite, with its message.
package struct SQLiteError: Error, CustomStringConvertible {
    package let description: String
}

/// A value bound to a statement's parameter.
package enum SQLValue {
    case integer(Int)
    case text(String)
    case null
}

/// One result row, valid only inside the closure it's passed to.
package struct Row {
    fileprivate let statement: OpaquePointer

    package func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    package func text(_ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    package func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }
}

/// A connection to a SQLite database. Use it from one thread only.
package final class Database {
    private let handle: OpaquePointer

    package init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw SQLiteError(description: "\(path): \(message)")
        }
        self.handle = handle
        // The viewer reads while the recorder writes; WAL makes that rare, but not impossible.
        sqlite3_busy_timeout(handle, 1000)
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements that take no parameters.
    package func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
    }

    /// Runs one statement with parameters, discarding any rows.
    package func run(_ sql: String, _ parameters: [SQLValue] = []) throws {
        _ = try rows(sql, parameters) { _ in () }
    }

    /// Runs one statement with parameters, numbered from ?1, and maps each row.
    package func rows<T>(_ sql: String, _ parameters: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error(sql)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            switch parameter {
            case .integer(let value): sqlite3_bind_int64(statement, position, Int64(value))
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, transient)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: results.append(try map(Row(statement: statement)))
            case SQLITE_DONE: return results
            default: throw error(sql)
            }
        }
    }

    /// Runs the body atomically. Nests: an inner call is a savepoint inside the outer one.
    package func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("SAVEPOINT chronos")
        do {
            let result = try body()
            try execute("RELEASE chronos")
            return result
        } catch {
            try? execute("ROLLBACK TO chronos")
            try? execute("RELEASE chronos")
            throw error
        }
    }

    package var userVersion: Int {
        get throws { try rows("PRAGMA user_version") { $0.int(0) }.first ?? 0 }
    }

    private func error(_ sql: String) -> SQLiteError {
        SQLiteError(description: "\(String(cString: sqlite3_errmsg(handle))) (in: \(sql))")
    }
}
