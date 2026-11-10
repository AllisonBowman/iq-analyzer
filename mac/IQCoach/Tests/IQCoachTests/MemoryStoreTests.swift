import Testing
import Foundation
@testable import IQCoach

/// The memory reader (docs/MEMORY-SPEC.md §7) on temporary databases built from iqa/memory_schema.sql.
struct MemoryStoreTests {
    private func store(_ m: TestMemory, previews: URL? = nil, staging: URL? = nil) throws -> MemoryStore {
        MemoryStore(database: m.database, previews: PreviewFiles(directory: try previews ?? TestMemory.tempDir("previews")), staging: staging)
    }

    @Test func theSchemaFileIsFoundFromTheTests() throws {
        let url = TestMemory.schemaURL()
        #expect(url.path.hasSuffix("iq-analyzer/iqa/memory_schema.sql"))
        let sql = try String(contentsOf: url, encoding: .utf8)
        #expect(sql.contains("CREATE TABLE asset"))
        // The schema stamps the file with the id and version the reader checks.
        let m = try TestMemory()
        m.close()
        let (app, version) = try m.database.read { c in (try c.scalarInt("PRAGMA application_id"), try c.scalarInt("PRAGMA user_version")) }
        #expect(app == Int64(MemoryDatabase.applicationID))
        #expect(version == Int64(MemoryDatabase.schemaVersion))
    }

    // MARK: Raw DEFLATE

    /// A hand-made RFC 1951 "stored" block: 0x01 (final block, type 00), LEN and NLEN = ~LEN little-endian, the bytes.
    static func storedBlock(_ payload: Data) -> Data {
        let n = UInt16(payload.count), nn = ~n
        return Data([0x01, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(nn & 0xFF), UInt8(nn >> 8)]) + payload
    }

