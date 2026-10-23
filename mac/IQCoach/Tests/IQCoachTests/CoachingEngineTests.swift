import Testing
import Foundation
@testable import IQCoach

/// The one thing, Next up, the fallback and the library headline (spec §2 layers 1 and 7, §4.5).
struct CoachingEngineTests {
    /// 100 photos: 25 with blown highlights and 25 other photos with crushed shadows (both Solid, both Worth acting on).
    private func bothClip() -> CameraGroup {
        Fx.camera(100) { i, p in
            p.clipHighPct = i < 25 ? 3 : 0.1
            p.clipLowPct = (25..<50).contains(i) ? 3 : 0
        }
    }

    @Test func highlightsBeatShadowsAtEqualGrade() {
        let o = CoachingEngine.output(for: bothClip())
        #expect(o.oneThing?.insight?.id == "highlight-discipline:Test Cam")
        #expect(o.oneThing?.sentence == "Expose for the highlights.")
        #expect(o.oneThing?.nextUp?.hasPrefix("Next up: crushed shadows") == true)
        #expect(o.oneThing?.action?.effort == .atCamera)
    }

    @Test func aThinCardIsNeverTheOneThing() {
        let cam = Fx.camera(21) { i, p in p.clipHighPct = i < 6 ? 2 : 0.2 }
        let o = CoachingEngine.output(for: cam)
        #expect(o.oneThing?.isFallback == true)
        #expect(o.oneThing?.sentence == "No single change stands out yet.")
        #expect(o.oneThing?.detail == "The likeliest candidate needs more photos: blown highlights (6 of 21; with 21 photos the share could be anywhere from 14 to 50 %).")
        #expect(o.needsMorePhotos.map(\.id) == ["highlight-discipline:Test Cam"])
        #expect(!o.cards.contains { $0.isThin })
    }

    @Test func aSetAsideCardIsSkipped() {
        let cam = bothClip()
        var prefs = UserPreferences()
        let hi = CameraRules.highlightDiscipline(cam)!
        prefs.setAside[hi.id] = Dismissal(note: "snow days", insight: hi)
        let o = CoachingEngine.output(for: cam, prefs: prefs)
        #expect(o.oneThing?.insight?.id == "shadow-discipline:Test Cam")
        #expect(o.setAside.map(\.id) == [hi.id])
        #expect(!o.cards.contains { $0.id == hi.id })
    }

    @Test func rarePrevalenceIsNotTheOneThing() throws {
        // A ceiling that only 1 of 36 photos crosses is a card, not the one change (prevalence under 10 %).
        let isos: [Double] = [64, 100, 250, 640]
        let cam = Fx.camera(36, model: "NIKON D850") { i, p in
            p.cameraMake = "NIKON CORPORATION"
            if i == 35 { p.iso = 9000; p.snrMidgreyDB = 29.6 } else if i >= 32 { p.iso = 1250; p.snrMidgreyDB = 34 }
            else { p.iso = isos[i % 4]; p.snrMidgreyDB = [42.5, 39.1, 37.8, 35.8][i % 4] }
        }
        let o = CoachingEngine.output(for: cam)
        let iso = try #require(o.cards.first { $0.id.hasPrefix("noise-by-iso") })
        #expect(iso.title == "Keep ISO at or below ISO 1250 for clean pictures")
        #expect((iso.prevalence ?? 1) < CoachingEngine.minPrevalence)
        #expect(o.oneThing?.isFallback == true)
        #expect(o.oneThing?.nextUp?.hasPrefix("Also good to know: noise falls with ISO the way a sensor's does") == true)
    }

    @Test func sparseCamerasGetNoOutput() {
        let o = CoachingEngine.output(for: Fx.camera(4) { _, p in p.clipHighPct = 5 })
        #expect(o.oneThing == nil && o.cards.isEmpty && o.needsMorePhotos.isEmpty)
    }

