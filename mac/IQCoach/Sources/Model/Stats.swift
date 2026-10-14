import Foundation

enum Stats {
    static func median(_ values: [Double]) -> Double? {
        let v = values.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return nil }
        let mid = v.count / 2
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
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
