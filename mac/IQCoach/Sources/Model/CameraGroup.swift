import Foundation

struct LensGroup: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let photos: [PhotoRecord]

    /// Median p80 sharpness over the photos with at least three valid edges (iqa/report.py `_sharp_ok`).
    var p80Sharpness: Double? { Stats.median(photos.compactMap(\.gatedSharpnessLWPH)) }
    /// Photos behind `p80Sharpness`.
    var sharpnessCount: Int { photos.filter { $0.gatedSharpnessLWPH != nil }.count }
    var medianFocalMM: Double? { Stats.median(photos.compactMap(\.focalMM)) }
    var isFront: Bool { photos.first?.isFront ?? false }
}

struct SNRBandStat: Identifiable, Sendable {
    let band: ISOBand
    let median: Double
    let count: Int
    var id: Int { band.rawValue }
}

/// How many photos were left out of a figure, and why.
struct ExclusionCount: Hashable, Sendable {
    let reason: String
    let count: Int
}

/// A camera's report-card figures. Each figure counts only the rows the analyzer itself would count
/// (iqa/report.py VALIDITY): sharpness, halo and centre/outer need three valid edges; SNR needs a clean
/// reading; dynamic range is exact only from frames that reached the noise floor.
struct CameraSummary: Sendable {
    /// Fewest photos that must pass a figure's gate before the report card shows a median.
    static let minRowsForFigure = 5

    let photoCount: Int
    let sharpnessLWPH: Double?
    let sharpnessCPP: Double?
    /// Photos with three or more valid edges (behind the sharpness and halo figures).
    let sharpnessCounted: Int
    /// Photos with one or two valid edges: measured, but not enough to count.
    let sharpnessRough: Int
    /// Photos with no valid edge.
    let sharpnessNone: Int
    /// Middle half of the counted photos' sharpness (LW/PH), nil under `minRowsForFigure`.
    let sharpnessIQR: ClosedRange<Double>?
    /// Median width of the per-photo p80 interval relative to the p80 figure, over counted photos.
    let p80RelativeWidthMedian: Double?
    let snr: Double?
    let snrCounted: Int
    let snrExcluded: [ExclusionCount]
    let snrByBand: [SNRBandStat]
    let centreOuterRatio: Double?
    let centreOuterCount: Int
    let clipHighMedian: Double?
    let clipLowMedian: Double?
    let clipHighShare: Double?
    let clipLowShare: Double?
    let clipHighCount: Int
    let clipLowCount: Int
    /// Photos with more than 1 % of pixels in colour beyond sRGB (`clip_gamut_pct`): colour the file keeps, not lost detail.
    let gamutCount: Int
    /// Rows per file format ("jpeg", "heic", ...).
    let formats: [String: Int]
    let whiteness: Double?
    /// Median whiteness over clean rows above ISO 160, where whiteness reflects noise reduction rather than
    /// low-noise texture (FINDINGS §5 item 5); nil when fewer than `minRowsForFigure` such rows exist.
    let whitenessAbove160: Double?
    let whitenessAbove160Count: Int
    let overshoot: Double?
    let overshootCounted: Int
    let wbRStops: Double?
    let wbBStops: Double?
    let wbCount: Int
    let dynamicRange: Double?
    let dynamicRangeIsLowerBound: Bool
    let drExactCount: Int
    let drLowerBoundCount: Int
    /// Median of the exact rows, shown in the caption when there are too few of them to be the figure.
    let drExactMedian: Double?
    let firstDate: Date?
    let lastDate: Date?

    /// Fewest clean photos an ISO band needs before its median is used.
    static let minPerBand = 3
    /// A band median may rise this much above the band below it and still count as following ISO (a design choice).
    static let followsISOToleranceDB = 1.0

    /// Bands with at least `minPerBand` clean photos.
    var ratedBands: [SNRBandStat] { snrByBand.filter { $0.count >= Self.minPerBand } }

    /// True when no band median rises more than 1 dB above the band below it (a sensor's behaviour); false when one
    /// does (processing); nil with fewer than two rated bands.
    var snrFollowsISO: Bool? {
        let b = ratedBands
        guard b.count >= 2 else { return nil }
        return !zip(b, b.dropFirst()).contains { $1.median - $0.median > Self.followsISOToleranceDB }
    }

    var hasSharpnessFigure: Bool { sharpnessCounted >= Self.minRowsForFigure && sharpnessLWPH != nil }
    var hasOvershootFigure: Bool { overshootCounted >= Self.minRowsForFigure && overshoot != nil }

