import Foundation

/// The verdict of a capture check, from rules fixed in advance (spec §5).
enum CheckVerdict: Hashable, Sendable {
    case keepShooting(Int)
    case notComparable
    case worked
    case smallDrop
    case higher
    case notSettled(aboutSame: Bool)

    var word: String {
        switch self {
        case .keepShooting(let k): "Keep shooting (\(k) of \(CheckComparison.firstLook))"
        case .notComparable: "Not comparable"
        case .worked: "It worked"
        case .smallDrop: "A small drop"
        case .higher: "Higher than before"
        case .notSettled(let same): same ? "Not settled yet, about the same so far" : "Not settled yet"
        }
    }

    var symbol: String {
        switch self {
        case .keepShooting: "camera"
        case .notComparable: "exclamationmark.triangle"
        case .worked: "checkmark.seal"
        case .smallDrop: "arrow.down.right"
        case .higher: "arrow.up.right"
        case .notSettled: "hourglass"
        }
    }
}

struct CheckResult: Sendable {
    let verdict: CheckVerdict
    let before: ShareCount
    let after: ShareCount
    /// after - before, as a fraction, with its 95 % range (Newcombe); nil before the first look.
    let difference: Double?
    let range: ClosedRange<Double>?
    /// The verdict in words, with its numbers.
    let sentence: String
    let formatCaveat: String?
    let undatedLine: String?
}

/// Starts checks, counts new photos into them and decides, with rules fixed in advance. Pure.
enum CheckComparison {
    /// New photos before the first look.
    static let firstLook = 10
    /// A drop at least this large (in share) counts as "It worked" (a design choice).
    static let workedDrop = 0.10
    /// A difference within this counts as "about the same so far".
    static let aboutSame = 0.05
    /// The format mix must differ by more than this (in share) for the caveat.
    static let formatMixLine = 0.30

    static let howIDecide = "I compare the share of your new photos with the share before, and allow for chance with a 95 % range (Newcombe's method). 'It worked' means the whole range is below zero and the drop is at least 10 points; 10 points is a choice I made so that small wobbles do not count. I give a first look at 10 new photos; at 10 only a large change can show. A lower share can also mean different scenes, so look at the photos."

    // MARK: Starting

    /// Why a check of this kind cannot start on these results, or nil when it can.
    static func blockReason(_ kind: CheckKind, library: PhotoLibrary?) -> String? {
        guard let library else { return "Open a results file first." }
        switch kind {
        case .highlights, .shadows:
            return library.hasNativeClipping ? nil : "These results were written before clipping was measured in each file's own encoding (15 Oct 2026). Re-analyze the photos, then start the check."
        case .levelEdges:
            return library.hasStructure ? nil : "These results carry no level-edge measurements (they need iqa 0.2 or later). Re-analyze the photos, then start the check."
        }
    }

    /// The photos of a camera that take part, without the check's intent.
    static func participants(_ kind: CheckKind, _ photos: [PhotoRecord], intents: [PhotoKey: Set<IntentTag>]) -> (rows: [(PhotoRecord, Double, Bool)], excluded: Int) {
        var rows: [(PhotoRecord, Double, Bool)] = []
        var excluded = 0
        for p in photos {
            guard let r = kind.reading(p) else { continue }
            if intents[p.key]?.contains(kind.intent) == true { excluded += 1; continue }
            rows.append((p, r.value, r.hit))
        }
        return (rows, excluded)
    }

    /// A new check with its baseline frozen from the loaded library, now.
    static func start(_ kind: CheckKind, camera: CameraGroup, library: PhotoLibrary, intents: [PhotoKey: Set<IntentTag>], now: Date = .now) -> CaptureCheck {
        let (rows, excluded) = participants(kind, camera.photos, intents: intents)
        let formats = Dictionary(grouping: rows.map(\.0), by: { $0.format ?? "unknown" }).mapValues(\.count)
        let baseline = CaptureCheck.Baseline(hits: rows.filter(\.2).count, count: rows.count, formats: formats,
                                             sourceName: library.sourceName, sourceDate: library.sourceDate, intentExcluded: excluded,
                                             undatedKeys: Set(camera.photos.filter { $0.date == nil }.map(\.key)))
        return CaptureCheck(id: UUID(), camera: camera.model, kind: kind, started: now, baseline: baseline)
    }

    // MARK: Counting new photos

    /// Adds the library's new photos to every active check. A photo counts when it comes from the check's camera, was
    /// taken after the start, is not marked with the check's intent and takes part (a level edge, for level edges).
    /// Undated photos are kept apart. The same photo loaded twice counts once.
    static func ingest(_ checks: [CaptureCheck], library: PhotoLibrary, intents: [PhotoKey: Set<IntentTag>]) -> [CaptureCheck] {
        checks.map { c in
            guard c.status == .active else { return c }
            var c = c
            let photos = library.photos.filter { $0.camera == c.camera }
            var fresh: [PhotoKey: CaptureCheck.AfterRow] = [:]
            for p in photos {
                guard let d = p.date else {
                    if !c.baseline.undatedKeys.contains(p.key) { c.undated.insert(p.key) }
                    continue
                }
                guard d > c.started, intents[p.key]?.contains(c.kind.intent) != true, let r = c.kind.reading(p) else { continue }
                fresh[p.key] = CaptureCheck.AfterRow(hit: r.hit, value: r.value, format: p.format, file: p.file, path: p.path)
            }
            guard !fresh.isEmpty else { return c }
            if blockReason(c.kind, library: library) != nil {
                c.notComparable = true
                return c
            }
            c.after.merge(fresh) { _, new in new }
            return c
        }
    }

    // MARK: Deciding

    private static func pts(_ v: Double) -> String { Fmt.num(abs(v) * 100, 0) }

