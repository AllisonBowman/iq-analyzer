import Foundation

/// What a photo's advice needs besides the photo: its camera's usual rendering, the library's colourfulness, Vision's
/// horizon and the photographer's intent tags.
struct PhotoContext: Sendable {
    var cameraName: String?
    /// The camera's median R/G and B/G (its usual rendering), in stops.
    var cameraLeanR: Double?
    var cameraLeanB: Double?
    var libraryColorfulnessMedian: Double?
    /// Vision's horizon angle in degrees, as `ContentSummary.horizonDegrees` gives it (counter-clockwise positive).
    var visionHorizonDeg: Double?
    var intents: Set<IntentTag> = []

    static let none = PhotoContext()

    init(cameraName: String? = nil, cameraLeanR: Double? = nil, cameraLeanB: Double? = nil, libraryColorfulnessMedian: Double? = nil,
         visionHorizonDeg: Double? = nil, intents: Set<IntentTag> = []) {
        self.cameraName = cameraName
        self.cameraLeanR = cameraLeanR
        self.cameraLeanB = cameraLeanB
        self.libraryColorfulnessMedian = libraryColorfulnessMedian
        self.visionHorizonDeg = visionHorizonDeg
        self.intents = intents
    }

    init(camera: CameraGroup?, library: PhotoLibrary?, visionHorizonDeg: Double? = nil, intents: Set<IntentTag> = []) {
        self.init(cameraName: camera?.model, cameraLeanR: camera?.summary.wbRStops, cameraLeanB: camera?.summary.wbBStops,
                  libraryColorfulnessMedian: library?.colorfulnessMedian, visionHorizonDeg: visionHorizonDeg, intents: intents)
    }

    /// Vision's angle mapped to the analyzer's level-edge convention (positive: right end lower). Vision measures the
    /// horizon counter-clockwise in a y-up frame, so a horizon whose right end is lower has a negative angle. To be
    /// eye-checked on a real photo before shipping (spec §7 step 12).
    var visionTiltRightEndLower: Double? { visionHorizonDeg.map { -$0 } }
}

/// The photo screen's lists (spec §2 layer 5): up to two steps to do first, the rest, what was checked and what could
/// not be measured. Do first and Also are in the fixed edit order.
struct PhotoAdvice: Sendable {
    var doFirst: [EditingAdvice] = []
    var also: [EditingAdvice] = []
    /// Advice the photographer silenced with an intent tag; shown collapsed with Show Anyway.
    var silenced: [EditingAdvice] = []
    var checked: [CheckedItem] = []
    var notMeasured: [NotMeasuredItem] = []

    var nothingToFix: Bool { doFirst.isEmpty }
}

/// A rule that looked at this photo and did not fire, with the value and the rule's line.
struct CheckedItem: Hashable, Sendable {
    let name: String
    let value: String
    /// "acts above 0.5"; empty for a plain statement such as "No repeating pattern".
    let line: String
    var text: String { line.isEmpty ? (value.isEmpty ? name : "\(name) \(value)") : "\(name) \(value) (\(line))" }
}

struct NotMeasuredItem: Hashable, Sendable {
    let name: String
    let reason: String
    var text: String { "\(name): \(reason)" }
}

/// Per-photo editing advice. Every rule is a pure function of one photo and its context.
enum EditingRules {
    static let nothingToFixText = "Nothing here needs fixing: the checks below found nothing to change. Edit for taste."
    /// Noise advice fires below this SNR. It sits inside the Fair band (25 to 32 dB): grain starts to show
    /// under the 32 dB clean mark, and under 30 dB noise reduction is worth the texture it costs.
    static let noiseAdviceDB = 30.0
    /// Sharpness advice fires below this p80 figure (c/px).
    static let softCPP = 0.18
    /// Clipping advice fires above this share of the frame (%).
    static let clipAdvicePct = 0.5
    /// Colour advice fires when the photo differs from its camera's usual rendering by more than this (stops).
    static let leanAdviceStops = 0.15
    /// From this colourfulness a lean probably describes the subject's own colour (library median 39; eye-check
    /// ten such photos before shipping).
    static let colourfulFrom = 60.0
    static let veryColourfulFrom = 100.0
    /// Vision's horizon agrees with the level edge within this many degrees.
    static let visionAgreementDeg = 1.0
    static let doFirstLimit = 2

