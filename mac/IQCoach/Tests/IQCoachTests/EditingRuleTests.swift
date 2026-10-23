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

/// The photo screen's lists (spec §2 layer 5, §7 step 5).
struct PhotoAdviceTests {
    private let i13 = PhotoContext(cameraName: "iPhone 13", cameraLeanR: 0.041, cameraLeanB: 0.033, libraryColorfulnessMedian: 38.6)

    /// E07C5F37, the petunia (iPhone 13, ISO 40).
    private var petunia: PhotoRecord {
        Fx.photo(1, camera: "iPhone 13") { p in
            p.clipHighPct = 1.383; p.clipLowPct = 0; p.clipGamutPct = 11.736; p.lumaP50 = 92; p.tonalRangeStops = 7.78
            p.snrMidgreyDB = 36.22; p.noiseWhiteness = 0.42
            p.edgesMeasured = 0; p.edgesCandidates = 7; p.mtf50P80CPP = nil; p.mtf50P80LWPH = nil; p.overshootMedianPct = nil
            p.edgesRejectReasons = "contrast_gt_1=1;error=1;fit_residual=1;plateau_noise=2;shading=1;step_too_small=1"
            p.wbROverGStops = 1.459; p.wbBOverGStops = 1.027; p.colorfulness = 125.2
            p.structureThirdsDistance = 0.929; p.structureFocusFraction = 0.333
        }
    }

    @Test func oneEdgeSoftRowGivesNoCard() {
        let a = EditingRules.advice(for: Fx.photo { $0.edgesMeasured = 1; $0.mtf50P80CPP = 0.1 }, context: .none)
        #expect(!(a.doFirst + a.also).contains { $0.rule == .soft })
        #expect(a.notMeasured.first?.name == "Sharpness")
    }

    @Test func petuniaPutsTheLeanInAlsoWithTheSubjectWording() {
        let a = EditingRules.advice(for: petunia, context: i13)
        #expect(a.doFirst.map(\.rule) == [.highlights])
        #expect(a.doFirst.first?.note?.hasPrefix("A further 11.7 % of pixels hold colour sRGB cannot show") == true)
        #expect(a.also.map(\.rule) == [.colourLean, .thirds])
        let lean = a.also[0]
        #expect(lean.grade == .thin)
        #expect(lean.finding.contains("your iPhone 13 usually leans 0.04 stops, so most of this is the light or the subject"))
        #expect(lean.finding.contains("very colourful picture (colourfulness 125; your library's median is 39), so the figure most likely describes the subject's own colour"))
        #expect(lean.silencedBy == .colourIsThePoint)
        let checked = a.checked.map(\.text)
        #expect(checked.contains("Crushed shadows 0.00 % (acts above 0.5)"))
        #expect(checked.contains("Noise 36.2 dB (acts below 30)"))
        #expect(a.notMeasured.first?.text == "Sharpness: 7 candidate edges were found and none could be used (2 too noisy on either side; one each an invalid contrast reading, the measurement could not be computed, not straight enough, uneven light across the edge and too little contrast). A figure needs 3 usable straight edges; this says nothing about whether the photo is sharp.")
    }

    @Test func straightenIsThinWithoutVisionAndModerateWhenItAgrees() {
        let p = Fx.photo { $0.structureHorizonTiltDeg = 2.0 }   // right end lower
        #expect(EditingRules.straighten(p)?.grade == .thin)
        // Vision measures counter-clockwise: a right-end-lower horizon has a negative angle.
        let agree = PhotoContext(cameraName: "Test Cam", visionHorizonDeg: -2.4)
        #expect(agree.visionTiltRightEndLower == 2.4)
        #expect(EditingRules.straighten(p, agree)?.grade == .moderate)
        #expect(EditingRules.straighten(p, agree)?.finding.contains("which agrees: probably a real horizon") == true)
        let opposite = PhotoContext(cameraName: "Test Cam", visionHorizonDeg: 2.0)
        #expect(EditingRules.straighten(p, opposite)?.grade == .thin)
        #expect(EditingRules.straighten(p, PhotoContext(cameraName: "Test Cam"))?.finding.contains("Vision found no horizon") == true)
        #expect(EditingRules.advice(for: p, context: .none).doFirst.isEmpty)
    }

