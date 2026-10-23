import Foundation

/// One analysed photograph: a row of `results.json`. Every measurement is optional because the
/// analyzer writes NaN (decoded to nil here) whenever it could not measure something.
struct PhotoRecord: Codable, Identifiable, Sendable, Hashable {
    var file: String
    var path: String? = nil
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    var lens: String? = nil
    var iso: Double? = nil
    var exposureS: Double? = nil
    var fNumber: Double? = nil
    var focalMM: Double? = nil
    var width: Int? = nil
    var height: Int? = nil
    var format: String? = nil
    var isRaw: Bool? = nil
    var colorProfile: String? = nil
    var edgesMeasured: Int? = nil
    var edgesCenter: Int? = nil
    var edgesOuter: Int? = nil
    /// Candidate edges the finder offered before the quality gates (iqa/edges.py).
    var edgesCandidates: Int? = nil
    /// Why candidates were rejected, as the analyzer writes it: "plateau_noise=2;shading=1".
    var edgesRejectReasons: String? = nil
    var mtf50MedianCPP: Double? = nil
    var mtf50MedianCILo: Double? = nil
    var mtf50MedianCIHi: Double? = nil
    var mtf50P80CPP: Double? = nil
    var mtf50P80LWPH: Double? = nil
    var mtf50P80CILo: Double? = nil
    var mtf50P80CIHi: Double? = nil
    var mtf50CenterMedianCPP: Double? = nil
    var mtf50OuterMedianCPP: Double? = nil
    var mtf50pMedianCPP: Double? = nil
    var overshootMedianPct: Double? = nil
    var snrMidgreyDB: Double? = nil
    var snrMidgreyExtrapolated: Bool? = nil
    var noiseWhiteness: Double? = nil
    var noiseTextureSuspect: Bool? = nil
    var noisePeriodicSuspect: Bool? = nil
    var noiseSpectralPeak: Double? = nil
    var drSNR4Stops: Double? = nil
    var drSNR4LowerBound: Bool? = nil
    var clipHighPct: Double? = nil
    var clipLowPct: Double? = nil
    var clipGamutPct: Double? = nil
    var lumaP50: Double? = nil
    var tonalRangeStops: Double? = nil
    var wbROverGStops: Double? = nil
    var wbBOverGStops: Double? = nil
    var colorfulness: Double? = nil
    var datetime: String? = nil
    // Structure analysis (iqa 0.2 and later); all nil in older results files.
    var structureFocusFraction: Double? = nil
    var structureFocusCX: Double? = nil
    var structureFocusCY: Double? = nil
    var structureThirdsDistance: Double? = nil
    var structureOrientHorizontal: Double? = nil
    var structureOrientVertical: Double? = nil
    var structureOrientDiagonal: Double? = nil
    var structureHorizonTiltDeg: Double? = nil
    var structureFlatShare: Double? = nil
    var structureTextureShare: Double? = nil
    var structureEdgeShare: Double? = nil
    var structureFocusMap: [[Double]]? = nil
    var mtf50InfocusCPP: Double? = nil
    var mtf50BackgroundCPP: Double? = nil
    var infocusEdgeShare: Double? = nil

