import CoreGraphics
import Foundation
import ImageIO

/// Where a picture is clipped: pixels at or above 254 in any channel (blown) and at or below 1 in all channels (crushed).
struct ClippingMask: @unchecked Sendable {
    static let highThreshold: UInt8 = 254
    static let lowThreshold: UInt8 = 1
    /// The long side of the thumbnail a mask is drawn on (OverlayImage.loadPixel).
    static let previewPixel = 800

    /// A tint image the size of the source: opaque red on blown pixels, opaque blue on crushed ones, clear elsewhere.
    let image: CGImage
    let width: Int
    let height: Int
    let highCount: Int
    let lowCount: Int

    /// The pure part: classify an RGBA8 buffer and return the tint buffer (RGBA8, premultiplied) with the two counts.
    static func classify(rgba: [UInt8], width: Int, height: Int) -> (tint: [UInt8], high: Int, low: Int) {
        var tint = [UInt8](repeating: 0, count: width * height * 4)
        var high = 0, low = 0
        for i in 0..<(width * height) {
            let r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2]
            if r >= highThreshold || g >= highThreshold || b >= highThreshold {
                tint[i * 4] = 255; tint[i * 4 + 3] = 255; high += 1
            } else if r <= lowThreshold && g <= lowThreshold && b <= lowThreshold {
                tint[i * 4 + 2] = 255; tint[i * 4 + 3] = 255; low += 1
            }
        }
        return (tint, high, low)
    }

    /// The colour space the pixels are classified in: the image's own RGB space, so a Display P3 file is judged in
    /// P3 as the analyzer does (iqa/imageio.py, clipping in the file's own encoding). Drawing a P3 picture into sRGB
    /// would clip its out-of-gamut colours to 255 and paint them as blown. Falls back to sRGB for non-RGB images.
    static func classificationSpace(for source: CGImage) -> CGColorSpace? {
        if let own = source.colorSpace, own.model == .rgb, own.supportsOutput { return own }
        return CGColorSpace(name: CGColorSpace.sRGB)
    }

    /// Draws `source` into an RGBA8 buffer in its own colour space and builds the mask. nil when the image has no
    /// pixels or a context cannot be made.
    static func make(from source: CGImage) -> ClippingMask? {
        let w = source.width, h = source.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let drawSpace = classificationSpace(for: source) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: drawSpace, bitmapInfo: info) else { return false }
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let result = classify(rgba: rgba, width: w, height: h)
        guard let provider = CGDataProvider(data: Data(result.tint) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return ClippingMask(image: img, width: w, height: h, highCount: result.high, lowCount: result.low)
    }

    /// Reads a mask written as PNG by the preview store and recounts its pixels: opaque red is blown, opaque blue
    /// crushed. PNG is lossless, so the counts and the tint are those of the mask that was written.
    static func load(png url: URL) -> ClippingMask? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var high = 0, low = 0
        for i in 0..<(w * h) where rgba[i * 4 + 3] == 255 {
            if rgba[i * 4] == 255 && rgba[i * 4 + 2] == 0 { high += 1 } else if rgba[i * 4 + 2] == 255 && rgba[i * 4] == 0 { low += 1 }
        }
        return ClippingMask(image: img, width: w, height: h, highCount: high, lowCount: low)
    }

    /// Bytes the decoded tint occupies, the cache cost.
    var cost: Int { image.bytesPerRow * image.height }
}

/// Builds clipping masks off the main thread and remembers them per path in a byte-bounded cache. For a preview
/// with a stored `<sha>.mask.png` (computed from the original, not the lossy preview) that mask is used.
actor ClippingMaskStore {
    static let shared = ClippingMaskStore()
    static let costLimit = 32 * 1024 * 1024

    private final class Box: Sendable {
        let mask: ClippingMask
        init(_ m: ClippingMask) { mask = m }
    }

    private let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.totalCostLimit = ClippingMaskStore.costLimit
        return c
    }()
    private var inflight: [String: Task<ClippingMask?, Never>] = [:]
    private let previews: PreviewFiles

    init(previews: PreviewFiles = PreviewStore.shared.files) { self.previews = previews }

    func mask(path: String, source: CGImage) async -> ClippingMask? {
        if let hit = cache.object(forKey: path as NSString) { return hit.mask }
        if let running = inflight[path] { return await running.value }
        let stored = previews.sha(ofPreview: path).map(previews.mask).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let task = Task.detached(priority: .userInitiated) { () -> ClippingMask? in
            if let stored, let m = ClippingMask.load(png: stored) { return m }
            return ClippingMask.make(from: source)
        }
        inflight[path] = task
        let result = await task.value
        inflight[path] = nil
        if let result { cache.setObject(Box(result), forKey: path as NSString, cost: result.cost) }
        return result
    }
}
