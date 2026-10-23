import Foundation

/// What a camera with fewer than 5 photos gets instead of coaching: its photos' own figures, never medians (spec §2
/// layer 7). Pure.
enum SparseSummary {
    static func text(for cam: CameraGroup) -> String {
        let photos = cam.photos.sorted { ($0.date ?? .distantPast, $0.file) < ($1.date ?? .distantPast, $1.file) }
        let n = photos.count
        var parts = ["Coaching starts at \(CameraRules.minPhotos) photos; this camera has \(n), so here \(n == 1 ? "is the photo's own figure" : "are the photos' own figures") rather than medians."]
        func pct(_ v: Double, _ digits: Int) -> String { Fmt.num(v, digits) }
        let clean = photos.filter(\.snrIsClean).compactMap(\.snrMidgreyDB)
        let unclean = photos.filter { $0.snrMidgreyDB != nil && !$0.snrIsClean }.count
        if clean.isEmpty {
            parts.append("No clean noise reading.")
        } else {
            parts.append("Noise \(Fmt.list(clean.map { Fmt.num($0, 1) })) dB" + (unclean > 0 ? " (\(unclean) more not counted)." : "."))
        }
        let hi = photos.compactMap(\.clipHighPct)
        if !hi.isEmpty { parts.append("Blown highlights \(Fmt.list(hi.map { pct($0, $0 < 0.1 ? 2 : 1) })) %.") }
        let lo = photos.compactMap(\.clipLowPct)
        if !lo.isEmpty {
            let under = lo.allSatisfy { $0 < CameraRules.clipPhotoPct }
            let all = lo.count == 2 ? "both" : "all"
            parts.append("Crushed shadows \(Fmt.list(lo.map { pct($0, 2) })) %" + (under ? (lo.count == 1 ? " (under the 1 % line)." : " (\(all) under the 1 % line).") : "."))
        }
        let sharp = photos.filter(\.hasSharpnessFigure)
        if sharp.isEmpty {
            let who = n == 1 ? "the photo did not have" : n == 2 ? "neither photo had" : "none of the \(n) photos had"
            parts.append("No sharpness figure: \(who) \(PhotoRecord.minEdgesForSharpness) usable straight edges.")
        } else {
            parts.append("Sharpness " + Fmt.list(sharp.compactMap { p in p.mtf50P80LWPH.map { "\(Fmt.lwph($0)) (\(Fmt.count(p.edgesMeasured ?? 0, "edge")))" } }) + ".")
        }
        parts.append("Add photos taken with this camera with Choose Photos to Analyze… (⇧⌘P).")
        return parts.joined(separator: " ")
    }
}
