import Testing
import CoreGraphics
import Foundation
@testable import IQCoach

/// One test (or more) per confirmed app discrepancy in docs/DISCREPANCIES.md. Ids in each test's comment.
struct DiscrepancyFixTests {
    // MARK: Helpers

    /// A phone whose photos sit in ISO bands with the given clean SNR values.
    private func isoCam(_ bands: [(iso: Double, snrs: [Double])], model: String = "Test Cam", phone: Bool = true) -> CameraGroup {
        var photos: [PhotoRecord] = []
        for b in bands {
            for s in b.snrs {
                let n = photos.count
                photos.append(Fx.photo(n, camera: model) { p in
                    p.iso = b.iso; p.snrMidgreyDB = s
                    if !phone { p.cameraMake = "NIKON CORPORATION"; p.lens = "50mm" }
                })
            }
        }
        return CameraGroup(model: model, photos: photos)
    }

    private let mainLens = "Test Cam back camera 6mm f/1.8"
    private let wideLens = "Test Cam back camera 2mm f/2.2"
    private let frontLens = "Test Cam front camera 3mm f/2.2"

    // MARK: Three-edge sharpness gate (F12 [high], APP-01, F1 [high])

    @Test func oneAndTwoEdgeRowsDoNotMoveTheCameraMedian() {
        let cam = Fx.camera(8) { i, p in
            if i >= 5 { p.edgesMeasured = i == 5 ? 1 : 2; p.mtf50P80LWPH = 900; p.mtf50P80CPP = 0.1; p.overshootMedianPct = 40 }
        }
        let s = cam.summary
        #expect(s.sharpnessLWPH == 3000)
        #expect(s.sharpnessCPP == 0.30)
        #expect(s.overshoot == 4)
        #expect(s.sharpnessCounted == 5)
        #expect(s.sharpnessRough == 3)
        #expect(s.sharpnessNone == 0)
        #expect(s.hasSharpnessFigure)
    }

    @Test func fewerThanFiveCountedPhotosShowNotEnough() {
        let cam = Fx.camera(8) { i, p in if i >= 4 { p.edgesMeasured = 1 } }
        let s = cam.summary
        #expect(!s.hasSharpnessFigure)
        #expect(!s.hasOvershootFigure)
        #expect(s.sharpnessCell == "Not enough photos (4)")
        #expect(s.sharpnessCaption.hasPrefix("4 of 8 photos had 3 or more usable edges (median 3,000 LW/PH)"))
        #expect(s.haloCell == "Not enough photos (4)")
    }

    @Test func centreOuterRatioNeedsThreeEdgesInBothRegions() {
        let cam = Fx.camera(8) { i, p in
            p.mtf50CenterMedianCPP = 0.3; p.mtf50OuterMedianCPP = i < 4 ? 0.15 : 0.27
            if i < 4 { p.edgesOuter = 1 }
        }
        #expect(cam.summary.centreOuterCount == 4)
        #expect(abs((cam.summary.centreOuterRatio ?? 0) - 0.9) < 1e-9)
    }

    @Test func photoRowsShowTooFewEdgesInsteadOfABand() {
        let two = Fx.photo { $0.edgesMeasured = 2; $0.mtf50P80CPP = 0.1 }
        #expect(PhotoReading.notCountedText(.sharpnessLWPH, two) == "— · only 2 edges, not enough to count")
        #expect(PhotoReading.band(.sharpnessCPP, two) == nil)
        #expect(PhotoReading.band(.overshoot, two) == nil)
        #expect(PhotoReading.sharpnessText(two) == "— · 2 edges")
        #expect(PhotoReading.sharpnessText(Fx.photo()) == "3,000 LW/PH · Excellent · 6 edges")
        #expect(two.sortSharpness == -1)
    }

    @Test func softAndHaloAdviceNeedThreeEdges() {
        let thin = Fx.photo { $0.edgesMeasured = 2; $0.mtf50P80CPP = 0.1; $0.overshootMedianPct = 20 }
        #expect(EditingRules.soft(thin) == nil)
        #expect(EditingRules.halo(thin) == nil)
        let counted = Fx.photo { $0.edgesMeasured = 3; $0.mtf50P80CPP = 0.1; $0.overshootMedianPct = 20 }
        #expect(EditingRules.soft(counted) != nil)
        #expect(EditingRules.halo(counted) != nil)
    }

