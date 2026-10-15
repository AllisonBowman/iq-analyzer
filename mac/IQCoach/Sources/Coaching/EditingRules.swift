import Foundation

/// Per-photo editing advice. Every rule is a pure function of one photo.
enum EditingRules {
    static let nothingToFixText = "This photo is clean, sharp and well exposed; edit for taste."

    static func advice(for p: PhotoRecord) -> [EditingAdvice] {
        let found = [blownHighlights(p), crushedShadows(p), noisy(p), soft(p), halo(p), colourLean(p),
                     flatTones(p), exposure(p), moire(p), straighten(p), thirdsCrop(p), shallowDepth(p)].compactMap { $0 }
        if found.isEmpty {
            return [EditingAdvice(id: "clean:\(p.id)", metric: nil, finding: nothingToFixText,
                                  apple: "Nothing needed. Try Auto only if you want a quick look.",
                                  lightroom: "Nothing needed. Adjust Vibrance or a preset for style.",
                                  generic: "Nothing needed; edit for taste.", caution: nil)]
        }
        return found
    }

    static func isNothingToFix(_ list: [EditingAdvice]) -> Bool { list.count == 1 && list[0].id.hasPrefix("clean:") }

    private static let noDetailCaution = "On a JPEG or HEIC the pixels at 255 hold no detail; only a RAW file can recover one or two stops."

    static func blownHighlights(_ p: PhotoRecord) -> EditingAdvice? {
        guard let c = p.clipHighPct, c > 0.5 else { return nil }
        return EditingAdvice(
            id: "highlights:\(p.id)", metric: .highlightClip,
            finding: "\(Fmt.pct(c, 1)) of the picture is blown to pure white.",
            apple: "Adjust > Light: drag Highlights down, then add Brilliance to open the bright areas.",
            lightroom: "Highlights -40 to -80, then Whites down a little.",
            generic: "Lower highlights, then whites.",
            caution: p.isRaw == true ? "A RAW file can recover one or two stops of highlights, so push further if the preview allows." : noDetailCaution)
    }

    static func crushedShadows(_ p: PhotoRecord) -> EditingAdvice? {
        guard let c = p.clipLowPct, c > 0.5 else { return nil }
        return EditingAdvice(
            id: "shadows:\(p.id)", metric: .shadowClip,
            finding: "\(Fmt.pct(c, 1)) of the picture is crushed to pure black.",
            apple: "Adjust > Light: drag Shadows up and lower Black Point.",
            lightroom: "Shadows +30 to +60; Blacks +10 to +30.",
            generic: "Raise shadows, then lift the black point.",
            caution: "Lifting shadows raises noise; check the noise advice and the photo's SNR first.")
    }

    static func noisy(_ p: PhotoRecord) -> EditingAdvice? {
        guard let s = p.snrMidgreyDB, s < 30, p.noisePeriodicSuspect != true else { return nil }
        let smoothed = (p.noiseWhiteness ?? 0) >= 0.4
        return EditingAdvice(
            id: "noise:\(p.id)", metric: .snr,
            finding: "Noise is visible: signal to noise is \(Fmt.db(s)), under the 30 dB mark.",
            apple: "Adjust > Noise Reduction: start moderate (about 30-50).",
            lightroom: "Denoise (AI) 30-50, or Luminance noise reduction 20-40 with Detail 50.",
            generic: "Apply luminance noise reduction before any sharpening.",
            caution: smoothed ? "Already smoothed by the camera (noise whiteness \(Fmt.num(p.noiseWhiteness ?? 0, 2))); more noise reduction will smear texture." : nil)
    }