    // MARK: Lists

    /// All advice for a photo, sorted into Do first, Also, silenced, Checked and Not measured.
    static func advice(for p: PhotoRecord, context ctx: PhotoContext) -> PhotoAdvice {
        let all = [colourLean(p, ctx), exposure(p), blownHighlights(p), crushedShadows(p), flatTones(p), noisy(p), moire(p),
                   soft(p), halo(p), shallowDepth(p), straighten(p, ctx), thirdsCrop(p)].compactMap { $0 }
        var out = PhotoAdvice()
        out.silenced = all.filter { a in a.silencedBy.map(ctx.intents.contains) == true }.sorted { $0.step < $1.step }
        let live = all.filter { a in a.silencedBy.map(ctx.intents.contains) != true }
        // Ranking: evidence, then band severity (Poor before Fair), then edit order. Thin never goes first.
        let ranked = live.filter { $0.grade != .thin }.sorted { a, b in
            if a.grade != b.grade { return a.grade > b.grade }
            if a.severityBand != b.severityBand { return a.severityBand < b.severityBand }
            return a.step < b.step
        }
        let first = Array(ranked.prefix(doFirstLimit))
        out.doFirst = first.sorted { $0.step < $1.step }
        out.also = live.filter { a in !first.contains { $0.id == a.id } }.sorted { $0.step < $1.step }
        out.checked = checked(p, ctx, fired: Set(all.map(\.rule)))
        out.notMeasured = notMeasured(p)
        return out
    }

    /// Every piece of advice that fires, without context: the legacy flat list (or the "clean" placeholder).
    static func advice(for p: PhotoRecord) -> [EditingAdvice] {
        let a = advice(for: p, context: .none)
        let found = (a.doFirst + a.also).sorted { $0.step < $1.step }
        if found.isEmpty {
            return [EditingAdvice(id: "clean:\(p.id)", rule: .clean, metric: nil, title: "Nothing to fix", finding: nothingToFixText,
                                  apple: "Nothing needed. Try Auto only if you want a quick look.",
                                  lightroom: "Nothing needed. Adjust Vibrance or a preset for style.",
                                  generic: "Nothing needed; edit for taste.", caution: nil, grade: .solid, step: .composition)]
        }
        return found
    }

    static func isNothingToFix(_ list: [EditingAdvice]) -> Bool { list.count == 1 && list[0].rule == .clean }

    // MARK: Checked, nothing to do

    /// Formats a value next to its line so rounding never lands on the line: 11.99 % under a 12 % line reads
    /// "11.99 %", not "12.0 %".
    static func clear(_ v: Double, of line: Double, digits: Int, unit: String) -> String {
        var d = digits
        while d < 4, Fmt.num(v, d) == Fmt.num(line, d) || (Double(Fmt.num(v, d).replacingOccurrences(of: ",", with: "")).map { ($0 - line) * (v - line) <= 0 } ?? false) { d += 1 }
        return Fmt.num(v, d) + unit
    }

