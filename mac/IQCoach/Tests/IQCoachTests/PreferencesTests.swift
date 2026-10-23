import Testing
import Foundation
@testable import IQCoach

/// Set aside, intent tags and the preferences file (spec §3.2, §4.5, §7 step 10).
@MainActor
struct PreferencesTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("iqcoach-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func highlights(_ n: Int, hits: Int, model: String = "Test Cam") -> CameraGroup {
        Fx.camera(n, model: model) { i, p in p.clipHighPct = i < hits ? 3 : 0.1 }
    }

    @Test func roundTripsThroughAFile() throws {
        let dir = try tempDir()
        let store = PreferencesStore(directory: dir)
        let cam = highlights(100, hits: 25)
        let card = try #require(CameraRules.highlightDiscipline(cam))
        store.setAside(card, note: " snow and beach days ", date: Date(timeIntervalSince1970: 1_760_000_000))
        store.toggle(.brightOnPurpose, for: cam.photos[0])
        store.setEditor(.lightroom)
        try store.saveNow()

        let again = PreferencesStore(directory: dir)
        #expect(again.prefs == store.prefs)
        #expect(again.prefs.setAside[card.id]?.note == "snow and beach days")
        #expect(again.prefs.setAside[card.id]?.hits == 25)
        #expect(again.prefs.intents(for: cam.photos[0]) == [.brightOnPurpose])
        #expect(again.prefs.editor == .lightroom)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"Test Cam|p0.jpg|2026:01:01 12:00:00\""))
    }

    @Test func aCorruptFileIsMovedAside() throws {
        let dir = try tempDir()
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("preferences.json"))
        let store = PreferencesStore(directory: dir)
        #expect(store.prefs == UserPreferences())
        let moved = try #require(store.movedAside)
        #expect(moved.lastPathComponent.hasPrefix("preferences.bad-"))
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func photoKeyFormat() {
        let p = Fx.photo(7, camera: "NIKON D850") { $0.file = "DSC_0001.JPG"; $0.datetime = "2025:01:19 11:40:16" }
        #expect(p.key.rawValue == "NIKON D850|DSC_0001.JPG|2025:01:19 11:40:16")
        #expect(Fx.photo { $0.datetime = nil }.key.rawValue == "Test Cam|p0.jpg|")
    }

    @Test func comeBackRule() throws {
        let base = try #require(CameraRules.highlightDiscipline(highlights(100, hits: 25)))
        let d = Dismissal(note: "", insight: base)
        #expect(d.comeBackReason(for: base) == nil)
        // 24 % more photos, same severity and grade: stays aside.
        let grew24 = try #require(CameraRules.highlightDiscipline(highlights(124, hits: 31)))
        #expect(grew24.severity == base.severity && grew24.grade == base.grade)
        #expect(d.comeBackReason(for: grew24) == nil)
        // 25 % more photos: back.
        let grew25 = try #require(CameraRules.highlightDiscipline(highlights(125, hits: 32)))
        #expect(d.comeBackReason(for: grew25) == "Back because the evidence changed: you set this aside at 25 of 100 photos (25 %); it is now 32 of 125 (26 %).")
        // Severity changes (over 30 % is Important).
        let worse = try #require(CameraRules.highlightDiscipline(highlights(100, hits: 35)))
        #expect(worse.severity == .important)
        #expect(d.comeBackReason(for: worse)?.contains("moved from Worth acting on to Important") == true)
        // Grade changes (Moderate under 10... here, a crossing range makes it Thin).
        let thin = try #require(CameraRules.highlightDiscipline(highlights(100, hits: 18)))
        #expect(thin.grade == .thin)
        #expect(d.comeBackReason(for: thin)?.contains("its evidence moved from Solid to Thin") == true)
    }

    @Test func aCardThatComesBackIsActiveAgain() throws {
        var prefs = UserPreferences()
        let base = try #require(CameraRules.highlightDiscipline(highlights(100, hits: 25)))
        prefs.setAside[base.id] = Dismissal(note: "", insight: base)
        #expect(CoachingEngine.output(for: highlights(100, hits: 25), prefs: prefs).setAside.count == 1)
        let out = CoachingEngine.output(for: highlights(130, hits: 33), prefs: prefs)
        #expect(out.setAside.isEmpty)
        #expect(out.oneThing?.insight?.backBecause?.hasPrefix("Back because the evidence changed") == true)
    }

    @Test func brightOnPurposeLeavesAPhotoOutOfTheHighlightsCount() throws {
        let cam = highlights(100, hits: 25)
        var prefs = UserPreferences()
        for p in cam.photos.prefix(3) { prefs.intents[p.key] = [.brightOnPurpose] }
        let card = try #require(CameraRules.highlightDiscipline(cam, prefs.context).insight)
        #expect(card.counted == 97)
        #expect(card.share == ShareCount(hits: 22, of: 97))
        #expect(card.countedText == "Counted: 97 of 100 photos (3 you marked bright on purpose are left out)")
        #expect(card.whyShown.counted.contains("3 you marked bright on purpose left out"))
        // The report card still counts every photo: it describes the files, not the coaching.
        #expect(cam.summary.clipHighCount == 25)
    }

    @Test func intentSilencesThePhotosAdvice() {
        let p = Fx.photo { $0.clipHighPct = 3 }
        let store = PreferencesStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), load: false)
        store.toggle(.brightOnPurpose, for: p)
        let a = EditingRules.advice(for: p, context: PhotoContext(intents: store.prefs.intents(for: p)))
        #expect(a.doFirst.isEmpty && a.silenced.map(\.rule) == [.highlights])
        store.toggle(.brightOnPurpose, for: p)
        #expect(store.prefs.intents.isEmpty)
    }
}
