import Testing
import Foundation
@testable import IQCoach

/// Each camera rule names the photos that best show its point. The rules return file names and captions only.
struct ExampleFileTests {
    private func check(_ r: Insight?, files expected: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        guard let r else { Issue.record("rule did not fire", sourceLocation: sourceLocation); return }
        #expect(r.exampleFiles.count <= 4, sourceLocation: sourceLocation)
        #expect(r.exampleCaptions.count == r.exampleFiles.count, sourceLocation: sourceLocation)
        #expect(r.exampleFiles == expected, sourceLocation: sourceLocation)
    }

    @Test func highlightsPicksTheFourMostClipped() {
        let cam = Fx.camera(12) { i, p in p.clipHighPct = Double(i) }
        let r = CameraRules.highlightDiscipline(cam)
        check(r, files: ["p11.jpg", "p10.jpg", "p9.jpg", "p8.jpg"])
        #expect(r?.exampleCaptions.first == "11.0 %")
    }

    @Test func shadowsPicksTheFourMostCrushed() {
        let cam = Fx.camera(12) { i, p in p.clipLowPct = Double(i) }
        check(CameraRules.shadowDiscipline(cam), files: ["p11.jpg", "p10.jpg", "p9.jpg", "p8.jpg"])
    }

    @Test func isoCeilingPicksLowestSNRAboveTheCeiling() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.iso = 50; p.snrMidgreyDB = 38 } else { p.iso = 800; p.snrMidgreyDB = Double(20 + i) }
        }
        let r = CameraRules.isoCeiling(cam)
        check(r, files: ["p6.jpg", "p7.jpg", "p8.jpg", "p9.jpg"])
        #expect(r?.exampleCaptions.first == "26.0 dB")
    }

    @Test func isoCeilingFallsBackToTheCeilingBandWhenNothingIsAbove() {
        let cam = Fx.camera(12) { i, p in p.iso = 50; p.snrMidgreyDB = Double(30 + i) }
        check(CameraRules.isoCeiling(cam), files: ["p0.jpg", "p1.jpg", "p2.jpg", "p3.jpg"])
    }

    @Test func fieldSoftnessPicksLowestOuterToCentreRatios() {
        let cam = Fx.camera(12) { i, p in
            p.mtf50CenterMedianCPP = 0.3
            p.mtf50OuterMedianCPP = 0.3 * (0.2 + 0.04 * Double(i))
        }
        let r = CameraRules.fieldSoftness(cam)
        check(r, files: ["p0.jpg", "p1.jpg", "p2.jpg", "p3.jpg"])
        #expect(r?.exampleCaptions.first?.hasPrefix("0.20") == true)
    }

    @Test func sharpeningPicksRepresentativeOvershoot() {
        // Representative, not extreme (F13): the four closest to the median of 9...20 (14.5).
        let cam = Fx.camera(12) { i, p in p.overshootMedianPct = 9 + Double(i) }
        guard let r = CameraRules.sharpeningCharacter(cam) else { Issue.record("rule did not fire"); return }
        #expect(Set(r.exampleFiles) == ["p4.jpg", "p5.jpg", "p6.jpg", "p7.jpg"])
    }

    @Test func colourLeanPicksLargestLeans() {
        let cam = Fx.camera(12) { i, p in p.wbROverGStops = 0.2 + 0.02 * Double(i); p.wbBOverGStops = -0.02 }
        check(CameraRules.colourLean(cam), files: ["p11.jpg", "p10.jpg", "p9.jpg", "p8.jpg"])
    }

    @Test func slowShutterPicksSoftestSlowFrames() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.exposureS = 1.0 / 15; p.mtf50P80LWPH = 1500 + 100 * Double(i) }
            else { p.exposureS = 0.004; p.mtf50P80LWPH = 3000 }
        }
        check(CameraRules.slowShutter(cam), files: ["p0.jpg", "p1.jpg", "p2.jpg", "p3.jpg"])
    }

    @Test func lensComparisonTakesTwoFromEachEnd() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.lens = "Test Cam back camera 6mm f/1.8"; p.focalMM = 6; p.mtf50P80LWPH = 3000 + Double(i) }
            else { p.lens = "Test Cam back camera 2mm f/2.2"; p.focalMM = 2; p.mtf50P80LWPH = 2000 + Double(i) }
        }
        guard let r = CameraRules.lensComparison(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.exampleFiles.count == 4)
        #expect(r.exampleCaptions.count == 4)
        let sharpLens = Set((0..<6).map { "p\($0).jpg" }), laggard = Set((6..<12).map { "p\($0).jpg" })
        #expect(r.exampleFiles.prefix(2).allSatisfy { sharpLens.contains($0) })
        #expect(r.exampleFiles.suffix(2).allSatisfy { laggard.contains($0) })
    }

    @Test func levelEdgeLeanPicksLargestTiltsOnTheMediansSide() {
        // The median leans right, so the left-leaning p5 is a counter-example and is not shown (F8).
        let cam = Fx.camera(12) { i, p in p.structureHorizonTiltDeg = i == 5 ? -4.0 : 1.5 + 0.1 * Double(i) }
        let r = CameraRules.levelEdgeLean(cam)
        check(r, files: ["p11.jpg", "p10.jpg", "p9.jpg", "p8.jpg"])
        #expect(r?.exampleCaptions.first == "+2.6\u{00B0}")
        let leftCam = Fx.camera(12) { i, p in p.structureHorizonTiltDeg = i == 5 ? 4.0 : -1.5 - 0.1 * Double(i) }
        #expect(CameraRules.levelEdgeLean(leftCam)?.exampleCaptions.first == "\u{2212}2.6\u{00B0}")
    }

    @Test func shallowDepthPicksWidestFocusGap() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.mtf50InfocusCPP = 0.3; p.mtf50BackgroundCPP = 0.05 + 0.03 * Double(i) }
        }
        check(CameraRules.shallowDepthHabit(cam), files: ["p0.jpg", "p1.jpg", "p2.jpg", "p3.jpg"])
    }

    @Test func noiseCharacterPicksRepresentativePhotos() {
        let cam = Fx.camera(12) { i, p in p.noiseWhiteness = 0.1 + 0.01 * Double(i) }
        guard let r = CameraRules.noiseCharacter(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.exampleFiles.count == 4)
        #expect(Set(r.exampleFiles) == ["p4.jpg", "p5.jpg", "p6.jpg", "p7.jpg"])
    }

    @Test func fewerThanFourPhotosGiveFewerExamples() {
        let cam = Fx.camera(5) { i, p in p.clipHighPct = 2 + Double(i) }
        let r = CameraRules.highlightDiscipline(cam)
        #expect(r?.exampleFiles.count == 4)
        let tiny = CameraRules.extremes([Fx.photo(0) { $0.clipHighPct = 3 }], highest: true, value: \.clipHighPct, caption: { Fmt.pct($1, 1) })
        #expect(tiny.files == ["p0.jpg"])
    }
}
