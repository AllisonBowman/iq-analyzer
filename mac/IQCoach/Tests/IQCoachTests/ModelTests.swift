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
