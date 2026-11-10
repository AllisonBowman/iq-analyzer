import Foundation
import SQLite3

enum MemoryDatabaseError: LocalizedError, Equatable {
    case missing(String)
    case cannotOpen(String, String)
    case notAMemory(String)
    case newerSchema(Int32)
    case query(String, String)

    var errorDescription: String? {
        switch self {
        case .missing(let p): "There is no memory at \(p) yet. It is created by the first analysis."
        case .cannotOpen(let p, let m): "The memory at \(p) could not be opened. SQLite said: \(m)"
        case .notAMemory(let p): "\(p) is an SQLite file but not IQ Coach's memory, so it was not read."
        case .newerSchema(let v): "The memory was written by a newer analyzer (schema \(v)); this IQ Coach reads schema \(MemoryDatabase.schemaVersion). Update the app."
        case .query(let sql, let m): "Reading the memory failed (\(m)) in: \(sql)"
        }
    }
}

/// The analyzer's memory, `memory.sqlite` (schema in iqa/memory_schema.sql). The analyzer is its only writer, so the app
/// opens it read-write with `query_only` on (a WAL file opened SQLITE_OPEN_READONLY fails with SQLITE_CANTOPEN when no
/// -wal/-shm exist), reads, and closes. A connection is never held: a long reader keeps WAL checkpoints from finishing.
struct MemoryDatabase: Sendable {
    /// "IQC1", PRAGMA application_id in the schema.
    static let applicationID: Int32 = 0x4951_4331
    static let schemaVersion: Int32 = 1
    static let fileName = "memory.sqlite"

    let url: URL

    /// ~/Library/Application Support/IQCoach, beside preferences.json.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("IQCoach", isDirectory: true)
    }

    init(url: URL) { self.url = url }
    init(directory: URL) { url = directory.appendingPathComponent(Self.fileName) }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The database and the WAL files SQLite keeps beside it.
    var companionFiles: [URL] { [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] }

    /// Bytes on disk: the database plus its -wal.
    var bytesOnDisk: Int64 {
        companionFiles.prefix(2).reduce(0) { sum, u in
            sum + ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Opens, runs `body`, closes. The connection must not escape `body`.
    func read<T>(_ body: (MemoryConnection) throws -> T) throws -> T {
        let c = try MemoryConnection(url: url)
        defer { c.close() }
        return try body(c)
    }
}

/// One short-lived read connection. Not Sendable: it lives inside `MemoryDatabase.read` on one thread.
final class MemoryConnection {
    private var db: OpaquePointer?
    let path: String

    init(url: URL) throws {
        path = url.path
        // Never create: a missing memory is reported, not made empty by the reader.
        guard FileManager.default.fileExists(atPath: path) else { throw MemoryDatabaseError.missing(path) }
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(rc))
            sqlite3_close_v2(db)
            db = nil
            throw MemoryDatabaseError.cannotOpen(path, m)
        }
        sqlite3_busy_timeout(db, 5000)
        do {
            try execute("PRAGMA query_only=ON")
            let app = try scalarInt("PRAGMA application_id") ?? 0
            // 0 is a file the analyzer has not stamped yet; anything else foreign is left alone.
            guard app == 0 || app == Int64(MemoryDatabase.applicationID) else { throw MemoryDatabaseError.notAMemory(path) }
            let version = try scalarInt("PRAGMA user_version") ?? 0
            guard version <= Int64(MemoryDatabase.schemaVersion) else { throw MemoryDatabaseError.newerSchema(Int32(version)) }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    deinit { close() }

    private var message: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection" }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MemoryDatabaseError.query(sql, message) }
    }

    /// Runs `sql` with `bindings` and calls `each` for every row.
    func rows(_ sql: String, _ bindings: [MemoryValue] = [], _ each: (MemoryRow) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MemoryDatabaseError.query(sql, message)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in bindings.enumerated() { v.bind(stmt, Int32(i + 1)) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw MemoryDatabaseError.query(sql, message) }
            try each(MemoryRow(stmt: stmt))
        }
    }

    func scalarInt(_ sql: String, _ bindings: [MemoryValue] = []) throws -> Int64? {
        var out: Int64?
        try rows(sql, bindings) { out = $0.int(0) }
        return out
    }

    /// True when the database has `table`; lets a read of an older or partial file degrade instead of failing.
    func hasTable(_ table: String) throws -> Bool {
        try scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]) ?? 0 > 0
    }
}

/// A value bound to a statement parameter.
enum MemoryValue: Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    /// SQLite copies bound text and blobs before the call returns.
    static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    func bind(_ stmt: OpaquePointer, _ i: Int32) {
        switch self {
        case .int(let v): sqlite3_bind_int64(stmt, i, v)
        case .double(let v): sqlite3_bind_double(stmt, i, v)
        case .text(let s): sqlite3_bind_text(stmt, i, s, -1, Self.transient)
        case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), Self.transient) }
        case .null: sqlite3_bind_null(stmt, i)
        }
    }
}

/// Typed column accessors for the current row; NULL reads as nil.
struct MemoryRow {
    let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String? {
        guard !isNull(i), let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }
    func blob(_ i: Int32) -> Data? {
        guard !isNull(i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}