    @Test func realDataOneThings() throws {
        guard let lib = try RealData.library() else { return }
        func out(_ m: String) throws -> CoachingOutput { CoachingEngine.output(for: try #require(lib.camera(m))) }

        let pro = try out("iPhone 17 Pro Max")
        #expect(pro.oneThing?.insight?.id == "highlight-discipline:iPhone 17 Pro Max")
        #expect(pro.oneThing?.insight?.capsuleText == "Worth acting on · Solid · 206 photos")
        #expect(pro.oneThing?.detail.hasPrefix("54 of your 206 photos (26 %) have more than 1 % of the frame blown") == true)
        #expect(pro.oneThing?.nextUp == "Also good to know: noise does not follow ISO on this phone; up to ISO 1000 every ISO band has a median of 32.0 dB or more.")
        #expect(pro.needsMorePhotos.map(\.id).sorted() == ["field-softness:iPhone 17 Pro Max", "slow-shutter:iPhone 17 Pro Max"])

        // The level-edge card is Good to know here (15 left, 7 right: sign test p = 0.13), so it is not Next up.
        let i13 = try out("iPhone 13")
        #expect(i13.oneThing?.insight?.id == "highlight-discipline:iPhone 13")
        #expect(i13.oneThing?.nextUp?.hasPrefix("Also good to know: noise does not follow ISO") == true)
        #expect(i13.cards.first { $0.id.hasPrefix("level-edge-lean") }?.severity == .info)

        let d850 = try out("NIKON D850")
        #expect(d850.oneThing?.isFallback == true)
        #expect(d850.oneThing?.detail.hasPrefix("Your 36 photos rarely clip: 3 have more than 1 % blown and none loses its shadows.") == true)
        #expect(d850.oneThing?.nextUp?.hasPrefix("Also good to know: noise falls with ISO the way a sensor's does") == true)

        let xr = try out("iPhone XR")
        #expect(xr.oneThing?.isFallback == true)
        #expect(xr.oneThing?.detail.contains("blown highlights (6 of 21; with 21 photos the share could be anywhere from 14 to 50 %)") == true)

        let sea = try out("SEALIFE DC2000")
        #expect(sea.oneThing?.isFallback == true)
        #expect(sea.oneThing?.detail.hasPrefix("Every finding for this camera rests on fewer than 8 photos") == true)

        for cam in lib.coachedCameras {
            #expect(!CoachingEngine.output(for: cam).cards.contains { $0.id.hasPrefix("shadow-discipline") }, Comment(rawValue: cam.model))
        }
    }

    @Test func realDataHeadline() throws {
        guard let lib = try RealData.library() else { return }
        let h = CoachingEngine.headline(for: lib.cameras)
        #expect(h == "The NIKON D850's noise follows ISO the way a sensor's does: 42.5 dB at ISO 64 and below, falling to 33.9 dB above ISO 1000. On the iPhone 17 Pro Max, iPhone 13 and iPhone XR it does not fall steadily with ISO, which points to processing: noise figures here compare each camera's processing, not its sensor.")
    }
}

struct SparseSummaryTests {
    @Test func sparseCameraGetsItsPhotosOwnFigures() {
        let cam = Fx.camera(2, model: "iPhone 13 mini") { i, p in
            p.datetime = i == 0 ? "2026:09:01 10:00:00" : "2024:05:31 10:00:00"
            p.snrMidgreyDB = i == 0 ? 42.67 : 28.4; p.clipHighPct = i == 0 ? 0.5 : 1.4; p.clipLowPct = i == 0 ? 0 : 0.04
            p.edgesMeasured = 0
        }
        #expect(SparseSummary.text(for: cam) == "Coaching starts at 5 photos; this camera has 2, so here are the photos' own figures rather than medians. Noise 28.4 and 42.7 dB. Blown highlights 1.4 and 0.5 %. Crushed shadows 0.04 and 0.00 % (both under the 1 % line). No sharpness figure: neither photo had 3 usable straight edges. Add photos taken with this camera with Choose Photos to Analyze… (⇧⌘P).")
    }
}
