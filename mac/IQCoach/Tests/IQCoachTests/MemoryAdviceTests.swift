import Testing
import Foundation
@testable import IQCoach

/// Resting cameras and "this photo against your usual" (docs/MEMORY-SPEC.md §8 items 1 and 2).
struct MemoryAdviceTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let last = Date(timeIntervalSince1970: 1_783_512_000)   // 2026-07-08 12:00 UTC

    private func now(plus days: Int) -> Date { utc.date(byAdding: .day, value: days, to: last)! }

    @Test(arguments: [(0, CameraFreshness.active), (89, .active), (90, .active), (91, .resting), (365, .resting), (366, .dormant), (2_000, .dormant)])
    func freshnessBoundaries(_ days: Int, _ state: CameraFreshness) {
        #expect(CameraFreshness.days(from: last, to: now(plus: days), calendar: utc) == days)
        #expect(CameraFreshness(lastDate: last, now: now(plus: days), calendar: utc) == state)
        #expect(CameraFreshness.state(days: days) == state)
    }

    @Test func freshnessNeedsADatedPhotoAndIgnoresTheFuture() {
        #expect(CameraFreshness(lastDate: nil) == nil)
        #expect(CameraFreshness(lastDate: now(plus: 5), now: last, calendar: utc) == .active)
        #expect(CameraFreshness.days(from: now(plus: 5), to: last, calendar: utc) == 0)
    }

    @Test func theBannerSaysWhenAndThatTheAdviceIsFromThosePhotos() throws {
        #expect(CameraFreshness.banner(camera: "iPhone 13", lastDate: last, now: now(plus: 90), calendar: utc) == nil)
        let b = try #require(CameraFreshness.banner(camera: "iPhone 13", lastDate: last, now: now(plus: 110), calendar: utc))
        #expect(b == "You haven't shot with the iPhone 13 since \(Fmt.date(last)) (110 days). This advice comes from those photos; a new photo from this camera brings it up to date.")
        #expect(CameraFreshness.resting.tag == "Resting" && CameraFreshness.dormant.tag == "Dormant" && CameraFreshness.active.tag == nil)
    }

    @Test func freshnessDoesNotChangeTheCoaching() {
        let recent = Fx.camera(12) { i, p in p.clipHighPct = i < 4 ? 3 : 0.1; p.datetime = "2026:10:20 12:00:00" }
        let old = Fx.camera(12) { i, p in p.clipHighPct = i < 4 ? 3 : 0.1; p.datetime = "2024:01:20 12:00:00" }
        #expect(old.freshness() == .dormant && recent.freshness() == .active)
        #expect(CoachingEngine.output(for: old).oneThing?.insight?.id == CoachingEngine.output(for: recent).oneThing?.insight?.id)
    }

    // MARK: Against your usual

    /// The photo plus `values.count` other photos of one camera.
    private func camera(photo edit: (inout PhotoRecord) -> Void, others values: [Double], set: (inout PhotoRecord, Double) -> Void) -> (PhotoRecord, CameraGroup) {
        let photo = Fx.photo(999, edit)
        let others = values.enumerated().map { i, v in Fx.photo(i) { set(&$0, v) } }
        return (photo, CameraGroup(model: "Test Cam", photos: others + [photo]))
    }

    private func line(_ m: UsualComparison.Measure, _ photo: PhotoRecord, _ cam: CameraGroup) -> UsualComparison? {
        UsualComparison.lines(for: photo, camera: cam).first { $0.measure == m }
    }

    @Test func midRankCountsTiesAsHalf() {
        let v = (1...20).map(Double.init)
        #expect(UsualComparison.midRankPercentile(18.5, among: v) == 90)
        #expect(UsualComparison.midRankPercentile(18, among: v) == 87.5)
        #expect(UsualComparison.midRankPercentile(5, among: Array(repeating: 5, count: 30)) == 50)
    }

    @Test(arguments: [(18.5, true), (17.5, false), (19.0, true), (18.0, false), (2.5, true), (3.5, false)])
    func highlightsAreSaidOnlyOutsideTheBand(_ x: Double, _ shown: Bool) {
        let (p, cam) = camera(photo: { $0.clipHighPct = x }, others: (1...20).map(Double.init)) { $0.clipHighPct = $1 }
        #expect((line(.highlights, p, cam) != nil) == shown)
    }

    @Test func theHighlightsSentence() throws {
        let (p, cam) = camera(photo: { $0.clipHighPct = 2.2 }, others: (0..<205).map { Double($0) / 100 }) { $0.clipHighPct = $1 }
        let l = try #require(line(.highlights, p, cam))
        #expect(l.high && l.others == 205)
        #expect(l.text == "More blown highlights than 100 % of your other 205 Test Cam photos (2.2 % of the frame).")
        let (q, cam2) = camera(photo: { $0.clipHighPct = 0 }, others: (1...40).map(Double.init)) { $0.clipHighPct = $1 }
        #expect(line(.highlights, q, cam2)?.text == "Fewer blown highlights than 100 % of your other 40 Test Cam photos (0.0 % of the frame).")
    }

    @Test func frameShares() {
        #expect(UsualComparison.frameText(2.2) == "2.2 %")
        #expect(UsualComparison.frameText(0.04) == "0.04 %")
        #expect(UsualComparison.frameText(0.0004) == "under 0.01 %")
        #expect(UsualComparison.frameText(0) == "0.0 %")
        #expect(UsualComparison.shareText(99.9) == "99 %")
    }

    @Test func fewerThanTwentyOthersStaySilent() {
        let (p, cam) = camera(photo: { $0.clipHighPct = 50; $0.clipLowPct = 50; $0.snrMidgreyDB = 60 }, others: (1...19).map(Double.init)) {
            $0.clipHighPct = $1; $0.clipLowPct = $1; $0.snrMidgreyDB = 30 + $1 / 10
        }
        #expect(UsualComparison.lines(for: p, camera: cam).isEmpty)
    }

    @Test func tiesAtTheTypicalValueStaySilent() {
        // Most photos clip nothing: a photo that clips nothing is ordinary, not "fewer than 90 %".
        let (p, cam) = camera(photo: { $0.clipLowPct = 0 }, others: Array(repeating: 0, count: 30) + [1, 2]) { $0.clipLowPct = $1 }
        #expect(line(.shadows, p, cam) == nil)
    }

    @Test func tiesAreNotCountedAsFewer() {
        // 5 others clip nothing like this photo, 20 clip 0.2 ... 2.1 %: the median (0.9 %) is material and the
        // mid-rank percentile is 10, but only 20 of 25 (80 %) clip more. The line never says "90 %".
        let others = Array(repeating: 0.0, count: 5) + (0..<20).map { 0.2 + Double($0) / 10 }
        let (p, cam) = camera(photo: { $0.clipHighPct = 0 }, others: others) { $0.clipHighPct = $1 }
        #expect(UsualComparison.midRankPercentile(0, among: others) == 10)
        #expect(UsualComparison.strictShare(0, among: others, high: false) == 80)
        #expect(line(.highlights, p, cam) == nil)
        // With one tie in 21 the strict share is 95 %, and the sentence says so.
        let few = [0.0] + (0..<20).map { 0.2 + Double($0) / 10 }
        let (q, cam2) = camera(photo: { $0.clipHighPct = 0 }, others: few) { $0.clipHighPct = $1 }
        #expect(line(.highlights, q, cam2)?.text == "Fewer blown highlights than 95 % of your other 21 Test Cam photos (0.0 % of the frame).")
    }

    @Test func clippingTooSmallToMatterStaysSilent() {
        // On the real library a photo with almost no crushed shadows read "Fewer crushed shadows than 90 %": both sides
        // were a few thousandths of the frame. Neither side of a comparison is said below 0.1 % of the frame.
        let tiny = (0..<30).map { 0.01 + Double($0) / 1_000 }
        let (fewer, cam) = camera(photo: { $0.clipLowPct = 0.003 }, others: tiny) { $0.clipLowPct = $1 }
        #expect(line(.shadows, fewer, cam) == nil)
        let (more, cam2) = camera(photo: { $0.clipHighPct = 0.09 }, others: tiny) { $0.clipHighPct = $1 }
        #expect(line(.highlights, more, cam2) == nil)
        let (shown, cam3) = camera(photo: { $0.clipHighPct = 0.1 }, others: tiny) { $0.clipHighPct = $1 }
        #expect(line(.highlights, shown, cam3)?.high == true)
        let (fewerShown, cam4) = camera(photo: { $0.clipHighPct = 0 }, others: tiny.map { $0 * 20 }) { $0.clipHighPct = $1 }
        #expect(line(.highlights, fewerShown, cam4)?.high == false)
    }

    @Test func snrComparesCleanReadingsOnly() throws {
        let values = (0..<25).map { 30 + Double($0) / 5 }
        let (p, cam) = camera(photo: { $0.snrMidgreyDB = 50 }, others: values) { $0.snrMidgreyDB = $1 }
        #expect(try #require(line(.snr, p, cam)).text == "Cleaner than 100 % of your other 25 Test Cam photos with a clean noise reading (50.0 dB).")
        let (q, cam2) = camera(photo: { $0.snrMidgreyDB = 50; $0.snrMidgreyExtrapolated = true }, others: values) { $0.snrMidgreyDB = $1 }
        #expect(line(.snr, q, cam2) == nil, "an extrapolated reading is not compared")
        let (r, cam3) = camera(photo: { $0.snrMidgreyDB = 20 }, others: values) { $0.snrMidgreyDB = $1; $0.noiseTextureSuspect = true }
        #expect(line(.snr, r, cam3) == nil, "others without a clean reading do not count")
    }

    /// 20 others at 2,000 ... 3,900 LW/PH: p10 = 2,190 and p90 = 3,710 (linear-interpolated). The photo's range in
    /// LW/PH is 2 x c/px x 3,024 (the fixture's short side).
    @Test(arguments: [(0.62, 0.70, true, true), (0.60, 0.70, false, true), (0.30, 0.35, true, false), (0.30, 0.37, false, false)])
    func sharpnessNeedsTheWholeRangeBeyondTheTenthOrNinetieth(_ lo: Double, _ hi: Double, _ shown: Bool, _ high: Bool) {
        let (p, cam) = camera(photo: { $0.mtf50P80CILo = lo; $0.mtf50P80CIHi = hi }, others: (0..<20).map { 2_000 + 100 * Double($0) }) {
            $0.mtf50P80LWPH = $1
        }
        let l = line(.sharpness, p, cam)
        #expect((l != nil) == shown)
        if let l { #expect(l.high == high && l.percentile == nil && l.others == 20) }
    }

    /// 22 others at 2,000 ... 4,100 LW/PH: p90 = 3,890 (linear-interpolated), but a range starting at 3,891 has only 19
    /// of 22 (86 %) below it. "9 in 10" is claimed only when the count holds.
    @Test(arguments: [(3_891.0, false), (3_950.0, true)])
    func sharpnessNineInTenIsACount(_ low: Double, _ shown: Bool) throws {
        let side = 2 * 3_024.0
        let (p, cam) = camera(photo: { $0.mtf50P80CILo = low / side; $0.mtf50P80CIHi = 4_500 / side },
                              others: (0..<22).map { 2_000 + 100 * Double($0) }) { $0.mtf50P80LWPH = $1 }
        #expect(abs((p.p80RangeLWPH?.lowerBound ?? 0) - low) < 1e-6)
        #expect((line(.sharpness, p, cam) != nil) == shown)
        let (soft, cam2) = camera(photo: { $0.mtf50P80CILo = 1_500 / side; $0.mtf50P80CIHi = (6_100 - low) / side },
                                  others: (0..<22).map { 2_000 + 100 * Double($0) }) { $0.mtf50P80LWPH = $1 }
        #expect((line(.sharpness, soft, cam2) != nil) == shown, "the soft side mirrors it")
    }

    @Test func sharpnessNeedsThePhotosOwnFigure() {
        let (p, cam) = camera(photo: { $0.mtf50P80CILo = 0.9; $0.mtf50P80CIHi = 1.0; $0.edgesMeasured = 2 }, others: (0..<20).map { 2_000 + 100 * Double($0) }) {
            $0.mtf50P80LWPH = $1
        }
        #expect(line(.sharpness, p, cam) == nil, "two edges are not a sharpness figure")
    }
}
