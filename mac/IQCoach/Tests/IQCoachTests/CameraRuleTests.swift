import Testing
import Foundation
@testable import IQCoach

struct CameraRuleTests {
    // 1. ISO ceiling
    @Test func isoCeilingFires() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.iso = 50; p.snrMidgreyDB = 38 } else { p.iso = 800; p.snrMidgreyDB = 27 }
        }
        let r = CameraRules.isoCeiling(cam)
        #expect(r != nil)
        #expect(r?.finding.contains("up to ISO 64") == true)
        #expect(r?.finding.contains("drops to 27.0 dB") == true)
    }
    @Test func isoCeilingCleanEverywhere() {
        let r = CameraRules.isoCeiling(Fx.camera(12) { i, p in p.iso = i < 6 ? 50 : 800; p.snrMidgreyDB = 38 })
        #expect(r?.title == "Noise is clean at every ISO you have used")
    }
    @Test func isoCeilingNeedsData() {
        #expect(CameraRules.isoCeiling(Fx.camera(12) { _, p in p.snrMidgreyDB = nil }) == nil)
    }

    // 2. Noise character
    @Test func noiseCharacterStrong() {
        let r = CameraRules.noiseCharacter(Fx.camera { _, p in p.noiseWhiteness = 0.5 })
        #expect(r?.severity == .notice)
        #expect(r?.finding.contains("strong smoothing") == true)
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
        #expect(r?.actions.first?.contains("ultra-wide") == true)
    }
    @Test func lensComparisonCallsSmallGapsATie() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.lens = "Test Cam back camera 6mm f/1.8"; p.focalMM = 6; p.mtf50P80LWPH = 3000 }
            else { p.lens = "Test Cam back camera 2mm f/2.2"; p.focalMM = 2; p.mtf50P80LWPH = 2800 }
        }
        let r = CameraRules.lensComparison(cam)
        #expect(r?.title == "Your lenses resolve about the same detail")
        #expect(r?.severity == .info)
        #expect(r?.actions.contains { $0.contains("inside the measurement band") } == true)
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
        #expect(r?.actions.contains { $0.contains("-0.3 to -0.7 EV") } == true)
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
        let r = CameraRules.slowShutter(Fx.camera(12) { i, p in
            if i < 5 { p.exposureS = 0.1; p.mtf50P80LWPH = 1800 } else { p.exposureS = 0.004; p.mtf50P80LWPH = 3000 }
        })
        #expect(r?.finding.contains("40 % softer") == true)
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

    // 10. Confidence
    @Test func confidenceFires() {
        let r = CameraRules.sharpnessConfidence(Fx.camera { _, p in p.mtf50MedianCPP = 0.2; p.mtf50MedianCILo = 0.12; p.mtf50MedianCIHi = 0.30 })
        #expect(r?.severity == .info)
        #expect(r?.finding.contains("90 %") == true)
    }
    @Test func confidenceQuiet() {
        #expect(CameraRules.sharpnessConfidence(Fx.camera { _, p in p.mtf50MedianCPP = 0.2; p.mtf50MedianCILo = 0.18; p.mtf50MedianCIHi = 0.22 }) == nil)
    }

    // Engine
    @Test func engineSkipsSmallCameras() {
        #expect(CoachingEngine.insights(for: Fx.camera(4) { _, p in p.overshootMedianPct = 20 }).isEmpty)
        #expect(!CoachingEngine.insights(for: Fx.camera(5) { _, p in p.overshootMedianPct = 20 }).isEmpty)
    }
}
