import SwiftUI

extension PhotoRecord {
    var sortDate: Date { date ?? .distantPast }
    var sortISO: Double { iso ?? 0 }
    var sortSharpness: Double { mtf50P80LWPH ?? -1 }
    var sortSNR: Double { snrMidgreyDB ?? -1 }
    var sortClip: Double { max(clipHighPct ?? 0, clipLowPct ?? 0) }

    var clippingSummary: String {
        guard clipHighPct != nil || clipLowPct != nil else { return "Not measured" }
        return "\(Fmt.pct(clipHighPct ?? 0, 1)) high, \(Fmt.pct(clipLowPct ?? 0, 1)) low"
    }
}

/// A plain Grid used in place of Table when rendering PNG snapshots (Table cannot draw off-screen).
struct SnapshotGrid<Row: Identifiable>: View {
    let columns: [(title: String, text: (Row) -> String)]
    let rows: [Row]
    var limit = 14
    /// Optional first column: a thumbnail path for each row.
    var thumb: ((Row) -> String?)?
    var thumbSize: CGFloat = 44

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                if thumb != nil { Text("").frame(width: thumbSize) }
                ForEach(columns.indices, id: \.self) { Text(columns[$0].title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Divider()
            ForEach(rows.prefix(limit)) { r in
                GridRow {
                    if let thumb { PhotoThumb(path: thumb(r), maxPixel: 128).frame(width: thumbSize, height: thumbSize) }
                    ForEach(columns.indices, id: \.self) { Text(columns[$0].text(r)).font(.callout).monospacedDigit().lineLimit(1) }
                }
            }
        }
        .padding(8)
    }
}

struct PhotoTable: View {
    let photos: [PhotoRecord]
    @Binding var selection: PhotoRecord.ID?
    @State private var sortOrder = [KeyPathComparator(\PhotoRecord.sortDate, order: .reverse)]
    @Environment(\.isSnapshot) private var isSnapshot

    private var sorted: [PhotoRecord] { photos.sorted(using: sortOrder) }

    private static func band(_ metric: Metric, _ v: Double?) -> String {
        guard let v else { return "Not measured" }
        return metric.format(v) + (metric.band(for: v).map { " · \($0.word)" } ?? "")
    }

    var body: some View {
        if isSnapshot {
            SnapshotGrid(columns: [
                ("File", { $0.file }),
                ("Date", { $0.date.map(Fmt.date) ?? "No date" }),
                ("Lens", { $0.lensName }),
                ("ISO", { $0.iso.map(Fmt.int) ?? "—" }),
                ("Sharpness", { Self.band(.sharpnessLWPH, $0.mtf50P80LWPH) }),
                ("SNR", { Self.band(.snr, $0.snrMidgreyDB) }),
                ("Clipping", { $0.clippingSummary }),
            ], rows: sorted, thumb: { $0.path })
        } else {
            Table(sorted, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Photo") { p in
                    PhotoThumb(path: p.path, maxPixel: 128).frame(width: 44, height: 44).padding(.vertical, 2)
                }
                .width(52)
                TableColumn("File", value: \.file) { p in Text(p.file).lineLimit(1).truncationMode(.middle) }
                    .width(min: 120, ideal: 180)
                TableColumn("Date", value: \.sortDate) { p in Text(p.date.map(Fmt.date) ?? "No date") }
                    .width(min: 90, ideal: 110)
                TableColumn("Lens", value: \.lensName) { p in Text(p.lensName).lineLimit(1) }
                    .width(min: 120, ideal: 200)
                TableColumn("ISO", value: \.sortISO) { p in Text(p.iso.map(Fmt.int) ?? "—").monospacedDigit() }
                    .width(min: 50, ideal: 60)
                TableColumn("Sharpness", value: \.sortSharpness) { p in Text(Self.band(.sharpnessLWPH, p.mtf50P80LWPH)).monospacedDigit() }
                    .width(min: 130, ideal: 170)
                TableColumn("SNR", value: \.sortSNR) { p in Text(Self.band(.snr, p.snrMidgreyDB)).monospacedDigit() }
                    .width(min: 110, ideal: 140)
                TableColumn("Clipping", value: \.sortClip) { p in Text(p.clippingSummary).monospacedDigit() }
                    .width(min: 150, ideal: 190)
            }
            .frame(height: 440)
            .accessibilityLabel("Photos table")
        }
    }
}