    enum CodingKeys: String, CodingKey {
        case file, path, lens, iso, width, height, format, datetime, colorfulness
        case cameraMake = "camera_make"
        case cameraModel = "camera_model"
        case exposureS = "exposure_s"
        case fNumber = "f_number"
        case focalMM = "focal_mm"
        case isRaw = "is_raw"
        case colorProfile = "color_profile"
        case edgesMeasured = "edges_measured"
        case edgesCenter = "edges_center"
        case edgesOuter = "edges_outer"
        case edgesCandidates = "edges_candidates"
        case edgesRejectReasons = "edges_reject_reasons"
        case mtf50MedianCPP = "mtf50_median_cpp"
        case mtf50MedianCILo = "mtf50_median_ci_lo_cpp"
        case mtf50MedianCIHi = "mtf50_median_ci_hi_cpp"
        case mtf50P80CPP = "mtf50_p80_cpp"
        case mtf50P80LWPH = "mtf50_p80_lwph"
        case mtf50P80CILo = "mtf50_p80_ci_lo_cpp"
        case mtf50P80CIHi = "mtf50_p80_ci_hi_cpp"
        case mtf50CenterMedianCPP = "mtf50_center_median_cpp"
        case mtf50OuterMedianCPP = "mtf50_outer_median_cpp"
        case mtf50pMedianCPP = "mtf50p_median_cpp"
        case overshootMedianPct = "overshoot_median_pct"
        case snrMidgreyDB = "snr_midgrey_db"
        case snrMidgreyExtrapolated = "snr_midgrey_extrapolated"
        case noiseWhiteness = "noise_whiteness"
        case noiseTextureSuspect = "noise_texture_suspect"
        case noisePeriodicSuspect = "noise_periodic_suspect"
        case noiseSpectralPeak = "noise_spectral_peak"
        case drSNR4Stops = "dr_snr4_stops"
        case drSNR4LowerBound = "dr_snr4_lower_bound"
        case clipHighPct = "clip_high_pct"
        case clipLowPct = "clip_low_pct"
        case clipGamutPct = "clip_gamut_pct"
        case lumaP50 = "luma_p50"
        case tonalRangeStops = "tonal_range_stops"
        case wbROverGStops = "wb_r_over_g_stops"
        case wbBOverGStops = "wb_b_over_g_stops"
        case structureFocusFraction = "structure_focus_fraction"
        case structureFocusCX = "structure_focus_cx"
        case structureFocusCY = "structure_focus_cy"
        case structureThirdsDistance = "structure_thirds_distance"
        case structureOrientHorizontal = "structure_orient_horizontal"
        case structureOrientVertical = "structure_orient_vertical"
        case structureOrientDiagonal = "structure_orient_diagonal"
        case structureHorizonTiltDeg = "structure_horizon_tilt_deg"
        case structureFlatShare = "structure_flat_share"
        case structureTextureShare = "structure_texture_share"
        case structureEdgeShare = "structure_edge_share"
        case structureFocusMap = "structure_focus_map"
        case mtf50InfocusCPP = "mtf50_infocus_cpp"
        case mtf50BackgroundCPP = "mtf50_background_cpp"
        case infocusEdgeShare = "infocus_edge_share"
    }

    var id: String { path ?? file }
}

extension PhotoRecord {
    /// Decodes leniently: a missing key, `null` and `NaN` all become nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func num(_ k: CodingKeys) -> Double? {
            guard let v = try? c.decodeIfPresent(Double.self, forKey: k), v.isFinite else { return nil }
            return v
        }
        func int(_ k: CodingKeys) -> Int? {
            if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return v }
            return num(k).map { Int($0) }
        }
        func str(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func bool(_ k: CodingKeys) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil }
        self.init(
            file: try c.decode(String.self, forKey: .file),
            path: str(.path), cameraMake: str(.cameraMake), cameraModel: str(.cameraModel), lens: str(.lens),
            iso: num(.iso), exposureS: num(.exposureS), fNumber: num(.fNumber), focalMM: num(.focalMM),
            width: int(.width), height: int(.height), format: str(.format), isRaw: bool(.isRaw),
            colorProfile: str(.colorProfile), edgesMeasured: int(.edgesMeasured),
            mtf50MedianCPP: num(.mtf50MedianCPP), mtf50MedianCILo: num(.mtf50MedianCILo),
            mtf50MedianCIHi: num(.mtf50MedianCIHi), mtf50P80CPP: num(.mtf50P80CPP),
            mtf50P80LWPH: num(.mtf50P80LWPH), mtf50CenterMedianCPP: num(.mtf50CenterMedianCPP),
            mtf50OuterMedianCPP: num(.mtf50OuterMedianCPP), mtf50pMedianCPP: num(.mtf50pMedianCPP),
            overshootMedianPct: num(.overshootMedianPct), snrMidgreyDB: num(.snrMidgreyDB),
            snrMidgreyExtrapolated: bool(.snrMidgreyExtrapolated), noiseWhiteness: num(.noiseWhiteness),
            noiseTextureSuspect: bool(.noiseTextureSuspect), noisePeriodicSuspect: bool(.noisePeriodicSuspect),
            noiseSpectralPeak: num(.noiseSpectralPeak), drSNR4Stops: num(.drSNR4Stops),
            drSNR4LowerBound: bool(.drSNR4LowerBound), clipHighPct: num(.clipHighPct), clipLowPct: num(.clipLowPct),
            lumaP50: num(.lumaP50), tonalRangeStops: num(.tonalRangeStops),
            wbROverGStops: num(.wbROverGStops), wbBOverGStops: num(.wbBOverGStops),
            colorfulness: num(.colorfulness), datetime: str(.datetime))
        structureFocusFraction = num(.structureFocusFraction)
        structureFocusCX = num(.structureFocusCX)
        structureFocusCY = num(.structureFocusCY)
        structureThirdsDistance = num(.structureThirdsDistance)
        structureOrientHorizontal = num(.structureOrientHorizontal)
        structureOrientVertical = num(.structureOrientVertical)
        structureOrientDiagonal = num(.structureOrientDiagonal)
        structureHorizonTiltDeg = num(.structureHorizonTiltDeg)
        structureFlatShare = num(.structureFlatShare)
        structureTextureShare = num(.structureTextureShare)
        structureEdgeShare = num(.structureEdgeShare)
        if let m = (try? c.decodeIfPresent([[Double]].self, forKey: .structureFocusMap)) ?? nil,
           !m.isEmpty, m.allSatisfy({ !$0.isEmpty }) {
            structureFocusMap = m.map { $0.map { $0.isFinite ? min(max($0, 0), 1) : 0 } }
        }
        mtf50InfocusCPP = num(.mtf50InfocusCPP)
        mtf50BackgroundCPP = num(.mtf50BackgroundCPP)
        infocusEdgeShare = num(.infocusEdgeShare)
        edgesCenter = int(.edgesCenter)
        edgesOuter = int(.edgesOuter)
        mtf50P80CILo = num(.mtf50P80CILo)
        mtf50P80CIHi = num(.mtf50P80CIHi)
        clipGamutPct = num(.clipGamutPct)
        edgesCandidates = int(.edgesCandidates)
        edgesRejectReasons = str(.edgesRejectReasons)
    }
}