    @Test func apertureSweetSpotIgnoresOneEdgeRows() {
        let cam = CameraGroup(model: "D850", photos: (0..<8).map { i in
            Fx.photo(i, camera: "D850", lens: "50mm") { p in
                if i < 4 { p.fNumber = 5.6; p.mtf50P80LWPH = 3500 } else { p.fNumber = 16; p.mtf50P80LWPH = 2500; p.edgesMeasured = 1 }
            }
        })
        #expect(CameraRules.apertureSweetSpot(cam).isEmpty)
    }

    // MARK: Lens comparison leaves out the front camera (F2 [high])

    @Test func lensComparisonExcludesTheFrontCamera() {
        let cam = Fx.camera(18) { i, p in
            switch i {
            case 0..<6: p.lens = mainLens; p.focalMM = 6; p.mtf50P80LWPH = 3000
            case 6..<12: p.lens = wideLens; p.focalMM = 2; p.mtf50P80LWPH = 2800
            default: p.lens = frontLens; p.focalMM = 3; p.mtf50P80LWPH = 1000
            }
        }
        guard let r = CameraRules.lensComparison(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.title == "Your lenses resolve about the same detail")
        #expect(!r.finding.contains("front camera is"))
        #expect(r.finding.contains("Not compared: the front camera (a selfie camera"))
        #expect(!r.actions.contains { $0.contains("front") })
        #expect(r.counted == 12)
    }

    @Test func lensComparisonDropsLensesWithoutThreeEdgeRows() {
        let cam = Fx.camera(12) { i, p in
            if i < 6 { p.lens = mainLens; p.focalMM = 6; p.mtf50P80LWPH = 3000 }
            else { p.lens = wideLens; p.focalMM = 2; p.mtf50P80LWPH = 1000; p.edgesMeasured = 2 }
        }
        #expect(CameraRules.lensComparison(cam) == nil)
        #expect(cam.lenses.first { $0.name == wideLens }?.p80Sharpness == nil)
    }

    // MARK: Slow shutter: back lenses, three-edge gate, no "hand-held" (F3 [high])

    @Test func slowShutterIgnoresFrontCameraAndThinRows() {
        let cam = Fx.camera(14) { i, p in
            switch i {
            case 0..<2: p.lens = frontLens; p.exposureS = 1.0 / 15; p.mtf50P80LWPH = 600
            case 2: p.exposureS = 1.0 / 7; p.mtf50P80LWPH = 1200
            case 3..<5: p.exposureS = 1.0 / 15; p.mtf50P80LWPH = 800; p.edgesMeasured = 1
            default: p.exposureS = 0.004; p.mtf50P80LWPH = 2600
            }
        }
        #expect(CameraRules.slowShutter(cam) == nil)
    }

    @Test func slowShutterComparesWithinALensAndDropsHandHeld() {
        let cam = Fx.camera(12) { i, p in
            if i < 4 { p.exposureS = 0.1; p.mtf50P80LWPH = 1800 } else { p.exposureS = 0.004; p.mtf50P80LWPH = 3000 }
        }
        guard let r = CameraRules.slowShutter(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.finding.contains("40 % softer than faster frames from the same lens"))
        #expect(!r.finding.lowercased().contains("hand-held"))
        #expect(r.counted == 12)
    }

    // MARK: Field softness per lens (F5 [high])

    @Test func fieldSoftnessNamesTheSoftLensNotTheUltraWide() {
        let cam = Fx.camera(12) { i, p in
            p.mtf50CenterMedianCPP = 0.3
            if i < 6 { p.lens = mainLens; p.focalMM = 6; p.mtf50OuterMedianCPP = 0.18 }
            else { p.lens = wideLens; p.focalMM = 2; p.mtf50OuterMedianCPP = 0.28 }
        }
        guard let r = CameraRules.fieldSoftness(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.title == "Corners are softer than the centre on the main camera")
        #expect(r.finding.contains("40 % softer"))
        #expect(r.actions.contains { $0.contains("the ultra-wide camera holds up better") })
        #expect(!r.actions.contains { $0.contains("Avoid the ultra-wide") })
        #expect(r.counted == 6)
    }