    static func checked(_ p: PhotoRecord, _ ctx: PhotoContext, fired: Set<AdviceRule>) -> [CheckedItem] {
        var out: [CheckedItem] = []
        func add(_ rule: AdviceRule, _ item: CheckedItem?) { if !fired.contains(rule), let item { out.append(item) } }
        if ctx.cameraLeanR != nil || ctx.cameraLeanB != nil, let r = p.wbROverGStops, let b = p.wbBOverGStops {
            let d = max(abs(r - (ctx.cameraLeanR ?? 0)), abs(b - (ctx.cameraLeanB ?? 0)))
            add(.colourLean, d <= leanAdviceStops ? CheckedItem(name: "Colour", value: "within \(Fmt.num(leanAdviceStops, 2)) stops of this camera's usual", line: "") : nil)
        } else if let lean = p.wbLeanStops {
            add(.colourLean, lean <= leanAdviceStops ? CheckedItem(name: "Colour lean", value: Fmt.stops(lean), line: "acts above \(Fmt.num(leanAdviceStops, 2))") : nil)
        }
        if let l = p.lumaP50 {
            add(.exposure, (70...190).contains(l) ? CheckedItem(name: "Middle tone", value: "\(Fmt.int(l)) of 255", line: "acts below 70 or above 190") : nil)
        }
        if let c = p.clipHighPct {
            add(.highlights, c <= clipAdvicePct ? CheckedItem(name: "Blown highlights", value: clear(c, of: clipAdvicePct, digits: 2, unit: " %"), line: "acts above \(Fmt.num(clipAdvicePct, 1))") : nil)
        }
        if let c = p.clipLowPct {
            add(.shadows, c <= clipAdvicePct ? CheckedItem(name: "Crushed shadows", value: clear(c, of: clipAdvicePct, digits: 2, unit: " %"), line: "acts above \(Fmt.num(clipAdvicePct, 1))") : nil)
        }
        if let t = p.tonalRangeStops, t >= 7 {
            add(.flatTones, CheckedItem(name: "Tonal range", value: Fmt.stops(t, 1), line: "acts below 7"))
        }
        if p.snrIsClean, let s = p.snrMidgreyDB, s >= noiseAdviceDB {
            add(.noise, CheckedItem(name: "Noise", value: clear(s, of: noiseAdviceDB, digits: 1, unit: " dB"), line: "acts below \(Fmt.int(noiseAdviceDB))"))
        }
        if p.noisePeriodicSuspect == false { add(.moire, CheckedItem(name: "No repeating pattern", value: "", line: "")) }
        if p.hasSharpnessFigure, let c = p.mtf50P80CPP, c >= softCPP {
            add(.soft, CheckedItem(name: "Sharpness", value: clear(c, of: softCPP, digits: 2, unit: " c/px"), line: "acts below \(Fmt.num(softCPP, 2))"))
        }
        if p.hasSharpnessFigure, let o = p.overshootMedianPct, o < Metric.overshootHaloPct {
            add(.halo, CheckedItem(name: "Sharpening halo", value: clear(o, of: Metric.overshootHaloPct, digits: 1, unit: " %"), line: "acts at \(Fmt.int(Metric.overshootHaloPct)) or above"))
        }
        if let t = p.structureHorizonTiltDeg, abs(t) < 1 {
            add(.straighten, CheckedItem(name: "Level edge", value: Fmt.num(abs(t), 1) + "°", line: "acts at 1° or more"))
        }
        if let d = p.structureThirdsDistance, d <= 0.75 {
            add(.thirds, CheckedItem(name: "Subject", value: "\(Fmt.num(d, 2)) from a thirds point", line: "acts above 0.75"))
        }
        return out
    }

    // MARK: Not measured

    static func notMeasured(_ p: PhotoRecord) -> [NotMeasuredItem] {
        var out: [NotMeasuredItem] = []
        if !p.hasSharpnessFigure { out.append(NotMeasuredItem(name: "Sharpness", reason: sharpnessReason(p))) }
        if p.snrMidgreyDB == nil {
            out.append(NotMeasuredItem(name: "Noise", reason: "no flat area was found to measure it on."))
        } else if let r = p.snrExclusionReason {
            out.append(NotMeasuredItem(name: "Noise", reason: "not read as noise: \(r), so the noise advice does not apply."))
        }
        return out
    }

    /// "7 candidate edges were found and none could be used (2 too noisy on either side; one each …)."
    static func sharpnessReason(_ p: PhotoRecord) -> String {
        let used = p.edgesMeasured ?? 0
        let tail = "A figure needs \(PhotoRecord.minEdgesForSharpness) usable straight edges; this says nothing about whether the photo is sharp."
        guard let cand = p.edgesCandidates, cand > 0 else {
            return "no straight edge the method could use was found in the scene. Water, sky, foliage and petals rarely give one. " + tail
        }
        let reasons = p.rejectReasons
        var groups: [String] = reasons.filter { $0.count > 1 }.map { "\($0.count) \($0.reason.words)" }
        let ones = reasons.filter { $0.count == 1 }.map(\.reason.words)
        if ones.count == 1 { groups.append("1 \(ones[0])") }
        if ones.count > 1 { groups.append("one each " + ones.dropLast().joined(separator: ", ") + " and " + ones.last!) }
        let usedText = used == 0 ? "none could be used" : "only \(used) could be used"
        return "\(Fmt.count(cand, "candidate edge")) \(cand == 1 ? "was" : "were") found and \(usedText)" + (groups.isEmpty ? "." : " (" + groups.joined(separator: "; ") + ").") + " " + tail
    }

