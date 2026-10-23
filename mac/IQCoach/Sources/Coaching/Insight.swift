import Foundation

enum InsightScope: Hashable, Sendable {
    case camera(String)
    case lens(String, String)
    case photo(String)
}

enum Severity: Int, Comparable, Sendable {
    case info, notice, important
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .notice: "lightbulb"
        case .important: "exclamationmark.circle"
        }
    }
    var word: String {
        switch self {
        case .info: "Good to know"
        case .notice: "Worth acting on"
        case .important: "Important"
        }
    }
}

struct EvidenceItem: Hashable, Sendable {
    let metric: String
    let value: String
    let n: Int
}

struct Insight: Identifiable, Hashable, Sendable {
    let id: String
    let scope: InsightScope
    var severity: Severity
    let title: String
    var finding: String
    var why: String
    /// What to do, each with where it is done. `actionTexts` gives the plain strings.
    var actions: [Action]
    let evidence: [EvidenceItem]
    /// `file` values of up to four photos that best show the point, and a caption for each (the value that made it an example).
    var exampleFiles: [String] = []
    var exampleCaptions: [String] = []
    /// Photos the finding rests on: those that passed the rule's gates in every group it compares.
    /// Each rule sets it; it is not the largest evidence row.
    var counted: Int = 0
    /// Photos from this camera (or lens) that the rule looked at, before its gates.
    var total: Int = 0

    /// How much stands behind the finding (§4.2).
    var grade: EvidenceGrade = .moderate
    var kind: EvidenceKind = .measured
    /// Photos left out of `counted`, by reason (intent tags, unclean readings).
    var excluded: [ExclusionCount] = []
    /// Share rules only: the hits and the photos they are a share of (the range and a check's baseline).
    var share: ShareCount?
    /// "Expose for the highlights.": set only on rules that can be the one thing.
    var imperative: String?
    /// The one-thing sentence after the imperative, with this camera's numbers.
    var oneThingDetail: String?
    /// Share of the camera's photos showing the behaviour the action changes (the one-thing prevalence gate).
    var prevalence: Double?
    var whyShown: WhyShown = .empty
    /// Thin cards: what would make the finding firmer.
    var whatWouldChange: String?
    var checkKind: CheckKind?
    /// A short line for "Next up" and "Also good to know", without the trailing full stop.
    var brief: String?
    /// Order among rules at equal severity and grade: highlights, shadows, ISO, level edges, lens choice, others.
    var ruleOrder: Int = 99
    /// Set when a card the photographer set aside came back because its evidence changed.
    var backBecause: String?

    var actionTexts: [String] { actions.map(\.text) }
    var isThin: Bool { grade == .thin }

    /// The footer: "Counted: 43 of 206 photos", plus the intent exclusions when there are any.
    var countedText: String {
        var s = "Counted: \(counted.formatted()) of \(Fmt.count(total, "photo"))"
        let tagged = excluded.filter { $0.reason.hasPrefix("you marked") }
        if !tagged.isEmpty {
            s += " (" + tagged.map { "\($0.count) \($0.reason) \($0.count == 1 ? "is" : "are") left out" }.joined(separator: "; ") + ")"
        }
        return s
    }

    /// "Worth acting on · Solid · 206 photos"
    var capsuleText: String { "\(severity.word) · \(grade.word) · \(Fmt.count(counted, "photo"))" }
}

/// Which photo rule a piece of advice came from.
enum AdviceRule: String, Hashable, Sendable {
    case highlights, shadows, noise, soft, halo, colourLean, flatTones, exposure, moire, straighten, thirds, shallow, clean
}

/// The fixed order edits are made in (spec §2 layer 5): white balance, exposure, highlights and shadows, noise,
/// sharpening, straighten, composition.
enum EditStep: Int, Comparable, CaseIterable, Sendable {
    case whiteBalance, exposure, tone, noise, sharpening, geometry, composition
    static func < (a: EditStep, b: EditStep) -> Bool { a.rawValue < b.rawValue }

    var word: String {
        switch self {
        case .whiteBalance: "White balance"
        case .exposure: "Exposure"
        case .tone: "Highlights and shadows"
        case .noise: "Noise"
        case .sharpening: "Sharpening"
        case .geometry: "Straighten"
        case .composition: "Composition"
        }
    }
}

/// One piece of per-photo editing advice, worded for each editor.
struct EditingAdvice: Identifiable, Hashable, Sendable {
    let id: String
    let rule: AdviceRule
    let metric: Metric?
    /// The step's heading: "Blown highlights", "Exposure: dark".
    let title: String
    let finding: String
    let apple: String
    let lightroom: String
    let generic: String
    let caution: String?
    /// Solid for direct pixel counts, Moderate for noise and edge-based advice, Thin for scene-dependent notes.
    var grade: EvidenceGrade = .moderate
    var step: EditStep = .tone
    /// The intent tag that silences this advice on the photo.
    var silencedBy: IntentTag?
    /// An extra line under the step (colour beyond sRGB).
    var note: String?
    /// The band of the value behind it, for ranking (Poor before Fair).
    var band: Band?

    /// Ranking key: Poor sorts first; advice without a band counts as Fair.
    var severityBand: Band { band.map { min($0, .fair) } ?? .fair }

    func text(for editor: Editor) -> String {
        switch editor {
        case .applePhotos: apple
        case .lightroom: lightroom
        case .any: generic
        }
    }
}

enum Editor: String, CaseIterable, Identifiable, Sendable {
    case applePhotos = "Apple Photos"
    case lightroom = "Lightroom"
    case any = "Any editor"
    var id: String { rawValue }
}
