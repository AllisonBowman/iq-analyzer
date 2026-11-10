import SwiftUI

struct LibraryOverviewView: View {
    let library: PhotoLibrary
    var prefs = UserPreferences()
    /// The day camera freshness is measured to (fixtures pin it).
    var now: Date = .now
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.isSnapshot) private var isSnapshot

    private static func cell(_ metric: Metric, _ v: Double?) -> String {
        guard let v else { return "—" }
        return metric.format(v) + (metric.band(for: v).map { " · \($0.word)" } ?? "")
    }

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library").font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Text(library.provenance + ".")
                        .font(.callout).foregroundStyle(.secondary)
                    if let older = PhotoLibrary.olderMethodText(library.olderMethodCount(current: model?.currentAnalyzerKey)) {
                        Label(older, systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
                    }
                    if let h = CoachingEngine.headline(for: library.cameras) {
                        Text(h).font(.title3).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "Cameras", subtitle: "Each camera's one thing and report-card numbers; the count in brackets is the photos a figure rests on. Pick a camera in the sidebar for its coaching.")
                    cameraTable
                }
                if library.cameras.contains(where: { $0.representativePhoto != nil }) {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Your cameras", subtitle: "Each camera's newest photo. Choose one to open that camera's report.")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                            ForEach(library.cameras) { cameraTile($0) }
                        }
                    }
                }
                LibrarySNRChart(cameras: library.cameras)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func oneThing(_ c: CameraGroup) -> String { CoachingEngine.oneThingLine(for: c, prefs: prefs) }

    private func cameraTile(_ c: CameraGroup) -> some View {
        Button { model?.sidebarSelection = .camera(c.model); model?.selectedPhotoID = nil } label: {
            VStack(alignment: .leading, spacing: 6) {
                PhotoThumb(path: c.representativePhoto?.path, maxPixel: 400, cornerRadius: 8).frame(width: 160, height: 160)
                Text(c.model).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Fmt.count(c.photos.count, "photo")).font(.caption).foregroundStyle(.secondary)
                    if let tag = c.freshness(now: now)?.tag {
                        Text(tag).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.fill.tertiary, in: Capsule())
                            .help(CameraFreshness.banner(camera: c.model, lastDate: c.summary.lastDate, now: now) ?? "")
                    }
                }
            }
            .frame(width: 160, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Open the \(c.model) report")
        .accessibilityLabel("\(c.model), \(Fmt.count(c.photos.count, "photo"))" + (c.freshness(now: now)?.tag.map { ", \($0)" } ?? ""))
        .accessibilityHint("Opens this camera's report")
    }

    @ViewBuilder private var cameraTable: some View {
        if isSnapshot {
            SnapshotGrid(columns: [
                ("Camera", { $0.model }),
                ("Photos", { String($0.photos.count) }),
                ("One thing", { oneThing($0) }),
                ("Sharpness", { $0.summary.sharpnessCellWithCount }),
                ("Noise", { $0.summary.noiseCell }),
                ("Highlights", { Self.cell(.highlightClip, $0.summary.clipHighMedian) }),
                ("Halo", { $0.summary.haloCell }),
                ("Colour lean", { $0.summary.leanCell }),
            ], rows: library.cameras, limit: 19)
        } else {
            Table(library.cameras) {
                TableColumn("Camera") { c in Text(c.model).lineLimit(1) }.width(min: 140, ideal: 190)
                TableColumn("Photos") { c in Text(c.photos.count.formatted()).monospacedDigit() }.width(60)
                TableColumn("One thing") { c in Text(oneThing(c)).lineLimit(2).help(oneThing(c)) }.width(min: 160, ideal: 220)
                TableColumn("Sharpness") { c in Text(c.summary.sharpnessCellWithCount).monospacedDigit() }.width(min: 140, ideal: 180)
                TableColumn("Noise") { c in Text(c.summary.noiseCell).monospacedDigit() }.width(min: 110, ideal: 140)
                TableColumn("Highlights") { c in Text(Self.cell(.highlightClip, c.summary.clipHighMedian)).monospacedDigit() }.width(min: 110, ideal: 140)
                TableColumn("Halo") { c in Text(c.summary.haloCell).monospacedDigit() }.width(min: 100, ideal: 130)
                TableColumn("Colour lean") { c in Text(c.summary.leanCell).monospacedDigit() }.width(min: 130, ideal: 170)
            }
            .frame(height: CGFloat(min(library.cameras.count, 10)) * 28 + 40)
            .accessibilityLabel("Cameras table")
        }
    }
}
