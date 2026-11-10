import Foundation
import ImageIO
import Photos
import AppKit
import UniformTypeIdentifiers

/// The names in the previews folder, one group per content id: `<sha>.heic` (or `<sha>.jpg` where HEIC cannot be
/// encoded), `<sha>.mask.png` (the clipping mask) and `<sha>.vision.json` (what Vision found).
struct PreviewFiles: Sendable, Equatable {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IQCoach/previews", isDirectory: true)
    }

    init(directory: URL = PreviewFiles.defaultDirectory) { self.directory = directory.standardizedFileURL }

    func heic(_ sha: String) -> URL { directory.appendingPathComponent("\(sha).heic") }
    func jpeg(_ sha: String) -> URL { directory.appendingPathComponent("\(sha).jpg") }
    func mask(_ sha: String) -> URL { directory.appendingPathComponent("\(sha).mask.png") }
    func vision(_ sha: String) -> URL { directory.appendingPathComponent("\(sha).vision.json") }

    /// The preview on disk, if any.
    func existing(_ sha: String) -> URL? {
        [heic(sha), jpeg(sha)].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where a photo's preview is, or would be: the HEIC unless only the JPEG fallback exists.
    func path(_ sha: String) -> String { (existing(sha) ?? heic(sha)).path }

    /// The content id a preview path names; nil for any path that is not one of this folder's previews.
    func sha(ofPreview path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == directory.path else { return nil }
        let name = url.lastPathComponent
        for ext in [".heic", ".jpg"] where name.hasSuffix(ext) {
            let sha = String(name.dropLast(ext.count))
            if Self.isSHA(sha) { return sha }
        }
        return nil
    }

    static func isSHA(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The group a file in the folder belongs to (its content id), or nil when the name is not one the store writes.
    static func group(ofFileName name: String) -> String? {
        for ext in [".heic", ".jpg", ".mask.png", ".vision.json"] where name.hasSuffix(ext) {
            let sha = String(name.dropLast(ext.count))
            if isSHA(sha) { return sha }
        }
        return nil
    }
}

enum PreviewError: LocalizedError {
    case unreadable(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let f): "\(f) could not be read as an image, so no preview was made."
        case .cannotWrite(let f): "The preview \(f) could not be written."
        }
    }
}

