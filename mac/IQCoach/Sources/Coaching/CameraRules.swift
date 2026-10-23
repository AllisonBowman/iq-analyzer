import Foundation

/// Camera-level coaching rules. Each is a pure function of a camera group; nil means "does not apply".
enum CameraRules {
    static let minPhotos = 5
    static let minPerBand = 3

    // MARK: Example photos

    static let maxExamples = 4

    /// Photos that best show a point: their `file` names and one caption each. Rules stay pure; the view resolves files to paths.
    struct Examples: Sendable {
        var files: [String] = []
        var captions: [String] = []
        static let none = Examples()
    }

    /// The `limit` photos with the highest (or lowest) value, ties broken by file name.
    static func extremes(_ photos: [PhotoRecord], limit: Int = maxExamples, highest: Bool,
                         value: (PhotoRecord) -> Double?, caption: (PhotoRecord, Double) -> String) -> Examples {
        var rows = measured(photos, value)
        rows.sort { a, b in
            if a.1 != b.1 { return highest ? a.1 > b.1 : a.1 < b.1 }
            return a.0.file < b.0.file
        }
        return pack(Array(rows.prefix(limit)), caption: caption)
    }

    /// The `limit` photos closest to the median of `value`: representative rather than extreme.
    static func representative(_ photos: [PhotoRecord], limit: Int = maxExamples,
                               value: (PhotoRecord) -> Double?, caption: (PhotoRecord, Double) -> String) -> Examples {
        let rows = measured(photos, value)
        guard let med = Stats.median(rows.map { $0.1 }) else { return .none }
        let sorted = rows.sorted { (a: (PhotoRecord, Double), b: (PhotoRecord, Double)) -> Bool in
            let da = abs(a.1 - med), db = abs(b.1 - med)
            if da != db { return da < db }
            return a.0.file < b.0.file
        }
        return pack(Array(sorted.prefix(limit)), caption: caption)
    }

    private static func measured(_ photos: [PhotoRecord], _ value: (PhotoRecord) -> Double?) -> [(PhotoRecord, Double)] {
        var out: [(PhotoRecord, Double)] = []
        for p in photos {
            if let v = value(p), v.isFinite { out.append((p, v)) }
        }
        return out
    }

    private static func pack(_ rows: [(PhotoRecord, Double)], caption: (PhotoRecord, Double) -> String) -> Examples {
        var seen = Set<String>()
        var out = Examples()
        for (p, v) in rows where seen.insert(p.file).inserted {
            out.files.append(p.file)
            out.captions.append(caption(p, v))
        }
        return out
    }

    static func signedDegrees(_ t: Double) -> String { (t < 0 ? "\u{2212}" : "+") + Fmt.num(abs(t), 1) + "\u{00B0}" }

