import Foundation
import CryptoKit

enum StagingError: LocalizedError {
    case outside(String)

    var errorDescription: String? {
        switch self {
        case .outside(let p): "IQ Coach refused to delete \(p) because it is not inside its staging folder."
        }
    }
}

/// `~/Library/Caches/IQCoach/staging`: originals copied out of Photos while they are measured, one folder per batch.
/// A batch is deleted once its previews are made; leftovers of an interrupted batch are swept at launch. Nothing
/// outside this folder is ever deleted through it.
struct Staging: Sendable {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IQCoach/staging", isDirectory: true)
    }

    init(root: URL = Staging.defaultRoot) { self.root = root.standardizedFileURL }

    /// A new, empty batch folder `<root>/<stamp>-<random>`, owned by this process through its `.lock` until
    /// `remove(_:)` (or until the last copy of the batch is gone).
    func newBatch(now: Date = .now) throws -> StagedBatch {
        let stamp = now.formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        var attempt = 0
        while true {
            attempt += 1
            let folder = root.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A sweep elsewhere may have taken the folder between its creation and the lock: then it is being
            // deleted, and a fresh name is tried.
            guard let lock = BatchLock(folder: folder) else {
                if attempt < 3 { continue }
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: folder.appendingPathComponent(BatchLock.fileName).path])
            }
            let batch = StagedBatch(folder: folder, lock: lock)
            for d in [batch.files, batch.other, batch.out] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            return batch
        }
    }

    /// The path's components with `..` removed and symlinks resolved (realpath) up to its deepest existing folder,
    /// so an existing and a not-yet-made path under the same folder compare alike (/var is /private/var here).
    static func canonical(_ url: URL) -> [String] {
        var head = url.standardizedFileURL
        var tail: [String] = []
        while true {
            if let r = realpath(head.path, nil) {
                defer { free(r) }
                return URL(fileURLWithPath: String(cString: r)).pathComponents + tail.reversed()
            }
            let parent = head.deletingLastPathComponent()
            if parent.path == head.path { return url.standardizedFileURL.pathComponents }
            tail.append(head.lastPathComponent)
            head = parent
        }
    }

    /// True only when `url` lies strictly inside `dir`: not `dir` itself, not a sibling that shares its name as a
    /// prefix, not reached through `..` or a symlink that leads out.
    static func isInside(_ url: URL, _ dir: URL) -> Bool {
        let u = canonical(url), d = canonical(dir)
        return u.count > d.count && Array(u.prefix(d.count)) == d
    }

    /// Deletes a batch folder (or anything else inside staging); refuses any path outside it.
    func remove(_ folder: URL) throws {
        guard Self.isInside(folder, root) else { throw StagingError.outside(folder.path) }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Deletes a batch and then gives up its lock.
    func remove(_ batch: StagedBatch) throws {
        defer { batch.lock?.release() }
        try remove(batch.folder)
    }

    /// Deletes every leftover batch: each folder whose lock it can take (its owner has ended or crashed, since flock
    /// dies with the process) or that has none. A batch another instance, or this one, is still measuring holds its
    /// lock and is left alone. Returns how many were removed.
    @discardableResult
    func sweep() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names {
            let u = root.appendingPathComponent(name)
            let isFolder = (try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
            // The lock file is made if missing, so this sweep owns the folder while it deletes it and a batch being
            // created in it at that moment fails its lock and picks another name.
            var lock: BatchLock?
            if isFolder, Self.isInside(u, root) {
                guard let l = BatchLock(folder: u) else { continue }
                lock = l
            }
            if (try? remove(u)) != nil { removed += 1 }
            lock?.release()
        }
        return removed
    }
}

/// An exclusive, non-blocking flock on `<batch>/.lock`, held from the batch's creation until it is removed. A lock
/// belongs to its open file description, so a second open of the same file fails to lock it even in this process.
final class BatchLock: @unchecked Sendable {
    static let fileName = ".lock"
    private let mutex = NSLock()
    private var fd: Int32

    /// Opens (creating it if needed) and locks `<folder>/.lock`; nil when another holder has it or it cannot be opened.
    init?(folder: URL) {
        let path = folder.appendingPathComponent(Self.fileName).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        self.fd = fd
    }

    var isHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return fd >= 0 }

    /// Closes the file, which releases the lock. Safe to call more than once.
    func release() {
        mutex.lock(); defer { mutex.unlock() }
        if fd >= 0 { close(fd); fd = -1 }
    }

    deinit { if fd >= 0 { close(fd) } }
}

/// One batch's folder: `files/<index>/<originalFilename>` the analyzer measures (so a record's `file` is the real
/// name), `other/<index>/<name>` the non-captures that are only listed in the manifest, `sources.jsonl`, and `out/`.
struct StagedBatch: Sendable, Hashable {
    let folder: URL
    /// The owner lock that keeps a sweep from deleting the batch while it is used (nil for a batch named by path).
    var lock: BatchLock? = nil

    static func == (a: StagedBatch, b: StagedBatch) -> Bool { a.folder == b.folder }
    func hash(into h: inout Hasher) { h.combine(folder) }

    var files: URL { folder.appendingPathComponent("files", isDirectory: true) }
    var other: URL { folder.appendingPathComponent("other", isDirectory: true) }
    var manifest: URL { folder.appendingPathComponent("sources.jsonl") }
    var out: URL { folder.appendingPathComponent("out", isDirectory: true) }

