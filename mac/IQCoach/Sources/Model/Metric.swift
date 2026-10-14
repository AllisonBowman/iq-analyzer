import SwiftUI

enum Band: Int, Comparable, Sendable, CaseIterable {
    case poor, fair, good, excellent

    static func < (a: Band, b: Band) -> Bool { a.rawValue < b.rawValue }

    /// Always shown next to the colour (colour is never the only signal).
    var word: String {
        switch self {
        case .poor: "Poor"
        case .fair: "Fair"
        case .good: "Good"
        case .excellent: "Excellent"
        }
    }

    var color: Color {
        switch self {
        case .poor: .red
        case .fair: .orange
        case .good: .yellow
        case .excellent: .green
        }
    }
}

enum GoodDirection: Sendable { case higher, lower, informational }

/// Every number the app shows, with its plain-language name, meaning, scale and bands.
enum Metric: String, CaseIterable, Identifiable, Sendable {
    case sharpnessLWPH, sharpnessCPP, snr, highlightClip, shadowClip, overshoot, whiteBalance, whiteness
    case dynamicRange, tonalRange, colorfulness

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sharpnessLWPH: "In-focus sharpness"
        case .sharpnessCPP: "In-focus sharpness (per pixel)"
        case .snr: "Noise (signal to noise)"
        case .highlightClip: "Blown highlights"
        case .shadowClip: "Crushed shadows"
        case .overshoot: "Sharpening halo"
        case .whiteBalance: "Colour lean"
        case .whiteness: "Noise smoothing"
        case .dynamicRange: "Dynamic range"
        case .tonalRange: "Tonal range"
        case .colorfulness: "Colourfulness"
        }
    }

    var shortMeaning: String {
        switch self {
        case .sharpnessLWPH: "How fine a detail the camera resolves where the picture is in focus."
        case .sharpnessCPP: "The same sharpness, counted per pixel so different resolutions compare fairly."
        case .snr: "How much the picture signal stands above the grain, in a flat mid-grey area."
        case .highlightClip: "Share of the picture that is pure white with no detail."
        case .shadowClip: "Share of the picture that is pure black with no detail."
        case .overshoot: "How strongly the camera or editor has sharpened edges, shown as a bright fringe."
        case .whiteBalance: "How far greys are rendered toward warm, cool, green or magenta."
        case .whiteness: "Whether the grain was left fine or smoothed by noise reduction."
        case .dynamicRange: "How many stops of brightness the picture holds before noise takes over."
        case .tonalRange: "How many stops separate the darkest and brightest areas of this picture."
        case .colorfulness: "How vivid the colours are overall."
        }
    }

    /// The project's glossary wording (results/report.md, "How to read these numbers").
    var definition: String {
        switch self {
        case .sharpnessLWPH, .sharpnessCPP:
            "MTF50 is the spatial frequency, in cycles per pixel along the edge normal, at which contrast falls to 50 %. Higher is sharper; 0.25-0.35 is very sharp (often sharpened), 0.10-0.15 is soft. It is measured on natural slanted edges with the ISO 12233 e-SFR method, so every figure is a scene-dependent lower bound on the system MTF: consistent across images of similar subjects, not a chart-grade absolute. In-focus sharpness (p80) assumes at least a fifth of the measured edges are in the plane of focus; on a shallow-depth-of-field frame with few in-focus edges it reports the background. LW/PH is line widths per picture height: the c/px figure times the picture height in pixels."
        case .snr:
            "SNR at mid-grey is 20 x log10(118 / noise std) on the 8-bit luminance of flat patches; 35+ dB is clean, below 25 dB is visibly noisy. 8-bit quantisation alone caps it at about 52 dB. The figure is output-referred: noise reduction and JPEG/HEIC compression lower it as much as the sensor does, so SNR across ISO and formats is partly a chart of processing."
        case .highlightClip:
            "Clipping is the share of pixels at the top of the range (any channel at 254 or above). Those pixels hold no detail."
        case .shadowClip:
            "Clipping is the share of pixels at the bottom of the range (all channels at 1 or below). Those pixels hold no detail."
        case .overshoot:
            "Overshoot is how far the edge profile overshoots its bright plateau, in % of the step: a direct measure of sharpening halo."
        case .whiteBalance:
            "White balance is the gray-world ratio of linear channel means, expressed in stops. It describes the scene's cast as rendered, which for sunsets and underwater work is intent, not error."
        case .whiteness:
            "Noise whiteness near 0.14 means white noise; 0.3+ means the noise has been smoothed by noise reduction or compression. This is informational: it says how the noise looks, not whether it is good."
        case .dynamicRange:
            "Dynamic range is output-referred: the stops between near-white and the darkest level whose scene-linear SNR still exceeds the threshold. A JPEG's tone curve bounds it, and the floor can only be found in frames that contain near-black flat areas; lower-bound rows are excluded from the medians and shown as 'at least'."
        case .tonalRange:
            "The stops between the darkest and brightest areas actually present in this picture (about 1st to 99th percentile). A low number means a flat, low-contrast scene or edit."
        case .colorfulness:
            "A single score for how vivid the colours are. Higher is more saturated; it is informational."
        }
    }

    var goodLooksLike: String {
        switch self {
        case .sharpnessLWPH: "Excellent from 3500 LW/PH; poor below 1500."
        case .sharpnessCPP: "Excellent from 0.30 c/px; poor below 0.12."
        case .snr: "Clean from 38 dB; visibly noisy below 25 dB."
        case .highlightClip, .shadowClip: "Excellent below 0.1 %; poor from 2 %."
        case .overshoot: "Excellent below 3 %; poor from 15 %."
        case .whiteBalance: "Excellent below 0.1 stops; poor from 0.4 stops."
        case .whiteness: "0.14 is white grain; 0.5 and above is heavily smoothed."
        case .dynamicRange: "More stops is better; there is no pass mark."
        case .tonalRange: "7 stops or more reads as full-bodied; under 7 looks flat."
        case .colorfulness: "No pass mark; it describes the scene."
        }
    }

    var unit: String {
        switch self {
        case .sharpnessLWPH: "LW/PH"
        case .sharpnessCPP: "c/px"
        case .snr: "dB"
        case .highlightClip, .shadowClip, .overshoot: "%"
        case .whiteBalance, .dynamicRange, .tonalRange: "stops"
        case .whiteness, .colorfulness: ""
        }
    }

    /// The range drawn by the scale bar: poor on one end, excellent on the other.
    var scale: ClosedRange<Double> {
        switch self {
        case .sharpnessLWPH: 0...4500
        case .sharpnessCPP: 0...0.4
        case .snr: 15...45
        case .highlightClip, .shadowClip: 0...4
        case .overshoot: 0...25
        case .whiteBalance: 0...0.6
        case .whiteness: 0.1...0.6
        case .dynamicRange: 0...12
        case .tonalRange: 0...12
        case .colorfulness: 0...60
        }
    }

    var goodDirection: GoodDirection {
        switch self {
        case .sharpnessLWPH, .sharpnessCPP, .snr: .higher
        case .highlightClip, .shadowClip, .overshoot, .whiteBalance: .lower
        case .whiteness, .dynamicRange, .tonalRange, .colorfulness: .informational
        }
    }

    /// Band thresholds from the spec. Informational metrics have no band.
    func band(for value: Double) -> Band? {
        switch self {
        case .sharpnessLWPH: Self.higherBand(value, 1500, 2500, 3500)
        case .sharpnessCPP: Self.higherBand(value, 0.12, 0.20, 0.30)
        case .snr: Self.higherBand(value, 25, 32, 38)
        case .highlightClip, .shadowClip: Self.lowerBand(value, 0.1, 0.5, 2)
        case .overshoot: Self.lowerBand(value, 3, 8, 15)
        case .whiteBalance: Self.lowerBand(value, 0.1, 0.2, 0.4)
        case .whiteness, .dynamicRange, .tonalRange, .colorfulness: nil
        }
    }

    private static func higherBand(_ v: Double, _ fair: Double, _ good: Double, _ excellent: Double) -> Band {
        v < fair ? .poor : v < good ? .fair : v < excellent ? .good : .excellent
    }

    private static func lowerBand(_ v: Double, _ excellent: Double, _ good: Double, _ fair: Double) -> Band {
        v < excellent ? .excellent : v < good ? .good : v < fair ? .fair : .poor
    }

    /// Position 0...1 along the scale where 0 is the poor end and 1 the excellent end.
    func scalePosition(for value: Double) -> Double {
        let r = scale
        let t = min(max((value - r.lowerBound) / (r.upperBound - r.lowerBound), 0), 1)
        return goodDirection == .lower ? 1 - t : t
    }

    func format(_ v: Double) -> String {
        switch self {
        case .sharpnessLWPH: v.formatted(.number.precision(.fractionLength(0))) + " LW/PH"
        case .sharpnessCPP: v.formatted(.number.precision(.fractionLength(2))) + " c/px"
        case .snr: v.formatted(.number.precision(.fractionLength(1))) + " dB"
        case .highlightClip, .shadowClip: v.formatted(.number.precision(.fractionLength(v < 10 ? 2 : 1))) + " %"
        case .overshoot: v.formatted(.number.precision(.fractionLength(1))) + " %"
        case .whiteBalance, .dynamicRange, .tonalRange: v.formatted(.number.precision(.fractionLength(1))) + " stops"
        case .whiteness: v.formatted(.number.precision(.fractionLength(2)))
        case .colorfulness: v.formatted(.number.precision(.fractionLength(0)))
        }
    }

    /// Value of this metric for one photo.
    func value(of p: PhotoRecord) -> Double? {
        switch self {
        case .sharpnessLWPH: p.mtf50P80LWPH
        case .sharpnessCPP: p.mtf50P80CPP
        case .snr: p.snrMidgreyDB
        case .highlightClip: p.clipHighPct
        case .shadowClip: p.clipLowPct
        case .overshoot: p.overshootMedianPct
        case .whiteBalance: p.wbLeanStops
        case .whiteness: p.noiseWhiteness
        case .dynamicRange: p.drSNR4Stops
        case .tonalRange: p.tonalRangeStops
        case .colorfulness: p.colorfulness
        }
    }
}