    /// The larger of the median R/G and median B/G casts, in stops: the camera's typical rendering.
    /// Not the median of per-photo leans, which is larger because every scene adds its own cast.
    var wbLean: Double? {
        guard wbRStops != nil || wbBStops != nil else { return nil }
        return max(abs(wbRStops ?? 0), abs(wbBStops ?? 0))
    }

    init(photos: [PhotoRecord]) {
        photoCount = photos.count
        let sharp = photos.filter(\.hasSharpnessFigure)
        sharpnessLWPH = Stats.median(sharp.compactMap(\.mtf50P80LWPH))
        sharpnessCPP = Stats.median(sharp.compactMap(\.mtf50P80CPP))
        sharpnessCounted = sharp.filter { $0.mtf50P80LWPH != nil }.count
        sharpnessRough = photos.filter { (1...2).contains($0.edgesMeasured ?? 0) }.count
        sharpnessNone = photoCount - sharpnessCounted - sharpnessRough
        p80RelativeWidthMedian = Stats.median(sharp.compactMap(\.p80RelativeWidth))
        let sv = sharp.compactMap(\.mtf50P80LWPH)
        if sv.count >= Self.minRowsForFigure, let q1 = Stats.quantile(sv, 0.25), let q3 = Stats.quantile(sv, 0.75) {
            sharpnessIQR = q1...q3
        } else {
            sharpnessIQR = nil
        }
        let clean = photos.filter(\.snrIsClean)
        snr = Stats.median(clean.compactMap(\.snrMidgreyDB))
        snrCounted = clean.count
        var excluded: [String: Int] = [:]
        for p in photos { if let r = p.snrExclusionReason { excluded[r, default: 0] += 1 } }
        snrExcluded = excluded.map { ExclusionCount(reason: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.reason < $1.reason }
        snrByBand = ISOBand.allCases.compactMap { band in
            let rows = clean.filter { $0.iso.map(ISOBand.band(for:)) == band }
            guard let m = Stats.median(rows.compactMap(\.snrMidgreyDB)) else { return nil }
            return SNRBandStat(band: band, median: m, count: rows.count)
        }
        let ratios = photos.compactMap(\.gatedOuterCentreRatio)
        centreOuterRatio = Stats.median(ratios)
        centreOuterCount = ratios.count
        let hi = photos.compactMap(\.clipHighPct), lo = photos.compactMap(\.clipLowPct)
        clipHighMedian = Stats.median(hi)
        clipLowMedian = Stats.median(lo)
        clipHighShare = Stats.share(hi.map { $0 > 1 })
        clipLowShare = Stats.share(lo.map { $0 > 1 })
        clipHighCount = hi.filter { $0 > 1 }.count
        clipLowCount = lo.filter { $0 > 1 }.count
        gamutCount = photos.filter { ($0.clipGamutPct ?? 0) > 1 }.count
        formats = Dictionary(grouping: photos, by: { $0.format ?? "unknown" }).mapValues(\.count)
        whiteness = Stats.median(photos.filter { $0.noiseTextureSuspect != true }.compactMap(\.noiseWhiteness))
        let above = clean.filter { ($0.iso ?? 0) > 160 }.compactMap(\.noiseWhiteness)
        whitenessAbove160Count = above.count
        whitenessAbove160 = above.count >= Self.minRowsForFigure ? Stats.median(above) : nil
        let os = photos.compactMap(\.gatedOvershoot)
        overshoot = Stats.median(os)
        overshootCounted = os.count
        wbRStops = Stats.median(photos.compactMap(\.wbROverGStops))
        wbBStops = Stats.median(photos.compactMap(\.wbBOverGStops))
        wbCount = photos.filter { $0.wbROverGStops != nil || $0.wbBOverGStops != nil }.count
        let exact = photos.filter { $0.drSNR4LowerBound != true }.compactMap(\.drSNR4Stops)
        drExactCount = exact.count
        drLowerBoundCount = photos.filter { $0.drSNR4LowerBound == true && $0.drSNR4Stops != nil }.count
        drExactMedian = Stats.median(exact)
        if exact.count >= Self.minRowsForFigure || (drLowerBoundCount == 0 && !exact.isEmpty) {
            dynamicRange = drExactMedian
            dynamicRangeIsLowerBound = false
        } else {
            // Too few frames reached the noise floor: the honest figure is "at least" the median of all rows.
            dynamicRange = Stats.median(photos.compactMap(\.drSNR4Stops))
            dynamicRangeIsLowerBound = true
        }
        let dates = photos.compactMap(\.date)
        firstDate = dates.min()
        lastDate = dates.max()
    }
}

struct CameraGroup: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let photos: [PhotoRecord]
    let lenses: [LensGroup]
    let summary: CameraSummary

