import SwiftUI

/// Layer 4: one coaching card. The claim and its numbers, why, what to do grouped by where it is done, examples,
/// and a footer with the count, "Why Am I Seeing This?" and the More menu.
struct InsightCard: View {
    let insight: Insight
    /// Resolves `insight.exampleFiles` to photos (and so to paths). Without it the Examples strip is not shown.
    var camera: CameraGroup?
    var startCheck: ((Insight) -> Void)?
    var setAside: ((Insight) -> Void)?
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
                if let back = insight.backBecause {
                    Label(back, systemImage: "arrow.uturn.backward.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text(insight.finding)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text("Why: \(insight.why)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ActionGroups(actions: insight.actions, title: insight.isThin ? "Try this" : "What to do")
                    .padding(.top, 4)
                if let w = insight.whatWouldChange {
                    Text("What would change this: \(w)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                examplesStrip
                Divider()
                HStack(spacing: 12) {
                    Text(insight.countedText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    WhyButton(why: insight.whyShown)
                    if setAside != nil || (insight.checkKind != nil && startCheck != nil) {
                        Menu {
                            if let setAside { Button("That Is Intended…") { setAside(insight) } }
                            if insight.checkKind != nil, let startCheck { Button("Start a Check…") { startCheck(insight) } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(insight.title).font(.headline)
                } icon: {
                    Image(systemName: insight.severity.symbol).foregroundStyle(tint)
                }
                Spacer()
                Text(insight.severity.word).font(.caption).foregroundStyle(.secondary)
                EvidenceCapsule(grade: insight.grade, counted: insight.counted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(insight.severity.word). \(insight.title). \(insight.grade.word) evidence, \(Fmt.count(insight.counted, "photo")).")
            .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .contain)
        .id(insight.id)
    }

    /// 96 pt thumbnails of the photos that show the point, each captioned with the value that made it an example.
    @ViewBuilder private var examplesStrip: some View {
        let shown = examples
        if !shown.isEmpty {
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

/// A set-aside card collapsed to one line: title, date, note and Bring Back.
struct SetAsideRow: View {
    let card: SetAsideCard
    var bringBack: ((SetAsideCard) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let bringBack { Button("Bring Back") { bringBack(card) } }
        }
        .font(.callout)
    }

    var line: String { Self.line(card) }

    nonisolated static func line(_ c: SetAsideCard) -> String {
        var s = "\(c.insight.title) · set aside \(Fmt.date(c.dismissal.date))"
        if !c.dismissal.note.isEmpty { s += " · \u{201C}\(c.dismissal.note)\u{201D}" }
        return s
    }
}

/// "That Is Intended…": sets a card aside with an optional note, and says when it comes back.
struct SetAsideSheet: View {
    let insight: Insight
    let confirm: (String) -> Void
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    static let explanation = "This card moves to You set aside and stops being the one thing. It stays counted in the report card. It comes back on its own if the evidence changes: the photo count grows by a quarter, or its severity or evidence word changes."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set aside \u{201C}\(insight.title)\u{201D}?").font(.title3.weight(.semibold))
            Text(Self.explanation).fixedSize(horizontal: false, vertical: true)
            TextField("Note (optional), for example \u{201C}snow and beach days\u{201D}", text: $note)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Aside") { confirm(note); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
