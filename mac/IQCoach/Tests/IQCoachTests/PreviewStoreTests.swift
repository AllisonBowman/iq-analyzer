import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import IQCoach

/// Previews, masks and the byte-bounded caches (docs/MEMORY-SPEC.md §4, §7). Everything happens in temporary folders.
struct PreviewStoreTests {
    private func sha(_ s: String) -> String { TestMemory.sha(s) }

    private func write(_ bytes: Int, to url: URL, modified: Date) throws {
        try Data(repeating: 7, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test func trimPlanEvictsLeastRecentlyUsedGroupsUntilUnderBudget() {
        let d = URL(fileURLWithPath: "/p")
        let e = [
            PreviewStore.Entry(url: d.appendingPathComponent("a.heic"), group: "a", bytes: 80, modified: Date(timeIntervalSince1970: 1)),
            PreviewStore.Entry(url: d.appendingPathComponent("a.mask.png"), group: "a", bytes: 20, modified: Date(timeIntervalSince1970: 1)),
            PreviewStore.Entry(url: d.appendingPathComponent("b.heic"), group: "b", bytes: 100, modified: Date(timeIntervalSince1970: 3)),
            PreviewStore.Entry(url: d.appendingPathComponent("c.heic"), group: "c", bytes: 100, modified: Date(timeIntervalSince1970: 2)),
            // c's Vision result was written later than its preview: the group counts as used then.
            PreviewStore.Entry(url: d.appendingPathComponent("c.vision.json"), group: "c", bytes: 1, modified: Date(timeIntervalSince1970: 4)),
        ]
        #expect(PreviewStore.trimPlan(e, budget: 1_000).isEmpty)
        #expect(PreviewStore.trimPlan(e, budget: 201) == ["a"])
        #expect(PreviewStore.trimPlan(e, budget: 150) == ["a", "b"])
        #expect(PreviewStore.trimPlan(e, budget: 0) == ["a", "b", "c"])
    }

    @Test func trimNeverEvictsTheWindow() async throws {
        let d = URL(fileURLWithPath: "/p")
        let e = ["a", "b", "c", "d"].enumerated().map { i, g in
            PreviewStore.Entry(url: d.appendingPathComponent("\(g).heic"), group: g, bytes: 100, modified: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(PreviewStore.trimPlan(e, budget: 250, keep: ["a"]) == ["b", "c"], "outside the window, least recently used first")
        #expect(PreviewStore.trimPlan(e, budget: 0, keep: ["a", "c"]) == ["b", "d"], "the bound becomes the window's own bytes")
        #expect(PreviewStore.trimPlan(e, budget: 1_000, keep: []).isEmpty)

        let dir = try TestMemory.tempDir("trimkeep")
        let store = PreviewStore(directory: dir)
        let (inWindow, left) = (sha("window"), sha("left"))
        try write(1_000, to: store.files.heic(inWindow), modified: Date(timeIntervalSince1970: 1))      // oldest, but shown
        try write(200, to: store.files.mask(inWindow), modified: Date(timeIntervalSince1970: 1))
        try write(1_000, to: store.files.heic(left), modified: Date(timeIntervalSince1970: 5))
        let r = await store.trim(budget: 500, keep: [inWindow])
        #expect(r.removedFiles == 1 && r.remainingBytes == 1_200)
        #expect(store.files.existing(inWindow) != nil && FileManager.default.fileExists(atPath: store.files.mask(inWindow).path))
        #expect(store.files.existing(left) == nil)
    }

    /// A previews folder reached through a symlink (the folder itself, or Caches above it), as when Caches lives on
    /// another disk: trimming, clearing and removing must still delete the store's own files.
    @Test(arguments: [false, true])
    func aSymlinkedFolderIsStillTrimmedClearedAndRemoved(_ linkTheFolder: Bool) async throws {
        let base = try TestMemory.tempDir("symlink")
        let realParent = base.appendingPathComponent("disk/IQCoach", isDirectory: true)
        let real = realParent.appendingPathComponent("previews", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let dir: URL
        if linkTheFolder {
            dir = base.appendingPathComponent("previews-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: real)
        } else {
            let parent = base.appendingPathComponent("Caches-IQCoach", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: realParent)
            dir = parent.appendingPathComponent("previews", isDirectory: true)
        }
        let store = PreviewStore(directory: dir)
        let (a, b, c) = (sha("la"), sha("lb"), sha("lc"))
        try write(1_000, to: store.files.heic(a), modified: Date(timeIntervalSince1970: 1))
        try write(1_000, to: store.files.heic(b), modified: Date(timeIntervalSince1970: 2))
        try write(1_000, to: store.files.heic(c), modified: Date(timeIntervalSince1970: 3))
        #expect(store.totalBytes() == 3_000)
        let trimmed = await store.trim(budget: 2_000)
        #expect(trimmed.removedFiles == 1 && !FileManager.default.fileExists(atPath: real.appendingPathComponent("\(a).heic").path))
        #expect(await store.remove(shas: [b]) == 1)
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("\(b).heic").path))
        let cleared = await store.clear()
        #expect(cleared.removedFiles == 1 && cleared.remainingBytes == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: real.path), "the folder and the link stay")
    }

    @Test func trimRespectsTheBudgetAndTouchesNothingElse() async throws {
        let parent = try TestMemory.tempDir("trim")
        let dir = parent.appendingPathComponent("previews", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PreviewStore(directory: dir)
        let files = store.files
        let (old, mid, new) = (sha("old"), sha("mid"), sha("new"))
        try write(1_000, to: files.heic(old), modified: Date(timeIntervalSince1970: 1_000))
        try write(300, to: files.mask(old), modified: Date(timeIntervalSince1970: 1_000))
        try write(1_000, to: files.heic(mid), modified: Date(timeIntervalSince1970: 2_000))
        try write(1_000, to: files.jpeg(new), modified: Date(timeIntervalSince1970: 3_000))
        // Not the store's: a file beside the folder, an unrecognised file in it, and a folder in it.
        let outside = parent.appendingPathComponent("\(old).heic")
        try write(5_000, to: outside, modified: Date(timeIntervalSince1970: 1))
        let notes = dir.appendingPathComponent("notes.txt")
        try write(5_000, to: notes, modified: Date(timeIntervalSince1970: 1))
        let sub = dir.appendingPathComponent(sha("folder") + ".heic", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        #expect(store.totalBytes() == 3_300)
        let r = await store.trim(budget: 2_000)
        #expect(r.remainingBytes <= 2_000)
        #expect(r.freedBytes == 1_300 && r.removedFiles == 2)
        #expect(!FileManager.default.fileExists(atPath: files.heic(old).path))
        #expect(!FileManager.default.fileExists(atPath: files.mask(old).path))
        #expect(FileManager.default.fileExists(atPath: files.heic(mid).path))
        #expect(FileManager.default.fileExists(atPath: files.jpeg(new).path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(FileManager.default.fileExists(atPath: sub.path))

        let cleared = await store.clear()
        #expect(cleared.remainingBytes == 0 && store.totalBytes() == 0)
        #expect(FileManager.default.fileExists(atPath: notes.path) && FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func previewPathsAreRecognisedOnlyInTheFolder() throws {
        let files = PreviewFiles(directory: URL(fileURLWithPath: "/tmp/previews"))
        let s = sha("x")
        #expect(files.sha(ofPreview: "/tmp/previews/\(s).heic") == s)
        #expect(files.sha(ofPreview: "/tmp/previews/\(s).jpg") == s)
        #expect(files.sha(ofPreview: "/tmp/previews/sub/../\(s).heic") == s)
        #expect(files.sha(ofPreview: "/tmp/other/\(s).heic") == nil)
        #expect(files.sha(ofPreview: "/tmp/previews/\(s).mask.png") == nil)
        #expect(files.sha(ofPreview: "/tmp/previews/IMG_0001.heic") == nil)
        #expect(files.sha(ofPreview: "/tmp/previews/\(s.uppercased()).heic") == nil)
        #expect(PreviewFiles.group(ofFileName: "\(s).vision.json") == s)
        #expect(PreviewFiles.group(ofFileName: "\(s).txt") == nil)
    }

    /// A 2400 x 1200 sRGB picture: grey with a white block (blown) and a black block (crushed), saved as PNG.
    private func original(in dir: URL) throws -> URL {
        let w = 2_400, h = 1_200
        var px = [UInt8](repeating: 128, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if x < 600 && y < 300 { px[i] = 255; px[i + 1] = 255; px[i + 2] = 255 }
                if x >= 1_800 && y >= 900 { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0 }
                px[i + 3] = 255
            }
        }
        let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = dir.appendingPathComponent("IMG_0453.PNG")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func makeWritesAPreviewAndTheOriginalsMask() async throws {
        let dir = try TestMemory.tempDir("make")
        let store = PreviewStore(directory: dir.appendingPathComponent("previews"))
        let src = try original(in: dir)
        let s = sha("make")
        let url = try await store.make(sha: s, from: src)
        #expect(url == store.files.existing(s))
        #expect(url.pathExtension == (PreviewStore.canEncodeHEIC ? "heic" : "jpg"))
        let preview = try #require(ThumbnailLoader.loadSync(path: url.path, maxPixel: 4_000))
        #expect(max(preview.width, preview.height) == PreviewStore.maxPixel)
        #expect(preview.width == 2 * preview.height)

        // The stored mask is the one OverlayImage would compute from the original's 800 px thumbnail.
        let thumb = try #require(ThumbnailLoader.loadSync(path: src.path, maxPixel: ClippingMask.previewPixel))
        let direct = try #require(ClippingMask.make(from: thumb))
        let stored = try #require(ClippingMask.load(png: store.files.mask(s)))
        #expect(stored.width == direct.width && stored.height == direct.height)
        #expect(stored.highCount == direct.highCount && stored.lowCount == direct.lowCount)
        // Each block is 1/16 of the frame (200 x 100 of 800 x 400); the downsampling filter softens its rim.
        #expect((15_000...20_400).contains(direct.highCount) && (15_000...20_400).contains(direct.lowCount))

        // The mask store prefers the stored mask for a preview path.
        let masks = ClippingMaskStore(previews: store.files)
        let m = await masks.mask(path: url.path, source: preview)
        #expect(m?.highCount == direct.highCount)
    }

    @Test func aMissingPreviewWithoutAPhotoKitSourceIsNotRebuilt() async throws {
        let store = PreviewStore(directory: try TestMemory.tempDir("rebuild"))
        let path = store.files.heic(sha("gone")).path
        #expect(await store.rebuildIfPossible(path: path) == false)
        #expect(await store.rebuildIfPossible(path: "/elsewhere/x.jpg") == false)
    }

    @Test func thePlaceholderSaysWhyThereIsNoPicture() {
        let preview = "/p/\(sha("x")).heic"
        let isPreview = { (p: String) in p == preview }
        #expect(OverlayImage.placeholderText(path: nil, gaveUp: true, exists: { _ in false }, isPreview: isPreview) == "No file path in these results")
        #expect(OverlayImage.placeholderText(path: preview, gaveUp: false, exists: { _ in false }, isPreview: isPreview) == "Loading preview…",
                "a missing preview may still be rebuilt")
        #expect(OverlayImage.placeholderText(path: preview, gaveUp: true, exists: { _ in false }, isPreview: isPreview) == OverlayImage.previewNotKeptText)
        #expect(OverlayImage.placeholderText(path: "/f/a.jpg", gaveUp: true, exists: { _ in false }, isPreview: isPreview) == "File not found at its recorded path")
    }

    @Test func touchMovesTheDateForwardAtMostHourly() async throws {
        let store = PreviewStore(directory: try TestMemory.tempDir("touch"))
        let url = store.files.heic(sha("t"))
        let longAgo = Date(timeIntervalSince1970: 1_000_000)
        try write(10, to: url, modified: longAgo)
        let now = Date(timeIntervalSince1970: 2_000_000)
        await store.touch(path: url.path, now: now)
        // FileManager, not URL resource values, which a URL caches after the first read.
        func modified() -> Date { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast }
        #expect(abs(modified().timeIntervalSince(now)) < 1)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
        await store.touch(path: url.path, now: now.addingTimeInterval(60))
        #expect(modified() == longAgo, "a second touch within the hour does nothing")
        await store.touch(path: url.path, now: now.addingTimeInterval(3_700))
        #expect(abs(modified().timeIntervalSince(now.addingTimeInterval(3_700))) < 1)
    }

    @Test func visionResultsRoundTripThroughJSON() throws {
        var s = ContentSummary(available: true)
        s.labels = [ContentLabel(label: "sky", confidence: 0.9)]
        s.faceCount = 2
        s.horizonDegrees = 1.5
        s.salientBox = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let url = try TestMemory.tempDir("vision").appendingPathComponent("\(sha("v")).vision.json")
        ContentIdentifier.write(s, to: url)
        #expect(ContentIdentifier.read(url) == s)
        ContentIdentifier.write(.unavailable("no"), to: url)
        #expect(ContentIdentifier.read(url) == nil, "an unavailable result is not served from disk")
    }

    // MARK: Byte-bounded caches

    @Test func thumbnailCostIsBytesPerRowTimesHeight() throws {
        #expect(ThumbnailStore.cost(bytesPerRow: 3_200, height: 600) == 1_920_000)
        let ctx = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let img = try #require(ctx.makeImage())
        #expect(ThumbnailStore.cost(of: img) == img.bytesPerRow * 600)
        #expect(ThumbnailStore.cost(of: img) >= 1_920_000)
        // 96 MB holds about fifty 800 px thumbnails, where the count limit alone allowed 600 (about 1.1 GB).
        #expect((50...53).contains(ThumbnailStore.costLimit / ThumbnailStore.cost(of: img)))
        #expect(ClippingMaskStore.costLimit == 32 * 1024 * 1024)
    }

    @Test func storedThumbnailsAreServedFromTheCache() throws {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let img = try #require(ctx.makeImage())
        let path = "/nonexistent/\(UUID().uuidString).jpg"
        #expect(ThumbnailStore.cached(path: path, maxPixel: 8) == nil)
        ThumbnailStore.store(img, path: path, maxPixel: 8)
        #expect(ThumbnailStore.cached(path: path, maxPixel: 8) === img)
    }
}