    // MARK: 1. ISO ceiling
    /// The ceiling is the top of the unbroken run of ISO bands, from the lowest, whose clean-SNR medians are all at
    /// or above the clean mark. A band that falls under the mark ends the run even if a higher band recovers; a
    /// recovery is reported, not hidden. The open-ended top band is checked at the highest ISO actually used.
    static func isoCeiling(_ cam: CameraGroup) -> Insight? {
        let mark = Metric.snrCleanDB
        let markText = Fmt.db(mark)
        let bands = cam.summary.snrByBand.filter { $0.count >= minPerBand }
        guard !bands.isEmpty else { return nil }
        let clean = cam.photos.filter { $0.snrIsClean && $0.iso != nil }
        let evidence = bands.map { EvidenceItem(metric: "Median SNR, \($0.band.label)", value: Fmt.db($0.median), n: $0.count) }
        let counted = bands.map(\.count).reduce(0, +)
        let id = "iso-ceiling:\(cam.model)"
        func inBand(_ b: ISOBand) -> [PhotoRecord] { clean.filter { $0.iso.map(ISOBand.band(for:)) == b } }
        func lowestSNR(_ rows: [PhotoRecord]) -> Examples {
            extremes(rows, highest: false, value: \.snrMidgreyDB, caption: { Fmt.db($1) })
        }
        func bandText(_ b: SNRBandStat) -> String { "\(b.band.label) \(Fmt.db(b.median)) (\(Fmt.count(b.count, "photo")))" }
        let run = Array(bands.prefix { $0.median >= mark })
        let failing = bands.first { $0.median < mark }
        let recovers = failing.map { f in bands.filter { $0.band > f.band && $0.median >= mark } } ?? []

        // No band passes from the bottom.
        guard let ceiling = run.last else {
            let first = bands[0]
            let ex = lowestSNR(inBand(first.band))
            if recovers.isEmpty {
                return Insight(
                    id: id, scope: .camera(cam.model), severity: .important,
                    title: "Noise is visible at every ISO you used",
                    finding: "Median noise is \(Fmt.db(first.median)) even in \(first.band.label) (\(Fmt.count(first.count, "photo"))), below the \(markText) mark for clean.",
                    why: "Below about \(markText) grain starts to show at full size. Much of this figure is the camera's own processing and compression, so it will not change much with settings alone.",
                    actions: ["Shoot in the brightest light you can find.", "Use a support and a slower shutter instead of a higher ISO.", "Plan on gentle noise reduction when you edit."],
                    evidence: evidence, exampleFiles: ex.files, exampleCaptions: ex.captions, counted: counted, total: cam.photos.count)
            }
            return Insight(
                id: id, scope: .camera(cam.model), severity: .info,
                title: "Noise does not follow ISO on this \(cam.isPhone ? "phone" : "camera")",
                finding: "Median noise by ISO band: " + bands.map(bandText).joined(separator: "; ") + ". The lowest band is already under the \(markText) clean mark while a higher band reads cleaner, so ISO alone does not predict noise here.",
                why: "This figure is output-referred: the camera's noise reduction and compression change with ISO and with the scene, so it compares processing, not the sensor.",
                actions: ["Do not chase a low ISO for clean pictures on this \(cam.isPhone ? "phone" : "camera"): no ISO band you used is reliably clean.", "Expose generously: a dark frame lifted later is noisier at any ISO."],
                evidence: evidence, exampleFiles: ex.files, exampleCaptions: ex.captions, counted: counted, total: cam.photos.count)
        }

        // Every band passes.
        if failing == nil {
            let topRows = inBand(ceiling.band)
            let isos = Array(Set(topRows.compactMap(\.iso))).sorted()
            guard let maxISO = isos.last else { return nil }
            func medianAt(_ iso: Double) -> Double? { Stats.median(topRows.filter { $0.iso == iso }.compactMap(\.snrMidgreyDB)) }
            let atMax = medianAt(maxISO) ?? ceiling.median
            if ceiling.band.topISO != nil || atMax >= mark {
                let ex = lowestSNR(topRows)
                return Insight(
                    id: id, scope: .camera(cam.model), severity: .info,
                    title: "Noise is clean at every ISO you have used",
                    finding: "Noise stays clean at every ISO you have used, up to ISO \(Fmt.int(maxISO)), the highest (\(ceiling.band.label): \(Fmt.db(ceiling.median)) over \(Fmt.count(ceiling.count, "photo"))).",
                    why: "A signal-to-noise figure of \(markText) or more means grain is hard to see at full size.",
                    actions: ["Clean at every ISO you have used: raise ISO rather than risk a blurred shot.", "Try a higher ISO in dim light to see where the limit is."],
                    evidence: evidence, exampleFiles: ex.files, exampleCaptions: ex.captions, counted: counted, total: cam.photos.count)
            }
            // The open-ended band passes as a whole, but not at the highest ISO used: cap the claim at the top of the
            // unbroken run of ISOs in that band whose own photos are clean.
            let capISO = isos.prefix { (medianAt($0) ?? 0) >= mark }.last
            let capText = capISO.map { "ISO \(Fmt.int($0))" } ?? "ISO 1000"
            let nAtMax = topRows.filter { $0.iso == maxISO }.count
            let ex = lowestSNR(topRows.filter { ($0.iso ?? 0) > (capISO ?? 1000) })
            return Insight(
                id: id, scope: .camera(cam.model), severity: .notice,
                title: "Keep ISO at or below \(capText) for clean pictures",
                finding: "Noise stays clean up to \(capText) (\(ceiling.band.label): \(Fmt.db(ceiling.median)) over \(Fmt.count(ceiling.count, "photo"))), but at ISO \(Fmt.int(maxISO)), the highest you used, \(nAtMax == 1 ? "the photo measures" : "the \(nAtMax) photos measure") \(Fmt.db(atMax)), under the \(markText) mark.",
                why: "The top ISO band pools everything above ISO 1000, so its median can hide the highest settings. The \(markText) mark is where grain begins to be visible at full size.",
                actions: ["Shoot freely up to \(capText).", "Above that, prefer a slower shutter on a support, or add more light, before raising ISO."],
                evidence: evidence, exampleFiles: ex.files, exampleCaptions: ex.captions, counted: counted, total: cam.photos.count)
        }

        // A band falls under the mark above the ceiling.
        let next = failing ?? ceiling
        let topText = ceiling.band.topISO.map { "ISO \($0)" } ?? ceiling.band.label
        let ex = lowestSNR(inBand(next.band))
        var finding = "Noise stays clean up to \(topText) (\(Fmt.db(ceiling.median)) over \(Fmt.count(ceiling.count, "photo")) in \(ceiling.band.label)); at \(next.band.label) it drops to \(Fmt.db(next.median)) (\(Fmt.count(next.count, "photo")))."
        let why: String
        if recovers.isEmpty {
            why = "Higher ISO amplifies the sensor signal and the grain with it. The \(markText) mark is where grain begins to be visible at full size."
        } else {
            finding += " Higher up it reads cleaner again (" + recovers.map(bandText).joined(separator: "; ") + "), so noise here does not simply follow ISO."
            why = "The camera's noise reduction changes with ISO and scene, and this figure is output-referred, so it compares processing as much as the sensor. The \(markText) mark is where grain begins to be visible at full size."
        }
        return Insight(
            id: id, scope: .camera(cam.model), severity: .notice,
            title: "Keep ISO at or below \(topText) for clean pictures",
            finding: finding,
            why: why,
            actions: ["Shoot freely up to \(topText).", "Above that, prefer a slower shutter on a support, or add more light, before raising ISO.", "If you must go higher, expose generously: a bright, noisy frame beats a dark one lifted later."],
            evidence: evidence, exampleFiles: ex.files, exampleCaptions: ex.captions, counted: counted, total: cam.photos.count)
    }

