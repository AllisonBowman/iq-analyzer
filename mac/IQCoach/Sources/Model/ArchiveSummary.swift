import Foundation

/// The fixed bins of one archived metric (docs/MEMORY-SPEC.md §5). Counts are exact integers, so buckets merge
/// exactly in any order; a quantile read back is off by at most half a bin.
struct ArchiveBins: Sendable, Equatable {
    enum Scale: Sendable, Equatable {
        case log(ratio: Double)
        case linear(width: Double)
    }

    let scale: Scale
    /// Values below this count in `under` (or `zero` when exactly 0 and the metric has a zero bin).
    let lo: Double
    /// Values above this count in `over`.
    let top: Double
    let hasZero: Bool

    /// mtf50_p80_lwph when edges_measured >= 3: ratio 1.02 (about 1 % relative) from 50 LW/PH.
    static let sharpness = ArchiveBins(scale: .log(ratio: 1.02), lo: 50, top: 10_000, hasZero: false)
    /// snr_midgrey_db when clean: 0.25 dB from 0 dB.
    static let snr = ArchiveBins(scale: .linear(width: 0.25), lo: 0, top: 80, hasZero: false)
    /// clip_high_pct and clip_low_pct: an exact zero bin, then ratio 1.05 from 0.001 %.
    static let clipping = ArchiveBins(scale: .log(ratio: 1.05), lo: 0.001, top: 100, hasZero: true)
    /// structure_horizon_tilt_deg: 0.25 degrees from -45.
    static let tilt = ArchiveBins(scale: .linear(width: 0.25), lo: -45, top: 45, hasZero: false)

    static func forMetric(_ name: String) -> ArchiveBins? {
        switch name {
        case "sharpness_lwph": sharpness
        case "snr_db": snr
        case "clip_high_pct", "clip_low_pct": clipping
        case "tilt_deg": tilt
        default: nil
        }
    }

    enum Slot: Hashable, Sendable {
        case zero, under, over
        case bin(Int)
    }

    /// Where `x` is counted: `floor(ln(x / lo) / ln(ratio))` for a log metric, `floor((x - lo) / width)` for a linear one.
    func slot(_ x: Double) -> Slot {
        if hasZero && x == 0 { return .zero }
        if x < lo { return .under }
        if x > top { return .over }
        switch scale {
        case .log(let r): return .bin(Int((log(x / lo) / log(r)).rounded(.down)))
        case .linear(let w): return .bin(Int(((x - lo) / w).rounded(.down)))
        }
    }

    /// The value a bin stands for: its geometric centre (log bins) or mid-point (linear bins).
    func representative(_ i: Int) -> Double {
        switch scale {
        case .log(let r): lo * pow(r, Double(i) + 0.5)
        case .linear(let w): lo + (Double(i) + 0.5) * w
        }
    }
}

/// A quantile read from the bins; `below` and `above` when it falls in the under or over count.
enum ArchiveQuantile: Equatable, Sendable {
    case value(Double)
    case below(Double)
    case above(Double)
}

/// One metric's counts in a bucket: `{"counts": {"<bin>": n}, "zero": n, "under": n, "over": n, "n": n}`.
struct ArchiveHistogram: Sendable, Equatable {
    var counts: [Int: Int] = [:]
    var zero = 0
    var under = 0
    var over = 0

    /// Values counted, from the parts (the stored `n` is not trusted over them).
    var n: Int { zero + under + over + counts.values.reduce(0, +) }

    mutating func add(_ x: Double, bins: ArchiveBins) {
        guard x.isFinite else { return }
        switch bins.slot(x) {
        case .zero: zero += 1
        case .under: under += 1
        case .over: over += 1
        case .bin(let i): counts[i, default: 0] += 1
        }
    }

    mutating func merge(_ other: ArchiveHistogram) {
        zero += other.zero
        under += other.under
        over += other.over
        for (i, c) in other.counts { counts[i, default: 0] += c }
    }

    /// The nearest-rank quantile (the ceil(q x n)-th smallest value), read at its bin's representative value.
    func quantile(_ q: Double, bins: ArchiveBins) -> ArchiveQuantile? {
        let total = n
        guard total > 0, q >= 0, q <= 1 else { return nil }
        let target = max(1, Int((q * Double(total)).rounded(.up)))
        var seen = zero
        if seen >= target { return .value(0) }
        seen += under
        if seen >= target { return .below(bins.lo) }
        for i in counts.keys.sorted() {
            seen += counts[i] ?? 0
            if seen >= target { return .value(bins.representative(i)) }
        }
        return .above(bins.top)
    }
}

/// A decoded archive bucket: per-metric histograms and exact share counts (`{"shares": {name: [hits, of]}}`).
struct ArchiveBucketContent: Sendable, Equatable {
    var metrics: [String: ArchiveHistogram] = [:]
    var shares: [String: ShareCount] = [:]

    private struct Wire: Decodable {
        struct Metric: Decodable {
            var counts: [String: Int]?
            var zero: Int?
            var under: Int?
            var over: Int?
        }
        var metrics: [String: Metric]?
        var shares: [String: [Int]]?
    }