    @Test func doFirstHoldsAtMostTwoAndNeverThin() {
        let p = Fx.photo { p in
            p.clipHighPct = 3; p.clipLowPct = 1; p.lumaP50 = 50; p.snrMidgreyDB = 24; p.overshootMedianPct = 15
            p.wbROverGStops = 0.6; p.structureHorizonTiltDeg = 3; p.structureThirdsDistance = 0.9; p.structureFocusFraction = 0.2
        }
        let a = EditingRules.advice(for: p, context: .none)
        #expect(a.doFirst.count == 2)
        #expect(a.doFirst.allSatisfy { $0.grade != .thin })
        #expect(a.doFirst.map(\.rule) == [.exposure, .highlights])
        #expect(a.also.map(\.step) == a.also.map(\.step).sorted())
        #expect(!a.nothingToFix)
    }

    @Test func checkedHoldsNoRuleThatFired() {
        // C6220E43: level edge 7.9° and a sharp subject on a soft background fire; the halo (11.99 %) does not.
        let p = Fx.photo { p in
            p.structureHorizonTiltDeg = -7.9; p.clipHighPct = 0.237; p.clipLowPct = 0.176; p.snrMidgreyDB = 41.2
            p.lumaP50 = 166; p.tonalRangeStops = 9.88; p.mtf50P80CPP = 0.44; p.edgesMeasured = 27; p.overshootMedianPct = 11.99
            p.wbROverGStops = 0.161; p.wbBOverGStops = -0.197; p.structureThirdsDistance = 0.626; p.structureFocusFraction = 0.167
            p.mtf50InfocusCPP = 0.41; p.mtf50BackgroundCPP = 0.153
        }
        let ctx = PhotoContext(cameraName: "iPhone 17 Pro Max", cameraLeanR: 0.038, cameraLeanB: -0.170)
        let a = EditingRules.advice(for: p, context: ctx)
        let fired = Set((a.doFirst + a.also).map(\.rule))
        #expect(fired == [.straighten, .shallow])
        #expect(a.doFirst.isEmpty && a.nothingToFix)
        let names = a.checked.map(\.name)
        #expect(!names.contains("Level edge"))
        #expect(names.contains("Colour") && names.contains("Sharpness"))
        #expect(a.checked.first { $0.name == "Sharpening halo" }?.text == "Sharpening halo 11.99 % (acts at 12 or above)")
    }

    @Test func silencedAdviceMovesOut() {
        let p = Fx.photo { $0.clipLowPct = 3; $0.lumaP50 = 40 }
        let a = EditingRules.advice(for: p, context: PhotoContext(intents: [.darkOnPurpose]))
        #expect(a.silenced.map(\.rule) == [.exposure, .shadows])
        #expect(a.doFirst.isEmpty)
    }

    @Test func realDataSoftAndHaloCounts() throws {
        guard let lib = try RealData.library() else { return }
        let pro = try #require(lib.camera("iPhone 17 Pro Max"))
        // 11 photos have 3 or more edges and p80 under 0.18 c/px (the spec's count); one of them is a shallow-depth
        // frame whose sharp group reads 0.18 or more, which the APP-15 fix keeps quiet. So 10 cards.
        #expect(pro.photos.filter { $0.hasSharpnessFigure && ($0.mtf50P80CPP ?? 1) < EditingRules.softCPP }.count == 11)
        #expect(pro.photos.filter { EditingRules.soft($0) != nil }.count == 10)
        #expect(pro.photos.filter { EditingRules.halo($0) != nil }.count == 17)
    }
}

struct PhotoScreenTests {
    @MainActor @Test func petuniaClippingCaptionSeparatesBlownFromBeyondSRGB() {
        let p = Fx.photo { $0.clipHighPct = 1.383; $0.clipLowPct = 0; $0.clipGamutPct = 11.736 }
        let c = OverlayImage.caption(for: .clipping, photo: p, hasSalientBox: false) ?? ""
        #expect(c.contains("on the full-resolution file: 1.38 % blown, 0.00 % crushed"))
        #expect(c.contains("A further 11.7 % of pixels hold colour beyond sRGB; the file keeps that colour, so it is not marked and is not lost detail."))
        #expect(c.hasSuffix("No pixel is crushed to pure black."))
    }

    @MainActor @Test func photoContextComesFromItsCamera() {
        let cam = Fx.camera(6) { _, p in p.wbROverGStops = 0.04; p.wbBOverGStops = -0.17 }
        let v = PhotoDetailView(photo: cam.photos[0], camera: cam, library: PhotoLibrary(sourceName: "x", photos: cam.photos))
        #expect(v.context.cameraName == "Test Cam")
        #expect(abs((v.context.cameraLeanB ?? 0) + 0.17) < 1e-9)
    }
}