    @Test func fieldSoftnessIgnoresSingleOuterEdgeRows() {
        let cam = Fx.camera(8) { _, p in p.mtf50CenterMedianCPP = 0.3; p.mtf50OuterMedianCPP = 0.1; p.edgesOuter = 1 }
        #expect(CameraRules.fieldSoftness(cam) == nil)
    }

    // MARK: Sharpening: gated, five photos, representative examples (F14, F13)

    @Test func sharpeningNeedsFiveGatedPhotos() {
        let cam = Fx.camera(10) { i, p in
            if i < 4 { p.overshootMedianPct = 20 } else { p.overshootMedianPct = 30; p.edgesMeasured = 1 }
        }
        #expect(CameraRules.sharpeningCharacter(cam) == nil)
    }

    @Test func sharpeningExamplesComeFromGatedRows() {
        let cam = Fx.camera(10) { i, p in
            if i < 6 { p.overshootMedianPct = 10 + Double(i) } else { p.overshootMedianPct = 200; p.edgesMeasured = 2 }
        }
        guard let r = CameraRules.sharpeningCharacter(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.exampleFiles.allSatisfy { ["p0.jpg", "p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg", "p5.jpg"].contains($0) })
        #expect(r.counted == 6)
        #expect(r.finding.contains("median over 6 photos with 3 or more usable edges"))
    }

    // MARK: ISO ceiling (APP-02, F4 [high], F6 [high], F13)

    @Test func isoCeilingStopsAtTheFirstBandUnderTheMark() {
        // iPhone 13 in results.json: 33.1, 33.5, 30.5, 35.4, 31.3 dB.
        let cam = isoCam([(50, Array(repeating: 33.07, count: 6)), (100, Array(repeating: 33.52, count: 6)),
                          (250, Array(repeating: 30.54, count: 6)), (640, Array(repeating: 35.37, count: 5)),
                          (2000, Array(repeating: 31.33, count: 5))])
        guard let r = CameraRules.isoCeiling(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.title == "Keep ISO at or below ISO 160 for clean pictures")
        #expect(r.finding.contains("at ISO 161-400 it drops to 30.5 dB"))
        #expect(r.finding.contains("does not simply follow ISO"))
        #expect(!r.why.contains("Higher ISO amplifies"))
        #expect(r.counted == 28)
    }

    @Test func isoCeilingDoesNotCallANonMonotonicCameraCleanEverywhere() {
        // iPhone XR in results.json: 31.99 (<=64), 31.79 (161-400), 35.29 (401-1000).
        let cam = isoCam([(50, Array(repeating: 31.989, count: 6)), (250, Array(repeating: 31.794, count: 6)),
                          (640, Array(repeating: 35.289, count: 6))])
        guard let r = CameraRules.isoCeiling(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.title == "Noise does not follow ISO on this phone")
        #expect(!r.title.contains("clean at every ISO"))
        #expect(r.counted == 18)
    }

    @Test func openEndedBandIsCheckedAtTheHighestISOUsed() {
        // NIKON D850: the >1000 band pools ISO 1100-1400 with one ISO 9000 frame at 29.6 dB.
        let cam = isoCam([(64, [42.5, 42.5, 42.5]), (100, Array(repeating: 39.1, count: 10)), (250, Array(repeating: 37.8, count: 5)),
                          (640, Array(repeating: 35.8, count: 11)), (1100, [34.0]), (1250, [35.0]), (1400, [33.9]), (9000, [29.6])],
                         model: "NIKON D850", phone: false)
        guard let r = CameraRules.isoCeiling(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.title == "Keep ISO at or below ISO \(Fmt.int(1400)) for clean pictures")
        #expect(r.finding.contains("at ISO \(Fmt.int(9000)), the highest you used, the photo measures 29.6 dB"))
        #expect(!r.finding.contains("up to above"))
        #expect(r.exampleCaptions.first == "29.6 dB")
    }

    @Test func cleanEverywhereStatesTheHighestISOActuallyUsed() {
        let cam = isoCam([(50, Array(repeating: 38, count: 4)), (2500, Array(repeating: 36, count: 4))])
        guard let r = CameraRules.isoCeiling(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.title == "Noise is clean at every ISO you have used")
        #expect(r.finding.contains("up to ISO \(Fmt.int(2500)), the highest"))
    }