    // MARK: Rules

    private static let noDetailCaution = "On a JPEG or HEIC, pixels at the top of the range hold no detail in that channel: this softens the glare but cannot bring detail back."

    /// "A further 1.9 % of pixels hold colour sRGB cannot show …", when the file holds colour beyond sRGB.
    static func gamutNote(_ p: PhotoRecord) -> String? {
        guard let g = p.clipGamutPct, g >= 0.5 else { return nil }
        return "A further \(Fmt.pct(g, 1)) of pixels hold colour sRGB cannot show; that colour is in the file and is not lost detail. Keep the original, or export with a Display P3 profile where your app offers one."
    }

    static func blownHighlights(_ p: PhotoRecord) -> EditingAdvice? {
        guard let c = p.clipHighPct, c > clipAdvicePct else { return nil }
        var a = EditingAdvice(
            id: "highlights:\(p.id)", rule: .highlights, metric: .highlightClip, title: "Blown highlights",
            finding: "\(Fmt.pct(c, 1)) of the picture is blown: at the top of the range in at least one colour channel, counted in the file's own encoding.",
            apple: "Adjust > Light: drag Highlights down, then add Brilliance to open the bright areas.",
            lightroom: "Highlights -40 to -80, then Whites down a little.",
            generic: "Lower highlights, then whites.",
            caution: p.isRaw == true ? "A RAW file can recover one or two stops of highlights, so push further if the preview allows." : noDetailCaution,
            grade: .solid, step: .tone)
        a.note = gamutNote(p)
        a.silencedBy = .brightOnPurpose
        a.band = Metric.highlightClip.band(for: c)
        return a
    }

    static func crushedShadows(_ p: PhotoRecord) -> EditingAdvice? {
        guard let c = p.clipLowPct, c > clipAdvicePct else { return nil }
        var a = EditingAdvice(
            id: "shadows:\(p.id)", rule: .shadows, metric: .shadowClip, title: "Crushed shadows",
            finding: "\(Fmt.pct(c, 1)) of the picture is crushed to pure black.",
            apple: "Adjust > Light: drag Shadows up and lower Black Point.",
            lightroom: "Shadows +30 to +60; Blacks +10 to +30.",
            generic: "Raise shadows, then lift the black point.",
            caution: "Lifting shadows raises noise; check the noise advice and the photo's SNR first.",
            grade: .solid, step: .tone)
        a.silencedBy = .darkOnPurpose
        a.band = Metric.shadowClip.band(for: c)
        return a
    }

    static func noisy(_ p: PhotoRecord) -> EditingAdvice? {
        // Only a clean reading counts: extrapolated, texture-suspect and periodic rows are not sensor noise.
        guard p.snrIsClean, let s = p.snrMidgreyDB, s < noiseAdviceDB else { return nil }
        let smoothed = (p.noiseWhiteness ?? 0) >= Metric.whitenessHeavy
        var a = EditingAdvice(
            id: "noise:\(p.id)", rule: .noise, metric: .snr, title: "Noise",
            finding: "Noise is visible: signal to noise is \(Fmt.db(s)). Grain starts to show under the \(Fmt.db(Metric.snrCleanDB)) clean mark; under \(Fmt.db(noiseAdviceDB)) noise reduction is worth applying." + (smoothed ? " The camera has already smoothed it (whiteness \(Fmt.num(p.noiseWhiteness ?? 0, 2))): add only gentle noise reduction." : ""),
            apple: "Adjust > Noise Reduction: start gently, around 30 to 50.",
            lightroom: "Denoise (AI) 30-50, or Luminance noise reduction 20-40 with Detail 50.",
            generic: "Apply luminance noise reduction before any sharpening.",
            caution: smoothed ? "Already smoothed by the camera (noise whiteness \(Fmt.num(p.noiseWhiteness ?? 0, 2))); more noise reduction will smear texture." : nil,
            grade: .moderate, step: .noise)
        a.band = Metric.snr.band(for: s)
        return a
    }

