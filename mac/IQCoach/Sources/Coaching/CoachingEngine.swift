import Foundation

enum CoachingEngine {
    /// Every camera rule's result for one camera. Cameras under five photos get none.
    static func results(for cam: CameraGroup, context ctx: RuleContext = .none) -> [RuleResult] {
        guard cam.photos.count >= CameraRules.minPhotos else { return [] }
        return [
            CameraRules.noiseByISO(cam, ctx),
            CameraRules.noiseCharacter(cam, ctx),
            CameraRules.lensComparison(cam, ctx),
            CameraRules.fieldSoftness(cam, ctx),
            CameraRules.highlightDiscipline(cam, ctx),
            CameraRules.shadowDiscipline(cam, ctx),
            CameraRules.sharpeningCharacter(cam, ctx),
            CameraRules.colourLean(cam, ctx),
            CameraRules.slowShutter(cam, ctx),
            CameraRules.levelEdgeLean(cam, ctx),
            CameraRules.shallowDepthHabit(cam, ctx),
        ] + CameraRules.apertureResults(cam, ctx)
    }

    /// Card order: severity, then evidence word, then the fixed rule order.
    static func ranked(_ a: Insight, before b: Insight) -> Bool {
        if a.severity != b.severity { return a.severity > b.severity }
        if a.grade != b.grade { return a.grade > b.grade }
        if a.ruleOrder != b.ruleOrder { return a.ruleOrder < b.ruleOrder }
        return a.id < b.id
    }

    /// All camera-level findings (Thin ones included), most important first.
    static func insights(for cam: CameraGroup, context ctx: RuleContext = .none) -> [Insight] {
        results(for: cam, context: ctx).compactMap(\.insight).sorted(by: ranked)
    }

    static func editingAdvice(for photo: PhotoRecord) -> [EditingAdvice] {
        EditingRules.advice(for: photo)
    }

    // MARK: Output (spec §4.5)

    /// Share of a camera's photos that must show the behaviour an action changes before it can be the one thing.
    static let minPrevalence = 0.10

    /// True when a card can be the one thing: Worth acting on or above, not Thin, an action at the camera or set up
    /// once, a one-thing sentence, and the behaviour it changes in at least 10 % of the camera's photos.
    static func isEligible(_ i: Insight) -> Bool {
        i.severity >= .notice && i.grade != .thin && i.imperative != nil
            && i.actions.contains { $0.effort == .atCamera || $0.effort == .setUpOnce }
            && (i.prevalence ?? 0) >= minPrevalence
    }

    static func output(for cam: CameraGroup, prefs: UserPreferences = UserPreferences()) -> CoachingOutput {
        guard cam.photos.count >= CameraRules.minPhotos else { return CoachingOutput() }
        let results = results(for: cam, context: prefs.context)
        var active: [Insight] = [], setAside: [SetAsideCard] = []
        for var i in results.compactMap(\.insight) {
            if let d = prefs.setAside[i.id] {
                if let reason = d.comeBackReason(for: i) {
                    i.backBecause = reason
                    active.append(i)
                } else {
                    setAside.append(SetAsideCard(insight: i, dismissal: d))
                }
            } else {
                active.append(i)
            }
        }
        var out = CoachingOutput()
        out.cards = active.filter { !$0.isThin }.sorted(by: ranked)
        out.needsMorePhotos = active.filter(\.isThin).sorted(by: ranked)
        out.setAside = setAside.sorted { ranked($0.insight, before: $1.insight) }
        out.silent = results.compactMap(\.silentCheck)
        out.oneThing = oneThing(cam, cards: out.cards, thin: out.needsMorePhotos)
        return out
    }

    private static func oneThing(_ cam: CameraGroup, cards: [Insight], thin: [Insight]) -> OneThing {
        let eligible = cards.filter(isEligible)
        if let top = eligible.first {
            let next: String?
            if eligible.count > 1, let b = eligible[1].brief {
                next = "Next up: \(b)."
            } else {
                next = alsoGoodToKnow(cards.filter { $0.id != top.id && !isEligible($0) })
            }
            let action = top.actions.first { $0.effort == .atCamera || $0.effort == .setUpOnce }
            return OneThing(insight: top, sentence: top.imperative ?? top.title, detail: top.oneThingDetail ?? top.finding,
                            action: action, nextUp: next)
        }
        let also = alsoGoodToKnow(cards)
        let s = cam.summary
        if cam.photos.count < EvidenceGrade.thinBelow {
            return OneThing(insight: nil, sentence: "No single change stands out yet.",
                            detail: "Every finding for this camera rests on fewer than \(EvidenceGrade.thinBelow) photos, so they are listed under Needs more photos. Add photos from this camera with Choose Photos to Analyze… to get coaching you can act on.",
                            action: nil, nextUp: also)
        }
        if let candidate = thin.first(where: { $0.imperative != nil && $0.severity >= .notice }), let b = candidate.brief {
            return OneThing(insight: nil, sentence: "No single change stands out yet.",
                            detail: "The likeliest candidate needs more photos: \(b).", action: nil, nextUp: also)
        }
        var detail = ""
        let n = s.photoCount
        if (s.clipHighShare ?? 0) <= CameraRules.clipShareLine && (s.clipLowShare ?? 0) <= CameraRules.clipShareLine {
            let lows = s.clipLowCount == 0 ? "none loses its shadows" : "\(s.clipLowCount) \(s.clipLowCount == 1 ? "loses" : "lose") more than 1 % to pure black"
            let highs = s.clipHighCount == 0 ? "none has" : "\(s.clipHighCount) \(s.clipHighCount == 1 ? "has" : "have")"
            detail = "Your \(Fmt.count(n, "photo")) rarely clip: \(highs) more than 1 % blown and \(lows)."
        } else {
            detail = "Nothing this camera does is both common enough and firm enough to be the one change."
        }
        if !s.hasSharpnessFigure {
            detail += " Sharpness needs scenes with straight edges; water, sky and foliage give the method nothing to measure (\(s.sharpnessCounted) of \(Fmt.count(n, "photo")) had 3 or more usable edges)."
        }
        return OneThing(insight: nil, sentence: "No single change stands out.", detail: detail, action: nil, nextUp: also)
    }

