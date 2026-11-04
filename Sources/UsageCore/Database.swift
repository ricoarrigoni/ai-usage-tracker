import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let description: String
}

/// A small wrapper around the system SQLite library.
final class Database {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            throw DatabaseError(description: "Couldn't open the database at \(url.path)")
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode = WAL")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        return Statement(statement, database: self)
    }

    fileprivate func lastError() -> DatabaseError {
        DatabaseError(description: String(cString: sqlite3_errmsg(handle)))
    }
}

final class Statement {
    private let pointer: OpaquePointer
    private let database: Database

    fileprivate init(_ pointer: OpaquePointer, database: Database) {
        self.pointer = pointer
        self.database = database
    }

    deinit { sqlite3_finalize(pointer) }

    /// Runs the statement with these values, and passes each result row to `row`.
    func run(_ values: [Value] = [], row: ((Statement) throws -> Void)? = nil) throws {
        sqlite3_reset(pointer)
        sqlite3_clear_bindings(pointer)
        let copyText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let number): sqlite3_bind_int64(pointer, position, number)
            case .text(let text): sqlite3_bind_text(pointer, position, text, -1, copyText)
            case .null: sqlite3_bind_null(pointer, position)
            }
        }
        while true {
            switch sqlite3_step(pointer) {
            case SQLITE_ROW: try row?(self)
            case SQLITE_DONE: return
            default: throw database.lastError()
            }
        }
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(pointer, column) }

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(pointer, column).map { String(cString: $0) }
    }

    enum Value {
        case int(Int64)
        case text(String)
        case null
    }
}
