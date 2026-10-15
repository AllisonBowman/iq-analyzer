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
    static func isoCeiling(_ cam: CameraGroup) -> Insight? {
        let bands = cam.summary.snrByBand.filter { $0.count >= minPerBand }
        guard !bands.isEmpty else { return nil }
        let evidence = bands.map { EvidenceItem(metric: "Median SNR, \($0.band.label)", value: Fmt.db($0.median), n: $0.count) }
        func lowestSNR(_ rows: [PhotoRecord]) -> Examples {
            extremes(rows, highest: false, value: \.snrMidgreyDB, caption: { Fmt.db($1) })
        }
        func inBand(_ b: ISOBand) -> [PhotoRecord] { cam.photos.filter { $0.iso.map(ISOBand.band(for:)) == b } }
        guard let ceiling = bands.last(where: { $0.median >= 32 }) else {
            let first = bands[0]
            return Insight(
                id: "iso-ceiling:\(cam.model)", scope: .camera(cam.model), severity: .important,
                title: "Noise is visible at every ISO you used",
                finding: "Median noise is \(Fmt.db(first.median)) even in \(first.band.label) (\(Fmt.count(first.count, "photo"))), below the 32 dB mark for clean.",
                why: "Below about 32 dB grain starts to show at full size. Much of this figure is the camera's own processing and compression, so it will not change much with settings alone.",
                actions: ["Shoot in the brightest light you can find.", "Use a support and a slower shutter instead of a higher ISO.", "Plan on gentle noise reduction when you edit."],
                evidence: evidence, exampleFiles: lowestSNR(inBand(first.band)).files, exampleCaptions: lowestSNR(inBand(first.band)).captions)
        }
        let isHighest = ceiling.band == bands.last?.band
        if isHighest {
            return Insight(
                id: "iso-ceiling:\(cam.model)", scope: .camera(cam.model), severity: .info,
                title: "Noise is clean at every ISO you have used",
                finding: "Noise stays clean at every ISO you have used, up to \(ceiling.band.label) (\(Fmt.db(ceiling.median)) over \(Fmt.count(ceiling.count, "photo"))).",
                why: "A signal-to-noise figure of 32 dB or more means grain is hard to see at full size.",
                actions: ["Clean at every ISO you have used: raise ISO rather than risk a blurred shot.", "Try a higher ISO in dim light to see where the limit is."],
                evidence: evidence, exampleFiles: lowestSNR(inBand(ceiling.band)).files, exampleCaptions: lowestSNR(inBand(ceiling.band)).captions)
        }
        let above = cam.photos.filter { p in p.iso.map { ISOBand.band(for: $0) > ceiling.band } == true }
        let shown = lowestSNR(above.contains { $0.snrMidgreyDB != nil } ? above : inBand(ceiling.band))
        let next = bands.first { $0.band > ceiling.band }
        let nextText = next.map { "above that it drops to \(Fmt.db($0.median))" } ?? "above that it drops further"
        let topText = ceiling.band.topISO.map { "ISO \($0)" } ?? ceiling.band.label
        return Insight(
            id: "iso-ceiling:\(cam.model)", scope: .camera(cam.model), severity: .notice,
            title: "Keep ISO at or below \(topText) for clean pictures",
            finding: "Noise stays clean up to \(topText) (\(Fmt.db(ceiling.median)) over \(Fmt.count(ceiling.count, "photo"))); \(nextText).",
            why: "Higher ISO amplifies the sensor signal and the grain with it. The 32 dB mark is where grain begins to be visible at full size.",
            actions: ["Shoot freely up to \(topText).", "Above that, prefer a slower shutter on a support, or add more light, before raising ISO.", "If you must go higher, expose generously: a bright, noisy frame beats a dark one lifted later."],
            evidence: evidence, exampleFiles: shown.files, exampleCaptions: shown.captions)
    }

    // MARK: 2. Noise reduction character
    static func noiseCharacter(_ cam: CameraGroup) -> Insight? {
        let w = cam.photos.compactMap(\.noiseWhiteness)
        guard let med = Stats.median(w) else { return nil }
        let ex = representative(cam.photos, value: \.noiseWhiteness, caption: { "whiteness " + Fmt.num($1, 2) })
        let ev = [EvidenceItem(metric: "Median noise whiteness", value: Fmt.num(med, 2), n: w.count)]
        if med < 0.2 {
            return Insight(
                id: "noise-character:\(cam.model)", scope: .camera(cam.model), severity: .info,
                title: "Noise is left as fine grain",
                finding: "Noise whiteness is \(Fmt.num(med, 2)) (white noise is 0.14): the noise is left as fine grain, with little smoothing.",
                why: "Fine grain looks natural and keeps texture, but it is more visible than smoothed noise at the same level.",
                actions: ["Apply light luminance noise reduction in editing if grain bothers you.", "Fine texture such as hair and foliage is preserved."],
                evidence: ev, exampleFiles: ex.files, exampleCaptions: ex.captions)
        } else if med < 0.4 {
            return Insight(
                id: "noise-character:\(cam.model)", scope: .camera(cam.model), severity: .info,
                title: "Moderate noise smoothing",
                finding: "Noise whiteness is \(Fmt.num(med, 2)): moderate smoothing by the camera.",
                why: "Some grain has been smoothed away, a fair trade between texture and cleanliness.",
                actions: ["Little action needed; add noise reduction only for high-ISO frames."],
                evidence: ev, exampleFiles: ex.files, exampleCaptions: ex.captions)
        } else {
            return Insight(
                id: "noise-character:\(cam.model)", scope: .camera(cam.model), severity: .notice,
                title: "Strong noise smoothing softens fine texture",
                finding: "Noise whiteness is \(Fmt.num(med, 2)): strong smoothing. Fine texture (hair, foliage, fabric) softens at higher ISO even though the noise number looks good.",
                why: "The camera removes grain by blurring, and blurring cannot tell grain from texture. A clean SNR figure here can hide lost detail.",
                actions: ["Keep ISO low for texture subjects.", "Do not add noise reduction in editing: it is already applied."],
                evidence: ev, exampleFiles: ex.files, exampleCaptions: ex.captions)
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

    static func lensComparison(_ cam: CameraGroup) -> Insight? {
        guard cam.isPhone else { return nil }
        let usable = cam.lenses.filter { $0.sharpnessCount >= 3 && $0.p80Sharpness != nil }
        guard usable.count >= 2 else { return nil }
        let names = lensNames(cam.lenses)
        let ranked = usable.sorted { ($0.p80Sharpness ?? 0) > ($1.p80Sharpness ?? 0) }
        let best = ranked[0]
        let bestName = names[best.name] ?? best.name
        let bestV = best.p80Sharpness ?? 0
        let others = ranked.dropFirst()
        let gaps = others.map { l -> String in
            let gap = (1 - (l.p80Sharpness ?? 0) / bestV) * 100
            return "the \(names[l.name] ?? l.name) is \(Fmt.num(gap, 0)) % lower (\(Fmt.lwph(l.p80Sharpness ?? 0)))"
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
            actions = laggards.map { "For detail, move closer with the \(bestName) rather than zooming with the \(names[$0.name] ?? $0.name)." }
        } else {
            let tiedNames = ([bestName] + tied.map { names[$0.name] ?? $0.name }).joined(separator: " and ")
            title = laggards.isEmpty ? "Your lenses resolve about the same detail" : "The \(tiedNames) resolve about the same; the others fall behind"
            actions = laggards.map { "For detail, use the \(tiedNames) rather than the \(names[$0.name] ?? $0.name)." }
                + ["Differences under 15 % are inside the measurement band: treat those lenses as equal."]
        }
        let sharpCap: (PhotoRecord, Double) -> String = { _, v in Fmt.lwph(v) }
        let fromBest = representative(best.photos, limit: 2, value: \.mtf50P80LWPH, caption: sharpCap)
        let fromLag = ranked.count > 1 ? representative(ranked[ranked.count - 1].photos, limit: 2, value: \.mtf50P80LWPH, caption: sharpCap) : .none
        return Insight(
            id: "lens-comparison:\(cam.model)", scope: .camera(cam.model), severity: worstGap >= 15 ? .notice : .info,
            title: title,
            finding: "The \(bestName) resolves \(Fmt.lwph(bestV)) (\(Fmt.count(best.sharpnessCount, "photo"))); " + gaps.joined(separator: "; ") + ".",
            why: "Each lens on a phone is a different small camera. The main one usually has the biggest sensor and the best optics; the others trade detail for reach. Gaps under 15 % are within the uncertainty of natural-scene sharpness.",
            actions: actions,
            evidence: usable.map { EvidenceItem(metric: "Sharpness, \(names[$0.name] ?? $0.name)", value: Fmt.lwph($0.p80Sharpness ?? 0), n: $0.sharpnessCount) },
            exampleFiles: fromBest.files + fromLag.files, exampleCaptions: fromBest.captions + fromLag.captions)
    }

    // MARK: 4. Field softness
    static func outerCentreRatio(_ p: PhotoRecord) -> Double? {
        guard let c = p.mtf50CenterMedianCPP, let o = p.mtf50OuterMedianCPP, c > 0 else { return nil }
        return o / c
    }

    static func fieldSoftness(_ cam: CameraGroup) -> Insight? {
        let ratios = cam.photos.compactMap { p -> Double? in
            guard let c = p.mtf50CenterMedianCPP, let o = p.mtf50OuterMedianCPP, c > 0 else { return nil }
            return o / c
        }
        guard ratios.count >= 3, let med = Stats.median(ratios), med < 0.80 else { return nil }
        let pct = (1 - med) * 100
        let ex = extremes(cam.photos, highest: false, value: Self.outerCentreRatio, caption: { Fmt.num($1, 2) + " outer / centre" })
        let action = cam.isPhone
            ? "Avoid the ultra-wide for detail near the edges of the frame."
            : "Stop down one or two stops: corner sharpness improves faster than centre sharpness."
        return Insight(
            id: "field-softness:\(cam.model)", scope: .camera(cam.model), severity: pct >= 30 ? .important : .notice,
            title: "Corners are softer than the centre",
            finding: "Corners are \(Fmt.num(pct, 0)) % softer than the centre (outer-to-centre sharpness \(Fmt.num(med, 2)), over \(Fmt.count(ratios.count, "photo"))).",
            why: "Most lenses resolve best on the axis and fall off toward the corners; wide-open apertures and wide angles show it most.",
            actions: ["Keep the subject in the central area of the frame.", action],
            evidence: [EvidenceItem(metric: "Median outer / centre sharpness", value: Fmt.num(med, 2), n: ratios.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions)
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
            finding: "\(Fmt.share(share)) of your photos (\(n) of \(v.count)) have more than 1 % of the picture blown to pure white.",
            why: "Pure white holds no detail and cannot be recovered in a JPEG or HEIC. Cameras expose for the average of the scene, so bright skies and windows run out of range first.",
            actions: ["Dial exposure compensation to -0.3 to -0.7 EV in bright scenes.", "Watch the histogram or zebra stripes and back off when the right edge piles up.", "On iPhone, tap the subject and drag the sun slider down before shooting."],
            evidence: [EvidenceItem(metric: "Photos with over 1 % clipped highlights", value: Fmt.share(share), n: v.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions)
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
            exampleFiles: ex.files, exampleCaptions: ex.captions)
    }

    // MARK: 6. Sharpening character
    static func sharpeningCharacter(_ cam: CameraGroup) -> Insight? {
        let v = cam.photos.compactMap(\.overshootMedianPct)
        guard let med = Stats.median(v), med > 8 else { return nil }
        let ex = extremes(cam.photos, highest: true, value: \.overshootMedianPct, caption: { Fmt.pct($1, 1) })
        return Insight(
            id: "sharpening:\(cam.model)", scope: .camera(cam.model), severity: med >= 15 ? .important : .notice,
            title: "This camera sharpens hard",
            finding: "This camera sharpens hard: edges overshoot by \(Fmt.num(med, 1)) % (median over \(Fmt.count(v.count, "photo"))), which shows as a bright halo.",
            why: "In-camera sharpening makes pictures look crisp at small sizes but can show halos and a brittle look when enlarged. Its sharpness numbers are partly the sharpening, not only the lens.",
            actions: ["Turn down the in-camera style or sharpness setting if the camera offers it.", "Never add sharpening in editing.", "Downsize for the web with a soft resampler (bicubic smoother, or Lanczos) so the halos do not double."],
            evidence: [EvidenceItem(metric: "Median overshoot", value: Fmt.pct(med, 1), n: v.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions)
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
        let n = cam.photos.filter { $0.wbROverGStops != nil || $0.wbBOverGStops != nil }.count
        let ex = extremes(cam.photos, highest: true, value: \.wbLeanStops, caption: { Fmt.stops($1) })
        return Insight(
            id: "colour-lean:\(cam.model)", scope: .camera(cam.model), severity: d.stops >= 0.4 ? .notice : .info,
            title: "Colours lean \(d.words)",
            finding: "This camera renders \(d.words) by \(Fmt.stops(d.stops)) (median over \(Fmt.count(n, "photo"))): R/G \(Fmt.num(r, 2)) stops, B/G \(Fmt.num(b, 2)) stops.",
            why: "A lean in the average of a scene shows up as a tint over greys. Part of it is the scenes you shoot (golden light, blue shade); a consistent lean across many scenes is the camera.",
            actions: ["Set a white-balance preset instead of auto in that light.", "Shoot a grey card once per lighting setup.", "Or correct in editing with Temperature and Tint."],
            evidence: [EvidenceItem(metric: "Median R/G", value: Fmt.stops(r), n: n), EvidenceItem(metric: "Median B/G", value: Fmt.stops(b), n: n)],
            exampleFiles: ex.files, exampleCaptions: ex.captions)
    }

    // MARK: 8. Slow-shutter softness (phones)
    static func slowShutter(_ cam: CameraGroup) -> Insight? {
        guard cam.isPhone else { return nil }
        let rows = cam.photos.compactMap { p -> (Double, Double)? in
            guard let e = p.exposureS, let s = p.mtf50P80LWPH else { return nil }
            return (e, s)
        }
        let slow = rows.filter { $0.0 >= 1.0 / 30 - 1e-9 }.map(\.1)
        let fast = rows.filter { $0.0 < 1.0 / 30 - 1e-9 }.map(\.1)
        guard slow.count >= 3, fast.count >= 3, let ms = Stats.median(slow), let mf = Stats.median(fast), mf > 0 else { return nil }
        let pct = (1 - ms / mf) * 100
        guard pct >= 20 else { return nil }
        let slowPhotos = cam.photos.filter { ($0.exposureS ?? 0) >= 1.0 / 30 - 1e-9 }
        let ex = extremes(slowPhotos, highest: false, value: \.mtf50P80LWPH,
                          caption: { p, v in (p.exposureS.map { Fmt.shutter($0) + ", " } ?? "") + Fmt.lwph(v) })
        return Insight(
            id: "slow-shutter:\(cam.model)", scope: .camera(cam.model), severity: .notice,
            title: "Slow shutter speeds cost sharpness",
            finding: "Hand-held frames at 1/30 s or slower were \(Fmt.num(pct, 0)) % softer (\(Fmt.lwph(ms)) over \(slow.count) photos, against \(Fmt.lwph(mf)) over \(fast.count) at faster speeds).",
            why: "Hand shake blurs the whole frame during a long exposure, and stabilisation only buys a stop or two.",
            actions: ["Brace against a wall or rest the phone on a surface.", "Use burst and keep the sharpest frame.", "Raise ISO one stop to buy a faster shutter (see the ISO ceiling for how far you can go)."],
            evidence: [EvidenceItem(metric: "Sharpness at 1/30 s or slower", value: Fmt.lwph(ms), n: slow.count),
                       EvidenceItem(metric: "Sharpness at faster speeds", value: Fmt.lwph(mf), n: fast.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions)
    }

    // MARK: 9. Aperture sweet spot (per lens)
    static func apertureSweetSpot(_ cam: CameraGroup) -> [Insight] {
        cam.lenses.compactMap { lens -> Insight? in
            let rows = lens.photos.compactMap { p -> (Double, Double)? in
                guard let f = p.fNumber, let s = p.mtf50P80LWPH else { return nil }
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
                                    highest: true, value: \.mtf50P80LWPH, caption: { Fmt.lwph($1) })
            let lensLabel = lens.name == PhotoRecord.unknownLens ? "" : " with \(lens.name)"
            return Insight(
                id: "aperture:\(cam.model):\(lens.name)", scope: .lens(cam.model, lens.name), severity: .info,
                title: "Sharpest at f/\(Fmt.num(best.key, 1))",
                finding: "\(cam.model)\(lensLabel) is sharpest at f/\(Fmt.num(best.key, 1)) (\(Fmt.lwph(best.value)) over \(counts[best.key] ?? 0) photos) and softest at f/\(Fmt.num(worst.key, 1)) (\(Fmt.lwph(worst.value)) over \(counts[worst.key] ?? 0) photos).",
                why: "Lenses are usually sharpest a couple of stops from wide open. Very small apertures lose detail to diffraction.",
                actions: ["Use f/\(Fmt.num(best.key, 1)) when detail matters and the light allows it.", "Avoid f/\(Fmt.num(worst.key, 1)) for fine detail unless you need the depth of field."],
                evidence: byAperture.sorted { $0.key < $1.key }.map { EvidenceItem(metric: "Sharpness at f/\(Fmt.num($0.key, 1))", value: Fmt.lwph($0.value), n: counts[$0.key] ?? 0) },
                exampleFiles: sharpest.files, exampleCaptions: sharpest.captions)
        }
    }

    // MARK: 10. Sharpness confidence
    static func sharpnessConfidence(_ cam: CameraGroup) -> Insight? {
        let w = cam.photos.compactMap(\.relativeCIWidth)
        guard let med = Stats.median(w), med > 0.5 else { return nil }
        let ex = representative(cam.photos, value: \.relativeCIWidth, caption: { "\u{00B1}" + Fmt.num($1 * 50, 0) + " %" })
        return Insight(
            id: "sharpness-confidence:\(cam.model)", scope: .camera(cam.model), severity: .info,
            title: "Read single-photo sharpness loosely",
            finding: "The median confidence interval on a photo's sharpness is \(Fmt.num(med * 100, 0)) % of the value itself (over \(Fmt.count(w.count, "photo"))).",
            why: "Per-photo sharpness figures on natural scenes are bands of roughly 30 % either way, because a handful of edges from one frame cannot pin the number down. The per-camera medians pool many photos and are the figures to trust.",
            actions: ["Compare cameras and lenses by their medians, not by single photos.", "Treat a gap between two photos of under 30 % as a tie."],
            evidence: [EvidenceItem(metric: "Median relative CI width", value: Fmt.share(med), n: w.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions)
    }

    // MARK: Horizon lean
    static func horizonLean(_ cam: CameraGroup) -> Insight? {
        let tilts = cam.photos.compactMap(\.structureHorizonTiltDeg)
        guard tilts.count >= minPhotos, let med = Stats.median(tilts), abs(med) >= 0.7 else { return nil }
        let side = med > 0 ? "right" : "left"
        let ex = extremes(cam.photos, highest: true, value: { $0.structureHorizonTiltDeg.map(abs) },
                          caption: { p, _ in signedDegrees(p.structureHorizonTiltDeg ?? 0) })
        let x = Fmt.num(abs(med), 1)
        return Insight(
            id: "horizon-lean:\(cam.model)", scope: .camera(cam.model), severity: .notice,
            title: "Your horizons lean \(side) by \(x)°",
            finding: "Across \(Fmt.count(tilts.count, "photo")) with a level edge, the median horizon is tilted \(x)°, with the \(side) end lower.",
            why: "A consistent lean points to a habit in how the camera is held or mounted, not to chance, and every photo then needs straightening and cropping.",
            actions: ["Turn on the level or grid in the camera app and line the horizon up before you shoot.",
                      "If you use a tripod, check the head is level with the bubble or the built-in level.",
                      "Straighten in editing for photos you already have; the per-photo advice gives the angle."],
            evidence: [EvidenceItem(metric: "Median horizon tilt (positive = right end lower)", value: Fmt.num(med, 1) + "°", n: tilts.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions)
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
            why: "On those frames the median edge sharpness includes the blurred background, so it reads low. The p80 figure is the subject; the median includes the background.",
            actions: ["Read the p80 (in-focus) sharpness as the lens figure for this camera.", "When you sharpen in editing, mask the subject instead of sharpening the whole frame."],
            evidence: [EvidenceItem(metric: "Photos with a clean sharp / soft split", value: Fmt.share(Double(k) / Double(n)), n: n)],
            exampleFiles: ex.files, exampleCaptions: ex.captions)
    }
}
