import Testing
import Foundation
@testable import IQCoach

/// Capture checks (spec §5, §7 step 11).
struct CheckTests {
    private let started = Date(timeIntervalSince1970: 1_792_022_400)   // 15 Oct 2026

    /// A check with the given baseline and `afterHits` of `afterCount` new photos.
    private func check(_ kind: CheckKind = .highlights, before: (Int, Int), after: (Int, Int), afterFormat: String = "jpeg",
                       baselineFormats: [String: Int]? = nil) -> CaptureCheck {
        var c = CaptureCheck(id: UUID(), camera: "Test Cam", kind: kind, started: started,
                             baseline: .init(hits: before.0, count: before.1, formats: baselineFormats ?? ["jpeg": before.1],
                                             sourceName: "results.json", sourceDate: nil, intentExcluded: 0))
        for i in 0..<after.1 {
            c.after[PhotoKey(rawValue: "Test Cam|n\(i).jpg|x")] = .init(hit: i < after.0, value: i < after.0 ? 3 : 0.1, format: afterFormat, file: "n\(i).jpg", path: nil)
        }
        return c
    }

    /// The §5 worked examples: (before, after, verdict).
    static let table: [((Int, Int), (Int, Int), CheckVerdict)] = [
        ((54, 206), (0, 10), .notSettled(aboutSame: false)),
        ((54, 206), (1, 10), .notSettled(aboutSame: false)),
        ((54, 206), (0, 20), .worked),
        ((54, 206), (1, 20), .worked),
        ((54, 206), (2, 20), .notSettled(aboutSame: false)),
        ((54, 206), (6, 24), .notSettled(aboutSame: true)),
        ((17, 206), (0, 10), .notSettled(aboutSame: false)),
        ((17, 206), (0, 60), .smallDrop),
        ((17, 206), (4, 12), .higher),
        ((22, 26), (2, 10), .worked),
    ]

    @Test(arguments: table.indices) func everyRowOfTheTable(_ i: Int) {
        let (b, a, v) = Self.table[i]
        #expect(CheckComparison.evaluate(check(before: b, after: a)).verdict == v)
    }

    @Test func sentencesCarryTheNumbers() {
        #expect(CheckComparison.evaluate(check(before: (54, 206), after: (0, 10))).sentence == "Not settled yet. Before: 26 % of 206. After: 0 of 10 new photos. That looks better, but with 10 photos the difference could be anywhere from 33 points lower to 2 points higher. Keep going: more photos narrow it.")
        #expect(CheckComparison.evaluate(check(before: (54, 206), after: (1, 20))).sentence == "It worked. Before: 26 % of 206. After: 1 of 20 (5 %). The drop is 21 points; allowing for chance it is somewhere between 2 and 29 points.")
        #expect(CheckComparison.evaluate(check(before: (17, 206), after: (0, 60))).sentence == "A small drop. Before: 17 of 206 (8 %). After: 0 of 60 (0 %). Allowing for chance the drop is between 2 and 13 points, under the 10 points I count as a change that worked.")
        let early = CheckComparison.evaluate(check(before: (54, 206), after: (1, 4)))
        #expect(early.verdict == .keepShooting(4))
        #expect(early.sentence == "4 of 10 new photos so far. No hurry: the check waits.")
    }

    private func library(_ photos: [PhotoRecord], gamut: Bool = true) -> PhotoLibrary {
        PhotoLibrary(sourceName: "new.json", photos: photos.map { p in var q = p; q.clipGamutPct = gamut ? 0 : nil; return q })
    }

    @Test func onlyPhotosTakenAfterTheStartCountAndUndatedAreApart() {
        let c = check(before: (54, 206), after: (0, 0))
        let photos = [Fx.photo(1) { $0.datetime = "2026:10:01 10:00:00"; $0.clipHighPct = 3 },    // before the start
                      Fx.photo(2) { $0.datetime = "2026:10:20 10:00:00"; $0.clipHighPct = 3 },    // after
                      Fx.photo(3) { $0.datetime = nil; $0.clipHighPct = 3 },                      // undated
                      Fx.photo(4, camera: "Other") { $0.datetime = "2026:10:20 10:00:00" }]     // another camera
        let out = CheckComparison.ingest([c], library: library(photos), intents: [:])[0]
        #expect(out.after.count == 1)
        #expect(out.after.values.first?.file == "p2.jpg")
        #expect(out.undated.count == 1)
        #expect(CheckComparison.evaluate(out).undatedLine == "1 new photo carries no date and is not counted.")
    }

