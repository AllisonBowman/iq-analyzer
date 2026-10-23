import Testing
import Foundation
@testable import IQCoach

/// Evidence words are counts, not probabilities (§4.2).
struct EvidenceTests {
    @Test func boundaries() {
        #expect(EvidenceGrade.grade(counted: 7, kind: .measured) == .thin)
        #expect(EvidenceGrade.grade(counted: 8, kind: .measured) == .moderate)
        #expect(EvidenceGrade.grade(counted: 19, kind: .measured) == .moderate)
        #expect(EvidenceGrade.grade(counted: 20, kind: .measured) == .solid)
        #expect(EvidenceGrade.grade(counted: 9, kind: .pixelCount) == .moderate)
        #expect(EvidenceGrade.grade(counted: 10, kind: .pixelCount) == .solid)
        #expect(EvidenceGrade.grade(counted: 7, kind: .pixelCount) == .thin)
    }

    @Test func aRangeThatCrossesTheLineIsThin() {
        // iPhone XR: 6 of 21 photos over 1 % blown; the 95 % range is 14 to 50 %, which straddles 15 %.
        let r = Stats.wilson(k: 6, n: 21)
        #expect(Int((r.lowerBound * 100).rounded()) == 14 && Int((r.upperBound * 100).rounded()) == 50)
        #expect(EvidenceGrade.grade(counted: 21, kind: .pixelCount, shareRange: r, line: 0.15) == .thin)
        #expect(EvidenceGrade.grade(counted: 206, kind: .pixelCount, shareRange: Stats.wilson(k: 54, n: 206), line: 0.15) == .solid)
    }

    @Test func edgeAndSceneRulesAreCappedAtModerate() {
        #expect(EvidenceGrade.grade(counted: 500, kind: .edgeBased) == .moderate)
        #expect(EvidenceGrade.grade(counted: 500, kind: .sceneDependent) == .moderate)
        #expect(EvidenceGrade.grade(counted: 3, kind: .edgeBased) == .thin)
    }

    @Test func wordsDoNotCollideWithBandsOrSeverities() {
        let other = Set(Band.allCases.map(\.word) + [Severity.info, .notice, .important].map(\.word))
        #expect(EvidenceGrade.allCases.allSatisfy { !other.contains($0.word) })
        #expect(EvidenceGrade.allCases.allSatisfy { $0.definition.hasPrefix($0.word) })
    }
}

struct HowSureTextTests {
    @Test func solidShareSaysItsRangeClearsTheLine() {
        let s = ShareCount(hits: 54, of: 206)
        #expect(CameraRules.howSure(.solid, counted: 206, kind: .pixelCount, share: s, line: 0.15) == "Solid: 206 photos, and allowing for chance the share is between 21 and 33 %, clear of the 15 % line.")
        #expect(CameraRules.howSure(.thin, counted: 21, kind: .pixelCount, share: ShareCount(hits: 6, of: 21), line: 0.15) == "Thin: with 21 photos the share could be anywhere from 14 to 50 %, which crosses the 15 % line.")
    }
}
