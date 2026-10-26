import SwiftUI

/// Layer 1: the one change most worth making on this camera, how sure it is, where it is made, and what comes next.
struct OneThingCard: View {
    let camera: CameraGroup
    let oneThing: OneThing
    /// Scrolls to the proof (the card the one thing came from).
    var openProof: ((String) -> Void)?
    var startCheck: ((Insight) -> Void)?
    var setAside: ((Insight) -> Void)?
    var choosePhotos: (() -> Void)?
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(oneThing.sentence)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(oneThing.detail)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    if let i = oneThing.insight {
                        HStack(spacing: 12) {
                            Text(i.severity.word).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            EvidenceCapsule(grade: i.grade, counted: i.counted)
                            if let a = oneThing.action { EffortLabel(effort: a.effort) }
                        }
                        if let a = oneThing.action {
                            Text(a.text).font(.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let next = oneThing.nextUp {
                        Divider()
                        Text(next).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    controls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(oneThing.spoken(camera: camera.model))
                .accessibilityAddTraits(.isHeader)
            } label: {
                Label("The one thing", systemImage: "scope").font(.headline)
            }
            .padding(.leading, 6)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 4).accessibilityHidden(true)
            }
    }

    @ViewBuilder private var controls: some View {
        if let i = oneThing.insight {
            HStack(spacing: 12) {
                if i.checkKind != nil, let startCheck {
                    Button("Start a Check…") { startCheck(i) }
                        .buttonStyle(.borderedProminent)
                        .help("Measure your next photos against these, with a rule fixed in advance")
                }
                if isSnapshot || openProof != nil {
                    Button("Open the Proof") { openProof?(i.id) }
                        .help("Show the card this comes from, with its examples and numbers")
                }
                if let setAside {
                    Menu {
                        Button("That Is Intended…") { setAside(i) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More")
                }
            }
            .padding(.top, 4)
        } else if let choosePhotos, camera.photos.count < EvidenceGrade.thinBelow {
            Button("Choose Photos to Analyze…", action: choosePhotos)
                .disabled(model?.isBusy == true)
                .padding(.top, 4)
        }
    }
}