    static func soft(_ p: PhotoRecord) -> EditingAdvice? {
        // A sharpness figure needs three valid edges. On a shallow-depth-of-field frame whose sharp group is not
        // soft, a low p80 is the background, not the subject.
        guard p.hasSharpnessFigure, let c = p.mtf50P80CPP, c < softCPP else { return nil }
        if p.hasFocusSplit, (p.mtf50InfocusCPP ?? 0) >= softCPP { return nil }
        let o = p.overshootMedianPct ?? 0
        var a: EditingAdvice
        if o >= Metric.overshootHardPct {
            a = EditingAdvice(
                id: "soft:\(p.id)", rule: .soft, metric: .sharpnessCPP, title: "Soft",
                finding: "Sharpness is low (\(Fmt.cpp(c))) but edges already overshoot by \(Fmt.pct(o, 1)).",
                apple: "Already sharpened; do not add more. Leave Sharpen at 0.",
                lightroom: "Already sharpened; do not add more. Keep Sharpening low and Masking high.",
                generic: "Already sharpened; do not add more. Downsize for the web with care, using a soft resampler.",
                caution: "The softness is probably focus or motion blur; sharpening would only thicken the halos.",
                grade: .moderate, step: .sharpening)
        } else {
            a = EditingAdvice(
                id: "soft:\(p.id)", rule: .soft, metric: .sharpnessCPP, title: "Soft",
                finding: "Sharpness is low (\(Fmt.cpp(c)), under \(Fmt.num(softCPP, 2))) and the edges show little sharpening (\(Fmt.pct(o, 1)) overshoot).",
                apple: "Adjust > Sharpen: start around 20 to 40 for Sharpness, and about 10 for Definition.",
                lightroom: "Detail > Sharpening 40-60, Radius 1.0, Masking 40-70.",
                generic: "Sharpen on luminance only, and mask flat areas such as sky.",
                caution: nil, grade: .moderate, step: .sharpening)
        }
        a.band = Metric.sharpnessCPP.band(for: c)
        return a
    }

    static func halo(_ p: PhotoRecord) -> EditingAdvice? {
        guard p.hasSharpnessFigure, let o = p.overshootMedianPct, o >= Metric.overshootHaloPct else { return nil }
        var a = EditingAdvice(
            id: "halo:\(p.id)", rule: .halo, metric: .overshoot, title: "Sharpening halo",
            finding: "Edges overshoot by \(Fmt.pct(o, 1)): a visible sharpening halo (\(Fmt.int(Metric.overshootHaloPct)) % and up). Do not add sharpening.",
            apple: "Adjust > Sharpen: leave it off (Sharpness at 0).",
            lightroom: "Reduce Sharpening to 0-20 and set Clarity to 0.",
            generic: "Avoid any further sharpening.",
            caution: nil, grade: .moderate, step: .sharpening)
        a.band = Metric.overshoot.band(for: o)
        return a
    }

    static func colourLean(_ p: PhotoRecord, _ ctx: PhotoContext = .none) -> EditingAdvice? {
        guard p.wbROverGStops != nil || p.wbBOverGStops != nil, let lean = p.wbLeanStops else { return nil }
        let r = p.wbROverGStops ?? 0, b = p.wbBOverGStops ?? 0
        let hasCamera = ctx.cameraLeanR != nil || ctx.cameraLeanB != nil
        let camR = ctx.cameraLeanR ?? 0, camB = ctx.cameraLeanB ?? 0
        let gap = hasCamera ? max(abs(r - camR), abs(b - camB)) : lean
        guard gap > leanAdviceStops else { return nil }
        let d = CameraRules.leanDescription(r: r, b: b)
        var lr: [String] = []
        if d.words.contains("warm") { lr.append("Temp toward blue (negative)") }
        if d.words.contains("cool") { lr.append("Temp toward yellow (positive)") }
        if d.words.contains("magenta") { lr.append("Tint toward green (negative)") }
        if d.words.contains("green") { lr.append("Tint toward magenta (positive)") }
        var finding = "This picture leans \(d.words) by \(Fmt.stops(lean))"
        if hasCamera {
            let usual = max(abs(camR), abs(camB))
            finding += "; your \(ctx.cameraName ?? "camera") usually leans \(Fmt.stops(usual)), so " + (lean > 2 * usual ? "most of this is the light or the subject." : "part of this is the camera's usual rendering.")
        } else {
            finding += "."
        }
        var caution = "Gray-world on one scene: a sunset or stage lighting is intent, so leave the lean if it is the mood you wanted."
        if let c = p.colorfulness, c >= colourfulFrom {
            let med = ctx.libraryColorfulnessMedian.map { "; your library's median is \(Fmt.int($0))" } ?? ""
            if c >= veryColourfulFrom {
                finding += " It is a very colourful picture (colourfulness \(Fmt.int(c))\(med)), so the figure most likely describes the subject's own colour, not the light."
                caution = "Leave white balance alone unless greys look tinted."
            } else {
                finding += " It is a colourful picture (colourfulness \(Fmt.int(c))\(med)), so the figure may describe the subject's own colour."
                caution = "Correct it only if greys should look neutral."
            }
        }
        var a = EditingAdvice(
            id: "lean:\(p.id)", rule: .colourLean, metric: .whiteBalance, title: "Colour lean",
            finding: finding,
            apple: "Adjust > White Balance: use the picker on something that should be grey or white.",
            lightroom: "White Balance: " + lr.joined(separator: ", ") + ", or use the eyedropper on a neutral.",
            generic: "Use the white-balance picker on something that should be neutral.",
            caution: caution, grade: .thin, step: .whiteBalance)
        a.silencedBy = .colourIsThePoint
        a.band = Metric.whiteBalance.band(for: lean)
        return a
    }

