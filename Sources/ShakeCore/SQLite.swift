import Foundation
import SQLite3

public enum SQLiteValue {
    case null, integer(Int64), real(Double), text(String), blob(Data)
    public static func string(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
    public static func int(_ value: Int64?) -> SQLiteValue { value.map(SQLiteValue.integer) ?? .null }
    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    public var double: Double? {
        switch self { case .real(let value): value; case .integer(let value): Double(value); default: nil }
    }
}

public struct SQLiteRow { public let values: [String: SQLiteValue]; public subscript(_ key: String) -> SQLiteValue? { values[key] } }
public struct SQLiteError: LocalizedError { public let message: String; public var errorDescription: String? { message } }

public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
        sqlite3_busy_timeout(handle, 5_000)
        try executeScript("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
    }
    deinit { sqlite3_close(handle) }

    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func bind(_ statement: OpaquePointer?, _ bindings: [SQLiteValue]) throws {
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, position)
            case .integer(let number): result = sqlite3_bind_int64(statement, position, number)
            case .real(let number): result = sqlite3_bind_double(statement, position, number)
            case .text(let string): result = sqlite3_bind_text(statement, position, string, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            }
            if result != SQLITE_OK { throw SQLiteError(message: String(cString: sqlite3_errmsg(handle))) }
        }
    }

    @discardableResult public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw SQLiteError(message: String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        try bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteError(message: String(cString: sqlite3_errmsg(handle))) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw SQLiteError(message: String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        try bind(statement, bindings)
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw SQLiteError(message: String(cString: sqlite3_errmsg(handle))) }
            var values: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, index))
                    values[name] = .blob(Data(bytes: sqlite3_column_blob(statement, index), count: length))
                default: values[name] = .null
                }
            }
            rows.append(SQLiteRow(values: values))
        }
        return rows
    }

    public func transaction<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let value = try operation(); try execute("COMMIT"); return value }
        catch { _ = try? execute("ROLLBACK"); throw error }
    }
}
