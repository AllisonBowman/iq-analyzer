import Testing
import Foundation
@testable import IQCoach

struct EditingRuleTests {
    private func ids(_ p: PhotoRecord) -> [String] { EditingRules.advice(for: p).map { String($0.id.prefix { $0 != ":" }) } }

    @Test func cleanPhotoSaysNothingToFix() {
        let a = EditingRules.advice(for: Fx.photo())
        #expect(EditingRules.isNothingToFix(a))
        #expect(a.first?.finding == EditingRules.nothingToFixText)
    }
    @Test func blownHighlights() {
        let a = EditingRules.blownHighlights(Fx.photo { $0.clipHighPct = 2 })
        #expect(a?.lightroom.contains("-40 to -80") == true)
        #expect(a?.caution?.contains("JPEG") == true)
        #expect(EditingRules.blownHighlights(Fx.photo { $0.clipHighPct = 0.5 }) == nil)
    }
    @Test func crushedShadows() {
        #expect(EditingRules.crushedShadows(Fx.photo { $0.clipLowPct = 1 })?.caution?.contains("noise") == true)
        #expect(EditingRules.crushedShadows(Fx.photo { $0.clipLowPct = 0.4 }) == nil)
    }
    @Test func noisy() {
        let a = EditingRules.noisy(Fx.photo { $0.snrMidgreyDB = 24; $0.noiseWhiteness = 0.5 })
        #expect(a?.caution?.contains("smear texture") == true)
        #expect(EditingRules.noisy(Fx.photo { $0.snrMidgreyDB = 24; $0.noiseWhiteness = 0.2 })?.caution == nil)
        #expect(EditingRules.noisy(Fx.photo { $0.snrMidgreyDB = 30 }) == nil)
    }
    @Test func softUnsharpenedAndAlreadySharpened() {
        let soft = EditingRules.soft(Fx.photo { $0.mtf50P80CPP = 0.14; $0.overshootMedianPct = 3 })
        #expect(soft?.lightroom.contains("Masking 40-70") == true)
        let sharp = EditingRules.soft(Fx.photo { $0.mtf50P80CPP = 0.14; $0.overshootMedianPct = 10 })
        #expect(sharp?.apple.contains("do not add more") == true)
        #expect(EditingRules.soft(Fx.photo { $0.mtf50P80CPP = 0.18 }) == nil)
    }
    @Test func halo() {
        #expect(EditingRules.halo(Fx.photo { $0.overshootMedianPct = 12 })?.lightroom.contains("Clarity to 0") == true)
        #expect(EditingRules.halo(Fx.photo { $0.overshootMedianPct = 11.9 }) == nil)
    }
    @Test func colourLean() {
        let a = EditingRules.colourLean(Fx.photo { $0.wbROverGStops = 0.3; $0.wbBOverGStops = -0.3 })
        #expect(a?.finding.contains("warm") == true)
        #expect(a?.lightroom.contains("Temp toward blue") == true)
        #expect(a?.caution?.contains("sunset") == true)
        #expect(EditingRules.colourLean(Fx.photo { $0.wbROverGStops = 0.1; $0.wbBOverGStops = 0.1 }) == nil)
    }
    @Test func flatTones() {
        #expect(EditingRules.flatTones(Fx.photo { $0.tonalRangeStops = 6 })?.generic == "Apply an S-curve.")
        #expect(EditingRules.flatTones(Fx.photo { $0.tonalRangeStops = 6; $0.clipHighPct = 0.3 }) == nil)
        #expect(EditingRules.flatTones(Fx.photo { $0.tonalRangeStops = 7 }) == nil)
    }
    @Test func exposure() {
        #expect(EditingRules.exposure(Fx.photo { $0.lumaP50 = 60 })?.apple.contains("+0.3 to +0.7") == true)
        #expect(EditingRules.exposure(Fx.photo { $0.lumaP50 = 200 })?.lightroom == "Exposure -0.3.")
        #expect(EditingRules.exposure(Fx.photo { $0.lumaP50 = 200; $0.clipHighPct = 1 }) == nil)
        #expect(EditingRules.exposure(Fx.photo { $0.lumaP50 = 120 }) == nil)
    }
    @Test func moire() {
        #expect(EditingRules.moire(Fx.photo { $0.noisePeriodicSuspect = true })?.lightroom.contains("Moire brush") == true)
        #expect(EditingRules.moire(Fx.photo()) == nil)
    }
    @Test func adviceHasEveryEditorText() {
        let a = EditingRules.advice(for: Fx.photo { $0.clipHighPct = 3 })
        for e in Editor.allCases { #expect(a.allSatisfy { !$0.text(for: e).isEmpty }) }
    }
}
