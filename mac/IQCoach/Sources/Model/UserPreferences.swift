import Foundation

/// What the photographer told the app: editor, set-aside cards, intent tags and capture checks. Stored as one JSON
/// file (`PreferencesStore`); every field decodes leniently so an older file still loads.
struct UserPreferences: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version = UserPreferences.currentVersion
    var editor: Editor = .applePhotos
    /// Keyed by `Insight.id`, e.g. "shadow-discipline:iPhone 17 Pro Max".
    var setAside: [String: Dismissal] = [:]
    var intents: [PhotoKey: Set<IntentTag>] = [:]
    var checks: [CaptureCheck] = []

    init() {}

    enum CodingKeys: String, CodingKey { case version, editor, setAside, intents, checks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        editor = (try? c.decodeIfPresent(Editor.self, forKey: .editor)) ?? .applePhotos
        setAside = (try? c.decodeIfPresent([String: Dismissal].self, forKey: .setAside)) ?? [:]
        intents = (try? c.decodeIfPresent([PhotoKey: Set<IntentTag>].self, forKey: .intents)) ?? [:]
        checks = (try? c.decodeIfPresent([CaptureCheck].self, forKey: .checks)) ?? []
        // Migrations by version go here; version 1 is the first.
        version = Self.currentVersion
    }

    var context: RuleContext { RuleContext(intents: intents.filter { !$0.value.isEmpty }) }

    func intents(for p: PhotoRecord) -> Set<IntentTag> { intents[p.key] ?? [] }
}

/// A card the photographer set aside, with a snapshot of its evidence for the come-back rule.
struct Dismissal: Codable, Sendable, Equatable {
    var date: Date
    var note: String
    var counted: Int
    /// Share rules only: the hits at the time.
    var hits: Int?
    var severity: Severity
    var grade: EvidenceGrade

    init(date: Date = Date(), note: String = "", insight: Insight) {
        self.date = date
        self.note = note
        counted = insight.counted
        hits = insight.share?.hits
        severity = insight.severity
        grade = insight.grade
    }

    /// The card comes back when its photo count grew by a quarter, or its severity or evidence word changed.
    /// Returns the sentence it carries when it does; nil while it stays set aside.
    func comeBackReason(for i: Insight) -> String? {
        let grew = counted > 0 ? Double(i.counted - counted) / Double(counted) >= 0.25 : i.counted > 0
        guard grew || i.severity != severity || i.grade != grade else { return nil }
        let then: String, now: String
        if let h = hits, let s = i.share {
            then = "\(h) of \(Fmt.count(counted, "photo")) (\(Fmt.share(counted > 0 ? Double(h) / Double(counted) : 0)))"
            now = "\(s.hits) of \(s.of) (\(Fmt.share(s.fraction)))"
        } else {
            then = Fmt.count(counted, "photo")
            now = Fmt.count(i.counted, "photo")
        }
        var s = "Back because the evidence changed: you set this aside at \(then); it is now \(now)"
        if i.severity != severity { s += ", and it moved from \(severity.word) to \(i.severity.word)" }
        if i.grade != grade { s += "\(i.severity != severity ? "," : ", and") its evidence moved from \(grade.word) to \(i.grade.word)" }
        return s + "."
    }
}

extension PhotoKey: CodingKeyRepresentable {
    var codingKey: any CodingKey { Key(stringValue: rawValue) }
    init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

extension Severity: Codable {}
extension Editor: Codable {}
