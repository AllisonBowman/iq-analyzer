import Foundation

/// A before-and-after check on one share metric (feedback-layers spec §5). The baseline is frozen when the check
/// starts; new photos accumulate across loads, de-duplicated by key, because the library is replaced on every load.
struct CaptureCheck: Codable, Identifiable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case active, finished, dropped }

    struct Baseline: Codable, Sendable, Equatable {
        var hits: Int
        var count: Int
        /// Rows per format ("jpeg", "heic") in the baseline.
        var formats: [String: Int]
        var sourceName: String
        var sourceDate: Date?
        /// Photos left out because of the check's intent tag when it started.
        var intentExcluded: Int
        /// Undated photos already in the library at the start, so a later load does not count them as new.
        var undatedKeys: Set<PhotoKey> = []
    }

    struct AfterRow: Codable, Sendable, Equatable {
        var hit: Bool
        var value: Double
        var format: String?
        var file: String
        var path: String?
    }

    let id: UUID
    let camera: String
    let kind: CheckKind
    let started: Date
    let baseline: Baseline
    var after: [PhotoKey: AfterRow] = [:]
    /// New rows without an EXIF date: counted separately and left out.
    var undated: Set<PhotoKey> = []
    var status: Status = .active
    /// Set when a results file without the needed columns brought new photos: clipping counted before the fifth run,
    /// or no structure fields.
    var notComparable = false
}

extension CheckKind {
    /// The intent tag whose photos a check of this kind leaves out.
    var intent: IntentTag {
        switch self {
        case .highlights: .brightOnPurpose
        case .shadows: .darkOnPurpose
        case .levelEdges: .notMeantToBeLevel
        }
    }

    /// The per-photo value and whether it is a hit; nil when the photo does not take part (no level edge).
    func reading(_ p: PhotoRecord) -> (value: Double, hit: Bool)? {
        switch self {
        case .highlights: p.clipHighPct.map { ($0, $0 > CameraRules.clipPhotoPct) }
        case .shadows: p.clipLowPct.map { ($0, $0 > CameraRules.clipPhotoPct) }
        case .levelEdges: p.structureHorizonTiltDeg.map { ($0, abs($0) >= 1) }
        }
    }

    /// "have more than 1 % blown"
    var hitPhrase: String {
        switch self {
        case .highlights: "have more than 1 % of the frame blown"
        case .shadows: "have more than 1 % of the frame crushed to pure black"
        case .levelEdges: "have a long level edge a degree or more off level"
        }
    }

    /// How a single photo's value is written in the strip.
    func valueText(_ v: Double) -> String {
        switch self {
        case .highlights, .shadows: Fmt.pct(v, 1)
        case .levelEdges: CameraRules.signedDegrees(v)
        }
    }
}