    static func soft(_ p: PhotoRecord) -> EditingAdvice? {
        guard let c = p.mtf50P80CPP, c < 0.18 else { return nil }
        let o = p.overshootMedianPct ?? 0
        if o >= 8 {
            return EditingAdvice(
                id: "soft:\(p.id)", metric: .sharpnessCPP,
                finding: "Sharpness is low (\(Fmt.cpp(c))) but edges already overshoot by \(Fmt.pct(o, 1)).",
                apple: "Already sharpened; do not add more. Leave Sharpen at 0.",
                lightroom: "Already sharpened; do not add more. Keep Sharpening low and Masking high.",
                generic: "Already sharpened; do not add more. Downsize for the web with care, using a soft resampler.",
                caution: "The softness is probably focus or motion blur; sharpening would only thicken the halos.")
        }
        return EditingAdvice(
            id: "soft:\(p.id)", metric: .sharpnessCPP,
            finding: "Sharpness is low (\(Fmt.cpp(c)), under 0.18) and the edges show little sharpening (\(Fmt.pct(o, 1)) overshoot).",
            apple: "Adjust > Sharpen: Sharpness 20-40, and Definition about 10.",
            lightroom: "Detail > Sharpening 40-60, Radius 1.0, Masking 40-70.",
            generic: "Sharpen on luminance only, and mask flat areas such as sky.",
            caution: nil)
    }

    static func halo(_ p: PhotoRecord) -> EditingAdvice? {
        guard let o = p.overshootMedianPct, o >= 12 else { return nil }
        return EditingAdvice(
            id: "halo:\(p.id)", metric: .overshoot,
            finding: "Edges overshoot by \(Fmt.pct(o, 1)): a visible sharpening halo.",
            apple: "Adjust > Sharpen: set Sharpness to 0.",
            lightroom: "Reduce Sharpening to 0-20 and set Clarity to 0.",
            generic: "Avoid any further sharpening.",
            caution: nil)
    }

    static func colourLean(_ p: PhotoRecord) -> EditingAdvice? {
        guard p.wbROverGStops != nil || p.wbBOverGStops != nil, let lean = p.wbLeanStops, lean > 0.15 else { return nil }
        let r = p.wbROverGStops ?? 0, b = p.wbBOverGStops ?? 0
        let d = CameraRules.leanDescription(r: r, b: b)
        var lr: [String] = []
        if d.words.contains("warm") { lr.append("Temp toward blue (negative)") }
        if d.words.contains("cool") { lr.append("Temp toward yellow (positive)") }
        if d.words.contains("magenta") { lr.append("Tint toward green (negative)") }
        if d.words.contains("green") { lr.append("Tint toward magenta (positive)") }
        return EditingAdvice(
            id: "lean:\(p.id)", metric: .whiteBalance,
            finding: "The picture leans \(d.words) by \(Fmt.stops(lean)).",
            apple: "Adjust > Color > Cast, or the White Balance picker on a neutral grey area.",
            lightroom: "White Balance: " + lr.joined(separator: ", ") + ", or use the eyedropper on a neutral.",
            generic: "Use the white-balance picker on something that should be neutral.",
            caution: "A sunset or stage lighting is intent: leave the lean if it is the mood you wanted.")
    }

    static func flatTones(_ p: PhotoRecord) -> EditingAdvice? {
        guard let t = p.tonalRangeStops, t < 7, (p.clipHighPct ?? 0) < 0.2, (p.clipLowPct ?? 0) < 0.2 else { return nil }
        return EditingAdvice(
            id: "flat:\(p.id)", metric: .tonalRange,
            finding: "Tones are flat: only \(Fmt.stops(t, 1)) between darkest and brightest, with room to spare at both ends.",
            apple: "Adjust > Light: Contrast up, and lower Black Point.",
            lightroom: "Contrast +15 to +30, or add a gentle tone curve.",
            generic: "Apply an S-curve.",
            caution: nil)
    }

