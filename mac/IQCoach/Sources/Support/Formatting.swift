import Foundation

/// Every number the user sees goes through here: formatted(), with a unit.
enum Fmt {
    static func num(_ v: Double, _ digits: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }
    static func int(_ v: Double) -> String { num(v, 0) }
    /// "ISO 1400": ISO settings are written without grouping, as cameras show them.
    static func iso(_ v: Double) -> String { "ISO \(Int(v.rounded()))" }
    static func db(_ v: Double) -> String { num(v, 1) + " dB" }
    static func pct(_ v: Double, _ digits: Int = 0) -> String { num(v, digits) + " %" }
    static func share(_ fraction: Double) -> String { num(fraction * 100, 0) + " %" }
    static func stops(_ v: Double, _ digits: Int = 2) -> String { num(v, digits) + " stops" }
    static func lwph(_ v: Double) -> String { int(v) + " LW/PH" }
    static func cpp(_ v: Double) -> String { num(v, 2) + " c/px" }
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(n == 1 ? noun : plural(noun))"
    }
    /// "lens" -> "lenses", "photo" -> "photos".
    static func plural(_ noun: String) -> String {
        let last = noun.split(separator: " ").last.map(String.init) ?? noun
        let es = ["s", "x", "z", "ch", "sh"].contains { last.hasSuffix($0) }
        return noun + (es ? "es" : "s")
    }
    static func shutter(_ s: Double) -> String {
        s >= 0.5 ? num(s, 1) + " s" : "1/" + int(1 / s) + " s"
    }
    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
}
