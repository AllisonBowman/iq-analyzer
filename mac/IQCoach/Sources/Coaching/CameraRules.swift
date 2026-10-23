import Foundation

/// Camera-level coaching rules (feedback-layers spec §4.6). Each is a pure function of a camera group and the
/// photographer's intent tags. It returns a finding, a silent check with its numbers, or `.notApplicable`.
/// The one-argument overloads return just the finding, for call sites and tests that only need that.
enum CameraRules {
    static let minPhotos = 5
    static let minPerBand = CameraSummary.minPerBand
    /// The share line of the clipping rules: more than this share of photos over 1 % fires.
    static let clipShareLine = 0.15
    /// The per-photo clipping line, in percent of the frame.
    static let clipPhotoPct = 1.0

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

    // MARK: How sure

    /// The "How sure" sentence of a rule's popover: the evidence word, its reason, and the range for share rules.
    static func howSure(_ grade: EvidenceGrade, counted: Int, kind: EvidenceKind, share: ShareCount? = nil, line: Double? = nil) -> String {
        let n = Fmt.count(counted, "photo")
        if let share, let line {
            let r = Fmt.shareRange(share.range), between = Fmt.shareBetween(share.range), l = Fmt.share(line)
            switch grade {
            case .thin where counted >= EvidenceGrade.thinBelow:
                return "Thin: with \(n) the share could be anywhere from \(r), which crosses the \(l) line."
            case .thin: return "Thin: only \(n); allowing for chance the share could be anywhere from \(r)."
            default:
                return "\(grade.word): \(n), and allowing for chance the share is between \(between), clear of the \(l) line."
            }
        }
        if grade == .thin { return "Thin: only \(n) passed the rule's checks; fewer than \(EvidenceGrade.thinBelow) cannot show a pattern." }
        switch kind {
        case .edgeBased: return "\(grade.word): \(n). Read from natural edges in your scenes, so every figure is a lower bound that depends on what was photographed; rules of this kind never rise above Moderate."
        case .sceneDependent: return "\(grade.word): \(n). It rests on an assumption a scene can break, so rules of this kind never rise above Moderate."
        case .measured: return "\(grade.word): \(n) with a clean reading\(grade == .solid ? "" : "; Solid needs \(EvidenceGrade.solidFrom)")."
        case .pixelCount: return "\(grade.word): \(n), counted pixel by pixel."
        }
    }

    // MARK: 1. Noise by ISO
    /// Clean rows only, ISO bands with at least three photos. A camera whose noise follows ISO gets a ceiling (or
    /// "clean at every ISO"); one whose noise does not gets "Noise does not follow ISO", listing every band. The
    /// ceiling is the top of the unbroken run of bands, from the lowest, whose medians are at or above the clean mark;
    /// the open-ended top band is checked at the highest ISO actually used.
    static func noiseByISO(_ cam: CameraGroup) -> Insight? { noiseByISO(cam, .none).insight }

