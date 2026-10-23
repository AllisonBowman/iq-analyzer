import Testing
import Foundation
@testable import IQCoach

/// The three Markdown exports (spec §6).
struct ExportTests {
    private func cam() -> CameraGroup {
        Fx.camera(100) { i, p in
            p.clipHighPct = i < 25 ? 3 : 0.1
            p.noiseWhiteness = 0.5
        }
    }

    @Test func fullExportBeginsWithTheOneThingAndEndsWithTheFooter() {
        let c = cam()
        let md = MarkdownExport.coaching(for: c, output: CoachingEngine.output(for: c))
        let headings = md.split(separator: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings.first == "## The one thing")
        #expect(md.contains("Expose for the highlights. 25 of your 100 photos (25 %)"))
        #expect(md.contains("Worth acting on · Solid · 100 photos · At the camera\n- [ ] On bright scenes, tap the subject and drag the sun slider down before you shoot."))
        #expect(md.contains("**In the editor**\n- [ ] Do not add noise reduction"))
        #expect(md.hasSuffix("---\n\(MarkdownExport.footer)\n"))
        #expect(md.contains("_Counted: 100 of 100 photos._"))
    }

    @Test func pocketCardHasFiveLinesOrFewer() {
        let c = cam()
        let card = MarkdownExport.pocketCard(for: c, output: CoachingEngine.output(for: c), date: Date(timeIntervalSince1970: 1_792_022_400))
        let lines = card.split(separator: "\n")
        #expect(lines.count <= 5)
        #expect(lines.first?.hasPrefix("Test Cam · ") == true)
        #expect(lines[1] == "1. Expose for the highlights. On bright scenes, tap the subject and drag the sun slider down before you shoot.")
        #expect(lines.last == "From 100 photos.")
        #expect(card.contains("In editing: Do not add noise reduction"))
    }

    @Test func editingStepsFollowEditOrder() {
        let p = Fx.photo { p in
            p.clipHighPct = 3; p.lumaP50 = 50; p.snrMidgreyDB = 24; p.overshootMedianPct = 15; p.wbROverGStops = 0.6
            p.structureHorizonTiltDeg = 3
        }
        let a = EditingRules.advice(for: p, context: .none)
        let md = MarkdownExport.editingSteps(for: p, advice: a, editor: .lightroom)
        let order = ["Colour lean", "Exposure: dark", "Blown highlights", "Noise", "Sharpening halo", "Level edge"]
        let positions = order.compactMap { md.range(of: "] " + $0)?.lowerBound ?? md.range(of: ". " + $0)?.lowerBound }
        #expect(positions.count == order.count)
        let doFirstPositions = a.doFirst.compactMap { md.range(of: $0.title)?.lowerBound }
        #expect(doFirstPositions == doFirstPositions.sorted())
        let alsoPositions = a.also.compactMap { md.range(of: "- [ ] \($0.title)")?.lowerBound }
        #expect(alsoPositions == alsoPositions.sorted())
        #expect(a.also.map(\.step) == a.also.map(\.step).sorted())
        #expect(md.contains("Exposure up, starting around +0.3 to +0.7."))
        #expect(md.hasSuffix(MarkdownExport.footer + "\n"))
    }

    @Test func realDataExportMatchesTheScreen() throws {
        guard let lib = try RealData.library(), let pro = lib.camera("iPhone 17 Pro Max") else { return }
        let out = CoachingEngine.output(for: pro)
        let md = MarkdownExport.coaching(for: pro, output: out, library: lib)
        #expect(md.contains("- In-focus sharpness: 1,966 LW/PH · Good, from 43 of 206 photos with 3 or more usable edges"))
        #expect(md.contains("## Needs more photos"))
        #expect(md.contains(out.oneThing?.nextUp ?? "missing"))
    }
}
