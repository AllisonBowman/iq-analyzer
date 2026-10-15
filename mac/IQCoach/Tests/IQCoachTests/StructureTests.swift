import Testing
import Foundation
@testable import IQCoach

struct StructureTests {
    // Editing rules
    @Test func straightenFires() {
        let a = EditingRules.straighten(Fx.photo { $0.structureHorizonTiltDeg = 1.4 })
        #expect(a?.finding.contains("1.4°") == true)
        #expect(a?.apple.contains("Straighten") == true)
        #expect(a?.lightroom.contains("Angle") == true)
        #expect(a?.generic.contains("-1.4") == true)
    }
    @Test func straightenQuietBelowOneDegree() {
        #expect(EditingRules.straighten(Fx.photo { $0.structureHorizonTiltDeg = 0.9 }) == nil)
        #expect(EditingRules.straighten(Fx.photo()) == nil)
    }
    @Test func thirdsCropFires() {
        let a = EditingRules.thirdsCrop(Fx.photo { $0.structureThirdsDistance = 0.4; $0.structureFocusFraction = 0.2 })
        #expect(a?.lightroom.contains("O") == true)
        #expect(a?.caution?.contains("taste") == true)
    }
    @Test func thirdsCropQuiet() {
        #expect(EditingRules.thirdsCrop(Fx.photo { $0.structureThirdsDistance = 0.2; $0.structureFocusFraction = 0.2 }) == nil)
        #expect(EditingRules.thirdsCrop(Fx.photo { $0.structureThirdsDistance = 0.4; $0.structureFocusFraction = 0.6 }) == nil)
        #expect(EditingRules.thirdsCrop(Fx.photo()) == nil)
    }
    @Test func shallowDepthFires() {
        let a = EditingRules.shallowDepth(Fx.photo { $0.mtf50InfocusCPP = 0.31; $0.mtf50BackgroundCPP = 0.12 })
        #expect(a?.lightroom.contains("Masking") == true)
        #expect(a?.caution?.contains("noise") == true)
    }
    @Test func shallowDepthQuiet() {
        #expect(EditingRules.shallowDepth(Fx.photo { $0.mtf50InfocusCPP = 0.31; $0.mtf50BackgroundCPP = 0.2 }) == nil)
        #expect(EditingRules.shallowDepth(Fx.photo()) == nil)
    }

    // Camera rules
    @Test func horizonLeanFires() {
        let cam = Fx.camera(8) { _, p in p.structureHorizonTiltDeg = 1.0 }
        let r = CameraRules.horizonLean(cam)
        #expect(r?.title == "Your horizons lean right by 1.0°")
        let left = CameraRules.horizonLean(Fx.camera(8) { _, p in p.structureHorizonTiltDeg = -0.8 })
        #expect(left?.title.contains("left") == true)
    }
    @Test func horizonLeanQuiet() {
        #expect(CameraRules.horizonLean(Fx.camera(8) { _, p in p.structureHorizonTiltDeg = 0.5 }) == nil)
        #expect(CameraRules.horizonLean(Fx.camera(4) { _, p in p.structureHorizonTiltDeg = 2 }) == nil)
        #expect(CameraRules.horizonLean(Fx.camera(8)) == nil)
    }
    @Test func shallowHabitFires() {
        let cam = Fx.camera(10) { i, p in if i < 4 { p.mtf50InfocusCPP = 0.3; p.mtf50BackgroundCPP = 0.1 } }
        let r = CameraRules.shallowDepthHabit(cam)
        #expect(r?.severity == .info)
        #expect(r?.finding.contains("40 %") == true)
    }
    @Test func shallowHabitQuiet() {
        let cam = Fx.camera(10) { i, p in if i < 2 { p.mtf50InfocusCPP = 0.3; p.mtf50BackgroundCPP = 0.1 } }
        #expect(CameraRules.shallowDepthHabit(cam) == nil)
    }

    // Readings
    @Test func focusCaptions() {
        let a = Fx.photo { $0.structureFocusFraction = 0.12; $0.structureFocusCX = 0.8; $0.structureFocusCY = 0.2; $0.structureThirdsDistance = 0.05 }
        #expect(Structure.focusCaption(a) == "Detail is concentrated in the top-right (12 % of the frame), on a rule-of-thirds point.")
        let b = Fx.photo { $0.structureFocusFraction = 0.9 }
        #expect(Structure.focusCaption(b) == "The frame is sharp almost everywhere (focus fraction 0.9).")
        #expect(Structure.focusCaption(Fx.photo()) == nil)
    }
    @Test func horizonBands() {
        #expect(Structure.horizonBand(0.3) == .excellent)
        #expect(Structure.horizonBand(-0.7) == .good)
        #expect(Structure.horizonBand(1.5) == .fair)
        #expect(Structure.horizonBand(3) == .poor)
        #expect(Structure.horizonText(Fx.photo()) == "no level edge found")
    }
    @Test func orientationAndSplitText() {
        let p = Fx.photo { $0.structureOrientHorizontal = 0.58; $0.structureOrientVertical = 0.3; $0.structureOrientDiagonal = 0.12
            $0.mtf50InfocusCPP = 0.31; $0.mtf50BackgroundCPP = 0.12; $0.infocusEdgeShare = 0.44 }
        #expect(Structure.orientation(p) == "mostly horizontal structure 58 %")
        #expect(Structure.splitText(p) == "sharp group 0.31 c/px on 44 % of edges; background 0.12 c/px")
    }
    @Test func decodesStructureFieldsAndNaN() throws {
        let json = #"[{"file":"a.jpg","structure_focus_fraction":0.4,"structure_horizon_tilt_deg":NaN,"mtf50_infocus_cpp":0.3,"mtf50_background_cpp":NaN,"structure_focus_map":[[0,0.5],[1,NaN]]}]"#
        let p = try PhotoRecord.decodeAll(from: Data(json.utf8))[0]
        #expect(p.structureFocusFraction == 0.4)
        #expect(p.structureHorizonTiltDeg == nil)
        #expect(p.mtf50BackgroundCPP == nil)
        #expect(p.structureFocusMap == [[0, 0.5], [1, 0]])
        #expect(p.hasStructure)
    }
    @Test func contentLine() {
        var s = ContentSummary(available: true)
        #expect(s.summaryLine == nil)
        s.faceCount = 2; s.textObservationCount = 3; s.horizonDegrees = -1.4
        #expect(s.summaryLine == "2 faces · text present · horizon 1.4° off level")
    }
    @Test func unavailableForMissingFile() {
        let s = ContentIdentifier.analyze(path: "/nonexistent/x.jpg", full: true)
        #expect(!s.available)
        #expect(s.reason != nil)
    }
}

struct VisionTests {
    /// Runs the real Vision pass on the walkthrough photo when it is on disk (media/build is not tracked).
    @Test func visionIdentifiesTheWhiteboardPhoto() async {
        let path = "/Users/allisonbowman/Developer/iq-analyzer/media/build/deck/01_photo.jpg"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let s = ContentIdentifier.analyze(path: path, full: true)
        #expect(s.available, Comment(rawValue: s.reason ?? ""))
        #expect(!s.labels.isEmpty)
        #expect(s.labels.allSatisfy { $0.confidence >= 0.25 && $0.confidence <= 1.0 })
        print("vision labels:", s.labels.map { "\($0.label) \(Int($0.confidence * 100))%" }.joined(separator: ", "))
        print("faces:", s.faceCount, "text:", s.textObservationCount, "horizon:", s.horizonDegrees.map { "\($0)" } ?? "none", "salient:", s.salientBox.map { "\($0)" } ?? "none")
    }
}
