import Foundation

/// How much stands behind a finding, as counts of photos, never as a probability (feedback-layers spec §4.2).
/// The words are chosen not to collide with band words (Poor ... Excellent) or severity words.
enum EvidenceGrade: Int, Codable, Comparable, Sendable, CaseIterable {
    case thin, moderate, solid

    static func < (a: EvidenceGrade, b: EvidenceGrade) -> Bool { a.rawValue < b.rawValue }

    /// Photos below which a finding is Thin.
    static let thinBelow = 8
    /// Photos from which a measured finding is Solid.
    static let solidFrom = 20
    /// Photos from which a direct pixel count is Solid.
    static let solidFromPixelCount = 10

    var word: String {
        switch self {
        case .thin: "Thin"
        case .moderate: "Moderate"
        case .solid: "Solid"
        }
    }

    var symbol: String {
        switch self {
        case .thin: "questionmark.circle"
        case .moderate: "circle.lefthalf.filled"
        case .solid: "checkmark.seal"
        }
    }

    /// Printed verbatim in the Glossary's Method tab.
    var definition: String {
        switch self {
        case .solid:
            "Solid: at least 20 photos passed the rule's checks (10 for direct pixel counts), the rule measures something direct (pixel counts, or noise on clean patches), and for a share the 95 % range allowing for chance stays on one side of the rule's own line."
        case .moderate:
            "Moderate: 8 to 19 photos; or the rule rests on natural edges (sharpness, sharpening halo, lens comparisons: lower bounds read from your scenes); or on an assumption a scene can break (colour lean assumes the scene averages to grey; a level edge is not always a horizon). Rules of those last two kinds never rise above Moderate."
        case .thin:
            "Thin: fewer than 8 photos, or a share whose 95 % range crosses the rule's line. A Thin finding is never the one thing; it sits under Needs more photos, says Try this instead of What to do, and says what would change it."
        }
    }

    /// The grade of a finding resting on `counted` photos. For share rules, `shareRange` is the 95 % Wilson range of
    /// the share and `line` the rule's own threshold: a range that crosses the line is Thin. Pure.
    static func grade(counted: Int, kind: EvidenceKind, shareRange: ClosedRange<Double>? = nil, line: Double? = nil) -> EvidenceGrade {
        if counted < thinBelow { return .thin }
        if let r = shareRange, let line, r.contains(line) { return .thin }
        switch kind {
        case .pixelCount: return counted >= solidFromPixelCount ? .solid : .moderate
        case .measured: return counted >= solidFrom ? .solid : .moderate
        case .edgeBased, .sceneDependent: return .moderate
        }
    }
}

/// What a rule's figure rests on, which caps how sure it can be.
enum EvidenceKind: Sendable {
    /// Direct pixel counts (clipping): the most certain figures here.
    case pixelCount
    /// Measured on clean patches (noise).
    case measured
    /// Read from natural edges in the scene: lower bounds that depend on what was photographed.
    case edgeBased
    /// Rests on an assumption a scene can break (gray-world colour, level edges).
    case sceneDependent
}

/// Where a change is made.
enum Effort: String, Codable, Sendable, CaseIterable {
    case atCamera, setUpOnce, inEditor

    var word: String {
        switch self {
        case .atCamera: "At the camera"
        case .setUpOnce: "Set up once"
        case .inEditor: "In the editor"
        }
    }

    var symbol: String {
        switch self {
        case .atCamera: "camera"
        case .setUpOnce: "gearshape"
        case .inEditor: "slider.horizontal.3"
        }
    }

    var definition: String {
        switch self {
        case .atCamera: "At the camera: a habit at the moment of shooting."
        case .setUpOnce: "Set up once: a setting changed once, such as the grid or the level."
        case .inEditor: "In the editor: for photos already taken."
        }
    }
}

/// One thing to do, and where it is done.
struct Action: Hashable, Sendable {
    let text: String
    let effort: Effort

    static func camera(_ t: String) -> Action { Action(text: t, effort: .atCamera) }
    static func setUp(_ t: String) -> Action { Action(text: t, effort: .setUpOnce) }
    static func editor(_ t: String) -> Action { Action(text: t, effort: .inEditor) }
}

/// The "Why am I seeing this?" popover: the only place the full mechanics of a rule appear.
struct WhyShown: Hashable, Sendable {
    /// Trigger and threshold.
    let rule: String
    /// n of N, with exclusions by reason.
    let counted: String
    /// The evidence word, its reason, and the range for share rules.
    let howSure: String
    /// The standing caveat.
    let cannotTell: String
    /// One concrete shot that would confirm or overturn the claim.
    let checkYourself: String

    static let empty = WhyShown(rule: "", counted: "", howSure: "", cannotTell: "", checkYourself: "")
}

/// The share metrics a before-and-after check can compare (§5).
enum CheckKind: String, Codable, Sendable, CaseIterable {
    case highlights, shadows, levelEdges

    var title: String {
        switch self {
        case .highlights: "blown highlights"
        case .shadows: "crushed shadows"
        case .levelEdges: "level edges"
        }
    }
}

/// A share with its count: the basis of a share rule's range and of a check's baseline.
struct ShareCount: Hashable, Sendable {
    let hits: Int
    let of: Int
    var fraction: Double { of > 0 ? Double(hits) / Double(of) : 0 }
    var range: ClosedRange<Double> { Stats.wilson(k: hits, n: of) }
}
