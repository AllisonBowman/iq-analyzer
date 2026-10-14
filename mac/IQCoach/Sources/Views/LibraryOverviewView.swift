import SwiftUI

struct LibraryOverviewView: View {
    let library: PhotoLibrary
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
                    Text("\(Fmt.count(library.photos.count, "photo")) from \(Fmt.count(library.cameras.count, "camera")) in \(library.sourceName)")
                        .font(.callout).foregroundStyle(.secondary)
                    if let h = CoachingEngine.headline(for: library.cameras) {
                        Text(h).font(.title3).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "Cameras", subtitle: "Report-card numbers for every camera. Pick one in the sidebar for its coaching.")
                    cameraTable
                }
                LibrarySNRChart(cameras: library.cameras)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var cameraTable: some View {
        if isSnapshot {
            SnapshotGrid(columns: [
                ("Camera", { $0.model }),
                ("Photos", { String($0.photos.count) }),
                ("Sharpness", { Self.cell(.sharpnessLWPH, $0.summary.sharpnessLWPH) }),
                ("Noise", { Self.cell(.snr, $0.summary.snr) }),
                ("Highlights", { Self.cell(.highlightClip, $0.summary.clipHighMedian) }),
                ("Halo", { Self.cell(.overshoot, $0.summary.overshoot) }),
                ("Colour lean", { Self.cell(.whiteBalance, $0.summary.wbLean) }),
            ], rows: library.cameras, limit: 19)
        } else {
            Table(library.cameras) {
                TableColumn("Camera") { c in Text(c.model).lineLimit(1) }.width(min: 140, ideal: 190)
                TableColumn("Photos") { c in Text(c.photos.count.formatted()).monospacedDigit() }.width(60)
                TableColumn("Sharpness") { c in Text(Self.cell(.sharpnessLWPH, c.summary.sharpnessLWPH)).monospacedDigit() }.width(min: 140, ideal: 180)
                TableColumn("Noise") { c in Text(Self.cell(.snr, c.summary.snr)).monospacedDigit() }.width(min: 110, ideal: 140)
                TableColumn("Highlights") { c in Text(Self.cell(.highlightClip, c.summary.clipHighMedian)).monospacedDigit() }.width(min: 110, ideal: 140)
                TableColumn("Halo") { c in Text(Self.cell(.overshoot, c.summary.overshoot)).monospacedDigit() }.width(min: 100, ideal: 130)
                TableColumn("Colour lean") { c in Text(Self.cell(.whiteBalance, c.summary.wbLean)).monospacedDigit() }.width(min: 130, ideal: 170)
            }
            .frame(height: CGFloat(min(library.cameras.count, 10)) * 28 + 40)
            .accessibilityLabel("Cameras table")
        }
    }
}