    static func flatTones(_ p: PhotoRecord) -> EditingAdvice? {
        guard let t = p.tonalRangeStops, t < 7, (p.clipHighPct ?? 0) < 0.2, (p.clipLowPct ?? 0) < 0.2 else { return nil }
        var a = EditingAdvice(
            id: "flat:\(p.id)", rule: .flatTones, metric: .tonalRange, title: "Flat tones",
            finding: "Tones are flat: only \(Fmt.stops(t, 1)) between darkest and brightest, with room to spare at both ends.",
            apple: "Adjust > Light: Contrast up, and raise Black Point to deepen the blacks.",
            lightroom: "Contrast +15 to +30, or add a gentle tone curve.",
            generic: "Apply an S-curve.",
            caution: nil, grade: .solid, step: .tone)
        a.band = .fair
        return a
    }

    static func exposure(_ p: PhotoRecord) -> EditingAdvice? {
        guard let l = p.lumaP50 else { return nil }
        if l < 70 {
            var a = EditingAdvice(
                id: "dark:\(p.id)", rule: .exposure, metric: nil, title: "Exposure: dark",
                finding: "The picture is dark: the middle tone sits at \(Fmt.int(l)) of 255.",
                apple: "Adjust > Light: Exposure up, starting around +0.3 to +0.7.",
                lightroom: "Exposure up, starting around +0.3 to +0.7.",
                generic: "Raise exposure, starting around a third to two-thirds of a stop.",
                caution: "Brighten before you judge noise; brightening raises it.",
                grade: .solid, step: .exposure)
            a.silencedBy = .darkOnPurpose
            a.band = .fair
            return a
        }
        if l > 190, (p.clipHighPct ?? 0) < 0.5, (p.clipLowPct ?? 0) < 0.5 {
            var a = EditingAdvice(
                id: "bright:\(p.id)", rule: .exposure, metric: nil, title: "Exposure: bright",
                finding: "The picture is bright: the middle tone sits at \(Fmt.int(l)) of 255, with nothing clipped.",
                apple: "Adjust > Light: Exposure down, starting around -0.3.",
                lightroom: "Exposure -0.3.",
                generic: "Lower exposure, starting around a third of a stop.",
                caution: nil, grade: .solid, step: .exposure)
            a.silencedBy = .brightOnPurpose
            a.band = .fair
            return a
        }
        return nil
    }

    static func moire(_ p: PhotoRecord) -> EditingAdvice? {
        guard p.noisePeriodicSuspect == true else { return nil }
        var a = EditingAdvice(
            id: "moire:\(p.id)", rule: .moire, metric: nil, title: "Moire",
            finding: "A repeating pattern (moire, a screen or a fabric weave) was found in the flat areas. Where it covered a minority of them it was removed before measuring; otherwise the noise figure describes the pattern. Either way this photo is left out of the camera's noise figures.",
            apple: "Photos has no moire control; crop or re-shoot.",
            lightroom: "Use the Moire brush in the Adjustment brush panel.",
            generic: "Re-shoot at a different distance or angle.",
            caution: "Moire comes from fine regular detail (screens, fabric, brick) beating against the sensor grid.",
            grade: .moderate, step: .noise)
        a.band = .fair
        return a
    }

