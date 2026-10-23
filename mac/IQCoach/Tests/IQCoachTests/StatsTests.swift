import Testing
import Foundation
@testable import IQCoach

/// Wilson and Newcombe intervals against the worked examples in the feedback-layers spec §5.
struct StatsTests {
    private func pts(_ v: Double) -> Int { Int((v * 100).rounded()) }

    @Test func wilsonMatchesTheSpec() {
        let a = Stats.wilson(k: 54, n: 206)
        #expect(abs(a.lowerBound - 0.207) < 0.0005 && abs(a.upperBound - 0.326) < 0.0005)
        let b = Stats.wilson(k: 0, n: 10)
        #expect(b.lowerBound == 0 && abs(b.upperBound - 0.278) < 0.0005)
        #expect(Stats.wilson(k: 0, n: 0) == 0...1)
    }

    /// (before k, n, after k, n, difference points, low, high), every row of the §5 table.
    static let table: [(Int, Int, Int, Int, Int, Int, Int)] = [
        (54, 206, 0, 10, -26, -33, 2),
        (54, 206, 1, 10, -16, -27, 15),
        (54, 206, 0, 20, -26, -33, -9),
        (54, 206, 1, 20, -21, -29, -2),
        (54, 206, 2, 20, -16, -26, 5),
        (54, 206, 6, 24, -1, -16, 19),
        (17, 206, 0, 10, -8, -13, 20),
        (17, 206, 0, 60, -8, -13, -2),
        (17, 206, 4, 12, 25, 5, 53),
        (22, 26, 2, 10, -65, -82, -29),
    ]

    @Test(arguments: table.indices) func newcombeMatchesEveryRow(_ i: Int) {
        let (k2, n2, k1, n1, d, lo, hi) = Self.table[i]
        let r = Stats.newcombeDifference(k1: k1, n1: n1, k2: k2, n2: n2)
        #expect(pts(r.difference) == d)
        #expect(pts(r.range.lowerBound) == lo)
        #expect(pts(r.range.upperBound) == hi)
    }

    @Test func quantileInterpolates() {
        #expect(Stats.quantile([1, 2, 3, 4], 0.25) == 1.75)
        #expect(Stats.quantile([], 0.5) == nil)
    }
}