    // MARK: 2. Noise reduction character
    /// Whiteness is read above ISO 160 when at least five clean photos are there: at low noise, scene texture
    /// raises it even without noise reduction (FINDINGS §5 item 5).
    static func noiseCharacter(_ cam: CameraGroup) -> Insight? {
        let s = cam.summary
        let rows: [PhotoRecord]
        let scopeText: String
        if s.whitenessAbove160 != nil {
            rows = cam.photos.filter { $0.snrIsClean && ($0.iso ?? 0) > 160 && $0.noiseWhiteness != nil }
            scopeText = "above ISO 160"
        } else {
            rows = cam.photos.filter { $0.noiseTextureSuspect != true && $0.noiseWhiteness != nil }
            scopeText = "over all ISOs (at low noise, scene texture also raises it)"
        }
        guard let med = Stats.median(rows.compactMap(\.noiseWhiteness)) else { return nil }
        let ex = representative(rows, value: \.noiseWhiteness, caption: { "whiteness " + Fmt.num($1, 2) })
        let ev = [EvidenceItem(metric: "Median noise whiteness, \(scopeText)", value: Fmt.num(med, 2), n: rows.count)]
        let ref = "white noise is \(Fmt.num(Metric.whitenessWhite, 2))"
        let id = "noise-character:\(cam.model)"
        if med < Metric.whitenessSmoothed {
            return Insight(
                id: id, scope: .camera(cam.model), severity: .info,
                title: "Noise is left as fine grain",
                finding: "Noise whiteness is \(Fmt.num(med, 2)) \(scopeText) (\(ref)): the noise is left close to fine grain, with little smoothing.",
                why: "Fine grain looks natural and keeps texture, but it is more visible than smoothed noise at the same level.",
                actions: ["Apply light luminance noise reduction in editing if grain bothers you.", "Fine texture such as hair and foliage is preserved."],
                evidence: ev, exampleFiles: ex.files, exampleCaptions: ex.captions, counted: rows.count, total: cam.photos.count)
        } else if med < Metric.whitenessHeavy {
            return Insight(
                id: id, scope: .camera(cam.model), severity: .info,
                title: "Moderate noise smoothing",
                finding: "Noise whiteness is \(Fmt.num(med, 2)) \(scopeText) (\(ref)): moderate smoothing by the camera, or scene texture left in the flat areas.",
                why: "Some grain has been smoothed away, a fair trade between texture and cleanliness.",
                actions: ["Little action needed; add noise reduction only for high-ISO frames."],
                evidence: ev, exampleFiles: ex.files, exampleCaptions: ex.captions, counted: rows.count, total: cam.photos.count)
        } else {
            return Insight(
                id: id, scope: .camera(cam.model), severity: .notice,
                title: "Strong noise smoothing can soften fine texture",
                finding: "Noise whiteness is \(Fmt.num(med, 2)) \(scopeText) (\(ref); \(Fmt.num(Metric.whitenessHeavy, 1)) and up is heavy smoothing): the camera smooths noise strongly, which can soften fine texture such as hair, foliage and fabric even when the noise number looks good.",
                why: "The camera removes grain by blurring, and blurring cannot tell grain from texture. A clean SNR figure here can hide lost detail.",
                actions: ["Do not add noise reduction in editing: it is already applied.", "Check texture subjects at full size before you sharpen them."],
                evidence: ev, exampleFiles: ex.files, exampleCaptions: ex.captions, counted: rows.count, total: cam.photos.count)
        }
    }

    // MARK: 3. Lens comparison
    /// Human names for a camera's lens groups, from focal-length rank and the word "front".
    static func lensNames(_ lenses: [LensGroup]) -> [String: String] {
        var names: [String: String] = [:]
        let back = lenses.filter { !($0.photos.first?.isFront ?? false) }
            .sorted { ($0.medianFocalMM ?? 0) < ($1.medianFocalMM ?? 0) }
        for l in lenses where l.photos.first?.isFront == true { names[l.name] = "front camera" }
        let ladder: [String]
        switch back.count {
        case 0, 1: ladder = ["main camera"]
        case 2: ladder = ["ultra-wide camera", "main camera"]
        case 3: ladder = ["ultra-wide camera", "main camera", "telephoto camera"]
        default: ladder = ["ultra-wide camera", "main camera", "telephoto camera"] + (3..<back.count).map { "telephoto camera \($0 - 1)" }
        }
        for (i, l) in back.enumerated() {
            let lower = l.name.lowercased()
            names[l.name] = lower.contains("telephoto") ? "telephoto camera" : ladder[min(i, ladder.count - 1)]
        }
        return names
    }

