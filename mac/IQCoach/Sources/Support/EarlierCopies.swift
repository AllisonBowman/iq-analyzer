import Foundation

/// The originals earlier versions of the app copied to `~/Library/Application Support/IQCoach/photos` (93 files,
/// 444 MB on 2026-10-23, 44 % of them duplicates). Import and Remove measures them into the memory, makes their
/// previews and then deletes only the copies whose content the memory now holds. It runs only when the user asks.
enum EarlierCopies {
    static var defaultDirectory: URL { MemoryDatabase.defaultDirectory.appendingPathComponent("photos", isDirectory: true) }
    static var runsDirectory: URL { MemoryDatabase.defaultDirectory.appendingPathComponent("runs", isDirectory: true) }

    /// Regular, visible files under `dir`, recursively (symlinks are not followed).
    static func files(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if v?.isRegularFile == true && v?.isSymbolicLink != true { out.append(u) }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func size(of dir: URL) -> Int64 {
        files(in: dir).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    struct Removal: Sendable, Equatable {
        var removed = 0
        var freedBytes: Int64 = 0
        /// Kept copies by reason ("not measured", "no preview could be made").
        var kept: [String: Int] = [:]

        var keptCount: Int { kept.values.reduce(0, +) }

        var sentence: String {
            let copies = removed == 1 ? "1 earlier copy" : "\(removed.formatted()) earlier copies"
            var s = "Removed \(copies) (\(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)))"
            if keptCount > 0 {
                s += "; kept \(keptCount.formatted()): " + kept.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            }
            return s + "."
        }
    }

    /// The name a copy had before earlier versions prefixed it: "007-IMG_0448.JPG" -> "IMG_0448.JPG". A picker copy
    /// ("002-photo.jpeg") never had a name, so it gets the picker's own fallback, "photo-<first 8 hex>.jpeg".
    static func originalName(_ copyName: String, sha256: String) -> String {
        guard let m = copyName.wholeMatch(of: /\d{3}-(.+)/) else { return copyName }
        let rest = String(m.1)
        if let p = rest.wholeMatch(of: /photo\.([A-Za-z0-9]+)/) { return "photo-\(sha256.prefix(8)).\(p.1)" }
        return rest
    }

    /// Clones one copy of each distinct content into `batch.files/<index>/<original name>` (APFS clones share the
    /// blocks, so this costs no disk), skipping formats the analyzer cannot read. Returns the staged files.
    static func stage(_ files: [StagedFile], into batch: StagedBatch) throws -> [StagedFile] {
        var seen = Set<String>(), out: [StagedFile] = []
        for f in files where !seen.contains(f.sha256) {
            seen.insert(f.sha256)
            let name = PhotosImporter.safeFileName(originalName(f.url.lastPathComponent, sha256: f.sha256))
            guard PhotosImporter.analyzerReads(name) else { continue }
            let target = try batch.slot(out.count + 1, under: batch.files).appendingPathComponent(name)
            try FileManager.default.copyItem(at: f.url, to: target)
            out.append(StagedFile(url: target, sha256: f.sha256))
        }
        return out
    }

    static let keptNotRemembered = "not in the memory"
    static let keptNoPreview = "without a preview"

    /// Deletes each copy whose content the memory holds as measured (with a preview to show it by) or as not a
    /// capture. Every other copy is kept, and nothing outside `root` is touched.
    static func removeRemembered(_ files: [StagedFile], known: [String: KnownAsset], hasPreview: (String) -> Bool,
                                 root: URL) -> Removal {
        var r = Removal()
        for f in files {
            guard Staging.isInside(f.url, root) else { continue }
            let status = known[f.sha256]?.status
            let remove: Bool
            switch status {
            case "measured":
                remove = hasPreview(f.sha256)
                if !remove { r.kept[keptNoPreview, default: 0] += 1 }
            case "not_capture":
                remove = true
            default:
                remove = false
                r.kept[keptNotRemembered, default: 0] += 1
            }
            guard remove else { continue }
            let bytes = Int64((try? f.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if (try? FileManager.default.removeItem(at: f.url)) != nil {
                r.removed += 1
                r.freedBytes += bytes
            }
        }
        return r
    }

    /// Removes folders under `root` that are empty (or hold only .DS_Store), deepest first; `root` itself too when
    /// `includingRoot`. Returns how many were removed.
    @discardableResult
    static func removeEmptyFolders(under root: URL, includingRoot: Bool) -> Int {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isDirectory == true && v?.isSymbolicLink != true { dirs.append(u) }
            }
        }
        dirs.sort { $0.pathComponents.count > $1.pathComponents.count }
        if includingRoot { dirs.append(root) }
        var n = 0
        for d in dirs where d == root || Staging.isInside(d, root) {
            guard let items = try? fm.contentsOfDirectory(atPath: d.path), items.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            if (try? fm.removeItem(at: d)) != nil { n += 1 }
        }
        return n
    }
}
