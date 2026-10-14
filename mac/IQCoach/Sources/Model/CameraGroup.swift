import Foundation

struct LensGroup: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let photos: [PhotoRecord]

    var p80Sharpness: Double? { Stats.median(photos.compactMap(\.mtf50P80LWPH)) }
    var sharpnessCount: Int { photos.filter { $0.mtf50P80LWPH != nil }.count }
    var medianFocalMM: Double? { Stats.median(photos.compactMap(\.focalMM)) }
}

struct SNRBandStat: Identifiable, Sendable {
    let band: ISOBand
    let median: Double
    let count: Int
    var id: Int { band.rawValue }
}

struct CameraSummary: Sendable {
    let photoCount: Int
    let sharpnessLWPH: Double?
    let sharpnessCPP: Double?
    let snr: Double?
    let snrByBand: [SNRBandStat]
    let centreOuterRatio: Double?
    let clipHighMedian: Double?
    let clipLowMedian: Double?
    let clipHighShare: Double?
    let clipLowShare: Double?
    let whiteness: Double?
    let overshoot: Double?
    let wbRStops: Double?
    let wbBStops: Double?
    let dynamicRange: Double?
    let dynamicRangeIsLowerBound: Bool
    let firstDate: Date?
    let lastDate: Date?

    var wbLean: Double? {
        guard wbRStops != nil || wbBStops != nil else { return nil }
        return max(abs(wbRStops ?? 0), abs(wbBStops ?? 0))
    }

    init(photos: [PhotoRecord]) {
        photoCount = photos.count
        sharpnessLWPH = Stats.median(photos.compactMap(\.mtf50P80LWPH))
        sharpnessCPP = Stats.median(photos.compactMap(\.mtf50P80CPP))
        let clean = photos.filter(\.snrIsClean)
        snr = Stats.median(clean.compactMap(\.snrMidgreyDB))
        snrByBand = ISOBand.allCases.compactMap { band in
            let rows = clean.filter { $0.iso.map(ISOBand.band(for:)) == band }
            guard let m = Stats.median(rows.compactMap(\.snrMidgreyDB)) else { return nil }
            return SNRBandStat(band: band, median: m, count: rows.count)
        }
        centreOuterRatio = Stats.median(photos.compactMap { p in
            guard let c = p.mtf50CenterMedianCPP, let o = p.mtf50OuterMedianCPP, c > 0 else { return nil }
            return o / c
        })
        let hi = photos.compactMap(\.clipHighPct), lo = photos.compactMap(\.clipLowPct)
        clipHighMedian = Stats.median(hi)
        clipLowMedian = Stats.median(lo)
        clipHighShare = Stats.share(hi.map { $0 > 1 })
        clipLowShare = Stats.share(lo.map { $0 > 1 })
        whiteness = Stats.median(photos.compactMap(\.noiseWhiteness))
        overshoot = Stats.median(photos.compactMap(\.overshootMedianPct))
        wbRStops = Stats.median(photos.compactMap(\.wbROverGStops))
        wbBStops = Stats.median(photos.compactMap(\.wbBOverGStops))
        let exact = photos.filter { $0.drSNR4LowerBound != true }.compactMap(\.drSNR4Stops)
        if let m = Stats.median(exact) {
            dynamicRange = m
            dynamicRangeIsLowerBound = false
        } else {
            dynamicRange = Stats.median(photos.compactMap(\.drSNR4Stops))
            dynamicRangeIsLowerBound = true
        }
        let dates = photos.compactMap(\.date)
        firstDate = dates.min()
        lastDate = dates.max()
    }
}

struct CameraGroup: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let photos: [PhotoRecord]
    let lenses: [LensGroup]
    let summary: CameraSummary

    init(model: String, photos: [PhotoRecord]) {
        self.model = model
        self.photos = photos
        let byLens = Dictionary(grouping: photos, by: \.lensName)
        lenses = byLens.map { LensGroup(name: $0.key, photos: $0.value) }
            .sorted { ($0.medianFocalMM ?? 0) < ($1.medianFocalMM ?? 0) || (($0.medianFocalMM ?? 0) == ($1.medianFocalMM ?? 0) && $0.name < $1.name) }
        summary = CameraSummary(photos: photos)
    }

    var isPhone: Bool { model.hasPrefix("iPhone") || photos.first?.cameraMake == "Apple" }
    var isRaw: Bool { photos.contains { $0.isRaw == true } }

    static func groups(from photos: [PhotoRecord]) -> [CameraGroup] {
        Dictionary(grouping: photos, by: \.camera)
            .map { CameraGroup(model: $0.key, photos: $0.value) }
            .sorted { $0.photos.count > $1.photos.count || ($0.photos.count == $1.photos.count && $0.model < $1.model) }
    }
}

struct PhotoLibrary: Sendable {
    let sourceName: String
    let photos: [PhotoRecord]
    let cameras: [CameraGroup]

    init(sourceName: String, photos: [PhotoRecord]) {
        self.sourceName = sourceName
        self.photos = photos
        cameras = CameraGroup.groups(from: photos)
    }

    func camera(_ model: String) -> CameraGroup? { cameras.first { $0.model == model } }
}