    @Test func inflateReadsHeaderlessRawDeflate() throws {
        let json = Data(#"{"file":"IMG_0453.JPG","camera_model":"iPhone 17 Pro Max","mtf50_p80_lwph":NaN,"iso":64}"#.utf8)
        let stored = Self.storedBlock(json)
        #expect(stored.first == 0x01, "no zlib header (0x78 ..): raw DEFLATE")
        #expect(try MemoryStore.inflate(stored) == json)
        let sha = Data(repeating: 0xAB, count: 32)
        let p = try MemoryStore.decodeRecord(stored, sha: sha, analyzerKey: "m1-r30-s0")
        #expect(p.file == "IMG_0453.JPG")
        #expect(p.mtf50P80LWPH == nil, "Python's bare NaN token decodes to nil")
        #expect(p.iso == 64)
        #expect(p.sha256 == String(repeating: "ab", count: 32))
        #expect(p.id == p.sha256)
        #expect(p.analyzerKey == "m1-r30-s0")
        #expect(p.memoryTier == "record")
    }

    @Test func appleZlibRoundTripsAndIsRawDeflate() throws {
        let json = try TestMemory.recordJSON(Fx.photo(3))
        let z = try TestMemory.deflate(json)
        #expect(z.first != 0x78, "Apple's .zlib writes no zlib header")
        #expect(try MemoryStore.inflate(z) == json)
    }

    /// Compressed (not stored) raw DEFLATE from Python's own zlib, with iqa/memory.py's settings (level 6, wbits -15):
    /// json.dumps({"file": "IMG_0453.JPG", "camera_model": "iPhone 17 Pro Max", "mtf50_p80_lwph": nan, "iso": 64.0,
    /// "edges_measured": 5}, allow_nan=True, separators=(",", ":")).
    static let pythonZlibBase64 = "DcrRCsIgFAbgV5H/WobRrPAFRoMN3+BwyLMmaA4tCqJ3b9ff98USk8DhOg1kenvsRj9A48ZZKlMuQdKu0a/lIepwVr4WNfFnL/m5WEPbxVB6byvczLNGbAXu1HdGQ8JdGmXh9qoS4OzvDw=="

    @Test func inflatesPythonsCompressedRawDeflate() throws {
        let z = try #require(Data(base64Encoded: Self.pythonZlibBase64))
        let p = try MemoryStore.decodeRecord(z, sha: Data(repeating: 1, count: 32), analyzerKey: TestMemory.key)
        #expect(p.file == "IMG_0453.JPG" && p.cameraModel == "iPhone 17 Pro Max")
        #expect(p.mtf50P80LWPH == nil && p.iso == 64 && p.edgesMeasured == 5)
    }

    // Cross-language fixture: a record blob written by iqa/memory.py's own deflate() (zlib 1.2.12, level 6, wbits -15;
    // byte-identical under Python 3.12 and 3.14), base64. It inflates to exactly
    // {"file":"IMG_0001.JPG","camera_model":"iPhone 17 Pro Max","snr_midgrey_db":NaN,"mtf50_p80_lwph":812.5}.
    static let pythonRecordBase64: String? =
        "DcpRCoQgEADQq8h8R4wLkXiBaKHwBoO7jiVohi1sEd29vt87wYfIoKEfOkJEWb9NBxV8beJiKWXH8dFg5rywkK0wJYvB7k/ZlkIpuKnwQe4DerRjBennG6RVIcX/OoNW8lU31w0="
    static let pythonRecordFile: String? = "IMG_0001.JPG"

    @Test func decodesTheRecordPythonWrote() throws {
        let b64 = try #require(Self.pythonRecordBase64)
        let z = try #require(Data(base64Encoded: b64))
        #expect(z.first.map { $0 & 0x07 } == 0x05, "a final dynamic-Huffman block (BFINAL 1, BTYPE 10): compressed, no zlib header")
        #expect(String(decoding: try MemoryStore.inflate(z), as: UTF8.self)
                == #"{"file":"IMG_0001.JPG","camera_model":"iPhone 17 Pro Max","snr_midgrey_db":NaN,"mtf50_p80_lwph":812.5}"#)
        let p = try MemoryStore.decodeRecord(z, sha: Data(repeating: 0, count: 32), analyzerKey: TestMemory.key)
        if let f = Self.pythonRecordFile { #expect(p.file == f) }
        #expect(p.cameraModel == "iPhone 17 Pro Max")
        #expect(p.snrMidgreyDB == nil, "Python's bare NaN token decodes to nil")
        #expect(p.mtf50P80LWPH == 812.5)
    }

    // MARK: Opening

    @Test func aMissingMemoryIsReportedAndNotCreated() throws {
        let dir = try TestMemory.tempDir()
        let db = MemoryDatabase(directory: dir)
        #expect(throws: MemoryDatabaseError.missing(db.url.path)) { try db.read { _ in 0 } }
        #expect(!FileManager.default.fileExists(atPath: db.url.path))
    }

    @Test func theReaderCannotWrite() throws {
        let m = try TestMemory()
        m.close()
        #expect(throws: MemoryDatabaseError.self) {
            try m.database.read { c in try c.execute("INSERT INTO meta (key, value) VALUES ('x', 'y')") }
        }
        let n = try m.database.read { c in try c.scalarInt("SELECT count(*) FROM meta WHERE key = 'x'") }
        #expect(n == 0)
    }

    @Test func aForeignSQLiteFileIsNotRead() throws {
        let m = try TestMemory()
        try m.exec("PRAGMA application_id = 12345")
        m.close()
        #expect(throws: MemoryDatabaseError.notAMemory(m.url.path)) { try m.database.read { _ in 0 } }
    }

    @Test func aNewerSchemaIsNotRead() throws {
        let m = try TestMemory()
        try m.exec("PRAGMA user_version = 2")
        m.close()
        #expect(throws: MemoryDatabaseError.newerSchema(2)) { try m.database.read { _ in 0 } }
    }

    // MARK: The window

    @Test func windowRecordsCarryTheirContentIDAndKey() throws {
        let m = try TestMemory()
        let a = try m.addPhoto(Fx.photo(1, camera: "iPhone 13") { $0.file = "IMG_0001.JPG" }, seed: "a", ts: 2_000)
        let b = try m.addPhoto(Fx.photo(2, camera: "NIKON D850") { $0.file = "IMG_0001.JPG" }, seed: "b", ts: 3_000, key: "m0-r30-s0")
        m.close()
        let snap = try store(m).load()
        #expect(snap.records.count == 2)
        #expect(snap.undecodable == 0)
        let ids = Set(snap.records.map(\.id))
        #expect(ids == [a.sha, b.sha], "two IMG_0001.JPG from different cameras no longer collide")
        #expect(snap.records.allSatisfy { PreviewFiles.isSHA($0.id) && $0.memoryTier == "record" })
        #expect(snap.records.first { $0.sha256 == b.sha }?.analyzerKey == "m0-r30-s0")
        #expect(snap.currentAnalyzerKey == TestMemory.key)
        #expect(snap.window == MemorySnapshot.defaultWindow)
    }

    @Test func theWindowIsTheNewestPerCameraWithUndatedLast() throws {
        let m = try TestMemory(window: 2)
        try m.addPhoto(Fx.photo(1, camera: "A"), seed: "a1", ts: 100)
        try m.addPhoto(Fx.photo(2, camera: "A"), seed: "a2", ts: 300)
        try m.addPhoto(Fx.photo(3, camera: "A"), seed: "a3", ts: 200)
        try m.addPhoto(Fx.photo(4, camera: "A"), seed: "a4", ts: nil, firstSeen: 9_999)
        try m.addPhoto(Fx.photo(5, camera: "B"), seed: "b1", ts: nil)
        m.close()
        let snap = try store(m).load()
        #expect(Set(snap.records.filter { $0.cameraModel == "A" }.map(\.file)) == ["p2.jpg", "p3.jpg"],
                "undated photos leave the window first")
        #expect(snap.records.filter { $0.cameraModel == "B" }.count == 1, "a rarely used camera keeps its photos")
    }

