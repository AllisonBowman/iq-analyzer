import Foundation

/// "This photo against your usual" (docs/MEMORY-SPEC.md §8 item 2): where one photo sits among the camera's other
/// photos, said only when it is outside a tolerance band. Blown highlights, crushed shadows and clean SNR use the
/// mid-rank percentile, shown at or below the 10th or at or above the 90th with at least 20 other photos; the sentence
/// states the share strictly beyond the photo (ties are not "fewer") and is said only when that share is 90 % or more.
/// Sharpness is claimed only when the photo's whole 95 % range lies beyond the camera's 10th or 90th percentile and
/// at least 9 in 10 others lie strictly beyond the range, because one photo's range is about +/-30 % wide and an
/// interpolated percentile can sit inside the last tenth. Clipping is mentioned only when it is material: "more"
/// needs the photo itself at `materialClipPct` or above, "fewer" needs the camera's median there, so a photo is never
/// praised for 0.003 % against a usual of 0.01 %. Pure; it does not feed any coaching rule.
struct UsualComparison: Sendable, Hashable, Identifiable {
    enum Measure: String, Sendable, Hashable {
        case highlights, shadows, snr, sharpness
    }

    let measure: Measure
    /// True when the photo sits at the top end (more clipping, cleaner, sharper).
    let high: Bool
    /// Mid-rank percentile among the other photos (0...100); nil for sharpness, which is claimed by interval.
    let percentile: Double?
    let others: Int
    let text: String
    var id: String { measure.rawValue }

    static let minOthers = 20
    static let lowPercentile = 10.0
    static let highPercentile = 90.0
    /// Clipping smaller than this share of the frame (24,000 pixels of a 24 MP photo) is not worth a sentence.
    static let materialClipPct = 0.1

    /// The share of `others` below `x`, ties counting half, in percent.
    static func midRankPercentile(_ x: Double, among others: [Double]) -> Double {
        guard !others.isEmpty else { return 50 }
        let below = others.filter { $0 < x }.count, ties = others.filter { $0 == x }.count
        return (Double(below) + 0.5 * Double(ties)) / Double(others.count) * 100
    }

    /// The share of `others` strictly below `x` (the high side) or strictly above it (the low side), in percent: what
    /// "more than" and "fewer than" may claim, since a tie is neither.
    static func strictShare(_ x: Double, among others: [Double], high: Bool) -> Double {
        guard !others.isEmpty else { return 0 }
        return Double(others.filter { high ? $0 < x : $0 > x }.count) / Double(others.count) * 100
    }

    /// The comparisons worth saying for `photo`, in a fixed order; empty when none clears its threshold.
    static func lines(for photo: PhotoRecord, camera: CameraGroup) -> [UsualComparison] {
        let others = camera.photos.filter { $0.id != photo.id }
        let name = camera.model
        var out: [UsualComparison] = []
        if let x = photo.clipHighPct, let c = material(x, others.compactMap(\.clipHighPct)) {
            out.append(UsualComparison(measure: .highlights, high: c.high, percentile: c.p, others: c.n,
                text: "\(c.high ? "More" : "Fewer") blown highlights than \(shareText(c.share)) of your other \(Fmt.count(c.n, "\(name) photo")) (\(frameText(x)) of the frame)."))
        }
        if let x = photo.clipLowPct, let c = material(x, others.compactMap(\.clipLowPct)) {
            out.append(UsualComparison(measure: .shadows, high: c.high, percentile: c.p, others: c.n,
                text: "\(c.high ? "More" : "Fewer") crushed shadows than \(shareText(c.share)) of your other \(Fmt.count(c.n, "\(name) photo")) (\(frameText(x)) of the frame)."))
        }
        if photo.snrIsClean, let x = photo.snrMidgreyDB,
           let c = ranked(x, others.filter(\.snrIsClean).compactMap(\.snrMidgreyDB)) {
            out.append(UsualComparison(measure: .snr, high: c.high, percentile: c.p, others: c.n,
                text: "\(c.high ? "Cleaner" : "Noisier") than \(shareText(c.share)) of your other \(Fmt.count(c.n, "\(name) photo")) with a clean noise reading (\(Fmt.db(x)))."))
        }
        if let s = sharpness(photo, others: others, camera: name) { out.append(s) }
        return out
    }

    /// `ranked`, for clipping: kept only when the side it speaks of is material.
    private static func material(_ x: Double, _ values: [Double]) -> (p: Double, share: Double, n: Int, high: Bool)? {
        guard let c = ranked(x, values) else { return nil }
        if c.high { return x >= materialClipPct ? c : nil }
        return (Stats.median(values) ?? 0) >= materialClipPct ? c : nil
    }

    /// The mid-rank percentile when it clears a threshold with enough other photos, and the strict share the sentence
    /// states, which must clear the same 90 % (ties at the photo's value, often 0 % clipped, would otherwise inflate it).
    private static func ranked(_ x: Double, _ values: [Double]) -> (p: Double, share: Double, n: Int, high: Bool)? {
        guard values.count >= minOthers else { return nil }
        let p = midRankPercentile(x, among: values)
        let high: Bool
        if p >= highPercentile { high = true } else if p <= lowPercentile { high = false } else { return nil }
        let share = strictShare(x, among: values, high: high)
        return share >= highPercentile ? (p, share, values.count, high) : nil
    }

    private static func sharpness(_ photo: PhotoRecord, others: [PhotoRecord], camera name: String) -> UsualComparison? {
        guard photo.hasSharpnessFigure, let r = photo.p80RangeLWPH else { return nil }
        let values = others.compactMap(\.gatedSharpnessLWPH)
        guard values.count >= minOthers, let p10 = Stats.quantile(values, 0.10), let p90 = Stats.quantile(values, 0.90) else { return nil }
        let range = "\(Fmt.int(r.lowerBound))–\(Fmt.int(r.upperBound)) LW/PH"
        let of = "of your other \(Fmt.count(values.count, "\(name) photo")) with a sharpness figure"
        // "9 in 10" must hold as a count: the interpolated percentile alone let 19 of 22 (86 %) pass.
        let below = values.filter { $0 < r.lowerBound }.count, above = values.filter { $0 > r.upperBound }.count
        if r.lowerBound > p90, 10 * below >= 9 * values.count {
            return UsualComparison(measure: .sharpness, high: true, percentile: nil, others: values.count,
                text: "Sharper than 9 in 10 \(of): even the low end of this photo's range (\(range)) is above their 90th percentile (\(Fmt.lwph(p90))).")
        }
        if r.upperBound < p10, 10 * above >= 9 * values.count {
            return UsualComparison(measure: .sharpness, high: false, percentile: nil, others: values.count,
                text: "Softer than 9 in 10 \(of): even the high end of this photo's range (\(range)) is below their 10th percentile (\(Fmt.lwph(p10))).")
        }
        return nil
    }

    /// "95 %": rounded down, so the claim is never stronger than the count.
    static func shareText(_ pct: Double) -> String { Fmt.pct(pct.rounded(.down)) }

    /// "2.2 %", "0.04 %", "under 0.01 %" (a figure that would round to 0.00 is not shown as nothing).
    static func frameText(_ pct: Double) -> String {
        if pct > 0 && pct < 0.005 { return "under " + Fmt.pct(0.01, 2) }
        return Fmt.pct(pct, pct >= 1 || pct == 0 ? 1 : 2)
    }
}
