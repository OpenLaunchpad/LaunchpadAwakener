import Foundation
import SQLite3

/// A value read from or bound to an SQLite statement.
package enum SQLiteValue: Sendable, Equatable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null

    package var integerValue: Int64? {
        switch self {
        case .integer(let integer): integer
        case .real(let real): Int64(real)
        case .text(let text): Int64(text)
        case .blob, .null: nil
        }
    }

    package var realValue: Double? {
        switch self {
        case .integer(let integer): Double(integer)
        case .real(let real): real
        case .text(let text): Double(text)
        case .blob, .null: nil
        }
    }

    package var textValue: String? {
        switch self {
        case .text(let text): text
        case .integer(let integer): String(integer)
        case .real(let real): String(real)
        case .blob, .null: nil
        }
    }

    package var blobValue: Data? {
        if case .blob(let blob) = self { blob } else { nil }
    }
}

package struct SQLiteError: Error, CustomStringConvertible {
    package let resultCode: Int32
    package let message: String
    package let statementText: String?

    package var description: String {
        if let statementText {
            "SQLite error \(resultCode): \(message) (in \(statementText))"
        } else {
            "SQLite error \(resultCode): \(message)"
        }
    }
}

/// The smallest wrapper over the SQLite C interface the layout store needs.
///
/// Not thread-safe: one connection belongs to one owner, which serialises every call.
package final class SQLiteDatabase {
    package enum OpenMode {
        /// Reads only, and never creates the file. What the legacy database is opened with.
        case readOnly
        case readWriteCreate
    }

    /// Tells SQLite to copy bound text and blobs before `sqlite3_bind_*` returns.
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let connection: OpaquePointer

    package init(path: String, mode: OpenMode) throws {
        let openFlags: Int32 = switch mode {
        case .readOnly: SQLITE_OPEN_READONLY
        case .readWriteCreate: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        var openedConnection: OpaquePointer?
        let resultCode = sqlite3_open_v2(path, &openedConnection, openFlags | SQLITE_OPEN_FULLMUTEX, nil)
        guard resultCode == SQLITE_OK, let openedConnection else {
            let message = openedConnection.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(openedConnection)
            throw SQLiteError(resultCode: resultCode, message: message, statementText: nil)
        }
        connection = openedConnection
        sqlite3_busy_timeout(connection, 2000)
    }

    deinit {
        sqlite3_close_v2(connection)
    }

    package var lastInsertedRowIdentifier: Int64 {
        sqlite3_last_insert_rowid(connection)
    }

    /// Runs one or more statements that take no arguments, such as a schema.
    package func execute(_ statementText: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let resultCode = sqlite3_exec(connection, statementText, nil, nil, &errorMessage)
        guard resultCode == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteError(resultCode: resultCode, message: message, statementText: statementText)
        }
    }

    /// Runs one statement that returns no rows.
    package func run(_ statementText: String, _ arguments: [SQLiteValue] = []) throws {
        _ = try rows(statementText, arguments)
    }

    /// Runs one statement and returns every row it produces.
    package func rows(_ statementText: String, _ arguments: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        let prepareResultCode = sqlite3_prepare_v2(connection, statementText, -1, &statement, nil)
        guard prepareResultCode == SQLITE_OK, let statement else {
            throw makeError(resultCode: prepareResultCode, statementText: statementText)
        }
        defer { sqlite3_finalize(statement) }

        for (argumentIndex, argument) in arguments.enumerated() {
            let parameterIndex = Int32(argumentIndex + 1)
            let bindResultCode: Int32 = switch argument {
            case .integer(let integer):
                sqlite3_bind_int64(statement, parameterIndex, integer)
            case .real(let real):
                sqlite3_bind_double(statement, parameterIndex, real)
            case .text(let text):
                sqlite3_bind_text(statement, parameterIndex, text, -1, Self.transientDestructor)
            case .blob(let blob):
                blob.withUnsafeBytes { blobBytes in
                    sqlite3_bind_blob(statement, parameterIndex, blobBytes.baseAddress, Int32(blobBytes.count), Self.transientDestructor)
                }
            case .null:
                sqlite3_bind_null(statement, parameterIndex)
            }
            guard bindResultCode == SQLITE_OK else {
                throw makeError(resultCode: bindResultCode, statementText: statementText)
            }
        }

        var resultRows: [[SQLiteValue]] = []
        while true {
            let stepResultCode = sqlite3_step(statement)
            if stepResultCode == SQLITE_DONE { break }
            guard stepResultCode == SQLITE_ROW else {
                throw makeError(resultCode: stepResultCode, statementText: statementText)
            }
            let columnCount = sqlite3_column_count(statement)
            resultRows.append((0..<columnCount).map { columnIndex in Self.value(of: statement, at: columnIndex) })
        }
        return resultRows
    }

    /// Runs `body` inside one transaction; rolls back if it throws.
    ///
    /// Nests: a call inside another call's `body` becomes a savepoint of the outer transaction, so
    /// helpers that need atomicity of their own can still be composed into a larger transaction.
    package func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        let savepointName = "nested_transaction_\(transactionDepth)"
        try execute(transactionDepth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepointName)")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try execute(transactionDepth == 1 ? "COMMIT" : "RELEASE \(savepointName)")
            return result
        } catch {
            if transactionDepth == 1 {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(savepointName)")
                try? execute("RELEASE \(savepointName)")
            }
            throw error
        }
    }

    private var transactionDepth = 0

    private static func value(of statement: OpaquePointer, at columnIndex: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, columnIndex) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, columnIndex))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, columnIndex))
        case SQLITE_TEXT:
            return sqlite3_column_text(statement, columnIndex).map { .text(String(cString: $0)) } ?? .null
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(statement, columnIndex))
            guard let blobBytes = sqlite3_column_blob(statement, columnIndex), byteCount > 0 else { return .blob(Data()) }
            return .blob(Data(bytes: blobBytes, count: byteCount))
        default:
            return .null
        }
    }

    private func makeError(resultCode: Int32, statementText: String) -> SQLiteError {
        SQLiteError(resultCode: resultCode, message: String(cString: sqlite3_errmsg(connection)), statementText: statementText)
    }
}
