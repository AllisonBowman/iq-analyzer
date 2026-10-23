import Testing
import Foundation
@testable import IQCoach

struct ModelTests {
    @Test func sharpnessBandBoundaries() {
        // One scale only (APP-04): LW/PH is capped by the picture height, so it carries no band of its own.
        #expect(Metric.sharpnessLWPH.band(for: 1000) == nil)
        #expect(Metric.sharpnessLWPH.band(for: 5000) == nil)
        #expect(Metric.sharpnessCPP.band(for: 0.1199) == .poor)
        #expect(Metric.sharpnessCPP.band(for: 0.12) == .fair)
        #expect(Metric.sharpnessCPP.band(for: 0.20) == .good)
        #expect(Metric.sharpnessCPP.band(for: 0.30) == .excellent)
    }
    @Test func snrBandBoundaries() {
        #expect(Metric.snr.band(for: 24.9) == .poor)
        #expect(Metric.snr.band(for: 25) == .fair)
        #expect(Metric.snr.band(for: 32) == .good)
        #expect(Metric.snr.band(for: 38) == .excellent)
    }
    @Test func lowerIsBetterBands() {
        for m in [Metric.highlightClip, .shadowClip] {
            #expect(m.band(for: 0.0999) == .excellent)
            #expect(m.band(for: 0.1) == .good)
            #expect(m.band(for: 0.5) == .fair)
            #expect(m.band(for: 2) == .poor)
        }
        #expect(Metric.overshoot.band(for: 2.99) == .excellent)
        #expect(Metric.overshoot.band(for: 3) == .good)
        #expect(Metric.overshoot.band(for: 8) == .fair)
        #expect(Metric.overshoot.band(for: 11.99) == .fair)
        #expect(Metric.overshoot.band(for: 12) == .poor)
        #expect(Metric.whiteBalance.band(for: 0.1) == .good)
        #expect(Metric.whiteBalance.band(for: 0.2) == .fair)
        #expect(Metric.whiteBalance.band(for: 0.4) == .poor)
    }
    @Test func informationalMetricsHaveNoBand() {
        #expect(Metric.whiteness.band(for: 0.3) == nil)
        #expect(Metric.dynamicRange.band(for: 8) == nil)
    }
    @Test func isoBands() {
        #expect(ISOBand.band(for: 64) == .upTo64)
        #expect(ISOBand.band(for: 65) == .to160)
        #expect(ISOBand.band(for: 400) == .to400)
        #expect(ISOBand.band(for: 401) == .to1000)
        #expect(ISOBand.band(for: 1001) == .above1000)
    }
    @Test func decoderAcceptsNaNAndNull() throws {
        let json = #"[{"file":"a.jpg","camera_model":"X","iso":100.0,"mtf50_p80_lwph":NaN,"snr_midgrey_db":null,"edges":[]}]"#
        let rows = try PhotoRecord.decodeAll(from: Data(json.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].mtf50P80LWPH == nil)
        #expect(rows[0].snrMidgreyDB == nil)
        #expect(rows[0].iso == 100)
        #expect(rows[0].lens == nil)
    }
    @Test func exifDateParses() {
        #expect(PhotoRecord(file: "a", datetime: "2025:01:19 11:40:16").date != nil)
    }
    @Test func decodesRepoResults() throws {
        guard let path = ProcessInfo.processInfo.environment["IQA_RESULTS"], !path.isEmpty else { return }
        let rows = try PhotoRecord.decodeAll(from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(rows.count == 389)
        let lib = PhotoLibrary(sourceName: "results.json", photos: rows)
        #expect(lib.cameras.count == 19)
        #expect(rows.contains { $0.mtf50CenterMedianCPP == nil })
        #expect(rows.allSatisfy { $0.snrMidgreyDB?.isNaN != true })
    }
}

/// Step 1 of the feedback-layers spec: gates, the p80 range, edge reasons, provenance.
struct ModelGateTests {
    @Test func oneEdgeRowIsLeftOutOfCameraAndLensMedians() {
        let cam = Fx.camera(6) { i, p in if i == 0 { p.edgesMeasured = 1; p.mtf50P80LWPH = 500 } }
        #expect(cam.summary.sharpnessLWPH == 3000)
        #expect(cam.summary.sharpnessCounted == 5)
        #expect(cam.lenses.first?.p80Sharpness == 3000)
        #expect(cam.lenses.first?.sharpnessCount == 5)
    }

    @Test func rejectReasonsParseAndKeepUnknownKeysRaw() {
        let p = Fx.photo { $0.edgesRejectReasons = "plateau_noise=2;shading=1;wobble=3;error=0" }
        let r = p.rejectReasons
        #expect(r.count == 3)
        #expect(r[0].reason == .other("wobble") && r[0].count == 3)
        #expect(r[0].reason.words == "wobble")
        #expect(r[1].reason.words == "too noisy on either side" && r[1].count == 2)
        #expect(r[2].reason == .shading)
        #expect(Fx.photo().rejectReasons.isEmpty)
    }

    @Test func p80RangeUsesTheShortSide() throws {
        let p = Fx.photo { $0.width = 5712; $0.height = 4284; $0.mtf50P80CILo = 0.2; $0.mtf50P80CIHi = 0.25 }
        let r = try #require(p.p80RangeLWPH)
        #expect(abs(r.lowerBound - 2 * 0.2 * 4284) < 1e-6)
        #expect(abs(r.upperBound - 2 * 0.25 * 4284) < 1e-6)
    }

    @Test func photoKeySeparatesRepeatedNames() {
        let a = Fx.photo(1) { $0.datetime = "2026:01:01 10:00:00" }, b = Fx.photo(1) { $0.datetime = "2026:01:02 10:00:00" }
        #expect(a.key.rawValue == "Test Cam|p1.jpg|2026:01:01 10:00:00")
        #expect(a.key != b.key)
    }

