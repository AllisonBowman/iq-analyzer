import Foundation

/// Plain-language readings of the analyzer's structure fields. Pure functions of one photo.
enum Structure {
    static let thirdsPointDistance = 0.35

    static let missingText = "Structure analysis needs a results file from iqa 0.2 or later; re-run Analyze."

    static let focusFractionDefinition = "The share of a 4 by 6 grid over the frame whose cells hold at least half of the frame's peak fine detail. A small value means a subject against a smooth or blurred field; a value near 1 means the frame is sharp everywhere."
    static let focusPositionDefinition = "Where that fine detail sits, measured from the top-left corner of the frame (0 to 1 across and down). The map above shades each cell by how much fine detail it holds."
    static let thirdsDefinition = "Distance from the spot where the detail sits to the nearest rule-of-thirds point: 0 on the point, 1 at the frame centre, at most about 1.4 (all the detail in a corner cell of the grid). Under 0.35 counts as on a thirds point; above 0.75 the subject is centred or near an edge."
    static let orientationDefinition = "How much of the strong edge energy runs horizontally, vertically or diagonally. It describes the lines in the scene (horizons and walls are horizontal or vertical), not quality."
    static let horizonDefinition = "Level-edge tilt: the length-weighted median tilt of the long nearly level edges in the picture (each at least 40 % of the frame width and within 10 degrees of level), in degrees. Such an edge is sometimes a horizon, but often a table top, a shelf or a window frame seen in perspective. Positive means the right end is lower. Under 0.5 degrees is excellent, under 1 good, under 2 fair, otherwise poor. Straighten only when that edge should be level."
    static let surfaceDefinition = "What the picture surface is made of: flat areas (sky, walls), fine texture (foliage, fabric) and strong edges. The three shares add up to 100 %."
    static let splitDefinition = "When the measured edges split cleanly into a sharp group and a soft group (a shallow depth-of-field frame), this is the sharpness of each group in cycles per pixel and the share of edges in the sharp group. The median over all edges then blends subject and background."

    // MARK: Focus map

    /// "Detail is concentrated in the top-right (12 % of the frame), on a rule-of-thirds point", or the sharp-everywhere sentence.
    static func focusCaption(_ p: PhotoRecord) -> String? {
        guard let f = p.structureFocusFraction else { return nil }
        if f >= 0.8 {
            return "The frame is sharp almost everywhere (focus fraction \(Fmt.num(f, 1)))."
        }
        var s = "Detail is concentrated"
        if let cx = p.structureFocusCX, let cy = p.structureFocusCY {
            s += " in " + region(cx: cx, cy: cy)
        }
        s += " (\(Fmt.share(f)) of the frame)"
        if let t = p.structureThirdsDistance {
            s += t < thirdsPointDistance ? ", on a rule-of-thirds point" : ", away from the rule-of-thirds points"
        }
        return s + "."
    }

    static func region(cx: Double, cy: Double) -> String {
        let h = cx < 1.0 / 3 ? "left" : cx > 2.0 / 3 ? "right" : "centre"
        let v = cy < 1.0 / 3 ? "top" : cy > 2.0 / 3 ? "bottom" : "middle"
        if h == "centre" && v == "middle" { return "the centre" }
        if h == "centre" { return "the \(v) centre" }
        if v == "middle" { return "the \(h) side" }
        return "the \(v)-\(h)"
    }

    // MARK: Orientation

    static func orientation(_ p: PhotoRecord) -> String? {
        guard let h = p.structureOrientHorizontal, let v = p.structureOrientVertical, let d = p.structureOrientDiagonal else { return nil }
        let best = [("horizontal", h), ("vertical", v), ("diagonal", d)].max { $0.1 < $1.1 }!
        if best.1 < 0.4 { return "mixed structure (horizontal \(Fmt.share(h)), vertical \(Fmt.share(v)), diagonal \(Fmt.share(d)))" }
        return "mostly \(best.0) structure \(Fmt.share(best.1))"
    }

    // MARK: Level edge

    static func horizonBand(_ tilt: Double) -> Band {
        let a = abs(tilt)
        return a < 0.5 ? .excellent : a < 1 ? .good : a < 2 ? .fair : .poor
    }

    static func horizonText(_ p: PhotoRecord) -> String {
        guard let t = p.structureHorizonTiltDeg else { return "no level edge found" }
        let side = abs(t) < 0.05 ? "" : (t > 0 ? ", right end lower" : ", left end lower")
        return "\(Fmt.num(abs(t), 1))° off level\(side)"
    }

    // MARK: Surface and split

    static func surfaceText(_ p: PhotoRecord) -> String? {
        guard let f = p.structureFlatShare, let t = p.structureTextureShare, let e = p.structureEdgeShare else { return nil }
        return "flat \(Fmt.share(f)) · texture \(Fmt.share(t)) · edges \(Fmt.share(e))"
    }

    static func splitText(_ p: PhotoRecord) -> String? {
        guard let sharp = p.mtf50InfocusCPP, let bg = p.mtf50BackgroundCPP else { return nil }
        var s = "sharp group \(Fmt.cpp(sharp))"
        if let share = p.infocusEdgeShare { s += " on \(Fmt.share(share)) of edges" }
        return s + "; background \(Fmt.cpp(bg))"
    }
}