    /// "Also good to know: …" from the strongest Solid card that cannot be the one thing, Good to know first.
    /// Shooting habits come first (a card with an action at the camera or set up once), then the fixed rule order: an
    /// editor-only card belongs to the photo screen's steps rather than to this line.
    private static func alsoGoodToKnow(_ cards: [Insight]) -> String? {
        func shooting(_ i: Insight) -> Bool { i.actions.contains { $0.effort != .inEditor } }
        let solid = cards.filter { $0.grade == .solid && $0.brief != nil }
        let pick = solid.sorted { a, b in
            if shooting(a) != shooting(b) { return shooting(a) }
            if a.ruleOrder != b.ruleOrder { return a.ruleOrder < b.ruleOrder }
            return ranked(a, before: b)
        }.first
        return pick?.brief.map { "Also good to know: \($0)." }
    }

    /// The one-thing sentence for the library table, the sidebar tooltip and the export.
    static func oneThingLine(for cam: CameraGroup, prefs: UserPreferences = UserPreferences()) -> String {
        guard cam.photos.count >= CameraRules.minPhotos else { return "Coaching starts at \(CameraRules.minPhotos) photos" }
        return output(for: cam, prefs: prefs).oneThing?.sentence ?? "No single change stands out."
    }

    // MARK: Library headline

    /// Cameras with at least 5 photos and two ISO bands of 3 or more clean photos, split by whether noise follows ISO.
    static func headline(for cameras: [CameraGroup]) -> String? {
        let rated = cameras.filter { $0.photos.count >= CameraRules.minPhotos && $0.summary.snrFollowsISO != nil }
        let following = rated.filter { $0.summary.snrFollowsISO == true }
        let not = rated.filter { $0.summary.snrFollowsISO == false }
        guard !rated.isEmpty else { return nil }
        func list(_ cs: [CameraGroup]) -> String {
            let names = cs.map(\.model)
            return "the " + (names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!)
        }
        var parts: [String] = []
        if !following.isEmpty {
            let detail = following.count == 1 ? following[0].summary.ratedBands : []
            var s = following.count == 1 ? "The \(following[0].model)'s noise follows ISO the way a sensor's does"
                                         : "On \(list(following)) noise follows ISO the way a sensor's does"
            if let a = detail.first, let b = detail.last, detail.count >= 2 {
                s += ": \(Fmt.db(a.median)) at \(a.band.label), falling to \(Fmt.db(b.median)) \(b.band == .above1000 ? "" : "at ")\(b.band.label)"
            }
            parts.append(s + ".")
        }
        if !not.isEmpty {
            parts.append("On \(list(not)) it does not fall steadily with ISO, which points to processing: noise figures here compare each camera's processing, not its sensor.")
        }
        return parts.joined(separator: " ")
    }
}

/// What the camera screen shows, in order (spec §4.5).
struct CoachingOutput: Sendable {
    var oneThing: OneThing?
    /// Not Thin, not set aside: severity, then evidence word, then rule order.
    var cards: [Insight] = []
    /// Thin findings.
    var needsMorePhotos: [Insight] = []
    var setAside: [SetAsideCard] = []
    /// Rules that looked and had nothing to say.
    var silent: [SilentCheck] = []
}

/// The one change most worth making, or the fallback when nothing qualifies.
struct OneThing: Sendable {
    /// nil for the fallback.
    let insight: Insight?
    /// "Expose for the highlights." or "No single change stands out."
    let sentence: String
    let detail: String
    /// The single at-camera or set-up-once action.
    let action: Action?
    /// "Next up: …" or "Also good to know: …".
    let nextUp: String?

    var isFallback: Bool { insight == nil }

    /// The VoiceOver label, spelled out.
    func spoken(camera: String) -> String {
        var s = "The one thing for \(camera). \(sentence) \(detail)"
        if let i = insight { s += " \(i.severity.word). \(i.grade.word) evidence, \(Fmt.count(i.counted, "photo"))." }
        if let a = action { s += " \(a.effort.word)." }
        return s
    }
}

struct SetAsideCard: Sendable, Identifiable {
    let insight: Insight
    let dismissal: Dismissal
    var id: String { insight.id }
}