    static func noiseByISO(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        let s = cam.summary
        let mark = Metric.snrCleanDB
        let markText = Fmt.db(mark)
        let device = CameraVocabulary.device(phone: cam.isPhone)
        let bands = s.ratedBands
        let clean = cam.photos.filter { $0.snrIsClean && $0.iso != nil }
        let name = "Noise by ISO"
        let id = "noise-by-iso:\(cam.model)"
        guard !clean.isEmpty else { return .notApplicable }
        guard !bands.isEmpty else {
            return .silent(SilentCheck(id: id, name: name, reason: "no ISO band has \(minPerBand) clean noise readings (\(Fmt.count(clean.count, "clean photo")) in all)."))
        }
        let evidence = bands.map { EvidenceItem(metric: "Median SNR, \($0.band.label)", value: Fmt.db($0.median), n: $0.count) }
        let counted = bands.map(\.count).reduce(0, +)
        let grade = EvidenceGrade.grade(counted: counted, kind: .measured)
        let left = s.snrExcluded.map(\.count).reduce(0, +)
        let countedText = "\(counted) of \(Fmt.count(cam.photos.count, "photo")): those with a clean noise reading in an ISO band with \(minPerBand) or more" + (left > 0 ? "; \(left) left out (" + s.snrExcluded.map { "\($0.count): \($0.reason)" }.joined(separator: "; ") + ")." : ".")
        func inBand(_ b: ISOBand) -> [PhotoRecord] { clean.filter { $0.iso.map(ISOBand.band(for:)) == b } }
        func lowestSNR(_ rows: [PhotoRecord]) -> Examples {
            extremes(rows, highest: false, value: \.snrMidgreyDB, caption: { Fmt.db($1) })
        }
        func bandText(_ b: SNRBandStat) -> String { "\(b.band.label) \(Fmt.db(b.median)) (\(Fmt.count(b.count, "photo")))" }
        let cannotTell = "This figure is measured on the finished file, so noise reduction and compression lower it as much as the sensor does: it compares the \(device)'s processing across ISO, not its sensor."
        let checkYourself = "Photograph the same plain wall in bright light and in dim light and analyze both; the \(device) will pick different ISOs."
        let ruleText = "Groups the clean noise readings into ISO bands with \(minPerBand) or more photos. If no band median rises more than \(Fmt.num(CameraSummary.followsISOToleranceDB, 0)) dB above the band below it, noise follows ISO and the card gives the highest ISO that stays at or above \(markText); otherwise it says noise does not follow ISO."
        func why(_ how: String? = nil) -> WhyShown {
            WhyShown(rule: ruleText, counted: countedText, howSure: how ?? howSure(grade, counted: counted, kind: .measured),
                     cannotTell: cannotTell, checkYourself: checkYourself)
        }
        func base(severity: Severity, title: String, finding: String, why w: String, actions: [Action], ex: Examples) -> Insight {
            var i = Insight(id: id, scope: .camera(cam.model), severity: severity, title: title, finding: finding, why: w,
                            actions: actions, evidence: evidence, exampleFiles: ex.files, exampleCaptions: ex.captions,
                            counted: counted, total: cam.photos.count)
            i.grade = grade; i.kind = .measured; i.excluded = s.snrExcluded; i.ruleOrder = 2; i.whyShown = why()
            return i
        }

        // Noise does not follow ISO: processing, not the sensor.
        if s.snrFollowsISO == false {
            let top = bands.last!
            let topFew = top.band == .above1000 && top.count < 10
            let listed = topFew ? Array(bands.dropLast()) : bands
            var finding = "Median noise is " + listed.map { "\(Fmt.db($0.median)) at \($0.band.label) (\($0.count))" }.joined(separator: ", ") + "."
            if topFew {
                let v = inBand(.above1000).compactMap(\.snrMidgreyDB)
                finding += " Above ISO 1000 your \(Fmt.count(v.count, "photo")) range from \(Fmt.db(v.min() ?? 0)) to \(Fmt.db(v.max() ?? 0)), too few to say where grain starts."
            }
            let bounded = bands.filter { $0.band.topISO != nil }
            let allClean = !bounded.isEmpty && bounded.allSatisfy { $0.median >= mark }
            let topBounded = bounded.last?.band.topISO.map { "ISO \($0)" } ?? ""
            let lowest = bands.min { $0.median < $1.median }!, cleanest = bands.max { $0.median < $1.median }!
            let action = allClean
                ? "Do not chase a low ISO for clean pictures on this \(device): up to \(topBounded) every ISO band has a median of \(markText) or more."
                : "Do not chase a low ISO for clean pictures on this \(device): ISO alone does not predict noise here (\(lowest.band.label) reads \(Fmt.db(lowest.median)), \(cleanest.band.label) \(Fmt.db(cleanest.median)))."
            var i = base(severity: .info, title: "Noise does not follow ISO on this \(device)", finding: finding,
                         why: "The \(device)'s noise reduction rises with ISO and holds the output roughly level, so this figure compares its processing, not its sensor; that is why some higher-ISO bands read cleaner than lower ones.",
                         actions: [.camera(action)], ex: lowestSNR(inBand(lowest.band)))
            i.brief = allClean
                ? "noise does not follow ISO on this \(device); up to \(topBounded) every ISO band has a median of \(markText) or more"
                : "noise does not follow ISO on this \(device), so ISO alone does not predict it"
            if topFew { i.whatWouldChange = "10 or more photos above ISO 1000." }
            return .fired(i)
        }

        let run = Array(bands.prefix { $0.median >= mark })
        let failing = bands.first { $0.median < mark }
        let recovers = failing.map { f in bands.filter { $0.band > f.band && $0.median >= mark } } ?? []
        let follows = s.snrFollowsISO == true ? "Noise falls with ISO the way a sensor's does. " : ""

        // No band passes from the bottom.
        guard let ceiling = run.last else {
            let first = bands[0]
            // Important only when the lowest band is visibly noisy (the Poor band); between that and the clean mark
            // grain is only starting to show.
            var i = base(severity: first.median < Metric.snrNoisyDB ? .important : .notice, title: "Noise is visible at every ISO you used",
                         finding: "Median noise is \(Fmt.db(first.median)) even in \(first.band.label) (\(Fmt.count(first.count, "photo"))), below the \(markText) mark for clean." + (recovers.isEmpty ? "" : " Higher up it reads cleaner again (" + recovers.map(bandText).joined(separator: "; ") + "), so noise here does not simply follow ISO."),
                         why: "Below about \(markText) grain starts to show at full size. Much of this figure is the \(device)'s own processing and compression, so it will not change much with settings alone.",
                         actions: [.camera("Shoot in the brightest light you can find."),
                                   .camera("Use a support and a slower shutter instead of a higher ISO."),
                                   .editor("Plan on gentle noise reduction when you edit.")],
                         ex: lowestSNR(inBand(first.band)))
            // Not a one-thing candidate: the level is the processing's, and no habit at the camera changes it reliably.
            i.brief = "noise is under the \(markText) clean mark even at \(first.band.label)"
            return .fired(i)
        }

        // Every band passes.
        if failing == nil {
            let topRows = inBand(ceiling.band)
            let isos = Array(Set(topRows.compactMap(\.iso))).sorted()
            guard let maxISO = isos.last else { return .notApplicable }
            func medianAt(_ iso: Double) -> Double? { Stats.median(topRows.filter { $0.iso == iso }.compactMap(\.snrMidgreyDB)) }
            let atMax = medianAt(maxISO) ?? ceiling.median
            if ceiling.band.topISO != nil || atMax >= mark {
                var i = base(severity: .info, title: "Noise is clean at every ISO you have used",
                             finding: follows + "Noise stays clean at every ISO you have used, up to \(Fmt.iso(maxISO)), the highest (\(ceiling.band.label): \(Fmt.db(ceiling.median)) over \(Fmt.count(ceiling.count, "photo"))).",
                             why: "A signal-to-noise figure of \(markText) or more means grain is hard to see at full size.",
                             actions: [.camera("Raise ISO rather than risk a blurred shot: it was clean at every ISO you have used."),
                                       .camera("Try a higher ISO in dim light to see where the limit is.")],
                             ex: lowestSNR(topRows))
                i.brief = (s.snrFollowsISO == true ? "noise falls with ISO the way a sensor's does, and " : "") + "every ISO band you used has a median of \(markText) or more"
                return .fired(i)
            }
            // The open-ended band passes as a whole, but not at the highest ISO used: cap the claim at the top of the
            // unbroken run of ISOs in that band whose own photos are clean.
            let capISO = isos.prefix { (medianAt($0) ?? 0) >= mark }.last
            let capText = capISO.map { Fmt.iso($0) } ?? "ISO 1000"
            let nAtMax = topRows.filter { $0.iso == maxISO }.count
            var i = base(severity: .notice, title: "Keep ISO at or below \(capText) for clean pictures",
                         finding: follows + "Noise stays clean up to \(capText) (\(ceiling.band.label): \(Fmt.db(ceiling.median)) over \(Fmt.count(ceiling.count, "photo"))), but at \(Fmt.iso(maxISO)), the highest you used, \(nAtMax == 1 ? "the photo measures" : "the \(nAtMax) photos measure") \(Fmt.db(atMax)), under the \(markText) mark.",
                         why: "The top ISO band pools everything above ISO 1000, so its median can hide the highest settings. The \(markText) mark is where grain begins to be visible at full size.",
                         actions: [.camera("Shoot freely up to \(capText)."),
                                   .camera("Above that, prefer a slower shutter on a support, or add more light, before raising ISO.")],
                         ex: lowestSNR(topRows.filter { ($0.iso ?? 0) > (capISO ?? 1000) }))
            i.imperative = "Keep ISO at or below \(capText)."
            i.oneThingDetail = "Up to \(capText) your photos are clean; at \(Fmt.iso(maxISO)) \(nAtMax == 1 ? "the photo measures" : "they measure") \(Fmt.db(atMax))."
            let above = cam.photos.filter { ($0.iso ?? 0) > (capISO ?? 1000) }.count
            i.prevalence = Double(above) / Double(max(cam.photos.count, 1))
            i.brief = (s.snrFollowsISO == true ? "noise falls with ISO the way a sensor's does; " : "") + "it is clean up to \(capText), and \(nAtMax == 1 ? "the one photo" : "the \(nAtMax) photos") at \(Fmt.iso(maxISO)) \(nAtMax == 1 ? "measures" : "measure") \(Fmt.db(atMax))"
            return .fired(i)
        }

        // A band falls under the mark above the ceiling.
        let next = failing ?? ceiling
        let topText = ceiling.band.topISO.map { "ISO \($0)" } ?? ceiling.band.label
        var finding = follows + "Noise stays clean up to \(topText) (\(Fmt.db(ceiling.median)) over \(Fmt.count(ceiling.count, "photo")) in \(ceiling.band.label)); at \(next.band.label) it drops to \(Fmt.db(next.median)) (\(Fmt.count(next.count, "photo")))."
        let w: String
        if recovers.isEmpty {
            w = "Higher ISO amplifies the sensor signal and the grain with it. The \(markText) mark is where grain begins to be visible at full size."
        } else {
            finding += " Higher up it reads cleaner again (" + recovers.map(bandText).joined(separator: "; ") + "), so noise here does not simply follow ISO."
            w = "The \(device)'s noise reduction changes with ISO and scene, and this figure is output-referred, so it compares processing as much as the sensor. The \(markText) mark is where grain begins to be visible at full size."
        }
        var i = base(severity: .notice, title: "Keep ISO at or below \(topText) for clean pictures", finding: finding, why: w,
                     actions: [.camera("Shoot freely up to \(topText)."),
                               .camera("Above that, prefer a slower shutter on a support, or add more light, before raising ISO."),
                               .camera("If you must go higher, expose generously: a bright, noisy frame beats a dark one lifted later.")],
                     ex: lowestSNR(inBand(next.band)))
        i.imperative = "Keep ISO at or below \(topText)."
        i.oneThingDetail = "Your photos are clean up to \(topText); at \(next.band.label) the median drops to \(Fmt.db(next.median)), under the \(markText) mark."
        let capISO = Double(ceiling.band.topISO ?? 1000)
        i.prevalence = Double(cam.photos.filter { ($0.iso ?? 0) > capISO }.count) / Double(max(cam.photos.count, 1))
        i.brief = (s.snrFollowsISO == true ? "noise falls with ISO the way a sensor's does: " : "") + "clean up to \(topText), \(Fmt.db(next.median)) at \(next.band.label)"
        return .fired(i)
    }

    // MARK: 2. Noise reduction character
    /// Whiteness is read above ISO 160 when at least five clean photos are there: at low noise, scene texture
    /// raises it even without noise reduction (FINDINGS §5 item 5). Editor actions only.
    static func noiseCharacter(_ cam: CameraGroup) -> Insight? { noiseCharacter(cam, .none).insight }

