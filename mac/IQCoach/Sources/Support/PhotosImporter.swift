import Foundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum PhotosImportError: LocalizedError {
    case denied(PHAuthorizationStatus)
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .denied(let s):
            "IQ Coach was not allowed to read your Photos library (status \(s.rawValue)). Allow it in System Settings > Privacy & Security > Photos, then try again."
        case .nothingToExport:
            "No camera captures were found in the library (a capture names a camera model in its EXIF and has at least 5 MP)."
        }
    }
}

/// What one import put in staging and what it skipped, for the analyzer run and the progress sheet.
struct ImportResult: Sendable {
    /// Captures to measure, with their content ids.
    var staged: [StagedFile] = []
    var manifest: [ManifestLine] = []
    /// Known current assets skipped before any download or copy.
    var skippedKnown = 0
    /// Assets that failed to measure with the current analyzer key, skipped before any download (not retried).
    var skippedFailed = 0
    /// Files found not to be camera captures (remembered as not_capture, not counted).
    var notCaptures = 0
    /// Captures considered, known or new: what N counts.
    var considered = 0

    /// True when the analyzer has something to do: files to measure or manifest lines to ingest.
    var needsAnalyzer: Bool { !staged.isEmpty || !manifest.isEmpty }
}

/// What to do with one PhotoKit asset before anything is downloaded.
enum ImportDecision: Equatable, Sendable {
    /// Measured (or failed for good) with the current analyzer key, and its original is unchanged: no download, counted.
    case skipKnown
    /// Remembered as not a camera capture, original unchanged: no download, not counted.
    case skipNotCapture
    case download
}

/// What to do with the hashed bytes of a picked photo that did not come through PhotoKit.
enum PickedBytesDecision: Equatable, Sendable {
    /// Known with the current key and nothing to gain from a copy: linked to its item identifier, not copied.
    case link
    /// Copied to staging and listed: new, measured with an earlier key, failed only once, or measured but without a
    /// preview (the analyzer then reports a hit, and the preview is made from the staged copy).
    case stage
}

/// Exports camera originals from the Photos library into staging so the analyzer can read them, skipping what the
/// memory already knows. Read-only against the library; the library itself is never modified.
struct PhotosImporter: Sendable {
    /// "originalFilename|uti|WxH" of the .photo resource and its own pixel size: changes when the original does.
    static func signature(filename: String, uti: String, width: Int, height: Int) -> String {
        "\(filename)|\(uti)|\(width)x\(height)"
    }

    /// The original's pixel size: the .photo resource's own, because PHAsset's is the current version's (a crop moves
    /// it, which changed the signature and put real captures under the 5 MP gate); the asset's only when the resource
    /// reports none.
    static func originalSize(resource: (width: Int, height: Int), asset: (width: Int, height: Int)) -> (width: Int, height: Int) {
        resource.width > 0 && resource.height > 0 ? resource : asset
    }

    static func originalSize(of resource: PHAssetResource, asset: PHAsset) -> (width: Int, height: Int) {
        originalSize(resource: (resource.pixelWidth, resource.pixelHeight), asset: (asset.pixelWidth, asset.pixelHeight))
    }

    /// The pure skip rule. A skip needs a remembered source with the same signature (zero false skips: anything
    /// unverifiable is downloaded); a measurement must also carry the current analyzer key, and a failure must be
    /// final (a first failure is tried once more, as the analyzer does). A non-capture stays one whatever the analyzer
    /// version, since the capture rule is the app's.
    static func decide(known: KnownAsset?, signature: String?, currentKey: String?) -> ImportDecision {
        guard let k = known, let sig = signature, let stored = k.signature, sig == stored else { return .download }
        if k.status == "not_capture" { return .skipNotCapture }
        guard let currentKey, k.analyzerKey == currentKey, k.status == "measured" || k.isFinalFailure else { return .download }
        return .skipKnown
    }

    /// The picker's rule for an item the library can read: newest-N's, except that a measured photo whose preview is
    /// missing is downloaded again, since choosing a photo is how its preview comes back when the library cannot
    /// rebuild it (an original only in iCloud).
    static func decidePickedAsset(known: KnownAsset?, signature: String?, currentKey: String?, hasPreview: (String) -> Bool) -> ImportDecision {
        let d = decide(known: known, signature: signature, currentKey: currentKey)
        if d == .skipKnown, let k = known, k.status == "measured", !(k.sha256.map(hasPreview) ?? false) { return .download }
        return d
    }