    /// Compares the back lenses only (a selfie camera is not an alternative for the same shot), each on its photos
    /// with at least three valid edges.
    static func lensComparison(_ cam: CameraGroup) -> Insight? {
        guard cam.isPhone else { return nil }
        let names = lensNames(cam.lenses)
        func name(_ l: LensGroup) -> String { names[l.name] ?? l.name }
        let usable = cam.lenses.filter { !$0.isFront && $0.sharpnessCount >= 3 && $0.p80Sharpness != nil }
        guard usable.count >= 2 else { return nil }
        let ranked = usable.sorted { ($0.p80Sharpness ?? 0) > ($1.p80Sharpness ?? 0) }
        let best = ranked[0]
        let bestName = name(best)
        let bestV = best.p80Sharpness ?? 0
        let others = ranked.dropFirst()
        let gaps = others.map { l -> String in
            let gap = (1 - (l.p80Sharpness ?? 0) / bestV) * 100
            return "the \(name(l)) is \(Fmt.num(gap, 0)) % lower (\(Fmt.lwph(l.p80Sharpness ?? 0)), \(Fmt.count(l.sharpnessCount, "photo")))"
        }
        let worstGap = others.map { (1 - ($0.p80Sharpness ?? 0) / bestV) * 100 }.max() ?? 0
        // A per-photo sharpness figure is a +/-30 % band; only call a lens "sharpest" when the runner-up
        // is at least 15 % behind. Otherwise the lenses are a tie and the advice is about the laggards.
        let runnerGap = ranked.count > 1 ? (1 - (ranked[1].p80Sharpness ?? 0) / bestV) * 100 : 100
        let laggards = others.filter { (1 - ($0.p80Sharpness ?? 0) / bestV) * 100 >= 15 }
        let tied = others.filter { (1 - ($0.p80Sharpness ?? 0) / bestV) * 100 < 15 }
        let title: String
        let actions: [String]
        if runnerGap >= 15 {
            title = "The \(bestName) is your sharpest lens"
            actions = laggards.map { "For detail, move closer with the \(bestName) rather than zooming with the \(name($0))." }
        } else {
            let tiedNames = ([bestName] + tied.map(name)).joined(separator: " and ")
            title = laggards.isEmpty ? "Your lenses resolve about the same detail" : "The \(tiedNames) resolve about the same; the others fall behind"
            actions = laggards.map { "For detail, use the \(tiedNames) rather than the \(name($0))." }
                + ["Differences under 15 % are inside the measurement band: treat those lenses as equal."]
        }
        let left = cam.lenses.filter { l in !usable.contains { $0.name == l.name } }
        var notCompared = ""
        if !left.isEmpty {
            notCompared = " Not compared: " + left.map { l in
                l.isFront ? "the \(name(l)) (a selfie camera, not an alternative for the same shot)"
                          : "the \(name(l)) (\(l.sharpnessCount == 0 ? "no photo" : "only \(Fmt.count(l.sharpnessCount, "photo"))") with 3 or more usable edges)"
            }.joined(separator: "; ") + "."
        }
        let sharpCap: (PhotoRecord, Double) -> String = { _, v in Fmt.lwph(v) }
        let fromBest = representative(best.photos, limit: 2, value: \.gatedSharpnessLWPH, caption: sharpCap)
        let fromLag = ranked.count > 1 ? representative(ranked[ranked.count - 1].photos, limit: 2, value: \.gatedSharpnessLWPH, caption: sharpCap) : .none
        let counted = usable.map(\.sharpnessCount).reduce(0, +)
        return Insight(
            id: "lens-comparison:\(cam.model)", scope: .camera(cam.model), severity: worstGap >= 15 ? .notice : .info,
            title: title,
            finding: "Counting only photos with 3 or more usable edges, the \(bestName) resolves \(Fmt.lwph(bestV)) (\(Fmt.count(best.sharpnessCount, "photo"))); " + gaps.joined(separator: "; ") + "." + notCompared,
            why: "Each lens on a phone is a different small camera. The main one usually has the biggest sensor and the best optics; the others trade detail for reach. Gaps under 15 % are within the uncertainty of natural-scene sharpness, and every figure is a lower bound read from real edges.",
            actions: actions,
            evidence: usable.map { EvidenceItem(metric: "Sharpness, \(name($0))", value: Fmt.lwph($0.p80Sharpness ?? 0), n: $0.sharpnessCount) },
            exampleFiles: fromBest.files + fromLag.files, exampleCaptions: fromBest.captions + fromLag.captions,
            counted: counted, total: cam.photos.count)
    }

