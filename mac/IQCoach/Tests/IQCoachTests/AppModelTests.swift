import Testing
import Foundation
@testable import IQCoach

/// The app model's memory flows (docs/MEMORY-SPEC.md §6, §7) on temporary folders: never the real memory, previews,
/// staging or preferences.
@MainActor
struct AppModelTests {
    private func model(memory: URL, previews: URL? = nil, staging: URL? = nil) throws -> AppModel {
        AppModel(preferences: PreferencesStore(directory: try TestMemory.tempDir("prefs"), load: false),
                 memoryDirectory: memory,
                 previews: PreviewStore(directory: try previews ?? TestMemory.tempDir("previews")),
                 staging: Staging(root: try staging ?? TestMemory.tempDir("staging")),
                 earlierCopies: try TestMemory.tempDir("earlier"))
    }

    @Test func maintenanceLeavesAnOpenedResultsFileOnScreen() async throws {
        let m = try TestMemory()
        try m.addPhoto(Fx.photo(1), seed: "a", ts: 1)
        m.close()
        let app = try model(memory: m.dir)
        let json = try TestMemory.tempDir("results").appendingPathComponent("results.json")
        try JSONEncoder().encode([Fx.photo(2), Fx.photo(3)]).write(to: json)
        app.load(url: json)
        #expect(app.library?.sourceName == "results.json")
        // What Compact Now and Forget a Camera do when their command ends.
        #expect(await app.loadMemory(keepSelection: true, onlyIfShown: true))
        #expect(app.library?.sourceName == "results.json", "the file the photographer opened stays on screen")
        #expect(app.memory?.records.count == 1, "Settings still reads the new snapshot")
        // Launch and analyses still make the memory's window the library, and maintenance then refreshes it.
        #expect(await app.loadMemory())
        #expect(app.isShowingMemory)
        #expect(await app.loadMemory(keepSelection: true, onlyIfShown: true))
        #expect(app.isShowingMemory && app.library?.photos.count == 1)
    }

    @Test func launchSweepsLeftoversKeepsALiveBatchAndTrims() async throws {
        let stagingRoot = try TestMemory.tempDir("staging"), previews = try TestMemory.tempDir("previews")
        let app = try model(memory: try TestMemory.tempDir("nomemory"), previews: previews, staging: stagingRoot)
        let live = try app.staging.newBatch()          // another instance's run, as far as this launch can tell
        let leftover = app.staging.root.appendingPathComponent("20261001T000000-old/files", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let stale = previews.appendingPathComponent(".\(UUID().uuidString).tmp")
        try Data("x".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: stale.path)
        await app.launch()
        #expect(!FileManager.default.fileExists(atPath: leftover.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: live.files.path), "a batch still in use is not swept")
        #expect(!FileManager.default.fileExists(atPath: stale.path), "the previews are trimmed at launch")
        try app.staging.remove(live)
    }

    @Test func forgetEverythingSaysWhenPreviewsRemain() async throws {
        let m = try TestMemory()
        m.close()
        let previews = try TestMemory.tempDir("previews")
        let app = try model(memory: m.dir, previews: previews)
        let file = app.previews.files.heic(TestMemory.sha("p"))
        try Data(repeating: 1, count: 4_096).write(to: file)
        // A folder whose files cannot be deleted (on another disk, say): the memory goes, the previews stay, and the
        // photographer is told so instead of being told everything was forgotten.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: previews.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: previews.path) }
        await app.forgetEverything()
        #expect(!m.database.exists)
        #expect(app.errorMessage?.contains("of previews in \(app.previews.files.directory.path)") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: previews.path)
        app.errorMessage = nil
        await app.forgetEverything()
        #expect(app.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func noAnalysisStartsWhileAnotherStopsOrTheMemoryIsMaintained() {
        #expect(AppModel.busyMessage(isAnalyzing: false, isMaintaining: false) == nil)
        #expect(AppModel.busyMessage(isAnalyzing: true, isMaintaining: false) == "The previous analysis is still stopping. Try again in a moment.")
        #expect(AppModel.busyMessage(isAnalyzing: false, isMaintaining: true)?.contains("compacted") == true)
        #expect(AppModel.busyMessage(isAnalyzing: true, isMaintaining: true)?.contains("still stopping") == true)
    }

    private func staged(_ seed: String) -> StagedFile {
        StagedFile(url: URL(fileURLWithPath: "/s/files/0001/\(seed).jpg"), sha256: TestMemory.sha(seed))
    }

    @Test func previewsAreMadeOnlyForRememberedPhotosWithout() {
        let (new, stale, known, failed) = (staged("new"), staged("stale"), staged("known"), staged("failed"))
        var o = BatchOutcome()
        o.record("IQA-MEMORY miss \(new.sha256) new.jpg")
        o.record("IQA-MEMORY stale \(stale.sha256) stale.jpg")
        o.record("IQA-MEMORY hit \(known.sha256) known.jpg")
        o.record("IQA-MEMORY failed \(failed.sha256) failed.jpg")
        let has: (String) -> Bool = { $0 == stale.sha256 }
        #expect(AppModel.previewsWanted([new, stale, known, failed], remembered: o.remembered, hasPreview: has) == [new, known],
                "a photo measured again keeps its preview; a known one without a preview gets one")
    }

    @Test func aStoppedRunStillPreviewsWhatItRemembered() {
        let (a, b, c) = (staged("a"), staged("b"), staged("c"))
        let a2 = StagedFile(url: URL(fileURLWithPath: "/s/files/0004/a copy.jpg"), sha256: a.sha256)
        let known = [a.sha256: KnownAsset(status: "measured", analyzerKey: TestMemory.key),
                     b.sha256: KnownAsset(status: "failed", analyzerKey: TestMemory.key, attempts: 1),
                     c.sha256: KnownAsset(status: "measured", analyzerKey: TestMemory.key)]
        #expect(AppModel.previewsToSalvage([a, b, c, a2, staged("unknown")], known: known, hasPreview: { $0 == c.sha256 }) == [a],
                "measured before the stop and without a preview, once per content")
    }
}