    static func evaluate(_ c: CaptureCheck) -> CheckResult {
        let before = ShareCount(hits: c.baseline.hits, of: c.baseline.count)
        let rows = Array(c.after.values)
        let after = ShareCount(hits: rows.filter(\.hit).count, of: rows.count)
        let undated = c.undated.isEmpty ? nil : "\(Fmt.count(c.undated.count, "new photo")) \(c.undated.count == 1 ? "carries" : "carry") no date and \(c.undated.count == 1 ? "is" : "are") not counted."
        let caveat = formatCaveat(c)
        let beforeText = "Before: \(Fmt.share(before.fraction)) of \(before.of)."
        if c.notComparable {
            let s = c.kind == .levelEdges
                ? "Not comparable: the newest results carry no level-edge measurements. Re-analyze the photos, then start the check again."
                : "Not comparable: these results were written before clipping was measured in each file's own encoding (15 Oct 2026). Re-analyze the photos, then start the check again."
            return CheckResult(verdict: .notComparable, before: before, after: after, difference: nil, range: nil, sentence: s, formatCaveat: nil, undatedLine: undated)
        }
        guard after.of >= firstLook else {
            let s = "\(after.of) of \(firstLook) new photos so far. No hurry: the check waits."
            return CheckResult(verdict: .keepShooting(after.of), before: before, after: after, difference: nil, range: nil, sentence: s, formatCaveat: caveat, undatedLine: undated)
        }
        let n = Stats.newcombeDifference(k1: after.hits, n1: after.of, k2: before.hits, n2: before.of)
        let d = n.difference, r = n.range
        let afterText = "After: \(after.hits) of \(after.of) (\(Fmt.share(after.fraction)))."
        let verdict: CheckVerdict
        let sentence: String
        if r.upperBound < 0 && -d >= workedDrop {
            verdict = .worked
            sentence = "It worked. \(beforeText) \(afterText) The drop is \(pts(d)) points; allowing for chance it is somewhere between \(pts(r.upperBound)) and \(pts(r.lowerBound)) points."
        } else if r.upperBound < 0 {
            verdict = .smallDrop
            sentence = "A small drop. Before: \(before.hits) of \(before.of) (\(Fmt.share(before.fraction))). \(afterText) Allowing for chance the drop is between \(pts(r.upperBound)) and \(pts(r.lowerBound)) points, under the \(pts(workedDrop)) points I count as a change that worked."
        } else if r.lowerBound > 0 {
            verdict = .higher
            sentence = "Higher than before. \(beforeText) \(afterText) Allowing for chance the rise is between \(pts(r.lowerBound)) and \(pts(r.upperBound)) points."
        } else {
            let same = abs(d) <= aboutSame
            verdict = .notSettled(aboutSame: same)
            let span = "the difference could be anywhere from \(pts(r.lowerBound)) points lower to \(pts(r.upperBound)) points higher"
            if same {
                let look = c.kind == .highlights ? " Look at the photos below: white pages and screens clip whatever you do." : " Look at the photos below: a share can also move with the scenes."
                sentence = "Not settled yet, and about the same so far. After: \(after.hits) of \(after.of) (\(Fmt.share(after.fraction))) against \(Fmt.share(before.fraction)) before; \(span).\(look)"
            } else {
                sentence = "Not settled yet. \(beforeText) After: \(after.hits) of \(after.of) new photos. That looks \(d < 0 ? "better" : "worse"), but with \(after.of) photos \(span). Keep going: more photos narrow it."
            }
        }
        return CheckResult(verdict: verdict, before: before, after: after, difference: d, range: r, sentence: sentence, formatCaveat: caveat, undatedLine: undated)
    }

    /// Shown when the JPEG share of the new photos differs from the baseline's by more than 30 points.
    static func formatCaveat(_ c: CaptureCheck) -> String? {
        let rows = Array(c.after.values)
        guard !rows.isEmpty, c.baseline.count > 0 else { return nil }
        let bj = c.baseline.formats["jpeg"] ?? 0, bh = c.baseline.formats["heic"] ?? 0
        let aj = rows.filter { $0.format == "jpeg" }.count, ah = rows.filter { $0.format == "heic" }.count
        let bShare = Double(bj) / Double(c.baseline.count), aShare = Double(aj) / Double(rows.count)
        guard abs(bShare - aShare) > formatMixLine else { return nil }
        let how = c.kind == .levelEdges ? "Level edges are measured the same way in both" : "Clipping is counted the same way in both"
        return "Before: \(bj) of \(c.baseline.count) JPEG, \(bh) HEIC; after: \(aj) of \(rows.count) JPEG, \(ah) HEIC. \(how), but a JPEG copy may have been edited before it was saved."
    }

    /// The start sheet's text, with the baseline's numbers.
    static func startText(_ c: CaptureCheck, phone: Bool) -> String {
        let b = ShareCount(hits: c.baseline.hits, of: c.baseline.count)
        let how: String
        switch c.kind {
        case .highlights: how = phone ? "using the sun slider on bright scenes" : "using exposure compensation on bright scenes"
        case .shadows: how = phone ? "tapping the darker subject in high-contrast scenes" : "using exposure compensation in high-contrast scenes"
        case .levelEdges: how = "with the grid and level turned on"
        }
        return "Check: \(c.kind.title) on \(c.camera). Before: \(b.hits) of \(Fmt.count(b.of, "photo")) (\(Fmt.share(b.fraction)); between \(Fmt.shareBetween(b.range)) allowing for chance) \(c.kind.hitPhrase). Shoot as you normally would, \(how), then choose the new photos with Choose Photos to Analyze…. Only photos taken after now count. I give a first look at \(firstLook) new photos; more give a firmer answer."
    }
}
