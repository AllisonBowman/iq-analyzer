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

/// Exports the newest camera originals from the Photos library into the app's own folder so the
/// analyzer can read them. Read-only against the library; the library itself is never modified.
struct PhotosImporter: Sendable {
    /// Where the copies go: ~/Library/Application Support/IQCoach/photos/<stamp>/
    static func exportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return base.appendingPathComponent("IQCoach/photos/\(stamp)", isDirectory: true)
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

    /// Copies the `count` newest camera captures and returns the folder. Screenshots are skipped, and so is any
    /// file without an EXIF camera model or under 5 MP (saved images, thumbnails), matching iqa/select_captures.py;
    /// scanning continues until `count` captures are copied or the library runs out.
    static func exportNewest(count: Int, onLine: @escaping @Sendable (String) -> Void) async throws -> URL {
        try await authorize()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetch = PHAsset.fetchAssets(with: options)
        let dir = exportDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = PHAssetResourceManager.default()
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true          // iCloud-only originals are downloaded
        var written = 0
        var index = 0
        while written < count && index < fetch.count {
            let asset = fetch.object(at: index)
            index += 1
            if asset.mediaSubtypes.contains(.photoScreenshot) || asset.pixelWidth * asset.pixelHeight < minCapturePixels { continue }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let original = resources.first(where: { $0.type == .photo }) ?? resources.first else { continue }
            let name = original.originalFilename.isEmpty ? "\(asset.localIdentifier.prefix(36)).jpg" : original.originalFilename
            let target = dir.appendingPathComponent("\(String(format: "%03d", written + 1))-\(name)")
            onLine("[\(written + 1)/\(count)] exporting \(name)")
            do {
                try await writeResource(original, to: target, manager: manager, options: opts)
                let info = captureInfo(of: target)
                guard isCapture(cameraModel: info?.model, width: info?.width ?? 0, height: info?.height ?? 0) else {
                    try? FileManager.default.removeItem(at: target)   // our own copy, never the library
                    onLine("  skipped \(name): not a camera capture (no EXIF camera model, or under 5 MP)")
                    continue
                }
                written += 1
            } catch {
                onLine("  skipped \(name): \(error.localizedDescription)")
            }
        }
        guard written > 0 else { throw PhotosImportError.nothingToExport }
        onLine("exported \(written) photos to \(dir.path)")
        return dir
    }

    /// Copies the photos chosen in the system picker (which needs no library permission) into the
    /// app's folder. Each item arrives as its original data with EXIF intact.
    static func export(picked items: [PhotosPickerItem], onLine: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard !items.isEmpty else { throw PhotosImportError.nothingToExport }
        let dir = exportDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written = 0
        for (i, item) in items.enumerated() {
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            let ext = type.preferredFilenameExtension ?? "jpg"
            let name = String(format: "%03d-photo.%@", i + 1, ext)
            onLine("[\(i + 1)/\(items.count)] copying \(name)")
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { onLine("  skipped: no data"); continue }
                try data.write(to: dir.appendingPathComponent(name))
                written += 1
            } catch {
                onLine("  skipped \(name): \(error.localizedDescription)")
            }
        }
        guard written > 0 else { throw PhotosImportError.nothingToExport }
        onLine("copied \(written) photos to \(dir.path)")
        return dir
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