    init(model: String, photos: [PhotoRecord]) {
        self.model = model
        self.photos = photos
        let byLens = Dictionary(grouping: photos, by: \.lensName)
        lenses = byLens.map { LensGroup(name: $0.key, photos: $0.value) }
            .sorted { ($0.medianFocalMM ?? 0) < ($1.medianFocalMM ?? 0) || (($0.medianFocalMM ?? 0) == ($1.medianFocalMM ?? 0) && $0.name < $1.name) }
        summary = CameraSummary(photos: photos)
    }

    var isPhone: Bool { model.hasPrefix("iPhone") || photos.first?.cameraMake == "Apple" }
    var isRaw: Bool { photos.contains { $0.isRaw == true } }

    static func groups(from photos: [PhotoRecord]) -> [CameraGroup] {
        Dictionary(grouping: photos, by: \.camera)
            .map { CameraGroup(model: $0.key, photos: $0.value) }
            .sorted { $0.photos.count > $1.photos.count || ($0.photos.count == $1.photos.count && $0.model < $1.model) }
    }
}

struct PhotoLibrary: Sendable {
    let sourceName: String
    let photos: [PhotoRecord]
    let cameras: [CameraGroup]
    /// When the results file was written (its modification date), when known.
    let sourceDate: Date?

    init(sourceName: String, photos: [PhotoRecord], sourceDate: Date? = nil) {
        self.sourceName = sourceName
        self.photos = photos
        self.sourceDate = sourceDate
        cameras = CameraGroup.groups(from: photos)
    }

    /// True when clipping was counted in each file's own encoding: only results written after that change (the fifth
    /// run, FINDINGS §8) carry `clip_gamut_pct`.
    var hasNativeClipping: Bool { photos.contains { $0.clipGamutPct != nil } }
    /// True when the results carry the structure fields (iqa 0.2 and later).
    var hasStructure: Bool { photos.contains(where: \.hasStructure) }

    /// Cameras with enough photos for coaching, and those without.
    var coachedCameras: [CameraGroup] { cameras.filter { $0.photos.count >= CameraRules.minPhotos } }
    var sparseCameras: [CameraGroup] { cameras.filter { $0.photos.count < CameraRules.minPhotos } }

    /// Median colourfulness over every photo: the reference for "a colourful picture".
    var colorfulnessMedian: Double? { Stats.median(photos.compactMap(\.colorfulness)) }

    /// "From results.json, written 23 Oct 2026 at 04:36 · 389 photos from 19 cameras."
    var provenance: String {
        var s = "From \(sourceName)"
        if let d = sourceDate { s += ", written \(Fmt.date(d)) at \(d.formatted(date: .omitted, time: .shortened))" }
        return s + " · \(Fmt.count(photos.count, "photo")) from \(Fmt.count(cameras.count, "camera"))"
    }

    func camera(_ model: String) -> CameraGroup? { cameras.first { $0.model == model } }
}

// MARK: Report-card text

/// What each report-card tile shows: the number (or "Not enough photos") and a caption saying what the number
/// is a median of and what was left out. Pure, so the tests can pin the wording.
extension CameraSummary {
    static let notEnoughText = "Not enough photos"

    private var minText: String { "a camera figure needs \(Self.minRowsForFigure)" }

    var sharpnessCaption: String {
        let rest = "\(sharpnessRough) had only 1 or 2 usable edges and \(sharpnessNone) had none"
        if hasSharpnessFigure, let cpp = sharpnessCPP {
            var s = "From the \(sharpnessCounted) of \(Fmt.count(photoCount, "photo")) with 3 or more usable edges (\(Fmt.cpp(cpp))); not counted: \(rest). Read from real edges in your scenes, so a lower bound on the lens."
            if let w = p80RelativeWidthMedian {
                s += " One photo's figure has a 95 % range typically \(Fmt.share(w)) of its value wide; compare single photos only when they differ by more than 30 %."
            }
            return s
        }
        var s = "\(sharpnessCounted) of \(Fmt.count(photoCount, "photo")) had 3 or more usable edges"
        if sharpnessCounted > 0, let v = sharpnessLWPH { s += " (median \(Fmt.lwph(v)))" }
        return s + "; \(rest); \(minText). Scenes with straight edges, such as buildings, signs or bookshelves, give the method something to measure."
    }

    var hasSNRFigure: Bool { snrCounted >= Self.minRowsForFigure && snr != nil }

