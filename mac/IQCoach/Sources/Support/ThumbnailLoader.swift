import AppKit
import ImageIO

/// Downsampled thumbnails straight from disk. Missing or unreadable files return nil, never throw.
enum ThumbnailLoader {
    static func load(path: String?, maxPixel: Int = 800) async -> CGImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let url = URL(fileURLWithPath: path) as CFURL
            guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return cg
        }.value
    }
}