    // MARK: 4. Field softness
    /// Per lens, on photos with at least three valid edges in both the centre and the outer frame.
    static func fieldSoftness(_ cam: CameraGroup) -> Insight? {
        let names = lensNames(cam.lenses)
        func name(_ l: LensGroup) -> String {
            if cam.isPhone { return names[l.name] ?? l.name }
            return l.name == PhotoRecord.unknownLens ? "lens" : l.name
        }
        let perLens = cam.lenses.compactMap { l -> (lens: LensGroup, median: Double, n: Int)? in
            let r = l.photos.compactMap(\.gatedOuterCentreRatio)
            guard r.count >= minPhotos, let m = Stats.median(r) else { return nil }
            return (l, m, r.count)
        }
        guard let worst = perLens.min(by: { $0.median < $1.median }), worst.median < 0.80 else { return nil }
        let pct = (1 - worst.median) * 100
        let lensName = name(worst.lens)
        let ex = extremes(worst.lens.photos, highest: false, value: \.gatedOuterCentreRatio, caption: { Fmt.num($1, 2) + " outer / centre" })
        let holders = perLens.filter { $0.median >= 0.80 }
        var actions = ["Keep the subject in the central area of the frame when you use the \(lensName)."]
        if cam.isPhone {
            if let h = holders.max(by: { $0.median < $1.median }) {
                actions.append("For detail near the edges of the frame, the \(name(h.lens)) holds up better (outer-to-centre \(Fmt.num(h.median, 2)) over \(Fmt.count(h.n, "photo"))).")
            }
        } else {
            actions.append("Stop down one or two stops: corner sharpness improves faster than centre sharpness.")
        }
        let single = cam.lenses.count == 1
        return Insight(
            id: "field-softness:\(cam.model)", scope: .camera(cam.model), severity: pct >= 30 ? .important : .notice,
            title: single ? "Corners are softer than the centre" : "Corners are softer than the centre on the \(lensName)",
            finding: "On the \(lensName), the outer frame is \(Fmt.num(pct, 0)) % softer than the centre (median outer-to-centre sharpness \(Fmt.num(worst.median, 2)) over \(Fmt.count(worst.n, "photo")) with 3 or more usable edges in both regions).",
            why: "Most lenses resolve best on the axis and fall off toward the corners; wide-open apertures and wide angles show it most. Edges near the frame's edge are also more often out of focus, so read this as a lower bound on the lens.",
            actions: actions,
            evidence: perLens.map { EvidenceItem(metric: "Median outer / centre sharpness, \(name($0.lens))", value: Fmt.num($0.median, 2), n: $0.n) },
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: worst.n, total: worst.lens.photos.count)
    }

