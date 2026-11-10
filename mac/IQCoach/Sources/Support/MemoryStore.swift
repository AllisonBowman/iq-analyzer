import Foundation

/// One way a remembered content was reached (the `source` table): a file path, a PhotoKit localIdentifier or a
/// picker itemIdentifier. Several sources may share one content.
struct MemorySource: Sendable, Hashable {
    enum Kind: String, Sendable { case file, photokit, picker }
    let kind: Kind
    let locator: String
    /// PhotoKit: "originalFilename|uti|WxH" of the .photo resource.
    let signature: String?
    let verifiedAt: Double?
}

/// What the memory knows about a content or one of its sources, for the import decisions.
struct KnownAsset: Sendable, Hashable {
    /// "measured", "failed" or "not_capture".
    let status: String
    let analyzerKey: String
    /// The source's signature (PhotoKit only).
    var signature: String? = nil
    /// When the content behind the source was last hashed (unix seconds; sources only).
    var verifiedAt: Double? = nil
    /// Failed measurements with `analyzerKey`: a failure is final (not tried again) from the second one.
    var attempts: Int = 0
    /// The content id behind a source (sources only), to tell whether its preview exists.
    var sha256: String? = nil

    /// Failed attempts with one analyzer key before a photo is not tried again (iqa/memory.py FINAL_ATTEMPTS).
    static let finalAttempts = 2

    /// A failure that is not tried again with the current key; a first failure may have been a passing problem.
    var isFinalFailure: Bool { status == "failed" && attempts >= Self.finalAttempts }
}

/// Counts and bytes per tier (spec §8 item 4).
struct MemoryTierStats: Sendable, Equatable {
    var assets = 0
    var measured = 0
    var failed = 0
    var notCapture = 0
    var sources = 0
    var records = 0
    var recordBytes: Int64 = 0
    var details = 0
    var detailBytes: Int64 = 0
    var buckets = 0
    var bucketPhotos = 0
    var bucketBytes: Int64 = 0
    /// memory.sqlite plus its -wal.
    var databaseBytes: Int64 = 0
    /// captured_ts of the oldest and newest measured photo: the EXIF wall clock read as UTC.
    var oldestCapture: Double?
    var newestCapture: Double?
}

/// One camera in the ledger.
struct CameraMemory: Sendable, Equatable, Identifiable {
    /// The name the app groups by (`PhotoRecord.camera`).
    let camera: String
    /// The ledger's own name (the EXIF model, "" when the files name none), which `iqa memory forget --camera` takes.
    let ledgerName: String
    /// Measured photos remembered, in the window or not.
    let remembered: Int
    let oldestCapture: Double?
    let newestCapture: Double?
    var id: String { camera }
}

/// Everything the app reads from the memory at once: the window, its sources, the ledger's counts and the archive.
struct MemorySnapshot: Sendable {
    var records: [PhotoRecord] = []
    /// Record blobs that did not inflate or decode (counted, never shown as photos).
    var undecodable = 0
    /// content id -> its sources, for the photos in the window.
    var sources: [String: [MemorySource]] = [:]
    var meta: [String: String] = [:]
    var stats = MemoryTierStats()
    var cameras: [CameraMemory] = []
    /// Display camera name -> its archive buckets.
    var archive: [String: [ArchiveBucket]] = [:]
    var loadedAt = Date.now

    static let defaultWindow = 500

    var currentAnalyzerKey: String? { meta["current_analyzer_key"].flatMap { $0.isEmpty ? nil : $0 } }
    var window: Int { meta["window"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultWindow }
    var detailBudgetBytes: Int64? { meta["detail_budget_bytes"].flatMap { Int64($0) } }

    /// content id -> PhotoKit localIdentifier, for rebuilding previews.
    var photoKitLocators: [String: String] {
        sources.compactMapValues { list in list.first { $0.kind == .photokit }?.locator }
    }

    func archiveSummary(camera: String, currentKey: String?) -> ArchiveSummary? {
        ArchiveSummary.make(archive[camera] ?? [], currentKey: currentKey)
    }
}

/// Reads the memory (spec §7). Pure decoding is static so the tests can pin it; every read opens and closes.
struct MemoryStore: Sendable {
    let database: MemoryDatabase
    let previews: PreviewFiles
    /// File sources inside staging are never a photo's path: staging is deleted after each batch.
    var staging: URL?

    // MARK: Decoding

    /// Inflates a raw-DEFLATE blob (RFC 1951, no zlib header), which is what Apple's `.zlib` reads.
    static func inflate(_ z: Data) throws -> Data {
        try (z as NSData).decompressed(using: .zlib) as Data
    }

