import Testing
import Foundation
@testable import IQCoach

struct CameraRuleTests {
    // 1. ISO ceiling
    @Test func noiseByISOFires() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.iso = 50; p.snrMidgreyDB = 38 } else { p.iso = 800; p.snrMidgreyDB = 27 }
        }
        let r = CameraRules.noiseByISO(cam)
        #expect(r != nil)
        #expect(r?.finding.contains("up to ISO 64") == true)
        #expect(r?.finding.contains("drops to 27.0 dB") == true)
    }
    @Test func noiseByISOCleanEverywhere() {
        let r = CameraRules.noiseByISO(Fx.camera(12) { i, p in p.iso = i < 6 ? 50 : 800; p.snrMidgreyDB = 38 })
        #expect(r?.title == "Noise is clean at every ISO you have used")
    }
    @Test func noiseByISONeedsData() {
        #expect(CameraRules.noiseByISO(Fx.camera(12) { _, p in p.snrMidgreyDB = nil }) == nil)
    }

    // 2. Noise character
    @Test func noiseCharacterStrong() {
        let r = CameraRules.noiseCharacter(Fx.camera { _, p in p.noiseWhiteness = 0.5 })
        #expect(r?.severity == .notice)
        #expect(r?.finding.contains("smooths noise strongly") == true)
    }
    @Test func noiseCharacterGrainIsInfoOnly() {
        let r = CameraRules.noiseCharacter(Fx.camera { _, p in p.noiseWhiteness = 0.15 })
        #expect(r?.severity == .info)
        #expect(r?.finding.contains("fine grain") == true)
        #expect(CameraRules.noiseCharacter(Fx.camera { _, p in p.noiseWhiteness = nil }) == nil)
    }

    // 3. Lens comparison
    @Test func lensComparisonFires() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.lens = "Test Cam back camera 6mm f/1.8"; p.focalMM = 6; p.mtf50P80LWPH = 3000 }
            else { p.lens = "Test Cam back camera 2mm f/2.2"; p.focalMM = 2; p.mtf50P80LWPH = 2000 }
        }
        let r = CameraRules.lensComparison(cam)
        #expect(r?.title == "The main camera is your sharpest lens")
        #expect(r?.finding.contains("33 % lower") == true)
        #expect(r?.actionTexts.first?.contains("ultra-wide") == true)
    }
    @Test func lensComparisonCallsSmallGapsATie() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.lens = "Test Cam back camera 6mm f/1.8"; p.focalMM = 6; p.mtf50P80LWPH = 3000 }
            else { p.lens = "Test Cam back camera 2mm f/2.2"; p.focalMM = 2; p.mtf50P80LWPH = 2800 }
        }
        let r = CameraRules.lensComparison(cam)
        #expect(r?.title == "Your lenses resolve about the same detail")
        #expect(r?.severity == .info)
        #expect(r?.actionTexts.contains { $0.contains("inside the measurement band") } == true)
    }
    @Test func lensComparisonNeedsThreeRowsEach() {
        let cam = Fx.camera(12) { i, p in
            if i < 10 { p.focalMM = 6 } else { p.lens = "Test Cam back camera 2mm f/2.2"; p.focalMM = 2; p.mtf50P80LWPH = 1000 }
        }
        #expect(CameraRules.lensComparison(cam) == nil)
    }

    // 4. Field softness
    @Test func fieldSoftnessFires() {
        let r = CameraRules.fieldSoftness(Fx.camera { _, p in p.mtf50CenterMedianCPP = 0.3; p.mtf50OuterMedianCPP = 0.18 })
        #expect(r?.finding.contains("40 % softer") == true)
    }
    @Test func fieldSoftnessQuietWhenEven() {
        #expect(CameraRules.fieldSoftness(Fx.camera { _, p in p.mtf50CenterMedianCPP = 0.3; p.mtf50OuterMedianCPP = 0.27 }) == nil)
    }

    // 5. Highlights and shadows
    @Test func highlightDisciplineFires() {
        let r = CameraRules.highlightDiscipline(Fx.camera(10) { i, p in p.clipHighPct = i < 4 ? 3 : 0 })
        #expect(r?.finding.contains("40 %") == true)
        #expect(r?.actionTexts.contains { $0.contains("sun slider") } == true)
        let nikon = Fx.camera(10, model: "D850") { i, p in p.cameraMake = "NIKON CORPORATION"; p.clipHighPct = i < 4 ? 3 : 0 }
        #expect(CameraRules.highlightDiscipline(nikon)?.actionTexts.contains { $0.contains("-0.3 to -0.7 EV") } == true)
    }
    @Test func highlightDisciplineQuiet() {
        #expect(CameraRules.highlightDiscipline(Fx.camera(10) { i, p in p.clipHighPct = i < 1 ? 3 : 0 }) == nil)
    }
    @Test func shadowDisciplineFiresAndStaysQuiet() {
        let r = CameraRules.shadowDiscipline(Fx.camera(10) { i, p in p.clipLowPct = i < 3 ? 5 : 0 })
        #expect(r?.finding.contains("3 photos lost shadow detail") == true)
        #expect(CameraRules.shadowDiscipline(Fx.camera(10)) == nil)
    }

    // 6. Sharpening
    @Test func sharpeningFires() {
        let r = CameraRules.sharpeningCharacter(Fx.camera { _, p in p.overshootMedianPct = 12 })
        #expect(r?.finding.contains("12.0 %") == true)
    }
    @Test func sharpeningQuiet() {
        #expect(CameraRules.sharpeningCharacter(Fx.camera { _, p in p.overshootMedianPct = 8 }) == nil)
    }

    // 7. Colour lean
    @Test func colourLeanWarm() {
        let r = CameraRules.colourLean(Fx.camera { _, p in p.wbROverGStops = 0.3; p.wbBOverGStops = -0.3 })
        #expect(r?.title == "Colours lean warm")
    }
    @Test func colourLeanQuiet() {
        #expect(CameraRules.colourLean(Fx.camera { _, p in p.wbROverGStops = 0.1; p.wbBOverGStops = -0.1 }) == nil)
    }

    // 8. Slow shutter
    @Test func slowShutterFires() {
        let r = CameraRules.slowShutter(Fx.camera(20) { i, p in
            if i < 8 { p.exposureS = 0.1; p.mtf50P80LWPH = 1800 } else { p.exposureS = 0.004; p.mtf50P80LWPH = 3000 }
        })
        #expect(r?.finding.contains("40 % softer") == true)
        #expect(r?.grade == .moderate)
        #expect(r?.title == "Slow shutter speeds cost sharpness")
    }
    @Test func slowShutterQuiet() {
        let r = CameraRules.slowShutter(Fx.camera(12) { i, p in
            if i < 5 { p.exposureS = 0.1; p.mtf50P80LWPH = 2800 } else { p.exposureS = 0.004; p.mtf50P80LWPH = 3000 }
        })
        #expect(r == nil)
    }

    // 9. Aperture
    @Test func apertureFires() {
        let cam = CameraGroup(model: "D850", photos: (0..<8).map { i in
            Fx.photo(i, camera: "D850", lens: "50mm") { p in
                if i < 4 { p.fNumber = 5.6; p.mtf50P80LWPH = 3500 } else { p.fNumber = 16; p.mtf50P80LWPH = 2500 }
            }
        })
        let r = CameraRules.apertureSweetSpot(cam)
        #expect(r.count == 1)
        #expect(r.first?.title == "Sharpest at f/5.6")
        #expect(r.first?.finding.contains("softest at f/16.0") == true)
    }
    @Test func apertureQuietWithOneAperture() {
        #expect(CameraRules.apertureSweetSpot(Fx.camera(8)).isEmpty)
    }

    // 10. Confidence: the card is gone (F10); its content is the p80 range in the sharpness tile caption.
    @Test func noConfidenceCardEvenWithWideIntervals() {
        let cam = Fx.camera { _, p in p.mtf50MedianCPP = 0.2; p.mtf50MedianCILo = 0.12; p.mtf50MedianCIHi = 0.30 }
        #expect(!CoachingEngine.insights(for: cam).contains { $0.id.hasPrefix("sharpness-confidence") })
    }

    // Engine
    @Test func engineSkipsSmallCameras() {
        #expect(CoachingEngine.insights(for: Fx.camera(4) { _, p in p.overshootMedianPct = 20 }).isEmpty)
        #expect(!CoachingEngine.insights(for: Fx.camera(5) { _, p in p.overshootMedianPct = 20 }).isEmpty)
    }

    // Feedback-layers spec §4.6 (step 3)

    @Test func nonFollowingCameraSaysNoiseDoesNotFollowISO() {
        let cam = Fx.camera(15) { i, p in p.iso = [50, 100, 250][i / 5]; p.snrMidgreyDB = [33.6, 32.0, 36.7][i / 5] }
        let r = CameraRules.noiseByISO(cam)
        #expect(r?.title == "Noise does not follow ISO on this phone")
        #expect(r?.actionTexts.first == "Do not chase a low ISO for clean pictures on this phone: up to ISO 400 every ISO band has a median of 32.0 dB or more.")
        #expect(r?.grade == .moderate)
    }

    @Test func sensorLikeCameraFollowsISO() {
        let isos: [Double] = [64, 100, 250, 640, 1250]
        let cam = Fx.camera(25, model: "NIKON D850") { i, p in
            p.cameraMake = "NIKON CORPORATION"; p.iso = isos[i / 5]; p.snrMidgreyDB = [42.5, 39.1, 37.8, 35.8, 33.9][i / 5]
        }
        let r = CameraRules.noiseByISO(cam)
        #expect(r?.finding.hasPrefix("Noise falls with ISO the way a sensor's does.") == true)
        #expect(r?.title == "Noise is clean at every ISO you have used")
        #expect(r?.grade == .solid)
    }

    @Test func lensTieIsComputedOnGatedRows() {
        // One-edge rows on the ultra-wide read far lower; left out, the two lenses tie.
        let cam = Fx.camera(16) { i, p in
            if i < 6 { p.lens = "Test Cam back camera 6mm f/1.8"; p.focalMM = 6; p.mtf50P80LWPH = 3000 }
            else { p.lens = "Test Cam back camera 2mm f/2.2"; p.focalMM = 2; p.mtf50P80LWPH = i < 12 ? 2900 : 900; if i >= 12 { p.edgesMeasured = 1 } }
        }
        let r = CameraRules.lensComparison(cam)
        #expect(r?.title == "Your lenses resolve about the same detail")
        #expect(r?.counted == 12)
        #expect(r?.grade == .moderate)
    }

    @Test func fieldSoftnessWithThreeGatedRowsIsThin() {
        let cam = Fx.camera(10) { i, p in
            p.mtf50CenterMedianCPP = 0.3; p.mtf50OuterMedianCPP = [0.14, 0.165, 0.19][i % 3]
            if i >= 3 { p.edgesOuter = 1 }
        }
        let r = CameraRules.fieldSoftness(cam)
        #expect(r?.grade == .thin)
        #expect(r?.title == "Corners may be softer than the centre")
        #expect(r?.finding.contains("47 %, 55 % and 63 % of the centre") == true)
        #expect(r?.whatWouldChange == "5 photos with straight edges both in the middle and near the corners.")
    }

    @Test func slowShutterWithOneGatedSlowRowIsThin() {
        let cam = Fx.camera(12) { i, p in
            if i == 0 { p.exposureS = 0.1; p.mtf50P80LWPH = 923 }
            else if i < 4 { p.exposureS = 0.1; p.edgesMeasured = 1 }
            else { p.exposureS = 0.004; p.mtf50P80LWPH = 1995 }
        }
        let r = CameraRules.slowShutter(cam)
        #expect(r?.grade == .thin)
        #expect(r?.finding.hasPrefix("4 of your 12 photos were taken at 1/30 s or slower; only 1 had 3 or more usable edges.") == true)
        #expect(r?.actions.allSatisfy { $0.effort == .atCamera } == true)
    }

    @Test func phoneColourLeanHasNoPresetAction() {
        let phone = CameraRules.colourLean(Fx.camera { _, p in p.wbROverGStops = 0.3; p.wbBOverGStops = -0.3 })
        #expect(phone?.actions.contains { $0.effort == .atCamera } == false)
        #expect(phone?.actionTexts.contains { $0.contains("preset") } == false)
        let nikon = CameraRules.colourLean(Fx.camera(model: "D850") { _, p in p.cameraMake = "NIKON CORPORATION"; p.wbROverGStops = 0.3; p.wbBOverGStops = -0.3 })
        #expect(nikon?.actionTexts.first?.contains("white-balance preset") == true)
        #expect(phone?.grade == .moderate)
    }

    @Test func noiseSmoothingCardHasNoTextureAction() {
        let r = CameraRules.noiseCharacter(Fx.camera { _, p in p.noiseWhiteness = 0.5 })
        #expect(r?.actions.allSatisfy { $0.effort == .inEditor } == true)
        #expect(r?.actionTexts.contains { $0.lowercased().contains("iso") } == false)
    }

    @Test func phoneSharpeningHasNoCameraAction() {
        let r = CameraRules.sharpeningCharacter(Fx.camera { _, p in p.overshootMedianPct = 11 })
        #expect(r?.title == "This phone sharpens hard")
        #expect(r?.actions.allSatisfy { $0.effort == .inEditor } == true)
    }

    @Test func everySilentRuleGivesAReasonWithNumbers() {
        // A clean camera: every rule that looks and finds nothing says so, with its numbers.
        let cam = Fx.camera(12) { i, p in
            p.structureHorizonTiltDeg = i.isMultiple(of: 2) ? 0.2 : -0.2
            p.clipHighPct = i == 0 ? 2 : 0.1; p.clipLowPct = i == 0 ? 2 : 0
            p.mtf50CenterMedianCPP = 0.3; p.mtf50OuterMedianCPP = 0.28
            if i == 1 { p.mtf50InfocusCPP = 0.3; p.mtf50BackgroundCPP = 0.1 }
            if i == 2 { p.exposureS = 0.1 }
        }
        let silent = CoachingEngine.results(for: cam).compactMap(\.silentCheck)
        #expect(silent.count >= 7)
        for s in silent { #expect(s.reason.contains { $0.isNumber }, Comment(rawValue: s.text)) }
    }

    @Test func highlightsWithACrossingRangeAreThin() {
        // iPhone XR: 6 of 21 photos over 1 %.
        let r = CameraRules.highlightDiscipline(Fx.camera(21) { i, p in p.clipHighPct = i < 6 ? 2 : 0.2 })
        #expect(r?.grade == .thin)
        #expect(r?.whatWouldChange?.contains("14 to 50 %") == true)
    }
}
