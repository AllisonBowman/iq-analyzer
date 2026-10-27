import Testing
import Foundation
@testable import IQCoach

/// The import flows' pure parts (docs/MEMORY-SPEC.md §6, §7): the skip rule, the sources manifest, the IQA-MEMORY
/// lines, staging's path safety and the earlier-copies clean-up. Files are only made and deleted in temporary folders.
struct ImportFlowTests {
    private let key = "m1-r30-s0"
    private let sig = "IMG_0453.JPG|public.jpeg|5712x4284"

    @Test func theTestHostLeavesTheRealFoldersAlone() {
        // The window's launch() sweeps staging and trims previews in ~/Library; the test host's window must skip it.
        #expect(AppModel.isTestHost)
    }

    // MARK: The skip rule

    @Test func aKnownCurrentAssetWithTheSameSignatureIsSkipped() {
        let k = KnownAsset(status: "measured", analyzerKey: key, signature: sig)
        #expect(PhotosImporter.decide(known: k, signature: sig, currentKey: key) == .skipKnown)
        #expect(PhotosImporter.decide(known: KnownAsset(status: "failed", analyzerKey: key, signature: sig, attempts: 2), signature: sig, currentKey: key) == .skipKnown,
                "a second failure is final: the analyzer would not retry it, so it is not downloaded either")
        #expect(PhotosImporter.decide(known: KnownAsset(status: "failed", analyzerKey: key, signature: sig, attempts: 1), signature: sig, currentKey: key) == .download,
                "a first failure may have been a passing problem: the analyzer tries it once more")
        #expect(PhotosImporter.decide(known: KnownAsset(status: "failed", analyzerKey: "m0-r30-s0", signature: sig, attempts: 5), signature: sig, currentKey: key) == .download,
                "failures with an earlier key count for nothing")
    }

    @Test func theOriginalsOwnPixelSizeIsUsed() {
        // A crop makes PHAsset's size the render's: 5712 x 4284 cropped to 2400 x 1800 fell under the 5 MP gate.
        let s = PhotosImporter.originalSize(resource: (5712, 4284), asset: (2400, 1800))
        #expect(s.width == 5712 && s.height == 4284)
        let fallback = PhotosImporter.originalSize(resource: (0, 0), asset: (4032, 3024))
        #expect(fallback.width == 4032 && fallback.height == 3024, "a resource that reports no size falls back to the asset's")
        #expect(PhotosImporter.originalSize(resource: (4032, 0), asset: (4032, 3024)).height == 3024)
    }

    @Test func anythingUnverifiableIsDownloaded() {
        let k = KnownAsset(status: "measured", analyzerKey: key, signature: sig)
        #expect(PhotosImporter.decide(known: nil, signature: sig, currentKey: key) == .download, "unknown")
        #expect(PhotosImporter.decide(known: k, signature: "IMG_0453.JPG|public.heic|5712x4284", currentKey: key) == .download, "changed signature")
        #expect(PhotosImporter.decide(known: KnownAsset(status: "measured", analyzerKey: "m0-r30-s0", signature: sig), signature: sig, currentKey: key) == .download, "older key")
        #expect(PhotosImporter.decide(known: k, signature: sig, currentKey: nil) == .download, "no current key to compare with")
        #expect(PhotosImporter.decide(known: KnownAsset(status: "measured", analyzerKey: key, signature: nil), signature: sig, currentKey: key) == .download, "no stored signature")
        #expect(PhotosImporter.decide(known: k, signature: nil, currentKey: key) == .download)
    }

    @Test func aRememberedNonCaptureIsSkippedWithoutCounting() {
        let k = KnownAsset(status: "not_capture", analyzerKey: "m0-r30-s0", signature: sig)
        #expect(PhotosImporter.decide(known: k, signature: sig, currentKey: key) == .skipNotCapture)
        #expect(PhotosImporter.decide(known: k, signature: "other|public.png|10x10", currentKey: key) == .download)
    }

    @Test func pickerItemsAreCurrentOnlyWithTheCurrentKey() {
        #expect(PhotosImporter.isCurrent(KnownAsset(status: "measured", analyzerKey: key), currentKey: key))
        #expect(PhotosImporter.isCurrent(KnownAsset(status: "not_capture", analyzerKey: key), currentKey: key))
        #expect(!PhotosImporter.isCurrent(KnownAsset(status: "measured", analyzerKey: "m0-r30-s0"), currentKey: key))
        #expect(!PhotosImporter.isCurrent(nil, currentKey: key))
        #expect(!PhotosImporter.isCurrent(KnownAsset(status: "measured", analyzerKey: key), currentKey: nil))
    }

    @Test func aPickedLibraryPhotoFollowsNewestNsRuleUnlessItsPreviewIsMissing() {
        let content = TestMemory.sha("picked")
        let k = KnownAsset(status: "measured", analyzerKey: key, signature: sig, sha256: content)
        let has = { (s: String) in s == content }, none = { (_: String) in false }
        #expect(PhotosImporter.decidePickedAsset(known: k, signature: sig, currentKey: key, hasPreview: has) == .skipKnown)
        #expect(PhotosImporter.decidePickedAsset(known: k, signature: sig, currentKey: key, hasPreview: none) == .download,
                "choosing a photo whose preview is gone downloads it, so the preview comes back")
        #expect(PhotosImporter.decidePickedAsset(known: nil, signature: sig, currentKey: key, hasPreview: has) == .download)
        #expect(PhotosImporter.decidePickedAsset(known: k, signature: "IMG_0453.JPG|public.jpeg|4000x3000", currentKey: key, hasPreview: has) == .download)
        let failed = KnownAsset(status: "failed", analyzerKey: key, signature: sig, attempts: 2, sha256: content)
        #expect(PhotosImporter.decidePickedAsset(known: failed, signature: sig, currentKey: key, hasPreview: none) == .skipKnown,
                "a final failure has no preview to bring back")
        let screen = KnownAsset(status: "not_capture", analyzerKey: key, signature: sig, sha256: content)
        #expect(PhotosImporter.decidePickedAsset(known: screen, signature: sig, currentKey: key, hasPreview: none) == .skipNotCapture)
    }

    @Test func pickedBytesAreLinkedOnlyWhenACopyGainsNothing() {
        let measured = KnownAsset(status: "measured", analyzerKey: key)
        #expect(PhotosImporter.pickedBytes(known: measured, currentKey: key, hasPreview: true) == .link)
        #expect(PhotosImporter.pickedBytes(known: measured, currentKey: key, hasPreview: false) == .stage,
                "staged so the analyzer reports a hit and the preview is made from the copy")
        #expect(PhotosImporter.pickedBytes(known: nil, currentKey: key, hasPreview: true) == .stage)
        #expect(PhotosImporter.pickedBytes(known: KnownAsset(status: "measured", analyzerKey: "m0-r30-s0"), currentKey: key, hasPreview: true) == .stage)
        #expect(PhotosImporter.pickedBytes(known: measured, currentKey: nil, hasPreview: true) == .stage)
        #expect(PhotosImporter.pickedBytes(known: KnownAsset(status: "not_capture", analyzerKey: key), currentKey: key, hasPreview: false) == .link)
        #expect(PhotosImporter.pickedBytes(known: KnownAsset(status: "failed", analyzerKey: key, attempts: 2), currentKey: key, hasPreview: false) == .link)
        #expect(PhotosImporter.pickedBytes(known: KnownAsset(status: "failed", analyzerKey: key, attempts: 1), currentKey: key, hasPreview: false) == .stage,
                "a first failure is tried once more")
    }

    @Test func pickedBytesAreNamedByWhatTheyAre() {
        func bytes(_ b: [UInt8]) -> Data { Data(b + [UInt8](repeating: 0, count: 16)) }
        let ftyp = { (brand: String) in Data([0, 0, 0, 0x18] + Array("ftyp".utf8) + Array(brand.utf8) + [0, 0, 0, 0]) }
        // An edited ProRAW is delivered as a HEIC or JPEG render: it must not be named .dng, or LibRaw rejects it.
        #expect(PhotosImporter.fileExtension(of: bytes([0xFF, 0xD8, 0xFF, 0xE1]), declared: "dng") == "jpg")
        for brand in ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"] {
            #expect(PhotosImporter.fileExtension(of: ftyp(brand), declared: "dng") == "heic", "\(brand)")
        }
        #expect(PhotosImporter.fileExtension(of: ftyp("crx "), declared: "cr3") == "cr3", "another ISO-BMFF brand keeps its declared type")
        #expect(PhotosImporter.fileExtension(of: bytes([0x49, 0x49, 0x2A, 0x00]), declared: "dng") == "dng", "TIFF bytes of a DNG stay a DNG")
        #expect(PhotosImporter.fileExtension(of: bytes([0x4D, 0x4D, 0x00, 0x2A]), declared: "jpeg") == "tiff")
        #expect(PhotosImporter.fileExtension(of: bytes([0x49, 0x49, 0x2A, 0x00]), declared: nil) == "tiff")
        #expect(PhotosImporter.fileExtension(of: bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), declared: "heic") == "png")
        #expect(PhotosImporter.fileExtension(of: Data("RIFF....WEBP".utf8), declared: "webp") == "webp")
        #expect(PhotosImporter.fileExtension(of: Data([0x00]), declared: nil) == "jpg")
    }

    @Test func onlyFormatsTheAnalyzerReadsAreStaged() {
        for n in ["IMG_0001.HEIC", "IMG_0001.JPG", "DSC_0001.NEF", "a.dng", "b.png", "c.jpeg"] { #expect(PhotosImporter.analyzerReads(n), "\(n)") }
        for n in ["IMG_0001.AVIF", "clip.mov", "noext", "a.jxl"] { #expect(!PhotosImporter.analyzerReads(n), "\(n)") }
    }

    @Test func earlierCopiesGetTheirOriginalNamesBack() {
        let sha = "0123abcd" + String(repeating: "0", count: 56)
        #expect(EarlierCopies.originalName("007-IMG_0448.JPG", sha256: sha) == "IMG_0448.JPG")
        #expect(EarlierCopies.originalName("002-photo.jpeg", sha256: sha) == "photo-0123abcd.jpeg")
        #expect(EarlierCopies.originalName("IMG_0448.JPG", sha256: sha) == "IMG_0448.JPG")
        #expect(EarlierCopies.originalName("12-IMG_1.JPG", sha256: sha) == "12-IMG_1.JPG", "only the app's three-digit prefix")
    }

    @Test func earlierCopiesAreStagedOncePerContentAsClones() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("iqc-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("photos/20261015T040500")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let a = src.appendingPathComponent("001-IMG_0001.JPG"), b = src.appendingPathComponent("002-IMG_0001.JPG")
        let c = src.appendingPathComponent("003-clip.mov")
        try Data("one".utf8).write(to: a); try Data("one".utf8).write(to: b); try Data("two".utf8).write(to: c)
        let files = try [a, b, c].map { StagedFile(url: $0, sha256: try ContentHash.sha256(of: $0)) }
        let batch = try Staging(root: tmp.appendingPathComponent("staging")).newBatch()
        let staged = try EarlierCopies.stage(files, into: batch)
        #expect(staged.count == 1, "one per content, and no unreadable format")
        #expect(staged[0].url.lastPathComponent == "IMG_0001.JPG" && staged[0].sha256 == files[0].sha256)
        #expect(Staging.isInside(staged[0].url, batch.files))
        #expect(try ContentHash.sha256(of: staged[0].url) == files[0].sha256)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path), "the copies themselves stay")
        let line = String(decoding: try ManifestLine.encode(staged.map { .staged($0.url, sha256: $0.sha256, kind: .file, locator: nil) }), as: UTF8.self)
        #expect(line == #"{"kind":"file","path":"\#(staged[0].url.path)","sha256":"\#(files[0].sha256)"}"# + "\n", "no locator: no source in the ledger")
    }

    @Test func signatureAndFileNames() {
        #expect(PhotosImporter.signature(filename: "IMG_0453.JPG", uti: "public.jpeg", width: 5712, height: 4284) == sig)
        #expect(PhotosImporter.safeFileName("IMG_0453.JPG") == "IMG_0453.JPG")
        #expect(PhotosImporter.safeFileName("a/b:c.jpg") == "a_b_c.jpg")
        #expect(PhotosImporter.safeFileName("..") == "photo")
        #expect(PhotosImporter.safeFileName("") == "photo")
    }

    // MARK: The sources manifest

    @Test func manifestLinesAreTheSpecsJSONLines() throws {
        let staged = String(repeating: "b", count: 64)
        let lines: [ManifestLine] = [
            .staged(URL(fileURLWithPath: "/s/files/0001/IMG_0453.JPG"), sha256: staged, kind: .photokit, locator: "ABC/L0/001", signature: sig),
            .notCapture(URL(fileURLWithPath: "/s/other/0002/IMG_0460.PNG"), kind: .photokit, locator: "DEF/L0/001", signature: "IMG_0460.PNG|public.png|1170x2532", reason: "no EXIF camera model"),
            .link(sha256: String(repeating: "a", count: 64), kind: .picker, locator: "GHI/L0/001"),
        ]
        let text = String(decoding: try ManifestLine.encode(lines), as: UTF8.self)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(rows.count == 4 && rows.last == "", "one object per line, newline-terminated")
        #expect(rows[0] == #"{"kind":"photokit","locator":"ABC/L0/001","path":"/s/files/0001/IMG_0453.JPG","sha256":"\#(staged)","signature":"IMG_0453.JPG|public.jpeg|5712x4284"}"#,
                "a staged file carries the app's hash, which the analyzer checks before measuring")
        #expect(String(decoding: try ManifestLine.encode([.staged(URL(fileURLWithPath: "/s/files/0002/photo-0123abcd.heic"), sha256: staged, kind: .picker, locator: nil)]), as: UTF8.self)
                == #"{"kind":"picker","path":"/s/files/0002/photo-0123abcd.heic","sha256":"\#(staged)"}"# + "\n", "picker bytes carry no signature")
        #expect(rows[1] == #"{"kind":"photokit","locator":"DEF/L0/001","path":"/s/other/0002/IMG_0460.PNG","reason":"no EXIF camera model","signature":"IMG_0460.PNG|public.png|1170x2532","status":"not_capture"}"#)
        #expect(rows[2] == #"{"kind":"picker","locator":"GHI/L0/001","sha256":"\#(String(repeating: "a", count: 64))"}"#)
        let back = try rows.prefix(3).map { try JSONDecoder().decode(ManifestLine.self, from: Data($0.utf8)) }
        #expect(back == lines)
    }

    // MARK: IQA-MEMORY lines

    @Test func memoryLinesParse() throws {
        let sha = String(repeating: "0123456789abcdef", count: 4)
        let p = try #require(BatchOutcome.parse("IQA-MEMORY hit \(sha) IMG_0453.JPG"))
        #expect(p.kind == .hit && p.sha256 == sha && p.file == "IMG_0453.JPG")
        #expect(BatchOutcome.parse("IQA-MEMORY miss \(sha.uppercased()) My Photo 1.jpg")?.sha256 == sha)
        #expect(BatchOutcome.parse("IQA-MEMORY miss \(sha) My Photo 1.jpg")?.file == "My Photo 1.jpg")
        #expect(BatchOutcome.parse("IQA-MEMORY stale \(sha)")?.file == "")
        for k in BatchOutcome.Kind.allCases { #expect(BatchOutcome.parse("IQA-MEMORY \(k.rawValue) \(sha) a.jpg")?.kind == k) }
        #expect(BatchOutcome.parse("IQA-MEMORY maybe \(sha) a.jpg") == nil)
        #expect(BatchOutcome.parse("IQA-MEMORY hit abc123 a.jpg") == nil)
        #expect(BatchOutcome.parse("[3/40] IMG_0453.JPG") == nil)
        #expect(BatchOutcome.parse("iqa-memory hit \(sha) a.jpg") == nil)
    }

    @Test func outcomeCountsAndSummary() {
        var o = BatchOutcome()
        let sha = { (i: Int) in TestMemory.sha("o\(i)") }
        for i in 0..<30 { o.record("IQA-MEMORY hit \(sha(i)) a.jpg") }
        for i in 30..<35 { o.record("IQA-MEMORY miss \(sha(i)) b.jpg") }
        let counted = o.record("[1/40] exporting IMG_0001.JPG")
        #expect(!counted)
        o.skippedBeforeImport = 5
        #expect(o.count(.hit) == 30 && o.count(.miss) == 5)
        #expect(o.measured.count == 5)
        #expect(o.remembered.count == 35)
        #expect(o.summary == "Remembered: 35 already measured, 5 new")
        o.record("IQA-MEMORY stale \(sha(40)) c.jpg")
        o.record("IQA-MEMORY failed \(sha(41)) d.jpg")
        o.record("IQA-MEMORY skip \(sha(42)) IMG_0460.PNG")
        #expect(o.measured.contains(sha(40)) && !o.measured.contains(sha(41)) && !o.remembered.contains(sha(42)))
        #expect(o.summary == "Remembered: 35 already measured, 5 new, 1 measured again with the current method, 1 not measured (not a camera capture, or failed before), 1 photo could not be measured")
    }

    // MARK: Analyzer invocation

    @Test func validationGivesTheAnalyzerKey() throws {
        let c = try #require(AnalyzerRunner.parseCheck("Warning: something\n/Users/a/iq-analyzer/iqa/__init__.py\nm1-r30-s0\n"))
        #expect(c.analyzerKey == "m1-r30-s0")
        #expect(c.sentence == "Python works and iqa imports from /Users/a/iq-analyzer/iqa/__init__.py.")
        #expect(AnalyzerRunner.parseCheck("/x/iqa/__init__.py\n") == nil)
        #expect(AnalyzerRunner.parseCheck("Traceback\nModuleNotFoundError: No module named 'iqa.memory'") == nil)
    }

    @Test func onlyACleanExitOrAnAllFailedRunIsFinished() throws {
        var failed = BatchOutcome()
        failed.record("IQA-MEMORY failed \(TestMemory.sha("f")) a.jpg")
        let empty = BatchOutcome()
        #expect(try AnalyzerRunner.finished(status: 0, output: "", outcome: empty) == empty, "an empty list is a finished run")
        #expect(try AnalyzerRunner.finished(status: 4, output: "", outcome: failed).count(.failed) == 1, "every photo failed: finished, and said")
        #expect(throws: AnalyzerError.self) { try AnalyzerRunner.finished(status: 4, output: "", outcome: empty) }
        #expect(throws: AnalyzerError.self, "a traceback after a failed photo is a crash, not a finished run") {
            try AnalyzerRunner.finished(status: 1, output: "Traceback\nFileNotFoundError: x", outcome: failed)
        }
        for code: Int32 in [2, 3] {
            #expect(throws: AnalyzerError.self) { try AnalyzerRunner.finished(status: code, output: "", outcome: failed) }
        }
        do {
            _ = try AnalyzerRunner.finished(status: 5, output: "iqa: the measurement libraries cannot be imported: ModuleNotFoundError('cv2')", outcome: empty)
            Issue.record("exit 5 must throw")
        } catch let e as AnalyzerError {
            guard case .measurementLibrariesMissing(let m) = e else { Issue.record("\(e)"); return }
            #expect(m.contains("cv2"))
            #expect(e.localizedDescription.contains("cannot import the measurement libraries"))
        }
    }

    /// A stand-in interpreter: prints `lines` and exits with `code`, whatever its arguments.
    private func fakePython(_ lines: [String], exit code: Int32) throws -> AnalyzerRunner {
        let dir = try TestMemory.tempDir("fakepy")
        let exe = dir.appendingPathComponent("python")
        let body = lines.map { "echo '\($0)'" }.joined(separator: "\n")
        try Data("#!/bin/sh\n\(body)\nexit \(code)\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return AnalyzerRunner(python: exe.path, repo: dir.path)
    }

    @Test func theRunnerReadsTheAnalyzersExitCode() async throws {
        let dir = try TestMemory.tempDir("run")
        let out = dir.appendingPathComponent("out"), db = dir.appendingPathComponent("memory.sqlite")
        let sha = TestMemory.sha("bad")
        let allFailed = try fakePython(["IQA-MEMORY failed \(sha) a.jpg", "memory: 0 measured, 1 failed"], exit: 4)
        let o = try await allFailed.analyze(paths: [dir], out: out, memory: db, sources: nil, onLine: { _ in })
        #expect(o.count(.failed) == 1 && o.kinds[sha] == .failed)
        let crashed = try fakePython(["IQA-MEMORY failed \(sha) a.jpg", "Traceback (most recent call last):"], exit: 1)
        await #expect(throws: AnalyzerError.self) { _ = try await crashed.analyze(paths: [dir], out: out, memory: db, sources: nil, onLine: { _ in }) }
    }

    @Test func aChildKilledByASignalIsNeverAFinishedRun() async throws {
        // SIGILL is 4 and SIGTRAP 5: as bare statuses they would read as "every photo failed" and "no libraries".
        #expect(AnalyzerRunner.status(.uncaughtSignal, SIGILL) == 132 && AnalyzerRunner.status(.uncaughtSignal, SIGTRAP) == 133)
        #expect(AnalyzerRunner.status(.exit, 4) == 4)
        let dir = try TestMemory.tempDir("run")
        let exe = dir.appendingPathComponent("python")
        // SIGKILL leaves no crash report behind; the mapping is the same for every signal.
        try Data("#!/bin/sh\necho 'IQA-MEMORY failed \(TestMemory.sha("bad")) a.jpg'\nkill -KILL $$\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let killed = AnalyzerRunner(python: exe.path, repo: dir.path)
        do {
            _ = try await killed.analyze(paths: [dir], out: dir.appendingPathComponent("out"), memory: dir.appendingPathComponent("memory.sqlite"),
                                         sources: nil, onLine: { _ in })
            Issue.record("a killed analyzer must throw")
        } catch let e as AnalyzerError {
            guard case .failed(let code, _) = e else { Issue.record("\(e)"); return }
            #expect(code == 128 + SIGKILL)
        }
    }

    @Test func aCancelBetweenSetAndRunStillStopsTheChild() throws {
        // The order the race produced: the cancel lands after the box holds the process but before it runs.
        let box = AnalyzerRunner.ProcessBox()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        #expect(box.set(p))
        box.cancel()
        try p.run()
        box.launched()
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM)
        #expect(box.wasCancelled)
    }

    @Test func analyzeArgumentsUseTheMemory() {
        let r = AnalyzerRunner(python: "/py", repo: "/repo")
        let args = r.analyzeArguments(paths: [URL(fileURLWithPath: "/s/files")], out: URL(fileURLWithPath: "/s/out"),
                                      memory: URL(fileURLWithPath: "/m/memory.sqlite"), sources: URL(fileURLWithPath: "/s/sources.jsonl"))
        #expect(args == ["-m", "iqa", "analyze", "/s/files", "-r", "--out", "/s/out", "--memory", "/m/memory.sqlite",
                         "--sources", "/s/sources.jsonl", "--no-report"])
        #expect(!r.analyzeArguments(paths: [], out: URL(fileURLWithPath: "/o"), memory: URL(fileURLWithPath: "/m"), sources: nil).contains("--sources"))
    }

    // MARK: Staging

    @Test func stagingSafetyCheck() throws {
        let base = try TestMemory.tempDir("staging")
        let root = base.appendingPathComponent("staging", isDirectory: true)
        let inside = root.appendingPathComponent("20261026T030000-abc/files/0001/IMG_0453.JPG")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inside)
        let sibling = base.appendingPathComponent("staging2/x", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sibling)

        #expect(Staging.isInside(inside, root))
        #expect(Staging.isInside(root.appendingPathComponent("not-yet-made"), root))
        #expect(!Staging.isInside(root, root), "the staging folder itself is never a batch")
        #expect(!Staging.isInside(sibling, root), "a sibling sharing the name as a prefix is outside")
        #expect(!Staging.isInside(root.appendingPathComponent("../staging2/x"), root), ".. leads out")
        #expect(!Staging.isInside(link, root), "a symlink that leads out is outside")
        #expect(!Staging.isInside(URL(fileURLWithPath: "/"), root))
    }

    @Test func stagingRemovesBatchesAndRefusesAnythingElse() throws {
        let base = try TestMemory.tempDir("staging")
        let staging = Staging(root: base.appendingPathComponent("staging", isDirectory: true))
        let batch = try staging.newBatch()
        #expect(FileManager.default.fileExists(atPath: batch.files.path) && FileManager.default.fileExists(atPath: batch.out.path))
        let file = try batch.slot(1, under: batch.files).appendingPathComponent("IMG_0453.JPG")
        try Data("x".utf8).write(to: file)
        #expect(file.path.hasSuffix("files/0001/IMG_0453.JPG"))

        let keep = base.appendingPathComponent("keep.txt")
        try Data("k".utf8).write(to: keep)
        #expect(throws: (any Error).self) { try staging.remove(keep) }
        #expect(throws: (any Error).self) { try staging.remove(staging.root) }
        #expect(FileManager.default.fileExists(atPath: keep.path))

        try staging.remove(batch.folder)
        #expect(!FileManager.default.fileExists(atPath: batch.folder.path))
        _ = try staging.newBatch()
        _ = try staging.newBatch()
        #expect(staging.sweep() == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.root.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: staging.root.path) && FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func aLiveBatchIsNotSweptAndALeftoverIs() throws {
        let base = try TestMemory.tempDir("staging")
        let staging = Staging(root: base.appendingPathComponent("staging", isDirectory: true))
        let live = try staging.newBatch()
        let lockFile = live.folder.appendingPathComponent(BatchLock.fileName)
        #expect(FileManager.default.fileExists(atPath: lockFile.path) && live.lock?.isHeld == true)
        // A flock belongs to its open file description: a second open of the same file cannot take it, even here,
        // which is what another instance's sweep meets.
        #expect(BatchLock(folder: live.folder) == nil)
        let old = staging.root.appendingPathComponent("20261001T000000-old/files", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)   // an older version's: no .lock
        do { _ = try staging.newBatch() }                                                     // ended without remove: lock released
        #expect(staging.sweep() == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.root.path) == [live.folder.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: live.files.path), "the live batch keeps its files")
        try staging.remove(live)
        #expect(!FileManager.default.fileExists(atPath: live.folder.path))
        #expect(live.lock?.isHeld == false, "removing the batch gives up its lock")
        let next = try staging.newBatch()
        next.lock?.release()
        #expect(BatchLock(folder: next.folder) != nil, "a released lock can be taken")
    }

    @Test func contentHashIsSHA256() throws {
        // FIPS 180-2 test vector for "abc".
        #expect(ContentHash.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let url = try TestMemory.tempDir("hash").appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: url)
        #expect(try ContentHash.sha256(of: url) == ContentHash.sha256(of: Data("abc".utf8)))
        #expect(MemoryStore.data(hex: "ba78")! == Data([0xBA, 0x78]))
        #expect(MemoryStore.data(hex: "zz") == nil)
    }

    // MARK: Earlier copies

    @Test func earlierCopiesAreRemovedOnlyWhenRemembered() throws {
        let base = try TestMemory.tempDir("earlier")
        let root = base.appendingPathComponent("photos", isDirectory: true)
        func copy(_ run: String, _ name: String, _ body: String) throws -> StagedFile {
            let u = root.appendingPathComponent("\(run)/\(name)")
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: u)
            return StagedFile(url: u, sha256: ContentHash.sha256(of: Data(body.utf8)))
        }
        let a = try copy("20261013T040000", "001-IMG_1.JPG", "a")
        let a2 = try copy("20261015T050000", "001-IMG_1.JPG", "a")      // a byte-identical duplicate
        let b = try copy("20261015T050000", "002-IMG_2.JPG", "b")
        let c = try copy("20261015T050000", "003-IMG_3.PNG", "c")
        let d = try copy("20261016T060000", "001-IMG_4.JPG", "d")
        let outside = StagedFile(url: base.appendingPathComponent("elsewhere.jpg"), sha256: a.sha256)
        try Data("a".utf8).write(to: outside.url)
        let known = [a.sha256: KnownAsset(status: "measured", analyzerKey: key),
                     b.sha256: KnownAsset(status: "measured", analyzerKey: key),
                     c.sha256: KnownAsset(status: "not_capture", analyzerKey: key)]
        let r = EarlierCopies.removeRemembered([a, a2, b, c, d, outside], known: known, hasPreview: { $0 == a.sha256 }, root: root)
        #expect(r.removed == 3)
        #expect(r.kept == [EarlierCopies.keptNoPreview: 1, EarlierCopies.keptNotRemembered: 1])
        #expect(!FileManager.default.fileExists(atPath: a.url.path) && !FileManager.default.fileExists(atPath: a2.url.path))
        #expect(!FileManager.default.fileExists(atPath: c.url.path))
        #expect(FileManager.default.fileExists(atPath: b.url.path), "kept: measured but no preview to show it by")
        #expect(FileManager.default.fileExists(atPath: d.url.path), "kept: not in the memory")
        #expect(FileManager.default.fileExists(atPath: outside.url.path), "never outside the folder")
        #expect(r.sentence.hasPrefix("Removed 3 earlier copies"))

        try Data().write(to: root.appendingPathComponent("20261013T040000/.DS_Store"))
        #expect(EarlierCopies.removeEmptyFolders(under: root, includingRoot: true) == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("20261013T040000").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("20261015T050000").path))
        #expect(EarlierCopies.files(in: root).map(\.lastPathComponent).sorted() == ["001-IMG_4.JPG", "002-IMG_2.JPG"])
    }
}
