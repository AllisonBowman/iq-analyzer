import Foundation
import CryptoKit
import SQLite3
@testable import IQCoach

/// A temporary memory.sqlite built by executing iqa/memory_schema.sql (the single source of truth), with rows
/// inserted by SQL and blobs compressed with Apple's `.zlib` (raw DEFLATE), as iqa/memory.py writes them.
final class TestMemory {
    let dir: URL
    var url: URL { dir.appendingPathComponent(MemoryDatabase.fileName) }
    var database: MemoryDatabase { MemoryDatabase(url: url) }
    private var db: OpaquePointer?

    static let key = "m1-r30-s0"

    /// iqa/memory_schema.sql, found from this file: Tests/IQCoachTests/ -> ../../../../iqa/.
    static func schemaURL(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent()
            .appendingPathComponent("../../../../iqa/memory_schema.sql").standardizedFileURL
    }

    static func tempDir(_ label: String = "memory") throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("iqcoach-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init(window: Int? = nil, currentKey: String? = TestMemory.key) throws {
        dir = try Self.tempDir()
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw MemoryDatabaseError.cannotOpen(url.path, "test open")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec(String(contentsOf: Self.schemaURL(), encoding: .utf8))
        if let currentKey { try run("INSERT INTO meta (key, value) VALUES ('current_analyzer_key', ?)", [.text(currentKey)]) }
        if let window { try run("INSERT INTO meta (key, value) VALUES ('window', ?)", [.text(String(window))]) }
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw MemoryDatabaseError.query(sql, m)
        }
    }

    func run(_ sql: String, _ values: [MemoryValue]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MemoryDatabaseError.query(sql, String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in values.enumerated() { v.bind(stmt, Int32(i + 1)) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MemoryDatabaseError.query(sql, String(cString: sqlite3_errmsg(db))) }
    }

    var lastRowID: Int64 { sqlite3_last_insert_rowid(db) }

    static func sha(_ seed: String) -> String { ContentHash.sha256(of: Data(seed.utf8)) }

    static func deflate(_ data: Data) throws -> Data { try (data as NSData).compressed(using: .zlib) as Data }

    /// The JSON a record blob holds: the results.json row without path, edges and noise_curve.
    static func recordJSON(_ p: PhotoRecord) throws -> Data {
        var q = p
        q.path = nil
        return try JSONEncoder().encode(q)
    }

    /// Inserts an asset (and its record when `record` is given) and returns its row id.
    @discardableResult
    func addAsset(sha: String, camera: String, ts: Double?, status: String = "measured", key: String = TestMemory.key,
                  file: String = "IMG.JPG", firstSeen: Double = 1_000, attempts: Int = 0, record: Data? = nil) throws -> Int64 {
        try run("""
            INSERT INTO asset (sha256, byte_size, file, camera, format, captured_ts, status, analyzer_key, measured_at, first_seen, last_seen, attempts)
            VALUES (?, 1000, ?, ?, 'jpeg', ?, ?, ?, 1000, ?, 1000, ?)
            """, [.blob(MemoryStore.data(hex: sha)!), .text(file), .text(camera), ts.map(MemoryValue.double) ?? .null,
                  .text(status), .text(key), .double(firstSeen), .int(Int64(attempts))])
        let id = lastRowID
        if let record { try run("INSERT INTO record (asset_id, z) VALUES (?, ?)", [.int(id), .blob(try Self.deflate(record))]) }
        return id
    }

    /// A measured photo with its record, from a fixture PhotoRecord.
    @discardableResult
    func addPhoto(_ p: PhotoRecord, seed: String, ts: Double?, key: String = TestMemory.key, firstSeen: Double = 1_000) throws -> (id: Int64, sha: String) {
        let sha = Self.sha(seed)
        let id = try addAsset(sha: sha, camera: p.cameraModel ?? "", ts: ts, key: key, file: p.file, firstSeen: firstSeen,
                              record: try Self.recordJSON(p))
        return (id, sha)
    }

    func addSource(assetID: Int64, kind: String, locator: String, signature: String? = nil, verifiedAt: Double = 1_000) throws {
        try run("INSERT INTO source (kind, locator, asset_id, signature, verified_at) VALUES (?, ?, ?, ?, ?)",
                [.text(kind), .text(locator), .int(assetID), signature.map(MemoryValue.text) ?? .null, .double(verifiedAt)])
    }

    func addBucket(camera: String, month: String, key: String = TestMemory.key, n: Int, json: String) throws {
        try run("INSERT INTO archive (camera, month, analyzer_key, n, z) VALUES (?, ?, ?, ?, ?)",
                [.text(camera), .text(month), .text(key), .int(Int64(n)), .blob(try Self.deflate(Data(json.utf8)))])
    }
}