    @Test func isoExamplesComeOnlyFromCleanRows() {
        var cam = isoCam([(50, Array(repeating: 38, count: 6)), (800, [27, 27, 27, 28])])
        var photos = cam.photos
        photos.append(Fx.photo(99) { $0.iso = 800; $0.snrMidgreyDB = 15; $0.snrMidgreyExtrapolated = true })
        cam = CameraGroup(model: "Test Cam", photos: photos)
        guard let r = CameraRules.isoCeiling(cam) else { Issue.record("rule did not fire"); return }
        #expect(!r.exampleFiles.contains("p99.jpg"))
    }

    // MARK: "Based on n photos" is the true n (F9 [medium evidence-count])

    @Test func countedIsThePhotosTheFindingRestsOn() {
        let cam = Fx.camera(10) { i, p in p.clipHighPct = i < 4 ? 3 : 0 }
        let r = CameraRules.highlightDiscipline(cam)
        #expect(r?.counted == 10)
        #expect(r?.total == 10)
        #expect(r?.countedText == "Counted: 10 of 10 photos")
        let md = MarkdownExport.coaching(for: cam, insights: [r].compactMap { $0 })
        #expect(md.contains("_Counted: 10 of 10 photos._"))
        #expect(!md.contains("Based on"))
    }

    // MARK: Dynamic range lower bounds (APP-07, F7 [high])

    @Test func dynamicRangeIsAtLeastWhenFewFramesReachTheFloor() {
        let cam = Fx.camera(36) { i, p in
            p.drSNR4Stops = i == 0 ? 3.92 : 8.63; p.drSNR4LowerBound = i != 0
        }
        let s = cam.summary
        #expect(s.dynamicRangeIsLowerBound)
        #expect(s.dynamicRange == 8.63)
        #expect(s.dynamicRangePrefix == "At least ")
        #expect(s.drExactCount == 1 && s.drLowerBoundCount == 35)
        #expect(s.dynamicRangeCaption.hasPrefix("Only 1 of 36 photos reached the noise floor (3.9 stops in that frame)"))
    }

    @Test func dynamicRangeIsExactFromFiveFrames() {
        let cam = Fx.camera(20) { i, p in p.drSNR4Stops = i < 5 ? 7.2 : 6.7; p.drSNR4LowerBound = i >= 5 }
        #expect(!cam.summary.dynamicRangeIsLowerBound)
        #expect(cam.summary.dynamicRange == 7.2)
        #expect(cam.summary.dynamicRangePrefix == "")
    }

    // MARK: One SNR scale (APP-03, F11, F23)

    @Test func oneCleanMarkEverywhere() {
        #expect(Metric.snrCleanDB == 32)
        #expect(Metric.snr.band(for: Metric.snrCleanDB) == .good)
        #expect(Metric.snr.band(for: Metric.snrNoisyDB - 0.01) == .poor)
        #expect(Metric.snr.band(for: Metric.snrExcellentDB) == .excellent)
        #expect(Metric.snr.definition.contains("32 dB and up is clean"))
        #expect(Metric.snr.goodLooksLike == "Clean from 32 dB; excellent from 38 dB; visibly noisy below 25 dB.")
        #expect(!Metric.snr.definition.contains("35"))
        #expect(Fx.camera(8).summary.snrCaption.contains("32.0 dB and up is clean"))
        #expect(EditingRules.noisy(Fx.photo { $0.snrMidgreyDB = 24 })?.finding.contains("32.0 dB clean mark") == true)
    }

    // MARK: Sharpness banded on one scale (APP-04)

    @Test func lwphRowTakesThePerPixelBand() {
        // 0.386 c/px on a 3024-px-high frame is 2334 LW/PH: one band, from c/px, for both rows.
        let p = Fx.photo { $0.mtf50P80CPP = 0.386; $0.mtf50P80LWPH = 2334; $0.height = 3024 }
        #expect(PhotoReading.band(.sharpnessLWPH, p) == .excellent)
        #expect(PhotoReading.band(.sharpnessCPP, p) == .excellent)
        #expect(Metric.sharpnessLWPH.goodLooksLike.contains("No band of its own"))
    }

    // MARK: LW/PH definition has the factor 2 (F13 [medium], APP-12, F15)