extension PhotoRecord {
    static let unknownCamera = "Unknown camera"
    static let unknownLens = "(lens not recorded)"

    var camera: String { cameraModel ?? Self.unknownCamera }
    var lensName: String { lens ?? Self.unknownLens }

    /// EXIF "2025:01:19 11:40:16", interpreted in the current time zone.
    var date: Date? {
        guard let datetime else { return nil }
        return Self.exifFormatter.date(from: datetime)
    }

    /// True when the SNR figure is a trustworthy sensor/processing measurement. Mirrors iqa/report.py `_noise_ok`:
    /// extrapolated, texture-suspect and periodic-suspect rows are left out.
    var snrIsClean: Bool {
        snrMidgreyDB != nil && snrMidgreyExtrapolated != true && noisePeriodicSuspect != true && noiseTextureSuspect != true
    }

    /// Why this row's SNR is left out of the medians, or nil when it counts (or was not measured).
    var snrExclusionReason: String? {
        guard snrMidgreyDB != nil else { return nil }
        if snrMidgreyExtrapolated == true { return "measured at a different grey level and extrapolated to mid-grey" }
        if noiseTextureSuspect == true { return "the flat areas are texture or heavy smoothing, not sensor noise" }
        if noisePeriodicSuspect == true { return "a repeating pattern was found in the flat areas" }
        return nil
    }

    /// Fewest valid edges a photo needs before its sharpness, halo and centre/outer figures count (iqa/report.py `_sharp_ok`).
    static let minEdgesForSharpness = 3

    /// True when the photo has a sharpness figure the analyzer itself would use: at least three valid edges.
    var hasSharpnessFigure: Bool { (edgesMeasured ?? 0) >= Self.minEdgesForSharpness }

    /// p80 sharpness in LW/PH, only when the photo has enough edges for it to count.
    var gatedSharpnessLWPH: Double? { hasSharpnessFigure ? mtf50P80LWPH : nil }
    /// p80 sharpness in c/px, gated the same way.
    var gatedSharpnessCPP: Double? { hasSharpnessFigure ? mtf50P80CPP : nil }
    /// Edge overshoot (sharpening halo), gated the same way.
    var gatedOvershoot: Double? { hasSharpnessFigure ? overshootMedianPct : nil }

    /// Outer-to-centre sharpness ratio, only when both regions have at least three valid edges.
    var gatedOuterCentreRatio: Double? {
        guard (edgesCenter ?? 0) >= Self.minEdgesForSharpness, (edgesOuter ?? 0) >= Self.minEdgesForSharpness,
              let c = mtf50CenterMedianCPP, let o = mtf50OuterMedianCPP, c > 0 else { return nil }
        return o / c
    }