    @Test func followsISOAllowsOneDecibel() {
        func cam(_ snrs: [Double]) -> CameraGroup {
            let isos: [Double] = [50, 100, 250, 640, 2000]
            return Fx.camera(snrs.count * 3) { i, p in p.iso = isos[i / 3]; p.snrMidgreyDB = snrs[i / 3] }
        }
        #expect(cam([42.5, 39.1, 37.8, 35.8, 33.9]).summary.snrFollowsISO == true)
        #expect(cam([33.6, 32.0, 36.7]).summary.snrFollowsISO == false)
        #expect(cam([33.0, 33.9]).summary.snrFollowsISO == true)
        #expect(cam([33.0]).summary.snrFollowsISO == nil)
    }

    @Test func realDataGatesMatchTheFile() throws {
        guard let lib = try RealData.library() else { return }
        let pro = try #require(lib.camera("iPhone 17 Pro Max"))
        #expect(pro.summary.sharpnessCounted == 43)
        #expect(abs((pro.summary.sharpnessLWPH ?? 0) - 1966) < 1)
        let i13 = try #require(lib.camera("iPhone 13"))
        #expect(i13.summary.sharpnessCounted == 20)
        #expect(abs((i13.summary.sharpnessLWPH ?? 0) - 1861) < 1)
        let xr = try #require(lib.camera("iPhone XR"))
        #expect(!xr.summary.hasSharpnessFigure)
        #expect(xr.summary.sharpnessCell == "Not enough photos (3)")
        let d850 = try #require(lib.camera("NIKON D850"))
        #expect(d850.summary.dynamicRangeIsLowerBound && d850.summary.drExactCount == 1)
        #expect(d850.summary.dynamicRangePrefix + Metric.dynamicRange.format(d850.summary.dynamicRange ?? 0) == "At least 8.6 stops")
        #expect(lib.hasNativeClipping)
        #expect(lib.hasStructure)
        #expect(pro.summary.formats == ["jpeg": 181, "heic": 25])
        #expect(d850.summary.snrFollowsISO == true)
        #expect(pro.summary.snrFollowsISO == false && i13.summary.snrFollowsISO == false && xr.summary.snrFollowsISO == false)
    }
}

/// Shared components and "How sure" (spec §7 step 6).
struct HowSureTests {
    @Test func measuredValueKeepsItsQualifier() {
        #expect(MeasuredValue.text(.dynamicRange, 8.63, qualifier: .atLeast) == "At least 8.6 stops")
        #expect(MeasuredValue.text(.sharpnessLWPH, 900, qualifier: .notCounted, edges: 1) == "— · 1 edge")
        #expect(MeasuredValue.text(.sharpnessLWPH, 3768.9, edges: 27) == "3,769 LW/PH · 27 edges")
        let one = Fx.photo { $0.edgesMeasured = 1 }
        #expect(MeasuredValue.photoText(.sharpnessLWPH, one) == ("— · 1 edge", false))
        #expect(MeasuredValue.photoText(.dynamicRange, Fx.photo { $0.drSNR4Stops = 8.63; $0.drSNR4LowerBound = true }).text == "At least 8.6 stops")
    }

    @Test func pluralsAreRight() {
        #expect(Fmt.count(4, "lens") == "4 lenses")
        #expect(Fmt.count(1, "lens") == "1 lens")
        #expect(Fmt.count(2, "photo") == "2 photos")
        #expect(Fmt.count(3, "candidate edge") == "3 candidate edges")
    }

    @Test func everyMetricSaysHowSure() {
        for m in Metric.allCases { #expect(!m.howSure.isEmpty, Comment(rawValue: m.rawValue)) }
        #expect(!Structure.levelEdgeHowSure.isEmpty)
        #expect(Metric.highlightClip.howSure.contains("file's own encoding"))
    }

    @Test func cameraEvidenceTextNamesItsCount() throws {
        let s = Fx.camera(8).summary
        #expect(Metric.sharpnessLWPH.evidenceText(camera: s)?.hasPrefix("3,000 LW/PH is the median of 8 of 8 photos with 3 or more usable edges; the middle half lies between 3,000 and 3,000") == true)
        guard let lib = try RealData.library(), let pro = lib.camera("iPhone 17 Pro Max") else { return }
        let t = try #require(Metric.sharpnessLWPH.evidenceText(camera: pro.summary))
        #expect(t.hasPrefix("1,966 LW/PH is the median of 43 of 206 photos with 3 or more usable edges; the middle half lies between"))
    }
}

struct MethodTests {
    @Test func methodTextHasTheStandardAndEveryEvidenceWord() {
        #expect(Method.text.contains("ISO 12233"))
        for g in EvidenceGrade.allCases { #expect(Method.text.contains(g.definition)) }
        for e in Effort.allCases { #expect(Method.text.contains(e.definition)) }
        #expect(Method.text.contains("Newcombe"))
        #expect(Method.measurements.count == 8)
    }

    @Test func libraryCellsCarryTheirCounts() throws {
        #expect(Fx.camera(8).summary.sharpnessCellWithCount == "3,000 LW/PH · Excellent (8)")
        #expect(CoachingEngine.oneThingLine(for: Fx.camera(3)) == "Coaching starts at 5 photos")
        guard let lib = try RealData.library() else { return }
        #expect(lib.coachedCameras.count == 8 && lib.sparseCameras.count == 11)
        #expect(lib.camera("iPhone 17 Pro Max")?.summary.sharpnessCellWithCount == "1,966 LW/PH · Good (43)")
        #expect(lib.camera("NIKON D850")?.summary.sharpnessCellWithCount == "Not enough photos (1)")
    }
}
