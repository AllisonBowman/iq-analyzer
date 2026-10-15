import Foundation
import Photos

enum PhotosImportError: LocalizedError {
    case denied(PHAuthorizationStatus)
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .denied(let s):
            "IQ Coach was not allowed to read your Photos library (status \(s.rawValue)). Allow it in System Settings > Privacy & Security > Photos, then try again."
        case .nothingToExport:
            "No camera photos were found in the library."
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

    /// Copies the `count` newest camera photos (screenshots skipped) and returns the folder.
    static func exportNewest(count: Int, onLine: @escaping @Sendable (String) -> Void) async throws -> URL {
        try await authorize()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetch = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, stop in
            if !asset.mediaSubtypes.contains(.photoScreenshot) { assets.append(asset) }
            if assets.count >= count { stop.pointee = true }
        }
        guard !assets.isEmpty else { throw PhotosImportError.nothingToExport }
        let dir = exportDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = PHAssetResourceManager.default()
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true          // iCloud-only originals are downloaded
        var written = 0
        for (i, asset) in assets.enumerated() {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let original = resources.first(where: { $0.type == .photo }) ?? resources.first else { continue }
            let name = original.originalFilename.isEmpty ? "\(asset.localIdentifier.prefix(36)).jpg" : original.originalFilename
            let target = dir.appendingPathComponent("\(String(format: "%03d", i + 1))-\(name)")
            onLine("[\(i + 1)/\(assets.count)] exporting \(name)")
            do {
                try await writeResource(original, to: target, manager: manager, options: opts)
                written += 1
            } catch {
                onLine("  skipped \(name): \(error.localizedDescription)")
            }
        }
        guard written > 0 else { throw PhotosImportError.nothingToExport }
        onLine("exported \(written) photos to \(dir.path)")
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