    /// Thin on its own: a level edge is not always a horizon. Moderate when Vision's horizon agrees within 1°.
    static func straighten(_ p: PhotoRecord, _ ctx: PhotoContext = .none) -> EditingAdvice? {
        guard let t = p.structureHorizonTiltDeg, abs(t) >= 1.0 else { return nil }
        let a = Fmt.num(abs(t), 1) + "°"
        let dir = t > 0 ? "counter-clockwise" : "clockwise"
        let agrees = ctx.visionTiltRightEndLower.map { abs($0 - t) <= visionAgreementDeg } ?? false
        var vision = ""
        if let v = ctx.visionTiltRightEndLower {
            vision = agrees ? " Vision finds a horizon \(Fmt.num(abs(v), 1))° off level, which agrees: probably a real horizon."
                            : " Vision's horizon (\(Fmt.num(abs(v), 1))° off level) does not agree, so it may be a table, a roof line or a slope; straighten only if it should be level."
        } else if ctx.visionHorizonDeg == nil && ctx.cameraName != nil {
            vision = " Vision found no horizon, so it is probably a table, a roof line or a slope; straighten only if it should be level."
        }
        var adv = EditingAdvice(
            id: "straighten:\(p.id)", rule: .straighten, metric: nil, title: "Level edge",
            finding: "Straighten by \(a): a long level edge is tilted \(a) (\(t > 0 ? "right" : "left") end lower). It may be a horizon or a table edge seen at an angle." + vision,
            apple: "Crop > Straighten dial: turn it \(dir) by \(a), or press Auto.",
            lightroom: "Transform > Auto, or the Straighten tool in the Crop panel, or the Angle slider set to \(Fmt.num(-t, 1))°.",
            generic: "Rotate by \(Fmt.num(-t, 1))° and crop in to remove the empty corners.",
            caution: "Straightening crops the corners, so leave room round the edges. A tilted line may be intended, such as a slope.",
            grade: agrees ? .moderate : .thin, step: .geometry)
        adv.silencedBy = .notMeantToBeLevel
        adv.band = Structure.horizonBand(t)
        return adv
    }

    static func thirdsCrop(_ p: PhotoRecord) -> EditingAdvice? {
        guard let d = p.structureThirdsDistance, d > 0.75, let f = p.structureFocusFraction, f < 0.4 else { return nil }
        var a = EditingAdvice(
            id: "thirds:\(p.id)", rule: .thirds, metric: nil, title: "Composition",
            finding: "The subject sits \(Fmt.num(d, 2)) from the nearest rule-of-thirds point (0 is on the point, 1 is the frame centre), with detail concentrated in \(Fmt.share(f)) of the frame.",
            apple: "Crop, with the grid showing: drag the frame so the subject lands on a crossing of the grid lines.",
            lightroom: "Crop overlay: press O to cycle to the Rule of Thirds grid, then position the subject on a crossing.",
            generic: "Crop so the subject sits on a rule-of-thirds crossing.",
            caution: "Composition is taste: a centred or off-balance subject can be exactly the point.",
            grade: .thin, step: .composition)
        a.silencedBy = .composedThisWay
        return a
    }

    static func shallowDepth(_ p: PhotoRecord) -> EditingAdvice? {
        guard let sharp = p.mtf50InfocusCPP, let bg = p.mtf50BackgroundCPP, sharp > 0, bg < 0.5 * sharp else { return nil }
        return EditingAdvice(
            id: "shallow:\(p.id)", rule: .shallow, metric: nil, title: "Shallow depth of field",
            finding: "Shallow depth of field: the sharp group measures \(Fmt.cpp(sharp)) and the background \(Fmt.cpp(bg)). Sharpen only the subject.",
            apple: "Photos has no local tool: apply light sharpening only (Adjust > Sharpen, Intensity low).",
            lightroom: "Masking > Subject, then Sharpening + on that mask.",
            generic: "Mask the subject and sharpen only inside the mask.",
            caution: "Global sharpening will bring out noise in the blurred areas.",
            grade: .thin, step: .sharpening)
    }
}