    static func exposure(_ p: PhotoRecord) -> EditingAdvice? {
        guard let l = p.lumaP50 else { return nil }
        if l < 70 {
            return EditingAdvice(
                id: "dark:\(p.id)", metric: nil,
                finding: "The picture is dark: the middle tone sits at \(Fmt.int(l)) of 255.",
                apple: "Adjust > Light: Exposure +0.3 to +0.7.",
                lightroom: "Exposure +0.3 to +0.7.",
                generic: "Raise exposure by a third to two-thirds of a stop.",
                caution: "Brightening a dark photo lifts shadow noise; check the shadow and noise advice.")
        }
        if l > 190, (p.clipHighPct ?? 0) < 0.5, (p.clipLowPct ?? 0) < 0.5 {
            return EditingAdvice(
                id: "bright:\(p.id)", metric: nil,
                finding: "The picture is bright: the middle tone sits at \(Fmt.int(l)) of 255, with nothing clipped.",
                apple: "Adjust > Light: Exposure -0.3.",
                lightroom: "Exposure -0.3.",
                generic: "Lower exposure by a third of a stop.",
                caution: nil)
        }
        return nil
    }

    static func moire(_ p: PhotoRecord) -> EditingAdvice? {
        guard p.noisePeriodicSuspect == true else { return nil }
        return EditingAdvice(
            id: "moire:\(p.id)", metric: nil,
            finding: "A repeating pattern is present in flat areas (moire), so the noise figure reflects the pattern rather than the sensor.",
            apple: "Photos has no moire control; crop or re-shoot.",
            lightroom: "Use the Moire brush in the Adjustment brush panel.",
            generic: "Re-shoot at a different distance or angle.",
            caution: "Moire comes from fine regular detail (screens, fabric, brick) beating against the sensor grid.")
    }

    static func straighten(_ p: PhotoRecord) -> EditingAdvice? {
        guard let t = p.structureHorizonTiltDeg, abs(t) >= 1.0 else { return nil }
        let a = Fmt.num(abs(t), 1) + "°"
        let dir = t > 0 ? "counter-clockwise" : "clockwise"
        return EditingAdvice(
            id: "straighten:\(p.id)", metric: nil,
            finding: "Straighten by \(a): a long level edge is tilted \(a) (\(t > 0 ? "right" : "left") end lower).",
            apple: "Crop > Straighten dial: turn it \(dir) by \(a), or press Auto.",
            lightroom: "Transform > Auto, or the Straighten tool in the Crop panel, or the Angle slider set to \(Fmt.num(-t, 1))°.",
            generic: "Rotate by \(Fmt.num(-t, 1))° and crop in to remove the empty corners.",
            caution: "Straightening crops the corners, so leave room round the edges. A tilted line may be intended, such as a slope.")
    }

    static func thirdsCrop(_ p: PhotoRecord) -> EditingAdvice? {
        guard let d = p.structureThirdsDistance, d > 0.3, let f = p.structureFocusFraction, f < 0.4 else { return nil }
        return EditingAdvice(
            id: "thirds:\(p.id)", metric: nil,
            finding: "The subject sits \(Fmt.num(d, 2)) frame-diagonals from the nearest rule-of-thirds point, with detail concentrated in \(Fmt.share(f)) of the frame.",
            apple: "Crop, with the grid showing: drag the frame so the subject lands on a crossing of the grid lines.",
            lightroom: "Crop overlay: press O to cycle to the Rule of Thirds grid, then position the subject on a crossing.",
            generic: "Crop so the subject sits on a rule-of-thirds crossing.",
            caution: "Composition is taste: a centred or off-balance subject can be exactly the point.")
    }

    static func shallowDepth(_ p: PhotoRecord) -> EditingAdvice? {
        guard let sharp = p.mtf50InfocusCPP, let bg = p.mtf50BackgroundCPP, sharp > 0, bg < 0.5 * sharp else { return nil }
        return EditingAdvice(
            id: "shallow:\(p.id)", metric: nil,
            finding: "Shallow depth of field: the sharp group measures \(Fmt.cpp(sharp)) and the background \(Fmt.cpp(bg)). Sharpen only the subject.",
            apple: "Photos has no local tool: apply light sharpening only (Adjust > Sharpen, Intensity low).",
            lightroom: "Masking > Subject, then Sharpening + on that mask.",
            generic: "Mask the subject and sharpen only inside the mask.",
            caution: "Global sharpening will bring out noise in the blurred areas.")
    }
}
