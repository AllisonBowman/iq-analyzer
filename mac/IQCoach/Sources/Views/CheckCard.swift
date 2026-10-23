import SwiftUI

/// Layer 2: a before-and-after check, under the one thing. Before, after and the difference with its range, the
/// verdict in words, the new photos worst first, and the rule. It never nags: no badges, no notifications.
struct CheckCard: View {
    let check: CaptureCheck
    var finish: (() -> Void)?
    var drop: (() -> Void)?
    @State private var confirmingDrop = false
    @Environment(AppModel.self) private var model: AppModel?

    private var result: CheckResult { CheckComparison.evaluate(check) }

    var body: some View {
        let r = result
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Before").foregroundStyle(.secondary)
                        Text("\(r.before.hits) of \(r.before.of) (\(Fmt.share(r.before.fraction)); \(Fmt.shareRange(r.before.range)) allowing for chance)")
                    }
                    GridRow {
                        Text("After").foregroundStyle(.secondary)
                        Text(r.after.of == 0 ? "No new photos yet" : "\(r.after.hits) of \(r.after.of) (\(Fmt.share(r.after.fraction)))")
                    }
                    if let d = r.difference, let range = r.range {
                        GridRow {
                            Text("Difference").foregroundStyle(.secondary)
                            Text("\(Self.points(d)) points (\(Self.points(range.lowerBound)) to \(Self.points(range.upperBound)))")
                        }
                    }
                }
                .monospacedDigit()
                if case .keepShooting(let k) = r.verdict {
                    ProgressView(value: Double(k), total: Double(CheckComparison.firstLook)) {
                        Text("\(k) of \(CheckComparison.firstLook) new photos for a first look").font(.caption)
                    }
                }
                Label(r.verdict.word, systemImage: r.verdict.symbol).font(.headline)
                Text(r.sentence).fixedSize(horizontal: false, vertical: true)
                if let c = r.formatCaveat {
                    Label(c, systemImage: "doc.on.doc").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let u = r.undatedLine { Text(u).font(.callout).foregroundStyle(.secondary) }
                strip
                Disclosure(title: "How I Decide") {
                    Text(CheckComparison.howIDecide).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Started \(Fmt.date(check.started)) from \(check.baseline.sourceName)\(check.status == .finished ? " · finished" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if finish != nil || drop != nil {
                        Menu {
                            if let finish, check.status == .active { Button("Finish Check", action: finish) }
                            if drop != nil { Button("Drop Check…") { confirmingDrop = true } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More")
                        .confirmationDialog("Drop this check?", isPresented: $confirmingDrop) {
                            Button("Drop Check", role: .destructive) { drop?() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Its new photos stop being counted. The photos themselves are not touched.")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Your check: \(check.kind.title)", systemImage: "flag.checkered").font(.headline)
        }
    }

    static func points(_ v: Double) -> String {
        let p = Int((v * 100).rounded())
        return p > 0 ? "+\(p)" : p < 0 ? "\u{2212}\(-p)" : "0"
    }

    /// The new photos, hits first then by value, each with its value; choosing one opens it when it is in the library.
    @ViewBuilder private var strip: some View {
        let rows = check.after.sorted { a, b in
            if a.value.hit != b.value.hit { return a.value.hit }
            if abs(a.value.value) != abs(b.value.value) { return abs(a.value.value) > abs(b.value.value) }
            return a.key < b.key
        }
        if !rows.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(rows.prefix(24), id: \.key) { key, row in
                    Button {
                        if let p = model?.library?.photos.first(where: { $0.key == key }) {
                            model?.sidebarSelection = .camera(p.camera)
                            model?.selectedPhotoID = p.id
                        }
                    } label: {
                        VStack(spacing: 2) {
                            PhotoThumb(path: row.path, maxPixel: 128).frame(width: 64, height: 64)
                            Text(check.kind.valueText(row.value)).font(.caption2).monospacedDigit()
                                .foregroundStyle(row.hit ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(row.file)
                    .accessibilityLabel("\(row.file), \(check.kind.valueText(row.value))\(row.hit ? ", counts against" : "")")
                }
            }
        }
    }
}

/// "Start a Check…": freezes the baseline now and explains what happens next.
struct StartCheckSheet: View {
    let insight: Insight
    let camera: CameraGroup
    let library: PhotoLibrary?
    let intents: [PhotoKey: Set<IntentTag>]
    let start: (CaptureCheck) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let kind = insight.checkKind ?? .highlights
        let block = CheckComparison.blockReason(kind, library: library)
        let draft = library.map { CheckComparison.start(kind, camera: camera, library: $0, intents: intents) }
        VStack(alignment: .leading, spacing: 16) {
            Text("Start a check: \(kind.title)").font(.title3.weight(.semibold))
            if let block {
                Label(block, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
            } else if let draft {
                Text(CheckComparison.startText(draft, phone: camera.isPhone)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Check") {
                    if let library { start(CheckComparison.start(kind, camera: camera, library: library, intents: intents)) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(block != nil)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
