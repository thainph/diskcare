import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// Bindable SQL value.
enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

/// Minimal wrapper over the system SQLite3 library. Not thread-safe; callers serialize access.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// SQLite copies bound strings when given this destructor.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(error)
            throw SQLiteError(code: status, message: message)
        }
    }

    /// Runs a statement once per parameter set (prepared once).
    func run(_ sql: String, _ rows: [[SQLValue]]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for values in rows {
            try bind(values, to: statement)
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE || status == SQLITE_ROW else { throw failure(status) }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        try run(sql, [values])
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var results: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure(status) }
            results.append(try map(Row(statement: statement!)))
        }
        return results
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

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

    struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func optionalInt(_ column: Int32) -> Int64? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(column)
        }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
        }
    }

    private var lastMessage: String { String(cString: sqlite3_errmsg(handle)) }

    private func failure(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: lastMessage)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK else { throw failure(status) }
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .int(let number): status = sqlite3_bind_int64(statement, index, number)
            case .double(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let string): status = sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw failure(status) }
        }
    }
}
