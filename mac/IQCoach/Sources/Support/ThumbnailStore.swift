import SwiftUI
import AppKit

/// In-memory thumbnail cache in front of `ThumbnailLoader`, keyed by (path, maxPixel), with one load per key in flight.
actor ThumbnailStore {
    static let shared = ThumbnailStore()

    struct Key: Hashable, Sendable {
        let path: String
        let maxPixel: Int
    }

    static let capacity = 600

    /// Thread-safe mirror of the cache so a view can show an already-loaded image on its first frame,
    /// and so PNG snapshots can load synchronously.
    nonisolated(unsafe) private static let mirror: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = capacity
        return c
    }()

    private var cache: [Key: CGImage] = [:]
    private var inflight: [Key: Task<CGImage?, Never>] = [:]

    nonisolated static func cached(path: String, maxPixel: Int) -> CGImage? {
        mirror.object(forKey: "\(maxPixel)|\(path)" as NSString)
    }

    nonisolated static func store(_ image: CGImage, path: String, maxPixel: Int) {
        mirror.setObject(image, forKey: "\(maxPixel)|\(path)" as NSString)
    }

    /// Synchronous load for PNG snapshots (the main thread, ImageIO directly).
    nonisolated static func loadSynchronously(path: String, maxPixel: Int) -> CGImage? {
        if let hit = cached(path: path, maxPixel: maxPixel) { return hit }
        guard let img = ThumbnailLoader.loadSync(path: path, maxPixel: maxPixel) else { return nil }
        store(img, path: path, maxPixel: maxPixel)
        return img
    }

    func image(path: String, maxPixel: Int) async -> CGImage? {
        let key = Key(path: path, maxPixel: maxPixel)
        if let hit = cache[key] { return hit }
        if let running = inflight[key] { return await running.value }
        let task = Task<CGImage?, Never> { await ThumbnailLoader.load(path: path, maxPixel: maxPixel) }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            if cache.count >= Self.capacity { cache.removeAll(keepingCapacity: true) }
            cache[key] = result
            Self.store(result, path: path, maxPixel: maxPixel)
        }
        return result
    }
}

/// A photo thumbnail: a grey placeholder until the image arrives, then the picture filled and clipped to a rounded rectangle.
/// The caller sets the size with `.frame` (44 pt in table rows, 96 pt in card strips, 160 pt in the library overview).
struct PhotoThumb: View {
    let path: String?
    var maxPixel: Int = 256
    var cornerRadius: CGFloat = 6
    @State private var loaded: CGImage?
    @Environment(\.isSnapshot) private var isSnapshot

    private var fileName: String { path.map { ($0 as NSString).lastPathComponent } ?? "no file" }

    private var current: CGImage? {
        guard let path else { return nil }
        if isSnapshot { return ThumbnailStore.loadSynchronously(path: path, maxPixel: maxPixel) }
        return loaded ?? ThumbnailStore.cached(path: path, maxPixel: maxPixel)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .overlay {
                if let img = current {
                    Image(decorative: img, scale: 1).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .contentShape(shape)
            .accessibilityElement()
            .accessibilityLabel(path == nil ? "No photo file" : "Photo \(fileName)")
            .accessibilityAddTraits(.isImage)
            .task(id: path.map { "\($0)|\(maxPixel)" }) {
                guard !isSnapshot, let path else { loaded = nil; return }
                if let hit = ThumbnailStore.cached(path: path, maxPixel: maxPixel) { loaded = hit; return }
                loaded = nil
                let img = await ThumbnailStore.shared.image(path: path, maxPixel: maxPixel)
                if !Task.isCancelled { loaded = img }
            }
    }
}