    /// True when the memory has this content with the current analyzer key, whatever its status: the analyzer would
    /// not measure it again. Used only after the bytes were hashed, so the content id is the proof.
    static func isCurrent(_ k: KnownAsset?, currentKey: String?) -> Bool {
        guard let k, let currentKey else { return false }
        return k.analyzerKey == currentKey
    }

    /// Link or copy hashed picker bytes. A current measurement is linked only when its preview exists, so picking a
    /// photo again brings a lost preview back; a first failure is copied so the analyzer tries it once more.
    static func pickedBytes(known: KnownAsset?, currentKey: String?, hasPreview: Bool) -> PickedBytesDecision {
        guard let k = known, isCurrent(k, currentKey: currentKey) else { return .stage }
        switch k.status {
        case "measured": return hasPreview ? .link : .stage
        case "failed": return k.isFinalFailure ? .link : .stage
        default: return .link
        }
    }

    /// HEIF brands the analyzer reads as .heic.
    static let heifBrands: Set<String> = ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"]

    /// The extension the bytes call for. The analyzer picks its decoder by extension, so an edited render (HEIC or
    /// JPEG bytes) must never be named after a RAW original. JPEG, HEIF, TIFF and PNG are told by their magic bytes
    /// (TIFF bytes keep a declared TIFF-based RAW extension, such as a DNG's); anything else takes the declared one.
    static func fileExtension(of data: Data, declared: String?) -> String {
        let b = [UInt8](data.prefix(12))
        let declared = declared?.lowercased() ?? "jpg"
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.count >= 12, b[4..<8].elementsEqual("ftyp".utf8), heifBrands.contains(String(decoding: b[8..<12], as: UTF8.self)) { return "heic" }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return rawExtensions.contains(declared) ? declared : "tiff"
        }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        return declared
    }

    /// A file name safe to create inside a staging folder.
    static func safeFileName(_ name: String) -> String {
        let cleaned = String(name.map { $0 == "/" || $0 == ":" || $0 == "\0" ? "_" : $0 })
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "photo" : cleaned
    }

    static func authorize() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { throw PhotosImportError.denied(status) }
    }

    /// Smallest picture counted as a camera capture, as in iqa/select_captures.py (which built the library run).
    static let minCapturePixels = 5_000_000

    /// A camera capture, as iqa/select_captures.py defines it: the file names a camera model in its EXIF and has at
    /// least 5 MP. Screenshots, saved images and thumbnails fail one or both.
    static func isCapture(cameraModel: String?, width: Int, height: Int) -> Bool {
        guard let m = cameraModel?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return false }
        return width * height >= minCapturePixels
    }

    /// The camera model and pixel size recorded in an image file, read with ImageIO.
    static func captureInfo(of url: URL) -> (model: String?, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (model, w, h)
    }

    /// Considers the `count` newest camera captures. Screenshots and originals under 5 MP (the .photo resource's own
    /// size) are skipped from library metadata before any download; a known asset with the current key and an unchanged signature is skipped with no
    /// download and no copy; everything else goes into `batch` under its original file name and into the manifest.
    /// Files found not to be captures after download (no EXIF camera model, under 5 MP) are listed as not_capture so
    /// they are never downloaded again. `known` maps localIdentifier -> what the memory remembers.
    static func exportNewest(count: Int, known: [String: KnownAsset], currentKey: String?, batch: StagedBatch,
                             onLine: @escaping @Sendable (String) -> Void) async throws -> ImportResult {
        try await authorize()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetch = PHAsset.fetchAssets(with: options)
        let manager = PHAssetResourceManager.default()
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true          // iCloud-only originals are downloaded
        var r = ImportResult()
        var index = 0, slot = 0
        while r.considered < count && index < fetch.count {
            try Task.checkCancellation()
            let asset = fetch.object(at: index)
            index += 1
            if asset.mediaSubtypes.contains(.photoScreenshot) { continue }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let original = resources.first(where: { $0.type == .photo }) ?? resources.first else { continue }
            let size = originalSize(of: original, asset: asset)
            if size.width * size.height < minCapturePixels { continue }
            let id = asset.localIdentifier
            let name = fileName(of: original, localIdentifier: id)
            let sig = signature(filename: original.originalFilename, uti: original.uniformTypeIdentifier, width: size.width, height: size.height)
            switch decide(known: known[id], signature: sig, currentKey: currentKey) {
            case .skipKnown:
                r.considered += 1
                if known[id]?.status == "failed" {
                    r.skippedFailed += 1
                    onLine("[\(r.considered)/\(count)] \(name): could not be measured before, not downloaded again")
                } else {
                    r.skippedKnown += 1
                    onLine("[\(r.considered)/\(count)] \(name): already measured, not downloaded")
                }
                continue
            case .skipNotCapture:
                continue
            case .download:
                break
            }
            slot += 1
            onLine("[\(r.considered + 1)/\(count)] exporting \(name)")
            do {
                switch try await copyOriginal(original, locator: id, name: name, signature: sig, slot: slot, gate: true,
                                              batch: batch, manager: manager, options: opts) {
                case .staged(let file, let line):
                    r.staged.append(file)
                    r.manifest.append(line)
                    r.considered += 1
                case .notCapture(let line, let reason):
                    r.manifest.append(line)
                    r.notCaptures += 1
                    onLine("  skipped \(name): not measured (\(reason))")
                }
            } catch {
                onLine("  skipped \(name): \(error.localizedDescription)")
            }
        }
        try ManifestLine.encode(r.manifest).write(to: batch.manifest, options: .atomic)
        onLine("\(Fmt.count(r.considered, "capture")) considered: \(r.skippedKnown.formatted()) already measured, \(r.staged.count.formatted()) copied to staging")
        return r
    }

    /// The photos chosen in the system picker (which needs no library permission). When the library is readable
    /// without asking and an item's identifier names an asset with a .photo resource, the item goes the PhotoKit way:
    /// newest-N's skip rule against the known PhotoKit sources, then the original downloaded under its own name and
    /// listed as a photokit source with its signature. A picked photo is not held to the 5 MP and camera-model gate
    /// (the photographer chose it), but a format the analyzer cannot read is listed as not_capture. Any other item is
    /// loaded as the picker delivers it (the current version: the edited render once a photo has adjustments) and
    /// hashed; a content the memory holds is linked to the item, anything else is staged as `photo-<first 8 hex>.<ext>`
    /// with the extension its bytes call for. Picker bytes never carry a signature: nothing proves they are the original.
    static func export(picked items: [PhotosPickerItem], knownPhotoKit: [String: KnownAsset], currentKey: String?, batch: StagedBatch,
                       knownContent: @Sendable (String) throws -> KnownAsset?, hasPreview: @Sendable (String) -> Bool,
                       onLine: @escaping @Sendable (String) -> Void) async throws -> ImportResult {
        guard !items.isEmpty else { throw PhotosImportError.nothingToExport }
        var r = ImportResult()
        let readable = [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        let manager = PHAssetResourceManager.default()
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true          // the photographer chose it: an iCloud-only original is downloaded
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            let id = item.itemIdentifier
            let label = "[\(i + 1)/\(items.count)]"
            r.considered += 1
            if readable, let id, let found = libraryAsset(localIdentifier: id) {
                let size = originalSize(of: found.resource, asset: found.asset)
                let sig = signature(filename: found.resource.originalFilename, uti: found.resource.uniformTypeIdentifier,
                                    width: size.width, height: size.height)
                let name = fileName(of: found.resource, localIdentifier: id)
                switch decidePickedAsset(known: knownPhotoKit[id], signature: sig, currentKey: currentKey, hasPreview: hasPreview) {
                case .skipKnown:
                    if knownPhotoKit[id]?.status == "failed" {
                        r.skippedFailed += 1
                        onLine("\(label) \(name): could not be measured before, not downloaded again")
                    } else {
                        r.skippedKnown += 1
                        onLine("\(label) \(name): already measured, not downloaded")
                    }
                    continue
                case .skipNotCapture:
                    r.notCaptures += 1
                    onLine("\(label) \(name): remembered as not a camera capture, not downloaded")
                    continue
                case .download:
                    break
                }
                onLine("\(label) exporting \(name)")
                do {
                    switch try await copyOriginal(found.resource, locator: id, name: name, signature: sig, slot: i + 1, gate: false,
                                                  batch: batch, manager: manager, options: opts) {
                    case .staged(let file, let line):
                        r.staged.append(file)
                        r.manifest.append(line)
                        onLine("  copied \(name)")
                    case .notCapture(let line, let reason):
                        r.manifest.append(line)
                        r.notCaptures += 1
                        onLine("  skipped \(name): not measured (\(reason))")
                    }
                } catch {
                    onLine("  skipped \(name): \(error.localizedDescription)")
                }
                continue
            }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            onLine("\(label) loading a picked photo")
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { onLine("  skipped: no data"); continue }
                let sha = ContentHash.sha256(of: data)
                let known = try knownContent(sha)
                if pickedBytes(known: known, currentKey: currentKey, hasPreview: hasPreview(sha)) == .link {
                    if let id { r.manifest.append(.link(sha256: sha, kind: .picker, locator: id)) }
                    switch known?.status {
                    case "failed":
                        r.skippedFailed += 1
                        onLine("  could not be measured before (same bytes), not copied")
                    case "not_capture":
                        r.notCaptures += 1
                        onLine("  remembered as not a camera capture (same bytes), not copied")
                    default:
                        r.skippedKnown += 1
                        onLine("  already measured (same bytes), not copied")
                    }
                    continue
                }
                let name = safeFileName("photo-\(sha.prefix(8)).\(fileExtension(of: data, declared: type.preferredFilenameExtension))")
                guard Self.analyzerReads(name) else {
                    onLine("  skipped \(name): iq-analyzer cannot read this format")
                    continue
                }
                let target = try batch.slot(i + 1, under: batch.files).appendingPathComponent(name)
                try data.write(to: target)
                r.staged.append(StagedFile(url: target, sha256: sha))
                // An item without an identifier is still listed, with no source: it is remembered by its content.
                r.manifest.append(.staged(target, sha256: sha, kind: .picker, locator: id))
                onLine("  copied \(name)")
            } catch {
                onLine("  skipped: \(error.localizedDescription)")
            }
        }
        try ManifestLine.encode(r.manifest).write(to: batch.manifest, options: .atomic)
        return r
    }

    /// A library asset and its .photo resource, when this app may read the library. Never asks.
    static func libraryAsset(localIdentifier id: String) -> (asset: PHAsset, resource: PHAssetResource)? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let r = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else { return nil }
        return (asset, r)
    }

    /// The staged name of an original: its own file name, or its identifier's UUID when it has none.
    static func fileName(of resource: PHAssetResource, localIdentifier id: String) -> String {
        resource.originalFilename.isEmpty ? "\(id.prefix(36)).jpg" : resource.originalFilename
    }

    /// One downloaded original: staged to be measured, or moved aside and listed as not a camera capture.
    enum Copy: Sendable {
        case staged(StagedFile, ManifestLine)
        case notCapture(ManifestLine, reason: String)
    }

    /// Downloads a .photo original into `files/<slot>/` and hashes it. One the analyzer cannot read, or (with `gate`)
    /// one that is not a camera capture, is moved to `other/<slot>/` and listed as not_capture: hashed and remembered,
    /// not measured, so it is never downloaded again.
    static func copyOriginal(_ original: PHAssetResource, locator id: String, name: String, signature sig: String, slot: Int,
                             gate: Bool, batch: StagedBatch, manager: PHAssetResourceManager,
                             options: PHAssetResourceRequestOptions) async throws -> Copy {
        let target = try batch.slot(slot, under: batch.files).appendingPathComponent(safeFileName(name))
        do {
            try await writeResource(original, to: target, manager: manager, options: options)
            var reason: String?
            if !analyzerReads(target.lastPathComponent) {
                reason = "a format iq-analyzer cannot read"
            } else if gate {
                let info = captureInfo(of: target)
                if !isCapture(cameraModel: info?.model, width: info?.width ?? 0, height: info?.height ?? 0) {
                    reason = (info?.model?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty ? "no EXIF camera model" : "under 5 MP"
                }
            }
            if let reason {
                let moved = try batch.slot(slot, under: batch.other).appendingPathComponent(target.lastPathComponent)
                try FileManager.default.moveItem(at: target, to: moved)
                return .notCapture(.notCapture(moved, kind: .photokit, locator: id, signature: sig, reason: reason), reason: reason)
            }
            let sha = try ContentHash.sha256(of: target)
            return .staged(StagedFile(url: target, sha256: sha), .staged(target, sha256: sha, kind: .photokit, locator: id, signature: sig))
        } catch {
            try? FileManager.default.removeItem(at: target)   // our own copy in staging, never the library
            throw error
        }
    }

    /// File extensions iq-analyzer reads (iqa/imageio.py IMAGE_EXT). A file it cannot read would print no memory line,
    /// so it would never be remembered and would be downloaded again on every run.
    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf", "rw2", "pef", "3fr", "iiq", "erf", "mos", "x3f",
    ]
    static let analyzerExtensions: Set<String> = rawExtensions.union([
        "jpg", "jpeg", "jpe", "png", "tif", "tiff", "bmp", "webp", "heic", "heif", "gif",
    ])

    static func analyzerReads(_ fileName: String) -> Bool {
        analyzerExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    private static func writeResource(_ r: PHAssetResource, to url: URL, manager: PHAssetResourceManager,
                                      options: PHAssetResourceRequestOptions) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.writeData(for: r, toFile: url, options: options) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}
