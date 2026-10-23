import SwiftUI

struct InsightCard: View {
    let insight: Insight
    /// Resolves `insight.exampleFiles` to photos (and so to paths). Without it the Examples strip is not shown.
    var camera: CameraGroup?
    @Environment(AppModel.self) private var model: AppModel?

    private var examples: [(photo: PhotoRecord, caption: String)] {
        guard let camera else { return [] }
        let byFile = Dictionary(camera.photos.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        return insight.exampleFiles.prefix(4).enumerated().compactMap { i, f in
            byFile[f].map { ($0, i < insight.exampleCaptions.count ? insight.exampleCaptions[i] : "") }
        }
    }

    private var tint: Color {
        switch insight.severity {
        case .info: .secondary
        case .notice: .accentColor
        case .important: .orange
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(insight.finding)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text("Why: \(insight.why)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !insight.actions.isEmpty {
                    Text("Do this").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(insight.actions, id: \.self) { a in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").accessibilityHidden(true)
                                Text(a).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                }
                examplesStrip
                Divider()
                Text(insight.countedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label {
                HStack {
                    Text(insight.title).font(.headline)
                    Spacer()
                    Text(insight.severity.word).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: insight.severity.symbol).foregroundStyle(tint)
            }
        }
    }

    /// 96 pt thumbnails of the photos that show the point, each captioned with the value that made it an example.
    @ViewBuilder private var examplesStrip: some View {
        let shown = examples
        if shown.contains(where: { $0.photo.path != nil }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Examples").font(.subheadline.weight(.semibold)).padding(.top, 4)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(shown, id: \.photo.id) { ex in
                        Button { model?.selectedPhotoID = ex.photo.id } label: {
                            VStack(spacing: 4) {
                                PhotoThumb(path: ex.photo.path, maxPixel: 256).frame(width: 96, height: 96)
                                Text(ex.caption).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center).lineLimit(2)
                                    .frame(width: 96)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Show \(ex.photo.file)")
                        .accessibilityLabel("\(ex.photo.file), \(ex.caption)")
                        .accessibilityHint("Shows this photo's measurements")
                    }
                }
            }
        }
    }
}