    static func hex(_ d: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(d.count * 2)
        for b in d { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }

    static func data(hex: String) -> Data? {
        guard hex.utf8.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.utf8.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// One record blob as a PhotoRecord, with the content id and analyzer key from its asset row.
    static func decodeRecord(_ z: Data, sha: Data, analyzerKey: String, decoder: JSONDecoder = PhotoRecord.makeDecoder()) throws -> PhotoRecord {
        var p = try decoder.decode(PhotoRecord.self, from: inflate(z))
        p.sha256 = hex(sha)
        p.analyzerKey = analyzerKey
        p.memoryTier = "record"
        p.path = nil
        return p
    }

    /// The path a remembered photo is shown from: a real file of a `file` source that still exists (outside staging),
    /// newest verified first; otherwise the preview, present or not (a missing one is rebuilt or shown as not kept).
    static func path(sha: String, sources: [MemorySource], previews: PreviewFiles, staging: URL?,
                     fileExists: (String) -> Bool) -> String {
        let real = sources.filter { s in
            s.kind == .file && !(staging.map { Staging.isInside(URL(fileURLWithPath: s.locator), $0) } ?? false) && fileExists(s.locator)
        }
        .sorted { ($0.verifiedAt ?? 0) > ($1.verifiedAt ?? 0) }
        return real.first?.locator ?? previews.path(sha)
    }

    /// A captured_ts (the EXIF wall clock read as UTC) as the same wall-clock time here, as PhotoRecord.date reads EXIF.
    static func captureDate(_ ts: Double) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: ts))
        return Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: ts)
    }

    static func cameraName(_ ledger: String) -> String { ledger.isEmpty ? PhotoRecord.unknownCamera : ledger }

    // MARK: Reading

    /// The newest `window` measured records per camera (undated ones by first_seen, after the dated), as the window
    /// in the database may briefly exceed it before the analyzer compacts. The order is iqa/memory.py's `_NEWEST_FIRST`,
    /// tie-break on the row id included, so the app's window is exactly the one the analyzer keeps and exports.
    static let windowSQL = """
        SELECT sha256, analyzer_key, z FROM (
            SELECT a.sha256 AS sha256, a.analyzer_key AS analyzer_key, r.z AS z,
                   ROW_NUMBER() OVER (PARTITION BY a.camera
                                      ORDER BY a.captured_ts IS NULL, a.captured_ts DESC, a.first_seen DESC, a.id DESC) AS rank
            FROM record r JOIN asset a ON a.id = r.asset_id
            WHERE a.status = 'measured')
        WHERE rank <= ?
        """

    func load(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> MemorySnapshot {
        var snap = MemorySnapshot()
        try database.read { c in
            try c.rows("SELECT key, value FROM meta") { r in
                if let k = r.text(0) { snap.meta[k] = r.text(1) ?? "" }
            }
            let decoder = PhotoRecord.makeDecoder()
            try c.rows(Self.windowSQL, [.int(Int64(snap.window))]) { r in
                guard let sha = r.blob(0), let z = r.blob(2) else { snap.undecodable += 1; return }
                do {
                    snap.records.append(try Self.decodeRecord(z, sha: sha, analyzerKey: r.text(1) ?? "", decoder: decoder))
                } catch {
                    snap.undecodable += 1
                }
            }
            let window = Set(snap.records.compactMap(\.sha256))
            try c.rows("""
                SELECT a.sha256, s.kind, s.locator, s.signature, s.verified_at
                FROM source s JOIN asset a ON a.id = s.asset_id
                WHERE s.asset_id IN (SELECT asset_id FROM record)
                """) { r in
                guard let sha = r.blob(0).map(Self.hex), window.contains(sha),
                      let kind = r.text(1).flatMap(MemorySource.Kind.init(rawValue:)), let loc = r.text(2) else { return }
                snap.sources[sha, default: []].append(MemorySource(kind: kind, locator: loc, signature: r.text(3), verifiedAt: r.double(4)))
            }
            snap.stats = try Self.stats(c)
            try c.rows("""
                SELECT camera, count(*), min(captured_ts), max(captured_ts) FROM asset
                WHERE status = 'measured' GROUP BY camera ORDER BY count(*) DESC, camera
                """) { r in
                let ledger = r.text(0) ?? ""
                snap.cameras.append(CameraMemory(camera: Self.cameraName(ledger), ledgerName: ledger, remembered: Int(r.int(1) ?? 0),
                                                 oldestCapture: r.double(2), newestCapture: r.double(3)))
            }
            try c.rows("SELECT camera, month, analyzer_key, n, first_ts, last_ts, z FROM archive") { r in
                let content = r.blob(6).flatMap { try? ArchiveBucketContent.decode(Self.inflate($0)) }
                let camera = Self.cameraName(r.text(0) ?? "")
                snap.archive[camera, default: []].append(ArchiveBucket(
                    camera: camera, month: r.text(1) ?? "undated", analyzerKey: r.text(2) ?? "", n: Int(r.int(3) ?? 0),
                    firstTS: r.double(4), lastTS: r.double(5), content: content))
            }
        }
        snap.stats.databaseBytes = database.bytesOnDisk
        for i in snap.records.indices {
            guard let sha = snap.records[i].sha256 else { continue }
            snap.records[i].path = Self.path(sha: sha, sources: snap.sources[sha] ?? [], previews: previews, staging: staging, fileExists: fileExists)
        }
        return snap
    }

    static func stats(_ c: MemoryConnection) throws -> MemoryTierStats {
        var s = MemoryTierStats()
        try c.rows("SELECT status, count(*) FROM asset GROUP BY status") { r in
            let n = Int(r.int(1) ?? 0)
            s.assets += n
            switch r.text(0) {
            case "measured": s.measured = n
            case "failed": s.failed = n
            case "not_capture": s.notCapture = n
            default: break
            }
        }
        s.sources = Int(try c.scalarInt("SELECT count(*) FROM source") ?? 0)
        try c.rows("SELECT count(*), coalesce(sum(length(z)), 0) FROM record") { r in
            s.records = Int(r.int(0) ?? 0); s.recordBytes = r.int(1) ?? 0
        }
        try c.rows("SELECT count(*), coalesce(sum(length(z)), 0) FROM detail") { r in
            s.details = Int(r.int(0) ?? 0); s.detailBytes = r.int(1) ?? 0
        }
        try c.rows("SELECT count(*), coalesce(sum(n), 0), coalesce(sum(length(z)), 0) FROM archive") { r in
            s.buckets = Int(r.int(0) ?? 0); s.bucketPhotos = Int(r.int(1) ?? 0); s.bucketBytes = r.int(2) ?? 0
        }
        try c.rows("SELECT min(captured_ts), max(captured_ts) FROM asset WHERE status = 'measured'") { r in
            s.oldestCapture = r.double(0); s.newestCapture = r.double(1)
        }
        return s
    }

    /// Sources of one kind with their content's status and analyzer key; all of them, or only `locators`.
    func knownSources(kind: MemorySource.Kind, locators: [String]? = nil) throws -> [String: KnownAsset] {
        guard database.exists else { return [:] }
        var out: [String: KnownAsset] = [:]
        try database.read { c in
            let attempts = try Self.attemptsColumn(c, "a.")
            let base = """
                SELECT s.locator, a.status, a.analyzer_key, s.signature, s.verified_at, \(attempts), a.sha256
                FROM source s JOIN asset a ON a.id = s.asset_id WHERE s.kind = ?
                """
            let add: (MemoryRow) -> Void = { r in
                if let loc = r.text(0), let st = r.text(1), let key = r.text(2) {
                    out[loc] = KnownAsset(status: st, analyzerKey: key, signature: r.text(3), verifiedAt: r.double(4),
                                          attempts: Int(r.int(5) ?? 0), sha256: r.blob(6).map(Self.hex))
                }
            }
            if let locators {
                for l in locators { try c.rows(base + " AND s.locator = ?", [.text(kind.rawValue), .text(l)], add) }
            } else {
                try c.rows(base, [.text(kind.rawValue)], add)
            }
        }
        return out
    }

    /// The status, analyzer key and failed attempts of these contents (64-hex ids), for those the memory knows.
    func knownContents(_ shas: [String]) throws -> [String: KnownAsset] {
        guard database.exists, !shas.isEmpty else { return [:] }
        var out: [String: KnownAsset] = [:]
        try database.read { c in
            let attempts = try Self.attemptsColumn(c, "")
            for sha in shas {
                guard let blob = Self.data(hex: sha), blob.count == 32 else { continue }
                try c.rows("SELECT status, analyzer_key, \(attempts) FROM asset WHERE sha256 = ?", [.blob(blob)]) { r in
                    if let st = r.text(0), let key = r.text(1) {
                        out[sha] = KnownAsset(status: st, analyzerKey: key, attempts: Int(r.int(2) ?? 0), sha256: sha)
                    }
                }
            }
        }
        return out
    }

    /// `<prefix>attempts`, or 0 on a pre-release file of schema version 1 made before that column: the analyzer adds
    /// it when it next opens the file, and the app reads with query_only on, so until then no failure counts as final.
    static func attemptsColumn(_ c: MemoryConnection, _ prefix: String) throws -> String {
        try c.scalarInt("SELECT count(*) FROM pragma_table_info('asset') WHERE name = 'attempts'") ?? 0 > 0 ? "\(prefix)attempts" : "0"
    }

    /// The measured content ids of a camera (its ledger name), to remove their previews when it is forgotten. Only
    /// measured rows, the ones `iqa memory forget --camera` deletes: its failed and not_capture verdicts are kept.
    func shas(ledgerCamera: String) throws -> [String] {
        guard database.exists else { return [] }
        var out: [String] = []
        try database.read { c in
            try c.rows("SELECT sha256 FROM asset WHERE camera = ? AND status = 'measured'", [.text(ledgerCamera)]) { r in
                if let b = r.blob(0) { out.append(Self.hex(b)) }
            }
        }
        return out
    }
}

extension PhotoLibrary {
    /// Photos measured with an analyzer key other than `current` (spec §7): kept and counted, never mixed silently.
    func olderMethodCount(current: String?) -> Int {
        guard let current else { return 0 }
        return photos.filter { $0.analyzerKey != nil && $0.analyzerKey != current }.count
    }

    /// "12 photos were measured with an earlier method; analyze them again to refresh."
    static func olderMethodText(_ n: Int) -> String? {
        guard n > 0 else { return nil }
        return "\(Fmt.count(n, "photo")) \(n == 1 ? "was" : "were") measured with an earlier method; analyze \(n == 1 ? "it" : "them") again to refresh."
    }
}
