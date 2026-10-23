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

    // One scale per quantity, used by the bands, the Glossary, the tiles, the charts and the coaching rules.
    /// SNR below this is visibly noisy (the Poor band).
    static let snrNoisyDB = 25.0
    /// SNR at or above this is clean: grain is hard to see at full size (the Good band starts here).
    static let snrCleanDB = 32.0
    /// SNR at or above this is excellent.
    static let snrExcellentDB = 38.0
    /// Overshoot under this is natural (an unsharpened edge reads about 0.5 to 1.5 %).
    static let overshootNaturalPct = 3.0
    /// Overshoot from here is hard sharpening (the Fair band).
    static let overshootHardPct = 8.0
    /// Overshoot from here is a visible halo (the Poor band).
    static let overshootHaloPct = 12.0
    /// Noise whiteness of white (unsmoothed) noise, from iqa/noise.py.
    static let whitenessWhite = 0.14
    /// Whiteness from here: the noise has been smoothed.
    static let whitenessSmoothed = 0.3
    /// Whiteness from here: heavily smoothed (iqa/noise.py "0.4+ = heavily correlated / NR'd").
    static let whitenessHeavy = 0.4
    /// Whiteness above this: the flat areas are texture, not noise (iqa/noise.py `noise_texture_suspect`).
    static let whitenessTexture = 0.7

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
        case .highlightClip: "Share of the picture at the top of the range in at least one colour channel, where that channel holds no detail."
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
            "MTF50 is the spatial frequency, in cycles per pixel along the edge normal, at which contrast falls to 50 %. Higher is sharper; 0.25-0.35 is very sharp (often sharpened), 0.10-0.15 is soft. It is measured on natural slanted edges with the ISO 12233 e-SFR method, so every figure is a scene-dependent lower bound on the system MTF: consistent across images of similar subjects, not a chart-grade absolute. In-focus sharpness (p80) is the 80th-percentile edge: it lands on in-focus edges only when they are clearly more than a fifth of the measured edges, so on a shallow-depth-of-field frame with few in-focus edges it can read the background (the photo's sharp-group figure is then the one to read). A photo's figure counts only when at least 3 edges were measured. LW/PH is line widths per picture height: two times the c/px figure times the picture height in pixels (one cycle is two line widths; the height is the short side, as in a landscape frame), so it cannot exceed that height; bands come from the per-pixel figure."
        case .snr:
            "SNR at mid-grey is 20 x log10(118 / noise std) on the 8-bit luminance of flat patches; 32 dB and up is clean (grain is hard to see at full size), 38 dB and up is excellent, below 25 dB is visibly noisy. Photos whose mid-grey was extrapolated, whose flat areas are texture, or that hold a repeating pattern are left out of camera medians. 8-bit quantisation alone caps it at about 52 dB. The figure is output-referred: noise reduction and JPEG/HEIC compression lower it as much as the sensor does, so SNR across ISO and formats is partly a chart of processing."
        case .highlightClip:
            "Clipping is the share of pixels at the top of the range (any channel at 254 or above), counted in the file's own encoding. Those pixels hold no detail in the clipped channel; few of them are pure white in all three."
        case .shadowClip:
            "Clipping is the share of pixels at the bottom of the range (all channels at 1 or below). Those pixels hold no detail."
        case .overshoot:
            "Overshoot is how far the edge profile overshoots its bright plateau, in % of the step: a direct measure of sharpening halo. Under 3 % is natural, 8 % and up is hard sharpening, 12 % and up is a visible halo. It counts only on photos with at least 3 measured edges."
        case .whiteBalance:
            "White balance is the gray-world ratio of linear channel means, expressed in stops. It describes the scene's cast as rendered, which for sunsets and underwater work is intent, not error. A photo's lean is the larger of |R/G| and |B/G|; a camera's lean is the larger of its median R/G and median B/G, its typical rendering, which is smaller than the typical photo's lean because each scene adds its own cast."
        case .whiteness:
            "Noise whiteness near 0.14 means white noise; 0.3 and up means the noise has been smoothed by noise reduction or compression, 0.4 and up heavily; above 0.7 the flat areas are texture rather than noise. At low noise, scene texture also raises it, so it reads high at base ISO even without noise reduction. This is informational: it says how the noise looks, not whether it is good."
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
        case .sharpnessLWPH: "No band of its own: LW/PH is capped by the picture height, so the band comes from the per-pixel figure. Use LW/PH to compare cameras."
        case .sharpnessCPP: "Excellent from 0.30 c/px; poor below 0.12."
        case .snr: "Clean from 32 dB; excellent from 38 dB; visibly noisy below 25 dB."
        case .highlightClip, .shadowClip: "Excellent below 0.1 %; poor from 2 %."
        case .overshoot: "Natural below 3 %; hard sharpening from 8 %; a visible halo from 12 %."
        case .whiteBalance: "Excellent below 0.1 stops; poor from 0.4 stops."
        case .whiteness: "0.14 is white grain; 0.3 and up smoothed; 0.4 and up heavily smoothed; above 0.7 texture, not noise."
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
        case .whiteness: 0.1...0.8
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
        // LW/PH is not banded: it is capped by the picture height, so the same lens reads lower on a smaller frame.
        // The per-pixel figure (LW/PH / height = 2 x c/px) carries the band for both.
        case .sharpnessLWPH: nil
        case .sharpnessCPP: Self.higherBand(value, 0.12, 0.20, 0.30)
        case .snr: Self.higherBand(value, Self.snrNoisyDB, Self.snrCleanDB, Self.snrExcellentDB)
        case .highlightClip, .shadowClip: Self.lowerBand(value, 0.1, 0.5, 2)
        case .overshoot: Self.lowerBand(value, Self.overshootNaturalPct, Self.overshootHardPct, Self.overshootHaloPct)
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
