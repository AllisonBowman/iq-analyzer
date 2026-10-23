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
    let severity: Severity
    let title: String
    let finding: String
    let why: String
    let actions: [String]
    let evidence: [EvidenceItem]
    /// `file` values of up to four photos that best show the point, and a caption for each (the value that made it an example).
    var exampleFiles: [String] = []
    var exampleCaptions: [String] = []
    /// Photos the finding rests on: those that passed the rule's gates in every group it compares.
    /// Each rule sets it; it is not the largest evidence row.
    var counted: Int = 0
    /// Photos from this camera (or lens) that the rule looked at, before its gates.
    var total: Int = 0

    /// The footer: "Counted: 43 of 206 photos".
    var countedText: String { "Counted: \(counted.formatted()) of \(Fmt.count(total, "photo"))" }
}

/// One piece of per-photo editing advice, worded for each editor.
struct EditingAdvice: Identifiable, Hashable, Sendable {
    let id: String
    let metric: Metric?
    let finding: String
    let apple: String
    let lightroom: String
    let generic: String
    let caution: String?

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
