import Foundation

/// Markdown exports (spec §6), for ShareLink and the clipboard. Nothing is computed here: every line comes from the
/// same engine output the screen shows, so a sheet can never disagree with the screen.
enum MarkdownExport {
    static let footer = "Measured by iq-analyzer. One photo's sharpness is a range; camera medians over many photos are the figures to trust. Noise is measured on the finished file, so it compares processing as much as sensors."

    /// "From results.json, written 23 Oct 2026 04:36 · 206 photos, shot 19 Jun to 12 Oct 2026"
    static func provenance(_ cam: CameraGroup, library: PhotoLibrary?) -> String {
        var t = "From \(library?.sourceName ?? "results")"
        if let d = library?.sourceDate { t += ", written \(Fmt.date(d)) \(d.formatted(date: .omitted, time: .shortened))" }
        t += " · \(Fmt.count(cam.photos.count, "photo"))"
        if let a = cam.summary.firstDate, let b = cam.summary.lastDate { t += ", shot \(Fmt.date(a)) to \(Fmt.date(b))" }
        return t
    }

    // MARK: 1. The full camera report

    static func coaching(for cam: CameraGroup, output o: CoachingOutput, checks: [CaptureCheck] = [], library: PhotoLibrary? = nil) -> String {
        var out = "# \(cam.model): coaching from IQ Coach\n\(provenance(cam, library: library))\n\n"
        out += "## The one thing\n"
        if let one = o.oneThing {
            out += "\(one.sentence) \(one.detail)\n"
            if let i = one.insight {
                out += "\(i.capsuleText)" + (one.action.map { " · \($0.effort.word)" } ?? "") + "\n"
                if let a = one.action { out += "- [ ] \(a.text)\n" }
            }
            if let n = one.nextUp { out += "\(n)\n" }
        } else {
            out += "Coaching starts at \(CameraRules.minPhotos) photos; this camera has \(cam.photos.count). \(SparseSummary.text(for: cam))\n"
        }
        out += "\n## Report card\n"
        for line in reportCard(cam.summary) { out += "- \(line)\n" }
        if !o.cards.isEmpty {
            out += "\n## Coaching\n"
            for i in o.cards {
                out += "\n### \(i.title) (\(i.capsuleText))\n\(i.finding)\n\n**Why.** \(i.why)\n"
                for effort in Effort.allCases {
                    let group = i.actions.filter { $0.effort == effort }
                    guard !group.isEmpty else { continue }
                    out += "\n**\(effort.word)**\n"
                    for a in group { out += "- [ ] \(a.text)\n" }
                }
                out += "\n_\(i.countedText)._\n"
            }
        }
        if !o.needsMorePhotos.isEmpty {
            out += "\n## Needs more photos\n"
            for i in o.needsMorePhotos {
                out += "- \(i.title) (\(i.grade.word) · \(Fmt.count(i.counted, "photo"))): \(i.finding)" + (i.whatWouldChange.map { " What would change this: \($0)" } ?? "") + "\n"
            }
        }
        if !o.setAside.isEmpty {
            out += "\n## Set aside by you\n"
            for c in o.setAside { out += "- \(SetAsideRow.line(c))\n" }
        }
        let mine = checks.filter { $0.camera == cam.model && $0.status != .dropped }
        if !mine.isEmpty {
            out += "\n## Checks\n"
            for c in mine {
                let r = CheckComparison.evaluate(c)
                out += "- \(c.kind.title.prefix(1).uppercased() + c.kind.title.dropFirst()), started \(Fmt.date(c.started)): \(r.sentence)\n"
            }
        }
        if !o.silent.isEmpty {
            out += "\n## Checks that had nothing to say\n"
            for s in o.silent { out += "- \(s.text)\n" }
        }
        return out + "\n---\n\(footer)\n"
    }

    /// The report card in one line per figure, with the same gates and counts as the tiles.
    static func reportCard(_ s: CameraSummary) -> [String] {
        let n = Fmt.count(s.photoCount, "photo")
        var lines: [String] = []
        lines.append("In-focus sharpness: " + (s.hasSharpnessFigure ? "\(s.sharpnessCell), from \(s.sharpnessCounted) of \(n) with 3 or more usable edges" : "\(CameraSummary.notEnoughText): \(s.sharpnessCounted) of \(n) had 3 or more usable edges"))
        lines.append("Noise: " + (s.hasSNRFigure ? "\(s.noiseCell), \(s.snrCounted) of \(n); compares processing, not sensors" : "\(CameraSummary.notEnoughText): \(s.snrCounted) clean readings"))
        if let m = s.clipHighMedian { lines.append("Blown highlights: \(Metric.highlightClip.format(m)) median; \(s.clipHighCount) of \(n) over 1 %") }
        lines.append("Sharpening halo: " + (s.hasOvershootFigure ? "\(s.haloCell), \(Fmt.count(s.overshootCounted, "photo"))" : "\(CameraSummary.notEnoughText): \(s.overshootCounted) with 3 or more usable edges"))
        if s.wbRStops != nil || s.wbBStops != nil {
            lines.append("Colour lean: \(s.leanCell), R/G \(Fmt.num(s.wbRStops ?? 0, 2)) and B/G \(Fmt.num(s.wbBStops ?? 0, 2)) stops, \(Fmt.count(s.wbCount, "photo")); gray-world")
        }
        if let d = s.dynamicRange {
            lines.append("Dynamic range: \(s.dynamicRangePrefix)\(Metric.dynamicRange.format(d)), \(s.drExactCount) reached the noise floor; \(s.drLowerBoundCount) are lower bounds")
        }
        return lines
    }

    // MARK: 2. Pocket card

    /// Five plain lines or fewer, for a note on the phone.
    static func pocketCard(for cam: CameraGroup, output o: CoachingOutput, date: Date = .now) -> String {
        var items: [String] = []
        if let one = o.oneThing {
            items.append(one.action.map { "\(one.sentence) \($0.text)" } ?? one.sentence)
            if let next = one.nextUp { items.append(next) }
        }
        if let editor = o.cards.first(where: { c in !c.actions.isEmpty && c.actions.allSatisfy { $0.effort == .inEditor } }),
           let a = editor.actions.first {
            items.append("In editing: \(a.text)")
        }
        var lines = ["\(cam.model) · \(Fmt.date(date))"]
        lines += items.prefix(3).enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines.append("From \(Fmt.count(cam.photos.count, "photo")).")
        return lines.joined(separator: "\n")
    }

    // MARK: 3. A photo's editing steps

    static func editingSteps(for p: PhotoRecord, advice a: PhotoAdvice, editor: Editor, library: PhotoLibrary? = nil) -> String {
        var out = "# \(p.file): editing steps in \(editor.rawValue)\n\n"
        if a.nothingToFix { out += "\(EditingRules.nothingToFixText)\n" }
        for (i, adv) in a.doFirst.enumerated() {
            out += "- [ ] \(i + 1). \(adv.title) (\(adv.grade.word)): \(adv.text(for: editor))\n"
        }
        if !a.also.isEmpty {
            out += "\nAlso:\n"
            for adv in a.also { out += "- [ ] \(adv.title) (\(adv.grade.word)): \(adv.text(for: editor))\n" }
        }
        if !a.checked.isEmpty { out += "\nChecked, nothing to do: " + a.checked.map(\.text).joined(separator: " · ") + "\n" }
        out += "\n---\nFrom \(library?.sourceName ?? "results") · \(p.camera)" + (p.date.map { " · shot \(Fmt.date($0))" } ?? "") + ". \(footer)\n"
        return out
    }
}