    @Test func windowTiesBreakOnTheRowIDAsTheAnalyzerDoes() throws {
        let m = try TestMemory(window: 1)
        try m.addPhoto(Fx.photo(1, camera: "A"), seed: "tie1", ts: 500)
        let later = try m.addPhoto(Fx.photo(2, camera: "A"), seed: "tie2", ts: 500)
        m.close()
        let snap = try store(m).load()
        #expect(snap.records.map(\.sha256) == [later.sha], "same capture time and first sight: iqa/memory.py keeps the later row")
    }

    @Test func onlyMeasuredRowsAreInTheWindow() throws {
        let m = try TestMemory()
        try m.addPhoto(Fx.photo(1), seed: "ok", ts: 1)
        try m.addAsset(sha: TestMemory.sha("bad"), camera: "Test Cam", ts: 2, status: "failed", record: try TestMemory.recordJSON(Fx.photo(2)))
        try m.addAsset(sha: TestMemory.sha("screen"), camera: "", ts: 3, status: "not_capture")
        m.close()
        let snap = try store(m).load()
        #expect(snap.records.map(\.file) == ["p1.jpg"])
        #expect(snap.stats.measured == 1 && snap.stats.failed == 1 && snap.stats.notCapture == 1 && snap.stats.assets == 3)
    }

    @Test func aBrokenBlobIsCountedNotShown() throws {
        let m = try TestMemory()
        try m.addPhoto(Fx.photo(1), seed: "ok", ts: 1)
        let id = try m.addAsset(sha: TestMemory.sha("broken"), camera: "Test Cam", ts: 2)
        try m.run("INSERT INTO record (asset_id, z) VALUES (?, ?)", [.int(id), .blob(Data([0xFF, 0x00, 0x13]))])
        m.close()
        let snap = try store(m).load()
        #expect(snap.records.count == 1)
        #expect(snap.undecodable == 1)
    }

    // MARK: Paths

