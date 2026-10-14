import Foundation

enum CoachingEngine {
    /// All camera-level insights, most important first. Cameras under five photos get none.
    static func insights(for cam: CameraGroup) -> [Insight] {
        guard cam.photos.count >= CameraRules.minPhotos else { return [] }
        var out: [Insight?] = [
            CameraRules.isoCeiling(cam),
            CameraRules.noiseCharacter(cam),
            CameraRules.lensComparison(cam),
            CameraRules.fieldSoftness(cam),
            CameraRules.highlightDiscipline(cam),
            CameraRules.shadowDiscipline(cam),
            CameraRules.sharpeningCharacter(cam),
            CameraRules.colourLean(cam),
            CameraRules.slowShutter(cam),
        ]
        out += CameraRules.apertureSweetSpot(cam)
        out.append(CameraRules.sharpnessConfidence(cam))
        return out.compactMap { $0 }.enumerated()
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
            .map(\.element)
    }

    static func editingAdvice(for photo: PhotoRecord) -> [EditingAdvice] {
        EditingRules.advice(for: photo)
    }

    /// One sentence for the library overview: who holds noise flat, who falls.
    static func headline(for cameras: [CameraGroup]) -> String? {
        let rated = cameras.filter { $0.photos.count >= CameraRules.minPhotos }.compactMap { c -> (CameraGroup, Double, Double)? in
            let bands = c.summary.snrByBand.filter { $0.count >= 3 }
            guard bands.count >= 2, let first = bands.first, let last = bands.last else { return nil }
            return (c, last.median - first.median, last.median)
        }
        guard rated.count >= 2,
              let flat = rated.min(by: { abs($0.1) < abs($1.1) }),
              let fall = rated.min(by: { $0.1 < $1.1 }), flat.0.id != fall.0.id else { return nil }
        return "\(flat.0.model) holds noise flattest across its ISO range (\(Fmt.num(flat.1, 1)) dB from lowest to highest ISO band); \(fall.0.model) falls furthest (\(Fmt.num(fall.1, 1)) dB)."
    }
}
