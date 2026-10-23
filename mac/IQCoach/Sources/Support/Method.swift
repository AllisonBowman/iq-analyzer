import Foundation

/// The Glossary's Method tab. The measurement paragraphs are copied verbatim from results/report.md, section
/// "How to read these numbers" (iqa/report.py writes them); the evidence, effort and check rules are this app's own
/// (feedback-layers spec §4.2, §4.3, §5). Keep both in step when either changes.
enum Method {
    struct Section: Identifiable, Sendable {
        let title: String
        let paragraphs: [String]
        var id: String { title }
    }

    /// From results/report.md, "How to read these numbers".
    static let measurements: [(title: String, text: String)] = [
        ("MTF50", "MTF50 is the spatial frequency (cycles per pixel, along the edge normal) at which contrast falls to 50 %. Higher is sharper; 0.25-0.35 is very sharp (often sharpened), 0.10-0.15 is soft. Measured on natural slanted edges with the ISO 12233 e-SFR method: a real edge is never a perfect step, so every figure is a scene-dependent lower bound on the system MTF, consistent across images of similar subjects but not a chart-grade absolute. The 'sharpest images' ranking compares scenes as much as lenses."),
        ("In-focus sharpness (p80)", "In-focus sharpness (p80) assumes at least a fifth of the measured edges are in the plane of focus; on a shallow-depth-of-field frame with few in-focus edges it reports the background. Check edges_measured and mtf50_max_cpp. mtf50__ci_lo/hi_cpp are 95 % percentile-bootstrap intervals over the measured edges: how far the figure would move with a different handful of edges from the same frame. With few edges they are wide and reach the sample's extremes; they do not include the scene-dependent bias of natural edges."),
        ("Structure", "Structure columns describe the frame, not its quality: structure_focus_fraction is the share of a 4x6 grid holding at least half the frame's peak fine detail (small = a subject against a smooth or blurred field), structure_focus_cx/cy is where that detail sits (0-1), structure_thirds_distance its distance from the nearest rule-of-thirds point (0 on the point, 1 at the frame centre), the structure_orient_ shares say whether strong gradients run horizontally, vertically or diagonally, structure_horizon_tilt_deg is the tilt of the longest near-level edge when one exists (a horizon, a table, a shelf; positive = right end lower), and the flat/texture/edge shares say what the surface is made of. mtf50_infocus_cpp / mtf50_background_cpp appear when the measured edges split cleanly into a sharp and a soft group (a shallow-depth-of-field frame), with infocus_edge_share the sharp share; the p80 figure should then be read as the in-focus value."),
        ("Overshoot", "Overshoot is how far the edge profile overshoots its bright plateau, in % of the step: a direct measure of sharpening halo. MTF50P (relative to the MTF peak) is the sharpening-robust companion of MTF50."),
        ("SNR at mid-grey", "SNR at mid-grey is 20·log10(118 / noise std) on the 8-bit luminance of flat patches; 38+ dB is excellent, 32+ clean, below 25 dB visibly noisy (the same scale IQ Coach uses). 8-bit quantisation alone caps it at about 52 dB. The figure is output-referred: noise reduction and JPEG/HEIC compression lower it as much as the sensor does, so SNR-vs-ISO across formats is partly a chart of processing. noise_whiteness near 0.14 means white noise; 0.3+ means the noise has been smoothed by NR or compression, 0.4+ heavily (at very low noise, fine texture and compression raise it too). noise_spectral_peak is how far the strongest frequency in the averaged patch spectrum stands above its surroundings: about 1 for noise, above 6 (noise_periodic_suspect) the flat patches contain a repeating pattern (a screen's pixel grid, a weave, halftone) at noise_periodic_freq_cpp cycles per pixel, and the SNR is of the pattern, not the sensor."),
        ("Dynamic range", "Dynamic range is output-referred: the stops between near-white and the darkest level whose scene-linear SNR still exceeds the threshold. A JPEG's tone curve bounds it, and the floor can only be found in frames that contain near-black flat areas; 'lower bound' rows are excluded from the medians."),
        ("Clipping", "Clipping is the share of pixels at the top (any channel >= 254) or bottom (all channels <= 1) of the range, measured in the file's own encoding before any profile conversion. clip_gamut_pct is the extra share that saturates only after converting Display P3 or Adobe RGB to sRGB, counted on the same pixels (0 when the file needed no conversion): colour outside the sRGB gamut, not lost detail."),
        ("White balance", "White balance is the gray-world ratio of linear channel means (and in stops); it describes the scene's cast as rendered, which for sunsets and underwater work is intent, not error."),
    ]

    static let oneThingRules = [
        "The one thing is chosen from the coaching cards. A card can be the one thing only when it is Worth acting on or Important, its evidence is not Thin, it has an action at the camera or set up once, you have not set it aside, and the behaviour its action changes shows in at least \(Fmt.share(CoachingEngine.minPrevalence)) of the camera's photos. That last rule is why an ISO ceiling is never offered to a camera whose photos are almost all under it.",
        "Cards are ranked by severity, then evidence word, then a fixed rule order: highlights, shadows, ISO, level edges, lens choice, others. Highlights come before shadows as a design choice: bright areas draw the eye, while dark areas are often the look.",
        "Next up is the second card that qualifies. When none does, the line reads Also good to know, with the firmest (Solid) card about shooting. When no card qualifies at all, the card says no single change stands out, and why.",
        "A card you set aside comes back on its own when its evidence changes: the photo count grows by a quarter, or its severity or evidence word changes. Nothing is deleted.",
    ]

    static let checkRules = [
        "A check compares the share of your new photos with the share before, for blown highlights (more than 1 % of the frame), crushed shadows (more than 1 % pure black) or level edges (a degree or more off level, among photos with a long level edge). Sharpness, noise and dynamic range are not compared: they depend on the scene, the processing and the light too much for ten photos to say anything.",
        "The baseline is frozen when you start. New photos count when they come from the same camera, were taken after the start, and are not marked with the check's intent; photos without a date are counted separately and left out.",
        "Chance is allowed for with a 95 % range on the difference (Newcombe's method). It worked: the whole range is below zero and the drop is at least 10 points. A small drop: the whole range is below zero but the drop is under 10 points. Higher than before: the whole range is above zero. Not settled yet: the range includes zero. 10 points is a design choice so that small wobbles do not count.",
        "The first look comes at 10 new photos; at 10 only a large change can show, and more photos give a firmer answer. A lower share can also mean different scenes, so the check shows the photos.",
    ]

    static var sections: [Section] {
        [Section(title: "How the numbers are measured", paragraphs: measurements.map(\.text)),
         Section(title: "How sure: the evidence words", paragraphs: EvidenceGrade.allCases.reversed().map(\.definition)),
         Section(title: "Where a change is made", paragraphs: Effort.allCases.map(\.definition)),
         Section(title: "The one thing", paragraphs: oneThingRules),
         Section(title: "Checks: did a change work?", paragraphs: checkRules)]
    }

    /// The whole tab as plain text.
    static var text: String {
        sections.map { s in ([s.title] + s.paragraphs).joined(separator: "\n\n") }.joined(separator: "\n\n")
    }
}