    @Test func theSamePhotoLoadedTwiceCountsOnce() {
        let c = check(before: (54, 206), after: (0, 0))
        let lib = library([Fx.photo(2) { $0.datetime = "2026:10:20 10:00:00"; $0.clipHighPct = 3 }])
        let once = CheckComparison.ingest([c], library: lib, intents: [:])
        let twice = CheckComparison.ingest(once, library: lib, intents: [:])
        #expect(twice[0].after.count == 1)
    }

    @Test func taggedPhotosAreLeftOut() {
        let c = check(before: (54, 206), after: (0, 0))
        let p = Fx.photo(2) { $0.datetime = "2026:10:20 10:00:00"; $0.clipHighPct = 3 }
        let out = CheckComparison.ingest([c], library: library([p]), intents: [p.key: [.brightOnPurpose]])
        #expect(out[0].after.isEmpty)
    }

    @Test func aLibraryWithoutNativeClippingIsNotComparable() {
        let c = check(before: (54, 206), after: (0, 0))
        let lib = library([Fx.photo(2) { $0.datetime = "2026:10:20 10:00:00"; $0.clipHighPct = 3 }], gamut: false)
        #expect(!lib.hasNativeClipping)
        let out = CheckComparison.ingest([c], library: lib, intents: [:])[0]
        let r = CheckComparison.evaluate(out)
        #expect(r.verdict == .notComparable)
        #expect(r.sentence.hasPrefix("Not comparable: these results were written before clipping was measured in each file's own encoding"))
        #expect(CheckComparison.blockReason(.highlights, library: lib) != nil)
        #expect(CheckComparison.blockReason(.highlights, library: library([Fx.photo()])) == nil)
    }

    @Test func formatMixCaveatAboveThirtyPoints() {
        // Before: 181 JPEG of 206 (88 %); after: all HEIC (0 %): caveat.
        let mixed = check(before: (54, 206), after: (1, 12), afterFormat: "heic", baselineFormats: ["jpeg": 181, "heic": 25])
        #expect(CheckComparison.evaluate(mixed).formatCaveat == "Before: 181 of 206 JPEG, 25 HEIC; after: 0 of 12 JPEG, 12 HEIC. Clipping is counted the same way in both, but a JPEG copy may have been edited before it was saved.")
        // After 65 % JPEG against 88 %: 23 points, no caveat.
        var close = check(before: (54, 206), after: (0, 0), baselineFormats: ["jpeg": 181, "heic": 25])
        for i in 0..<20 {
            close.after[PhotoKey(rawValue: "k\(i)")] = .init(hit: false, value: 0, format: i < 13 ? "jpeg" : "heic", file: "f\(i)", path: nil)
        }
        #expect(CheckComparison.evaluate(close).formatCaveat == nil)
    }

    @Test func startFreezesTheBaselineWithIntentExclusions() throws {
        let cam = Fx.camera(20) { i, p in p.clipHighPct = i < 5 ? 3 : 0.1 }
        var intents: [PhotoKey: Set<IntentTag>] = [:]
        intents[cam.photos[0].key] = [.brightOnPurpose]
        let c = CheckComparison.start(.highlights, camera: cam, library: PhotoLibrary(sourceName: "r.json", photos: cam.photos), intents: intents, now: started)
        #expect(c.baseline.hits == 4 && c.baseline.count == 19 && c.baseline.intentExcluded == 1)
        let r = Stats.wilson(k: 4, n: 19)
        #expect(CheckComparison.startText(c, phone: true).hasPrefix("Check: blown highlights on Test Cam. Before: 4 of 19 photos (21 %; between \(Fmt.num(r.lowerBound * 100, 0)) and \(Fmt.num(r.upperBound * 100, 0)) % allowing for chance) have more than 1 % of the frame blown. Shoot as you normally would, using the sun slider on bright scenes"))
        let lvl = CheckComparison.start(.levelEdges, camera: Fx.camera(6) { i, p in p.structureHorizonTiltDeg = i < 2 ? 2 : (i < 4 ? 0.3 : nil) },
                                        library: PhotoLibrary(sourceName: "r", photos: []), intents: [:])
        #expect(lvl.baseline.count == 4 && lvl.baseline.hits == 2)
    }
}
