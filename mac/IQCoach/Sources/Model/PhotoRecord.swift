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
    var mtf50MedianCPP: Double? = nil
    var mtf50MedianCILo: Double? = nil
    var mtf50MedianCIHi: Double? = nil
    var mtf50P80CPP: Double? = nil
    var mtf50P80LWPH: Double? = nil
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
        case mtf50MedianCPP = "mtf50_median_cpp"
        case mtf50MedianCILo = "mtf50_median_ci_lo_cpp"
        case mtf50MedianCIHi = "mtf50_median_ci_hi_cpp"
        case mtf50P80CPP = "mtf50_p80_cpp"
        case mtf50P80LWPH = "mtf50_p80_lwph"
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

    /// True when the SNR figure is a trustworthy sensor/processing measurement.
    var snrIsClean: Bool {
        snrMidgreyDB != nil && snrMidgreyExtrapolated != true && noisePeriodicSuspect != true && noiseTextureSuspect != true
    }

    /// Relative width of the sharpness confidence interval (hi - lo) / median.
    var relativeCIWidth: Double? {
        guard let lo = mtf50MedianCILo, let hi = mtf50MedianCIHi, let m = mtf50MedianCPP, m > 0 else { return nil }
        return (hi - lo) / m
    }

    /// Larger of |R/G| and |B/G| in stops.
    var wbLeanStops: Double? {
        guard wbROverGStops != nil || wbBOverGStops != nil else { return nil }
        return max(abs(wbROverGStops ?? 0), abs(wbBOverGStops ?? 0))
    }

    /// True when this row carries any structure-analysis field.
    var hasStructure: Bool { structureFocusFraction != nil || structureFocusMap != nil || structureHorizonTiltDeg != nil }

    /// True when the measured edges split cleanly into a sharp group and a soft background group.
    var hasFocusSplit: Bool { mtf50InfocusCPP != nil && mtf50BackgroundCPP != nil }

    var isFront: Bool { (lens ?? "").lowercased().contains("front") }

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
