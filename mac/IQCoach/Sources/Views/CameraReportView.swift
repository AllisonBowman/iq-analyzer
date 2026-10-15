import SwiftUI

struct CameraReportView: View {
    let camera: CameraGroup
    @Binding var selectedPhotoID: PhotoRecord.ID?

    private var s: CameraSummary { camera.summary }
    private var insights: [Insight] { CoachingEngine.insights(for: camera) }

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 32) {
                header
                reportCard
                CameraContentRow(camera: camera)
                charts
                coaching
                photosSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(camera.model).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
            let names = CameraRules.lensNames(camera.lenses)
            let lensText = camera.lenses.map { camera.isPhone ? (names[$0.name] ?? $0.name) : $0.name }.joined(separator: ", ")
            Text("\(Fmt.count(camera.photos.count, "photo")) · \(Fmt.count(camera.lenses.count, "lens")): \(lensText)")
                .font(.callout).foregroundStyle(.secondary)
            if let a = s.firstDate, let b = s.lastDate {
                Text("Shot \(Fmt.date(a)) to \(Fmt.date(b))").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Report card", subtitle: "Medians over all \(Fmt.count(camera.photos.count, "photo")). Each tile says what the number is, where it sits, and what good looks like.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                MetricTile(metric: .sharpnessLWPH, title: "In-focus sharpness", value: s.sharpnessLWPH,
                           detail: s.sharpnessCPP.map { "Sharpest-fifth edges, \(Fmt.cpp($0)). Higher is finer detail." })
                MetricTile(metric: .snr, title: "Noise (SNR)", value: s.snr,
                           detail: "Mid-grey signal to noise. 35 dB and up is clean; under 25 dB is visibly noisy.")
                MetricTile(metric: .highlightClip, title: "Blown highlights", value: s.clipHighMedian,
                           detail: s.clipHighShare.map { "Median share of pixels at pure white. \(Fmt.share($0)) of photos lose more than 1 %." })
                MetricTile(metric: .overshoot, title: "Sharpening halo", value: s.overshoot,
                           detail: "Edge overshoot. Under 3 % is natural; over 15 % is a visible halo.")
                MetricTile(metric: .whiteBalance, title: "Colour lean", value: s.wbLean, detail: leanDetail)
                MetricTile(metric: .dynamicRange, title: "Dynamic range", value: s.dynamicRange,
                           detail: s.dynamicRangeIsLowerBound ? "Only lower bounds were found, so read this as at least. No pass mark." : "Stops of brightness above the noise floor. No pass mark; it describes the camera.",
                           prefix: s.dynamicRangeIsLowerBound ? "At least " : "", banded: false)
            }
        }
    }

    private var leanDetail: String {
        guard let r = s.wbRStops, let b = s.wbBStops else { return "Gray-world cast of the picture as rendered." }
        let d = CameraRules.leanDescription(r: r, b: b)
        return (d.stops > 0.15 ? "Renders \(d.words)." : "Close to neutral.") + " Gray-world cast in stops."
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Charts")
            SNRvsISOChart(camera: camera)
            LensSharpnessChart(camera: camera)
            ClippingChart(camera: camera)
        }
    }

    private var coaching: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Coaching", subtitle: "What this camera does well and badly, and what to change when you shoot.")
            if insights.isEmpty {
                ContentUnavailableView("Not enough photos yet", systemImage: "camera.metering.unknown",
                                       description: Text("Coaching needs at least 5 photos from a camera; this one has \(camera.photos.count)."))
            } else {
                ForEach(insights) { InsightCard(insight: $0) }
            }
        }
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Photos", subtitle: "Choose a photo to see its measurements and per-photo editing advice.")
            PhotoTable(photos: camera.photos, selection: $selectedPhotoID)
        }
    }
}