    /// The p80 sharpness range (95 % interval) in LW/PH: 2 x c/px x the short side, as the analyzer computes
    /// `mtf50_p80_lwph` (picture height in landscape orientation).
    var p80RangeLWPH: ClosedRange<Double>? {
        guard let lo = mtf50P80CILo, let hi = mtf50P80CIHi, let w = width, let h = height, lo <= hi else { return nil }
        let side = Double(min(w, h))
        return (2 * lo * side)...(2 * hi * side)
    }

    /// Width of the p80 interval relative to the p80 figure itself.
    var p80RelativeWidth: Double? {
        guard let lo = mtf50P80CILo, let hi = mtf50P80CIHi, let m = mtf50P80CPP, m > 0 else { return nil }
        return (hi - lo) / m
    }

    /// The colour lean of one photo: the larger of |R/G| and |B/G| in stops.
    var wbLeanStops: Double? {
        guard wbROverGStops != nil || wbBOverGStops != nil else { return nil }
        return max(abs(wbROverGStops ?? 0), abs(wbBOverGStops ?? 0))
    }

    /// True when this row carries any structure-analysis field.
    var hasStructure: Bool { structureFocusFraction != nil || structureFocusMap != nil || structureHorizonTiltDeg != nil }

    /// True when the measured edges split cleanly into a sharp group and a soft background group.
    var hasFocusSplit: Bool { mtf50InfocusCPP != nil && mtf50BackgroundCPP != nil }

    var isFront: Bool { (lens ?? "").lowercased().contains("front") }

    /// The key preferences use for this photo (intent tags, checks).
    var key: PhotoKey { PhotoKey(camera: camera, file: file, datetime: datetime) }

    /// The analyzer's edge rejections in plain words, most frequent first; unknown keys are kept with their raw name.
    var rejectReasons: [(reason: EdgeRejectReason, count: Int)] {
        guard let s = edgesRejectReasons, !s.isEmpty else { return [] }
        var out: [(reason: EdgeRejectReason, count: Int)] = []
        for part in s.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let k = kv.first, !k.isEmpty else { continue }
            let n = kv.count > 1 ? Int(kv[1]) ?? 0 : 0
            guard n > 0 else { continue }
            out.append((EdgeRejectReason(key: k), n))
        }
        return out.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// Decoder that accepts the bare `NaN` token Python writes.
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return d
    }

    static func decodeAll(from data: Data) throws -> [PhotoRecord] {
        try makeDecoder().decode([PhotoRecord].self, from: data)
    }
}

/// "<camera_model>|<file>|<datetime>": survives --no-paths; the datetime separates repeated DSLR names such as DSC_0001.
struct PhotoKey: Codable, Hashable, Sendable, RawRepresentable, Comparable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(camera: String, file: String, datetime: String?) { rawValue = "\(camera)|\(file)|\(datetime ?? "")" }
    static func < (a: PhotoKey, b: PhotoKey) -> Bool { a.rawValue < b.rawValue }
}

/// Why the analyzer rejected a candidate edge, in plain words (keys from iqa/edges.py).
enum EdgeRejectReason: Hashable, Sendable {
    case plateauNoise, clipped, contrastGT1, stepTooSmall, shading, fitResidual, noMTF50BelowNyquist
    case slant, riseWidth, notAStep, error
    case other(String)

    init(key: String) {
        switch key {
        case "plateau_noise": self = .plateauNoise
        case "clipped": self = .clipped
        case "contrast_gt_1": self = .contrastGT1
        case "step_too_small": self = .stepTooSmall
        case "shading": self = .shading
        case "fit_residual": self = .fitResidual
        case "no_mtf50_below_nyquist": self = .noMTF50BelowNyquist
        case "slant": self = .slant
        case "rise_width": self = .riseWidth
        case "not_a_step": self = .notAStep
        case "error": self = .error
        default: self = .other(key)
        }
    }

    var words: String {
        switch self {
        case .plateauNoise: "too noisy on either side"
        case .clipped: "touched pure white or black"
        case .contrastGT1: "an invalid contrast reading"
        case .stepTooSmall: "too little contrast"
        case .shading: "uneven light across the edge"
        case .fitResidual: "not straight enough"
        case .noMTF50BelowNyquist: "could not be read within the pixel grid"
        case .slant: "at the wrong angle (the method needs 1 to 16°)"
        case .riseWidth: "blurred over too many pixels"
        case .notAStep: "a thin line or double edge, not a step"
        case .error: "the measurement could not be computed"
        case .other(let raw): raw
        }
    }
}
