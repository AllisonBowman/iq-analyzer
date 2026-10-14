import Foundation

/// Coaching for one camera as Markdown, for ShareLink.
enum MarkdownExport {
    static func coaching(for cam: CameraGroup, insights: [Insight]) -> String {
        var out = "# \(cam.model): coaching from IQ Coach\n\n"
        out += "Based on \(Fmt.count(cam.photos.count, "photo")).\n\n"
        out += "## Report card\n\n"
        let s = cam.summary
        let rows: [(String, String)] = [
            ("In-focus sharpness", s.sharpnessLWPH.map(Metric.sharpnessLWPH.format) ?? "not measured"),
            ("Noise", s.snr.map(Metric.snr.format) ?? "not measured"),
            ("Blown highlights", s.clipHighMedian.map(Metric.highlightClip.format) ?? "not measured"),
            ("Sharpening halo", s.overshoot.map(Metric.overshoot.format) ?? "not measured"),
            ("Colour lean", s.wbLean.map(Metric.whiteBalance.format) ?? "not measured"),
        ]
        for (k, v) in rows { out += "- \(k): \(v)\n" }
        out += "\n## Coaching\n\n"
        if insights.isEmpty { out += "Not enough photos for coaching (at least 5 needed).\n" }
        for i in insights {
            out += "### \(i.title)\n\n\(i.finding)\n\n**Why.** \(i.why)\n\n**Do this.**\n"
            for a in i.actions { out += "- \(a)\n" }
            out += "\n_Based on \(Fmt.count(i.basedOn, "photo"))._\n\n"
        }
        return out
    }
}