    // MARK: 5. Highlight and shadow discipline
    static func highlightDiscipline(_ cam: CameraGroup) -> Insight? {
        let v = cam.photos.compactMap(\.clipHighPct)
        guard let share = Stats.share(v.map { $0 > 1 }), share > 0.15 else { return nil }
        let n = v.filter { $0 > 1 }.count
        let ex = extremes(cam.photos, highest: true, value: \.clipHighPct, caption: { Fmt.pct($1, 1) })
        return Insight(
            id: "highlight-discipline:\(cam.model)", scope: .camera(cam.model), severity: share > 0.3 ? .important : .notice,
            title: "Highlights are often blown out",
            finding: "\(Fmt.share(share)) of your photos (\(n) of \(v.count)) have more than 1 % of the picture blown: at the top of the range in at least one colour channel.",
            why: "A channel at the top of the range holds no detail there, and a JPEG or HEIC cannot bring it back. Cameras expose for the average of the scene, so bright skies and windows run out of range first.",
            actions: ["Dial exposure compensation to -0.3 to -0.7 EV in bright scenes.", "Watch the histogram or zebra stripes and back off when the right edge piles up.", "On iPhone, tap the subject and drag the sun slider down before shooting."],
            evidence: [EvidenceItem(metric: "Photos with over 1 % clipped highlights", value: Fmt.share(share), n: v.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: v.count, total: cam.photos.count)
    }

    static func shadowDiscipline(_ cam: CameraGroup) -> Insight? {
        let v = cam.photos.compactMap(\.clipLowPct)
        guard let share = Stats.share(v.map { $0 > 1 }), share > 0.15 else { return nil }
        let n = v.filter { $0 > 1 }.count
        let ex = extremes(cam.photos, highest: true, value: \.clipLowPct, caption: { Fmt.pct($1, 1) })
        return Insight(
            id: "shadow-discipline:\(cam.model)", scope: .camera(cam.model), severity: .notice,
            title: "Shadows often lose detail",
            finding: "\(n) photos lost shadow detail: \(Fmt.share(share)) of \(v.count) have more than 1 % of the picture crushed to pure black.",
            why: "Pure black holds no detail. If the dark areas are intentional that is fine; if not, the exposure was set for the bright parts.",
            actions: ["Lift exposure compensation by +0.3 to +0.7 EV in high-contrast scenes.", "Or accept dark blacks when the mood calls for it, and keep important subjects out of them."],
            evidence: [EvidenceItem(metric: "Photos with over 1 % crushed shadows", value: Fmt.share(share), n: v.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: v.count, total: cam.photos.count)
    }

    // MARK: 6. Sharpening character
    /// Overshoot counts only on photos with at least three valid edges, and needs five of them.
    static func sharpeningCharacter(_ cam: CameraGroup) -> Insight? {
        let v = cam.photos.compactMap(\.gatedOvershoot)
        guard v.count >= CameraSummary.minRowsForFigure, let med = Stats.median(v), med > Metric.overshootHardPct else { return nil }
        let halo = med >= Metric.overshootHaloPct
        let ex = representative(cam.photos, value: \.gatedOvershoot, caption: { Fmt.pct($1, 1) })
        var actions = ["Never add sharpening in editing.", "Downsize for the web with a soft resampler (bicubic smoother, or Lanczos) so the halos do not double."]
        if !cam.isPhone { actions.insert("Turn down the in-camera style or sharpness setting.", at: 0) }
        return Insight(
            id: "sharpening:\(cam.model)", scope: .camera(cam.model), severity: halo ? .important : .notice,
            title: "This camera sharpens hard",
            finding: "Edges overshoot by \(Fmt.num(med, 1)) % (median over \(Fmt.count(v.count, "photo")) with 3 or more usable edges): hard sharpening" + (halo ? ", which shows as a visible halo." : "; from \(Fmt.int(Metric.overshootHaloPct)) % it shows as a visible halo."),
            why: "In-camera sharpening makes pictures look crisp at small sizes but can show halos and a brittle look when enlarged. Its sharpness numbers are partly the sharpening, not only the lens.",
            actions: actions,
            evidence: [EvidenceItem(metric: "Median overshoot", value: Fmt.pct(med, 1), n: v.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: v.count, total: cam.photos.count)
    }

    // MARK: 7. Colour lean
    /// Plain description of a white-balance lean given medians of R/G and B/G in stops.
    static func leanDescription(r: Double, b: Double) -> (words: String, stops: Double, warm: Double, tint: Double) {
        let warm = r - b          // positive: warm
        let tint = (r + b) / 2    // positive: magenta, negative: green
        let stops = max(abs(r), abs(b))
        var parts: [String] = []
        if abs(warm) >= 0.15 { parts.append(warm > 0 ? "warm" : "cool") }
        if abs(tint) >= 0.15 { parts.append(tint > 0 ? "magenta" : "green") }
        if parts.isEmpty { parts.append(abs(warm) >= abs(tint) ? (warm > 0 ? "warm" : "cool") : (tint > 0 ? "magenta" : "green")) }
        return (parts.joined(separator: " and "), stops, warm, tint)
    }

    static func colourLean(_ cam: CameraGroup) -> Insight? {
        let s = cam.summary
        guard s.wbRStops != nil || s.wbBStops != nil else { return nil }
        let r = s.wbRStops ?? 0, b = s.wbBStops ?? 0
        guard abs(r) > 0.15 || abs(b) > 0.15 else { return nil }
        let d = leanDescription(r: r, b: b)
        let n = s.wbCount
        let ex = extremes(cam.photos, highest: true, value: \.wbLeanStops, caption: { Fmt.stops($1) })
        return Insight(
            id: "colour-lean:\(cam.model)", scope: .camera(cam.model), severity: d.stops >= 0.4 ? .notice : .info,
            title: "Colours lean \(d.words)",
            finding: "This camera renders \(d.words) by \(Fmt.stops(d.stops)) (median over \(Fmt.count(n, "photo"))): R/G \(Fmt.num(r, 2)) stops, B/G \(Fmt.num(b, 2)) stops.",
            why: "A lean in the average of a scene shows up as a tint over greys. Part of it is the scenes you shoot (golden light, blue shade); a consistent lean across many scenes is the camera.",
            actions: ["Set a white-balance preset instead of auto in that light.", "Shoot a grey card once per lighting setup.", "Or correct in editing with Temperature and Tint."],
            evidence: [EvidenceItem(metric: "Median R/G", value: Fmt.stops(r), n: n), EvidenceItem(metric: "Median B/G", value: Fmt.stops(b), n: n)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: n, total: cam.photos.count)
    }

    // MARK: 8. Slow-shutter softness (phones)
    /// Back cameras only, photos with at least three valid edges. Each slow frame is compared with the faster
    /// frames from its own lens, so a slow ultra-wide frame is not set against a fast main-camera median.
    static func slowShutter(_ cam: CameraGroup) -> Insight? {
        guard cam.isPhone else { return nil }
        let slowLimit = 1.0 / 30 - 1e-9
        let rows = cam.photos.filter { !$0.isFront && $0.exposureS != nil && $0.gatedSharpnessLWPH != nil }
        var ratios: [Double] = [], slowVals: [Double] = [], fastVals: [Double] = []
        var slowPhotos: [PhotoRecord] = []
        for (_, lensRows) in Dictionary(grouping: rows, by: \.lensName) {
            let fast = lensRows.filter { ($0.exposureS ?? 0) < slowLimit }.compactMap(\.gatedSharpnessLWPH)
            let slow = lensRows.filter { ($0.exposureS ?? 0) >= slowLimit }
            guard fast.count >= 3, let mf = Stats.median(fast), mf > 0, !slow.isEmpty else { continue }
            let sv = slow.compactMap(\.gatedSharpnessLWPH)
            ratios += sv.map { $0 / mf }
            slowVals += sv
            fastVals += fast
            slowPhotos += slow
        }
        guard ratios.count >= 3, let mr = Stats.median(ratios), let ms = Stats.median(slowVals), let mf = Stats.median(fastVals) else { return nil }
        let pct = (1 - mr) * 100
        guard pct >= 20 else { return nil }
        let ex = extremes(slowPhotos, highest: false, value: \.gatedSharpnessLWPH,
                          caption: { p, v in (p.exposureS.map { Fmt.shutter($0) + ", " } ?? "") + Fmt.lwph(v) })
        return Insight(
            id: "slow-shutter:\(cam.model)", scope: .camera(cam.model), severity: .notice,
            title: "Slow shutter speeds cost sharpness",
            finding: "Frames at 1/30 s or slower were \(Fmt.num(pct, 0)) % softer than faster frames from the same lens (\(Fmt.lwph(ms)) over \(Fmt.count(slowVals.count, "slow photo")), against \(Fmt.lwph(mf)) over \(fastVals.count) faster ones; back cameras only, photos with 3 or more usable edges).",
            why: "Camera or subject movement blurs the whole frame during a long exposure, and stabilisation only buys a stop or two.",
            actions: ["Brace against a wall or rest the phone on a surface.", "Use burst and keep the sharpest frame.", "Raise ISO one stop to buy a faster shutter (see the ISO ceiling for how far you can go)."],
            evidence: [EvidenceItem(metric: "Sharpness at 1/30 s or slower", value: Fmt.lwph(ms), n: slowVals.count),
                       EvidenceItem(metric: "Sharpness at faster speeds, same lenses", value: Fmt.lwph(mf), n: fastVals.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: slowVals.count + fastVals.count, total: cam.photos.count)
    }

    // MARK: 9. Aperture sweet spot (per lens)
    static func apertureSweetSpot(_ cam: CameraGroup) -> [Insight] {
        cam.lenses.compactMap { lens -> Insight? in
            let rows = lens.photos.compactMap { p -> (Double, Double)? in
                guard let f = p.fNumber, let s = p.gatedSharpnessLWPH else { return nil }
                return ((f * 10).rounded() / 10, s)
            }
            let byAperture = Dictionary(grouping: rows, by: \.0)
                .filter { $0.value.count >= 3 }
                .compactMapValues { Stats.median($0.map(\.1)) }
            guard byAperture.count >= 2,
                  let best = byAperture.max(by: { $0.value < $1.value }),
                  let worst = byAperture.min(by: { $0.value < $1.value }) else { return nil }
            let counts = Dictionary(grouping: rows, by: \.0).mapValues(\.count)
            let sharpest = extremes(lens.photos.filter { $0.fNumber.map { ($0 * 10).rounded() / 10 } == best.key },
                                    highest: true, value: \.gatedSharpnessLWPH, caption: { Fmt.lwph($1) })
            let lensLabel = lens.name == PhotoRecord.unknownLens ? "" : " with \(lens.name)"
            let counted = byAperture.keys.map { counts[$0] ?? 0 }.reduce(0, +)
            return Insight(
                id: "aperture:\(cam.model):\(lens.name)", scope: .lens(cam.model, lens.name), severity: .info,
                title: "Sharpest at f/\(Fmt.num(best.key, 1))",
                finding: "\(cam.model)\(lensLabel) is sharpest at f/\(Fmt.num(best.key, 1)) (\(Fmt.lwph(best.value)) over \(counts[best.key] ?? 0) photos) and softest at f/\(Fmt.num(worst.key, 1)) (\(Fmt.lwph(worst.value)) over \(counts[worst.key] ?? 0) photos), counting photos with 3 or more usable edges.",
                why: "Lenses are usually sharpest a couple of stops from wide open. Very small apertures lose detail to diffraction.",
                actions: ["Use f/\(Fmt.num(best.key, 1)) when detail matters and the light allows it.", "Avoid f/\(Fmt.num(worst.key, 1)) for fine detail unless you need the depth of field."],
                evidence: byAperture.sorted { $0.key < $1.key }.map { EvidenceItem(metric: "Sharpness at f/\(Fmt.num($0.key, 1))", value: Fmt.lwph($0.value), n: counts[$0.key] ?? 0) },
                exampleFiles: sharpest.files, exampleCaptions: sharpest.captions, counted: counted, total: lens.photos.count)
        }
    }

    // MARK: Level-edge lean
    /// Two-sided exact sign test: the chance of a split at least this lopsided if left and right were equally likely.
    static func signTestP(_ a: Int, _ b: Int) -> Double {
        let n = a + b
        guard n > 0 else { return 1 }
        let k = min(a, b)
        var tail = 0.0
        for i in 0...k {
            tail += exp(lgamma(Double(n + 1)) - lgamma(Double(i + 1)) - lgamma(Double(n - i + 1)) - Double(n) * log(2.0))
        }
        return min(1, 2 * tail)
    }

    /// A lean in the long level edges. Most such edges are table tops, shelves and frames, not horizons
    /// (FINDINGS §7), so the card says "level edges", counts both sides, and calls it a habit only when the
    /// left/right split is lopsided beyond chance.
    static func levelEdgeLean(_ cam: CameraGroup) -> Insight? {
        let tilts = cam.photos.compactMap(\.structureHorizonTiltDeg)
        guard tilts.count >= minPhotos, let med = Stats.median(tilts), abs(med) >= 0.7 else { return nil }
        let side = med > 0 ? "right" : "left"
        let left = tilts.filter { $0 <= -1 }.count, right = tilts.filter { $0 >= 1 }.count
        let p = signTestP(left, right)
        let habit = p < 0.05 && (med > 0 ? right > left : left > right)
        let sameSide = cam.photos.filter { ($0.structureHorizonTiltDeg ?? 0) * med > 0 }
        let ex = extremes(sameSide, highest: true, value: { $0.structureHorizonTiltDeg.map(abs) },
                          caption: { p, _ in signedDegrees(p.structureHorizonTiltDeg ?? 0) })
        let x = Fmt.num(abs(med), 1)
        let pText = p < 0.001 ? "under 0.001" : Fmt.num(p, p < 0.01 ? 3 : 2)
        let edgeNote = "A level edge is not always a horizon: table tops, shelves and window frames seen at an angle count too, so check the examples."
        return Insight(
            id: "level-edge-lean:\(cam.model)", scope: .camera(cam.model), severity: habit ? .notice : .info,
            title: "Your level edges lean \(side) by \(x)°",
            finding: "Across \(Fmt.count(tilts.count, "photo")) with a long level edge, the median tilt is \(x)° (\(side) end lower); \(left) lean left and \(right) lean right by a degree or more.",
            why: habit
                ? "A split that lopsided is unlikely to be chance (sign test p = \(pText)), so it points to how the camera is held or mounted. " + edgeNote
                : "The split is not lopsided enough to call it a habit (sign test p = \(pText)); it may be the scenes. " + edgeNote,
            actions: ["Turn on the level or grid in the camera app and line a straight edge up with it before you shoot.",
                      "If you use a tripod, check the head is level with the bubble or the built-in level.",
                      "Straighten only photos whose edge should be level; each photo's note gives the angle."],
            evidence: [EvidenceItem(metric: "Median level-edge tilt (positive = right end lower)", value: Fmt.num(med, 1) + "°", n: tilts.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: tilts.count, total: cam.photos.count)
    }

    // MARK: Shallow depth of field habit
    static func shallowDepthHabit(_ cam: CameraGroup) -> Insight? {
        let n = cam.photos.count
        let k = cam.photos.filter(\.hasFocusSplit).count
        guard n >= minPhotos, Double(k) / Double(n) >= 0.30 else { return nil }
        let ex = extremes(cam.photos, highest: true,
                          value: { p in p.mtf50InfocusCPP.flatMap { s in p.mtf50BackgroundCPP.map { s - $0 } } },
                          caption: { p, _ in Fmt.num(p.mtf50InfocusCPP ?? 0, 2) + " vs " + Fmt.num(p.mtf50BackgroundCPP ?? 0, 2) + " c/px" })
        return Insight(
            id: "shallow-dof:\(cam.model)", scope: .camera(cam.model), severity: .info,
            title: "You shoot a lot of shallow depth of field",
            finding: "\(Fmt.share(Double(k) / Double(n))) of your photos (\(k) of \(n)) split into a sharp subject and a soft background.",
            why: "On those frames the median edge sharpness includes the blurred background, so it reads low. The p80 figure usually lands on the subject, but when in-focus edges are few it can read the background too; the photo's sharp-group figure is then the one to read.",
            actions: ["On split frames, read each photo's sharp-group figure as its in-focus sharpness.", "When you sharpen in editing, mask the subject instead of sharpening the whole frame."],
            evidence: [EvidenceItem(metric: "Photos with a clean sharp / soft split", value: Fmt.share(Double(k) / Double(n)), n: n)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: n, total: n)
    }
}