    /// Decodes the inflated bucket JSON. Unknown metrics are kept; malformed bin keys are an error, not a silent loss.
    static func decode(_ json: Data) throws -> ArchiveBucketContent {
        let wire = try PhotoRecord.makeDecoder().decode(Wire.self, from: json)
        var out = ArchiveBucketContent()
        for (name, m) in wire.metrics ?? [:] {
            var h = ArchiveHistogram(zero: m.zero ?? 0, under: m.under ?? 0, over: m.over ?? 0)
            for (k, c) in m.counts ?? [:] {
                guard let i = Int(k) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bin key \(k) of \(name) is not an integer"))
                }
                h.counts[i, default: 0] += c
            }
            out.metrics[name] = h
        }
        for (name, pair) in wire.shares ?? [:] where pair.count == 2 {
            out.shares[name] = ShareCount(hits: pair[0], of: pair[1])
        }
        return out
    }

    mutating func merge(_ other: ArchiveBucketContent) {
        for (name, h) in other.metrics { metrics[name, default: ArchiveHistogram()].merge(h) }
        for (name, s) in other.shares {
            let a = shares[name] ?? ShareCount(hits: 0, of: 0)
            shares[name] = ShareCount(hits: a.hits + s.hits, of: a.of + s.of)
        }
    }
}

/// One row of the `archive` table: a camera's photos of one capture month and one analyzer key.
struct ArchiveBucket: Sendable, Equatable {
    let camera: String
    /// "YYYY-MM" of capture, "undated" when unknown.
    let month: String
    let analyzerKey: String
    let n: Int
    let firstTS: Double?
    let lastTS: Double?
    /// nil when the blob did not inflate or decode.
    let content: ArchiveBucketContent?
}

/// "Your earlier photos with this camera", from the buckets of the current analyzer key only (spec §8 item 3).
/// It never feeds the coaching rules, which read the window.
struct ArchiveSummary: Sendable, Equatable {
    let photos: Int
    let buckets: Int
    /// Earliest and latest dated month, "YYYY-MM".
    let firstMonth: String?
    let lastMonth: String?
    let content: ArchiveBucketContent
    /// Buckets of other analyzer keys, never merged with these.
    let leftOutPhotos: Int
    let leftOutBuckets: Int
    /// Buckets of the current key whose blob could not be read.
    let unreadable: Int

    /// Merges the current key's buckets; nil when there are none (or no current key to choose by).
    static func make(_ buckets: [ArchiveBucket], currentKey: String?) -> ArchiveSummary? {
        guard let key = currentKey else { return nil }
        let mine = buckets.filter { $0.analyzerKey == key }
        let others = buckets.filter { $0.analyzerKey != key }
        let readable = mine.filter { $0.content != nil }
        guard !readable.isEmpty else { return nil }
        var merged = ArchiveBucketContent()
        for b in readable { if let c = b.content { merged.merge(c) } }
        let months = readable.map(\.month).filter { $0 != "undated" && monthDate($0) != nil }.sorted()
        return ArchiveSummary(photos: readable.map(\.n).reduce(0, +), buckets: readable.count,
                              firstMonth: months.first, lastMonth: months.last, content: merged,
                              leftOutPhotos: others.map(\.n).reduce(0, +), leftOutBuckets: others.count,
                              unreadable: mine.count - readable.count)
    }

    func quantile(_ metric: String, _ q: Double) -> ArchiveQuantile? {
        guard let bins = ArchiveBins.forMetric(metric) else { return nil }
        return content.metrics[metric]?.quantile(q, bins: bins)
    }

    var medianSharpness: ArchiveQuantile? { quantile("sharpness_lwph", 0.5) }
    /// Photos with more than 1 % of the frame blown, over the photos that have the figure.
    var blownShare: ShareCount? { content.shares["clip_high_gt1"].flatMap { $0.of > 0 ? $0 : nil } }

    /// "Earlier: 2,310 photos (Mar 2021 – Jun 2026), median sharpness 812 LW/PH, more than 1 % blown in 21 %".
    /// Parts without data are left out.
    var sentence: String {
        var s = "Earlier: \(Fmt.count(photos, "photo"))"
        if let a = firstMonth.flatMap(Self.monthText), let b = lastMonth.flatMap(Self.monthText) {
            s += a == b ? " (\(a))" : " (\(a) – \(b))"
        }
        var parts: [String] = []
        switch medianSharpness {
        case .value(let v): parts.append("median sharpness \(Fmt.lwph(v))")
        case .below(let v): parts.append("median sharpness under \(Fmt.lwph(v))")
        case .above(let v): parts.append("median sharpness over \(Fmt.lwph(v))")
        case nil: break
        }
        if let b = blownShare { parts.append("more than 1 % blown in \(Fmt.share(b.fraction))") }
        return ([s] + parts).joined(separator: ", ")
    }

    /// Says how many earlier photos were measured with another method and so are not in the sentence.
    var leftOutSentence: String? {
        var t: [String] = []
        if leftOutBuckets > 0 {
            t.append("\(Fmt.count(leftOutPhotos, "earlier photo")) measured with another method \(leftOutPhotos == 1 ? "is" : "are") not included")
        }
        if unreadable > 0 { t.append(unreadable == 1 ? "1 monthly summary could not be read" : "\(unreadable.formatted()) monthly summaries could not be read") }
        return t.isEmpty ? nil : t.joined(separator: "; ") + "."
    }

    static func monthDate(_ month: String) -> Date? {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: 15))
    }

    /// "2021-03" -> "Mar 2021" (UTC, because capture months are the EXIF wall-clock months).
    static func monthText(_ month: String) -> String? {
        guard let d = monthDate(month) else { return nil }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).year()
        style.timeZone = TimeZone(identifier: "UTC")!
        return d.formatted(style)
    }
}
