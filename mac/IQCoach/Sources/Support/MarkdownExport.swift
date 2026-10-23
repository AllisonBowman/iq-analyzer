import Foundation

/// Coaching for one camera as Markdown, for ShareLink.
enum MarkdownExport {
    static func coaching(for cam: CameraGroup, insights: [Insight]) -> String {
        var out = "# \(cam.model): coaching from IQ Coach\n\n"
        out += "\(Fmt.count(cam.photos.count, "photo")); each figure counts only the photos that pass its check.\n\n"
        out += "## Report card\n\n"
        let s = cam.summary
        let rows: [(String, String)] = [
            ("In-focus sharpness", s.sharpnessCell + ". " + s.sharpnessCaption),
            ("Noise", s.noiseCell + ". " + s.snrCaption),
            ("Blown highlights", (s.clipHighMedian.map(Metric.highlightClip.format) ?? "not measured") + (s.clipCaption.map { ". " + $0 } ?? "")),
            ("Sharpening halo", s.haloCell + ". " + s.overshootCaption),
            ("Colour lean", s.leanCell + ". " + s.leanCaption),
            ("Dynamic range", (s.dynamicRange.map { s.dynamicRangePrefix + Metric.dynamicRange.format($0) } ?? "not measured") + ". " + s.dynamicRangeCaption),
        ]
        for (k, v) in rows { out += "- \(k): \(v)\n" }
        out += "\n## Coaching\n\n"
        if insights.isEmpty { out += "Not enough photos for coaching (at least 5 needed).\n" }
        for i in insights {
            out += "### \(i.title)\n\n\(i.finding)\n\n**Why.** \(i.why)\n\n**Do this.**\n"
            for a in i.actions { out += "- \(a)\n" }
            out += "\n_\(i.countedText)._\n\n"
        }
        return out
    }
}
