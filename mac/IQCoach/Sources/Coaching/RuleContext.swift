import Foundation

/// What the photographer said about a photo. The effect is always visible and always reversible (spec §3.2).
enum IntentTag: String, Codable, CaseIterable, Sendable, Identifiable {
    case darkOnPurpose, brightOnPurpose, colourIsThePoint, notMeantToBeLevel, composedThisWay

    var id: String { rawValue }

    /// The menu item and capsule word.
    var word: String {
        switch self {
        case .darkOnPurpose: "Dark on purpose"
        case .brightOnPurpose: "Bright on purpose"
        case .colourIsThePoint: "Colour is the point"
        case .notMeantToBeLevel: "Not meant to be level"
        case .composedThisWay: "Composed this way"
        }
    }

    /// Title-style capitalisation for menu items (macOS HIG).
    var menuTitle: String {
        switch self {
        case .darkOnPurpose: "Dark on Purpose"
        case .brightOnPurpose: "Bright on Purpose"
        case .colourIsThePoint: "Colour Is the Point"
        case .notMeantToBeLevel: "Not Meant to Be Level"
        case .composedThisWay: "Composed This Way"
        }
    }

    /// "you marked bright on purpose": the reason in a card's footer.
    var exclusionReason: String { "you marked \(word.lowercased())" }
}

/// What a camera rule needs besides the photos: the photographer's intent tags.
struct RuleContext: Sendable {
    var intents: [PhotoKey: Set<IntentTag>] = [:]

    static let none = RuleContext()

    func has(_ tag: IntentTag, _ p: PhotoRecord) -> Bool { intents[p.key]?.contains(tag) == true }

    /// The photos not tagged with `tag`, and how many were left out.
    func kept(_ photos: [PhotoRecord], without tag: IntentTag) -> (photos: [PhotoRecord], excluded: [ExclusionCount]) {
        let kept = photos.filter { !has(tag, $0) }
        let n = photos.count - kept.count
        return (kept, n > 0 ? [ExclusionCount(reason: tag.exclusionReason, count: n)] : [])
    }
}

/// A rule that looked and had nothing to say, with its numbers: "4 checks had nothing to say".
struct SilentCheck: Identifiable, Hashable, Sendable {
    let id: String
    /// "Crushed shadows"
    let name: String
    /// The reason, always with its numbers.
    let reason: String

    var text: String { "\(name): \(reason)" }
}

/// What a camera rule returns: a finding, a silent check, or nothing (the rule does not apply to this camera).
enum RuleResult: Sendable {
    case fired(Insight)
    case silent(SilentCheck)
    case notApplicable

    var insight: Insight? {
        if case .fired(let i) = self { return i }
        return nil
    }

    var silentCheck: SilentCheck? {
        if case .silent(let s) = self { return s }
        return nil
    }
}

/// Device wording for camera-side actions, keyed by whether the camera is a phone (spec §4.3). Every iPhone path is
/// the iOS Camera app's; confirm them on the phone before shipping.
enum CameraVocabulary {
    static func lessExposure(phone: Bool) -> String {
        phone ? "On bright scenes, tap the subject and drag the sun slider down before you shoot."
              : "On bright scenes, set exposure compensation to -0.3 to -0.7 EV, and turn on the highlight warning in playback."
    }

    static func exposeForShadows(phone: Bool) -> String {
        phone ? "In high-contrast scenes, tap the darker subject so the camera exposes for it."
              : "In high-contrast scenes, set exposure compensation to +0.3 to +0.7 EV."
    }

    static func level(phone: Bool) -> String {
        phone ? "Settings > Camera: turn on Grid and Level, and line a straight edge up with them before you shoot."
              : "Turn on the camera's grid or electronic level, if it has one, and line a straight edge up with it before you shoot."
    }

    /// nil on phones: the Camera app has no white-balance preset.
    static func whiteBalance(phone: Bool) -> String? {
        phone ? nil : "Set a white-balance preset for that light, or shoot a grey card once per lighting setup."
    }

    /// nil on phones: the Camera app has no sharpness setting.
    static func sharpening(phone: Bool) -> String? {
        phone ? nil : "Turn down the in-camera sharpening or picture style."
    }

    static func device(phone: Bool) -> String { phone ? "phone" : "camera" }
}

extension Fmt {
    /// "21 to 33 %"
    static func shareRange(_ r: ClosedRange<Double>) -> String {
        "\(num(r.lowerBound * 100, 0)) to \(num(r.upperBound * 100, 0)) %"
    }
    /// "21 and 33 %", after "between".
    static func shareBetween(_ r: ClosedRange<Double>) -> String {
        "\(num(r.lowerBound * 100, 0)) and \(num(r.upperBound * 100, 0)) %"
    }
}