    @Test func lwphDefinitionHasTheFactorTwo() {
        #expect(Metric.sharpnessLWPH.definition.contains("two times the c/px figure times the picture height"))
        #expect(!Metric.sharpnessLWPH.definition.contains("LW/PH is line widths per picture height: the c/px figure times"))
    }

    // MARK: Clipping overlay (CLIP-3) and wording (CLIP-4, APP-14, CLIP-5)

    private func p3Image(_ rgb: (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes: [UInt8] = []
        for _ in 0..<16 { bytes += [rgb.0, rgb.1, rgb.2, 255] }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                       space: CGColorSpace(name: CGColorSpace.displayP3)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func maskIsDrawnInTheImagesOwnColourSpace() throws {
        // A saturated P3 red is not clipped in the file's own encoding, but leaves sRGB's gamut (red channel 255).
        let img = p3Image((240, 40, 40))
        var srgb = [UInt8](repeating: 0, count: 4)
        srgb.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(srgb[0] >= ClippingMask.highThreshold, "sanity: in sRGB this colour is gamut-clipped")
        let m = try #require(ClippingMask.make(from: img))
        #expect(m.highCount == 0)
        #expect((ClippingMask.classificationSpace(for: img)?.name as String?) == (CGColorSpace.displayP3 as String))
        let white = try #require(ClippingMask.make(from: p3Image((255, 250, 250))))
        #expect(white.highCount == 16)
    }

    @MainActor @Test func clippingCaptionSaysPreviewAndFullResolution() {
        let c = OverlayImage.caption(for: .clipping, photo: Fx.photo { $0.clipHighPct = 1.117; $0.clipLowPct = 0.2 }, hasSalientBox: false) ?? ""
        #expect(c.contains("800 px preview"))
        #expect(c.contains("the figures are the analyzer's, on the full-resolution file: 1.12 % blown"))
    }

    @Test func clippingIsNotCalledPureWhite() {
        let cam = Fx.camera(10) { i, p in p.clipHighPct = i < 4 ? 3 : 0 }
        let texts = [Metric.highlightClip.shortMeaning,
                     EditingRules.blownHighlights(Fx.photo { $0.clipHighPct = 2 })?.finding ?? "",
                     CameraRules.highlightDiscipline(cam)?.finding ?? "",
                     CameraRules.highlightDiscipline(cam)?.why ?? "",
                     cam.summary.clipCaption ?? ""]
        for t in texts {
            #expect(!t.contains("pure white"), Comment(rawValue: t))
            #expect(t.contains("channel"), Comment(rawValue: t))
        }
    }

    @Test func clippingTileSaysWhatItsBandGrades() {
        let s = Fx.camera(10) { i, p in p.clipHighPct = i < 4 ? 3 : 0.2 }.summary
        #expect(s.clipCaption?.contains("The band grades the typical photo") == true)
        #expect(s.clipCaption?.contains("40 % of photos (4) lose more than 1 %") == true)
    }

    // MARK: Whiteness cut-offs and the noise-character rule (APP-09, APP-10, F12 [medium])

    @Test func whitenessCutOffsMatchTheAnalyzer() {
        #expect(Metric.whiteness.goodLooksLike == "0.14 is white grain; 0.3 and up smoothed; 0.4 and up heavily smoothed; above 0.7 texture, not noise.")
        #expect(Metric.whiteness.definition.contains("0.4 and up heavily"))
        #expect(Metric.whitenessHeavy == 0.4)
    }

    @Test func noiseCharacterReadsAboveISO160() {
        // High whiteness at base ISO is the low-noise texture confound; above ISO 160 the noise is near white.
        let cam = Fx.camera(16) { i, p in
            if i < 10 { p.iso = 50; p.noiseWhiteness = 0.47 } else { p.iso = 800; p.noiseWhiteness = 0.2 }
        }
        guard let r = CameraRules.noiseCharacter(cam) else { Issue.record("rule did not fire"); return }
        #expect(r.title == "Noise is left as fine grain")
        #expect(r.finding.contains("above ISO 160"))
        #expect(r.counted == 6)
    }

    @Test func strongSmoothingCardDropsKeepISOLow() {
        let r = CameraRules.noiseCharacter(Fx.camera { _, p in p.noiseWhiteness = 0.45 })
        #expect(r?.title == "Strong noise smoothing can soften fine texture")
        #expect(r?.actions.contains { $0.contains("Keep ISO low") } == false)
        #expect(r?.finding.contains("at higher ISO") == false)
        let moderate = CameraRules.noiseCharacter(Fx.camera { _, p in p.noiseWhiteness = 0.35 })
        #expect(moderate?.finding.contains("or scene texture") == true)
        #expect(moderate?.finding.contains("white noise is 0.14") == true)
    }

    // MARK: One visible-halo mark (APP-11, F11)

    @Test func oneVisibleHaloMark() {
        #expect(Metric.overshoot.band(for: Metric.overshootHaloPct) == .poor)
        #expect(EditingRules.halo(Fx.photo { $0.overshootMedianPct = 12 }) != nil)
        #expect(EditingRules.halo(Fx.photo { $0.overshootMedianPct = 11.9 }) == nil)
        #expect(Fx.camera(8).summary.overshootCaption.contains("12 % and up is a visible halo"))
        let fair = CameraRules.sharpeningCharacter(Fx.camera { _, p in p.overshootMedianPct = 10 })
        #expect(fair?.finding.contains("from 12 % it shows as a visible halo") == true)
        let halo = CameraRules.sharpeningCharacter(Fx.camera { _, p in p.overshootMedianPct = 13 })
        #expect(halo?.finding.contains("which shows as a visible halo") == true)
    }

    // MARK: Colour lean tile (APP-13)

    @Test func cameraColourLeanIsLabelledAndUnbanded() {
        let s = Fx.camera(8) { _, p in p.wbROverGStops = 0.04; p.wbBOverGStops = -0.17 }.summary
        #expect(s.leanCell == "0.2 stops")
        #expect(s.leanCaption.hasPrefix("Larger of the median R/G (0.04) and median B/G (-0.17) over 8 photos"))
        #expect(Metric.whiteBalance.definition.contains("A photo's lean is the larger of |R/G| and |B/G|"))
    }

    // MARK: p80 on shallow-depth-of-field frames (APP-15)

    @Test func softAdviceIsSuppressedWhenTheSharpGroupIsSharp() {
        let split = Fx.photo { $0.mtf50P80CPP = 0.17; $0.mtf50InfocusCPP = 0.29; $0.mtf50BackgroundCPP = 0.1 }
        #expect(EditingRules.soft(split) == nil)
        let softSplit = Fx.photo { $0.mtf50P80CPP = 0.12; $0.mtf50InfocusCPP = 0.15; $0.mtf50BackgroundCPP = 0.05 }
        #expect(EditingRules.soft(softSplit) != nil)
    }

    // MARK: Structure wording (APP-05, F9 [medium range], APP-21, APP-16, F8 [medium], APP-20)

    @Test func thirdsDistanceUsesCentreToThirdsUnits() {
        let a = EditingRules.thirdsCrop(Fx.photo { $0.structureThirdsDistance = 0.93; $0.structureFocusFraction = 0.2 })
        #expect(a?.finding.hasPrefix("The subject sits 0.93 from the nearest rule-of-thirds point (0 is on the point, 1 is the frame centre)") == true)
        #expect(a?.finding.contains("diagonal") == false)
        #expect(Structure.thirdsDefinition.contains("at most about 1.4"))
        #expect(!Structure.thirdsDefinition.contains("about 2"))
    }

    @Test func levelEdgeDefinitionIsTheWeightedMedian() {
        #expect(Structure.horizonDefinition.contains("length-weighted median tilt of the long nearly level edges"))
        #expect(!Structure.horizonDefinition.contains("longest"))
    }

    @Test func levelEdgeCardCountsBothSidesAndClaimsAHabitOnlyWhenLopsided() {
        // iPhone 13: 15 left, 7 right at a degree or more (sign test p about 0.13): not a habit.
        let mixed = Fx.camera(26) { i, p in p.structureHorizonTiltDeg = i < 15 ? -2.5 : (i < 22 ? 1.5 : -0.3) }
        guard let r = CameraRules.levelEdgeLean(mixed) else { Issue.record("rule did not fire"); return }
        #expect(r.title == "Your level edges lean left by 2.5°")
        #expect(r.finding.contains("15 lean left and 7 lean right by a degree or more"))
        #expect(r.why.contains("not lopsided enough to call it a habit"))
        #expect(r.severity == .info)
        #expect(!r.title.contains("horizon"))
        #expect(abs(CameraRules.signTestP(15, 7) - 0.1338) < 0.001)
        let lopsided = CameraRules.levelEdgeLean(Fx.camera(12) { _, p in p.structureHorizonTiltDeg = -2 })
        #expect(lopsided?.severity == .notice)
        #expect(lopsided?.why.contains("unlikely to be chance") == true)
    }

    @Test func visionHorizonIsLabelledAsVisions() {
        var s = ContentSummary(available: true)
        s.horizonDegrees = 6.4
        #expect(s.summaryLine == "Vision horizon 6.4° off level")
    }

    // MARK: Noise validity on the photo screen (APP-06, NEW-2)

    @Test func noiseAdviceNeedsACleanReading() {
        let texture = Fx.photo { $0.snrMidgreyDB = 19.4; $0.noiseTextureSuspect = true; $0.noiseWhiteness = 0.93 }
        let extrapolated = Fx.photo { $0.snrMidgreyDB = 25.4; $0.snrMidgreyExtrapolated = true }
        #expect(EditingRules.noisy(texture) == nil)
        #expect(EditingRules.noisy(extrapolated) == nil)
        #expect(EditingRules.noisy(Fx.photo { $0.snrMidgreyDB = 25.4 }) != nil)
        #expect(PhotoReading.band(.snr, texture) == nil)
        #expect(PhotoReading.noiseNote(texture)?.contains("texture or heavy smoothing") == true)
        #expect(PhotoReading.noiseNote(extrapolated)?.contains("extrapolated") == true)
        #expect(PhotoReading.snrText(extrapolated) == "25.4 dB · not counted")
        #expect(PhotoReading.noiseNote(Fx.photo()) == nil)
    }

    @Test func periodicWordingAllowsForTheMinorityRule() {
        let p = Fx.photo { $0.noisePeriodicSuspect = true }
        #expect(PhotoReading.noiseNote(p)?.contains("Where it covered a minority of them it was removed before measuring") == true)
        #expect(EditingRules.moire(p)?.finding.contains("Where it covered a minority of them it was removed") == true)
        #expect(EditingRules.moire(p)?.finding.contains("reflects the pattern rather than the sensor") == false)
    }

    // MARK: Black Point direction (NEW-4)

    @Test func blackPointMovesOppositeWaysForOppositeProblems() {
        #expect(EditingRules.crushedShadows(Fx.photo { $0.clipLowPct = 1 })?.apple.contains("lower Black Point") == true)
        #expect(EditingRules.flatTones(Fx.photo { $0.tonalRangeStops = 6 })?.apple.contains("raise Black Point") == true)
    }

    // MARK: p80 interval replaces the median-MTF50 confidence card (F10)

    @Test func p80RangeComesFromTheP80Interval() throws {
        let p = Fx.photo { $0.mtf50P80CPP = 0.25; $0.mtf50P80CILo = 0.22; $0.mtf50P80CIHi = 0.31
            $0.mtf50MedianCPP = 0.2; $0.mtf50MedianCILo = 0.1; $0.mtf50MedianCIHi = 0.3 }
        #expect(abs((p.p80RelativeWidth ?? 0) - 0.36) < 1e-9)
        let r = try #require(p.p80RangeLWPH)
        #expect(abs(r.lowerBound - 2 * 0.22 * 3024) < 1e-6 && abs(r.upperBound - 2 * 0.31 * 3024) < 1e-6)   // short side
        let s = Fx.camera(8) { _, q in q.mtf50P80CILo = 0.22; q.mtf50P80CIHi = 0.31; q.mtf50P80CPP = 0.25 }.summary
        #expect(s.sharpnessCaption.contains("95 % range typically 36 % of its value wide"))
    }

    @Test func decodesTheNewColumns() throws {
        let json = #"[{"file":"a.jpg","edges_measured":4,"edges_center":3,"edges_outer":1,"mtf50_p80_ci_lo_cpp":0.2,"mtf50_p80_ci_hi_cpp":NaN,"clip_gamut_pct":1.9}]"#
        let p = try PhotoRecord.decodeAll(from: Data(json.utf8))[0]
        #expect(p.edgesMeasured == 4 && p.edgesCenter == 3 && p.edgesOuter == 1)
        #expect(p.mtf50P80CILo == 0.2 && p.mtf50P80CIHi == nil)
        #expect(p.clipGamutPct == 1.9)
        #expect(p.hasSharpnessFigure)
    }

    // MARK: Camera captures only (app-camera-photos-includes-non-camera-image)

    @Test func aCaptureNeedsACameraModelAndFiveMegapixels() {
        #expect(PhotosImporter.isCapture(cameraModel: "iPhone 17 Pro Max", width: 4032, height: 3024))
        #expect(!PhotosImporter.isCapture(cameraModel: nil, width: 4032, height: 3024))
        #expect(!PhotosImporter.isCapture(cameraModel: "  ", width: 4032, height: 3024))
        #expect(!PhotosImporter.isCapture(cameraModel: "iPhone 13", width: 1320, height: 2346))
    }

    // MARK: Snapshot picks a photo whose file exists (CLIP-6)

    @Test func snapshotCandidatesHaveFiles() {
        let photos = [Fx.photo(0) { $0.path = "/gone/a.jpg"; $0.clipHighPct = 14.7 },
                      Fx.photo(1) { $0.path = "/here/b.jpg"; $0.clipHighPct = 2 },
                      Fx.photo(2) { $0.path = nil; $0.clipHighPct = 20 }]
        let c = SnapshotRunner.clippedCandidates(photos, exists: { $0.hasPrefix("/here") })
        #expect(c.map(\.file) == ["p1.jpg"])
        #expect(SnapshotRunner.clippedCandidates(photos, exists: { _ in false }).isEmpty)
    }
}

/// The fixes checked against the analyzer's own numbers on results/results.json (IQA_RESULTS), when it is given.
struct RepoResultsFixTests {
    private func library() throws -> PhotoLibrary? {
        guard let path = ProcessInfo.processInfo.environment["IQA_RESULTS"], !path.isEmpty else { return nil }
        return PhotoLibrary(sourceName: "results.json", photos: try PhotoRecord.decodeAll(from: Data(contentsOf: URL(fileURLWithPath: path))))
    }

    @Test func cameraFiguresMatchReportPy() throws {
        guard let lib = try library() else { return }
        let pro = try #require(lib.camera("iPhone 17 Pro Max"))
        #expect(pro.summary.sharpnessCounted == 43)
        // report.md "By camera" 0.252 (43); LW/PH on the short side, FINDINGS §2: 1966.
        #expect(abs((pro.summary.sharpnessLWPH ?? 0) - 1966) < 1)
        #expect(abs((pro.summary.sharpnessCPP ?? 0) - 0.252) < 0.001)
        let d850 = try #require(lib.camera("NIKON D850"))
        #expect(d850.summary.sharpnessCounted == 1)
        #expect(!d850.summary.hasSharpnessFigure)
        #expect(d850.summary.dynamicRangeIsLowerBound)
        #expect(abs((d850.summary.dynamicRange ?? 0) - 8.6) < 0.1)
        let xr = try #require(lib.camera("iPhone XR"))
        #expect(xr.summary.sharpnessCounted == 3)
        #expect(!xr.summary.hasSharpnessFigure)
    }

    @Test func coachingCardsMatchTheGatedData() throws {
        guard let lib = try library() else { return }
        let pro = try #require(lib.camera("iPhone 17 Pro Max"))
        #expect(CameraRules.slowShutter(pro) == nil)
        let lens = CameraRules.lensComparison(pro)
        #expect(lens?.finding.contains("front camera is") != true)
        #expect(lens?.evidence.contains { $0.metric.contains("front") } != true)
        let xr = try #require(lib.camera("iPhone XR"))
        #expect(CameraRules.isoCeiling(xr)?.title != "Noise is clean at every ISO you have used")
        let i13 = try #require(lib.camera("iPhone 13"))
        #expect(CameraRules.isoCeiling(i13)?.title == "Keep ISO at or below ISO 160 for clean pictures")
        let d850 = try #require(lib.camera("NIKON D850"))
        #expect(CameraRules.isoCeiling(d850)?.title != "Noise is clean at every ISO you have used")
        #expect(CameraRules.sharpeningCharacter(d850) == nil)
    }
}