    static func noiseCharacter(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        let s = cam.summary
        let device = CameraVocabulary.device(phone: cam.isPhone)
        let rows: [PhotoRecord]
        let scopeText: String
        let above = s.whitenessAbove160 != nil
        if above {
            rows = cam.photos.filter { $0.snrIsClean && ($0.iso ?? 0) > 160 && $0.noiseWhiteness != nil }
            scopeText = "above ISO 160"
        } else {
            rows = cam.photos.filter { $0.noiseTextureSuspect != true && $0.noiseWhiteness != nil }
            scopeText = "over all ISOs (at low noise, scene texture also raises it)"
        }
        guard let med = Stats.median(rows.compactMap(\.noiseWhiteness)) else { return .notApplicable }
        let ex = representative(rows, value: \.noiseWhiteness, caption: { "whiteness " + Fmt.num($1, 2) })
        let ev = [EvidenceItem(metric: "Median noise whiteness, \(scopeText)", value: Fmt.num(med, 2), n: rows.count)]
        let ref = "white noise is \(Fmt.num(Metric.whitenessWhite, 2))"
        let id = "noise-character:\(cam.model)"
        let grade = EvidenceGrade.grade(counted: rows.count, kind: .measured)
        let why = WhyShown(
            rule: "Reads noise whiteness, how fine or smoothed the grain is, as the median \(above ? "over clean photos above ISO 160, where it reflects noise reduction rather than scene texture" : "over every photo whose flat areas are not texture, because fewer than \(CameraSummary.minRowsForFigure) clean photos are above ISO 160"). \(Fmt.num(Metric.whitenessSmoothed, 1)) and up is smoothed; \(Fmt.num(Metric.whitenessHeavy, 1)) and up is heavy.",
            counted: "\(rows.count) of \(Fmt.count(cam.photos.count, "photo")).",
            howSure: howSure(grade, counted: rows.count, kind: .measured),
            cannotTell: "Below ISO 160 the noise is too faint to separate from the scene's own fine detail, so whiteness there is unreliable. It says how the grain looks, not whether texture was lost in a given photo.",
            checkYourself: "Open a high-ISO photo of hair, foliage or fabric at 100 % and look for smeared, waxy texture.")
        func make(_ severity: Severity, _ title: String, _ finding: String, _ w: String, _ actions: [Action]) -> RuleResult {
            var i = Insight(id: id, scope: .camera(cam.model), severity: severity, title: title, finding: finding, why: w,
                            actions: actions, evidence: ev, exampleFiles: ex.files, exampleCaptions: ex.captions,
                            counted: rows.count, total: cam.photos.count)
            i.grade = grade; i.kind = .measured; i.whyShown = why; i.ruleOrder = 6
            i.brief = "\(title.prefix(1).lowercased() + title.dropFirst()) (whiteness \(Fmt.num(med, 2)) \(above ? "above ISO 160" : "over all ISOs"))"
            return .fired(i)
        }
        if med < Metric.whitenessSmoothed {
            return make(.info, "Noise is left as fine grain",
                        "Noise whiteness is \(Fmt.num(med, 2)) \(scopeText) (\(ref)): the noise is left close to fine grain, with little smoothing.",
                        "Fine grain looks natural and keeps fine texture such as hair and foliage, but it is more visible than smoothed noise at the same level.",
                        [.editor("Apply light luminance noise reduction if grain bothers you.")])
        } else if med < Metric.whitenessHeavy {
            return make(.info, "Moderate noise smoothing",
                        "Noise whiteness is \(Fmt.num(med, 2)) \(scopeText) (\(ref)): moderate smoothing by the \(device), or scene texture left in the flat areas.",
                        "Some grain has been smoothed away, a fair trade between texture and cleanliness.",
                        [.editor("Add noise reduction only to high-ISO frames.")])
        } else {
            return make(.notice, "Strong noise smoothing can soften fine texture",
                        "Noise whiteness is \(Fmt.num(med, 2)) \(scopeText) (\(ref); \(Fmt.num(Metric.whitenessHeavy, 1)) and up is heavy smoothing): the \(device) smooths noise strongly, which can soften fine texture such as hair, foliage and fabric even when the noise number looks good.",
                        "The \(device) removes grain by blurring, and blurring cannot tell grain from texture, so a clean noise figure can hide lost texture.",
                        [.editor("Do not add noise reduction to photos that look clean: it is already applied."),
                         .editor("Check texture subjects at full size before you sharpen them.")])
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
    static func lensComparison(_ cam: CameraGroup) -> Insight? { lensComparison(cam, .none).insight }

    static func lensComparison(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        guard cam.isPhone else { return .notApplicable }
        let names = lensNames(cam.lenses)
        func name(_ l: LensGroup) -> String { names[l.name] ?? l.name }
        let id = "lens-comparison:\(cam.model)"
        let back = cam.lenses.filter { !$0.isFront }
        guard back.count >= 2 else { return .notApplicable }
        let usable = back.filter { $0.sharpnessCount >= 3 && $0.p80Sharpness != nil }
        guard usable.count >= 2 else {
            return .silent(SilentCheck(id: id, name: "Lens comparison", reason: "fewer than two back lenses have 3 photos with 3 or more usable edges (" + back.map { "\(name($0)) \($0.sharpnessCount)" }.joined(separator: ", ") + "), so there is nothing to compare."))
        }
        let ranked = usable.sorted { ($0.p80Sharpness ?? 0) > ($1.p80Sharpness ?? 0) }
        let best = ranked[0]
        let bestName = name(best)
        let bestV = best.p80Sharpness ?? 0
        let others = ranked.dropFirst()
        func gap(_ l: LensGroup) -> Double { (1 - (l.p80Sharpness ?? 0) / bestV) * 100 }
        let gaps = others.map { l -> String in
            "the \(name(l)) is \(Fmt.num(gap(l), 0)) % lower (\(Fmt.lwph(l.p80Sharpness ?? 0)), \(Fmt.count(l.sharpnessCount, "photo")))"
        }
        let worstGap = others.map(gap).max() ?? 0
        // A per-photo sharpness figure is a +/-30 % band; only call a lens "sharpest" when the runner-up
        // is at least 15 % behind. Otherwise the lenses are a tie and the advice is about the laggards.
        let runnerGap = ranked.count > 1 ? gap(ranked[1]) : 100
        let laggards = others.filter { gap($0) >= 15 }
        let tied = others.filter { gap($0) < 15 }
        let title: String
        var actions: [Action]
        if runnerGap >= 15 {
            title = "The \(bestName) is your sharpest lens"
            actions = laggards.map { .camera("For detail, move closer with the \(bestName) rather than zooming with the \(name($0)).") }
        } else {
            let tiedNames = ([bestName] + tied.map(name)).joined(separator: " and ")
            title = laggards.isEmpty ? "Your lenses resolve about the same detail" : "The \(tiedNames) resolve about the same; the others fall behind"
            actions = laggards.map { .camera("For detail, use the \(tiedNames) rather than the \(name($0)).") }
                + [.camera("Use whichever of the \(tiedNames) frames the shot better: differences under 15 % are inside the measurement band, so treat them as equal.")]
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
        let grade = EvidenceGrade.grade(counted: counted, kind: .edgeBased)
        var i = Insight(
            id: id, scope: .camera(cam.model), severity: worstGap >= 15 ? .notice : .info,
            title: title,
            finding: "Counting only photos with 3 or more usable edges, the \(bestName) resolves \(Fmt.lwph(bestV)) (\(Fmt.count(best.sharpnessCount, "photo"))); " + gaps.joined(separator: "; ") + "." + notCompared,
            why: "Each lens on a phone is a different small camera. The main one usually has the biggest sensor and the best optics; the others trade detail for reach. Gaps under 15 % are within the uncertainty of natural-scene sharpness, and every figure is a lower bound read from real edges.",
            actions: actions,
            evidence: usable.map { EvidenceItem(metric: "Sharpness, \(name($0))", value: Fmt.lwph($0.p80Sharpness ?? 0), n: $0.sharpnessCount) },
            exampleFiles: fromBest.files + fromLag.files, exampleCaptions: fromBest.captions + fromLag.captions,
            counted: counted, total: cam.photos.count)
        i.grade = grade; i.kind = .edgeBased; i.ruleOrder = 4
        let lagPhotos = laggards.map(\.photos.count).reduce(0, +)
        if runnerGap >= 15, !laggards.isEmpty {
            i.imperative = "Use the \(bestName) when detail matters."
            i.oneThingDetail = "It resolves \(Fmt.lwph(bestV)); " + gaps.joined(separator: "; ") + "."
            i.prevalence = Double(lagPhotos) / Double(max(cam.photos.count, 1))
        }
        i.brief = runnerGap >= 15 ? "the \(bestName) is your sharpest lens" : "your \(([bestName] + tied.map(name)).joined(separator: " and ")) resolve about the same detail"
        if let missing = left.first(where: { !$0.isFront }) {
            i.whatWouldChange = "\(CameraSummary.minRowsForFigure) \(name(missing)) photos of scenes with straight edges."
        }
        i.whyShown = WhyShown(
            rule: "Compares the median sharpness of each back lens over its photos with 3 or more usable edges, when at least two lenses have 3 such photos. A gap under 15 % is called a tie.",
            counted: "\(counted) of \(Fmt.count(cam.photos.count, "photo")): " + usable.map { "\(name($0)) \($0.sharpnessCount)" }.joined(separator: ", ") + "." + notCompared,
            howSure: howSure(grade, counted: counted, kind: .edgeBased),
            cannotTell: "Each lens also gets different scenes: an ultra-wide sees more distant detail, a telephoto more close-ups. The gap mixes lens and subject.",
            checkYourself: "Photograph the same bookshelf from the same spot with each lens, filling the frame, and analyze the set.")
        return .fired(i)
    }

    // MARK: 4. Field softness
    /// Per lens, on photos with at least three valid edges in both the centre and the outer frame. A finding needs
    /// five such photos on one lens; with one to four in all, a Thin card says what was seen.
    static func fieldSoftness(_ cam: CameraGroup) -> Insight? { fieldSoftness(cam, .none).insight }

    static func fieldSoftness(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        let names = lensNames(cam.lenses)
        func name(_ l: LensGroup) -> String {
            if cam.isPhone { return names[l.name] ?? l.name }
            return l.name == PhotoRecord.unknownLens ? "lens" : l.name
        }
        let id = "field-softness:\(cam.model)"
        let perLens = cam.lenses.compactMap { l -> (lens: LensGroup, median: Double, n: Int)? in
            let r = l.photos.compactMap(\.gatedOuterCentreRatio)
            guard r.count >= minPhotos, let m = Stats.median(r) else { return nil }
            return (l, m, r.count)
        }
        let allRatios = cam.photos.compactMap(\.gatedOuterCentreRatio)
        let rule = "Compares sharpness near the frame's edge with the centre on photos with 3 or more usable edges in both regions. A finding needs \(minPhotos) such photos on one lens and a median outer-to-centre ratio under 0.80."
        let cannot = "Edges near the frame's edge are also more often out of focus, so the method cannot separate the lens from depth of field."
        let check = "Photograph a bookshelf, a brick wall or a page of text filling the frame, square on, and analyze it."
        guard !perLens.isEmpty else {
            guard !allRatios.isEmpty, let m = Stats.median(allRatios), m < 0.80 else {
                return .silent(SilentCheck(id: id, name: "Corner softness", reason: allRatios.isEmpty
                    ? "no photo has 3 or more usable edges in both the centre and the outer frame."
                    : "\(Fmt.count(allRatios.count, "photo")) with 3 or more usable edges in both regions; their outer edges measure a median \(Fmt.share(Stats.median(allRatios) ?? 1)) of the centre, above the 80 % line."))
            }
            let sorted = allRatios.sorted()
            let list = sorted.map { Fmt.share($0) }
            let listText = list.count == 1 ? list[0] : list.dropLast().joined(separator: ", ") + " and " + list.last!
            let ex = extremes(cam.photos, highest: false, value: \.gatedOuterCentreRatio, caption: { Fmt.num($1, 2) + " outer / centre" })
            var i = Insight(
                id: id, scope: .camera(cam.model), severity: .notice, title: "Corners may be softer than the centre",
                finding: "Only \(Fmt.count(allRatios.count, "photo")) \(allRatios.count == 1 ? "has" : "have") 3 or more usable edges in both the centre and the outer frame; on \(allRatios.count == 1 ? "it" : "those"), the outer edges measured \(listText) of the centre. \(cannot)",
                why: "Most lenses resolve best on the axis and fall off toward the corners; wide-open apertures and wide angles show it most.",
                actions: [.camera(check)], evidence: [EvidenceItem(metric: "Median outer / centre sharpness", value: Fmt.num(m, 2), n: allRatios.count)],
                exampleFiles: ex.files, exampleCaptions: ex.captions, counted: allRatios.count, total: cam.photos.count)
            i.grade = .thin; i.kind = .edgeBased
            i.whatWouldChange = "\(minPhotos) photos with straight edges both in the middle and near the corners."
            i.brief = "corners may be softer than the centre (\(Fmt.count(allRatios.count, "photo")): \(listText) of the centre)"
            i.whyShown = WhyShown(rule: rule, counted: "\(allRatios.count) of \(Fmt.count(cam.photos.count, "photo")).",
                                  howSure: howSure(.thin, counted: allRatios.count, kind: .edgeBased), cannotTell: cannot, checkYourself: check)
            return .fired(i)
        }
        guard let worst = perLens.min(by: { $0.median < $1.median }), worst.median < 0.80 else {
            return .silent(SilentCheck(id: id, name: "Corner softness", reason: perLens.map { "\(name($0.lens)): outer edges a median \(Fmt.share($0.median)) of the centre over \(Fmt.count($0.n, "photo"))" }.joined(separator: "; ") + ", above the 80 % line."))
        }
        let pct = (1 - worst.median) * 100
        let lensName = name(worst.lens)
        let ex = extremes(worst.lens.photos, highest: false, value: \.gatedOuterCentreRatio, caption: { Fmt.num($1, 2) + " outer / centre" })
        let holders = perLens.filter { $0.median >= 0.80 }
        var actions: [Action] = [.camera("Keep the subject in the central area of the frame when you use the \(lensName).")]
        if cam.isPhone {
            if let h = holders.max(by: { $0.median < $1.median }) {
                actions.append(.camera("For detail near the edges of the frame, the \(name(h.lens)) holds up better (outer-to-centre \(Fmt.num(h.median, 2)) over \(Fmt.count(h.n, "photo")))."))
            }
        } else {
            actions.append(.camera("Stop down one or two stops: corner sharpness improves faster than centre sharpness."))
        }
        let single = cam.lenses.count == 1
        let grade = EvidenceGrade.grade(counted: worst.n, kind: .edgeBased)
        var i = Insight(
            id: id, scope: .camera(cam.model), severity: pct >= 30 ? .important : .notice,
            title: single ? "Corners are softer than the centre" : "Corners are softer than the centre on the \(lensName)",
            finding: "On the \(lensName), the outer frame is \(Fmt.num(pct, 0)) % softer than the centre (median outer-to-centre sharpness \(Fmt.num(worst.median, 2)) over \(Fmt.count(worst.n, "photo")) with 3 or more usable edges in both regions).",
            why: "Most lenses resolve best on the axis and fall off toward the corners; wide-open apertures and wide angles show it most. Edges near the frame's edge are also more often out of focus, so read this as a lower bound on the lens.",
            actions: actions,
            evidence: perLens.map { EvidenceItem(metric: "Median outer / centre sharpness, \(name($0.lens))", value: Fmt.num($0.median, 2), n: $0.n) },
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: worst.n, total: worst.lens.photos.count)
        i.grade = grade; i.kind = .edgeBased; i.ruleOrder = 5
        i.imperative = "Keep the subject away from the corners on the \(lensName)."
        i.oneThingDetail = "Its outer frame measures \(Fmt.num(pct, 0)) % softer than the centre over \(Fmt.count(worst.n, "photo"))."
        i.prevalence = Double(worst.lens.photos.count) / Double(max(cam.photos.count, 1))
        i.brief = "the \(lensName)'s corners are \(Fmt.num(pct, 0)) % softer than its centre"
        i.whyShown = WhyShown(rule: rule, counted: "\(worst.n) of the \(lensName)'s \(Fmt.count(worst.lens.photos.count, "photo")).",
                              howSure: howSure(grade, counted: worst.n, kind: .edgeBased), cannotTell: cannot, checkYourself: check)
        return .fired(i)
    }

    // MARK: 5. Highlight and shadow discipline
    /// More than 15 % of photos with over 1 % of the frame clipped. Photos tagged "bright on purpose" are left out.
    static func highlightDiscipline(_ cam: CameraGroup) -> Insight? { highlightDiscipline(cam, .none).insight }

    static func highlightDiscipline(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        let (kept, excluded) = ctx.kept(cam.photos, without: .brightOnPurpose)
        let v = kept.compactMap(\.clipHighPct)
        let id = "highlight-discipline:\(cam.model)"
        guard !v.isEmpty else { return .notApplicable }
        let n = v.filter { $0 > clipPhotoPct }.count
        let share = ShareCount(hits: n, of: v.count)
        let range = Fmt.shareRange(share.range)
        guard share.fraction > clipShareLine else {
            return .silent(SilentCheck(id: id, name: "Blown highlights", reason: "\(n) of \(Fmt.count(v.count, "photo")) (\(Fmt.share(share.fraction)); \(range) allowing for chance) have more than 1 % blown, under the \(Fmt.share(clipShareLine)) line."))
        }
        let phone = cam.isPhone
        let ex = representative(kept.filter { ($0.clipHighPct ?? 0) > clipPhotoPct }, value: \.clipHighPct, caption: { Fmt.pct($1, 1) })
        let grade = EvidenceGrade.grade(counted: v.count, kind: .pixelCount, shareRange: share.range, line: clipShareLine)
        let blown = "have more than 1 % of the frame blown, at the top of the range in at least one colour channel"
        var i = Insight(
            id: id, scope: .camera(cam.model), severity: share.fraction > 0.3 ? .important : .notice,
            title: "Highlights are often blown out",
            finding: "\(n) of your \(Fmt.count(v.count, "photo")) (\(Fmt.share(share.fraction))) \(blown).",
            why: "A channel at the top of the range holds no detail there, and a JPEG or HEIC cannot bring it back. The \(CameraVocabulary.device(phone: phone)) exposes for the average of the scene, so skies, windows and white pages run out of range first.",
            actions: [.camera(CameraVocabulary.lessExposure(phone: phone)),
                      .editor("For photos you already have, follow each photo's Highlights step.")],
            evidence: [EvidenceItem(metric: "Photos with over 1 % clipped highlights", value: Fmt.share(share.fraction), n: v.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: v.count, total: cam.photos.count)
        i.grade = grade; i.kind = .pixelCount; i.excluded = excluded; i.share = share; i.ruleOrder = 0
        i.checkKind = .highlights
        i.imperative = "Expose for the highlights."
        i.oneThingDetail = "\(n) of your \(Fmt.count(v.count, "photo")) (\(Fmt.share(share.fraction))) \(blown), and a JPEG or HEIC cannot bring that back."
        i.prevalence = share.fraction
        i.brief = "blown highlights (\(n) of \(v.count); with \(Fmt.count(v.count, "photo")) the share could be anywhere from \(range))"
        if grade == .thin { i.whatWouldChange = "More photos from this camera: the share's 95 % range (now \(range)) has to clear the \(Fmt.share(clipShareLine)) line." }
        i.whyShown = WhyShown(
            rule: "Appears when more than \(Fmt.share(clipShareLine)) of a camera's photos have over 1 % of the frame at the top of the range (any channel at 254 or above, counted in the file's own encoding).",
            counted: excluded.isEmpty ? "All \(Fmt.count(v.count, "photo")); clipping is counted on every pixel, so none is left out."
                                      : "\(v.count) of \(Fmt.count(cam.photos.count, "photo")): " + excluded.map { "\($0.count) \($0.reason)" }.joined(separator: ", ") + " left out.",
            howSure: howSure(grade, counted: v.count, kind: .pixelCount, share: share, line: clipShareLine),
            cannotTell: "Whether the bright area was a sky you wanted, a white page or a screen; the examples show which kind yours are.",
            checkYourself: phone ? "Shoot the same bright scene twice, once as it comes and once with the sun slider pulled down, and analyze both."
                                 : "Shoot the same bright scene twice, once as it comes and once at -0.7 EV, and analyze both.")
        return .fired(i)
    }

    /// More than 15 % of photos with over 1 % crushed to pure black. Photos tagged "dark on purpose" are left out.
    static func shadowDiscipline(_ cam: CameraGroup) -> Insight? { shadowDiscipline(cam, .none).insight }

    static func shadowDiscipline(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        let (kept, excluded) = ctx.kept(cam.photos, without: .darkOnPurpose)
        let v = kept.compactMap(\.clipLowPct)
        let id = "shadow-discipline:\(cam.model)"
        guard !v.isEmpty else { return .notApplicable }
        let n = v.filter { $0 > clipPhotoPct }.count
        let share = ShareCount(hits: n, of: v.count)
        let range = Fmt.shareRange(share.range)
        guard share.fraction > clipShareLine else {
            return .silent(SilentCheck(id: id, name: "Crushed shadows", reason: "\(n) of \(Fmt.count(v.count, "photo")) (\(Fmt.share(share.fraction)); \(range) allowing for chance) have more than 1 % of the frame at pure black, under the \(Fmt.share(clipShareLine)) line."))
        }
        let phone = cam.isPhone
        let ex = representative(kept.filter { ($0.clipLowPct ?? 0) > clipPhotoPct }, value: \.clipLowPct, caption: { Fmt.pct($1, 1) })
        let grade = EvidenceGrade.grade(counted: v.count, kind: .pixelCount, shareRange: share.range, line: clipShareLine)
        var i = Insight(
            id: id, scope: .camera(cam.model), severity: .notice,
            title: "Shadows often lose detail",
            finding: "\(n) photos lost shadow detail: \(Fmt.share(share.fraction)) of \(v.count) have more than 1 % of the picture crushed to pure black.",
            why: "Pure black holds no detail. If the dark areas are intentional that is fine; if not, the exposure was set for the bright parts.",
            actions: [.camera(CameraVocabulary.exposeForShadows(phone: phone)),
                      .camera("Or accept dark blacks when the mood calls for it, and keep important subjects out of them."),
                      .editor("For photos you already have, follow each photo's Shadows step.")],
            evidence: [EvidenceItem(metric: "Photos with over 1 % crushed shadows", value: Fmt.share(share.fraction), n: v.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: v.count, total: cam.photos.count)
        i.grade = grade; i.kind = .pixelCount; i.excluded = excluded; i.share = share; i.ruleOrder = 1
        i.checkKind = .shadows
        i.imperative = "Expose for the shadows."
        i.oneThingDetail = "\(n) of your \(Fmt.count(v.count, "photo")) (\(Fmt.share(share.fraction))) have more than 1 % of the frame crushed to pure black, which holds no detail."
        i.prevalence = share.fraction
        i.brief = "crushed shadows (\(n) of \(v.count); with \(Fmt.count(v.count, "photo")) the share could be anywhere from \(range))"
        if grade == .thin { i.whatWouldChange = "More photos from this camera: the share's 95 % range (now \(range)) has to clear the \(Fmt.share(clipShareLine)) line." }
        i.whyShown = WhyShown(
            rule: "Appears when more than \(Fmt.share(clipShareLine)) of a camera's photos have over 1 % of the frame at pure black (all channels at 1 or below).",
            counted: excluded.isEmpty ? "All \(Fmt.count(v.count, "photo")); clipping is counted on every pixel, so none is left out."
                                      : "\(v.count) of \(Fmt.count(cam.photos.count, "photo")): " + excluded.map { "\($0.count) \($0.reason)" }.joined(separator: ", ") + " left out.",
            howSure: howSure(grade, counted: v.count, kind: .pixelCount, share: share, line: clipShareLine),
            cannotTell: "Whether the black was a night sky or a deliberate silhouette; the examples show which kind yours are.",
            checkYourself: "Shoot the same high-contrast scene twice, once as it comes and once exposed for the dark subject, and analyze both.")
        return .fired(i)
    }

    // MARK: 6. Sharpening character
    /// Overshoot counts only on photos with at least three valid edges, and needs five of them. No at-camera
    /// action on phones: the Camera app has no sharpness setting.
    static func sharpeningCharacter(_ cam: CameraGroup) -> Insight? { sharpeningCharacter(cam, .none).insight }

    static func sharpeningCharacter(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        let v = cam.photos.compactMap(\.gatedOvershoot)
        let id = "sharpening:\(cam.model)"
        let device = CameraVocabulary.device(phone: cam.isPhone)
        guard v.count >= CameraSummary.minRowsForFigure, let med = Stats.median(v) else {
            return v.isEmpty ? .notApplicable : .silent(SilentCheck(id: id, name: "Sharpening", reason: "only \(Fmt.count(v.count, "photo")) with 3 or more usable edges; the figure needs \(CameraSummary.minRowsForFigure)."))
        }
        guard med > Metric.overshootHardPct else {
            return .silent(SilentCheck(id: id, name: "Sharpening", reason: "edges overshoot by a median \(Fmt.pct(med, 1)) over \(Fmt.count(v.count, "photo")), under the \(Fmt.int(Metric.overshootHardPct)) % line for hard sharpening."))
        }
        let halo = med >= Metric.overshootHaloPct
        let ex = representative(cam.photos, value: \.gatedOvershoot, caption: { Fmt.pct($1, 1) })
        var actions: [Action] = [.editor("Do not add sharpening."),
                                 .editor("Downsize for the web with a soft resampler (bicubic smoother, or Lanczos) so the fringes do not double.")]
        if let a = CameraVocabulary.sharpening(phone: cam.isPhone) { actions.insert(.camera(a), at: 0) }
        let grade = EvidenceGrade.grade(counted: v.count, kind: .edgeBased)
        var i = Insight(
            id: id, scope: .camera(cam.model), severity: halo ? .important : .notice,
            title: "This \(device) sharpens hard",
            finding: "Edges overshoot by \(Fmt.num(med, 1)) % (median over \(Fmt.count(v.count, "photo")) with 3 or more usable edges): hard sharpening" + (halo ? ", which shows as a visible halo." : "; from \(Fmt.int(Metric.overshootHaloPct)) % it shows as a visible halo."),
            why: "Sharpening makes pictures look crisp at small sizes but shows a bright fringe and a brittle look when enlarged. Part of the sharpness figure is this sharpening, not the lens.",
            actions: actions,
            evidence: [EvidenceItem(metric: "Median overshoot", value: Fmt.pct(med, 1), n: v.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: v.count, total: cam.photos.count)
        i.grade = grade; i.kind = .edgeBased; i.ruleOrder = 7
        if !cam.isPhone {
            i.imperative = "Turn down in-camera sharpening."
            i.oneThingDetail = "Edges overshoot by \(Fmt.num(med, 1)) % over \(Fmt.count(v.count, "photo")): hard sharpening."
            i.prevalence = 1
        }
        i.brief = "the \(device) sharpens hard (edges overshoot by \(Fmt.num(med, 1)) %)"
        i.whyShown = WhyShown(
            rule: "Appears when the median edge overshoot over photos with 3 or more usable edges is above \(Fmt.int(Metric.overshootHardPct)) % (hard sharpening); from \(Fmt.int(Metric.overshootHaloPct)) % it is a visible halo. It needs \(CameraSummary.minRowsForFigure) such photos.",
            counted: "\(v.count) of \(Fmt.count(cam.photos.count, "photo")); the rest had fewer than 3 usable edges.",
            howSure: howSure(grade, counted: v.count, kind: .edgeBased),
            cannotTell: "Whether an edit added sharpening after the shot; the figure reads the file as it is.",
            checkYourself: "Open a photo of a sign or a roof line against the sky at 200 % and look for a bright line along the dark side of the edge.")
        return .fired(i)
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

    /// The camera's typical cast over its photos, leaving out those tagged "colour is the point". No preset action on
    /// phones: the Camera app has none.
    static func colourLean(_ cam: CameraGroup) -> Insight? { colourLean(cam, .none).insight }

    static func colourLean(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        let (kept, excluded) = ctx.kept(cam.photos, without: .colourIsThePoint)
        let id = "colour-lean:\(cam.model)"
        let rs = kept.compactMap(\.wbROverGStops), bs = kept.compactMap(\.wbBOverGStops)
        guard let r = Stats.median(rs) ?? (bs.isEmpty ? nil : 0), let b = Stats.median(bs) ?? (rs.isEmpty ? nil : 0) else { return .notApplicable }
        let n = kept.filter { $0.wbROverGStops != nil || $0.wbBOverGStops != nil }.count
        guard abs(r) > 0.15 || abs(b) > 0.15 else {
            return .silent(SilentCheck(id: id, name: "Colour lean", reason: "median R/G \(Fmt.num(r, 2)) and B/G \(Fmt.num(b, 2)) stops over \(Fmt.count(n, "photo")), within the 0.15-stop line."))
        }
        let d = leanDescription(r: r, b: b)
        let ex = representative(kept, value: \.wbLeanStops, caption: { Fmt.stops($1) })
        var actions: [Action] = []
        if let a = CameraVocabulary.whiteBalance(phone: cam.isPhone) { actions.append(.camera(a)) }
        actions.append(.editor("Where greys should look neutral, use the white-balance picker on something grey or white."))
        let grade = EvidenceGrade.grade(counted: n, kind: .sceneDependent)
        let device = CameraVocabulary.device(phone: cam.isPhone)
        var i = Insight(
            id: id, scope: .camera(cam.model), severity: d.stops >= 0.4 ? .notice : .info,
            title: "Colours lean \(d.words)",
            finding: "Across \(Fmt.count(n, "photo")) the gray-world balance leans \(d.words) by \(Fmt.stops(d.stops)): R/G \(Fmt.num(r, 2)) stops, B/G \(Fmt.num(b, 2)) stops (medians).",
            why: "Part of any lean is the light you shoot in (golden light, blue shade); a lean that holds across many scenes is the \(device)'s rendering.",
            actions: actions,
            evidence: [EvidenceItem(metric: "Median R/G", value: Fmt.stops(r), n: n), EvidenceItem(metric: "Median B/G", value: Fmt.stops(b), n: n)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: n, total: cam.photos.count)
        i.grade = grade; i.kind = .sceneDependent; i.excluded = excluded; i.ruleOrder = 8
        if !cam.isPhone {
            i.imperative = "Set white balance for the light."
            i.oneThingDetail = "Across \(Fmt.count(n, "photo")) the camera renders \(d.words) by \(Fmt.stops(d.stops))."
            i.prevalence = Double(kept.filter { ($0.wbLeanStops ?? 0) > 0.15 }.count) / Double(max(cam.photos.count, 1))
        }
        i.brief = "colours lean slightly \(d.words) (\(Fmt.stops(d.stops)) over \(Fmt.count(n, "photo")))"
        i.whyShown = WhyShown(
            rule: "Takes the median gray-world R/G and B/G over the camera's photos and appears when either is more than 0.15 stops from neutral.",
            counted: "\(n) of \(Fmt.count(cam.photos.count, "photo"))" + (excluded.isEmpty ? "." : "; " + excluded.map { "\($0.count) \($0.reason)" }.joined(separator: ", ") + " left out."),
            howSure: howSure(grade, counted: n, kind: .sceneDependent),
            cannotTell: "Gray-world assumes the scene averages to grey: a one-colour subject, a sunset or stage light moves it.",
            checkYourself: "Photograph a sheet of white paper in daylight; if it comes out tinted, the lean is the \(device).")
        return .fired(i)
    }

    // MARK: 8. Slow-shutter softness (phones)
    /// Back cameras only, photos with at least three valid edges. Each slow frame is compared with the faster
    /// frames from its own lens. Fewer than eight slow frames give a Thin card.
    static func slowShutter(_ cam: CameraGroup) -> Insight? { slowShutter(cam, .none).insight }

    static func slowShutter(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        guard cam.isPhone else { return .notApplicable }
        let id = "slow-shutter:\(cam.model)"
        let slowLimit = 1.0 / 30 - 1e-9
        let slowAll = cam.photos.filter { !$0.isFront && ($0.exposureS ?? 0) >= slowLimit }
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
        guard !slowAll.isEmpty else { return .notApplicable }
        guard let mr = Stats.median(ratios), let ms = Stats.median(slowVals), let mf = Stats.median(fastVals) else {
            return .silent(SilentCheck(id: id, name: "Slow shutter", reason: "\(slowAll.count) of \(Fmt.count(cam.photos.count, "photo")) were taken at 1/30 s or slower, and none of them has 3 or more usable edges next to 3 faster photos from the same lens."))
        }
        let pct = (1 - mr) * 100
        let k = slowVals.count
        guard pct >= 20 else {
            return .silent(SilentCheck(id: id, name: "Slow shutter", reason: "\(Fmt.count(k, "slow photo")) with 3 or more usable edges measured \(Fmt.num(max(pct, 0), 0)) % softer than faster frames from the same lens, under the 20 % line."))
        }
        let thin = k < EvidenceGrade.thinBelow
        let ex = extremes(slowPhotos, highest: false, value: \.gatedSharpnessLWPH,
                          caption: { p, v in (p.exposureS.map { Fmt.shutter($0) + ", " } ?? "") + Fmt.lwph(v) })
        // The claim rests on the slow photos; the faster ones are the comparison.
        let counted = k
        let comparison = "\(Fmt.lwph(ms)) against \(Fmt.lwph(mf)) over \(fastVals.count) faster \(fastVals.count == 1 ? "photo" : "photos")"
        let finding = thin
            ? "\(slowAll.count) of your \(Fmt.count(cam.photos.count, "photo")) were taken at 1/30 s or slower; \(k == 1 ? "only 1" : "\(k)") had 3 or more usable edges. \(k == 1 ? "It" : "They") measured \(Fmt.num(pct, 0)) % softer than faster frames from the same lens (\(comparison)), but \(k == 1 ? "one photo cannot show a pattern" : "\(k) photos are too few to call it a pattern")."
            : "Frames at 1/30 s or slower were \(Fmt.num(pct, 0)) % softer than faster frames from the same lens (\(Fmt.lwph(ms)) over \(Fmt.count(k, "slow photo")), against \(Fmt.lwph(mf)) over \(fastVals.count) faster ones; back cameras only, photos with 3 or more usable edges)."
        let actions: [Action] = thin
            ? [.camera("In dim light, take the same scene twice, once hand-held and once braced against a wall, and analyze both.")]
            : [.camera("Brace against a wall or rest the phone on a surface."),
               .camera("Use burst and keep the sharpest frame."),
               .camera("Raise ISO one stop to buy a faster shutter (see Noise by ISO for how far you can go).")]
        var i = Insight(
            id: id, scope: .camera(cam.model), severity: .notice,
            title: thin ? "Slow shutter speeds may cost sharpness" : "Slow shutter speeds cost sharpness",
            finding: finding,
            why: "Camera or subject movement blurs the whole frame during a long exposure, and stabilisation only buys a stop or two.",
            actions: actions,
            evidence: [EvidenceItem(metric: "Sharpness at 1/30 s or slower", value: Fmt.lwph(ms), n: k),
                       EvidenceItem(metric: "Sharpness at faster speeds, same lenses", value: Fmt.lwph(mf), n: fastVals.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: counted, total: cam.photos.count)
        i.grade = thin ? .thin : EvidenceGrade.grade(counted: k, kind: .edgeBased)
        i.kind = .edgeBased; i.ruleOrder = 6
        if thin { i.whatWouldChange = "\(EvidenceGrade.thinBelow) slow photos of scenes with straight edges." }
        i.imperative = "Brace the phone below 1/30 s."
        i.oneThingDetail = "Frames at 1/30 s or slower measured \(Fmt.num(pct, 0)) % softer than faster frames from the same lens."
        i.prevalence = Double(slowAll.count) / Double(max(cam.photos.count, 1))
        i.brief = "slow shutter speeds may cost sharpness (\(Fmt.count(k, "photo")) with a figure)"
        i.whyShown = WhyShown(
            rule: "Compares photos at 1/30 s or slower with faster photos from the same back lens, counting only photos with 3 or more usable edges. A finding needs \(EvidenceGrade.thinBelow) slow photos and a gap of 20 % or more.",
            counted: "\(k) slow and \(fastVals.count) faster photos of \(Fmt.count(cam.photos.count, "photo")); \(slowAll.count - k) more slow photos had too few usable edges.",
            howSure: howSure(i.grade, counted: k, kind: .edgeBased),
            cannotTell: "Slow frames are usually dim scenes, whose edges are noisier and softer anyway; the gap mixes motion blur with low light.",
            checkYourself: "In dim light, take the same scene twice, once hand-held and once braced against a wall, and analyze both.")
        return .fired(i)
    }

    // MARK: 9. Aperture sweet spot (per lens)
    static func apertureSweetSpot(_ cam: CameraGroup) -> [Insight] { apertureResults(cam, .none).compactMap(\.insight) }

    static func apertureResults(_ cam: CameraGroup, _ ctx: RuleContext) -> [RuleResult] {
        let names = lensNames(cam.lenses)
        var used: [String] = []
        let fired = cam.lenses.compactMap { lens -> RuleResult? in
            let rows = lens.photos.compactMap { p -> (Double, Double)? in
                guard let f = p.fNumber, let s = p.gatedSharpnessLWPH else { return nil }
                return ((f * 10).rounded() / 10, s)
            }
            let byAperture = Dictionary(grouping: rows, by: \.0)
                .filter { $0.value.count >= 3 }
                .compactMapValues { Stats.median($0.map(\.1)) }
            if byAperture.count == 1, let f = byAperture.keys.first {
                used.append("\(cam.isPhone ? (names[lens.name] ?? lens.name) : lens.name) f/\(Fmt.num(f, 1))")
            }
            guard byAperture.count >= 2,
                  let best = byAperture.max(by: { $0.value < $1.value }),
                  let worst = byAperture.min(by: { $0.value < $1.value }) else { return nil }
            let counts = Dictionary(grouping: rows, by: \.0).mapValues(\.count)
            let sharpest = extremes(lens.photos.filter { $0.fNumber.map { ($0 * 10).rounded() / 10 } == best.key },
                                    highest: true, value: \.gatedSharpnessLWPH, caption: { Fmt.lwph($1) })
            let lensLabel = lens.name == PhotoRecord.unknownLens ? "" : " with \(lens.name)"
            let counted = byAperture.keys.map { counts[$0] ?? 0 }.reduce(0, +)
            let grade = EvidenceGrade.grade(counted: counted, kind: .edgeBased)
            var i = Insight(
                id: "aperture:\(cam.model):\(lens.name)", scope: .lens(cam.model, lens.name), severity: .info,
                title: "Sharpest at f/\(Fmt.num(best.key, 1))",
                finding: "\(cam.model)\(lensLabel) is sharpest at f/\(Fmt.num(best.key, 1)) (\(Fmt.lwph(best.value)) over \(counts[best.key] ?? 0) photos) and softest at f/\(Fmt.num(worst.key, 1)) (\(Fmt.lwph(worst.value)) over \(counts[worst.key] ?? 0) photos), counting photos with 3 or more usable edges.",
                why: "Lenses are usually sharpest a couple of stops from wide open. Very small apertures lose detail to diffraction.",
                actions: [.camera("Use f/\(Fmt.num(best.key, 1)) when detail matters and the light allows it."),
                          .camera("Avoid f/\(Fmt.num(worst.key, 1)) for fine detail unless you need the depth of field.")],
                evidence: byAperture.sorted { $0.key < $1.key }.map { EvidenceItem(metric: "Sharpness at f/\(Fmt.num($0.key, 1))", value: Fmt.lwph($0.value), n: counts[$0.key] ?? 0) },
                exampleFiles: sharpest.files, exampleCaptions: sharpest.captions, counted: counted, total: lens.photos.count)
            i.grade = grade; i.kind = .edgeBased; i.ruleOrder = 9
            i.brief = "\(lens.name == PhotoRecord.unknownLens ? "the lens" : lens.name) is sharpest at f/\(Fmt.num(best.key, 1))"
            i.whyShown = WhyShown(
                rule: "Compares the median sharpness at each aperture with 3 or more photos that have 3 or more usable edges, per lens.",
                counted: "\(counted) of the lens's \(Fmt.count(lens.photos.count, "photo")).",
                howSure: howSure(grade, counted: counted, kind: .edgeBased),
                cannotTell: "Each aperture also gets different scenes: you stop down for landscapes and open up for portraits.",
                checkYourself: "Photograph the same brick wall at each aperture from a tripod and analyze the set.")
            return .fired(i)
        }
        if !fired.isEmpty { return fired }
        guard cam.photos.contains(where: { $0.gatedSharpnessLWPH != nil && $0.fNumber != nil }) else { return [.notApplicable] }
        let reason = used.isEmpty
            ? "no lens has 3 photos with 3 or more usable edges at two different apertures, so there is nothing to compare."
            : "each lens with measurable photos was used at one aperture (\(used.joined(separator: ", "))), so there is nothing to compare."
        return [.silent(SilentCheck(id: "aperture:\(cam.model)", name: "Aperture", reason: reason))]
    }

    // MARK: 10. Level-edge lean
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
    /// left/right split is lopsided beyond chance. Photos tagged "not meant to be level" are left out.
    static func levelEdgeLean(_ cam: CameraGroup) -> Insight? { levelEdgeLean(cam, .none).insight }

    static func levelEdgeLean(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        let (kept, excluded) = ctx.kept(cam.photos, without: .notMeantToBeLevel)
        let id = "level-edge-lean:\(cam.model)"
        let tilts = kept.compactMap(\.structureHorizonTiltDeg)
        guard !tilts.isEmpty else { return .notApplicable }
        let left = tilts.filter { $0 <= -1 }.count, right = tilts.filter { $0 >= 1 }.count
        guard tilts.count >= minPhotos, let med = Stats.median(tilts) else {
            return .silent(SilentCheck(id: id, name: "Level-edge habit", reason: "only \(Fmt.count(tilts.count, "photo")) \(tilts.count == 1 ? "has" : "have") a long level edge; a habit needs \(minPhotos)."))
        }
        guard abs(med) >= 0.7 else {
            return .silent(SilentCheck(id: id, name: "Level-edge habit", reason: "in the \(Fmt.count(tilts.count, "photo")) with a long level edge, \(left) lean left and \(right) lean right by a degree or more (median \(Fmt.num(abs(med), 1))°), so there is no habit to correct. Each photo's own note still gives its angle."))
        }
        let side = med > 0 ? "right" : "left"
        let p = signTestP(left, right)
        let habit = p < 0.05 && (med > 0 ? right > left : left > right)
        let sameSide = kept.filter { ($0.structureHorizonTiltDeg ?? 0) * med > 0 }
        let sameSideCount = med > 0 ? right : left
        let ex = extremes(sameSide, highest: true, value: { $0.structureHorizonTiltDeg.map(abs) },
                          caption: { p, _ in signedDegrees(p.structureHorizonTiltDeg ?? 0) })
        let x = Fmt.num(abs(med), 1)
        let pText = p < 0.001 ? "under 0.001" : Fmt.num(p, p < 0.01 ? 3 : 2)
        let edgeNote = "A level edge is not always a horizon: table tops, shelves and window frames seen at an angle count too, so check the examples."
        let phone = cam.isPhone
        var actions: [Action] = [.setUp(CameraVocabulary.level(phone: phone))]
        if !phone { actions.append(.setUp("If you use a tripod, check the head is level with the bubble or the built-in level.")) }
        actions.append(.editor("Straighten only photos whose edge should be level; each photo's note gives the angle."))
        let grade = EvidenceGrade.grade(counted: tilts.count, kind: .sceneDependent)
        var i = Insight(
            id: id, scope: .camera(cam.model), severity: habit ? .notice : .info,
            title: "Your level edges lean \(side) by \(x)°",
            finding: "In the \(Fmt.count(tilts.count, "photo")) with a long level edge, the median tilt is \(x)° (\(side) end lower); \(left) lean left and \(right) lean right by a degree or more.",
            why: habit
                ? "A split that lopsided is unlikely to be chance (sign test p = \(pText)), so it points to how the \(CameraVocabulary.device(phone: phone)) is held or mounted. " + edgeNote
                : "The split is not lopsided enough to call it a habit (sign test p = \(pText)); it may be the scenes. " + edgeNote,
            actions: actions,
            evidence: [EvidenceItem(metric: "Median level-edge tilt (positive = right end lower)", value: Fmt.num(med, 1) + "°", n: tilts.count)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: tilts.count, total: cam.photos.count)
        i.grade = grade; i.kind = .sceneDependent; i.excluded = excluded; i.ruleOrder = 3
        i.checkKind = .levelEdges
        i.share = ShareCount(hits: left + right, of: tilts.count)
        i.imperative = "Level the \(CameraVocabulary.device(phone: phone)) before you shoot."
        i.oneThingDetail = "In the \(Fmt.count(tilts.count, "photo")) with a long level edge, \(left) lean left and \(right) lean right by a degree or more (median \(x)°, \(side) end lower)."
        i.prevalence = Double(sameSideCount) / Double(max(cam.photos.count, 1))
        i.brief = "your level edges lean \(side) by \(x)° (\(Fmt.count(tilts.count, "photo")) with a long level edge)"
        i.whyShown = WhyShown(
            rule: "Takes the median tilt of the long level edge in each photo that has one and appears when it is 0.7° or more. It calls it a habit (Worth acting on) only when the left/right split is lopsided beyond chance (sign test p under 0.05).",
            counted: "\(tilts.count) of \(Fmt.count(cam.photos.count, "photo")): those with a long level edge" + (excluded.isEmpty ? "." : "; " + excluded.map { "\($0.count) \($0.reason)" }.joined(separator: ", ") + " left out."),
            howSure: howSure(grade, counted: tilts.count, kind: .sceneDependent),
            cannotTell: "Whether the edge should be level: a slope, a roof line or a table seen at an angle tilts in the frame however the camera is held.",
            checkYourself: "Photograph a horizon or a door frame with the level on, and again without it, and compare the two notes.")
        return .fired(i)
    }

    // MARK: 11. Shallow depth of field habit
    static let shallowLine = 0.30

    static func shallowDepthHabit(_ cam: CameraGroup) -> Insight? { shallowDepthHabit(cam, .none).insight }

    static func shallowDepthHabit(_ cam: CameraGroup, _ ctx: RuleContext) -> RuleResult {
        let n = cam.photos.count
        let k = cam.photos.filter(\.hasFocusSplit).count
        let id = "shallow-dof:\(cam.model)"
        guard n >= minPhotos else { return .notApplicable }
        guard Double(k) / Double(n) >= shallowLine else {
            return k == 0 ? .notApplicable : .silent(SilentCheck(id: id, name: "Shallow depth of field", reason: "\(k) of \(Fmt.count(n, "photo")) (\(Fmt.share(Double(k) / Double(n)))) split into a sharp subject and a soft background; this note appears at \(Fmt.share(shallowLine))."))
        }
        let ex = extremes(cam.photos, highest: true,
                          value: { p in p.mtf50InfocusCPP.flatMap { s in p.mtf50BackgroundCPP.map { s - $0 } } },
                          caption: { p, _ in Fmt.num(p.mtf50InfocusCPP ?? 0, 2) + " vs " + Fmt.num(p.mtf50BackgroundCPP ?? 0, 2) + " c/px" })
        let grade = EvidenceGrade.grade(counted: n, kind: .sceneDependent)
        var i = Insight(
            id: id, scope: .camera(cam.model), severity: .info,
            title: "You shoot a lot of shallow depth of field",
            finding: "\(Fmt.share(Double(k) / Double(n))) of your photos (\(k) of \(n)) split into a sharp subject and a soft background.",
            why: "On those frames the median edge sharpness includes the blurred background, so it reads low. The p80 figure usually lands on the subject, but when in-focus edges are few it can read the background too; the photo's sharp-group figure is then the one to read.",
            actions: [.editor("When you sharpen, mask the subject instead of sharpening the whole frame."),
                      .editor("On split frames, read the photo's sharp-group figure as its in-focus sharpness.")],
            evidence: [EvidenceItem(metric: "Photos with a clean sharp / soft split", value: Fmt.share(Double(k) / Double(n)), n: n)],
            exampleFiles: ex.files, exampleCaptions: ex.captions, counted: n, total: n)
        i.grade = grade; i.kind = .sceneDependent; i.ruleOrder = 10
        i.brief = "\(k) of your \(n) photos split into a sharp subject and a soft background"
        i.whyShown = WhyShown(
            rule: "Appears when \(Fmt.share(shallowLine)) or more of a camera's photos have measured edges that split cleanly into a sharp group and a soft group.",
            counted: "All \(Fmt.count(n, "photo")); \(k) split.",
            howSure: howSure(grade, counted: n, kind: .sceneDependent),
            cannotTell: "Whether the soft background was intended; it usually is.",
            checkYourself: "Open a split photo with the Focus map overlay and see where the detail sits.")
        return .fired(i)
    }
}
