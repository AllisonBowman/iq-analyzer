import Foundation

enum Stats {
    static func median(_ values: [Double]) -> Double? {
        let v = values.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return nil }
        let mid = v.count / 2
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
    }

    /// Linear-interpolated quantile (numpy's default), q in 0...1.
    static func quantile(_ values: [Double], _ q: Double) -> Double? {
        let v = values.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return nil }
        let pos = q * Double(v.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return v[lo] + (v[hi] - v[lo]) * (pos - Double(lo))
    }

    /// The 95 % Wilson score interval for k successes in n trials (z = 1.96). n = 0 gives 0...1.
    static func wilson(k: Int, n: Int, z: Double = 1.96) -> ClosedRange<Double> {
        guard n > 0 else { return 0...1 }
        let p = Double(k) / Double(n), nn = Double(n), z2 = z * z
        let d = 1 + z2 / nn
        let c = (p + z2 / (2 * nn)) / d
        let h = z * ((p * (1 - p) / nn + z2 / (4 * nn * nn)).squareRoot()) / d
        return max(0, c - h)...min(1, c + h)
    }

    /// Newcombe's hybrid score interval (method 10) for the difference p1 - p2 of two independent shares, where
    /// p1 = k1/n1 and p2 = k2/n2. Callers pass the new photos as 1 and the baseline as 2, so the result is after - before.
    static func newcombeDifference(k1: Int, n1: Int, k2: Int, n2: Int) -> (difference: Double, range: ClosedRange<Double>) {
        let p1 = n1 > 0 ? Double(k1) / Double(n1) : 0, p2 = n2 > 0 ? Double(k2) / Double(n2) : 0
        let w1 = wilson(k: k1, n: n1), w2 = wilson(k: k2, n: n2)
        let d = p1 - p2
        let lo = d - ((p1 - w1.lowerBound) * (p1 - w1.lowerBound) + (w2.upperBound - p2) * (w2.upperBound - p2)).squareRoot()
        let hi = d + ((w1.upperBound - p1) * (w1.upperBound - p1) + (p2 - w2.lowerBound) * (p2 - w2.lowerBound)).squareRoot()
        return (d, lo...hi)
    }

    static func share(_ values: [Bool]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.filter { $0 }.count) / Double(values.count)
    }
}

/// The same ISO bands as FINDINGS.md.
enum ISOBand: Int, CaseIterable, Comparable, Sendable, Identifiable {
    case upTo64, to160, to400, to1000, above1000

    var id: Int { rawValue }
    static func < (a: ISOBand, b: ISOBand) -> Bool { a.rawValue < b.rawValue }

    static func band(for iso: Double) -> ISOBand {
        switch iso {
        case ...64: .upTo64
        case ...160: .to160
        case ...400: .to400
        case ...1000: .to1000
        default: .above1000
        }
    }

    var label: String {
        switch self {
        case .upTo64: "ISO 64 and below"
        case .to160: "ISO 65-160"
        case .to400: "ISO 161-400"
        case .to1000: "ISO 401-1000"
        case .above1000: "above ISO 1000"
        }
    }

    /// Top of the band as it is said aloud ("ISO 400"). The open-ended band has none.
    var topISO: Int? {
        switch self {
        case .upTo64: 64
        case .to160: 160
        case .to400: 400
        case .to1000: 1000
        case .above1000: nil
        }
    }

    /// Where the band sits on a log axis.
    var representativeISO: Double {
        switch self {
        case .upTo64: 50
        case .to160: 100
        case .to400: 250
        case .to1000: 640
        case .above1000: 2000
        }
    }
}
