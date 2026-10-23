import Foundation
@testable import IQCoach

enum Fx {
    /// A clean, sharp, well-exposed photo; tests override what they need.
    static func photo(_ n: Int = 0, camera: String = "Test Cam", lens: String? = "Test Cam back camera 6mm f/1.8",
                      _ edit: (inout PhotoRecord) -> Void = { _ in }) -> PhotoRecord {
        var p = PhotoRecord(file: "p\(n).jpg", cameraMake: "Apple", cameraModel: camera, lens: lens)
        p.iso = 50; p.exposureS = 0.004; p.fNumber = 1.8; p.focalMM = 6
        p.width = 3024; p.height = 4032
        // Enough edges for every sharpness figure to count (iqa/report.py _sharp_ok needs 3, and 3 per region).
        p.edgesMeasured = 6; p.edgesCenter = 3; p.edgesOuter = 3
        p.mtf50P80CPP = 0.30; p.mtf50P80LWPH = 3000; p.overshootMedianPct = 4
        p.mtf50P80CILo = 0.28; p.mtf50P80CIHi = 0.32
        p.datetime = "2026:01:01 12:00:00"; p.format = "jpeg"
        p.snrMidgreyDB = 40; p.snrMidgreyExtrapolated = false; p.noiseWhiteness = 0.3
        p.noiseTextureSuspect = false; p.noisePeriodicSuspect = false
        p.clipHighPct = 0.0; p.clipLowPct = 0.0; p.lumaP50 = 120; p.tonalRangeStops = 9
        p.wbROverGStops = 0.02; p.wbBOverGStops = -0.02
        p.isRaw = false
        edit(&p)
        return p
    }

    static func camera(_ n: Int = 8, model: String = "Test Cam", _ edit: (Int, inout PhotoRecord) -> Void = { _, _ in }) -> CameraGroup {
        CameraGroup(model: model, photos: (0..<n).map { i in photo(i, camera: model) { edit(i, &$0) } })
    }
}

/// results/results.json, when the test run is given it (TEST_RUNNER_IQA_RESULTS); nil otherwise, and the test returns early.
enum RealData {
    static func library() throws -> PhotoLibrary? {
        guard let path = ProcessInfo.processInfo.environment["IQA_RESULTS"], !path.isEmpty else { return nil }
        return PhotoLibrary(sourceName: "results.json", photos: try PhotoRecord.decodeAll(from: Data(contentsOf: URL(fileURLWithPath: path))))
    }
}