    @Test func pathIsTheRealFileWhenItExistsElseThePreview() throws {
        let m = try TestMemory()
        let previews = try TestMemory.tempDir("previews"), staging = try TestMemory.tempDir("staging")
        let folder = try TestMemory.tempDir("folder")
        let real = folder.appendingPathComponent("DSC_0001.JPG")
        try Data("x".utf8).write(to: real)
        let staged = staging.appendingPathComponent("batch/files/0001/IMG_0453.JPG")
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: staged)

        let f = try m.addPhoto(Fx.photo(1), seed: "folder", ts: 1)
        try m.addSource(assetID: f.id, kind: "file", locator: real.path)
        try m.addSource(assetID: f.id, kind: "file", locator: "/gone/DSC_0001.JPG", verifiedAt: 5_000)
        let p = try m.addPhoto(Fx.photo(2), seed: "photokit", ts: 2)
        try m.addSource(assetID: p.id, kind: "photokit", locator: "ABC/L0/001", signature: "IMG_0453.JPG|public.jpeg|5712x4284")
        try m.addSource(assetID: p.id, kind: "file", locator: staged.path)
        m.close()

        let snap = try store(m, previews: previews, staging: staging).load()
        let folderPhoto = try #require(snap.records.first { $0.sha256 == f.sha })
        #expect(folderPhoto.path == real.path, "a folder's file stays where it is and is its own preview")
        let pk = try #require(snap.records.first { $0.sha256 == p.sha })
        #expect(pk.path == PreviewFiles(directory: previews).heic(p.sha).path, "a staged copy is never a photo's path")
        #expect(snap.photoKitLocators == [p.sha: "ABC/L0/001"])
        #expect(snap.sources[p.sha]?.contains { $0.kind == .photokit && $0.signature == "IMG_0453.JPG|public.jpeg|5712x4284" } == true)
    }

    @Test func aJPEGFallbackPreviewIsFound() throws {
        let previews = try TestMemory.tempDir("previews")
        let files = PreviewFiles(directory: previews)
        let sha = TestMemory.sha("jpeg")
        #expect(files.path(sha) == files.heic(sha).path)
        try Data("j".utf8).write(to: files.jpeg(sha))
        #expect(files.path(sha) == files.jpeg(sha).path)
    }

    // MARK: Stats, cameras, archive

    @Test func statsCountRowsAndBytes() throws {
        let m = try TestMemory()
        let a = try m.addPhoto(Fx.photo(1, camera: "A"), seed: "a", ts: 1_700_000_000)
        try m.addPhoto(Fx.photo(2, camera: "A"), seed: "b", ts: 1_600_000_000)
        try m.addPhoto(Fx.photo(3, camera: ""), seed: "c", ts: nil)
        try m.addSource(assetID: a.id, kind: "file", locator: "/x/a.jpg")
        try m.run("INSERT INTO detail (asset_id, z, bytes) VALUES (?, ?, 7)", [.int(a.id), .blob(Data(repeating: 1, count: 7))])
        try m.addBucket(camera: "A", month: "2021-03", n: 4, json: #"{"metrics": {}, "shares": {}}"#)
        m.close()
        let snap = try store(m).load()
        let s = snap.stats
        #expect(s.assets == 3 && s.measured == 3)
        #expect(s.sources == 1)
        #expect(s.records == 3 && s.recordBytes > 0)
        #expect(s.details == 1 && s.detailBytes == 7)
        #expect(s.buckets == 1 && s.bucketPhotos == 4 && s.bucketBytes > 0)
        #expect(s.oldestCapture == 1_600_000_000 && s.newestCapture == 1_700_000_000)
        #expect(s.databaseBytes > 0)
        let cams = Dictionary(uniqueKeysWithValues: snap.cameras.map { ($0.camera, $0) })
        #expect(cams["A"]?.remembered == 2 && cams["A"]?.newestCapture == 1_700_000_000)
        #expect(cams[PhotoRecord.unknownCamera]?.ledgerName == "", "the ledger's '' is the app's Unknown camera")
    }

    @Test func archiveBucketsAreReadPerCamera() throws {
        let m = try TestMemory()
        try m.addBucket(camera: "iPhone 13", month: "2021-03", n: 3,
                        json: #"{"metrics": {"sharpness_lwph": {"counts": {"140": 3}, "zero": 0, "under": 0, "over": 0, "n": 3}}, "shares": {"clip_high_gt1": [1, 3]}}"#)
        try m.addBucket(camera: "iPhone 13", month: "2021-04", key: "m0-r30-s0", n: 5, json: #"{"metrics": {}, "shares": {}}"#)
        m.close()
        let snap = try store(m).load()
        let buckets = try #require(snap.archive["iPhone 13"])
        #expect(buckets.count == 2 && buckets.allSatisfy { $0.content != nil })
        let summary = try #require(snap.archiveSummary(camera: "iPhone 13", currentKey: snap.currentAnalyzerKey))
        #expect(summary.photos == 3)
        #expect(summary.leftOutPhotos == 5 && summary.leftOutBuckets == 1)
        #expect(summary.blownShare == ShareCount(hits: 1, of: 3))
    }

    // MARK: Lookups for the import decisions

    @Test func knownSourcesAndContents() throws {
        let m = try TestMemory()
        let a = try m.addPhoto(Fx.photo(1), seed: "a", ts: 1)
        try m.addSource(assetID: a.id, kind: "photokit", locator: "PK1", signature: "IMG_1.JPG|public.jpeg|4032x3024")
        try m.addSource(assetID: a.id, kind: "picker", locator: "PK1")
        let n = try m.addAsset(sha: TestMemory.sha("n"), camera: "", ts: nil, status: "not_capture")
        try m.addSource(assetID: n, kind: "photokit", locator: "PK2", signature: "s")
        let f = try m.addAsset(sha: TestMemory.sha("f"), camera: "Test Cam", ts: nil, status: "failed", attempts: 1)
        try m.addSource(assetID: f, kind: "photokit", locator: "PK3", signature: "f")
        try m.addAsset(sha: TestMemory.sha("f0"), camera: "", ts: nil, status: "failed", attempts: 2)
        m.close()
        let s = try store(m)
        let pk = try s.knownSources(kind: .photokit)
        #expect(pk["PK1"] == KnownAsset(status: "measured", analyzerKey: TestMemory.key, signature: "IMG_1.JPG|public.jpeg|4032x3024",
                                        verifiedAt: 1_000, attempts: 0, sha256: a.sha),
                "with the content behind it, so the picker can tell whether its preview exists")
        #expect(pk["PK2"]?.status == "not_capture")
        #expect(pk["PK3"]?.attempts == 1 && pk["PK3"]?.isFinalFailure == false, "a first failure is not final")
        #expect(try s.knownSources(kind: .picker, locators: ["PK1", "nope"]).keys.sorted() == ["PK1"])
        let c = try s.knownContents([a.sha, TestMemory.sha("unknown"), TestMemory.sha("f0")])
        #expect(c.keys.sorted() == [a.sha, TestMemory.sha("f0")].sorted())
        #expect(c[a.sha]?.status == "measured" && c[a.sha]?.sha256 == a.sha)
        #expect(c[TestMemory.sha("f0")]?.attempts == 2 && c[TestMemory.sha("f0")]?.isFinalFailure == true)
        // Forgetting a camera removes its measured photos only, as iqa memory forget --camera does: its failed and
        // not_capture verdicts survive, so their previews (none) and their skips stay.
        #expect(try s.shas(ledgerCamera: "Test Cam") == [a.sha])
        #expect(try s.shas(ledgerCamera: "").isEmpty, "the unknown camera's failures and non-captures are not forgotten with it")
    }

    @Test func aPreReleaseFileWithoutAttemptsStillAnswersTheLookups() throws {
        // Schema version 1 made before the attempts column: the app cannot add it (query_only), so it reads 0 and
        // newest-N and Choose Photos keep working until the analyzer next opens the file and adds the column.
        let m = try TestMemory()
        let f = try m.addAsset(sha: TestMemory.sha("f"), camera: "", ts: nil, status: "failed", attempts: 2)
        try m.addSource(assetID: f, kind: "photokit", locator: "PK1", signature: "s")
        try m.exec("ALTER TABLE asset DROP COLUMN attempts")
        m.close()
        let s = try store(m)
        let pk = try s.knownSources(kind: .photokit)
        #expect(pk["PK1"]?.status == "failed" && pk["PK1"]?.attempts == 0 && pk["PK1"]?.isFinalFailure == false)
        #expect(try s.knownContents([TestMemory.sha("f")])[TestMemory.sha("f")]?.attempts == 0)
    }

    @Test func lookupsOnAMissingMemoryAreEmpty() throws {
        let s = MemoryStore(database: MemoryDatabase(directory: try TestMemory.tempDir()), previews: PreviewFiles(directory: try TestMemory.tempDir()))
        #expect(try s.knownSources(kind: .photokit).isEmpty)
        #expect(try s.knownContents([TestMemory.sha("x")]).isEmpty)
    }

    // MARK: Older methods

    @Test func photosMeasuredWithAnEarlierMethodAreCounted() throws {
        let m = try TestMemory()
        for i in 0..<3 { try m.addPhoto(Fx.photo(i), seed: "new\(i)", ts: Double(i)) }
        for i in 3..<5 { try m.addPhoto(Fx.photo(i), seed: "old\(i)", ts: Double(i), key: "m0-r30-s0") }
        m.close()
        let snap = try store(m).load()
        let lib = PhotoLibrary(sourceName: AppModel.memorySourceName, photos: snap.records)
        #expect(lib.olderMethodCount(current: snap.currentAnalyzerKey) == 2)
        #expect(lib.olderMethodCount(current: nil) == 0)
        #expect(PhotoLibrary.olderMethodText(2) == "2 photos were measured with an earlier method; analyze them again to refresh.")
        #expect(PhotoLibrary.olderMethodText(1) == "1 photo was measured with an earlier method; analyze it again to refresh.")
        #expect(PhotoLibrary.olderMethodText(0) == nil)
        // A results.json row without a key (file mode) is not "older".
        #expect(PhotoLibrary(sourceName: "results.json", photos: [Fx.photo()]).olderMethodCount(current: TestMemory.key) == 0)
    }

    @Test func photoRecordDecodesTheMemoryFields() throws {
        let sha = String(repeating: "C", count: 64)
        let json = #"[{"file":"a.jpg","sha256":"\#(sha)","analyzer_key":"m1-r30-s0","memory_tier":"ledger"},{"file":"b.jpg","path":"/x/b.jpg"}]"#
        let rows = try PhotoRecord.decodeAll(from: Data(json.utf8))
        #expect(rows[0].sha256 == sha.lowercased() && rows[0].id == sha.lowercased())
        #expect(rows[0].analyzerKey == "m1-r30-s0" && rows[0].memoryTier == "ledger")
        #expect(rows[1].sha256 == nil && rows[1].id == "/x/b.jpg", "without a content id, the id is the path, as before")
    }

    @Test func repeatedContentsInAResultsFileKeepTheirOwnIDs() throws {
        // A --memory run over a folder with byte-identical copies writes one row per copy, with one sha256.
        let sha = String(repeating: "d", count: 64)
        let json = #"""
            [{"file":"a.jpg","path":"/f/a.jpg","sha256":"\#(sha)"},{"file":"a copy.jpg","path":"/f/a copy.jpg","sha256":"\#(sha)"},
             {"file":"x.jpg","sha256":"\#(sha)"},{"file":"n.jpg"},{"file":"n.jpg"}]
            """#
        let rows = try PhotoRecord.decodeAll(from: Data(json.utf8))
        #expect(rows[0].id == sha, "the first copy keeps the content id")
        #expect(Set(rows.map(\.id)).count == rows.count, "no two rows share an identity")
        #expect(rows[1].id.hasPrefix(sha) && rows[1].id.contains("/f/a copy.jpg"))
        #expect(rows[3].id == "n.jpg" && rows[4].id != "n.jpg", "--no-paths copies with one name are told apart by their index")
        #expect(rows.allSatisfy { $0.sha256 == nil || $0.sha256 == sha }, "the content id itself is unchanged")
    }

    // MARK: Real memory (TEST_RUNNER_IQA_MEMORY)

    /// What iqa/memory.py reads from the same file (written by a script beside the real memory): the window's content
    /// ids and, per display camera, the merged archive of the current analyzer key.
    private struct PythonView: Decodable {
        struct Camera: Decodable {
            let photos: Int
            let buckets: Int
            /// metric -> quantile ("0.5") -> Bucket.quantile, null when the metric has no values.
            let quantiles: [String: [String: Double?]]
            let shares: [String: [Int]]
        }
        let window: [String]
        let archive: [String: Camera]
    }

    /// The real memory, when the test run is given one (xcodebuild passes TEST_RUNNER_IQA_MEMORY as IQA_MEMORY), and,
    /// with TEST_RUNNER_IQA_MEMORY_EXPECT, Python's reading of it to agree with.
    @Test func realMemoryDecodesEveryRecord() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["IQA_MEMORY"], !path.isEmpty else { return }
        let s = MemoryStore(database: MemoryDatabase(url: URL(fileURLWithPath: path)), previews: PreviewFiles(directory: try TestMemory.tempDir("previews")))
        let snap = try s.load()
        #expect(snap.undecodable == 0)
        #expect(snap.records.count + snap.undecodable <= snap.stats.records)
        #expect(snap.records.allSatisfy { PreviewFiles.isSHA($0.id) && $0.analyzerKey?.isEmpty == false })
        #expect(Set(snap.records.map(\.id)).count == snap.records.count)
        // The import lookups read the analyzer's attempts column: every window photo is a measured content.
        let shas = snap.records.compactMap(\.sha256)
        let known = try s.knownContents(shas)
        #expect(shas.allSatisfy { known[$0]?.status == "measured" && known[$0]?.attempts == 0 })
        _ = try s.knownSources(kind: .file)
        for (camera, buckets) in snap.archive {
            for b in buckets {
                let content = try #require(b.content, "\(camera) \(b.month): the bucket inflates and decodes")
                for (metric, h) in content.metrics { #expect(h.n <= b.n, "\(camera) \(b.month) \(metric)") }
            }
        }

        guard let expectPath = env["IQA_MEMORY_EXPECT"], !expectPath.isEmpty else { return }
        let python = try JSONDecoder().decode(PythonView.self, from: Data(contentsOf: URL(fileURLWithPath: expectPath)))
        #expect(Set(snap.records.compactMap(\.sha256)) == Set(python.window), "the app's window is the analyzer's")
        #expect(snap.records.count == python.window.count)
        for (camera, x) in python.archive {
            let summary = try #require(snap.archiveSummary(camera: camera, currentKey: snap.currentAnalyzerKey), "\(camera)")
            #expect(summary.photos == x.photos && summary.buckets == x.buckets, "\(camera)")
            for (metric, qs) in x.quantiles {
                for (qText, want) in qs {
                    let q = try #require(Double(qText))
                    let got: Double? = switch summary.quantile(metric, q) {
                    case .value(let v)?, .below(let v)?, .above(let v)?: v
                    case nil: nil
                    }
                    let same = switch (got, want) {
                    case (let g?, let w?): abs(g - w) <= 1e-9 * max(1, abs(w))
                    case (nil, nil): true
                    default: false
                    }
                    #expect(same, "\(camera) \(metric) q\(qText): Swift \(String(describing: got)), Python \(String(describing: want))")
                }
            }
            for (name, pair) in x.shares where pair.count == 2 {
                #expect(summary.content.shares[name] == ShareCount(hits: pair[0], of: pair[1]), "\(camera) \(name)")
            }
        }
    }
}