    var snrCaption: String {
        var s = hasSNRFigure ? "Mid-grey signal to noise over \(snrCounted) of \(Fmt.count(photoCount, "photo"))"
                             : "Only \(snrCounted) of \(Fmt.count(photoCount, "photo")) gave a clean noise reading; \(minText)"
        let left = snrExcluded.map(\.count).reduce(0, +)
        if left > 0 {
            s += "; \(left) left out (" + snrExcluded.map { "\($0.count): \($0.reason)" }.joined(separator: "; ") + ")"
        }
        return s + ". \(Fmt.db(Metric.snrCleanDB)) and up is clean; under \(Fmt.db(Metric.snrNoisyDB)) is visibly noisy. It compares processing, not the sensor."
    }

    var clipCaption: String? {
        guard let share = clipHighShare else { return nil }
        var t = "Median share of pixels at the top of the range in at least one colour channel, counted in the file's own encoding. The band grades the typical photo; how often photos clip is graded by the 15 % line in the chart: \(Fmt.share(share)) of photos (\(clipHighCount)) lose more than 1 %."
        if gamutCount > 0 {
            t += " \(gamutCount) \(gamutCount == 1 ? "photo also has" : "photos also have") more than 1 % of pixels in colour sRGB cannot show; that colour is in the file, not lost detail."
        }
        return t
    }

    var overshootCaption: String {
        let scale = "Under \(Fmt.int(Metric.overshootNaturalPct)) % is natural; \(Fmt.int(Metric.overshootHardPct)) % and up is hard sharpening; \(Fmt.int(Metric.overshootHaloPct)) % and up is a visible halo."
        if hasOvershootFigure { return "Median edge overshoot over the \(overshootCounted) photos with 3 or more usable edges. " + scale }
        return "Only \(overshootCounted) of \(Fmt.count(photoCount, "photo")) had 3 or more usable edges; \(minText). " + scale
    }

    var leanCaption: String {
        guard wbRStops != nil || wbBStops != nil else { return "Gray-world cast of the picture as rendered." }
        let r = wbRStops ?? 0, b = wbBStops ?? 0
        let d = CameraRules.leanDescription(r: r, b: b)
        let words = d.stops > 0.15 ? "renders \(d.words)" : "close to neutral"
        return "Larger of the median R/G (\(Fmt.num(r, 2))) and median B/G (\(Fmt.num(b, 2))) over \(Fmt.count(wbCount, "photo")): the camera's typical rendering, \(words). A single photo's lean is usually larger, because each scene adds its own cast. Gray-world."
    }

    /// "At least " when the dynamic-range figure is a lower bound.
    var dynamicRangePrefix: String { dynamicRangeIsLowerBound ? "At least " : "" }

    var dynamicRangeCaption: String {
        if !dynamicRangeIsLowerBound {
            let more = drLowerBoundCount > 0 ? "; \(drLowerBoundCount) more only show 'at least'" : ""
            return "Median over the \(drExactCount) photos dark enough to reach the noise floor\(more). Stops above the noise floor; no pass mark."
        }
        var s = "Only \(drExactCount) of \(Fmt.count(photoCount, "photo")) reached the noise floor"
        if drExactCount > 0, let m = drExactMedian { s += " (\(Fmt.stops(m, 1)) in \(drExactCount == 1 ? "that frame" : "those frames"))" }
        return s + "; the other \(drLowerBoundCount) only set a lower bound, so read this as at least. No pass mark, and not comparable with other cameras."
    }

    // One-line cells for the library table and the Markdown export, with the same gates as the tiles.
    var sharpnessCell: String {
        guard hasSharpnessFigure, let v = sharpnessLWPH, let c = sharpnessCPP else { return "\(Self.notEnoughText) (\(sharpnessCounted))" }
        return Metric.sharpnessLWPH.format(v) + (Metric.sharpnessCPP.band(for: c).map { " · \($0.word)" } ?? "")
    }
    /// "1,966 LW/PH · Good (43)" or "Not enough photos (1)": the cell with the photos it rests on.
    var sharpnessCellWithCount: String { hasSharpnessFigure ? "\(sharpnessCell) (\(sharpnessCounted))" : sharpnessCell }
    var noiseCell: String {
        guard hasSNRFigure, let v = snr else { return "\(Self.notEnoughText) (\(snrCounted))" }
        return Metric.snr.format(v) + (Metric.snr.band(for: v).map { " · \($0.word)" } ?? "")
    }
    var haloCell: String {
        guard hasOvershootFigure, let v = overshoot else { return "\(Self.notEnoughText) (\(overshootCounted))" }
        return Metric.overshoot.format(v) + (Metric.overshoot.band(for: v).map { " · \($0.word)" } ?? "")
    }
    /// The camera's typical cast, unbanded: the bands grade a single photo's lean.
    var leanCell: String { wbLean.map(Metric.whiteBalance.format) ?? "—" }
}