    /// `<under>/<0001>/`, created; each file gets its own folder so two originals with one name cannot collide.
    func slot(_ index: Int, under: URL) throws -> URL {
        let d = under.appendingPathComponent(String(format: "%04d", index), isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

/// A staged original and its content id (hashed by the app, so previews match the analyzer's records by content).
struct StagedFile: Sendable, Hashable {
    let url: URL
    let sha256: String
}

/// One line of the sources manifest (`--sources`, JSON Lines, docs/MEMORY-SPEC.md §6).
struct ManifestLine: Sendable, Equatable, Codable {
    var path: String?
    var sha256: String?
    var kind: String
    /// nil only for a staged file with no identity to remember it by (a picker item without an identifier): it is
    /// measured and remembered by content, and its staging path never becomes a source.
    var locator: String?
    var signature: String?
    var status: String?
    var reason: String?

    /// A staged file to measure, with the app's hash of it: the analyzer measures the file only when its own hash of
    /// it agrees, so bytes that changed after they were hashed (and previewed) are never remembered under this id.
    static func staged(_ url: URL, sha256: String, kind: MemorySource.Kind, locator: String?, signature: String? = nil) -> ManifestLine {
        ManifestLine(path: url.path, sha256: sha256, kind: kind.rawValue, locator: locator, signature: signature)
    }

    /// A staged file to remember as not a camera capture, without measuring it.
    static func notCapture(_ url: URL, kind: MemorySource.Kind, locator: String, signature: String?, reason: String) -> ManifestLine {
        ManifestLine(path: url.path, kind: kind.rawValue, locator: locator, signature: signature, status: "not_capture", reason: reason)
    }

    /// Links a source to a content the memory already has, without a file.
    static func link(sha256: String, kind: MemorySource.Kind, locator: String) -> ManifestLine {
        ManifestLine(sha256: sha256, kind: kind.rawValue, locator: locator)
    }

    /// The whole manifest: one compact JSON object per line, keys sorted, slashes unescaped, absent fields omitted.
    static func encode(_ lines: [ManifestLine]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for l in lines {
            out.append(try e.encode(l))
            out.append(0x0A)
        }
        return out
    }
}

/// What one `analyze --memory` run did, from its `IQA-MEMORY <kind> <sha256> <file>` lines, plus what the app skipped
/// before importing anything.
struct BatchOutcome: Sendable, Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case hit, archived, skip, stale, miss, failed
    }

    var counts: [Kind: Int] = [:]
    /// Content id -> what the analyzer did with it.
    var kinds: [String: Kind] = [:]
    /// Known PhotoKit assets and picker items skipped before any download or copy.
    var skippedBeforeImport = 0
    /// Of those, assets remembered as failed with the current analyzer key (not retried, not "already measured").
    var failedBeforeImport = 0

    static let prefix = "IQA-MEMORY "

    /// (kind, content id, file name) of an IQA-MEMORY line; nil for any other line or a malformed one.
    static func parse(_ line: String) -> (kind: Kind, sha256: String, file: String)? {
        guard line.hasPrefix(prefix) else { return nil }
        let parts = line.dropFirst(prefix.count).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let kind = Kind(rawValue: String(parts[0])) else { return nil }
        let sha = String(parts[1]).lowercased()
        guard PreviewFiles.isSHA(sha) else { return nil }
        return (kind, sha, parts.count > 2 ? String(parts[2]) : "")
    }

    /// Counts an IQA-MEMORY line; returns false for any other line.
    @discardableResult
    mutating func record(_ line: String) -> Bool {
        guard let p = Self.parse(line) else { return false }
        counts[p.kind, default: 0] += 1
        kinds[p.sha256] = p.kind
        return true
    }

    func count(_ k: Kind) -> Int { counts[k] ?? 0 }

    /// Contents measured in this run: new ones and ones measured again with the current method.
    var measured: Set<String> { Set(kinds.filter { $0.value == .miss || $0.value == .stale }.keys) }

    /// Contents with a current measurement after this run (a preview is worth making for any of them).
    var remembered: Set<String> { Set(kinds.filter { [.hit, .archived, .miss, .stale].contains($0.value) }.keys) }

    var alreadyMeasured: Int { skippedBeforeImport + count(.hit) + count(.archived) }

    /// "Remembered: 35 already measured, 5 new", then re-measured, unmeasured and failed photos when there are any.
    /// A `skip` is a non-capture (newly listed or remembered) or a photo that failed before: known, not measured.
    var summary: String {
        var s = "Remembered: \(alreadyMeasured.formatted()) already measured, \(count(.miss).formatted()) new"
        if count(.stale) > 0 { s += ", \(count(.stale).formatted()) measured again with the current method" }
        if count(.skip) > 0 { s += ", \(count(.skip).formatted()) not measured (not a camera capture, or failed before)" }
        if count(.failed) > 0 { s += ", \(Fmt.count(count(.failed), "photo")) could not be measured" }
        if failedBeforeImport > 0 { s += ", \(failedBeforeImport.formatted()) that could not be measured before were not tried again" }
        return s
    }
}

enum ContentHash {
    /// SHA-256 of a file's bytes, streamed in 4 MB chunks, as 64 lowercase hex.
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return MemoryStore.hex(Data(hasher.finalize()))
    }

    static func sha256(of data: Data) -> String { MemoryStore.hex(Data(SHA256.hash(data: data))) }
}
