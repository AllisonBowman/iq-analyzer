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
            RecentPhotoStrip(camera: camera, selectedPhotoID: $selectedPhotoID).padding(.top, 8)
        }
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Report card", subtitle: "Each figure counts only the photos that pass its check and says how many of the \(Fmt.count(camera.photos.count, "photo")) it rests on.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                // Banded on the per-pixel figure: LW/PH is capped by the picture height, so it carries no band of its own.
                if s.hasSharpnessFigure, let lwph = s.sharpnessLWPH {
                    MetricTile(metric: .sharpnessCPP, title: "In-focus sharpness", value: s.sharpnessCPP,
                               valueText: Metric.sharpnessLWPH.format(lwph), detail: s.sharpnessCaption)
                } else {
                    MetricTile(metric: .sharpnessLWPH, title: "In-focus sharpness", value: nil,
                               valueText: CameraSummary.notEnoughText, detail: s.sharpnessCaption)
                }
                MetricTile(metric: .snr, title: "Noise (SNR)", value: s.hasSNRFigure ? s.snr : nil,
                           valueText: s.hasSNRFigure ? nil : CameraSummary.notEnoughText, detail: s.snrCaption)
                MetricTile(metric: .highlightClip, title: "Blown highlights", value: s.clipHighMedian, detail: s.clipCaption)
                MetricTile(metric: .overshoot, title: "Sharpening halo", value: s.hasOvershootFigure ? s.overshoot : nil,
                           valueText: s.hasOvershootFigure ? nil : CameraSummary.notEnoughText, detail: s.overshootCaption)
                MetricTile(metric: .whiteBalance, title: "Colour lean", value: s.wbLean, detail: s.leanCaption, banded: false)
                MetricTile(metric: .dynamicRange, title: "Dynamic range", value: s.dynamicRange,
                           detail: s.dynamicRangeCaption, prefix: s.dynamicRangePrefix, banded: false)
            }
        }
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
                ForEach(insights) { InsightCard(insight: $0, camera: camera) }
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


extension CameraGroup {
    /// Photos that have a file path, newest first.
    func recentPhotos(_ limit: Int) -> [PhotoRecord] {
        photos.filter { $0.path != nil }
            .sorted { ($0.date ?? .distantPast) != ($1.date ?? .distantPast) ? ($0.date ?? .distantPast) > ($1.date ?? .distantPast) : $0.file < $1.file }
            .prefix(limit).map { $0 }
    }

    /// The newest photo with a path: stands in for the camera in the library overview.
    var representativePhoto: PhotoRecord? { recentPhotos(1).first }
}

/// Up to eight recent photos of the camera at 96 pt; choosing one opens its measurements.
struct RecentPhotoStrip: View {
    let camera: CameraGroup
    @Binding var selectedPhotoID: PhotoRecord.ID?
    @Environment(\.isSnapshot) private var isSnapshot
    static let count = 8

    var body: some View {
        let photos = camera.recentPhotos(Self.count)
        if !photos.isEmpty {
            let strip = HStack(spacing: 10) {
                ForEach(photos) { p in
                    Button { selectedPhotoID = p.id } label: {
                        PhotoThumb(path: p.path, maxPixel: 256).frame(width: 96, height: 96)
                    }
                    .buttonStyle(.plain)
                    .help("Show \(p.file)")
                    .accessibilityLabel("Open \(p.file)")
                }
            }
            if isSnapshot { strip } else { ScrollView(.horizontal, showsIndicators: false) { strip } }
        }
    }
}