/// Previews of remembered photos in `~/Library/Caches/IQCoach/previews`: a 1600 px HEIC (quality 0.7), the clipping
/// mask as PNG and the Vision result, so a photo can be shown after its staged copy is deleted. Bounded by bytes,
/// least recently used first, never evicting a photo in the memory's window: the bound is the larger of the budget
/// and the window's own previews. A missing preview of a PhotoKit photo is rebuilt from the library when a view asks.
actor PreviewStore {
    static let shared = PreviewStore()

    static let defaultBudget: Int64 = 256 * 1024 * 1024
    static let maxPixel = 1600
    static let quality = 0.7
    /// A preview's date is moved forward at most this often when it is shown.
    static let touchInterval: TimeInterval = 3600

    nonisolated let files: PreviewFiles
    /// content id -> PhotoKit localIdentifier, for lazy rebuilds.
    private var photoKit: [String: String] = [:]
    private var lastTouch: [String: Date] = [:]
    private var rebuilding: [String: Task<Bool, Never>] = [:]
    /// Rebuilds that failed this session, so a placeholder does not ask PhotoKit again on every redraw.
    private var failed: Set<String> = []

    init(directory: URL = PreviewFiles.defaultDirectory) {
        files = PreviewFiles(directory: directory)
    }

    // MARK: Making

    /// Writes `<sha>.heic` (or `.jpg`) and `<sha>.mask.png` from the original file. The mask is computed as OverlayImage
    /// does from the original's 800 px thumbnail in the file's own colour space, and stored lossless, because a lossy
    /// preview moves the blown-pixel count by up to 116 %.
    nonisolated func make(sha: String, from original: URL) async throws -> URL {
        let files = self.files
        return try await Task.detached(priority: .utility) {
            try Self.makeSync(sha: sha, from: original, files: files)
        }.value
    }

    nonisolated static func makeSync(sha: String, from original: URL, files: PreviewFiles) throws -> URL {
        // A preview is named by its content id; anything else would escape the naming the trimmer relies on.
        guard PreviewFiles.isSHA(sha) else { throw PreviewError.cannotWrite(sha) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        guard let src = CGImageSourceCreateWithURL(original as CFURL, nil),
              let preview = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbnailOptions(maxPixel) as CFDictionary) else {
            throw PreviewError.unreadable(original.lastPathComponent)
        }
        let mask = ThumbnailLoader.loadSync(path: original.path, maxPixel: ClippingMask.previewPixel).flatMap(ClippingMask.make(from:))
        return try write(preview: preview, mask: mask, sha: sha, files: files)
    }

    nonisolated static func thumbnailOptions(_ maxPixel: Int) -> [CFString: Any] {
        [kCGImageSourceCreateThumbnailFromImageAlways: true,
         kCGImageSourceCreateThumbnailWithTransform: true,
         kCGImageSourceThumbnailMaxPixelSize: maxPixel]
    }

    nonisolated static var canEncodeHEIC: Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)
    }

    /// Writes the preview (HEIC, or JPEG when this Mac cannot encode HEIC) and the mask, each through a temporary
    /// name and a rename, so a half-written file never carries a preview's name.
    nonisolated static func write(preview: CGImage, mask: ClippingMask?, sha: String, files: PreviewFiles) throws -> URL {
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        var target = files.heic(sha)
        if !(canEncodeHEIC && encode(preview, as: .heic, quality: quality, to: target, files: files)) {
            target = files.jpeg(sha)
            guard encode(preview, as: .jpeg, quality: quality, to: target, files: files) else {
                throw PreviewError.cannotWrite(target.lastPathComponent)
            }
            try? FileManager.default.removeItem(at: files.heic(sha))
        } else {
            try? FileManager.default.removeItem(at: files.jpeg(sha))
        }
        if let mask { _ = encode(mask.image, as: .png, quality: nil, to: files.mask(sha), files: files) }
        return target
    }

    @discardableResult
    nonisolated static func encode(_ image: CGImage, as type: UTType, quality: Double?, to url: URL, files: PreviewFiles) -> Bool {
        let tmp = files.directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type.identifier as CFString, 1, nil) else { return false }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return false }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    // MARK: Trimming

    struct Entry: Sendable, Equatable {
        let url: URL
        let group: String
        let bytes: Int64
        let modified: Date
    }

    struct TrimResult: Sendable, Equatable {
        var removedFiles = 0
        var freedBytes: Int64 = 0
        var remainingBytes: Int64 = 0
    }

    /// The groups to evict, least recently used first (a group's date is its newest file's), until the rest fits.
    /// Groups in `keep` (the window's photos) are never evicted: a window's preview would only be rebuilt, or lost
    /// for good, and the window itself is bounded.
    nonisolated static func trimPlan(_ entries: [Entry], budget: Int64, keep: Set<String> = []) -> [String] {
        var bytes: [String: Int64] = [:], newest: [String: Date] = [:]
        for e in entries {
            bytes[e.group, default: 0] += e.bytes
            newest[e.group] = max(newest[e.group] ?? .distantPast, e.modified)
        }
        var total = bytes.values.reduce(0, +)
        let order = newest.keys.filter { !keep.contains($0) }.sorted { (newest[$0]!, $0) < (newest[$1]!, $1) }
        var out: [String] = []
        for g in order where total > budget {
            out.append(g)
            total -= bytes[g] ?? 0
        }
        return out
    }

    /// The names directly in the folder, each as a URL built from the folder's own path. Listing by path follows a
    /// symlinked folder (or Caches), and the URLs keep the unresolved path the delete check compares against, where
    /// contentsOfDirectory(at:) may hand back resolved ones that no delete would accept.
    nonisolated func folderItems() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: files.directory.path) else { return [] }
        return names.map { files.directory.appendingPathComponent($0) }
    }

    /// The store's own files: regular files directly in the folder whose names it writes. Anything else is left alone.
    nonisolated func entries() -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        return folderItems().compactMap { u in
            guard let g = PreviewFiles.group(ofFileName: u.lastPathComponent), let v = try? u.resourceValues(forKeys: keys),
                  v.isRegularFile == true, v.isSymbolicLink != true else { return nil }
            return Entry(url: u, group: g, bytes: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast)
        }
    }

    nonisolated func totalBytes() -> Int64 { entries().map(\.bytes).reduce(0, +) }

    /// Deletes least recently used groups outside `keep` until the folder is under `budget` (or only `keep` is left).
    /// Leftover temporary files from an interrupted write are removed too.
    func trim(budget: Int64 = PreviewStore.defaultBudget, keep: Set<String> = []) -> TrimResult {
        removeStaleTemporaries()
        let all = entries()
        let evict = Set(Self.trimPlan(all, budget: budget, keep: keep))
        var r = TrimResult()
        for e in all {
            if evict.contains(e.group), removeOwnFile(e.url) {
                r.removedFiles += 1
                r.freedBytes += e.bytes
            } else {
                r.remainingBytes += e.bytes
            }
        }
        return r
    }

    /// Deletes every preview, mask and Vision result.
    func clear() -> TrimResult {
        lastTouch = [:]
        failed = []
        return trim(budget: -1)
    }

    /// Deletes the groups of these content ids (a forgotten camera's previews).
    func remove(shas: [String]) -> Int {
        let wanted = Set(shas)
        return entries().filter { wanted.contains($0.group) }.reduce(0) { $0 + (removeOwnFile($1.url) ? 1 : 0) }
    }

    /// Removes a file only when it sits directly in the previews folder.
    private func removeOwnFile(_ url: URL) -> Bool {
        let u = url.standardizedFileURL
        guard u.deletingLastPathComponent().path == files.directory.path else { return false }
        return (try? FileManager.default.removeItem(at: u)) != nil
    }

    private func removeStaleTemporaries() {
        for u in folderItems() where u.lastPathComponent.hasPrefix(".") && u.lastPathComponent.hasSuffix(".tmp") {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date.now.timeIntervalSince(m) > Self.touchInterval { _ = removeOwnFile(u) }
        }
    }

    // MARK: Access

    /// Marks a preview as used (its modification date is what trimming orders by), at most once an hour per file.
    func touch(path: String, now: Date = .now) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == files.directory.path,
              PreviewFiles.group(ofFileName: url.lastPathComponent) != nil else { return }
        let name = url.lastPathComponent
        if let t = lastTouch[name], now.timeIntervalSince(t) < Self.touchInterval { return }
        lastTouch[name] = now
        let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
        guard now.timeIntervalSince(modified) >= Self.touchInterval else { return }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    /// The PhotoKit assets behind remembered contents (content id -> localIdentifier).
    func register(photoKit map: [String: String]) {
        photoKit = map
        failed = []
    }

    /// When `path` is a missing preview of a photo that has a PhotoKit source, rebuilds it from the library.
    /// Never asks for Photos access: without it, or when the asset is gone or only in iCloud, it returns false.
    func rebuildIfPossible(path: String) async -> Bool {
        guard let sha = files.sha(ofPreview: path) else { return false }
        if files.existing(sha) != nil { return true }
        guard let id = photoKit[sha], !failed.contains(sha) else { return false }
        if let running = rebuilding[sha] { return await running.value }
        let files = self.files
        let task = Task<Bool, Never>.detached(priority: .utility) {
            guard let image = await Self.requestImage(localIdentifier: id) else { return false }
            let small = Self.downsample(image, maxPixel: ClippingMask.previewPixel)
            return (try? Self.write(preview: image, mask: small.flatMap(ClippingMask.make(from:)), sha: sha, files: files)) != nil
        }
        rebuilding[sha] = task
        let ok = await task.value
        rebuilding[sha] = nil
        if !ok { failed.insert(sha) }
        return ok
    }

    /// The original (unadjusted) at 1600 px from PHImageManager, network off.
    nonisolated static func requestImage(localIdentifier id: String) async -> CGImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let opts = PHImageRequestOptions()
        opts.version = .unadjusted
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .exact
        opts.isNetworkAccessAllowed = false
        opts.isSynchronous = false
        let size = CGSize(width: maxPixel, height: maxPixel)
        let once = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: opts) { image, info in
                // highQualityFormat calls back once; the guard keeps a second call from resuming twice.
                guard once.claim() else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                cont.resume(returning: degraded ? nil : image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    /// `image` scaled so its long side is `maxPixel`, drawn in its own colour space (the mask's classification space).
    nonisolated static func downsample(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > maxPixel else { return image }
        let s = Double(maxPixel) / Double(long)
        let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
        guard let space = ClippingMask.classificationSpace(for: image),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Lets a callback that might run twice resume a continuation once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
